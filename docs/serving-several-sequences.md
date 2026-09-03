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

Above the primitive, policy:

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

A session joining with a prompt prefills on its own first, which is the
batched path exactly as it is today — its rows are its own tokens. Mixing
prefill rows and decode rows in one round is a later thing and is not in this
design: it needs a per-row token count as well as a per-row position, and the
win from it is smaller than the win from decode rounds.

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

**Three — priced, not built.** A per-row cache on the device, which lets it
run a round's attention as well as its products.

What it is worth: at a context of seventy-one positions, nothing at two and
four members and ten per cent at eight. At fourteen hundred positions, **16,
34 and 50 per cent** — so at eight members and a long context half the round
is host attention, and stage three would take eight members from 82.1 tokens
a second to about 163. Attention grows with the square of the context and the
products do not grow at all, which is why the same arrangement is free at one
end and costs half at the other.

What it has to be, which the measurement settled:

- **One shader, not two.** A decode round never reaches the matrix attention
  shader: that one wants sixteen rows and a round has as many rows as
  members. `attention.comp` in its three compilations is the whole of it.
- **One table, not three.** In a decode round the row *is* the member, so a
  row's cache base is its row number times a stride; and the window's start
  derives from the last position and the window's width. Only the last
  position is genuinely per row.
- **Room in the push constants.** The attention block is sixty-four bytes and
  every device offers a hundred and twenty-eight, so a stride and eight
  last-positions fit. That caps a device round's attention at eight members,
  which is where the win is; more members than that keep attention on the
  host as stage two left it.
- **The device's cache.** It is reserved for one session's keys and values.
  A round needs it reserved for the members and written with a member's
  offset — that, and `Attend_And_Feed`'s interface, are the work.

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
