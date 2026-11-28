# Local Inkling campaign artifacts

`obj/` holds generated binaries, source archives, raw measurement logs and V3
execution records. It is excluded from Git; it contains no required production
dependency. Keep these files locally when reviewing the corresponding evidence.

Checked-in results and reproduction instructions are recorded in
[the implementation verification](../../docs/inkling2-verification.md),
[the common-engine measurement evidence](../../docs/inkling2-no-adapter-evidence.json)
and [the independent fixture inventory](../../tests/fixtures/inkling2/README.md).

The [native timing report](../../docs/inkling2-benchmarks.md) includes CPU and
bounded-GPU samples. Its [interpretation correction](../../docs/inkling2-benchmark-interpretation.md)
preserves the original raw data and premeasurement protocols while correcting
the generator operation counts.

The committed [selected baseline recovery bundle](baseline/README.md) retains
only small compiler-profile and verification artifacts. It excludes weights,
executables and the larger local experiment archives under `obj/`.
