# Changelog

All notable changes to model_runner are recorded here. The format follows
Keep a Changelog and the project uses semantic versioning.

## [Unreleased]

### Changed

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
