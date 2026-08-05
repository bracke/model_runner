with Interfaces.C;

package body Raise_Interrupt is

   use type Interfaces.C.int;

   --  Windows has no kill. The C runtime's raise delivers to the handler the
   --  runtime installed for SIGINT, on the calling thread and synchronously,
   --  which is how signals reach a program here. GenerateConsoleCtrlEvent is
   --  the other candidate and was not used: it needs a console attached, and
   --  a test runner does not always have one.
   function C_Raise (Signal : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => C, External_Name => "raise";

   SIGINT : constant Interfaces.C.int := 2;

   -------------
   -- Request --
   -------------

   function Request return Boolean is (C_Raise (SIGINT) = 0);

end Raise_Interrupt;
