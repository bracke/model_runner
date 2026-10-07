with Interfaces.C;
--  Large pages on this host: not asked for. The host has no advice of the
--  kind Linux takes, or this build does not know how to give it, and a
--  buffer in ordinary pages is the same buffer.
package body Model_Runner.Platform.Pages is

   procedure Prefer_Large (Bytes : Model_Runner.Bytes.Byte_Array_Access) is
      pragma Unreferenced (Bytes);
   begin
      null;
   end Prefer_Large;

   procedure Prefer_Large_At
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count)
   is
      pragma Unreferenced (Start, Length);
   begin
      null;
   end Prefer_Large_At;

   function Mlock
     (Start  : System.Address;
      Length : Interfaces.C.size_t) return Interfaces.C.int
     with Import, Convention => C, External_Name => "mlock";

   function Keep_Resident
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count) return Boolean
   is
      use type Interfaces.C.int;
      use type Model_Runner.Bytes.Byte_Count;
   begin
      return Length > 0
        and then Mlock (Start, Interfaces.C.size_t (Length)) = 0;
   end Keep_Resident;

end Model_Runner.Platform.Pages;
