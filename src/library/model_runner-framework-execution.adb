with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Process;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Templates;
with Model_Runner.Platform;

package body Model_Runner.Framework.Execution is

   --  How much of a check's output is kept where it says keep=summary.
   Kept_Tail : constant := 4096;

   use Ada.Strings.Unbounded;
   use type Ada.Calendar.Time;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   ---------------
   -- Policy_Of --
   ---------------

   function Policy_Of (Item : Stores.Store) return Policy is
      Config : Records.Item;
      Status : E.Error_Info;
      Result : Policy;

      function Count (Text : String; Default : Positive) return Positive
      is (if Text'Length in 1 .. 9 and then (for all Char of Text => Char in '0' .. '9')
            and then Natural'Value (Text) > 0
          then Natural'Value (Text) else Default);

      function Amount (Text : String) return Natural
      is (if Text'Length in 1 .. 7 and then (for all Char of Text => Char in '0' .. '9')
          then Natural'Value (Text) else 0);
   begin
      Configurations.Read (Item, Config, Status);
      if E.Is_Error (Status) then
         return Result;
      end if;
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
      return Result;
   end Policy_Of;

   -----------
   -- Watch --
   -----------

   Watched : Model_Runner.Cancellation.Token_Reference := null;

   procedure Watch (Token : Model_Runner.Cancellation.Token_Reference) is
   begin
      Watched := Token;
   end Watch;

   --  Whether the run has been cancelled, asked while a command waits.
   function Stop_Asked return Boolean
   is (Model_Runner.Cancellation."/=" (Watched, null)
       and then Model_Runner.Cancellation.Is_Cancelled (Watched));

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

   --  Take one of the project's process slots: a file of its own, made by
   --  a move that never replaces, holding this process's number, so that a
   --  slot a process that is gone left behind can be taken back.
   function Take_Slot (Item : Stores.Store; Slots : Positive) return String is
      Directory : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "slots");
      Mine      : constant String := Trim (Integer'Image (Hostkit.Host.Own_Process_Id));
      Draft     : constant String := Hostkit.Fs.Join (Directory, "draft-" & Mine);
      Written   : E.Error_Info;
   begin
      if not Files.Make_Directory (Directory) then
         return "";
      end if;
      Files.Write_Text (Draft, Mine, Written);
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
                     Held  : Unbounded_String;
                     Read  : E.Error_Info;
                     use type Hostkit.Process.Presence;
                  begin
                     Files.Read_Text (Path, Held, Read);
                     if E.Is_Ok (Read) and then Length (Held) in 1 .. 9
                       and then (for all C of To_String (Held) => C in '0' .. '9')
                       and then Hostkit.Process.Presence_Of (Integer'Value (To_String (Held)))
                                  = Hostkit.Process.Absent
                     then
                        Files.Discard (Path);
                        if Hostkit.Fs.Move_No_Replace (Draft, Path) then
                           return Path;
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
      Workspaces_Root : constant String :=
        Hostkit.Fs.Join (Stores.Root (Item), "workspaces");
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

      if Words.Is_Empty then
         Refuse ("there is nothing to run");
         return;
      elsif Base /= ""
        and then (Base'Length <= Workspaces_Root'Length
                  or else Base (Base'First .. Base'First + Workspaces_Root'Length - 1)
                          /= Workspaces_Root)
      then
         Refuse (Base & " is not one of the project's workspaces");
         return;
      elsif Directory /= "" and then not Templates.Is_Project_Path (Directory) then
         Refuse (Directory & " is not a directory inside the project");
         return;
      elsif Shell and then not Rules.Shell_Allowed then
         Refuse ("it needs a shell, and the policy does not allow one");
         return;
      elsif not Shell
        and then not Rules.Allowed.Contains
                       (Ada.Directories.Simple_Name (Words.First_Element))
      then
         Refuse (Words.First_Element & " is not a program the policy allows");
         return;
      elsif (Rules.Memory_MB > 0 or else Rules.CPU_Seconds > 0 or else Rules.Processes > 0
             or else Rules.File_MB > 0)
        and then Hostkit.Process.Locate ("prlimit") = ""
      then
         Refuse ("the policy limits its resources, and prlimit is not here to set them");
         return;
      end if;

      declare
         Scratch   : constant String :=
           Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "exec");
         Output    : constant String := Hostkit.Fs.Join (Scratch, "output");
         Where     : constant String :=
           (if Directory = "" then Project else Hostkit.Fs.Join (Project, Directory));
         Arguments : Hostkit.String_Vectors.Vector;
         Began     : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         Happened  : Hostkit.Process.Process_Outcome;
         Text      : Unbounded_String;
         Read      : E.Error_Info;
         Program   : constant String := "env";
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

         --  Its limits, and no network where it may have none and the host
         --  can take it away.
         if Rules.Memory_MB > 0 or else Rules.CPU_Seconds > 0 or else Rules.Processes > 0
           or else Rules.File_MB > 0
         then
            Arguments.Append (To_Unbounded_String ("prlimit"));
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
         if Rules.No_Network and then Can_Isolate then
            Arguments.Append (To_Unbounded_String ("unshare"));
            Arguments.Append (To_Unbounded_String ("--net"));
            Arguments.Append (To_Unbounded_String ("--map-root-user"));
            Result.Isolated := True;
         end if;
         if Shell then
            Arguments.Append (To_Unbounded_String ("sh"));
            Arguments.Append (To_Unbounded_String ("-c"));
            Arguments.Append (To_Unbounded_String (Command));
         else
            for Word of Words loop
               Arguments.Append (To_Unbounded_String (Word));
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
            Happened :=
              Hostkit.Process.Run_Captured
                (Program           => Program,
                 Arguments         => Arguments,
                 Working_Directory => Where,
                 Stdin_Path        => Hostkit.Fs.Null_Device,
                 Stdout_Path       => Output,
                 Stderr_Path       => Output,
                 Timeout_Ms        => Rules.Timeout * 1000,
                 Cancelled         => Stop_Asked'Access);
            if Slot /= "" then
               Files.Discard (Slot);
            end if;
         end;
         Result.Cancelled := Happened.Timed_Out and then Stop_Asked;

         Result.Started := Happened.Started;
         Result.Timed_Out := Happened.Timed_Out;
         Result.Exit_Status := Happened.Exit_Status;
         Result.Seconds := Natural (Ada.Calendar.Clock - Began);

         if Ada.Directories.Exists (Output) then
            Files.Read_Text (Output, Text, Read);
            Files.Discard (Output);
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
      Words.Append (To_Unbounded_String (Program));
      for Word of Arguments loop
         Words.Append (To_Unbounded_String (Word));
         Append (Command, " " & Word);
      end loop;

      Happened :=
        Hostkit.Process.Run_Captured
          (Program           => "env",
           Arguments         => Words,
           Working_Directory => Directory,
           Stdin_Path        => Hostkit.Fs.Null_Device,
           Stdout_Path       => Output,
           Stderr_Path       => Output & ".stderr",
           Timeout_Ms        => Timeout * 1000);
      Result := (Command     => Command,
                 Directory   => To_Unbounded_String (Directory),
                 Started     => Happened.Started,
                 Timed_Out   => Happened.Timed_Out,
                 Exit_Status => Happened.Exit_Status,
                 Seconds     => Natural (Ada.Calendar.Clock - Began),
                 others      => <>);

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
               Result.Output := To_Unbounded_String
                 (Slice (Said, Integer'Max (1, Length (Said) - 3999), Length (Said)));
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
               Open (File, Append_File, Harness_Log (Project));
            else
               Create (File, Out_File, Harness_Log (Project));
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
