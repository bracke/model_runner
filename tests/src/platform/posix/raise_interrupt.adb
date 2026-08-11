with Interfaces.C;

package body Raise_Interrupt is

   use type Interfaces.C.int;

   --  The signal has to be directed at the process, not at this thread. The
   --  runtime blocks signals in ordinary tasks and delivers them through a
   --  dedicated waiter, so a thread-directed raise would stay pending on a
   --  thread that never waits for it.
   function C_Getpid return Interfaces.C.int
   with Import, Convention => C, External_Name => "getpid";

   function C_Kill
     (Process : Interfaces.C.int;
      Signal  : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "kill";

   --  Two on Linux and on macOS alike, which this directory is compiled
   --  for both of. A number right for one host is not thereby right for the
   --  other: the capture in this crate had Linux's create-and-truncate
   --  flags and stopped truncating on macOS.
   SIGINT : constant Interfaces.C.int := 2;

   -------------
   -- Request --
   -------------

   -----------------
   -- Can_Request --
   -----------------

   --  A POSIX signal is directed at one process, so this disturbs nothing.
   function Can_Request return Boolean is (True);

   -------------
   -- Request --
   -------------

   function Request return Boolean is (C_Kill (C_Getpid, SIGINT) = 0);

end Raise_Interrupt;
