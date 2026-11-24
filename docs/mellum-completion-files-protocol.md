# Separate multi-file completion guidance check

Declared on 2026-11-24 before changing production instructions or running the following checks.
The original eighteen-attempt Mellum learning comparison finishes unchanged and retains every failure.
Its results are not replaced or relabeled by this follow-up.

The original native prompt says `changed_files: the files you wrote`, without naming a separator.
Observed Subtract reports put two paths on one line separated by a space; the existing path parser treats
that as one path and rejects completion. The parser already accepts commas and separate lines. Clarify
that existing contract in root, child and helper instructions. Preserve paths containing spaces; do not
introduce whitespace splitting, relax path validation or change the definition of workflow completion.

Verify the accepted multi-path report against the existing parser and actual file-claim handling, including
a path containing spaces. Run the normal builds, complete suite and repository checks for the final change.

After the original timed comparison and verification jobs end, run two fresh ordinary `subtract` attempts:
the same base Mellum and the unchanged selected epoch-six merged model, seed 61, base first. Both retain
the user's inference defaults, disabled carried knowledge, a 300-second work bound and existing startup
and confinement rules. Record the new executable, protocol, model and configuration hashes.

The purpose is to verify the clarified report format through the native workflow. Each attempt must finish
and pass protected tests to count as passing. Retain a failure without replacement. These two new attempts
do not establish an adapter gain and are reported separately from the original nine pairs. No further
training, checkpoint selection, scaling, default-model change or grading exception is part of this check.
