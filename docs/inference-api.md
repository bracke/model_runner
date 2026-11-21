# Embedded inference API

`Model_Runner.Inference` is the supported in-process Ada boundary for one
local, schema-constrained completion without the command-line presentation or
model-selection layers. It owns the GGUF files, parsed container, prepared
model, worker pool, generation context and, when requested, the device. A
session can be reused sequentially. The status-bearing `Close` releases every
owned resource, reports the first cleanup failure, and joins worker tasks before
their storage is reclaimed. The parameterless overload raises on an operational
cleanup failure. Controlled finalization remains non-raising and best effort.

Embeddings import the named `model_runner_inference.gpr` project from the Alire
dependency solution. The underlying `inference/model_runner_inference.gpr` has
no main unit and does not pull CLI presentation into the embedding's source
closure. Inference and the task framework import one neutral core project; a
consumer may import both without assigning the shared Ada units to two project
views. Their source ownership comes from `build/model_runner_sources.gpr`, the
single list used by all three projects.

The neutral core has its own compiler profile because independently consumable
projects cannot impose conflicting switches on one imported project. It defaults
to `release`; development and validation builds can select
`-XMODEL_RUNNER_CORE_PROFILE=development` or `validation`. Each profile has a
separate object directory. The root `model_runner_test_support.gpr` exposes only
deterministic `Fixtures` and `Tiny_Model` units for downstream integration tests;
it is not a production project file.

`Open` accepts the backbone path and bounded `Open_Options`. The options expose
the runtime facilities that affect loading: explicit auxiliary GGUF files (for
separately distributed PLE/engram tensors), repacking and its panel cache,
context and cache layout, model/session limits, worker counts, cooperative
cancellation, and the device's index, memory budget, host-sharing policy and
patience. A progress observer can receive the same semantic preparation events
as the command-line application. Device sessions are exclusive because the
underlying runtime owns one global device queue: while one public session owns
that queue, the backend refuses every other `Open` request. Conversely, a
public session is refused while a direct backend user owns the queue. The
session holds an opaque lease, so an unrelated or stale closer cannot release
its acquisition. The low-level backend operations still require the package's
documented single-task discipline; they are engine internals, not an isolation
boundary for mutually untrusted code in one process. Closing the owner releases
the queue for a later session. Loading never resolves aliases or downloads a
model.

`Prepare` converts a JSON Schema to a reusable grammar. The overload of
`Complete` taking `Prepared_Schema` avoids compiling an invariant response
contract for every request; the string overload remains available for one-off
calls. `Complete` resets the context and runs synchronously on the calling task.
Its options bound tokens and returned bytes and carry an absolute deadline,
sampling configuration, progress observer, and cooperative cancellation token.
`Fill_Context` permits a response to use whatever context remains after the
prompt when its byte bound is not a useful token reservation; `Maximum_Tokens`
still caps generation. The result distinguishes complete output, incomplete token/context stops,
cancellation, timeout, bounded-output closure, and typed schema or engine
failure. `Completion_Ready` therefore means the engine reached a complete stop;
the embedding must still parse and validate the returned JSON value.

`Provenance` returns the canonical backbone path, declared model name,
architecture, engine fingerprint, byte total, and part count. `SHA256` is an
explicit potentially expensive operation over the exact joined model bytes;
`Open` never hashes the model implicitly. Hashing accepts cooperative
cancellation and reports `Hashing_Model` byte progress through the normal load
observer.

```ada
with Ada.Text_IO;
with Ada.Strings.Unbounded;
with Model_Runner.Errors;
with Model_Runner.Inference;

procedure Ask_Local_Model is
   package I renames Model_Runner.Inference;
   Session : I.Session;
   Status  : Model_Runner.Errors.Error_Info;
   Answer  : I.Completion;
   Schema  : I.Prepared_Schema;
begin
   I.Prepare (Schema, "{""type"":""integer""}", Status);
   if Model_Runner.Errors.Is_Error (Status) then
      return;
   end if;

   I.Open (Session, "/models/model.gguf", Status => Status);
   if Model_Runner.Errors.Is_Error (Status) then
      return;
   end if;

   I.Complete
     (Session, "Return a priority from one to three.",
      Schema,
      (Maximum_Tokens => 8, Maximum_Output_Bytes => 32, others => <>),
      Answer);
   if Answer.State = I.Completion_Ready then
      Ada.Text_IO.Put_Line (Ada.Strings.Unbounded.To_String (Answer.Text));
   end if;
end Ask_Local_Model;
```

The session is single-owner: do not call `Open`, `Complete`, or `Close`
concurrently and do not asynchronously abort the task while the engine owns
resources. Cancellation is the supported way to stop work. See
[Library API lifecycle](api-lifecycle.md) for the compatibility policy.
