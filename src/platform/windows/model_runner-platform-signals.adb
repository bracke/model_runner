with System;
with Interfaces.C;

with Model_Runner.Text;

--  Interrupt-driven cancellation on Windows.
--
--  Ada.Interrupts has no path from a console control event here, which is not
--  a guess: the handler installs, the operating system accepts an interrupt
--  raised either by the C runtime or by GenerateConsoleCtrlEvent, and the
--  cancellation token is never set. Both were tried.
--
--  So the console event is taken directly, through SetConsoleCtrlHandler. The
--  difficulty is that Windows runs that callback on a thread of its own making
--  -- one the Ada runtime has never seen. Calling a protected operation from
--  such a thread is not defined, and Cancellation.Token is a protected type,
--  so the callback must not touch it.
--
--  The callback therefore does one thing: store True in an atomic Boolean. A
--  single task, started when a handler is installed and stopped when it is
--  removed, polls that Boolean and does the protected work from a proper Ada
--  context. Nothing crosses the boundary except one scalar.
package body Model_Runner.Platform.Signals is

   use type Interfaces.C.int;
   use type Model_Runner.Cancellation.Token_Reference;
   use type Interfaces.C.unsigned_long;

   --  Written by a thread Windows owns, read by the poller. Atomic is the
   --  whole of the synchronization, and the whole of what the foreign thread
   --  is allowed to do.
   Raised : Boolean := False
     with Atomic, Volatile;

   --  The one process-global object in this crate. A process has a single
   --  interrupt vector, so the handler cannot be per-session; the token it
   --  acts on is still supplied explicitly by whoever installs it.
   protected Handler is

      --  Set the token and count the interrupt.
      procedure Interrupt;

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

   --  Carries the event from the foreign thread into Ada. It is bounded: one
   --  task, started on Install and stopped on Remove, and a partition that
   --  never installs a handler terminates it without ever starting it.
   task Poller is
      entry Start;
      entry Stop;
   end Poller;

   task body Poller is
      Running : Boolean;
   begin
      loop
         select
            accept Start;
            Running := True;
         or
            terminate;
         end select;

         while Running loop
            select
               accept Stop;
               Running := False;
            or
               --  Short enough that an interrupt feels immediate, long
               --  enough that an idle process is not spinning.
               delay 0.005;

               if Raised then
                  Raised := False;
                  Handler.Interrupt;
               end if;
            end select;
         end loop;
      end loop;
   end Poller;

   --  Windows calls this on its own thread. It stores one Boolean and returns
   --  true to say the event was handled, which is what stops the default
   --  action from ending the process.
   function Console_Handler
     (Event : Interfaces.C.unsigned_long) return Interfaces.C.int;
   pragma Convention (Stdcall, Console_Handler);

   function Console_Handler
     (Event : Interfaces.C.unsigned_long) return Interfaces.C.int is
   begin
      --  Ctrl+C and Ctrl+Break both mean "stop what you are doing".
      if Event = 0 or else Event = 1 then
         Raised := True;
         return 1;
      end if;

      return 0;
   end Console_Handler;

   function Set_Console_Ctrl_Handler
     (Handler : System.Address;
      Add     : Interfaces.C.int) return Interfaces.C.int
   with Import, Convention => Stdcall,
        External_Name => "SetConsoleCtrlHandler";

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
         if Set_Console_Ctrl_Handler (Console_Handler'Address, 1) = 0 then
            Last_Failure :=
              Model_Runner.Text.To_Bounded ("SetConsoleCtrlHandler refused");
            Installed := False;
            return;
         end if;

         Raised := False;
         Poller.Start;
         Attached := True;
      end if;

      Installed := True;
   exception
      when others =>
         Last_Failure :=
           Model_Runner.Text.To_Bounded ("the console handler could not be installed");
         Attached := False;
         Installed := False;
   end Install;

   ------------
   -- Remove --
   ------------

   procedure Remove is
   begin
      if Attached then
         if Set_Console_Ctrl_Handler (Console_Handler'Address, 0) = 0 then
            null;
         end if;
         Poller.Stop;
         Attached := False;
      end if;

      Handler.Bind (null);
      Raised := False;
   exception
      when others =>
         Attached := False;
   end Remove;

   ----------------
   -- Interrupts --
   ----------------

   function Interrupts return Natural is (Handler.Count);

   ------------------
   -- Failure_Name --
   ------------------

   function Failure_Name return String
   is (Model_Runner.Text.To_String (Last_Failure));

end Model_Runner.Platform.Signals;
