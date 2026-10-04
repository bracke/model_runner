--  Large pages on this host: not asked for. The host has no advice of the
--  kind Linux takes, or this build does not know how to give it, and a
--  buffer in ordinary pages is the same buffer.
package body Model_Runner.Platform.Pages is

   procedure Prefer_Large (Bytes : Model_Runner.Bytes.Byte_Array_Access) is
      pragma Unreferenced (Bytes);
   begin
      null;
   end Prefer_Large;

end Model_Runner.Platform.Pages;
