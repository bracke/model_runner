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

The [four-arm edit screen](harness-adapter-twil-screen.json) and
[its native manifest](harness-adapter-twil-screen-manifest.json) finish with **zero verified completions**,
four timeouts and zero infrastructure failures. Both model variants execute native edits and checks with
thinking off. All four attempts preserve their project configuration and record the expected thinking
choice, CPU controls and zero/one runtime attachment counts. This qualifies the tool contract, rather than
successful coding or an adapter recommendation.

| Arm | Executed calls | Generated tokens | Verified completion |
| --- | ---: | ---: | --- |
| Base, thinking off | 7 | 823 | no |
| Adapted, thinking off | 4 | 509 | no |
| Base, thinking on | 1 | 1,101 | no |
| Adapted, thinking on | unavailable | unavailable | no |

The last arm requests no tools before timing out; native completed-work counters are unavailable and remain
null. Fewer tokens in the off comparison do not establish efficiency without verified completion.
Check-only reuse reads all four finished records with zero new attempts and leaves the summary hash unchanged.

The first startup attempt, retained separately under `tests/obj/trained-twil-screen-v1`, was an infrastructure
failure because the pinned program bundle lacked its project templates. The complete source resource tree
was copied before the fresh v2 screen; its manifest SHA-256 is
`c2cc1ec128340e41f8afd2b99973baeb4f1e82c3fa4b430e1bdfe62691db2f96`.
That packaging failure is excluded from model-quality outcomes. Program and harness bytes did not change.

The first full-pilot launch under `tests/obj/trained-twil-pilot-v1` stops after one model timeout and one
infrastructure failure. The second session completes initialization after the driver's thirty-second wait
has expired; no model work begins in that attempt. These partial records remain separate from the new pilot.

The harness now gives initialization up to 300 seconds and stops early on a reported setup error. This
changes startup tolerance only; the model's work budget remains 300 seconds. Confined runtime caches now
live under the project's already-ignored `obj` directory. The native boundary probe verifies that cache
location and actual cache writes while retaining the original verifier, host-write and descendant attacks.
That regression fails with the prior cache environment and all ten campaign cases pass with the fix.

After the startup fix, the mandatory suite again passes **969/969** and the final repository audit passes
**30,617 checks with zero failures**. The audit's duration remains unqualified at host load 1.26; its
195-second bound is unchanged.

The replacement pilot starts at 2026-11-23 13:23 UTC under `tests/obj/trained-twil-pilot-v2`, using source
checkpoint `ecdb93a3862743fd9056a4f9ff6f24c21f364a77` and a fresh manifest. Its pinned harness SHA-256 is
`3d44c7bc0761b06fdd547d93f0ea046fdc3b1854c109c203f4ee1328a23b4229`. It retains the same inference
program, models, template, sampler and work budgets. Results are pending. Generated panel files are removed
only from finished
attempts; transcripts, diffs, configurations and verifier results are retained. The process holds a temporary
idle/sleep inhibitor and the existing hard deadline.

A separate lightweight operational monitor samples host load every 45 seconds and removes generated panel
files from finished attempts. It retains the native summary and every transcript. After the campaign exits,
it attempts native check-only reuse if at least two minutes remain before the same deadline, records the
exit status and whether the summary hash changed, and writes `pilot-result.json` in the pilot directory.
That result file is not present while the pilot is running; no completed pilot result is claimed here.

The user authorized sixteen hours and reported the machine quiet. The shared screen/pilot deadline is
2026-11-24 04:07:54 UTC. Confirmation remains conditional on a promising pilot and its separate frozen-suite
and uncertainty requirements. No model default has changed.

Build and validation logs are retained under `/tmp/model-runner-twil-*.log`; plain generation output, process
timing and panel cache are under `tests/obj/trained-twil-smoke`. Pinned executables and the shared template
are under `tests/obj/twil-runtime-pinned`; the replacement harness bundle is `tests/obj/twil-runtime-pinned-v2`.
Model payloads remain in
`/tmp/model-runner-trained-adapter-evaluation` at this checkpoint.
