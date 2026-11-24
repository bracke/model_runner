# Multi-file completion guidance: completed native check

Both separately declared checks pass: **base 1/1, trained 1/1**, seed 61. Both finish the native workflow,
report the two changed source paths with commas, and pass the independent protected tests. There are no
infrastructure errors or replacement attempts. The original eighteen learning outcomes remain unchanged.

| Model | Native grade | Work seconds | Calls | Generated tokens |
| --- | --- | ---: | ---: | ---: |
| Base Mellum | passed | 134.4 | 5 | 2,968 |
| Selected epoch-six merged model | passed | 110.0 | 7 | 2,184 |

The [protocol](mellum-completion-files-protocol.md) was declared before the production guidance change.
The [complete results](mellum-completion-files-results.json) retain both native attempt records, resolved
settings, configuration snapshots, visible completion replies and source identities. The matched initial
source and protected test are also identical to the original Subtract comparison.

The production change tells root, child and helper agents to separate `changed_files` paths with commas
or following lines, and that spaces inside a path are not separators. The parser, path checks, completion
gate and protected grader are unchanged. Base reports `src/calc.ads, src/calc.adb`; trained reports
`src/calc.adb, src/calc.ads`. Both are accepted as two distinct paths.

The actual workflow regression additionally checks following-line reports and a path containing spaces,
and rejects a space-joined pair. Both normal builds, **998/998 tests** and **30,924 repository checks**
pass. The audit duration remains unqualified under its existing load gate; see
[implementation validation](mellum-learning-validation.md).

Both runs use the user's unchanged inference defaults, unforced thinking and effort, disabled carried
knowledge, the same 300-second work limit and native confinement. Base runs first, then trained; no build
or test job runs alongside either. Paired resolved settings match apart from model and the fractional
time remaining in the work bound. The existing base, adapter and merged weights are unchanged.

The executable SHA-256 is
`8173b8af3d57e05e26882fdf3ceca6c921ad51e4cb5baae59da34b9d75390a26`;
the driver SHA-256 is
`95345b03a5a22201f1b729e07382ac4b76fb33c7f1d0f85c34dac12ef12e76d2`.
The protocol, configuration and model digests are retained in the results manifest. These executables are
preserved separately from the original comparison images. Raw projects, captures and grading evidence
are retained in `artifacts/mellum-learning-v1/obj/completion-check/` and its evidence archive.

This verifies the clarified format through two fresh native workflows. One seed per model cannot establish
a general reliability improvement or an adapter effect. The original [nine-pair result](mellum-learning-results.md)
remains trained 5/9 versus base 4/9, with mixed outcomes and no reliable general-gain claim.
