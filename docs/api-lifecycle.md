# Library API lifecycle

`model_runner` keeps its public Ada surface intentional. The repository gate
checks every exported operation that the executable does not use against the
documented `Library_Surface` registry, in both directions. An operation cannot
become public merely because a test happens to call it.

The pre-1.0 crate may still remove accidental exports. Compatibility code for
old persisted records belongs at the reader of those records, not in a public
configuration package: otherwise callers can create new data under an obsolete
contract. The legacy verification-fingerprint calculation therefore remains an
internal evidence-reader migration and is no longer a public operation.

Public runtime contracts follow these rules:

* add a new operation only for an embedding caller, not to share code between
  implementation units;
* keep persisted format versions separate from the crate version;
* reject removed or unknown serialized versions explicitly;
* retain compatibility readers only while repository fixtures exercise them;
* remove deprecated entry points instead of maintaining two names indefinitely;
* record intentionally command-unused exports in `Library_Surface` with their
  embedding use case.

This mirrors the useful part of a 1.0 cleanup: one supported route for each
operation, explicit version boundaries, and compatibility logic that cannot be
mistaken for the current API.
