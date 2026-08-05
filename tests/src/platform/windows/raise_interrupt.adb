with Interfaces.C;

package body Raise_Interrupt is

   use type Interfaces.C.int;

   --  The console control event is the path the GNAT runtime hooks on this
   --  host. The C runtime's raise was tried first and was not enough: it
   --  reported success, the handler was installed, and the token was never
   --  set, because raise dispatches on the calling thread through the C
   --  runtime and never reaches the Ada interrupt handler.
   function Generate_Console_Ctrl_Event
     (Event : Interfaces.C.unsigned_long;
      Group : Interfaces.C.unsigned_long) return Interfaces.C.int
   with Import, Convention => Stdcall,
        External_Name => "GenerateConsoleCtrlEvent";

   --  Kept as the fallback: a process with no console attached cannot send a
   --  console event at all, and a test runner does not always have one.
   function C_Raise (Signal : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "raise";

   Ctrl_C_Event : constant Interfaces.C.unsigned_long := 0;

   --  Group zero means every process attached to this console, which is the
   --  only group a process may address without being a group leader. In a
   --  test runner that is this process and the shell that started it, and a
   --  shell treats the event as an ordinary interrupt.
   Own_Console_Group : constant Interfaces.C.unsigned_long := 0;

   SIGINT : constant Interfaces.C.int := 2;

   -------------
   -- Request --
   -------------

   function Request return Boolean is
   begin
      if Generate_Console_Ctrl_Event (Ctrl_C_Event, Own_Console_Group) /= 0
      then
         return True;
      end if;

      --  No console to send it to. Fall back rather than report failure: the
      --  assertion that follows is about whether the token was set, and that
      --  is the more useful thing to hear from.
      return C_Raise (SIGINT) = 0;
   end Request;

end Raise_Interrupt;
