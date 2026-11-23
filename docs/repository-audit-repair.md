# Repository audit repair, 2026-11-23

This repair addresses the nineteen findings and the database/Cryptolib resolution failure reported at the
previous [adapter execution checkpoint](harness-adapter-execution.md). It does not complete the remaining
trained-adapter campaign, device execution or training-data stages.

## Changes

- The linked database manifest now pins `../cryptolib`, consistently with the other workspace crates.
  This is a change in the sibling database checkout, outside the model_runner Git tree.
- Headless public operations have complete parameter/result documentation and are used by native command
  dispatch. Requests missing their noninteractive acknowledgement retain the original validation behavior.
- The headless integration test generates its own tiny model instead of selecting hard-coded fixture paths.
- An obsolete failed-spec diagnostic in the linked Ada_Quality build directory was preserved under
  `/tmp/model-runner-audit-repair-ada-quality-failed-spec.stderr`. Its body had subsequently compiled cleanly.
  No dependency warning allowance was raised.
- The previous README and measurement ledger are preserved in [PERFORMANCE_HISTORY.md](../PERFORMANCE_HISTORY.md)
  and [measured-figures-history.txt](measured-figures-history.txt), including their original numbers and
  fingerprints. Stale observations are withdrawn from current performance claims, not restamped as fresh.
- The active ledger registers only the qualified [no-adapter CPU comparison](harness-adapter-no-adapter-check.md).
  Its selected inference sources were checked against the preserved measured source archive. Headless command
  wrappers are outside that probe's execution path. The new group fingerprint is `0E463A7AD897F4E2`.
- The device publication check accepts an explicit absence of current timings only without an active device
  group. Published timings require one active group and exact recorded numbers. Regression cases reject
  duplicate groups/headings, missing evidence and numeric substring matches.
- The changelog records the earlier headless implementation and this repair. Its ancestry gate requires a
  local commit containing that record; editing the file alone is insufficient.

The implementation and changelog checkpoint is model_runner commit `3b5cbdf5`; the linked database pin
repair is database commit `fde9939`. Both commits are local.

## Validation

Normal Alire application and test builds pass. The mandatory full suite passes **966/966**, with zero failed
assertions and unexpected errors. The focused project-state suite passes **153/153**, and the release-gate
suite passes **11/11**. The final repository audit completes **30,555 checks with zero failures** (exit 0).
All thirty-four previously blocked checks now run successfully.

The audit reports no dependency-warning verdict for Ada_Quality or SSH_Lib because they have no qualifying
compilation evidence in this tree. It also leaves its own duration unqualified: 223.56 CPU seconds exceeds
the existing 195-second budget, but measured host load 3.54 exceeds the gate's idle-load requirement.
No warning allowance, duration budget or load threshold was changed.

Final logs:

- `/tmp/model-runner-audit-repair-root-final-build.log`
- `/tmp/model-runner-audit-repair-tests-final-build.log`
- `/tmp/model-runner-audit-repair-full-suite.log`
- `/tmp/model-runner-audit-repair-final-audit.log`

Logs use the `/tmp/model-runner-audit-repair-` prefix. These are local validation artifacts, not durable
benchmark evidence. Existing measurement JSON files retain the original campaign environment and results.
