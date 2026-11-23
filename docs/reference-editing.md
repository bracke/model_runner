# Edit an Ada routine by reference

`edit_file` accepts a revision-bound declaration reference in place of `old_text`.
For a complete Ada function or procedure body, this avoids copying the existing body or its indentation.
The same tool, write permissions, confinement and change tracking apply to both modes.

First ask for the named declaration:

```json
{"kind":"declaration","query":"Calc.Add"}
```

Use `find` with those arguments. Select the complete body in the intended `.adb` file from its results;
a specification, interior excerpt or clipped body is not a replacement target. The result includes a
reference such as `src/calc.adb:3-6@0123456789abcdef`. Use the actual returned reference and its path:

```json
{
  "path":"src/calc.adb",
  "ref":"src/calc.adb:3-6@0123456789abcdef",
  "new_text":"function Add (A, B : Integer) return Integer is\nbegin\n   return A + B;\nend Add;"
}
```

The hexadecimal value above is illustrative. A reference's complete file revision must still match,
even if an external change was outside the selected body. The path must be spelled exactly as in the
reference. If several overloads are shown, choose one reference; a bare symbol name cannot authorize a
replacement, and a range spanning neighboring declarations is refused.

Supply the complete replacement, including the same routine's header and end. Common leading indentation
is removed from the supplied text, then the body is placed at the original indentation. Adjacent source
bytes, line endings and the presence or absence of the final newline are preserved. Leading comments
included in the selected declaration reference are part of what is replaced.

Success reports the before/after revisions and a fresh reference, which may be used for another repair
without copying the old text. An unchanged replacement is reported unchanged. A stale reference, wrong
path, incompatible routine name/kind, incomplete body or ambiguous line boundary leaves the file intact.
The checked writer also verifies the revision again when staging and publishing the replacement.

The current reference mode is limited to recognized complete multiline Ada function/procedure bodies,
at most 400 lines, in text files of at most 4 MiB. Unsupported shapes are refused; the ordinary passage
mode remains available for other edits. This is a structural editing aid, not a compiler or behavior check.
Run the project's normal checks after changing code.

Pass either `ref` or `old_text`, never both. `new_text` and `path` are required in either mode. Optional
`revision` retains its existing meaning for passage edits; if supplied with a reference, it must agree
with the reference's revision. Malformed reference arguments cannot fall back to an unchecked passage edit.

The feature addresses editing uncertainty observed in the
[Mellum trace review](mellum-trajectory-review.md). Deterministic structural safety and a bounded real-model
check are separate evidence: successful structural replacement alone does not establish better task completion.

See [validation and limits](reference-editing-validation.md). The ordinary Mellum check passed through
passage editing. A separate [directed check](mellum-reference-directed-results.md) exercised reference
replacement and stale-reference refusal, but failed the coding task. No completion benefit is established.
