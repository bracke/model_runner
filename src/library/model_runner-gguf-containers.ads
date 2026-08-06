private with Ada.Containers.Indefinite_Hashed_Maps;
private with Ada.Containers.Vectors;
private with Ada.Finalization;
private with Ada.Strings.Hash;

with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Numerics;

--  A parsed and validated GGUF container.
--
--  A Container holds everything the file said about itself: the version, the
--  data-section alignment, every metadata entry, every tensor descriptor and
--  the absolute byte range of each tensor. It holds no tensor data. Building
--  one is the job of the child package Reader; this package owns the storage
--  and the typed accessors.
--
--  Typed access. Every accessor distinguishes four outcomes -- the key is
--  absent, the key has a different type, the value is outside the requested
--  range, or the value is usable -- and reports the first three as structured
--  GGUF diagnostics. Architecture code therefore never repeats a metadata type
--  check, and a diagnostic always names the key that was wrong.
--
--  Storage. Strings and metadata array payloads live in one byte pool whose
--  total size is bounded by Max_Metadata_Pool_Bytes. Entries refer to slices
--  of that pool, so the number of separate allocations does not grow with the
--  size of a tokenizer vocabulary.
--
--  Task safety: a Container is built by one task and is immutable afterwards.
--  Concurrent readers of a built container are safe.
package Model_Runner.GGUF.Containers is

   --  A parsed container. Release with Close, which is idempotent and is also
   --  performed by finalization.
   type Container is tagged limited private;

   --  Release every resource held by a container.
   --
   --  @param Item Container to release.
   procedure Close (Item : in out Container);

   --  Report whether a container was successfully built.
   --
   --  @param Item Container to inspect.
   --  @return True when parsing and validation completed.
   function Is_Valid (Item : Container) return Boolean;

   ---------------------------------------------------------------------------
   --  Container-level facts
   ---------------------------------------------------------------------------

   --  Container format version.
   --
   --  @param Item Container to inspect.
   --  @return Version number read from the header.
   function Version (Item : Container) return U32;

   --  Alignment of the tensor data section.
   --
   --  @param Item Container to inspect.
   --  @return Alignment in bytes, from general.alignment or the default.
   function Alignment (Item : Container) return U64;

   --  Absolute offset of the first byte of the tensor data section.
   --
   --  @param Item Container to inspect.
   --  @return Byte offset from the start of the file.
   function Data_Offset (Item : Container) return U64;

   --  Size of the file the container was read from.
   --
   --  @param Item Container to inspect.
   --  @return Size in bytes.
   function File_Size (Item : Container) return U64;

   --  Number of bytes occupied by tensor data.
   --
   --  @param Item Container to inspect.
   --  @return Total tensor bytes, excluding alignment padding before the
   --    section.
   function Tensor_Data_Bytes (Item : Container) return U64;

   ---------------------------------------------------------------------------
   --  Metadata
   ---------------------------------------------------------------------------

   --  Number of metadata entries.
   --
   --  @param Item Container to inspect.
   --  @return Entry count.
   function Metadata_Count (Item : Container) return Natural;

   --  Key of a metadata entry.
   --
   --  @param Item Container to inspect.
   --  @param Index Entry position in 1 .. Metadata_Count.
   --  @return Key text, exactly as it appeared in the file.
   function Metadata_Key (Item : Container; Index : Positive) return String;

   --  Declared type of a metadata entry.
   --
   --  @param Item Container to inspect.
   --  @param Index Entry position in 1 .. Metadata_Count.
   --  @return Value type.
   function Metadata_Kind (Item : Container; Index : Positive) return Value_Type;

   --  Element type of an array metadata entry.
   --
   --  @param Item Container to inspect.
   --  @param Index Entry position in 1 .. Metadata_Count.
   --  @return Element type; meaningless when the entry is not an array.
   function Metadata_Element_Kind
     (Item : Container; Index : Positive) return Value_Type;

   --  Number of elements in an array metadata entry.
   --
   --  @param Item Container to inspect.
   --  @param Index Entry position in 1 .. Metadata_Count.
   --  @return Element count; 1 for a scalar entry.
   function Metadata_Length (Item : Container; Index : Positive) return Natural;

   --  Position of a key.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to find.
   --  @return Entry position, or 0 when the key is absent.
   function Find (Item : Container; Key : String) return Natural;

   --  Report whether a key is present.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to find.
   --  @return True when the key exists.
   function Has (Item : Container; Key : String) return Boolean
   is (Find (Item, Key) /= 0);

   --  Read a string-valued key.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Max_Length Largest accepted length in bytes.
   --  @param Value Value text; empty on failure.
   --  @param Last Length of the returned text.
   --  @param Status Success, GGUF_Missing_Metadata_Key,
   --    GGUF_Metadata_Type_Mismatch or GGUF_Metadata_Out_Of_Range.
   procedure Get_String
     (Item       : Container;
      Key        : String;
      Max_Length : Natural;
      Value      : out String;
      Last       : out Natural;
      Status     : out Model_Runner.Errors.Error_Info);

   --  Read a string-valued key whose length is already known to be bounded.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @return Value text, or an empty string when absent or not a string.
   function String_Value (Item : Container; Key : String) return String;

   --  Read an integer-valued key and check it against a range.
   --
   --  Any of the six integer types is accepted; the value is widened and then
   --  range checked, so a file that writes a layer count as UInt16 and one that
   --  writes it as UInt32 behave identically.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Minimum Smallest accepted value.
   --  @param Maximum Largest accepted value.
   --  @param Value Value read; Minimum on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_Integer
     (Item    : Container;
      Key     : String;
      Minimum : Long_Long_Integer;
      Maximum : Long_Long_Integer;
      Value   : out Long_Long_Integer;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Read a floating-point key and check it against a range.
   --
   --  Both Float32 and Float64 are accepted. A non-finite value is rejected as
   --  out of range rather than propagated into the model configuration.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Minimum Smallest accepted value.
   --  @param Maximum Largest accepted value.
   --  @param Value Value read; Minimum on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_Float
     (Item    : Container;
      Key     : String;
      Minimum : Model_Runner.Numerics.Wide_Real;
      Maximum : Model_Runner.Numerics.Wide_Real;
      Value   : out Model_Runner.Numerics.Wide_Real;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Read a boolean key.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Value Value read; False on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_Boolean
     (Item   : Container;
      Key    : String;
      Value  : out Boolean;
      Status : out Model_Runner.Errors.Error_Info);

   --  Number of elements in an array-valued key.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Element Required element type.
   --  @param Length Element count; 0 on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_Array_Length
     (Item    : Container;
      Key     : String;
      Element : Value_Type;
      Length  : out Natural;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Read one element of a string array into caller-owned storage.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Index Element position in 1 .. array length.
   --  @param Value Element text; unspecified beyond Last.
   --  @param Last Length written; 0 on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_String_Element
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Value  : out String;
      Last   : out Natural;
      Status : out Model_Runner.Errors.Error_Info);

   --  Length of one element of a string array.
   --
   --  Lets a caller size a buffer before reading, so that a hostile vocabulary
   --  entry cannot overflow a fixed target.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Index Element position.
   --  @param Length Element length in bytes; 0 on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_String_Element_Length
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Length : out Natural;
      Status : out Model_Runner.Errors.Error_Info);

   --  Read one element of an integer array.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Index Element position.
   --  @param Value Element value; 0 on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_Integer_Element
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Value  : out Long_Long_Integer;
      Status : out Model_Runner.Errors.Error_Info);

   --  Read one element of a floating-point array.
   --
   --  @param Item Container to inspect.
   --  @param Key Key to read.
   --  @param Index Element position.
   --  @param Value Element value; 0.0 on failure.
   --  @param Status Success or a GGUF metadata diagnostic.
   procedure Get_Float_Element
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Value  : out Model_Runner.Numerics.Wide_Real;
      Status : out Model_Runner.Errors.Error_Info);

   ---------------------------------------------------------------------------
   --  Tensor descriptors
   ---------------------------------------------------------------------------

   --  Number of tensor descriptors.
   --
   --  @param Item Container to inspect.
   --  @return Descriptor count.
--  Render one metadata value for display.
   --
   --  The type word, then the value. Everything here came out of a model file
   --  and is escaped; a long string is shortened on a code-point boundary and
   --  says so, and an array is described rather than dumped -- a tokenizer
   --  vocabulary is an array of tens of thousands of strings and printing it
   --  is never what a reader asked for.
   --
   --  @param Item Container to inspect.
   --  @param Index Metadata entry, one based.
   --  @param Width Largest number of bytes of value text to show.
   --  @return Display text; the type word alone when the value cannot be read.
   function Value_Image
     (Item  : Container;
      Index : Positive;
      Width : Natural := 120) return String;

   function Tensor_Count (Item : Container) return Natural;

   --  Position of a tensor by name.
   --
   --  @param Item Container to inspect.
   --  @param Name Tensor name.
   --  @return Descriptor position, or 0 when absent.
   function Find_Tensor (Item : Container; Name : String) return Natural;

   --  Name of a tensor.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position in 1 .. Tensor_Count.
   --  @return Tensor name exactly as it appeared in the file.
   function Tensor_Name (Item : Container; Index : Positive) return String;

   --  Element format of a tensor.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position.
   --  @return Tensor type.
   function Tensor_Format
     (Item : Container; Index : Positive) return Tensor_Type;

   --  Number of dimensions of a tensor.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position.
   --  @return Rank in 1 .. Max_Rank.
   function Tensor_Rank (Item : Container; Index : Positive) return Positive;

   --  One dimension of a tensor, in GGUF order.
   --
   --  Dimension 1 is the contiguous dimension. The conversion to this crate's
   --  internal convention happens once, in the tensor layer.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position.
   --  @param Axis Dimension position in 1 .. Tensor_Rank.
   --  @return Dimension length.
   function Tensor_Dimension
     (Item : Container; Index : Positive; Axis : Positive) return U64;

   --  Total element count of a tensor.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position.
   --  @return Product of the dimensions.
   function Tensor_Elements (Item : Container; Index : Positive) return U64;

   --  Absolute file offset of a tensor's first byte.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position.
   --  @return Byte offset from the start of the file.
   function Tensor_Offset (Item : Container; Index : Positive) return U64;

   --  Serialized size of a tensor.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position.
   --  @return Size in bytes.
   function Tensor_Bytes (Item : Container; Index : Positive) return U64;

   --  Report whether a tensor format is one this crate implements.
   --
   --  @param Item Container to inspect.
   --  @param Index Descriptor position.
   --  @return True when the format is supported end to end.
   function Tensor_Is_Supported
     (Item : Container; Index : Positive) return Boolean;

private

   --  A slice of the shared byte pool.
   type Slice is record
      Offset : Model_Runner.Bytes.Byte_Count := 0;
      Length : Model_Runner.Bytes.Byte_Count := 0;
   end record;

   package Slice_Vectors is
     new Ada.Containers.Vectors (Positive, Slice);

   --  One metadata entry. Scalar values are stored inline; strings and arrays
   --  refer to the pool.
   type Metadata_Entry is record
      Key          : Slice;
      Kind         : Value_Type := Value_UInt8;
      Element_Kind : Value_Type := Value_UInt8;
      Length       : Natural := 1;
      Unsigned     : U64 := 0;
      Signed       : Long_Long_Integer := 0;
      Number       : Model_Runner.Numerics.Wide_Real := 0.0;
      Flag         : Boolean := False;
      First_Slice  : Natural := 0;
      Payload      : Slice;
   end record;

   package Metadata_Vectors is
     new Ada.Containers.Vectors (Positive, Metadata_Entry);

   type Dimension_Array is array (1 .. Max_Rank) of U64;

   type Tensor_Entry is record
      Name       : Slice;
      Format     : Tensor_Type := Type_Unknown;
      Rank       : Positive := 1;
      Dimensions : Dimension_Array := [others => 1];
      Elements   : U64 := 0;
      Relative   : U64 := 0;
      Absolute   : U64 := 0;
      Size       : U64 := 0;
   end record;

   package Tensor_Vectors is
     new Ada.Containers.Vectors (Positive, Tensor_Entry);

   package Name_Maps is
     new Ada.Containers.Indefinite_Hashed_Maps
       (Key_Type        => String,
        Element_Type    => Positive,
        Hash            => Ada.Strings.Hash,
        Equivalent_Keys => "=");

   type Container is limited new Ada.Finalization.Limited_Controlled with record
      Valid        : Boolean := False;
      Format       : U32 := 0;
      Align        : U64 := Default_Alignment;
      Data_Start   : U64 := 0;
      Total_Size   : U64 := 0;
      Data_Bytes   : U64 := 0;
      Pool         : Model_Runner.Bytes.Byte_Array_Access := null;
      Pool_Used    : Model_Runner.Bytes.Byte_Count := 0;
      Slices       : Slice_Vectors.Vector;
      Entries      : Metadata_Vectors.Vector;
      Tensors      : Tensor_Vectors.Vector;
      Metadata_Map : Name_Maps.Map;
      Tensor_Map   : Name_Maps.Map;
      Bounds       : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
   end record;

   overriding procedure Finalize (Item : in out Container);

end Model_Runner.GGUF.Containers;
