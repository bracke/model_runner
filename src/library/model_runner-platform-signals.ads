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
--  run at the next checkpoint. A process that must be stopped sooner can still
--  be sent SIGTERM or SIGKILL, which this crate does not intercept.
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
   --  Installing over an existing installation replaces the target token.
   --
   --  @param Token Token to set when an interrupt arrives.
   --  @param Installed True when the handler was attached.
   procedure Install
     (Token     : Model_Runner.Cancellation.Token_Reference;
      Installed : out Boolean);

   --  Stop routing interrupts and restore the previous behaviour. Idempotent.
   procedure Remove;

   --  Name of the exception the last failed Install raised, for diagnosis.
   --
   --  @return Exception name, or an empty string when Install has succeeded.
   function Failure_Name return String;

   --  Number of interrupts seen since the handler was installed.
   --
   --  @return Interrupt count.
   function Interrupts return Natural;

end Model_Runner.Platform.Signals;
