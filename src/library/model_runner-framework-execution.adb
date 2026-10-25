with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Task_Attributes;
with Ada.Task_Identification;

with GNAT.OS_Lib;

with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Process;
with Hostkit.Signals;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Templates;
with Model_Runner.Platform;

package body Model_Runner.Framework.Execution is

   --  Each run's own number in this process, so that two runs -- this
   --  session's and another's, or two tasks of one -- never share a file
   --  to write what they say into.
   protected Output_Numbers is
      procedure Take (Number : out Natural);
   private
      Count : Natural := 0;
   end Output_Numbers;

   protected body Output_Numbers is
      procedure Take (Number : out Natural) is
      begin
         Count := (if Count = Natural'Last then 0 else Count + 1);
         Number := Count;
      end Take;
   end Output_Numbers;

   function Next_Output_Number return Natural is
      Number : Natural;
   begin
      Output_Numbers.Take (Number);
      return Number;
   end Next_Output_Number;

   --  How much of a check's output is kept where it says keep=summary.
   Kept_Tail : constant := 4096;

   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   --  Resolve the command before env clears PATH. This matters especially on
   --  Windows, where the native PATH uses semicolons but the MSYS env utility
   --  interprets the replacement PATH as a POSIX search path. A name with a
   --  directory in it is no search: it is passed as written, so a relative
   --  one is found from where the command runs -- the workspace, the
   --  check's directory -- not from where this process does.
   --
   --  Searched only along the search path's absolute directories: an empty
   --  entry or a relative one -- ".", node_modules/.bin -- is the current
   --  directory's, where the work under check could have put a make or a
   --  prlimit of its own to run in place of the one allowed.
   function Executable (Name : String) return String is
   begin
      if (for some C of Name => C in '/' | '\') then
         return Name;
      end if;
      declare
         Search : constant String := Model_Runner.Platform.Search_Path;
         From   : Positive := Search'First;
      begin
         for Index in Search'First .. Search'Last + 1 loop
            if Index > Search'Last or else Search (Index) = GNAT.OS_Lib.Path_Separator then
               declare
                  Folder : constant String := Search (From .. Index - 1);
               begin
                  if Folder /= "" and then GNAT.OS_Lib.Is_Absolute_Path (Folder) then
                     --  And with the suffix a program has where one is
                     --  named so -- env.exe -- as the path search adds it.
                     for Suffix of Name_Lists.Vector'
                       (if GNAT.OS_Lib.Directory_Separator = '\' then ["", ".exe"] else [""])
                     loop
                        declare
                           Candidate : constant String := Hostkit.Fs.Join (Folder, Name & Suffix);
                        begin
                           if GNAT.OS_Lib.Is_Executable_File (Candidate)
                             and then not GNAT.OS_Lib.Is_Directory (Candidate)
                           then
                              return Candidate;
                           end if;
                        end;
                     end loop;
                  end if;
               end;
               From := Index + 1;
            end if;
         end loop;
         --  Not found where it may be: the name as given, which nothing
         --  passed on will find in a relative place (Passed_Environment
         --  keeps only the absolute directories).
         return Name;
      end;
   end Executable;

   ---------------
   -- Policy_Of --
   ---------------

   function Policy_Of (Item : Stores.Store) return Policy is
      Config : Records.Item;
   begin
      Config := Configurations.Required (Item);
      return Policy_From (Config);
   end Policy_Of;

   -----------------
   -- Policy_From --
   -----------------

   function Policy_From (Config : Records.Item) return Policy is
      Result : Policy;

      function Count (Text : String; Default : Positive) return Positive
      is (if Text'Length in 1 .. 9 and then (for all Char of Text => Char in '0' .. '9')
            and then Natural'Value (Text) > 0
          then Natural'Value (Text) else Default);

      function Amount (Text : String) return Natural
      is (if Text'Length in 1 .. 7 and then (for all Char of Text => Char in '0' .. '9')
          then Natural'Value (Text) else 0);
   begin
      Result.Allowed := Lines_Of (Records.Get (Config, "set.execution.allowed"));
      Result.Shell_Allowed :=
        Records.Get (Config, "scalar.execution.shell") = "allowed";
      for Name of Lines_Of (Records.Get (Config, "set.execution.environment")) loop
         Append (Result.Environment, Name & ",");
      end loop;
      Result.Timeout := Count (Records.Get (Config, "scalar.execution.timeout"), 600);
      Result.Output_Limit :=
        Count (Records.Get (Config, "scalar.execution.output_limit"), 1024 * 1024);
      Result.Network := Records.Get (Config, "scalar.execution.network") = "allowed";
      Result.No_Network := Records.Get (Config, "scalar.execution.network") = "denied";
      Result.Memory_MB := Amount (Records.Get (Config, "scalar.execution.max_memory_mb"));
      Result.CPU_Seconds := Amount (Records.Get (Config, "scalar.execution.max_cpu_seconds"));
      Result.Processes := Amount (Records.Get (Config, "scalar.execution.max_processes"));
      Result.File_MB := Amount (Records.Get (Config, "scalar.execution.max_file_mb"));
      Result.Process_Slots := Amount (Records.Get (Config, "scalar.execution.process_slots"));
      Result.Confine_Writes := Records.Get (Config, "scalar.execution.confine_writes") = "true";
      return Result;
   end Policy_From;

   -----------
   -- Watch --
   -----------

   --  What stops the work of one task, and why: the token whoever runs it
   --  cancels, the lease it holds and its owner, and the reason it was
   --  stopped once it was -- one record, the stop file only one way of
   --  setting it. Each task has its own, made at its first use, so two
   --  executions on two tasks never share it, where one process-wide set
   --  of these let one execution only be watched at a time.
   type Control is record
      Watched       : Model_Runner.Cancellation.Token_Reference := null;
      Store         : access constant Stores.Store := null;
      Lease         : Unbounded_String;
      Owner         : Unbounded_String;
      Last_Asked    : Ada.Calendar.Time := Ada.Calendar.Clock;
      Reason        : Stop_Reason := Not_Stopped;
      --  Why the last watched work was stopped, kept when its watch ends,
      --  for the run to be concluded as asked.
      Ended_For     : Stop_Reason := Not_Stopped;
      --  Whether the group of the command now running could not be
      --  recorded: then nothing could stop it should this process be
      --  killed, so it is stopped now, and the run says why.
      Group_Unrecorded : Boolean := False;
      --  The file the command now running writes what it says into, and
      --  whether it said more than is kept: stopped then, not let fill the
      --  disk the project's state is on.
      Capture       : Unbounded_String;
      Overflowed    : Boolean := False;

      --  What this run wrote into the process slot it holds, beside its
      --  process's line: two runs of one process are told apart by it.
      Slot_Mark     : Unbounded_String;
   end record;
   type Control_Access is access Control;

   --  The most a command may say before it is stopped.
   Most_Said : constant := 256 * 1024 * 1024;

   package Task_Controls is new Ada.Task_Attributes (Control_Access, null);

   --  The calling task's own control, made at its first use: what Watch
   --  and Watch_Lease set.
   function Own return not null Control_Access is
      Mine : Control_Access := Task_Controls.Value;
   begin
      if Mine = null then
         Mine := new Control;
         Task_Controls.Set_Value (Mine);
      end if;
      return Mine;
   end Own;

   --  The control the calling task's work is under: its own where it set
   --  one; else the environment task's, where a run's work is done -- a
   --  worker task running a call the agent made alongside others watches
   --  nothing of its own, and is stopped with the work it serves.
   function Current return not null Control_Access is
      Mine : constant Control_Access := Task_Controls.Value;
   begin
      if Mine /= null then
         return Mine;
      end if;
      declare
         Main : constant Control_Access :=
           Task_Controls.Value (Ada.Task_Identification.Environment_Task);
      begin
         return (if Main /= null then Main else Own);
      end;
   end Current;

   -----------
   -- Watch --
   -----------

   procedure Watch (Token : Model_Runner.Cancellation.Token_Reference) is
   begin
      Own.Watched := Token;
   end Watch;

   -----------------
   -- Watch_Lease --
   -----------------

   procedure Watch_Lease
     (Item     : access constant Stores.Store;
      Resource : String := "";
      Owner    : String := "")
   is
      Here : constant not null Control_Access := Own;
   begin
      --  The work this task runs under a lease holds it while it runs
      --  (Leases.Working); the one watched before, no longer.
      if Length (Here.Lease) > 0 then
         Leases.Done_Working (To_String (Here.Lease), To_String (Here.Owner));
      end if;
      if Item /= null and then Resource /= "" then
         Leases.Working (Resource, Owner);
      end if;
      Here.Store := Item;
      Here.Lease := To_Unbounded_String (Resource);
      Here.Owner := To_Unbounded_String (Owner);
      --  A new watch starts unstopped; why the last one stopped is kept
      --  when the watch ends, for the run to be concluded as asked.
      Here.Ended_For := (if Item = null then Here.Reason else Not_Stopped);
      Here.Reason := Not_Stopped;
      Here.Last_Asked := Ada.Calendar.Clock;
   end Watch_Lease;

   -----------------
   -- Stopped_For --
   -----------------

   --  Whom a stop request is for, as it says: "" where it names nobody.
   function Addressed_To (Said : String) return String is
      Mark : constant String := "for=";
      At_Mark : constant Natural := Ada.Strings.Fixed.Index (Said, Mark);
   begin
      if At_Mark = 0 then
         return "";
      end if;
      declare
         From : constant Positive := At_Mark + Mark'Length;
         Upto : Natural := From - 1;
      begin
         while Upto < Said'Last and then Said (Upto + 1) not in ASCII.LF | ASCII.CR loop
            Upto := Upto + 1;
         end loop;
         return Said (From .. Upto);
      end;
   end Addressed_To;

   function Stopped_For return Stop_Reason is
      Here : constant not null Control_Access := Current;
   begin
      if Here.Reason /= Not_Stopped or else Here.Store = null then
         return Here.Reason;
      end if;
      if Ada.Calendar.Clock - Here.Last_Asked >= 1.0 then
         Here.Last_Asked := Ada.Calendar.Clock;
         if Leases.Holder (Here.Store.all, To_String (Here.Lease)) /= To_String (Here.Owner) then
            Here.Reason := Lease_Lost;
            return Here.Reason;
         end if;

         --  Or asked to stop by another process, which cannot change the
         --  state while this one holds it.
         declare
            Lease   : constant String := To_String (Here.Lease);
            Request : constant String :=
              Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Here.Store.all), "runtime"),
                               "stop." & (if Lease'Length > 5
                                            and then Lease (Lease'First .. Lease'First + 4) = "task."
                                          then Lease (Lease'First + 5 .. Lease'Last) else Lease));
         begin
            if Ada.Directories.Exists (Request) then
               --  Seen, it is heeded: a request that cannot then be read
               --  or taken away still stops the work, as a stop and not a
               --  cancel where what it said cannot be told.
               Here.Reason := Stop_Requested;
               declare
                  Said : Unbounded_String;
                  Read : E.Error_Info;
               begin
                  Files.Read_Text (Request, Said, Read);
                  --  For another run on the task -- one before this, which
                  --  ended before it was seen -- it is not this one's: gone,
                  --  and not heeded.
                  if E.Is_Ok (Read)
                    and then Addressed_To (To_String (Said)) /= ""
                    and then Addressed_To (To_String (Said)) /= To_String (Here.Owner)
                  then
                     Here.Reason := Not_Stopped;
                  elsif E.Is_Ok (Read) and then Ada.Strings.Fixed.Index (To_String (Said), "cancel") > 0 then
                     Here.Reason := Cancel_Requested_Elsewhere;
                  end if;
                  Ada.Directories.Delete_File (Request);
               exception
                  when others =>
                     --  Heeded already: only what it said is unknown.
                     null;
               end;
            end if;
         exception
            --  Whether there is a request could not be told: asked again
            --  at the next look, a second from now.
            when others =>
               null;
         end;
      end if;
      return Here.Reason;
   end Stopped_For;

   --------------------
   -- Work_Withdrawn --
   --------------------

   function Work_Withdrawn return Boolean
   is (Stopped_For in Lease_Lost | Stop_Requested | Cancel_Requested_Elsewhere);

   --  Where a work run keeps the process group of what it runs, for a
   --  later opening to stop should the run be killed: runtime/group.TASK.
   function Group_File (Root : String; Lease : String) return String
   is (Hostkit.Fs.Join (Hostkit.Fs.Join (Root, "runtime"),
                        "group." & (if Lease'Length > 5
                                      and then Lease (Lease'First .. Lease'First + 4) = "task."
                                    then Lease (Lease'First + 5 .. Lease'Last) else Lease)));

   --  Told the process a command started as, which leads its own group.
   procedure Record_Group (Process_Id : Integer) is
      Wrote : E.Error_Info;
   begin
      if Current.Store /= null and then Length (Current.Lease) > 0 then
         --  With what tells it apart from a later process given its id: an
         --  opening after a kill stops it only where it is that one.
         Files.Write_Text
           (Group_File (Stores.Root (Current.Store.all), To_String (Current.Lease)),
            Process_Line (Process_Id), Wrote);
         Current.Group_Unrecorded := E.Is_Error (Wrote);
      end if;
   end Record_Group;

   --  What a command stopped for that reason says.
   Unrecorded_Said : constant String :=
     "its process group could not be recorded, for stopping it should this process be killed,"
     & " so it was stopped";

   ----------------------
   -- Stop_Left_Groups --
   ----------------------

   procedure Stop_Left_Groups (Item : Stores.Store; Stopped : out Name_Lists.Vector) is
      Runtime : constant String := Hostkit.Fs.Join (Stores.Root (Item), "runtime");
   begin
      Stopped.Clear;
      for Name of Files.Files_In (Runtime) loop
         if Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "group." then
            declare
               Path : constant String := Hostkit.Fs.Join (Runtime, Name);
               Text : Unbounded_String;
               Read : E.Error_Info;
               Pid  : Integer := 0;
            begin
               Files.Read_Text (Path, Text, Read);
               declare
                  Said  : constant String := Trim (To_String (Text));
                  Space : constant Natural := Ada.Strings.Fixed.Index (Said & " ", " ");
                  Id    : constant String := Said (Said'First .. Space - 1);
               begin
                  if Id'Length in 1 .. 9 and then (for all C of Id => C in '0' .. '9') then
                     Pid := Integer'Value (Id);
                  end if;
               end;
               --  Stopped only where it is the process recorded: an id is
               --  reused once its process is gone, and a group signalled by
               --  its id alone could be some other program's. One not known
               --  to be the same is left alone, and its record goes.
               if Pid > 1 and then Standing_Of (To_String (Text)) = Same_Process
               then
                  if Hostkit.Signals.Send_To_Group (Pid, Hostkit.Signals.Signal_Terminate) then
                     delay 0.2;
                     if Hostkit.Signals.Send_To_Group (Pid, Hostkit.Signals.Signal_Kill) then
                        null;
                     end if;
                  end if;
                  Stopped.Append
                    ("stopped process" & Integer'Image (Pid) & " and what it started, left running"
                     & " for " & Name (Name'First + 6 .. Name'Last) & " by a run that was killed");
               end if;
               Files.Discard (Path);
            end;
         end if;
      end loop;
   end Stop_Left_Groups;

   -----------------
   -- Ask_To_Stop --
   -----------------

   procedure Ask_To_Stop
     (Project_Directory : String;
      Task_Id           : String;
      Cancel            : Boolean := True;
      Holder            : String := "";
      Status            : out Model_Runner.Errors.Error_Info)
   is
   begin
      Files.Write_Text
        (Hostkit.Fs.Join (Hostkit.Fs.Join (Hostkit.Fs.Join (Project_Directory, State_Directory),
                                           "runtime"),
                          "stop." & Task_Id),
         (if Cancel then "cancel" else "stop")
         & (if Holder = "" then "" else ASCII.LF & "for=" & Holder), Status);
   end Ask_To_Stop;

   function Cancel_Asked_From_Outside return Boolean
   is (Current.Reason = Cancel_Requested_Elsewhere or else Current.Ended_For = Cancel_Requested_Elsewhere);

   function Cancel_Requested return Boolean
   is (Model_Runner.Cancellation."/=" (Current.Watched, null)
       and then Model_Runner.Cancellation.Is_Cancelled (Current.Watched));

   --  Whether the run has been cancelled, asked while a command waits: by
   --  whoever runs it, or by the work being ended elsewhere.
   function Said_Too_Much return Boolean;

   function Stop_Asked return Boolean
   is ((Model_Runner.Cancellation."/=" (Current.Watched, null)
        and then Model_Runner.Cancellation.Is_Cancelled (Current.Watched))
       or else Work_Withdrawn
       or else Current.Group_Unrecorded
       or else Said_Too_Much);

   function Said_Too_Much return Boolean is
      use type Ada.Directories.File_Size;
      Path : constant String := To_String (Current.Capture);
   begin
      if Path /= "" and then Ada.Directories.Exists (Path)
        and then Ada.Directories.Size (Path) > Most_Said
      then
         Current.Overflowed := True;
      end if;
      return Current.Overflowed;
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         return Current.Overflowed;
   end Said_Too_Much;

   --  Whether this host can take the network away from one program: asked
   --  once, by trying.
   type Answer is (Unasked, Yes, No);
   Isolation : Answer := Unasked;

   function Can_Isolate return Boolean is
   begin
      if Isolation = Unasked then
         declare
            Words    : Hostkit.String_Vectors.Vector;
            Happened : Hostkit.Process.Process_Outcome;
         begin
            Isolation := No;
            if Hostkit.Process.Locate ("unshare") /= "" then
               Words.Append (To_Unbounded_String ("--net"));
               Words.Append (To_Unbounded_String ("--map-root-user"));
               Words.Append (To_Unbounded_String ("true"));
               Happened := Hostkit.Process.Run_Captured
                 ("unshare", Words, Stdin_Path => Hostkit.Fs.Null_Device,
                  Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Hostkit.Fs.Null_Device,
                  Timeout_Ms => 10_000);
               if Happened.Started and then not Happened.Timed_Out
                 and then Happened.Exit_Status = 0
               then
                  Isolation := Yes;
               end if;
            end if;
         end;
      end if;
      return Isolation = Yes;
   end Can_Isolate;

   --  The places under /run a confined check reads and the empty /run
   --  over it would hide: the directory the resolver's file really is in,
   --  where that is under /run, and the search path's entries there.
   function Run_Readable return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      function Under_Run (Path : String) return Boolean is
        (Path'Length > 5 and then Path (Path'First .. Path'First + 4) = "/run/");
      procedure Keep (Path : String) is
      begin
         if Under_Run (Path) and then not Result.Contains (Path) and then Path /= "/run/systemd/resolve" then
            Result.Append (Path);
         end if;
      end Keep;
   begin
      declare
         Real : constant String := GNAT.OS_Lib.Normalize_Pathname ("/etc/resolv.conf", Resolve_Links => True);
      begin
         if Under_Run (Real) then
            Keep (Ada.Directories.Containing_Directory (Real));
         end if;
      end;
      if Model_Runner.Platform.Search_Path /= "" then
         declare
            Search : constant String := Model_Runner.Platform.Search_Path;
            Start  : Positive := Search'First;
         begin
            for Index in Search'First .. Search'Last + 1 loop
               if Index > Search'Last or else Search (Index) = ':' then
                  Keep (Search (Start .. Index - 1));
                  Start := Index + 1;
               end if;
            end loop;
         end;
      end if;
      return Result;
   exception
      when others =>
         return Result;
   end Run_Readable;

   --  Give a slot back -- only while it is still this process's: one
   --  moved aside by a claim racing it and taken by a third run since is
   --  that run's, and removing it let a fourth past the limit.
   procedure Let_Slot_Go (Slot : String) is
      Held : Unbounded_String;
      Read : E.Error_Info;
   begin
      Files.Read_Text (Slot, Held, Read);
      if E.Is_Ok (Read)
        and then To_String (Held)
                 = Process_Line (Hostkit.Host.Own_Process_Id) & ASCII.LF & To_String (Current.Slot_Mark)
      then
         Files.Discard (Slot);
      end if;
   end Let_Slot_Go;

   --  A slot's first line, the process's: what Standing_Of reads.
   function Holder_Line (Held : Unbounded_String) return String is
      Text : constant String := To_String (Held);
      Cut  : constant Natural := Ada.Strings.Fixed.Index (Text, [1 => ASCII.LF]);
   begin
      return (if Cut = 0 then Text else Text (Text'First .. Cut - 1));
   end Holder_Line;

   --  Take one of the project's process slots: a file of its own, made by
   --  a move that never replaces, holding this process's number, so that a
   --  slot a process that is gone left behind can be taken back.
   function Take_Slot (Item : Stores.Store; Slots : Positive) return String is
      Directory : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "slots");
      Mine      : constant String := Trim (Integer'Image (Hostkit.Host.Own_Process_Id));
      --  Its own draft, this run's: two runs of one process share no name.
      Draft     : constant String :=
        Hostkit.Fs.Join (Directory, "draft-" & Mine & "-" & Trim (Natural'Image (Next_Output_Number)));
      Written   : E.Error_Info;
   begin
      if not Files.Make_Directory (Directory) then
         return "";
      end if;
      Current.Slot_Mark := To_Unbounded_String (Ada.Directories.Simple_Name (Draft));
      Files.Write_Text
        (Draft, Process_Line (Hostkit.Host.Own_Process_Id) & ASCII.LF & To_String (Current.Slot_Mark), Written);
      if E.Is_Error (Written) then
         return "";
      end if;
      for Pass in 1 .. 2 loop
         for Slot in 1 .. Slots loop
            declare
               Path : constant String :=
                 Hostkit.Fs.Join (Directory, "process-" & Trim (Positive'Image (Slot)));
            begin
               if Hostkit.Fs.Move_No_Replace (Draft, Path) then
                  return Path;
               elsif Pass = 2 then
                  --  Held by a process that is gone: let go, and try again.
                  declare
                     Seen    : Unbounded_String;
                     Held    : Unbounded_String;
                     Looked  : E.Error_Info;
                     Read    : E.Error_Info;
                     Claimed : constant String := Draft & ".claimed";
                  begin
                     --  Looked at where it is first: a slot whose holder
                     --  lives is never moved, so its holder always finds it
                     --  to let go. Only one that looks stale is taken
                     --  aside -- by one only: two that both found it stale
                     --  do not both free it -- and freed only if what was
                     --  taken is what was looked at, not one taken afresh
                     --  between the look and the taking.
                     Files.Read_Text (Path, Seen, Looked);
                     if E.Is_Ok (Looked) and then Standing_Of (Holder_Line (Seen)) = Other_Process
                       and then Hostkit.Fs.Move_No_Replace (Path, Claimed)
                     then
                        Files.Read_Text (Claimed, Held, Read);
                        --  Gone, or another process given its id since: the
                        --  slot is free.
                        if E.Is_Ok (Read) and then Held = Seen
                          and then Standing_Of (Holder_Line (Held)) = Other_Process
                        then
                           Files.Discard (Claimed);
                           if Hostkit.Fs.Move_No_Replace (Draft, Path) then
                              return Path;
                           end if;
                        elsif not Hostkit.Fs.Move_No_Replace (Claimed, Path) then
                           --  Held after all, and its place taken since: it
                           --  is not left aside under this run's name.
                           Files.Discard (Claimed);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end loop;
      Files.Discard (Draft);
      return "";
   end Take_Slot;

   -----------------
   -- Needs_Shell --
   -----------------

   function Needs_Shell (Command : String) return Boolean
   is (for some Char of Command => Char in '&' | '|' | ';' | '<' | '>' | '$' | '`'
                                         | '*' | '?' | '(' | ')');

   --------------
   -- Words_Of --
   --------------

   function Words_Of (Command : String) return Name_Lists.Vector is
      Result  : Name_Lists.Vector;
      Current : Unbounded_String;
      Quote   : Character := ' ';
      Started : Boolean := False;
   begin
      for Char of Command loop
         if Quote /= ' ' then
            if Char = Quote then
               Quote := ' ';
            else
               Append (Current, Char);
            end if;
         elsif Char in '"' | ''' then
            Quote := Char;
            Started := True;
         elsif Char in ' ' | ASCII.HT then
            if Started then
               Result.Append (To_String (Current));
               Current := Null_Unbounded_String;
               Started := False;
            end if;
         else
            Append (Current, Char);
            Started := True;
         end if;
      end loop;
      if Started then
         Result.Append (To_String (Current));
      end if;
      return Result;
   end Words_Of;

   -------------
   -- Refusal --
   -------------

   function Refusal (Rules : Policy; Command : String) return String is
      Words : constant Name_Lists.Vector := Words_Of (Command);
   begin
      if Words.Is_Empty or else Words.First_Element = "" then
         return "there is nothing to run";
      elsif Needs_Shell (Command) then
         return (if Rules.Shell_Allowed then ""
                 else "it needs a shell, and the policy does not allow one; /reconfigure"
                      & " scalar.execution.shell=allowed lets checks use one -- and with it run any program"
                      & " a shell can, set.execution.allowed no longer holding them");
      --  A program by its name is the one the host finds by it; one given
      --  as a path is that file, which the work may have written -- allowed
      --  only as the policy writes it, not by the name it ends in.
      elsif not Rules.Allowed.Contains (Words.First_Element)
        and then (Ada.Strings.Fixed.Index (Words.First_Element, "/") > 0
                  or else not Rules.Allowed.Contains (Ada.Directories.Simple_Name (Words.First_Element)))
      then
         return Words.First_Element & " is not a program the policy allows; allow it with"
           & " /reconfigure add set.execution.allowed " & Words.First_Element;
      elsif (Rules.Memory_MB > 0 or else Rules.CPU_Seconds > 0 or else Rules.Processes > 0
             or else Rules.File_MB > 0)
        and then Hostkit.Process.Locate ("prlimit") = ""
      then
         return "the policy limits its resources, and prlimit is not here to set them";
      end if;
      return "";
   end Refusal;

   ---------
   -- Run --
   ---------

   procedure Run
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Rules     : Policy;
      Command   : String;
      Directory : String;
      Result    : out Outcome;
      Status    : out Model_Runner.Errors.Error_Info;
      Base      : String := "")
   is
      --  Both as full names: a store opened by a relative directory holds
      --  its workspaces at full paths.
      Workspaces_Root : constant String :=
        Ada.Directories.Full_Name (Hostkit.Fs.Join (Stores.Root (Item), "workspaces"));
      Base_Full : constant String :=
        (if Base = "" then "" else Ada.Directories.Full_Name (Base));
      Project : constant String :=
        (if Base = "" then Ada.Directories.Containing_Directory (Stores.Root (Item))
         else Base);
      Words   : constant Name_Lists.Vector := Words_Of (Command);
      Shell   : constant Boolean := Needs_Shell (Command);

      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.Framework_Execution_Refused);
         E.Add_Text (Status, "name", Command);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;
   begin
      Result := (Command   => To_Unbounded_String (Command),
                 Directory => To_Unbounded_String (Directory),
                 others    => <>);
      Status := E.Success;

      if Refusal (Rules, Command) /= "" then
         Refuse (Refusal (Rules, Command));
         return;
      elsif Base /= ""
        and then (Base_Full'Length <= Workspaces_Root'Length
                  or else Base_Full (Base_Full'First .. Base_Full'First + Workspaces_Root'Length - 1)
                          /= Workspaces_Root)
      then
         Refuse (Base & " is not one of the project's workspaces");
         return;
      elsif Directory /= "" and then not Templates.Is_Project_Path (Directory) then
         Refuse (Directory & " is not a directory inside the project");
         return;
      end if;

      declare
         Scratch   : constant String :=
           Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "exec");
         Output    : constant String :=
           Hostkit.Fs.Join (Scratch, "output-" & Trim (Integer'Image (Hostkit.Host.Own_Process_Id))
                                     & "-" & Trim (Natural'Image (Next_Output_Number)));
         Where     : constant String :=
           (if Directory = "" then Project else Hostkit.Fs.Join (Project, Directory));
         Arguments : Hostkit.String_Vectors.Vector;
         Began     : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         Happened  : Hostkit.Process.Process_Outcome;
         Text      : Unbounded_String;
         Read      : E.Error_Info;
         Program   : constant String := Executable ("env");
      begin
         if not Files.Make_Directory (Scratch) then
            Files.Write_Failed (Scratch, Status);
            return;
         end if;

         --  Only what the policy passes: env starts from nothing.
         Arguments.Append (To_Unbounded_String ("-i"));
         for Assignment of Lines_Of
                             (Model_Runner.Platform.Passed_Environment
                                (To_String (Rules.Environment)))
         loop
            Arguments.Append (To_Unbounded_String (Assignment));
         end loop;

         --  Writing only in its own tree, where the project asks: the host
         --  read-only to it but for that tree and a /tmp of its own. Refused
         --  where nothing here can do it, rather than run unconfined.
         if Rules.Confine_Writes then
            if Hostkit.Process.Locate ("bwrap") = "" then
               Refuse ("the project confines what checks write (execution.confine_writes) and bwrap,"
                       & " which does it, is not on this host");
               return;
            end if;
            Arguments.Append (To_Unbounded_String (Executable ("bwrap")));
            --  And nothing it could ask to write for it: the sockets under
            --  /run -- a session bus, an agent, a container daemon -- hidden
            --  (the resolver kept, which names hosts), its own processes,
            --  messages and session, none of the caller's to reach.
            for Word of Name_Lists.Vector'(["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc",
                                           "--tmpfs", "/tmp", "--tmpfs", "/run",
                                           "--ro-bind-try", "/run/systemd/resolve", "/run/systemd/resolve"])
            loop
               Arguments.Append (To_Unbounded_String (Word));
            end loop;
            --  And what else under /run is no socket but a place it reads:
            --  the resolver's file where another keeper puts it, and the
            --  program directories its search path names there (NixOS).
            for Kept of Run_Readable loop
               Arguments.Append (To_Unbounded_String ("--ro-bind-try"));
               Arguments.Append (To_Unbounded_String (Kept));
               Arguments.Append (To_Unbounded_String (Kept));
            end loop;
            for Word of Name_Lists.Vector'(["--unshare-pid", "--unshare-ipc", "--new-session",
                                           "--bind", Ada.Directories.Full_Name (Project),
                                           Ada.Directories.Full_Name (Project)])
            loop
               Arguments.Append (To_Unbounded_String (Word));
            end loop;
            --  Inside the tree, what a check has no business writing: the
            --  project's state and its repository's hooks and history.
            for Kept of Name_Lists.Vector'([Hostkit.Fs.Join (Project, State_Directory),
                                           Hostkit.Fs.Join (Project, ".git")])
            loop
               if Ada.Directories.Exists (Kept) then
                  Arguments.Append (To_Unbounded_String ("--ro-bind"));
                  Arguments.Append (To_Unbounded_String (Ada.Directories.Full_Name (Kept)));
                  Arguments.Append (To_Unbounded_String (Ada.Directories.Full_Name (Kept)));
               end if;
            end loop;
            for Word of Name_Lists.Vector'(["--chdir", Ada.Directories.Full_Name (Where),
                                           "--die-with-parent", "--"]) loop
               Arguments.Append (To_Unbounded_String (Word));
            end loop;
         end if;

         --  Its limits, and no network where it may have none and the host
         --  can take it away.
         if Rules.Memory_MB > 0 or else Rules.CPU_Seconds > 0 or else Rules.Processes > 0
           or else Rules.File_MB > 0
         then
            Arguments.Append (To_Unbounded_String (Executable ("prlimit")));
            if Rules.Memory_MB > 0 then
               Arguments.Append (To_Unbounded_String
                 ("--as=" & Trim (Long_Long_Integer'Image (Long_Long_Integer (Rules.Memory_MB) * 1_048_576))));
            end if;
            if Rules.CPU_Seconds > 0 then
               Arguments.Append (To_Unbounded_String ("--cpu=" & Trim (Natural'Image (Rules.CPU_Seconds))));
            end if;
            if Rules.Processes > 0 then
               Arguments.Append (To_Unbounded_String ("--nproc=" & Trim (Natural'Image (Rules.Processes))));
            end if;
            if Rules.File_MB > 0 then
               Arguments.Append (To_Unbounded_String
                 ("--fsize=" & Trim (Long_Long_Integer'Image (Long_Long_Integer (Rules.File_MB) * 1_048_576))));
            end if;
         end if;
         --  No network asked and none that can be taken away: refused, as a
         --  limit or a confinement the host cannot give is -- not run with
         --  the network it was not to have.
         if Rules.No_Network and then not Can_Isolate then
            Refuse ("the project denies checks the network (execution.network) and this host cannot take it"
                    & " away (no unshare, or user namespaces are off)");
            return;
         end if;
         if (Rules.No_Network or else Rules.Prefer_Offline) and then Can_Isolate then
            Arguments.Append (To_Unbounded_String (Executable ("unshare")));
            Arguments.Append (To_Unbounded_String ("--net"));
            Arguments.Append (To_Unbounded_String ("--map-root-user"));
            Result.Isolated := True;
         end if;
         if Shell then
            Arguments.Append (To_Unbounded_String (Executable ("sh")));
            Arguments.Append (To_Unbounded_String ("-c"));
            Arguments.Append (To_Unbounded_String (Command));
         else
            for Index in Words.First_Index .. Words.Last_Index loop
               Arguments.Append
                 (To_Unbounded_String
                    (if Index = Words.First_Index
                     then Executable (Words (Index))
                     else Words (Index)));
            end loop;
         end if;

         --  A slot of the project's, where it bounds how many run at once.
         declare
            Slot : constant String :=
              (if Rules.Process_Slots > 0 then Take_Slot (Item, Rules.Process_Slots) else "");
         begin
            if Rules.Process_Slots > 0 and then Slot = "" then
               Status := E.Make (E.Framework_Limit_Exceeded);
               E.Add_Text (Status, "name", "process slots");
               E.Add_Text (Status, "detail", "all" & Natural'Image (Rules.Process_Slots)
                           & " process slots are taken");
               return;
            end if;
            Current.Group_Unrecorded := False;
            Current.Capture := To_Unbounded_String (Output);
            Current.Overflowed := False;
            Happened :=
              Hostkit.Process.Run_Captured
                (Program           => Program,
                 Arguments         => Arguments,
                 Working_Directory => Where,
                 Stdin_Path        => Hostkit.Fs.Null_Device,
           Whole_Group       => True,
                 Clean_Wrapper     => True,
                 Stdout_Path       => Output,
                 Stderr_Path       => Output,
                 Timeout_Ms        => Natural'Min (Rules.Timeout, Integer'Last / 1000) * 1000,
                 Cancelled         => Stop_Asked'Access,
                 Started           => Record_Group'Access);
            Current.Capture := Null_Unbounded_String;
            --  Said more than is kept: stopped for it, and said so -- not a
            --  check that failed, nor one that passed.
            if Current.Overflowed then
               Current.Overflowed := False;
               Files.Discard (Output);
               if Current.Store /= null and then Length (Current.Lease) > 0 then
                  Files.Discard (Group_File (Stores.Root (Current.Store.all), To_String (Current.Lease)));
               end if;
               if Slot /= "" then
                  Let_Slot_Go (Slot);
               end if;
               Status := E.Make (E.Framework_Limit_Exceeded);
               E.Add_Text (Status, "name", "what a check says");
               E.Add_Text (Status, "detail", Command & " said more than"
                           & Natural'Image (Most_Said / (1024 * 1024)) & " MiB, and was stopped");
               return;
            end if;
            if Current.Store /= null and then Length (Current.Lease) > 0 then
               Files.Discard (Group_File (Stores.Root (Current.Store.all), To_String (Current.Lease)));
            end if;
            if Slot /= "" then
               Let_Slot_Go (Slot);
            end if;
            if Current.Group_Unrecorded then
               Current.Group_Unrecorded := False;
               Files.Discard (Output);
               Files.Write_Failed (Group_File (Stores.Root (Item), To_String (Current.Lease)), Status);
               E.Add_Text (Status, "detail", Command & ": " & Unrecorded_Said);
               return;
            end if;
         end;
         Result.Cancelled := Happened.Timed_Out and then Stop_Asked;

         Result.Started := Happened.Started;
         Result.Timed_Out := Happened.Timed_Out;
         Result.Exit_Status := Happened.Exit_Status;
         Result.Seconds := Natural (Ada.Calendar.Clock - Began);

         if Ada.Directories.Exists (Output) then
            Files.Read_Text (Output, Text, Read);
            --  More than is read whole: its end, which is where a program
            --  says why it stopped, read on its own.
            if E.Is_Error (Read) and then E."=" (Read.Code, E.IO_File_Too_Large) then
               declare
                  use Ada.Streams;
                  use type Stream_IO.Count;
                  File  : Stream_IO.File_Type;
                  Size  : constant Stream_IO.Count := Stream_IO.Count (Ada.Directories.Size (Output));
                  Want  : constant Stream_IO.Count := Stream_IO.Count'Min (Size, Stream_IO.Count (Kept_Tail));
                  Piece : Stream_Element_Array (1 .. Stream_Element_Offset (Want));
                  Last  : Stream_Element_Offset;
                  Tail  : String (1 .. Natural (Want));
               begin
                  Stream_IO.Open (File, Stream_IO.In_File, Output, Form => "shared=no");
                  Stream_IO.Set_Index (File, Size - Want + 1);
                  Stream_IO.Read (File, Piece, Last);
                  Stream_IO.Close (File);
                  for Index in 1 .. Natural (Last) loop
                     Tail (Index) := Character'Val (Piece (Stream_Element_Offset (Index)));
                  end loop;
                  Text := To_Unbounded_String ("[the start of what it said was too large to keep]" & ASCII.LF
                                               & Tail (1 .. Natural (Last)));
                  Read := E.Success;
               exception
                  when Failure : others =>
                     if Stream_IO.Is_Open (File) then
                        Stream_IO.Close (File);
                     end if;
                     Read := E.Make (E.IO_Read_Failed);
                     E.Add_Text (Read, "path", Output, E.Param_Path);
                     E.Add_Text (Read, "detail", Ada.Exceptions.Exception_Name (Failure));
               end;
            end if;
            Files.Discard (Output);
            --  What it said, not read, is not said to be nothing.
            if E.Is_Error (Read) then
               Status := Read;
               E.Add_Text (Status, "detail", Command & ": what it said could not be read");
               return;
            end if;
         --  Started, ran its course, and nothing to read of what it said --
         --  the file it was to say it into not there: not taken for having
         --  said nothing. One stopped at once may have said nothing yet.
         elsif Result.Started and then not Result.Timed_Out then
            Status := E.Make (E.IO_Read_Failed);
            E.Add_Text (Status, "path", Output, E.Param_Path);
            E.Add_Text (Status, "detail", Command & ": what it said was not captured");
            return;
         end if;

         --  The whole of it kept; a limit's worth of it read.
         declare
            Raw : Results.Result :=
              (Kind       => Results.Verification,
               Producer   => To_Unbounded_String ("execution"),
               Summary    => To_Unbounded_String ("output of " & Command),
               Payload    =>
                (if Rules.Keep_Whole or else Length (Text) <= Kept_Tail then Text
                 else Unbounded_Slice (Text, Length (Text) - Kept_Tail + 1, Length (Text))),
               Provenance => To_Unbounded_String
                               (Trim (Directory) & ": " & Command
                                & (if Result.Isolated then " [no network]" else "")
                                & (if Result.Cancelled then " [cancelled]" else "")),
               others     => <>);
         begin
            Results.Add (Item, Change, Raw, Status);
            Result.Raw_Log := Raw.Id;
         end;
         Result.Output :=
           (if Length (Text) <= Rules.Output_Limit then Text
            else Unbounded_Slice (Text, Length (Text) - Rules.Output_Limit + 1,
                                  Length (Text)));
      end;
   end Run;

   -----------------
   -- Harness_Log --
   -----------------

   function Harness_Log (Project : String) return String
   is (Hostkit.Fs.Join
         (Hostkit.Fs.Join (Hostkit.Fs.Join (Project, State_Directory), "runtime"), "harness.log"));

   -----------------
   -- Run_Harness --
   -----------------

   procedure Run_Harness
     (Project   : String;
      Program   : String;
      Arguments : Name_Lists.Vector;
      Directory : String;
      Output    : String;
      Timeout   : Positive;
      Result    : out Outcome;
      Passed    : String := "";
      Added     : Name_Lists.Vector := Name_Lists.Empty_Vector)
   is
      Words    : Hostkit.String_Vectors.Vector;
      Command  : Unbounded_String := To_Unbounded_String (Program);
      Began    : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Happened : Hostkit.Process.Process_Outcome;

      --  Each line of what it said on its error stream, after its own,
      --  indented.
      function Indented (Text : String) return String is
         Done : Unbounded_String;
      begin
         for One of Lines_Of (Text) loop
            Append (Done, "    " & One & ASCII.LF);
         end loop;
         return To_String (Done);
      end Indented;
   begin
      --  Only what is passed: env starts from nothing.
      Words.Append (To_Unbounded_String ("-i"));
      for Assignment of Lines_Of (Model_Runner.Platform.Passed_Environment (Passed)) loop
         Words.Append (To_Unbounded_String (Assignment));
      end loop;
      for Assignment of Added loop
         Words.Append (To_Unbounded_String (Assignment));
      end loop;
      Words.Append (To_Unbounded_String (Executable (Program)));
      for Word of Arguments loop
         Words.Append (To_Unbounded_String (Word));
         Append (Command, " " & Word);
      end loop;

      Current.Group_Unrecorded := False;
      Happened :=
        Hostkit.Process.Run_Captured
          (Program           => Executable ("env"),
           Arguments         => Words,
           Working_Directory => Directory,
           Stdin_Path        => Hostkit.Fs.Null_Device,
                 Whole_Group       => True,
                 Clean_Wrapper     => True,
           Stdout_Path       => Output,
           Stderr_Path       => Output & ".stderr",
           Timeout_Ms        => Natural'Min (Timeout, Integer'Last / 1000) * 1000,
           Cancelled         => Stop_Asked'Access,
           Started           => Record_Group'Access);
      if Current.Store /= null and then Length (Current.Lease) > 0 then
         Files.Discard (Group_File (Stores.Root (Current.Store.all), To_String (Current.Lease)));
      end if;
      Result := (Command     => Command,
                 Directory   => To_Unbounded_String (Directory),
                 Started     => Happened.Started,
                 Timed_Out   => Happened.Timed_Out,
                 Exit_Status => (if Current.Group_Unrecorded then -1 else Happened.Exit_Status),
                 Seconds     => Natural (Ada.Calendar.Clock - Began),
                 Output      => (if Current.Group_Unrecorded then To_Unbounded_String (Unrecorded_Said)
                                 else Null_Unbounded_String),
                 others      => <>);
      Current.Group_Unrecorded := False;

      --  What it said on its error stream, kept -- the end of it, which is
      --  where a program says why it stopped -- rather than thrown away.
      declare
         Said : Unbounded_String;
         Read : E.Error_Info;
      begin
         if Ada.Directories.Exists (Output & ".stderr") then
            Files.Read_Text (Output & ".stderr", Said, Read);
            Files.Discard (Output & ".stderr");
            if E.Is_Ok (Read) and then Length (Said) > 0 then
               --  After why it was stopped, where it was.
               Result.Output := (if Length (Result.Output) > 0 then Result.Output & ASCII.LF
                                 else Null_Unbounded_String)
                 & Slice (Said, Integer'Max (1, Length (Said) - 3999), Length (Said));
            end if;
         end if;
      end;

      --  Said where the project keeps its runtime, when it has one.
      if Project /= ""
        and then Ada.Directories.Exists (Ada.Directories.Containing_Directory (Harness_Log (Project)))
      then
         declare
            use Ada.Streams.Stream_IO;
            File : File_Type;
            Line : constant String :=
              Ada.Calendar.Formatting.Image (Began) & ASCII.HT & Directory & ASCII.HT
              & To_String (Command) & ASCII.HT
              & (if not Happened.Started then "not started"
                 elsif Happened.Timed_Out then "timed out"
                 else "exit" & Integer'Image (Happened.Exit_Status))
              & ASCII.HT & Trim (Natural'Image (Result.Seconds)) & "s" & ASCII.LF
              & Indented (To_String (Result.Output));
         begin
            if Ada.Directories.Exists (Harness_Log (Project)) then
               Open (File, Append_File, Harness_Log (Project), Form => "shared=no");
            else
               Create (File, Out_File, Harness_Log (Project), Form => "shared=no");
            end if;
            String'Write (Stream (File), Line);
            Close (File);
         exception
            when others =>
               if Is_Open (File) then
                  Close (File);
               end if;
         end;
      end if;
   end Run_Harness;

end Model_Runner.Framework.Execution;
