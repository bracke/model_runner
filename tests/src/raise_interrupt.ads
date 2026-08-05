--  Raise an interrupt at this process, the way this host does it.
--
--  The cancellation test needs a real interrupt, not a simulated one: the
--  point is that the path from the operating system through the runtime to
--  the cancellation token works. How a process raises one at itself differs
--  by host, so that difference lives here rather than in the test.
--
--  Task safety: call from one task.
package Raise_Interrupt is

   --  Can this host raise an interrupt at this process alone?
   --
   --  False on Windows, and not for want of a mechanism: the engine handles
   --  console control events, but a process may only send one to its whole
   --  console group, which in a test runner includes the shell that started
   --  it. Firing it wedged the runner. There is no per-process form, so the
   --  delivery path is exercised by hand there rather than in CI.
   --
   --  @return True when Request can be used without disturbing anything else.
   function Can_Request return Boolean;

   --  Ask the host to deliver an interrupt to this process.
   --
   --  @return True when the host accepted the request. False means the
   --    request could not be made, which is a test failure rather than a
   --    reason to skip: every host this builds for can do it.
   function Request return Boolean;

end Raise_Interrupt;
