with Interfaces;

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
   procedure Open
     (Ready      : out Boolean;
      Budget     : Interfaces.Unsigned_64 := 0;
      Share_Host : Boolean := False);

   --  Release the device and everything it holds. Idempotent.
   procedure Close;

   --  Give back every matrix the device holds, and stay open.
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
   --  @param Status Success, Backend_Unsupported_Format when the view is not
   --    binary32, Lifecycle_Invalid_State when no device is open, or
   --    Tensor_Shape_Mismatch.
   procedure Dispatch
     (Weight : Model_Runner.Tensors.View;
      Vector : Model_Runner.Tensors.Real_Array_Access;
      Target : Model_Runner.Tensors.Real_Array_Access;
      Status : out Model_Runner.Errors.Error_Info);

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
   --  @param Status Success, or what one product would have said.
   procedure Dispatch_Batch
     (Weight  : Model_Runner.Tensors.View;
      Vectors : Model_Runner.Tensors.Real_Array_Access;
      Count   : Model_Runner.Numerics.Element_Count;
      Target  : Model_Runner.Tensors.Real_Array_Access;
      Status  : out Model_Runner.Errors.Error_Info);

private

   subtype Real_Array is Model_Runner.Numerics.Real_Array;

end Model_Runner.Backend.Device;
