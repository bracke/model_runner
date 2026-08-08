--  Core count on a host neither the Linux, macOS nor Windows body covers.
--
--  There is no portable way to ask, so this does not pretend to. Zero means
--  unknown and the caller falls back to the processor count, which is what
--  every host used before this question was asked at all.
package body Model_Runner.Platform.Topology is

   ---------------------
   -- Physical_Cores --
   ---------------------

   function Physical_Cores (Processors : Positive) return Natural is
      pragma Unreferenced (Processors);
   begin
      return 0;
   end Physical_Cores;

end Model_Runner.Platform.Topology;
