# TwIL adapter: completed three-pair screen

Completed on 2026-11-23 under the [pre-generation protocol](twil-adapter-paired-protocol.md).
The baseline passes two of three attempts; the released Pi adapter passes one. There are no adapted wins,
one adapted loss, one pair where both pass and one where both time out. This screen demonstrates no local
adapter benefit. Keep the adapter disabled and leave model defaults unchanged. The cancelled 144-attempt
pilot remains cancelled; no confirmation or larger campaign starts.

## All six outcomes

Every attempt uses a fresh project, the same edit fixture, thinking off and a requested 300-second work
limit. Both arms use the same Q4_K_M base; only the adapted arm attaches the trained adapter at scale one.
These are new baseline measurements, with no reuse or regrading of the earlier smoke or cancelled pilot.

| Order | Seed | Arm | Native result | Work seconds | Elapsed seconds | Calls | Generated tokens |
| ---: | ---: | --- | --- | ---: | ---: | ---: | ---: |
| 1 | 42 | base | passed, complete | 218.8 | 221.815200 | 7 | 812 |
| 2 | 42 | adapted | passed, complete | 291.3 | 303.300096 | 6 | 669 |
| 3 | 43 | adapted | failed, out of time | 300.6 | 343.995123 | 4 | 726 |
| 4 | 43 | base | passed, complete | 201.5 | 243.577709 | 6 | 738 |
| 5 | 44 | base | failed, out of time | 300.2 | 306.870988 | 8 | 1,167 |
| 6 | 44 | adapted | failed, out of time | 300.3 | 310.354693 | 4 | 709 |

All six attempts finish grading: three passes, three ordinary model timeouts, zero infrastructure errors,
zero ungraded attempts and zero pending attempts. The campaign exits one because some native grades fail.
The configured work limits are unchanged; cancellation and timer granularity account for the small recorded
overruns. Total recorded work is 1,612.7 seconds, approximately 26 minutes 53 seconds, within the 1,800-second
aggregate allowance. Elapsed time includes startup and other work outside the model-work timer.

Only seed 42 supplies a both-solved cost comparison. Its adapted attempt takes 33.1% more work time,
291.3 versus 218.8 seconds, despite generating fewer tokens. Faster failures and fewer tokens without
completion do not count as efficiency gains. Timeout observations are censored; they do not measure how
long successful completion would have taken.

Three paired seeds on one Ada fixture provide descriptive screening evidence. They do not establish a
general adapter effect, statistical significance or a precise adapter overhead. The local Q4 CPU setting
also differs from upstream BF16 evaluation. Native peak host and device memory measurements remain null.

## Input identity and qualification

The [native manifest](twil-adapter-paired-manifest.json) and
[pre-generation control record](twil-adapter-paired-control.json) preserve complete paths, artifact hashes,
budgets and settings. The source checkpoint is `53bdc8a0d0952bc6f9c8efe4ebf8f79ba13b4eee`.
The release inference program includes the XML report repair; its SHA-256 is
`c8d3ab420981a1ed5814ed55b5926b70ec3be4895bc58dba194de73751f5d7a7`.
The pinned campaign harness SHA-256 is
`a7bdc8d9b82a9ebeaec8d9435f51befa75439cd0fab5941dfe0467f1850062cb`.

The complete base and adapter digests are verified before generation. Program, harness, publisher template
and all eight resource files match their pinned hashes after the study. The manifest source revision also
matches the detached source checkpoint used for execution and check-only reuse.

All twelve native setting snapshots, session and root for each attempt, match the selected controls:
CPU, eight workers, batch 512, F16 keys and values, context 8192, integer arithmetic, packed rows,
thinking off, no drafting, temperature 0.8, top-p one, top-k zero, min-p zero and repeat penalty one.
Each snapshot records its expected seed. Runtime adapter counts are zero for base and one for adapted.
There are no helper invocations. All six before/after project configuration snapshots are identical.
The manifest records fixed inference, knowledge and carry off, and memory mapping.

Execution is sequential on the quiet host after all builds, tests and audits finish. No competing model
job runs alongside it. The lightweight monitor retains 43 host-load samples, including the inference work
itself; load values are not treated as proof of an entirely idle machine. The temporary idle/sleep inhibitor
ends with the campaign. No campaign or model process remains active.

## Evidence reuse and retention

Check-only reuse runs from the same pinned source with the same manifest inputs and thinking selector.
It reports three passes, three failures, zero infrastructure errors and **zero new attempts**. The summary
is byte-identical before and after reuse, with SHA-256
`6b7f4188ed7bf7c8dbce81691d0e86a83858859eb1b0c407800651dc04ed1b00`.
The archived manifest SHA-256 is
`d71203cc708e16721baadac1e93e487d3848be3f60a3e772d7b3d04ab89251ed`.

The [native summary](twil-adapter-paired-summary.json) is copied byte-for-byte and contains every attempt,
effective setting snapshot, project configuration and descriptive statistic. Its zero-observation thinking-on
entries are unselected arms, not missing trials. The [result record](twil-adapter-paired-results.json)
collects the decision, qualification, validation and cleanup evidence without changing native grades.

The full local evidence remains under `tests/obj/twil-adapter-paired-v1`: transcripts, project sources,
diffs, protected verifier outputs, configurations and host-load records. Six generated panel caches totaling
30,670,872,576 bytes are removed only after all study processes stop. Model and adapter payloads remain.
The study and reuse logs are `/tmp/model-runner-twil-paired-study.log` and
`/tmp/model-runner-twil-paired-check-only.log`.

## Implementation validation

The native campaign gains `--thinking off` to select two arms while retaining four arms by default.
The selector is bound to the manifest. A regression verifies six planned attempts, alternating order,
matched seeds and attachment counts, retention of ordinary failures, exclusion of unselected records,
and refusal to resume with another selector. It fails against the original twelve-attempt behavior.

Normal root and tests builds pass without warnings. The full suite passes **970/970** at feature checkpoint
`9822d3352260f5a2dbaa988869e5990330cda5db`. A subsequent test-only repair normalizes two diagnostic-file
reads across hosts; all **11/11** affected campaign cases pass at the frozen source checkpoint. The full
suite is not repeated after that reader-only change. The final repository audit passes **30,634 checks
with zero failures**. Its duration remains unqualified: 221.85 seconds wall time and 210.49 seconds CPU,
at host load 1.54, against the unchanged 195-second bound. These checks finish before model generation.
No inference-kernel change or model-default change is made for this screen.
