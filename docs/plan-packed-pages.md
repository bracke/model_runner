# A packed cache dealt in pages

The device cache can be dealt in pages rather than in blocks, so a session
holds only the positions it has filled -- eight sessions filling twenty-three
of a 2,048 context hold 33 MB where the blocks hold 1,056, thirty-two times
less, for the same answer to the bit (`docs/serving-several-sequences.md`, the
Pages section, and `docs/measured-figures.txt`). The device cache can also be
kept packed -- keys and values as bytes or nibbles with their scales beside
them -- which is a quarter or an eighth of the exact cache the session would
otherwise hold.

A session may have either, and not both. `Take_Pages` refuses any session that
is not `Exact` (`src/library/model_runner-llama.adb`, the guard that reads
`Item.Held /= Exact`): a paged session keeps its cache in full precision. This
plan lets the two meet, so a paged session may keep its pages packed and the
two savings compound -- thirty-two times fewer positions, and a quarter to an
eighth of each. On the workload the Pages section measures that is 33 MB
falling toward 8, and the point of paging is capacity, so it is the count of
sessions a memory-bound server holds that multiplies.

Every stage below is built the way the log builds: bit for bit against a
packed block, at each granularity the exact paging was checked at -- past a
page boundary, turned out under a bound, and as a round -- kept or refused by
the reading, and priced.

**Where this stands.** Stages one, two and three are done: the three packed
kernels address a cache by pages, the engine deals, places and attends a
packed page, a packed session turned out of its pages reads them back, and a
packed round gives each member what it gets alone. A session kept packed and
dealt in pages says its packed block's mark to the bit -- in bytes and in
nibbles, past two pages, turned out under a bound, and as a round. Measured on
the device, eight sessions filling twenty-three of a 2,048 context: the q8
paged cache is 8.4 MB against the packed block's 259 and the exact block's
1,056; the q4 paged cache is 5.2 MB, two hundred times under the exact block;
and held to a pool of forty-four pages, six turned out, it is 2.1 MB and still
the block's mark to the bit. And a long packed paged prompt attends by the
cooperative-matrix kernel now, over its pages gathered into the copy, at the
packed block's rate -- so nothing is left of this plan: the packed pages do
everything the exact pages do, and take the matrix instruction where the batch
is long enough for it, in both storages, to the bit.

## Where the two stand, and why they do not meet

Paging and packing were built apart and touch different code.

**Paging** is one indirection. A key or a value that sat at a base plus the
position times the width now goes through `place_of`: a position names a word
of a per-layer table, the table names its page, and the place inside the page
is the position's low bits by a shift. It lives in the four exact kernels --
`attention.comp`, `attention_matrix.comp`, `heads.comp`, `place.comp` -- each
carrying `pages_at`, `page_shift` and `first_position` on its push block, and
in `Take_Pages`, which deals a session a page of a layer only as a position
reaches it.

**Packing** is a different shape and a different set of kernels. A packed
block holds its keys and values as bytes or nibbles at one region, their
scales at another -- `Packed_Cache` names the widths and the offsets
(`K_Bits`, `V_Bits`, `K_Bytes`, `V_Bytes`, `KS_At`, `VS_At`, `K_Blocks`,
`V_Blocks`). The kernels that read and write it are their own: `pack.comp` and
`pack_subgroups` write it, `attention_packed.comp` and
`attention_packed_subgroups` read it, and `unpack.comp` gathers a layer's rows
into the half-precision copy the matrix instruction attends over. `place.comp`
does no packing; a packed session never runs it. None of these five kernels
knows a page from a block.

So the two axes are orthogonal and no kernel today reads a cache that is packed
and paged at once.

## The one decision: a packed page's layout

An exact page is uniform: `Page_Positions` positions of one layer, each a run
of `KV_Heads * (Head_Size + Value_Size)` floats, position after position. A
packed page cannot be, because a packed position is bytes, or nibbles, with
scales apart from them. There are two ways to lay one out.

**Position-major.** Each position's packed keys, values and scales contiguous,
position after position, as the exact page is. The addressing is the exact
page's -- page base plus the position's low bits times a packed row's width --
and nothing but the width changes. But the packed kernels read region by
region, all the keys then all the values then the scales, so that a workgroup's
lanes read one contiguous run; position-major breaks that, and a nibble
straddling a lane's word is worse still.

**Region-major, a page a small packed block.** A page holds its positions'
keys, then their values, then their key scales and value scales -- the packed
block's own layout at `Page_Positions` rows. The packed kernels keep their
access pattern: within a page they read exactly as they read within a block,
by the offsets `Packed_Cache` already names, scaled to a page. A position's
data is split across the page's regions, which is what the packed block already
does across a block's, so the math is the block's with the page's base under
it.

**Take region-major.** It keeps five kernels reading the way they read now and
reuses `Packed_Layout`, which is the work of the plan halved. A page is a
packed block of `Page_Positions` positions, and `place_of` becomes: name the
page, then index its region as the block was indexed.

## Stages

### 1. The packed kernels read and write a cache by pages (one to two weeks)

The five packed kernels learn the indirection the exact four learned, into a
region-major packed page. `pack.comp` and `pack_subgroups` write a position's
packed keys, values and scales into the page the position names rather than at
a block's base; `attention_packed` and its subgroup twin read them from there;
`unpack.comp` gathers a layer's rows, now scattered across the layer's pages,
into the contiguous half copy.

Each carries `pages_at`, `page_shift` and `first_position` on its push block,
as the exact four do, and reads its page table through a read-only view of the
cache at a binding of its own -- the same trick `place.comp` and `heads.comp`
use, because a buffer bound writeonly and readonly at one binding made a driver
drop the writes. `pack.comp` writes the cache and reads the table out of it, so
it needs that view; the descriptor wiring that points its fourth binding at the
cache for a paged pack is new, and is where the exact head step cost its
debugging.

`unpack` is the one that is not a copy of the exact indirection. It reads a
whole layer at once to build the half copy, and a layer's positions are now in
scattered pages rather than one run: it walks the page table a page at a time
and lays each page's rows where the contiguous copy wants them. Priced on its
own before the rest, since it is the new shape here.

The shift is zero everywhere the engine calls today, which is a packed cache in
blocks and the arithmetic these kernels do now, so the whole device suite
passes unchanged. Nothing asks for a packed page yet.

Checked: the four device attention and round tests, packed, at shift zero, say
what they say today.

### 2. The engine deals a packed page (one week)

`Take_Pages` lifts its `Exact` guard to admit `Eighth` and `Fourth`, and its
geometry generalizes. `Page_Row` and `Page_Elements` become a packed page's
word count: a page holds `Page_Positions` rows of packed keys and values and
their scales, which is a constant per position -- a row's bytes and its
`K_Blocks + V_Blocks` scales -- so the page is a whole number of words and the
slot arithmetic stands. The page's regions are laid out as `Packed_Layout`
lays a block's, scaled to `Page_Positions`.

A page must hold a whole number of packing groups, so that no group's scale
serves positions in two pages -- the packed analog of the exact page's "a
multiple of sixteen so a tile never straddles a page." `Set_Page_Size` gains
that constraint against the quant group size where the session is packed.

The one-geometry-per-pool guard already holds: a packed page's `Page_Elements`
differs from an exact page's, and the pool refuses a session whose page is not
the size the held pages are, so a packed and an exact paged session do not
share a pool, as a paged and a blocked session do not share a device.

Checked: a packed paged session says, bit for bit, what the same session says
in a packed block, past two pages -- the packed twin of
`A_Paged_Session_Says_What_A_Block_Session_Says`.

### 3. Eviction and the round (half a week)

Both fall out of stages one and two if they are built to the geometry rather
than to the exact page. `Release_Session_Pages`, `Evict_Coldest_Pages` and the
per-row table a round writes count slots and bases, which are the packed page's
as much as the exact page's. This stage is the checking, not new mechanism: a
packed paged session turned out under a bound reads its pages back and says
what it said, and a round of packed paged members gives each what it gets
alone -- the packed twins of the two tests that already say this for the exact
page.

### 4. The measurement (a day)

`tests speed --turns N --paged` with a packed `--kv-cache` says the compounded
footprint: the eight sessions of the Pages section, packed, against the same
paged exact and the same packed block. The figure the plan is worth is the
product -- a quarter to an eighth of thirty-two times less -- for the same mark
to the bit, at what the packed kernels' page walk costs a token. Written to
`docs/measured-figures.txt` beside the exact paging's, and the headline cited
in the serving page's Pages section as a fifth stage.

## What is not in this plan, and why

**A packed page position-major.** Refused above: it would make the packed
kernels read against their grain for an addressing that saves nothing the
region-major page does not.

**A page size chosen for the session.** The engine could pick a packed page
size from the quant group and the expected fill rather than take it from
`Set_Page_Size`. The fill is not known when the first page is dealt, so this is
a server's policy over the knob, not the engine's, and it is left to the
server as the exact page size is.

**Folding a packed round's placement into a head step.** A packed round places
with its own kernels and attends on the host, as every device round does; the
fused head step is the batch's, and a round would gain a dispatch or two for
work the host already does row by row. Marginal, and orthogonal to packing.

## Order and estimate

One, two, three, four, in order: the kernels first because everything reads
what they read, the engine second, the checking of eviction and the round
third because it is checking, the measurement last. Three to four weeks, the
weight in stage one and its `unpack` gather, and the risk in the descriptor
aliasing on the packed write kernel -- the one thing here that cost the exact
paging real time when it was the head step's turn.

The whole is gated behind the per-pool geometry guard, so at every stage before
it is asked for, a packed cache is dealt in blocks and an exact cache in pages,
exactly as today.
