with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Indefinite_Vectors;
with Ada.Containers.Vectors;
with Ada.Strings.Hash;

with Model_Runner.Byte_Sources;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;

--  The table of a safetensors file: what a diffusion model's VAE is published
--  as, rarely as GGUF.
--
--  The format is eight bytes of little-endian length, a JSON object of that
--  many bytes naming each tensor's element type, shape and byte range, and
--  then the tensors' bytes, raw, the ranges counted from the end of the
--  header. Only the table is read here; the bytes are the caller's to map
--  or read, at Data_Offset, as a GGUF tensor's are at its offset.
--
--  What the header says is held to what the file can hold: every range
--  within the file, as long as its element type and shape say, and none
--  overlapping another; a header the format does not allow is refused with
--  what is wrong with it, not read as far as it goes.
--
--  Task safety: a Table may be read by many tasks once filled; Read is not
--  reentrant on one Table.
package Model_Runner.Safetensors is

   --  The most dimensions a tensor here may have: a convolution's four.
   Max_Rank : constant := 4;

   --  The most tensors one file may name.
   Max_Tensors : constant := 65_536;

   --  The longest header read: the format's own limit, 100 MB.
   Max_Header : constant := 100_000_000;

   subtype Rank_Count is Natural range 0 .. Max_Rank;

   --  Dimensions as the file writes them, the outermost first: a
   --  convolution's [out, in, height, width]. GGUF's order is the reverse.
   type Shape_Array is array (1 .. Max_Rank) of Model_Runner.GGUF.U64;

   --  One tensor the header names.
   type Tensor_Info is record
      Element     : Model_Runner.GGUF.Tensor_Type := Model_Runner.GGUF.Type_F32;
      Rank        : Rank_Count := 0;
      Shape       : Shape_Array := [others => 1];
      Elements    : Model_Runner.GGUF.U64 := 1;
      --  Absolute, from the file's first byte.
      Data_Offset : Model_Runner.Bytes.Byte_Count := 0;
      Data_Length : Model_Runner.Bytes.Byte_Count := 0;
   end record;

   type Table is limited private;

   --  Read a file's table.
   --
   --  The element types read are those a VAE or a denoiser is published in:
   --  F32, F16 and BF16. Any other the format names is refused by name.
   --
   --  @param Into the table, empty when the header is refused
   --  @param Source the file
   --  @param Status success, or why the header is not one the format allows
   procedure Read
     (Into   : in out Table;
      Source : in out Model_Runner.Byte_Sources.Source'Class;
      Status : out Model_Runner.Errors.Error_Info);

   --  @param Item a table
   --  @return how many tensors it names
   function Count (Item : Table) return Natural;

   --  @param Item a table
   --  @param Index one of its tensors, 1 .. Count
   --  @return that tensor
   function Info (Item : Table; Index : Positive) return Tensor_Info;

   --  @param Item a table
   --  @param Index one of its tensors, 1 .. Count
   --  @return that tensor's name
   function Name (Item : Table; Index : Positive) return String;

   --  @param Item a table
   --  @param Named a tensor's name
   --  @return its index, or 0 where the table names no such tensor
   function Find (Item : Table; Named : String) return Natural;

   --  @param Item a table
   --  @return where the tensors' bytes begin, from the file's first byte
   function Data_Start (Item : Table) return Model_Runner.Bytes.Byte_Count;

private

   package Info_Vectors is new Ada.Containers.Vectors (Positive, Tensor_Info);
   package Name_Vectors is new Ada.Containers.Indefinite_Vectors (Positive, String);
   package Index_Maps is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type        => String,
      Element_Type    => Positive,
      Hash            => Ada.Strings.Hash,
      Equivalent_Keys => "=");

   type Table is limited record
      Tensors : Info_Vectors.Vector;
      Names   : Name_Vectors.Vector;
      Start   : Model_Runner.Bytes.Byte_Count := 0;
      By_Name : Index_Maps.Map;
   end record;

end Model_Runner.Safetensors;
