# Taking the several-sequences server back out

The purpose of this engine is to run one language model on hardware that can
barely hold it. Serving several sequences at once is the opposite workload --
it spends memory and compute the target hardware does not have to raise a
throughput a single user at a command line never asks for. The machinery for
it was built and is real, but nothing a user types reaches it: `Evaluate_Round`
and `Serving.Server` are called only from the test suite and the speed
benchmark, never from the command driver. This plan takes it out, and keeps
the parts that serve one session on little hardware -- a cache dealt in pages
so a context pays for what it fills, and kept packed where the caller trades
precision for room.

What a user runs stays exactly as it is: `Evaluate` and `Evaluate_Batch` a
single session, its prompt read in one batch, its cache in a block or in pages,
exact or packed. The suite is the net -- every stage below leaves the
single-session inference tests, the conformance sweep and the CLI cases green,
and removes their round and serving counterparts with the code they cover.

## What comes out, in three layers

The subsystem is not one module but three, of rising entanglement.

**One -- the server, standalone.** `Model_Runner.Serving` (a `Server` of
seats, `Open`/`Admit`/`Step`/`Retire`, the round scheduler over it) is 1,091
lines that nothing in the library depends on. It comes out whole, with its one
inference test and the `--serve` path of the speed tool.

**Two -- the round, threaded through the core.** `Evaluate_Round` is a thin
wrapper: it calls `Evaluate_Batch` with the members as `Beside`. So the round
is not a module to delete but a set of branches to unpick from the shared
engine -- some forty-six `Rounding`/`Seated` branches across `Evaluate_Batch`
and the whole layer, the `Beside`, `Given`, `Givens` parameters and the
`Session_Group`, `Given_Rows`, `Row_Counts` types, the per-row table the device
kernels read when `Table_At` is not zero (a branch in `place.comp`, `pack.comp`,
`attention.comp` and `attention_packed.comp`, so this layer regenerates
`shaders.ads`), and the round-forming code in the engine and the device
backend. The single-session path is the same code with `Beside` empty, so the
work is removing the not-empty case and proving the empty one unchanged.

**Three -- eviction and the shared rooms, dormant for one session.** A block,
a page or a ring is turned out only when a new session needs room another holds
-- which one session never does. `Evict_Coldest_Pages`, `Free_Session_Pages`,
the warmth guard (`Block_Clock`, `Asked_At`, `Asked_Before`), the turn-out of
blocks and of seats in the room of rings, the `Blocks_Turned`/`Pages_Turned`/
`Rings_Turned` counters, `Limit_Page_Pool`, and the sharing of the block room
and the ring room across sessions. This is woven into the allocators
`Take_Block` and `Take_Pages`, dormant on one session, so it is the finest
unpicking and the smallest gain.

## What stays, and the one thing to be careful of

Kept, because it serves one session on little hardware:

- `Evaluate` and `Evaluate_Batch` for a single session, prefill read as one
  batch on the device or the processor.
- The cache dealt in pages for one session -- a context pays for the positions
  it fills, not the whole of a block -- and `Set_Page_Size`.
- The cache kept packed, keys and values in bytes or nibbles, where the caller
  asks, and the exact cache otherwise.
- The device whole-layer, the matrix instruction over a long prompt, the host
  fallback -- all of it single-session.

**The care point is the room of rings.** A single session on a sliding-window
or state-space model still needs its ring buffer; what layer three removes is
the *sharing* of a room of rings across sessions and the turning-out of seats,
not the ring itself. `State_Seats` must lose its many-seat sharing while a lone
session keeps its one. This is the place the untangling is most likely to
catch a single-session case, so layer three is checked hardest against the
windowed and state-space inference tests.

## Stages

Each stage builds, passes the single-session suite, and is committed on its
own, so the removal can stop at any layer that turns out to be enough.

### 1. The server (half a day)

Delete `model_runner-serving.ads`/`.adb`, its inference test, the `--serve`
branch of the speed tool and its options, and the server sections of
`docs/serving-several-sequences.md`. Nothing in the library references it, so
this is a deletion, not an untangling. The suite loses the serving cases and
stays green.

### 2. The round (two to four days)

Remove `Evaluate_Round`, the `Beside`/`Given`/`Givens` parameters and the
`Session_Group`/`Given_Rows`/`Row_Counts` types, and unpick the `Rounding`
branches from `Evaluate_Batch`, the whole layer and the device backend --
including the per-row-table branches this session added to the packed kernels,
and the exact ones before them, regenerating `shaders.ads` with
`compile-shaders.sh`. Remove the round and packed-round inference tests and the
`--round` path of the speed tool. The single-session `Evaluate_Batch` -- the
same code with the members empty -- is what remains, and the inference and
conformance suites are what say it is unchanged.

This is the stage with the shader regeneration and the most branches, and the
one to take slowly: unpick a branch, build, run the single-session suite,
commit.

### 3. Eviction and the shared rooms (two to three days, optional)

Remove the turn-out of blocks, pages and ring seats, the warmth guard, the
turn counters, `Limit_Page_Pool`, and the many-session sharing of the block
room and the ring room -- keeping a lone session's block, its pages, and its
one ring. This is dormant for one session, so the gain is the code gone rather
than a session served better, and the risk is a single-session case that ran
through the shared path. Optional: a server that is gone turns nothing out
anyway, so this layer is cleanliness, not correctness, and can be left for
later or left alone.

## What is not in this plan, and why

**Keeping the round as a latent capability.** It could be left in, unreached,
against the day a batch workload appears. But an engine for one model on little
hardware will not grow a batch workload without contradicting itself, and dead
code that the suite still exercises costs more to carry than to remove. If a
batch need ever arises it is a feature to design against the hardware then, not
a subsystem to keep warm now.

**Removing quantization or paging.** Both serve one session on little hardware
-- packing fits a bigger model or a longer context, paging pays for the fill --
so they stay, as capabilities the caller reaches for.

## Order and estimate

One, two, three, in order: the server first because it is a clean deletion and
the rest reads more easily without it; the round second because it is the bulk
and touches the shaders; eviction last because it is dormant and optional.
Three days to a week for the first two, which is where the simplification is;
the third only if the cleanliness is wanted. The single-session suite is green
at every step, and the removal can stop after any stage.
