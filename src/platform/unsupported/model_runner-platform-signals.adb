with Model_Runner.Text;

--  Interrupt-driven cancellation on a host neither the POSIX nor the Windows
--  body covers.
--
--  Is_Supported answers False and Install refuses, which is the honest answer
--  rather than a handler that silently never fires. Cancellation itself still
--  works: the token can be requested by any caller that holds it, and only the
--  route from an operating-system interrupt is missing here.
package body Model_Runner.Platform.Signals is

   Last_Failure : constant Model_Runner.Text.Bounded :=
     Model_Runner.Text.To_Bounded ("this host has no interrupt path");

   function Is_Supported return Boolean is (False);

   procedure Install
     (Token     : Model_Runner.Cancellation.Token_Reference;
      Installed : out Boolean)
   is
      pragma Unreferenced (Token);
   begin
      Installed := False;
   end Install;

   procedure Remove is null;

   function Interrupts return Natural is (0);

   function Failure_Name return String
   is (Model_Runner.Text.To_String (Last_Failure));

end Model_Runner.Platform.Signals;
