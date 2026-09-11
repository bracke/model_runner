# Closing the mixture's gap to llama.cpp

Where this program stands against llama.cpp `95b8e33e1` on this host
(Ryzen 7 7840U, Radeon 780M, 30 GB), measured 2026-09-11:

| | this program | llama.cpp | behind |
| --- | ---: | ---: | ---: |
| TinyLlama Q8_0, processor, 1419 prompt | 313 t/s | 298 | ahead |
| TinyLlama Q8_0, device, 1419 prompt | 1960 | 1890 | ahead |
| TinyLlama Q8_0, generating, either | | | 1.02–1.07 |
| Qwen3-30B-A3B Q2_K, processor, 110 prompt | 71 | 108 | 1.5 |
| Qwen3-30B-A3B Q2_K, processor, 1419 prompt | 69 | 250 | **3.6** |
| Qwen3-30B-A3B Q2_K, device, generating, empty context | 22 | 34 | 1.55 |
| Qwen3-30B-A3B Q2_K, device, generating, 1302 context | 18 | — | — |

The dense engine is level. The mixture is a week old and its gap is three
mechanisms, each measured; four other explanations were built or priced
and refused (dispatch count, residency, the pool's wake, submissions --
see `docs/measured-figures.txt`, 2026-09-10 and -11). This plan is those
three, in the order of what they are worth, with a tooling step first
because two of the four refusals came from prices reasoned rather than
measured.

Every step is done the way the log does it: a hypothesis stated with the
number it predicts, built, alternated against the binary before it, kept
or refused by the reading, and written down either way.

## 0. Instruments first (a day)

Two measurements this plan needs and the repository cannot take today.

**A device timeline.** `Products.Run` records a sequence and the only
clock is the fence at its end. `VK_QUERY_TYPE_TIMESTAMP` written after each
dispatch into a query pool, read back with the results, would give the cost
of every step of a layer -- and would have priced the dispatches, the
route kernel and attention in an hour where the entries of 2026-09-11
spent a day on ablations. Build: a query pool of `Sequence_Limit` stamps
per slot, a `--device-timeline` on `tests speed` that prints a layer's
steps in microseconds, and one measured-figures entry that says what a
Qwen3-30B-A3B layer costs step by step. That entry is the first real map
of the device's token and decides the order of 2 and 3 below.

**Expert-shaped products in `tests benchmark`.** The kernels group measures
row products at 5632 by 2048. Add 768 by 2048 and 2048 by 768 at 1, 8, 32
and 80 vectors, in Q2_K, Q3_K and Q4_K, panelled -- the shapes a mixture's
expert is -- and report nanoseconds an element beside the dense shape's.
The number that matters: whether the cost an element rises at 768 rows,
and whether it falls from 8 to 80 vectors. Today it is known only that the
whole prompt reads 2.3e11 multiply-adds a second at seven members an
expert and at eighty, against 4.8e11 dense.

## 1. A cheaper multiply-add in the strip kernel (the 3.6, one to two weeks)

**Revised 2026-09-11 by the instrument in step 0.** The cost an element on
the pool is the same at 768 rows as at 5632 and flat from eight vectors to
eighty, at 5.3e11 multiply-adds a second -- the dense prompt's rate. So
there is no per-call cost to amortize and no decode a wider tile would
save; the kernel is at its arithmetic's rate. llama.cpp reaches 8e11 and
more from the same instructions' peak by spending fewer of them a
multiply-add. The log measured the strip at thirty-nine instructions for
two hundred and fifty-six where the byte dot product's floor is eight; the
work is that ratio -- the `zmm` form of the byte dot product with two rows
to a register, which lost for Q8_0 on the scale broadcast and was never
tried on the k-quants, and the shuffles that assemble a k-quant's nibbles
into dot-product operands. The section as first written follows; its
mechanism is refuted and its measure stands.


**The mechanism.** The strip kernels read a panel's weights once for eight
vectors and again for the next eight; llama.cpp's `mul_mat_id` feeds an
expert's gathered tokens to a GEMM that decodes a weight once for a
register tile of sixteen to thirty-two of them. Their cost a weight-token
falls with the members an expert has; ours is flat. At 5632 rows and 110
tokens the two are level; at 768 rows and eighty members they are not.

**Hypothesis to state before building:** a kernel that carries N vectors
per weight decode, N in 16..32, brings the mixture's 1419-token prompt
from 69 t/s to within 1.5 of llama.cpp's 250 -- because the prompt's
arithmetic is 2.3e11 a second now and a dense prompt reaches 4.8e11 on
the same cores, and because llama.cpp's own curve says the rest is tile
width.

**Where it goes.** `Model_Runner.Quantization.Integers.Deep` (the
`rows_by_panels_*` kernels, `run_one` / `run_wide`) gains a `run_tile`
that takes a run of the packed activation sixteen or thirty-two vectors
long. The byte dot product (`vpdpbusd`) with the weight broadcast and the
activation streamed is the shape the log already measured as the right
one; what changes is the loop nest -- weights outermost, vectors inner,
accumulators a `zmm` per (row of the panel, four vectors). Register
budget decides N: eight rows by sixteen vectors is thirty-two
accumulators, which is the whole file, so the first cut is eight by
eight with the activation tile kept in L1, and the measurement says
whether wider pays. `Multiply_Packed` (2026-09-11) already hands an
expert its members as one packed run, so the caller does not change.

**Measure:** the benchmark shapes from step 0 first -- the kernel alone,
ns an element at 8, 32 and 80 vectors -- then the 1419-token prompt
alternated, then the 110-token one, then TinyLlama's dense prompt as the
control, which must not lose. Kept only if the dense control holds.

**Risk:** the k-quant prologue (the sub-block scales and the minimum's
term) is per block and per vector; at N vectors it is N times the work
unless the scales are hoisted, which the 2026-09-06 entries did for eight.
Budget a second entry for that.

## 2. The two-bit row product on the device (one week)

**The mechanism.** Inside a token Q2_K streams at 39 GB/s where Q4_K
streams at 59 and Q8_0 at 56; `tests device-bench` says Q3_K is worse, 21.
The mixture is 1.15 GB of Q2_K a token. Factoring the minimum out of the
sum (2026-09-11) bought 7%; halving the loads bought nothing; the shape of
the kernel -- eight lanes a row, every lane every block, sixteen
accumulators of GROUP -- is what is left, and llama.cpp's kernel differs
in exactly that: sixteen lanes a row, two rows a workgroup, the sub-block
scales staged in shared memory once for the workgroup, subgroup reductions
where the instance is 1.1.

**Hypothesis:** the Q2_K branch reshaped to llama.cpp's lane layout
streams at 55 GB/s inside a token, which is TinyLlama Q2_K from 72 to
about 100 t/s and the mixture from 22 to about 28 from an empty context.

**Where it goes.** `row_product.comp`'s Q2_K and Q3_K branches, compiled
as they are today; the reduction stays through shared memory for the 1.0
instance and a `-DSUBGROUPS` compilation joins the attention's for
devices that offer them. The engine's dispatch geometry (`Row_Lanes`,
`Row_Width`) is per format already.

**Measure:** `tests device-bench` for the kernel alone, then TinyLlama
Q2_K generating alternated, then the mixture from a six-token prompt with
the stacks held at load, then Q8_0 as the control. Conformance at zero
outside tolerance; the association changes, so no digest is held.

## 3. Attention over a long context on the device (one week)

**The mechanism.** The same mixture generates at 22 t/s from an empty
context and 18 at 1302 positions: 10 ms a token for 1302 positions over
48 layers, 0.2 ms a layer, for 5.3 MB of keys and values a layer -- 25
GB/s, half of what the part streams. A generated token's attention is one
query a head against every cached position, forty-eight times; llama.cpp
splits the positions across workgroups and merges the partial softmaxes.

**Hypothesis:** attention split over the positions, with an online
softmax merge, streams the cache at 50 GB/s and brings the 1302-context
token from 18 to about 20.5 t/s; at 4096 positions the difference is
larger than that.

**Where it goes.** `attention.comp`'s single-position path: a split-K
over the cached positions with a second small dispatch that merges (or a
subgroup merge within one workgroup where the instance allows). The step
kinds and the fusing are untouched.

**Measure:** the device timeline from step 0 says what attention costs
per layer before and after; the token rate at 6, 1302 and 4096 positions
alternated; the batched prompt as the control (it uses the tile
attention and must not move).

## What is not in this plan, and why

- **One submission a token.** Priced at two or three milliseconds of a
  forty-five millisecond token by the dispatch measurement; the log's
  reading at twenty-two layers was a wash; a descriptor bank a layer to
  build. The timeline in step 0 will say whether the price is right, and
  it goes back on the list if it isn't.
- **A faster processor generating token.** 1.02-1.19 behind by format,
  and the log has taken it apart to the instruction; the remaining per-core
  gap on the four-bit format is instructions in the k-quant prologue, a
  known and small item.
- **This host's memory.** The mixture's prompt on the device cannot be
  measured cleanly here: 11.26 GB pinned leaves no page cache for the file
  and every run reads gigabytes back from disk. Measure the device prompt
  on a machine with 64 GB or accept the generating figures as the device's
  measure of the mixture.

## Order and estimate

Step 0, then 1, then 2, then 3: roughly four weeks of the log's kind of
work, the first week decisive for the largest number. Each step ends in a
measured-figures entry, kept or refused, and the gate passing.
