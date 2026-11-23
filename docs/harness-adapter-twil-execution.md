# Trained TwIL adapter execution

The complete Q4 base and released trained Pi adapter pass pinned whole-file size and SHA-256 checks.
All 280 adapter pairs resolve against the declared Granite base. The required publisher template compiles
and renders with both thinking choices and tool definitions using the complete verified model.
See [the frozen protocol](harness-adapter-twil-protocol.md) and [inputs](harness-adapter-twil-artifacts.json).

## Native generation and memory

[The retained smoke record](harness-adapter-twil-smoke.json) contains the native outputs and observed
process memory for base, zero-scale attachment and active attachment. All three processes exit successfully,
read 31 prompt tokens and reply `READY` in one generated token. Base and zero scale match text and token
counts exactly. These are actual released trained weights, rather than synthetic adapter fixtures.

The first load constructs 5,111,808,000 bytes of native packed panels and peaks at 10,069,672 KiB RSS
(about 9.60 GiB). The zero and active runs reuse the same panel cache and peak at 5,556,132 and 5,560,920 KiB.
Their wall times are 11.14, 6.51 and 4.10 seconds respectively. Cache preparation differs between these
single runs, and repository audit compilation overlaps them; no adapter overhead ratio follows from them.
The observations admit native execution on this host without a 35.2 GB F32 weight expansion.

## Implementation and checks

Dense Granite now accepts CPU runtime attachments through its existing seven projection routes. Independent
binary64 projection checks include Granite's four nontrivial scaling controls. Token execution, full prompt
tiles and a tail match same-base F32 reference merging on bounded fixtures, including packed Granite rows.
The two new Granite paths fail against the prior allowlist and pass after the extension.

Explicit template overrides now recognize their source's tool-call format when no name is supplied.
This preserves the publisher's XML function-call syntax without replacing its template. A regression fails
before the fix and passes after it, including explicit-name, unknown-format and invalid-source controls.

Both normal serial builds pass without warnings. All fifteen adapter cases and the new template regression
pass; the final mandatory suite passes **969/969**, with zero failed assertions and unexpected errors.
The [fresh ordinary-inference comparison](harness-adapter-no-adapter-check.md) passes both seven-pair
batches at the unchanged 5% boundary, retaining every stall and output. The repository audit completes
**30,612 checks with zero failures**. Its own duration remains unqualified at host load 1.33; no threshold
or warning allowance changed.

## Coding gate and budget

Real native `/work` attempts and their independent coding verdicts are still pending. Successful short text
generation is not an adapter-transfer or coding-quality result. The initial screen uses all four arms of
the edit task. Its records must qualify isolation, native settings, tool execution and independent grading
before the full twelve-task, three-repeat pilot proceeds.

The user authorized sixteen hours and reported the machine quiet. The shared screen/pilot deadline is
2026-11-24 04:07:54 UTC. Confirmation remains conditional on a promising pilot and its separate frozen-suite
and uncertainty requirements. No model default has changed.

Build and validation logs are retained under `/tmp/model-runner-twil-*.log`; plain generation output, process
timing and panel cache are under `tests/obj/trained-twil-smoke`. Pinned executables and the shared template
are under `tests/obj/twil-runtime-pinned`. Model payloads remain in
`/tmp/model-runner-trained-adapter-evaluation` at this checkpoint.
