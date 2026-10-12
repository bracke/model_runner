with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Hostkit;
with Hostkit.Descriptors;
with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Metadata;
with Hostkit.Process;
with Hostkit.Pty;
with Hostkit.Spawn;

package body Agent_Trial is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element_Offset;

   LF : constant Character := ASCII.LF;

   --  How the session shows a call: an arrow, in UTF-8, and a space.
   Arrow : constant String :=
     Character'Val (16#E2#) & Character'Val (16#86#) & Character'Val (16#92#) & " ";

   --  A task: its name, its kind, what it asks, and whether its project
   --  carries a test of what it asks -- which fails until the task is done,
   --  so only the task that changes Add has it.
   type Trial_Task is record
      Name   : Unbounded_String;
      Kind   : Unbounded_String;
      Notes  : Unbounded_String;
      Tested : Boolean;
   end record;

   function T (Name, Kind, Notes : String; Tested : Boolean := False) return Trial_Task is
     ((To_Unbounded_String (Name), To_Unbounded_String (Kind), To_Unbounded_String (Notes), Tested));

   --  The tasks: one that changes part of a file, one that only finds --
   --  the two things a coding agent most does -- and one handed to a helper,
   --  its output named, which is how a run delegates.
   Tasks : constant array (1 .. 3) of Trial_Task :=
     [T ("edit", "implementation",
         "In src/calc.adb make Add return Integer'Last when A + B would overflow above it and"
         & " Integer'First when it would overflow below, instead of raising. Change only Add.",
         Tested => True),
      T ("find", "analysis",
         "Find which units use the package Calc, and in which file and on which line Times is"
         & " declared. Report them. Change no file."),
      T ("delegate", "implementation",
         "Hand this part to a helper with the delegate tool, its outputs [""docs/calc.md""]: write"
         & " docs/calc.md, a short paragraph each on what Add and Times in src/calc.ads do. Do not"
         & " write docs/calc.md yourself. When the helper has finished, check that docs/calc.md is"
         & " there, and report.")];

   --  The project a task is run in, made fresh: a package, its body, and a
   --  main that uses it, under version control.
   procedure Make_Project (Root : String; Tested : Boolean) is
      procedure Put (Name, Text : String) is
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Root & "/" & Name);
         Ada.Text_IO.Put (File, Text);
         Ada.Text_IO.Close (File);
      end Put;

      procedure Git (Words : String) is
         Line    : Hostkit.String_Vectors.Vector;
         Start   : Positive := Words'First;
         Ignored : Hostkit.Process.Process_Outcome;
      begin
         Line.Append (To_Unbounded_String ("-C"));
         Line.Append (To_Unbounded_String (Root));
         Line.Append (To_Unbounded_String ("-c"));
         Line.Append (To_Unbounded_String ("user.email=trial@example.invalid"));
         Line.Append (To_Unbounded_String ("-c"));
         Line.Append (To_Unbounded_String ("user.name=trial"));
         for Index in Words'First .. Words'Last + 1 loop
            if Index > Words'Last or else Words (Index) = ' ' then
               Line.Append (To_Unbounded_String (Words (Start .. Index - 1)));
               Start := Index + 1;
            end if;
         end loop;
         Ignored := Hostkit.Process.Run_Captured
           ("git", Line, Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Hostkit.Fs.Null_Device);
      end Git;
   begin
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Ada.Directories.Create_Path (Root & "/src");
      Put ("src/calc.ads",
           "package Calc is" & LF & "   --  The sum of A and B." & LF
           & "   function Add (A, B : Integer) return Integer;" & LF & "   --  A times B." & LF
           & "   function Times (A, B : Integer) return Integer;" & LF & "end Calc;" & LF);
      Put ("src/calc.adb",
           "package body Calc is" & LF & LF
           & "   function Add (A, B : Integer) return Integer is" & LF & "   begin" & LF
           & "      return A + B;" & LF & "   end Add;" & LF & LF
           & "   function Times (A, B : Integer) return Integer is" & LF
           & "      Result : Integer := 0;" & LF & "   begin" & LF
           & "      for I in 1 .. B loop" & LF & "         Result := Add (Result, A);" & LF
           & "      end loop;" & LF & "      return Result;" & LF & "   end Times;" & LF & LF
           & "end Calc;" & LF);
      --  What Add is to do, said as a program: it fails until Add holds
      --  to Integer's limits, so a task that leaves Add as it was is not
      --  complete for building -- and near them, not only at them: an Add
      --  that saturated only from Integer'Last itself passed a test of the
      --  limits alone.
      if Tested then
         Put ("src/test_add.adb",
              "with Calc;" & LF & "procedure Test_Add is" & LF & "begin" & LF
              & "   if Calc.Add (Integer'Last, 1) /= Integer'Last" & LF
              & "     or else Calc.Add (Integer'First, -1) /= Integer'First" & LF
              & "     or else Calc.Add (Integer'Last - 1, 5) /= Integer'Last" & LF
              & "     or else Calc.Add (5, Integer'Last - 1) /= Integer'Last" & LF
              & "     or else Calc.Add (Integer'First + 1, -5) /= Integer'First" & LF
              & "     or else Calc.Add (Integer'Last, Integer'First) /= -1" & LF
              & "     or else Calc.Add (2, 3) /= 5" & LF & "   then" & LF
              & "      raise Program_Error with ""Add does not hold to Integer's limits"";" & LF
              & "   end if;" & LF & "end Test_Add;" & LF);
      end if;
      Put ("src/main.adb",
           "with Ada.Text_IO;" & LF & "with Calc;" & LF & "procedure Main is" & LF & "begin" & LF
           & "   Ada.Text_IO.Put_Line (Integer'Image (Calc.Times (6, 7)));" & LF & "end Main;" & LF);
      --  Where the check's compiler writes, apart from the sources: kept
      --  in version control as a directory, empty, so a workspace -- a
      --  worktree, which holds only what is tracked -- has it too; what is
      --  built there is not tracked. In a workspace without it every check
      --  failed, "cannot find object directory".
      Ada.Directories.Create_Path (Root & "/obj");
      Put ("obj/.gitkeep", "");
      Put (".gitignore", "obj/*" & LF & "!obj/.gitkeep" & LF);
      Git ("init -q");
      Git ("add -A");
      Git ("commit -qm start");
   end Make_Project;

   --  The project's checks, where a compiler is here: the program built,
   --  bound and linked, and Add's test built and run. /init's own is the
   --  command true, which checks nothing, and a model that wrote Ada that
   --  would not compile was told its work had passed; a semantic check of
   --  the main alone passed a body rewritten as another unit, which only
   --  the link finds; and a build alone passed an Add left as it was, which
   --  only the test finds.
   --  The work's own bound, inside the half hour the trial waits for it:
   --  past that a run read "did not end", and nothing said why; ended by
   --  the harness, it says.
   Time_Bound : constant String := " scalar.agents.max_seconds=1200";

   --  Where the work is written: in a workspace of its own, taken in by
   --  the harness once its checks pass there, where the trial asks it.
   --  The harness takes work in for an agent that may ask for it:
   --  request_integration, which a project's default leaves out.
   function Apart_Words (Apart : Boolean) return String is
     (if Apart
      then " scalar.work.isolation=workspace scalar.work.integrate=automatic"
           & " map.permission.project.request_integration=on"
      else "");

   function Check_Line (Tested : Boolean; Apart : Boolean := False) return String is
     (if Tested
      then "/reconfigure add set.execution.allowed gnatmake obj/test_add "
           & "profile.checks=""build: gnatmake -q -D obj -aIsrc src/main.adb -o obj/main;"
           & " test: gnatmake -q -D obj -aIsrc src/test_add.adb -o obj/test_add; run: obj/test_add"""
           & Time_Bound & Apart_Words (Apart) & " confirm=yes"
      else "/reconfigure add set.execution.allowed gnatmake "
           & "profile.checks=""build: gnatmake -q -D obj -aIsrc src/main.adb -o obj/main"""
           & Time_Bound & Apart_Words (Apart) & " confirm=yes");

   --  Text without the terminal's escape sequences and carriage returns.
   function Plain (Text : String) return String is
      Result : String (1 .. Text'Length);
      Last   : Natural := 0;
      Index  : Positive := Text'First;
   begin
      while Index <= Text'Last loop
         if Text (Index) = ASCII.ESC and then Index < Text'Last and then Text (Index + 1) = '[' then
            Index := Index + 2;
            while Index <= Text'Last and then Text (Index) not in 'A' .. 'Z' | 'a' .. 'z' loop
               Index := Index + 1;
            end loop;
            Index := Index + 1;
         elsif Text (Index) = ASCII.CR then
            Index := Index + 1;
         else
            Last := Last + 1;
            Result (Last) := Text (Index);
            Index := Index + 1;
         end if;
      end loop;
      return Result (1 .. Last);
   end Plain;

   ---------
   -- Run --
   ---------

   --  Whether a task is among those asked for: every one where none is
   --  named, else each named, a comma apart -- edit,find -- so one trial,
   --  with one copy of the program, runs a set.
   function Chosen (Only, Name : String) return Boolean is
   begin
      if Only = "" then
         return True;
      end if;
      declare
         Start : Positive := Only'First;
      begin
         for At_Char in Only'Range loop
            if Only (At_Char) = ',' or else At_Char = Only'Last then
               if Ada.Strings.Fixed.Trim
                    (Only (Start .. (if Only (At_Char) = ',' then At_Char - 1 else At_Char)), Ada.Strings.Both)
                 = Name
               then
                  return True;
               end if;
               Start := At_Char + 1;
            end if;
         end loop;
      end;
      return False;
   end Chosen;

   procedure Run
     (Model   : String;
      Program : String;
      Options : String;
      Only    : String;
      Clean   : out Boolean;
      Repeats : Positive := 1;
      Apart   : Boolean := False)
   is
      --  How many of the runs of each task ended complete.
      Completed : array (Tasks'Range) of Natural := [others => 0];

      --  Each run of each task in a line -- how it ended, its time, its
      --  calls, the thoughts closed at their budget -- for a table that
      --  sets one commit's runs beside another's.
      Rows      : array (Tasks'Range) of Unbounded_String;

      --  The program as it was when the trial began, copied aside and run
      --  from there: a build during an hour of runs replaced it under them,
      --  and a run started then read half a file, or another program.
      function Copied return String is
         --  With the program's own extension: a host that runs only an
         --  .exe runs this one.
         --  Beside the program, not elsewhere: it finds its messages and
         --  resources from where it is, and a copy in obj/ found none.
         --  This trial's own: a second trial started meanwhile copied over
         --  a shared one under the first one's runs.
         Aside : constant String :=
           Hostkit.Fs.Join
             (Ada.Directories.Containing_Directory (Program),
              ".agent-trial-program-"
              & Ada.Strings.Fixed.Trim (Integer'Image (Hostkit.Host.Own_Process_Id), Ada.Strings.Both)
              & (if Ada.Directories.Extension (Program) = "" then ""
                 else "." & Ada.Directories.Extension (Program)));
         Ignored : Boolean;
      begin
         Ada.Directories.Copy_File (Program, Aside);
         Ignored := Hostkit.Metadata.Set_Permissions (Aside, 8#755#);
         return Aside;
      exception
         when others =>
            return Program;
      end Copied;

      Own_Copy : constant String := Copied;

      --  The build the trial runs, as the repository names it: its commit,
      --  + where the tree differs from it. Each run is kept under it in
      --  obj/agent-trial-history.tsv, so one build's runs are set beside
      --  another's without reading a file a trial.
      function Build_Named return String is
         Words  : Hostkit.String_Vectors.Vector;
         Said   : constant String := Ada.Directories.Full_Name ("obj/agent-trial-commit.txt");
         Dirty  : constant String := Ada.Directories.Full_Name ("obj/agent-trial-dirty.txt");
         Ran    : Hostkit.Process.Process_Outcome;
         File   : Ada.Text_IO.File_Type;
         Commit : Unbounded_String := To_Unbounded_String ("unknown");
         Mark   : Unbounded_String;
      begin
         Words.Append (To_Unbounded_String ("rev-parse"));
         Words.Append (To_Unbounded_String ("--short"));
         Words.Append (To_Unbounded_String ("HEAD"));
         Ran := Hostkit.Process.Run_Captured ("git", Words, Stdout_Path => Said);
         if Ran.Started and then Ada.Directories.Exists (Said) then
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Said);
            if not Ada.Text_IO.End_Of_File (File) then
               Commit := To_Unbounded_String (Ada.Strings.Fixed.Trim (Ada.Text_IO.Get_Line (File), Ada.Strings.Both));
            end if;
            Ada.Text_IO.Close (File);
            Ada.Directories.Delete_File (Said);
         end if;
         Words.Clear;
         Words.Append (To_Unbounded_String ("status"));
         Words.Append (To_Unbounded_String ("--porcelain"));
         Words.Append (To_Unbounded_String ("--untracked-files=no"));
         Ran := Hostkit.Process.Run_Captured ("git", Words, Stdout_Path => Dirty);
         if Ran.Started and then Ada.Directories.Exists (Dirty) then
            if Ada.Directories."/=" (Ada.Directories.Size (Dirty), 0) then
               Mark := To_Unbounded_String ("+");
            end if;
            Ada.Directories.Delete_File (Dirty);
         end if;
         return To_String (Commit & Mark);
      exception
         when others =>
            return "unknown";
      end Build_Named;

      Build : constant String := Build_Named;

      --  One run, a line of the history: when, the build, the model, the
      --  task, where it worked, how it ended, its seconds, calls and the
      --  thoughts closed at their budget; a tab apart.
      procedure Keep_In_History (Task_Name, Ending : String; Seconds, Calls : Natural; Closed : String) is
         Path  : constant String := Ada.Directories.Full_Name ("obj/agent-trial-history.tsv");
         File  : Ada.Text_IO.File_Type;
         Fresh : constant Boolean := not Ada.Directories.Exists (Path);
         HT    : constant Character := ASCII.HT;
         Now   : String := Ada.Calendar.Formatting.Image (Ada.Calendar.Clock);
      begin
         Now (Now'First + 10) := 'T';
         if Fresh then
            Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
            Ada.Text_IO.Put_Line
              (File, "when_utc" & HT & "build" & HT & "model" & HT & "task" & HT & "isolation" & HT & "outcome"
               & HT & "seconds" & HT & "calls" & HT & "thoughts_closed");
         else
            Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Path);
         end if;
         Ada.Text_IO.Put_Line
           (File, Now & HT & Build & HT & Ada.Directories.Simple_Name (Model) & HT & Task_Name & HT
            & (if Apart then "workspace" else "project") & HT & Ending & HT
            & Ada.Strings.Fixed.Trim (Natural'Image (Seconds), Ada.Strings.Left) & HT
            & Ada.Strings.Fixed.Trim (Natural'Image (Calls), Ada.Strings.Left) & HT & Closed);
         Ada.Text_IO.Close (File);
      exception
         --  A history not kept is no trial lost.
         when others =>
            if Ada.Text_IO.Is_Open (File) then
               Ada.Text_IO.Close (File);
            end if;
      end Keep_In_History;

      --  The copy gone with the trial it was made for.
      procedure Discard_Copy is
      begin
         if Own_Copy /= Program and then Ada.Directories.Exists (Own_Copy) then
            Ada.Directories.Delete_File (Own_Copy);
         end if;
      exception
         when others =>
            null;
      end Discard_Copy;

      --  Whether a session could not start: the runs after it would end the
      --  same, and are not run.
      Halted   : Boolean := False;
   begin
      Clean := True;
      --  A name no task has runs nothing: said, not an empty trial.
      if not (for some One of Tasks => Chosen (Only, To_String (One.Name))) then
         Ada.Text_IO.Put_Line
           ("agent-trial: no task is called " & Only & "; they are edit, find and delegate, a comma apart");
         Clean := False;
         Discard_Copy;
         return;
      end if;
      for Round in 1 .. Repeats loop
         exit when Halted;
         for Which in Tasks'Range loop
            exit when Halted;
            declare
               One : Trial_Task renames Tasks (Which);
            begin
               if Chosen (Only, To_String (One.Name)) then
                  declare
                     Name    : constant String := To_String (One.Name);
                     Root    : constant String := Ada.Directories.Full_Name ("obj/agent-trial-" & Name);
                     Project : constant String := Ada.Directories.Simple_Name (Root);
                     Pair    : Hostkit.Pty.Pair;
                     Spawned : Hostkit.Spawn.Options;
                     Child   : Hostkit.Spawn.Process_Handle;
                     Ended   : Hostkit.Spawn.Status;
                     Seen    : Unbounded_String;
                     Began   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                     Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
                     Last    : Ada.Streams.Stream_Element_Offset;

                     procedure Keep_Variable (Variable, Value : String) is
                     begin
                        if Variable /= "TERM" then
                           Spawned.Environment.Append (To_Unbounded_String (String'(Variable & "=" & Value)));
                        end if;
                     end Keep_Variable;

                     --  Read what arrives until Text has, after From, or the
                     --  seconds are up.
                     function Wait_For (Text : String; Seconds : Duration) return Boolean is
                        use type Ada.Calendar.Time;
                        From  : constant Natural := Length (Seen);
                        Until_At : constant Ada.Calendar.Time := Ada.Calendar.Clock + Seconds;
                     begin
                        loop
                           if Ada.Strings.Fixed.Index (Plain (Slice (Seen, From + 1, Length (Seen))), Text) > 0 then
                              return True;
                           end if;
                           exit when Ada.Calendar.Clock > Until_At;
                           if Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 500) then
                              exit when Hostkit.Descriptors."/="
                                          (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                                           Hostkit.Descriptors.Transfer_Ok)
                                or else Last < Buffer'First;
                              for Byte of Buffer (Buffer'First .. Last) loop
                                 Append (Seen, Character'Val (Byte));
                              end loop;
                           end if;
                        end loop;
                        return False;
                     end Wait_For;

                     procedure Send (Line : String) is
                        Bytes : Ada.Streams.Stream_Element_Array
                          (1 .. Ada.Streams.Stream_Element_Offset (Line'Length + 1));
                        Wrote : Ada.Streams.Stream_Element_Offset;
                        pragma Warnings (Off, Wrote);
                        Ignored : Hostkit.Descriptors.Transfer_Outcome;
                     begin
                        for Index in Line'Range loop
                           Bytes (Ada.Streams.Stream_Element_Offset (Index - Line'First + 1)) :=
                             Character'Pos (Line (Index));
                        end loop;
                        Bytes (Bytes'Last) := 13;
                        Ignored := Hostkit.Descriptors.Write (Pair.To_Child, Bytes, Wrote);
                     end Send;

                     --  Send a line, as a condition: true, so a chain of steps
                     --  reads as one.
                     function Send_Then (Line : String) return Boolean is
                     begin
                        Send (Line);
                        return True;
                     end Send_Then;

                     Words  : Hostkit.String_Vectors.Vector;
                     Worked : Boolean := False;
                  begin
                     Make_Project (Root, One.Tested);
                     if not Hostkit.Pty.Is_Supported or else not Hostkit.Pty.Open (Pair) then
                        Ada.Text_IO.Put_Line ("agent-trial: no terminal to run a session on");
                        Clean := False;
                        return;
                     end if;
                     Ada.Environment_Variables.Iterate (Keep_Variable'Access);
                     Spawned.Environment.Append (To_Unbounded_String ("TERM=xterm"));
                     --  The copy ends with the trial: stopped, it ran on with
                     --  its model loaded.
                     Spawned.Environment.Append (To_Unbounded_String ("MODEL_RUNNER_END_WITH_PARENT=1"));
                     Spawned.Replace_Environment := True;
                     Spawned.Working_Directory := To_Unbounded_String (Root);
                     if not (Hostkit.Pty.Set_Size (Pair, (Rows => 50, Columns => 200))
                             and then Hostkit.Pty.Attach (Pair, Spawned))
                     then
                        Clean := False;
                        return;
                     end if;
                     Words.Append (To_Unbounded_String (Model));
                     Words.Append (To_Unbounded_String ("--context-size"));
                     Words.Append (To_Unbounded_String ("8192"));
                     declare
                        Start : Positive := Options'First;
                     begin
                        for Index in Options'First .. Options'Last + 1 loop
                           if Index > Options'Last or else Options (Index) = ' ' then
                              if Index > Start then
                                 Words.Append (To_Unbounded_String (Options (Start .. Index - 1)));
                              end if;
                              Start := Index + 1;
                           end if;
                        end loop;
                     end;
                     if Hostkit.Spawn."/=" (Hostkit.Spawn.Start (Own_Copy, Words, Spawned, Child),
                                            Hostkit.Spawn.Spawn_Ok)
                     then
                        Ada.Text_IO.Put_Line ("agent-trial: " & Program & " did not start");
                        Clean := False;
                        return;
                     end if;
                     Hostkit.Pty.Close_Device (Pair);

                     --  The session, as a person would drive it.
                     if Wait_For ("Interactive mode", 300.0) then
                        Send ("/init");
                        if Wait_For ("Select project type", 30.0) then
                           Send ("");
                           if Wait_For ("as planned", 30.0) then
                              Send ("");
                              if Wait_For ("initialized", 30.0)
                                and then (Hostkit.Process.Locate ("gnatmake") = ""
                                          or else (Send_Then (Check_Line (One.Tested, Apart))
                                                   and then Wait_For ("is now revision", 30.0)))
                              then
                                 Send ("/task new Trial " & Name & " kind=" & To_String (One.Kind)
                                       & (if To_String (One.Kind) = "implementation"
                                          then " component=" & Project else "")
                                       & " notes=" & To_String (One.Notes));
                                 if Wait_For ("created TASK-", 30.0) then
                                    Send ("/accept TASK-001");
                                    if Wait_For ("ready", 30.0) then
                                       Send ("/work TASK-001");
                                       Worked := Wait_For ("How it came out", 1800.0);
                                       declare
                                          Ignored : constant Boolean := Wait_For ("> ", 20.0);
                                       begin
                                          null;
                                       end;
                                    end if;
                                 end if;
                              end if;
                           end if;
                        end if;
                     end if;
                     Send ("/exit");
                     declare
                        Ignored : constant Boolean := Wait_For ("never said", 5.0);
                     begin
                        null;
                     end;
                     Hostkit.Pty.Close (Pair);
                     declare
                        Ignored : constant Boolean := Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Block, Ended);
                     begin
                        null;
                     end;

                     --  What came of it.
                     declare
                        use type Ada.Calendar.Time;
                        Text    : constant String := Plain (To_String (Seen));
                        Took    : constant Duration := Ada.Calendar.Clock - Began;
                        Calls   : Natural := 0;
                        Used    : Unbounded_String;
                        Outcome : Unbounded_String := To_Unbounded_String ("did not end");
                        Figures : Unbounded_String;
                        Start   : Positive := Text'First;
                     begin
                        for Index in Text'Range loop
                           if Text (Index) = LF then
                              declare
                                 Line : constant String :=
                                   Ada.Strings.Fixed.Trim (Text (Start .. Index - 1), Ada.Strings.Both);
                              begin
                                 --  A call, as the session shows one: an arrow, the tool.
                                 if Line'Length > Arrow'Length
                                   and then Line (Line'First .. Line'First + Arrow'Length - 1) = Arrow
                                 then
                                    Calls := Calls + 1;
                                    declare
                                       Rest  : constant String := Line (Line'First + Arrow'Length .. Line'Last);
                                       Space : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
                                       Tool  : constant String :=
                                         (if Space = 0 then Rest else Rest (Rest'First .. Space - 1));
                                    begin
                                       if Ada.Strings.Fixed.Index (To_String (Used), Tool) = 0 then
                                          Append (Used, (if Length (Used) = 0 then "" else ", ") & Tool);
                                       end if;
                                    end;
                                 elsif Ada.Strings.Fixed.Index (Line, "the task is ") = 1
                                   or else Ada.Strings.Fixed.Index (Line, "the task failed") = 1
                                 then
                                    Outcome := To_Unbounded_String
                                      (Line (Line'First .. Natural'Min (Line'Last, Line'First + 80)));
                                 elsif Ada.Strings.Fixed.Index (Line, "calls before the first change") = 1 then
                                    Figures := To_Unbounded_String (Line);
                                 end if;
                              end;
                              Start := Index + 1;
                           end if;
                        end loop;
                        --  A session that never started is said as that, not as
                           --  work that did not end: the program without its
                           --  messages -- their names shown in their place -- or
                           --  no model loaded. Two trials ran an hour on nothing
                           --  so, each run "did not end".
                        --  A setup the program refused is the same: no run
                        --  of it can work, so none more is tried.
                        if To_String (Outcome) = "did not end"
                          and then Ada.Strings.Fixed.Index (Text, "model_runner: error: ") > 0
                          and then Ada.Strings.Fixed.Index (Text, "model_runner: error: ")
                                     < Ada.Strings.Fixed.Index (Text & "/work", "/work")
                        then
                           declare
                              At_Error : constant Positive := Ada.Strings.Fixed.Index (Text, "model_runner: error: ");
                              Line_End : constant Natural :=
                                Ada.Strings.Fixed.Index (Text (At_Error .. Text'Last), [ASCII.LF]);
                           begin
                              Outcome := To_Unbounded_String
                                ("the session could not start: its setup was refused -- "
                                 & Text (At_Error + 21 .. (if Line_End = 0 then Text'Last else Line_End - 1)));
                           end;
                           Halted := True;
                        elsif To_String (Outcome) = "did not end"
                          and then (Ada.Strings.Fixed.Index (Text, "message catalog could not be read") > 0
                                    or else Ada.Strings.Fixed.Index (Text, "<cli.") > 0
                                    or else Ada.Strings.Fixed.Index (Text, "<progress.") > 0)
                        then
                           Outcome := To_Unbounded_String
                             ("the session could not start: the program found no message catalog -- "
                              & "its messages came out as their names");
                           Halted := True;
                        end if;
                        if not Worked or else Ada.Strings.Fixed.Index (To_String (Outcome), "complete") = 0 then
                           Clean := False;
                        else
                           Completed (Which) := Completed (Which) + 1;
                        end if;

                        --  What it changed, as version control sees it.
                        declare
                           Line  : Hostkit.String_Vectors.Vector;
                           Diff  : constant String := Root & "/.trial-diff";
                           Ran   : Hostkit.Process.Process_Outcome;
                           Said  : Unbounded_String;
                           File  : Ada.Text_IO.File_Type;
                        begin
                           --  New files counted with the changed: what a helper
                           --  wrote is new.
                           declare
                              Marked : Hostkit.String_Vectors.Vector;
                              Ignore : Hostkit.Process.Process_Outcome;
                           begin
                              for Word of Hostkit.String_Vectors.Vector'
                                ([To_Unbounded_String ("-C"), To_Unbounded_String (Root), To_Unbounded_String ("add"),
                                  To_Unbounded_String ("--intent-to-add"), To_Unbounded_String ("--"),
                                  To_Unbounded_String ("src"), To_Unbounded_String ("docs")])
                              loop
                                 Marked.Append (Word);
                              end loop;
                              Ignore := Hostkit.Process.Run_Captured
                                ("git", Marked, Stdout_Path => Hostkit.Fs.Null_Device,
                                 Stderr_Path => Hostkit.Fs.Null_Device);
                           end;
                           for Word of Hostkit.String_Vectors.Vector'
                             ([To_Unbounded_String ("-C"), To_Unbounded_String (Root), To_Unbounded_String ("diff"),
                               To_Unbounded_String ("--shortstat"), To_Unbounded_String ("--"),
                               To_Unbounded_String ("src"), To_Unbounded_String ("docs")])
                           loop
                              Line.Append (Word);
                           end loop;
                           Ran := Hostkit.Process.Run_Captured ("git", Line, Stdout_Path => Diff);
                           if Ran.Started and then Ada.Directories.Exists (Diff) then
                              Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Diff);
                              while not Ada.Text_IO.End_Of_File (File) loop
                                 Append (Said, Ada.Strings.Fixed.Trim (Ada.Text_IO.Get_Line (File), Ada.Strings.Both));
                              end loop;
                              Ada.Text_IO.Close (File);
                           end if;
                           declare
                              Text   : constant String := To_String (Outcome);
                              Mark   : constant String := "thoughts closed at their budget:";
                              At_It  : constant Natural := Ada.Strings.Fixed.Index (To_String (Figures), Mark);
                              Closed : constant String :=
                                (if At_It = 0 then "0"
                                 else Ada.Strings.Fixed.Trim
                                   (To_String (Figures) (At_It + Mark'Length .. Length (Figures)), Ada.Strings.Both));
                              Ending : constant String :=
                                (if Ada.Strings.Fixed.Index (Text, "complete") > 0 then "complete"
                                 elsif Ada.Strings.Fixed.Index (Text, "ran out of time") > 0 then "out of time"
                                 elsif Ada.Strings.Fixed.Index (Text, "blocked") > 0 then "blocked"
                                 elsif Ada.Strings.Fixed.Index (Text, "failed") > 0 then "failed"
                                 else "other");
                           begin
                              Append (Rows (Which),
                                      "  run" & Integer'Image (Round) & ": " & Ending
                                      & [1 .. Natural'Max (1, 12 - Ending'Length) => ' ']
                                      & Integer'Image (Integer (Took)) & " s," & Natural'Image (Calls) & " calls, "
                                      & Closed & " thoughts closed" & LF);
                              Keep_In_History (Name, Ending, Natural (Took), Calls, Closed);
                           end;
                           Ada.Text_IO.Put_Line
                             ("agent-trial " & Name
                              & (if Repeats = 1 then ""
                                 else " (run" & Integer'Image (Round) & " of" & Integer'Image (Repeats) & ")")
                              & ": " & To_String (Outcome)
                              & LF & "  time:" & Integer'Image (Integer (Took)) & " s; calls:" & Natural'Image (Calls)
                              & (if Length (Used) = 0 then "" else " (" & To_String (Used) & ")")
                              & LF & "  " & (if Length (Figures) = 0 then "(no work figures)" else To_String (Figures))
                              & LF & "  changed: " & (if Length (Said) = 0 then "nothing" else To_String (Said))
                              & LF & "  session kept in " & Root);
                        end;
                     end;
                     --  The session as it went, for a reader who wants all of it.
                     declare
                        File : Ada.Text_IO.File_Type;
                     begin
                        Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Root & "/.trial-session.txt");
                        Ada.Text_IO.Put (File, Plain (To_String (Seen)));
                        Ada.Text_IO.Close (File);
                        --  Each run's session beside the project, which the next
                        --  run makes afresh.
                        if Repeats > 1 then
                           Ada.Text_IO.Create
                             (File, Ada.Text_IO.Out_File,
                              Root & "-run" & Ada.Strings.Fixed.Trim (Integer'Image (Round), Ada.Strings.Left)
                              & ".txt");
                           Ada.Text_IO.Put (File, Plain (To_String (Seen)));
                           Ada.Text_IO.Close (File);
                        end if;
                     end;
                  end;
               end if;
            end;
         end loop;
      end loop;

      if Halted then
         Ada.Text_IO.Put_Line
           ("agent-trial: stopped -- a session could not start, and the runs after it would not either");
      end if;
      Discard_Copy;

      --  Of several runs, how many of each task's ended complete: one run
      --  of a small model is a sample, and a change is told from luck only
      --  by a count.
      if Repeats > 1 then
         for Which in Tasks'Range loop
            if Chosen (Only, To_String (Tasks (Which).Name)) then
               Ada.Text_IO.Put_Line
                 ("agent-trial " & To_String (Tasks (Which).Name) & ": complete in"
                  & Natural'Image (Completed (Which)) & " of" & Integer'Image (Repeats) & " runs");
               Ada.Text_IO.Put (To_String (Rows (Which)));
            end if;
         end loop;
      end if;
   end Run;

end Agent_Trial;
