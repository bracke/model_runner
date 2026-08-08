package body Model_Runner.GGUF is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;

   --  Elements per block for the k-quant family.
   Super_Block : constant U64 := 256;

   --  Elements per block for the legacy quantization family.
   Legacy_Block : constant U64 := 32;

   --  Properties of one tensor format.
   type Format_Info is record
      Code      : U32;
      Elements  : U64;
      Bytes     : U64;
      Supported : Boolean;
   end record;

   --  The GGML type codes. Codes 4 and 5 named formats that were removed from
   --  the format before GGUF and are therefore not listed; codes above 15 name
   --  the importance-matrix families and the integer formats, which this crate
   --  does not implement and reports as unknown.
   Formats : constant array (Tensor_Type) of Format_Info :=
     [Type_F32     => (0,  1,            4,   True),
      Type_F16     => (1,  1,            2,   True),
      Type_Q4_0    => (2,  Legacy_Block, 18,  True),
      Type_Q4_1    => (3,  Legacy_Block, 20,  False),
      Type_Q5_0    => (6,  Legacy_Block, 22,  False),
      Type_Q5_1    => (7,  Legacy_Block, 24,  False),
      Type_Q8_0    => (8,  Legacy_Block, 34,  True),
      Type_Q8_1    => (9,  Legacy_Block, 40,  False),
      Type_Q2_K    => (10, Super_Block,  84,  False),
      Type_Q3_K    => (11, Super_Block,  110, False),
      Type_Q4_K    => (12, Super_Block,  144, True),
      Type_Q5_K    => (13, Super_Block,  176, True),
      Type_Q6_K    => (14, Super_Block,  210, True),
      Type_Q8_K    => (15, Super_Block,  292, False),
      Type_BF16    => (30, 1,            2,   True),
      Type_Unknown => (U32'Last, 0,      0,   False)];

   -------------------
   -- To_Value_Type --
   -------------------

   function To_Value_Type (Code : U32; Known : out Boolean) return Value_Type is
   begin
      if Code <= U32 (Value_Type'Pos (Value_Type'Last)) then
         Known := True;
         return Value_Type'Val (Code);
      else
         Known := False;
         return Value_UInt8;
      end if;
   end To_Value_Type;

   ------------------
   -- Scalar_Size --
   ------------------

   function Scalar_Size (Item : Value_Type) return Model_Runner.Bytes.Byte_Count is
   begin
      case Item is
         when Value_UInt8 | Value_Int8 | Value_Bool          => return 1;
         when Value_UInt16 | Value_Int16                     => return 2;
         when Value_UInt32 | Value_Int32 | Value_Float32     => return 4;
         when Value_UInt64 | Value_Int64 | Value_Float64     => return 8;
         when Value_String | Value_Array                     => return 0;
      end case;
   end Scalar_Size;

   --------------------
   -- To_Tensor_Type --
   --------------------

   function To_Tensor_Type (Code : U32; Known : out Boolean) return Tensor_Type is
   begin
      for Candidate in Tensor_Type loop
         if Candidate /= Type_Unknown and then Formats (Candidate).Code = Code then
            Known := True;
            return Candidate;
         end if;
      end loop;

      Known := False;
      return Type_Unknown;
   end To_Tensor_Type;

   ------------------
   -- Tensor_Code --
   ------------------

   function Tensor_Code (Item : Tensor_Type) return U32
   is (Formats (Item).Code);

   ------------------
   -- Is_Supported --
   ------------------

   function Is_Supported (Item : Tensor_Type) return Boolean
   is (Formats (Item).Supported);

   ---------------------
   -- Block_Elements --
   ---------------------

   function Block_Elements (Item : Tensor_Type) return U64
   is (Formats (Item).Elements);

   ------------------
   -- Block_Bytes --
   ------------------

   function Block_Bytes (Item : Tensor_Type) return U64
   is (Formats (Item).Bytes);

   ----------------
   -- Type_Name --
   ----------------

   function Type_Name (Item : Tensor_Type) return String is
   begin
      case Item is
         when Type_F32     => return "F32";
         when Type_F16     => return "F16";
         when Type_Q4_0    => return "Q4_0";
         when Type_Q4_1    => return "Q4_1";
         when Type_Q5_0    => return "Q5_0";
         when Type_Q5_1    => return "Q5_1";
         when Type_Q8_0    => return "Q8_0";
         when Type_Q8_1    => return "Q8_1";
         when Type_Q2_K    => return "Q2_K";
         when Type_Q3_K    => return "Q3_K";
         when Type_Q4_K    => return "Q4_K";
         when Type_Q5_K    => return "Q5_K";
         when Type_Q6_K    => return "Q6_K";
         when Type_Q8_K    => return "Q8_K";
         when Type_BF16    => return "BF16";
         when Type_Unknown => return "unknown";
      end case;
   end Type_Name;

   --------------------------
   -- Divides_Into_Blocks --
   --------------------------

   function Divides_Into_Blocks (Item : Tensor_Type; Dimension : U64) return Boolean
   is
      Elements : constant U64 := Block_Elements (Item);
   begin
      return Elements /= 0 and then Dimension mod Elements = 0;
   end Divides_Into_Blocks;

end Model_Runner.GGUF;
