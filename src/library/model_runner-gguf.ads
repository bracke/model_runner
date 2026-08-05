with Interfaces;

with Model_Runner.Bytes;

--  GGUF container vocabulary: versions, metadata value types and tensor
--  element types.
--
--  This package holds the facts about the format, not the parsing logic. It is
--  the single place that maps a numeric code in a file to a name this crate
--  understands, and the single place that states how many elements a
--  quantization block holds and how many bytes it occupies.
--
--  Recognition is not support. To_Tensor_Type distinguishes three outcomes: a
--  code this crate implements, a code the format defines but this crate does
--  not implement, and a code that is not a GGML tensor type at all. Only the
--  first is ever accepted into an executable model.
--
--  Task safety: everything here is a pure function over static tables.
package Model_Runner.GGUF is

   subtype U32 is Interfaces.Unsigned_32;
   subtype U64 is Interfaces.Unsigned_64;

   --  The four magic bytes "GGUF" read as a little-endian 32-bit value.
   Magic : constant U32 := 16#4655_4747#;

   --  Container versions this crate parses. Version 1 used 32-bit counts and a
   --  different tensor-descriptor layout and is deliberately not accepted.
   Minimum_Version : constant U32 := 2;
   Maximum_Version : constant U32 := 3;

   --  Alignment applied to the tensor data section when the file does not
   --  state one through general.alignment.
   Default_Alignment : constant U64 := 32;

   --  Largest tensor rank GGUF can express.
   Max_Rank : constant := 4;

   ---------------------------------------------------------------------------
   --  Metadata value types
   ---------------------------------------------------------------------------

   --  Metadata value kinds, in GGUF code order.
   type Value_Type is
     (Value_UInt8,
      Value_Int8,
      Value_UInt16,
      Value_Int16,
      Value_UInt32,
      Value_Int32,
      Value_Float32,
      Value_Bool,
      Value_String,
      Value_Array,
      Value_UInt64,
      Value_Int64,
      Value_Float64);

   --  Numeric code a value type is written as.
   --
   --  @param Item Value type.
   --  @return GGUF code.
   function Value_Code (Item : Value_Type) return U32
   is (Value_Type'Pos (Item));

   --  Decode a metadata value-type code.
   --
   --  @param Code Code read from the file.
   --  @param Known True when the code names a defined value type.
   --  @return Decoded type; Value_UInt8 when Known is False.
   function To_Value_Type (Code : U32; Known : out Boolean) return Value_Type;

   --  Serialized size of a scalar metadata value.
   --
   --  @param Item Value type.
   --  @return Size in bytes; 0 for Value_String and Value_Array, whose sizes
   --    depend on their contents.
   function Scalar_Size (Item : Value_Type) return Model_Runner.Bytes.Byte_Count;

   --  Report whether a value type may appear as a metadata array element.
   --
   --  Arrays of arrays are not part of the format and are rejected.
   --
   --  @param Item Candidate element type.
   --  @return True when the type is a legal array element type.
   function Is_Valid_Array_Element (Item : Value_Type) return Boolean
   is (Item /= Value_Array);

   --  Report whether a value type holds an integer.
   --
   --  @param Item Value type.
   --  @return True for the signed and unsigned integer types.
   function Is_Integer (Item : Value_Type) return Boolean
   is (Item in Value_UInt8 .. Value_Int32
       or else Item in Value_UInt64 .. Value_Int64);

   --  Report whether a value type holds a floating-point number.
   --
   --  @param Item Value type.
   --  @return True for Value_Float32 and Value_Float64.
   function Is_Float (Item : Value_Type) return Boolean
   is (Item = Value_Float32 or else Item = Value_Float64);

   ---------------------------------------------------------------------------
   --  Tensor element types
   ---------------------------------------------------------------------------

   --  Tensor element formats this crate names.
   --
   --  Type_Unknown covers every code that is not one of the listed formats,
   --  including codes that a future GGML release may define.
   type Tensor_Type is
     (Type_F32,
      Type_F16,
      Type_Q4_0,
      Type_Q4_1,
      Type_Q5_0,
      Type_Q5_1,
      Type_Q8_0,
      Type_Q8_1,
      Type_Q2_K,
      Type_Q3_K,
      Type_Q4_K,
      Type_Q5_K,
      Type_Q6_K,
      Type_Q8_K,
      Type_BF16,
      Type_Unknown);

   --  Decode a tensor type code.
   --
   --  @param Code Code read from the file.
   --  @param Known True when the code names a format this crate can name.
   --  @return Decoded format; Type_Unknown when Known is False.
   function To_Tensor_Type (Code : U32; Known : out Boolean) return Tensor_Type;

   --  Numeric code a tensor type is written as.
   --
   --  @param Item Tensor type.
   --  @return GGML code; U32'Last for Type_Unknown.
   function Tensor_Code (Item : Tensor_Type) return U32;

   --  Report whether this crate implements a format end to end.
   --
   --  A format is supported only when it has structural validation, a
   --  reference dequantizer, a reference dot product, golden vectors and
   --  differential tests. Naming a format is not supporting it.
   --
   --  @param Item Tensor type.
   --  @return True when the format is implemented and tested.
   function Is_Supported (Item : Tensor_Type) return Boolean;

   --  Number of elements in one block of a format.
   --
   --  @param Item Tensor type.
   --  @return Elements per block; 1 for the unquantized formats.
   function Block_Elements (Item : Tensor_Type) return U64;

   --  Serialized size of one block of a format.
   --
   --  @param Item Tensor type.
   --  @return Bytes per block; 0 for Type_Unknown.
   function Block_Bytes (Item : Tensor_Type) return U64;

   --  Stable machine-readable name of a format, such as "Q4_K".
   --
   --  Never localized: it appears in the support matrix, in diagnostics and in
   --  inspection output as an identifier.
   --
   --  @param Item Tensor type.
   --  @return Format name, or "unknown".
   function Type_Name (Item : Tensor_Type) return String;

   --  Report whether a tensor dimension is compatible with a format's block
   --  size.
   --
   --  A quantized tensor stores whole blocks along its contiguous dimension,
   --  so that dimension must be a multiple of the block element count.
   --
   --  @param Item Tensor type.
   --  @param Dimension Length of the contiguous dimension.
   --  @return True when the dimension divides into whole blocks.
   function Divides_Into_Blocks (Item : Tensor_Type; Dimension : U64) return Boolean;

end Model_Runner.GGUF;
