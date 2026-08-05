with Ada.Exceptions;
with Ada.Interrupts;
with Ada.Interrupts.Names;

with Model_Runner.Text;

package body Model_Runner.Platform.Signals is

   use type Model_Runner.Cancellation.Token_Reference;

   --  The one process-global object in this crate. A process has a single
   --  interrupt vector, so the handler cannot be per-session; the token it
   --  acts on is still supplied explicitly by whoever installs it.
   protected Handler is

      --  Interrupt entry point. It does the least possible work: set the
      --  token and count the interrupt.
      procedure Interrupt;
      pragma Interrupt_Handler (Interrupt);

      --  Point the handler at a token.
      procedure Bind (Token : Model_Runner.Cancellation.Token_Reference);

      --  Number of interrupts since the last Bind.
      function Count return Natural;

   private
      Target : Model_Runner.Cancellation.Token_Reference := null;
      Seen   : Natural := 0;
   end Handler;

   protected body Handler is

      procedure Interrupt is
      begin
         if Seen < Natural'Last then
            Seen := Seen + 1;
         end if;

         if Target /= null then
            Target.all.Request;
         end if;
      end Interrupt;

      procedure Bind (Token : Model_Runner.Cancellation.Token_Reference) is
      begin
         Target := Token;
         Seen := 0;
      end Bind;

      function Count return Natural is (Seen);

   end Handler;

   Attached : Boolean := False;
   Last_Failure : Model_Runner.Text.Bounded;

   ------------------
   -- Is_Supported --
   ------------------

   function Is_Supported return Boolean is (True);

   -------------
   -- Install --
   -------------

   procedure Install
     (Token     : Model_Runner.Cancellation.Token_Reference;
      Installed : out Boolean) is
   begin
      Handler.Bind (Token);

      if not Attached then
         Ada.Interrupts.Attach_Handler
           (Handler.Interrupt'Access, Ada.Interrupts.Names.SIGINT);
         Attached := True;
      end if;

      Installed := True;
   exception
      --  A host that will not let this process take the interrupt is not a
      --  failure: the command simply cannot be interrupted cleanly.
      when Occurrence : others =>
         Attached := False;
         Installed := False;
         Last_Failure :=
           Model_Runner.Text.To_Bounded
             (Ada.Exceptions.Exception_Name (Occurrence));
   end Install;

   ------------
   -- Remove --
   ------------

   procedure Remove is
   begin
      Handler.Bind (null);

      if Attached then
         Ada.Interrupts.Detach_Handler (Ada.Interrupts.Names.SIGINT);
         Attached := False;
      end if;
   exception
      when others =>
         Attached := False;
   end Remove;

   ----------------
   -- Interrupts --
   ----------------

   function Interrupts return Natural is (Handler.Count);

   -------------------
   -- Failure_Name --
   -------------------

   function Failure_Name return String
   is (Model_Runner.Text.To_String (Last_Failure));

end Model_Runner.Platform.Signals;
