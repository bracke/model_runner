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
   type Capabilities is record
      Kind : Backend_Kind := Backend_CPU;

      --  Tensor formats the backend can read directly.
      Formats : Format_Support := [others => False];

      --  Whether accumulation happens in the wide format. Every kernel in this
      --  crate accumulates length-dependent reductions in Wide_Real, so a
      --  result never depends on how the work was partitioned.
      Wide_Accumulation : Boolean := True;

      --  Alignment the backend needs from tensor storage, in bytes.
      Alignment : Positive := 4;

      Supports_Matrix_Vector : Boolean := True;
      Supports_Batched       : Boolean := False;
      Supports_Noncontiguous : Boolean := False;
      Supports_Mapping       : Boolean := True;
      Supports_Quantized     : Boolean := True;

      --  Whether more than one worker can be used.
      Supports_Parallel : Boolean := False;

      --  Whether results are independent of the worker count. This crate only
      --  offers deterministic partitioning, so it is always True.
      Deterministic : Boolean := True;

      --  Largest worker count the backend accepts.
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
