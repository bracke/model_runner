--  What a test says when the device it needs is not there.
--
--  A device test on a machine with no device -- or with Vulkan fallen back
--  to a software rasterizer after a desktop crash, or another program
--  holding the part -- cannot check anything, and returned without a word:
--  sixty device tests reported a pass that way, which reads as the device
--  being right. Each now says so on the standard error stream, where a
--  reader of the run sees it, through the one procedure here.
--
--  A machine that is known to have a device can insist on it: with
--  MR_EXPECT_DEVICE set to anything but the empty string, a skip is a
--  failure rather than a note.
--
--  Task safety: called from the test runner's one task.
package Device_Notes is

   --  Say that a test could not reach the device and is skipping what
   --  needs it, or fail it where MR_EXPECT_DEVICE says a device is there.
   --
   --  @param What What the test would have checked, as "no device <What>
   --    here" reads.
   procedure Skip (What : String);

end Device_Notes;
