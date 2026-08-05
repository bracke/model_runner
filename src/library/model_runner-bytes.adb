with Ada.Unchecked_Deallocation;

package body Model_Runner.Bytes is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_32;
   use type Interfaces.Integer_64;

   package N renames Model_Runner.Numerics;

   procedure Deallocate is
     new Ada.Unchecked_Deallocation (Byte_Array, Byte_Array_Access);

   ----------
   -- Free --
   ----------

   procedure Free (Item : in out Byte_Array_Access) is
   begin
      if Item /= null then
         Deallocate (Item);
      end if;
      Item := null;
   end Free;

   --------------
   -- Allocate --
   --------------

   procedure Allocate
     (Length : Byte_Count;
      Result : out Byte_Array_Access) is
   begin
      Result := new Byte_Array (1 .. Length);
      Result.all := [others => 0];
   exception
      when Storage_Error =>
         Result := null;
   end Allocate;

   ----------
   -- Wipe --
   ----------

   procedure Wipe (Item : in out Byte_Array) is
   begin
      Item := [others => 0];
   end Wipe;

   ---------------
   -- To_String --
   ---------------

   function To_String (Item : Byte_Array) return String is
      Result : String (1 .. Natural (Item'Length));
      Target : Natural := 0;
   begin
      for Value of Item loop
         Target := Target + 1;
         Result (Target) := Character'Val (Value);
      end loop;
      return Result;
   end To_String;

   --------------
   -- To_Bytes --
   --------------

   function To_Bytes (Item : String) return Byte_Array is
      Result : Byte_Array (1 .. Byte_Count (Item'Length));
      Target : Byte_Count := 0;
   begin
      for Value of Item loop
         Target := Target + 1;
         Result (Target) := Byte (Character'Pos (Value));
      end loop;
      return Result;
   end To_Bytes;

   --------------
   -- Has_Room --
   --------------

   function Has_Room
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Length : Byte_Count) return Boolean is
   begin
      --  Written so that no intermediate can overflow Byte_Count: the two
      --  operands are compared against the available span rather than added.
      return Offset <= Data'Length
        and then Length <= Data'Length - Offset;
   end Has_Room;

   --  Return the element at a zero-based offset. The caller has already
   --  established that the offset is inside Data.
   function At_Offset (Data : Byte_Array; Offset : Byte_Count) return Byte
   is (Data (Data'First + Offset));

   ------------
   -- Get_U8 --
   ------------

   function Get_U8
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_8 is
   begin
      Ok := Has_Room (Data, Offset, 1);
      return (if Ok then At_Offset (Data, Offset) else 0);
   end Get_U8;

   -------------
   -- Get_U16 --
   -------------

   function Get_U16
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_16 is
   begin
      Ok := Has_Room (Data, Offset, 2);
      if not Ok then
         return 0;
      end if;
      return Interfaces.Unsigned_16 (At_Offset (Data, Offset))
        or Interfaces.Shift_Left
             (Interfaces.Unsigned_16 (At_Offset (Data, Offset + 1)), 8);
   end Get_U16;

   -------------
   -- Get_U32 --
   -------------

   function Get_U32
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_32
   is
      Result : Interfaces.Unsigned_32 := 0;
   begin
      Ok := Has_Room (Data, Offset, 4);
      if not Ok then
         return 0;
      end if;
      for Index in reverse Byte_Count range 0 .. 3 loop
         Result := Interfaces.Shift_Left (Result, 8)
           or Interfaces.Unsigned_32 (At_Offset (Data, Offset + Index));
      end loop;
      return Result;
   end Get_U32;

   -------------
   -- Get_U64 --
   -------------

   function Get_U64
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Unsigned_64
   is
      Result : Interfaces.Unsigned_64 := 0;
   begin
      Ok := Has_Room (Data, Offset, 8);
      if not Ok then
         return 0;
      end if;
      for Index in reverse Byte_Count range 0 .. 7 loop
         Result := Interfaces.Shift_Left (Result, 8)
           or Interfaces.Unsigned_64 (At_Offset (Data, Offset + Index));
      end loop;
      return Result;
   end Get_U64;

   ------------
   -- Get_I8 --
   ------------

   function Get_I8
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_8
   is
      Raw : constant Interfaces.Unsigned_8 := Get_U8 (Data, Offset, Ok);
   begin
      return
        (if Raw < 16#80#
         then Interfaces.Integer_8 (Raw)
         else Interfaces.Integer_8 (Integer (Raw) - 256));
   end Get_I8;

   -------------
   -- Get_I16 --
   -------------

   function Get_I16
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_16
   is
      Raw : constant Interfaces.Unsigned_16 := Get_U16 (Data, Offset, Ok);
   begin
      return
        (if Raw < 16#8000#
         then Interfaces.Integer_16 (Raw)
         else Interfaces.Integer_16 (Integer (Raw) - 65536));
   end Get_I16;

   -------------
   -- Get_I32 --
   -------------

   function Get_I32
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_32
   is
      Raw : constant Interfaces.Unsigned_32 := Get_U32 (Data, Offset, Ok);
   begin
      return
        (if Raw < 16#8000_0000#
         then Interfaces.Integer_32 (Raw)
         else Interfaces.Integer_32
                (Interfaces.Integer_64 (Raw) - 16#1_0000_0000#));
   end Get_I32;

   -------------
   -- Get_I64 --
   -------------

   function Get_I64
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Interfaces.Integer_64
   is
      Raw : constant Interfaces.Unsigned_64 := Get_U64 (Data, Offset, Ok);
   begin
      --  Convert through the low 63 bits so that the sign bit is applied
      --  explicitly rather than by relying on a wrapping conversion.
      if (Raw and 16#8000_0000_0000_0000#) = 0 then
         return Interfaces.Integer_64 (Raw);
      else
         return Interfaces.Integer_64 (Raw and 16#7FFF_FFFF_FFFF_FFFF#)
           + Interfaces.Integer_64'First;
      end if;
   end Get_I64;

   -------------
   -- Get_F32 --
   -------------

   function Get_F32
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return N.Real
   is
      Raw : constant Interfaces.Unsigned_32 := Get_U32 (Data, Offset, Ok);
   begin
      return (if Ok then N.From_Bits (Raw) else 0.0);
   end Get_F32;

   -------------
   -- Get_F16 --
   -------------

   function Get_F16
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return N.Half
   is
      Raw : constant Interfaces.Unsigned_16 := Get_U16 (Data, Offset, Ok);
   begin
      return (if Ok then N.Half (Raw) else 0);
   end Get_F16;

   -------------
   -- Get_F64 --
   -------------

   function Get_F64
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return N.Wide_Real
   is
      Raw : constant Interfaces.Unsigned_64 := Get_U64 (Data, Offset, Ok);
   begin
      return (if Ok then N.Wide_From_Bits (Raw) else 0.0);
   end Get_F64;

   --------------
   -- Get_Bool --
   --------------

   function Get_Bool
     (Data   : Byte_Array;
      Offset : Byte_Count;
      Ok     : out Boolean) return Boolean
   is
      Raw : constant Interfaces.Unsigned_8 := Get_U8 (Data, Offset, Ok);
   begin
      return Ok and then Raw /= 0;
   end Get_Bool;

   -------------
   -- Put_U16 --
   -------------

   function Put_U16 (Value : Interfaces.Unsigned_16) return Byte_Array is
   begin
      return
        [1 => Byte (Value and 16#FF#),
         2 => Byte (Interfaces.Shift_Right (Value, 8) and 16#FF#)];
   end Put_U16;

   -------------
   -- Put_U32 --
   -------------

   function Put_U32 (Value : Interfaces.Unsigned_32) return Byte_Array is
      Result : Byte_Array (1 .. 4);
   begin
      for Index in Result'Range loop
         Result (Index) :=
           Byte (Interfaces.Shift_Right (Value, Natural (Index - 1) * 8)
                 and 16#FF#);
      end loop;
      return Result;
   end Put_U32;

   -------------
   -- Put_U64 --
   -------------

   function Put_U64 (Value : Interfaces.Unsigned_64) return Byte_Array is
      Result : Byte_Array (1 .. 8);
   begin
      for Index in Result'Range loop
         Result (Index) :=
           Byte (Interfaces.Shift_Right (Value, Natural (Index - 1) * 8)
                 and 16#FF#);
      end loop;
      return Result;
   end Put_U64;

   -------------
   -- Put_F32 --
   -------------

   function Put_F32 (Value : N.Real) return Byte_Array
   is (Put_U32 (N.Bits (Value)));

end Model_Runner.Bytes;
