with Interfaces;

with Model_Runner.Numerics;

--  Raw byte storage and little-endian primitive decoding.
--
--  Every value read out of a GGUF file passes through the accessors here. They
--  decode explicitly, byte by byte, in GGUF's little-endian order. No
--  serialized record is ever reinterpreted through an Ada record overlay,
--  because that would make the result depend on host padding, host alignment
--  and host endianness.
--
--  Bounds. Each accessor takes the buffer and an offset and reports whether
--  the requested field lies wholly inside the buffer. A caller that ignores
--  the Ok flag reads zero, never memory outside the buffer.
--
--  Task safety: the decoding operations are pure functions on their arguments.
--  Allocation and deallocation of Byte_Array_Access are not task safe and are
--  performed only by the owning preparation or session object.
package Model_Runner.Bytes is

   subtype Byte is Interfaces.Unsigned_8;

   --  Byte positions and sizes. Wide enough for any file a 64-bit host can
   --  map, and wide enough that a tensor byte size derived from 64-bit GGUF
   --  dimensions is representable before the range check rejects it.
   type Byte_Count is range 0 .. 2 ** 47;
   subtype Byte_Index is Byte_Count;

   type Byte_Array is array (Byte_Index range <>) of Byte
   with Component_Size => 8;

   type Byte_Array_Access is access Byte_Array;

   Empty_Bytes : constant Byte_Array (1 .. 0) := [others => 0];

   --  Release a heap byte buffer and clear the reference.
   --
   --  Idempotent: releasing a null reference does nothing.
   --
   --  @param Item Reference to release.
   procedure Free (Item : in out Byte_Array_Access);

   --  Allocate a zero-filled byte buffer.
   --
   --  @param Length Number of bytes.
   --  @param Result Allocated buffer, or null when allocation failed.
   procedure Allocate
     (Length : Byte_Count;
      Result : out Byte_Array_Access);

   --  Overwrite a buffer with zeros.
   --
   --  This said it was used to clear prompt and generated-text buffers on
   --  session reset. It was called by nothing, and it could not have done
   --  that job: the conversation is held as tokens and as text, neither of
   --  which is a byte array. A session reset clears the token history
   --  itself. What is left here is the primitive, for a caller with a byte
   --  buffer to clear.
   --
   --  @param Item Buffer to clear.
   procedure Wipe (Item : in out Byte_Array);

   --  Reinterpret bytes as characters, one byte per character.
   --
   --  @param Item Bytes to view.
   --  @return String of the same length.
   function To_String (Item : Byte_Array) return String;

   --  Reinterpret characters as bytes, one character per byte.
   --
   --  @param Item Characters to view.
   --  @return Byte array of the same length, indexed from 1.
   function To_Bytes (Item : String) return Byte_Array;

   ---------------------------------------------------------------------------
   --  Little-endian primitive decoding.
   --
   --  Offset is a zero-based position relative to Data'First. Ok reports
   --  whether the whole field lies inside Data.
   ---------------------------------------------------------------------------

   --  Report whether Length bytes starting at Offset lie inside Data.
   --
   --  @param Data Buffer to check against.
   --  @param Offset Zero-based start position.
   --  @param Length Field length in bytes.
   --  @return True when the field is wholly contained.
   function Has_Room
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Length : Byte_Count) return Boolean;

   --  Decode an unsigned 8-bit value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_U8
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_8;

   --  Decode an unsigned 16-bit little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_U16
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_16;

   --  Decode an unsigned 32-bit little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_U32
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_32;

   --  Decode an unsigned 64-bit little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_U64
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_64;

   --  Decode a signed 8-bit value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_I8
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_8;

   --  Decode a signed 16-bit little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_I16
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_16;

   --  Decode a signed 32-bit little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_I32
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_32;

   --  Decode a signed 64-bit little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0 when Ok is False.
   function Get_I64
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_64;

   --  Decode an IEEE binary32 little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0.0 when Ok is False.
   function Get_F32
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Model_Runner.Numerics.Real;

   --  Decode an IEEE binary16 little-endian bit pattern.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Raw half-precision pattern, or 0 when Ok is False.
   function Get_F16
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Model_Runner.Numerics.Half;

   --  Decode an IEEE binary64 little-endian value.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or 0.0 when Ok is False.
   function Get_F64
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Model_Runner.Numerics.Wide_Real;

   --  Decode a GGUF boolean, which is one byte.
   --
   --  Any non-zero byte is True. GGUF writers emit 0 or 1; accepting other
   --  values keeps a valid-but-unusual file readable without weakening any
   --  bounds check.
   --
   --  @param Data Buffer to read from.
   --  @param Offset Zero-based start position.
   --  @param Ok True when the field was inside Data.
   --  @return Decoded value, or False when Ok is False.
   function Get_Bool
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Boolean;

   ---------------------------------------------------------------------------
   --  Little-endian primitive encoding, used by the synthetic model writer in
   --  the tests crate and by nothing in the production path.
   ---------------------------------------------------------------------------

   --  Encode an unsigned 16-bit value.
   --
   --  @param Value Value to encode.
   --  @return Two little-endian bytes indexed from 1.
   function Put_U16 (Value : Interfaces.Unsigned_16) return Byte_Array;

   --  Encode an unsigned 32-bit value.
   --
   --  @param Value Value to encode.
   --  @return Four little-endian bytes indexed from 1.
   function Put_U32 (Value : Interfaces.Unsigned_32) return Byte_Array;

   --  Encode an unsigned 64-bit value.
   --
   --  @param Value Value to encode.
   --  @return Eight little-endian bytes indexed from 1.
   function Put_U64 (Value : Interfaces.Unsigned_64) return Byte_Array;

   --  Encode an IEEE binary32 value.
   --
   --  @param Value Value to encode.
   --  @return Four little-endian bytes indexed from 1.
   function Put_F32 (Value : Model_Runner.Numerics.Real) return Byte_Array;

end Model_Runner.Bytes;
