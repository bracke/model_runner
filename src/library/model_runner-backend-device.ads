with Interfaces;

with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

--  The backend that runs on a device.
--
--  It computes the one operation an evaluation is made of -- a matrix
--  against a vector -- on whatever compute device the host has, and it is
--  refused work it cannot take rather than approximating it.
--
--  Binary32 only. A weight on a device is a run of binary32 values, because
--  that is what the shader reads; every other format this program decodes is
--  packed bits with a scale, and decoding those on a device is a shader per
--  format and a piece of work of its own. So this backend declares one
--  format, the per-tensor check the loader already makes refuses a model
--  that carries anything else, and `--repack f32` is what makes a quantized
--  model usable here. That costs four bytes a weight, which is the bargain
--  that flag already publishes.
--
--  Availability. A machine with no device, or a device that will not take
--  the shader, reports itself unready. A caller that asked for this backend
--  is told so rather than quietly given another one: choosing a backend is a
--  decision, and silently substituting would make it a suggestion.
--
--  One device, opened once. A second call to Open on an open backend is the
--  same device; Close gives back everything the device is holding, which is
--  every weight of the model that was run on it.
--
--  Task safety: one task at a time. The device is a single queue and this
--  makes no attempt to feed it from several.
package Model_Runner.Backend.Device is

   --  What this backend can do.
   --
   --  @return The capability record.
   function Describe return Capabilities;

   --  Open the first device the host names.
   --
   --  @param Ready True when a device took the shader and is ready for work.
   --  @param Budget Bytes of device memory the model's matrices may take, or
   --    zero for the share of the device's own heap the product engine
   --    chooses. What does not fit is given back and uploaded again when it
   --    is next wanted, so a budget is a speed decision rather than a limit
   --    on what will run.
   --  @param Share_Host Whether to read the weights where they lie rather
   --    than copy them to the device. It holds the model once instead of
   --    twice and runs slower, measurably; the statistics report how many
   --    matrices it applied to.
   --  @param Slice How long one wait for the device lasts before a stop
   --    request is asked about again.
   --  @param Patience How long to wait in all before giving up on a device
   --    that has stopped answering. Zero waits not at all.
   --  @param Which Which of the host's devices to open, counting from one in
   --    the order the host names them -- which is the order `inspect` lists
   --    them in. Out of range is a refusal rather than a fallback: a caller
   --    that named a device and got another one would be told the wrong
   --    thing about what ran.
   procedure Open
     (Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False;
      Slice      : Duration := 0.020;
      Patience   : Duration := 60.0;
      Which      : Positive := 1);

   --  Release the device and everything it holds. Idempotent.
   procedure Close;

   --  Slices the last product spent waiting for the device.
   --
   --  One is a product answered inside the first slice, which is what every
   --  product on this machine is. More says the wait went round and asked
   --  whether the caller wanted to stop.
   --
   --  @return Slices taken by the last product, or zero before any.

   function Waited return Natural;

   --  How many queues the open device's family offers.
   --
   --  The engine submits to one and waits on it. Whether it could submit to
   --  two is a fact about the host rather than a plan, and a run that used a
   --  device says what it found rather than leaving the number where only a
   --  test can see it.
   --
   --  @return Queues the family has, or zero when no device is open.
   function Queues return Natural;

   --  Give back every matrix the device holds, and stay open.
   --
   --
   --  Called when a model closes, because a resident matrix is remembered by
   --  where its bytes lie: once that storage is freed, another matrix of the
   --  same shape and format can take the address and the device would answer
   --  for the second with the first one's weights. Safe to call with no
   --  device, or with one holding nothing.
   procedure Forget_Matrices;

   --  Report whether a device is open and ready.
   --
   --  @return True when Dispatch can succeed.
   function Is_Ready return Boolean;

   --  What the device is called, for a report.
   --
   --  @return The device's own name, or an empty string when none is open.
   function Name return String;

   --  How many of a model's matrices the device is holding.
   --
   --  A model handed over once stays there; this is how much of it has
   --  arrived. It is what tells a reader that the device is computing rather
   --  than being handed the same weights again.
   --
   --  @return Count of matrices resident.
   function Resident return Natural;

   --  How many bytes of the model the device is holding.
   --
   --  @return Bytes resident.
   function Resident_Bytes return Interfaces.Unsigned_64;

   --  How many matrices the device is reading where they already are.
   --
   --  @return Count taken rather than copied.
   function Imported return Natural;

   --  How many matrices have been given back to make room for others.
   --
   --  Zero for a model the device can hold. A number that rises with every
   --  token means the model does not fit and is being uploaded again as it
   --  is needed, which is correct and slow.
   --
   --  @return Count of matrices released to make room.
   function Given_Back return Natural;

   --  One matrix-vector product, on the device.
   --
   --  @param Weight Weight view; must be binary32.
   --  @param Vector Input vector of Weight's column count.
   --  @param Target Receives Weight's row count.
   --  @param Cancel Stop request to watch, or null for none. Asked before
   --    anything reaches the device and between slices of the wait for it
   --    to finish; answered with Generation_Cancelled once the dispatch is
   --    done there, which it must be, because a dispatch cannot be taken
   --    back and its buffers belong to the device until the fence says
   --    otherwise. Cancellation is checked between layers everywhere else
   --    in this program, and a layer on a device is these waits, so a wait
   --    that could not be interrupted was the longest a stop request went
   --    unanswered.
   --  @param Status Success, Backend_Unsupported_Format when the view is not
   --    binary32, Lifecycle_Invalid_State when no device is open, or
   --    Tensor_Shape_Mismatch.
   procedure Dispatch
     (Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Target : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null);

   --  Three products of the same activation, in one submission.
   --
   --  A layer's queries, keys and values are three matrices read against one
   --  normalized input, and nothing between them waits for anything. Sent one
   --  at a time they cost three uploads of that input, three command buffers,
   --  three submissions and three fence waits; sent together they cost one of
   --  each and three dispatches. This is the entry point that says they may
   --  go together -- it is not a general batching facility, it is the shape
   --  attention actually has.
   --
   --  The three matrices must agree about how wide the activation is, which
   --  they do by construction: they all read the same one. They may differ in
   --  every other way, and for the architectures that fuse them into one
   --  tensor they are three views of it.
   --
   --  A caller with no device, or one whose device refuses, gets the same
   --  diagnostics the single dispatch gives.
   --
   --  @param First Matrix for the queries.
   --  @param Second Matrix for the keys.
   --  @param Third Matrix for the values.
   --  @param Vector The activation all three read.
   --  @param Into_First Receives the queries.
   --  @param Into_Second Receives the keys.
   --  @param Into_Third Receives the values.
   --  @param Status Success, or why not.
   --  @param Cancel Token a caller may set to ask for a stop.
   procedure Dispatch_Three
     (First       : Model_Runner.Tensors.View;
      Second      : Model_Runner.Tensors.View;
      Third       : Model_Runner.Tensors.View;
      Vector      : Model_Runner.Tensors.Real_Array_Access;
      Into_First  : Model_Runner.Tensors.Real_Array_Access;
      Into_Second : Model_Runner.Tensors.Real_Array_Access;
      Into_Third  : Model_Runner.Tensors.Real_Array_Access;
      Status      : out Model_Runner.Errors.Error_Info;
      Cancel      : Model_Runner.Cancellation.Token_Reference := null);

   --  The same product for each vector of a batch.
   --
   --  A batch of one is what the evaluator hands a backend that says it does
   --  not batch, and it still comes through this path. So this is not a
   --  refusal but a loop: one whole product per vector, which is the saving
   --  this backend declines to make and the reason it reports that it does
   --  not batch.
   --
   --  @param Weight Weight view; must be binary32.
   --  @param Vectors Count vectors of Weight's column count, one after
   --    another.
   --  @param Count How many.
   --  @param Target Receives Count results of Weight's row count.
   --  @param Cancel Stop request to watch, or null for none, as in Dispatch.
   --  @param Status Success, or what one product would have said.
   procedure Dispatch_Batch
     (Weight  : Model_Runner.Tensors.View;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info;
      Cancel  : Model_Runner.Cancellation.Token_Reference := null);

private

   subtype Real_Array is Model_Runner.Numerics.Real_Array;

end Model_Runner.Backend.Device;
