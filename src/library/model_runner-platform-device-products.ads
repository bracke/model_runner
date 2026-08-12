with Interfaces;

with Model_Runner.Numerics;

--  Matrix-vector products on a device.
--
--  One operation, because one is what an evaluation is made of: a matrix of
--  rows by columns against a vector of columns, giving a vector of rows.
--  Everything else the engine does is that, repeated.
--
--  An Engine holds what is expensive to make -- the pipeline, the layout,
--  the command pool -- and makes what is cheap per call. Buffers are cheap
--  and are made per call in this piece; keeping a model resident on the
--  device is what the piece after this one is for, and it is the difference
--  between a device that helps and one that spends its time being handed
--  the same weights again.
--
--  Availability. Everything here reports failure rather than raising. A
--  machine with no device, a driver that refuses, a shader that will not
--  load: each is a False, and the caller runs on the processor instead.
--
--  Arithmetic. The shader accumulates in binary32 where the processor's
--  kernels accumulate a row in binary64 and round once. The two agree to
--  the precision binary32 carries and not beyond it, which is a thing to
--  measure rather than to assume.
--
--  Task safety: an Engine belongs to one task. Two tasks wanting a device
--  want two engines.
package Model_Runner.Platform.Device.Products is

   --  Largest product this will attempt, in elements. A device states its
   --  own limits and they are larger than this; the bound is here so that a
   --  request the caller got wrong is refused rather than handed to a
   --  driver.
   Max_Elements : constant := 2 ** 28;

   --  What holds a device's pipeline for the product.
   type Engine is limited private;

   --  Prepare a device to compute products.
   --
   --  @param Item Engine to fill; released first.
   --  @param On Open device.
   --  @param Ready True when the device took the shader and the pipeline.
   procedure Open
     (Item  : in out Engine;
      On    : Context;
      Ready : out Boolean);

   --  Release everything the device was holding. Idempotent.
   --
   --  @param Item Engine to release.
   procedure Close (Item : in out Engine);

   --  Report whether an engine has a device behind it.
   --
   --  @param Item Engine to inspect.
   --  @return True when it is ready to compute.
   function Is_Ready (Item : Engine) return Boolean;

   --  One matrix-vector product.
   --
   --  Weights are read row by row, which is the layout every weight in this
   --  program already has: element (row, column) is at row * columns +
   --  column.
   --
   --  @param Item Ready engine.
   --  @param Weights Rows * Columns values, row by row.
   --  @param Vector Columns values.
   --  @param Rows Number of rows, which is the length of the result.
   --  @param Columns Number of columns.
   --  @param Target Receives Rows values.
   --  @param Key Where these weights live, which is what makes a second
   --    product with the same matrix cost nothing to set up. Null_Address
   --    keeps nothing, which is what a caller with a matrix it will not use
   --    again should pass.
   --  @param Ok True when the device computed it.
   procedure Multiply
     (Item    : in out Engine;
      Weights : Model_Runner.Numerics.Real_Array;
      Vector  : Model_Runner.Numerics.Real_Array;
      Rows    : Natural;
      Columns : Natural;
      Target  : out Model_Runner.Numerics.Real_Array;
      Ok      : out Boolean;
      Key     : System.Address := System.Null_Address);

   --  How many matrices the device is holding.
   --
   --  @param Item Engine to inspect.
   --  @return Count of matrices kept.
   function Resident (Item : Engine) return Natural;

private

   --  How many matrices one engine will keep. A model of a few dozen layers
   --  has some hundreds of them; past this the oldest are not evicted but
   --  the newest are simply not kept, which costs time and never
   --  correctness.
   Max_Resident : constant := 1024;

   type Held_Matrix is record
      Key    : System.Address := System.Null_Address;
      Buffer : System.Address := System.Null_Address;
      Memory : System.Address := System.Null_Address;
      Bytes  : Interfaces.Unsigned_64 := 0;
   end record;

   type Held_Array is array (1 .. Max_Resident) of Held_Matrix;

   type Engine is limited record
      --  The instance every entry point this engine uses is found through.
      --  An engine outlives no instance and each names its own.
      Instance : System.Address := System.Null_Address;

      --  The device this belongs to, and the queue work goes to. Copies of
      --  what the context holds: an engine outlives no context, and holding
      --  them saves reaching back through one on every call.
      Logical : System.Address := System.Null_Address;
      Queue   : System.Address := System.Null_Address;
      Family  : Natural := 0;
      Upload  : Natural := 0;

      --  Made once, in this order, and released in the reverse of it.
      Shader     : System.Address := System.Null_Address;
      Set_Layout : System.Address := System.Null_Address;
      Layout     : System.Address := System.Null_Address;
      Pipeline   : System.Address := System.Null_Address;
      Pool       : System.Address := System.Null_Address;
      Descriptor : System.Address := System.Null_Address;
      Commands   : System.Address := System.Null_Address;
      Buffer     : System.Address := System.Null_Address;
      Fence      : System.Address := System.Null_Address;

      --  The matrices this device is holding, and the two buffers that
      --  change every call.
      Kept       : Held_Array;
      Used       : Natural := 0;

      Vector_Buffer : System.Address := System.Null_Address;
      Vector_Memory : System.Address := System.Null_Address;
      Vector_Bytes  : Interfaces.Unsigned_64 := 0;

      Result_Buffer : System.Address := System.Null_Address;
      Result_Memory : System.Address := System.Null_Address;
      Result_Bytes  : Interfaces.Unsigned_64 := 0;
   end record;

end Model_Runner.Platform.Device.Products;
