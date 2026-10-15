with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with AUnit.Assertions;
with AUnit.Test_Cases;

with GNAT.OS_Lib;
with Interfaces;
with System;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Durability;
with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Process;
with Hostkit.Pty;
with Hostkit.Signals;
with Hostkit.Spawn;
with Hostkit.Terminal_Control;
with Hostkit.Terminal_Control.Differences;

with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Platform;
with Model_Runner.Platform.Mapped_Ranges;
with Model_Runner.Platform.Mapping;
with Model_Runner.Platform.Signals;
with Model_Runner.Platform.Signals.Waiting;

with Tiny_Model;

package body Tests.Platform_Cases is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Hostkit.Signals.Disposition;

   package Signals renames Model_Runner.Platform.Signals;
   package Mapping renames Model_Runner.Platform.Mapping;

   --  The suite's own command, the probe a test watches from outside.
   function Tests_Program return String is
     (Ada.Directories.Full_Name
        (if Ada.Directories.Exists ("bin/tests") then "bin/tests"
         else "bin/tests.exe"));

   --  The first number in Text, or -1.
   function Number_At (Text : String; From : in out Natural) return Integer is
      First : Natural := From;
   begin
      while First <= Text'Last and then Text (First) not in '0' .. '9' loop
         First := First + 1;
      end loop;
      if First > Text'Last then
         return -1;
      end if;
      From := First;
      while From <= Text'Last and then Text (From) in '0' .. '9' loop
         From := From + 1;
      end loop;
      return Integer'Value (Text (First .. From - 1));
   end Number_At;

   function Read_Whole (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Said : Unbounded_String;
   begin
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Said, Ada.Text_IO.Get_Line (File) & ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Said);
   end Read_Whole;

   ------------------------------------------------------------------------
   --  Interrupts and endings
   ------------------------------------------------------------------------

   --  A process that ends with its interrupt handling still installed --
   --  as one whose run raised past its own clean-up did -- ends. The task
   --  that watched for the recorded signals had no way out but Remove, and
   --  the program's ending waited on it for ever after saying what went
   --  wrong.
   procedure A_Process_Leaving_Its_Handler_Installed_Ends
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Words    : Hostkit.String_Vectors.Vector;
      Happened : Hostkit.Process.Process_Outcome;
   begin
      Words.Append (To_Unbounded_String ("probe"));
      Words.Append (To_Unbounded_String ("leave-signals"));
      Happened := Hostkit.Process.Run_Captured
        (Tests_Program, Words, Stdout_Path => "obj/probe-leave.out",
         Timeout_Ms => 20_000);
      Assert (Happened.Started, "the probe did not start");
      Assert (not Happened.Timed_Out,
              "a process that ended with its interrupt handling installed "
              & "did not end in twenty seconds");
      Assert (Happened.Exit_Status = 0,
              "the probe ended with status" & Integer'Image (Happened.Exit_Status));
      Assert (Ada.Strings.Fixed.Index (Read_Whole ("obj/probe-leave.out"), "installed TRUE") > 0,
              "the probe did not install, so its ending says nothing");
   end A_Process_Leaving_Its_Handler_Installed_Ends;

   --  A signal ignored when the handling is installed stays ignored, and is
   --  given back ignored: a job started under nohup ignores SIGHUP, and the
   --  run took it over and set it to end the program -- the closing
   --  terminal ended the run nohup was asked to keep, and Remove gave it
   --  the default after.
   procedure An_Ignored_Signal_Is_Left_Ignored
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Token    : aliased Model_Runner.Cancellation.Token;
      Attached : Boolean;
      Now      : Hostkit.Signals.Disposition;
   begin
      if not Hostkit.Signals.Can_Record (Hostkit.Signals.Signal_Hangup) then
         Ada.Text_IO.Put_Line ("note: this host records no hang-ups; not checked");
         return;
      end if;
      Assert (Hostkit.Signals.Set_Disposition
                (Hostkit.Signals.Signal_Hangup, Hostkit.Signals.Disposition_Ignore),
              "SIGHUP could not be ignored");
      Signals.Install (Token'Unchecked_Access, Attached);
      Assert (Attached, "the handling was not installed: " & Signals.Failure_Name);
      Assert (Hostkit.Signals.Current_Disposition (Hostkit.Signals.Signal_Hangup, Now),
              "SIGHUP's disposition could not be read");
      Assert (Now = Hostkit.Signals.Disposition_Ignore,
              "an ignored SIGHUP was taken over by the run");
      Assert (Hostkit.Signals.Current_Disposition (Hostkit.Signals.Signal_Terminate, Now),
              "SIGTERM's disposition could not be read");
      Assert (Now /= Hostkit.Signals.Disposition_Ignore,
              "SIGTERM, which was not ignored, was not taken");
      Signals.Remove;
      Assert (Hostkit.Signals.Current_Disposition (Hostkit.Signals.Signal_Hangup, Now),
              "SIGHUP's disposition could not be read back");
      Assert (Now = Hostkit.Signals.Disposition_Ignore,
              "SIGHUP was given back as other than ignored");
      Assert (Hostkit.Signals.Set_Disposition
                (Hostkit.Signals.Signal_Hangup, Hostkit.Signals.Disposition_Default),
              "SIGHUP could not be given its default back");
   end An_Ignored_Signal_Is_Left_Ignored;

   --  Installs nest: the program's lasts its life, a run's binds the run's
   --  token, and the run's Remove gives the binding back -- an interrupt
   --  after it reaches the outer token.
   procedure Installs_Nest_And_Remove_Gives_The_Binding_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Outer, Inner : aliased Model_Runner.Cancellation.Token;
      Attached     : Boolean;
   begin
      if not Hostkit.Signals.Is_Supported (Hostkit.Signals.Signal_Interrupt) then
         Ada.Text_IO.Put_Line ("note: this host sends no interrupts; not checked");
         return;
      end if;
      Signals.Install (Outer'Unchecked_Access, Attached);
      Assert (Attached, "the outer handling was not installed");
      Signals.Install (Inner'Unchecked_Access, Attached);
      Assert (Attached, "the inner handling was not installed");
      Signals.Remove;
      Assert (Hostkit.Signals.Send_To_Process
                (Hostkit.Host.Own_Process_Id, Hostkit.Signals.Signal_Interrupt),
              "an interrupt could not be sent to this process");
      for Turn in 1 .. 60 loop
         exit when Outer.Is_Requested;
         delay 0.05;
      end loop;
      Signals.Remove;
      Assert (Outer.Is_Requested,
              "an interrupt after the inner Remove did not reach the outer token");
      Assert (not Inner.Is_Requested,
              "an interrupt after the inner Remove reached the inner token");
   end Installs_Nest_And_Remove_Gives_The_Binding_Back;

   --  A wait for a line is said over however its scope is left: an
   --  exception past the wait left the program said to wait, and told to
   --  end after it ended at once, the run's caches unsaved.
   procedure A_Wait_Ends_With_Its_Scope
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      begin
         declare
            Held : Signals.Waiting.Guard;
         begin
            Signals.Waiting.Begin_Wait (Held);
            if not Signals.Waiting_For_Input then
               Ada.Text_IO.Put_Line ("note: this host keeps no waiting flag; not checked");
               return;
            end if;
            raise Constraint_Error with "past the wait";
         end;
      exception
         when Constraint_Error =>
            null;
      end;
      Assert (not Signals.Waiting_For_Input,
              "a wait left by an exception was still said to wait");

      --  And ended early by its holder, which says it once and again.
      declare
         Held : Signals.Waiting.Guard;
      begin
         Signals.Waiting.Begin_Wait (Held);
         Signals.Waiting.Stop_Wait (Held);
         Assert (not Signals.Waiting_For_Input,
                 "a wait stopped by its holder was still said to wait");
         Signals.Waiting.Stop_Wait (Held);
         Assert (not Signals.Waiting_For_Input,
                 "a wait stopped twice was said to wait again");
      end;
   end A_Wait_Ends_With_Its_Scope;

   --  Told to end while a chooser holds the terminal in a session: the
   --  chooser lets go at once, the terminal put back as it was and its
   --  other screen left, and the run ends. The list never looked at the
   --  ending, so it held on for the ten seconds the run is given, and the
   --  forced ending after gave the mode back but not the screen: the shell
   --  came back on a screen nothing showed again.
   procedure An_Ending_Gives_A_Chooser_Terminal_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Hostkit.Descriptors.Descriptor;
      use type Hostkit.Spawn.Spawn_Outcome;
      use type Hostkit.Spawn.Wait_State;
      use type Ada.Streams.Stream_Element_Offset;
      --  The name the linker gives it, which differs by host.
      Plain   : constant String :=
        (if Ada.Directories.Exists ("../bin/model_runner")
         then "../bin/model_runner" else "../bin/model_runner.exe");
      Model   : constant String := Ada.Directories.Full_Name ("obj/chooser-model.gguf");
      Here    : constant String := Ada.Directories.Full_Name ("obj/chooser-project");
      Pair    : Hostkit.Pty.Pair;
      Options : Hostkit.Spawn.Options;
      Child   : Hostkit.Spawn.Process_Handle;
      Result  : Hostkit.Spawn.Status;
      Before, After : Hostkit.Terminal_Control.Mode;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
      Last    : Ada.Streams.Stream_Element_Offset;
      Was, Became : Interfaces.Unsigned_8;
      Words   : Hostkit.String_Vectors.Vector;
      Said    : Unbounded_String;
      Ended   : Boolean := False;

      procedure Keep_Variable (Name, Value : String) is
      begin
         if Name /= "TERM" then
            Options.Environment.Append (To_Unbounded_String (String'(Name & "=" & Value)));
         end if;
      end Keep_Variable;

      procedure Gather is
      begin
         while Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 50) loop
            exit when Hostkit.Descriptors."/="
                        (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                         Hostkit.Descriptors.Transfer_Ok)
              or else Last < Buffer'First;
            for Byte of Buffer (Buffer'First .. Last) loop
               Append (Said, Character'Val (Byte));
            end loop;
         end loop;
      end Gather;

      function Shows (Text : String) return Boolean is
        (Ada.Strings.Fixed.Index (To_String (Said), Text) > 0);

      procedure Type_In (Text : String) is
         Bytes : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
      begin
         for Index in Text'Range loop
            Bytes (Ada.Streams.Stream_Element_Offset (Index - Text'First + 1)) :=
              Character'Pos (Text (Index));
         end loop;
         Assert (Hostkit.Descriptors."=" (Hostkit.Descriptors.Write (Pair.To_Child, Bytes, Last),
                                          Hostkit.Descriptors.Transfer_Ok),
                 "the line was not typed");
      end Type_In;
   begin
      if not Ada.Directories.Exists (Plain) then
         Ada.Text_IO.Put_Line ("note: model_runner is not built at " & Plain & "; not checked");
         return;
      end if;
      if not Hostkit.Pty.Is_Supported or else not Hostkit.Pty.Open (Pair)
        or else Pair.Device = Hostkit.Descriptors.Invalid
      then
         Ada.Text_IO.Put_Line ("note: no pseudo-terminal device here; not checked");
         return;
      end if;

      Tiny_Model.Write (Model);
      if Ada.Directories.Exists (Here) then
         Ada.Directories.Delete_Tree (Here);
      end if;
      Ada.Directories.Create_Path (Here);

      Ada.Environment_Variables.Iterate (Keep_Variable'Access);
      Options.Environment.Append (To_Unbounded_String ("TERM=xterm"));
      Options.Replace_Environment := True;
      Options.Working_Directory := To_Unbounded_String (Here);
      Assert (Hostkit.Pty.Set_Size (Pair, (Rows => 24, Columns => 80)),
              "the pseudo-terminal was not sized");
      Assert (Hostkit.Pty.Attach (Pair, Options), "the pseudo-terminal was not attached");
      Assert (Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, Before),
              "the terminal's mode was not read");
      Words.Append (To_Unbounded_String ("run"));
      Words.Append (To_Unbounded_String (Model));
      Assert (Hostkit.Spawn.Start (Ada.Directories.Full_Name (Plain), Words, Options, Child)
              = Hostkit.Spawn.Spawn_Ok, "model_runner did not start");
      Hostkit.Pty.Close_Device (Pair);

      --  The session's prompt, and then a command that offers a list.
      for Try in 1 .. 200 loop
         Gather;
         exit when Shows ("> ");
      end loop;
      Type_In ("/init" & ASCII.CR);
      for Try in 1 .. 200 loop
         Gather;
         exit when Shows (ASCII.ESC & "[?1049h");
      end loop;
      Assert (Shows (ASCII.ESC & "[?1049h"),
              "the session drew no list on a screen of its own, so nothing is checked: "
              & To_String (Said));

      Assert (Hostkit.Signals.Send_To_Process
                (Hostkit.Spawn.Process_Id (Child), Hostkit.Signals.Signal_Terminate),
              "SIGTERM could not be sent");
      for Turn in 1 .. 60 loop
         Gather;
         if Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Poll, Result)
           and then Result.State /= Hostkit.Spawn.Wait_Running
         then
            Ended := True;
            exit;
         end if;
         delay 0.05;
      end loop;
      if not Ended then
         --  Not left behind, whatever this test says.
         declare
            Killed : constant Boolean :=
              Hostkit.Signals.Send_To_Process
                (Hostkit.Spawn.Process_Id (Child), Hostkit.Signals.Signal_Kill);
            Waited : constant Boolean :=
              Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Block, Result);
         begin
            Hostkit.Pty.Close (Pair);
            Assert (False, "told to end at a list, the session had not ended in three "
                    & "seconds (killed:" & Boolean'Image (Killed and then Waited) & ")");
         end;
      end if;
      Gather;
      Assert (Result.State = Hostkit.Spawn.Wait_Exited,
              "told to end at a list, the session was killed by the signal rather "
              & "than ending");
      Assert (Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, After),
              "the terminal's mode was not read afterwards");
      Assert (Hostkit.Terminal_Control.Differences.First_Difference (Before, After, Was, Became) = 0,
              "the terminal was left raw after SIGTERM at a list");
      Assert (Shows (ASCII.ESC & "[?1049l"),
              "the list's screen was not left after SIGTERM");
      Hostkit.Pty.Close (Pair);
   end An_Ending_Gives_A_Chooser_Terminal_Back;

   --  Told to end with nothing bound to stop while the terminal is held raw
   --  on its other screen: the program ends at once, the mode and the
   --  screen given back. The forced ending gave the mode back and left the
   --  screen, so the shell's prompt came back where nothing showed it.
   procedure An_Ending_Leaves_The_Other_Screen
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Hostkit.Descriptors.Descriptor;
      use type Hostkit.Spawn.Spawn_Outcome;
      use type Hostkit.Spawn.Wait_State;
      use type Ada.Streams.Stream_Element_Offset;
      Pair    : Hostkit.Pty.Pair;
      Options : Hostkit.Spawn.Options;
      Child   : Hostkit.Spawn.Process_Handle;
      Result  : Hostkit.Spawn.Status;
      Before, After : Hostkit.Terminal_Control.Mode;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
      Last    : Ada.Streams.Stream_Element_Offset;
      Was, Became : Interfaces.Unsigned_8;
      Words   : Hostkit.String_Vectors.Vector;
      Said    : Unbounded_String;
      Ended   : Boolean := False;

      procedure Keep_Variable (Name, Value : String) is
      begin
         if Name /= "TERM" then
            Options.Environment.Append (To_Unbounded_String (String'(Name & "=" & Value)));
         end if;
      end Keep_Variable;

      procedure Gather is
      begin
         while Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 50) loop
            exit when Hostkit.Descriptors."/="
                        (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                         Hostkit.Descriptors.Transfer_Ok)
              or else Last < Buffer'First;
            for Byte of Buffer (Buffer'First .. Last) loop
               Append (Said, Character'Val (Byte));
            end loop;
         end loop;
      end Gather;

      function Shows (Text : String) return Boolean is
        (Ada.Strings.Fixed.Index (To_String (Said), Text) > 0);
   begin
      if not Hostkit.Pty.Is_Supported or else not Hostkit.Pty.Open (Pair)
        or else Pair.Device = Hostkit.Descriptors.Invalid
      then
         Ada.Text_IO.Put_Line ("note: no pseudo-terminal device here; not checked");
         return;
      end if;
      Ada.Environment_Variables.Iterate (Keep_Variable'Access);
      Options.Environment.Append (To_Unbounded_String ("TERM=xterm"));
      Options.Replace_Environment := True;
      Assert (Hostkit.Pty.Attach (Pair, Options), "the pseudo-terminal was not attached");
      Assert (Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, Before),
              "the terminal's mode was not read");
      Words.Append (To_Unbounded_String ("probe"));
      Words.Append (To_Unbounded_String ("hold-screen"));
      Assert (Hostkit.Spawn.Start (Tests_Program, Words, Options, Child)
              = Hostkit.Spawn.Spawn_Ok, "the probe did not start");
      Hostkit.Pty.Close_Device (Pair);
      for Try in 1 .. 200 loop
         Gather;
         exit when Shows ("held");
      end loop;
      Assert (Shows ("held"), "the probe did not hold the terminal: " & To_String (Said));
      Said := Null_Unbounded_String;
      Assert (Hostkit.Signals.Send_To_Process
                (Hostkit.Spawn.Process_Id (Child), Hostkit.Signals.Signal_Terminate),
              "SIGTERM could not be sent");
      for Turn in 1 .. 60 loop
         Gather;
         if Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Poll, Result)
           and then Result.State /= Hostkit.Spawn.Wait_Running
         then
            Ended := True;
            exit;
         end if;
         delay 0.05;
      end loop;
      if not Ended then
         declare
            Killed : constant Boolean :=
              Hostkit.Signals.Send_To_Process
                (Hostkit.Spawn.Process_Id (Child), Hostkit.Signals.Signal_Kill);
            Waited : constant Boolean :=
              Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Block, Result);
         begin
            Hostkit.Pty.Close (Pair);
            Assert (False, "told to end with nothing to stop, the probe had not ended in "
                    & "three seconds (killed:" & Boolean'Image (Killed and then Waited) & ")");
         end;
      end if;
      Gather;
      Assert (Result.State = Hostkit.Spawn.Wait_Exited and then Result.Exit_Code = 7,
              "told to end with nothing to stop, the probe did not end as told");
      Assert (Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, After),
              "the terminal's mode was not read afterwards");
      Assert (Hostkit.Terminal_Control.Differences.First_Difference (Before, After, Was, Became) = 0,
              "the terminal was left raw");
      Assert (Shows (ASCII.ESC & "[?1049l"), "the other screen was not left");
      Hostkit.Pty.Close (Pair);
   end An_Ending_Leaves_The_Other_Screen;

   ------------------------------------------------------------------------
   --  Descriptors and mappings
   ------------------------------------------------------------------------

   --  A mapped model's descriptor is not handed to the programs a run
   --  starts: a tool or a build inheriting it held the model's file on the
   --  disk after it was deleted, for as long as any grandchild lived.
   procedure A_Mapped_File_Is_Not_Inherited
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Path   : constant String := Ada.Directories.Full_Name ("obj/mapped-cloexec.gguf");
      Region : Mapping.Region;
      Ok     : Boolean;
      Found  : Boolean := False;
   begin
      if not Ada.Directories.Exists ("/proc/self/fdinfo") then
         Ada.Text_IO.Put_Line ("note: no /proc/self/fdinfo here; not checked");
         return;
      end if;
      Tiny_Model.Write (Path);
      Mapping.Open (Region, Path, Ok);
      Assert (Ok, "the file was not mapped");
      for Number in 3 .. 1023 loop
         declare
            Image : constant String := Integer'Image (Number);
            Link  : constant String :=
              "/proc/self/fd/" & Image (Image'First + 1 .. Image'Last);
         begin
            if GNAT.OS_Lib.Is_Symbolic_Link (Link)
              and then Hostkit.Fs.Real_Path (Link) = Path
            then
               declare
                  Info  : constant String :=
                    Read_Whole ("/proc/self/fdinfo/" & Image (Image'First + 1 .. Image'Last));
                  At_Flags : constant Natural := Ada.Strings.Fixed.Index (Info, "flags:");
                  From  : Natural := At_Flags + 6;
                  Last  : Natural;
                  Flags : Long_Long_Integer;
               begin
                  Assert (At_Flags > 0, "the descriptor's flags were not read");
                  while From <= Info'Last and then Info (From) = ASCII.HT loop
                     From := From + 1;
                  end loop;
                  Last := From;
                  while Last <= Info'Last and then Info (Last) in '0' .. '7' loop
                     Last := Last + 1;
                  end loop;
                  Flags := Long_Long_Integer'Value ("8#" & Info (From .. Last - 1) & "#");
                  --  O_CLOEXEC, as /proc shows it.
                  Assert ((Flags / 8#2000000#) mod 2 = 1,
                          "the mapped file's descriptor is handed to children");
                  Found := True;
               end;
            end if;
         end;
      end loop;
      Mapping.Close (Region);
      Assert (Found, "the mapped file's descriptor was not found");
   end A_Mapped_File_Is_Not_Inherited;

   --  A region left by an exception is closed with it: its mapping and its
   --  descriptor were kept for the life of the process.
   procedure A_Region_Left_By_An_Exception_Is_Closed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Path : constant String := "obj/mapped-finalized.gguf";
      Base : System.Address := System.Null_Address;
   begin
      Tiny_Model.Write (Path);
      begin
         declare
            Region : Mapping.Region;
            Ok     : Boolean;
         begin
            Mapping.Open (Region, Path, Ok);
            Assert (Ok, "the file was not mapped");
            Base := Mapping.Base (Region);
            Assert (Model_Runner.Platform.Mapped_Ranges.Holds (Base, 1),
                    "an open mapping was not noted");
            raise Constraint_Error with "past the mapping";
         end;
      exception
         when Constraint_Error =>
            null;
      end;
      Assert (not Model_Runner.Platform.Mapped_Ranges.Holds (Base, 1),
              "a mapping left by an exception was still open");
   end A_Region_Left_By_An_Exception_Is_Closed;

   --  A handle located for reading past the cache is the mapping's until the
   --  reader says it holds its own: a region forgotten -- closed -- under
   --  that, its descriptor's number reused, was another file read and
   --  called this one.
   procedure A_Located_Handle_Holds_Its_Mapping
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Room   : aliased Model_Runner.Bytes.Byte_Array (1 .. 64) := [others => 0];
      Handle : Long_Long_Integer;
      Offset : Model_Runner.Bytes.Byte_Count;

      protected Done is
         procedure Say;
         function Said return Boolean;
      private
         Was : Boolean := False;
      end Done;

      protected body Done is
         procedure Say is
         begin
            Was := True;
         end Say;

         function Said return Boolean is (Was);
      end Done;
   begin
      Model_Runner.Platform.Mapped_Ranges.Note (Room'Address, Room'Length, 77);
      Assert (Model_Runner.Platform.Mapped_Ranges.Locate (Room'Address, 8, Handle, Offset),
              "a noted run was not located");
      declare
         task Forgetter;
         task body Forgetter is
         begin
            Model_Runner.Platform.Mapped_Ranges.Forget (Room'Address);
            Done.Say;
         end Forgetter;
      begin
         delay 0.2;
         Assert (not Done.Said
                 and then Model_Runner.Platform.Mapped_Ranges.Holds (Room'Address, 8),
                 "a mapping was forgotten while its located handle was being opened");
         Model_Runner.Platform.Mapped_Ranges.Located_Done;
      end;
      Assert (Done.Said, "the mapping was not forgotten once its handle was let go");
      Assert (not Model_Runner.Platform.Mapped_Ranges.Holds (Room'Address, 8),
              "a forgotten mapping was still noted");
   end A_Located_Handle_Holds_Its_Mapping;

   --  What was written through a shared mapping is put into the file before
   --  the file is synced: only Linux makes a file's fsync cover it.
   procedure A_Written_Mapping_Is_Synced
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Hostkit.Durability.Outcome;
      Path   : constant String := "obj/mapped-synced.bin";
      Region : Mapping.Region;
      Ok     : Boolean;
      File   : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Close (File);
      Mapping.Open_Writable (Region, Path, 8192, Ok);
      if not Ok then
         Ada.Text_IO.Put_Line ("note: this host maps nothing writable; not checked");
         return;
      end if;
      Assert (Hostkit.Durability.Sync_Mapping
                (Mapping.Base (Region), Long_Long_Integer (Mapping.Length (Region)))
              = Hostkit.Durability.Synced,
              "a written mapping could not be synced");
      Mapping.Close (Region);
   end A_Written_Mapping_Is_Synced;

   ------------------------------------------------------------------------
   --  The cache folders
   ------------------------------------------------------------------------

   --  The file a trim keeps is kept however its name is spelled: under a
   --  relative folder, or with a doubled separator, it never matched the
   --  name the search gave it, and the file just written -- the oldest
   --  here -- was the first to go.
   procedure A_Trim_Keeps_The_File_However_It_Is_Named
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Folder : constant String := "obj/trim-keep";

      procedure Write (Name : String; Year : GNAT.OS_Lib.Year_Type) is
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Folder & "/" & Name);
         Ada.Text_IO.Put (File, [1 .. 99 => 'x']);
         Ada.Text_IO.Close (File);
         GNAT.OS_Lib.Set_File_Last_Modify_Time_Stamp
           (Folder & "/" & Name, GNAT.OS_Lib.GM_Time_Of (Year, 1, 1, 0, 0, 0));
      end Write;
   begin
      if Ada.Directories.Exists (Folder) then
         Ada.Directories.Delete_Tree (Folder);
      end if;
      Ada.Directories.Create_Path (Folder);
      Write ("kept.kv", 2020);
      Write ("newer.kv", 2021);
      Model_Runner.Platform.Trim_Directory
        (Folder, "*.kv", 150, Keep => Folder & "//kept.kv");
      Assert (Ada.Directories.Exists (Folder & "/kept.kv"),
              "the file a trim was told to keep, named with a doubled separator under "
              & "a relative folder, was deleted");
      Assert (not Ada.Directories.Exists (Folder & "/newer.kv"),
              "the trim kept the folder over its bound");
      Ada.Directories.Delete_Tree (Folder);
   end A_Trim_Keeps_The_File_However_It_Is_Named;

   --  A relative XDG base directory is ignored, as the specification says:
   --  one relative to wherever the program started put a cache there.
   procedure A_Relative_Base_Directory_Is_Ignored
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Env renames Ada.Environment_Variables;
      Had : constant Boolean := Env.Exists ("XDG_CACHE_HOME");
      Was : constant String := (if Had then Env.Value ("XDG_CACHE_HOME") else "");
   begin
      Env.Set ("XDG_CACHE_HOME", "relative-cache-home");
      declare
         Folder : constant String := Model_Runner.Platform.Cache_Directory;
      begin
         if Had then
            Env.Set ("XDG_CACHE_HOME", Was);
         else
            Env.Clear ("XDG_CACHE_HOME");
         end if;
         Assert (Ada.Strings.Fixed.Index (Folder, "relative-cache-home") = 0,
                 "a relative XDG_CACHE_HOME was taken: " & Folder);
      end;
   end A_Relative_Base_Directory_Is_Ignored;

   ------------------------------------------------------------------------
   --  Processors
   ------------------------------------------------------------------------

   --  A process held to some processors takes that many: `taskset`, a
   --  cpuset or a container left eight to sixteen workers spinning on four,
   --  every product waiting for one descheduled.
   procedure A_Held_Process_Takes_The_Processors_It_Has
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Taskset  : constant String := "/usr/bin/taskset";
      Words    : Hostkit.String_Vectors.Vector;
      Happened : Hostkit.Process.Process_Outcome;
      Usable   : Hostkit.Host.Processor_Set;
      Count    : Natural := 0;
      Siblings : Boolean := False;
   begin
      if not Ada.Directories.Exists (Taskset)
        or else not Hostkit.Host.Usable_Processors (Usable)
      then
         Ada.Text_IO.Put_Line ("note: no taskset, or no affinity to ask; not checked");
         return;
      end if;
      for May of Usable loop
         if May then
            Count := Count + 1;
         end if;
      end loop;
      if Count < 3 then
         Ada.Text_IO.Put_Line ("note: fewer than three processors; not checked");
         return;
      end if;
      --  Two processors of one core where the machine pairs them -- the
      --  first this process may use and its sibling -- so that the cores
      --  are counted over what may be used: one, not the machine's; and
      --  the first two otherwise.
      declare
         Named : Unbounded_String;
         Taken : Natural := 0;
      begin
         for Index in Usable'Range loop
            if Usable (Index) then
               declare
                  Image : constant String := Integer'Image (Index);
                  Own   : constant String := Image (Image'First + 1 .. Image'Last);
                  List  : constant String :=
                    Read_Whole ("/sys/devices/system/cpu/cpu" & Own
                                & "/topology/thread_siblings_list");
                  From  : Natural := List'First;
                  First : constant Integer := Number_At (List, From);
                  Next  : constant Integer :=
                    (if From <= List'Last and then List (From) in ',' | '-'
                     then Number_At (List, From) else -1);
               begin
                  if First = Index and then Next in Usable'Range
                    and then Usable (Next)
                  then
                     declare
                        Other : constant String := Integer'Image (Next);
                     begin
                        Named := To_Unbounded_String
                          (Own & "," & Other (Other'First + 1 .. Other'Last));
                        Siblings := True;
                     end;
                  end if;
               end;
               exit;
            end if;
         end loop;
         if not Siblings then
            for Index in Usable'Range loop
               if Usable (Index) and then Taken < 2 then
                  declare
                     Image : constant String := Integer'Image (Index);
                  begin
                     Append (Named, (if Taken = 0 then "" else ",")
                                    & Image (Image'First + 1 .. Image'Last));
                  end;
                  Taken := Taken + 1;
               end if;
            end loop;
         end if;
         Words.Append (To_Unbounded_String ("-c"));
         Words.Append (Named);
      end;
      Words.Append (To_Unbounded_String (Tests_Program));
      Words.Append (To_Unbounded_String ("probe"));
      Words.Append (To_Unbounded_String ("processors"));
      Happened := Hostkit.Process.Run_Captured
        (Taskset, Words, Stdout_Path => "obj/probe-processors.out", Timeout_Ms => 20_000);
      Assert (Happened.Started and then Happened.Exit_Status = 0,
              "the probe under taskset did not run");
      declare
         Said  : constant String := Read_Whole ("obj/probe-processors.out");
         From  : Natural := Said'First;
         Took  : constant Integer := Number_At (Said, From);
         Cores : constant Integer := Number_At (Said, From);
      begin
         Assert (Took = 2,
                 "a process held to two processors took" & Integer'Image (Took));
         Assert ((if Siblings then Cores = 1 else Cores in 1 .. 2),
                 "a process held to two processors"
                 & (if Siblings then " of one core" else "") & " counted"
                 & Integer'Image (Cores) & " cores");
      end;
   end A_Held_Process_Takes_The_Processors_It_Has;

   --  The low-power wait is asked of the processor, not assumed: MONITORX
   --  and MWAITX on a processor without them -- any Intel part, a guest
   --  whose hypervisor hides them -- fault the program.
   procedure The_Low_Power_Wait_Is_Asked_Of_The_Processor
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Info : constant String := Read_Whole ("/proc/cpuinfo");
   begin
      if Info = "" then
         Assert (not Model_Runner.Platform.Low_Power_Waits,
                 "a host that says nothing was taken to have the low-power wait");
         return;
      end if;
      declare
         At_Flags : constant Natural := Ada.Strings.Fixed.Index (Info, "flags");
         Line_End : constant Natural :=
           (if At_Flags = 0 then 0 else Ada.Strings.Fixed.Index (Info, [1 => ASCII.LF], At_Flags));
         Flags : constant String :=
           (if At_Flags = 0 then "" else Info (At_Flags .. Line_End - 1) & " ");
      begin
         Assert (Model_Runner.Platform.Low_Power_Waits
                 = (Ada.Strings.Fixed.Index (Flags, " mwaitx ") > 0),
                 "the low-power wait was not what the processor's flags say");
      end;
   end The_Low_Power_Wait_Is_Asked_Of_The_Processor;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("the platform layer");
   end Name;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Process_Leaving_Its_Handler_Installed_Ends'Access,
         "a process that ends with its interrupt handling installed ends");
      Register_Routine
        (T, An_Ignored_Signal_Is_Left_Ignored'Access,
         "a signal ignored when the handling is installed is left ignored and "
         & "given back so");
      Register_Routine
        (T, Installs_Nest_And_Remove_Gives_The_Binding_Back'Access,
         "installs nest, and a Remove gives the binding back to the one before");
      Register_Routine
        (T, A_Wait_Ends_With_Its_Scope'Access,
         "a wait for a line is said over however its scope is left");
      Register_Routine
        (T, An_Ending_Gives_A_Chooser_Terminal_Back'Access,
         "told to end at a list in a session, the chooser lets go at once and "
         & "the terminal is given back");
      Register_Routine
        (T, An_Ending_Leaves_The_Other_Screen'Access,
         "told to end with nothing to stop, the program ends and leaves the "
         & "other screen");
      Register_Routine
        (T, A_Mapped_File_Is_Not_Inherited'Access,
         "a mapped model's descriptor is not handed to children");
      Register_Routine
        (T, A_Region_Left_By_An_Exception_Is_Closed'Access,
         "a mapping left by an exception is closed with it");
      Register_Routine
        (T, A_Located_Handle_Holds_Its_Mapping'Access,
         "a handle located for reading holds its mapping until let go");
      Register_Routine
        (T, A_Written_Mapping_Is_Synced'Access,
         "what was written through a mapping is synced into the file");
      Register_Routine
        (T, A_Trim_Keeps_The_File_However_It_Is_Named'Access,
         "a trim keeps the file it is told to however its name is spelled");
      Register_Routine
        (T, A_Relative_Base_Directory_Is_Ignored'Access,
         "a relative XDG base directory is ignored");
      Register_Routine
        (T, A_Held_Process_Takes_The_Processors_It_Has'Access,
         "a process held to some processors takes that many");
      Register_Routine
        (T, The_Low_Power_Wait_Is_Asked_Of_The_Processor'Access,
         "the low-power wait is asked of the processor, not assumed");
   end Register_Tests;

end Tests.Platform_Cases;
