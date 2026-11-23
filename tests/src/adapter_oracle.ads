with Interfaces;
with Model_Runner.Errors;

--  Test-only binary64 reference. No production tensor, backend or merger arithmetic is used.
package Adapter_Oracle is

   subtype Number is Interfaces.IEEE_Float_64;
   type Vector is array (Natural range <>) of Number;
   type Matrix is array (Natural range <>, Natural range <>) of Number;

   Max_Width : constant := 32_768;
   Max_Rank : constant := 64;
   Max_Elements : constant := 2 ** 21;
   Max_Products : constant := 2 ** 24;
   Absolute_Tolerance : constant Number := 1.0E-5;
   Relative_Tolerance : constant Number := 2.0E-5;

   --  Failure preserves Into. Bounds may start anywhere; indices are matched by position.
   --  @param Weight Decoded base matrix, output rows by input columns.
   --  @param Input One input vector.
   --  @param Into Receives the binary64 base projection on success.
   --  @param Status Shape, reference-limit or non-finite error; Success otherwise.
   procedure Project
     (Weight : Matrix; Input : Vector; Into : in out Vector;
      Status : out Model_Runner.Errors.Error_Info);

   --  Expand B*A before multiplying x, independently of the proposed B*(A*x) implementation.
   --  Nonzero rank <=64, widths <=32768, base <=2**21 elements and <=2**24 expanded products per call.
   --  A large projection can be checked one output row at a time. Binary32 operands are within the reference's
   --  magnitude bound (1E40); an accumulated result may be up to 1E240 before the next addition.
   --  Failure preserves Into, including signed zeros.
   --  @param Down Rank rows by input columns, GGUF lora_a.
   --  @param Up Output rows by rank columns, GGUF lora_b.
   --  @param Input The same input read by the base projection.
   --  @param Scale Positional adapter scale, including zero and negative values.
   --  @param Alpha Stored alpha, nonnegative when present; zero uses Scale alone.
   --  @param Alpha_Present Whether alpha was stored; absent alpha uses Scale alone.
   --  @param Into Base projection plus all previously accumulated adapters.
   --  @param Status Shape, reference-limit or non-finite error; Success otherwise.
   procedure Accumulate
     (Down, Up : Matrix; Input : Vector; Scale, Alpha : Number; Alpha_Present : Boolean;
      Into : in out Vector; Status : out Model_Runner.Errors.Error_Info);

end Adapter_Oracle;
