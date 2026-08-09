with Interfaces;

package body Model_Runner.Byte_Sources.Memory is

   use type Model_Runner.Bytes.Byte_Count;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;

   ----------
   -- Size --
   ----------

   overriding function Size (Self : Buffer_Source) return B.Byte_Count
   is (if Self.Data = null then 0 else Self.Data.all'Length);

   ----------
   -- Read --
   ----------

   overriding procedure Read
     (Self   : in out Buffer_Source;
      Offset : B.Byte_Count;
      Target : out B.Byte_Array;
      Status : out E.Error_Info) is
   begin
      if Self.Data = null
        or else not B.Has_Room (Self.Data.all, Offset, Target'Length)
      then
         --  Defined only where it is not filled. Zeroing first and copying
         --  over it writes every byte twice, and a caller reading straight
         --  into a large buffer pays that for the whole of it.
         Target := [others => 0];
         Status := E.Make (E.GGUF_Truncated);
         E.Add_Integer
           (Status, "offset", Long_Long_Integer (Offset), E.Param_Offset);
         E.Add_Integer
           (Status, "length", Long_Long_Integer (Target'Length), E.Param_Bytes);
         E.Set_Location (Status, Interfaces.Unsigned_64 (Offset));
         return;
      end if;

      declare
         First : constant B.Byte_Index := Self.Data.all'First + Offset;
      begin
         Target := Self.Data.all (First .. First + Target'Length - 1);
      end;
      Status := E.Success;
   end Read;

   ---------------
   -- Is_Mapped --
   ---------------

   overriding function Is_Mapped (Self : Buffer_Source) return Boolean is
      pragma Unreferenced (Self);
   begin
      return False;
   end Is_Mapped;

   -------------
   -- Changed --
   -------------

   overriding function Changed (Self : Buffer_Source) return Boolean is
      pragma Unreferenced (Self);
   begin
      return False;
   end Changed;

   ----------
   -- Name --
   ----------

   overriding function Name (Self : Buffer_Source) return String is
      pragma Unreferenced (Self);
   begin
      return "<memory>";
   end Name;

end Model_Runner.Byte_Sources.Memory;
