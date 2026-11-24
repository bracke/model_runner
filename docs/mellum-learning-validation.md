# Mellum learning implementation validation

The normal release build and tests build pass. Project-owned units have no compiler warnings; existing
dependency diagnostics remain subject to the repository's recorded allowances. No production source or
inference default changes in the original learning experiment. The learning tools live in the tests crate.
The separately declared report-guidance correction changes production instructions after that comparison.

The original complete suite passes **997/997**, with zero failed assertions and zero unexpected errors.
All nine focused learning checks also pass, including actual Linux confinement rather than a skipped probe:

- Cross-entropy gradients for both factors match independent binary64 finite differences.
- Adam learns actual parameters; nonfinite or malformed factors are refused without damaging existing weights.
- A zero update preserves the complete GGUF and exact base lineage is required.
- All five teaching graders reject unchanged source and accept their independent reference implementations.
- Nonzero F32 and Q6_K merges match an independent low-rank product and preserve unrelated bytes.
- Complete eight-epoch fitting retains checkpoints, selects by validation and refuses tampered inputs.
- Extracted states and logits precede the intended target token, checked against independent prefix evaluation.
- Default-arm statistics retain regressions and exclude fast failures from jointly passing task costs.
- An attempt cannot see a sibling solution; its project remains writable and host files and descendants stay confined.

The repository audit completes with **30,909 checks, zero failures and exit zero**. Compiler evidence comes
from actual recompilation, including the standalone probes and release-checker units. Large local weights
and frozen executables remain in ignored `obj` directories; no audit rule is relaxed.

The audit takes 224.22 seconds wall time and 211.30 seconds processor time. Its existing 195-second
processor allowance is exceeded at load 1.12, so its existing load gate leaves the duration unqualified.
This is a structural pass, not evidence of satisfying the audit's performance allowance. No timing bound,
performance fingerprint or inference setting is changed.

The final report-guidance correction passes both normal builds and **998/998 tests**, with zero failed
assertions and zero unexpected errors. Its added functional case exercises actual workflow completion
with two comma-separated paths and following-line paths, preserves a filename containing spaces, and
rejects a space-joined pair. A malformed protocol-digest override is refused with exit one.

The final repository audit passes **30,924 checks, zero failures and exit zero**. It takes 223.85 seconds
wall time and 211.23 seconds processor time at load 1.38. The existing 195-second processor allowance
therefore remains unqualified under the load gate; this is not a performance pass. No audit rule or
timing allowance is changed. Both verification jobs finish before the separately declared native checks.

The [real merged-file check](mellum-learning-merge-verification.json) independently compares the complete
prefix and suffix outside `output.weight` and finds them identical. The head differs and the merged file
passes native inspection. The [fit](mellum-learning-fit.json), [full curve](mellum-learning-curve.json),
[feature identities](mellum-learning-features.json) and [teaching outcomes](mellum-learning-collection.json)
are retained separately. Synthetic numerical fixtures never enter the actual Mellum dataset.

Full build, focused-test, complete-suite and audit logs remain under
`artifacts/mellum-learning-v1/validation/`. Model quality is determined by the separately declared
held-out native workflow comparison, not by these implementation checks.
