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

private

   type Byte_Buffer is record
      Data : B.Byte_Array_Access := null;
      Used : B.Byte_Count := 0;
   end record;

   type Builder is tagged limited record
      Version        : G.U32 := 3;
      Alignment      : G.U64 := 0;
      Metadata       : Byte_Buffer;
      Metadata_Count : Natural := 0;
      Descriptors    : Byte_Buffer;
      Tensor_Count   : Natural := 0;
      Tensor_Data    : Byte_Buffer;
      Array_Open     : Boolean := False;
   end record;

end Fixtures;
