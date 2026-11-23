# Reference editing validation

The new `edit_file` reference mode is implemented for recognized complete multiline Ada routine bodies.
See the [usage contract](reference-editing.md) and
[separately declared Mellum check](mellum-reference-edit-protocol.md).

Normal root and test builds pass without warnings. The complete native suite passes **988/988**, with
zero failed assertions and zero unexpected errors. Six focused reference-edit tests also pass.

The repository audit passes **30,785 checks with zero failures** (exit zero). Its own 210.30-second
processor cost exceeds the existing 195-second allowance at load 1.17; the existing load gate leaves
that duration unqualified. No timing allowance, performance fingerprint or inference default is changed.

The focused cases use actual references emitted by the existing retrieval layer. They verify full-body
replacement, exact preservation of neighboring source, indentation, fresh returned references and no-op
reporting. They also exercise leading comments, procedure bodies, explicit overload selection, CRLF and
files without a final newline.

Rejected cases retain their original bytes: stale revisions, a path differing from the reference, interior
or multi-declaration spans, same-line neighboring declarations, a conflicting routine name/kind, an
appended unrelated declaration and excessive replacement size. A checked-writer test changes the file
between the original reference read and replacement entry, confirming the intervening version survives.

Runtime tool tests verify exclusive reference/passage modes, contradictory revision refusal, rejection of
a non-string reference without falling back to passage editing, ordinary write permissions, and acceptance
of a fresh explicit reference when the runner's implicit seen revision is obsolete. The existing file-tool
and integration cases remain green in the complete suite.

The ordinary model check uses the actual configured Mellum model and unchanged task wording.
It must report whether reference mode was used and retain any failure. These structural results do not
establish improved model completion rates.

The [ordinary model check](mellum-reference-edit-results.md) passes using `old_text`, without exercising
reference editing. The separate [directed check](mellum-reference-directed-results.md) exercises two
successful reference replacements and one stale-reference refusal, but times out with invalid Ada.
Its independent protected rebuild fails and its validated export retains that failure. Real reference
use is observed; correct completion of that directed workflow and any completion benefit remain unproven.

The named-only native `edit-ref` fixture enables capture and requires successful reference use before
its protected behavioral and source-scope checks can pass. Its capture controls reject passage edits,
stale failures, no-ops and missing evidence. All 11 campaign tests pass. The final full suite reruns after
correcting a fixture-registration error caught by the existing grader self-check. Neither real model
outcome is substituted or promoted to training data.
