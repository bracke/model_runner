# Serving several sequences in one pass

## What this is

A design, not a description. Nothing here is built yet. It is written down
because the thing it proposes is worth more than everything the performance
work of the last week measured put together, and because the shape of it turns
out to be much smaller than it looks.

## Why

A generated token reads every weight once and multiplies each of them once, so
what it costs is what the memory costs. Two tokens that come out of *one*
reading of the weights cost barely more than one. Measured with
`--batch-size` on the 110-token prompt, where a batch of one is a token at a
time and reads 27.7 ms a token — the generating figure to a tenth:

| batch | processor | | device | |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 27.7 ms a token | 1.00× | 18.8 ms a token | 1.00× |
| **2** | **17.8** | **1.56×** | **13.6** | **1.38×** |
| 4 | 8.6 | 3.23× | 7.6 | 2.48× |
| 8 | 5.8 | 4.79× | 3.8 | 4.92× |
| 32 | 3.6 | 7.63× | 2.1 | 9.02× |

**Two callers served in one pass get tokens at one and a half times the rate
of two served in turn; four at three and a quarter.** Every reading above
prints the same digest, `8ca534de63ff96ac`, at nine batch sizes on the
processor and six on the device — so batching changes no answer, which is the
guarantee the whole design rests on and it is already measured rather than
assumed.

For comparison, everything else this program has left on the table on the
processor is fifteen per cent, and every arrangement of workers inside one
process has now been tried for it. This is a different order of thing.

## What is already there

- **Any number of sessions on one prepared model.** A model carries no
  per-evaluation state — the activations, the normalized copies and the query
  and key rows all belong to the session — so a second sequence costs its own
  cache and nothing else. A test interleaves two sessions a token at a time
  and checks each gets what it would have got alone.
- **A batched evaluation that is already a loop over rows.** `Evaluate_Batch`
  allocates every buffer it uses for the call, sized `Count × width`, and does
  its per-position work in loops over `Which in 0 .. Count - 1`. It touches
  the session for four things only: the cache, the committed position, the
  attention scratch, and the token history.

That last point is the whole reason this is a small change. The batched path
is not a special case that would have to be generalised; it is the general
case with one restriction.

## The restriction, and lifting it

Today every row of a batch belongs to one session, at consecutive positions,
attending one cache. The restriction is exactly that: **which cache a row
attends, and where in it the row sits.**

So the engine gains one primitive:

```ada
procedure Evaluate_Round
  (Members : Session_Group;              --  one session a row
   Source  : Model'Class;
   Tokens  : Token_Array;                --  one token a member
   Logits  : out Real_Array;             --  one row a member
   Cancel  : Cancellation.Token_Reference := null;
   Status  : out Error_Info);
```

which is `Evaluate_Batch` with four substitutions:

| today | in a round |
| --- | --- |
| `Item.Keys`, `Item.Values` and their halved and byte forms | `Members (Row).Keys` … |
| `Reserved`, one number | `Reserved (Row)` |
| `Earliest (Settings, Reserved, Index)` | the same, per row |
| the cache write at `Reserved + Which` | at `Reserved (Row)` in that row's cache |

Nothing else in that procedure changes. The products are already over the
whole batch; the normalizations, the rotation, the gated middle and the joins
are already per row.

## What a round refuses

A round is one model and one arithmetic, so its members must agree about
things the kernels cannot vary a row at a time:

- the same prepared model;
- the same cache precision — exact, halved or eighth — because the attention
  kernel reads one form;
- room in each member's cache for one more position.

A group that disagrees is refused by name rather than run. Nothing about a
member's *content* has to match: different prompts, different lengths,
different positions, different sliding windows are all ordinary.

## What the scheduler does

Above the primitive, policy — **built**, as `Model_Runner.Serving`:

1. Sessions that are ready to generate wait in a queue.
2. A round takes up to *K* of them. **Gather in fours**: a batch of three
   costs nearly what four does and a batch of six costs *more in total* than
   four, because the strip kernel takes vectors in fours and a partial strip
   leaves lanes idle for the whole pass.
3. Step the round: one `Evaluate_Round`, one row of logits a member.
4. Sample per member, with that member's own penalties, biases and stops.
5. Commit per member. A member that stopped leaves the round; a member that
   arrived joins the next one.
6. Re-form and step again.

A session joining with a prompt used to prefill on its own first. **It does
not any more**, and that was the largest thing left here: with the arriving
timed apart from the rounds, sixteen callers through eight seats spent
seventy per cent of a run on arrivals at a hundred and ten tokens a prompt.

A joining member's next stretch of prompt is rows of the same round as
everyone else's next token. `Evaluate_Round` takes a share list — how many
rows each member contributes, one apiece being a decode round — and a row is
a member and a position and nothing in an evaluation cares which of the two
kinds it is. Admitting a caller costs a copy of its prompt into its seat and
ten milliseconds, where it cost seventy to four hundred and thirteen.

Alternated, medians of three, eight seats and thirty-two callers: the
processor reads **1.29×** at a seven-token prompt and **1.21×** at a hundred
and ten; the device **1.27×** and **1.16×**.

**Every stretch rides the round**, and there is no exception left.

A device has a second attention kernel that answers sixteen query positions
at once out of one cache, and a round's rows do not share a cache — so for a
while a stretch of sixteen or more was read on its own. Giving a round that
kernel, by dispatching it a member at a time, was built and measured and
dropped: better than it was, still behind reading alone, and worse than
nothing below the kernel's tile.

What a lone prompt really won with was `Whole_Layer`, the entire layer in one
submission with the cache write in it. **A round takes that now**: the step
that writes the cache reads the same per-row table the step that attends
does, so the sequence names no one cache and no one run of positions.
Alternated, medians of three on the device: a round of eight **1.13×**,
sixteen 1.14×, a server 1.11× at a seven-token prompt and **1.17×** at a
hundred and ten. With it a round beats reading alone, so the threshold and
the pass it protected are gone.

It took two goes, and the first read as a much deeper fault than it was — one
hoisted expression, evaluated before the call that gives a session its block.
`docs/measured-figures.txt` has it, and the rule it left: when a rewrite is
supposed to be arithmetically identical, ask the program, do not read it
again.

**This design is built.** What is left is not in it: the cache is dealt out
in blocks of a whole session's context, so sixteen members cost sixteen
contexts whether or not the members fill them. Blocks of positions rather
than blocks of sessions is the next thing, and it is a capacity question
rather than a speed one.

## Pages

A block is a session's whole context, taken the first time it writes and
kept for its life. A session that fills a hundred positions of a
two-thousand-position context holds the room for two thousand, and sixteen
of them hold it sixteen times. What a server wants instead is to deal the
cache in **pages** -- a fixed stretch of positions -- and give a session
only as many as it has filled, wherever they happen to be free.

A page holds a power-of-two run of positions of one layer, its keys and then
its values: `P` keys of `KV_Width` and `P` values of `V_Width`, so a page is
a fixed size for the model whatever session it serves. A session at a
context of `C` holds `ceil(cells/P)` pages a layer, a sliding-window layer
fewer than a whole-context one, and the pages it holds are scattered through
the buffer rather than one run. Where a block let a row read `k_base + the
block's base + the position times the width`, a page makes the position name
its page: a per-layer table, a word a page giving the element that page
begins at, and the position's keys at that base plus its place inside the
page. `k_base` and `v_base` become offsets inside a page -- nought and `P *
KV_Width` -- and the table is where the block's base was.

**Stage one -- done.** The four kernels that touch the cache read and write
it either way. `attention.comp`, `attention_matrix.comp`, `heads.comp` and
`place.comp` each carry a `place_of` that a shift of zero sends down the
block path it always took and a shift above zero sends through a page table;
the products and backend layers pass a `Pages_At` and a `Page_Shift` through
`Add_Place`, `Add_Attention`, `Add_Heads`, `Whole_Layer`, `Attend_And_Feed`
and `Attend_And_Project`. The engine asks for a shift of zero everywhere
today, which is the same arithmetic and the whole device suite unchanged, so
what is added is the room to page and not a page.

**Stage two -- the engine.** A session opened paged is given pages of the
device's cache instead of a block: `Page_Owner` deals the slots, `Pages`
records each page's base and `Page_First` where a layer's pages begin, the
per-layer table is written into the cache a layer at a time as the round's is,
settling reads the scattered pages back into the host's contiguous copy, and
close gives the pages back. The gate is met: a paged session gives, bit for
bit, the logits it gives in a block, past a hundred and thirty positions and
two pages, on the device.

Two things the building settled. A layer's page table carries a couple of
entries past its own pages, each a valid page, because a kernel reads a chunk
past the last position that attends -- masked out of the answer, but a wild
read through a table with no slack. And a paged session places with the place
step, not the chained head step: the head step read the page table from the
same binding it wrote the cache through, and a driver dropped the writes, so
until that is bound apart and proven the same way a paged session mirrors.

**Stage three -- the capacity, taken lazily.** A page is dealt only when a
position reaches it, so a session holds `Page_Count` pages a layer -- as many
as its filled cells reach -- and not its whole context. `Take_Pages` is given
the highest position a pass will write and grows each layer to the page that
reaches, at the first free slot, and the reserve grows with it; a session that
fills a hundred of two thousand positions holds two pages a layer where a
block held the room for thirty-two. `Pages_Held` reads the count, and the gate
is a second one: a paged session past the first page holds one more page a
layer than before it and no more, far below the block's worth.

**Stage four -- eviction.** The pool is bounded by the device's memory, which
the reserve enforces, and a server may bound it tighter with `Limit_Page_Pool`
to hold more sessions in less. A session asking for a page the pool cannot grow
to turns out the coldest other session -- gone unasked since before the asker's
own last ask, so two sessions reading a token apiece in turn leave each other
alone and one does without rather than each turning the next out every token.
The session turned out reads its pages back into its host copy, gives the slots
up, and writes its cache into the pages it is given again when it next runs.
`Pages_Turned` counts it, and the gate is the block's, in pages: a paged
session turned out and brought back says, to a ten-thousandth, what one that
kept its pages says.

And priced under the bound: the eight sessions above, whose pages want 176
slots, held to a pool of twenty-four -- an eighth of what they want, 4.5 MB,
two hundred and thirty-five times under the block cache -- say the same mark to
the bit and read within about a ninth of the tokens a second the unbounded pool
reads, at a matched device clock. The turning-out does not thrash, because a
session turns out only one colder than itself: past the first squeeze, where
seven of the eight are turned out once, the set settles. `tests speed --turns N
--paged --page-pool P` measures it; `docs/measured-figures.txt` keeps the run.

**Stage five -- a round whose members are paged.** A round of paged members
costs its members' pages rather than their whole contexts. Each member holds
its own scattered pages, and the round's per-row table points each row not at a
block's base but at where that member's page table for the layer sits -- a
per-row table with the member page tables laid out past it, a member's a row,
the base word naming one by its place in the cache. The kernels needed nothing:
`place_of` already reads a round's base word as a page table where the shift
says so, so the whole change is the engine laying the tables out and the round's
whole layer carrying the shift. The gate is the round's, in pages: a member of
a round of four paged members, two of them past a page, gets to a thousandth
what it gets paged alone.

**The design is built.** The cache is dealt in pages -- taken as a position
reaches one, turned out coldest-first under a bound, and read by a round a
member's own -- so a server holds as many sessions as their filled positions
fit rather than as many as sixteen whole contexts. Blocks remain for a single
long session, where a block is one contiguous reserve and nothing is dealt
between sessions; pages are what a churn of many wants.

**And held to it off the tested path.** A cache dealt two ways from the front
of the one buffer is a thing to get wrong quietly, so a multi-agent review was
turned on the whole of it, and what it found is closed. A device holds one kind
at a time now -- a paged session finds a block held and does without pages, a
block session finds pages held and does without a block, each on the host until
the other lets go, where before the two dealt the same elements and wrote over
each other. A paged session whose layer will not go over whole -- a
normalize-after model, a whole-norm one -- attends on the host out of its
mirror-current copy rather than over block offsets a paged cache does not hold.
The pool serves one page size at a time, so the slot a base divides back to is
always the size of the pages held. The blocks past the stack are written back
when a session comes again, not the stack alone. And a settle that cannot
finish leaves the pages where they are, an empty range reads nothing rather
than counting below zero, and a table written where the sequence reads it turns
the layer to the host where the write could not land. None of these was on the
path the tiny fixture takes -- it fits, it is one model, it never mixes -- and
each is now held where it would have gone wrong.

**And made to cost what it should.** A single session's page tables are written
once a token where the pages grow, all the layers at their own places past the
pages, not a table a layer every token; `Take_Pages` returns at once for the
asks past the position its pages already reach, rather than walking every layer
to find nothing to grow; and one release path frees a session's slots for both
the close and the turn-out, where two copies could drift.

**And placed by the head step, as a block is.** A paged batch first placed its
keys and values with a separate place step where a block folded that placement
into the chained head step -- two dispatches a layer the pages did not save.
The head step now reads the page table out of the cache it writes, through a
read-only view of it at a binding of its own, and places into the page a
position names, so a paged batch dispatches exactly what a block does. A round,
whose rows carry their own per-row table, still mirrors.

**And priced.** Eight sessions taking turns, each of a 2,048-position context
and filling twenty-three of it, on the device: the blocks hold 1,056 MB of
cache and read 39.1 tokens a second; the pages hold 33 MB -- one page a layer
apiece -- and read 39.1, for the same answer to the bit (mark `10452449`). The
cache is thirty-two times smaller for no cost a token, because the head step
places the pages where it placed the blocks; a memory-bound server fits that
many times more of these in the cache it has. `tests speed --turns N --paged`
and `--round N --paged` serve them, and `docs/measured-figures.txt` keeps the
run.

**And sized to the fill.** A page holds sixty-four positions of a layer by
default, so a session filling twenty-three of its context wastes forty-one of
the page's positions -- the page is taken whole as the first position reaches
it. `Set_Page_Size` moves it: a server whose callers fill little may hold the
page to thirty-two, where the same twenty-three round up wasting nine, and the
cache halves -- 16.5 MB, sixty-four times under the block cache -- for the same
answer to the bit. Smaller pays back less and costs more: sixteen rounds the
same twenty-three up to thirty-two again, saving no cache and doubling the
pages and the table each layer carries. The size is a power of two of at least
sixteen -- a page and a place inside it are a shift and a mask, and a tile of
the matrix instruction must not straddle a page -- and it is one geometry with
the pages, so it is set before a session holds any. `--page-size N` measures
it.

## Staging

**One — done.** `Evaluate_Round` on the processor, the four substitutions
above, and `tests speed --round N` to serve a fixed set of sessions. It was
checked against the figure that justifies it and beat it: two members read
17.4 ms a token where one reads 29.3, and four read 8.7. Six read 9.3 --
slower a token than four -- which is the strip-of-four kink turning up in the
round exactly where this page said a scheduler should gather in fours. One
thing was added that this design did not name: the final projection over the
vocabulary is done for all rows at once, because a row at a time there gives
back a fifteenth of what the layers just saved.

**Two — done.** The device. The fused half-layer names one cache base and one
range of positions for the whole batch, so a round takes the unfused path
there: every product to the device, the device's own copy of the cache not
written, attention on the host where each row already has its own. The device
is ahead of the processor at every member count — 198.8 tokens a second at
eight members against 183.6 — and gains less from each added member, four
times over one against the processor's five and a half, which is what putting
attention on the host costs. A single member reads 20.2 ms a token where the
fused path reads 19.3, so the arrangement costs about five per cent for one
sequence and two members pay for it twice over.

The round driver digests every token every member chose, and the two backends
print the same mark at every count: a device round says exactly what a
processor round says. Nothing else in the suite would catch that — the
conformance sweep runs evaluations, not rounds.

**Three — done.** A per-row cache on the device, which lets it run a
round's attention as well as its products.

What it is worth, alternated with the arrangement it replaces, medians of
three each way on the device at a context of fourteen hundred positions:

| | attention on the host | on the device, pushed | in blocks |
| --- | ---: | ---: | ---: |
| 2 members | 2.024 s | 1.587 s | **1.292 s** |
| 4 members | 2.915 s | 1.965 s | **1.477 s** |
| 8 members | 5.658 s | 2.777 s | **1.783 s** |
| 16 members | — | 8.115 s | **3.444 s** |

Eight members read **143.6 tokens a second against 45.2**, and sixteen read
148.7 where the pushed table read 62.8 — that last row being the cap the
push block imposed: a round of more than eight attended on the host and was
slower than the same device at eight. The removal below priced eight members
at a long context at fifty per cent of the round; taking it away more than
doubled the round, which is the rarest kind of entry here — a price named
before the work and met by it.

How it is built, which is what the pricing said it had to be:

- **One shader.** `attention.comp` in its three compilations. A round takes
  the compilation whose block is one query, because a block of more reads a
  cached key once and dots it into every query of the block — and rows of a
  round do not share a cache.
- **One table, at the end of the cache.** Two words a row: where the row has
  got to, and where its block begins. It was pushed at first, which held
  eight rows and capped a round there; the cache is a buffer the kernel has
  bound already, so what was a limit became a read of two words a row.
- **The device's cache, dealt out in blocks.** It held one session's keys and
  values. It is handed out a session at a time now, each placed at the first
  gap that holds what it keeps -- so a block is the size of the session in it,
  and a session takes one the first time it writes to that cache and keeps it
  while anything else can be given one: where every block is held, the block
  stamped longest ago goes to the session asking. A round's rows read the
  blocks their sessions were already in, so forming a round writes the table
  and nothing else; rows of members that are not laid out alike go to the
  processor, the table saying where each block begins and not where a layer
  begins inside it.
- **Sixteen members.** What memory bounds rather than what a push block
  holds: sixteen blocks of this model at two thousand positions is two
  gigabytes. More than that keeps attention on the host, as stage two left
  it, and says the same thing.

Three things came out of the building that this design did not name.

A round of eight at a long context spent a third of a thirty-two-round
measurement writing every member's cache into the block its row number named
— a member prefills alone and was then moved. Blocks a session keeps for its
life remove that, and the phase clock is what found it: the whole of the cost
fell between the last layer of one round and the first of the next, and did
not grow with the round count.

A wider cache buffer used to come up empty and turn every seated session out
of its block. It carries its contents over now, values and half-precision
copy alike.

Blocks are placed at the first gap that holds them and moved down when the
buffer would otherwise grow past a gap a larger block cannot use -- the
packing stops at the first block that makes the room, and a block moved is
the session's cache written where it now is. The room of rings does the same
with its seats -- and only where the gaps below would hold what is being
placed, which is when the moving is what keeps the buffer from growing.
`--turns N --churn K` prices it: twelve sessions at a context of 512 with a
departure every other turn read 46.7 tokens a second under that rule, against
45.1 when any gap at all set the packing going and 46.6 with no packing at
all -- the same 594 MB of cache in all three, the gaps on that workload being
reusable. What the packing is for is the pattern the tests build, where two
gaps neither of which holds the arrival together do.

Members and sessions of different lengths are what a server has, and both
measurements can be asked for them: `--spread` gives each a prompt from a
fraction of the file to the whole of it. Sixteen sessions taking turns so
spread read 46.7 tokens a second against 45.9 level; a packed round of
sixteen read 1.038 s against 1.277. The first spread round measured read
2.150 s, which was the engine counting a round's slices from its first
member's last rather than from the widest row's -- the rows each carry their
own in the table, and the kernel takes its span from there.

A seventeenth session turns out whichever block has gone longest unasked --
the session holding it reads back whatever the device owes its copy, gives
the block up, and writes its keys and values into whatever block it is given
next -- and a seventeenth hybrid does the same to a seat in the room of
rings, whose ring comes home first. Neither happens between two sessions as
warm as each other: a block or a seat is taken only from a session that has
gone unasked since before the asking session's previous token, so seventeen
sessions reading a token apiece in turn leave each other alone and the
seventeenth does without, which costs one session its speed rather than all
seventeen a cache carried back and forth every token. `--show-stats` says how
often either happened -- and how often a block or a seat was moved to close a
gap -- and a caller can ask what is true now rather than what happened: `Holds_Block` and `Holds_Seat` of a session, `Blocks_Held` and
`Seats_Held` of the device. `tests speed --turns N` measures the cost: N sessions
taking turns a token apiece, which is the shape the sixteen blocks are a
limit on where a round is not. On TinyLlama-1.1B Q8_0 at a context of 512,
sixteen sessions read 49.3 tokens a second and turn no block over, seventeen
read 48.1 and turn one, and thirty-two read 43.6 and turn sixteen; the same
counts on the processor read 39.1 to 39.4 whatever the count, having nothing
to run out of. Take the guard away and the same thirty-two turn a block over
528 times instead of sixteen; at a 1,419-token context, twenty sessions read
7.8 tokens a second without the guard against 42.1 with it, which is a
64-megabyte cache written across the bus every token against four writes in
the run. Where a session holds little the churn is nearly free and the guard
costs about four per cent -- five alternated pairs at a context of 512 read
43.2 guarded against 45.1, the unguarded binary ahead in every pair -- which
is the price of not falling off the other end. That write was the whole of its cache, which is the room it has rather
than what it has put there: twelve tokens of a 2,048-token context is 540
kilobytes of ninety-two megabytes. It writes a layer at a time now, the cells
that layer still holds. A round stamps every member before any of them asks,
so no member turns another out, and a round holds at most as many members as
there are blocks.

And two sessions on one device used to write over each other's keys, which
nothing did and nothing caught; blocks are the answer to that as well.

**Four — done.** The cache dealt in pages rather than blocks, built and
priced in the **Pages** section above: the four kernels addressing the cache
either way, an engine that gives a session a page of a layer only as a
position reaches it, eviction of the coldest under a bound, and a round whose
rows read their own pages. A block reserves a session's whole context whether
it fills it or not; a page is taken as it is reached, so eight sessions
filling twenty-three of a 2,048 context hold 33 MB where the blocks hold
1,056 -- thirty-two times less cache for the same mark to the bit, and at no
cost a token, because the chained head step places the pages where it placed
the blocks. Held to a pool of twenty-four pages the cache falls to 4.5 MB and
the answer still holds, within about a ninth of the tokens a second; sized to
a page of thirty-two, where the sessions fill less than that, it halves again
to 16.5 MB. `tests speed --turns N --paged`, with `--page-pool P` and
`--page-size S`, measures the three; `Pages_Held`, `Pages_Turned`,
`Limit_Page_Pool` and `Set_Page_Size` are what a server reads and turns.

**Five — done.** The pages kept packed as well: a session's cache in bytes or
nibbles, dealt in pages, so paging's fraction of the positions and packing's
quarter or eighth of each compound. The three packed kernels and the whole
layer place and attend a packed page; a packed session turned out of its pages
reads them back; a packed round gives each member its own. A packed paged
session says its packed block's mark to the bit, in both storages, past two
pages, turned out under a bound, and as a round. The same eight sessions hold
8.4 MB of q8 pages against the packed block's 259, or 5.2 MB of q4 against 160
-- two hundred times under the exact block -- and 2.1 MB held to a pool of
forty-four. A long packed prompt attends by the cooperative-matrix kernel, over
its pages gathered into the copy the packed pages leave free, at the packed
block's rate. `--kv-cache` on `tests speed --turns` and `--round` serves them;
`docs/plan-packed-pages.md` has the plan. The packed pages now do everything
the exact pages do, to the bit.

## How it will be checked

The correctness gate is the existing two-session test generalised, and it is a
strong one: **every member of a round must produce, bit for bit, the logits it
would have produced alone.** That is not an aspiration — the batch-size table
above shows fifteen readings at nine batch sizes and two backends with one
digest between them, so the products already do not care how many rows they
are given. What the test guards is the part that is new: that no row reads
another's cache, and that each writes only its own.

Beside it, the sweep and the fixture check run as they do now: a round is
evaluation, so everything that holds evaluation holds it.

## What it is not

It is not throughput at the cost of an answer. A member of a round gets the
same tokens in the same order it would have got alone, and if it ever does
not, the test above fails rather than the figure improving.

It is also not a way to make one caller faster. A single sequence is a chain
of dependent products and stays what it is; what a round buys is that the
second caller is nearly free.
