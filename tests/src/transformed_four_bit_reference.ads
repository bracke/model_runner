with Model_Runner.Cache_Codecs.Transformed_Four_Bit;

--  A deliberately plain reference for the transformed four-bit experiment.
--  It forms every Hadamard matrix coefficient from parity and never calls the
--  production transform, packer, decoder or dot-product operations.
package Transformed_Four_Bit_Reference is

   package C renames Model_Runner.Cache_Codecs.Transformed_Four_Bit;

   --  Independently rotate and encode a key.
   --
   --  @param Source Key in the model's basis.
   --  @param Codes Receives packed nibbles.
   --  @param Scales Receives one scale per group.
   --  @param Valid True when the buffers and values are valid.
   procedure Encode_Key
     (Source : C.Real_Array;
      Codes  : out C.Byte_Array;
      Scales : out C.Real_Array;
      Valid  : out Boolean);

   --  Independently decode a key.
   --
   --  @param Codes Packed key nibbles.
   --  @param Scales One scale per group.
   --  @param Target Receives the key in the model's basis.
   --  @param Valid True when the buffers and values are valid.
   procedure Decode_Key
     (Codes  : C.Byte_Array;
      Scales : C.Real_Array;
      Target : out C.Real_Array;
      Valid  : out Boolean);

   --  Independently score a packed key.
   --
   --  @param Query Query in the model's basis.
   --  @param Codes Packed key nibbles.
   --  @param Scales One scale per group.
   --  @param Valid True when the buffers and values are valid.
   --  @return Query/key dot product.
   function Score_Key
     (Query  : C.Real_Array;
      Codes  : C.Byte_Array;
      Scales : C.Real_Array;
      Valid  : out Boolean) return C.Wide_Real;

   --  Independently encode an ordinary-Q4 value row.
   --
   --  @param Source Value row.
   --  @param Codes Receives packed nibbles.
   --  @param Scales Receives one scale per group.
   --  @param Valid True when the buffers and values are valid.
   procedure Encode_Value
     (Source : C.Real_Array;
      Codes  : out C.Byte_Array;
      Scales : out C.Real_Array;
      Valid  : out Boolean);

   --  Independently decode an ordinary-Q4 value row.
   --
   --  @param Codes Packed value nibbles.
   --  @param Scales One scale per group.
   --  @param Target Receives the decoded row.
   --  @param Valid True when the buffers and values are valid.
   procedure Decode_Value
     (Codes  : C.Byte_Array;
      Scales : C.Real_Array;
      Target : out C.Real_Array;
      Valid  : out Boolean);

end Transformed_Four_Bit_Reference;
