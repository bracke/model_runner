with Interfaces;

with Model_Runner.Numerics;

--  The authoritative host codec for transformed-four-bit cache rows: a fixed
--  orthonormal Walsh-Hadamard rotation for keys, followed by the cache's
--  ordinary per-32 Q4 body. Values deliberately remain ordinary Q4. Session
--  storage, snapshots, tests and device-reference checks share this codec.
package Model_Runner.Cache_Codecs.Transformed_Four_Bit is
   pragma Pure;

   package N renames Model_Runner.Numerics;

   subtype Real is N.Real;
   subtype Wide_Real is N.Wide_Real;
   subtype Real_Array is N.Real_Array;
   subtype Element_Count is N.Element_Count;

   use type N.Element_Count;

   subtype Byte is Interfaces.Unsigned_8;
   type Byte_Array is array (Element_Count range <>) of Byte
     with Component_Size => 8;

   Group_Size : constant Element_Count := 32;

   --  The fixed Rademacher signs applied before each 32-coordinate transform.
   --  Bit zero belongs to the first coordinate. This mask is part of the
   --  format, not a runtime seed.
   Sign_Mask : constant Interfaces.Unsigned_32 := 16#D6E8_FEB8#;

   --  Bytes occupied by the packed nibbles.
   --
   --  @param Elements Number of encoded elements.
   --  @return Number of bytes required.
   function Code_Bytes (Elements : Element_Count) return Element_Count
   is (Elements / 2 + Elements mod 2);

   --  Per-group scales occupied by the packed body.
   --
   --  @param Elements Number of encoded elements.
   --  @return Number of scales required.
   function Scale_Count (Elements : Element_Count) return Element_Count
   is (Elements / Group_Size
       + (if Elements mod Group_Size = 0 then 0 else 1));

   --  Rotate a key into the basis stored by Encode_Key. Complete groups use
   --  a normalized 32-point transform. A short final group is partitioned
   --  greedily into power-of-two transforms, so it needs no padded storage.
   --
   --  @param Source Key in the model's basis.
   --  @param Target Receives the key in the stored basis.
   --  @param Valid True when the buffers and values are valid.
   procedure Rotate_Key
     (Source : Real_Array;
      Target : out Real_Array;
      Valid  : out Boolean);

   --  Return a decoded key from the stored basis to the model's basis.
   --  This is the inverse of Rotate_Key and lets a session reuse its
   --  established byte/scale layout when snapshots or shifts need a row.
   --
   --  @param Source Key in the stored basis.
   --  @param Target Receives the key in the model's basis.
   --  @param Valid True when the buffers and values are valid.
   procedure Restore_Key
     (Source : Real_Array;
      Target : out Real_Array;
      Valid  : out Boolean);

   --  Encode/decode a key. Buffers must have exactly Code_Bytes and
   --  Scale_Count elements for Source/Target. No allocation is performed.
   --
   --  @param Source Key in the model's basis.
   --  @param Codes Receives packed nibbles.
   --  @param Scales Receives one scale per group.
   --  @param Valid True when the buffers and values are valid.
   procedure Encode_Key
     (Source : Real_Array;
      Codes  : out Byte_Array;
      Scales : out Real_Array;
      Valid  : out Boolean);

   --  Decode a stored key to the model's basis.
   --
   --  @param Codes Packed nibbles.
   --  @param Scales One scale per group.
   --  @param Target Receives the decoded key.
   --  @param Valid True when the buffers and values are valid.
   procedure Decode_Key
     (Codes  : Byte_Array;
      Scales : Real_Array;
      Target : out Real_Array;
      Valid  : out Boolean);

   --  Dot Query with the key represented by Codes and Scales, rotating the
   --  query rather than reconstructing the key in its original basis.
   --
   --  @param Query Query in the model's basis.
   --  @param Codes Packed key nibbles.
   --  @param Scales One scale per group.
   --  @param Valid True when the buffers and values are valid.
   --  @return Query/key dot product.
   function Score_Key
     (Query  : Real_Array;
      Codes  : Byte_Array;
      Scales : Real_Array;
      Valid  : out Boolean) return Wide_Real;

   --  Values use the same Q4 body without rotation. Accumulate_Value adds one
   --  decoded value row times Weight to Target; Finish_Value is the explicit
   --  identity finishing step for this first codec.
   --
   --  @param Source Value row in the model's basis.
   --  @param Codes Receives packed nibbles.
   --  @param Scales Receives one scale per group.
   --  @param Valid True when the buffers and values are valid.
   procedure Encode_Value
     (Source : Real_Array;
      Codes  : out Byte_Array;
      Scales : out Real_Array;
      Valid  : out Boolean);

   --  Add a weighted decoded value row to a blend.
   --
   --  @param Weight Weight of this value row.
   --  @param Codes Packed value nibbles.
   --  @param Scales One scale per group.
   --  @param Target Blend to update.
   --  @param Valid True when the buffers and values are valid.
   procedure Accumulate_Value
     (Weight : Real;
      Codes  : Byte_Array;
      Scales : Real_Array;
      Target : in out Real_Array;
      Valid  : out Boolean);

   --  Finish a value blend; identity for this codec.
   --
   --  @param Target Blend to validate.
   --  @param Valid True when every result is finite.
   procedure Finish_Value
     (Target : Real_Array;
      Valid  : out Boolean);

end Model_Runner.Cache_Codecs.Transformed_Four_Bit;
