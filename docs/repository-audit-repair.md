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

## Validation

Normal Alire application and test builds pass. The mandatory full suite passes **966/966**, with zero failed
assertions and unexpected errors. The focused project-state suite passes **153/153**, and the release-gate
suite passes **11/11**. The final repository audit follows the local changelog checkpoint.

Logs use the `/tmp/model-runner-audit-repair-` prefix. These are local validation artifacts, not durable
benchmark evidence. Existing measurement JSON files retain the original campaign environment and results.
