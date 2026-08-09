with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.GGUF;
with Model_Runner.Numerics;

--  Synthetic GGUF construction.
--
--  Every mandatory test builds the model file it needs in memory. Nothing is
--  downloaded, nothing large is committed, and a malformed case is produced by
--  building a valid file and then editing one field, so the difference between
--  the accepted and the rejected input is exactly the thing under test.
--
--  Task safety: a Builder is used by one task.
package Fixtures is

   package B renames Model_Runner.Bytes;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;

   Max_Dimensions : constant := 4;

   type Dimension_List is array (Positive range <>) of G.U64;

   --  Accumulates metadata entries, tensor descriptors and tensor data, then
   --  assembles them into a well-formed container.
   type Builder is tagged limited private;

   --  Start a new file.
   --
   --  @param Item Builder to reset.
   --  @param Version Container version to write.
   --  @param Alignment Data-section alignment to write, or 0 to omit the
   --    general.alignment key and rely on the default.
   procedure Reset
     (Item      : in out Builder;
      Version   : G.U32 := 3;
      Alignment : G.U64 := 0);

   --  Append a string metadata entry.
   --
   --  @param Item Builder to extend.
   --  @param Key Metadata key.
   --  @param Value Metadata value.
   procedure Add_String (Item : in out Builder; Key, Value : String);

   --  Append an unsigned 32-bit metadata entry.
   --
   --  @param Item Builder to extend.
   --  @param Key Metadata key.
   --  @param Value Metadata value.
   procedure Add_U32
     (Item : in out Builder; Key : String; Value : Interfaces.Unsigned_32);

   --  Append an unsigned 64-bit metadata entry.
   --
   --  @param Item Builder to extend.
   --  @param Key Metadata key.
   --  @param Value Metadata value.
   procedure Add_U64
     (Item : in out Builder; Key : String; Value : Interfaces.Unsigned_64);

   --  Append a signed 32-bit metadata entry.
   --
   --  @param Item Builder to extend.
   --  @param Key Metadata key.
   --  @param Value Metadata value.
   procedure Add_I32
     (Item : in out Builder; Key : String; Value : Interfaces.Integer_32);

   --  Append a binary32 metadata entry.
   --
   --  @param Item Builder to extend.
   --  @param Key Metadata key.
   --  @param Value Metadata value.
   procedure Add_F32 (Item : in out Builder; Key : String; Value : N.Real);

   --  Append a boolean metadata entry.
   --
   --  @param Item Builder to extend.
   --  @param Key Metadata key.
   --  @param Value Metadata value.
   procedure Add_Bool (Item : in out Builder; Key : String; Value : Boolean);

   --  Begin a metadata array. Elements follow through the Element operations
   --  and the array is closed by End_Array.
   --
   --  @param Item Builder to extend.
   --  @param Key Metadata key.
   --  @param Element Element type.
   --  @param Count Number of elements that will be appended.
   procedure Begin_Array
     (Item    : in out Builder;
      Key     : String;
      Element : G.Value_Type;
      Count   : Natural);

   --  Append one string element to the open array.
   --
   --  @param Item Builder to extend.
   --  @param Value Element value.
   procedure String_Element (Item : in out Builder; Value : String);

   --  Append one signed 32-bit element to the open array.
   --
   --  @param Item Builder to extend.
   --  @param Value Element value.
   procedure Int32_Element
     (Item : in out Builder; Value : Interfaces.Integer_32);

   --  Append one unsigned 64-bit element to the open array.
   --
   --  Values above Long_Long_Integer'Last are writable on purpose: a reader
   --  has to refuse them, and it cannot be shown doing so unless a fixture
   --  can hold one.
   --
   --  @param Item Builder to extend.
   --  @param Value Element value.
   procedure UInt64_Element
     (Item : in out Builder; Value : Interfaces.Unsigned_64);

   --  Append one binary32 element to the open array.
   --
   --  @param Item Builder to extend.
   --  @param Value Element value.
   procedure Float_Element (Item : in out Builder; Value : N.Real);

   --  Close the open array.
   --
   --  @param Item Builder to extend.
   procedure End_Array (Item : in out Builder);

   --  Append a tensor descriptor and its data.
   --
   --  Dimensions are given in GGUF order, contiguous dimension first. Data
   --  must already be encoded in the requested format.
   --
   --  @param Item Builder to extend.
   --  @param Name Tensor name.
   --  @param Dimensions Dimension lengths.
   --  @param Format Tensor element format.
   --  @param Data Encoded tensor bytes.
   procedure Add_Tensor
     (Item       : in out Builder;
      Name       : String;
      Dimensions : Dimension_List;
      Format     : G.Tensor_Type;
      Data       : B.Byte_Array);

   --  Assemble the file.
   --
   --  @param Item Builder holding the accumulated content.
   --  @param Result Newly allocated file bytes; the caller frees them.
   procedure Build (Item : in out Builder; Result : out B.Byte_Array_Access);

   --  Encode binary32 values.
   --
   --  @param Values Values to encode.
   --  @return Little-endian bytes.
   function Encode_F32 (Values : N.Real_Array) return B.Byte_Array;

   --  Quantize values to Q8_0 blocks.
   --
   --  Thirty-two elements to a block: one half-precision scale, then the
   --  values divided by it and rounded to signed bytes. The scale is the
   --  largest magnitude in the block over 127, which is what the format's
   --  producers use, so a fixture built here is shaped like a real one.
   --
   --  @param Values Values to quantize; the length must be a multiple of 32.
   --  @return Encoded block bytes.
   function Encode_Q8_0 (Values : N.Real_Array) return B.Byte_Array;

   --  Encode values as Q4_K: superblocks of 256, eight sub-blocks of
   --  thirty-two, each with a six-bit scale and a six-bit minimum packed
   --  twelve bytes to the superblock, and one four-bit quant per element.
   --
   --  Written so that the fixture can carry a k-quant at all. The fixture
   --  built binary32 and Q8_0, so conformance measured every claim about
   --  quantized weights -- including what repacking to brain floats costs --
   --  from those two alone, while the formats a real model uses most were
   --  reachable only through a file nobody can commit.
   --
   --  The packing is the inverse of what Quantization decodes, and a test
   --  holds it to that: encode, decode with the engine's own reader, and the
   --  values must return within what four bits can carry.
   --
   --  @param Values Values to encode; a whole number of 256-element blocks.
   --  @return The encoded bytes.
   function Encode_Q4_K (Values : N.Real_Array) return B.Byte_Array;

   --  Encode values as Q2_K: superblocks of 256, sixteen sub-blocks of
   --  sixteen, each with a four-bit scale and a four-bit minimum sharing a
   --  byte, and two bits an element.
   --
   --  Two bits name four levels, so this is the format that leans hardest on
   --  its scales and the one where repacking to brain floats buys most --
   --  and it was as unreachable from here as Q4_K was.
   --
   --  @param Values Values to encode; a whole number of 256-element blocks.
   --  @return The encoded bytes.
   function Encode_Q2_K (Values : N.Real_Array) return B.Byte_Array;

   --  Encode binary16 values.
   --
   --  @param Values Values to encode.
   --  @return Little-endian bytes.
   function Encode_F16 (Values : N.Real_Array) return B.Byte_Array;

   --  Deterministic pseudo-random weights derived from a fixed integer
   --  sequence, so that a fixture has the same contents on every host.
   --
   --  @param Count Number of values.
   --  @param Seed Sequence seed.
   --  @param Scale Largest magnitude produced.
   --  @return Generated values indexed from 0.
   function Sequence
     (Count : N.Element_Count;
      Seed  : Interfaces.Unsigned_64;
      Scale : N.Real := 1.0) return N.Real_Array;

   ---------------------------------------------------------------------------
   --  Editing a built image
   ---------------------------------------------------------------------------

   --  A field the builder wrote, which a test may want to make wrong.
   --
   --  Some refusals cannot be reached by building a container, only by
   --  writing one and then changing a field: a value type the format does not
   --  define, a tensor whose data overlaps its neighbour, an offset that is
   --  not aligned. The builder writes correct files by construction, so the
   --  fault has to be introduced afterwards -- and doing that with counted
   --  byte offsets makes a test that breaks whenever the layout moves.
   --
   --  The builder therefore records where it put each of these, and a test
   --  asks for the position by name.
   type Field_Name is
     (Metadata_Value_Type,
      Array_Element_Type,
      String_Value_Length,
      Tensor_Format,
      Tensor_Extent,
      Tensor_Offset);

   --  Where a field lies in the image Build produced.
   --
   --  @param Item Builder that produced the image.
   --  @param Field Which field.
   --  @param Owner Which metadata entry or tensor, counting from one.
   --  @param Axis Which extent, for Tensor_Extent, counting from one.
   --  @return Offset from the start of the image, or zero when the builder
   --    wrote no such field.
   function Field_Position
     (Item  : Builder;
      Field : Field_Name;
      Owner : Positive;
      Axis  : Positive := 1) return B.Byte_Count;

   --  Overwrite a 32-bit field in a built image.
   --
   --  @param Image Image to edit in place.
   --  @param At_Offset Offset from the start of the image.
   --  @param Value Value to write, little-endian as the format requires.
   procedure Poke_U32
     (Image     : in out B.Byte_Array;
      At_Offset : B.Byte_Count;
      Value     : Interfaces.Unsigned_32);

   --  Overwrite a 64-bit field in a built image.
   --
   --  @param Image Image to edit in place.
   --  @param At_Offset Offset from the start of the image.
   --  @param Value Value to write, little-endian as the format requires.
   procedure Poke_U64
     (Image     : in out B.Byte_Array;
      At_Offset : B.Byte_Count;
      Value     : Interfaces.Unsigned_64);

private

   type Byte_Buffer is record
      Data : B.Byte_Array_Access := null;
      Used : B.Byte_Count := 0;
   end record;

   --  Where the builder put a field, before the sections are joined.
   type Section is (In_Metadata, In_Descriptors);

   type Mark is record
      Where : Section := In_Metadata;
      Field : Field_Name := Metadata_Value_Type;
      Owner : Natural := 0;
      Axis  : Natural := 0;
      At_Offset : B.Byte_Count := 0;
   end record;

   Max_Marks : constant := 256;

   type Mark_List is array (1 .. Max_Marks) of Mark;

   type Builder is tagged limited record
      Version        : G.U32 := 3;
      Alignment      : G.U64 := 0;
      Metadata       : Byte_Buffer;
      Metadata_Count : Natural := 0;
      Descriptors    : Byte_Buffer;
      Tensor_Count   : Natural := 0;
      Tensor_Data    : Byte_Buffer;
      Array_Open     : Boolean := False;
      Marks          : Mark_List;
      Marks_Used     : Natural := 0;
   end record;

end Fixtures;
