# Changelog

All notable changes to model_runner are recorded here. The format follows
Keep a Changelog and the project uses semantic versioning.

## [Unreleased]

### Measured

- **The device budget taken again — and a fifth of a device prompt is in no
  kernel at all.** Retaken with the corrected instrument (keep the stores,
  drop the work), against a 0.841 s long prompt: `matrix_product` **515 ms**
  (removal said 595), attention **106** (108), `combine` **39** (71), `norm`
  **5** (69), `rotate` ≤15 (10). Two of the five are transformed — the
  normalization was reported at sixty-nine milliseconds and is five.

  The kernels now total **680 ms of 841**, so **160 ms — one fifth — is not
  any kernel's work**; 21 of it is the barriers, priced separately.

  That inverts the comparison. llama.cpp's logger reports kernel durations,
  and at 1419 tokens it reads ~575 ms of matrix products, 80 attention, 61
  gated middle and joins, 21 normalization, 15 rotation — **752 ms against
  our 680**. This program's device kernels are *faster* in total and its
  device prompt is slower. The gap is the fifth that belongs to no kernel,
  which is a different thing from everything chased on that side so far.

- **What a voided kernel really measures — the device budget tables say what
  removing a kernel saves, not what it costs.** Measured three ways instead
  of two: the normalization as it is reads **0.833 s**, with its work thrown
  away but one store a row keeping the region written **0.829**, and voided
  entirely **0.783**.

  **Four milliseconds is what the kernel does; forty-six is what its output
  costs the five kernels that read it.** The removal method charges it for
  both and reports fifty — a factor of twelve.

  That corrects every share in the device budget tables, and explains the
  110-token non-additivity recorded earlier as unexplained: most of each
  kernel's figure is the same downstream reads becoming cheap, and removing a
  second kernel cannot make them cheap twice. The two ends of such a table
  survive, and the ordering roughly; the shares do not.

  The instrument to use from here: keep the writes, throw away the work.

- **The probe was the bug: there is no thirty-one milliseconds.** Three
  entries chased a store that appeared to cost 29–31 ms, closing six doors on
  it. The seventh test was of the probe itself. Made to write *both* the
  halves and the binary32 copy — a correct build — the kernel reads 0.838 s,
  so adding a 4.2 MB store costs ~5 ms where removing a 2.1 MB one was
  supposed to save 29. And writing the region **once a row** — 512 stores
  instead of a million — reads 0.847, while writing nothing reads 0.810.

  Writing a megabyte into the region and a kilobyte into it cost the same;
  writing nothing is what is cheap. **The saving was in the readers, not the
  store**: the probe replaced a real dependency with reads of memory nobody
  had written. The combining step shows no effect for the same reason — its
  region is written by the tile products anyway.

  The rule worth keeping: a probe that removes a write must be asked what
  reads it.

- **The size argument refuted, and the instruction read.** Cutting the batch
  to a quarter takes the half-precision buffer from 17 MB to 4.3 — a
  fourfold cut in the working set — and the store penalty is **29 ms against
  27**. Not the size.

  `RADV_DEBUG=asm` then says what the driver actually emits: `h[at+c]` is
  `buffer_store_b16`, `y[at+c]` is `buffer_store_b32`, and the pair-packed
  `h2[(at+c)/2]` is `buffer_store_b32`. So the half store is a real 16-bit
  store and not a read-modify-write — the last mechanism that would have
  explained a per-element penalty — and the pair variant really did emit the
  wide store, so its 0.838 against 0.830 was a wide store into the half
  buffer losing to a narrow one into the same buffer.

  **Six doors closed**: the memory kind at both ends, the buffer's size, the
  store's width, its contents, and the barriers (bounded at 21 ms for a whole
  prompt, less than the 29 this costs). What is left is what else touches the
  buffer inside a submission, and this repository has no name for it yet.

- **The weights' traffic costs nothing, which takes the bus off the list.**
  Generating reads 1.17 GB of weights a token, and four refused hypotheses
  about that bus never tested the premise. With the insertion's weight cursor
  left at zero — every block reading the same thirty-two bytes, same
  instructions, same order — generating reads **1.804 s against 1.800** at
  five shares and **4.327 against 4.553** at one worker. A gigabyte and a
  sixth a token is worth *nothing* at the share count this program uses.

  It does not say what the row *is* waiting for: the kernel is 79% of the
  samples and ~380 million instructions a token, a quarter of the 28 ms a
  token takes, and the dependent chain is another quarter.

  **And the normalization's store, re-probed:** writing the binary32 copy
  instead of the half-precision one reads **0.800 s against 0.828** — 31 ms,
  where the same probe read 11 before the binary32 sum. Still not the heap,
  the bits, the width, the contents or the barriers. Untried and fitting
  every reading: the half buffer is 17 MB against the result buffer's 4.2,
  and this part's L2 is 2.

- **The step's depth had already been done, and I walked round the guard that
  says so.** The previous entry called the tile's depth the one dimension
  never varied. It was swept on 2026-08-29 — eleven shapes, all answering the
  same digest, the current one winning by 6% — and the shader says so two
  lines under the constant I edited. There is even a **repository check that
  `TILE_R` and `KCH` are thirty-two**, written for exactly this mistake; it
  did not fire because I ran the shader build and the speed tool and skipped
  `tests check` for being slow.

  Re-asking is justified by the date: that sweep was taken when the long
  device prompt was 1.935 s and it is now 0.831. Asked again with a minimal
  loop over sixteen-value units: **0.831 s without the loop, 0.880 with it at
  step 32, 0.898 at 64, 0.888 at 128.** The depth is still wrong at both
  larger values — 2% and 1% against the same loop, a smaller gap than before
  but the same sign — and the loop costs 4.5% and unlocks nothing, so it is
  not kept, for the second time and the same reason.

- **The short device prompt: the occupancy premise refuted, and the other
  runtime's tile table read.** Halving the column tile doubles the
  workgroups and changes nothing — **0.103 s against 0.101** at 110 tokens,
  0.846 against 0.841 at 1419. Fourth independent measurement on this device
  that occupancy is not the constraint.

  Measured with `GGML_VK_PERF_LOGGER`, llama.cpp's 110-token prompt is **85%
  matrix products (63.1 ms of 74.0) — the same shape as ours** (88 of 104).
  Their rates by shape: 2908/3765/575/4073 GFLOPS at n=110 against
  4552/5581/2097/5002 at n=512, so they lose a quarter to a third going from
  512 columns to 110 and **we lose 47%**. The 256-row projection is the worst
  for both (575 GFLOPS).

  `ggml-vulkan.cpp` keeps **three tile shapes chosen by matrix size** where
  this has one, and at n=110 it picks the *taller* one — already measured 13%
  worse here on the long prompt. What is left untried is the tile's **depth**:
  all three of their shapes take 64 or 128 columns of the shared dimension
  where this takes 32, and setting it to 64 compiles but does not run, so it
  is shader work rather than a constant.

- **Three more constants asked, and all three stand.** The **chunk grain**
  had never been swept — it was set to the row tile because the tiling
  requires that as a floor. One tile is also the optimum and the curve is
  monotone: 4.827 s on the long prompt at one tile, 5.009 at two, 5.264 at
  three, 5.567 at four. The floor being the optimum is luck rather than
  design, since the grain cannot go below a tile without moving the answers.

  The **elementwise pool gate** (sixteen positions) is flat from one to
  sixty-four — 1.797 to 1.810 s generating, 2.964 to 3.052 drafted — because
  a batch of one or five positions has too little elementwise work to see.
  The **quantizer's 256-block floor** does matter: 64 blocks costs 6% (1.909
  s against 1.801) and 1024 is level.

  **`Max_Batch` = 512** is flat from 256 to 1024 on both backends, two per
  cent with the arms overlapping.

- **The share count a generated token was tuned to — 2.7%, and the constant
  was measured against a pool that no longer exists.** A generated token gets
  four shares where a prompt takes eight, because under the old fixed cut a
  fifth and a sixth bought nothing and cost a straggler. The atomic-chunk
  pool replaced that cut two commits ago and this constant was never asked
  again.

  Swept on the pool that is there now: three shares 2.047 s, four 1.872,
  **five 1.812**, six 1.794, eight 1.790 — for 6.77, 7.91, 9.35, 10.88 and
  14.08 s of processor time. Alternated against four over three rounds, every
  reading of one arm below every reading of the other, **five reads 1.800 s
  against 1.849** for 9.29 s of processor against 7.87. Six is 3.1% for +38%
  and eight is level with six for +50%.

  Five takes seven eighths of the gain for less than half of what six spends
  on it — the trade the worker default is chosen on. The prompt is untouched
  and the digest holds at every share count.

  Generating: **34.8 t/s, gap 1.18 → 1.12.** Fourth constant in this program
  found right when it was measured and wrong afterwards: a tuned constant is
  a measurement, and a measurement has a date.

- **Attention read line by line against llama.cpp's, and nothing to take from
  it.** It is 108 ms of a device prompt against their 80 — the largest named
  item left on that side — so `flash_attn_cm1.comp` was read through rather
  than sampled. **The two are the same design step for step**: scores by
  cooperative matrix into shared memory, softmax read back into registers
  with a rescale, weighing by a second cooperative matrix stored to shared
  and added into those registers. The step this page had guessed was theirs
  alone is `coopMatStore` into `pvsh` and `Of[r][d] += pvsh[...]` — exactly
  what this kernel does. The tile is the same sixteen-by-sixty-four.

  The one structural difference, four subgroups, was already built and is 14%
  slower here. The one unswept parameter, the query block, is at its peak:
  sixteen rows reads **0.830 s** and thirty-two **0.911** — the third taller
  tile on this device to lose.

  Reading the other runtime's source found the answer twice on the processor
  side and nothing twice here, which is a result about the two sides: the
  device kernels are already shaped the way theirs are.

- **What the barriers cost, which bounds the question they came from.** A
  layer walks a memory barrier in wherever a step reads what a step before it
  wrote — about ten a layer, six hundred in a 1419-token prompt. Removed
  altogether (wrong answers, a ceiling only): **0.809 s against 0.830**, and
  1.199 against 1.225 generating. **21 ms, 2.5%** — the whole budget for
  anything barrier-shaped, and the 11 ms being chased is half of it. It is
  not the count either: both variants of that experiment issue the same
  barriers.

  Split with an execution-only barrier that requests no cache work: **0.816
  s**. So 7 ms is the drain — a dispatch waiting for the one before it — and
  14 is the cache maintenance a shader-read-after-shader-write requires,
  because the per-unit vector caches must be invalidated. Nothing there is
  removable.

- **The normalization taken apart — the fold is free, the store is
  everything, and the item's number was stale.** The 58 ms that ranked this
  first came from a removal sweep taken before the binary32 change; the
  kernel is **35 ms** against llama.cpp's 21 — 1.7× and 14 ms of an 830 ms
  prompt. Voided part by part against 0.830 s: the sum pass gone reads 0.834
  (free), the output pass gone reads **0.794**, neither reads 0.795.

  The eight barriers named as the mechanism cost nothing — folding in two
  turns instead reads 0.835 — so the subgroup reduction that item was really
  proposing was never built. Inside the output pass the reads are free too:
  writing a constant and reading nothing still reads 0.832.

  **The whole cost is the store, and not for its width.** A binary32 store of
  twice the bytes reads 0.819 — but it writes the *result* buffer, not the
  half-precision one, and packing two halves into one four-byte store of the
  same buffer reads 0.838. It is which buffer is written. The result buffer
  is host-cached out of the heap that is not the device's own; the
  half-precision one is the device's own and host-coherent.

  Both ends were then tried for the *write*, and neither is it. Host-cached
  out of the other heap reads **0.860 s against 0.830** — thirty worse,
  because the tile product reads that buffer every dispatch. The device's own
  kind with no host bits reads half a per cent better over four rounds, arms
  overlapping. So it is not the heap, not the property bits, not the store
  width and not the contents. What is left is the one other difference: the
  half-precision buffer is written by the normalization, read by the tile
  product, written by it and read by the combining step inside one
  submission, so every barrier in a layer is a barrier over that buffer — and
  the faster variant wrote a buffer nothing else in the sequence touched.

- **Where the device's gap is now — and a "bound" that was a bug.** Taken
  again kernel against kernel (ours by removal, llama.cpp's from
  `GGML_VK_PERF_LOGGER`), the map has changed: **matrix products 595 ms
  against ~575 — level**, attention 108 against 80, **the normalization 69
  against 21**, the gated middle and joins 71 against 61, the rotation ahead.
  The entry that opened this comparison put 84% of the gap in the matrix row
  at 3.4 teraflops against 4.9; ours is now 4.9 against 5.0.

  The entry before this one called the elementwise kernels' 16 GB/s a bound
  after ruling out the access width, the arithmetic and the memory kind. It
  was the shader: llama.cpp's `rms_norm.comp` is binary32 and ours was
  **binary64 the whole way through**, on a part that runs double at a
  sixteenth rate. A pairwise fold of 2048 squares carries a few parts in ten
  million and the epsilon is a thousand times that, so nothing downstream can
  see it. **0.832 s against 0.843 on the long prompt, 0.101 against 0.103 on
  the short one**, every digest held — including `cbf29ce484222325`, which
  both backends print — and the shader stops requiring `shaderFloat64`.

  **Both processor prompt rows are now ahead of llama.cpp** (306.4 t/s
  against 272.5 at 1419 tokens, 314.3 against 311.0 at 110) and **the
  device's long prompt is 1.05 behind**, its closest yet.

- **A share a worker, decided before any of them started — 11% of a
  processor prompt, and the long-prompt row passes llama.cpp.** Reading
  llama.cpp instead of guessing: its Q8_0 dot product is the same kernel as
  this one, and it does not repack Q8_0 weights. **The scheduling is the
  difference.** `ggml_compute_forward_mul_mat` hands out chunks of sixteen
  rows through an atomic counter; this program cut a product into one
  contiguous range per worker before any of them started. That is right when
  the workers run at the same speed, and on a fifteen-watt part sharing its
  boost between eight cores they do not — a job is not done until its slowest
  range is.

  A worker takes its next tile from an atomic counter now. The grid is
  anchored at row zero and a tile is never split, so the answer is **bit for
  bit** what the fixed cut produced, at every worker count.

  | | 1419-token prompt | 110-token prompt | 64 generated |
  | --- | ---: | ---: | ---: |
  | a range a worker | 5.412 s | 0.406 s | 1.916 s |
  | a tile at a time | **4.796 s** | **0.370 s** | **1.893 s** |

  **The processor reads the long prompt at 292.3 t/s against llama.cpp's
  268.8 — 1.09 times faster**, where it was level one commit ago and 2.7
  behind when this work began. Seven workers against one now reads 5.03x
  where the sitting before read 4.11x.

  Worth naming: three of the last five things tried on the processor were
  arithmetic and all three were level or refused. This one is the same
  instructions in the same order, handed out differently — and no profile
  would have found it, because it is not a symbol, it is workers idle in a
  spin loop.

- **The memory kind, level — and the figure the item was ranked on was
  wrong.** The device's elementwise kernels were the widest unexplained
  number on that side, and the last untested explanation was the memory:
  this machine offers a device-local kind that is *not* host-visible
  (type 0), where the engine allocates its scratch out of one that is
  host-visible and host-coherent (type 3). Coherence is a promise a driver
  can only keep by not caching, so a scratch buffer nothing maps might be
  read through to memory for a guarantee it does not need. Given its own
  kind, the half-precision buffer reads **0.847 s against 0.855 on the long
  prompt and 1.235 against 1.236 generating** — nine tenths of one per cent
  and nothing. Not kept.

  The 16 GB/s that made this worth doing counted one dispatch of the
  combining kernel a layer. **There are three** — the gated middle and the
  two residual joins, which go through the same shader on a narrower width.
  Counted properly the rate is nearer **28 GB/s**: still under half of what
  the part should do, but not the sixth that put it at the top of a list.

- **A prefetch and a wider lane, both level — and one piece of reasoning
  corrected.** A `prefetcht0` in the generating row loop, at 256 and 512
  bytes ahead, reads 1.870 and 1.871 s against 1.876: the hardware
  prefetcher already has the contiguous rows. The generating gap is now
  three things it is *not* — the page tables, the accumulator chain, the
  prefetcher.

  The device's combining step costs 71 ms of a 1419-token prompt and moves
  ~1.06 GB, which is 16 GB/s. An invocation read two halves and wrote one, so
  the two-byte lane looked like the reason; four values to an invocation
  through `f16vec4`/`vec4` aliases reads **0.844 s against 0.845 — level**.
  The mistake was taking a lane's width as the unit: a wave of 64 lanes
  reading consecutive halves is 128 contiguous bytes coalesced into two cache
  lines whatever the per-lane width, so widening it makes fewer, larger
  requests for the same bytes. Nor is it the arithmetic: replacing the whole
  activation with an addition buys 7 ms of the 71.

  `norm` costs 69 ms and moves about the same bytes, so both elementwise
  kernels sit at 16 GB/s. Whatever holds them is shared, is not their
  arithmetic, and is not the access width.

- **Two accumulators in the generating kernel — 17% at one worker, refused
  because it breaks drafting.** The page-table suspicion is refuted first:
  11.1 million second-level TLB misses over 64 tokens is 173 000 a token, ~0.8%
  of the run. What *is* the wall below three workers is the single binary32
  accumulator per row — consecutive blocks form a dependent multiply-add
  chain. Two accumulators read 3.657 s against 4.388 at one worker, 1.855
  against 1.937 at two, and 1.856 against 1.878 at seven: **17% down to 1%,
  the fewer workers the more**, which is the shape every instruction cut on
  this side has had.

  It is refused for what it does to the answers, not what it does to the
  clock. It moves the single-vector kernel only, and `Rows_By_Strips` cannot
  follow — eighteen accumulators in `ymm8`–`ymm25` already, and doubling them
  does not fit in 32 registers. The two kernels then sum in different orders,
  and **drafting depends on their agreeing**: with the change in, the drafted
  twelve-token run printed `33f48397f89839f6` and the undrafted one
  `5abff916f9d83ca6` — the guarantee `### Drafting` opens with, false in a
  published figure.

  Nothing caught it: 294/294, 28344 conformance sequences none outside
  tolerance, and the with-and-without-a-draft test did not diverge on its own
  model. The sitting's own table caught it, two digests one line apart.

  The constraint is now written down: `Rows_Singly` and `Rows_By_Strips` must
  sum a row's blocks in the same order and precision.

- **The feed-forward's activation was running on one core — 9.7% of a
  processor prompt, and the long-prompt row is now level with llama.cpp.** A
  profile sorted by *thread* rather than by symbol shows `silu` and
  `multiply` on the main task and on **no worker at all**, where every other
  hot symbol appears on all eight. At 35.66 s of processor time in 5.93 s of
  wall that is ~0.63 s of the prompt on one core of eight — a batch of 512
  positions, 5632 numbers each, twenty-two layers over.

  Three of that block's loops already went to the pool; this is the fifth and
  was never named. It is elementwise like the others, so a share is the same
  arithmetic in the same order: **`1a26d24d33b8957b` both ways**.

  | | 1419-token prompt | 110-token prompt |
  | --- | ---: | ---: |
  | on one core | 5.930 s | 0.468 s |
  | shared out | **5.355 s** | **0.448 s** |

  **The processor reads the long prompt at 269.1 t/s against llama.cpp's
  269.8 — a gap of 1.00**, level for the first time on either side of this
  comparison, where it was 2.7 when this work began. The 110-token row went
  1.39 → 1.08. The device row is untouched: it takes the whole gated block at
  once and never runs this loop.

  The method note is the sort order. By symbol these two kernels read 1.8% of
  a prompt and look like rounding; by thread they are ten per cent of the
  wall. A symbol's share of the samples is its share of the time only when
  the samples are spread evenly across threads — and a worker pool is exactly
  the arrangement where they are not.

- **Three candidates priced, none kept, and the first one's premise
  refuted.** The device prompt was said to carry ~35 ms of fixed cost,
  because 110 and 1419 tokens do not lie on a line through the origin. With
  every compute shader voided at once the 110-token prompt reads **0.008 s
  against 0.104** — 92% is in the shaders and 8 ms is the host, the queue and
  the readback together. The short prompt's gap is `matrix_product` costing
  **0.80 ms a token against 0.425 at 1419**, which is occupancy, not
  overhead; and it is not the batch (one batch of 1536 reads 0.845 s against
  0.831 in three of 512).

  It also found a limit of this repository's main measuring method: at 110
  tokens each of five small kernels appears to cost ~32 ms alone and all five
  together cost 35. Single-kernel removal stops measuring the kernel at that
  length — `place` costs nothing at 1419 tokens and appears to cost 28 ms
  here. Budgets belong on the long prompt.

  The strip kernel's scale table is worth **3.5% of a processor prompt** as a
  ceiling, and neither route reaches it: hoisting the per-block activation
  scales out of the row loop is bit-exact and *slower* (6.083 s against
  5.929), and moving the multiply into the insertion costs sixteen extra
  `vmulps` a block against the three or four the table costs, while moving
  every processor digest.

  `quantize_blocks` and `mat_mul_range_packed` are not overheads. Removing
  the first makes the prompt **14% slower** (the integer path refuses without
  a quantized activation); removing the second takes it to 1.541 s, because
  it dispatches the whole product rather than sitting beside it.

- **The block scale in three instructions instead of six, in the one kernel
  that can spend them — and two corrections to the entry below.** Decoding a
  Q8_0 block scale with `vpinsrw` rather than two byte loads, a shift and an
  or takes 8.4% off every instruction a generated token executes. In the
  shared `Scale_At` it costs Q4_K generation 21%; in `Rows_Singly`, which is
  Q8_0 and nothing else, it costs nothing and gains. **4.0% at one worker and
  1.4% at seven**, every reading of one arm below every reading of the other,
  and bit for bit the same tokens. Generating goes 33.85 → 34.34 t/s, the gap
  to llama.cpp 1.16 → 1.14.

  **Correction: the generating side is bus-bound, as this repository said
  before the last entry.** That entry claimed otherwise on an
  instructions-per-cycle figure of 2.29 — an average over cycles that include
  seven workers spinning in a four-instruction loop. By worker count: one
  worker 4.575 s and 16 GB/s at 3.46 instructions a cycle, three 1.894 s and
  40 GB/s, seven 1.893 s and nothing added. Issue-bound alone, bus-bound in
  company, corner at three. It explains the four refusals rather than
  contradicting them.

  **Correction: the 1419-token processor row published last time was an
  outlier.** It said 260.4 t/s and a gap of 1.04, from a retake reading
  5.450 s; every other reading of that binary that day lies between 5.9 and
  6.1, including this sitting's own quiet retake at 6.071. A median of three
  inside one unusually good window is not a defence against the window. The
  row now says **233.7 t/s and 1.16**, and the method gains a clause: take a
  published figure in more than one sitting.

  `Blend_Run` at two positions a turn — twenty-two instructions where two
  turns were twenty-six, bit-exact — is **0.38% of a prompt's instructions
  and nothing on the clock**. Not kept.

- **Four ways of making the generating row kernel cheaper, all refused — and
  the diagnosis behind them corrected.** The plan said that kernel copies and
  biases every weight before multiplying it. It reads the wrong kernel: a
  generated token never enters the four-row insertion, and deleting that
  staging loop moves the instruction count by **four hundredths of a per
  cent**. What a token runs already reads the weights in place and keeps its
  accumulator in a register.

  **The generating side is also not waiting for the bus**, which this
  repository has claimed for several sittings. Sixty-four tokens execute 81.2
  billion instructions in 35.5 billion cycles — **2.29 instructions a
  cycle**. The gap there is in what the two programs execute, not what they
  fetch.

  Decoding the block scale with `vpinsrw` instead of two byte loads, a shift
  and an or: **−8.4% of every instruction a token executes**, bit for bit the
  same tokens, and *not faster* — level on Q8_0 and clearly worse on Q4_K
  (0.40 s generating against 0.69). Dropping a 4 KB `rep stosq`: 1.2%, under
  the floor. Folding the bias correction into the multiply-add's own
  accumulator lane: **−18.5% of the instructions and +1.9% cycles**, because
  the `vpxor` it replaces is a zeroing idiom that occupies no execution unit
  and the load that replaces it joins the chain the arithmetic waits on.

  Three of the four cut instructions by four to eighteen per cent and none
  cut cycles. There is no front-end slack left in that kernel; the next thing
  to try has to shorten a dependency chain or move fewer bytes.

- **Both of attention's loops moved into the kernel that scores — four per
  cent of every instruction a prompt executes.** A profile of the long prompt
  put `head_scores` at 6.7 per cent of the processor's time and **forty-six
  per cent of that kernel's samples outside its run**: ten arguments, six
  reach comparisons, an index check on each of three arrays every time an
  address was taken, a frame — in front of sixty-four multiply-adds, because
  the caller walks one block of eight keys against one head and that is one
  turn of the loop inside.

  `Head_Scores_Across` takes the head range and the whole key run, proves the
  reach once for the widest head and the last key, and issues the run in
  place — block outside and head inside, the order the caller had. The run is
  a constant both procedures share, so it is the same instructions in the
  same order and **every score is bit for bit what it was**.

  Counted rather than timed, alternated twice: **1032.5 → 991.4 billion
  instructions** and **379.4 → 373.4 billion cycles**, both reproducing to
  five figures. Nine wall-clock runs over three rounds read 6.057 s against
  5.952 — 1.7 per cent, and inside the spread on its own. The counters settle
  this one and the clock does not.

  Inside the kernel the multiply-adds went from 39 per cent of the samples to
  51 and the prologue from 46 to 30. What is left is at both walls at once:
  sixty-four loads and sixty-four multiply-adds to a block on a part that
  does two of each a cycle.

  The list this came from said the cost was the horizontal fold, eight
  reductions where one transposed fold would do. **That was wrong** — the
  transposed fold has been there for months and costs about seven per cent of
  the kernel. The profile said something else and the profile was right.

  `src/library/model_runner-kernels.ads` was in no fingerprint group's source
  list, so a change to it would have passed the gate in silence. It is in the
  five groups that name the body now.

  The processor reads the 1419-token prompt at **260.4 tokens a second**
  against llama.cpp's 270.0 — a gap of **1.04**, the closest either side of
  that comparison has been at either length.

- **The feed-forward arms in half precision — kept, worth 4.5 per cent, and
  the entry below it corrected.** The two arms are read by the step that
  combines them and by nothing else, and that step reads halves — so the
  products that make them need not write binary32. The device reads the long
  prompt at **1699 tokens a second** and the gap to llama.cpp is **1.07**,
  from 1.11.

  The first build gave a different answer every run —
  `d2c51a052ab789a2`, `e7fae034fbfe106e` and others — which is a race, caught
  only because the tool prints a digest for every run. Two arms need two
  places but **three answers are live at once**: the normalization both arms
  read is still there when the first arm writes over it. Three regions, and
  the same digest in five runs.

  **The control that condemned it was wrong.** Two readings at `--repeats 1`
  with no load test put a three-region allocation at 1.102 and 1.106 s
  against 0.901, and on that the change was discarded and written up as
  refused. Swept properly — five sizes, medians of three, two rounds, arms in
  binary32 — the allocation is flat: 0.893, 0.882, 0.891, 0.894, 0.890 s at
  one, two, three, four and six regions. The size costs nothing.

  All four cells then measured together, alternated, load-gated: binary32
  arms 0.881/0.891 and 0.893/0.885 s at one and three regions; halved arms
  **0.845/0.847** at two regions with changing answers, and
  **0.851/0.842** at three with the published ones.

  The tokens are unchanged because the digest is of the generated text and
  the arms crossing in halves moves logits in the last bits without moving an
  argmax; the sweep reads 28344 sequences with none outside tolerance. Three
  readings at `--repeats 1` have now pointed the wrong way in this work, and
  this one nearly cost a correct change.

- **The activation quantizer widened: worth 0.7 per cent, and it does not
  answer the same.** `quantize_blocks` runs on 128-bit `xmm` because its
  unit compiles at baseline. Compiled for `x86-64-v3` as a probe — not
  shippable, since the binary would then fault on a processor without it —
  the wall clock read 5.809 s against about 6.05, which looked like four per
  cent. The profile is the honest measure: **`quantize_blocks` falls from
  2.0 per cent of the prompt to 1.27** and every other share stands still.

  And the 1419-token prompt comes back `b8887185cdd328a7` where it has
  always been `1a26d24d33b8957b`; reverting the switch restores it. Nothing
  in that unit reduces across lanes — its only accumulation is an integer
  total, exact in any order — so what changed is the rounding.
  `Real'Rounding` is ties away from zero, which the baseline reaches by
  adding and truncating and the vectorised form by a rounding instruction; a
  value landing exactly on a half goes the other way, and three million
  activations a batch is enough for that to show.

  Seven tenths of a per cent, four files of plumbing to get it safely, and a
  different answer. Not built.

  **The tile write-back is bit-exact and level.** `mat_mul_range_packed`
  narrows binary64 accumulators to binary32, and unlike `Real'Rounding`
  there is no emulation to differ — a narrowing is round-to-nearest-even,
  one instruction at any width. Digest held; 6.266, 6.053 and 6.218 s
  against 5.786, 6.137 and 6.220, ahead in one round of three. Its share
  moves 3.26 per cent to 3.04: the loop writes contiguously and **reads with
  a stride**, and a wider lane does not help a strided read. One of the two
  sides must be strided, which is the subject of an earlier section.

  And the reading that started it — 5.648 s, looking like six and a half per
  cent — was noise. The processor's prompt column swings five per cent
  between sittings, and this is the third single reading of it this session
  to point the wrong way.

  Worth setting beside the entry below, because they are the same lesson
  from opposite ends: widening the blending run was **bit-exact and
  slower**; widening the quantizer is **faster and not bit-exact**. In both
  the reason is a property of the instruction rather than of the lane — one
  is double-pumped, the other rounds differently.

- **Five hundred and twelve bits, on a part that has none.** A profile of
  the processor's 1419-token prompt puts 62.3 per cent in the strip kernel
  and **14.1 in attention** — `head_scores` 6.5, `blend_run` 5.6,
  `blend_exact` 1.9 — which is larger than the 1.11 times that prompt is
  behind. And nothing in this library uses a 512-bit lane: every
  hand-written vector kernel is `ymm`.

  So the blending run was widened — eight `vfmadd231ps` a position, carrying
  65 per cent of that kernel, become four in `zmm`. **Bit-exact**, and not by
  luck: every component accumulates the same terms in the same order, and
  only how many a register holds changed. And **slower**: 6.176, 6.266 and
  6.166 s against 6.049, 6.086 and 6.199, behind in two rounds of three.
  **Zen 4 runs a 512-bit instruction on 256-bit hardware**, two passes each,
  so halving the instructions leaves the cycles and adds the transitions.
  Which is why the byte dot product *is* worth `-march=x86-64-v4` and this
  is not: that is a new instruction, this is only a wider lane. Not kept.

  `head_scores` would not have gone the same way regardless — its annotation
  is led by six `vhaddps`, the reduction that ends a dot product, which a
  wider lane lengthens and which would move every processor digest here.

  **The device's `combine` is entirely traffic**: replacing its gated unit
  with a plain addition costs nothing (0.890 and 0.896 s against 0.892 and
  0.895) where removing the kernel reads 0.823. The only lever left is fewer
  bytes — the feed-forward arms in half precision, ~23 MB a layer, which
  changes what the program computes.

  **And the processor's two small kernels are at 128 bits**: `quantize_blocks`
  (2 %) is `addps`/`cmpleps`/`movups` on `xmm`, `mat_mul_range_packed` (3.4 %)
  moves its tile 64 bits at a time. Neither unit gets wide flags, deliberately
  — the wide code is isolated and chosen at run time so the binary runs
  anywhere. They want the treatment the row kernels have, widened to 256 and
  no further.

- **The workers are not spinning for nothing, and generating saturates this
  part at three cores of seven.** A profile of the processor generating puts
  73.5 per cent in the eight-bit row kernel and 12.1 in the worker loop,
  ninety-five per cent of which is four instructions — a shared counter, a
  compare, a `pause`, a decrement. Three measurements say it is not
  overhead.

  The spin budget swept: 20 000 reads 1.90 s, 4 000 reads 1.93, 400 reads
  2.04, and 0 reads 2.07. **Taking it out costs nine per cent** — the wake
  it avoids is worth more than the core it burns, a hundred and fifty-four
  times a token.

  `Ticket` and `Left` share a cache line, so a worker's decrement takes it
  from the six reading it. Given each its own line: 1.911 s against 1.907
  generating, 6.085 against 5.972 on the prompt. **Level and slightly
  worse.** Not kept.

  The worker count swept: **3 workers is fastest** (1.875 s) and 4 through 8
  are flat (1.911–1.927). Generating reads every weight once and multiplies
  once, and three cores saturate whatever carries them. The prompt on the
  same cores scales — 25.142 s at one worker to 5.944 at seven — because a
  batch shares one reading of the weights.

  **So the processor's two gaps are two problems**: generating is 1.16 times
  behind at 39.7 GB/s against 46, near a wall both runtimes are at; the
  prompt is 1.11 behind with scaling still in it.

  And `norm`'s six per cent of a device prompt is neither of its two
  suspects: the second read was refused last commit for occupancy, and
  removing the fold's eight barriers entirely reads 0.892 and 0.903 s
  against 0.892 and 0.885. Nothing kept, nothing restamped.

- **The normalization's second read of its row is free, and holding the row
  instead costs a third of the occupancy.** It walks the row once to sum the
  squares and again to scale; a workgroup is 256 lanes and a row is 2048
  values, so sixteen a lane holds the whole of it in registers — confirmed
  in registers and not scratch by the shader report. Bit-exact and **level,
  if anything behind**: 0.899, 0.906 and 0.885 s against 0.883, 0.895 and
  0.902, ahead in one round of three.

  The report says why: registers 24 → 48, subgroups a SIMD **32 → 20**. A
  row is eight kilobytes and the kernel that wrote it ran a moment before,
  so the second read is a cache hit — an instruction, not memory — and
  holding it costs twelve waves. The fourth measurement in this file to find
  occupancy is what this part is short of, and the first where the change
  removed work rather than adding it. Not kept.

  With the conversion gone the budget was taken again, two rounds each
  against an 0.897 s prompt: `matrix_product` 0.635 s (71 %),
  `attention_matrix` 0.106 (12 %), `combine` 0.071 (8 %), `norm` 0.051
  (6 %), `rotate` 0.017 (2 %), and **`half_batch` −0.003** — what a kernel
  reads when it is compiled, bound and never dispatched.

- **The fourth activation follows the other three, and the conversion kernel
  stops running altogether.** The attention blend is read by the projection
  after it and by nothing else, so it too is written only in half precision
  — where the tile kernel is the one that will attend, which the engine
  already tests for.

  In time it is **level**: 0.886, 0.900 and 0.905 s against 0.901, 0.904 and
  0.901, ahead in two rounds of three. Kept for a different reason.
  **Voiding `half_batch` entirely now leaves the 1419-token prompt at 0.885 s
  and the 110-token one at 0.105, both still answering their published
  digests** — a kernel whose absence changes neither the answers nor the time
  is a kernel that is not being dispatched. A whole pass over every
  activation of every layer has gone from the measured path. It stays in the
  program for the single-product path and for producers that feed something
  which is not a tile.

  The device reads the long prompt at **1591 tokens a second** and the gap to
  llama.cpp is **1.11**.

  **The first reading of this was taken from a binary that did not contain
  it.** The build helper swallowed its compiler output, an Ada error failed
  the build silently, and the measurement ran the previous executable — 0.893
  s with the digests holding, which is what a correct change looks like. The
  helper prints its errors now.

- **Three of the four activations a layer converts are never read in binary32,
  so they are no longer written in it: the 1419-token device prompt reads
  1577 tokens a second and the gap to llama.cpp is 1.12**, from 1.15. Ahead
  in each of three alternated rounds — 0.897, 0.905 and 0.905 s against
  0.938, 0.940 and 0.944 — four per cent, same tokens. The 110-token prompt
  goes 0.112 to 0.107.

  A normalization is read by the query, key and value; the second by both
  feed-forward arms; the gated middle by the projection down. All of those
  are tiles, and a tile's operand is half precision — it reads the copy and
  never the original. The engine walks the steps after each one and where
  every reader is a tiled product and the host keeps none of it, the step
  writes **only** the copy: two bytes a value instead of four, into the place
  the conversion would have put it, and the conversion does not run.

  **This is why the fusing two entries ago was level and this is not.**
  Writing the copy *as well* adds a store and removes a pass, and on a part
  where everything is at the bus those cancel; writing it *instead* removes
  a store and a pass and adds nothing. The question is not whether a kernel
  can write half precision but whether anything wants the binary32 — and the
  engine already had what it needed to answer it, in the same
  back-references it uses to place a barrier.

- **The repetition penalty asked its question two million times a token; it
  asks it thirty-two thousand times now. The device generates at 50.6 tokens
  a second and the gap to llama.cpp is 1.10**, from 1.20. Ahead in each of
  three alternated rounds — 1.239, 1.251 and 1.250 s against 1.279, 1.282
  and 1.283 — and bit-identical.

  The 2.8 ms of a token that is no kernel was blamed on the twenty-two
  submissions. It is not them. A profile with every kernel voided puts the
  model's one-time 1.1 GB upload at the top and the host's correct idle
  under it; writing every descriptor **twice** costs nothing (1.264 s against
  1.270). What the profile names instead is `Sampling.Adjusted` at 6.8 per
  cent: the repetition penalty is on by default over a 64-token window, and
  "is this token in the window?" was a walk of the window asked once for
  every token of the vocabulary. The window is sorted and deduplicated once a
  token now, in the one place the history changes, and the question is a
  binary search.

  **The check did not fire on it.** The sampler was in no group's source
  list, so a change that made every generated figure faster passed the gate
  in silence — the same repair `model_runner-llama.ads` needed two commits
  ago, and the second time in three days. It is in the five groups that
  publish a generating figure now.

- **A generated token is one kernel: `row_product` is 86 per cent of it and
  everything else measures zero.** Priced by voiding each kernel in turn
  over sixty-four tokens: 1.270 s as it is, **0.181 s with the row product
  voided**, and 1.249–1.282 s with attention, the joins, the
  normalizations, the rotation or the cache write voided — every one of them
  free at a batch of one.

  Per token: 19.8 ms, of which 17.0 is the row product and **2.8 is no
  kernel at all**. llama.cpp's whole token here is 17.9, so this program's
  one kernel is about as fast as their entire token and the 2.8 ms around it
  is what puts it behind.

  **The kernel is at the bus, not at its instructions** — 1.17 GB a token in
  17.0 ms is 69 GB/s of about a hundred. Tested directly: a `Q8_0` block is
  34 bytes so half of every matrix's blocks straddle a word, and the
  straddling path read both words of every pair where carrying the second
  forward reads each once — a quarter off every weight read. Bit-exact, and
  **level**: 1.276/1.282/1.280 s against 1.278/1.282/1.288.

  **The 2.8 ms is not the descriptors either**: writing every one of them
  twice costs nothing, 1.264 s against 1.270. What is left is the twenty-two
  submissions a token makes.

  And `--budget` puts attending at **75 per cent** of a generated token
  where removal puts it at zero — the sharpest illustration yet that the
  instrument answers where the host waits, not where the time goes. Nothing
  kept, nothing restamped.

- **The half-precision conversion fused into the kernel that produces the
  activation: it works, and it is level.** `norm.comp` makes two of the four
  activations a layer converts, so it writes the half copy beside its own
  answer, zeroes the positions the rounding invented, and tells the engine
  so; the engine then skips the conversion for any product reading that
  normalization. 0.926, 0.939 and 0.916 s against 0.928, 0.931 and 0.943, at
  the same tokens.

  The diagnostic is the part worth keeping: voiding `half_batch` was worth
  0.047 s before and is worth **0.011 s** after — so the fusing removed
  thirty-six milliseconds of the conversion's work and the run did not get
  thirty-six milliseconds faster. That work reappeared in the
  normalization. What a conversion costs is the writing, and the writing
  costs the same wherever it is done; what fusing saves on top — one read,
  one dispatch, one barrier — is swallowed by making a store-bound kernel
  write two arrays instead of one. The other two producers were not built,
  because they can recover at most the 0.011 s that is left and would pay
  the same extra store for it.

  A correctness trap on the way, silent on the run that matters and loud on
  the one that does not: a run whose products all take the row shader has no
  half-precision buffer, and the binding that would carry it is then the
  batch's own. The normalization wrote through it and a generated token came
  back with a different digest while the prompt's stayed right. Nothing
  kept, nothing restamped.

- **A layer converts four activations where it converted seven: the
  1419-token device prompt reads 1500 tokens a second and the gap to
  llama.cpp is 1.17**, from 1.20. Ahead in each of three alternated rounds —
  0.933, 0.921 and 0.937 s against 0.944, 0.969 and 0.969 — worth 3.7 per
  cent at the same tokens.

  Found by pricing every kernel the way attention was priced, voiding each
  of the eight in turn. The eight add to 0.966 s against a 0.964 s prompt,
  so this is the whole of where a device prompt goes:

  | kernel | what it costs |
  | --- | ---: |
  | `matrix_product` | **0.642 s, 67 %** |
  | `attention_matrix` | 0.116 s, 12 % |
  | `combine` | 0.078 s, 8 % |
  | `half_batch` | **0.076 s, 8 %** |
  | `norm` | 0.037 s, 4 % |
  | `rotate`, `place`, `row_product` | 0.017 s together |

  `half_batch` is the surprise: the smallest kernel in the program, a
  binary32 activation copied into half precision with no arithmetic at all,
  costing as much as attention's keys, values and both matrix products
  together — because it ran once per product where a layer's seven products
  share four activations. The engine already computes which earlier step
  each step reads, for the barrier; a tiled product now skips the conversion
  when the product before it converted the same answer at the same width.

  A note on how nearly this was measured wrong: the first A/B toggled the
  arms with a `sed` whose pattern matched one arm and not the other, so
  every round after the first built the same program. What caught it was the
  twelve-token run coming back identical to the thousandth in both arms,
  which two different binaries do not do.

- **Attention priced by removal instead of by the instrument: a ninth of a
  prompt and 1.4 times behind, where the instrument said a sixth and 2.1.**
  The caution recorded with the four-subgroup split — that `--budget` times
  host-side spans while the device runs on past them — turned out to matter,
  because every attention figure in the file came from it.

  Priced by taking pieces out and reading the whole run: the whole kernel is
  **0.111 s of a 0.965 s prompt**. Against llama.cpp's 0.078 s of
  flash-attention nodes that is 1.4 times, and everything else in the prompt
  is 0.854 against their 0.726, which is 1.18. The gap is flatter than this
  file has been saying and attention is a fifth of what is left, not a
  third.

  **And nothing inside the kernel is individually attributable**: removing
  either product's matrix instructions, the keys, the values, or both
  changes nothing; staging the queries is free; only removing the whole tile
  loop shows. That is what a loop looks like when its loads, its arithmetic
  and its shared-memory traffic overlap and none is the wall alone — the
  same plateau the four-subgroup split found from the other side.

  Nothing kept, nothing restamped. The profile table under `### The tile
  llama.cpp uses` now carries the correction.

- **Attention split four ways as llama.cpp splits it: correct, and fourteen
  per cent slower having won every number that was meant to make it
  faster.** `get_fa_tuning_params_coopmat1` gives this device the same
  sixteen-by-sixty-four tile this kernel already uses, and then `row_split =
  4` — four subgroups where this uses one. Their split falls in three
  places: sixteen cached positions each for scoring, four query rows each
  for the softmax, and sixteen head components each for weighing. The third
  is the clever one — splitting by component means a subgroup's slice is its
  own from the first tile to the last, so nothing is reduced across the
  four and only the softmax's rescale crosses.

  Built, same tokens, 1.108/1.099/1.092 s against 0.968/0.951/0.964 —
  behind in each of three alternated rounds. And the shader report went the
  right way on everything: registers 128 → **64**, subgroups a SIMD 8 →
  **16**, code 17588 → **6032** bytes, four times fewer sequential matrix
  instructions in a subgroup. What it buys instead is four real barriers a
  tile where one subgroup needs none.

  **Occupancy was not the constraint** — the third independent measurement
  to say so, after the 128-row product tile (+13 %) and staging both its
  operands (+16 %). Three kernels, three shapes, one answer: a workgroup
  here wants to be one subgroup.

  A caution the run exposed: `--budget` puts attention at 0.241 s before and
  0.236 s after — no change — while the run is a seventh slower. Its spans
  are host-side and the device runs past them, so the phase shares say where
  work is issued, not where time goes. Nothing kept, nothing restamped.

- **The half-precision batch turned depth-major, so a tile's operand would
  be contiguous — thirty-two per cent slower, and the reason is worth
  keeping.** The instruction's second operand is sixteen depths by sixteen
  vectors; read out of a vector-major batch that is sixteen runs of
  thirty-two bytes four kilobytes apart, and out of a depth-major copy it
  would be one contiguous run of two hundred and fifty-six.

  Taken in two pieces — the copy turned first, with the reader left alone,
  which computes wrong answers on purpose and times the transpose by itself:
  0.966 s as they were, 1.059 with the copy turned, 1.271 with both.

  The copy costs ten per cent, because "once per product" is seven times a
  layer over twenty-two layers and three batches, and turning it round makes
  its own reads the strided ones. **The reader costs twenty-two**, reading
  contiguous memory where the original strides four kilobytes:
  `ColumnMajor` is what this instruction's second operand natively is on
  this part, and asking for `RowMajor` buys a register rearrangement that
  costs more than all the locality it wins. The batch was already the right
  way round. Nothing kept, nothing restamped.

- **A wider tile, now that a batch can fill one — measured, refused, and the
  wall named.** With a batch of 512 the tile could finally be wider than
  128, which would cut the weight reads per answer, and those are a fifth of
  a prompt. Two rounds each, medians of three, digests held: 128 reads
  0.954 and 0.964 s on the long prompt, 256 reads 1.223 and 1.176, and 512
  reads 14.678 and 14.420.

  The part says why. A tile's accumulators are its registers — `TILE_R/16`
  by `TILE_V/16` of them, four apiece. At twice the width the shader reports
  **256 registers with 67 spilled**, twelve kilobytes of shared memory taken
  to spill into, and occupancy down from six subgroups a SIMD to four. At
  four times, the accumulators alone want the whole file.

  **All four walls of this tile are now measured** and they are not the same
  wall: wider is the register file (+23 %, +1400 %), taller is the barrier
  (+13 %), staging the operands is the round trip (+16 %), deeper was
  measured earlier, and the only direction that ever paid is the padded
  stride (−1 %, kept). Thirty-two by a hundred and twenty-eight on one
  subgroup is a corner, not a choice.

  The loads are already as wide as they go: the executed Q8_0 loop holds
  thirty-four `buffer_load_b128` and three `buffer_load_b32`, and the three
  are block scales. Nothing shipped; nothing moved; no figure re-measured.

- **A prompt reads the weights three times where it read them twelve: the
  1419-token device prompt goes to 1466 tokens a second and the gap to
  llama.cpp to 1.20**, from 1.27. `Max_Batch` was 128, so a batch — which is
  one pass over the whole model — made twelve passes at that length where
  llama.cpp's `n_ubatch` of 512 makes three. Five hundred and twelve is
  ahead in every alternated round: 0.961, 0.995 and 0.987 s against 1.027,
  1.026 and 1.036 on the device, and 6.126 and 6.248 against 6.440 and 6.336
  on the processor. Four per cent there and three here, same tokens.

  Above 512 it goes back — 1.026 s at 1024 — because a batch holds the
  activations of every position in it and those stop fitting. An optimum,
  not a direction, and it sits where the other runtime already had it.

  **Two careful changes to the decode measured nothing, and finding out why
  is what found this.** Replacing the decode with a constant is worth 23 per
  cent, and the disassembly showed thirty-two matrix instructions against a
  hundred and fifty others and a shared tile written one 16-bit value at a
  time. Holding the tile four values to an element and applying the scale to
  whole vectors fixed both — confirmed in the disassembly, two wide stores
  and eight packed multiplies — and read 1.032 s against 1.031. Level, and
  not kept.

  So the 23 per cent was split, because removing the decode had also removed
  the loads feeding it: **the arithmetic is 3.5 per cent and the weight
  reads are 19**. A hundred and twenty instructions of decoding are worth
  almost nothing; what a prompt does is read the weights.

  **A measuring tool that carried its own default nearly hid it.** `tests
  speed` defaulted `--batch-size` to 128, a copy of a default the command
  had just moved, so the first sitting measured a batch nobody would run. It
  reads the default out of the request record now. Second time this tool has
  differed from the command it publishes figures for.

  And `Max_Batch` lives in a specification file no fingerprint group listed
  — two defaults elsewhere moved with it, so the check fired by luck.
  `model_runner-llama.ads` is in the five groups now.

- **llama.cpp's matrix tile, built here and thirty-one per cent slower; the
  one per cent of it that was worth keeping, kept.** The matrix product is
  seventy-nine per cent of the device's prompt and 1.42 times behind — 3.4
  teraflops against 4.9, and **eighty-four per cent of the whole remaining
  gap**. Their tile was read out of `ggml-vulkan.cpp` rather than guessed
  at: `{256, 128, 128, 32}` for an AMD device with cooperative matrices on
  the open driver, four subgroups, both operands staged in shared memory.

  Built, correct, and slower. The two halves were then separated, alternated
  round by round, medians of three, on the 1419-token device prompt:

  | | prompt |
  | --- | ---: |
  | thirty-two rows, one subgroup, batch read in place | **1.026 s** |
  | the same, batch staged in shared memory | 1.195 s |
  | 128 rows, four subgroups, in place | 1.170 s |
  | 128 rows, four subgroups, staged | 1.355 s |

  **Both halves lose alone and the costs compose.** Staging the batch costs
  sixteen per cent with one subgroup, where the barrier is free and cannot
  be blamed. The taller tile costs thirteen on its own. Reading the staged
  batch four values at a time, as llama.cpp does, changes nothing. What the
  tall tile saves is real — the batch is re-read four times as often at
  thirty-two rows — and this part would rather serve those re-reads out of
  its second-level cache than pay a shared-memory round trip for them.

  **Kept: the shared weight tile's stride, padded.** Sixteen rows are read
  at once and a power-of-two stride puts all sixteen in the same banks;
  llama.cpp pads its own tile on these devices for the same reason. 1.036 s
  against 1.048, ahead in each of seven alternated pairs. Four, eight and
  sixteen measure the same, so what it buys is a stride that is not a power
  of two; two is worse than none, 1.097 s, which no bank arithmetic predicts
  and which is recorded as not understood.

  The device reads the 1419-token prompt at **1382.9 tokens a second** and
  the gap to llama.cpp is **1.27**, from 1.31. 293 tests pass, the sweep
  reads 28344 sequences with none outside tolerance, and every digest held.

- **A generated token carries its activation from layer to layer too, and
  the host's copy of its cache is read back once a token rather than once a
  layer: sixty-four generated tokens on the device read 1.269, 1.273 and
  1.286 s against 1.351, 1.336 and 1.369** — ahead in each of three
  alternated rounds, and in five of five in an earlier sitting. Eight pairs,
  eight wins, about five per cent. The device generates at **48.5 tokens a
  second**, a fifth clear of llama.cpp's processor row and 1.2 times behind
  its device one. 293 tests pass and every digest held.

  The batched evaluator got the carry, the deferred mirror and the chaining
  three commits ago; the one that generates never did, and generating is
  where the host's share of a token is. A generated token dispatches 18.29
  ms of work against llama.cpp's 17.9 — level overall, six times faster on
  attention and twice on the keys and values — while taking 20.8 ms of wall.
  The kernels were not what was left. Twenty-two layers each waiting on
  their own fence were.

  The condition that is not obvious: whether a layer may be carried is asked
  of the **next** layer as well as this one. A layer the device cannot take
  whole reads the host's copy of the activation, and the host's copy is
  exactly what carrying does not write.

  Two figures were taken twice and both are recorded rather than the kinder
  one. Sixty-four generated on the device read 1.319 s in the sitting and
  1.364 s an hour later on the same binary — a spread as wide as the change
  itself, which is why the alternated pairs and not the end-to-end cell are
  what the claim rests on.

- **The attending tile takes sixty-four cached positions rather than
  thirty-two, which is worth one per cent**: 1.025, 1.032, 1.033 and 1.046 s
  against 1.041, 1.043 and 1.046 — never behind in four rounds, ahead in
  three. Small enough to say plainly; kept because it never loses and
  because sixty-four is the tile the scalar kernel beside it already walks.
  A hundred and twenty-eight is worse, 1.058 s: a tile's scores live in
  shared memory and doubling them costs more occupancy than the halved tile
  count buys. The device reads the 1419-token prompt at **1364 tokens a
  second** and the gap to llama.cpp is **1.29**.

  **The attending kernel has no large overhead left in it.** It runs at 3.95
  microseconds a position a layer against llama.cpp's 2.85, and each piece
  that might account for that has now been priced: the round trip the
  weighted values make through shared memory is 0.5 per cent, the tile width
  1.0, and a wider tile than that is negative. The two-pass form — walk the
  tiles once for each row's largest score and once to weigh against it, so
  nothing is rescaled and the answer stays in the accumulators — removes
  only that half per cent and adds a whole second pass. It was built earlier
  in this work and measured slower; this says why it always would be.

- **The engine holds two of everything a submission holds, and a layer hands
  its work over without waiting: the 1419-token device prompt reads 1.041 s
  against 1.113**, better in each of three alternated rounds with clean
  separation. The device reads it at **1354 tokens a second** and the gap to
  llama.cpp falls from 1.36 times to **1.30** — from 2.32 when this began.
  293 tests pass, the sweep reads 28344 sequences with none outside
  tolerance, and every digest held.

  Of the time a layer spent inside its wait, 94 per cent was the device
  computing and 6 was the gap around it — the device finishing, the host
  waking, recording, submitting, and the device starting again. **68
  milliseconds a prompt in which nothing computes.**

  It needed the two changes before it: a layer that leaves its answer on the
  device and its keys and values in the device's own cache has nothing the
  host wants, so `Run` waits only where a step is kept, a matrix was
  borrowed, or the answer is the last one.

  Two command buffers, because one may not be re-recorded while it executes.
  Two sets of descriptors, because they may not be written while a
  submission reads them. Two fences. And **one semaphore, not two** — a
  binary semaphore may not be signalled while already signalled, and a
  signal nothing waits for leaves it that way, so waiting and signalling the
  same one in the same submission is what keeps it balanced. Two semaphores
  deadlocked the device tests, and a flag left set across a close deadlocked
  them again.

  The eviction floor drops one clock where a sequence is still in flight, a
  sequence that borrowed a matrix waits before giving it back, and anything
  writing what a submission may read — the activation, a grown buffer, a
  closing engine — settles everything in flight first.

- **A layer's answer stays on the device for the next layer to read: the
  1419-token device prompt reads 1.105 s against 1.134**, better in each of
  three alternated rounds with clean separation. The device reads that
  prompt at **1296 tokens a second** and the gap to llama.cpp falls from
  1.40 times to **1.36**. Digest `1a26d24d33b8957b` unmoved, sweep clean at
  28344 sequences.

  A megabyte a layer was coming out of the mapped result buffer and the same
  megabyte going back over. **Nothing is copied to stop it**: the result
  buffer keeps room at its front that nothing else is placed in, and a layer
  that carries out has its last step placed *there*, so the device writes
  the answer straight into the room the next layer reads from. The first
  version did copy — a transfer command and a barrier either side — and was
  worth half as much, 1.2 per cent against 2.6.

  **A layer may only carry out if the next one will be taken whole too.** A
  layer that falls back reads the host's copy, which is what carrying does
  not write, so the condition deciding whether the device takes a layer is
  now a function and is asked of the next layer first.

  What it does not remove is the fence per layer. The host wants nothing
  from a carried layer but its keys and values, for its own mirror of the
  cache; if that mirror went, submissions could chain and the 68 ms a prompt
  spends between submit and wake would go too. That changes what a session
  guarantees, and is not made here.

- **The rotation table is tabulated once a batch rather than once a layer:
  the 1419-token device prompt reads 1.131 s against 1.209**, better in each
  of three alternated rounds with the slowest cached run faster than the
  fastest uncached one. Six and a half per cent, and about a hundred
  milliseconds on the processor as well. The device reads that prompt at
  **1244 tokens a second** and the gap to llama.cpp falls from 1.52 times to
  **1.42**.

  `Rotary_Table` is called once a position a layer and works out a cosine
  and a sine a pair in binary64 — 128 positions by 32 pairs, 22 times a
  batch — and **it does not depend on the layer**. Everything it reads is
  fixed for one call except the rotation base, and a base is stated once
  unless an architecture states a local one for windowed layers. So it is
  cached on the base, and reallocation clears the cache.

- **Found by accounting the prompt against llama.cpp's own accounting.**
  Per-step GPU timestamps sum to 1025 ms of a 1190 ms prompt — 86 per cent
  inside a dispatch, where their logger accounts for 96. Timing `Run` from
  the caller's side split the rest: 1093 ms waiting on the device, 40 ms
  inside `Run` and not waiting, and **190 ms outside `Run` altogether**,
  three quarters of a millisecond of host work per layer. Three sections of
  work before this one had gone after the other six sevenths.

- **A prompt attends sixteen query rows to a workgroup rather than
  thirty-two: 1.212 s against 1.237** on the 1419-token prompt, better in
  each of three alternated rounds. Sixteen is the instruction's own tile and
  so the floor, and it wins on the register file — thirty-two rows hold
  twice the answer and need **256 registers against 96, four subgroups a
  SIMD against ten**. The device reads that prompt at 1194 tokens a second
  now, from 1105 two changes ago. Digest `1a26d24d33b8957b` unmoved, sweep
  clean.

- **Two shapes measured against it and not kept, both aimed at a real
  defect.** A workgroup of the matrix product answers 32 rows by 128
  vectors, so the workgroup count follows the rows: 176 for a feed-forward
  arm, 64 for a projection, **8 for the keys and values** — eight waves on a
  part with 24 SIMDs, and the rates say so exactly (4390, 4050, 3814, and
  1040 gigaflops). Sending the narrow products to the row product, which
  dispatches 32 workgroups instead of 8, reads **1.246 s against 1.223** —
  the matrix kernel wins even under-occupied. Splitting a workgroup's rows
  between two subgroups reads **1.360 s**, the third multi-subgroup shape to
  lose in this kernel after the taller tile and the wider one. Raising the
  workgroup count without putting two subgroups behind one barrier — a split
  of the columns with a pass to add the partials up — is the shape left
  untried.

- **A prompt attends through the device's matrix instruction, and the cache
  is kept in half precision so that it can: the 1419-token prompt reads
  1.236 s against 1.323**, better in each of three alternated rounds with
  every matrix run faster than every scalar one. The gap to llama.cpp on
  that prompt falls from 1.63 times to **1.52**, and the device reads it at
  1158 tokens a second against 1105.

  `attention_matrix.comp` does the scores as the queries against the
  transpose of the keys and the blend as the weights against the values,
  both through `coopMatMulAdd` at sixteen by sixteen by sixteen, with the
  softmax between them. **The same kernel was built before and rejected for
  being thirteen per cent slower**, and what was missing was not its shape:
  the instruction reads half precision and the cache was binary32, so every
  tile had to be staged into shared memory and converted there. Two kernels
  paid that — 1.535 s for the straightforward one, 1.785 for a variant that
  walks the keys twice so nothing is ever rescaled — and the difference
  between them is one more staging and one more product, a quarter of a
  second, which is what named the staging as the cost.

  So `place.comp` writes each position twice, binary32 where it always went
  and half precision after it in the same buffer, and attention loads its
  operands straight into the instruction with the cache's own stride.
  Nothing is staged but the queries. **The cache costs half again as much
  room** and `--show-stats` says so.

  **The sweep is what allows the rounding**: 28344 sequences, none outside
  tolerance, and every published digest held — `1a26d24d33b8957b`,
  `cbf29ce484222325`, `448c2ed68ec342ee`, `5abff916f9d83ca6`. A device
  without the instruction, a head wider than sixty-four or not a multiple of
  sixteen, and every generated token go to the scalar kernels unchanged.

  Two details cost measurable time. The running softmax cannot rescale a
  cooperative matrix — an accumulator's elements belong to lanes in an order
  the hardware chooses — so each tile's blend is a product of its own, moved
  through shared memory into ordinary registers where a rescale is a
  multiply. And the row reductions are clustered over half a subgroup rather
  than walked: one invocation to a row, walking its thirty-two columns, read
  1.606 s.

- **Read llama.cpp's profiler rather than deriving from ours.**
  `GGML_VK_PERF_LOGGER` prints their per-operation timings, and per position
  per layer they say attention 2.85 µs against our 6.12, the five matrix
  products 21.6 against our 22.5, everything else 3.1 against 3.3. **Our
  matrix product was already level with theirs** — 4154 gigaflops against
  4050 on the same shape — which is why three attempts at its tile shape all
  failed, and attention was fifty-two per cent of what remained. Their build
  says why on its own: `GGML_VK_DISABLE_COOPMAT=1` takes their attention
  from 2945 gigaflops to 1610 and a 1419-token prompt from 1744 tokens a
  second to 1240. This corrects an earlier note here that read that flag at
  512 tokens, where attention is a small share, and concluded the
  instruction was not where their speed came from.

- **A generated token's attention runs two hundred and fifty-six invocations
  to a workgroup where it ran sixty-four: 64 tokens after a 1419-token
  prompt read 1.603 s against 1.715**, better in each of three alternated
  rounds with every wide run faster than every narrow one. Sixty-four lanes
  is one subgroup, which made every barrier in that kernel free, and made a
  workgroup one wave. Generating, a workgroup is one head of one position,
  so a thirty-two-head model is thirty-two waves on a part with twenty-four
  SIMDs: attention reads 87 Gflop/s where the same layer's matrix products
  read 4000. Nothing there is bandwidth or arithmetic — it is a kernel with
  nothing behind it to hide a load.

  **Only the compilation a generated token enters is widened.** Reading a
  prompt, a workgroup is a head of a block of eight positions and there are
  five hundred and twelve of them, which fills the part already — and there
  the same change costs six per cent, 1.740 s against 1.635. The tiled
  compilation stays narrow, and so does the one for a device without
  subgroup operations, which reduces by walking the score tile and would
  walk four times as far.

  The value a lane carries is now four partial sums added at the end rather
  than one running sum, so a floating-point addition changed order. Both
  digests held — `1a26d24d33b8957b` and `7ec6b755e53e16b4` — and the sweep
  reads 28344 sequences with none outside tolerance. It is worth least
  where the cache is shortest: twelve tokens after a six-token prompt moved
  0.249 s to 0.240, and sixty-four after that same prompt read 1.340 s
  against 1.348, which is level.

- **Where a device prompt goes, and three attempts at the matrix product
  that were measured and not kept.** Removing one piece at a time from the
  1419-token prompt, against 1.282 s: the weight staging is worth 0.200 s,
  the activation loads 0.099, and thirty-one of every thirty-two matrix
  instructions 0.366. **So the matrix instruction is twenty-nine per cent
  of a device prompt** — a kernel whose multiplies were free would read
  0.92 s where llama.cpp reads 0.74, and the gap is not in the multiply.

  The packed half-precision dot product `v_dot2_f32_f16`, reached through a
  SPIR-V intrinsic exactly as llama.cpp reaches it, is **thirty-nine per
  cent slower** than the cooperative matrix here: 1.806 s against 1.295.
  The disassembly holds 2048 `v_dot2acc_f32_f16` in one unbroken run at 144
  registers against 256 — better on every static measure, slower on the
  only one that counts. llama.cpp does not owe its speed to it either:
  `GGML_VK_DISABLE_COOPMAT=1` reads 1418 t/s against 1408 with it.

  A taller tile, 128 rows over four subgroups with the activations staged
  in shared memory, reads 2.665 s: the 33 MB of activation re-reads that
  argued for it are second-level cache hits, not memory, so it traded free
  bandwidth for contended bandwidth. A wider tile, 512 vectors over four
  subgroups sharing one decoded copy of the weights with the step deepened
  to 128 columns so every invocation decodes, reads 1.624 s at the same
  registers and the same occupancy: 512 vectors is a two-megabyte
  activation tile, which is the whole L2. Batch width alone is neutral —
  1.319, 1.261 and 1.336 s at 128, 512 and 256. **Thirty-two rows by a
  hundred and twenty-eight vectors is where this part's cache hierarchy
  puts the optimum.**

- **A layer's second half in one submission, kept: 64 generated tokens read
  1.447 s against 1.476, and a token is 45 submissions where it was 67.**
  The entry below names the three submissions a layer makes as structural,
  because the host normalizes, rotates and joins between the products. One
  of the three is gone: `norm.comp`, a third unit on `combine.comp` that
  adds its two arms instead of gating them, back-references on the sequence
  so a step can read one it names, and `Attend_And_Feed` — nine steps where
  the engine made two submissions.

  **The missing third was the normalization, and the bisect that found it
  is the point.** The same sequence with the norm replaced by a join of the
  same shape reads 1.370 s against 1.820 with it, and 1.48 unfused — so the
  fusing was worth what the submission count said, and the kernel in the
  middle was giving all of it back. Three shapes: the sum walked on one
  invocation cost 320 µs a layer; the workgroup fetching each block together
  with one lane adding it up cost 100, all of it the adds, with the other
  255 lanes at a barrier; folding the sum eight times costs nothing
  measurable.

  **Folding gives up bit-exactness, and the sweep is what allows it.** A
  tree associates differently from a walk, so this is one of the few places
  on the device where the conformance sweep judges rather than a digest:
  28344 sequences across 13 architectures and 15 formats, none outside
  tolerance. The published digests did not move either — `5abff916f9d83ca6`
  for twelve tokens and `448c2ed68ec342ee` for sixty-four — which is a fact
  about this model and not a guarantee.

  The prompt is level: a batch amortizes a submission over its positions
  already, and its normalization is real work rather than a fixed cost.

- **The processor's strip kernel asked again and closed with a ceiling.** Its
  feed-forward is 64.5 % of a 1419-token processor prompt, the largest single
  number left in this file. The block loop still disassembles to 77
  instructions of which 50 want one of the two vector pipes, so its floor is
  25 cycles; `perf stat` over a whole prompt puts it at **25.2**. It is on
  its floor.

  **16 of those 50 pipe slots do the multiplying.** The other 34 are Q8_0's
  per-32-element scale: a `vpdpbusd` covers exactly one block, so every
  block's integer result is converted and scaled before it joins the row's
  sum — one convert and one multiply-add per dot product, whatever the tile
  is. The kernel therefore runs at about a third of what the part's byte dot
  product could do, and the two thirds are the format rather than the loop.

- **A register-tiled product built without the matrix instruction, and it is
  slower: 2.98 s against 1.66.** 128 rows × 128 vectors a workgroup, 256
  invocations dividing it 16×16, each holding an 8×8 square of the answer in
  registers — four multiplies per shared-memory read where the kernel it
  would replace does one. Bit-exact. Not registers or occupancy either: 104
  VGPRs against the matrix kernel's 168, nothing spilled, and 8 subgroups a
  SIMD against 6. The inner loop is 16 reads, 16 conversions and 64
  multiply-adds — two thirds efficiency at best, a quarter measured.

  **Then their source was read rather than guessed at, which should have come
  first.** What their kernel has that this did not is one instruction:
  `v_dot2_f32_f16`, a SPIR-V intrinsic doing two half-precision multiplies
  and an addition into a binary32 sum where a scalar loop spends two — and
  the part advertises it, `fp16: dot2`, in the line that runtime prints at
  startup. Staging the tiles as pairs and calling it takes 2.98 s to **2.02**,
  the 1.47× the arithmetic predicts. Four halves a read is worse (2.12), so
  the pair is the width.

  **Their tile and thread shape too**: 64×64 rather than 128×128, 256
  invocations holding 4×4 rather than 8×8 — the worse ratio and the better
  occupancy, and the occupancy wins: **1.95 s**. At 48 registers and 20
  subgroups a SIMD against the matrix kernel's 168 and 6, it is short of
  neither waves nor registers and still 18 % behind — because a
  cooperative-matrix multiply-add is 4096 multiply-adds in one instruction
  where a packed dot is two a lane. A dot-product kernel cannot beat a
  matrix kernel that is fed at all.

  **Then both kernels were disassembled** — the other runtime runs on the
  same driver, and `RADV_DEBUG=asm` prints what it generates. Their loop is
  512 `v_dot2acc_f32_f16` against 90 `ds_load_b64`, and their occupancy is 72
  registers and 14 subgroups a SIMD — fewer waves and more registers than
  ours, and faster. Copying that arrangement (128 invocations of 32
  accumulators, not 256 of 16) reads **1.89 s**, and the disassembly then
  matches theirs: 508 dots against 512, 96 loads against 90, 42 waits against
  111, 921 instructions against 1718, same registers, same shared memory,
  same occupancy — and still 1.8× slower.

  **A difference that survives replacing the kernel is not in the kernel**,
  and ours is 1.7× off theirs on the matrix path and 1.8× on the dot path —
  two unrelated kernels, the same distance. What they share is everything
  around them: 17 steps to a layer, a barrier between most, and dispatches as
  narrow as eight workgroups.

  **So the device was asked.** A timestamp query pool around every sequence's
  dispatches, read back after the fence, at this part's 10.019 ns tick: the
  device runs command buffers for **1.05 s of a 1.65 s prompt phase — a 64 %
  duty cycle**. The run's half-second of processor time is the other side of
  it: each sequence is recorded, submitted, waited for and read back in turn,
  so the host's 17 descriptor writes and 17 dispatches a layer are time the
  device sits idle through. Both of this program's kernels run inside that
  envelope, which is what a difference that survives replacing the kernel
  looks like from the other side.

  **And the third was then split, which changed what to build.** A clock
  around each part of a sequence, over a prompt's 240 of them: recording
  0.276 s, submit-and-wait 1.119 s, reading back 0.023 s. The readback is
  nothing; submission and fences cost 0.07 s over 240; **recording is 16 % of
  the prompt** — and it is not descriptors or commands, because the 240
  *generated* sequences after it add 0.002 s between them, 10 µs each against
  the prompt's 1.15 ms. A cost that appears only with a deep batch is the
  activation upload: a megabyte a layer, written into the mapping before
  every sequence. Two command buffers would hide none of it. What it says is
  that the activation should not go over at all — it is the previous layer's
  output, which the previous sequence left in the device's result buffer and
  then copied to the host so the host could copy it back.

  **So that was built, and it changes nothing**: a slot at the head of the
  answer buffer, the last step's result copied into it device-side, the next
  sequence reading its input from there. 1.665 s against 1.660, three rounds
  each way, same digest. The upload was not the cost either.

  **Asked in four parts, the clock says where it is**: sizing the steps and
  finding their weights **0.255 s**, buffers and upload 0.003, descriptors
  and commands 0.012, submit and wait 1.110, readback 0.022. Fifteen per cent
  of a device prompt is spent working out where things go — a loop over 17
  steps that asks the loader for each matrix, 2170 times over 240 sequences,
  answered from the resident list 1971 times with 199 first-sight misses, at
  117 µs an ask. Why a walk of a 199-entry list comparing five fields costs
  that is not yet known.

  Not kept. The instruction is recorded, because nothing here has used it
  and the next multiply-add loop should.

- **The device prompt's 1.7× is not the matrix instruction, and now there is
  a number for that.** llama.cpp uses the same extension on this part
  (`matrix cores: KHR_coopmat`), and telling it not to —
  `GGML_VK_DISABLE_COOPMAT=1` — reads 1353.7 t/s against 1949.3. So the
  instruction is worth 1.44× to them, and **their kernel without it is 28 %
  faster than ours with it** (1353.7 against 1059).

  Three attempts at the structure, all bit-exact, all worse: two subgroups
  sharing a staged batch 3.35 s, the same staged 16 bytes at a time 2.62 s,
  four subgroups 3.15 s, against 1.66 s for the kernel as it stands.
  `coopMatLoad` from the buffer issues wide loads straight into the matrix
  registers, so any trip through shared memory is one it did not need.

- **The integer matrix instruction priced before a rewrite was built for
  it: 11 %, not the 2× the hardware sheet implies.** This device offers ten
  cooperative-matrix shapes including signed 8-bit in, 32-bit out — and
  Q8_0 weights are already signed bytes, so an integer kernel would skip the
  decode entirely. Timed with the staging equalized so only the instruction
  differs, int8 reads 3.733 s against half precision's 4.199. Since Q8_0
  scales every 32 elements, using it needs per-block scale tiles and
  byte-quantized activations, and the ablations put every operand this
  kernel touches at 12 % of it. Not built.

- **A deeper prompt batch is level.** `Llama.Max_Batch` capped it at 128, so
  the weights are read eleven times over a 1419-token prompt where llama.cpp
  reads them once. Raising the cap: 256 is level, 512 is worse, digests
  unchanged. So the prompt is not weight-traffic-bound either, which is an
  independent confirmation that the matrix phase is compute-bound.

- **Four more attempts on the two widest gaps, all measured, none kept.**
  The scale preamble's binary64 chain: removing it entirely is level, so
  breaking it into partials would buy nothing — the pass waits for memory,
  it does not compute. Prefetching the next row: level. The matrix
  accumulator in half precision: level, so the instruction does not retire
  faster for writing less. And two subgroups to a workgroup sharing the
  batch through shared memory — the one arrangement the tile sweep never
  covered — is 2.5× slower, because staging 128 vectors by hand costs more
  than the `coopMatLoad` it replaces.

- **The processor's generated token is memory-saturated, and the share cap
  that says so is confirmed.** One share takes 4.558 s for 64 tokens, two
  1.943, three 1.905, and nothing after that moves — but that sweep was
  measuring `Vector_Team`, which caps the single-vector byte path at four
  shares on purpose. Sweeping the cap itself: three 2.025 s, four 1.965,
  five 1.953, six 1.940, eight 2.013, and four against six alternated four
  times is 1.955 against 1.949 — three tenths of a per cent. The cap stands.

  64 tokens read 69.8 GB in 1.907 s, which is 36.6 GB/s against llama.cpp's
  43: the gap is streaming, not parallelism. And annotating the profile
  splits the kernel almost evenly — 33.5 % in the vector loop, **31.3 % in
  the scalar pass that builds the row's scale table**, a 64-deep binary64
  dependency chain feeding a vector loop of about the same length. Breaking
  that chain associates the sum differently and moves what the model says,
  so it is the sweep's decision rather than a rewrite. Not taken — and
  there may be nothing there: the scalar pass walks the whole row before the
  vector loop reads any of it, so it is the pass that waits for memory.
  Prefetching the next row from inside the vector loop is level, 1.944 s
  against 1.948, because the hardware prefetcher already has the stream.

- **The output projection is not worth taking** — 6.8 % of a generated
  token, reading 69 MB in 1.4 ms, which is 50 GB/s and exactly the rate the
  rest of the token runs at.

- **A published table was wrong, and is corrected.** The entry above it
  compared four quantizations by dividing each run's time by sixty-four
  tokens; three of the four stopped earlier than that, Q4_K at ten, because
  the model reaches its end-of-sequence token sooner at those widths — and
  `tests speed` reports the count it actually produced on the same line as
  the time. Read properly, the two runs that reached sixty-four say the
  opposite: Q8_0 is 22.3 ms a token against Q5_K_M's 32.4 while reading half
  again as many bytes. There is no factor of four, and no 96 GB/s. The
  comparison cannot be completed with this tool either: it needs every run
  to produce the same number of tokens and there is no flag that ignores an
  end-of-sequence token.

- **The rotation's angles are kept the way the activation is kept- **The rotation's angles are kept the way the activation is kept, and the
  whole layer now pays for a generated token too: 3.5 %.** A matrix reaches
  the device through a loader that keeps it by address; a table of angles
  cannot be kept, because it depends on the position, so it went through
  that loader unkeyed — an allocation, a mapping, a copy and a release,
  twice a layer. A batch amortizes that over 128 positions and a token pays
  it whole.

  The activation has the same shape and is not loaded that way at all: one
  buffer, grown when it has to be, copied into a standing mapping. The
  angles are held the same way now, and the whole layer — 4 % slower for a
  token when it was built — is 3.5 % faster, three rounds of three. A token
  is one submission a layer again, and 46.2 tokens a second against 44.4.
  The prompt is level, as the case that amortized the cost should be.

- **Attention's key gather staged into shared memory, and reverted: 48 %
  slower.** Each lane walks its own cached position, so the 64 lanes of one
  instruction want addresses a kilobyte apart — 64 transactions for one
  instruction, and an ablation prices it at a fifth of attention, about 6 %
  of a device prompt. Staging the tile a position at a time makes every read
  one line and is bit-exact; it also takes 17 kB of shared memory, which
  takes the kernel from fourteen subgroups a SIMD to four. A memory-bound
  kernel with a quarter of the waves to hide behind loses far more than
  coalescing wins.

  Staging half a head brings occupancy back to eight but then never fires
  for a 64-wide head — and is still 4 % slower than the shader without the
  branch. The third time this file has measured a pipeline paying for code
  it never executes.

- **A layer goes over in one submission: 3.5 % of a 1419-token device
  prompt, at the same digests.** The turning was already a step; the cache
  write is fifteen more lines, and with both of them steps there is nothing
  left for the host to do in the middle. `Whole_Layer` names all seventeen.
  The prompt reads 1030.5 tokens a second and its gap to llama.cpp is 1.70,
  from 1.81.

  **It does not pay for a generated token, which is what it was built for.**
  A token was 45 submissions and this makes it 23 — 15 % by this file's own
  price — and measures **4 % slower**, three rounds of three. Seventeen
  steps each want a descriptor set and a dispatch, and the rotation's table
  is uploaded fresh every call; a batch of 128 amortizes that and a token
  cannot. So the whole layer is for batches and the two halves stay for a
  token.

- **The published figures were a sitting behind for one commit.** The script
  that rewrites them raised on the first anchor it could not find and wrote
  nothing, so the rotation commit stamped new fingerprints over the previous
  sitting's tables, under prose a second script had updated. Both are
  corrected here, and the script now applies what matches, reports what does
  not, and always writes.

- **The rotation runs on the device, and knows nothing about any
  architecture: 2 % of a 1419-token device prompt, at the same digests.**
  What varies between models is the angle, and an angle is a cosine and a
  sine. The host tabulates 32 of each for this model and then does 2300
  multiply-adds with them, so the table — which is all of the architecture:
  the stretch, its ramp, the divisor table, the attenuation — stays on the
  host, and the shader is twenty lines that apply it. `Kernels.Rotary_Table`
  is the one implementation, called by the processor's own rotation too, so
  the two cannot drift.

  In binary64, because that is what the processor does; there is a
  thousandth as much rotation as matrix product, so a part that runs
  binary64 at a thirty-second rate still finishes a layer in microseconds.
  Rotating went from 0.128 s to 0.040 s of the prompt, and what is left of
  it is the cache write.

  **What it is for is the submission after it.** A layer is two submissions
  because the host rotates and writes the cache between them. The rotation
  is now a step; when the cache write is one too, a layer is one submission,
  and a generated token is 45 of them at 83 µs — 15 % of it.

- **The generated shader words are written plainly rather than as
  hexadecimal literals** — 455 kB against 1025, which put the file back
  under the megabyte this repository allows a committed file. The tenth
  shader crossed it. The bound that keeps models out did not move.

- **A layer's first half fuses as well: 5 % of a 1419-token device prompt,
  and 70 % of the processor time it had left.** The host normalized the
  layer's input and then sent the queries, the keys and the values as three
  submissions of their own — four round trips a layer for a normalization
  and three matrices that all read it. A normalization first in a sequence
  now reads what the caller handed in, as a product first in one already
  did, so the three chain to it: one submission, and the normalized value
  never leaves the device.

  A 1419-token device prompt spent 3.30 s of processor two commits ago and
  spends 0.65; a 110-token one spends 0.04 s where it spent 0.32. What the
  host still does during a device prompt is the rotation, the sampler and
  the reading out.

  **The rotation is left on purpose** — 7 % of the prompt, and not the
  upload it looks like: `Put_Cache` is a copy into a standing mapping. What
  costs is the arithmetic, and that is where architectures differ most:
  Yarn's ramp, a per-dimension divisor table, an attenuation, two pairings.
  A second implementation of the most variable part of the program, for 7 %,
  with only the conformance sweep to catch a mistake in it.

- **A prompt's layers fuse too: 6 % of a 110-token device prompt, 1.5 % of a
  1419-token one, and a third of the processor time either way.** The
  fusing landed for a single generated position and a prompt has its own
  loop, which went on making three submissions a layer with the host
  joining and normalizing between them — a quarter of a million elements a
  layer for a batch of 128. Nothing new was needed: every kernel in the
  sequence takes a position count already. The batched loop now calls
  `Attend_And_Feed` under the same nine conditions and skips its tail.

  The wall figure is the smaller half. Moving the join and the normalization
  to the device does not make them free, it makes them the device's — what
  it makes free is the two round trips a layer, and what it takes off the
  machine is a third of the processor a device prompt was spending while the
  device did the work.

- **Attention's two inner loops unrolled by eight: 34 % of attention on the
  device and 7 % of a 1419-token prompt**, at the same digest. Attention was
  31 % of that prompt and the one phase running at about processor speed —
  0.754 s on the device against 0.894 s on eight cores, where the
  feed-forward beside it is 4.6 times faster there. Measured against the
  part rather than against the processor it read 236 Gflop/s of 4150.

  The loop was **one memory operation per multiply-add**: per component the
  dot product reads one key, reads a query component for each of the eight
  queries in the block, and does eight multiply-adds. A query's components
  lie together, so eight a turn is one fetch rather than eight; the value
  phase's weights lie together too and take the same treatment. Each dot
  product still accumulates over the components in increasing order, so this
  is a different schedule and the same arithmetic.

  **Four things measured first, and none of them was it.** The block's
  queries staged in shared memory: 2 % slower, because the query address is
  workgroup-uniform and was already a scalar load. A block of sixteen
  queries: level; of four: 10 % worse. Both reductions batched across the
  block: level, because this device gives a 64-lane workgroup one subgroup
  and the barriers were never there. What priced it was three probes reading
  the wrong operands from the right places — the key reads are a fifth of
  attention, the value reads a quarter, shared memory a tenth, and half of it
  is none of those.

- **The matrix shader asked again and closed again, with one earlier figure
  corrected.** After attention's unrolling the two matrix phases are 62 % of
  the device's long prompt, so the question was put again: three ablations
  and a batch sweep, none of which finds anything to take.

  The decode is **10 % of the prompt, not the 6.4 % this file published** —
  the earlier probe filled 128 of the tile's 1024 entries and left the
  decode running underneath. The corrected one guards it with a push-constant
  test that is false at run time and not at compile time. It does not change
  the decision: f16 is 1.9× the bytes of Q8_0 and the read is part of what
  was ablated, so uploading the model decoded still costs more than it saves
  and still doubles what a model needs on the device.

  The row tile is **not** starving the narrow matrices — a layer's key and
  value projections are 256 rows against the query's 2048, eight workgroups,
  and the projection phase does run at half the feed-forward's rate, but
  halving the tile to double the workgroups costs 16 % of the prompt, and a
  deeper batch is level at 256 and 384 against 128.

### Fixed

- **The eviction bug has a test now.** A budget small enough to evict must
  not change a single token, and until now only the counters were asserted —
  which is exactly why that bug did not fail when it happened: the run
  answered, and answered wrongly. The device-memory test compares the text a
  run produces with and without a budget. Removing the pin it guards makes
  it fail, which is how it was checked.

- **A sequence could evict a matrix it was about to read.** A sequence
  acquires every matrix it names before dispatching any of them, and
  acquiring one can evict another to stay inside `--device-memory`. The
  victim is the matrix wanted longest ago, which within a sequence is the
  one acquired first — a matrix a later step is about to read, leaving a
  descriptor pointing at a buffer that no longer exists. Three matrices
  never reached it; the fused layer's five did, and the run produced a logit
  that was not finite. A sequence now pins what it has taken, and a budget
  too small for all of it takes the memory outside the budget and gives it
  back at the end of the call — which is what the loader already did for a
  single matrix larger than the whole budget.

- **`Add_Norm` accepted a sequence with nothing to normalize** and recorded
  a step reading step zero.

### Changed

- **The engine asks a fence whether it is finished before it waits for one**,
  which is **5 % of a generated token on the device and 4.5 % of a device
  prompt**. The entry below prices a token's sixty-seven submissions at 23 %;
  the three a layer are structural, but the waiting is not — `vkWaitForFences`
  blocks in the driver and a short dispatch pays the wake-up rather than the
  device's work, which is the worker pool's own finding this sitting.

  64 generated **1.667 s to 1.583**, the 1419-token prompt **1.975 to 1.886**,
  six alternated rounds three each way, better in 6 of 6 both, digests
  unchanged. **The device's gap goes 2.52 to 2.32 on a prompt and 1.41 to
  1.34 generating**, and its generating row is ahead of llama.cpp's processor
  row by more than a rounding for the first time: 42.3 against 40.4.

  The budget was swept and matters: `vkGetFenceStatus` goes into the driver,
  so forty thousand turns costs a prompt twenty per cent while still gaining
  on generation. A thousand covers a generated token's dispatches and gives
  up long before a prompt's, for 0.48 s of host time against 0.22 on a
  64-token run.

- **`Waited` counts the asking as well as the waiting.** A spin that covers a
  short dispatch reaches the wait with the fence already signalled, so a
  standing stop request was never seen — the spin now asks every sixty-four
  turns, and the companion assertion that the wait "went round" is answered
  by either stage, because a product the asking answered has waited.

### Measured

- **A generated token on the device is sixty-seven submissions, and that is
  23 % of it.** Two ablations of `row_product.comp` settle the products
  first: the activation never read saves 1.4 % and the weights never read
  collapses the run to 0.011 s, so **the weights are 99 % of the row
  product**. A token streams 1.09 GiB in about 85 % of 24.4 ms — 55.5 GB/s
  against llama.cpp's whole token of 17.7 ms, which cannot be under 61.6
  GB/s. Eleven per cent apart on the stream, and nothing here reaches it.

  Attending is the other half and is not arithmetic: **3.6 ms a token at a
  context of 40 and 13.9 at 1450** — thirty-six times the work for 3.9 times
  the time, which fits 0.0073 ms a position and **3.3 ms a token that does
  not depend on the context at all**. A counter on `vkQueueSubmit` says why:
  4421 submissions for 64 generated tokens against 669 for eight, so
  **sixty-seven submissions a token, three a layer**, each a submit and a
  wait on a fence at the 83 µs this file has already measured.

  Not built. Everything between one sampler call and the next is device
  work, so a layer needs no round trip in principle and a token needs one.
  One a layer would be about 15 % of a generated token; one a token, 22 %.

### Measured

- **Three more rearrangements of the matrix shader, all level.** The subgroup
  width — this part's matrix instruction is documented at wave32 and the
  shader asks for sixty-four — reads 1.926 s against 1.917. Replacing the two
  barriers a step with `memoryBarrierShared` alone reads 1.907 against 1.936,
  inside the noise and **not correct in general** anyway, since a device with
  32-wide subgroups makes that workgroup two of them.

  And software pipelining, the one with a real argument: the loop decodes a
  step, waits, multiplies it and waits again, so the unpack and the
  instruction are end to end. Two buffers, multiplying the step already
  decoded while decoding the next, one barrier a turn rather than two —
  **1.960 s against 1.971**, six alternated rounds three each way, better in
  four of six. Six tenths of a per cent for two kilobytes more of shared
  memory is not a trade worth making.

  **That closes the shader.** Nine tile shapes, three subgroup counts, the
  batch against the vector tile, the decode ablated, both operands ablated,
  the wave width, the barriers and the pipelining — the only one that ever
  mattered was the tile it already had. The two and a half times is not in
  the shader's structure.

### Measured

- **The registers were never the wall, and they cost two lines rather than a
  second compilation.** Three entries running ended on "sixteen registers is
  what these kernels have"; `pragma Machine_Attribute (P, "target",
  "avx512f")` on one subprogram of the baseline-compiled unit emits
  `vmovups (%rdi),%ymm16` with an EVEX prefix, per subprogram, reachable
  through the run-time flag the insertion already hides behind.

  Having asked, neither thing it was wanted for pays. **Correcting this
  file:** a sixteen-position block in `head_scores` was said to halve the 65
  instructions that are not the dot product — it does not, because the eight
  zeroing exclusive-ors and the fourteen of fold **scale with the
  accumulators**. Only four instructions a call are fixed, so doubling the
  block saves four per sixteen positions out of ninety-eight per eight: 2 %
  of the kernel, a tenth of a per cent of a prompt. And the paired blend at
  64 components would give back the 2.3 % the narrowing cost, but the pairing
  itself measured level in situ.

  Both attention kernels are bound by the two multiply-add pipes with a fold
  that is 15 % of the loop and structural. More registers move neither.

### Measured

- **Attention through the matrix instruction: built, correct, and 13 %
  slower.** The entry below priced it at seventeen per cent of a device
  prompt. `attention_matrix.comp` does the scores as the queries against the
  transpose of the keys and the blend as the weights against the values, both
  through `coopMatMulAdd`, with the online softmax kept. **It does not move a
  single token** — 1419 tokens with twelve generated still answers
  `1a26d24d33b8957b` and the 110-token prompt `cbf29ce484222325`, with
  half-precision operands.

  Nine shapes swept against 1.911 s as it is; the best is **2.157 s** and
  **every shape runs the wrong way** — more for the instruction to chew on is
  worse. The instruction takes its operands from shared memory and shared
  memory bounds occupancy: `attention.comp` uses **2 KB** a workgroup and
  reads a key straight from the cache into the multiply-add, this one stages
  them and uses **9.5 KB** at its best. The arithmetic did its part — eight
  cooperative-matrix multiplies a tile where the old kernel issues 512
  multiply-adds a lane — and the staging became the cost instead.

  Not committed. The seventeen per cent is not available this way.

### Measured

- **Device attention is its two products, and they run at a fifth of the rate
  the same part reaches on the weight product.** Three ablations of
  `attention.comp`: the score half removed is **1.689 s against 1.911**
  (−11.6 %), the blend half removed 1.759 (−7.9 %), and the subgroup
  reductions cannot be removed at all — without the running maximum a score
  of minus infinity reaches the exponential and the run refuses, which is the
  guard working.

  So the two arithmetic halves are **19.5 % of a device prompt** of the 24.6
  attending takes, and the softmax, barriers and stores are the other five:
  nothing is hidden in attention, it is its two products.

  Those products are 181.6 Gflop in 19.5 % of 1.911 s — **0.49 Tflops** —
  against the weight product's 2.94 Tflop in the 59.8 % the matrix phases
  take, **2.57 Tflops**. The weight product goes through
  `VK_KHR_cooperative_matrix` and attention does not: both its halves are
  matrix products computed a lane at a time in binary32.

  **Attention at the matrix product's rate would be about five per cent of a
  device prompt rather than twenty-five** — seventeen per cent of the prompt,
  the largest single number left in this file, and the change llama.cpp
  already made.

### Measured

- **The score half of attention is where the blend is, and for the same
  reason.** `head_scores` is 7 % of a prompt and its horizontal fold was the
  suspect; disassembled, the fold is **14 instructions of 129** and its six
  `vhaddps` sample at nine per cent of the symbol between them. Sixty-four of
  the 129 are the dot product, so **half the body is not arithmetic**.

  It retires **25.2 G ops in 9.53 G cycles, 2.65 a cycle**, against an issue
  ceiling of about 3.2 — eighty-three per cent of it. `rows_by_strips`, proved
  on its floor, retires 3.17 against 3.08 and retires nothing for 41.7 % of
  its cycles where `head_scores` does for 46.7: **the two are in the same
  state**.

  Eight positions need eight accumulators and the 64-component query needs
  eight more — sixteen registers exactly, nothing left over. A block of
  sixteen positions would halve the non-arithmetic half per position and
  needs twenty-four. **Third time this session the answer is the register
  file**; `Model_Runner.Kernels` is compiled for baseline x86-64 so the
  program runs where the wide instructions do not. The unlock is named and
  not written: a second instantiation built for `x86-64-v4`, chosen by the
  host check that already picks between three compilations of the integer
  product.

### Measured

- **The strip kernel's published floor was mis-counted, and the kernel is on
  the real one.** Four sittings of this file have said it issues 36
  multiply-add-class operations a block — 18 cycles of floor against 24
  taken — and wondered where the third went. Disassembling the loop rather
  than describing it: 77 instructions, of which 16 `vpdpbusd`, **16
  `vcvtdq2ps`** and 18 `vfmadd231ps` contend for the two pipes. **The
  conversions were never counted**, because a dot product here is three
  operations and not two: every block carries its own scale and an integer
  sum cannot be scaled until it is a float.

  Fifty pipe-bound operations a block is a floor of **25 cycles, not 18**.
  The kernel retires 243.9 G ops in 76.8 G cycles — 3.17 a cycle — which is
  **24.2 cycles a block**, under the floor because the renamed `vpxor` retire
  without occupying a pipe. There is no third missing.

  What the count does say: **32 % of the kernel's arithmetic is format
  conversion**, not multiply-add, and it is there because `Q8_0` puts a scale
  on every 32 elements. No rewriting of the kernel reaches it.

### Measured

- **A device prompt is not waiting for its weights, and uploading them
  already decoded is priced out before it is built.** Three ablations of the
  matrix shader, each replacing one thing with a constant: the weights never
  read or unpacked is **1.815 s against 1.939** (−6.4 %), the activations
  never loaded 1.752 (−9.6 %), and every operand gone 1.673 and 1.720 in two
  readings — so **the whole handling of both operands is fourteen per cent of
  a device prompt** and the decode alone is six and a half.

  An f16 copy would still have to be read and is nearly twice the bytes, so
  it would buy less than six and a half per cent — for double what a model
  costs on the device, which is what decides whether a model runs there at
  all.

  Where the time is instead (`--budget`): feeding 40.2 %, attending 24.6,
  projecting 19.6, joining 5.7, rotating 5.6, normalizing 2.6, reading out
  1.6. The two matrix phases are sixty per cent and the operands fourteen, so
  **three quarters of the matrix phase is the instruction itself**.

### Changed

- **A tile of thirty-two rows rather than eight, which is 5.9 % of a
  prompt.** The strip kernel stages the batch's own numbers at the top of
  every call — where each vector's scales begin, the scale, and the block
  total the bias correction wants — and **those are the batch's numbers, not
  the row's**, so they are the same for every tile of rows a share is cut
  into. A profile put that staging at **twelve per cent of the hottest symbol
  in the program**, a scalar loop rebuilt for each of a share's tiles.

  Long prompt, medians of three: 8 rows 6.244 s, 16 6.206, **32 5.874**, 64
  6.059, 128 6.411 — better in three of three alternated rounds, digest
  unchanged. The curve turns over at 64 because the tile's accumulators stop
  fitting L1. No partition moves either: 2048, 5632, 256 and 32000 rows all
  still divide by 32 into eight shares.

### Measured

- **Hoisting the rest of that staging out of the kernel buys nothing** —
  5.926 s against 5.938, level in six alternated rounds — because the table
  it saves building is 2 KB freshly written into L1 and the table it reads
  instead is 32 KB walked eight strips apart.

  The two shapes of it are worth more than the result. Reading the shared
  table through **one name at a chosen address costs 7.256 s against 6.014**,
  a fifth: an object at an address the compiler cannot reason about is one it
  cannot prove does not alias the table being written, and the innermost loop
  stops vectorizing. Written out twice, once against the parameter and once
  against the local, both arms vectorize and the whole thing comes out level.

### Measured

- **The value blend is not waiting for its loads, and the register file
  prices out the only fix left.** A kernel that blends two heads of one key
  head's group from a single reading of the values — half the loads for a
  fifth more instructions — is **1.34x faster on a bench reading from L2**
  (39867 Me/s against 29788) and **exactly level in the engine**: 4.92 % of
  a prompt where the single blend took 4.95, wall 6.388 s against 6.309.
  With the heads walked inside a tile of sixteen positions, every head after
  the first reads what the first left in L1, and there the load ports are
  not the constraint.

  Two heads of 64 components is sixteen accumulators, which is every
  register the base encoding can name, so the component run has to halve and
  a head becomes two passes. **That alone costs 2.3 %** (6.454 s against
  6.309, worse in three of three) — so any two-way pairing of this blend,
  across heads or across query positions, starts 2.3 % behind before it
  gains anything.

  Two more measurements beside it: the blend tile is flat from 8 to 64
  positions (6.161, 6.230, 6.222, 6.304), and the blend's share of L1 misses
  is its share of cycles — 5.2 % against 5.0 — so it is not missing
  disproportionately either.

### Measured

- **The matrix shader's tile is the best of eleven shapes, and making it
  tunable costs one and a half per cent.** The staging was rewritten to deal
  sixteen-value units round the workgroup instead of hand-mapping sixty-four
  invocations onto thirty-two rows, which made `TILE_R`, `TILE_V`, `KCH` and
  the subgroup count into numbers — every shape then ran, where the earlier
  sweep found three of six producing a kernel that compiled and answered
  nothing.

  The long device prompt at **32x128 step 32 is 1.935 s**; the nearest of ten
  alternatives is 2.058 and the furthest 3.207, all answering
  `1a26d24d33b8957b`. Raising the vector tile with the batch raised to match
  — the one combination the old sweep could not ask — costs sixty per cent,
  so the weights are not what this shader waits for; more subgroups sharing a
  tile is worse at every count, so neither is occupancy.

  **The rewrite is not kept**: 1.99 s against 1.965 in three forms, better in
  three of eleven alternated rounds. What is kept is a repository check that
  `TILE_R` and `KCH` are thirty-two — the shape the staging is written for —
  so the next person to turn one gets a failure rather than a kernel that
  runs and answers nothing.

### Fixed

- **A batched prompt did not give the same answer at every worker count**,
  which three places in the README said it did. `--threads 4` generated
  different text from `--threads 3` and `--threads 7` on the same file, seed
  and temperature — `3740ed87be385f2d` against `3248ac1bb7011de0` — from the
  forty-third token, and `--batch-size 1` made it go away.

  A batch is computed a tile of rows at a time and **a tile of an odd size
  takes a different kernel from a full one**, which sums the same products in
  a different order. The rows were cut into shares without regard to the
  tile, so every share ended in a short tile and where those fell depended on
  how many shares there were. A share boundary now falls on a multiple of the
  row tile, so the tile grid is anchored at row zero however the rows are
  cut, and the only short tile is the one the matrix's own row count leaves.

  **No published figure or digest moves**: at the worker count the program
  chooses for itself the partition is unchanged, because 2048, 5632, 256 and
  32000 rows all divide by eight into eight shares. `--threads 2` through
  `--threads 15` now all answer `3248ac1bb7011de0`.

- **A pool test that failed would hang instead.** A raised assertion skips
  `Close`, and the frame that declares a pool waits for its workers. Both
  tests that compare a product across worker counts now collect the mismatch,
  close the pool, and assert afterwards.

### Added

- **A test that a batched quantized product is the same at every share
  count**, bit for bit — 100 rows of `Q8_0` against a batch of eight, share
  counts one to eight, compared against the serial result. It fails on the
  old partition at two workers. `Parallel_Matches_Serial` beside it did not,
  because it uses a binary32 weight and one vector: the one shape the integer
  tile kernel is never asked for, so the test named after the property tested
  where the property could not break.

### Changed

- **A worker looks for its next job before it blocks for it**, which is worth
  **seven per cent of a generated token** and one and a half of a prompt.
  Generating 64 tokens goes **2.058 s to 1.906 s** and the 1419-token prompt
  **6.549 s to 6.450 s**, better in four of four alternated rounds, and both
  digests are unchanged — `3248ac1bb7011de0` and `1a26d24d33b8957b`.

  A worker blocked on a protected entry is asleep in the kernel, and a
  generated token posts a hundred and fifty-five products, so the wake is paid
  a hundred and fifty-five times a token. Against llama.cpp on the same file
  this program used **3.4 cores' worth of cycles to its 8.0** and took thirty
  per cent longer — and two copies of this program running at once move 44
  GB/s of the model where one moves 37, so the bus had a fifth left in it and
  the pool was not asking. A ticket counter and a share counter beside the
  coordinator let a worker spin about ten microseconds before it blocks, and
  a submitting task spin before it waits. **Neither decides anything**: the
  coordinator still opens the barrier, hands over the job, says when it is
  done and says when the pool is closing.

  It is paid for in processor time — the twelve-token run went 1.57 s to
  1.85 s — and the spin budget is bounded so an idle pool stops burning a
  core at once. The share count did not move: a generated token still asks
  for four. What moved is the price of the wrong answer, eight shares costing
  7.97 s of processor time against four shares' 7.23, where it was 12.68
  against 7.28.

### Measured

- **The single-vector row tile is not the lever and contiguity is not
  either.** Sweeping it at one, two, four and eight rows reads 2.17 s, 2.08,
  2.04 and 2.04 for 64 generated tokens — and **one row at a time, which
  walks the weights perfectly contiguously, is the worst of the four**. Both
  were run against the idea that a generated token wants more misses in
  flight per worker; the answer was in the pool rather than the kernel.

### Measured

- **Caching the weight scales across batches deletes 7.6 % of the run and
  saves nothing.** The integer tile kernel re-extracts every weight scale for
  every tile of every batch — a 2-byte load at a 34-byte stride — and a
  1419-token prompt is eleven batches reading the same numbers eleven times.
  Hoisting them onto the processor pool, one table per Q8_0 tensor, moved
  that symbol's share from **7.6 % to 4.7 %** and instructions from
  **388.6 G to 384.3 G** — and cycles from 132.9 G to 132.4 G, the wall from
  6.733 s to 6.786 s: nothing, in five alternated rounds of three. Cache
  references rose 28.2 G to 31.6 G and peak residency 1201 MB to 1329 MB.

  The extraction is not a cost. It is a walk ahead of the strip kernel over
  the lines the strip kernel is about to read, and the weights come from
  memory whether or not their scales are read first; removing it trades a
  warm read for a cold one plus 128 MiB of table. **Not committed** — an
  earlier note priced this at "perhaps six per cent", which priced
  instructions where the machine is priced in bytes.

### Measured

- **Lengthening the conformance sweep to cross a matrix tile costs it forty
  minutes**, against about five today. A fifth sequence of 72 tokens used by
  one comparison — the batched device one — was added and the sweep timed;
  it was stopped rather than finished. The cost is not the comparison but the
  independent implementation, which computes every sequence for every fixture
  in binary64 without a pool whether a comparison asks for it or not.

  So the sweep is the wrong instrument for this: what the missing test wants
  to ask is whether two backends agree, which costs only running them. Such a
  test was written and is not committed — the processor side returns
  `BACKEND_CLOSED` where the same calls in the harness beside it do not,
  which is a fixture question and unresolved. A test that does not run is
  worse than a gap that is written down.

### Measured

- **The matrix tile sweep bought nothing, and three of six shapes do not
  run.** With the engine's `Tile_Rows` and `Tile_Vectors` moved to match:
  32x128 chunk 32 is **2.34 s**, 32x64 is 2.45, 16x128 is 2.56, and 64x64,
  64x128 and 32x128-chunk-64 all fail before an answer comes back.

  Every shape that fails moves `TILE_R` or `KCH`; every shape that runs
  leaves both alone. The staging loop maps lanes onto `wt[TILE_R * KCH]` by
  hand, so moving either end leaves a kernel that compiles and does not work.
  **It is one free parameter, not three** — and `TILE_V` is already at its
  best, 128 beating 64 by 5 %, which is what a batch of 128 vectors predicts.

  The matrix shader is not a kernel with a tunable tile; it is a kernel
  written for one tile.

### Measured

- **The device breakdown, re-taken on a device that was working.** The
  previous one was measured on the path that skipped half of every matrix
  tile, so it was wrong about the shape of a device prompt. Four runs, prompt
  only: feeding 0.505 s to **0.650 (26 % to 33 %)**, attending 0.690 to 0.590
  (35 % to 30), projecting 0.370 (19 %), joining 0.156, rotating 0.145,
  normalizing 0.082.

  **Feeding is the largest phase and it was never attention.** It grew 29 %
  when it started computing the tiles it had been skipping. Attention fell
  15 % and does not use the matrix shader — what changed is what it was fed:
  the old path handed it half a product and the rest of a buffer, and that
  arithmetic was slower than arithmetic on real numbers.

  The two matrix phases are **52 % of a device prompt against attention's
  30**. llama.cpp reads the prompt in 0.79 s against this program's 1.99, so
  with attention free this would be 1.40 s and still **1.8x** behind — which
  was 1.6 when the products were doing half their work.

### Fixed

- **`tests shader` refuses a compiled file older than its source.** The stale
  words found two commits ago were possible because nothing looked: the check
  compares a source against a digest recorded when the words were made, which
  proves the source has not changed since somebody ran the tool, not that the
  words came from the source. Compiling at check time would settle it and
  would put a shader compiler in the way of running the tests; a modification
  time is the weak thing that knows, and it catches the case that happened.

### Fixed

- **Every device prompt of more than 64 tokens was wrong, and is not any
  more.** `matrix_product.comp` said a tile of 64 vectors and the engine
  dispatched `Room / 128` workgroups, so a workgroup answered the first 64
  vectors of every tile and **nothing answered the rest**. At greedy sampling
  the device matched the processor at ~18 and ~36 tokens and returned
  `usedovoovoovoo…` at ~72.

  `TILE_V` is 128 now — what the shader's own comment two lines away has said
  all along, "all eight vector matrices". The device now returns the
  processor's digests to the bit: `cbf29ce484222325` at 110 tokens where it
  returned `7614f34a26a84b3c`, and `1a26d24d33b8957b` at 1419. It also stops
  generating when the processor stops; the old run read the noise, never
  found its ending, and ran on to twelve tokens in every sitting recorded.

  **The device figures get worse and are worth more**: a 110-token device
  prompt reads 575.9 t/s where the broken path read 709.7, and the gap to
  llama.cpp goes 2.3x to 2.9.

- **A check that the matrix tile's four numbers agree**, reading `TILE_R` and
  `TILE_V` from the shader and `Tile_Rows` and `Tile_Vectors` from the
  engine. The same check exists for `attention.comp`'s `QUERIES` against
  `Query_Block`, whose comment records that pair drifting within an hour of
  being written; the matrix one was never written and its drift shipped.

  Three things let it survive: the sweep's longest sequence is **eight
  tokens**, so no comparison it makes crosses a tile of anything; a speed run
  reports a device digest that nothing compares against the processor's; and
  the check that would have caught it existed only for the other shader.
  **The sweep's blind spot is still there** and lengthening it would cost the
  gate real time — a decision to make deliberately, not at the end of a
  commit.

### Measured

- **A device prompt re-broken-down after the two attention changes**:
  attending 0.907 s to **0.690** (40 % of the prompt to 35), feeding 0.505
  (26 %), projecting 0.367 (19 %), rotating 0.206 to 0.158 (8 %), joining
  0.165 (8 %), normalizing 0.079 (4 %). Attention is a quarter cheaper and
  still the largest phase, but **the two matrix phases together are 45 %
  now** against its 35. llama.cpp reads the same prompt in 0.79 s and this
  program in 1.98 — so with attention free this would be 1.29 s and still
  1.6x behind. Whatever is next on the device is not only attention.

- **The score loop's tile of eight is already its optimum**: 6.423 s at
  eight, 6.461 at sixteen, 6.510 at thirty-two. Eight key rows are 8 KB and
  every one of thirty-two heads reads them from the nearest cache before the
  next eight arrive, so a wider tile has nothing left to gain and a longer
  live range to pay for. The blend's move from no tiling to sixteen does not
  generalise to a loop that was already tiled.

### Changed

- **The llama.cpp comparison now publishes the 1419-token prompt beside the
  110-token one**, which is the prompt every change in that section is
  actually judged on. It says two things the short one does not: the gap is
  wider — **1.3x on the processor against 1.2, and 2.4 on the device against
  2.3**, because attention grows with the square of the context and is what
  this program is furthest behind on — and it is far quieter, `llama-bench`
  reporting ±0.6 on 282.2 at 1419 tokens against ±21 on 331.0 at 110.

  That noise had twice forced a paragraph explaining a published figure that
  moved more between sittings than the change being measured: the device row
  went 808.8 to 709.7 while the code got 6.5 % faster. Both tables are kept —
  nine sittings of history were taken on the short prompt — but the long one
  is the figure to argue about.

### Added

- **One table of angles for a position's two rotations: 23 % off the rotating
  phase and 6.5 % off a device prompt**, better in three of three, with 1.5 %
  off the processor's prompt too. Every digest unchanged — the same angles by
  the same expressions, and a pair touches two elements of one head that no
  other pair or head touches.

  A position rotates its queries and its keys by the same angles and each
  call computed the table again; a power, a cosine and a sine a pair are the
  most expensive arithmetic in that package.

  **The loop is written out twice on purpose.** Factored into a nested
  procedure the two vectors share, the processor lost 6 % of a prompt and
  `pragma Inline_Always` did not give it back: the loop stopped being one the
  compiler could see the bounds of. The comment beside it says so.

### Measured

- **A device prompt's 9 % on the processor is arithmetic, not transfer.**
  The cache is written a position at a time — 256 calls a layer against the
  attention dispatch's one — and batching it into one call each way for keys
  and values **measured nothing** (phase 0.208 s to 0.201, prompt unmoved).
  `Put_Cache` writes into a buffer that stays mapped, so a call there is a
  copy and not a fence. Reverted.

  Replacing the cosine and sine with the angle itself — wrong answers, right
  timing — takes the phase from **0.203 s to 0.137**: a third of it is two
  transcendentals a pair a position a layer, in binary64. And half of that
  third is redundant, because `Apply_Rotary` is called once for the queries
  and once for the keys at each position and **each computes the same table
  of angles**. Sharing it is bit-for-bit identical and worth about 1.5 % of a
  device prompt.

### Fixed

- **The committed shader words did not come from the committed shader
  source.** `TILE_V` in `matrix_product.comp` says 128 and the words were
  built from 64: somebody changed it and never regenerated. Every device
  figure this repository has published describes 64, the edit saying 128 has
  never run, and compiling it makes a device prompt 7 % slower. Set back to
  64, all nine shaders reproduce byte for byte with glslang 15.1.0 and the
  documented flags — which are now recorded in the figures file, since
  nothing named them.

  The shader check cannot catch this: it compares the source against a digest
  recorded when the words were made, so a stale `.spv` handed to
  `tests shader` updates the digest and leaves the words.

### Added

- **Eight queries a workgroup against a 128-position window: 16 % off
  attention and 3.7 % off a device prompt**, better in three of three, digest
  unchanged. `QUERIES` and `room` multiply into `held[QUERIES][room/64]`, so
  eight against the existing 256 window spills and measured 26 % worse.
  `Query_Block` moved with it — a repository check caught that the two must
  agree and the sweep did not, because the dispatch asked for blocks of four
  while the shader answered eight: half the workgroups redoing work, right
  answers either way.

  **The device's prompt gap is 2.1x**, from 2.5.

### Measured and blocked

- **Eight queries a block against a 128-position window takes 17 % off
  attention and 4.5 % off a device prompt** — 0.856 s to 0.707 attending,
  2.611 to 2.490 overall, better in three of three, digest unchanged. The
  attention shader already tiles queries; `QUERIES` and `room` multiply into
  the per-lane register budget, so eight against the existing 256 window
  spills and measured 26 % worse, while eight against 128 is the same
  registers with twice the reuse.

  **It cannot be landed on this machine.** Changing a shader means
  regenerating the words committed beside it, and this machine's glslang is
  15.1.0 while the committed words came from another. Recompiled with the
  documented flags and nothing else changed, the set is stable but different:
  2.611 s against the committed 2.40, and a digest matching the processor's
  rather than the committed device build's. That 7 % is larger than the 4.5 %
  the change wins, so landing it would be a net loss. The figures file does
  not record which glslang built the committed words; it does now.

### Measured

- **A device prompt is 40 % attention.** The first look inside the device
  path, using the per-phase times the engine has always kept and `--budget`
  prints, with a generation-only run subtracted: attending 0.907 s (40 %),
  feeding 0.520 (23 %), projecting 0.375 (16 %), rotating 0.206 (9 %),
  joining 0.176 (8 %), normalizing 0.084 (4 %) on the 1419-token prompt.

  Not where the processor's shape would suggest — there the matrix products
  are two thirds and attention a seventh. The device turns the products into
  one matrix multiply a layer against its matrix instruction and they fall to
  a third between them, leaving attention, which is quadratic in the context.

  **And 9 % of a device prompt runs on the processor**: a profile of the run
  shows `rms_norm`, `memmove`, `add` and `apply_rotary` and no attention
  symbols at all — so attention is on the device where it belongs, and the
  rotation and the cache writes are not.

### Added

- **The blend reads a tile of positions with the heads inside: 3.7 % of a
  1419-token prompt, better in four of four.** Cache misses 2.56 G to 1.48,
  instructions +1.7 %, `blend_run` from 7.8 % of the prompt's cycles to 5.6.
  No digest moves.

  Eight heads share one key head's values, so the shape this replaces read
  the same values eight times over, once for each head that wanted them, over
  a range far larger than L1. A tile of sixteen positions is 16 KB of values
  against 32 of cache, and every head after the first reads them where the
  first left them. It is the argument the score loop has made about eight
  positions at a time since long before this, made about the other half of
  attention.

  This is what the head-major copy of the previous commit was missing: that
  also cut the misses, to within noise of this, and bought nothing — because
  1.45 MB is L2 and this is L1. The counter run that told them apart was the
  one showing 79 % of the blend's slots stalled behind dispatch with the
  front end idle.

  **Generating pays 1 %**, worse in three of three: a tile costs a load and a
  store of every accumulator at each end and buys nothing where the range
  already sits in cache. The first version lost a fifth of the generating run
  before a guard was put on ranges under 128 positions.

### Measured

- **The strip kernel is at its arithmetic floor.** IPC 3.25, with 0.6 % of
  its dispatch slots lost to the front end and 39 % to the back. Per block it
  issues 36 multiply-add-class operations onto the two pipes that take them —
  18 cycles of floor against the 24 it takes — and every one of them is
  arithmetic the answer needs. That also kills the last idea for it: the
  sixteen `vpxor` a block are a zeroing idiom eliminated at rename, so they
  never reach a pipe. **Five changes in, the kernel is done**; nothing but a
  different algorithm moves it.

- **The value blend is waiting on the first-level cache.** IPC 0.94, 78.6 %
  of its slots stalled behind dispatch, 1.1 % in front of it. Not bandwidth —
  five experiments say so — and not the front end: a position's values are
  256 bytes and 32 KB does not hold a prompt's worth, so every position is
  four L1 misses whatever the order. The head-major copy did not change that
  either.

  The only reuse available is across query positions. Two queries against
  thirty-two components is eight accumulators and two broadcasts, fits the
  register file, reads each line for two queries instead of one, and costs
  about 17 % more instructions — which on a loop running at 0.94 is close to
  free.

### Measured and not kept

- **The redundant attention reads were removed, and it bought nothing.** A
  head-major copy of one layer's committed keys and values, built once before
  that layer's attention, with the loop reordered to hold a head still and
  walk the positions through it. **Cache misses 7.57 G to 1.47 — five times
  fewer — and the prompt 6.802 s against 6.788**, better in two rounds of
  four.

  The copy adds about 1.4 GB of traffic over the prompt and removes about
  130. The 130 were free: eight fused multiply-adds a position against eight
  independent accumulators is enough in flight to cover a second-level miss
  that the third level answers, and one layer's committed cache is under
  3 MB against 16 of it.

  Five things have now been tried against the value blend's 7 % — prefetching
  it near, prefetching it far, unrolling it, halving its bytes, and removing
  five sixths of its reads. None moved it. The memory is not what it costs,
  and "two thirds of the program's fetches happen here" was an answer to the
  wrong question. What is left is twelve instructions a position.

### Added

- **`--kv-cache q8` is 2.3x faster: 18.263 s to 7.971**, from 2.7x slower
  than f32 to 1.19x, at a quarter of the memory a context costs.
  `Head_Dot_Eighth` and `Blend_Run_Eighth` widen eight bytes with
  `vpmovzxbd`, take the bias out, convert and multiply — four instructions
  for eight components where the exact path spends one, and a quarter of the
  bytes. The same pair the half-precision cache got last commit.

### Measured and not kept

- **Attention reads the whole cache once per query position**, so a batch of
  128 reads it 128 times. That is what two thirds of the program's memory
  traffic is, and why prefetching, unrolling and halving the bytes had each
  measured as nothing: the traffic is redundant, not slow.

  Swapping the loops so a head is held still while the positions run past it
  — one head's slice is 347 KB and fits L2 — **more than doubled the misses**
  (7.57 G to 16.18) and cost 12 % of the prompt. Tiling the positions
  sixteen at a time did not bring them back. A position's keys and values are
  one contiguous kilobyte across all its heads, so a position at a time reads
  whole rows and a head at a time reads a quarter of every row it touches:
  the redundant reads are cheap because they are sequential.

  Removing the redundancy needs the cache laid out head-major, which crosses
  into the device and its shaders. Reverted; the evidence for that change is
  now much better than it was.

### Added

- **`--kv-cache f16` is 3.4x faster and usable now.** The half-precision and
  byte context storages have been here for a while and nothing wide read
  them: a prompt taking 6.9 s at full precision took **26.9 at half**, with
  81 % of it in one scalar loop. `Blend_Run_Halved` and `Head_Dot_Halved` are
  the exact kernels with a convert in front — a position's values as eight
  16-byte loads converted to eight lanes, then the same eight fused
  multiply-adds, so 128 bytes a position rather than 256.

  **f16 goes from 4.0x slower than f32 to 1.17x.** The byte cache is the same
  fix again and has not had it; `q8` is still 2.7x.

  Halving the bytes did not halve the time, which is a third piece of
  evidence — after the prefetch and the unroll — that the value blend is not
  simply short of bandwidth.

- **`Exponentiate` written out over eight lanes**: 390.2 G instructions to
  381.9. A clamp, a magic-constant round, a degree-five polynomial and a
  power of two in the exponent field are all lane arithmetic, and this unit
  is compiled for baseline x86-64, so the compiler was making four lanes of
  it with separate multiplies and adds.

  **The polynomial is deliberately not fused.** Fused it is one instruction a
  term and rounds once instead of twice — more accurate, and a different
  answer. The conformance sweep passed it at 28344 sequences and the suite at
  286 tests; what caught it was a digest in the sitting, where **the drafted
  run stopped matching the undrafted one**. That identity is a published
  claim, and it holds because a batched evaluation and a token-at-a-time one
  agree to the last bit. No tolerance question, so no tolerance caught it.

### Measured

- **Two thirds of everything this program fetches from memory is fetched by
  `Blend_Run`** — 68.1 % of the run's last-level cache misses on 2.4 % of its
  instructions, with `Head_Scores` taking another 19.9 %. That is why the
  prefetch and the unroll below both did nothing: a prefetch hides latency,
  and this is bytes. The strip kernel is the mirror image and the reassuring
  half — 70.8 % of the first-level misses and 3.3 % of the last-level ones, a
  kernel streaming through cache as intended. What it points at is the value
  cache stored at half precision, which is a format change and not a loop
  change.

- **The 34-byte block stride costs nothing** (6.629 s against 6.976 with the
  step set to 32 — wrong answers, right timing), so the alignment argument
  for repacking the weights is dead. And the scale extraction the repack
  would also delete is already done once per share, not once per tile:
  hoisting it to the caller measured 390.2 G instructions against 413.5,
  worse. Only a cache living across batches would save anything — about
  128 MiB here for perhaps 6 %, and the weights would stop being the file's
  own pages.

- **`Exponentiate` doubled costs 5.5 % of the wall for 2.75 % more
  instructions** (6.629 s against 6.985). One copy is three to five per cent
  and retires slowly. It is the largest untouched thing left in these
  kernels.

### Added

- **The two symbols nobody had opened: 10.5 % of a 1419-token prompt, better
  in four of four.** Instructions 410.2 G to 390.2. No digest moves.

  The tile write-back in `Mat_Mul_Range_Packed` narrows binary64 answers to
  binary32, and what a profile put on top were the index compares guarding a
  loop whose bounds the procedure proves at entry. Suppressed, with the
  vector's base lifted out: **2.8 % of a prompt to 1.3**.

  `Quantize_Blocks` scanned every block of activations for its largest
  magnitude and for whether all thirty-two numbers are finite, one number at
  a time — the same failure softmax's first pass had, in a different unit.
  Written out as four reads of eight lanes: a bitwise and for the magnitude,
  an ordered compare against infinity whose mask is accumulated, and a
  maximum. **3.0 % to 1.8**.

  Five per cent of the instructions bought ten of the time, which is what
  removing scalar code from an otherwise wide program looks like.

### Measured and not kept

- **Prefetching the value cache: no effect** (6.927 s against 6.846, better
  in two of four). **Two positions a turn in `Blend_Run`: worse in four of
  four** (6.729 against 6.925) despite fewer instructions. `Blend_Run` takes
  7 % of the samples on 2.4 % of the instructions and both attempts at the
  memory-latency explanation failed, so the layout change they were run to
  justify is not justified. The 7 % stands unexplained.

- **A strip of twelve: priced at 1.5 %, not built.** The corrections grow
  with the strip: twelve vectors is 113 instructions for 24 dot products
  against 77 for 16, which is 4.71 per dot against 4.81 — two per cent of
  the kernel for a shape needing fifteen of the sixteen general-purpose
  registers. Eight vectors against two rows is a local optimum.

- **A sixteen-bit load for the half-precision scales: fewer instructions, no
  time.** Three instructions where six read the two bytes; 390.2 G to 386.5.
  The symbol did not move (7.0 % to 7.3), so that loop is bound by its
  strided reads and not by the instructions around them. Reverted rather
  than carried.

- **A strip of eight vectors instead of four: 8.5 % of a 1419-token prompt,
  better in four of four.** Instructions 449.2 G to 410.2. Every digest
  unchanged.

  Two weight loads a block served four vectors; they serve eight now, and the
  inner loop falls from 5.25 instructions per dot product to 4.81. The eight
  extra accumulators were free — the shape was using ten of thirty-two vector
  registers.

  The obstacle was the general-purpose registers, not the vector ones. Four
  pointers reach eight vectors: the strip's vectors are a fixed stride apart,
  so a second index register starting at four strides addresses the upper
  four through the lower four's pointers. The block count and that stride
  take memory constraints rather than registers.

  The corrections stopped needing a fold: a row's eight are the eight lanes
  of one accumulator, one to a vector, so twelve instructions became one
  store.

  `Rows_By_Strips_Four` stays for the one strip of four a batch may end with.
  Sending those through the single-vector kernel instead cost a sixth of the
  six-token prompt and moved its digest — a strip folds eight lanes where the
  single-vector kernel sums a row in one register, and the two do not agree
  in the last bits.

- **`Scale_At` forced inline.** Taking the block size out of the driver's
  scale loop left it tight enough that the compiler stopped inlining the
  half-precision read and gave it a symbol of its own, costing what the call
  it replaced had cost. `rows` plus `scale_at` 3.5 % of a prompt to 2.7 %,
  instructions 456.7 G to 449.2.

### Measured and not built

- **Attention's two kernels priced by running each twice.** `Head_Scores`
  issues 6.5 % of the program's instructions and a second copy costs under
  3 % of the wall — it already overlaps, and there is nothing to win.
  `Blend_Run` is the reverse: **2.4 % of the instructions and 6.7 % of the
  samples**, so it is waiting rather than computing. It walks the value cache
  one position at a time with a stride of the cache row, which is a gather in
  everything but name. The thing to change there is the layout, not the code.

- **Three loops the compiler would not vectorize, written out: 3.5 % of a
  1419-token prompt, better in three of four.** Instructions 469.3 G to
  456.7. No digest moves.

  The strip driver's scale table asked `Block_Bytes` for the block size
  inside its own loop and the call did not inline — a call, an overflow
  check and a bounds compare per block, around a two-byte load. The size is
  already a constant of the enclosing procedure.

  Softmax divided every score by a binary64 sum, converting up and back four
  values a turn, and accumulated that sum down a single dependency chain.
  One reciprocal and a narrow multiply now; four independent chains put back
  together in a fixed order.

  Softmax's first pass wanted the largest score and whether every score is
  finite. The finiteness test is an integer test of the exponent field and
  kept the loop scalar. As an insertion both are lane work: a maximum, and
  an ordered compare of the magnitude against infinity whose mask is
  accumulated — a value that is not finite fails it whether it is an
  infinity or a NaN.

  It does not show on the 110-token prompt, and that is the shape of the
  work: attention grows with the square of the context.

### Measured and refused

- **Two Q8_0 blocks per 512-bit byte dot product: 7 % fewer instructions for
  20 % more cycles.** Built, measured, reverted. This part double-pumps
  512-bit operations, so a wide dot product costs what the two narrow ones it
  replaces cost and the three instructions around each cost what their two
  copies cost — while the wide shape needs a broadcast, a multiply to fold
  the row scale in, and four correction multiply-adds where there was one.
  The earlier 2.12x throughput probe reads like a promise and is not one.

### Changed

- **The published figures were re-taken on a machine measuring about a tenth
  slower**, llama.cpp included: 385.0 t/s on a prompt before, 347.8 now, with
  the part's idle floor up from 51 to 54 degrees. Every absolute in `## Speed`
  moves with it and the ratios do not — the processor prompt gap reads 1.5x
  against 1.51x. The two binaries were also run against each other directly
  on that machine to separate the two effects.

- **The bias correction and the eight-lane fold moved into the insertion:
  14 % of a processor prompt, better in three of three.** The largest single
  change measured on the processor here. **Prompt 254.6 t/s against
  llama.cpp's 385.0 — 1.51x**, from 2.5x when this work began.

  The accounting priced the correction at 23.7 % and the reduction at 3.9,
  both of them shuffle networks and widening loops `-O3` built around Ada
  that no arrangement of Ada could escape.

  The correction costs three instructions a block. The insertion already
  reads the eight scales it needs, one per dot product as a `{1to8}`
  broadcast; read instead as one 32-byte `vmovups` they are eight lanes in
  the order `[row0 v0..v3, row1 v0..v3]`, and the block totals — written
  twice over, eight to a block — line up lane for lane. One `vmovups`, one
  `vfmadd231ps`, and all eight corrections advance together.

  The fold costs twelve at the end, the same `vhaddps` reduction
  `Head_Scores` uses. The accumulators moved from `ymm16`–`23` to
  `ymm8`–`15`: `vhaddps` has no EVEX encoding and cannot reach the high
  sixteen.

  Median **8.144 → 7.005 s**. The answers move and the sweep is clean.

- **The bias correction is a quarter of a processor prompt, for one
  multiply-add against the byte dot product's thirty-two.** Nothing kept;
  two ways around it failed and the measurement names the third.

  Two ablations split the scale table's remaining cost: dropping the
  table's multiply and load is worth **0.466 s (5.7 %)**; dropping the
  correction's accumulation is worth **1.927 s (23.7 %)**. A thirty-second
  of the arithmetic taking half the time is a symptom, and `addr2line`
  names it — the four turns write `Undo (At_Undo + Vector)` in place and
  `-O3` builds a shuffle network around it, `vunpcklps`, `valignd` and
  `vaddps` coming to 18 % of the symbol for four additions.

  Row outside block puts the corrections in registers, halves the shuffles,
  and measures **8 % worse in five of five** — the scale table is then
  written with a stride in two passes instead of straight through. Block
  outermost with eight named scalars produces **exactly the baseline's
  shuffle counts** and measures level: GNAT vectorizes across the block
  loop, not within the four turns.

  What is left is to compute the correction where the code is not the
  compiler's — the insertion already reads the table a block at a time and
  could accumulate it with one more broadcast and one more fused
  multiply-add per dot product.

- **The scale-table build as two loops instead of one: 3.7 % of a processor
  prompt, better in five of five.** A quarter of the seventeen per cent the
  ablation priced.

  The inner four turns did a store into `Scaling` and a read-modify-write
  into `Undo` at once, and the second is what stopped the nest vectorizing —
  which is why halving its shuffles did nothing. Apart, one is a map and the
  other an accumulation and `-O3` takes both four at a time. The correction
  now multiplies by the block's scale times its total, worked out once a
  call rather than once a panel, so a turn multiplies by one number instead
  of two.

  Median **8.369 → 8.062 s**. Not bit for bit — the same three numbers in a
  different order — and the sweep is clean.

  The same restructuring measured level two days ago and was reverted. The
  difference is the second multiply, and the entry recording that null did
  not yet know the block was worth 17 %.

- **The scale-table build is 17 % of a processor prompt, and an earlier
  entry here said it was free.** Nothing kept; the measurement corrects the
  record and names the largest item left.

  Two entries disagreed: one halved the build's shuffles and measured level,
  concluding the block was free; the other found the inner loop already at
  four-fifths of the byte product's isolated peak, leaving half the kernel
  unaccounted. One ablation settles it — build the table for the first panel
  only, wrong answers but valid floats. **Median 8.058 → 6.700 s, 1.358
  seconds, better in five of five.**

  Both measurements are true, and the arithmetic says why. For a 2048-row
  matrix the build runs 1024 panels × 64 blocks × 8 = 512K iterations, and
  the insertion beside it runs 512K byte dot products. **The build is not
  overhead around the inner loop; it is a second loop of the same length**,
  four or five instructions an iteration against the dot product's four.
  Halving one kind of instruction inside it could never show.

  What it computes — a weight scale times an activation scale, eight a block
  — is irreducible. Computing them once a panel, storing them, and reading
  them back a few instructions later is not.

- **The interleaved layout is worth about 5 % and was not built.** Priced
  before it was written, which is the whole point of the entry.

  Rearranging rows' quants at load so a wide load is a wide operand — at
  four-byte granularity, so the lanes alternate between two rows and the
  scale becomes a `vbroadcastf32x2` rather than a cross-lane `vpermps`.
  Both loop shapes written against synthetic data with nothing in the
  engine touched: **127 and 130 giga-multiply-adds a second for the
  committed shape, 137 and 137 for the interleaved one.**

  Twenty-five instructions a block against thirty-nine, every cross-lane
  instruction gone, and a twentieth of the speed. Under 2 % of a prompt for
  a change to the loader, the packer, the kernel and a fallback. Not built.

  **The experiment says more than its result.** That loop reaches 127 on hot
  data and the real kernel manages about 67 — so the inner loop is already
  at four-fifths of the instruction's isolated peak, and **half this
  kernel's time is not in its inner loop.** Which contradicts the earlier
  finding that halving the scale-table build measured level, and that
  contradiction is now the sharpest open question in the file.

- **The 512-bit byte dot product is 2.12x the 256-bit one, and the kernel
  built on it is 11.5 % slower.** Nothing kept; both measurements are.

  A scratch program timing nothing but byte dot products: **152 giga
  multiply-adds a second at 256 bits, 324 at 512**, for the same instruction
  count in the same time. It is *not* double-pumped — which the earlier
  entry on this idea guessed and got wrong — and the kernel had room for it,
  issuing 39 instructions per 256 multiply-adds where the peak is one per
  32.

  So it was built: two rows into one register with `vinserti64x4`, the
  activation duplicated with `vbroadcasti64x4`, and the per-block scale
  expanded by `vpermps` rather than by a table sixteen times the size.
  **Median 8.275 → 9.228 s, worse in five of five.**

  The counters rule out the obvious excuse. 190.1 G cycles and 550.0 G
  instructions become **206.7 G cycles and 532.5 G instructions** — fewer
  instructions in more cycles, IPC 2.89 → 2.58 — and cycles a second is
  1.3 % *higher* on the wide build, so there is no AVX-512 throttling here.
  The instructions that feed the wide dot product cost more than the dot
  products they save.

  Same shape as the device's cooperative matrix: an instruction worth having
  that the data's layout cannot feed. Making it pay means interleaving
  several rows' quants at load — a change to what a file becomes, not to a
  loop.

- **The packing of a batch is shared between the workers: 6.3 % of a
  processor prompt, bit for bit.** The prompt gap to llama.cpp goes under
  two times for the first time — **206.8 t/s against 386.4, 1.87×**, from
  2.5× when the day began.

  `quantize_vectors` was the largest main-thread-only item: 1.54 % of
  samples, all on one thread of eight, so about 9 % of the clock. Checked
  before changed — the loop is already vectorized and its two calls are cold
  check handlers, so the lever was parallelism, not lanes.

  It has to be its own dispatch: packing runs before the workers are woken
  and cannot join the product's shares, because that job is cut by rows and
  every worker needs all of the activation. But its own loop is over blocks,
  and a block is independent of every other, so `Quantize_Blocks` takes a
  range and `Prepare_Packed` dispatches shares of the block count. Bounded
  at 256 blocks, since a wake and a barrier are not free and a generated
  token is one vector.

  Median **8.911 → 8.350 s, better in five of five**, digest unchanged. A
  test cuts a run into four uneven pieces including an empty one and
  requires the bytes, scales and totals to equal the whole run's.

- **The feed-forward gate's activation goes through the vectorized
  exponential: 3.5 % of a long prompt and 3.9 % of a short one.**

  Profiling by thread named the serial work: the main thread is busy 9.46 s
  of a 9.54 s prompt against each worker's 6.24, and `SiLU` with its libm
  calls is ~2 % of all samples on one thread — paid whole on the clock
  rather than divided by eight.

  The obvious remedy failed first and usefully. Giving the submitting task
  half a share measured **3 % worse in five of five**, because the serial
  work happens *between* dispatches, not inside one: a share cannot fix what
  is not in a share. Reverted.

  `SiLU` now uses the same polynomial as the softmax, hoisted into one
  body-local `Raised` — inline, checks suppressed *inside* it, clamped at
  both ends since its argument is unbounded. Suppressing in the callers left
  a check and a call in the loop and cost both loops their vectorization.

  **9.384 → 9.057 s (5 of 5) and 0.843 → 0.810 s (4 of 4).** Processor
  prompt **183.6 t/s**, gap to llama.cpp **2.09×**, from 2.5 when the day
  began. Sweep clean.

- **Two instrument corrections.** A 110-token prompt reading 0.84 s against
  0.62 was blamed on the gate change removing an accidental cool-down; it
  was **two copies of the sitting script running at once**. The part sat at
  95 °C while they fought and fell to 63 within twenty-five seconds of
  killing them. And the repository checks can be run alone — `tests check ..
  --repository`, eleven seconds against five minutes — which was in the
  usage line all along.

- **More than half of a processor prompt is what one core does alone, and a
  profile cannot see it.** Nothing changed; the measurement redirects the
  work.

  The same 1419-token prompt at one, two, four and seven workers: **34.606,
  16.860, 12.249 and 9.540 s**, for speedups of 1.00, 2.05, 2.83 and 3.63.
  Amdahl fitted to the four- and seven-worker points gives a **15 % serial
  fraction** and predicts 3.63x at seven — exactly what it reaches, so the
  wall clock is fully explained and the run is at its ceiling.

  Fifteen per cent of the one-worker time is 5.19 s against a 9.54 s prompt,
  so **54 % of a seven-worker prompt is one core working alone**. Halving
  the strip kernel — which four changes have now failed to do — would buy
  22 %; removing the serial part would buy 54 %.

  `perf` reports where instructions are, summed over eight threads, and by
  that measure the strip kernel is 61 % and the serial loops are a few per
  cent each. That is why those four changes went to the wrong place.

  The two-worker row is superlinear (2.05x on two) and the model
  under-predicts it, which is a second core's share of cache; the fit is to
  four and seven for that reason.

- **A run of attention scores in one call instead of one score at a time:
  8.8 % of a processor prompt, better in five of five.** The largest single
  change here since the batched product.

  A profile after the exponential put `Kernels.Head_Dot` at 12 % — the
  second largest symbol in the program, and one written three commits
  earlier. A dot product is eight fused multiply-adds and then a fold, a
  serial ~20-cycle chain behind arithmetic worth eight. Removing the fold
  (wrong answers) cost **10.501 s against 10.076** — 4 % of the prompt — so
  the premise was measured before the code was written.

  `Kernels.Head_Scores` does eight keys at once: eight accumulators, the
  whole query head in eight more registers, and **one twelve-instruction
  reduction** in place of eight folds. Called in blocks of eight positions
  so that neither the key-cache locality nor the shared fold is given up.

  Median **10.286 s against 9.383**. The processor's prompt goes 167.4 to
  **176.3 t/s** and the gap to llama.cpp 2.35 to **2.22 times**; unlike the
  three changes before it, this one shows on the 110-token prompt too.

  Not bit for bit — the lanes fold in a different order. The sweep is the
  arbiter (28344 sequences, nothing outside tolerance) and a test compares
  every score of a run against the one `Head_Dot` gives, which catches a
  permutation of the fold where comparing totals would not.

- **The strip kernel has issue slack, and filling it made things worse.**
  Nothing kept; the two measurements are the point.

  Counters for a whole prompt: 710.3 G instructions in 235.7 G cycles, an
  **IPC of 3.01**, frontend stalls 1.4 % of cycles, cache misses 0.4 % of
  instructions. The machine is not stalling — which explains the previous
  entry's null, since the shuffles removed there were filling idle slots.

  Then an ablation: one extra `vpdpbusd` added to the chain of eight, same
  operand into the same accumulator, so wrong answers and the right shape.
  **224.7 G cycles for eight, 222.1 G for nine, 221.8 G for eight again** —
  an eighth more byte products costs nothing measurable. The wall clock
  could not resolve it (better in two of four rounds, worse in two); cycles
  could.

  So the loop is latency-bound with slack: each chain is `vpxor` →
  `vpdpbusd` → `vcvtdq2ps` → `vfmadd231ps`, four deep, eight independent.
  The remedy — two blocks a turn with sixteen accumulators, which also
  halves the loop overhead — measured **3 % worse in five of five**. Written
  down as a reason and not a measurement: the loop body went from ~39
  instructions to ~78, and something holding the shorter one stops holding
  the longer, which is the shape the shader met when eight unreachable
  formats cost the six reachable ones 21 %.

  What is left to try is a *shorter* chain rather than more of them. This
  does not answer whether one exists.

- **The softmax's exponential is four lanes now instead of a library call:
  three and a half per cent of a processor prompt.** A profile put the
  exponential and the softmax around it at 8.5 % of the 1419-token prompt,
  nearly all inside `__ieee754_exp`. Exponentiating a row is a map, and a
  map is what `-O3` vectorizes without being asked; a call is what stops it.

  `Kernels.Exponentiate` is the standard decomposition — e^x as two raised
  to x over the logarithm of two, the whole part built as an exponent field
  and the fraction by a degree five polynomial, in binary32.

  Two invisible things kept it scalar. `'Truncation` is a call into
  `System.Fat_Flt.Attr_Float`, replaced by adding and subtracting three
  halves of two to the twenty-third; and `Integer (Whole)` carried an
  overflow check that the floor at eighty-seven already makes impossible.
  With both gone: 18 `addps` and 16 `mulps` where there were `mulss`,
  `addss` and two `call`s.

  Five alternated rounds, median 10.854 s against **10.480**, better in
  **five of five**. The profile said 8.5 % and the clock says 3.5 — samples
  are not seconds. The answers move; the sweep is the arbiter, 28344
  sequences with nothing outside tolerance, and a test holds the two
  exponentials to a few parts in a million and names the floor as the case
  that matters.

- **A correction of the same kind as the last one.** The engine figures were
  found still reading 0.470 s and 1.68 s from two sittings earlier: the
  restamp that should have moved them was in a script that failed partway
  and never wrote, exactly as the llama.cpp table's did. Both are right now,
  and every edit in this sitting was applied and verified one at a time.

- **Two and a half times fewer weight bytes is slower on the device, and a
  doubling cannot say what a kernel's share is.** Nothing kept; three scratch
  builds, all discarded.

  The device's remaining gap was to be attacked at the activation round trip,
  on a comment saying each result still returns to the host. That comment is
  stale for the path it matters on: the batched feed-forward already sends
  gate and up with `Kept => False`, chains the combine, and returns only the
  down projection.

  So the question became where a device prompt's time is, measured by
  doubling one kind of dispatch at a time: tile products 10 %, attention
  1.7 %, row products 1.0 %. Twelve per cent against the eighty that
  `### The floor a device prompt cannot go below` gets by emptying every
  dispatch — and the doubling is linear, four passes adding 0.233 s each
  against the pair's 0.226.

  **The doubling is a lower bound, not a share.** A second dispatch of the
  same product is recorded with no barrier after the first, so the device
  overlaps them, and it reads caches the first pass warmed. This page already
  said so in the floor section; the trap was walked into anyway.

  What is new is the byte test: the same prompt at Q8_0 (1171 MB), Q4_K_M
  (638 MB) and Q2_K (461 MB) reads **2.292, 2.342 and 2.465 s** — smaller is
  slower. The device prompt is not bound by weight traffic at any of these
  sizes.

- **A quarter of the strip kernel is shuffling and removing half of it
  changed nothing.** Nothing kept; the measurement is the point.

  The strip kernel is 55 % of a processor prompt. Two guesses about it were
  wrong. The register width is not available for the asking — the capability
  and the `-march=x86-64-v4` compilation already exist, but a register holds
  exactly one Q8_0 block and blocks are 34 bytes apart, so a 64-byte load
  straddles the next block's scale, and filling a `zmm` with two rows breaks
  the `{1to8}` scale broadcast. And the time is not where it looked: the
  shuffles map through `addr2line` to the scale-table build, not to the
  reduction.

  Rewriting that build with the row outside the block and its corrections in
  a local — same arithmetic, same order, bit for bit — took the object
  file's shuffle count from 299 to 236. Five alternated rounds: median
  10.998 s against 10.839, better in three of five, same digest. **Level.**

  So those instructions issue in the shadow of the byte-product loop and
  cost nothing a clock notices. The kernel is not short of instruction
  slots, and what it is short of is a measurement this did not take.

- **A hot part gives up a tenth of every serial figure, and the load gate
  had been hiding it.** The wait the gate used to do was also, unnoticed,
  letting the part cool. The first sitting under the new gate ran two
  benchmarks back to back and the second read nine per cent below the first
  on the same code.

  Measured rather than assumed, which took two goes — the first attempt
  waited four minutes because four minutes sounded right, which is the same
  mistake as the load average with a guess in place of a lagging proxy. The
  second reads `k10temp` and waits until two samples twenty seconds apart
  are within a degree.

  | | settled, 47 °C | straight after, 81 °C |
  | --- | ---: | ---: |
  | q8_0 `Row_Dot` | **2739** | 2399 |
  | one share | **2602** | 2380 |
  | eight shares | 14030 | 13681 |

  The serial rows lose a tenth and the eight-share row two per cent: a hot
  part gives up single-core boost first, and the all-core figure is already
  at the sustained clock. Every figure under `### Kernels` is a serial rate
  and every figure in the scaling section is a serial rate or a ratio
  against one, so all of them are boost-sensitive and none of them said so.
  Both are re-measured on a settled part and both now say it.

  Not done, and the obvious next thing: the tools print the load and the
  processor seconds beside a figure and not the temperature, so a reader
  cannot yet tell a settled figure from a hot one without prose.

- **The load gate asks the processors now, not the load average, and a
  six-group re-measure went from half an hour of waiting to no waiting at
  all.** A load average lags in both directions and this was found by
  watching it do both.

  Held out: every figure here is taken in a sitting of runs back to back, so
  the number `Host_Load.Publishable` read was nearly always the previous
  run's own load decaying. The gate was waiting for arithmetic rather than
  for the machine. Let in: with eight spinners started on this machine, the
  average was still 1.06 three seconds later and the gate admitted the run —
  the half that mattered, and nothing here had noticed it.

  It now samples `/proc/stat` over a fifth of a second and counts busy
  processors against the same `Too_Busy` of 1.5, which is the same quantity
  over a different window. A host that keeps no such times has only the
  average and is left exactly where it was. Verified three ways: a quiet
  machine at average 1.16 admitted; eight spinners refused; and a machine
  whose spinners had just stopped, average 1.86, admitted and measured in
  1.1 s total where the old gate refused it outright. The sitting after it
  ran seventeen speed runs, three `llama-bench` runs and two benchmarks back
  to back with no waiting and no refusals.

  Confined to `tests/src/host_load.ads` and its body, so no call site changed
  and no figure group moved for it.

  **The load figures printed beside a run now read higher than the machine
  actually was**, because the gate no longer waits for the average to fall.
  They overstate the disturbance rather than understate it, which is the
  safe direction, but they are not comparable with the load figures recorded
  before this. `docs/measured-figures.txt` says so where it matters.

- **A correction.** The llama.cpp comparison table was restamped in the
  previous entry's sitting and the edit that wrote it failed partway and was
  never applied, while the sentences either side of it were — so one commit
  carried a table reading 141.2 and 352.0 t/s under prose quoting 166.7 and
  389.0. The fingerprint check did not catch it and cannot: it asks whether
  a group was re-measured, not whether every number in it moved. The table
  is right now and the README records what happened.

- **The value blend keeps its sums in registers now: five and three quarter
  per cent of a processor prompt.** `model_runner-llama.o` held no packed
  fused multiply-add at all -- eighteen `mulps`, seventeen `addps` -- this
  being compiled for baseline x86-64, but the fusing was the smaller half of
  what was there.

  `-O3` vectorizes the blend's inner loop and cannot keep `Sums` in
  registers across the positions, because `Sums` is an array the loop writes
  and `Values` may alias it. So each position paid a load and a store of the
  whole run as well as its arithmetic: forty instructions where nine would
  do. `Model_Runner.Kernels.Blend_Run` loads eight accumulators once,
  broadcasts a position's score into eight lanes, issues eight
  `vfmadd231ps` over the values where they lie, and stores once at the end.

  Seven alternated rounds on the 1419-token prompt, median 11.372 s against
  **10.723**, better in **seven of seven**. The answers move because a fused
  multiply-add rounds a product once where the portable form rounds it
  twice -- the insertion is the more accurate of the two -- and the sweep is
  the arbiter: 28344 sequences, nothing outside tolerance. A test holds the
  two paths together.

  `Kernels.Use_Wide_Dots` is now `Use_Wide_Lanes`, since it gates both.

- **The matrix tile at sixty-four rows: measured and reverted, and the shapes
  table in `tests device-bench` gained a control that says its first row
  reads forty per cent high.**

  `tests device-bench` times a 16384 by 2048 product at a batch of 128 in
  eight formats, and every one of them lands between 3.1 and 4.3 teraflops a
  second -- half precision with no decode beside Q2_K with six times fewer
  bytes and the most elaborate decode. Neither the bytes nor the decode
  binds it, which leaves the activations: a workgroup takes thirty-two rows
  and the whole batch, so sixteen thousand rows read a half-megabyte batch
  five hundred and twelve times, a quarter of a gigabyte against
  thirty-four megabytes of weights.

  Doubling the row tile -- sixty-four rows in two waves splitting the
  vectors, same accumulators per wave, same decode per lane -- halves that
  and **lost in all eight formats**, by thirty to forty-five per cent, where
  two sittings of the committed shader agree within eight. Written down as a
  reason and not a measurement: with one wave a `barrier()` has nobody to
  wait for, and with two it is a real wait twice every thirty-two columns.
  Fifth attempt at this tile's shape, fifth revert.

  While measuring it, `query` and `out proj` in the shapes table turned out
  to be the same shape reading thirty-three per cent apart, in three
  sittings. The table now measures the first row's shape again at the end:
  in one run the four readings are 3035, 2173, 2178 and 2201 Gflop/s, so the
  three that are not first agree within one and a half per cent. The first
  shape a sitting measures reads high whichever shape it is, and the 2714
  published for `query` is the instrument. The control row stays.

- **The attention score dot product is a machine-code insertion now, and the
  value blend beside it is binary32: fourteen and a half per cent and four
  per cent of a processor prompt.** The entry below this one proved that no
  arrangement of Ada makes GNAT vectorise a reduction; this is what was left.

  `Model_Runner.Kernels.Head_Dot` issues `vfmadd231ps` over eight binary32
  pairs a turn and folds the eight lanes once at the end, with the portable
  loop still there for a host without the instructions. On the 1419-token
  prompt, alternated rounds under a load of 1.20: 13.538, 14.255 and 13.691 s
  against **11.736, 11.432 and 11.664** -- better in three of three.
  Generating is level at 2.02 s against 2.00, and has to be: a generated
  token has one query row, so the loop runs once a head rather than once a
  position.

  The value blend was already packed and was packed in *binary64*. It is a
  map, so the format is the lane count: 34 `mulpd` and 32 `addpd` become 18
  `mulps` and 17 `addps`. Three rounds did not clear the noise floor, so it
  was taken seven times and reads better in **seven of seven**, median 11.728
  against 11.249 -- four per cent. `Blend_Halved` and `Blend_Eighth` got the
  same change, which their own comments already said they should.

  Both move the answers and the conformance sweep is the arbiter for both, as
  it is for the byte dot product: 28344 sequences, nothing outside tolerance,
  run on each change separately. The sixty-four-token digest moves twice,
  `448c2ed68ec342ee` to `cf8edab322fa571f` to `1cb5fffbb21399ad`, and the
  110-token prompt digest does not move.

  Against llama.cpp the processor's prompt goes from 141.2 to **168.7 tokens
  a second** and the gap from 2.5 to 2.3 times.

  A repository check refused the insertion where it was first written.
  `model_runner-llama.adb` interprets what a model file holds, so it may not
  `with Model_Runner.Platform` -- that is what keeps a chat template or a
  metadata value from making the program read something else off the machine.
  The capability is told rather than asked, as `Use_Wide_Decoders` is:
  `Kernels.Use_Wide_Lanes`, called once from `Backend.CPU`'s elaboration
  before any container is open. A test drives both paths and asserts they
  agree.

- **The processor's attention scores in binary32 measured level, and the
  reason is that GNAT will not vectorise a reduction however it is written.**
  Not kept.

  That loop is 27 per cent of a processor prompt and widens two binary32
  operands to binary64 in one serial accumulator; the device has always
  computed the same scores in binary32 and the sweep holds both at the same
  tolerance, so the precision question was answered on the other side.
  Changed to binary32 in eight accumulators it reads 14.783 s and 14.640
  against 14.520 and 14.886 -- level -- and the answers do not move.

  The object file says why: the score loop is `mulsd`/`addsd` in binary64 and
  `mulss`/`addss` in binary32, both **scalar**, while the value blend twenty
  lines below is `mulpd`/`addpd`, **packed**. The blend is a map, which `-O3`
  vectorises unasked; the score is a reduction, and writing it as eight
  independent lanes -- a map by construction -- still produced eight scalar
  chains.

  This explains three null results that looked unrelated: reassociating
  `RMS_Norm` bought one per cent, four accumulators here seven, binary32
  nothing. Every arrangement of scalar arithmetic is scalar arithmetic. What
  would work is a machine-code insertion with a runtime capability check,
  which is what this project's integer kernels already are.

### Changed

- **The processor's attention read the whole key cache once for every head;
  reading it once for the heads that share it is four per cent of a processor
  prompt, bit-exact.** A 1419-token prompt reads 14.669 s against 15.292 and
  a 110-token one 0.703 s against 0.731, better in every round.

  The processor prompt had never had the floor treatment. Its budget is
  attending 6.79 s and feeding 6.91 of 16.11, and emptying the score dot
  product alone takes the prompt to 11.96 -- so **that one loop is 65 per
  cent of attending and 27 per cent of the whole prompt**, which nothing here
  had named.

  The head loop was outermost, so each head streamed 363 kilobytes of keys
  for itself and the next head streamed them again. With the position
  outside, the heads of a share read the same key row one after another. It
  is the same shape as the device's attention change and the same shape the
  value blend twenty lines below already had.

  Four accumulators were also tried on that loop's serial binary64 chain:
  seven per cent of attending, and it reassociates a sum every published
  digest depends on. Not kept.

  Four per cent is small for a loop that is 27 per cent of the prompt, and
  that is the finding -- the rest is the binary64 conversion and the
  arithmetic itself, which is the same answer the device gave from the other
  side.

### Changed

- **Attention loaded every value once per query of its block; loading it once
  makes a device prompt 1.14 times faster.** The 1419-token prompt reads
  2.235 s against 2.544 and the 110-token one 0.160 s against 0.203, better
  in every round. Generating does not move.

  The weighted sum of values ran the query loop outside the position loop, so
  one address holding one value was loaded once for every query of the
  block -- four loads for four multiply-adds where one will do. The dot
  product above it already had the shape the other way round, which is why
  the query block bought 1.5 times there and this went unnoticed.

  This is the mechanism the measurement pointed at rather than the one that
  was planned: attention's whole memory cost is fifteen per cent, so
  coalescing its key reads was retired, and what was left was instructions.

  **The prompt's answers change.** Each query accumulates over the positions
  in the same order and the expressions are identical, so the arithmetic is
  the same as written; what differs is which multiply-adds the compiler
  fuses, which GLSL lets it choose. The conformance sweep passes at 28344
  sequences with none outside tolerance. Generating is bit-identical, because
  a batch of one takes the kernel where the swap collapses to the same code.

  Against llama.cpp the device prompt goes to **670.7 tokens a second** and
  the gap from 3.0 times to **2.5**.

### Added

- **The batched product is short of arithmetic and not of memory: six times
  the bytes costs a quarter more time.** `tests device-bench` grew an
  instrument that holds the shape and the batch still and sweeps only the
  format, so the flops are identical and only the traffic differs. At 16384
  by 2048 and 128 vectors it reads 2624 Gflop/s at two bytes a weight and
  3358 at a third of a byte -- **6.1 times the bytes for 1.25 times the
  time**.

  Fitting arithmetic against bytes gives **3.52 Tflop/s of arithmetic and a
  marginal byte rate of 87 GB/s**, which is this part's bus. The weight
  reads are already as fast as they can be, and for the eight-bit format
  memory is 15 per cent of the time.

  That retires a class of ideas at once: a smaller weight format is not a
  faster one here (`q4_k` and `q8_0` are within six per cent), and nothing
  whose mechanism is fewer or better-shaped bytes will move the product.
  What is left is flops per clock out of the matrix instruction. Attention,
  measured separately, agrees -- so both device kernels are short of
  arithmetic and neither is short of memory.

  The instrument takes the best of three passes: a pass apiece gave a
  sixty per cent spread between rounds and a first reading that had `f16` 21
  per cent slower than `bf16`, which was noise and would have been published
  as a finding about `unpackHalf2x16`.

- **The narrow projection that looked six times slow was the instrument, and
  the tile does 3.4 teraflops a second.** `tests device-bench` times a whole
  `Multiply` -- upload, record, submit, wait, copy back -- and that round trip
  costs the same whatever the matrix is. Sweeping only the rows at a fixed
  batch, one workgroup to sixty-four, gives **sixty-four times the work for
  two and a third times the time**: 0.252 ms to 0.595 ms. A fit through the
  seven points is 0.289 ms fixed plus 0.154 microseconds a row, and that
  slope is 3.41 Tflop/s.

  The grouped key and value projection does 0.13 Gflop, which at that rate is
  0.038 ms on top of 0.289 ms of round trip: **88 per cent of its measured
  time was the instrument**. There is nothing wrong with the shape, and the
  narrow vector tile was measured and rejected earlier today for a problem
  that was not there.

  The fixed cost is not only the instrument's: a 1419-token prompt makes
  about 1710 product calls and the measured floor of its whole surround is
  0.502 s, which is 0.29 ms apiece. Whether a bigger batch divides it was
  checked -- `--batch-size` 64 through 1024 reads 3.138, 2.490, 2.459, 2.426
  and 2.547 s -- and it does not: the floor is host loops over positions.

  `tests device-bench` keeps the row sweep, so the next reader of that table
  sees what it is made of.

- **What surrounds the device's products is a fifth of a prompt, not a half,
  and the phase counters that said otherwise were measuring the host waiting
  for the device.** With every `Dispatch` asking for zero workgroups -- every
  command buffer still recorded, every submission made and waited on, every
  transfer done, no arithmetic -- a 1419-token device prompt reads 0.502 s
  against 2.530, and a 110-token one 0.045 s against 0.208. **Eighty per cent
  of a device prompt is device arithmetic.**

  A phase is host wall time around an asynchronous submission, so the
  "non-arithmetic" part of the feeding phase is the host waiting for the
  arithmetic to finish. It is the work, seen from the side not doing it. That
  is the third time a phase counter has pointed somewhere false here; they
  say which part of a layer grew and not what a part is made of.

  Taking the entire surround away -- submissions, transfers and host loops
  all free -- would leave this prompt at 2.03 s against llama.cpp's 0.86, so
  the remaining gap is the arithmetic.

### Changed

- **A device run gets a worker pool, and the host loops it never had one for
  are shared out: a 1419-token device prompt is 1.44 times faster.** It reads
  2.522 s against 3.626, the 110-token one 0.205 s against 0.241, better in
  every round, and the answers are bit-identical.

  Two things were wrong. The input normalization and the two residual joins
  are loops over positions on the host whichever backend answers, and they
  ran on the calling task -- 22 per cent of a device prompt on one core. They
  now go to `Dispatch_Shares`, which was already there and already used a few
  lines below for attention; a share takes its own scratch row, which is what
  `Item.Post_Room` -- one row shared by every position -- had prevented.

  And a device run had no pool at all: every place that opened a session
  decided one on the backend's `Supports_Parallel`, which says whether that
  backend's own *products* divide across workers. The device's do not; they
  divide across the device. But a run is not only its products.

  The rotation is left serial on purpose: it writes the key and value cache,
  and on a device that is a call through an engine that is one task's to use.

  Generating does not move -- a batch of one is below the sixteen this asks
  for -- and neither does the processor, which had a pool all along. Against
  llama.cpp the device prompt goes to **550.0 tokens a second** and the gap
  from 3.6 times to **3.0**.

  `inspect` now reports three worker tasks for a device run where it reported
  one. The suite caught that: the number was asserted, and asserted as one
  because that was true.

### Changed

- **Tokenizing is fourteen times faster on SentencePiece vocabularies, and a
  user's wall clock for a long prompt is halved.** A 1419-token prompt
  tokenized in 2.053 s and now takes 0.143 s; the whole run goes from 6.076 s
  to 4.033 s and its processor time from 3.13 s to 1.07 s. The tokens are
  bit for bit the same.

  The SentencePiece road found the best-scoring adjacent pair by walking
  every surviving pair, building the two symbols into one string and looking
  that string up -- a pass per merge. For that prompt it is about **21
  million concatenations and hash lookups**. What a merge changes is two
  pairs: the one the merged symbol now begins, and the one that ends where
  it begins. Working every pair's worth out once and those two out again is
  17,169 lookups, twelve hundred times fewer. The pass that remains compares
  floats, so the shape is still quadratic; the constant is a float compare
  rather than a string on the heap.

  The scan runs over the same symbols in the same order and takes a pair only
  on a strictly greater score, so the leftmost of equals still wins, which is
  what makes it bit-exact. The byte-pair and Unigram roads are untouched --
  byte pair merges within a word, where a pass per merge is right.

  It appeared in no published figure, because the speed tool times
  tokenization apart from evaluation. It was found by asking why a device
  prompt used 2.98 s of processor time for 3.755 s of wall.

### Added

- **The elementwise phases profiled: not dispatches, one core.** Joining,
  normalizing and rotating are 22 per cent of a device prompt and the second
  largest item after attending, and the guess that this was "a
  batching-of-dispatches problem" was wrong. They are host loops on the
  calling task: a 1419-token device prompt reads 3.400 s at `--threads 1`
  and 3.527 s at `--threads 8`, with the processor time identical. One core
  does elementwise work for a fifth of the run while seven sit idle.

  Two changes were sized and neither kept. Removing `RMS_Norm`'s dead
  zero-fill -- a whole pass over the target that the two loops below
  overwrite, 62,000 times a prompt -- is bit-exact and takes the device's
  normalizing from 0.251 s to 0.241 while making a processor prompt *worse*,
  0.748 s to 0.759 in all three rounds; the likeliest reason is that the
  fill brings the lines in before the scattered writes ask for them.
  Reassociating its serial binary64 accumulator into eight buys 40
  milliseconds, one per cent, and would move every published digest on both
  backends.

  What is left is named with its blocker: the phases parallelize by position
  and would be bit-exact, `Dispatch_Shares` is already used a few lines
  above for attention, and what stops a straight substitution is
  `Item.Post_Room` -- one scratch array shared by every position, which
  shares would race on.

- **What tokenizing costs, which no figure here has said.** Tokenizing a
  1419-token prompt takes **2.05 s**. The speed tool times it apart from
  evaluation, so it is in no published figure -- but the wall clock for that
  run is 6.148 s, of which 1.85 s is tokenizing. That is a larger single
  item than the elementwise phases and nothing here has looked at it.

### Changed

- **A device prompt is a tenth faster for deleting copies nobody read.** The
  1419-token prompt reads 3.538 s against 3.933 and the 110-token one 0.239
  against 0.260, better in every round and bit-identical: nothing about what
  is computed changed.

  `Run` copied every step's answer into the caller's target, and both callers
  that name several steps then read one. `Dispatch_Gated` said so in a
  comment of its own -- "only the last of the four is wanted here. The arms
  and the combined value are the device's business and stay there" -- and
  they did not stay there. For a batch of 128 that is three answers of 2.88
  MB each copied to the host to be stepped over, against the 1.05 MB that is
  read; `Attend_And_Project` copied the attention blend back with the
  projection for another 1.05 MB. Across 22 layers and the eleven batches of
  a long prompt, about two and a third gigabytes of memcpy that nothing
  reads.

  The change is a `Kept` flag on a sequence step, false where nothing on the
  host reads that step's answer, and one test in `Run`'s download loop. The
  room is still stepped over, so what a caller indexes does not depend on
  what it keeps.

  Feeding loses 0.191 s and attending 0.110, which is where the profile in
  the entry below said the time was. About half of that entry's
  fifty-seven per cent was this; the rest is submissions and fences and is
  still unmeasured. Generating does not move and cannot -- one vector makes
  those answers a few kilobytes.

  Against llama.cpp the device prompt goes to **464.1 tokens a second** and
  the gap from 3.8 times to **3.6**.

### Added

- **`tests device-bench` reports the batched product's throughput at the
  shapes a layer asks for, and the profile it produced moved the question
  elsewhere.** No kernel change kept.

  The budget said projecting runs at about 790 gigaflops a second and
  feeding at 1662 on the same kernel. Timing one product rather than a phase
  of four found why: the grouped keys and values, 256 rows by 2048, run at
  **455 Gflop/s against 2031 to 3204 for every other shape**. A workgroup
  takes 32 rows and 128 vectors, so that shape is eight workgroups on twelve
  compute units -- and grouped-query attention gives every modern model such
  a projection.

  Widening the batch alone confirms the cause: 455, 706, 835 and 1103
  Gflop/s at 8, 16, 32 and 64 workgroups. A narrower vector tile was built
  to make more workgroups at the batch a prompt has, and **buys 26 per cent
  on the narrow shape for 25 off the query and 41 off the vocabulary**. Not
  kept.

  The number that reframes it: dispatching every tile product twice with
  unchanged data adds 0.552 s to a 1.294 s feeding phase, so **the
  arithmetic is 43 per cent of it**. The other 57 -- three quarters of a
  second on a four-second prompt -- is submissions, fences, and the
  activation that returns to the host after every product and is uploaded
  again for the next. The batched product is not what is left of the
  device's prompt gap; what is left is around it.

- **Attention through the cooperative matrix works once its operands are
  already half precision -- 1.43 times faster -- and the half-precision
  cache it needs puts 8107 of 28344 conformance sequences outside
  tolerance. Not kept.**

  The entry below guessed that removing the staging would still leave the
  matrix kernel slower. That guess was wrong, and a probe said so before
  anything was built: the same kernel with the staging deleted and the
  operands read from the query room instead -- same instruction count, same
  matrix products, neither the room nor the conversion loops -- read
  attention at 0.99 s against the staged kernel's 1.65 and the kept
  kernel's 1.39.

  Built properly, with the device's copy of the cache written as
  `float16_t`, attention reads 1.031 s against 1.475 over three alternated
  rounds. The whole prompt does not move (3.919 s against 3.926): rotating
  gains 0.130 s converting each cache row on the host, and feeding gains
  0.192 s that nothing here touches.

  **The sweep is what decides it.** A half-precision cache is not a rounding
  of operands the way the batched product's weights are -- it compounds,
  because a key written at the first position is read again at every
  position after it. Twenty-nine per cent of the sweep fell outside
  tolerance. It would not be kept even if the prompt had moved.

  Two things are kept from it: the probe technique, which priced a change
  before it was built and corrected a badly wrong estimate, and the figure
  itself -- 1.43 times for the matrix instruction when its operands are
  already the precision it wants.

- **Attention through the cooperative matrix was built, measured twelve per
  cent slower, and is not kept.** With the query block in, attention was
  doing 182 Gflop at about 153 gigaflops a second on a part whose matrix
  tile reaches 2031, and confining its reads to a cache-resident window
  bought only 1.18 times -- so what remained was arithmetic, on an
  instruction this program already dispatches.

  Built as `attention_matrix.comp`: Q times K transposed as one matrix
  product, the softmax in shared memory between them, the weights times the
  values as another, at the same 16x16x16 half-precision shape the batched
  product uses. Attention alone on a 1419-token prompt read 1.565 s at its
  best against 1.396 for the kernel it would have replaced, better in no
  round.

  The reason is shared memory, again. The instruction takes half precision
  and the cache is binary32, so the keys and values must be staged to be
  converted; the softmax is not a matrix product, so the scores come out and
  the weights go back; and a running softmax scales the answer a row at a
  time, which the instruction cannot do to its own registers, so the
  accumulators come out and back once a tile too. The three key-tile widths
  order themselves by their room and nothing else -- 8768 bytes 1.579 s,
  11328 bytes 1.607 s, 16448 bytes 1.858 s -- and a wider tile does *fewer*
  round trips per key, which rules the round trips out. The kernel that
  stands uses one kilobyte.

  Fourth time hand-staging into shared memory has lost on this device, and
  the first where it was staging for the matrix instruction rather than a
  hand-written loop. It would also have changed the answers, since the
  operands round to half precision.

- **A workgroup of the attention kernel answers four query positions instead
  of one, and a device prompt is a tenth faster.** Attention itself goes
  from 2.030 s to 1.356 s on a 1419-token prompt; the 110-token device
  prompt reads 0.245 s against 0.267, better in each of three rounds, and
  the 1419-token one 3.922 s against 4.211. The answers are bit-identical:
  the long prompt prints `1a26d24d33b8957b` either way.

  **It was priced before it was built.** Confining the key and value reads
  to eight cached positions -- same instructions, same arithmetic, same
  count of loads, all cache-resident -- read attention at 1.27 s against
  2.06. Two fifths of attention was the traffic, and the traffic was almost
  entirely re-reading: the keys a group of eight heads shares are read by
  each of them, and every query position reads them again.

  `attention.comp` gained a `QUERIES` constant and a third compilation with
  `QUERY_TILE`, which sets it to four; the key component a lane reads is now
  multiplied into four queries rather than read again by each. Everything
  else is the same text -- `QUERIES` is one in the other two compilations.
  A block wants a maximum and a sum per query per tile, so the tiled
  compilation requires the subgroup one.

  Four beats two and eight: at eight the register pressure takes back more
  occupancy than the extra reuse buys. Generating does not move, and is not
  meant to -- one position is fewer than a block, so the engine binds the
  subgroup kernel there.

  A repository check now reads `QUERIES` out of the shader and requires the
  engine's `Query_Block` to equal it. That number is stated in two places,
  and it drifted within an hour of being written: a careless sweep set the
  shader's to four while the engine still dispatched one workgroup a query,
  and all 280 tests passed because the suite's batches are shorter than a
  block.

- **Attention reduces across a subgroup where the device offers one: a fifth
  faster as a kernel, and four per cent on a generated token with a long
  context.** `attention.comp` is compiled twice, the second with
  `SUBGROUPS`, and the engine binds it where the device reports the basic
  and arithmetic subgroup operations in a compute stage -- a different
  question from the matrix instruction, and one that needs no extension,
  since subgroup arithmetic is core Vulkan 1.1.

  Per tile of sixty-four scores every lane walked all sixty-four entries
  twice, once for the largest and once for the sum: a hundred and
  twenty-eight serial reads a lane against the sixty-four the dot product
  itself takes. Both are now one instruction and a partial per subgroup.
  `tests device-bench` reads 1.18 to 1.19 times faster on four shapes.

  **A prompt cannot feel it, and that is the finding.** A 110-token device
  prompt reads 0.269 s against 0.271 and a 1419-token one 4.268 against
  4.377, inside its own spread -- even though doubling the dispatch prices
  attention at 12 and 31 per cent of those two runs. Sixty-four tokens
  generated after a 1419-token prompt is the one shape that moves: 2.305 s
  against 2.401, better in each of three rounds, bit-identical answers.

  The reason is the workgroup count. A prompt dispatches a workgroup per
  head per position -- some forty-five thousand across twelve compute units
  -- and at that occupancy the reductions' latency hides behind other
  workgroups, leaving only the memory the keys come out of. A generated
  token dispatches thirty-two, one a head, with nothing to hide behind. The
  same kernel change is worth a fifth where the device is latency-bound and
  nothing where it is saturated, and `tests device-bench` measures the
  latency-bound shape by construction -- which is why a kernel benchmark and
  a run are not measuring the same machine.

  Kept because it is faster or level everywhere and the answers do not
  change, not because of the nineteen per cent.

- **A generated token on the device is 1.3 to 3.3 times faster, and the
  reason it was slow is not the one anybody would have guessed.** `Q5_K_M`
  generates 64 tokens in 2.301 s against 7.499, `Q2_K` in 1.433 against
  4.211, `Q8_0` in 1.630 against 2.072 -- 27.8, 44.7 and 39.3 tokens a
  second. Medians of three alternated rounds, better in every one, and the
  output digest is unchanged: `448c2ed68ec342ee` either way.

  **The diagnosis.** Time per generated token was not a function of model
  size: the 461 MB `Q2_K` file took twice as long per token as the 1171 MB
  `Q8_0` one, and the achieved rate varied five and a half times across
  formats. A kernel bound by memory cannot do that. A new per-format sweep
  in `tests device-bench` -- absolute seconds for one vector against a
  resident matrix, rather than the ratio against the processor that `tests
  benchmark` prints -- gave the cost per element, and multiplying it by a
  model's element count reproduced the token time for every format. So a
  generated token on the device is the row product and nothing else.

  Half precision and binary32 named the cause between them: binary32 reads
  four bytes an element at the bus rate, half precision reads two and took
  the same time per element at half the traffic. Something fixed was being
  paid per element. It was the batch group: the shader carries eight
  accumulators, reads eight vector offsets per weight and reserves eight
  kilobytes of shared memory for a reduction, because a prompt reads eight
  vectors to a pass. A generated token is one vector, so seven eighths of
  all three were spent on padding thrown away at the end -- and the shared
  memory is what bounds how many workgroups a compute unit will hold.

  `row_product.comp` is now compiled twice, the second with `SINGLE`, which
  sets the group to one; the engine binds the narrow pipeline for a batch of
  one and the wide one otherwise. The same arrangement `matrix_product.comp`
  already uses, and a repository check reads the narrow compilation's digest
  as well as the wide one's.

  A prompt does not move -- 0.336 s against 0.340 -- because a prompt is
  never a batch of one. Binary32 barely moves either, at 1.05 times, which
  is the control: it was the one format already at the bus and so the one
  with nothing to win.

  Against llama.cpp the device now generates at **40.8 tokens a second
  against 28.1**, and the gap goes from 2.0 times to 1.4. It is also past
  what llama.cpp reaches generating on this processor, 40.2, and past what
  llama.cpp reaches with its own layers off the device, 39.8. Both the
  device backend table and the fifteen per-format ratios were re-measured
  with it; every cell of the one-vector column fell and no cell of the
  eight-vector column moved, which is what says the narrow kernel is bound
  to a batch of one rather than asserting it.

- **Every format but binary32 now reaches the device's matrix instruction,
  through a second pipeline compiled from the same shader.** `Q4_0` reads a
  110-token prompt in 0.311 s against 0.469, and `Q2_K` in 0.295 against
  0.821 -- 1.5 and 2.8 times -- while the six formats that were already on
  the tile do not move: `Q8_0` 0.276 s against 0.283, `Q4_K_M` 0.284 against
  0.291, `Q5_K_M` 0.293 against 0.300. Medians of alternated rounds in one
  sitting.

  `Q4_0`, `Q4_1`, `Q5_0`, `Q5_1` and `IQ4_NL` share one shape and one branch
  between them, differing only in what is done to a nibble; `Q2_K`, `Q3_K`
  and `IQ4_XS` take a branch each. The fifteenth format, binary32, is still
  refused on purpose: the tile's operand is half precision, and a caller who
  kept a model at binary32 asked for the mantissa that would be lost.

  **Why two pipelines and not fourteen branches.** Putting the eight new
  decodes into the existing shader cost the six that were already there
  twenty-one per cent with the host refusing to dispatch them -- so with not
  one line of the new code reachable. A pipeline's registers are allocated
  for every branch compiled into it, and the occupancy that follows is the
  occupancy of every dispatch. `matrix_product.comp` is therefore compiled
  twice, once as it stands and once with `MORE_FORMATS`, and the engine binds
  whichever of the two decodes the weights it was given. The two share
  everything but the decode: the tile, the accumulators, the column loop, the
  operand loads and the store are one text.

  A shader compiled twice needed the shader tool to name its constants for
  the compiled file rather than the source. Shaders compiled once are
  unaffected, their two names agreeing. The two constants carry a digest
  each, of the same file, and a repository check requires them to agree: a
  pair that does not is one of the two compiled from a source the other has
  moved past, which the staleness check on its own cannot see.

  The cost is two SPIR-V modules in the binary rather than one, 48584 bytes
  beside 42004, and a rule no compiler enforces -- that the decode is the
  only part of `matrix_product.comp` which may differ between its two
  compilations. The tile itself is one text and cannot drift, which is why
  this is a define rather than a second file.

  `Q2_K` gained 2.8 times where the same eight-in-one-shader attempt had
  gained three per cent, and that is `Q3_K` going in with them: a "Q2_K" file
  is a mixture and much of it is `Q3_K`, so leaving that one format out had
  hidden the rest. It was the number the earlier note said to watch.

- **Half precision and brain floating point reach the device's matrix
  instruction too, and a `--repack bf16` prompt reads 0.302 s against
  1.164.** They cost nothing to add: half precision is already what the tile
  holds, and brain floating point has fewer mantissa bits than half
  precision has, so both reach the operand exactly and the decode is a copy
  or a shift. Medians of three alternated rounds, better in every one, digest
  unchanged, and the eight-bit control unmoved at 0.287 s against 0.286. A
  sixteen-bit model now reads a prompt level with the eight-bit one.

  They also settle what the tile's difference from the processor is made of.
  On the same fixtures half precision differs by 7.9e-3 and brain floating
  point by 7.9e-3, against 7.1e-3 for the eight-bit format and 7.4, 9.5 and
  8.1 for the k-quants: two formats whose weights arrive exact differ by as
  much as the ones that are unpacked, so what is measured is the
  half-precision operand and not any decode.

  **Binary32 is deliberately left out.** The tile's operand is half
  precision, so a binary32 weight would lose thirteen bits of mantissa on
  the way in, and a caller who kept a model at binary32 asked for exactly
  those bits. It stays on the row product, and the device format test holds
  it to the tight bound to prove it.

- **The five-bit k-quant reaches the device's matrix instruction too, and a
  `Q5_K_M` prompt reads 0.305 s against 1.368.** It is the four-bit decode
  with a fifth bit held in an array of its own: a byte of that array serves
  all eight sub-blocks at one position, one bit each, so the sixteen bytes
  an invocation reads are the same sixteen whichever sub-block the step is
  and only which bit changes.

  Medians of three alternated rounds, better in every one, every digest
  unchanged, and both formats already there unmoved -- 0.299 s against 0.301
  for the four-bit file and 0.286 against 0.282 for the eight-bit one.

  **The three published quantizations of this model now read a prompt on the
  device in the same tenth of a second**: 0.286 s for `Q8_0`, 0.299 for
  `Q4_K_M`, 0.305 for `Q5_K_M`, where this morning they were 0.527, 0.891
  and 1.368. The smaller file is no longer the slower one, which it had been
  since the device could read a k-quant at all.

  The device format test's tiled bound now covers four formats, which differ
  from the processor by 7.1e-3, 7.4e-3, 9.5e-3 and 8.1e-3 -- within a third
  of each other, which is what says the difference is the half-precision
  operand rather than any one decode.

- **The six-bit k-quant reaches the device's matrix instruction too, and a
  `Q4_K_M` prompt reads 0.300 s against 0.408.** A "_M" file is a mixture by
  construction: the four-bit format alone took it from 0.891 s to 0.402 and
  stopped, because a sixth of its weights are six-bit -- the output
  projection among them -- and a sixth left on the row product cost more
  than a quarter of what remained. With both it is level with the larger
  eight-bit file, 0.300 s against 0.280, where this morning it was three
  times slower.

  A step of thirty-two columns is exactly one of the eight runs the format
  is read in, and an invocation's sixteen values share one sub-block scale,
  so the scale is read once rather than per element. The word reader the
  eight-bit decode used is now shared by all three: a block of any of them
  begins two bytes into a word for every other block, and the odd case is
  shifted into place rather than read a byte at a time.

  Medians of three alternated rounds, better in every one, every digest
  unchanged, and the eight-bit path unmoved at 0.286 s against 0.282. The
  device format test's tiled bound now covers three formats, and they differ
  from the processor by 7.1e-3, 7.4e-3 and 8.1e-3 -- much the same figure,
  which is what says it is the half-precision operand rather than any one
  decode.

  What is left outside is `Q5_K`. A `Q5_K_M` file reads 1.419 s against the
  four-bit file's 0.300, because five sixths of it is a format the tile does
  not decode; tiling its six-bit sixth was worth 1.515 s to 1.419 and no
  more, which is the same arithmetic from the other end.

- **The four-bit k-quant reaches the device's matrix instruction, and a
  `Q4_K_M` prompt reads 0.402 s against 0.891.** It is the format most
  published models are shipped in, and until now none of the tile's work
  reached it. Only the decode differs from the eight-bit one -- a value is
  the scale times a nibble less a minimum, worked out in binary32 and
  rounded once into the tile -- so the two share a shader and the branch is
  on a push constant, uniform across a workgroup and taken once a step.

  Medians of three alternated rounds, better in every one, every digest
  unchanged. It costs the eight-bit path nothing (0.287 s against 0.286) and
  a generated token nothing (0.731 s against 0.725), which it has to: a
  generated token is one vector and the kernel refuses a batch shorter than
  thirty-two.

  A `Q4_K_M` file still reads its prompt slower than the larger `Q8_0` one,
  0.402 s against 0.280, because a "_M" file is a mixture and its six-bit
  tensors -- a sixth of the weights -- are still on the row product. That is
  the same shape of finding the processor's kernels reached one format
  later, and it has the same answer.

- **The device computes a batch as a matrix product now, through its own
  matrix instruction, and its 110-token prompt reads 0.280 s against
  0.527.** `VK_KHR_cooperative_matrix` at sixteen by sixteen by sixteen,
  subgroup scope, half precision in and binary32 out. A workgroup takes
  thirty-two rows and a hundred and twenty-eight vectors of the answer --
  two weight matrices against eight vector ones, sixteen accumulators held
  in registers by one subgroup from a row's first column to its last, and
  the weights decoded into two kilobytes of shared memory a block at a
  time. It replaces a row product repeated once per eight vectors, which
  read the whole matrix sixteen times for a batch of a hundred and
  twenty-eight.

  **The same instruction was built and reverted twice before**, at a
  sixteen-row output tile, where it was correct and 2.4 times slower. Three
  ablations then said what was not to blame -- the conversion was worth a
  seventh, the decode a thousandth, the batch traffic less than that -- and
  what was left was the shape of the work. This is that shape, and the four
  measurements that chose it are in `docs/measured-figures.txt`; three of
  them went the other way from the guess. The one worth repeating: bounding
  the loops by what the batch really holds costs a fifth of the speed,
  because a loop whose length is not known when it is compiled is a loop
  whose accumulators cannot stay in registers. The host rounds the batch up
  to a whole tile instead, and a fifth shader zeroes what the rounding
  invents.

  **Two things had to be true first.** The instance had asked for Vulkan
  1.0 since this program had a device at all, and a shader using the
  instruction is SPIR-V 1.6. The floor moved without the promise changing:
  `vkEnumerateInstanceVersion` is itself a 1.1 function, so a loader that
  does not export it is a 1.0 loader by definition; ask through
  `vkGetInstanceProcAddr` with no instance, request the best it answers up
  to 1.3, and fall back when `vkCreateInstance` refuses. And the
  instruction's operand is half precision and does not convert on the way
  in -- loading binary32 into a half-precision matrix reinterprets it, and
  the answers come back as not-a-number -- so the batch is copied once per
  product by a shader of its own.

  Three alternated rounds in one sitting, better in every one: **0.527 s to
  0.280** on the device's 110-token prompt, with every digest unchanged.
  Generating is untouched at 2.363 s against 2.383, and has to be: a
  generated token is one vector and the narrowest matrix the instruction
  has is sixteen. Against llama.cpp on the same host the device's prompt
  gap goes from eight times to **four**.

  Where it does not run, which is most places: fourteen of the fifteen
  formats, every row count the thirty-two-row tile does not divide, every
  batch shorter than thirty-two, every device without the extension, and
  every device whose subgroups are not sixty-four wide -- asked about
  rather than assumed. All of them go to `row_product.comp`, which reads
  all fifteen formats and needs nothing beyond Vulkan 1.0.

  Gate: 280 tests, conformance 28344 sequences with none outside tolerance.

### Fixed

- **Eight more formats were added to the device's tile and the shader got
  slower for the six that were already in it, so none of it is kept.**
  `Q4_0`, `Q4_1`, `Q5_0`, `Q5_1` and `IQ4_NL` share one shape and took one
  branch between them; `Q2_K` and `IQ4_XS` took a branch each. All fifteen
  formats pass the device format test at the tiled shape, so the decodes are
  right. `Q4_0` reads 0.358 s against 0.532 and `Q2_K` 0.813 against 0.844
  -- and `Q8_0`, the control, 0.372 against 0.285.

  It is the shader's size and not anything it runs. With the eight refused
  by the host, so that not one line of the new code can be reached, the same
  shader still reads 0.346, 0.427 and 0.350 against 0.286, 0.285 and 0.293:
  twenty-one per cent for code that never executes. A pipeline pays for every
  branch compiled into it whether or not the branch is taken.

  Fourth time occupancy has decided a device question here, and the first
  where the cause is the size of the code rather than the shape of a read.
  What it would take is a second pipeline, which means the tile existing
  twice; `docs/measured-figures.txt` has the trade and the numbers.

- **Attention's memory shape: the obvious fix built, measured and not kept,
  and a pattern this project can now state three times over.** A lane
  computes one score by walking a key in series, and a wave's sixty-four
  lanes take keys a whole cached position apart, so every step lands on
  sixty-four cache lines. Staging the tile's keys into shared memory the way
  `row_product.comp` does is correct -- the suite passes and the digest does
  not move -- and slower in every alternated pair, 0.678, 1.073, 0.771 and
  0.752 s against 0.492, 0.589, 0.579 and 0.584.

  The shared memory a workgroup takes went from two hundred and fifty-six
  bytes to sixteen and a half kilobytes, so what a workgroup processor can
  hold at once fell from dozens to three. Attention is not short of
  bandwidth -- every line a lane fetches is used sixteen times -- it is
  waiting, and what hides waiting is other workgroups.

  Three attempts now: the row product's shared window (1.399 s against
  0.516), the matrix product's staged operand (1.499 ms against 0.580), and
  this. On this part the path from the cache to the instruction beats
  anything built on top of it, and shared memory pays only where something
  is genuinely shared -- the matrix product's weight tile, read by four
  multiply-adds apiece, is the one staging here that does.

- **A strip of eight was built and is thirteen per cent slower, so it is not
  kept.** The entry below said the arithmetic around the insertion works four
  floats at a time on pipes that are eight wide. Widening the strip puts it
  in full-width registers; measured over three alternated rounds it reads
  0.881 s against 0.776, and 4.45 s of processor time against 3.82, better in
  none.

  The stack frame it doubled is not the reason -- shrinking the tables' room
  to a quarter changed nothing. What is left is that the insertion then walks
  the table twice, each pass taking half of every entry, and that is a guess
  rather than a measurement.

  It also moved a published digest: a batch of four to seven vectors no
  longer reaches a strip, goes through the single-vector kernel instead, and
  the two agree to the sweep's bound rather than bit for bit. Nothing was
  wrong; the batching was different.

  Three attempts in a row on this kernel have now measured and not been kept
  -- a fifth of its instructions removed bought two per cent of its time, the
  wider registers do not make one instruction worth two, and widening the
  arithmetic around it is slower. Its time is not set by the number of
  instructions it issues, and every lever reachable from the instruction mix
  has been tried.

- **The wider-register rewrite this file asked for one commit ago has a
  false premise, and the claim is withdrawn.** It said a
  five-hundred-and-twelve-bit dot product covers two blocks in one
  instruction and called that a reason rather than a hope. The premise is
  that a wide instruction does the work of two narrow ones in the time of
  one. Measured on this part, in a loop of eight independent dot products:
  279 G multiply-adds a second at 256 bits against 292 at 512, so one wide
  instruction is worth 1.04 to 1.13 narrow ones, and the multiply-add
  answers the same at 1.03 to 1.16. The datapath is 256 bits and the wide
  form is issued over two passes.

  The rewrite would therefore cut a third of the kernel's instructions and
  leave its floating-point work identical, on a kernel already shown not to
  be issue-bound. Not done. Two Q8_0 blocks are not contiguous either --
  thirty-four bytes apiece -- so the wide load would need two narrow ones
  and an insert.

  What the accounting points at instead is the fifteen thousand million
  instructions in the Ada around the insertion, more than the insertion's
  own sixteen, which works four floats at a time on pipes that are eight
  wide. `docs/measured-figures.txt` has the numbers and the reason it is a
  fact about this processor rather than about the instruction set.

- **The processor kernel's tenth of its own instruction's peak is explained,
  and it is arithmetic rather than a stall.** A 110-token prompt is 103.6
  thousand million multiply-adds through the strip kernel -- counted, not
  estimated -- in 13.4 thousand million cycles at one worker: 7.75 a cycle
  where a byte dot product delivers thirty-two and the part issues two a
  cycle.

  The insertion's loop body is forty instructions and eight of them are the
  byte dot product; the rest are the zeroed accumulators, the converts, the
  multiply-adds that apply the scales, two weight loads and four of loop
  control. None of it is waste: a format with a scale every thirty-two
  elements cannot convert or scale less often than that. One instruction in
  ten across the prompt is the multiply, each carries thirty-two
  multiply-adds, and 3.26 instructions a cycle then gives about ten a cycle
  before the rest of the program.

  An ablation that stubbed the insertion out said it was two per cent of the
  program, and was wrong: without it the model stops answering the prompt
  with its end token, so that run generated twelve tokens the reference did
  not. A counter in the panel loop replaced it. Nothing was changed; the
  measurement is in `docs/measured-figures.txt` and under
  `### A tenth of the instruction's peak`.

- **Two comment lines that did not fit the width the rest of the file
  keeps.** No token of the program changed. It is recorded because the
  figure fingerprints name the file the comment is in and cannot tell a
  comment from a kernel, so the stale groups are answered in
  `docs/measured-figures.txt` rather than re-stamped in silence.

- **The column split was built, priced and not kept -- and the estimate that
  led to it was wrong.** The entry below named it as the only lever left and
  put it at about 1.2 times on the products, a tenth of a prompt. Measured:
  two and a half to five per cent on the three wide shapes and forty-four
  per cent on the narrow one, which is the projection that was eight
  workgroups and is now sixty-four.

  What the estimate left out is the summing pass. Splitting multiplies the
  output traffic, so at split two a pair of five-thousand-row projections is
  seventeen megabytes a layer that did not exist before, and on a wide
  product the pass costs what the split saves. On the narrow one, where the
  slices are small, split eight with the pass included reads 0.200 ms
  against 0.323 -- 1.6 times.

  Applying it only where it pays is K and V twice a layer, 5.4 ms over
  twenty-two layers against a prompt of 177: three per cent, below the five
  a whole-prompt measurement resolves here, so it cannot be shown in place.
  Against that: a result buffer sized by the split, a fifth pipeline, a
  reduction shader, another barrier and a rule for choosing the split. The
  prototype is not kept and the measurement is.

  The partial sums are added by a pass in a fixed order rather than by
  atomics, which is worth saying because atomics are the obvious way and the
  wrong one here: an atomic add makes the answer depend on which workgroup
  finished first, and a digest in this project is meant to be a property of
  the model rather than of the run.

- **Four attempts at the device's matrix kernel, and the measurement is all
  that is kept.** The product is fifty-eight per cent of a device prompt, so
  it is where a gain has to come from. Ablations that halve an operand's
  loads or remove fifteen of sixteen multiply-adds put the operands at about
  half the kernel's time and the arithmetic at the other half.

  What it is short of is workgroups. The same kernel against row counts that
  change nothing else reads 890 GFLOP/s at sixteen workgroups, 2694 at
  sixty-four, 3238 at two hundred and fifty-six and 3723 at a thousand -- and
  a two-thousand-row matrix, which is most of this model, is sixty-four of
  them on twelve compute units.

  Tried and all worse than the 0.564 ms it stands at: pinning either operand
  to one address, a squarer sixty-four by sixty-four tile that halves the
  loads per multiply-add (0.850 ms), four smaller tiles for more workgroups
  (0.670 to 1.081), and staging the batch tile in shared memory (1.499). The
  last is the standard shape of a matrix kernel and is two and a half times
  worse here, because with one wave to a workgroup there is nobody to share
  the staged tile with.

  The one thing that did measure better is not worth taking: a
  sixteen-by-sixty-four tile reads 0.241 ms against 0.358 on the narrow K and
  V projections, about three per cent of a prompt for a second pipeline. What
  is left is named and not built -- splitting the columns across workgroups,
  priced by the scan at about 1.2 times on the products.

- **Where a device prompt's time goes was a guess, and one of the two
  guesses was wrong.** The scratch harness says this model's matrix products
  are about 0.124 s in isolation and the prompt reads 0.28, so this file had
  written down two suspects for the rest: the eighty-eight of a prompt's
  hundred and fifty-four products that go one to a submission with a fence
  wait each, and the narrow K and V projections at 403 GFLOP/s against 1845
  for the wide ones.

  The instrument mattered more than the answer. Skipping a kernel and taking
  the difference does not work when the kernels feed each other -- three of
  six ablations came out *slower* than the run with everything in it.
  Doubling works: these kernels write rather than accumulate, so dispatching
  one twice with the same inputs leaves the same answers and costs exactly
  its own time again, and the submission count does not move.

  Against a baseline of 0.177 s inside submit-and-wait, minimum of five runs
  at a load below 1.00: the matrix product is 0.103 s (58 %), attention
  0.032 s (18 %), recording and submitting the whole prompt 0.020 s (11 %),
  and the half-precision copy, the blend and the row product 0.007 s between
  them. **Two hundred empty submissions cost 0.020 s** -- a tenth of a
  millisecond each, against the 0.6 to 2.3 ms this file used to bracket a
  round trip at, which was arithmetic on a guess. That suspect is dead, and
  the second is worth five per cent rather than the share its rate implied.

  Nothing was changed and the instrument is reverted; what is kept is the
  measurement, in `docs/measured-figures.txt` and under
  `### The matrix instruction`.

- **The matrix product had been committed with a gate that could not enter
  it.** The conformance sweep's longest sequence is eight tokens, and the
  device format test multiplied twelve rows against a batch of ten; the
  kernel refuses a row count its thirty-two-row tile does not divide and a
  batch shorter than thirty-two, so it refused both. Every check it passed
  was a check of the shader beside it.

  The device format test now runs its fifteen formats twice, the second time
  at sixty-four rows and a batch of forty: the two tiled formats go through
  the matrix product and the other thirteen go through the row product at a
  larger shape than they had. The two are held to different bounds because
  they differ by different amounts, and both are measured rather than
  guessed -- at most 2.1e-5 between the row product and the processor,
  against 7.1e-3 for the eight-bit tile and 7.4e-3 for the four-bit one,
  which is three hundred times as much and is the price of a half-precision
  operand.

- **A test was intermittent because it let the sampler decide how much work
  the run did.** `Device_Memory_Reaches_The_Device` gives the device a four
  kilobyte budget, a model far larger than that, and asserts that at least
  one matrix was given back. It failed twice during this work's gate runs
  and passed on re-run both times, on binaries that were correct.

  The command it ran named no seed and no temperature, so sampling was
  random. About one run in fourteen the first token drawn was the
  end-of-sequence token: generation stopped before it began, the run did
  only the prompt, no matrix was ever evicted, and the assertion was right
  about what it read and wrong about what it meant. The failing run says so
  in its own statistics -- `generated tokens 0`, `stopped because the model
  produced its end-of-sequence token` -- two fields nothing was reading.

  The run is now greedy and from a fixed seed, and the test asserts that two
  tokens were generated before it reads how many matrices came back, so a
  future change that shortens the run is caught as itself rather than
  quietly making the eviction assertion vacuous. Measured: eleven of a
  hundred and fifty unpinned runs gave nothing back; eighty of eighty pinned
  ones gave two tokens and two matrices back, and three gate runs are clean
  at 280 tests. Nothing outside the test changed, so no measured figure can
  have moved.

- **No insertion advances an operand any more.** Yesterday's six-bit kernel
  raised inside a worker because it did, and adding an exception handler and
  nothing else made it run -- the signature of code generation rather than
  arithmetic. Two kernels were fixed then; four were left, all of them
  working at the time and all of them having passed gates, including
  `Rows_Singly`, which every generated eight-bit token runs and which
  advanced *four* operands -- more than the one that failed.

  All six now keep their cursors in registers of their own, named in the
  clobber list, and copy a counter rather than decrementing it in place.
  Three alternated rounds on both models say it costs nothing -- 2.086 s
  against 2.085 generating the eight-bit file, 0.765 against 0.767 on its
  prompt, 0.362 against 0.357 generating the four-bit one, every digest
  unchanged -- and `Rows_Singly` is one instruction a block shorter, three
  pointer advances having become two.

- **Sixteen per cent of a prompt was `memset`.** The strip kernel's first
  working version gave three of its arrays `[others => 0.0]`, which is
  sixty-four kilobytes zeroed for every strip of four vectors and every
  entry of it written by the loop that follows. The instruction count barely
  noticed -- `rep stos` moves sixty-four bytes an instruction -- and nothing
  in the source reads as expensive. `perf report` named it on the first run.

- **The claim that the prompt gap is stalls was wrong, and a counter says
  so.** `perf_event_paranoid` was 4 on the machine every figure here comes
  from, so nothing in this project had ever seen a cycle counter; a commit
  message and a README paragraph both asserted the processor was losing to
  stalls at 0.7 instructions a cycle against another runtime's 2.5. Both
  figures were arithmetic on a guessed instruction count.

  Measured: **3.40 instructions a cycle**, a 1.3 per cent cache miss rate,
  1.9 per cent of cycles stalled at the front end. It is not stalling. What
  the prompt costs is instructions -- about ninety-three thousand million for
  something near a hundred and ten thousand million multiply-accumulates,
  twenty-odd instructions for each one that multiplies. Seventy-two thousand
  million now, at 2.87 a cycle: the counter is the thing that made each of
  those steps decidable.

  The README now carries that correction under its own heading rather than
  quietly restating the number.

- **Every figure group names the third compilation and the flag reader that
  chooses it.** `tests check` guards seven groups of published figures with a
  fingerprint over the sources they depend on, and none of the seven named
  `model_runner-quantization-integers-deep.ads` -- the instantiation built
  for `x86-64-v4` -- or the platform body whose answer decides whether a run
  enters it. Either could have been changed, and with it every processor
  figure in the README, with the gate saying nothing. That is the fourth such
  hole found by looking; the previous three were the default batch size, the
  row-tile constant and the integer kernel itself.

### Changed

- **Attention works out each exponential once instead of a hundred and
  twenty-eight times.** Per tile of sixty-four cached positions every lane
  worked out `exp(score - raised)` for every score in order to sum them, and
  again for every score for every component of the value: eight thousand
  exponentials a tile where sixty-four are distinct. Each lane now works out
  its own and puts it back in the shared tile, at the cost of two barriers.

  Priced by dispatching attention twice and taking the difference, minimum of
  four runs: 0.0318 s against 0.0336, so five per cent of attention and one
  per cent of a prompt. The whole device prompt reads 0.287 s against 0.293
  over three alternated rounds, inside the floor, and the digest did not
  move.

  The five per cent is not the finding. A hundred and twenty-eight-fold
  redundancy in a transcendental function being worth a twentieth of the
  kernel says the kernel is waiting for something else, and
  `docs/measured-figures.txt` names what that probably is.

- **The weight scales were decoded once for every strip of the batch, and
  are worked out once for the call now: a `Q4_K_M` prompt on the processor
  reads 0.875 s against 1.046.** A batch is swept four vectors at a time, so
  a 110-token prompt is twenty-eight strips, and each of them decoded the
  same scales again -- one half-precision number a row and block for the
  eight-bit format, and for the k-quants that plus twelve bytes of six-bit
  fields unpacked into eight scales and eight minimums, or sixteen signed
  sub-block scales.

  Medians of three alternated rounds, better in every round for the two
  k-quants, every digest unchanged: `Q4_K_M` 1.046 s to 0.875, `Q5_K_M`
  1.077 to 0.882, `Q8_0` 0.815 to 0.792. A generated token is untouched,
  2.240 s against 2.233 for sixty-four, because it goes through a kernel
  with no strips in it.

  The eight-bit format's counter is the honest measure of the whole change:
  54.9 thousand million instructions became 43.5 and 14.72 thousand million
  cycles became 14.45 -- a fifth of the work removed bought two per cent of
  the time, which says that kernel was never issue-bound. The k-quants did
  not have a few more instructions but several times as many, and there the
  same removal is worth a fifth of the prompt.

  Found by profiling rather than by reading, though it was visible in the
  source from the day the strip kernel was written: a decode inside a loop
  whose caller loops over strips. `Sub_Block_Scale` is at body scope now
  instead of copied into four kernels.

- **The five-bit k-quant has both kernels, which completes what a "_M" file
  is made of.** `Q5_K` is `Q4_K` with a bit taken out of every quant and
  kept apart -- the same two scales, the same twelve packed six-bit scale
  and minimum pairs, then thirty-two bytes carrying the fifth bit of all two
  hundred and fifty-six elements, then the nibbles -- so both of the
  four-bit format's insertions applied as they stood and the only question
  was the cost of putting that bit back.

  Three instructions a sub-block and one constant register. A word shift
  brings the wanted bit to bit four of its own byte, a mask of one in
  sixteen per byte drops what the shift dragged in from the neighbour, and
  an or puts it on the nibble; the quant is then zero to thirty-one, which
  is still what the byte dot product's unsigned operand wants, so nothing
  around the instruction changes. Forty-eight instructions a block against
  the two hundred and fifty-six the multiply-adds spend.

  TinyLlama Q5_K_M, medians of three alternated rounds, better in every
  round: the 110-token prompt **4.193 s to 1.061** (29.09 s of processor
  time to 5.73), thirty-two generated **3.330 s to 1.241** (19.45 s to
  4.32). The digest is the same in all twelve runs -- `cbf29ce484222325` for
  the prompt and `0a1a63f0305d35d6` for the generated tokens -- because as
  with the four-bit format the integer sums are exact either way and the
  rounding falls in the same places.

  The conformance sweep is unchanged at 28344 sequences, none outside
  tolerance. Four of the fifteen formats have an integer kernel now.

- **A generated token of the six-bit k-quant has a kernel, and that was the
  last floating-point path in a "_M" file.** A profile put the unpacking and
  the floating-point dot product together at forty-one per cent of a Q4_K_M
  token. Thirty-two generated tokens go from **0.505 s to 0.356**, medians
  of three alternated rounds, with the same digest and the prompt unmoved:
  thirty-five milliseconds a token where the eight-bit file takes
  thirty-three, so a file two thirds the size now generates at the same
  rate.

- **Fixed, in the two single-vector kernels written today: an insertion must
  not advance the operands it is given.** They did -- an `addq` on a
  register the compiler was told is an input -- which says nothing to it and
  happens to work while it has no other use for the register. With eleven
  operands it stopped happening to work: the six-bit kernel raised inside a
  worker, and adding an exception handler and nothing else made it run,
  which is the signature of code generation rather than arithmetic. Both now
  keep their cursors in registers of their own, named in the clobber list.
  The four-bit one had the same latent fault and had passed a gate.

- **The six-bit k-quant has one too, because a file is a mixture.** Giving
  Q4_K a kernel stopped short of what it should have been worth, and a
  profile said why: `accumulate_dot`, the floating-point row product, was
  44.7 per cent of what remained, beside the new kernel's 43.6. Reading the
  file's tensor table explains it -- a `_M` file keeps its output projection
  and a few other tensors at six bits, so TinyLlama Q4_K_M is 21 tensors and
  16.9 per cent of its weights Q6_K, and that sixth was costing half the
  prompt.

  Three things differ from the four-bit kernel. A quant is six bits in two
  places, so assembling thirty-two is five instructions rather than two. A
  scale covers sixteen elements where an activation block covers thirty-two
  -- and the instruction makes that free, because it sums four bytes into
  each of eight lanes, so the two halves are already apart when the sums
  arrive: two masked multiply-adds, one per half of the register. And the
  quants go in unsigned, without the thirty-two the format subtracts, which
  needs the activation summed over each sixteen rather than each thirty-two
  and so is summed here rather than read from `Totals`.

  The 110-token prompt goes from **1.355 s to 0.990** and from 8.29 seconds
  of processor time to 5.47, medians of three alternated rounds, with the
  same digest and generating unmoved. End to end, this file read that prompt
  in **4.598 s** before today: four and a half times.

- **And a generated token of the four-bit k-quant has one too.** The
  eight-bit format's generated token is bound by the memory path -- it stops
  getting faster at four workers, and no kernel helps a token that is
  waiting. This one was not waiting, and the worker sweep said so before
  anything was written: 1.510 s at two shares, 1.130 at four, 0.993 at
  seven, still improving where the eight-bit format is flat past four,
  because the floating-point path it was taking spends its time unpacking
  and multiplying rather than fetching.

  Thirty-two generated tokens go from **0.938 s to 0.505** and from 6.33
  seconds of processor time to 2.81, medians of three alternated rounds,
  with the same digest and the prompt beside it unmoved. Fifty milliseconds
  a token against eighty-four, where the eight-bit format takes thirty-three.

  The kernel is the single-vector shape the eight-bit format already had,
  with the three differences the batch kernel records: a nibble needs no
  bias, one read serves two sub-blocks, and the minimum's term is the
  sub-block's activation total taken out once at the end of a row.

- **The four-bit k-quant has an integer kernel.** Every kernel of the last
  three days served Q8_0 and Q8_0 alone, and `Q4_K` -- which is what most
  published models are actually stored in -- took the floating-point path
  for every product it ever did. The same model in the smaller file read a
  prompt seven and a half times slower than in the larger one.

  It needed no new idea. A four-bit quant is zero to fifteen, which is
  already the unsigned operand `VPDPBUSD` wants, so unlike the eight-bit
  format it needs no bias and no bias correction. One thirty-two byte read
  serves two sub-blocks, the low nibbles and the high, which is the pairing
  the decoder beside it already uses. And the correction it does need -- a
  value is a scale times the quant less a minimum -- is the sub-block's
  activation total, which is the `Totals` table this kernel has been handed
  since the byte product was written and which its own note says was "put
  there for the formats that carry a minimum and unread for this one".

  The 110-token prompt goes from **4.598 s to 1.317 s** and from 31.67
  seconds of processor time to 8.19, medians of three alternated rounds,
  better in every one. **The digest is identical in all six runs**: the
  integer sums are exact either way and the rounding falls in the same
  places.

  A strip of four vectors and nothing else: a generated token and a host
  without the byte dot product both go back where they went before. What had
  to be added for them is a question the caller asks first -- whether a
  product of this format and this many vectors will actually use the
  quantized activations -- because quantizing for a product that then
  declines is the whole cost of the packing and none of its benefit, and it
  measured forty per cent of a generated token before the question existed.

- **The device's matrix instruction, built and not kept.** This device
  offers `VK_KHR_cooperative_matrix` at sixteen by sixteen by sixteen,
  subgroup scope, for half-precision and for signed bytes. The Vulkan 1.0
  floor turned out not to stand in the way -- `vkEnumerateInstanceVersion`
  is itself a 1.1 function, so a loader without it is a 1.0 loader by
  definition, and asking for the best it answers keeps every host that ran
  before. The negotiation, the feature through the `pNext` chain, the shape
  read back and checked, and a matrix-product shader were all written.

  **Correct, and twice as slow**: the twelve-token run answers
  `5abff916f9d83ca6` like every other path in this program, and the
  110-token device prompt reads 1.210 s against 0.515 for the shader it
  would replace.

  Three things were then measured and two of them were nothing. Converting
  the batch once, in a pass of its own before any product runs -- rather
  than in each of the hundred and twenty-eight workgroups that cover a
  two-thousand-row matrix -- takes it to **1.037 s**, fourteen per cent.
  Decoding four quants out of a word rather than one out of a byte, which
  was worth sixteen per cent in the shader beside it, takes it to 1.024.
  Ablating the operand read to a single address, so the batch traffic is
  perfectly cached and wrong, takes it to 1.018.

  So it is not the conversion, not the decode, and not the re-reading of the
  batch. What is left is the shape: a sixteen-row output tile means a
  hundred and twenty-eight workgroups of one subgroup on a part that runs
  five hundred waves for the row product. A square tile with several
  accumulators to a side is a real matrix-multiply kernel and not this one.
  All of it is reverted; the measurement is what is kept, and it now says
  which three things are not the answer.

- **A tile is written the way the target is laid out.** `Mat_Mul_Range_Packed`
  copied each tile of answers back in the order the tile is laid out -- a row
  at a time, the vectors inside -- where the target keeps a whole vector's
  answers together. Every step of the inner loop moved a row count along:
  eight kilobytes between consecutive writes on a two-thousand-row tensor.
  Turning the two loops about takes that procedure from **5.1 per cent of a
  prompt to 2.1** and the prompt from **0.777 s to 0.744**, three rounds
  alternated. Two lines, and no digest moves.

- **Unrolling the strip kernel's block loop, measured and not taken.** Four
  instructions of overhead a block serve eight row-vector pairs, and a
  profile put them at twenty-one per cent of that kernel's samples. Two
  blocks a turn halves them and the instruction count agrees -- 54.03
  thousand million against 54.79 -- but the alternated rounds say it is
  **slower**, 0.756 s against 0.738, better in none of three. The twenty-one
  per cent was skid onto the branch from the loads it waits for.

- **Attention had never been told its bounds were proved.** `Blend_Exact`
  and the two blends beside it were the only loops in the engine's own
  arithmetic without the suppressions the row kernels carry, and a profile
  said what that cost: fifty-four per cent of the procedure on 64-bit moves,
  twenty on `jo` -- the overflow branch after every index -- and not one
  multiply among its ten hottest instructions.

  Overflow checking is off in all three now, which drops the check that an
  index computation wraps and keeps the check that the index is inside the
  array. And in `Blend_Exact`, bounds checking too, after proving the ranges
  the way the row kernels prove theirs: every index it forms is a fixed
  function of the loop bounds, so the largest of each is computed at entry
  and compared against the array it will index, and a call that would step
  outside is refused through `Ok`.

  Attending falls from **0.074 s of a 110-token prompt to 0.039**, 8.9 per
  cent of it to 5.3, and the instruction count from 62.0 thousand million to
  **54.7**. No answer changes.

- **The weight scale is widened by the instruction that widens it.** Ada has
  no half-precision type, so the portable widening reads the two bytes as
  bits and computes both the normal and the subnormal answer before
  selecting -- about sixteen instructions, and unrecognisable to the
  compiler as a conversion. Both wider compilations are built for
  instruction sets with F16C, whose `VCVTPH2PS` does it in one instruction
  and exactly. A two-instruction insertion where the kernel reads a scale
  took the prompt from 64.8 thousand million instructions to **62.0**, and
  the quantized path from 4.44 times the floating-point one to 4.71 with a
  vector a pass. The baseline compilation keeps the portable form.

- **A product of one vector asks for four shares, and only those wake.**
  A generated token reads every weight once and multiplies it once, so it is
  the memory path that answers: measured over three rounds, sixty-four
  tokens take 2.303 s at three shares, 2.123 at four, 2.144 at five and
  2.187 at eight, for 6.3, 7.3, 8.7 and 12.7 seconds of processor time.
  Eight is both the slowest and the dearest. A prompt is the opposite and
  keeps every share.

  Cutting the team alone was not enough: `Coordinator.Post` bumped a
  generation counter that opened every worker's barrier whatever the job
  asked for, so the idle four still cost the wake -- a quarter less
  processor time for three per cent more wall. The barrier now tests the
  team, and `Post` counts only the workers it opens for.

  Sixty-four generated tokens go from **2.196 s to 2.102** and from **12.64
  seconds of processor time to 7.17**, three rounds alternated, better in
  every one. Against llama.cpp the processor's generating row goes from 27.6
  to **29.8 tokens a second**, the first thing to move it since the
  arithmetic changed. No digest moves.

  **The arithmetic decides this, not the vector count**, and a second
  measurement found it: asked before `Prepare_Packed`, the smaller team
  reaches the floating-point path too, which does four times the arithmetic
  on the same bytes and is not memory-bound -- twelve tokens at `--arith
  f32` measured 1.806 s against 1.365. The team is chosen after the
  arithmetic is known.

- **Four accumulators in the attention score loop, measured and not taken.**
  The loop is a floating-point sum reduction, which GNAT will not vectorise
  without fast-math; four partial sums would let it. Written and measured at
  **55.1 thousand million instructions against 54.7** -- worse, because GNAT
  kept the four in memory rather than a register -- and it would have moved
  a digest for the privilege.

- **A prompt runs the kernel a generated token already had.** The
  single-vector path keeps a row's accumulator in a register from its first
  block to its last, reads the weight bytes where the file holds them and
  biases them in flight, and takes the whole bias correction out once at the
  end. A batch could have none of that while it kept an accumulator for
  every row and every vector at once -- eight rows against a hundred and
  twenty-eight vectors is a thousand of them.

  A **strip** of four vectors against a panel of two rows is eight
  accumulators, and `-march=x86-64-v4` has thirty-two registers to hold
  them, so the batch is swept a strip at a time and every one of those
  things becomes possible for it too. Per row, vector and block: five
  instructions against twelve and a half, with the scale broadcast out of
  memory by the fused multiply-add itself rather than by an instruction
  before it. No panel is packed and none is needed -- two rows of this model
  are under five kilobytes, so the order of the loops is the packing.

  The 110-token prompt goes from **1.093 s to 0.847 s**, medians of three
  alternated rounds, better in every one; instructions 72.0 to **64.8**
  thousand million and cycles 25.1 to **16.1**, which is four instructions a
  cycle against 2.87. Against llama.cpp the processor's prompt goes from
  99.0 to **137.5 tokens a second** and the gap from 3.8 times to **2.8**.
  Generating does not move: 2.185 s against 2.190.

  The generated tokens hash to `448c2ed68ec342ee` where they said
  `1cb5fffbb21399ad`. A strip keeps the byte instruction's eight lanes where
  the kernel it replaces folded them into four, and that fold was what made
  the byte path agree with the sixteen-bit one on this model -- a
  coincidence the README already said was not promised. Two weak signs point
  the other way: each accumulator now carries half the magnitude, and the
  digests it lands on are the ones `--arith f32` and the device backend
  already produce.

- **Four rows of the integer product go into one machine code insertion.**
  The byte dot product is one instruction; the loop around it was not.
  Reading the code the compiler produced for a single row, eighteen
  instructions went by for the one that multiplied, and the other seventeen
  were the activation block loaded again, the bias correction loaded again,
  four pointers advanced and a branch -- every one of them the same for
  every row of a tile. Four rows written as one insertion load them once and
  hold them: fifty instructions for the group rather than seventy-two.

  The 110-token prompt goes from **89.9 to 72.0 thousand million
  instructions**, a fifth fewer, and from 1.163 s to **1.092 s**, medians of
  three alternated rounds. Generating does not move -- 2.192 s against 2.195
  -- and was not expected to: a generated token is one vector, and one vector
  spends its time fetching weights rather than issuing instructions. The
  instruction count is what settles it, because unlike a time it does not
  vary between runs.

  Against llama.cpp on the same file, the processor's prompt goes from 92.2
  to **99.0 tokens a second** and the gap from 4.2 to **3.8 times**.

- **The device's prompt was measured and left alone.** Its shader already
  reads each weight once for the eight vectors an invocation carries; what
  it re-reads is the activations, which lie a row apart. Building it with
  that read replaced by a single address takes the 110-token device prompt
  from 0.516 s to 0.394, so they are about a quarter of it. Two ways of
  removing them were built and both are worse: a window of the activations
  staged in shared memory measures **1.399 s**, because two barriers a
  window is sixteen a row on a part where barriers are dearer than reads;
  and turning the batch so those eight values are consecutive measures
  **0.746 s**, because a lane reads thirty-two consecutive columns of one
  vector and the turn trades that contiguity for a shorter one. The ablation
  had measured removing seven eighths of the loads, not their scatter.

- **A generated token stops getting faster at four shares.** That it is
  bound by the memory path rather than the arithmetic had only ever been
  inferred from a ratio. Varying the worker count says it: sixty-four tokens
  take 2.303 s at three shares, 2.123 at four, 2.144 at five and 2.187 at
  eight, for 6.3, 7.3, 8.7 and 12.7 seconds of processor time -- eight is
  both the slowest and the dearest. A prompt is the opposite and wants every
  share, 0.815 s at eight against 1.051 at four. Cutting a one-vector job to
  four shares was written and measured and is **not** in this release: the
  processor time fell a quarter but the wall rose three per cent, because
  the pool wakes every worker whatever the job asks for. Doing it properly
  needs the coordinator to wake only the team.

- **Eight lanes were re-measured and not taken, and the earlier reading of
  them was wrong.** The insertion folds the instruction's eight integer lanes
  into four before scaling them, which costs a `vextracti128` and a `vpaddd`
  a row. Keeping eight removes both and is faster -- 65.4 thousand million
  instructions against 72.0, and 1.022 s against 1.092 over three alternated
  rounds -- but it changes what the model says, because the fold is what
  makes each float accumulator receive an exact wider integer sum. The byte
  path agrees with both sixteen-bit compilations on this model today; the
  README says that agreement is not promised, and it is still worth more than
  six per cent. `docs/measured-figures.txt` carries the numbers so the choice
  can be reversed.

  The reading before this one said eight lanes were *slower*, and it was
  measuring a bug: the lane array carried `Alignment => 32` on sixteen bytes
  of data, so GNAT padded every entry out to thirty-two while the insertion
  walked them with a stride of sixteen. It produced wrong answers rather than
  slow ones. The test that compares the three compilations caught it; the
  conformance sweep did not, and would not -- a tolerance wide enough for a
  different rounding is wide enough for some wrong sums as well.

- **The activations are read where the quantizer left them.** The byte
  instruction's memory operand needs no alignment, so copying a block of them
  into an aligned buffer first was thirty-two moves shared between eight rows
  -- about four instructions for every multiply-add. Removing it takes the
  instruction count from 96.3 to 93.2 thousand million and about five per
  cent off a prompt: 1.191 s against 1.251, better in two rounds of three.
  The instruction count is what settles it, since it does not vary between
  runs the way a time does.


- **The device shader decodes four weights out of a word.** It read its
  weights from a buffer bound as words and extracted every byte by hand --
  about seven operations a weight, against the eight fused multiply-adds it
  then did with each one. Reading a word and sign-extending four bytes out of
  it with shifts is exact and costs about two.

  | device | before | after |
  | --- | ---: | ---: |
  | 110-token prompt | 0.540 s | **0.507 s** |
  | 64 generated | 2.114 s | **2.015 s** |

  Better in every one of three alternated rounds on both, with the digests
  unchanged -- the same arithmetic reached by fewer instructions, so an
  unchanged digest is the check that the sign extension is right.

  **The first version of it measured sixteen per cent worse**, at 0.628 s
  against 0.543. It returned the four decoded bytes as an `ivec4` from a
  helper; the same four expressions written inline at the point of use are
  the table above. A vector returned across a call is a vector the compiler
  puts in memory, and counting instructions would never have found it -- the
  two versions have the same arithmetic and nearly the same instruction
  count.

  The ceiling was measured before the work rather than assumed: with the
  decode replaced by a constant the prompt reads 0.427 s, so unpacking was
  about a quarter of the shader. Rather less than that quarter came back.

  Not done, and recorded so it is not reached for first: this device offers
  `VK_KHR_8bit_storage`, and binding the weights as bytes would remove the
  extraction outright -- at the cost of an instance extension, a device
  extension, and a features struct threaded through the `pNext` chain at
  device creation. The shader-side fix took most of the same ground for none
  of that.


- **A generated token's block loop lives inside the insertion**, so the
  accumulator is a register from a row's first block to its last rather than
  something loaded and stored at every one of them. Sixty-four tokens in
  **2.187 s against 2.400**, better in each of three alternated rounds and
  steady to a hundredth of a second.

  About eleven instructions a block become seven: the load and the store go,
  and a fused multiply-add replaces a separate multiply and add.

  It is only for one vector, and the reason is arithmetic about registers. A
  token multiplies one vector, so the accumulators are one a row -- four of
  them. A prompt multiplies a hundred and twenty-eight, which is a thousand
  accumulator sets against sixteen registers; holding those means re-reading
  the weights once per vector tile, sixteen passes over a gigabyte, unless
  the weights are packed into cache-sized panels first. That packing is the
  remaining work and is not here.

  The prompt's readings across the same six runs are the useful accident:
  1.192 to 1.300 s while never entering the path. That is a control nobody
  set up, and it puts this machine's noise floor at about five per cent --
  the size of several changes measured today, and why single readings keep
  being wrong here.


- **A third compilation of the integer kernel, through the byte dot
  product.** `VPDPBUSD` multiplies four eight-bit pairs into a lane where the
  other two compilations multiply two sixteen-bit ones, and no `-march` makes
  the compiler reach it, so it goes in as a machine code insertion. With it
  the weights are never widened -- they are the bytes the file holds -- which
  is the unpack loop gone and half the operand traffic besides.

  | | 110-token prompt | 64 generated |
  |---|---:|---:|
  | the sixteen-bit product | 1.271 s | 2.496 s |
  | the byte dot product | **1.222 s** | **2.354 s** |

  Medians of three alternated rounds, better in every one.

  The instruction is unsigned against signed, so the weight byte is biased by
  128 and the bias taken back out with the activation block's own sum -- the
  `Totals` table this kernel is already handed and does not otherwise read.
  **Where that correction went decided everything.** As a scalar
  read-modify-write in the innermost loop it cost fifteen per cent of a
  prompt, more than the instruction saved; built once a block as a vector and
  added inside the insertion as one integer add, it is the table above. Same
  instruction, same arithmetic, different place to put four bytes.

  **This is the first change whose answer depends on the host's instruction
  set.** The two sixteen-bit compilations still agree bit for bit and their
  test still asserts it. The byte one groups a block's products differently
  into its lanes, so the rounding falls elsewhere when they are scaled; it is
  held to the five per cent the conformance sweep already states for the
  quantized path, and the test says so with the reason written into it. A
  caller who needs a run reproducible across hosts of different instruction
  sets should ask for `--arith f32`.


- **A row is computed by eight invocations of the shader rather than one**,
  which is worth **twenty-nine per cent of a generated token** on the device:
  2.099 s for sixty-four against 2.973, better in each of three alternated
  rounds and steadier than the row it replaces by an order. The device now
  wins the short run outright -- 0.445 s against the processor's 0.541 --
  where it had been behind on everything but the long prompt.

  It was nearly thrown away. On a prompt the change is a wash: 0.531 s at one
  lane a row against 0.537 at eight, 0.545 at four, 0.564 at two, which is
  inside the spread. Only measuring the case it was argued for saved it.

  And the argument that motivated it was not the one that made it work. One
  invocation a row has a wave's lanes reading a byte each from addresses a
  row apart -- sixty-four transactions for what fits in one -- so this was
  written for coalescing. What it actually buys is occupancy: a 2048-row
  product at 256 invocations a group is eight workgroups and this part has
  twelve compute units, so a third of it idled for every token. A prompt is
  sixteen dispatches deep and hides that; a token is one dispatch and does
  not. Eight lanes makes the same work sixty-four workgroups.

  An earlier shape of the idea was measured and dropped: dividing inside a
  block, each lane taking every eighth element, has all eight lanes decode
  the same scale for an eighth of the multiplies each -- 0.603 s against
  0.520. Dividing by block keeps that work done once. And the reduction is
  through shared memory rather than a subgroup add, though this device offers
  clustered arithmetic: that needs SPIR-V 1.3 and so a Vulkan 1.1 instance,
  and this program asks for 1.0.

### Added

- **The budget covers a generated token as well as a batch.** `--budget`
  reported only the batched path, so asking it about a run of sixty-four
  tokens described the six-token prompt in front of them. The single-token
  evaluator carries the same marks now, and the phases mean the same thing in
  both -- which is the point, since a token and a prompt divide their time
  very differently and measuring them the same way is the only way to see it.

  Sixty-four tokens on the device: feeding 1.495 s, projecting 0.369,
  attending 0.285, reading out 0.110, everything else 0.047, accounting for
  2.304 s of a 2.390 s run.

  **The products are eighty-one per cent of it and they run at about 33 to 36
  gigabytes a second, against a part that can do near ninety.** A layer's
  feed-forward is 1062 microseconds a token for 34.6 million weights and its
  projections 262 for 5.2 million -- within a tenth of each other per weight,
  and their four-to-one ratio is their weight ratio. There is no outlier to
  attack.

  Attending reads 12.4 per cent where a prompt spends 6.2, and that is not
  what it looks like either: `Attend_And_Project` sends attention and the
  matrix reading its blend as one submission, so most of it is a
  four-megabyte product. What remains is about a hundred microseconds a
  submission, and collapsing those is the change already recorded as slower.

  So a generated token on the device is where a prompt on the processor is:
  the arithmetic is arranged about as well as this program knows how, and
  what is left is that the products do not reach the speed the memory could
  feed them.


- **A run can say where a prompt's time went.** `tests speed --budget` asks
  the session to keep account of itself and reports the phases as each run
  ends: normalizing, projecting, rotating, attending, feeding, joining,
  reading out. Off unless asked -- the clock is read once at each boundary,
  about a hundred and fifty reads for a batch of a hundred and ten, and a run
  nobody asked should not pay even that.

  The token budget under `tests benchmark` is a model: it multiplies the
  shapes a model has and adds the pieces up, and it says in its own output
  that attention is not among them. That is tolerable for a token and not for
  a prompt, where attention is the term that grows with the context and
  everything else is linear in it.

  On a 110-token prompt the run takes 1.260 s and the phases account for
  1.259 of it. The products are 89.3 per cent, the feed-forward is 3.4 times
  the attention projections -- against 3.7 times the weights, so the two are
  within a tenth of each other per weight -- and attention is 6.2 per cent,
  where it is about a third of a generated token.

  It was built to find a missing 54 per cent that turned out not to exist.
  An ablation had put the multiply-adds at 39 per cent of a prompt and the
  unpack at 7, and the remainder was written up as unaccounted for; what the
  ablation actually measured was the product's inner loop against the whole
  run, leaving the rest of the product's own work out of the total. A
  difference between two builds is not a share of a run.

### Fixed

- **Every figure group names the integer kernel now, and none of them did.**
  Not one of the seven source lists in `docs/measured-figures.txt` held
  `model_runner-quantization-integers.adb` or any of its children -- and that
  is the arithmetic every processor figure in the file is measured through,
  since `--arith int8` became the default. The kernel could be rewritten,
  and was, with nothing asking for a re-measure.

  Third time in two days. The default batch lived in a file no group named;
  the rows a tile takes was a constant no fingerprint could cover; now the
  kernel itself. What the three have in common is that a fingerprint follows
  what a figure is *computed by* and keeps missing what it is *decided by*.

### Changed

- **The block product goes through a machine code insertion.** The eight
  partial sums a sixteen-bit multiply-add leaves were reduced to a scalar at
  every block -- about seven instructions of shuffling for three of
  arithmetic -- and an ablation puts the whole multiply-add step at 39 per
  cent of a prompt while it issues at about a fifth of the rate this part
  can. The insertion folds them to four, keeps those across a row, and
  reduces once. The prompt reads 1.280 s against 1.323, better in each of
  three alternated rounds; generating is level and no digest moves.

  There are two insertions, one per instruction set, and that is what the
  suite required rather than a flourish: a test asserts that both
  compilations of this kernel answer the same bits, so that what a model says
  is a property of the model and not of the host that ran it. The first
  version was wide-only and failed it. The two are arranged so a sum holds
  the same four of a block's sixteen pairs either way -- the wide one folds
  the block's halves and then the register's, the baseline one adds all four
  quarters -- and everything after that is elementwise.

- **A device workgroup is 256 invocations rather than 64.** Nothing had ever
  varied it; it was the wave width of the part this was written against,
  which is a reason to pick a number and not a reason to keep it. The device
  prompt reads 0.547 s against 0.579, better in each of three rounds. A group
  is what the device switches to when one of its waves is waiting on memory,
  and one wave to a group leaves it nothing to switch to.

  Generating is the cost: about two per cent across the alternated rounds,
  and eleven per cent in the sitting that re-took the published table. That
  row has read 13.3 to 24.2 tokens a second across a dozen sittings on
  unchanged code, so the rounds are what the choice rests on and the table is
  what this sitting measured.



- **How many rows a tile takes is chosen from the batch rather than fixed.**
  Four was measured and published: 2.120 s at two rows a tile, 1.948 at four
  and 2.122 at eight on a 110-token prompt, read as four being where the
  register file runs out. Taken again it says 1.379 at four, 1.351 at six and
  1.281 at eight, with nothing about the kernel changed between the sittings.

  What changed is the batch. That first sweep ran when a prompt was read
  thirty-two vectors at a time and the default is a hundred and twenty-eight
  now; a tile reads the activation once and the activation is re-read once
  per tile, so what a larger tile saves grows with the batch. The answer
  moved and nothing asked the question again -- which is the same shape of
  mistake as a published figure resting on a source no group named.

  A generated token is one vector, where the activation is two kilobytes and
  in the nearest cache whatever the tile, and there eight measures slightly
  worse than four -- 2.593 s against 2.545. So it is eight for a prompt and
  four for a token, which is the only reading that took both. No value moves;
  the digests are what they were.

### Measured and not kept

- **Four rows to one insertion**, so that one address computation and one
  scale lookup would serve four multiply-adds. It executes **more**
  instructions than the loop it replaces -- 98.7 thousand million against
  96.3 -- and reads 1.328 s against 1.269. The hand count that predicted
  otherwise was the third this week to be wrong, and this time a counter was
  available to say so.

  It also carried a defect the conformance sweep missed and the kernel's own
  test caught: the lane type declared `Alignment => 32` on sixteen bytes of
  data, so every entry is padded to thirty-two and a hand-written stride of
  sixteen reads the wrong halves. An aspect that pads is a stride nobody
  declared.

- **A register-blocked tile for the prompt, four rows by four vectors.**
  Written, correct -- the conformance sweep passed with nothing outside
  tolerance -- and across three attempts it does not beat the kernel it
  replaces: 1.234 s against 1.254, then 1.243 against 1.291, then 1.299
  against 1.249. Against a five per cent noise floor none of those is
  separated from nothing.

  Two real defects were found and fixed on the way -- the weights were packed
  once per group of four vectors rather than once per chunk, thirty-two times
  over, and the innermost loop computed an index with a division in it -- and
  fixing them moved the figure inside the noise and no further.

  **Tiling amortises loads and nothing else.** Per row, per vector, per block
  the work is a zero, a multiply-add, a widening and a fused multiply-add,
  plus a scale multiply and a bias multiply-add in scalar; not one of those
  six is shared between the tile's elements, because each carries its own
  pair of scales. Sixteen elements share four weight loads and four
  activation loads, which is about 5.3 multiply-accumulates an instruction
  against 4.6 -- and the packing spends the difference.

  That says something about the remaining four-times gap on the prompt. The
  other runtime's inner loop pays the same six operations per element; at 387
  tokens a second it sustains about 2.5 instructions a cycle a core where
  this sustains about 0.7. **The prompt gap is not an instruction-mix problem
  and no rearrangement of the arithmetic will close it.** It is stalls, and
  finding them wants a cycle counter, which `perf_event_paranoid = 4` has
  denied this whole effort.

- **The device shader's decode is a quarter of a prompt.** Built with the
  eight-bit branch's decode replaced by a constant -- wrong answers, right
  shape -- the device prompt reads 0.427 s against 0.573. A repack that
  removed all of it would be worth about 191 to 258 tokens a second.

  Measured rather than assumed, and the measurement redirects the work: the
  bytes are already bytes, and what costs is that the buffer is bound as
  words so every weight is extracted with a shift and a mask. The way to it
  is `GL_EXT_shader_8bit_storage` and a binding of the right type, not a
  repack -- one that kept the byte count could not remove the extraction, and
  one that did not would cost four times the device memory.


- **Rows a tile beyond eight buy nothing.** 1.305 s at eight, 1.273 at
  twelve, 1.309 at sixteen and 1.316 at twenty-four on a 110-token prompt,
  with the spread inside one setting as wide as the gaps between them. The
  activation traffic a larger tile saves has stopped being what the prompt
  waits on -- which also corrects the claim that those re-reads dominate it.

- **Naming the next block with a prefetch makes generating worse.** 2.591 s
  against 2.533, worse in each of three rounds, with the prompt a wash. The
  rows of a tile are separate streams but sequential ones, and the part had
  already found them.


- **A layer collapsed into one submission on the device, which is slower.**
  This file's own reasoning said device generation was very nearly all host
  round-trip: 41 ms a token divided by the 66 submissions a token makes is
  0.63 ms, which sits inside the 0.6 to 2.3 ms a call the batch sweep had
  bracketed. That is arithmetic landing in a plausible range rather than a
  measurement, and building the change is what showed the difference.

  What was built: a fourth shader doing the normalizations and the residual
  additions on the device, a step kind for each, sequence steps naming which
  earlier step they read rather than only the one before them, and a barrier
  emitted only where a step reads something not yet visible. With it a
  layer's second half goes over as one submission; carrying that on through
  the next layer's projections makes a whole layer one. Three rounds,
  alternated, every digest identical:

  | A token of 64, generated | median |
  | --- | ---: |
  | three submissions a layer | **2.650 s** |
  | two -- the block in one recording | 2.767 s |
  | one -- the whole layer | 2.794 s |

  Monotonically worse as the submissions fall. Fusing trades submissions for
  pipeline barriers -- three a layer against ten -- and a barrier drains the
  device where a submission does not; against dispatches this small the
  drain costs more than the call it replaced. Taken back out, and the README
  now says what is ruled out rather than naming a next step it cannot
  support.

- **Two attempts on the processor's integer kernel, both measured out.**
  Keeping the eight lane sums a block product leaves, so that the horizontal
  reduction happens once a row rather than once a block, costs 2.6 times the
  prompt -- the lane form is no longer a reduction and the compiler stops
  emitting the sixteen-bit multiply-add the kernel was written around.
  Storing the quantized activations sixteen bits wide, so the kernel stops
  widening the same values again for every four rows, is level generating
  and slower on the prompt: doubling the activation array costs more in
  traffic than the widening costs in arithmetic. Both say the same thing --
  that this kernel is bound by reading activations, not by widening them.

### Fixed

- **A buffer the processor reads back is allocated out of memory the
  processor caches.** The engine asked the device for one kind of memory for
  everything they share: the first that is host-visible, coherent and the
  device's own. That is the right answer for what the device reads and the
  wrong one for what the processor does. Reading such memory back is uncached
  and uncombined, around a tenth of the bandwidth writing it gets, and a
  110-token prompt reads about ninety megabytes of results out of it.

  A result buffer comes from a kind the processor caches now, chosen at open
  and falling back to the other where a device offers none; uploads and the
  cache still come from the device's own memory, which is what they want.

  | device, 110-token prompt | before | after |
  | --- | ---: | ---: |
  | wall | 1.702 s | **0.610 s** |
  | processor time | 1.04 s | **0.12 s** |

  Generating goes 18.2 to 24.2 tokens a second with it, the six-token run
  1.025 s to 0.563 s, and `tests benchmark` halves every batched device ratio
  -- q8_0 at thirty-two vectors a pass from 0.104 to 0.043 of the processor's
  time. Same digests throughout.

  This is the open question the entry below was written to investigate. The
  same run had read 0.608 s in one sitting and 1.70 s in the next with the
  code between them unchanged, which looked like a fifteen-watt part's own
  state and was not: which kind of memory the driver handed back was the
  difference, and asking for a cached one makes the fast reading the only
  reading. The figures file now names the source that makes that choice,
  which nothing named while it decided every device figure published here.

### Added

- **A run says how much of the context the device is holding.** It could say
  how much of the *model* was there and not how much of the context, so a
  device computing the products there and attending here looked exactly like
  one doing all of it -- and the only sign from outside was processor time a
  run should not have needed. `--show-stats` reports **bytes of context on
  the device** now.

  It was added to answer an open question and its first act was to kill the
  answer that had been guessed. The device's 110-token prompt reads 1.7 s
  against 0.608 s an hour earlier, and that was written up as attention
  falling back off the device. The context is resident: 92274688 bytes, at
  the default budget and under a smaller one alike. Compiling the processor
  fallback out entirely, so that it cannot run at all, leaves the same prompt
  at 1.692 s and 1.05 s of processor. Attention is on the device throughout.

  What was left was inside the device path, and the entry below closes it.

- **The integer product is built twice, and the plan for it was wrong about
  the work.** The plan called for a hand-written kernel reaching `VPDPBUSD`
  through a machine code insertion, a third instruction-set level and a new
  host question to gate it. What it needed was one switch clause. The kernel
  is written around a sixteen-bit multiply-add, which the wider sets have
  more and wider lanes of, and the compiler finds it once it is told which
  machine it is compiling for:

  | | 110-token prompt | 64 generated |
  |---|---:|---:|
  | the baseline | 1.476 s | 2.672 s |
  | `-march=x86-64-v3` | **1.297 s** | **2.402 s** |
  | `-march=x86-64-v4`, 256-bit | 1.308 s | 2.366 s |

  Twelve per cent and ten, from ordinary Ada nobody rewrote. v4 is level with
  v3 and excludes far more hardware, so v3 is built -- and the host question
  it needs, avx2 and bmi2, is the one this program already asks for the
  decoders, so no new level and no new host body were needed either. There
  are no intrinsics here and no assembly.

  One source and two compilations of it, as `Decoders` is, with contraction
  off on the wider one so the two answer bit for bit and a test says so.

  Published: the 110-token prompt is 83.4 tokens a second and sixty-four
  generated tokens 26.2, against llama.cpp's 377.7 and 39.9 on the same file
  and host -- 4.5 times and 1.5, where the first reading of that table said
  16 and 3.3.

- **Attention runs in shares of the heads.** It was the one part of a forward
  pass still running entirely on the calling task while every worker sat
  idle, and the token budget had just named it the largest thing left on the
  processor. A head reads its own slice of the query and writes its own slice
  of the blend, so heads are independent -- the one thing that had to change
  first is that the scores are a row a head rather than one row shared, since
  a head writes its scores, softmaxes them and reads them back inside its own
  iteration.

  A 1419-token prompt goes from 83.757 s to **31.043 s**, which is 45.7 tokens
  a second against 16.9, and the 110-token prompt 1.767 s to 1.377 s. That
  shape is the point:
  attention is quadratic in the context and the rest of a forward pass is
  linear, so at a hundred and ten tokens it is a fifth of the gain and at
  fourteen hundred it is nearly all of it. `speed-prompt-long.txt` is a
  fixture now so the first line can be taken again.

  Every digest is unchanged: a head's arithmetic does not depend on which
  heads are computed beside it, so this is the same values in a different
  order of execution rather than something the tolerance had to allow.

  It nearly did not land. The gate reported four logits of the sweep's 1.1
  million outside tolerance -- all gemma3, generating a token at a time, one
  apart by 0.5131 against a bound of 0.5 -- while the same sweep run on its
  own was clean, which is the worst way for a gate to be wrong: differently
  from the thing it reproduces. **The sweep now sets its own arithmetic**,
  from the command line and from nothing else. It had been inheriting it: the
  gate runs the unit suite first, one of its cases runs the program in the
  same process, and the program's default arithmetic is the quantized one, so
  the whole cross product was running in an arithmetic nobody asked for and
  being held to the tight bound while doing it.

  `Model_Runner.Backend.CPU` gained a `Task_Item` interface and
  `Dispatch_Shares` for it, with a test that the shares cover every item
  exactly once at every worker count. The pool cuts a count of items the way it cuts
  the rows of a matrix and knows nothing else about the work, which is what
  keeps a blend's twenty parameters out of the backend.

- **The token budget says what to do next, and what not to.** It measured
  the floating-point path because `tests benchmark` never asked for the other
  one, so since the default changed it had been describing a run nobody
  makes. It sets the arithmetic itself now and reports both. Generating, at a
  load of 0.14: the feed-forward matrices are 69.1 per cent of a token, the
  attention projections 21.0, the vocabulary projection 6.4, and everything
  that is not a matrix product 3.5 -- 31.078 ms of these against 73.752 at
  `--arith f32`.

  Two decisions fall out of it. **The products are 96.5 per cent of what it
  measures**, so the rotation (0.101 ms, since its angles were tabulated) and
  the two transcendental kernels (0.845 ms together) are not worth an
  instruction set: a wider `Exp` would be worth about two per cent of a token
  if it won outright, and it has lost once already.

  And **a generated token really costs 44.2 ms against the 31.078 accounted
  for**. The missing third is attention over the cache, which this tool
  cannot reach because the three blend kernels have no entry point outside
  `Model_Runner.Llama`. That gap was about a ninth of a token when the budget
  was first taken; the products have got 2.4 times faster since and attention
  has not. It is the largest single thing left on the processor, and it is
  the one part of a forward pass that still runs entirely on the calling task
  with the worker pool idle beside it.

- **The activation a product writes is out of a standing mapping too.** The
  entry before this one kept the read-back's mapping and left this one,
  saying its wrong answers had a cause nobody had found. The cause was that
  the two products which write an activation are textually different -- one
  names `Columns`, the other `Steps.Items (1).Columns` -- so converting the
  obvious form converted one of them and left the other calling a writer that
  unmaps when it is done. **One writer left on a buffer pulls the mapping out
  from under every other writer of it.**

  With both standing, and `Write_Into` gone because nothing called it any
  more, the device's 110-token prompt goes 1.054 s → 0.660 s → **0.608 s**
  across the three steps, and sixty-four generated tokens 4.541 s → 4.292 s →
  **3.626 s**, which is that row's best reading in eight sittings. The gap to
  llama.cpp on the device is **9.2 times on the prompt and 3.2 generating**,
  where the first reading of that table said 29 and 4.1 -- and none of it came
  from the shader, which nothing has touched.

  Three explanations were tried and measured out before the real one was
  looked for, and none of them was wrong about anything except being the
  cause. The rule that would have found it first is in the code now: the unit
  that can be converted safely is every user of one buffer, not one call
  site.

- **A product's results are read out of a standing mapping.** Every product
  mapped the device's result memory, copied out of it and unmapped it again,
  twice a call counting the activation -- and the cache beside it had already
  written down that a map and an unmap pair costs about a millisecond and a
  half. B1 to B3 had ruled out the shader's memory pattern, its decode and
  its dispatch width, and left the cost of a call itself, which the batch
  measurement bracketed at 0.6 to 2.3 ms. This is most of that.

  The 110-token prompt on the device goes from 1.054 s to **0.660 s**, which
  is 166.7 tokens a second against llama.cpp's 1679 on the same file and
  host -- ten times, where the first reading of that table said twenty-nine.
  The device table now shows the device finishing the long run two and a half
  times sooner than the processor for a sixtieth of the processor time.

  The activation a product writes in is the other pair and is not done. It
  produced wrong answers, the drafted device test caught them, and three
  explanations were tried and measured out: a mapping sized by the call
  rather than the allocation, another path unmapping the same memory
  underneath it, and a megabyte of batch copied through a constant on the
  stack. None was it. The comment where that write is says so, so that the
  next person does not spend the afternoon twice.

- **A prompt is read in batches of a hundred and twenty-eight.** The default
  was thirty-two, chosen for the processor, and the device had never been
  asked what it wanted. It wants fewer calls: a 110-token prompt on the
  device reads 2.767 s at a batch of eight, 1.973 s at thirty-two and
  **1.054 s** at the cap -- sixteen passes over the weights either way, so
  the whole of that factor of 2.6 is how many times the host tells the device
  to do something. On the processor the same sweep reads 2.125 s at
  thirty-two and 1.738 s at the cap.

  So the device's 110-token prompt goes from 1.951 s to 1.054 s and its
  processor time from 1.07 s to **0.12 s**, against the processor backend's
  8.79 s for a run it now loses by sixty per cent. The gap to llama.cpp on
  the device is 15.7 times where it was 29, and none of it came from the
  shader.

  What the default costs is how often a run can be cancelled or report
  progress while reading a prompt: every hundred and twenty-eight tokens
  rather than every thirty-two, about a second on this model. A caller who
  wants a finer grain asks for a smaller batch and pays for it in prefill.

  Five figure groups gained `model_runner-generation.ads` and
  `model_runner-cli-options.ads` as sources, because this change walked
  through a hole: the default batch decides every prompt figure published in
  the README and lived in a file no group named, so raising it moved six
  numbers with no fingerprint firing.

- **Four rows against one reading of the activation.** The quantized product
  multiplied a row at a time, so the activation block was loaded once for
  every row of the matrix -- two thousand times for a matrix of two thousand
  rows, out of the nearest cache, which is not the same as out of a
  register. It multiplies four rows at once now, which also gives the
  processor four independent chains where one row gave it one.

  The 110-token prompt goes from 2.284 s to 2.056 s, which is 53.5 tokens a
  second against llama.cpp's 387.0 on the same file and host. Generating does
  not move and was not expected to: one token is one vector, and there is
  nothing to reuse a reading of. Nor does any value: the generated text's
  digest is what it was, because a row's blocks are still accumulated first
  to last whatever the tile.

  The tile is four because four measured fastest -- 2.120 s at two, 1.948 s
  at four, 2.122 s at eight, on the prompt. Eight spills the accumulators it
  was meant to keep, which is the whole of why this has a number in it rather
  than an argument.

  `Accumulate_Dot_Integer` is gone rather than kept beside it. A format with
  two implementations has one nobody tests, and the tiled entry answers for a
  tile of one.

  One reading in the sitting is a finding rather than a figure. **Fourteen
  threads beat seven for the first time in a year** -- 0.535 s against
  0.600 s for seventy-six per cent more processor time -- because a product
  that multiplies bytes waits on memory less and on execution units more, so
  a second thread on a core has something to do again. The bargain has now
  been eighteen per cent better, eleven worse, seven worse, nothing, and
  eleven better, on one machine, and every one of those readings was right
  when it was taken. The default stays one worker per core: eleven per cent
  of wall for seventy-six per cent of energy is not a bargain on a part
  sharing fifteen watts with a device.

- **Quantized activations are what a run does by default.** `--arith int8`
  became the default and `--arith f32` the option, because two times the
  speed for a bound the sweep states and holds is a bargain worth taking by
  default -- and because a default nobody selects is a path nobody
  exercises. Twelve tokens take 0.593 s against 1.299 s at `f32`, and 3.52 s
  of processor time against 8.62; a 110-token prompt 2.284 s and sixty-four
  generated tokens 2.927 s, which is 48.2 and 21.9 tokens a second against
  llama.cpp's 377.5 and 39.9 on the same file and host. Every figure in
  `## Speed` was taken again at the new default in one sitting.

  Two of them are worth reading twice. **The processor backend now wins the
  short run against the device** and has nearly caught it on the long one --
  nothing on the device moved, and the shader still multiplies in binary32;
  what the device keeps is the processor row, 0.22 s against 3.57 s. And the
  reference backend is thirty-six times the work of the processor one where
  it was seventeen, which is one side moving and not two.

- **The sweep runs the quantized path rather than only bounding it.** Every
  gate run now compares it against the independent implementation on the
  formats that have an integer kernel, at one shape, and reports what it
  compared in a bucket of its own: 1248 logits, 9.13E-02 worst absolute,
  1.92 worst relative, none outside the pair stated for it.

  The bucket exists because the first version of the pass proved nothing. It
  reported 1.47E-06 -- the exact path's own error -- and the reason was that
  `Dispatch` and `Dispatch_Batch` ran their serial branch straight into the
  floating-point product, so a run with no pool got the arithmetic it had not
  asked for, silently, and a sweep comparing through that branch compared the
  same two numbers twice. The serial path quantizes now, and a count of zero
  in that bucket is what a fallback would look like.

- **`--arith int8`, activations quantized to a byte.** A weight in a
  quantized format is already a small integer and a scale; the vector it is
  multiplied by was binary32, so the weight was widened to meet it and every
  element product rounded twice. Rounding the vector instead -- once, before
  the product, with a scale for every thirty-two elements -- makes a block
  product an exact integer sum of thirty-two byte products and one multiply
  by the two scales. That is twice the speed on this model: a 110-token
  prompt in 2.210 s against 4.940, sixty-four tokens generated in 2.922 s
  against 5.642, and half the processor time with it.

  Inside a block the new path is the more accurate one -- the integer sum
  cannot exceed 516128 and rounds nothing, where the other rounds every
  product and then the sum. What it costs is that the input arrived rounded,
  and the conformance sweep holds it to 5.0E-2 relative and 5.0E-1 absolute:
  0.426 worst absolute and 1.92 worst relative over 28311 sequences, none
  outside the bound. `--arith f32` is still the default and is what the
  published figures are measured against; `--backend reference` never
  quantizes anything.

  Two things about it are worth keeping. The width that made it work is
  sixteen bits, not eight: baseline x86-64 has no byte dot product and does
  have a sixteen-bit pair multiplied into a thirty-two bit lane, so the
  weights are unpacked to halfwords and the kernel needs no intrinsic and no
  instruction set beyond the baseline. And the first version was *slower* --
  41 per cent behind at thirty-two vectors a pass -- because it unpacked the
  weights inside the loop over the batch rather than outside it, so every
  vector re-read the block and a batch stopped being a batch.

  The sweep's tolerance chain now takes the widest of the pairs that apply
  rather than the first: a run with a rounded cache and quantized
  activations answered to the cache's bound alone, which is a gate reporting
  the mode it happened to test first.

- **Attention reads a position's values where they lie.** The blend held one
  component still and walked the whole cache for it, once for every component
  of a head -- `Value_Size` passes over the same bytes, each of them touching
  a cache line for four bytes of it, when a position's values are contiguous
  and one pass serves sixty-four components at a time. All three blends do
  it the second way now, a run of components at a time so the accumulators
  stay on the stack whatever width a model gives a head.

  Bit for bit what it replaced. Each component still sums over the steps in
  ascending order and rounds once, so the run's digest is unchanged and the
  conformance sweep moved no logit; what moved is where the sum is kept.

- **The rotation computes an angle once instead of once a head.**
  `Apply_Rotary` sat its head loop outside its pair loop and recomputed
  `Power`, `Cos` and `Sin` for every pair of every head, though the angle
  depends on the pair and the position and on nothing else. On a
  thirty-two-head model that is thirty-two times the transcendental calls the
  rotation needs, and they are the most expensive arithmetic in the package.
  The angles are tabulated first, in the wide format the rotation reads --
  rounding the table to `Real` would round twice where the rotation rounds
  once -- and every head is then rotated against them. Also bit for bit.

  Together the two are worth about a tenth of a run: the 110-token prompt
  goes from 21.5 to 24.1 tokens a second on the processor and 64 generated
  tokens from 11.0 to 12.2, with the device side moving less because less of
  it is here. Every figure in `## Speed` was re-taken in one sitting for
  them, and `docs/measured-figures.txt` says which sitting and at what load.

- **`tests benchmark` says where a token's time goes.** Seven matrix products
  a layer, two normalizations, an activation, a rotation and one projection
  over the vocabulary, measured on TinyLlama-1.1B's own shapes at one vector
  a pass and at thirty-two, each reported as milliseconds a token and as a
  share of the token. Generating, the feed-forward matrices are 71 per cent
  of it, the attention projections 20, and everything that is not a matrix
  product together is under 3.

  It exists because a whole-run figure is five things at once and three
  attempts at making this engine faster were aimed by reading rather than by
  measuring -- one of them at the attention call, which turned out not to be
  what was slow. Attention over the cache is not in the table, and the
  omission is the honest kind: the blends are inside `Model_Runner.Llama`
  with no entry point this tool can reach, and a proxy for them would report
  a number about the proxy.

- **What the other runtime costs for the same file.** The comparison with
  llama.cpp has been about agreement since it was written -- same tokens,
  same greedy continuation, same pooled vector -- and never about time, so
  this repository published how long a token takes here and nothing about
  what that is beside. `## Speed` now carries both sides, taken in one
  sitting on one host against one file: 21.5 tokens a second of prompt and
  11.0 generated on the processor against 387.6 and 40.0, and 54.1 and 16.2
  on the device against 1670.4 and 57.4.

  Three and a half times slower generating and eighteen to thirty-one times
  slower on the prompt, and the two are not one finding. Generating is the
  bus -- 12 GB/s of this model against 44 -- and that is a gap in kernels
  compiled for baseline x86-64. The prompt is a different shape of work: a
  batch here shares one reading of the weights and multiplies a row at a
  time, and there it is a product of two matrices against hand-written
  kernels. `docs/measured-figures.txt` records the runs, the loads and the
  build of the other runtime, and why the command says `--device none`
  rather than `-ngl 0`.

- **The eleventh architecture, read from a file somebody else wrote.**
  qwen3moe was the one architecture with no published file behind it -- the
  smallest published mixture is thirty billion parameters -- so what stood
  behind it was a fixture written here and one comparison against the
  independent implementation. Qwen3-30B-A3B now stands behind it: 579
  tensors, 30 532 122 624 parameters, loaded, generated from, deterministic
  and thread-stable under `tests external-model`, and its tensor names
  agreeing with the fixture written here name for name under
  `fixture-likeness` -- fifteen a layer published, fifteen written, none
  unwritten and none invented. That is the check that found gpt2's missing
  normalization shift on a file nobody here had written; it found nothing to
  report about the mixture keys, the router or the three stacked expert
  tensors.

  The arithmetic was right on it the first time and the figures file says so.
  What the file found was in the template.

- **A turn's tool calls, kept as calls, and a batch run that closes the loop
  they open.** Qwen3's template renders now, and until this it rendered a
  tool conversation the model had not had. A call reached the next turn as
  the model happened to spell it -- the `<tool_call>` block sitting in the
  reply's text -- while the template's own branch for writing one was
  guarded by `message.tool_calls`, a name that held nothing, and was never
  entered. The two spellings are close enough to read and not the same
  bytes, which is the only thing that matters to a model trained on one of
  them.

  So a conversation holds what the model asked for. `Append_Reply` takes a
  reply apart where the model stopped speaking and started calling: the text
  becomes the turn's content, each call is attached to the turn, and the
  newline between them belongs to neither, because the template puts one
  there itself when there is something to separate. A turn that called and
  said nothing is a turn with empty content, which a plain message may not
  be and which `Append_Asking` exists to allow.

  What the template gained is the branch the file already had: the name
  `message.tool_calls` and the question `'tool_calls' in message`, both
  answered from the turn rather than answered "no"; a loop over the calls,
  binding `tool_call` for the reason the list loop binds `message` -- the
  fields readable from what it binds are a call's fields; `tool_call.name`
  and `tool_call.arguments`; and `loop.first` inside such a loop, which is
  what decides whether a newline goes before the call. The branch the same
  template writes for a call shape this engine does not hold --
  `{%- if tool_call.function %}` -- is not entered rather than not present:
  it reads a name that means nothing here, and a name that means nothing is
  false in a condition.

  `--assistant`, `--assistant-file`, `--tool-result` and `--tool-result-file`
  put the earlier turns back, in the order they were written. That is how one
  run closes the loop another opened: the model asks for a tool, the caller
  runs it, and the next run is handed the conversation the model saw -- its
  own reply included, because a reply left out is a call the model never
  made. The reply is handed back as it was printed and the calls are read out
  of it here, so the caller pastes rather than parses. `run` also reports what
  a reply asked for, on standard error and by name, as the interactive session
  already did: a caller who has to find a call by eye in a page of text will
  find it wrong.

  Settled against Python's jinja2 on the published Qwen3 template, conversation
  for conversation: twenty-four conversations rendered with and without a
  generation prompt, forty-eight in all, every byte agreeing -- calls with text
  before them and without, two calls in one turn, a run of answers folded into
  one turn, arguments carrying quotes and backslashes, a reasoning block in an
  earlier reply, and a user turn that itself contains the words the template
  looks for.

- **Qwen3's own chat template, and everything it needed.** The template a
  current model ships was refused, so `run` on a Qwen3 of any size meant
  spelling `<|im_start|>` by hand under `--raw`. It renders now, and it
  renders the same bytes as the implementation it was written for: seventy-six
  conversations compared against Python's jinja2 on the published
  Qwen3 template, all agreeing, the two that differ being an empty
  conversation, which that implementation raises on and this one answers.

  What it needed, and each of these is what some template out there is
  written in rather than a feature for its own sake:

  * `namespace(a=x, b=y)` and its fields. A namespace exists in that
    language because a name assigned inside a loop does not outlive it;
    names here outlive everything already, so `ns.field` is a name like any
    other spelled with a dot. What tells it from `message.role` -- spelled
    the same way and not a name at all -- is that `ns` was made a namespace.
  * `{% for i in range(a, b, c) %}`, with a step that may count down. That
    is how a template finds the last question in a conversation, and no
    loop over a list can express it.
  * One message of a list bound to a name -- `{% set message = messages[i] %}`
    -- and a position worked out rather than written, `messages[loop.index0 - 1].role`.
    A loop binds the same name the same way, so `message.role` is one
    question however the binding was made.
  * `<`, `<=`, `>`, `>=`, reading both sides as whole numbers, and `-`
    between terms, which is how `messages|length - 1` becomes a number.
  * `'x' in TEXT` and `'x' not in TEXT`, which is the same word as the test
    that asks whether a message carries a field and a different question.
  * `is true`, `is false`, `is string`.
  * `.strip`, `.lstrip`, `.rstrip`, `.split(S)[0]`, `.split(S)[-1]`, and up
    to four of them in a row. That is how a template takes a reply apart at
    the marker its reasoning is in, and there is no reading a thinking
    model's reply back into a conversation without it.
  * A bare operand as a condition, with the empty string, `none`, `false`
    and a name never assigned all false. A name the template never assigned
    is nothing when a condition asks about it -- `{% if tools %}` is written
    to find out whether there are any -- and an error when the output asks
    for it, because printing the empty string where the template meant text
    says nothing about the mistake.

  `tests render --model M --system S --prompt P` prints what a model's own
  template makes of a conversation, which is what made the comparison above
  possible: a rendering worked out from this engine's reading of a template
  agrees with this engine by construction, and only a second implementation
  settles anything. It is `tests tokenize` for templates and exists for the
  same reason.

- **The unigram road, which is a fourth road and not a setting on the
  first.** A `t5` vocabulary neither merges nor spells. It chooses, out of
  every way the text could be cut into pieces the vocabulary holds, the one
  whose scores sum highest -- the scores being log probabilities, which is
  what makes summing them the right thing to do with them and comparing them
  the wrong one.

  That is a different answer from the SentencePiece road's rather than a
  better-computed one, and the fixture the two implementations are compared
  on is one where they differ: merging takes the marker and "a" together,
  then that and "b", and is left with two pieces summing to -7, where the
  best path takes the marked "a" and "bc" and sums to -6. No order of merges
  reaches the second. A fixture where the two agree would have let a reader
  that took the wrong road pass, which is what every fixture written for the
  other roads is.

  A character no piece spells is an edge of its own at the lowest score in
  the vocabulary less ten -- the only thing keeping the lattice connected,
  without which one unseen character fails the whole encode -- and a run of
  them is one unknown token and not one each. A file with no scores, or with
  no unknown token, is refused rather than read as a vocabulary of equals.

  The text is normalized first, through the table the file itself carries in
  `tokenizer.ggml.precompiled_charsmap`: a four-byte length, a compressed
  trie from an input prefix to what replaces it, and the pool of
  replacements it points into. Read rather than worked out here, because it
  is the model's own table and no two files need agree about it -- and a
  file that states one and is tokenized as though it had not is a file
  answered in the wrong pieces. A piece the file's author wrote in by hand
  passes through the table untouched; a byte sequence that is no character
  at all becomes the replacement character, one byte at a time, rather than
  failing the encode.

  Settled against the vocabulary llama.cpp ships for its own tests --
  250,048 pieces, a quarter-megabyte normalization table -- on the same
  sixty-two strings the cutting rules were settled on. All sixty-two agree,
  the charsmap included.

- **jina-bert-v2, and the engine's first positional bias.** `bert`'s
  arrangement with the positions taken away entirely. It neither rotates nor
  learns a row for where a token is; it is told by a fall-off in the
  attention scores, one slope a head, taken off after the scale by one over
  the root of the head width and before the softmax.

  Unsigned, because the model reads a whole text: a position is as far from
  what follows it as from what came before. That is the difference between
  this and the form a generating model would use, where every visible
  position is behind and the sign never comes up -- and it is why the three
  blend procedures needed a second number rather than one. They took the
  last position a query may read, which for a bidirectional batch is the
  same for every slot; the query's own position never reached them at all.
  It has no default, so every call site had to say which position it was
  asking about, which is the only part of this the compiler could check.

  The ladder of slopes has two branches and the second is only reached where
  the head count is not a power of two. Twelve heads take eight rungs of one
  and four of the other; a ladder written as the first branch alone is right
  for two thirds of the heads and wrong for the rest, which is a plausible
  embedding and not a refusal. That is why the file this was checked against
  is the twelve-head one and not the eight-head one, which would have agreed
  with the wrong ladder. The number the ladder is built from is eight, which
  no published file states and the other runtime carries in its own source;
  a file stating another is refused rather than cut to eight.

  Its feed-forward is gated by the Gaussian unit where `nomic-bert` gates by
  the sigmoid-weighted one, and it shifts what it projects down and nothing
  else. Not implemented and refused by name: the code variant's third
  normalization inside the attention sublayer and its query and key
  normalizations, which would otherwise be read as a model with three
  normalizations missing.

  Read off jina-embeddings-v2-base-en before anything was written, which is
  the order the last two architectures taught, and it agreed with the second
  runtime on the first run: 768 components, worst 4.4e-05, cosine
  0.99999942. `tests/fixtures/jina-v2-embedding.expect` records it whole.

  The shader learnt the same fall-off, which needed a sixteenth push-constant
  word -- and that turned up a bug: the pipeline layout declared a range of
  fifty-six bytes while attention pushed sixty, which is a write past the
  declared range that no device refuses because every device offers at least
  a hundred and twenty-eight and no validation layer was running. Two numbers
  a word apart is what let it drift; the range is taken from the largest of
  them now.

  `tests fixture-likeness` also learnt `bert`, `nomic-bert` and
  `jina-bert-v2`, which it had never had: the check written to catch a
  fixture describing a model nobody ships had never once been run against an
  embedding architecture. All three fixtures name exactly the tensors their
  published files carry.

- **nomic-bert, written from the file.** `bert`'s arrangement with three of
  its parts replaced: it rotates where `bert` learns a row for the position,
  its queries, keys and values are written fused, and its feed-forward is
  gated -- by the sigmoid-weighted unit rather than the Gaussian one `bert`
  uses, because two architectures of one shape need not share that. It
  carries no bias on any projection; only the two normalizations a block and
  the one over the embedding have one. It splits its rotation as everything
  since `llama` does, element i against element i + rotary/2.

  Every one of those was read off nomic-embed-text-v1.5 before anything was
  written, which is the order the last architecture taught: a fixture built
  from a description is a fixture that agrees with a reader built from the
  same description.

  What the file found that the fixture could not: layer five produced a
  value that is not finite, because `Join_Residual` normalizes only where it
  has a buffer to do it in and that buffer is allocated from a list this
  architecture was not on. A missing entry there is not a refusal -- it is
  arithmetic quietly skipped, so the residual was never normalized and grew
  until it overflowed. The same shape of fault as the one the batched
  evaluator had for `bert`, in a different buffer, and the allocation now
  asks the arrangement rather than a list.

  Also: the second of the two post-normalizations was written inside the
  gateless feed-forward branch, which a gated architecture never reaches.
  Both belong to the arrangement rather than to the shape of the block below
  them, and they are written together now. `Normalizes_After` names the
  arrangement once instead of spelling two architectures at the dozen places
  that mean it.

- **Bert, and `embed` on the models people actually embed with.** The first
  architecture here that does not generate: it reads a whole text at once and
  produces a state for every position of it. Three things follow, and none of
  them is a parameter of what was already here. Its attention is
  bidirectional, so a position sees what comes after it as well as what came
  before -- read causally it still answers, with an embedding that is quietly
  the wrong one. It normalizes after the residual add rather than before the
  sublayer, which is a third arrangement beside the two already written and
  not a flag on one of them. And it learns a row for the token, a row for
  where the token is and a row for which segment it belongs to, summed and
  normalized before the first layer.

  A whole text or nothing: a second batch into a written cache is refused by
  name, because the first half would then have been computed without the
  second and nothing about what came back would look wrong. `--batch-size`
  says nothing about such a model; the batch is the text.

  It carries no projection from a state to a token and ties none to its
  embedding table, so `run` is refused before a session is built and `embed`
  is what it is for. `--pooling cls` joins mean and last, and where the
  caller names no pooling the model's own `pooling_type` is used -- bge and
  e5 were trained on the first position and MiniLM on the mean, and reading
  the file is how the difference stops being the caller's problem.

- **The WordPiece tokenizer road.** A third road beside SentencePiece and
  byte-pair, for `tokenizer.ggml.model = "bert"`. It changes the text before
  anything is looked up -- lower-cased, accents off, punctuation and
  ideographs cut loose -- and then spells each word from the front with the
  longest piece the vocabulary carries, every piece after the first written
  with two leading hashes. A word no run of pieces spells is one unknown
  token and not the pieces that did match, because half a word spelled is a
  different word. A file that says it was cut without folding is refused
  rather than folded anyway: every word would come back unknown, which is an
  answer and not an error. Read by a second implementation written from the
  description, as the other two roads are.

- **A figure published in the README has to appear in the record of how it
  was taken.** The fingerprints catch a source that moved without its
  figures being re-measured; they cannot catch a number edited into one file
  and not the other, in either direction, and both happened while the device
  table was being rewritten. Every `N.NNN s` in that table is now looked for
  in `docs/measured-figures.txt`, and the check was confirmed to fail when a
  figure is altered.

- **The fuzzing campaign reaches a device.** Every third case is prepared
  for the device backend where there is one, so a malformed file gets past
  the reader and into a shader -- a path no processor case can reach,
  because the refusals guarding it belong to the device backend. The gate
  fails if a device was open and no case was prepared for it, since clean
  totals from a campaign that never asked would read as a pass. 200 cases
  send 43 to a device; 400 send 78; nothing has escaped.

- **The call that carries its own cache takes a batch too.** `Attend` passes
  `Positions` and `Window` through to the resident call it delegates to, so
  the two attention entry points agree on what a batch is. A test compares a
  batch of two positions against the same two taken singly.

- **An attention step can read its queries from the step before it.**
  `Add_Attention` takes `Chained`, binding the previous step's result as the
  queries so they never leave the device. The engine cannot use it yet --
  it rotates the queries and writes the position's keys and values on the
  processor, between the product that makes them and the attention that
  reads them -- and it is here to measure what moving that work would be
  worth before anyone moves it. Measured in a layer, alternated round by
  round: 0.392, 0.199, 0.321 and 0.159 ms a layer, which is the same size as
  a saving that has already failed to appear in a run.

- **A sequence can hold an attention step.** `Add_Attention` records
  attention into the same command buffer as the products around it, with
  `Run`'s activation count supplying how many positions attend, so a batch
  stays one dispatch. It names no matrix and is refused at run time when the
  engine holds no cache, rather than dispatching against whatever the
  binding last named. A test compares the recorded form against attention
  submitted on its own, on the same cache with the same queries.

### Fixed

- **A mapped model's weights are the file's own pages.** The file was
  mapped and the mapping served reads, and then the whole tensor section was
  read into one arena -- so an eleven-gigabyte model cost eleven gigabytes
  of memory and 5.248 s of loading warm, 38.684 s cold, before it had
  answered anything. The arena is gone for any source that can say where its
  bytes already are. Loading a one-gigabyte model costs 0.065 s against
  0.55 s; twelve tokens of Qwen3-30B-A3B from a cold cache take 15.84 s
  where the loading alone used to take 38.684 s; and the resident set peaks
  at 4.6 GB rather than 11.25 GB, because a mixture routes to eight experts
  of a hundred and twenty-eight and the pages of the other hundred and
  twenty are never touched.

  What stood in the way was Ada rather than design. An access to an
  unconstrained array carries its bounds and can only be made by allocating,
  so it cannot be pointed at a mapping: converting an address to one needs a
  general access type, and converting an access-to-constrained to an
  access-to-unconstrained is refused because the designated subtypes must
  statically match. Both were tried. So a view holds the address its buffer
  begins at and how far it runs, and each reader declares an overlay over
  the two -- which is what the device backend was already doing for every
  product it recorded, and which is now the only way weights are addressed.

  Three decisions worth naming. Only a mapping is borrowed: a source that is
  already an array in this process could say where it is and is not asked,
  because that array belongs to whoever passed it and may be freed while the
  model still refers to it. Mapped bytes are counted as mapped and are not
  charged against the memory limit, which is what this program's accounting
  has always said a mapping is -- address space rather than resident pages
  -- and is what lets a model larger than memory run. And a device opened to
  read the weights where they lie still gets them: that import wants the
  host's own pointer and this driver will not take a file's pages, so asked
  for both, a run copied 633 233 408 bytes to the device and read none where
  they lay. The two ways of not copying a model are exclusive on this
  hardware; the caller who named one gets it, and `--show-stats` says which
  of the two happened.

- **Four formats decode about twice as fast, from one source compiled
  twice.** Q5_0 and Q5_1 keep the fifth bit of each element at a varying
  place in a thirty-two bit word, so the shift amount varies with the
  element; IQ4_NL and IQ4_XS index a table of sixteen levels, which is a
  gather. Neither vectorizes on baseline x86-64, which this file has said
  for months beside a note that building for a host with those instructions
  measured slower everywhere else. That note was right and had never been
  quantified. It is now: four formats gain and eleven lose, by between seven
  and forty-two per cent.

  So the decoders are a generic instantiated twice -- `.Plain` with the
  project's switches, `.Wide` with `-march=x86-64-v3 -ffp-contract=off` --
  and the four are sent to the second. One source rather than a second copy
  of four decoders, because a format with two implementations has one nobody
  tests, which this repository learnt once already from an error injected
  into the unused copy of a decoder that went unnoticed.

  Only the decode is compiled wide, and that is what makes it better than
  the whole-program build it replaces. A row product decodes a span into a
  buffer and then multiplies it by each vector; the second half is shared by
  every format and is slower built wide, and it was dragging the four down
  with it. Split: 1.36 ns an element to 0.63 for IQ4_NL, 1.02 to 0.54 for
  Q5_0, 1.06 to 0.57 for Q5_1, 0.90 to 0.50 for IQ4_XS, where the wide build
  of everything managed 0.75, 0.64, 0.68 and 0.68.

  Contraction is off in the wide unit so that the arithmetic is the same
  operations in the same order as the baseline's, and a test holds it to
  that: eight formats decoded both ways, the four dispatched and four that
  are not, required to answer the same bits rather than to agree within a
  tolerance. If that switch is ever dropped, that test is what says so.

  Whether the host has the instructions is read from the host rather than
  assumed from whatever machine did the building. It is not read where it is
  used: the decoders interpret what a model file holds, and a unit that does
  that may not reach a file, an environment or a host -- that is what keeps
  a container from making the program read something else. The backend that
  runs the kernels asks once, at elaboration, and tells them. A host that
  says no runs every format on the baseline, as every host did before this.

  Eleven of the remaining formats sit within three per cent of where they
  were. The twelfth, Q4_1, is eleven per cent slower and nothing here
  explains it; the guess that it was the new call across a unit boundary was
  tested by moving the block loop inside the instance, and the number did not
  move. What is left is the code-layout sensitivity these row products have
  always had, which this repository measured and wrote down in August when
  the same four rows swung by up to a factor of two in the other direction
  with no decoder changed.

- **A chat format for Qwen3-Coder, whose own template this engine will not
  compile.** It opens with `{% macro render_extra_keys(json_dict,
  handled_keys) %}`, and a macro is rejected where it is read rather than
  approximated -- so that model was usable only in raw mode. The format is
  now carried here, as llama3, chatml, gemma and phi3 are, written in the
  same subset and settled the same way: thirty-two conversations against
  Python's jinja2 reading the template Qwen3-Coder-30B-A3B-Instruct ships,
  every byte agreeing. Its turns are ChatML's with one difference, and the
  difference is where a run of tool answers goes -- folded into one user
  turn, opened before the first and closed after the last, including the
  quirk that a tool answer standing first is not opened at all, because that
  template asks `loop.previtem` and a first item has none.

  What it does not carry is that template's tool half, and the reason is a
  shape rather than an effort: it writes a tool's parameters and a call's
  arguments one element per pair of a mapping, and nothing in this subset
  walks a mapping. Both halves of that are refused rather than approximated.
  Offering tools to this format is refused before a prompt is built, because
  the format never names them. A turn carrying calls is refused where the
  call would have been written, by a name that says so, rather than rendered
  as a turn that said nothing -- which is the fault the tool-call work fixed
  for Qwen3 and would have reintroduced here.

- **A template compiled into a Compiled that held another inherited its
  answers.** `Close` released the program, the operands, the conditions and
  the text, and left the name table and the slots that point into it, none
  of which is storage. So a format named on the command line -- which is
  compiled into the model's own -- reported that it reads tools when the
  model's template did, and a caller offering tools to a format with nowhere
  to put them was told nothing and had them dropped. The question exists to
  prevent exactly that: a model told about no tools answers as though there
  were none, which looks from the outside like a model that chose not to
  call one.

  Found while checking that the new format refuses tools, on a model whose
  own template reads them; on a model whose does not, the same combination
  had always refused, which is why nothing had noticed. Thirty-two names
  were being shared between two templates as well.

- **The device refused every model above about four billion parameters, and
  said the backend lacked a capability it has.** A bound of 268 million
  elements stood in the device path, described in the line above it as
  smaller than any device's own limit. It is not: a model's widest matrix is
  its output projection, which is the vocabulary by the embedding, and
  151936 by 4096 is 622 million. Falcon-7B, every Qwen3 above the smallest
  and every published mixture came to that line -- and came away told that
  this model needs `matrix_vector`, which the backend does not have, sending
  a reader to look for a device feature that was there all along and had
  been all along.

  What bounds a product is what the device says one storage buffer may hold,
  so that is what is asked now, matrix by matrix: 4 GiB on the part measured
  here, 128 MiB on the software renderer the same host lists. Reading it
  needed four bytes of care -- the limits sit at 296 in the properties
  structure rather than at 292, because they hold sixty-four bit numbers and
  are aligned to eight, and the four bytes between the two readings are the
  difference between what a storage buffer may hold and what a uniform
  buffer may, which is 65536 on every device and would have refused
  everything. That was caught by taking the second device's answer and
  finding it did not match what the driver reports.

  Two codes rather than the borrowed one. `MR-BACKEND-0011` says a product
  needs a buffer of so many bytes and the device reads at most so many,
  which is the whole diagnosis in one line; `MR-BACKEND-0010` says the
  device would not run this product, for the case nothing here can name.
  Neither claims a missing capability, because the capability is not
  missing.

  So Falcon-7B, Qwen3-8B and Qwen3-30B-A3B run on a device now, and the
  mixture does it reading its weights where they lie: twelve tokens, the
  same text the processor gives, 4094 of 4096 matrices never copied. Asked
  to copy them instead it is refused before it starts, by the memory plan,
  naming the bytes it wanted and the limit it had -- which is the refusal
  that should have been reached all along.

- **A published mixture's own chat template was refused, so `run` on it
  meant spelling the markers by hand.** The template Qwen3-30B-A3B ships is
  not the template Qwen3-0.6B ships. It asks the same question -- where is
  the last thing the user asked -- and asks it in a larger subset, and the
  engine had been settled against the smaller one. `run` refused it by name
  on every conversation there is, empty or not.

  Five things were missing, each of them what some template out there is
  written in rather than a feature for its own sake:

  * A loop over the conversation whose variable is not called `message`.
    The name was required because the fields this engine reads from a turn
    are read through that name; what the name actually decides is whether
    the loop binds. A loop calling its variable `message` binds each turn to
    it, and a loop calling it something else walks the same list and leaves
    the name alone -- which is what this template relies on, because it
    names its variable to be unused and says which turn it means with a
    `set` of its own. A field read off a name that is not `message` is
    refused where it is read rather than answered with the turn the loop
    happens to be on, which would be right by accident.
  * Brackets round part of a sum: `(messages|length - 1) - loop.index0`,
    which is how it counts back from the end. A group is spliced into the
    sum around it, and one joined by `-` has each of its own joins turned
    round, which is what taking a sum away comes to. Brackets round a single
    value are that value, so what is written after them applies to it --
    `(reply.split('</think>')|last).lstrip('\n')` is one term with two
    methods on it.
  * A choice written on one line: `A if C else B`. It compiles to what the
    block form compiles to, because it is the block form said in one line.
  * Cuts at a position rather than at a marker: `content[:n]`, `content[n:]`
    and `content[a:b]`, either end counted from the end where it is
    negative and neither reaching further than the text goes. The template
    writes the pair of them to ask whether a turn begins and ends with the
    markers a tool's answer is wrapped in.
  * `|first` and `|last` on a cut, which say which end of it is wanted --
    the same question `.split(S)[0]` and `.split(S)[-1]` ask. A cut that
    says neither end refuses where it is read rather than being handed the
    end this engine could most easily answer with.

  Settled against Python's jinja2 on the published Qwen3-30B-A3B template,
  conversation for conversation: forty-eight conversations, twenty-four
  rendered with and without a generation prompt, every byte agreeing. Calls
  with text before them and without, two calls in one turn, a run of tool
  answers folded into one turn, a reasoning block in an earlier reply and in
  the last one, a reasoning block with nothing in it, a user turn that
  itself contains the markers the template looks for, and a conversation of
  nine turns. The same forty-eight against the templates Qwen3-0.6B, Qwen3-8B
  and Qwen2-0.5B ship, all agreeing, because a subset grown for one file has
  to leave the files that already rendered where they were.

- **`inspect` called a template supported that refuses on every conversation
  there is.** It compiled the template and reported what compiling said. But
  a value this engine cannot compute is refused where it is read rather than
  where it is compiled -- which is the whole reason a template describing
  tool calling in a branch nobody enters can be used for the conversations
  that do not enter it -- so a template that refuses on everything compiles
  without complaint and was reported as supported. Qwen3-30B-A3B was
  reported that way while `run` refused it by name.

  It renders now before it answers: a turn, and a place for the model to
  answer, which is the question `run` asks. `--verbose` says which construct
  refused.

- **A template's own indentation reached the model.** The line a block tag
  stands on is the template's shape rather than text: a tag written on a
  line of its own is written that way to be read. The implementation these
  templates are written for takes the spaces before such a tag off, and the
  line break after it with them -- `trim_blocks` and `lstrip_blocks`, both
  turned on wherever a chat template is rendered -- and this engine kept
  them, so every template that indents its tags or writes them on their own
  lines handed the model blank lines and leading spaces it was never trained
  on. Neither is taken off where something other than whitespace shares the
  line, and neither for `{{ an expression }}`, which stands where its text
  is wanted; `{%+` keeps the line its tag stands on, for a template that
  means the indentation.

  Found by comparing against `jinja2` on the template TinyLlama-1.1B-Chat
  ships, which is written that way throughout: forty-eight conversations,
  not one of them agreeing, every divergence a line break. Forty-eight agree
  now. The templates Qwen3-0.6B, Qwen3-8B, Qwen3-30B-A3B, Qwen2-0.5B and
  Phi-3-mini ship agree as they did, none of them being written that way.

  The four formats this build carries are ordinary templates in the same
  subset and are read by the same rule, so the one that wrote a line break
  straight after `{% endif %}` -- gemma's, where a turn's role ends -- says
  it as text now, inside the branches, which is what it is. All four were
  set beside `jinja2` reading their own source afterwards: forty-eight
  conversations apiece, every byte agreeing.

- **A sum printed as a run of text where the same sum assigned was a
  number.** `{{ 10 - 3 }}` wrote `103`. The rule that reads an operand as
  arithmetic -- a subtraction outright, a plus where every term is a number
  by construction -- was in the reader that a `set` and a condition use and
  not in the one that prints, so a template that works a position out in a
  `set` and prints the same expression elsewhere meant two different things.
  Both readers ask one question now. A run of text still goes out a term at
  a time as it is reached, because what a template prints has no bound worth
  holding in one place.

- **An inspection described a mixture as the dense model it is not.** A
  mixture-of-experts file states a feed-forward width and does not have a
  feed-forward block: the width belongs to the dense model it would
  otherwise have been, and what it computes with is one expert's, which is
  narrower. `inspect` printed the first and never mentioned the mixture at
  all -- so a reader of the report for Qwen3-30B-A3B was told the block is
  6144 wide, where the model holds 128 experts of 768 and runs 8 of them
  for each position.

  All three numbers were already read into the configuration and none of
  them was printed. They are printed now, under the feed-forward width and
  only for a file that has a mixture, because reporting a mixture for a
  dense model would be the same fault the other way round.

  `Tiny_Model.Write` also learnt the shape parameter its in-memory
  counterpart already had. A fixture written to disk was always the plain
  one whatever architecture it declared, so a `qwen3moe` file written by a
  test had no expert keys in it -- a dense model under another name, which
  is not what a caller asking for a mixture gets to inspect.

- **A name given another name's value followed it afterwards.** `{% set a = b %}`
  copied where the value was rather than what it said, and the room a name
  holds is taken back when that name is reassigned. Inside a loop -- which is
  the only place a template writes this -- the loop's own variable is
  reassigned every time round, so the name that was supposed to remember
  where the loop had got to quietly became where the loop was now.

  Qwen3's template opens by walking the conversation backwards to find the
  last question in it and writing down the counter when it finds one. With
  the counter following the loop, that answer was always zero: every earlier
  reply then counted as later than the last question, and each was re-sent
  with its reasoning block still in it -- the block that template is written
  to strip. The prompt was well-formed and plausible and had text in it the
  model was never meant to see again. Text is copied now; a list, a message,
  a tool and a call are positions and have no room to take back.

- **`+` between two numbers ran them together.** The language this subset is
  written in adds numbers with it and runs text together with it, and only
  the second was implemented. `messages[loop.index0 + 1]` therefore asked for
  message "31" rather than message 4 -- and that expression is how Qwen3's
  template asks whether the next turn is another tool answer, which is what
  decides whether a run of answers is folded into one turn or broken into
  one turn each. It reads right at position zero, which is why a single tool
  answer looked correct.

  An operand whose every term is a number by construction -- a bare number,
  a loop counter, a length -- is now a sum. Two pieces of text joined with a
  plus are still run together, because that is the same language's other
  rule, and it is what every template that builds a prompt out of pieces
  relies on.

### Changed

- **Five faults in how text is cut, found by reading twenty-eight published
  vocabularies against a second runtime.** Every one of them decoded back to
  the caller's own text, so nothing downstream could have noticed; each of
  them handed the model a spelling it was not trained on.

  `starcoder` was on the original rule. It belongs on smollm's: the two are
  one block of expressions in the other runtime. This is invisible on the
  vocabulary starcoder itself ships -- no piece of it spans a digit and
  anything else -- so it is settled by the description and by a fixture built
  to tell the two apart, not by that file.

  An absent `tokenizer.ggml.pre` was read as the original rule. It is a rule
  of its own, and the other runtime says so in four lines of capitals when it
  meets one. It cuts every run of punctuation out of the text first and takes
  digits in threes with nothing before them, so of sixty-two texts a
  published Aquila and a published GPT-NeoX each answered seven and eight
  differently from the way they were trained. `Rule_Default` implements it,
  and the name `default` asks for it outright.

  Falcon cuts punctuation out first too, which had not been implemented at
  all: its contractions were kept whole where that step takes them apart, and
  a space stood before a full stop where that step leaves it behind. And it
  leaves a space on a run of one or two digits and not on a longer one,
  because what cuts digits into threes only reaches a run of three -- `" 12"`
  is one piece and `" 123"` is two. Falcon's own vocabulary happens to hold
  no piece that shows any of this.

  Punctuation here is Unicode's categories and not "everything that is
  neither letter nor digit", which is the difference between `" €5"` and
  `" —b"`: the sign keeps the space and the dash does not. The standard
  library has no general-category test, so the 191 ranges are written out;
  they were taken from a Unicode database and agree with the other runtime's
  own table on all 842 code points and on nothing outside them. WordPiece was
  reading the wider set and cut a word at every currency, degree and
  trademark sign, which the published bge vocabulary settles: it spells
  `"±5"` as one word.

  `tokenizer.ggml.add_space_prefix` was not read at all. gemma2 and gemma3
  state it false, so both had been given every prompt with a marker in front
  of it that they were never trained to see.

  A marker in the text was looked for only where the text opened a bracket.
  A published GPT-NeoX calls its runs of two to twenty-four spaces its
  author's own pieces and a bert vocabulary spells its own with square
  brackets, and neither was seen. The scan now looks wherever the byte is one
  some piece begins with, which is a byte set rather than one character and
  keeps the bound that makes a hostile text cheap.

- **A WordPiece vocabulary that names its markers the other way round.** The
  published jina-bert-v2 states `cls_token_id` and `seperator_token_id` and
  states neither `bos_token_id` nor `eos_token_id`, which were the only two
  keys read. Its text came back wrapped in nothing: six tokens where the
  model was trained on eight -- the same fault the missing flags were, in a
  different key and on the same road, and found the same way. The road now
  carries the identifiers the other runtime carries for a `bert` vocabulary
  before any key is read, guarded by the vocabulary's own size, and reads
  the separator key the format spells with an e.

  `tests tokenize --special` asks for the markers the vocabulary's own policy
  adds, which is what the counterpart in llama.cpp does by default. Without
  it the two differ by exactly those markers and the difference is the
  tool's; this is the flag that makes the fault above visible to the
  comparison rather than only to an embedding.

- **Forty-three more names for the cutting rules, and a check that both
  readers agree about them.** The other runtime files some ninety `pre`
  names under six blocks of expressions; the six this build implements
  account for fifty of them, so `mpt`, `olmo`, `phi-2`, `command-r`,
  `refact`, `dbrx`, `glm4`, `stablelm2`, `grok-2` and the rest are now
  accepted rather than refused by name, with no new cutting logic behind
  them. The engine and the independent reader each carry their own table from
  a name to a rule and nothing compared them; a repository check now reads
  the engine's names out of its source and requires each one in the reader's.
  That is fifty checks where there were none, and it fails on a name mapped
  in one and not the other.

- **Two faults a second runtime found and 857,184 comparisons could not.**
  The engine, the fixture and the independent implementation were written
  from one reading of one description, so all three agreed with each other
  about the same two mistakes. llama.cpp was written by other people from
  the file format, and disagreed.

  A WordPiece text is wrapped in `[CLS]` and `[SEP]` by construction -- that
  is what the road is, not a policy a file chooses. A published all-MiniLM
  states `bos_token_id` and `eos_token_id` and neither flag, and absent was
  read as "the model does not say", so six tokens went in where the model
  was trained on eight. Cosine 0.994 against the other runtime; 0.9999 with
  the markers where they belong.

  And `nomic-bert` splits its rotation, element i against element
  i + rotary/2. It had been written pairing element i with its neighbour, on
  a recollection of what llama.cpp does rather than on llama.cpp. Cosine
  0.947; 0.9993 corrected.

  On F16 weights the two now agree to 8.1e-05 and 8.8e-05 worst absolute.
  The larger gap on quantized weights is the other runtime's: ggml quantizes
  activations to eight bits before every dot product against a quantized
  weight, and reads GELU out of a table indexed and stored in f16 whose own
  worst error is 0.002 an activation. Recorded in
  `tests/fixtures/embedding-runtimes.expect`, with the F16 agreement as what
  licenses saying whose arithmetic the difference is.

- **A real bert file found two things the fixture had invented.** The
  architecture was crossed in every shape and format against an independent
  implementation and agreed to 2.5e-06, and then a published
  all-MiniLM-L6-v2 was read and neither thing survived contact.

  It states no `bert.rope.dimension_count`, because there is no rotation to
  state, and the width is read with the head size as its default -- so every
  query and key of a model that never rotates was turned. The fixture wrote
  the key as zero, so the sweep compared a rotation-free engine against a
  rotation-free reference and agreed.

  And its vocabulary marks a word's *first* piece with U+2581 rather than
  marking continuations with two hashes, which is the reverse of what the
  architecture describes: of 30,522 pieces not one begins with the hashes
  and 23,695 begin with the marker. Written from the paper, the engine
  spelled every word out of continuation pieces -- "a" found the bare "a"
  that continues a word rather than the marked one that starts it. Nothing
  refused. Two unrelated sentences scored 0.479 where they score 0.007 now,
  and "unaffable" came back as one unknown where it now spells as
  una + ##ff + ##able, which is the canonical example and is published.

  Both are the shape of trap the gpt2 output bias fell into, and both were
  invisible to a sweep, a fixture check and a second implementation, because
  all three were written from the same description. `tests/fixtures/
  all-minilm-l6-v2.expect` records the published identifiers so the
  convention is pinned to something outside this repository.

- **The fixture check knows what a model has no reading of.** It asked every
  architecture for a token at a time and on every backend, which a model that
  attends both ways has neither of: there is no computing a position of it
  before the text it reads exists, so the single-token path is not a path it
  has and the backend that declines batching is not one it runs on. Those
  asks came back as refusals, which read as ten faults. They are counted as
  unasked now and reported beside the rest, because a check that quietly asks
  less of one architecture than of the others reports the same clean totals
  either way.

- **A repacked model moves its segment table too.** `Matrices` is the
  registry repacking walks, and it carried a comment warning that a view
  left pointing at the file's bytes while everything around it moved into
  the repacked buffer reads a row that is not there. Bert's segment table
  is exactly such a view and was not in the list, so `--repack` produced an
  embedding built on whatever those bytes now meant -- an answer rather than
  a refusal, which is why nothing but a comparison could see it. Found by
  the sweep at 3.59 worst absolute; 2.5e-06 with the table registered.

- **Bert's feed-forward takes the Gaussian unit.** Both the engine and the
  independent implementation left it off the list of architectures that do,
  so the two agreed with each other while both computing the logistic one.
  A second implementation cannot catch a mistake made in both, and this is
  what that looks like: the sweep was clean about it. `Gate_Unit`, which
  tells a device the same thing, was wrong the same way and is fixed beside
  it -- its own comment says the two must not come to disagree.

- **The conformance sweep names its first disagreement.** It counted them
  and said how far apart the two implementations got, which is what a gate
  needs; it said nothing about which of eleven architectures, five formats,
  five shapes, three repack modes and three backends the disagreement was
  in. Finding that out cost a run per guess. The first line of the output
  now names the combination.

- **The independent implementation evaluates block by block.** It ran a
  position at a time through every layer, which works only while a position
  depends on nothing after it. There is no order in which each position is
  computed after what it reads once attention goes both ways, so the loops
  are inverted: every position's keys and values for a block are written
  before any attention in that block reads one. For a causal model that is
  the same arithmetic in the same order -- every key a position reads was
  written before it looks -- and the sweep says so.

- **`Post_Norm` is reached through one place.** A sublayer joins a residual
  at four places in the engine, and two architectures now differ in which
  side of the addition the normalization falls on. Both are written in
  `Join_Residual` and the four call sites go through it, rather than the
  difference being repeated four times for three of them to eventually stop
  having.

- **The parallel arrangement is asked of the architecture.** Two evaluators
  decided whether a block's two sublayers read the same normalized input by
  testing whether the feed normalization was absent. Bert has no feed
  normalization either and does not run its sublayers in parallel, so the
  test read the absence as the arrangement and copied a batch into a buffer
  that had never been allocated. Both now ask which architecture it is.

- **The documents caught up with the device.** Five claims had gone stale
  while the device backend grew, and none of them was wrong when it was
  written. `docs/support-matrix.md` described the device as running products
  and named one shader, where it now attends as well, on both evaluation
  paths and a batch at a time, with a layer's attention and the projection
  that reads its blend in one command buffer; the same file's backend column
  still said "both" of a table with three backends in it. The README's
  opening paragraph said the model is evaluated on the CPU. The comment
  heading `Model_Runner.Backend.Device` still said binary32 only and pointed
  a quantized model at `--repack f32`, which the body of `Describe` a few
  lines away had already stopped doing. The matrix's sampling table stopped at the
  frequency and presence penalties, leaving tail-free, locally typical,
  exclude-top-choices, the sequence repetition penalty, mirostat, per-token
  bias and reported probabilities unnamed, and had no row at all for drafting
  or for a rolling context, which now have a section of their own.
  `SECURITY.md` did not mention that the fuzzing campaign reaches a shader,
  nor that opening a host's Vulkan loader is a trust surface the other two
  backends have not got, and now says both.

- **Five cutting rules called five.** The README said six and
  `docs/reference-runtime.md` said five, because one was counting the values
  of `tokenizer.ggml.pre` this build accepts and the other the rules they
  select: `starcoder` cuts as `gpt-2` does, `llama-bpe` as `llama3` does, and
  an absent key as `gpt-2` does. Eight names, five rules, said that way in
  both places.

- **A layer's attention and the matrix that reads its blend go over
  together.** One command buffer instead of two, and the blend never returns
  to the host to be sent again. It saves no time: with a layer's other
  submissions around it the difference is nothing, and on an idle device the
  joined pair is about a millisecond slower. The half-millisecond saving
  first recorded for it was an artifact of timing the two arms as separate
  blocks of rounds, which let machine drift land on whichever ran second;
  alternating them round by round reverses the sign and four runs then
  agree.

- **A batch of positions attends in one call.** The attention kernel takes a
  workgroup a head of a position where it took a workgroup a head, and the
  batched evaluator submits its whole batch at once instead of a position at
  a time. Positions of a batch read the same cache and write their own
  blends, so nothing makes them wait for each other. A 110-token prompt's
  attention over twenty-two layers falls from 0.618 s in 2420 calls to
  0.145 s in 22, and the run it belongs to from 2.894 s to 2.621 s -- past
  the 2.504 s it read before either change. Two push constants carry it: how
  many positions, and the layer's sliding window, which is needed because
  `First` can only speak for one position and a window moves with each.

- **Both evaluators attend on the device, not just the generating one.** A
  drafted run checks its proposals through `Evaluate_Batch` and generates
  through `Evaluate`; a device wired into the second only made the two say
  different things. They now share `Put_Position` and `Attend_There` rather
  than each carrying its own copy, and `Attend_There` owns the fallback to
  the processor as well -- both call sites previously reported a device that
  declined as a tensor gone non-finite.

### Fixed

- **A batched attention read back one position's worth of blend.** Whatever
  the batch size, the copy out of the device's result buffer was
  `Heads * Value_Size` floats, so every position after the first kept what
  was already in the target. Caught by the drafted-run agreement test.

- **The withdrawal of the device speedups is itself withdrawn.** The probes
  behind it ran against a stale test binary: `tests/bin/tests` links the
  library statically, and several probes rebuilt only the library. Rebuilt
  properly they all reverse -- cutting `Evaluate` short fails the run, and a
  wrong activation unit moves the digest. The path is live and the grouping
  was running. Re-taken with both crates verified to have built and
  interleaved, cf13815 reads 0.594 s and bef8293 reads 0.456 s: twenty-three
  per cent, as first reported.

### Fixed

- **The split experiment is explained, and the earlier explanation of it was
  wrong.** It was recorded as void because one half supposedly could not
  compile; it compiles. Both halves are slow because the saving needs the
  caller that groups and the `Run` that records several products into one
  command buffer, and each half has only one of them. No puzzle, and no
  compile failure -- which a `git show REV:path | grep` would have settled
  before it was asserted.

- **The batched path hands a device the whole gated block as well.** The
  combining step works over a batch now -- it is elementwise and both arms
  share a layout, so the layout does not matter to it. Worth about three per
  cent on a 522-token prompt, with overlapping spreads, against twenty-three
  on the token-at-a-time path: a batch already amortizes a submission across
  its whole width, so there is little left for this to remove. Kept for the
  host arithmetic it takes off the processor rather than for the three per
  cent.

- **A combining kernel for the middle of a gated feed-forward**, and the
  sequence step that runs it: a unit on one arm, multiplied by the other,
  with neither arm leaving the device. Tested against the same arithmetic on
  the host, within the width of a binary32 -- the device computes its
  exponential in binary32 and the host in binary64, so they agree that far
  and no further. The shader tool now carries several shaders rather than one.

### Fixed

- **The device speedups reported yesterday are withdrawn.** The wiring went
  into `Llama.Evaluate`, which generation does not call -- it reads through
  `Evaluate_Batch` even for one token. Three probes agree that the path is
  dead for the figure it was measured on: an early exit, an early return, and
  a deliberately wrong activation unit, none of which moved the digest. The
  measured difference between the two revisions reproduces, but splitting the
  change in half finds it in neither half, so its cause is unknown and no
  device speedup is claimed until one measurement isolates one change.

- **A chained product in a device sequence**, whose activation is what the
  product before it wrote -- it never leaves the device. A barrier stands
  between the two, because the second reads what the first wrote; products
  that share an activation have none and need none. Nothing in the engine
  chains yet: every pair of products it names has host arithmetic between
  them, and the kernels that would remove it are not written.

### Fixed

- **The device comparison figures were taken sequentially and are corrected.**
  Building two revisions alternately and running each three times, twice
  around, puts grouping at twenty-three per cent rather than eighteen. The
  same build also drifts a quarter between morning and evening at the same
  load average, which is larger than the effect being measured, so the
  absolute wall times are of their moment.

- **The gated feed-forward's two projections go to a device together too.**
  The gate and the up projection read the same normalized input and neither
  waits for the other. The device entry point generalized to a group of any
  size rather than gaining a second fixed shape. Seven tokens went from
  0.397 s generating to 0.385 s -- a smaller saving than the queries, keys
  and values gave, because grouping two products removes one submission a
  layer where grouping three removes two.

- **A layer's queries, keys and values now reach a device in one submission.**
  They read the same normalized input and none waits for another, so they are
  recorded together: one upload, one command buffer, one fence, three
  dispatches. Seven tokens on TinyLlama-1.1B-Chat Q8_0 went from 0.468 s
  generating to 0.396 s, and the digest did not move -- which is what three
  products sent together must produce if they are the same three products.
  The processor and reference backends do what they did; the difference lives
  in one subprogram rather than in every backend's interface.

- **A device sequence now runs in one submission.** Every product records
  into one command buffer against its own descriptor set and its own share of
  the result buffer, and the engine waits once for all of them. Acquiring the
  matrices and updating the descriptors moved ahead of recording, because
  neither can happen between two dispatches already written down. The
  products read the same activation and write disjoint results, so no barrier
  stands between them. Nothing in the engine records a sequence yet, so no
  published figure moves.

- **A descriptor set per step of a device sequence.** A descriptor update is
  not recorded into a command buffer -- it takes effect at submit -- so with
  one set two dispatches recorded together would both read whatever the last
  update named. The pool now holds one set per product a sequence may carry,
  which is what a single command buffer over several products needs. Nothing
  dispatches differently yet.

- **`tests fixture-likeness`, which compares a fixture against a real file.**
  Everything else here compares two implementations written together against
  a fixture written to suit them. This asks the other question: does the
  fixture resemble a model anybody ships? It folds layer indices together and
  reports names each side has and the other does not.

### Fixed

- **gpt2's feed-forward normalization ran without its shift, and uncentred.**
  Every published gpt2 carries `blk.N.ffn_norm.bias`; the engine read every
  other layer-norm shift and not that one, and took the root-mean-square path
  where the architecture centres. Found by `fixture-likeness` on its first
  run, on the first file it was pointed at. The sweep could not see it: the
  reference did not read the tensor either and the fixture did not write one.

- **Every architecture the sweep crosses has now been read from a published
  file.** llama, gpt2, qwen2, qwen3, gemma, gemma2, gemma3, phi2, phi3 and
  falcon, each loaded, generated from, and checked for determinism and
  thread-stability by `tests external-model`. It was two this morning. Only
  gpt2 needed the engine changed to get there; the other eight loaded as
  written. The eleventh architecture, qwen3moe, still has no published file
  behind it, and the figures file says so rather than letting the count
  round up.

- **A figure for gpt2, on a published gpt2.** Twelve tokens in 0.253 s
  against TinyLlama-1.1B's 1.871 s, and `external-model` validates it:
  deterministic and thread-stable, 149 tensors, 163 million parameters. The
  comparison measures size rather than the absence of a rotation -- seven
  times faster on about a seventh of the parameters -- and the figures file
  says so, because a figure quoted for the wrong reason is worse than none.

- **What the byte cache costs on a device, measured.** 1.169 s against
  1.151 s for twelve tokens -- inside the spread between two runs, as on the
  processor. It had been agreeing there since the crossing was added and
  nothing had timed it.

- **One place says which architecture cannot hold which shape.** The sweep
  and the fixture check each declared the same four pairs, one to skip them
  and one to confirm they refuse, and two hand-kept copies of a fact is one
  more than can be kept true. `Tiny_Model.Cannot_Hold` is that fact now,
  beside the mapping that says what a shape is, and both read it.

- **One place says what a shape is.** The conformance sweep and the fixture
  check each built every architecture in every shape, and each said
  separately what a shape meant -- the sweep gave a stretched fixture its
  table of per-dimension divisors and the check did not, so `stretched` named
  two different files. The check passed a shape the sweep refused, 450
  comparisons went missing, and both halves reported themselves clean.
  `Tiny_Model.Build_Shaped` is the mapping now and both build through it, so
  the two cannot drift rather than being checked for drift.

- **The sweep declares the shapes it skips, in one place.** Its two skips
  were `goto` statements with comments, and the expected-sequence arithmetic
  restated the same fact in two more terms -- one added when falcon needed it
  and another when gpt2 did, so a third architecture would have wanted a
  third. The pairs are declared once now, and both the skip and the count
  read that declaration. Same figures to the digit: 26910 sequences, none
  outside tolerance.

- **The fixture check asks which shapes an architecture cannot hold.** Both
  of gpt2's skips were found by something breaking: a mixture handed to an
  architecture with no gate to route to, and a stretched rotation handed to
  one with no rotation, whose table of per-dimension divisors then has no
  elements. The four pairs are declared now, with the reason beside each, and
  the check tests both directions -- a pair outside the table that refuses
  fails, and a pair inside it that loads fails too, because a skip nothing
  needs costs the sweep comparisons it could have made.

  It also found why this check had been blind to the second one: it built a
  stretched fixture without the divisor table the sweep builds, so "stretched"
  meant one thing here and another there. Two builders of one shape have to
  build the same shape, and now they do.

- **The `gpt2` architecture.** The oldest shape here and the only one that
  does not rotate: it learns where a token is, one row a position added to
  the token's row before the first layer. Everything else it needs already
  existed -- `phi2`'s biases on every projection and centred normalization,
  llama's two normalizations a block, a feed-forward with no gate.

  Crossed with every format and both evaluation paths: 26910 sequences, none
  outside tolerance, none unlearned.

  It found a third defect, and the oldest. The table of positions is a matrix
  like any other and repacking rewrites every matrix it knows about -- this
  one was not on the list, so with --repack the view still pointed into the
  file bytes while everything around it had moved, and 689 evaluations were
  refused for reading a row that was not there. Every refusal carried a
  repack and none carried NO_REPACK, which is what said so.

  It found a defect of this build's own on the way in. `rope.dimension_count`
  was read with a minimum of one, so a model stating zero -- which is what a
  model with no rotation states -- was refused before anything else could
  happen. Any gpt2-family file would have been turned away, and nothing here
  had ever stated a zero to find out.

- **The fixture check asks whether the set of tensors is right, not only
  whether each is read.** A tensor the engine reads and the independent
  implementation never asks for is a disagreement about what an architecture
  carries, and the sweep cannot report it because it compares answers rather
  than appetites. `Load` records every name it asks the container for, and
  the check holds the file's tensor list against that. It reads zero, which
  is the answer I wanted and not the one I expected: the falcon fixture wrote
  a projection twice for a week and this is the check that would have said so
  on the first run.

- **The figures record the host that took them.** An AMD Ryzen 7 7840U with
  sixteen threads, and an integrated Radeon 780M whose compute family has one
  queue. The load each run carried has been written down for months and what
  carried it never was, which is half a condition recorded twice.

- **A run on a device says how many queues its family has.** The number was
  read to choose the family, kept last commit, and visible only to a test.
  Now the run prints it, and the answer on this host is one -- so submitting
  to a second queue is not something this machine could be made to do, and a
  figure comparing one against two cannot be taken here at all. That is worth
  more than the feature would have been: it says the work is not merely
  unwritten but untestable here.

- **Every figure group names the model it was taken with, and a check
  requires it.** The drafting row is unreproducible because its second model
  was requantized locally and nothing recorded the source or the tool; six
  groups had the same silence and only the external-model record named its
  file. Each group now carries a `# model:` line -- "none" being the answer
  for the groups that time kernels on tensors this tool builds itself -- and
  a group without one fails the gate.

- **The device reports how many queues its family offers.** This program
  submits to one and waits on it. Whether it could submit to two is a fact
  about the host, and the layer already read the number to decide the family
  was usable and then dropped it. It is kept and asserted now, which is the
  question that comes before the policy rather than the policy.

- **A check that every message key has its pseudo-locale twin.** Three keys
  went in without one over the last few commits, and what said so was four
  assertions naming symptoms -- a key renders identically under
  pseudo-translation, a partial locale will not load -- plus a fifth about a
  backend, because a catalog that will not load takes everything downstream
  with it. None of them said "you added a key and not its twin". This one
  does, by name, at check time.

- **Each built-in chat format held against the turns its architecture
  reads.** The four renderings are written out rather than derived, because a
  rendering derived from the template it checks agrees with itself. The test
  also fails when a format is added to the enumeration and not to it.

- **The `gemma` and `phi3` chat formats.** `--chat-template` offered two
  where four of the nine architectures this build reads carry templates it
  matched neither of. Phi-3's writes the role straight into its markers.
  Gemma's is the one format here that calls the assistant something else --
  its turns are "user" and "model" -- so the role a caller gives is mapped
  rather than written through, which is why it needs a comparison the other
  three do not. The template compiler already had `==`; nothing new was
  needed under it.

- **A check that no model file sits inside the repository.** A machine that
  takes the published figures has models on it and the smallest is four
  hundred megabytes; one copied into the tree for convenience would be
  ignored by git today and packaged by the release tomorrow, and nothing
  asked. The generated fixtures stay exempt: they are kilobytes and this
  program writes them itself.

  It found nothing, and the run that added it found something else -- the
  check that every option a command takes is documented caught `inspect
  --kv-cache`, which I had added without a help line.

- **`inspect --kv-cache MODE`.** It reported what a session would take at the
  default precision only, so the two lossy storages could say what they saved
  in arithmetic and not in a number the program produced. On
  TinyLlama-1.1B-Chat Q8_0 at 2048 tokens: 97,251,904 bytes exact, 48,807,695
  halved, 24,585,588 in bytes. `Plan_For` had taken the precision all along;
  `inspect` was the one caller that never passed it.

- **What the byte cache costs in time, measured.** Twelve tokens of
  TinyLlama-1.1B Q8_0: 1.912 s with it against 1.871 s without, which is
  inside what two runs of the same figure differ by on this machine. What it
  does change is the text -- the same twelve tokens come out as
  `7d3e2df2d776ba62` against `5abff916f9d83ca6`, so at this size the storage
  has already moved what the model says. `tests speed` takes `--kv-cache
  MODE` now, because a figure about a storage has to be taken by the tool
  that takes every other figure rather than by a stopwatch beside it.

- **`--kv-cache q8`: the context in one byte an element.** A third precision
  beside the exact and halved ones, with a scale for every row -- one
  position's keys, or its values, for one layer, which is the unit the
  evaluator already writes and reads whole. One scale for a whole context
  would be set by whichever position held the largest key and would quantize
  every other position against it.

  A quarter of the memory the exact cache takes. 0.303 worst absolute across
  the sweep against 0.0092 for the halved cache and 1.8e-5 for the exact one,
  measured over every architecture, shape and format it crosses, with a bound
  of 0.4 rounded up from what was measured. Both evaluation paths, every
  swept backend: 24912 sequences, 21600 of them in the byte cache, none
  outside tolerance.

  It runs on the device as well, on the first format the shader reads: what a
  session rounds is its own doing, and what crossing it with a device adds is
  whether products computed there read a rounded row back the way products
  computed here do. 24939 sequences, 22032 of them in the byte cache.

  The saved-context format is unchanged: it stores four bytes an element
  whatever the session holds, so a context written by one precision restores
  into another. `Shift` handles it by decoding a row, turning it back and
  packing it again -- which rounds a rounded row a second time, and the
  README says so where it says what the storage costs.

- **`--device N`.** Which of the host's devices to compute on, counting from
  one in the order `inspect` already lists them. The backend opened whichever
  the host named first and said so in a comment; a machine with an integrated
  device beside a discrete one had no way to choose. A number past what the
  host has is refused rather than fallen back from, and the chosen device is
  kept beside the budget and the sharing policy in what decides whether an
  already-open device can answer the next Open -- the same reason those are
  kept.

- **The `falcon` architecture.** The first here whose block is arranged
  differently rather than whose details differ: attention and the
  feed-forward both read what the layer normalized on the way in and both add
  to the same residual, so there is one normalization a block instead of two.
  That normalization subtracts the mean and divides by the standard deviation
  and carries a bias beside its gain, which is a different computation from
  the root-mean-square form the others use rather than a parameter of it. The
  feed-forward has no gate: one projection up, a Gaussian error unit, one
  projection down. Queries, keys and values are fused as phi3 fuses them.

  Crossed with every format and both evaluation paths: none outside
  tolerance.

- **The `phi2` architecture.** Falcon's arrangement -- one normalization a
  block, attention and the feed-forward reading it in parallel, a centred
  normalization carrying a bias, no gate -- with a bias on every projection
  rather than on none. The three attention biases are one vector as their
  matrices are one tensor, taken at the same offsets; attention's output and
  both sides of the feed-forward carry one each; and the output projection
  carries one that is added to every logit. That last one is added where the
  bound on the logits is applied, in the single place all three paths that
  produce logits call, rather than beside each of them.

  Crossed with every format and both evaluation paths: 23535 sequences,
  322560 logits, none outside tolerance.

- **A check that asks whether a fixture can fail.** Every tensor of every
  architecture's fixture is moved in turn and the model evaluated again; a
  tensor no logit answers to is reported and fails the gate. A comparison is
  worth what its fixture is worth, and a tensor nothing reads makes every
  comparison over that fixture weaker than its count suggests. `tests
  fixture-check` runs it alone; the gate runs it after the conformance
  sweep.

  It found what it was written for immediately: phi2's first fixture wrote
  its fused bias in the format of its weights, so a quantized phi2 file
  carried a bias no reader that asks for a plain vector would take.

- **The fixture check asks its question of every shape, format and path.** It
  moved one fixture an architecture -- binary32, plain, a token at a time on
  the processor -- so a tensor only a mixture writes, or only a stretched
  rotation, or only the batched path or the shader reads, was never moved at
  all. It now crosses all five shapes with five formats and four combinations
  of backend and path: 17975 tensors moved where 229 were before, in half a
  minute. A tensor that does not answer is moved sixteen times as far before
  it is called unread, because whether anything reads it and whether this
  fixture is sensitive to it are different questions; the ones that answer
  only to the larger move are counted and reported.

  What it found, and what is not yet explained: in the fixture the superblock
  formats are built at, qwen2's key bias can be moved by sixteen without
  changing a single bit of a single logit. The bytes do change -- they were
  read back and compared -- and the engine resolves a bias of the right width
  and adds it to the key row before the rotation, where it belongs and where
  the independent implementation adds it too. Both implementations agree,
  which is exactly why the conformance sweep cannot see it. It is named in the
  check with the reason, counted separately, and reported on every run so that
  it stays visible; anything else that stops answering fails the gate.

### Changed

- **The suite no longer runs the conformance sweep, and takes eight seconds
  instead of twenty-eight minutes.** One routine called `Conformance.Run`,
  which the gate already runs as a stage of its own, so the engine was
  compared against the reference twice a gate -- 948 s inside the suite and
  650 s beside it. The sweep still runs, once. `tests test` on its own no
  longer makes that comparison; the gate and `tests conformance` do. The
  suite's bound in the gate comes down from 2900 s to 60.

- **`tests slow`, which says where the suite's time goes.** Each of the nine
  cases run on its own and timed, or one test named by a prefix. It reports
  that 99.5 per cent of the suite is the inference case, and that 948 s of
  that case is one routine -- the comparison against the independent
  reference, which the conformance stage also performs for 650 s of its own.
  The cli case, holding every device test, is 3.2 s.

- **The gate times its first stage.** It ran the suite and then reported the
  time of every stage after it, so a suite that had grown to twenty-four
  minutes was invisible in the gate's own accounting. `took: suite` now
  appears beside the other four, with a bound of 2900 s.

### Fixed

- **The README said the suite takes a second and a half.** It takes 1443 s on
  the host the figures name. The old number had been true once and nothing
  re-measured it; combined with AUnit printing nothing until it finishes, it
  made every timeout set from it look like a hang.

- **An attention kernel for the device**, `attention.comp`: one position
  against everything a cache holds, with the softmax folded into the pass that
  computes the scores so nothing is stored per position. Keys and values share
  a buffer rather than widening the pipeline layout for every shader. Checked
  against the same arithmetic in binary64 to under 1.0E-5, and checked by
  breaking it. Not wired to the engine and unable to pay until the cache stays
  on the device between tokens, which is the next change.

- **The halved cache is compared with products computed on a device.** Every
  comparison of it had been against a processor: the cache is the session's
  doing rather than the backend's, so nothing had crossed the two. It runs on
  the first format the shader reads, a token at a time and in one pass --
  once rather than fifteen times, because what a weight is encoded in has
  nothing to do with what the session rounds. 23562 sequences now, 22032 of
  them cached, none outside tolerance.

- **The fixture check measures sensitivity again, as its own question.** Its
  threshold for a logit having moved was the sweep's absolute tolerance until
  that hid six tensors which had moved; the threshold sits at the noise floor
  now, and what the old one accidentally measured was left unmeasured. A
  tensor that answers by less than a comparison would call a disagreement is
  counted as quiet and the fixture holding it is named: a mistake of that
  size, in that tensor, in that fixture, would pass the sweep unremarked.
  Sixty-five of the 22195 are quiet, across thirty-eight fixtures, and each
  is named beside its fixture rather than only counted: what is worth acting
  on is which part of a fixture is quiet.

  All sixty-five are gemma3's, and nearly all are the queries, the keys and
  the gains that normalize their heads, in its last two blocks. That is quiet
  for a reason rather than a fixture wanting repair: gemma3 normalizes every
  query head and every key head against itself before the rotation, which
  removes exactly the magnitude a displacement changes, and it is the only
  architecture here that does that and is also built deep enough for the
  effect to show. What it means for the sweep is written where the measure
  is: an error in gemma3's late query and key projections has to be larger
  than a quarter before those comparisons would report it, and every other
  architecture's every tensor answers louder than that. It is not a failure
  and does not fail the gate -- it is the measure the sweep cannot take of
  itself.

### Fixed

- **GPT-2 has no output bias, and now this build agrees.** The loader
  required one because the synthetic fixture wrote one, so the sweep agreed
  with itself about a model nobody ships: a real gpt2 file refused to load
  with `MR-ARCH-0010`. The loader, the independent implementation and the
  fixture all say the same thing now, and a published gpt2 -- 149 tensors,
  163 million parameters -- loads and generates.

  A fixture and an engine can share a wrong idea, and no amount of agreement
  between them will say so. Only a real file will.

- **A file that ends in padding is read.** GPT-2 as published carries sixteen
  bytes after its last tensor against an alignment of thirty-two, and this
  refused it outright: `MR-GGUF-0025`, a real file no other runtime objects
  to. Trailing bytes are accepted now when there are fewer of them than one
  alignment unit *and* every one is zero, which is what padding is; anything
  longer, or anything non-zero, is still an undeclared run of bytes inside a
  mapped file and still refused.

  The zero test needed the reader to look at the bytes rather than judge the
  tail by its length, so the validation now takes the source it is
  validating. Both fuzzing campaigns run over it: 200 containers and 300 text
  cases, nothing escaping.

- **Gemma3 is built with six blocks, so the layer that sees everything
  exists.** Its window falls on five layers in six and the sixth attends to
  the whole context on a rotation base of its own. Every fixture had two
  blocks, so that sixth layer was never built: the engine described it, the
  independent implementation described it again, and nothing compared them.
  The check that moves tensors is what said so -- there was no `blk.5` to
  move.

- **The fixture check asks whether a tensor is read, not whether the sweep
  would catch a mistake in it.** A logit counted as having moved when it
  moved by more than the conformance sweep's own absolute tolerance, which
  conflated two questions and hid six tensors of gemma3's sixth block whose
  logits moved by two parts in a hundred thousand -- eleven orders of
  magnitude above what binary32 does on its own, and reported as read by
  nobody. An evaluation here is deterministic, so a logit that differs at all
  differs because the model did; the threshold is just above the noise now.
  What the old one measured is what the faint count already reports.

- **The check copied whole files onto the stack.** Every evaluation copied
  the image into a frame constant and every mutation copied it again. At two
  blocks of eight elements that is nothing; at six blocks of two hundred and
  fifty-six with a mixture behind each it is a storage error rather than a
  slow test. Both copies are on the heap now, and freed.

- **A fixture whose attention had already decided.** The deep fixture the
  superblock formats are built at draws its weights over two hundred and
  fifty-six elements, and an attention score is the product of two
  projections summed over that width: its scores read 32.3 against 20.2,
  which is a softmax at about a hundred and sixty thousand to one. One
  position carried every head, so the queries and keys of that fixture could
  be moved almost freely without changing a logit -- which is why qwen2's key
  bias could be moved by sixteen and come out bit for bit the same, and why
  sixteen other tensors answered only to a move sixteen times the size. It
  was not a defect in the engine: both implementations add that bias where it
  belongs, and agreeing is why the conformance sweep could not see it.

  The queries and the keys are now drawn with an amplitude that falls with
  the square root of the width, which keeps a score the size it is in the
  narrow fixture. Only those two: scaling every weight that way was the first
  attempt, and it moved the problem rather than fixing it -- the scores came
  back to size and the whole of what a layer contributes went under what
  gemma3 carries in its residual from multiplying the embedding by the square
  root of the width, so its second layer stopped answering at all. What a
  score is made of is what had to shrink.

  Every one of the 17975 tensors the fixture check moves now answers to the
  ordinary displacement: none unread, none faint, and the named allowance the
  check carried is gone rather than merely unused. The comparisons tightened
  with it -- the worst exact divergence across the sweep fell from 6.6e-5 to
  1.8e-5, the halved-cache one from 5.4e-2 to 9.2e-3, and the rounded one
  from 2.2e-1 to 1.0e-1. A fixture that cannot feel a mistake was also a
  fixture whose agreement meant less than it looked.

- **A feed-forward that was computed and discarded.** The ungated arm ended
  after the activation, and the projection down and the residual add sat
  inside the gated arm below it, so falcon ran with attention only -- in both
  the single-token and the batched path. The two arms differ only in how they
  fill the buffer now, and what follows is written once where neither can
  skip it. The batched path's last normalization, the one that produces the
  logits it returns, had the same shape of mistake: it called the
  root-mean-square kernel directly, so falcon was centred everywhere except
  in its answer.

- **A fixture that said two things about one projection.** The falcon fixture
  wrote its queries, keys and values fused into one tensor and then wrote
  separate key and value tensors beside them, because the guard that skipped
  those named an architecture rather than naming the arrangement.

- **A conformance sweep that skipped an architecture in silence.** A
  comparison whose reference has no answer returned before it compared
  anything, so an architecture the independent implementation could not load
  was passed over without a trace -- and the totals came out identical, to
  fifteen digits, to a run without it. Phi2's first sweep reported falcon's
  figures and read as a pass. Fixtures the reference will not load or run
  are counted now, reported beside the tolerance count, and a run with any
  of them is not clean.

- **A displacement that could not move a centred model.** The fixture check
  first moved every element of a tensor the same way, which adds a constant
  to each row a projection produces -- exactly what a normalization that
  subtracts the mean removes. The two architectures that centre reported
  their output projections, their down projections and their embedding table
  as read by nobody. Alternating the sign failed the same way, because a row
  of even length holds the same alternation as every other row. The
  displacement follows a hash of the element's index now, which has no
  period to line up with a row length.

### Fixed

- **A stage's timing bound no longer fails the gate on a busy machine.** Its
  message admitted it could not tell "either the machine was busy or the stage
  grew"; now it can, by the rule this repository already applies to every
  figure it prints. Above `Host_Load.Publishable` an overrun is reported and
  not counted; below it, it fails as before. Conformance read 648, 992, 1505
  and 1794 s in one day against a bound of 1250, and the machine was the
  difference every time. The bound itself goes to 3000 s: two quiet readings
  of the same stage differed by 2.3 times, so a bound meant to catch a
  doubling cannot be tighter than that. Processor time would be the better
  instrument and is not adopted here.

- **`tests device-bench`, and an attention kernel that is worth twenty-five
  times what it was.** A workgroup a head instead of one invocation, a cache
  left on the device instead of re-sent per call, and a standing mapping
  instead of one per write: 9.98 ms to 0.395 ms for thirty-two heads across
  five hundred positions, 0.52 to 13.0 Gflop/s, and a cache write from 1.6 ms
  to 0.26 us. The processor does the same attention in 0.85 ms.

  Not wired to the engine. End to end it still loses -- 0.654 s against
  0.150 s at 522 cached positions -- and the attention calls account for
  seventy milliseconds of that, so the rest is unexplained and nothing is
  claimed for it.

- **The `phi3` architecture.** Nothing in its arithmetic differs; everything
  about where its weights are does. The queries, keys and values are one
  tensor and the gate and up projection another, and a part is taken out as a
  view at a row offset rather than copied -- which works because a row is a
  whole number of blocks in every format this reads, so a part begins on a
  block boundary. Repacking then rewrites each part as its own tensor, so a
  repacked phi3 model is no longer fused at all.

  Crossed with every format and both evaluation paths: 19005 sequences,
  262080 logits, none outside tolerance.

### Fixed

- **A fixture that made a new architecture look wrong.** Phi3's first sweep
  disagreed on 72 logits, all in the halved-cache and rounded sets, and its
  exact comparisons sat at 4e-4 where every other architecture agrees at
  2e-5. The cause was the fixture: weights are drawn per tensor, so writing
  three projections as one tensor drew a different random model, and the
  lossy tolerances measured on the others did not describe it. The fused
  tensors are drawn as their parts now, in the order the unfused
  architectures draw them, so a phi3 fixture is a llama fixture with its
  weights in fewer places -- and the sweep compares like with like instead of
  calling the difference between two random models a tolerance. Every
  comparison agrees, and the exact set is back at 2.6e-5.

### Changed

- **Stage bounds are held against processor time, not wall time.** What a
  stage costs the machine barely moves when something else runs; what it costs
  the clock moves by more than the doubling a bound watches for -- conformance
  read 1741.85 s and 962 s of wall for the same work, and 1757.39 s of
  processor time. All five bounds and the whole-gate bound are re-derived from
  processor readings. Where a host reports no such number the bound is
  reported and not held, rather than silently falling back to the wall.

- **The `gemma3` architecture.** It keeps gemma2's two normalizations a
  block, drops its two bounds, normalizes query and key heads as qwen3 does,
  windows five layers in six rather than every other one, and turns those
  five on a rotation base of their own -- so a layer's base depends on where
  it sits in the pattern, which is the first architecture here where one
  model turns on two.

  Crossed with every format and both evaluation paths: 16290 sequences,
  224640 logits, none outside tolerance.

  The two implementations disagreed twice before they agreed, and both were
  the same shape of mistake. The reference loaded query and key head norms
  for qwen3 only, so it computed a model without them while the engine
  computed one with -- 36643 logits. Then the engine turned a layer's whole
  rotation on that layer's base while the reference used the model's base for
  the band a stretched rotation mixes across and the layer's for the
  frequency -- 8 logits. A base is a property of the rotation, so it decides
  the band as well, and the reference says so now.

- **A test for the conformance verdict:** a run that could not evaluate
  something is not clean, whatever its comparisons say. The counter that
  makes that true was added yesterday and nothing exercised it, which is the
  absence it was written to close.

### Fixed

- **A closed device engine kept its key-and-value cache allocated and
  mapped.** `Close` released the vector and result buffers and left the
  cache, with the mapping pointer still set; the next `Reserve` then unmapped
  and freed handles belonging to a device that had gone. Latent while nothing
  called `Reserve`, and immediate once anything did: a suite that opens and
  closes a device once a test aborted with `malloc(): unaligned tcache chunk
  detected`, and in another run with a glibc thread assertion -- one stale
  pointer, two symptoms.

- **`tests device-bench` gained the rows that answer where a device attention's
  time goes.** The kernel at the engine's own shape; the same walking every
  layer's region; a matrix product alone; four products around one attention;
  and weights cycled with and without a cache reserved. Timed inside a layer
  the call reads 0.537 ms, matching the benchmark -- so the call is not what
  is slow. What is slow is a wired run at sixty-four tokens, 81.6 ms a token
  against 4.4, which is not a per-call cost at all. Five explanations have been
  measured away; the cause is unknown and nothing is wired.

- **`tests device-bench` measures the engine's own shape and its neighbours.**
  The attention kernel at thirty-two heads sharing four groups of keys across
  a ninety-megabyte cache; the same walking every layer's region rather than
  one; a matrix product alone; and the two together. Enough to say that
  attention costs 0.35 to 0.54 ms alone and about 2.55 ms inside a layer, and
  to rule out machine load, the shape, and cache locality as the reason.
  What remains -- the cost of submitting beside a layer's other work -- is
  measured at between 0.7 and 1.8 ms beside a single product and is not
  settled.

- **The `gemma2` architecture:** `gemma` and four more differences, each
  silent when missed. A normalization after each sublayer as well as before
  it, required where the architecture states them; a bound on the attention
  scores and another on the logits, each the scaled hyperbolic tangent the
  architecture states, applied before the softmax reads a score and after the
  last projection produces a logit; and a sliding window on every other layer
  rather than on all of them.

  Crossed with every format and both evaluation paths against the independent
  implementation: 13575 sequences, 187200 logits, none outside tolerance.

### Fixed

- **A conformance sweep that passed over what it could not evaluate.** A
  comparison whose evaluation ended in a diagnostic was not counted, nothing
  was compared, and the only trace was that the total came up short against
  what the sweep expected to run. Three hundred of them -- every gemma2
  single-token comparison, failing on a buffer that was too small -- left
  exactly that trace and nothing else. Refused evaluations are counted and
  reported now, and a run with any of them is not clean.

  Two bugs took an afternoon to find behind that silence: the post-norm
  borrowed the query buffer, which is a head wide rather than an embedding
  wide; and the fix for that dereferenced a buffer allocated only for the
  architecture that needs it, at call sites reached by every architecture.
  The first cost 300 comparisons, the second 7320.

- **The attention bound cost every architecture.** Applied inside the loop
  that forms a score it was a test per score: twelve tokens went from 1.83 s
  to 2.07 s and the processor time from 10.5 s to 11.8 s, for a feature one
  architecture of six uses. It runs in a loop of its own now, entered only
  when there is a bound, and the figure is back to 1.832 s and 10.51 s.

### Added

- **The `gemma` architecture.** The same shape as the four already here with
  three differences, each of which produces a plausible wrong answer rather
  than a refusal when it is missed: the normalization gain is one plus the
  stored weight, because the weights are trained around zero; the embedding
  row is multiplied by the square root of the embedding width before the
  first layer; and the feed-forward gate is a Gaussian error unit in its
  hyperbolic-tangent form rather than a logistic one.

  Crossed with every format and both evaluation paths against the
  independent implementation, because the three touch every part of a pass
  rather than a metadata prefix. The sweep is 10860 sequences and 149760
  logits now, none outside tolerance.

  The fixture writes its normalization weights around zero rather than
  around one, which is what the convention means: written around one, a
  reader that missed the lift would answer almost correctly and the fixture
  would prove nothing.

  Not implemented: the second and third generations, which add attention and
  final logit softcapping, alternating window widths and a second pair of
  norms a block.

### Changed

- **The row-product table moved by up to a factor of two, and no decoder
  changed.** Q4_0 went from 0.33 ns an element to 0.59, IQ4_NL from 1.44 to
  0.59, IQ4_XS from 0.95 to 0.48, Q2_K from 0.79 to 1.01. What changed is
  that the kernels body gained a procedure -- the Gaussian gate -- which no
  row product calls.

  Two runs an hour apart agree on the new numbers, so it is not the machine.
  Adding a subprogram to a hot compilation unit moves what the compiler does
  with the rest of it, and that unit is where every decoder lives. The
  published table is the new one; the old one was the same code compiled
  beside different code, and neither number is evidence about a decoder.

### Added

- **`--wait MINUTES` on `tests speed` and `tests benchmark`,** which waits for
  the machine to go quiet instead of refusing it. Every figure retaken this
  week came through a loop that polled the load and started the tool when it
  fell -- a shell script outside the repository, which is both the wrong
  language for this project and the wrong place for a thing every measurement
  needs. It says what it is waiting for while it waits, and gives up with a
  failure rather than measuring something not worth publishing.

### Changed

- **The pinned scaling figures retaken,** which was the last group recording
  no load. At a load of 1.03 rising to 2.68: eight shares reads 10122 Me/s
  with one vector against the published 12420, and seven reads 10713 against
  12007 -- so the peak at seven that the last change removed is back, at six
  per cent where it used to be a quarter. Batched there is no peak at all,
  21234 at eight against 21035 at seven.

  The four-bit against eight-bit numbers swapped sides: four-bit now leads
  serially and batched and trails at eight shares with one vector, where last
  time it was the reverse. Two runs disagreeing about which is ahead at one
  shape is what level looks like, and the README says that rather than
  picking whichever run reads better.

### Changed

- **The worker-count comparison retaken, and the reasoning built on it
  rewritten.** Fourteen threads takes 1.54 s of wall and 16.1 s of processor
  time against seven at 1.88 s and 10.4 s, both at a load of about 1.25. That
  is eighteen per cent off the wall for fifty-five per cent more processor
  time, where the paragraph said six per cent for seventy.

  Six per cent for seventy is a bad bargain that argues for itself; eighteen
  for fifty-five is a real trade. The default of one worker per core stands,
  but on the energy alone -- the same tokens for two thirds of the processor
  time, on a fifteen-watt part where that is heat and battery. A caller who
  wants the wall can ask for `--threads 14`.

- **The tokenizer figures taken by the tool:** 0.0098 s for sixty thousand
  ordinary characters and 0.0127 s for sixty thousand brackets, at a load of
  1.12, against 0.039 and 0.045 timed in the shell. The older pair measured a
  whole `model_runner run` -- parse, load the vocabulary, encode, refuse for
  length -- and was quoted as the tokenizer's cost. These are the encode.

- **The row-product table and the thirty device ratios** republished from the
  same run, at a load of 1.12 rising to 2.03.

  One group is left recording no load: the pinned scaling figures, whose run
  needs a longer quiet window than this machine has offered.

### Added

- **`tests benchmark` times the tokenizer,** on sixty thousand ordinary
  characters and sixty thousand of the same bracket. Those were the last
  figures here taken by the shell rather than by a tool, which is why they
  were the last with no load beside them. What the tool reports is narrower
  than what the shell timed and more useful: the encode alone, where the old
  figure was a whole `model_runner run` -- parsing the model, loading the
  vocabulary, tokenizing, and refusing the prompt for length.

### Added

- **`tests speed` reports processor time,** taken around the same region as
  the wall time so the two answer about the same work. That was the one
  figure in the README that came from the shell, on the reasoning that
  totalling processor time across worker tasks needs a host call bound per
  platform. It needs the same file the load comes from, which this already
  reads. A figure from the shell is a figure with no load beside it.

- **A check that a tool publishing a timing reports a load.** The figures
  file is held to recording one, which covers the numbers already published;
  this covers the tools, so a new one -- or an old one that starts printing a
  duration -- cannot produce figures with no conditions attached. `tests
  external-model` is the stated exception, and the reason now lives in that
  file where somebody editing it will see it, because the check reads it
  there: an exception whose reason has quietly gone is an exception nobody
  decided on.

### Changed

- **The twelve-token figure retaken with its processor time:** 1.88 s wall
  and 10.4 s of processor time at a load of 1.28 to 1.82, against 1.37 s and
  a 9.3 s that came from `/usr/bin/time`.

  The worker-count pair beside it was not retaken and is now labelled the
  oldest figures here. Each half of that comparison needs its own quiet
  window, and the machine offered one rather than two: the tools refuse above
  a load of 1.5 and it sat above that nearly all day. The conclusion does not
  turn on the third digit, and saying they are old is not the same as
  pretending they are current.

### Changed

- **Three figure groups retaken with their loads recorded,** which is what
  the load lines were added for. Every one of them moved by more than the
  code changes between then and now can account for: the twelve-token figure
  from 1.37 s to 1.87 s, the reference comparison from thirteen times the
  work to eleven, the drafted run from 4.094 s to 5.705 s and the check of
  five positions from 396 ms to 540 ms.

  That is the argument for recording the load, made by the figures
  themselves. The older ones were taken on a machine whose state nobody
  wrote down, so nothing can say how much of each gap is the machine and how
  much is the program. From here on something can.

  Two groups still say unknown: the pinned scaling figures and the
  tokenizer's, which was timed by the shell. The count is reported by the
  gate and comes down as groups are retaken.

### Added

- **`tests check` finds the line that breaks a catalog.** The runtime refuses
  a catalog whole -- one line it cannot compile and nothing renders, in any
  locale, with no indication of where. Finding the last one took a bisection
  by hand. This does the bisection: eleven opens rather than eleven hundred,
  and the failing line comes back in the diagnostic.

  Proved on every run against a planted fault, because a search only
  exercised on the day something breaks is a search nobody knows works. The
  planted fault is a line with a key and no value: one line, and understood.

- **`tests speed` refuses to measure on a busy machine,** on the same bound
  as `tests benchmark` and for the same reason, with the same `--anyway`. The
  bound now lives beside the load reader rather than in one tool, because the
  rule is about figures and not about any one measurement: the same host was
  too busy for one set of published numbers and fine for another.

- **Every figure group records the load it was taken under,** and `tests
  check` refuses a group that says nothing. A group may say the load is
  unknown -- five do, and have to, because their figures predate the tools
  printing one -- and the check reports how many, so the number is visible
  and can only come down as figures are retaken.

### Fixed

- **The explanation for the `{seconds}` failure was wrong and is corrected in
  the catalog beside it.** What was measured is that with that placeholder in
  one message and its pseudo-locale twin, the catalog stopped loading and
  renaming it fixed it. The same name planted in other messages does not do
  it, so it is a fact about one line rather than a rule about a name, and
  yesterday's note said otherwise.

- **`--device-patience N`** says how many seconds to wait for one product
  before giving up on the device. The default of a minute is far longer than
  any product on any machine this has run on, and that is a guess about
  hardware -- which is exactly the guess a caller with different hardware has
  to be able to correct. A model wide enough on a device slow enough can take
  longer than a minute for one product, and that caller had no way to say so.
  Naming it where the run is not on a device says so rather than looking as
  though it worked, as `--device-memory` already does.

  How often the wait asks whether you want to stop is not an option and stays
  at twenty milliseconds: that is a responsiveness number rather than a
  hardware one, and nobody notices the difference between twenty
  milliseconds and five.

### Changed

- **A device that stops answering has its own diagnostic.** It borrowed the
  one for a machine with no device at all, which sends a reader the wrong
  way: there is a device, this model and this request are fine, and what a
  caller can do about it -- wait for whatever else is using the device, or
  say they will wait longer -- is not what the borrowed message suggests. A
  diagnostic that misdirects is worse than a vague one. That makes 162 codes.

- **The device's wait is sayable, so both of its unreachable paths are now
  tested.** How long one wait lasts before the caller's stop request is asked
  about again, and how long to wait in all before giving up on a device that
  has stopped answering, are what the engine was opened for rather than
  constants. Neither path could be reached on purpose before: giving up needs
  a device that has stopped answering, and seeing a stop request during a
  product needs a product that outlasts a slice.

  A caller who asks for no patience waits not at all, so the first product
  exceeds the bound however healthy the device is -- which reaches the
  giving-up path, and checks the part that matters, that the engine stays
  given-up-on rather than serving the next product from a buffer it no longer
  owns.

  A caller who asks for slices of a nanosecond makes every wait go round, so
  a request made while a product runs is seen. `Waited` reports how many
  slices the last product took, which is what tells a cancelled product
  cancelled between slices from one cancelled before it was submitted -- and
  it caught exactly that: the first version of the test had its asking task
  fire before the product began, and passed.

- **A fixture large enough to say where weights are read from.** The narrow
  binary32 model is seven kilobytes, under two pages, and a device is handed
  page-aligned ranges -- so which of its matrices could be read where they
  lie depended on where the mapping landed, and moved between runs of the
  same binary. `Tiny_Model.Write` takes a format now, and the k-quant
  fixtures are written at the deep widths: half a megabyte, a hundred pages,
  and the answer settles.

### Fixed

- **A closed engine remembered that it had given up.** Closing did not clear
  the stalled state, so an engine that had exceeded the bound refused every
  product after the next Open, on a device in perfect health. Found by the
  test above being followed by another.

- **A run on the device can be stopped.** Cancellation is checked between
  layers everywhere else in this program, and a layer on a device is a
  submission and a wait for it -- a wait that could not be interrupted, so it
  was the longest a stop request went unanswered. The wait is taken in
  twenty-millisecond slices now and the token is asked between them, and a
  request already standing when a product is asked for is answered before
  anything reaches the device at all.

  A cancelled product still finishes on the device. A dispatch cannot be
  taken back and its buffers belong to the device until the fence says
  otherwise; giving them back sooner is how a cancelled run would corrupt the
  next one.

  The token is held on the session rather than threaded through the twenty
  callers of the two procedures every product goes through. That is a
  deliberate trade with a cost, written down where the field is declared:
  twenty call sites is twenty places to miss one silently, in a program where
  missing one means a run that cannot be stopped.

- **A test for `--device-memory`,** which had none. Three runs in one
  process -- no option, a budget smaller than the model, and zero -- against
  the statistics each prints, because the statistics are the part that is a
  fact where a timing would be a measurement.

### Fixed

- **The bound on waiting for a device was a second, and wrong twice over.** A
  product larger than this machine's -- a wider model, a longer batch -- can
  legitimately take longer, so the bound refused work that was going
  perfectly well; and when it expired it returned with the command buffer
  still executing, so the next call would reset and record over a buffer the
  device was reading. The whole bound is a minute now, which slicing makes
  affordable because a device that has stopped answering no longer holds the
  thread for it, and a dispatch that exceeds it finishes the engine rather
  than reusing what cannot be taken back.

- **`--device-memory` was ignored when the device was already open.** A
  second Open with a different budget, or with the weights to be read where
  they lie rather than copied, was answered with the first one's device and
  its policy, and said nothing. One process runs one model in this program,
  so the shipped path never met it -- which is exactly why it survived. The
  new test runs three settings in one process and met it at once, reading the
  first setting's statistics three times.

- **`tests check --record-warnings` writes the pinned crates' warning counts
  down** instead of comparing against them, and writes the file's preamble
  with them so that it cannot end up explaining itself in terms that have
  stopped being true. Bringing a number down after a sibling crate is tidied
  meant reading a failure and editing a file to match it by hand, which is
  the same work done less carefully. It runs the repository checks and
  nothing else: a caller who wants a file rewritten is not asking for a
  conformance sweep.

- **The dependency check reads what a crate actually compiles, and holds its
  warnings to a recorded number.** It read one directory name, so a crate
  keeping its sources anywhere else was walked, found nothing and reported
  nothing -- which reads exactly like a crate in good order. It now walks the
  whole tree and judges the units that have objects, which is what this build
  compiles; a crate it can match nothing in fails rather than passing
  quietly.

  The counts live in `docs/dependency-warnings.txt`. Sixty-three warnings
  listed every run are sixty-three warnings nobody reads and a sixty-fourth
  arrives invisible among them, so a rise fails the gate, an unrecorded crate
  with warnings fails it, and a crate that gets tidier is reported so the
  number can come down.

  Units with a body per platform are exempt from both evidence checks and the
  exemption is counted, because it cannot be silent: a Windows body finds the
  POSIX body's object file -- they share a name -- and is judged against its
  own modification time. One edited in a pinned crate was reported as proof
  this build was stale. Nothing here can tell which of the two was compiled,
  because an object file records its source's name and not its path.

### Fixed

- **The second place the weights are freed did not tell the device.**
  Repacking frees the arena while the model stays open, and only the closing
  path had been taught to give the device's matrices back first -- so the
  same fault fixed yesterday was still there, at a site nobody had looked at.
  Both go through one procedure now, so there is one place to remember rather
  than two.

  Found by listing what the first fix did not cover rather than by anything
  failing, which is the only way this one was going to be found: it needs the
  allocator to hand a repacked model the address the device is still holding.

- **The gate can see the crates this build is made of.** Every dependency is
  pinned to a sibling working tree, so a build compiles those trees as surely
  as this one, and the checks read this repository's object directories only.
  Sixty-three compilations in six pinned crates had left warnings behind that
  were invisible from here, and a pinned crate that would not compile at all
  was found by a build failing rather than by anything saying so.

  Stale evidence in a pinned crate is refused, because that is a fact about
  this build: sources newer than objects mean the dependency has not been
  compiled since it changed, and nothing resting on it can be vouched for
  either. Their warnings are listed rather than refused -- this repository
  cannot hold another repository's tree to its own switches, and a gate that
  went red for a sibling crate's warning would pass on one machine and no
  other.

  Subunits are recognized and skipped in both checks. A subunit is compiled
  into its parent and has no object file of its own, and four ordinary files
  in a pinned crate were reported as never compiled before this was fixed.

- **The batch is measured for every format, and the argument it replaced was
  wrong.** One format at two widths was measured, on the reasoning that a
  batch buys the same arithmetic everywhere and measuring fifteen would say
  what one says. It does not: batching compresses the spread across formats
  from nine to one down to two to one, and the formats the device was worst
  at gain most. Binary32 reads 1.39 with one vector and 0.26 with eight --
  from slower than the processor to four times faster -- because a batch
  reads each weight once for eight vectors, so the bus stops being the wall.

  Thirty device ratios and the row-product table were published from one run
  at a load of 1.25.

### Fixed

- **A device answered one model with another's weights.** It remembers a
  matrix by where its bytes lie, what shape they are and what format they are
  in, and that names a matrix only while it exists. Once a model closed and
  its storage was freed, the next model's tensor could land on the same
  address with the same shape, and the device answered for the second with
  the first one's weights. A model closing now tells the device to give back
  everything it holds.

  The comment written when the residency key was fixed for format and shape
  said this could not arise, because in this program the weights live as long
  as the model does. That was true of the program and false of its own
  conformance sweep, which opens and closes a model per format and
  architecture with the device open across all of them -- and about half its
  runs were failing by a fifth of a logit, moving from run to run because it
  depended on what the allocator handed back. Four consecutive sweeps are
  clean now where four before it read 0, 16, 80 and 96 logits outside
  tolerance.

  It surfaced only because the sweep began crossing the device in fifteen
  formats instead of three, which is fifteen times as many models opened and
  closed.

- **The gate refuses evidence it cannot vouch for.** The no-warnings check
  reads the logs a compilation leaves behind, and a log is only written when
  a unit is compiled -- so a unit nobody has compiled since a switch was
  turned on has none and reads as clean. That is how 547 warnings sat in this
  tree while the gate said there were none. Every unit must now carry an
  `.ali` no older than its source and no older than any project file, so a
  unit compiled under different switches, or never compiled here at all,
  fails the gate instead of passing it silently. The remedy is a build from
  clean, which is the point: this is how a tree that cannot be built from
  clean says so. It could not be, and nobody knew.

  The `.ali` is what is checked rather than the log, because that one is
  written for every compilation whether anything was said or not; one body in
  this tree has an object and no log.

- **`tests benchmark` measures every format on the device.** It measured the
  three the shader used to decode, so the twelve branches added last week
  arrived with nothing timing them -- and a format can be perfectly correct
  and four times slower than the one beside it with nothing to say so.

  The finding is that the device's advantage tracks how badly the processor's
  own decoder vectorizes rather than anything about the device. It wins by
  four to one on IQ4_NL, Q5_1, Q5_0 and IQ4_XS -- the formats where a
  per-lane shift or a gather stops baseline x86-64 vectorizing -- and by a
  quarter on the formats the processor is best at. The ordering of the
  fifteen is nearly the reverse of the per-element table under Kernels, which
  is the same fact said twice.

  Published with the row-product table, both from one run at a load of 1.29.

- **The device shader decodes every format the program reads.** It decoded
  three of the fifteen -- binary32, Q8_0 and Q4_0 -- and the other twelve
  reached a device only through `--repack f32`: a pass over the whole model
  at load, and four bytes a weight afterwards, which for a four-bit model is
  eight times what it was quantized down to. It now has a branch for each of
  F16, BF16, Q4_1, Q5_0, Q5_1, Q2_K, Q3_K, Q4_K, Q5_K, Q6_K, IQ4_NL and
  IQ4_XS as well, decoding the bytes the file holds. No model needs repacking
  to reach a device any more.

  Each branch is a transcription of a bit layout from the processor's own
  decoder, and a transcription can be wrong in a way nothing downstream can
  see: a shift by the wrong amount or a sub-block scale read from the wrong
  byte gives an answer that is merely slightly wrong. Two checks hold them.
  A new test multiplies a matrix in every one of the fifteen formats on both
  backends and compares, at one vector and at ten; and the conformance sweep,
  which crossed the device in three formats, now crosses it in all fifteen --
  8145 sequences, 112320 logits, nothing outside tolerance.

  Measured: the four rows of the two-backend table and the five per-format
  ratios were taken again. Fifteen branches did not cost what three did; the
  ratios are within a few per cent of the run before.

  Two refusals became unreachable and went back on the unreached list with
  that as their reason. A model in a format the backend cannot read cannot be
  built any more, because a view will not hold a format the program does not
  decode and the device decodes all of those.

### Fixed

- **A device kept one matrix under another's name.** A resident matrix was
  identified by where it lay and how many bytes it took, and that does not
  name a matrix: two formats of the same width are the same length, and so
  are two shapes with the same number of elements. Storage freed and taken
  again at the same address was answered with the first matrix's weights.
  The format and the shape are compared now as well.

  Found by the new per-format test, which ran fifteen formats through
  same-sized storage in turn and got the previous format's answer for the
  one that followed it.

- **The shader generator wrote trailing spaces,** five hundred and seventeen
  of them into the file it produces, and had done since it was written. The
  gate refuses a build that leaves style warnings behind and had never seen
  these: a warning is reported when a unit is compiled, and that unit had not
  been since the switch was turned on. Regenerating the shader recompiled it
  and the whole set appeared at once -- along with thirty more in six library
  bodies where blocks had drifted three columns left of where they belong.
  All fixed.

- **`tests benchmark` reports the load as well,** at both ends of its run,
  and its five device ratios were taken again for it. One reader serves all
  the tools that publish timings now, rather than a copy each.

  Printing the load named a bias that was there all along and is now in the
  README: these are ratios of the device against the processor, taken while
  the measurement is itself occupying the processor. The device side competes
  for nothing the measurement wants and the processor side competes with it,
  so the ratios flatter the device by however busy the machine was.

  `tests external-model` does not report a load, and now says why: it
  publishes counts and answers rather than timings, and a line that carried a
  load would differ between two runs of the same check -- which is what the
  published transcripts are compared against. Adding it there broke that
  comparison, which is how the asymmetry got its reason instead of staying an
  oversight.

- **Every published figure now carries the load it was taken under.** The
  whole set was re-measured for it: the twelve-token figure, the device pair,
  the reference comparison and the drafting trio, starting from a load of
  0.4.

  With one thing worth knowing about the number, which is now written beside
  the table: the tool is itself the work, so a run of measurements raises the
  load it reports. A figure taken at 0.4 and one taken at 3.0 in the same
  burst differ mostly in how many measurements came before them. The pairs
  that are compared with each other were taken adjacently, and the drafting
  trio waited for the load to fall back under one, because its arithmetic
  subtracts one run from another.

- **A test that the load a figure carries is the load the host reports.** It
  falls back to zero where a host keeps no load average, and a zero reads as
  a quiet machine to anybody looking at a published figure -- so on a host
  that does keep one, a zero is a fault and the test says so. Checked by
  making the reader take the fallback and watching it fail.

- **`--context-shift N`: a context that rolls.** When the context fills, the
  oldest N positions are dropped, the rest slide down, and the run carries
  on; `--context-keep N` says how many at the front stay. Without it a run
  that fills its context ends there.

  The keys move with the text: each one is turned back by the angle those N
  positions stand for, because a key rotated for where it was would otherwise
  describe a position the text no longer has -- and a model reading that
  produces fluent text and no error. The identity that rests on -- turning
  back by N is rotating N earlier -- is held at the kernel level for every
  pairing and every stretch. Writing that test found two wrong versions: one
  applying the stretch's attenuation twice, one dividing it out.

  What a shift loses is more than the tokens it drops, and the specification
  says so: the keys and values that stay were computed while the dropped
  tokens were still there, so moving them renumbers their positions without
  recomputing them. A rolling context is an approximation of the same text
  read afresh, not an equivalent. The first version of the session-level test
  asserted that equivalence and failed by half a logit -- which was the
  approximation showing, not a fault, and the test now holds the bookkeeping
  and leaves the arithmetic to the kernel test that can be exact.

- **`--json-schema` and `--json-schema-file`: a schema becomes a grammar.**
  It reads `type`, `properties` with `required`, `items`, `enum` and `const`,
  and refuses every other keyword by name. Ignoring one would produce a
  grammar that allows more than the schema does -- a constraint that quietly
  is not one -- and the first version of this did exactly that until the test
  for it was written.

  Objects come out closed and ordered, which is narrower than the schema:
  JSON leaves member order free, and allowing every order would grow the
  grammar as the factorial of the property count. Everything it accepts the
  schema accepts and not the reverse, and that direction is written down
  where a reader meets it.

  The tests run the grammars rather than reading them -- a converter that
  writes plausible text is what a string comparison would pass. That found
  the fault worth recording: the rule for what may appear inside a JSON
  string was written with one backslash too many, so instead of excluding the
  control characters it excluded the letters `x`, `f`, the digits `0` and `1`
  and the dash, and let raw newlines through. A model under that grammar
  produced strings no JSON reader would take.

  `tests schema SCHEMA` prints what a schema becomes, which is how the
  grammar gets read without running a model -- and how that fault was found.

- **Adapters stack, and come off again.** `--lora` is repeatable and the
  adapters are merged in the order given; `--lora-scale` pairs with them
  positionally. A merge adds a difference to the weights, so a second lands
  on top of the first -- and a scale of minus one subtracts, which is how one
  is removed.

  Both followed from what a merge already was and neither was written down or
  checked. The test measures how far the logits move: a second merge moves
  them about as far again as the first, and plus one followed by minus one
  puts them back within a hundredth of that distance. Within rounding rather
  than exactly, because a binary32 weight that has had a number added and
  subtracted is not the bit pattern it began with, and demanding that would
  assert something nobody promised.

- **`--prompt` is repeatable: several sequences from one loaded model.** The
  model is read once and answers each prompt in turn, each with its own
  context and its own statistics; standard error says which prompt is which,
  so standard output stays nothing but generated text.

  Between prompts the session goes back to nothing. A second prompt
  continuing the first would be a different program, and nothing about the
  output would show it -- two answers concatenated look the same either way
  -- so the test compares a run of two prompts against the two runs of one,
  and first checks that those two answer differently, without which it could
  not tell a reset session from a kept one.

  Refused together with `--save-session` or `--load-session`, which name one
  conversation between them.

- **`tests external-model --draft-model PATH`,** which runs a caller's own
  model again with a smaller one proposing for it and checks that the text is
  identical. That is the claim drafting makes, and a caller's own model is
  the only place it can be checked against something anybody cares about. The
  summary reports how many proposals were made and taken.

- **A test that the external-model runner generates what the command
  generates** from the same inputs, by comparing a digest of the text. It
  samples greedily and seeds itself with forty-two, which is a choice rather
  than the command's default, so the test gives the command those settings
  explicitly rather than leaving the correspondence implied. `tests
  benchmark` has no counterpart and needs none: it measures kernels on
  synthetic tensors it builds itself.

### Fixed

- **`--context-shift` did nothing beside `--draft-model`.** The shift lived
  on the single-token path only, so a drafted run met the full context in the
  round's batch and ended there. Two options that each worked alone and one
  of which quietly stopped working in company -- the third time that shape of
  fault has been made here, and the reason the test for it asserts the token
  count rather than that nothing crashed.

  Both sessions shift together now. A draft proposing from a context the
  model no longer has proposes badly, which costs speed rather than
  correctness and would therefore go unnoticed.

- **A `required` name that no property describes was ignored.** The schema
  said a member was mandatory, nothing in the grammar made it so, and nothing
  said anything. Refused now, by name.

### Added

- **`tests speed` reports the machine's load, before and after.** The
  processor side of every comparison here has moved by forty per cent between
  otherwise identical measurements, and until now the only thing telling one
  measurement from another was prose written beside it by hand. A figure that
  carries its own conditions can be compared with another; one that does not
  has to be believed.

- **A test that a shifted context survives being written out and read back.**
  A saved context carries the positions it was written with, and after a
  shift those are not the positions the tokens were first evaluated at.
  Neither a snapshot that recorded the old ones nor a restore that put them
  back would raise anything.

- **`required` was read and then ignored.** The schema converter accepted the
  keyword and made every named property mandatory, while the package's own
  specification said a property not required is optional. One of the two was
  a lie and it was the specification -- the behaviour was at least narrow
  rather than loose, which is the direction stated everywhere else, but
  nothing said so.

  A property the schema does not require is now written as one that may be
  absent, with the comma that would precede it. A schema naming no `required`
  list still requires everything, which is not what JSON Schema says and is
  now written down as the narrow choice it is. A first property that may be
  absent is refused: it makes the comma before the second conditional on it,
  which needs an alternative for every place the object might start.

### Added

- **A test for `--context-shift` through the command.** It checks both
  halves: that the run is refused without the option, because the prompt and
  the tokens asked for do not fit -- which is the refusal the option lifts --
  and that with it the run finishes and reports its drops.

  And that the text is right as far as it can be: the same run in a context
  large enough to need no drop produces the same tokens up to where the small
  one first drops. Without that half the test would pass on a shift that
  scrambled the context, because a run producing nonsense produces it
  fluently.

- **Three of the four figures the engine group covers had not been
  re-measured.** The twelve-token figure was re-taken when the measuring tool
  was corrected; the worker-count and share-count comparisons and the
  batch-size table were not, so that group's fingerprint said re-measured
  while three of its figures still described the old prompt and the old
  sampler. All three re-taken.

  The batch-size table has no digest column any more. It had one, identical
  down every row, standing for the claim that batch size cannot change what
  the model says -- measured through a tool that read the prompt file
  including its final newline. Without that newline this model answers the
  prompt with its end-of-sequence token and generates nothing, so the column
  would be the digest of the empty string eight times. The claim it stood for
  is held by the conformance sweep, which compares batched evaluation against
  a token at a time over every format and architecture.

  `tests speed` takes a `--repeat-penalty` now. It was added on the theory
  that the default penalty was what silenced the model; it was not -- the
  trailing newline was -- but it is an option the command has and the tool
  should be able to reproduce a run that uses it.

- **`tests speed --draft-model PATH [--draft-tokens N]`.** The drafting
  figures were taken by hand, which is the thing this repository fixed for
  the reference-backend ratio and then again for the device. They are three
  runs of one command now -- the model, the draft, and the model with the
  draft -- and the summary line reports how many tokens were proposed and
  accepted.

  Re-measured through it and republished. The arithmetic under "Drafting"
  now comes out of figures anybody can take again: 125 ms a token for the
  model, 159 for the draft, and 382 ms to check five positions.

### Added

- **A test that `tests speed` runs the command it publishes figures for.**
  It compares the prompt token count, the generated token count and a digest
  of the generated text between the tool and the same run as a command. Three
  differences between them had gone unnoticed for as long as the tool
  existed, and none of them was visible in a figure: a wall time is a
  plausible number whatever run produced it.

  Two things had to change to make the comparison possible. The digest is one
  function now, called by the tool's own sink and by the test, rather than
  two copies of a hash that could drift. And generated text goes out through
  `Current_Output`'s stream rather than `Standard_Output`'s -- raw bytes
  either way, the same file for this program, and a file a test can read.
  Until that changed, nothing could see what the command generated without
  running it as a separate process.

  Every group whose figures come from `tests speed` now lists the tool among
  its sources, so a change to the thing doing the measuring asks for a
  re-measure the way a change to the engine does.

### Fixed

- **`tests speed --backend reference` measured a failure and called it a
  run.** It handed the asked-for batch size to a backend that refuses
  batches, so every prefill failed; the command clamps the batch to one for
  such a backend and warns. The report said "0 generated" in a millisecond
  and counted itself a successful measurement. It clamps as the command does
  now, and refuses to report a run that did not finish.

  The reference-backend comparison is published from that command for the
  first time, rather than by hand: four tokens, `cpu` 0.490 s of prompt and
  0.574 s of generation against `reference` 6.463 s and 4.104 s. Ten times
  the work, and the same digest from both.

- **The drafting figures were covered by the wrong fingerprint group.** They
  hung off the `device` group, whose source list does not include
  `model_runner-generation.adb` -- the file the drafting loop is written in,
  and which was in no group at all. The loop could have been rewritten
  without anything asking for a re-measure. Drafting has its own group now,
  and that file is in it.

### Fixed

- **`tests speed` was measuring a different run from the command it
  reproduces.** Two differences, both found by chasing the proposal-count
  disagreement recorded here yesterday; the tool was the one arranging the
  run differently.

  It read the prompt file raw. The command reads a prompt file line by line
  and puts the separators back between the lines, so the file's final newline
  -- which an editor wrote and nobody typed -- never reaches the model. Every
  figure this tool has published therefore described a seven-token prompt for
  a file the command tokenizes into six.

  And it sampled with the greedy configuration, which turns off the
  repetition penalty and the filters as well as the temperature. The
  published command sets `--temperature 0` and keeps everything else at its
  default, including a penalty of 1.1 over sixty-four tokens. That difference
  was harmless for as long as penalties did nothing at temperature zero, and
  stopped being harmless the day they started working -- three commits ago.

  Both fixed, and every figure the tool publishes re-measured. The two
  harnesses now agree token for token: sixteen proposals and nine accepted,
  either way. The headline twelve-token figure is 1.42 s where it was 1.28,
  most of which is the machine and some of which is the extra work the
  default penalty asks for.

- **`--draft-model PATH` and `--draft-tokens N`: a smaller model proposes,
  the real one checks.** The draft says what it would produce next, several
  tokens at a time; the model reads all of them in one pass over its weights
  and says what it would have said at each of those positions, and the
  proposals it agrees with are what the run produces.

  Only at temperature zero, and not with a grammar. That is what makes the
  guarantee sayable: a proposal either is the model's own choice or it is
  not, so the text is exactly what the model would have produced alone. Held
  by a test that runs the same prompt with and without a draft and compares
  the bytes. Above temperature zero the same guarantee needs an acceptance
  test written against the sampler's distribution, which this does not have,
  so it is refused rather than approximated.

  The statistics report how many tokens were proposed and how many accepted,
  because they are the only numbers that say whether a particular draft is
  worth having. On this machine no pair of models makes it pay -- the only
  two that number their tokens alike are two quantizations of the same 1.1B
  model -- and the README publishes that: 10.39 tokens a second without a
  draft against 0.98 with one, at 9 of 16 proposals accepted. A draft the
  size of the model it drafts for costs exactly what it saves and then some.

  Two supporting pieces, both useful on their own: `Evaluate_Batch` can now
  produce the logits of every position of a batch rather than only the last,
  and a session can be rewound to an earlier committed position.

  A model drafting for itself accepted only four proposals of six, which
  should have been six of six. The draft proposes further than it reads --
  the last proposal is one it never evaluated -- so when everything is
  accepted the draft ends a token behind the text and guesses the next round
  from a context missing its last token. Nothing is ever wrong from that,
  because the target checks everything; it just guesses badly, which is
  invisible except in the acceptance count.

### Fixed

- **The draft model ran serial while the model it drafts for used the pool.**
  The draft session was opened without workers, so every proposal cost seven
  times what it should on this machine and the published figure measured the
  arrangement rather than the idea. Twelve tokens went from 12.547 s to
  3.880 s when the two shared a pool -- which they can, because a round
  proposes and then checks and the two never evaluate at once.

  What that made possible was the arithmetic the README now publishes: with
  the draft's own cost subtracted, checking five positions takes 230 ms
  against 94 ms for a single token, so a round of K proposals costs K draft
  passes plus 230 ms and produces one more token than it had accepted. From
  which: at the acceptance rate measured here a draft has to cost under 57 ms
  a token to pay, against the target's 94.

  And the finding that decides the pair on this machine: the two-bit
  quantization is a third of the size of the eight-bit one and twice the cost
  to run, 185 ms a token against 94, because what it saves in bytes it spends
  unpacking them. A smaller file is not a faster model.

- **A draft model was ignored above temperature zero, silently.** Drafting
  runs only at temperature zero and only without a grammar, and both were
  conditions that quietly turned it off -- the exact fault fixed for
  `--device-memory` two days ago, reintroduced by the person who fixed it.
  Worse here: the draft was loaded first, so the run paid for a second model
  file and then never asked it anything. Both combinations are now refused
  by name. `--draft-tokens` without a draft model is a note instead, because
  nothing is loaded and nothing is wasted.

- **A draft that disagreed changed the text.** The guarantee is that a
  drafted run produces exactly what the same run produces without a draft,
  and it did not: the draft reads the prompt too, and it was writing its
  logits into the buffer the target's prefill had just filled -- so the first
  token of the run was sampled from the draft's distribution rather than the
  model's.

  The test that existed could not find it. It had a model drafting for
  itself, where the two distributions are the same one, so overwriting either
  with the other changes nothing. The new test drafts with the same model
  quantized: it agrees often and not always, which is the only fixture that
  can tell a correct acceptance from a lucky one. It also asserts that some
  proposals really were refused, without which it would be the first test
  written twice.

- **The same file could not be opened twice.** A model file is opened for
  reading, and the language's default for that is exclusive within one
  program, so naming one file as both the model and the draft failed with
  "cannot open" -- a true sentence about a file that is plainly there. Model
  files are now opened shared, which is what two readers of one read-only
  file need from each other: nothing.

- **Several sessions on one prepared model.** It was one, and the reason was
  a comment saying so rather than anything in the way: a model carries no
  per-evaluation state -- the activations, the normalized copies and the
  query and key rows all belong to the session -- and the specification has
  said since it was written that a prepared model is immutable and may be
  read concurrently. The refusal contradicted its own documentation.

  Held by a test that opens two sessions and evaluates them a token at a
  time in turn, checking each gets exactly what it got alone, and checking
  first that the two sequences differ so a collision cannot pass as a
  coincidence. Interleaved rather than sequential, because sequential
  sessions pass even on a model that does hold such state.

  What is still refused while a session is open is anything that would write
  to the model: merging an adapter, closing it. That is what makes the claim
  true rather than hopeful.

  The command still runs one sequence. This is a capability of the library
  and no option asks for two.

- **Five more samplers: locally typical, tail-free, exclude-top-choices,
  a sequence penalty and mirostat v2.**

  Locally typical keeps the candidates whose surprise is nearest the
  distribution's own entropy. Tail-free cuts where the sorted curve stops
  falling steeply, by the second differences, which is what to use when the
  head is flat and cumulative probability cuts arbitrarily among equals.
  Exclude-top-choices does the opposite of every other filter -- it throws the
  likeliest away, some of the time -- for text that has to stop being
  predictable rather than stop being wrong. The sequence penalty acts on
  paths rather than tokens: what it costs is the next step down a path
  already walked, growing as a base raised to how far past the allowed length
  the repetition runs. Mirostat steers for a steady surprise, moving its
  target by how surprising each choice turned out to be.

  Mirostat replaces the truncation filters rather than joining them, so
  asking for both is refused rather than resolved by precedence: a caller who
  set top-p and mirostat has a belief about what happens, and either
  resolution makes that belief wrong half the time.

  Two of the three tests written for these failed on the first run, and both
  fixtures were wrong rather than the code. Typical sampling was tested on a
  distribution with one overwhelming favourite, on the assumption that an
  overwhelming favourite must be the surprising candidate -- it is the
  opposite: a candidate holding nearly all the probability holds nearly all
  the entropy, so its surprise is what the entropy is. And mirostat was
  asserted to settle at its target measured in the model's bits, when the
  algorithm steers by the surprise of the distribution it truncated; the test
  now holds the ordering between two targets, which is the part that is a
  property of the algorithm rather than of the fixture.

### Fixed

- **Every penalty did nothing at temperature zero.** The repetition,
  frequency and presence penalties were applied where the candidate list is
  built, and the greedy path does not build one -- it walks the logits and
  takes the largest. So `--repeat-penalty` with `--temperature 0`, which is
  exactly the combination a caller reaches for when a model loops, has been
  silently ignored for as long as both have existed. Everything that acts on
  a token is now one function that both paths call.

- **`--logit-bias TOKEN=X` and `--logprobs N`.**

  A bias adds a fixed amount to a token's logit before anything else the
  sampler does, and on the greedy path as well as the probabilistic one. The
  obvious way to write it -- fold it into the candidate list the filters read
  -- leaves temperature zero untouched, which is the one mode a caller can
  check by hand, so the test drives both paths.

  `--logprobs N` reports, per generated token, its log-probability and the N
  likeliest alternatives, on standard error, one line a token. The numbers
  come from a plain softmax over the raw logits: no temperature, no masks, no
  penalties, no filters. That is the model's own distribution, and it is the
  only reading worth publishing -- a caller asking how sure the model was is
  asking about the model, and reporting probabilities from after the pipeline
  would answer a question about the configuration instead. Explaining
  consumes no random state, so a run with it produces the same text as one
  without, which is asserted rather than assumed.

- **The device can read the weights where they lie, and `--device-memory`
  says how much of its own memory it may use.** A device that shares the
  host's memory will take a pointer into this process instead of a copy, so
  the model is held once rather than twice. Two extensions are asked for when
  the device is opened, the pointer is aligned down to a page and the shader
  is told how far into the buffer the matrix begins; every way it can fail is
  a copy instead.

  It is a memory decision and never a speed one, which is the opposite of
  what it was written expecting. The same model and prompt: 10.69 tokens a
  second with the weights copied to the device, 2.58 with a budget holding a
  fifth of them and the rest uploaded again as they are wanted, and 0.74 read
  where they lie. Giving matrices back and uploading them again beats
  reading the host's memory by three to one, so this is not the answer to a
  model that does not fit -- it is the answer to a machine that cannot hold
  the model twice, which for a seven-billion parameter model at eight bits is
  fourteen gigabytes against seven.

  `--device-memory SIZE` names the share the weights may take. Naming it also
  says the caller knows what the device has, so a model larger than the number
  is run rather than refused. `--device-memory 0` means none of it: read them
  where they are. The statistics say which of the three happened, and an
  option that cannot do anything -- naming it without `--backend device` --
  says so rather than being accepted and forgotten.

  `Shares_Memory` came off the list of operations nothing calls. It had been
  on it since device discovery arrived, with a note saying what it would be
  for.

- **The device's memory is asked about, and what does not fit is given
  back.** Two faults with one cause: nothing knew how much memory the device
  had. `Context.Heap` was read from the driver and used by nothing, and the
  resident matrices were bounded by a count of 1024 with no eviction -- so a
  model larger than the device was discovered one failed allocation at a
  time, in the middle of a token, and a mixture of experts passed the count
  bound in silence.

  An engine now holds three quarters of the largest heap the device reports,
  and releases the matrix multiplied by longest ago to make room for the one
  wanted now. Least recently used rather than first or last, because a
  forward pass reads every matrix once in the same order: releasing the most
  recent releases the one wanted next.

  A model whose matrices are larger than that share is refused as it loads,
  with both numbers in the message -- it would otherwise run, slower than the
  processor and silently, by uploading weights again for every token. The
  question is asked through a new `Memory_Bytes` on the capability record, so
  a backend that computes out of the memory the model is already in answers
  zero and nothing is asked of it.

  `--show-stats` now names the device, how many matrices are on it, how many
  bytes those take, and how many have been given back. The last is the number
  that says a run was slower than it looked.

  `Open` takes a byte budget, which is how both behaviours are tested: the
  case worth testing is a heap smaller than a model, and no machine here can
  produce one on demand.

- **`tests external-model --backend NAME` and `tests benchmark` on a device.**
  The two tools that measure and validate could only see the processor path,
  which is a poor arrangement once there is a backend whose behaviour differs
  from it in kind rather than in speed.

  `external-model` now runs a caller's own model on any backend this build
  has, opening a device before the model loads and releasing it after. A
  backend that does not partition rows is not asked whether the worker count
  changes its answer and says so, rather than reporting an unrun check as one
  that held; a machine with no device is a skip, for the same reason a
  missing model is. The summary line names the backend, which the README's
  transcript now shows.

  `tests benchmark` measures the device against the serial processor path on
  a resident 512 by 2048 matrix, in the device's time as a fraction of the
  processor's: 0.76 for q8_0 a vector at a time, 0.90 for q4_0, 1.38 for
  binary32, 0.25 at eight vectors a pass and 0.099 at thirty-two. Binary32 is
  the one format the device is slower at, which is the finding rather than a
  disappointment -- four bytes a weight where q8_0 is one, so a vector at a
  time is bus-bound and the decoding the shader does is what buys the rest.

- **The device shader takes a batch, and reads packed weights.** Two changes
  to one shader, because both are the same loop with a different way of
  reading the weights, and together they are what turns the device backend
  from a demonstration into the fastest one here on this machine.

  A batch. One invocation carries eight vectors and reads each weight once
  for all of them; a longer batch is more dispatches in the one command
  buffer, not more submissions. `Supports_Batched` is now True, which is what
  makes the evaluator hand it a prompt in one call.

  A format. The shader decodes Q8_0 and Q4_0 from the bytes the file holds,
  block scale and all, so a quantized model goes to the device as it is
  stored -- a gigabyte for TinyLlama rather than the four `--repack f32`
  would make of it. The other twelve formats have no branch in the shader and
  are still refused by name, per tensor, while the model loads.

  Measured with `tests speed --backend NAME`, which is new and exists so that
  these figures are a command rather than a memory. TinyLlama-1.1B Q8_0,
  median of three: the published seven-token run takes 1.345 s on the device
  against 1.727 s on seven workers, and a 111-token prompt takes 3.827 s
  against 6.285 s. Both backends print the same digest of what they
  generated, so this is the same text and not a faster answer to a different
  question.

  The conformance sweep compares the device against the independent
  implementation on each of the three architectures in each of the three
  formats it reads, through both evaluation paths, including a batch longer
  than the eight an invocation carries and a batch that is not a whole number
  of them.

- **Tests for what the device backend refuses.** No device open, a format the
  shader has no branch for, a vector that is not there, a batch of none, and a
  batch longer than its storage. The first two run on a machine with no
  device at all, which is where a refusal being wrong would otherwise never
  show.

- **`--backend device` runs a model.** The fourth piece, and the one that
  makes the other three a backend rather than a demonstration. A matrix is
  uploaded once and stays on the device for the rest of the run; what crosses
  per product is the vector out, the dispatch and the result back.

  Binary32 only, so a quantized model reaches it through `--repack f32`. That
  did not work at first and the reason was a check asking the wrong question:
  the per-tensor backend format check ran against the format the *file* holds,
  which refused every quantized model on the one backend repacking exists to
  make usable. It now asks what the backend will read, and it no longer asks
  it at all of the norms and biases, which are decoded into vectors at load
  and never handed to a backend in any format.

  Measured rather than described. Against SmolLM2-360M on an integrated
  Radeon, generation runs at 5.7 tokens/s where one processor core does 6.3
  and seven do 21.0; a prompt runs at 1.5 tokens/s against 43.2, because this
  backend declares it does not batch and so evaluates a five-token prompt as
  five separate passes over every matrix. The text is identical to the
  processor's, token for token.

  The conformance sweep compares it against the independent implementation on
  each of the three architectures, separately rather than crossed: it reads
  one of the fifteen formats, so crossing it would have measured the
  repacking fifteen times over instead of the device once. Its binary32
  accumulation is where the sweep's worst relative figure now comes from --
  5.4e-03 against 1.9e-03 -- on a logit near zero; the worst absolute figure
  is unchanged.

- **A device computes a matrix-vector product.** The second half of the
  third piece, and the first thing here that runs on a device rather than
  reporting on one -- so the first that can be checked instead of described.

  A pipeline is made once and the buffers per call, which is the wrong way
  round for speed and the right way round for a piece whose job is to be
  correct: keeping a model resident is what the fourth piece is for. What
  goes to the device is the shape and three buffers; what comes back is
  compared against the same product in binary64.

  On this machine an integrated Radeon and a software rasterizer both agree
  to 3.7e-08 over a hundred and twenty-eight terms, which is what binary32
  accumulation carries. The first version of that test used multiples of an
  eighth, every product and sum of which is exact in binary32, and reported
  a difference of exactly zero -- a fixture that could not tell the two
  arithmetics apart, which is the third time this session that a test looked
  like proof and was not.

### Fixed

- **The imported range could reach past the memory it was taken from.** A
  device is handed whole pages, so the range rounds down at the start and up
  at the end -- and a matrix at the end of a heap arena rounds up past the
  arena, which is memory nobody allocated. What the device is given is now
  checked against the storage the matrix lives in, and a range that would
  leave it is copied instead. On a memory-mapped model that costs one matrix
  of one hundred and fifty-five: the last one.

- **The host-memory path was tested on binary32 only, and by a test that
  could not fail.** The offset the shader is told about is added to word
  indices for binary32 and to byte indices for Q8_0 and Q4_0 -- two
  arithmetics, one exercised -- and only through the unbatched path. Worse,
  the test asserted nothing about whether an import had happened, and the
  fixture it used was small enough that none did: every matrix of it is
  within a page of both ends of its storage, so every one was copied. The
  test passed by testing the copy path twice.

  It now runs every format the shader decodes, batched and not, against the
  processor's own answers, in storage large enough that the import can
  happen, and asserts that it did. Checked by breaking the packed-format
  offset on purpose and watching it fail.

  The conformance sweep does not cross this and cannot: its fixtures are
  eight wide and two deep, so every matrix is within a page of both ends of
  the model. Running it there would report fifty-four more comparisons and
  test the same path twice, which is worse than not running it, and the
  sweep says so where the device pass is set up.

- **`embed --backend device` refused every model.** The run command opens a
  device before it loads; the embed command never did, so a device was
  selected, prepared against, and then asked for a product it could not make.
  Every embedding on a device came back as a lifecycle error. The choice of
  backend is now made once in each command rather than in one of them, and
  `embed` on a device produces the same vector as the processor to the six
  digits it prints.

- **Three diagnostics rendered as their own keys.** A message whose text
  names a parameter the site never attached cannot be rendered at all, and
  what comes out instead is the message key in angle brackets. Users got
  `<error.lifecycle.invalid_state>` from the device backend for as long as it
  existed, and a machine with no device got the same treatment from the run
  command's refusal.

  The device backend now reports a closed backend where it reported an
  invalid session state -- the state message is about a session and this was
  never about one -- and reports a missing capability, naming the format,
  where it reported an unsupported format, whose message names the tensor
  that carries it and no tensor name exists at that point. The tensor-naming
  message keeps its one honest caller: the loader, which refuses a model in a
  format the backend cannot read and knows which tensor it was.

  A machine with no device gets `Backend_No_Device` -- new, 159 codes now --
  which says that and needs no parameters.

  Every one of these is now asserted to render as a sentence rather than as a
  key, which is the check that was missing rather than any of the individual
  fixes.

- **The loader aborted the process when a second engine was opened.** Entry
  points were found through an instance held in a package variable, set when
  an engine opened and never cleared. Closing an engine and then the device
  under it left that variable naming an instance that no longer existed, and
  the next engine's Open -- which releases before it makes -- asked the dead
  instance for `vkDestroyBuffer`. The loader does not return null for an
  invalid instance: it aborts, which it did, in the middle of the test suite
  and with no output flushed. Each engine now carries the instance it was
  opened on, and an engine that was never opened asks nobody.

- **A repository check silently stopped checking.** The collector that finds
  every public operation held four hundred of them and the project has more,
  so the rest were dropped without a word -- and the check then reported
  that an operation declared in plain sight was declared nowhere, which is
  how it was found. The bound is larger and overflowing it now fails by
  name. A bound that is silently full makes a check weaker as a project
  grows, which is the opposite of what a check is for.

- **The rule that a platform package needs one body per host** now
  distinguishes a package that is the host boundary from one that is
  portable code going through it. The first needs a body per host and no
  other; the second has one body in the library and none per host. A package
  cannot have both, so requiring one or the other keeps the rule as strict
  as it was.

- **A compute shader for the matrix product, and a way to carry one.** The
  third piece, in two halves; this is the first of them.

  The shader is GLSL under `src/shaders`, one row of a matrix against one
  vector per invocation. Compiled, it is a run of thirty-two bit words, and a
  binary in a source tree is a thing nobody can read or review -- so `tests
  shader` writes those words out as Ada beside the source they came from.
  That also settles how the engine gets them: it is one of the units that
  may not reach the filesystem, so a compiled shader has to be something it
  is linked against rather than something it opens.

  Compiling is not part of a build. It needs a shader compiler, which should
  not become a dependency of this project for a file that changes twice a
  year. Whoever changes the shader compiles it and runs the tool.

  Which leaves the obvious way to be wrong: a shader edited and not
  recompiled would go on running the old words with the new source sitting
  beside them, and every test would pass, because every test runs the words.
  The generated file records a digest of the source it came from and the
  release checklist compares it against the tree, the same bargain the
  measured figures already make.

  The accumulation in the shader is binary32, which is what a device offers
  without asking for an extension; the processor's kernels accumulate a row
  in binary64 and round once. The two are not meant to agree bit for bit,
  and what they must agree on is the answer to the tolerance the sweep
  states -- which is a thing to measure when there is something to measure
  it with. Nothing hands these words to a device yet.

- **A device can be opened.** The second of the four pieces: asking a device
  for a queue that accepts compute, and finding the two kinds of memory
  anything running on it needs -- one the processor can write and one the
  device reads directly.

  On this machine the integrated Radeon reports both as the same kind, which
  is what makes handing a model to it cost nothing but the write. The
  software rasterizer beside it says the same, for the obvious reason.

  Choosing that memory the obvious way was wrong and the machine said so.
  Taking the first kind the processor can write reported this device as not
  sharing its memory, because the kind that does both is further down the
  list than one only the processor can reach: a plausible answer, and the
  wrong one. It now prefers a kind that is both and settles for one that is
  writable, which is also the order a backend wants them in.

  Nothing computes yet. What is left is buffers and a compute shader for the
  matrix product, then the plumbing that makes it a third backend.

- **The machine can be asked what compute devices it has.** `version`
  reports them, found through the host's Vulkan loader.

  The loader is opened by name at the moment it is first asked for rather
  than linked, because linking it would make a binary that will not start on
  a machine without one -- which is most machines this program is useful on.
  A host with no loader, no driver or no device reports none and everything
  else goes on unchanged: being told no is the point of asking.

  Nothing computes on a device yet, and the documentation says so where a
  reader will meet it. This is the first of four pieces -- discovery, then a
  device and a queue, then buffers and a compute shader for the matrix
  product, then the plumbing that makes it a third backend the existing
  capability checks can refuse work to. Each of the remaining three can be
  measured against the CPU backend when it lands.

  Verified on this machine, which reports an AMD Radeon 780M and a software
  rasterizer, both integrated. The test accepts either answer: it runs on
  machines with a device and machines without, and demanding one would fail
  on the other for a reason that has nothing to do with the program.

- **Saved contexts: `--save-session` and `--load-session`.** Reading a prompt
  costs what it costs -- prefill runs at about 27 tokens a second here, so a
  thousand-token document is more than half a minute before the model says
  anything, and its cache is tens of megabytes. Writing that out and handing
  it back is the difference between re-reading a document every time and not.

  Only the committed positions are written, not the capacity. What is loaded
  fills the cache before the prompt is looked at, so the generation's
  existing prefix reuse keeps whatever the new prompt agrees with and re-reads
  only the rest.

  The bytes name the model they belong to, the shape of the cache, the
  context capacity and the precision it is held in, and any mismatch is
  refused rather than read. The model is identified by its validated shape
  together with the size of its tensor data and a sample of its bytes: that
  identifies a model file and is not meant to verify one, which the
  documentation says rather than implies.

  A saved context is untrusted input and every field is range checked --
  including that no key or value is a not-a-number, which would poison every
  later position. What cannot be checked is whether the contents mean
  anything, and that is said plainly: loading a file is trusting whoever
  wrote it with the conversation.

  The engine produces and consumes bytes; the file is the caller's. That is
  not a preference but a rule the checklist enforces -- the units that
  interpret what a model says may not reach the filesystem, so that a
  hostile model cannot cause a file to be read. The first version of this
  opened the file inside the engine and the checklist caught it.

- **Low-rank adapters: `--lora` and `--lora-scale`.** An adapter says what a
  fine-tune changed, as a pair of small matrices per weight whose product is
  the difference. Merging adds that difference into the weights before
  anything is generated, so evaluation afterwards costs exactly what it cost
  before and the adapter's storage goes with the file it came from.

  Only binary32 weights can be added to. A quantized weight is packed bits
  and a block scale, and adding an arbitrary difference to one means
  requantizing it, which is a different and lossier operation; naming an
  adapter therefore selects `--repack f32` where the caller named nothing,
  and `--repack bf16` beside an adapter is refused rather than rounding every
  merged weight to eight mantissa bits without saying so.

  The scale multiplies the difference over and above the adapter's own alpha,
  which is read from the file: leaving alpha out would scale every fine-tune
  by its rank.

  Half a pair is refused, because half a difference is not a smaller
  difference, and an adapter naming no weight this profile adapts is refused
  rather than reported as a merge that changed nothing.

  The test compares a merged model against a model file written with the same
  difference already in its weights, both built by the fixture from the same
  two vectors. A test that asked the engine what the difference was and then
  compared the engine against itself would have passed whatever the merge
  did.

- **Constrained output: `--grammar` and `--grammar-file`.** The generated
  text can be held to a grammar. At each step every token whose text cannot
  continue it is removed from the distribution before anything is sampled, so
  what comes out is text the grammar accepts rather than text the model was
  asked nicely to produce. This is the difference between a prompt that says
  "answer in JSON" and an answer that is JSON.

  The notation is GBNF: rules with `::=`, alternatives, sequences, literals
  with escapes, `[a-z]` and `[^a-z]` sets, grouping, `?` `*` `+`, `{n}`
  `{n,}` `{n,m}`, and `#` comments. Sets and literals match code points
  rather than bytes, so a set means what it says whatever the tokenizer does
  underneath.

  A grammar arrives from a command line or a file, so it is untrusted input.
  Everything is bounded -- rules, elements, ranges, nesting while parsing,
  stack depth while matching, and how many ways the grammar may be in the
  middle of at once -- and every bound is a refusal rather than an
  allocation. Anything outside the notation is refused where it is met, with
  its position; there is no construct the parser recognizes and then
  declines, so there is no separate diagnostic for one.

  Two masks a run needs and did not have: the end-of-sequence token is masked
  until the grammar may end, so a run cannot stop half way through what it
  was told to produce, and a token contributing no text is masked throughout,
  because it cannot advance a grammar and allowing it would let a run produce
  it forever while the grammar stood still. A step that leaves nothing at all
  ends the run naming that, rather than leaving the sampler an empty
  distribution and reporting that instead.

  In a conversation the grammar applies to each reply and starts again for
  each, because what a grammar describes is an answer rather than a whole
  conversation.

  Seven diagnostic codes, a `MR-GRAM` family of their own.

- **An `embed` command.** It prints what the model made of a text rather than
  what it would say next: the hidden state after the final normalization,
  before the projection that turns a state into a distribution over tokens.
  That projection is where the resemblance between two texts goes -- it keeps
  only how much each token is favoured -- so the state is what an embedding
  has to be pooled from, and until now there was no way to get one out of
  this program at all.

  `--pooling mean` averages every position and `--pooling last` takes the
  final one. Neither is chosen on a model's behalf, because which is right
  depends on how the model was trained. The vector is at unit length unless
  `--no-normalize`, since comparing two of them is a dot product only when
  both have length one. One component a line, so the usual tools can read it.

  The prompt is read as written and no chat template is applied. A template
  turns a text into a turn of a conversation, and an embedding is of the
  text.

  The text is evaluated a token at a time rather than as a batch, because
  every position's state is wanted and only that path leaves one behind for
  each. For a prompt that is the same arithmetic either way.

  `Hidden_State` refuses a session with nothing evaluated rather than
  reporting the buffer as it stands, which would be reporting zeros as
  though the model had made that of something.

- **The catalog check covers every command.** It named `run` and `inspect`
  where it meant "each command that takes options", so the first command
  added after it was written had every one of its help lines reported as
  read by nobody. That was the check being wrong rather than the catalog.

- **`--kv-cache f16`.** A session can store what it has committed as
  binary16 instead of binary32: half the memory for the context, which is the
  one part of a session that grows with how much has been said. The default
  is unchanged and every published figure is still taken against it.

  The engine still computes in binary32 -- nothing does arithmetic in half
  precision. A key or a value is rounded on its way into the cache and
  widened on its way back out, so what the rounding costs is one step of
  precision on what attention reads, not on what it computes.

  It is lossy and now it has a number. Over the conformance sweep the halved
  cache moves a logit by at most **0.0218** where the exact cache moves it by
  2.1e-05: three orders of magnitude worse than exact and six times better
  than rounding the weights with `--repack bf16`, which is what one would
  expect from where each rounding happens. A weight is rounded once and read
  into every product; a key is rounded once and read back by every later
  position.

  The comment in the engine that said a half-precision cache "would need its
  own conformance evidence before it could be advertised" has been answered
  rather than deleted: the sweep runs both evaluation paths on both storages
  and reports the difference as a bucket of its own, because rounding the
  weights and rounding the context are different things to have measured.

  The two storages are two procedures rather than one with a test in the
  innermost loop, which would put a branch between every multiply and the
  next on the path every published figure was measured on. Extracting them
  also took the per-head attention out of both evaluation paths, which had
  carried a copy each: what a position attends to is now written once.

- **IQ4_NL and IQ4_XS.** Two more weight formats, decoded end to end:
  structural validation, a decoder, the fused dot product, golden vectors and
  the differential tests, which is what this project means by supported.

  They are the first formats here where a nibble is not a number. It indexes
  a table of sixteen levels that belongs to the format rather than to any
  file, spaced finely near zero and coarsely away from it, which is what
  makes four bits go further than Q4_0's do. IQ4_NL is that over blocks of
  32 with one scale; IQ4_XS is the same levels over a super-block of 256,
  with a six-bit scale for each sub-block split between a nibble and a
  two-bit field and signed by an offset of 32.

  The table is written out three times -- in the decoder, in the fixture's
  encoder and in the independent implementation -- rather than shared. A
  fixture that asked the decoder what the levels were would agree with it by
  construction, which is the one thing these tests exist to rule out.

  Adding them found a second thing. The CPU backend's list of formats it can
  read was written out by hand, so it refused both new formats while the
  decoder decoded them and the reference backend said so of itself; the
  conformance sweep caught it as a count, since every comparison on the CPU
  backend silently did not happen. That list now answers from the decoder,
  as the reference backend's already did.

  Both are the slowest formats in the kernel table -- 1.37 and 0.92
  nanoseconds an element against 0.27 for binary32 -- and the reason is the
  table they buy their accuracy with: a load at an address each element
  decides is a gather, and a gather does not vectorize. The README publishes
  the figures and says so.

  The kernel and share-scaling figures were re-measured rather than argued
  about, since neither needs a model. The row-product table is republished
  from one sitting with all fifteen formats in it, and the share figures from
  one pinned sitting. One of them moved enough to say so: the four-bit format
  at thirty-two vectors and eight shares reads 17820 Me/s against the 23450
  published, and falls off above four shares in every run taken here, so the
  README no longer claims the two formats are level everywhere.

- **`qwen3` and `qwen3moe`.** Two more architectures, each read under its own
  metadata keys and refused by name otherwise. Qwen3 is the shape this
  profile already had with the biases dropped and a root-mean-square
  normalization of every query head and every key head before the rotation:
  one gain per element of a head, shared across the heads, required rather
  than taken if present -- a file claiming the name and not carrying them is
  refused, as a qwen2 file without its biases is. Qwen3moe is qwen3 with its
  feed-forward block behind a router, which is a metadata prefix and nothing
  else, since the mixture is read from the expert keys under that prefix.

  Qwen3 also states its head widths rather than implying them, which is what
  the previous entry made readable.

  The refusal for an architecture this build does not read now names every
  one it does. It named `llama` alone while reading four, which is the kind
  of message that sends somebody looking for a build that does not exist.

  The sweep crosses `llama`, `qwen2` and `qwen3` with every format, shape,
  backend, repack mode and path -- 6435 sequences. `qwen3moe` is compared on
  its own instead: crossing a metadata prefix with everything would buy one
  string comparison for a third of the run time.

- **Key and value heads may be different widths.** `attention.key_length` and
  `attention.value_length` are read when the file states them. Neither has to
  be the embedding width divided by the head count, and they do not have to
  equal each other: the keys decide which positions a head reads and the
  values decide what it reads from them, and nothing requires those to be the
  same size. A file stating neither still derives both from the embedding
  width, which then has to divide exactly.

  Three assumptions came out of the evaluator to make that true: that a head
  is as wide as the embedding implies, that a key head and a value head are
  the same width, and that what attention produces is as wide as the
  embedding. The key cache and the value cache are now sized and indexed
  separately, and the output projection reads the heads' worth of value width.

  This was the last of the architecture profile's explicitly rejected
  features. What remains rejected there is a file describing a model this
  arithmetic cannot express, and an architecture identifier this build does
  not carry.

- **Rotary scaling.** A model naming `<arch>.rope.scaling.type` as `yarn` now
  has its rotation stretched by that method rather than being refused: the
  frequencies fast enough to tell neighbouring positions apart are left as
  trained, the slow ones that carry position over long distances are divided
  by the factor, and the band between them -- named by `beta_fast` and
  `beta_slow` turns over `original_context_length` -- is ramped across. The
  rotated vector is scaled by the method's own correction times
  `attn_factor`, because interpolating angles brings the scores they produce
  together. `linear` and `none` were already computed; only the third stretch
  a file can state as one rule was missing.

  A `rope_freqs.weight` table of per-dimension divisors is applied when the
  file carries one. This is how a file states a schedule that is not one
  number, and it was previously ignored -- a model carrying one ran with the
  wrong rotation on every long-range dimension while looking entirely healthy
  on a short prompt, which is the worst way for this to be wrong.

  `rope_factors_long.weight` and `rope_factors_short.weight` are refused, by
  the tensors as well as by the metadata name, because a file may carry them
  without naming the method. Choosing between two tables by how long the
  prompt turned out to be makes the rotation depend on the sequence rather
  than on the position, and nothing here does that.

  The conformance sweep gained a stretched shape -- yarn and a divisor table
  at once, over every format, backend, repack mode and evaluation path, 3510
  sequences. That the ramp, the factor and the table each change the answer
  on their own is asserted separately, where a fixture can hold one thing
  still: the sweep would be satisfied by two implementations that both
  ignored the same table.

  Repacking to brain floats is left out of the sweep for the stretched shape
  as it is for the windowed one and the mixture: 0.325 worst absolute against
  a lossy tolerance of 0.3, where the same fixture unstretched gives 0.137.
  Three of the four shapes are now outside it, which the README says plainly
  -- 0.137 is what `--repack bf16` costs a dense model with full attention
  and it does not carry over to a model that does anything else.

- **Mixture of experts.** A model naming `<arch>.expert_count` and
  `<arch>.expert_used_count` carries a router beside each layer's
  feed-forward block and a stack of expert matrices instead of one. The
  router scores every expert for the position being computed, a softmax
  turns those scores into shares, the highest few run, and their outputs are
  summed in proportion to the shares renormalized over that few. Ties go to
  the lower-numbered expert, so two experts scoring the same do not make the
  answer depend on which one the search reached first. It was refused by
  name until now.

  One expert's width comes from `<arch>.expert_feed_forward_length` when the
  file states it and from `feed_forward_length` otherwise, because on a
  mixture those are different numbers: `feed_forward_length` describes the
  dense block the model does not have.

  Nothing is copied to make this work. A file writes a layer's experts as one
  tensor with the expert axis outermost, so an expert's rows are contiguous
  and reaching one is arithmetic on an offset -- a mixture holds no more bytes
  than the file does.

  Which experts run is decided per position, so this is the one block that
  runs a token at a time however many were handed over. Everything else about
  a batch -- the projections, the attention, the output -- is still one matrix
  against many vectors.

  A shared expert that runs for every position beside the chosen ones, a gate
  that is not a softmax, and expert weights the file asks not to be
  normalized are each refused by name rather than run with the part that is
  understood: each would produce a plausible wrong answer instead of a
  refusal.

  The conformance sweep gained the mixture as a third model shape beside
  dense and sliding-window -- 2730 sequences against the independent
  implementation, which reads the same keys and the same stacked tensors and
  arrives at the routing from the description.

  Repacking to brain floats is left out of the sweep for a mixture, as it is
  for a window, and the same sweep separates the two reasons: with every
  expert running, so that no choice can flip, the worst disagreement is 0.330;
  with two of four, where the route can change, it is 0.509, against a lossy
  tolerance of 0.3 and 0.137 dense. The exact modes agree at 2.1E-05 either
  way. The README carries the table.

- **The attention biases are released when a model closes.** A qwen2 model
  held three vectors a layer past its own closing. Only that architecture has
  them, which is why closing a llama model looked clean.

- **Sliding-window attention.** A model naming
  `<arch>.attention.sliding_window` has each position attend to that many
  positions ending at itself, uniformly across layers, on every evaluation
  path -- a token at a time, a whole prompt in one pass, a prompt in chunks --
  and on both backends. It was refused by name until now, which was one of the
  three rejections standing between this engine and the models people have.

  The cache still holds the whole context: the window narrows what may be
  read, not what is kept, so this buys the model's answer and not the model's
  memory. A window at least as wide as the context is stored as none, since it
  can see everything the context holds. An architecture that alternates
  windowed and full layers needs a per-layer pattern this does not have, and
  that is not claimed.

  The conformance sweep runs with and without a window -- 1950 sequences
  against the independent implementation, which reads the same key and applies
  the same rule, written from the description rather than from the engine.

  One combination is left out of the sweep and the README says why, with the
  measurement: repacking to brain floats halves the mantissa and a window
  makes the softmax sharper, so the worst disagreement against the reference
  goes 0.137 with no window, 0.517 at a window of five or four, 1.677 at
  three, against a lossy tolerance of 0.3. The exact repacking modes agree at
  every one of those windows, so it says nothing about whether the window is
  right and everything about what `--repack bf16` costs on a windowed model.

- The checks no longer refuse machine code. Failing the build on any use of
  `System.Machine_Code`, in a project written in Ada where machine code
  insertions are an Ada feature, guarded a sentence in the README rather than
  anything about the program. There is still no assembly in the repository,
  and that is now recorded as a fact about the code rather than as a rule.
  What keeps another language out is the check on the sources themselves,
  which is a different question and still asked.

- A third registry says what is deliberately not exercised.
  `Reserved_Codes` names the diagnostics nothing raises and `Unreached_Codes`
  the ones raised where no test walks; `Untested_Surface` names the public
  operations no test writes down. Sixty-two of three hundred and eighty-two
  were in that position with nothing recording it, so an operation exercised
  through a caller, one that answers differently on every machine, and one
  simply untested read alike. Held in both directions, with the same caveat
  as the other two: naming is the proxy for exercising, and it errs towards
  saying an operation is tested.

- Every typed byte reader decodes what the bytes say, at every edge. Six of
  them -- `Get_I8`, `Get_I16`, `Get_I64`, `Get_F32`, `Get_F64`, `Get_Bool` --
  read metadata out of an untrusted file and were named by no test: the
  tensor encoders had a round-trip test and the scalar readers none. Checked
  against bit patterns rather than through an encoder, so a pair of mistakes
  cannot agree, and at the edges where a sign or a width is wrong if it is
  wrong at all -- including that each refuses to read past the end.

- The statistics report the run they describe. What was held was that the
  block has fields; the figures are its whole point and none was compared
  with anything, so a build reporting a constant would have passed. The seed
  has to be the one asked for -- it is what a reader writes down to reproduce
  a run -- the generated count has to respect its bound and move when the
  bound moves, and the context position has to be the prompt plus what was
  generated.

- Memory mapping is asked for rather than allowed. The default policy maps
  when it can and reads when it cannot, so a host on which mapping quietly
  stopped working would behave correctly and slowly with nothing failing.
  `--mmap` exists to turn that into an error and no test had asked it to: the
  three policies now have to agree with each other, on a host that maps and
  on one that cannot.

- A directory compiled for more than one host says which. `src/platform/posix`
  and `tests/src/platform/posix` are built for Linux and for macOS, and a
  number right for one is not thereby right for the other -- the capture
  carried Linux's create-and-truncate flags and silently stopped truncating on
  macOS. A source in one of those directories must now name both hosts, which
  cannot check a number against a header but can make the next author say
  which hosts they checked.

- Options with a consequence are made to have it, through the command.
  `--color` was checked as a parse and at the presentation layer with the mode
  handed over in Ada, and nothing ran the command and looked for escape
  sequences; `--quiet` and `--no-stats` reached their fields and suppressed
  nothing any test observed; `--context-size` was checked for being accepted
  and never for the refusal it exists to make. All four are observed through
  the command now, and each was verified by breaking what it controls.

  Two things the writing turned up. A successful run says nothing on standard
  error by default, so a quiet run cannot be compared against an ordinary one
  -- there is nothing there to remove -- and the comparison that exists is
  verbose against quiet. And the colour mode the report uses is the one from
  the *second* `Pres.Open`, after full parsing; breaking the first, which
  exists so that an early usage error is renderable, changes nothing a reader
  sees.

- A stop given on the command line stops the run. The stop matcher had a
  test that built its set in Ada, and the parser test proves `--stop END`
  reaches the count -- between them was the loop in `CLI.Execute` that copies
  one into the other, which could have copied nothing while both passed.
  Copying none of them fails now.

- What the reader typed is checked against the diagnostics on the paths that
  had none. The rule -- do not log prompts, system messages or generated
  text, do not persist conversation history -- was held for a single-shot run
  with the text given inline. A prompt and a system message read from files
  are now checked too, which is the way the program recommends since a value
  on a command line may be visible to other local processes; and so is a
  conversation, which is the case the rule is really about, because a session
  holds every turn and renders them all again each time. Verified by making
  the loop report the line it was given: the conversation check fails, the
  single-shot ones do not.

- `tests check --repository` runs the half of the gate that asks about this
  host. The gate is one gate and stays one on the host that releases -- suite,
  checks, conformance, two fuzzing campaigns -- but asking another host for
  the checks meant repeating a suite that had just run and a conformance sweep
  that is the same arithmetic everywhere: measured, that took Windows from
  397 seconds to 668 and macOS from 521 to 844. The narrow form takes four.

- Every option is given to the parser rather than listed. Seventeen of the
  thirty-eight appeared in one place only, the test asserting each is on its
  command's help screen, so a parser that accepted `--top-p` and dropped the
  number would have passed -- the sampling tests build their configuration in
  Ada, so both halves were tested and the join between them was not. The
  value on the command line now has to reach the field it names, and a value
  the field cannot hold has to be refused.

- A system message read from a file is read, and refused by name. `--system`
  had a test and `--system-file` had none, although it is the one the program
  recommends: a value on a command line may be visible to other local
  processes, which the help says outright. A missing path, a directory and
  text that is not UTF-8 are each asked for.

- The repository checks see one path separator on every host. The walk joined
  the host's way, so on Windows a check was handed `tests\src\checks.adb` and
  compared it against `tests/src/checks.adb`; every comparison of that shape
  stopped matching at once. The visible effect was that the two code
  registries no longer excluded themselves from the scan that reads them, so
  every code they name read as named by a test and nine were reported as
  reached that nothing reaches. Found the first time the checks ran on that
  host, which is the argument for running them there.

- The repository checks run on all three hosts. They ran on Linux alone --
  the checks that exist to anticipate what differs between hosts, while eight
  continuous-integration runs went red on host differences and every one of
  them passed here. Two of those differences are rules now: a text file read
  raw and then compared fails, because a checkout gives back the host's line
  ending and the program writes its own; and a file naming a built executable
  that never names the `.exe` form fails, because that file looks for
  something that is not there on the host which writes one. Both were found
  by the rules the moment they existed -- `tests package` was putting a name
  in the archive that the Windows build does not produce.

- `--validate` is tested, in both directions. Of the thirty-eight registered
  options it was one of three no test named, and the only one of those that
  does work: `inspect MODEL --validate` parses the file, says so and reports
  nothing else. Its failure direction -- a truncated file must be refused and
  the code named -- is why the option exists.

- The release checklist checks itself. `check_all_selftest` runs the
  checklist from a directory that is not a model_runner tree and requires it
  to refuse -- the one thing a checklist cannot establish by passing, since a
  checklist that accepted anything would pass too. It was written, declared
  as an executable, and called by nothing: not by the checklist, not by the
  README, not by any test. It runs as the checklist's last step now.

  It also asks *why* the run failed. A non-zero status was not enough: run
  outside a tree, the checklist fails at the toolchain check as well, so
  taking the working-directory guard out left the self-test passing. It reads
  the refusal message now, with standard error merged in, because a
  diagnostic goes there and the first version looked for it in an empty
  string.

- The tools crate is held to the rules the rest of the repository is held to.
  Of the twenty-seven directory walks in the checks it appeared in two, line
  length and GNATdoc, and in none of the rules about what may be written --
  although it holds the program that gates every release, and the
  specification calls every piece of project tooling production code. It is
  now scanned for hand-written instructions and for host calls bound by name.

- Both tokenizers are compared against a reader written from the description
  rather than from the code. The forward pass has had one since the
  beginning; the tokenizer had three recordings from `llama.cpp`, each
  needing a model nobody can commit, so on a clean checkout the strongest
  thing said about it was that its own unit tests agreed with themselves.
  `Reference_Tokenizer` reads the vocabulary out of the container and encodes
  by the documented rule, scanning where the engine hashes, on both roads and
  under all five byte-pair cutting rules.

  Every case string was chosen against a wrong reader rather than by
  inspection. Two of the SentencePiece cases exist because a reader that
  merged the *leftmost* pair instead of the best-scoring one agreed with the
  engine on all the others; `"abc"` is in the byte-pair set against a reader
  that merged by position rather than by rank.

- The byte-pair half of the tokenizer is covered at all. Every tokenizer test
  built a `llama` vocabulary, so the merge table, the byte-to-character
  mapping and all five cutting rules ran nowhere, while the support matrix
  marked those rows implemented under a definition that requires coverage.
  `BPE_Vocabulary` is the smallest vocabulary on which the five rules give
  five different answers, and `Tiny_Model` can now write its vocabulary as a
  byte-pair one, so a byte-pair model prepares, evaluates and reads back.

- `--top-p` has a test of what it does. It was set below one in two places:
  once at zero to prove it is refused, and once at a random value in a test
  asserting only that some usable token comes back. A build in which it did
  nothing at all passed the suite.

- Text is fuzzed, not only model files. A prompt file, standard input and a
  command-line value are untrusted too and reach `Encode` whole.
  `Text_Fuzzing` fails a case that raises, that reports a code the interface
  does not document, that succeeds and hands back a token outside the
  vocabulary, or that takes longer than 50 ms plus 20 µs a character. The
  clock is there because the bracket cost above could not have been found any
  other way.

- Every host body is compiled for every host, in the tests crate as well as
  the library. `src/platform` holds five directories and a build uses two, so
  three were production code no compiler here would otherwise see; `gcc
  -gnatc` stops before code generation but after analysis, so profiles are
  checked against the spec all five share. The sibling `hostkit` crate had
  shipped a Windows body holding `('\\')` where Ada spells a backslash, found
  by building on Windows and nowhere else. Each host must also have exactly
  one body for each platform spec, and a host call may be bound by name only
  from a per-host directory.

- Diagnostics are held in three states rather than two. `Reserved_Codes`
  names the codes nothing raises; `Unreached_Codes` names the codes the
  program raises that no test names, each with why. Seventeen were in that
  third state with nothing saying so -- a refusal written and never made to
  happen is a promise the program has not been asked to keep. Eleven are
  reached now.

- `--repack` and `--no-mmap` are compared through the whole command for the
  first time. The comparison ran the driver in-process with `Set_Output`
  aimed at a file, which cannot catch generated text, so all three strings
  were a single newline and the assertions compared it with itself -- and the
  middle run was not a repacked one at all, because `"--repack f32"` arrived
  as one argument and was refused as an unknown option.

- Every interactive command runs, rather than only parsing. One session was
  driven anywhere in the suite and it typed `hello`, a blank line, `/stats`
  and `/exit`. `/reset` now has to clear the conversation, seen through
  `/context`; a line past the 8192-byte buffer and a line that is not UTF-8
  both have to be refused by name.

- Reusing a committed prefix has to change nothing. It decides whether an
  interactive turn keeps its context and evaluates only the new suffix, and a
  wrong answer in the reusing direction does not crash -- it feeds the model
  a context that does not match the text that was rendered.

- The core count that sets the default worker count keeps a contract, and the
  rule its Linux body applies to each line it reads is somewhere a test can
  hand it a string.

- The changelog itself is checked, against git: no commit touching the
  library, the message catalog or the release gate may be newer than the
  newest commit touching this file. Committing both together satisfies it, so
  the rule in practice is that a change and its entry arrive together. It
  watched `src` alone at first, which left every user-visible string
  uncovered -- a reworded diagnostic is a notable change by any reading.

- Conformance hands a prompt over in several calls as well as one: 1170
  sequences. A prompt longer than `--batch-size` is evaluated in chunks, and
  the seam between them -- where the cache position carries from one call to
  the next -- is where an off-by-one lives; every comparison used to hand the
  whole sequence over at once and never cross it. Eight tokens three at a
  time is two seams.

  Verified by breaking it: subtracting one from the reserved position in
  `Evaluate_Batch` puts 912 logits outside tolerance, and before this
  dimension existed the same fault would have passed the sweep untouched.

- Conformance compares the partitioned path as well as the serial one: 1092
  sequences. Every one of them ran with no worker pool, so the path a real
  run takes -- rows divided across workers -- had been compared only against
  the engine's own serial results. The two checks that do exercise a pool
  compare the engine against itself, so a partition that is wrong the same
  way at every worker count passes both and would have passed the sweep.

  The pool is asked for rather than assumed: the backends that partition are
  the ones that say they do, counted into the expected total like the ones
  that batch.

- Conformance compares the batched path as well as the single-token one:
  858 sequences. `Evaluate_Batch` is what a prompt goes through, and it was
  checked only against the engine's own single-token results -- so the
  strongest statement here, that the arithmetic agrees with an
  implementation written from the architecture description, was being made
  about the decode path alone. Every format, architecture and repacking mode
  is now compared both ways.

  A sequence of one token is the same call either way and is not repeated.
  The reference backend takes a token at a time by design, so the batched
  half runs on the backend that batches -- asked of the backend rather than
  named, and counted into the expected total the same way.

- The checklist fails when the engine decodes a format the fixture cannot
  build. A format arrives with a decoder, a matrix row, a README row and a
  name, and all four of those were checked; whether anything could build a
  file that used it was not, and without that there is no conformance
  sequence for it. Nine of thirteen formats were in that state this morning.
  Both directions are held: a fixture format the engine cannot read fails
  too.

- The conformance run computes how many sequences it should have run. The
  literal was edited nine times in one day -- 32, 96, 144, 192, 336, 384,
  528, 576, 624 -- and a literal can only confirm what somebody last typed:
  twice, a format failed to load, the count fell, and the number was edited
  to match. Skipping one repacking mode now fails the run rather than
  passing it.

- The widest fixtures have a 256-wide feed-forward rather than 512, which
  took the conformance run from 53 seconds to 36 without giving up a
  comparison. The cost is all in the independent implementation, which
  computes in Long_Float without a pool: the narrow formats together take
  0.04 seconds and each deep one about ten.

- Conformance covers every format the engine decodes: all thirteen, in 624
  sequences. The fixture writes each and the reference reads each, both
  worked out from the layouts rather than by calling the engine, so a
  packing mistake cannot be common to the two sides. The five that were
  left -- Q5_0, Q5_1, Q3_K, Q5_K and Q6_K -- are the ones with the most to
  get wrong: a fifth bit indexed by element out of a thirty-two bit word,
  four runs of sixteen spread across a half, and a third bit whose absence
  lowers a value rather than raising it.

  Writing them found a fault in the four the fixture already had: a centred
  level runs -8 .. 7, not -8 .. 8, so the scale has to cover the shorter
  side. Every centred encoder here divided by the longer one, which cost
  about a level of accuracy at the positive end. Q3_K failed its round-trip
  outright and the rest had been passing quietly.

  Q3_K also moved the bf16 figure from 0.090 to 0.254: its weights are the
  coarsest here, so rounding them again into eight mantissa bits moves a
  logit furthest. The lossy bound follows what is measured.

- Conformance covers eight of the thirteen formats the engine decodes, where
  it covered four: binary32, F16, BF16, Q4_0, Q4_1, Q8_0, Q4_K and Q2_K, in
  384 sequences. Both sides had to learn each one -- the fixture cannot write
  what the reference cannot read, and a format only one of them knows is
  silently skipped, which is what happened when the Q4_K fixture arrived
  before the reference could decode it.

  BF16 mattered most: it is what `--repack bf16` writes, so the one format
  the repacking path produces was the one no independent implementation
  could read.

  Q5_0, Q5_1, Q3_K, Q5_K and Q6_K remain decoded by code nothing here has
  read independently. The README says so rather than leaving the count to be
  inferred.

- The fixture builds both k-quants, and conformance compares them: 192
  sequences where there were 96. Q2_K names four levels over sixteen
  elements and leans hardest on its scales, which is why repacking helps it
  most; it was as unreachable from here as Q4_K. Both encoders are held to
  the engine's own reader by a round-trip test bounded by what the format
  can carry rather than by a number chosen to pass, and the reference
  transformer decodes both from the layout rather than by calling the
  engine.

  Writing them turned up a rule neither had followed: the stored minimum is
  subtracted and cannot be negative, so a sub-block sitting entirely above
  zero has to be anchored at zero. The first Q4_K encoder passed only
  because every sub-block of the test data happened to include a negative
  value.

  The rounding figure went 0.032, then 0.064, then 0.090 as the fixtures got
  wider and coarser -- which is the shape of the thing rather than a
  surprise.

- The fixture builds a k-quant, and conformance compares it: 144 sequences
  where there were 96. `Tiny_Model` built binary32 and Q8_0, so every claim
  about quantized weights -- including what repacking to brain floats costs
  -- was measured on those two, while the format a real model most often
  uses was reachable only through a file nobody can commit. The encoder is
  held to the engine's own reader by a round-trip test, and the reference
  transformer decodes Q4_K from the layout rather than by calling the
  engine, like its Q8_0 decoder and for the same reason.

  It doubled the rounding figure: 0.064 where the narrower fixtures said
  0.032, which is the shape of the thing -- wider matrices mean more terms
  and more accumulated rounding.

- `tests external-model --repack MODE` runs a model the caller has both
  ways and says whether the text changed. On TinyLlama Q4_K and Q2_K it did
  not, at 32, 64 and 128 tokens.

- The README says its bf16 figure is a fixture figure. It read as a bound on
  the flag; it bounds what was measured, on models three orders of magnitude
  smaller than the ones the flag is for.

- `tests conformance` runs every repacking mode against the independent
  implementation: 96 sequences where there were 32. Repacking replaces the
  quantized views the kernels decode with binary32 or brain-float ones,
  which is a different arithmetic path through the same engine, and it was
  checked only by a tiny-model test and by hand.

- What rounding to brain floats costs is a number now. On the fixture it
  moves a logit by up to 0.032, and a logit near zero by almost all of
  itself; the rounded comparisons are counted and reported apart from the
  exact ones, because mixing them would let the lossy path's error hide the
  exact path's. `--repack f32` is in the exact set, where it belongs. The
  README said only that bf16 "can change what the model says" and that the
  text happened not to change, which is an anecdote.

- `inspect` prices both repacking modes. It priced the cheaper one, so a
  caller who wanted the exact mode was shown the cost of the other: 4.83 GB
  against 2.63 for a 431 MB Q2_K file.

- `--repack` takes a mode: `f32`, `bf16` or `none`. Binary32 is exact and
  holds the logits to the bit; a brain float rounds to eight mantissa bits,
  writes two bytes a weight instead of four, and is faster everywhere --
  seven per cent on Q8_0, fifteen on Q4_K, thirty-eight on Q2_K, against the
  stored layout. Binary32 repacking is worth it only on Q2_K. A repacked
  model is 4.4 GB in binary32 and 2.2 in BF16, and at that size the product
  waits for memory rather than for the decoder, which is why the format that
  moves fewer bytes wins although it costs more per element.

- A matrix already in the target format is not copied. Every binary32 tensor
  in a file was being copied to itself: a 5024-byte fixture reported a
  9888-byte peak, and an all-binary32 file paid double for nothing. The
  file's bytes are released only when nothing is left pointing at them --
  freeing them under a skipped matrix read outside its storage on the first
  product.

- The decoding is handed to as many tasks as the run has workers. It was one
  core for thirteen seconds on a one-gigabyte model while seven watched;
  three seconds now. The matrices are independent and each writes its own
  region, so the queue hands them out one at a time rather than splitting by
  count, which would have split ten-to-one work evenly.

- Repacking releases the file's own bytes once the copy holds them. Every
  matrix refers into the copy and the vectors were decoded before it ran, so
  what was left was an arena with no reader, held for the life of the model:
  repacking cost the copy and the file at once. It does not move the peak --
  both exist while the copy is written -- it lowers what is held afterwards
  by the size of the file.

- `inspect` reports the peak with `--repack` rather than the size of the
  copy, because the peak is what decides whether it will run: 4.8 GB for a
  Q2_K file whose own weights are 0.43 GB.

- Repacking is exercised on the reference backend and through the whole
  command with the mapping turned off. The first test asked only the backend
  it was written against.

- The load trace says when it is repacking. Ten seconds of decoding sat
  between "reading tensors" and "finalizing model" with nothing in between,
  which was the longest silence in a load and the least explained.

- `tests speed --repack yes` takes the repacking comparison, so the figures
  in the README can be taken again by the tool rather than by hand -- the
  same gap the reference-backend ratio had.

- `inspect` reports what repacking would need, beside what the file needs.
  It was the one number a caller weighing the flag had to have, and the only
  way to get it was to try it and watch.

- `--repack` decodes every weight matrix once into binary32 and evaluates
  from that copy, instead of decoding a span of it on every pass. It cannot
  change what the model says -- the values written are the ones the decoder
  produces, in the order the kernels read them -- and a test holds the logits
  to the bit. A memory limit counts the copy, because four bytes a weight
  against about one is the whole of the trade.

  Measured, it usually loses: twelve tokens of generation take 1.34 s
  repacked against 1.11 s stored for Q8_0, 1.44 against 1.11 for Q4_K, and
  1.34 against 1.52 for Q2_K -- so two losses, one twelve per cent win, and
  ten seconds of decoding at load in every case. The kernel figures say a
  binary32 product is the fastest per element, and they are measured on 64 MB
  where the model is 4.4 GB repacked: at that size the product waits for
  memory, not for the decoder. That is why it is a flag and not a default,
  and it is written down in the README where the old "not implemented"
  paragraph was.

- `inspect` reports which backend would evaluate the model and how many
  worker tasks it would take, and `--show-stats` reports which one did and
  how many it had. Neither is read back off the command line: `--backend
  reference` takes one worker whatever `--threads` asked for. Two backends
  produce the same logits and differ by about twelve times in wall clock, so
  which one ran is the first thing a timing needs to say, and it was
  knowable only by remembering what was typed.

### Changed

- **The adapter merge is tested on a weight that is not square.** The
  fixture's query projection is as many rows as it has columns, so a merge
  with its rows and columns the wrong way round reads the pair transposed
  and still fits, still runs, and still produces a plausible model. Nothing
  about a square matrix can tell the two apart.

  The fixture that states its key and value head widths separately has a
  query projection of sixteen rows by eight columns. Transposing the shape
  check fails against it and passes against the square one.

  That is three tests now whose fixtures were chosen so that two things
  differ: the key and value widths, the model with and without an adapter,
  and a weight's rows and columns. One of the three found a real bug and the
  other two would not have found theirs.

- **The half-precision cache is swept on a windowed model too.** The two
  storages are two procedures and each carries its own copy of what a window
  means; the sweep ran the halved one only where there is no window, so half
  of "both are reached by the sweep, so neither is a copy nothing runs" was
  resting on the other procedure's code. It is reached now.

  It is also correct, and it costs more than it did: 0.0327 worst absolute
  against the independent implementation with a window where it is 0.0218
  without one. A window sharpens the softmax, so a rounded key moves a logit
  further -- the same reason brain floats cost more on a windowed model.

- **`tests benchmark` measures merging an adapter**, at rank one and at rank
  sixteen. Nothing changed in the merge, and that is the finding: the
  measurement was taken to justify rewriting it and said not to.

  The rank-one figure alone -- 4.4 ns an update -- extrapolates to about a
  minute for a rank-sixteen adapter on a billion-parameter model, which is
  what prompted the rewrite. It is the wrong figure to extrapolate from. A
  rank-one merge reads and writes each weight for a single update; a
  rank-sixteen merge amortizes that read and write over sixteen, and comes
  out at 0.27 ns an update. The real answer is about four seconds, and the
  restructure written to fix the imagined minute measured slower than what
  it replaced, twice, so it was thrown away.

  Both ranks are reported for that reason. One of them is a number that
  would have been believed.

- **Sampling is fifteen times faster on a real vocabulary.** It runs once per
  token over as many candidates as the model has tokens, and every fixture
  here has sixteen, so nothing in the tests would have shown it: 2.86 ms a
  token over 32,000 candidates, because a top-k of forty was reached by
  sorting all of them.

  A small top-k is now selected rather than sorted. The order candidates are
  ranked by is total -- the logit and then the token, so equal logits still
  have an order -- and any correct way of taking the first k of a total order
  takes the same k in the same places, which is what makes the change
  invisible in the output. A large top-k is still sorted: keeping k in order
  as you go costs more per candidate than sorting does once k is big enough,
  and where the two cross is a judgement written where it is made.

  0.18 ms a token with top-k, top-p, min-p and a penalty; 0.062 ms greedy.
  A test holds the two paths to each other over two dozen seeds on a
  distribution with deliberate ties, since a tie is where two orders that
  disagreed would disagree.

- **`embed` evaluates in batches.** It read its text a token at a time,
  because that was the only path that left a hidden state behind for each
  position. The batched path now writes every position's state when a caller
  asks for one, so embedding a text costs what reading a prompt costs: the
  kernel figures put a matrix product over thirty-two vectors at 1.87 times
  the elements a second that one at a time manages, and a text to be embedded
  is exactly that shape.

  `--batch-size` is accepted by `embed` now, since it is the option that
  controls what it does. It does not change the answer, and the test says so:
  a batch of one, a batch of two and the default all have to agree. That is
  the property that could have gone wrong quietly -- a batch that pooled the
  wrong positions, or pooled the last batch instead of the last token, would
  still produce a plausible vector of the right length.

- **The grammar filter is 725 times faster.** It runs over the whole
  vocabulary at every step, and the fixtures this suite uses have sixteen
  tokens, so nothing in the tests would have shown what it cost on a real
  one: 7.4 microseconds a token, which is 0.24 s a step over 32,000 tokens
  -- several times the forward pass it was filtering.

  All of it was copying. A matcher holds 256 stacks of 64 positions;
  stepping cleared the whole array and testing a token copied it twice,
  whether or not the stacks were in use. Now the count bounds what is copied
  and what is cleared, the slots carry no default so declaring a matcher does
  not write 65 kilobytes, and a token whose first character no live stack
  accepts is refused before anything is copied at all -- which is most tokens
  at most steps.

  10 ns a token where the grammar allows one character next, 116 ns inside a
  run of letters where most tokens survive to be matched in full. Over 32,000
  tokens: 0.3 ms and 3.7 ms a step, against about 85 ms for a token of
  TinyLlama-1.1B. `tests benchmark` reports both, because they are different
  enough to be worth reporting apart.

- **The conformance sweep runs the reference once per fixture and sequence
  instead of once per comparison.** It reads the file and the tokens and
  nothing else -- it does not know which backend it is being compared
  against, and cannot, because it has none -- so the comparisons that differ
  only in backend, repacking, batching or pooling were each paying for a
  forward pass whose answer was already in hand. 780 reference passes where
  there were 6435.

  The sweep went from nine minutes to two and a half while covering three
  times what it covered this morning, and every published figure is what the
  eight-fold version reported to the last digit. The suite runs the same
  sweep, so it is the same saving twice.

### Fixed

- **A context saved before an adapter was merged could be read after it
  was.** A cache is what the model made of what it read, so it belongs to
  the weights that made it; merging an adapter replaces those weights. The
  two models were indistinguishable to anything reading a saved context, so
  the cache would have been accepted and the model would have continued a
  conversation it never had -- with nothing about the text to show for it.

  What identifies a model now includes a digest of every adapter merged into
  it and the scale it was applied at.

  The test that found it passed before the fix, and that is the part worth
  recording. Written against the binary32 fixture it appeared to prove the
  case already handled: nothing is repacked for an all-binary32 model, so
  the merge writes into the file's own bytes, which the identifier samples.
  A quantized model is repacked into a second buffer, the merge writes
  there, and the file is untouched -- which is every model anyone would use
  an adapter with. Against that fixture the two fingerprints were equal to
  the digit.

- A run the reader interrupts leaves with the status the help promises.
  `Cancelled` is not `Runtime_Error`, so the command fell through to success
  and told a script the generation had finished normally, while `help` names
  "7 cancelled" and the error table maps `MR-GEN-0006` to seven. Cancellation
  during loading already came out that way; only cancellation during
  generation did not.

- An inspection that prints a refusal leaves with the status of that refusal.
  A model whose architecture this build does not implement was reported --
  correctly, and the rest of the report is worth having -- and the command
  left with a success, telling a script the file was fine. And `--validate`,
  whose whole output is a verdict, called such a file valid: it answered
  whether the container was sound and not whether this build can use the
  model, which is the question the option appears to answer and the one
  `run` answers with four.

  Found by asking which of the eight exit statuses the help promises any test
  observes. Five of the eight; 4, 7 and 8 were named nowhere. Asking for
  seven found it was produced by nothing at all, and asking for four found
  two commands that printed an error and left with a zero.

- A capture empties its file through the standard library before opening a
  descriptor on it, instead of asking for create-and-truncate with flag values
  that are not the same on every host. `O_CREAT` is 8#100# on Linux and
  16#200# on macOS; `O_TRUNC` is 8#1000# and 16#400#. The Linux numbers meant
  that on macOS the open never asked for truncation, so each capture wrote
  over the start of the previous one and left its tail behind: a run producing
  one byte read back as the nine before it. That is what made the stop test
  compare a truncated run against an untruncated one and find them equal, and
  it would have done the same to any test comparing two captures. `O_WRONLY`
  is 1 everywhere, which is the one value worth hard-coding.

- The suite passes on every host the project supports, not only on the one
  it was written on. Three separate faults, all found by continuous
  integration and none by the release checklist, which had been passing
  locally throughout:

  The check that compiles every host body ran a bare `gcc`. On a runner
  that has one without `gnat1` behind it, all ten bodies were reported as
  failing to compile, including the two the build had just made. It goes
  through `alr exec` now, and a run in which *every* body fails says that the
  compiler is the more likely explanation than the tree.

  `Captured_Output` did nothing on Windows. It reached the host through
  `Hostkit.Descriptors.Assign`, which is `dup2` on POSIX and `SetStdHandle`
  on Windows -- and `SetStdHandle` changes the handle `GetStdHandle` answers
  with, not the C runtime's descriptor 1, which is what `Ada.Text_IO` writes
  through. The redirection silently failed, the capture came back empty, and
  five tests failed there while passing here. It has a body per host now,
  in the directories the project file picks, binding the runtime's own
  `dup2` and `_dup2`; the Windows one opens in binary mode, because text
  mode would turn every line ending into two and the comparison would be
  against something the program never wrote.

  And the transcript the README publishes for `inspect` showed `worker
  tasks 7`, which is one per physical core less one on the machine it was
  taken from. The command asks for four now, so the line is the program's
  answer rather than the machine's.

  Four more were the host's line ending. Every capture in the command-line
  tests is written through `Ada.Text_IO`, which ends a line the way its host
  does -- one character here and two on Windows -- and a test comparing a
  captured line against a literal then found `cpu` followed by a carriage
  return and reported that the program printed something else. The same
  applied to the README, which a checkout gives back the host's way. Both
  come in without carriage returns now; the model file, which is not text,
  is still read raw.

  One was the executable's name: the repacking comparison looked for
  `../bin/model_runner` and refused to compare when it found none, which is
  what a host that writes `.exe` gives it.

  And one is a difference between hosts rather than a fault. Replacing a
  file this process still has open is a POSIX arrangement -- the name is
  unlinked and the open handle keeps the bytes -- and Windows refuses to
  delete an open file at all. The test says so and checks the half that
  holds on both, rather than staging something else and calling it the same.

- `run --help` prints the help for `run`. It printed the top-level screen,
  byte for byte identical to bare `help`, discarding the command it was typed
  against; `help run` gave the useful answer and the flag did not. The option
  registry marks `--help` as belonging to every command, which reads like it
  was meant to be command-aware, and no test named the option at all, so this
  was nobody's decision.

- The changelog gate asks git about ancestry rather than about dates. It
  compared committer timestamps, which a rebase rewrites and a skewed clock
  gets wrong, and two commits made in the same second compared equal and
  passed. It now asks whether the commit that last touched the program is an
  ancestor of the one that last touched this file.

- A marker written into the text -- `<|im_start|>`, `</s>` -- is one token on
  both tokenizer roads. The rule that turns a marker back into the token it
  stands for lived inside the byte-pair road alone, and a chat template
  substitutes `bos_token` and `eos_token` as their *spelling* before anything
  is tokenized. So every templated turn handed a SentencePiece model its own
  end marker as a run of byte tokens, and a model that sees the letters
  answers in letters, spelling its end marker out instead of stopping. On the
  fixture `"a</s>b"` was seven tokens and is four. `Encode` now cuts the text
  at every marker and encodes what lies between on whichever road the
  vocabulary names; text holding no marker tokenizes exactly as before.

- A prompt of brackets no longer costs six hundred times what ordinary text
  costs. The scan for a control token runs wherever the text opens a bracket
  and tried every length up to `Max_Token_Bytes`, 1024 -- thirty times longer
  than any real marker -- so the cost fell on whoever wrote the text rather
  than on whoever wrote the file. Prompt files and standard input are
  untrusted and the documented input limit is 65,536 code points, so this was
  a denial of service anyone could send: sixty thousand brackets took 25.5
  seconds where sixty thousand ordinary characters took 0.039. The vocabulary
  records the longest piece it calls a control token that opens a bracket and
  the scan stops there -- four bytes for the fixture, about seventeen for a
  real vocabulary. The same prompt takes 0.045 seconds.

- A byte-pair buffer too small for the answer is reported rather than filled
  as far as it goes. That road wrote into the target under a test for room
  and did nothing when there was none, so a cramped caller got a short answer
  and a success, where the SentencePiece road has always raised
  `MR-TOK-0013`.

- A piece a byte-pair vocabulary cannot spell is marked unknown rather than
  dropped. It used to be deleted from the caller's own prompt without a word.
  A byte-level vocabulary carries a piece for every one of the 256 stand-in
  characters so it cannot happen to a file written properly, and a file that
  was not is the case this program exists to survive. `MR-TOK-0014` was
  reserved for it and now reports it.

- `tests speed` fails when it measured nothing. With no `--model`, and with a
  path to a file that is not there, it printed "nothing measured" and left
  with a success. Every other campaign here refuses to pass on having done
  nothing.

- The suite no longer writes the program's generated text into its own
  report. Generated text goes through the raw stream of
  `Ada.Text_IO.Standard_Output`, which `Set_Output` does not redirect, so
  seven fragments of it sat in the middle of the AUnit report on every run --
  and the same mechanism let a comparison of generated text compare one
  newline with itself for as long as it existed.

- The `inspect` report goes to standard output. All of it went to standard
  error, so `inspect MODEL > report.txt` wrote an empty file, and
  `--metadata` and `--tensors` could not be redirected either. Headings and
  fields now name the stream they belong on, with no default, because the
  report inherited standard error from a choice nobody at the call site had
  to make. The README's stream table did not mention `inspect` at all; it
  does now.

- The headline speed figure names its input and can be taken again. It said
  "from a short prompt" and named no prompt, no token count and no worker
  count, so it could not be reproduced: the repository's own long prompt
  gives four times the number and a short one gives a quarter of the stated
  prompt-evaluation time. What made the published split plausible was the
  chat template, which turns six words into twenty-eight tokens -- and a
  templated run of this model stops at its end-of-sequence token after seven
  tokens, so it was not a twelve-token measurement. The figure is now the
  seven-token prompt in `tests/fixtures/speed-prompt-short.txt`, run with
  `--raw`, and the command is printed beside it: 1.28 s, 0.26 s evaluating
  and 1.02 s generating, 9.3 s of processor time. The worker-count and
  share-count figures beside it are re-measured in the same configuration.

- `tests pristine` clones what git carries beside its siblings, builds it,
  and runs the suite and the repository checks there -- twenty-three seconds,
  nothing fetched, every pin a path. The clean-checkout property was prose in
  the README and a sequence typed by hand; it is the one arrangement where
  the repository is what a reader gets, and the one where the suite failed
  for forty pushes while passing here. Removing every fixture write and
  committing it makes the command say the suite fails on a tree holding only
  what git carries, and leaves the clone where it says.

- The number of checks a run performs has a floor. It is the number quoted in
  every report of a run and nothing pinned it, so a check that stopped
  running, a scan that stopped finding, or a tree with fewer files in it
  would all have read as a clean run. A floor rather than a figure, because
  one check weighs every file in the tree: a clone counts four fewer than the
  tree it came from, which is a generated config and an editor's settings,
  and that is now written where the counting happens.

- No test names a model file under `fixtures/` by hand. That path is ignored
  by git -- a model file is not committed unless its licence plainly allows
  it -- so a model read from there must come through
  `Tiny_Model.Suite_Fixture`, which is beside the operation that writes it,
  or be written into `obj` like every other fixture the suite builds. The
  rule is what stops the next test from depending on a file the repository
  does not carry.

- The README no longer says the suite does not need that fixture. It said so,
  and it was the belief behind forty consecutive red CI runs.

- The clean-checkout path is verified rather than only described: clone,
  siblings, `alr update`, `alr build`, the same two in `tests`, then the
  suite and the repository checks. 169 tests and 3783 checks pass on a tree
  holding only what git carries.

- The suite writes the fixture it reads. `tests/fixtures/*.gguf` is ignored
  by git -- a model file is not committed unless its licence plainly allows
  it -- and four tests read `fixtures/tiny-model.gguf` as though it were
  there. It was there on the machine where `tests fixtures` had been run,
  and on no clean checkout, so the suite passed here and failed in
  continuous integration on every push. Any test that reads the fixture
  writes it first; the bytes are fixed, so it is the same file every time.

- The interactive commands are one list. `Command_Kind` named seven, a chain
  matched seven words beside it, and `/help` printed seven catalog keys
  written out in order, with nothing relating the three -- so an eighth
  command would have compiled, parsed and dispatched without appearing in
  the only screen that lists them, and this was the one command enumeration
  in the program that answered to no check. The word lives on the
  enumeration now; the parser matches against it and `/help` builds its
  keys from it.

- Every interactive command's help line must name the command, in every
  locale that carries the line. The words were written a fourth time inside
  the help text itself, so renaming one would have left every translation
  advertising something the parser refuses. Changing the Danish line for
  `/stats` fails; renaming the command without touching the catalog fails
  three times.

- `model_runner help NONSENSE` is a usage error. It printed the general help
  and exited successfully, so a mistyped topic was answered with a screen
  the reader had not asked for, while the same word typed as a command was
  refused by name and exited 2. A topic is a command name, and one that
  names no command is refused the same way.

- The help screens are dispatched on the command rather than on the word,
  and the list of commands in the general help is built from the
  enumeration. The chain named four topics beside a `Command_Kind` naming
  exactly those four, with nothing relating them: a fifth command would
  have compiled, dispatched, taken options and had no help at all. The
  checklist now requires a usage line, a summary, an options heading and a
  line in the general help for every command, and that every command word
  names its own command.

- The catalog check reads the root it was given. It opened the catalog
  beside the executable while every other check here reads the file under
  the root `tests check [ROOT]` names, so pointed at another tree it
  answered about this one: a copy with a deliberately broken catalog
  reported four missing files and nothing about the catalog. A check that
  reports on a file nobody asked it about is worse than no check, because
  it reports green.

- The parser records which options it saw as a set over the option
  registry. It kept a list of sixty-four names, allocated one string per
  option and freed none, and silently stopped validating past the bound --
  a cap of exactly the kind the rules here refuse elsewhere. A set has room
  for every option that exists, by construction, allocates nothing and has
  no bound to exceed.

- The repository checks load the catalog rather than only reading it. Every
  other check reads it as text -- keys, readers, counts, help lines -- and
  none of that notices a catalog the message runtime refuses, which it does
  for the whole file at once: every locale stops loading, the program
  renders identifiers in angle brackets, and nothing says why. It happened
  while the option registry was being written, and surfaced as four
  unrelated locale tests reporting that a catalog did not load, which is a
  long way from the line that caused it. The locales are taken from the file
  rather than listed, so one added is one checked, and each must render
  rather than reach the emergency form.

- `inspect` refuses an option it does not take. Every option reached every
  command: `inspect m.gguf --temperature 0.5 --interactive --raw` ran the
  inspection and said nothing, on a command whose help documented five
  options while thirty-seven were reachable. `MR-CLI-0020` now names the
  option and the command.

- The options, the commands that take them and the help lines that document
  them are one registry. The help screens are generated from it, so a screen
  cannot say less than the command accepts, and the checklist holds the
  parser against it in both directions.

- `inspect` documents `--quiet` and `--verbose`, which it has always
  honoured, and takes `--threads` and `--backend`, which decide the two
  figures it reports. `--locale` and `--color` reach every command,
  including `help` and `version`, where they had never been documented and
  were briefly refused while this was being written.

- Every command of the tests tool refuses an option it does not take, and
  the check happens once rather than in each command. Five of eleven checked
  and six did not: `tests check --nonsense` ran the whole gate without a
  word, `tests docs --nonsense` read the typo as a directory and failed at
  writing it, and `tests fixtures --nonsense` died with an unhandled
  exception and a stack trace. The option lists are in the registry beside
  the commands, one place reads them before dispatch, and a command with no
  options says so rather than printing an empty list.

- The usage text and the option list of a command must agree. They were two
  hand-written strings, added a day apart, saying the same thing about the
  same command with nothing holding them together -- which is the fault the
  registry was introduced to end, one level further down. An option shown
  and not accepted fails, and an option accepted and not shown fails; the
  first one found was `tokenize`, whose usage said `--text` where the
  command takes `--prompt`.

- The tests tool answers for its own commands. It has eleven; its usage line
  named six, so mistyping one told you about half the tool, and the README's
  tooling row named a different seven -- missing `tests speed`, which a
  section of that same file had told readers to run since the day before.
  Both lists sat beside a dispatch chain neither could see. The set is a
  registry now: the usage line is built from it, and the checklist holds the
  dispatch and the README against it in both directions. `tests` with no
  command prints every command, what it takes and one line on what it is
  for.

- `tests benchmark` reports the median of three rounds. It reported a single
  pass while every figure it feeds is published as a median of three, so the
  last step was left to whoever remembered it -- and on this part the spread
  is about a tenth: the same number came out 11136, 12574 and 12944 Me/s on
  three consecutive runs. A single pass read against a published median can
  look like a regression that is not there, and can hide one that is.

- `tests benchmark` takes `--seconds` and `--rounds`. `Run` had a `Seconds`
  parameter that nothing on the command line could reach, so the one knob
  that would steady a figure existed and could not be asked for.

- The pinned figures say how to pin. `taskset -c 0-7 tests benchmark` on this
  machine, with the reason the list is 0 to 7 and the file to read it from on
  another machine. It was the one measurement here that no documented means
  could reproduce, and it is in a group whose fingerprint fires like the
  rest. Re-taken that way, eight shares reads 13134 Me/s against seven at
  12532; the older 9326 needs the commit before the change and is quoted as
  history rather than as something to reproduce.

- The batch-size table is measured the same way as the figure above it. It
  was rendered through the chat template while that figure was raw, and
  neither said which: its caption's "131-token prompt" was the file's 110
  tokens after the template wrapped them, so a reader following the printed
  command got numbers about a quarter lower with nothing to explain the gap.
  Both are raw now, and the table carries the command that produces it.

- `tests speed` takes `--batch-size`, and reports a digest of what was
  generated. The table's last column claims that `--batch-size` changes no
  output; the claim now belongs to the thing that takes the measurement
  rather than to whoever last read the table.

- `tests speed --model PATH` takes that measurement three times and reports
  the median, so the fingerprint duty -- re-measure and record what you get
  -- is a command rather than an instruction. It needs a model the caller
  already has; nothing is downloaded and a missing file is a skip.

- The reference backend takes about twelve times as long, not forty. The
  figure was published when the backend was added, taken by hand and never
  checked; re-measuring it on the machine and model the other figures use
  gives 12.5x -- 18x on the prompt, where the CPU backend batches and this
  one does not, and 11x on the generation. `tests benchmark` measures the
  two against each other now, so the algorithmic part of the ratio can be
  re-taken without a model: 2.3x for q8_0, 2.4x for q4_k, 3.1x for f32,
  serial against serial. The rest of the twelve is the worker pool.

- `docs/measured-figures.txt` has a group for that comparison.
  `model_runner-backend-reference.adb` was named in no group, so the one
  file that could move the published ratio was unguarded by the document
  whose whole rule is that a published figure names the sources it depends
  on.

- `Presentation.Open` says that it writes the colour policy of
  `terminal_styles`, which is global to the process, and what that costs a
  caller who uses that library too.

- `--color always` colours a destination that is not a terminal, which is
  the only arrangement in which it differs from `auto`. The decision was
  made here and then made again by `terminal_styles`, whose own policy
  defaults to auto and judges auto by whether standard output is a terminal;
  the second gate won, so three modes were two and the mode a caller reaches
  for when piping to a pager did nothing. A global judged by one stream
  cannot answer a question asked per stream, so the library is told to emit
  what it is asked for and the decision stays where the mode, the
  destination and `NO_COLOR` are all in hand.

- Styling asks the stream a line is going to. Every styling decision asked
  whether standard error was a terminal, whatever stream the line was for,
  so moving the inspection report to standard output made
  `inspect MODEL > report.txt` write thirty-five escape sequences into the
  file: a terminal was still attached to standard error, which is what
  redirecting one stream and not the other means. `Output_Is_Terminal` was
  captured by the driver and read by nothing but `Supports_Interaction`, so
  the README's claim of per-destination styling had never been true; it
  could not bite while nothing but unstyled generated text used the other
  destination.

- Every test that read what a command wrote redirected both streams into one
  file, so no test could tell them apart and the five stream claims were
  checked by nothing. One test now runs each command with the streams kept
  apart and holds each claim.

- Every catalog key has a reader, and every message key the code names has a
  catalog entry. Ten keys had no reader: three of them read as capability
  rather than as cruft -- "backend" and "worker tasks" were labels for
  figures nothing printed, and "the model has no chat template; the prompt is
  being sent unchanged" described a fallback the program refuses to make.
  Six were removed and four wired to what they claimed. In the other
  direction a mistyped key shipped as `<cli.inspect.label.wrkers>`, in every
  locale, with the whole gate green.

- The pseudo-locale test walks the whole catalog. It walked `Error_Code`, so
  it covered 148 of 343 keys and skipped help, inspect, statistics,
  interactive and progress -- where a string that never went through the
  catalog would hide.

- The source walk recurses. It searched one level, so every scan kept a list
  of directories by hand: three scans were given `src/platform`, which holds
  no sources of its own, and visited nothing while reporting nothing; the
  older scans named three of the five host directories, leaving `linux` and
  `macos` -- the two holding the topology bodies -- outside the layering,
  lowercase and environment rules. The walk must now reach 120 files or it
  fails, so a scan that stops arriving says so.

- Line length is measured in `src/platform` and `tools/src`, and the GNATdoc
  rule covers the tooling crates, where it found `tiny_model.ads` carrying
  three headers for one subprogram and one subprogram's parameters
  documented against another.

- The README's list of what is not implemented said a second backend was
  absent for two commits after the reference backend arrived. Every positive
  claim was checked against the code and the list of absences was checked by
  nothing, which is the worst place for a stale claim: the section whose
  purpose is to say what the program does not do reads as modesty.

- `Library_Surface` lists the public operations the program itself never
  calls, with the reason for each. The check that every public operation has
  a reader counted a test as a reader, so thirty-three operations passed it
  exactly as one used on every run does, and it took a script to find out
  which. This is a library as well as a command and a wider interface is
  allowed; how much wider is now a thing somebody chose.

- The backend section of the support matrix and the README's backend row
  described one backend. Worker pools, partitioned rows, bounded queues and
  batched prefill were listed flat, as capabilities of "the backend", when
  every one of them belongs to `cpu` and the `reference` backend
  deliberately has none of them. Each capability now says which backend it
  belongs to.

- The release checklist fails when a backend this build has is missing from
  that table or from the README's row. Backends were checked where they are
  listed -- the help line, the version screen -- and not where they are
  described, which is how the description outlived them.

- Interactive mode clamps the batch size to what the backend can do.
  `--interactive --backend reference` refused its first turn: the clamp was
  written into the single-shot path and the interactive one builds its own
  request. Both ask `Llama.Capability` now, so the decision has one home
  rather than two.

- `tests conformance` runs both backends, so the independent implementation
  checks the reference backend too. That the two backends agree says the
  fast path's partitioning and batching change nothing; that both agree with
  a third implementation says the arithmetic is right, and that was being
  said about only one of them.

- The gate reads the build's diagnostic logs, for the library as well as the
  tests and the tools. Nothing had ever read the library's: forty-nine style
  faults and warnings were waiting under `obj`, because the only thing that
  looked at build logs looked at the other two trees. All are fixed, and a
  warning left behind now fails the gate.

  A caveat the check cannot remove: those logs are written where the build
  ran, so a tree built only from `tests` leaves the library's logs stale. The
  release checklist builds the library first, which is why it is the one that
  found them.

- The aggregate release checklist runs `tests check` as one step. It ran the
  suite, the conformance comparison and a fuzzing campaign as four separate
  steps, which was a second definition of what must pass, kept in step with
  the first by hand. The long two-thousand-case campaign stays, because that
  one is the checklist's own addition rather than a repeat.

- Six compiler warnings and layout faults in the test sources, all introduced
  during this session's work and none visible to `tests check`: the aggregate
  checklist requires the build to produce an empty stderr log, and it is the
  only thing that reads them.

- `tests check` runs the suite. Calling it the gate while a hundred and
  sixty-four tests were a command somebody had to remember was the same
  mistake as leaving conformance outside, made in the sentence that fixed
  that one. It costs 1.3 seconds.

- The gate fails when a test procedure is written and registered by nothing,
  and when the suite registers fewer tests than it had. A test nobody
  registers runs nothing and passes quietly, which is worse than not writing
  it: the count goes up and the coverage goes down.

- The gate asks whether the fuzzing campaign reached the engine.
  `Fuzzing.Reached_The_Engine` exists to say that clean totals mean nothing
  if every case stopped at the parser, and the gate added an hour earlier
  did not call it: a parser that refused everything left `escaped 0,
  internal 0` and the gate green. It also prints `prepared` and `ran` now,
  so a reader can see the same thing.

  This is why no mutation could make the fuzz half fail. It was not failing
  to catch a parser regression; it was failing to check that the campaign
  did anything at all.

- A gate failure says which of the two it was, rather than leaving the
  reader to infer it from a count of zero.

- `tests check` runs the conformance comparison and a short fuzzing campaign
  itself. Both were commands somebody had to remember: the strongest evidence
  this repository has that the arithmetic is right, and the only thing that
  puts a mutated file in front of the parser, were outside the gate. A
  release could have been cut with the suite and the checklist green and the
  two implementations disagreeing. They cost forty-four milliseconds and
  ninety.

- The README's conformance row described one architecture and one reference
  while the figures twelve lines below had grown to sixteen sequences. It
  says what the run covers, and that the gate runs it.

- `Reference_Transformer` reads `qwen2` too, so `tests conformance` compares
  both architectures against an independent implementation. It knew only the
  interleaved rotary and no attention bias, which meant the architecture
  added yesterday had nothing independent to be checked against -- and the
  ordering of the bias against the rotation was the one thing the fixtures
  could not see. Moving the bias to after the rotation now puts ninety
  logits outside tolerance.

  The published relative divergence moved seventy-fold and the README says
  why: it is one logit close to zero. In absolute terms the two
  implementations agree more closely on `qwen2` than on `llama`.

- The `Llama` package said "exactly one architecture is supported", fourteen
  lines above the enumeration that lists two. The README's capability row
  described only that one. Both say what the build reads, and the release
  checklist fails when an architecture this build has is missing from the
  matrix's architecture table or from the README's row.

- The tests binary refuses an option its command does not take. It read the
  arguments it knew and ignored the rest, so asking `tokenize` for `--text`
  when it takes `--prompt` tokenized the default prompt and printed it with
  no complaint -- the same answer for every input, while a real defect was
  being chased with it.

- `CLI.Options.Max_Path` is gone. It said a path was bounded at four
  thousand and ninety-six characters; the type that holds one stops at five
  hundred and twelve, so the stated limit was not merely unenforced but
  wrong. `Bytes.Empty_Bytes` is gone with it, as a constant nothing read.

- The release checklist covers public constants as well as operations. A
  limit written into a spec is read as a limit that holds, and this session
  has found four claims of that shape unenforced.

- A session reset clears the token history. `Bytes.Wipe` said it was used to
  clear prompt and generated-text buffers on session reset; it was called by
  nothing, and it could not have done that job -- the conversation is held as
  tokens and as text, neither of which is a byte array. The history is
  cleared directly now and `Wipe` says what it actually is.

- `Memory.Record_Conversion` is called where a tensor is converted, which is
  what it was written for.

- The release checklist fails when a public operation has no caller anywhere
  -- in the program or in a test. This is a library as well as a command, so
  its interface is wider than the command uses; being untested is a
  different matter, and fifteen operations were in that position. They are
  exercised now.

- A model file replaced between validation and reading is refused with
  `MR-GGUF-0002`. The container is parsed and its shapes checked, and only
  then are the tensors read; a file replaced in that window -- a download
  finishing over it, a build writing a new quantization to the same path --
  was read as though it were the file that had been checked.

  `Size_Changed` was written for exactly this and its own documentation said
  it was used before the tensor-loading stage. Nothing called it, and
  `GGUF_File_Changed` sat on the list of diagnostics this program declares
  and never produces. Every byte source answers `Changed` now, so the engine
  asks rather than the caller remembering to.

- A session reports whether it is reading a prompt or writing a reply.
  `Evaluating_Prompt` was declared and entered by nothing: the evaluator set
  `Generating` whether the tokens were a prompt or a reply, because it cannot
  tell the difference, and the caller who can never said so.

- `Completed` and `Cancelled` are gone from `Session_State`. They described
  what became of a request, which its result records, while the session that
  ran it is ready for the next one -- so they could not have been entered
  correctly even once. A session now returns to `Ready` when a request ends.

- The release checklist fails when a session state is declared and entered by
  nothing.

- `Recovery_Class` was computed for every diagnostic and read once, for one
  of its five values. Three quarters of that table was consulted by nothing.

- `Param_Duration_Ns` and `Param_Shape` are gone: two formatting rules for
  values no diagnostic reports.

- The release checklist fails when a value of `Parameter_Kind`,
  `Recovery_Class` or `Severity_Level` is declared and used by nothing.

- `--memory-limit` bounds the session as well as the model. It set the
  model's limit only, and a session's limit defaults to unlimited, so a
  caller asking for a hundred megabytes could be given a model inside it and
  then a KV cache of any size at all. The KV cache grows with the context and
  is the largest thing a session allocates.

- Nine of eleven accounting categories were charged by nothing. The session
  plan computed every one of its figures and threw them away, so the account
  read zero for the KV cache while the session held it, and the vocabulary's
  storage and the container's metadata -- megabytes each on a real model --
  were counted nowhere. All of them are charged now, and `Accounting` reports
  what a model and a session hold.

- `Temporary_Workspace` was removed rather than charged: the buffers it named
  are allocated and released within one call, and the limits that size them
  already bound them.

- The release checklist fails when an accounting category is declared and
  charged by nothing.

- `Prompt_Rendered` is reported. It was declared and published by nothing:
  generation is handed a prompt already rendered and never sees the
  conversation it came from, so only its caller could ever say so, and its
  caller did not.

- The release checklist fails when a progress stage is declared and
  published by nothing, and a test reads the generation stages out of a
  verbose run. Five stages had been in that position and none of them were
  found by anything.

- The progress trace reports selecting a backend, which it could not before
  because nothing published the event. `Converting_Tensor` and
  `Preparing_Kernels` were removed: they named steps this program does not
  take, and an observer switching on them would have waited forever.

- `Close_Progress` and the flag it tested are gone. The flag was declared,
  initialized to False, tested before every line the program prints, and set
  by nothing -- so the mechanism for finishing a half-written progress line
  had no half-written line to finish.

- The progress trace, a diagnostic and the interactive settings are read by
  tests. Every load stage this build reports has a message of its own and a
  verbose run reaches all of them; a quiet diagnostic is one line, and the
  context frames and file offset a verbose one adds are the lines it
  promises to leave out; and `/settings` shows the figures it claims.

- The `inspect` and statistics screens are read by a test. Both are built
  from many separate calls whose layout lives in the caller, which is the
  property that let three help lines drift out of their column; nothing had
  looked at either. Fields must line up within a section -- the container
  block and the three-column metadata table set their own -- every figure the
  statistics claim must appear, and no line may show a placeholder it was
  meant to substitute.

- The `--backend`, `--chat-template` and `--color` help lines print indented
  and in their places again. Each was moved out of the block that lays the
  help out, one at a time, to give it a value the program computes, and each
  landed flush left at the bottom of the list. `Put_Option` takes arguments
  now, so a line that carries a value and a line that does not are printed
  the same way.

- The help screen is read by a test: every option line indented by exactly
  two spaces, every option `run` accepts present on it, and no line showing
  the placeholder it was meant to substitute. Application text goes to
  `Current_Output` so that a test can take it; the program never redirects
  it, and generated text still goes to standard output as raw bytes through
  a sink of its own.

- The `--color` help lists its modes from the enumeration, in `run` and in
  `inspect`. Only the error message was changed when the modes were made to
  come from one place; the help beside it went on writing "auto, always or
  never" in three locales, twice.

  The release checklist now fails when any help line lists two names the
  program can list for itself. Two, not one, because "never memory-map the
  model file" is the English word and a rule that cannot tell the difference
  is a rule nobody keeps.

- `Localization.Locale` said it reported the locale the catalog resolved to
  and reports the one that was asked for. That sentence is what the
  unavailable-locale warning was written from, which is how it came to say
  that zz was unavailable and that zz was being used.

- `--locale` says when it could not give you the locale you asked for. An
  unavailable one fell back to English and said so only under `--verbose`, so
  `--locale de` produced English output and no reason. A locale named on the
  command line is now reported at any verbosity; one taken from the
  environment still only in verbose mode, because that fallback is ordinary
  and not a request that went unhonoured.

  The warning also said "locale zz is unavailable; using zz". `Locale`
  reports what was asked for, and the message wanted what answered, which is
  now `Answering_Locale`.

- `--color` lists the modes from the enumeration rather than from prose
  written into the catalog in three locales, and the parser matches against
  the same names. Renaming a mode moves the message with it.

- The rule in `Capabilities` -- every field here is asked by something -- is
  a check rather than a comment. The field names are read out of the record
  and looked for in the program with the backend's own assignments
  discounted, so a field added without a reader fails.

- `--chat-template` and `--backend` answer alike. A name neither carries is
  now refused the same way -- `MR-TMPL-0013: no chat format named nope in
  this build` beside `MR-BACKEND-0001: no backend named gpu in this build` --
  where the first used to report an invalid option value, which is true of
  any bad value and says nothing about what there is. A caller could not
  predict which kind of answer an option would give.

  The formats come from an enumeration now, as the backends do, so the help
  line, the matching and the tests read from one place. The help said
  "llama3 or chatml" in three locales and would have gone on saying it.

- Two diagnostics were removed rather than left reserved.
  `CLI_Invalid_Backend` was kept against the day `--backend` existed; it does
  now, and reports `Backend_Unknown`, which says which backend and that this
  build does not have it. `Backend_Unsupported_Operation` was the same shape
  of duplicate for `Backend_Capability_Missing`, which names the capability.
  A reserved code that a working feature has already superseded is not
  reserved for anything.

- The CPU backend said it does not batch, while every prefill went through
  its `Dispatch_Batch`. `Capabilities` is a table the code publishes about
  the code and nothing in the program consults it -- `Describe` has no caller
  outside the checklist -- so the two could disagree indefinitely without
  anything going wrong. It is now checked: the formats it claims must be the
  formats the decoder decodes, and the flags that name an operation must
  match whether the operation is there.

- The chat-template section of the support matrix is checked against the
  code. It was the last hand-maintained registry -- a table of claims beside
  the engine rather than about it -- and it said `set` and the filters were
  rejected for as long as they had been implemented.

  Every row now has a worked example carrying its label. The example is
  compiled and rendered, and where it ends must be the verdict the row gives.
  A row added without an example fails, an example left behind by a deleted
  row fails, a row that calls an implemented construct rejected fails, and so
  does a construct that stops working while its row still claims it.

  No check can invent a row for a construct somebody adds. What this one does
  is stop a row outliving what it says.

- The interactive loop is tested. Nothing drove it for as long as it existed:
  the driver refuses interactive mode unless both descriptors are terminals,
  so the loop could only be reached by hand, and everything it decides went
  unchecked. That is how a command word came to be compared with its argument
  still attached.

  What a line of input does to a turn is now a unit of its own -- accumulate,
  submit, refuse, or run a command -- and the loop itself runs over redirected
  input against a fixture model. A line is read into a fixed buffer rather
  than onto the stack, which the comment there said would be required if
  interactive mode ever accepted input that was not a terminal.

  Generated text is not what the loop test reads. It goes to standard output
  as raw bytes, past Text_IO and past any redirection this process can
  perform. The test asks the loop whether a turn completed instead, which is
  a question the program already answers.

- `/system` with no text removes the system message. It was matched as the
  eight characters `"/system "` -- with the space -- so a bare `/system` was
  not a command missing its argument but an unknown command, and a session
  had no way back to holding no system message at all: `--system` sets one
  before the first turn and `/system TEXT` replaces it, and nothing removed
  it. The conversation layer has removed one on an empty string all along;
  the interactive loop simply could not reach that.

  Reading a line as a command is now separate from acting on it, and tested.
  The loop needs a terminal at both ends and no test drives it, which is how
  the command word came to be compared with its argument still attached.

- The README said the engine decodes seven formats. It decodes thirteen: the
  row had not been touched since BF16, Q4_1, Q5_0, Q5_1, Q2_K and Q3_K were
  implemented. The support matrix still said the multiply was folded into the
  decode for Q4_0, after that had been measured 1.79 times slower and taken
  out -- a claim about performance that the source's own note contradicts.

  The release checklist now asks the code which formats it decodes, through
  `Is_Decodable`, and fails when the matrix or the README's quantization row
  does not name one. The README is checked against that row and not the whole
  file, because every one of the six missing formats was named somewhere else
  in it, and a check that reads the whole file would have passed.

- The support matrix said the tokenizer accepts `llama` and rejects
  everything else, which stopped being true when byte-pair encoding was
  implemented. A row further down the same file described its six cutting
  rules. A reader who trusted the table would have concluded their model was
  unsupported. It now names `gpt2` and every `tokenizer.ggml.pre` rule,
  including `llama-bpe`, which was written nowhere at all.

  The release checklist now reads those names out of the tokenizer and fails
  when the matrix does not carry one. Listing them in the check instead would
  be the same table again, going stale the same way, one file further from
  the code.

### Added

- A second backend. `--backend reference` evaluates the model one row at a
  time: the row decoded whole, multiplied element by element, summed in the
  wide format, on the calling task. No worker pool, no partition, no batch
  sharing, no span buffer -- each of which the `cpu` backend does for speed
  and each of which is a way an answer could be wrong for a reason that is
  hard to see.

  It produces the same logits as `cpu`, exactly, and takes about forty times
  as long. It exists so that a suspicious result on a caller's own model can
  be asked again by different code; `tests conformance` does something
  stronger but only on a fixture.

  It also makes the capability machinery answer for itself: it declares that
  it cannot batch and has one worker, and the command line clamps
  `--batch-size` to one rather than refusing the run.

- `qwen2` files run. They are the same shape as `llama` -- RMS normalization,
  rotary encoding, grouped-query attention, a SwiGLU feed-forward -- with a
  bias on each of the three attention projections and the other rotary
  pairing: element *i* rotated against element *i + rotary/2* rather than
  against its neighbour. Metadata is read under each architecture's own keys,
  so neither name is written anywhere but in the enumeration.

  The biases are required rather than taken if present. A qwen2 file read as
  though its biases were zero produces plausible text that is not what the
  model says, and plausible text is the hardest kind of wrong to notice.

- A diagnostic ends with what can be done about it, chosen from the recovery
  class every code already carried. A limit that was too small says to raise
  it or ask for less; something this build does not support says where the
  list of what it does support is; a usage error says where the usage is
  written. A cancelled run and a closed pipe say nothing, because neither is
  a mistake anybody made -- and neither does a path that is wrong, which is
  not put right by reading the usage.

- `version` reports what this build can take: the tensor formats it decodes,
  the backends it has and the chat formats it carries, all asked of the
  build. It said an architecture name and nothing else, while the same lists
  were already being produced for the help screen.

- Every field of the backend's `Capabilities` is now asked by something. The
  formats and the alignment are checked per tensor while a model loads,
  matrix-vector once when it is prepared, batching when a batch is evaluated,
  and the worker count when the pool is sized -- through the backend rather
  than through the CPU pool's own constants, so a second backend's numbers
  are the numbers used. Disclaiming any of them refuses with
  `MR-BACKEND-0002` or `MR-BACKEND-0004`, naming what was missing.

- Five capability fields were removed rather than wired: `Wide_Accumulation`,
  `Supports_Mapping`, `Supports_Quantized`, `Supports_Noncontiguous` and
  `Deterministic`. Nothing could act on any of them, each could only ever
  hold one value in this build, and a flag with one value documents nothing.
  What `Deterministic` claimed is tested where it can fail: the same text
  from one worker and from four.

- Model preparation asks the backend, per tensor, whether it can read the
  format, and refuses the model with `MR-BACKEND-0002` naming the backend,
  the format and the tensor when it cannot. `--backend` reaches this too, so
  the choice decides what will load and not only what will run.

  No shipped configuration refuses anything: the one backend claims exactly
  the formats the decoder decodes. The point is the seam. `Capabilities` was
  a record the code published about the code that nothing read -- `Supports`
  had no caller anywhere -- and a description nobody consults is one that can
  be wrong for a year, which is what happened to `Supports_Batched`.

- `--backend NAME` names the backend to evaluate the model on. There is one,
  `cpu`, and the option exists anyway: a name this build does not have is
  refused by name and exits as the usage error it is, where before the option
  itself was unknown and a caller learned nothing about what was available.
  The names come from the backend enumeration, in the help as well as in the
  matching, so neither can list one that is not there. Running goes through
  the choice rather than around it, on a case with no `others`: a kind added
  to the enumeration stops the program compiling until something answers for
  it, which is the only way a second backend can arrive without the flag that
  selects it quietly doing nothing.

  `Backend_Unknown` was on the list of diagnostics this program declares and
  never produces, with the reason "there is no --backend to be invalid".

- The chat template a current Llama-3 file ships with now renders. It needed
  variable assignment, list slicing, comments, `is defined`, `none`, the
  `trim` and `length` filters, parenthesised conditions and `'x' in message`,
  all of which are now in the supported subset -- and it also needed
  `strftime_now`, `tojson` and `raise_exception`, which are not and will not
  be.

  The way both are true at once is where a construct is refused. A statement
  whose shape cannot be read is still refused at compile time, because
  nothing after it can be trusted to mean anything. A value that cannot be
  computed is now carried through compilation and refused at the point it is
  asked for. Every one of those templates describes tool calling in branches
  that a conversation of plain messages never enters, so refusing the
  template for them refused the model; refusing at the point of use refuses
  only what was actually asked for. Nothing is approximated either way, and
  a render that reaches one of them ends with `MR-TMPL-0002` naming the
  construct rather than producing a prompt that is nearly right.

  `--chat-template` stays, for the models this still cannot read.

- Template errors that name a variable or a filter now say which one.

- `MR-TMPL-0011` reports a template whose variables need more room than the
  render has for them. It was reported as the rendered prompt being too
  large, which is a true sentence about the wrong subject.

- `--chat-template NAME` uses a chat format this build carries -- `llama3` or
  `chatml` -- in place of the model's own. Some models ship a template that
  assigns variables, slices lists, calls functions and formats dates, most of
  it to describe tool calling, and interpreting that on text from a model file
  is a larger and more exposed thing than formatting a conversation. The
  reference implementation carries named formats for the same reason. Nothing
  is chosen on a model's behalf: a chat format applied to the wrong model
  produces output that looks entirely reasonable and is not what the model was
  trained on.

- Chat templates may name a message by position -- `messages[0]['role']` --
  which is how a template asks whether a conversation already opens with a
  system message before adding one. It was the only construct standing
  between this engine and the templates modern models ship.

- A marker such as `<|im_start|>` is encoded as the token it is rather than
  the dozen its spelling merges into. A template writes markers into the text
  it renders, and a model shown their letters answers in letters: it ended its
  turn by spelling the marker out instead of stopping.

- Q4_1, Q5_0 and Q5_1 tensors are decoded rather than refused. Q4_1 is a
  nibble with a scale and a minimum instead of a fixed bias; the two five-bit
  formats hold each element's fifth bit in a thirty-two bit word beside the
  nibbles, centring by sixteen or carrying a minimum. Each was checked against
  a model quantized to it, and each matches the reference runtime's greedy
  output exactly.

  The five-bit pair costs about two and a half times what the four-bit ones
  do, because the fifth bit for element j is bit j of a word, so the shift
  varies with the element and the loop will not vectorize without a per-lane
  shift instruction. The README says so where the figures are.

  Q8_1 and Q8_K stay refused. Neither is a way weights are stored: both are
  intermediates ggml builds inside its own dot products.

- Q3_K tensors are decoded rather than refused, at 0.48 nanoseconds an
  element. Three bits in two pieces: the low two packed four to a byte, the
  third in a mask shared by the whole block whose absence subtracts four, and
  sixteen six-bit sub-block scales packed across twelve bytes. With this and
  Q2_K, a model quantized to Q2_K by the usual mixed recipe -- F32, Q2_K,
  Q3_K, Q4_K and Q6_K together -- loads and generates, and its greedy output
  matches the reference runtime exactly.

- Q2_K tensors are decoded rather than refused. Two bits an element, sixteen
  sub-blocks of sixteen, each with a four-bit scale and a four-bit minimum
  sharing one byte, and the two half-precision factors at the end rather than
  the start. It is the slowest format in the table at 0.72 nanoseconds an
  element, which is what carrying sixteen sub-blocks per 256 elements costs.
  Verified against a model requantized to pure Q2_K, whose greedy output
  matches the reference runtime exactly.

- BF16 tensors are decoded rather than refused. A brain float is the top half
  of a binary32 -- same sign, same eight exponent bits, mantissa cut to seven
  -- so widening one is a shift with no bias to undo and no case for infinity
  or not-a-number, and it is the only format here that cannot round. Verified
  against a 2.2 GB model requantized to BF16, which agrees with the reference
  runtime on tokens, greedy output and text.

- Byte-pair tokenization, for vocabularies declaring the `gpt2` model. The
  merge table is read from the file and applied by rank, every byte is
  rewritten as the printable character that stands for it, and the text is cut
  into pieces first so that no merge joins one word to the next. Checked
  against `llama.cpp` on its own tokenizer fixtures: gpt-2, qwen2, falcon and
  starcoder agree exactly on twenty-one strings, llama-bpe agrees on the
  tokens and differs only by the beginning-of-text marker it adds.

  Any script, not only ASCII: a letter is told from a symbol by its Unicode
  category, which the standard library knows, so a CJK ideograph cuts as a
  letter and a CJK comma does not. Twenty-seven strings across Latin,
  Cyrillic, Greek, CJK, emoji and punctuation agree with the reference.

  What is refused is a vocabulary naming a cutting rule this does not
  implement. The later rules let any single character that is neither letter
  nor digit lead a word, where the original lets only a space, so a tab
  between two words is three pieces under one rule and two under the other.
  Six rules are implemented and verified against the reference on
  fifty-six strings: `gpt-2`, `falcon`, `starcoder`, `smollm`, `llama3` and
  `qwen2`.
  They differ in what may lead a run -- a space under the first, any
  non-letter under the last two, nothing at all before digits there -- and in
  how digits group: without limit, in threes, or one at a time. A vocabulary
  naming a rule that is not among these is refused by name.

- `tests tokenize --model PATH --prompt TEXT` prints the identifiers a
  vocabulary produces, which is what makes this comparable with another
  implementation.

- Frequency and presence penalties, as `--frequency-penalty` and
  `--presence-penalty`. Both act on the same recent-token window as the
  repetition penalty and compose with it. Frequency is subtracted once for
  every occurrence of a token in the window, presence once for a token that
  occurs at all; a negative value is accepted and encourages repetition, and a
  magnitude large enough to make every logit in the window infinite is
  refused. Neither applies to greedy selection, which no penalty does.

- A benchmark for the vector kernels each token passes through -- softmax,
  normalization, the activation and the plain dot product -- which nothing had
  been measuring, and one for how the matrix product scales across shares,
  counted against its own serial rate.

- Benchmark rows for decoding f16 and q4_k without a dot product on top.
  Separating decode from the product is what located the half-precision
  defect below; the row product hid it.

- `Model_Runner.Platform.Core_Count`, and a body per host behind it, so the
  worker default can follow cores rather than processors. Linux reads the
  topology the kernel publishes and macOS asks sysctl; a host that cannot say
  returns the processor count rather than guessing.

- A reference recording for a Q4_K_M model, which carries Q4_K, Q6_K and F32
  tensors together and is read per tensor. Every recording before it was of a
  file whose tensors were all one type.

- A sweep over all 65 536 half-precision bit patterns, compared against the
  format's definition computed in binary64 rather than against another bit
  trick.

- Element-wise reference decoders for BF16, Q4_1, Q5_0, Q5_1, Q2_K and Q3_K,
  comparing every element of a block of arbitrary bytes against a reading that
  starts from the element rather than walking the block. The hand-built blocks
  those formats also carry are worth less than they look: the three-bit one
  passed four wrong decoders before its values were chosen so that a wrong
  answer differs from a right one.

- Element-wise reference decoders for the four-bit, five-bit and six-bit block
  formats, comparing all 256 elements of a block of arbitrary bytes against a
  reading that starts from an element index and asks where its bits are.

- A test that a malformed request is refused by the range procedures rather
  than raising, which is what makes the failure handlers in the pool a net and
  not a path.

- The render step bound is a field in the model limits rather than a constant
  in the engine, so a caller rendering untrusted templates can tighten it.

- Release checks that no source in another language and no machine code enters
  the repository, and a test that `--backend` is refused rather than ignored.

- The fuzzing campaign reports how many mutated files prepared a model and ran
  a forward pass, and fails if none did.

- The container fuzzer now renders every accepted container the way `inspect`
  does and requires that nothing a terminal would act on comes back, and it
  writes control bytes into the image on purpose so that the case arises.

- A differential test for UTF-8 validation: every string of up to three bytes,
  compared against the standard's table of well-formed sequences written out
  separately.

- A release check that nothing in the repository is large enough to be a model.

- A release check that no unit interpreting a model's contents can reach a
  file, a stream, a directory, the environment or the command line.

- A release check that the environment surface is the one the README lists,
  and that only two files read it at all.

- A benchmark for parsing a metadata-heavy container, alongside the row
  kernels. Loading is the first thing a run spends time on and nothing was
  measuring it. Reported as a cost against a memory copy timed in the same
  round, so that one run on one machine can be compared with another.

- A differential test for stop-string matching: the earliest-then-longest rule
  written out the slow, obvious way in the test and compared against the
  engine's single-pass matcher over generated sets and buffers.


- A property test over the chat-template engine: two thousand generated
  templates, built balanced so that most compile, one in four then broken, and
  rendered against conversations of varying shape into buffers small enough to
  overrun. It holds that neither compiling nor rendering raises, and that a
  failed render reports writing nothing.


- A property test over the command-line parser: four thousand generated
  argument vectors, each derived from its case number so a failure replays,
  asserting only what the parser owes every caller -- that it returns with a
  definite outcome and does not raise. The hand-written cases check which
  outcome; this checks that there is one for vectors nobody thought to write.


- Tests for the chat template engine's bounds: template size, instruction
  count, nesting depth at and past the documented limit, output size at and
  past the buffer, and the iteration bound. The engine already refused
  malformed and unsupported templates, and a test covered that; what none
  covered was the five numeric bounds, and the refusal codes were checked
  only for being errors rather than for being the documented ones.

- Checked 64-bit arithmetic with overflow propagation.
- UTF-8 validation and boundary-safe incremental prefix length.
- Structured errors: 14 domains, stable `MR-DOMAIN-NNNN` codes derived
  mechanically from the code enumeration, typed parameters, and centralized
  exit-status mapping.
- Explicit model and session resource limits.
- Random-access byte sources: in-memory, file-backed, and POSIX read-only
  memory mapping with automatic, required and disabled policies.
- GGUF container parsing and structural validation for versions 2 and 3.
- Typed metadata accessors separating missing, mistyped and out-of-range keys.
- Read-only tensor views with one documented dimension convention.
- Reference decoders for F32, F16, Q4_0, Q8_0, Q4_K, Q5_K and Q6_K.
- Scalar reference kernels with documented accumulation formats.
- SentencePiece tokenizer with byte fallback and an incremental decoder.
- Llama-compatible architecture validation, tensor resolution and preparation.
- Transactional KV cache, session state machine and single-token forward pass.
- Memory accounting and overflow-safe model and session plans.
- AUnit suites for the GGUF container and for inference, all offline.

- Sampling pipeline: greedy, temperature, top-k, top-p, minimum-p, repetition
  penalty, forbidden-token masks, and a session-local xoshiro256++ generator.
- Stop tokens and stop strings, matched across token boundaries with
  earliest-then-longest resolution.
- Bounded allowlisted chat-template engine, compiled and validated at load time.
- Structured conversation history with system-message replacement and turn
  rollback.
- Generation coordinator: prefill, decode loop, streaming to an output sink,
  eight completion reasons, statistics against a monotonic clock, committed
  prefix reuse.
- Commands `run`, `inspect`, `help` and `version`, with typed parsing separated
  from execution.
- Interactive conversation with committed history, per-turn template rendering,
  cache-prefix verification and the stable `/` command set.
- Localization through `messages`, with a catalog entry for all 174 diagnostic
  codes and an emergency path that cannot recurse.
- Terminal presentation through `terminal_styles`, confined to the presentation
  layer, with per-destination automatic styling.
- A deterministic offline test suite and a `tests fixtures` command.

- CPU backend with an Ada worker pool: protected coordinator, reusable worker
  tasks, deterministic partitioning, bounded queue, failure propagation and
  clean shutdown, selected with `--threads`.
- `tests fuzz`, a reproducible GGUF mutation campaign.
- `tests check`: repository, dependency-boundary and layering checks.
- `tests docs`, generating `docs/error-codes.md` from the error registry.
- Interrupt-driven cancellation: SIGINT requests a clean cancellation instead of
  terminating the process mid-token.
- A partial Danish locale and a generated pseudo-locale, with per-key fallback.
- `Reference_Transformer`, an independent implementation of the forward pass in
  the tests crate, and `tests conformance` comparing the engine against it.
- `tests external-model`, validating a user-supplied model without downloading
  anything; a missing file is a skip.
- A recording format for values produced by a trusted reference runtime, with
  required provenance, and `--expect` to compare against it.

- `tests benchmark` measures the row kernels on synthetic tensors, with no
  model file and no network. It was written because reading the code produced
  two confident wrong answers about where the time went.

- `tests package` assembles the distributable archive: the executable, the
  message catalog it looks for beside itself, and the documents that say what
  the program is and what it does not do. The layout inside is the layout
  `alr install` writes, so unpacking it over a prefix gives a working
  installation -- verified by unpacking and running it from the filesystem
  root, where it resolves its catalog and renders Danish.
- The archive sets the executable's mode rather than taking tarlib's default,
  which is 0644 for every regular file. An archive whose program unpacks
  without the execute bit is not a distribution, and that failure would appear
  on someone else's machine rather than here.
- It refuses rather than guesses: every input is checked before anything is
  written, so a missing file names itself and leaves no half-made archive.
  Nothing is built and nothing is fetched.
- `inspect --metadata` shows each entry's type and value, not just its key.
  Strings are escaped and shortened on a code-point boundary, with an explicit
  mark, so a prefix is never mistaken for the whole and no invalid UTF-8
  reaches the terminal. Arrays are described rather than dumped: a tokenizer
  vocabulary is a metadata array of tens of thousands of strings, and nobody
  asking to see the metadata asked for that.
- Windows memory mapping, over CreateFileMapping and MapViewOfFile. The
  platform-specific bodies now sit one per host under `src/platform`, chosen by
  the project file the way hostkit chooses its own, with a body for hosts
  covered by neither that reports mapping unavailable rather than pretending.
  Read-only throughout: the file is opened for reading, shared for reading and
  mapped for reading, so the model cannot be modified through it.
- `hostkit` is a dependency, for the things that exist only because operating
  systems differ. `Platform.Host_Name` asks it which host this is, and
  `Executable_Directory` asks it where the running program is rather than
  reading `/proc/self/exe` directly -- that is Linux and not even macOS, so on
  every other host the installed layout could not be found and the catalog
  silently fell back. `Hostkit.Host.Executable_Path` was added upstream for
  this.

- Memory accounting and the monotonic clock had no tests at all. Seven now
  cover them: an allocation past the budget refused before any allocator runs,
  totals following allocation and release, a peak that does not fall when
  memory is freed and reallocated, mapped bytes counted apart from allocated
  ones, a plan that cannot be represented refused rather than wrapped, a plan
  totalling what will actually be resident, a clock that goes backwards
  yielding no duration, and a rate over no elapsed time reading zero rather
  than infinite.
- `tests conformance` runs on quantized weights as well as binary32: eight
  sequences and 128 logits rather than four and 64. Nothing offline had
  compared quantized inference against an independent implementation before;
  the only check on it was two tokens recorded from another runtime, against a
  model that is not committed. `Reference_Transformer` gained its own Q8_0
  decoder, working the half-precision scale out from its sign, exponent and
  mantissa rather than reusing the engine's conversion, so a fault there cannot
  hide by being made twice. Shifting the engine's Q8_0 decode by one element
  puts 64 logits outside tolerance.
- `Fixtures.Encode_Q8_0` quantizes to blocks the way the format's producers do,
  and the fixture widens to thirty-two and sixty-four when quantized, because a
  quantized row is a whole number of thirty-two element blocks and the narrow
  model cannot hold one.

### Performance

- Q4_0 decodes 1.79 times faster, and is now the fastest format rather than
  the slowest: 0.31 nanoseconds an element against 0.57. It was the one format
  whose multiply was folded into its decode, which measured faster when it was
  written and measures slower now that the loop it competes with has been
  improved. The fused path is removed rather than switched off, so every
  format takes one route.

- Brain floats decode 3.9 times faster than they first did, at 0.32
  nanoseconds an element, which puts them second in the table. Decoding one is
  a shift and a reinterpretation, and the reinterpretation was a call across a
  unit boundary until it was inlined.

- Six-bit blocks decode about four times faster. The inner loop produced four
  elements per iteration and wrote them thirty-two apart; split into four runs
  that each read sixteen adjacent bytes and write sixteen adjacent elements,
  the same arithmetic runs against contiguous memory.

- Half precision decodes about 2.6 times faster, and the row product about the
  same. The conversion was being called once per element across a unit
  boundary; it is inlined now, and computes without branching.

- Softmax is about a third faster. Its finiteness test was a call per element
  for the same reason.

- A binary32 weight is read as a binary32 where the byte order and alignment
  allow it, rather than assembled a byte at a time.

- The task that submits a matrix product takes a share of it instead of
  waiting for the workers. With one worker per core the waiting task was one
  more runnable task than there were cores, and a job is not finished until
  its slowest share is. Pinned to one processor per core, eight shares went
  from 9326 to 14132 Me/s; unpinned and end to end it is about six per cent.

All figures are from the release build, on a Ryzen 7 7840U, against
TinyLlama-1.1B-Chat Q8_0. Generating twelve tokens with 14 threads takes 2.18 s
wall and 16.0 s of processor time.

- **No build profile reached the compiler.** Both project files set
  `Compiler.Default_Switches` without including the switches from the generated
  configuration project, which silently discards them: every profile compiled
  at `-O0`, and `--release` changed nothing. Every sibling crate includes them;
  model_runner was the one that did not. Fixing it took twelve tokens from
  14.0 s to 2.18 s, and means any measurement taken before the fix compared
  unoptimized builds against each other.
- `[build-profiles] "*" = "development"` stays, as in every sibling: one
  profile across every root so they share object files, and `-Og` with full
  validity checks is what development should build. Release is for a release.
- `tests.gpr` did not reference its own configuration project at all, and used
  one object directory for every profile, so objects built at one optimization
  level could be linked into a binary built at another. Both fixed.
- Batched prefill. A prompt is evaluated in batches rather than one token at a
  time, so every token in a batch shares one pass over the weights.
  `--batch-size` selects it and the engine caps it at 128 tokens. On a
  131-token prompt with 14 threads, prompt evaluation went from 12.91 s at a
  batch of one to 6.58 s at a batch of 128.
- A batch is exact, not an approximation: each token produces the same bits it
  produces alone, and leaves the same key-value cache. `Mat_Vec_Range` is the
  batched kernel with one input vector, so the two cannot drift apart. One test
  asserts the equality end to end, on the logits and on the cache; another
  asserts it at the kernel level for every quantization format, because the
  synthetic fixture is entirely F32 and could not have caught a divergence in a
  quantized one.
- The kernels are vectorized by the compiler, from ordinary Ada. Nothing is
  written in assembly, in intrinsics or in a foreign language. What unlocked it
  was removing Ada's per-element runtime checks from the innermost unpacking
  and accumulation loops: each check is a call the optimizer must treat as
  touching memory, so it cannot prove the iterations independent, and nothing
  vectorized with them in place. The ranges are validated once per span
  instead, and `Accumulate_Dot` now checks its input vectors itself rather than
  relying on its callers, which it did not do before. The trade is documented
  in SECURITY.md.
- Results are bit-identical. The four accumulator chains are independent, so
  the compiler packs them into vectors without reassociating anything:
  conformance against the independent reference implementation is unchanged to
  the last digit, and generated text is byte-identical.
- No target-specific flags are used. `-march=native` was measured on a machine
  with AVX-512 and made no difference: these loops are limited by the
  single-to-double conversions, not by vector width.
- The multiply is folded into the decode for Q4_0, whose value is a block scale
  times a small integer, so a block's contribution is the scale times the sum
  of integer times input. Applied per format on measurement, not on principle:
  it lost for Q8_0, whose element is already a byte, and for F32, which has no
  scale to fold. `Quantization.Fused_Formats` reports which formats take which
  path, and a test checks the fused kernel against the reference decoder for
  every format.
- Quantized weights are decoded a span of blocks at a time instead of a block
  at a time, with the format decided once per span. A Q8_0 block is thirty-two
  elements, so the per-block decision, its bounds check and the call around it
  cost more than the arithmetic they guarded; F32, whose block is a single
  element, paid that cost for every float.
- The row dot product keeps four running sums rather than one, so products no
  longer wait on the previous addition to retire. They are combined in a fixed
  order, so results stay reproducible.
- `Decode_Block` no longer zeroes its whole 256-element buffer on every call.
- The k-quant decoders were six times slower per element than the formats
  unpacked inline. A sub-block's scale and offset are now formed once rather
  than once per element -- they were four multiplies and four conversions per
  element that never changed within the sub-block -- packed bytes are read
  directly instead of through a call, and the per-element checks are suppressed
  after the block is bounds-checked at entry. Q4_K went from 6.68 ns to 1.12 ns
  per element; Q5_K and Q6_K have the same three changes.
- The k-quant path also decoded into a scratch block and copied 256 elements
  out of it. It decodes into the destination now, though measurement showed
  the copy was not what made it slow.
- Q6_K formed its four sub-block scales for every element rather than once per
  half, and Signed read each byte three times to decide its sign. Both fixed:
  Q6_K went from 2.24 ns to 1.37 ns per element, and every caller of Signed
  gained from the second.
- Row dot per element, release build, every supported format: Q4_0 0.91 ns,
  Q8_0 1.02, Q4_K 1.11, Q5_K 1.35, Q6_K 1.37, F32 1.59, F16 1.79. The
  benchmark now measures all seven rather than four, which is how the k-quant
  gap was found in the first place. These replace lower figures published earlier, which were
  measured on tensors filled with arbitrary bytes: read as half precision those
  are frequently denormal, infinite or not-a-number, which no real model
  contains. The benchmark now forces every block scale to a normal exponent,
  and the corrected numbers agree with the end-to-end timing where the earlier
  ones did not.

### Changed

- Q4_0 rounds each weight to single precision on the way past, as every other
  format already did. Folding its scale into the sum avoided that rounding and
  is no longer worth what it costs. Results for Q4_0 models change in the last
  bits.

- The default worker count follows the number of cores rather than the number
  of processors, and asks for one fewer than that because the submitting task
  takes the last share. On an eight-core machine reporting sixteen
  processors, twelve tokens took the same wall time for 14.6 s of processor
  time instead of 27.4 s. `--threads` overrides it as before.

- A test replays the transcripts the README publishes and compares them with
  what the program prints: the inspection of the committed fixture, the two
  locale examples, which are held to showing every line the program wrote and
  not merely lines it wrote, and the three external-model runs, whose wrapped
  summaries are joined and required back exactly.

- The external-model summary line is formatted in one place, `Summary`, rather
  than at the point it is printed, so that the published copy of it cannot
  agree with a second copy while disagreeing with the runner.

- `tests check` fails when the sources behind a published performance figure
  change without the figure being measured again. The figures cannot be
  checked by value -- they move between runs and further between machines --
  so what is checked is a fingerprint of the sources each group depends on,
  recorded in `docs/measured-figures.txt`.

- `tests conformance` checks that the README still quotes the numbers it
  prints, and fails the release checklist when it does not. The counts there
  had drifted to 4 and 64 while the run had grown to 8 and 128, and the worst
  divergence was published six times smaller than it had become.

- The speed figures in the README are quoted at the worker count the program
  chooses rather than at fourteen threads, which is more than this machine can
  use and is no longer what it picks. The batch-size sweep is re-measured at
  that setting and its prompt is committed, so the table can be reproduced
  rather than believed.

- Kernel figures in the README are re-measured and were between two and four
  times too slow. The support matrix names the README as their only home,
  which makes keeping them current a duty rather than a courtesy.

- Both the README and the support matrix said `-march=native` measured no
  difference. It measures 37 per cent slower for the f32 row product and 14
  per cent for Q8_0. The conclusion drawn from it was right; the reason given
  was not.

- The benchmark says what its numbers are worth: comparable within one sitting
  and not across two, since the same binary has reported 785 and 598 Me/s for
  one kernel hours apart.

- Paths are built through `hostkit` rather than by concatenating a separator
  here, and the directory holding the executable is asked of it rather than
  derived from the executable's path. What goes between two path segments is
  the host's business: Windows writes a backslash and accepts both, so a path
  built with the wrong one works through every file call and shows itself only
  when someone reads it.


- Terminal detection is asked of `hostkit` rather than by importing `isatty`
  here. That C name is spelled `_isatty` on Windows, where the console is
  asked about through `GetConsoleMode` instead, so the import was a POSIX
  assumption that looked portable. `hostkit` keeps one body per host and this
  crate keeps none for it.


- `docs/error-codes.md` marks every code raised or reserved. Thirty-six of the
  148 are declared, carry a message in every locale and are raised nowhere;
  read as a reference the document promised diagnostics the program cannot
  emit. The list lives in one place, the repository checks verify it against
  the sources, and the document renders it, so the three cannot disagree.

- `tests fuzz` now drives the whole load path rather than stopping at the
  parser: a mutated container goes through the parser, the tokenizer, the
  chat-template compiler and model preparation. The campaign's own contract
  names an invalid model reaching an executable state as a failure, and
  preparation is the gate that decides it, so the campaign stopped short of the
  thing it said it checked. The template compiler had never been driven by a
  mutated template at all, which is the most program-like thing a model file
  carries. A case now costs about ten times what it did; the case count is the
  knob.

- A fuzz case that runs past five seconds is reported and fails the run. The
  contract already said a wall-clock bound caught a loop that failed to
  terminate, and there was no clock anywhere in the fuzzer. A stage that never
  returns at all still cannot be interrupted from the single task a run uses,
  and the contract now says so instead of claiming otherwise.

- Architecture metadata that is present and wrong now stops preparation
  instead of falling back to a default. `attention.head_count_kv`,
  `rope.dimension_count`, `rope.freq_base`, `rope.scaling.factor`,
  `attention.layer_norm_rms_epsilon` and the key and value widths are all
  optional, and an absent one still takes the default -- not every model states
  its rotary width. One that is present and names a value the profile cannot
  use built a model of a different shape than the file described and said
  nothing about it. The key and value widths mattered most: an unreadable one
  skipped the asymmetric-width comparison, which is the check that exists to
  catch exactly that file.

- A tokenizer special-token identifier that is present but names no token now
  refuses the model instead of being ignored, as does a present-but-mistyped
  `add_bos_token` or `add_eos_token`. A missing key still leaves the identifier
  unset, because not every model declares every special token, and `-1` is
  accepted as an explicit absence. Previously all three cases were treated
  alike, so a file declaring token 999999 tokenized as though it had declared
  nothing: the prompt the model saw changed and nothing said so. The container
  accessors have always separated missing from mistyped from out-of-range; the
  tokenizer was discarding that distinction.

### Fixed

- A beginning-of-text marker is added only when the vocabulary asks for one,
  and a mandatory test holds it: two fixtures differing in that one
  declaration, the same prompt through the command line, and the token counts
  must differ by exactly one.
  A request could ask for one and get it regardless, so every model declaring
  that it wants none was fed a sequence no other implementation would produce.
  On such a model it moved a logit by nearly two -- against the hundredths
  that separate two honest implementations -- and ended generation after two
  tokens where the reference ran on. With it fixed the two agree token for
  token.

- Byte-pair output is decoded back to bytes. A vocabulary of that kind writes
  its token text in stand-in characters, one per byte, and the decoder was
  passing them through, so a model's output arrived as those stand-ins -- a
  space reading as the character that stands for one. Encoding, generation and
  the tokens themselves were right; only the way back was wrong, and no
  vocabulary-only fixture could show it because none of them generate.

- A container with no tensors is read rather than refused as truncated. Such a
  file ends at its metadata, and the reader required room for the padding that
  would precede a data section which is not there. Every vocabulary-only
  container was rejected, which is every file a tokenizer would be tested
  against.

- A truncated model file says what is wrong instead of printing the name of
  the message that would have said it. The message reads "ends inside a field
  at offset {offset}" and the reader recorded the offset as technical context
  rather than as a value the message could name, so the catalog could not
  render it and fell back to `<error.gguf.truncated>`. That is the commonest
  way a model file is wrong.

- The external-model runner reports the code a refused generation was refused
  with, instead of "generation failed" and nothing else. The README published
  an invocation of it that cannot succeed -- the committed fixture holds
  sixteen tokens of context and the runner asks for sixteen by default -- and
  the message said nothing worth chasing, so nobody chased it. The example is
  corrected and a test holds the reporting.

- `Model_Runner.CLI` described the command-line interface, the sampler, the
  generation coordinator, the template engine and the presentation layer as
  not implemented. All of them work. The rule against describing planned work
  as finished cuts both ways.

- The processor-time figure published for a twelve-token run was wrong when it
  was written. Building the commit that published it and running it again
  gives the same number this build gives, so nothing had regressed.

- The rest of the metadata parsing slowdown is gone. A run within the copy
  bound is read into a buffer and placed, and a string's encoding is checked
  from that buffer rather than from the pool.

- A container declaring a length or count above `Long_Long_Integer'Last` was
  refused correctly and then raised while saying so, because the diagnostic
  carried the number as a signed value. The value saturates now.

- Reading a float a file supplied no longer raises under validity checking in
  the development build. A not-a-number is possible input, and the finiteness
  guards are what refuse it; the checks fired first and reported the program
  as having a defect in itself.

- A chat template with a second `else`, or an `elif` after an `else`, crashed
  the compiler into an internal invariant violation instead of being refused.
  Both close a branch that has already been closed, and the code that patches
  the pending jump indexed instruction zero.

- Compiling a chat template no longer allocates twenty-six megabytes. An
  instruction named its operand and condition rather than carrying them, so a
  compiled program is about a hundred kilobytes and the tables holding the
  rest are as long as the template needs.

- Most of the metadata parsing slowdown introduced with the truncation fix is
  gone: a run within the copy bound is read into a buffer and placed, rather
  than written through a slice of the pool.

- Message text from the catalog is escaped before it is returned. Values
  substituted into a message were escaped because they come from a model file;
  the message itself was not, so a replaced catalog could send an escape
  sequence to the terminal.

- The environment table in the README now lists `LC_ALL` and `LANG`, which the
  program reads to choose a locale and which it did not mention.

- A container no longer sizes storage from a length it has not read. A file
  could declare a metadata array of four million elements, or a string of
  eight megabytes, and the reader would create storage of that size before
  reading a single byte of it -- so a file of a hundred bytes was enough to
  exhaust the stack. The failure surfaced as an internal invariant violation,
  which is the diagnostic reserved for a defect in the program rather than a
  fault in the file, and it was accurate: this was one. Runs of both kinds are
  now checked against the end of the file first and copied in fixed-size
  pieces, and such a file is refused as truncated.

- Long metadata strings are now checked for well-formed UTF-8 a window at a
  time rather than as one object, since the string limit allows sixteen
  megabytes. A code point lying across a window edge is judged whole.

- A byte source no longer zeroes the caller's buffer before filling it, only
  on the paths that return without filling it. Zeroing first writes every byte
  twice, which a caller reading straight into a large buffer pays for the
  whole of it.

- The host locale is asked of `hostkit` when the environment does not answer.
  Reading only `LC_ALL` and `LANG` is a POSIX convention: neither is set on
  Windows, so a Windows user's own locale was never looked for and the program
  always fell through to English. The environment still wins where it is set,
  because a variable somebody set is a statement about what they want.


- Sampling raised instead of reporting when the transformations it applies
  overflowed. The logits are checked for being finite when they arrive, but a
  large finite logit divided by a small temperature, or multiplied by a
  repetition penalty below one, produces a value that is not finite, and
  storing it trapped. It is now reported as a non-finite logit, which is what
  the same condition on arrival has always been. Found by a property test over
  generated configurations, on its first run.


- A directory given to `--prompt-file` was reported as unreadable rather than
  as not a file, which sends the reader to inspect a file that is not the
  problem. The model file reader has always made that distinction; the prompt
  file reader now does too.

- Three more diagnostics that were declared and never produced now are. A
  tokenizer score or token-type table that is present but does not match the
  vocabulary is refused rather than silently dropped -- scores decide which
  merge wins, so a short table tokenized the same text differently and said
  nothing. A chat template using a filter is reported as using a filter
  instead of as an unsupported expression. And a `MODEL_RUNNER_COLOR` set to
  something the program has no name for is refused, as `--color=bogus` always
  was: the same value should not be an error on the command line and ignored
  in the environment.

- `--interactive` no longer starts a session without a terminal to hold it.
  Interactive mode chosen implicitly, when no prompt source was given, was
  already conditional on standard input and standard output both being
  terminals; asked for by name it was not checked at all, so a redirected
  session drew prompts nobody saw and consumed a file as though someone were
  typing it. It now reports `MR-CLI-0019`, which was declared and catalogued
  from the start with nothing producing it.

- An option that takes no value accepted one and dropped it. `--verbose=5`,
  `--raw=yes` and eleven others parsed as though the value had not been
  written, so a mistake in a command line was silently ignored rather than
  reported. All thirteen now refuse, under `MR-CLI-0005`, which was declared
  and catalogued from the start with nothing producing it.

- A verbose run printed its last progress line twice: the last token produced
  and the end of generation carried identical wording, so the reader saw a
  stutter rather than two things happening. The completion line now says so.

- A verbose run with more than one worker hung, about two runs in three. The
  seed is an unsigned 64-bit value and the whole range is generated, but the
  statistics converted it to a signed type to print it, which raises for every
  seed above `Long_Long_Integer'Last`. With one worker the run ended as an
  internal failure; with several, the exception left the block holding the
  worker pool before the workers had been told to stop, and leaving that block
  waits for them to terminate, so the program stopped responding instead of
  reporting anything. Measured at thirteen hangs in twenty runs before the fix
  and none in twenty-five after.

  Three things were wrong and all three are fixed: the seed is formatted
  through a new unsigned image, the pool is closed before an exception leaves
  its block so a failure is reported rather than hung, and `--seed` now parses
  the whole unsigned range. That last one was its own defect: a run whose seed
  came from the upper half of the range could not be reproduced, which is what
  the option is for. Interactive mode's `/settings` had the same conversion.

- A prompt read from standard input was read without a bound. Input that was
  one very long line was placed on the stack in a single piece, and the
  resulting `Storage_Error` was reported as `MR-IO-0002`, a failure to read;
  the same volume of text as short lines ended as `MR-INTERNAL-0002`, an
  internal failure. Neither said that the prompt was simply too large. The
  reader now fills a bounded buffer, refuses input past the limit rather than
  shortening it silently, and reports the new `MR-IO-0009`. Standard input is
  the one prompt source whose size is not known in advance, and it was the one
  that did not check.

- Diagnostics about standard input rendered as bare message keys, such as
  `<error.io.read_failed>`, telling the reader nothing. The messages are
  written for files and ask for a path, standard input has none, and a message
  whose argument is missing falls back to naming itself. Those diagnostics now
  pass the localized name for standard input and read as sentences.

- Prompt reading and diagnostics now use the current input and current error
  files rather than the standard ones. They are the same files unless a
  program redirects them, which this one does not, so behaviour is unchanged;
  it is what allows a test to supply input and read back the diagnostic.

- `Finalize_Plan` said it summed a plan's components. It does not, and should
  not: file-backed bytes are excluded because a mapped model lives in the
  operating system's pages, and a safety margin is added on top. Writing the
  test against the documented behaviour is what surfaced the difference; the
  specification now describes what the code does and why.

- The quantized decoders had no test of the values they produce. Every other
  check compared them against themselves -- the fused kernel against the
  decoder it mirrors, one batch width against another -- and for the k-quant
  formats the fused path is the decoder, so that check said nothing at all
  about them. Conformance runs on an F32 model. Three of these decoders had
  just been rewritten. Golden vectors now check each format against
  expectations derived by hand from its documented layout; planting a wrong
  bias in Q6_K or Q4_0 fails them.
- Four formats had two implementations, and only one was reachable. An error
  injected into the unused copy of Q4_0 changed nothing and no test noticed.
  Decode_Block is now Decode_Blocks with a count of one, so there is a single
  implementation per format, as the package always claimed.

- `Numerics.To_Real` and the tensor kernels raised on a not-a-number instead of
  producing one. Half precision has infinities and not-a-numbers, a model file
  may carry either as a block scale, and reporting that is what `Is_Finite` and
  `All_Finite` are for -- but validity checking fires on the value before any
  caller can look at it. Suppressed where such a value is inspected, as in the
  sampler; bounds and range checking are untouched.

- `Backend.CPU.Partition` underflowed the unsigned element count when a worker
  had no rows, which the partition-coverage test found.
- Generated text acquired a trailing newline from `Ada.Text_IO` closing a
  partially written line; it is now written through the raw stream.
- The chat-template renderer and the command layer declared render buffers the
  size of the configured limit on the stack.
- The generation coordinator sized its token buffer to the context rather than
  to the prompt, reporting "buffer too small" instead of "prompt too long".
- `Localization.Open` discarded the requested locale when a single probe key was
  missing, which would have made every partial translation useless.
- Field padding counted bytes rather than characters, misaligning every label
  containing a non-ASCII character.
- A worker pool that was created but never used never terminated, hanging any
  command that failed before its first matrix product.
- Automatic seeding raised on every run that did not pass `--seed`. The host
  source measured the span from the real-time epoch as a `Duration` in its
  declarative part; that conversion overflows on this platform, and a value
  computed in a declarative part propagates past the subprogram's own handler,
  so a contained failure became an internal error. Every test pinned a seed for
  determinism, which is exactly why nothing covered the default path.
- The first generated token lost its leading space: the decoder treated it as a
  SentencePiece dummy prefix, which it is only when decoding a sequence from its
  beginning. Continuing after a prompt, that space is text the model produced,
  and deleting it made prompt and continuation run together. Found by comparing
  against a reference runtime.
- Reading a prompt file of more than about two megabytes reported that the file
  could not be read, when the file was fine and the copy onto the stack was not.
  The documented sixteen-megabyte limit is now actually usable, and exhausting
  memory is no longer reported as an I/O failure.
- `Tokenizer.Encode` built its working text on the stack at three times the
  length of the input, and leaked the symbol array when it failed. Oversized
  input is now rejected on its code point count before anything is allocated.

### Not yet implemented

The release checklist is implemented, as `tools/bin/check_all`, following the
sibling crates: it drives the repository, dependency and layering checks, the
test suite, the conformance run and a 2000-case fuzzing campaign, and fails on
any non-empty stderr log in a build tree.

Quantized weights are decoded into a buffer and then multiplied; the multiply
is not fused into the decode, there is no repacking, and there is no
hand-written vector code. That is the largest remaining difference against a
runtime built around the machine's vector instructions.

The comparison against a reference runtime has now been performed: `llama.cpp`
`b1-717dad5` against TinyLlama-1.1B-Chat-v1.0 Q8_0, matching on tokenization,
greedy token identifiers and generated text. See
[docs/reference-runtime.md](docs/reference-runtime.md).
