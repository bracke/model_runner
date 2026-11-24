# Adapter retired after the historical Ada transfer check

The selected Mellum output adapter is **retired**, following the user's decision on 2026-11-24.
The three completed runtime-qualified pairs give **base 1/3, trained 0/3**: one base-only success and
two pairs both failed. That is enough to reject this checkpoint for use; it does not establish a general
conclusion about adapter training. No replacement fit, additional evaluation or model-default change is
scheduled. The weights and raw evidence are preserved for provenance.
The [artifact ledger](ada-transfer-artifacts.json) records the separate archives, frozen images and
checksums; archive integrity and every final identity check pass.

The queue was held immediately when the user chose to ditch the adapter. The seventh attempt already
running was allowed to finish; it also timed out. Every model process finished before the held inactive
dispatcher was terminated. **Seven of 24 planned attempts completed; seventeen remain unattempted.**
This is a stopped partial study, not a completed 24-attempt comparison.

| Task | Seed | Base | Trained |
| --- | ---: | --- | --- |
| CRLF text value | 71 | passed, 555.5 s | timeout, 600.4 s |
| CRLF text value | 72 | timeout, 600.1 s | timeout, 600.0 s |
| Empty TOML string | 71 | timeout, 600.1 s | timeout, 600.1 s |
| Empty TOML string | 72 | unattempted | timeout, 600.1 s; unpaired |

The [complete partial report](ada-transfer-runtime-partial.json) retains all seven native records, the
frozen manifest, exact settings and capture-control counts. The extra unpaired failure is reported
separately from the decision's three matched pairs. No pair was solved by both arms, so a paired
efficiency comparison is unavailable.

All seven starting source identities match the curriculum. All configuration snapshots are unchanged,
and paired inference settings match across the three completed pairs. Every one of **38 actual sampled
generations** has an active compiled grammar, including a native continuation over a 7,571-byte prefix.
The base, merged weights, selected adapter and user configuration retain their original SHA-256 hashes.
All six unchanged/reference task controls qualify and exactly match the original source/test records.

Every failed trace was inspected as it completed. Five failures make no source change and run no tests:
they exhaust time generating replies, reading source, looking up declarations or recovering from malformed
references. Base CRLF seed 72 applies an edit but fails compilation for mixed logical operators and times
out before repairing it. A symbol name or line number supplied as `ref` is correctly rejected. These
remaining failures are model workflow outcomes under the fixed 600-second work bound, with substantial
cold-prompt and generation costs. The grammar repair is not a demonstrated adapter-quality improvement.

Two earlier partial comparisons remain separate: [six original outcomes](ada-transfer-original-partial.json)
before the schema repair, and [four schema-only outcomes](ada-transfer-schema-partial.json) before the
runtime repair. Neither is pooled with this run or upgraded. Both were stopped after a demonstrated tool
contract defect. The [repair report](ada-transfer-selector-repair.md) explains the defects and tests.
The retained production fixes require an edit selector, constrain marked open-reader calls on later turns,
and preserve grammar state over budget-cut continuations.

Validation passes **1,002/1,002 tests** and **30,954 repository checks with zero failures**. The audit's
duration is unqualified under its existing load gate. The generation change's required
[28-sample CPU speed requalification](runtime-no-adapter-evidence.json) also passes both declared gates.
It measures ordinary inference cost and says nothing about adapter quality.

This adaptive check reuses tasks observed before two repairs. Only three pairs from two task families
finished, at two seeds, with cold sessions and large prompts on one machine. It supports the practical
retirement decision, not a reliable general accuracy margin. The original small pilot's trained 5/9 versus
base 4/9 remains [historical evidence](mellum-learning-results.md), not a reason to promote this checkpoint.
