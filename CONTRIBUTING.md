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

## Building and testing

```
alr build
cd tests && alr build && ./bin/tests test
```
