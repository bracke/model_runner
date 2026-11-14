# Contributing

## Rules that are not negotiable

- Ada 2022 only. No shell, Python, Perl, Ruby, JavaScript, Make or CMake
  tooling; every project-owned tool is an Ada program in the `tests` crate.
- Lines are at most 120 characters.
- No package below the presentation layer may write to standard output or
  standard error, depend on the message catalog, or depend on terminal styling.
- Expected operational failures are reported as `Model_Runner.Errors.Error_Info`
  values. Exceptions are for defects, and are contained at the highest safe
  boundary.
- Untrusted input is validated with explicit bounds checks, never with
  assertions.
- A feature is *supported* only when it has a production implementation,
  structural validation, runtime execution, structured error handling, AUnit
  coverage and documentation. Parsing an identifier is not support.
- Do not describe planned functionality as implemented, in code comments, in
  the README or in a commit message.

## Adding a diagnostic code

Append the literal at the end of its domain group in
`Model_Runner.Errors.Error_Code`. Never reorder or remove one: the published
`MR-DOMAIN-NNNN` ordinal is the literal's position within its group, and the
catalog key is derived from its name.

## Formatting a message

A catalog entry is one line. Within it, `Model_Runner.Markup` reads a little
markup:

- `\n` breaks the line; a line that begins `- ` is a list item.
- `**words**` is bold, `*words*` italic, `` `words` `` code (nothing inside
  code is markup).
- `\\`, `\*` and `` \` `` are the character itself.

A marker opens only where text follows it and closes only where text comes
before it, on the same line, so a glob's asterisks (`a * stands for`,
`specs/*/requirements.md`) stay as they are. At a terminal that shows colour
the markup is drawn as styles and items get a bullet, wrapped under their own
text; elsewhere it is plain text and items keep their hyphen. Arguments are
never markup: they go in after the markup is read. A message whose lines or
items differ in number between locales fails the suite.

## Building and testing

```
alr build
cd tests && alr build && ./bin/tests test
```
