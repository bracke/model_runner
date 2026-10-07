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

   procedure Page_Out
     (Start  : System.Address;
      Length : Model_Runner.Bytes.Byte_Count)
   is
      pragma Unreferenced (Start, Length);
   begin
      null;
   end Page_Out;

end Model_Runner.Platform.Pages;
