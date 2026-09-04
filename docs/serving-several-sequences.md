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

**One exception, and it is not the kernel it looked like.** A device has a
second attention kernel that answers sixteen query positions at once out of
one cache, and a round's rows do not share a cache. A stretch of sixteen
positions or more is read on its own where that kernel exists; anything
smaller rides the round.

Giving a round that kernel was built — a *member's* own rows do share a
cache, so a round dispatched a member at a time can have it — and measured,
and reverted: 9.2 s to 8.9 for the in-round reading against 8.70 for reading
alone, and worse than nothing on stretches below the kernel's tile.

**What a lone prompt really wins with is `Whole_Layer`**, the entire layer in
one submission with the cache write in it, which a round cannot use either:
it names one cache and one run of positions for every row. Four submissions a
layer against one is the gap and the attention kernel was a third of it.

That was built next and is not kept. The per-row table a round already
carries is exactly what the step that writes the cache needs, so the sequence
can stop naming one of anything — and it measured **1.13× on a round of
eight**, 1.17× on a server, and it removed the read-alone exception
altogether. But the members of a round disagree, and the error hides at a
long context because a wrongly placed position is one part in fourteen
hundred of a softmax. `docs/measured-figures.txt` has the bisect: the table
reaches both shaders, one whole layer is already wrong, and it is neither the
carry nor the shader's aliasing of the cache. **The prize is still there and
so is the bug.**

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
  values. It is handed out in blocks of one session's worth now, and a
  session takes one the first time it writes to that cache and keeps it until
  it closes. A round's rows read the blocks their sessions were already in,
  so forming a round writes the table and nothing else.
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

And two sessions on one device used to write over each other's keys, which
nothing did and nothing caught; blocks are the answer to that as well.

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
