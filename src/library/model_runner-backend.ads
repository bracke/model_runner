with Model_Runner.GGUF;

--  Execution-backend capabilities.
--
--  A backend states what it can do before a model is prepared against it, so
--  that an unsupported combination is rejected during preparation rather than
--  discovered part way through a token. V1 has exactly one backend, the Ada
--  CPU backend in the child package, and it is mandatory: there is no GPU
--  backend and none is required.
--
--  Task safety: capabilities are an immutable value.
package Model_Runner.Backend is

   --  Stable backend identifiers. Never localized; they appear in diagnostics
   --  and in the support matrix as identifiers.
   type Backend_Kind is (Backend_CPU);

   --  Name of a backend.
   --
   --  @param Item Backend to name.
   --  @return Lower-case identifier such as "cpu".
   function Backend_Name (Item : Backend_Kind) return String
   is (case Item is when Backend_CPU => "cpu");

   type Format_Support is array (Model_Runner.GGUF.Tensor_Type) of Boolean;

   --  What a backend implements.
   --
   --  Every field here is asked by something. That is a rule and not an
   --  observation: this record began as eleven fields describing a backend to
   --  nobody, and a description nobody consults is one that can be wrong for
   --  a year -- Supports_Batched said False while every prefill batched
   --  through Dispatch_Batch, and nothing noticed because nothing asked.
   --
   --  Five fields were removed rather than wired, because nothing could act
   --  on them: whether accumulation is wide, whether mapped storage is
   --  usable, whether quantized formats are (which Formats already answers
   --  per format), whether noncontiguous views are, and whether results are
   --  independent of the worker count. Each could only ever have held one
   --  value in this build, and a flag with one value documents nothing. A
   --  backend that makes one of them a real question brings its field back
   --  along with the code that reads it.
   type Capabilities is record
      Kind : Backend_Kind := Backend_CPU;

      --  Tensor formats the backend can read directly. Asked per tensor while
      --  a model loads.
      Formats : Format_Support := [others => False];

      --  Alignment the backend needs from tensor storage, in bytes. Asked of
      --  every tensor offset while a model loads.
      Alignment : Positive := 4;

      --  Whether the backend can multiply a matrix by a vector at all, which
      --  is the whole of what evaluation asks of it. Asked once, when a model
      --  is prepared.
      Supports_Matrix_Vector : Boolean := True;

      --  Whether several vectors can share one reading of the weights. Asked
      --  when a batch is evaluated.
      Supports_Batched : Boolean := False;

      --  Whether more than one worker can be used. Asked when the worker
      --  count is chosen.
      Supports_Parallel : Boolean := False;

      --  Largest worker count the backend accepts. Asked when the worker
      --  count is chosen.
      Max_Workers : Positive := 1;
   end record;

   --  Report whether a backend can read a tensor format.
   --
   --  @param Item Capabilities to query.
   --  @param Format Tensor format.
   --  @return True when the backend implements the format.
   function Supports
     (Item   : Capabilities;
      Format : Model_Runner.GGUF.Tensor_Type) return Boolean
   is (Item.Formats (Format));

end Model_Runner.Backend;
