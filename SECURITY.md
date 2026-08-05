# Security

## Threat model

`model_runner` treats every one of the following as untrusted input:

- GGUF files, including metadata, tensor descriptors, tokenizer definitions
  and embedded chat templates
- Prompt files and standard input
- Command-line values and environment variables

The engine defends against integer and offset overflow, excessive counts and
allocations, invalid UTF-8, overlapping tensor ranges, invalid quantization
block structure, and unbounded recursion or iteration driven by file content.
No compatibility mode disables a bounds or integrity check.

Model files are opened read-only and are never modified. Embedded metadata and
templates never cause additional file access: only explicitly supplied paths
are opened.

### Suppressed checks in the numeric kernels

The innermost loops of `Model_Runner.Quantization` -- the ones that unpack a
quantized block and the ones that multiply it -- run under
`pragma Suppress (Index_Check, Range_Check, Overflow_Check)`. This is stated
here rather than buried, because it is the one place where a validation
mistake would become memory unsafety instead of a clean `Constraint_Error`.

Why: each check is a call the optimizer must treat as touching memory, so it
cannot prove the iterations independent, and the loops do not vectorize at all
with the checks in place. Unpacking is the larger half of a quantized row's
cost, so this is worth doing there and nowhere else.

What makes it safe:

- The suppression is scoped to those loops. It is not a build profile, not a
  command-line option, and not reachable by anything a file can say. Nothing a
  user or a model can set turns it on or off.
- Every range the loops touch is validated immediately before them, once per
  span instead of once per element: the packed bytes against `Has_Room`, the
  output against `Target'Length`, and the input vectors against an explicit
  bound that `Accumulate_Dot` now checks itself rather than trusting its
  callers to have checked.
- The parsing, validation and preparation layers are unaffected and keep every
  check. Nothing derived from a file reaches these loops without having been
  bounds-checked first.
- `tests fuzz` drives malformed containers through the whole path. Three
  thousand mutation cases across six seeds produce no escaped exception and no
  invalid acceptance.

The stated guarantee is unchanged: no compatibility mode, option or file
content disables a bounds or integrity check.

## Privacy

Inference is local only. The crate opens no network connection, starts no
process, sends no telemetry, and does not fall back to a remote service. Prompt
text, system messages, generated output and conversation history are not logged
and are not persisted.

Command-line prompt text may be visible to other local processes through the
process table. Use a prompt file or standard input for sensitive data.

## Reporting

Report suspected vulnerabilities to bent@bracke.dk.
