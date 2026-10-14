with Ada.Exceptions;
with Ada.Interrupts;
with Ada.Interrupts.Names;
with Ada.Real_Time.Timing_Events;

with Hostkit.Descriptors;
with Hostkit.Signals;

with Model_Runner.Text;

--  Interrupt handling on Linux and on macOS, which this directory is
--  compiled for both of.
--
--  Nothing here is a number: the interrupt is named through
--  Ada.Interrupts.Names.SIGINT, so the runtime supplies whatever the host
--  calls it and there is no value to be right about on one host and wrong on
--  the other. That is worth saying in a directory where being wrong about
--  exactly that stopped a capture truncating on macOS and nowhere else.
package body Model_Runner.Platform.Signals is

   use type Model_Runner.Cancellation.Token_Reference;

   --  The one process-global object in this crate. A process has a single
   --  interrupt vector, so the handler cannot be per-session; the token it
   --  acts on is still supplied explicitly by whoever installs it.
   --  Ended at once, as told: the runtime's own ending waits on the task
   --  this runs in, and would never come.
   procedure Quick_Exit (Status : Integer)
     with Import, Convention => C, External_Name => "_exit";

   --  Said before ending there, straight to the descriptor: the prompt's
   --  line is ended, and the shell's own starts on a line of its own.
   function Write_Error (Descriptor : Integer; Text : String; Count : Natural) return Integer
     with Import, Convention => C, External_Name => "write";

   Stopped_Line : constant String :=
     ASCII.LF & "stopped: told to end (SIGTERM or SIGHUP)" & ASCII.LF;

   --  How long a run told to end has to end cleanly before it is ended at
   --  once. A clean end is a layer of a token away, or a tensor of a load;
   --  a run that has not ended in this is stuck where nothing asks, and a
   --  stuck run once outlived `timeout`'s SIGTERM and a plain kill by
   --  twelve hours, holding seven gigabytes.
   Ending_Grace : constant Ada.Real_Time.Time_Span := Ada.Real_Time.Seconds (10);

   Forced_Line : constant String :=
     ASCII.LF & "stopped: told to end and did not, so ended at once" & ASCII.LF;

   --  The clock that ends a run which was told to end and did not: a
   --  timing event, so it holds nothing up -- a run that ends cleanly
   --  first leaves it set, and the process is gone before it fires.
   Deadline : Ada.Real_Time.Timing_Events.Timing_Event;

   protected Handler is

      --  Interrupt entry point. It does the least possible work: set the
      --  token and count the interrupt.
      procedure Interrupt;
      pragma Interrupt_Handler (Interrupt);

      --  Told to end: as an interrupt, and remembered; waiting for a line,
      --  the program ends here.
      procedure Ending;
      pragma Interrupt_Handler (Ending);

      procedure Overdue (Event : in out Ada.Real_Time.Timing_Events.Timing_Event);

      procedure Set_Waiting (Value : Boolean; Note : String);
      procedure Hold (Saved : Hostkit.Terminal_Control.Mode);
      procedure Release;
      function Ended return Boolean;
      function Noted return Boolean;

      --  Point the handler at a token.
      procedure Bind (Token : Model_Runner.Cancellation.Token_Reference);

      --  Number of interrupts since the last Bind.
      function Count return Natural;

   private
      Target  : Model_Runner.Cancellation.Token_Reference := null;
      Seen    : Natural := 0;
      Waiting : Boolean := False;
      Told    : Boolean := False;

      --  What an interrupt while waiting says, and whether it was said.
      Said_Text : String (1 .. 240) := [others => ' '];
      Said_Last : Natural := 0;
      Said      : Boolean := False;

      --  The terminal's own mode while it is held raw, put back before
      --  ending at once.
      Mode_Held : Boolean := False;
      Held_Mode : Hostkit.Terminal_Control.Mode;

      procedure Put_Mode_Back;
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
         --  Waiting for a line, the terminal has dropped what was typed:
         --  said now, not once the next line comes.
         if Waiting and then Said_Last > 0 and then not Told then
            declare
               Ignored : constant Integer :=
                 Write_Error (2, Said_Text (1 .. Said_Last), Said_Last);
            begin
               Said := True;
            end;
         elsif not Waiting and then not Told then
            --  The terminal echoed ^C where the line was: what is said of
            --  the stop starts on a line of its own.
            declare
               Ignored : constant Integer := Write_Error (2, [1 => ASCII.LF], 1);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         end if;
      end Interrupt;

      procedure Bind (Token : Model_Runner.Cancellation.Token_Reference) is
      begin
         Target := Token;
         Seen := 0;
      end Bind;

      function Count return Natural is (Seen);

      procedure Put_Mode_Back is
      begin
         if Mode_Held then
            --  And the screen modes a prompt sets: pasted text marked, the
            --  cursor hidden. Left on, the shell after showed ^[[200~ round
            --  every paste. (Not the other screen: leaving one not entered
            --  puts the cursor back where nothing saved it.)
            declare
               Back : constant String :=
                 ASCII.ESC & "[?2004l" & ASCII.ESC & "[?25h";
               Ignored : constant Integer := Write_Error (2, Back, Back'Length);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
            declare
               Ignored : constant Boolean :=
                 Hostkit.Terminal_Control.Restore_Mode
                   (Hostkit.Descriptors.Standard_Input, Held_Mode);
               pragma Unreferenced (Ignored);
            begin
               Mode_Held := False;
            end;
         end if;
      end Put_Mode_Back;

      procedure Hold (Saved : Hostkit.Terminal_Control.Mode) is
      begin
         Held_Mode := Saved;
         Mode_Held := True;
      end Hold;

      procedure Release is
      begin
         Mode_Held := False;
      end Release;

      procedure Overdue (Event : in out Ada.Real_Time.Timing_Events.Timing_Event) is
         pragma Unreferenced (Event);
         Ignored : constant Integer := Write_Error (2, Forced_Line, Forced_Line'Length);
         pragma Unreferenced (Ignored);
      begin
         Put_Mode_Back;
         Quick_Exit (7);
      end Overdue;

      procedure Ending is
         use type Ada.Real_Time.Time;
      begin
         --  Told twice: the first was not enough, so this one is.
         if Told then
            Overdue (Deadline);
         end if;

         Told := True;
         Interrupt;
         Ada.Real_Time.Timing_Events.Set_Handler
           (Deadline, Ada.Real_Time.Clock + Ending_Grace, Overdue'Access);
         if Waiting then
            declare
               Ignored : constant Integer := Write_Error (2, Stopped_Line, Stopped_Line'Length);
               --  What was half typed goes with it, not to the shell.
               Dropped : constant Boolean :=
                 Hostkit.Terminal_Control.Discard_Input (Hostkit.Descriptors.Standard_Input);
               pragma Unreferenced (Ignored, Dropped);
            begin
               null;
            end;
            Put_Mode_Back;
            Quick_Exit (7);
         end if;
      end Ending;

      procedure Set_Waiting (Value : Boolean; Note : String) is
         Line : constant String := ASCII.LF & Note;
      begin
         Waiting := Value;
         if Value then
            Said := False;
            Said_Last := (if Note = "" then 0 else Natural'Min (Line'Length, Said_Text'Length));
            Said_Text (1 .. Said_Last) := Line (Line'First .. Line'First + Said_Last - 1);
         end if;
      end Set_Waiting;

      function Noted return Boolean is (Said);

      function Ended return Boolean is (Told);

   end Handler;

   --  SIGINT left reserved to the runtime: a stand-alone library linked in
   --  -- sshlib, through versionlib -- initialises the tasking runtime from
   --  its own constructor before this program's pragma
   --  Unreserve_All_Interrupts is set, and the runtime then refuses to let
   --  any handler be attached. Reserved, SIGINT is kept unmasked in every
   --  thread, so the host's own handler -- Hostkit.Signals records the
   --  arrival -- is sure to see it, and this task hands each arrival to the
   --  same Handler.Interrupt.
   Recording : Boolean := False
     with Atomic;

   --  And SIGTERM and SIGHUP, always. Attached through the runtime, they
   --  were waited for by its server task, while every thread the runtime
   --  had not made -- the main one among them, the runtime started early
   --  by that same constructor -- left them unblocked at their default:
   --  being told to end killed the process where it stood, the terminal
   --  left raw at the prompt, a run's caches unsaved. Recorded by the
   --  host's handler, which any thread runs, and handed to Handler.Ending.
   Recording_Ends : Boolean := False
     with Atomic;

   task Interrupt_Watch is
      entry Start;
   end Interrupt_Watch;

   task body Interrupt_Watch is
   begin
      loop
         select
            accept Start;
         or
            terminate;
         end select;
         while Recording or else Recording_Ends loop
            if Recording and then Hostkit.Signals.Arrived (Hostkit.Signals.Signal_Interrupt) then
               Hostkit.Signals.Clear (Hostkit.Signals.Signal_Interrupt);
               Handler.Interrupt;
            end if;
            if Recording_Ends then
               if Hostkit.Signals.Arrived (Hostkit.Signals.Signal_Terminate) then
                  Hostkit.Signals.Clear (Hostkit.Signals.Signal_Terminate);
                  Handler.Ending;
               end if;
               if Hostkit.Signals.Arrived (Hostkit.Signals.Signal_Hangup) then
                  Hostkit.Signals.Clear (Hostkit.Signals.Signal_Hangup);
                  Handler.Ending;
               end if;
            end if;
            --  Started again while it still watches -- removed and installed
            --  within one look -- it watches on.
            select
               accept Start;
            or
               delay 0.05;
            end select;
         end loop;
      end loop;
   end Interrupt_Watch;

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

      --  An interrupt, and being told to end -- by a timeout, a closed
      --  terminal, a service manager -- end the run the same clean way:
      --  what it started is stopped, and nothing is left holding the
      --  project.
      if not Attached then
         if not Ada.Interrupts.Is_Reserved (Ada.Interrupts.Names.SIGINT) then
            Ada.Interrupts.Attach_Handler
              (Handler.Interrupt'Access, Ada.Interrupts.Names.SIGINT);
         elsif Hostkit.Signals.Set_Disposition
                 (Hostkit.Signals.Signal_Interrupt, Hostkit.Signals.Disposition_Record)
         then
            Hostkit.Signals.Clear (Hostkit.Signals.Signal_Interrupt);
            Recording := True;
            Interrupt_Watch.Start;
         else
            raise Program_Error with "interrupt 2 is reserved, and the host would not record it";
         end if;
         if Hostkit.Signals.Set_Disposition
                 (Hostkit.Signals.Signal_Terminate, Hostkit.Signals.Disposition_Record)
           and then Hostkit.Signals.Set_Disposition
                      (Hostkit.Signals.Signal_Hangup, Hostkit.Signals.Disposition_Record)
         then
            Hostkit.Signals.Clear (Hostkit.Signals.Signal_Terminate);
            Hostkit.Signals.Clear (Hostkit.Signals.Signal_Hangup);
            Recording_Ends := True;
            if not Recording then
               Interrupt_Watch.Start;
            end if;
         else
            raise Program_Error with "the ending signals are reserved, and the host would not record them";
         end if;
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
             (Ada.Exceptions.Exception_Name (Occurrence)
              & (if Ada.Exceptions.Exception_Message (Occurrence) = "" then ""
                 else ": " & Ada.Exceptions.Exception_Message (Occurrence)));
   end Install;

   ------------
   -- Remove --
   ------------

   procedure Remove is
      Ignored : Boolean;
   begin
      Handler.Bind (null);

      if Attached then
         if Recording then
            Recording := False;
            Ignored := Hostkit.Signals.Set_Disposition
              (Hostkit.Signals.Signal_Interrupt, Hostkit.Signals.Disposition_Default);
         else
            Ada.Interrupts.Detach_Handler (Ada.Interrupts.Names.SIGINT);
         end if;
         Recording_Ends := False;
         Ignored := Hostkit.Signals.Set_Disposition
           (Hostkit.Signals.Signal_Terminate, Hostkit.Signals.Disposition_Default);
         Ignored := Hostkit.Signals.Set_Disposition
           (Hostkit.Signals.Signal_Hangup, Hostkit.Signals.Disposition_Default);
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

   procedure Hold_Terminal_Mode (Saved : Hostkit.Terminal_Control.Mode) is
   begin
      Handler.Hold (Saved);
   end Hold_Terminal_Mode;

   procedure Release_Terminal_Mode is
   begin
      Handler.Release;
   end Release_Terminal_Mode;

   procedure Set_Waiting_For_Input (Waiting : Boolean; Note : String := "") is
   begin
      Handler.Set_Waiting (Waiting, Note);
   end Set_Waiting_For_Input;

   function Interrupt_Noted return Boolean is (Handler.Noted);

   function Ending_Asked return Boolean is (Handler.Ended);

   -------------------
   -- Failure_Name --
   -------------------

   function Failure_Name return String
   is (Model_Runner.Text.To_String (Last_Failure));

end Model_Runner.Platform.Signals;
