# Reference editing validation

The new `edit_file` reference mode is implemented for recognized complete multiline Ada routine bodies.
See the [usage contract](reference-editing.md) and
[separately declared Mellum check](mellum-reference-edit-protocol.md).

Normal root and test builds pass without warnings. The complete native suite passes **987/987**, with
zero failed assertions and zero unexpected errors. Five focused reference-edit tests also pass.

The repository audit passes **30,781 checks with zero failures** (exit zero). Its own 220.39-second
processor cost exceeds the existing 195-second allowance at load 1.19; the existing load gate leaves
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

The model check is one ordinary task with the actual configured Mellum model and unchanged task wording.
It must report whether reference mode was used and retain any failure. These structural results do not
establish improved model completion rates.
