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

   SIGINT : constant Interfaces.C.int := 2;

   -------------
   -- Request --
   -------------

   function Request return Boolean is (C_Kill (C_Getpid, SIGINT) = 0);

end Raise_Interrupt;
