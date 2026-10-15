with Hostkit.Host;
with Model_Runner.Text;

package body Model_Runner.CLI.Partials is

   --  Writes may come from more than one task of a run.
   protected Writes is
      procedure Next (Number : out Natural);
   private
      Count : Natural := 0;
   end Writes;

   protected body Writes is
      procedure Next (Number : out Natural) is
      begin
         Count := Count + 1;
         Number := Count;
      end Next;
   end Writes;

   ------------
   -- Beside --
   ------------

   function Beside (Path : String) return String is
      Number : Natural;
   begin
      Writes.Next (Number);
      return Path & "."
        & Model_Runner.Text.Trim
            (Integer'Image (Hostkit.Host.Own_Process_Id))
        & "-" & Model_Runner.Text.Trim (Natural'Image (Number)) & ".partial";
   end Beside;

end Model_Runner.CLI.Partials;
