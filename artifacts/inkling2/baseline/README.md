# Selected native Inkling baseline

This directory retains the small recovery evidence for the committed IQ3_S/Q4T
baseline, selected in `docs/inkling2-gsq-selected-evidence.json` (v15). It contains
source and executable hashes, exact compiler profiles, compiler flags, ELF
section hashes, the 72 focused qualification logs and original timing logs.
Model weights, executables, object files and source archives are excluded.

The saved baseline confirmation measured **26.65 tok/s prefill and 16.59 tok/s
decode**, using a 2048-token prompt and 512 generated tokens, eight workers,
batch 128, int8 arithmetic, Q4T and seven DSpark proposals. It used one warmup
and one measured pass; it does not establish a repeatability estimate. The
original selected measurement and later confirmation are retained separately.
The three subsequent relative-table, residual-mixing and cache-packing trials
were rejected; their source changes are absent from the committed baseline.

## Build and profile recovery

Ordinary Alire/GNAT builds work without profiles (`MODEL_RUNNER_PGO=off`).
The measured build used GNAT 15.2 with profiles only for the decoder and CPU
backend. Recover the exact saved profile directory in the recorded checkout:

```sh
mkdir -p artifacts/inkling2/obj/gsq-profiled-next/pgo-data
tar -xzf artifacts/inkling2/baseline/profiles.tar.gz \
  -C artifacts/inkling2/obj/gsq-profiled-next/pgo-data
export MODEL_RUNNER_PGO=use
export MODEL_RUNNER_PGO_UNITS=decoder
export MODEL_RUNNER_PGO_DIR="$PWD/artifacts/inkling2/obj/gsq-profiled-next/pgo-data"
alr exec -- gprbuild -P model_runner.gpr -j8 -p -s
(cd tests && alr exec -- gprbuild -P tests.gpr -j8 -p -s)
```

GCC profile filenames and checksums depend on the recorded build location,
compiler and source. These profiles were produced under
`/home/bent/Projekte/Ada/model_runner`; relocating them does not promise a
compatible or byte-identical build. Other environments can use the ordinary
build or generate fresh profiles through the existing project options. Profiles
are needed only for this compilation mode; inference has no profile dependency.

`source-sha256.json` records the measured source bytes, including locally
generated Alire configuration files. The source in this commit retains those
measured implementation bytes. Git does not retain generated configuration.
The restored executables remain local, identified by `binary-sha256.json`.
Full release verification is not claimed; the saved qualification is focused
native, independent numerical, CPU/Vulkan and existing-architecture testing.
