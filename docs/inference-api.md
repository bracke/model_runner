# Embedded inference API

`Model_Runner.Inference` is the supported in-process Ada boundary for one
local, schema-constrained completion without the command-line presentation or
model-selection layers. It owns the GGUF files, parsed container, prepared
model, worker pool, generation context and, when requested, the device. A
session can be reused sequentially; `Close` and controlled finalization release
the resources in dependency order.

`Open` accepts the backbone path and bounded `Open_Options`. The options expose
the runtime facilities that affect loading: explicit auxiliary GGUF files (for
separately distributed PLE/engram tensors), repacking and its panel cache,
context and cache layout, model/session limits, worker counts, cooperative
cancellation, and the device's index, memory budget, host-sharing policy and
patience. Device sessions are exclusive because the underlying runtime owns one
global device queue. Loading never resolves aliases or downloads a model.

`Complete` resets the context, converts the supplied JSON Schema to a grammar,
and runs synchronously on the calling task. Its options bound tokens and
returned bytes and carry an absolute deadline, sampling configuration and a
cooperative cancellation token. The result distinguishes ordinary completion,
cancellation, timeout, bounded-output closure, and typed schema or engine
failure. An ordinary `Maximum_Tokens` stop does not assert that the returned
text is a complete JSON value; the embedding must parse and validate it.

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
begin
   I.Open (Session, "/models/model.gguf", Status => Status);
   if Model_Runner.Errors.Is_Error (Status) then
      return;
   end if;

   I.Complete
     (Session, "Return a priority from one to three.",
      "{""type"":""integer""}",
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
