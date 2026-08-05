--  Raise an interrupt at this process, the way this host does it.
--
--  The cancellation test needs a real interrupt, not a simulated one: the
--  point is that the path from the operating system through the runtime to
--  the cancellation token works. How a process raises one at itself differs
--  by host, so that difference lives here rather than in the test.
--
--  Task safety: call from one task.
package Raise_Interrupt is

   --  Ask the host to deliver an interrupt to this process.
   --
   --  @return True when the host accepted the request. False means the
   --    request could not be made, which is a test failure rather than a
   --    reason to skip: every host this builds for can do it.
   function Request return Boolean;

end Raise_Interrupt;
