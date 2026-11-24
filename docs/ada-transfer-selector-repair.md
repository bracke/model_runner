# Edit-contract repair after native workflow timeouts

The original six completed attempts contain two base CRLF passes and four timeouts: both trained CRLF
attempts and both empty-TOML seed-71 arms. All six initial source identities match. Their complete native
records remain in [the partial report](ada-transfer-original-partial.json). Eighteen original attempts
remain unattempted. The original comparison is incomplete and establishes no general quality margin.

The two trained CRLF traces repeatedly call `edit_file` without `ref` or `old_text`. The advertised JSON
schema required only `path` and `new_text`, although execution requires a selector. Neither attempt edits
source or reaches protected grading. One also supplies mismatched passage text. The base empty-TOML
trace exhausts its reply budget writing an incomplete, selector-less full-file call. Large cold contexts
also consume substantial time; the contract defect does not explain every token or every timeout.

The production definition now advertises two closed argument objects: `path`, `ref`, `new_text`, or
`path`, `old_text`, `new_text`, each allowing optional `revision`. Its constrained grammar rejects calls
with neither selector, both selectors or no replacement. Guidance discourages copied line-number
prefixes, and runtime recovery names both supported selectors. Exact matching, reference boundaries,
revision checks and independent grading retain their existing behavior.

The regression exercises the actual complete tool set, rather than a standalone substitute schema.
It initially caught loose JSON fallback because the schema compiler refused `additionalProperties:false`;
after that correction it caught loose tag fallback because tag parameters lacked object alternatives.
The compiler now accepts plain closed objects and bounded object alternatives in tag calls, while
refusing closed compound shapes it cannot preserve safely. JSON, Qwen XML and function XML checks verify
the corrected selector requirement. The focused selector check and all seven output-grammar checks pass.
The normal production build and incremental tests builds pass, with no warnings in changed units.
The complete corrected suite passes **1,001/1,001 tests**, with zero failed assertions and unexpected errors.

The [corrective protocol](ada-transfer-selector-protocol.md) retains the original model weights, task
snapshots, protected checks, seeds, sampling configuration and time bounds. All six newly prepared
unchanged/reference controls qualify, and their complete task identity records equal the originals.
The corrected model run follows the full suite and repository audit; its eventual results must be
reported separately, including every failure. This adaptive engineering evaluation reuses tasks observed
before the repair and cannot serve as a blind confirmation of a general adapter improvement.

That comparison was subsequently stopped after four CRLF attempts: base seed 71 passes; the other three
time out. Its [four native records](ada-transfer-schema-partial.json) remain unchanged, with twenty planned
attempts unattempted. Trained seed 72 emits another selector-less marked edit despite the corrected schema.
Its actual `Open_JSON` agent path deliberately disables generation constraints after the first call.
The schema and grammar tests therefore did not prove the constraint was active in this workflow.

The runtime repair constrains marked calls on every open-reader turn while retaining bare JSON prose.
It also resumes the grammar at an already generated prefix when a thought budget cuts a call in progress,
instead of dropping the grammar for the continuation. A sampled agent regression checks both first and
later generations. A separate native sampling regression requires only the remaining suffix, records the
prefix in the capture and rejects invalid prefixes before sampling. All ten trajectory checks pass.
The complete runtime-repair suite passes **1,002/1,002 tests**, with zero failed assertions and unexpected
errors. The normal production/dependent tests build passes in 143.77 seconds, followed by the final
incremental tests build in 17.73 seconds; changed units have no compiler warnings.
The [runtime protocol](ada-transfer-runtime-protocol.md) controls the next separate comparison and requires
checking actual generation metadata, including continuations, rather than assuming grammar use.
