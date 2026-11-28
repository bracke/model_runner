# Benchmark model-bound regression measurement

Declared on 2026-11-25 before measurement. The benchmark now forwards an
explicit host memory limit to model preparation as well as session creation,
matching the existing command behavior. An explicit 24 GiB limit permits the
shared Q4_K_M arena beyond the default 16 GiB allocation cap. Production inference
source is unchanged. A focused AUnit regression checks preparation rejection
under a small model budget; the related benchmark cases also pass.

Repeat the unchanged [common-engine protocol](inkling2-no-adapter-protocol.md):
two seven-pair batches, unchanged probe and historical engine, fixed inputs,
release compiler arguments, exact output digests, and both 1.05 paired-median
prompt/decode gates. Build, tests and premeasurement source audit must finish
first. Run without a competing model, build, test or audit job; retain every
sample without retry or exclusion. Freeze and reverify all source, input,
dependency and executable identities.

Retain the [previous packed-view campaign](inkling2-no-adapter-panels-evidence.json)
and its raw files. Write the new raw campaign to
`artifacts/inkling2/obj/no-adapter-speed-limits/`. Only a passing campaign may
replace the active evidence and refresh the measured ledger through its
ordinary command. No throughput or precision gate changes.
