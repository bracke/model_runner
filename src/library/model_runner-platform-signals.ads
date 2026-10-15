with Hostkit.Terminal_Control;

with Model_Runner.Cancellation;

--  Interrupt-driven cancellation.
--
--  An interrupt at the terminal requests a clean cancellation rather than
--  killing the process: the token is set, and the work observes it at its next
--  bounded checkpoint. Model loading checks between tensors and between parser
--  sections, and generation checks between layers and between tokens, so the
--  documented worst-case latency is one transformer layer of one token.
--
--  A cancelled run releases every resource it acquired and commits no cache
--  position, which is what makes interrupting safe rather than merely fast.
--
--  Scope. There is exactly one interrupt vector in a process, so the handler
--  is the one piece of unavoidable process-global state in this crate. It is
--  installed only for the duration of a command that can be interrupted, and
--  removed afterwards, so no other command has its interrupt behaviour
--  changed.
--
--  A second interrupt is not treated specially: the first one already ends the
--  run at the next checkpoint. Being told to end -- SIGTERM, SIGHUP -- cancels
--  the same way, and where the program has not ended ten seconds later it ends
--  at once, status 7, as it does on being told a second time: a run stuck
--  where no checkpoint is reached would otherwise outlive every request but
--  SIGKILL.
--
--  Task safety: Install and Remove are called by the task that owns the
--  command; the handler runs in its own context and touches only the token.
package Model_Runner.Platform.Signals is

   --  Report whether interrupt handling is available on this host.
   --
   --  @return True when Install can attach a handler.
   function Is_Supported return Boolean;

   --  Route interrupts to a cancellation token.
   --
   --  Installing over an existing installation replaces the target token,
   --  and nests: the program installs for its whole life, a run for its own
   --  token, and the run's Remove gives the binding back to the program's.
   --  A signal ignored when the first Install comes -- a job started under
   --  nohup, or with & from a script -- is left ignored.
   --
   --  @param Token Token to set when an interrupt arrives.
   --  @param Installed True when the handler was attached.
   procedure Install
     (Token     : Model_Runner.Cancellation.Token_Reference;
      Installed : out Boolean);

   --  Undo the latest Install: the token bound before it is bound again,
   --  and the last Remove gives every signal back what it did before the
   --  first Install. A Remove with none to undo binds nothing and detaches
   --  whatever is attached.
   procedure Remove;

   --  Name of the exception the last failed Install raised, for diagnosis.
   --
   --  @return Exception name, or an empty string when Install has succeeded.
   function Failure_Name return String;

   --  Number of interrupts seen since the handler was installed.
   --
   --  @return Interrupt count.
   function Interrupts return Natural;

   --  Say whether the program waits for a line typed at its terminal: told
   --  to end then -- by a service manager, a closed terminal -- it ends at
   --  once, cancelled, having nothing under way to stop.
   --
   --  @param Waiting True while it waits.
   --  @param Note Said at once, on a line of its own, when an interrupt
   --    comes while it waits: the terminal has dropped the line typed so
   --    far. It ends as the caller wants the line after it to begin -- with
   --    the prompt again, say.
   procedure Set_Waiting_For_Input (Waiting : Boolean; Note : String := "");

   --  Whether the program is said to wait for a typed line.
   --
   --  @return True between Set_Waiting_For_Input (True) and (False).
   function Waiting_For_Input return Boolean;

   --  Say what the terminal's own mode was while the program holds it raw:
   --  told to end there, it ends at once, and puts that mode back first --
   --  a terminal left raw does not echo, and the remedy is `reset` typed
   --  blind.
   --
   --  @param Saved The mode Save_Mode read before raw mode was set.
   procedure Hold_Terminal_Mode (Saved : Hostkit.Terminal_Control.Mode);

   --  The terminal has its own mode back; nothing to put back on ending.
   procedure Release_Terminal_Mode;

   --  Say whether the program draws on the terminal's other screen while it
   --  holds the terminal: told to end there, it leaves that screen first,
   --  or the shell's prompt comes back on a screen nothing shows again.
   --
   --  @param On True once the other screen is entered, False once left.
   procedure Note_Alternate_Screen (On : Boolean);

   --  Whether the note was said for an interrupt since the program last
   --  began to wait: what it says need not be said again.
   --
   --  @return True once said.
   function Interrupt_Noted return Boolean;

   --  Whether the program has been told to end, as an interrupt is not.
   --
   --  @return True after a termination or hang-up signal.
   function Ending_Asked return Boolean;

end Model_Runner.Platform.Signals;
