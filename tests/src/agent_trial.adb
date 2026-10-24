with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Calendar.Time_Zones;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
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
   --  so only the task that changes Add has it -- and whether its checks
   --  hold the code to GNAT's style rules, warnings errors: a convention
   --  the task does not say and only a failed check tells, which a first
   --  attempt most often misses and a later one may be told.
   type Trial_Task is record
      Name   : Unbounded_String;
      Kind   : Unbounded_String;
      Notes  : Unbounded_String;
      Tested : Boolean;
      Styled : Boolean;

      --  Whether the project holds a convention its checks keep and the
      --  task does not say: every file its work changes begins with the
      --  license line. A first attempt misses it, a check's error says it,
      --  and the same holds for every attempt after -- what one run learns
      --  the next can use, which no other task here offers.
      Convention : Boolean;

      --  Whether the project holds a ledger too large for a context to give
      --  whole -- two hundred and forty subprograms, some twenty thousand
      --  tokens -- and the task names a subprogram of it and no file: what
      --  a context finds of the code is all the agent starts from.
      Large : Boolean := False;

      --  Whether the task is run only when named, being a measure of one
      --  thing rather than of a coding agent's work.
      Named_Only : Boolean := False;
   end record;

   function T (Name, Kind, Notes : String; Tested, Styled, Convention, Large, Named_Only : Boolean := False)
     return Trial_Task is
     ((To_Unbounded_String (Name), To_Unbounded_String (Kind), To_Unbounded_String (Notes), Tested, Styled,
       Convention, Large, Named_Only));

   --  The ledger's task: a subprogram named, no file.
   Large_Notes : constant String :=
     "Make Ledger.Post raise Constraint_Error when Amount is negative, instead of posting it."
     & " Change only Post.";

   --  The edit, said without holding the work to Add alone: a project's
   --  convention reaches past what a task names, and told to change only
   --  Add, Mellum took the license line its check asked for as a breach,
   --  and ran out of time between the two.
   Convention_Notes : constant String :=
     "In src/calc.adb make Add return Integer'Last when A + B would overflow above it and"
     & " Integer'First when it would overflow below, instead of raising.";

   --  The line the convention asks for.
   License_Line : constant String := "--  SPDX-License-Identifier: MIT";

   Edit_Notes : constant String :=
     "In src/calc.adb make Add return Integer'Last when A + B would overflow above it and"
     & " Integer'First when it would overflow below, instead of raising. Change only Add.";

   --  The tasks: one that changes part of a file, one that only finds --
   --  the two things a coding agent most does -- and one handed to a helper,
   --  its output named, which is how a run delegates.
   Tasks : constant array (1 .. 7) of Trial_Task :=
     [T ("edit", "implementation", Edit_Notes, Tested => True),
      T ("find", "analysis",
         "Find which units use the package Calc, and in which file and on which line Times is"
         & " declared. Report them. Change no file."),
      T ("delegate", "implementation",
         "Hand this part to a helper with the delegate tool, its outputs [""docs/calc.md""]: write"
         & " docs/calc.md, a short paragraph each on what Add and Times in src/calc.ads do. Do not"
         & " write docs/calc.md yourself. When the helper has finished, check that docs/calc.md is"
         & " there, and report."),
      --  The edit again, its build held to the style rules: run only when
      --  asked by name, being the edit's own measure of what is learned.
      T ("styled", "implementation", Edit_Notes, Tested => True, Styled => True),
      --  The edit again, in a project with a convention: run only when
      --  named, the measure of what is learned once and used again.
      T ("convention", "implementation", Convention_Notes, Tested => True, Convention => True),
      --  A change to one subprogram of a file too large to give whole,
      --  named by the subprogram: run only when named, the measure of what
      --  a context retrieves (--retrieval whole for the context before).
      T ("large", "implementation", Large_Notes, Tested => True, Large => True),
      --  The ledger's task again, its subprogram said by what it does and
      --  not named: with --retrieval whole the agent has the file's head
      --  and must find it -- the measure of the search by words a model
      --  makes. Named only.
      T ("described", "implementation",
         "In the ledger, the procedure that moves a book's balance by an amount and counts one entry more"
         & " must raise Constraint_Error when the amount is negative, instead of applying it. Change only"
         & " that procedure.", Tested => True, Large => True, Named_Only => True)];

   --  The project a task is run in, made fresh: a package, its body, and a
   --  main that uses it, under version control.
   procedure Make_Project
     (Root : String; Tested : Boolean; Convention : Boolean := False; Large : Boolean := False)
   is
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
      --  The ledger: a book of balances, and two hundred and forty small
      --  subprograms over it, Post among them half way down; its test in
      --  test_add's place, so the checks are the same.
      if Large then
         declare
            Spec : Unbounded_String;
            Body_Text : Unbounded_String;

            function Image (Value : Natural) return String
            is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));
         begin
            Append (Spec, "package Ledger is" & LF & LF
                    & "   type Book is record" & LF & "      Balance : Integer := 0;" & LF
                    & "      Entries : Natural := 0;" & LF & "   end record;" & LF & LF);
            Append (Body_Text, "package body Ledger is" & LF & LF);
            for Index in 1 .. 240 loop
               if Index = 120 then
                  Append (Spec, "   --  Post Amount to the book: its balance moved by it, one entry more." & LF
                          & "   procedure Post (Item : in out Book; Amount : Integer);" & LF & LF);
                  Append (Body_Text, "   procedure Post (Item : in out Book; Amount : Integer) is" & LF
                          & "   begin" & LF & "      Item.Balance := Item.Balance + Amount;" & LF
                          & "      Item.Entries := Item.Entries + 1;" & LF & "   end Post;" & LF & LF);
               end if;
               Append (Spec, "   --  The book's balance less a fee of " & Image (Index) & " in a hundred of Amount,"
                       & " or nought where that would go below it." & LF
                       & "   function Fee_" & Image (Index) & " (Item : Book; Amount : Natural) return Integer;"
                       & LF & LF);
               Append (Body_Text, "   function Fee_" & Image (Index)
                       & " (Item : Book; Amount : Natural) return Integer is" & LF
                       & "      Fee : constant Integer := Amount * " & Image (Index) & " / 100;" & LF
                       & "   begin" & LF & "      if Fee > Item.Balance then" & LF & "         return 0;" & LF
                       & "      end if;" & LF & "      return Item.Balance - Fee;" & LF & "   end Fee_"
                       & Image (Index) & ";" & LF & LF);
            end loop;
            Append (Spec, "end Ledger;" & LF);
            Append (Body_Text, "end Ledger;" & LF);
            Put ("src/ledger.ads", To_String (Spec));
            Put ("src/ledger.adb", To_String (Body_Text));
            Put ("src/test_add.adb",
                 "with Ledger;" & LF & "procedure Test_Add is" & LF & "   Item : Ledger.Book;" & LF
                 & "   Refused : Boolean := False;" & LF & "begin" & LF
                 & "   Ledger.Post (Item, 5);" & LF
                 & "   begin" & LF & "      Ledger.Post (Item, -3);" & LF & "   exception" & LF
                 & "      when Constraint_Error => Refused := True;" & LF & "   end;" & LF
                 & "   if not Refused or else Item.Balance /= 5 or else Item.Entries /= 1 then" & LF
                 & "      raise Program_Error with ""Post took a negative amount"";" & LF
                 & "   end if;" & LF & "end Test_Add;" & LF);
         end;
      elsif Tested then
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
      --  The convention's check: each source file changed since the trial's
      --  start begins with the license line, or it says which and how.
      if Convention then
         Put ("check_header.sh",
              "for f in $(git diff --name-only trial-start -- src); do" & LF
              & "  if [ ""$(head -n 1 ""$f"")"" != """ & License_Line & """ ]; then" & LF
              & "    echo ""$f:1:1: error: a file the work changes must begin with the line '"
              & License_Line & "'""" & LF
              & "    exit 1" & LF
              & "  fi" & LF
              & "done" & LF);
      end if;
      Git ("init -q");
      Git ("add -A");
      Git ("commit -qm start");
      Git ("tag trial-start");
   end Make_Project;

   --  A project kept from an earlier run, its sources put back as they were
   --  made -- whatever the work changed or committed -- and its state kept.
   procedure Reset_Sources (Root : String) is
      procedure Git (Words : String) is
         Line    : Hostkit.String_Vectors.Vector;
         Start   : Positive := Words'First;
         Ignored : Hostkit.Process.Process_Outcome;
      begin
         Line.Append (To_Unbounded_String ("-C"));
         Line.Append (To_Unbounded_String (Root));
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
      Git ("reset -q --hard trial-start");
      Git ("clean -fdq -e .model_runner");
   end Reset_Sources;

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
   --  0 where the trial names none: the model's pace, what so many tokens
   --  take at the speed it generates at -- a 12 t/s model ran out of a
   --  ten-minute bound a 40 t/s one did not need.
   Seconds_Bound : Natural := 0;

   function Time_Bound return String
   is (" scalar.agents.max_seconds="
       & (if Seconds_Bound = 0 then "model"
          else Ada.Strings.Fixed.Trim (Natural'Image (Seconds_Bound), Ada.Strings.Both)));

   --  Where the work is written: in a workspace of its own, taken in by
   --  the harness once its checks pass there, where the trial asks it.
   --  The harness takes work in for an agent that may ask for it:
   --  request_integration, which a project's default leaves out.
   function Apart_Words (Apart : Boolean) return String is
     (if Apart
      then " scalar.work.isolation=workspace scalar.work.integrate=automatic"
           & " map.permission.project.request_integration=on"
      else "");

   --  What the agents find kept and told to later work, or not; and the
   --  context retrieved as it was before excerpts, where the trial asks.
   Whole_Context : Boolean := False;

   function Knowledge_Words (Knowledge : Boolean) return String is
     ((if Knowledge then "" else " scalar.knowledge.observations=off")
      & (if Whole_Context then " scalar.context.retrieval=whole" else ""));

   --  The style rules and warnings as errors, and every unit compiled
   --  each time: an edit within the second of the last build is not taken
   --  for the source that built.
   function Style_Words (Styled : Boolean) return String is
     (if Styled then " -f -gnatyy -gnatwae" else "");

   function Check_Line
     (Tested : Boolean; Apart : Boolean := False; Knowledge : Boolean := True; Styled : Boolean := False;
      Convention : Boolean := False)
      return String is
     (if Tested
      then "/reconfigure add set.execution.allowed gnatmake obj/test_add" & (if Convention then " sh" else "") & " "
           & "profile.checks=""build: gnatmake -q" & Style_Words (Styled) & " -D obj -aIsrc src/main.adb -o obj/main;"
           & " test: gnatmake -q" & Style_Words (Styled)
           & " -D obj -aIsrc src/test_add.adb -o obj/test_add; run: obj/test_add"
           & (if Convention then "; header: sh check_header.sh" else "") & """"
           & Time_Bound & Apart_Words (Apart) & Knowledge_Words (Knowledge) & " confirm=yes"
      else "/reconfigure add set.execution.allowed gnatmake "
           & "profile.checks=""build: gnatmake -q -D obj -aIsrc src/main.adb -o obj/main"""
           & Time_Bound & Apart_Words (Apart) & Knowledge_Words (Knowledge) & " confirm=yes");

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

   --  The decisions the harness proposed from what was mended alike, still
   --  candidates, in a project's state: read from their records, a field
   --  being its name and length on a line and then that many characters.
   function Proposed_Lessons (Root : String) return Hostkit.String_Vectors.Vector is
      use Ada.Directories;
      Found  : Hostkit.String_Vectors.Vector;
      Where  : constant String := Root & "/.model_runner/decisions";
      Search : Search_Type;
      Item   : Directory_Entry_Type;

      function Field (Text, Name : String) return String is
         Mark  : constant String := ASCII.LF & Name & " ";
         At_It : constant Natural := Ada.Strings.Fixed.Index (Text, Mark);
      begin
         if At_It = 0 then
            return "";
         end if;
         declare
            Line_End : constant Natural := Ada.Strings.Fixed.Index (Text (At_It + 1 .. Text'Last), "" & ASCII.LF);
            Count    : Natural := 0;
         begin
            if Line_End = 0 then
               return "";
            end if;
            for C of Text (At_It + Mark'Length .. Line_End - 1) loop
               exit when C not in '0' .. '9';
               Count := Count * 10 + (Character'Pos (C) - Character'Pos ('0'));
            end loop;
            return Text (Line_End + 1 .. Natural'Min (Text'Last, Line_End + Count));
         end;
      end Field;
   begin
      if not Exists (Where) then
         return Found;
      end if;
      Start_Search (Search, Where, "DEC-*.rec", [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         --  A decision's earlier revisions lie beside it, DEC-N.rev-M.rec:
         --  the decision is the record without one, and accepting a
         --  revision's entity id asked for a decision there is none of.
         if Ada.Strings.Fixed.Index (Simple_Name (Item), ".rev-") = 0 then
            declare
               File : Ada.Text_IO.File_Type;
               Text : Unbounded_String;
            begin
               Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Full_Name (Item));
               while not Ada.Text_IO.End_Of_File (File) loop
                  Append (Text, ASCII.LF & Ada.Text_IO.Get_Line (File));
               end loop;
               Ada.Text_IO.Close (File);
               if Field (To_String (Text), "state") = "candidate"
                 and then Ada.Strings.Fixed.Head (Field (To_String (Text), "provenance"), 19) = "observation lesson "
               then
                  Found.Append (To_Unbounded_String (Field (To_String (Text), "entity_id")));
               end if;
            exception
               when others =>
                  if Ada.Text_IO.Is_Open (File) then
                     Ada.Text_IO.Close (File);
                  end if;
            end;
         end if;
      end loop;
      End_Search (Search);
      return Found;
   end Proposed_Lessons;

   procedure Run
     (Model     : String;
      Program   : String;
      Options   : String;
      Only      : String;
      Clean     : out Boolean;
      Repeats   : Positive := 1;
      Apart     : Boolean := False;
      Knowledge : Boolean := True;
      Carry     : Boolean := False;
      Max_Seconds : Natural := 0;
      Context_Size : Natural := 0;
      Accept_Lessons : Boolean := False;
      Whole_Files    : Boolean := False)
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
               & HT & "seconds" & HT & "calls" & HT & "thoughts_closed" & HT & "context");
         else
            --  A history kept before the context was: its heading given the
            --  column, its rows left as they were -- the context they ran at
            --  not said, 8192 as every trial then ran.
            declare
               Old   : Ada.Text_IO.File_Type;
               Lines : Hostkit.String_Vectors.Vector;
            begin
               Ada.Text_IO.Open (Old, Ada.Text_IO.In_File, Path);
               while not Ada.Text_IO.End_Of_File (Old) loop
                  Lines.Append (To_Unbounded_String (Ada.Text_IO.Get_Line (Old)));
               end loop;
               Ada.Text_IO.Close (Old);
               if not Lines.Is_Empty
                 and then Ada.Strings.Fixed.Index (To_String (Lines.First_Element), HT & "context") = 0
               then
                  Lines.Replace_Element (Lines.First_Index, Lines.First_Element & HT & "context");
                  Ada.Text_IO.Create (Old, Ada.Text_IO.Out_File, Path);
                  for Line of Lines loop
                     Ada.Text_IO.Put_Line (Old, To_String (Line));
                  end loop;
                  Ada.Text_IO.Close (Old);
               end if;
            end;
            Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Path);
         end if;
         Ada.Text_IO.Put_Line
           (File, Now & HT & Build & HT & Ada.Directories.Simple_Name (Model) & HT & Task_Name & HT
            & (if Apart then "workspace" else "project") & (if Knowledge then "" else ", knowledge off")
            & (if Whole_Context then ", whole files" else "")
            & (if Carry then ", carried" else "") & (if Accept_Lessons then ", lessons accepted" else "")
            & HT & Ending & HT
            & Ada.Strings.Fixed.Trim (Natural'Image (Seconds), Ada.Strings.Left) & HT
            & Ada.Strings.Fixed.Trim (Natural'Image (Calls), Ada.Strings.Left) & HT & Closed & HT
            & (if Context_Size = 0 then "own" else Ada.Strings.Fixed.Trim (Natural'Image (Context_Size),
                                                                             Ada.Strings.Left)));
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
      Seconds_Bound := Max_Seconds;
      Whole_Context := Whole_Files;
      for Round in 1 .. Repeats loop
         exit when Halted;
         for Which in Tasks'Range loop
            exit when Halted;
            declare
               One : Trial_Task renames Tasks (Which);
            begin
               if Chosen (Only, To_String (One.Name))
                 and then (Only /= ""
                           or else not (One.Styled or else One.Convention or else One.Large or else One.Named_Only))
               then
                  declare
                     Name    : constant String := To_String (One.Name);
                     Root    : constant String := Ada.Directories.Full_Name ("obj/agent-trial-" & Name);
                     Project : constant String := Ada.Directories.Simple_Name (Root);
                     Pair    : Hostkit.Pty.Pair;
                     Spawned : Hostkit.Spawn.Options;
                     Child   : Hostkit.Spawn.Process_Handle;
                     Ended   : Hostkit.Spawn.Status;
                     Seen    : Unbounded_String;
                     --  What the screen showed wrongly, said with the outcome.
                     Display_Faults : Unbounded_String;
                     Began   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                     --  When the screen last grew, and how often a stall was
                     --  written down: a session that shows nothing for five
                     --  minutes has every thread's wait recorded beside it,
                     --  and again at fifteen, so the two say whether anything
                     --  moved -- as the one stall seen (a helper silent 28
                     --  minutes, 2026-10-16) was recorded by hand, and by
                     --  then its run had been written over. Named for the
                     --  time the run began, so a later trial's stall does not
                     --  write over it either -- one of 2026-10-17 outlived its
                     --  run's record and could say only where it waited.
                     Grew    : Ada.Calendar.Time := Ada.Calendar.Clock;

                     --  A time as the host's clock on the wall reads it.
                     function Local (At_Time : Ada.Calendar.Time) return String
                     is (Ada.Calendar.Formatting.Image
                           (At_Time, Time_Zone => Ada.Calendar.Time_Zones.UTC_Time_Offset (At_Time)));

                     Stall_Name : constant String :=
                       Root & "-stall-"
                       & Ada.Strings.Fixed.Translate
                           (Local (Began), Ada.Strings.Maps.To_Mapping (" :", "_-"));
                     Stalls  : Natural := 0;
                     Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
                     Last    : Ada.Streams.Stream_Element_Offset;

                     procedure Keep_Variable (Variable, Value : String) is
                     begin
                        if Variable /= "TERM" then
                           Spawned.Environment.Append (To_Unbounded_String (String'(Variable & "=" & Value)));
                        end if;
                     end Keep_Variable;

                     --  Every thread of the session: its name, its state,
                     --  what it waits in and the call it is in -- whose first
                     --  argument names the descriptor a read waits on -- and
                     --  what each descriptor is, from the host's process
                     --  files where it keeps them, into a file beside the
                     --  session's folder.
                     procedure Note_Stall is
                        use Ada.Directories;
                        Tasks_At : constant String :=
                          "/proc/" & Ada.Strings.Fixed.Trim
                            (Integer'Image (Hostkit.Spawn.Process_Id (Child)),
                             Ada.Strings.Both) & "/task";
                        Out_File : Ada.Text_IO.File_Type;
                        Search   : Search_Type;
                        Item     : Directory_Entry_Type;

                        function First_Line (Path : String) return String is
                           F : Ada.Text_IO.File_Type;
                        begin
                           Ada.Text_IO.Open (F, Ada.Text_IO.In_File, Path);
                           declare
                              Line : constant String := Ada.Text_IO.Get_Line (F);
                           begin
                              Ada.Text_IO.Close (F);
                              return Line;
                           end;
                        exception
                           when others =>
                              return "?";
                        end First_Line;
                     begin
                        Stalls := Stalls + 1;
                        if Stalls = 1 then
                           Append (Display_Faults,
                                   "  display: the session showed nothing for five minutes;"
                                   & " its threads' waits are in " & Stall_Name & ".txt" & ASCII.LF);
                        end if;
                        if not Exists (Tasks_At) then
                           return;
                        end if;
                        --  Beside the project, not in it: written in it, it was a
                        --  file the work had changed, and the task failed for it.
                        Ada.Text_IO.Create
                          (Out_File, Ada.Text_IO.Out_File,
                           Stall_Name
                           & (if Stalls = 1 then ""
                              else "-" & Ada.Strings.Fixed.Trim (Natural'Image (Stalls), Ada.Strings.Both))
                           & ".txt");
                        --  What ran, since when, and how long it has shown
                        --  nothing.
                        Ada.Text_IO.Put_Line
                          (Out_File, "model " & Model & "; began " & Local (Began)
                           & "; quiet since " & Local (Grew));
                        Start_Search (Search, Tasks_At, "", [Directory => True, others => False]);
                        while More_Entries (Search) loop
                           Get_Next_Entry (Search, Item);
                           declare
                              Id : constant String := Simple_Name (Item);
                              At_Task : constant String := Tasks_At & "/" & Id;
                           begin
                              if Id /= "." and then Id /= ".." then
                                 Ada.Text_IO.Put_Line
                                   (Out_File, Id & " " & First_Line (At_Task & "/comm")
                                    & " wchan=" & First_Line (At_Task & "/wchan")
                                    & " syscall=" & First_Line (At_Task & "/syscall")
                                    & " stat=" & First_Line (At_Task & "/stat"));
                              end if;
                           end;
                        end loop;
                        End_Search (Search);
                        declare
                           Fds_At : constant String := Containing_Directory (Tasks_At) & "/fd";
                        begin
                           if Exists (Fds_At) then
                              Start_Search (Search, Fds_At, "");
                              while More_Entries (Search) loop
                                 Get_Next_Entry (Search, Item);
                                 declare
                                    Fd     : constant String := Simple_Name (Item);
                                    Target : Unbounded_String;
                                 begin
                                    if Fd /= "." and then Fd /= ".."
                                      and then Hostkit.Fs.Read_Link_Target (Fds_At & "/" & Fd, Target)
                                    then
                                       Ada.Text_IO.Put_Line (Out_File, "fd " & Fd & " " & To_String (Target));
                                    end if;
                                 end;
                              end loop;
                              End_Search (Search);
                           end if;
                        end;
                        --  And what the screen showed before it went quiet.
                        declare
                           Shown : constant String := Plain (To_String (Seen));
                        begin
                           Ada.Text_IO.Put_Line (Out_File, "screen, its last 4000 characters:");
                           Ada.Text_IO.Put_Line
                             (Out_File, Shown (Integer'Max (Shown'First, Shown'Last - 3_999) .. Shown'Last));
                        end;
                        Ada.Text_IO.Close (Out_File);
                     exception
                        when others =>
                           null;
                     end Note_Stall;

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
                              Grew := Ada.Calendar.Clock;
                           elsif (Stalls = 0 and then Ada.Calendar.Clock - Grew > 300.0)
                             or else (Stalls = 1 and then Ada.Calendar.Clock - Grew > 900.0)
                           then
                              Note_Stall;
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

                     --  Kept from the run before, where runs carry their
                     --  state: no /init, and the task the next one made.
                     Carried : constant Boolean :=
                       Carry and then Round > 1 and then Ada.Directories.Exists (Root & "/.model_runner");
                     Task_Id : Unbounded_String := To_Unbounded_String ("TASK-001");

                     --  The task the session last said it made.
                     function Made_Task return String is
                        Text  : constant String := Plain (To_String (Seen));
                        Mark  : constant String := "created TASK-";
                        At_It : constant Natural :=
                          Ada.Strings.Fixed.Index (Text, Mark, Going => Ada.Strings.Backward);
                        Last  : Natural := At_It + Mark'Length - 1;
                     begin
                        if At_It = 0 then
                           return "TASK-001";
                        end if;
                        while Last < Text'Last and then Text (Last + 1) in '0' .. '9' | 'A' .. 'Z' | '-' loop
                           Last := Last + 1;
                        end loop;
                        return Text (At_It + 8 .. Last);
                     end Made_Task;
                  begin
                     if Carried then
                        Reset_Sources (Root);
                     else
                        Make_Project (Root, One.Tested, One.Convention, One.Large);
                     end if;
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
                     --  The session's own context where none is asked, as a
                     --  person's session has it.
                     if Context_Size > 0 then
                        Words.Append (To_Unbounded_String ("--context-size"));
                        Words.Append (To_Unbounded_String
                                        (Ada.Strings.Fixed.Trim (Natural'Image (Context_Size), Ada.Strings.Both)));
                     end if;
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
                        if not Carried then
                           Send ("/init");
                        end if;
                        if Carried or else Wait_For ("Select project type", 30.0) then
                           if not Carried then
                              Send ("");
                           end if;
                           if Carried or else Wait_For ("as planned", 30.0) then
                              if not Carried then
                                 Send ("");
                              end if;
                              if Carried
                                or else (Wait_For ("initialized", 30.0)
                                         and then (Hostkit.Process.Locate ("gnatmake") = ""
                                                   or else (Send_Then
                                                              (Check_Line (One.Tested, Apart, Knowledge,
                                                                           One.Styled, One.Convention))
                                                            and then Wait_For ("is now revision", 30.0))))
                              then
                                 --  What the harness proposed from what earlier
                                 --  runs mended alike, accepted as a person
                                 --  would, before the task is made.
                                 if Carried and then Accept_Lessons then
                                    for Lesson of Proposed_Lessons (Root) loop
                                       Send ("/decision accept " & To_String (Lesson));
                                       --  The session's word that it is, not the
                                       --  echo of the command that asked.
                                       if Wait_For (To_String (Lesson) & " is accepted", 30.0) then
                                          Ada.Text_IO.Put_Line
                                            ("  accepted " & To_String (Lesson) & ", proposed from what was mended");
                                       end if;
                                    end loop;
                                 end if;
                                 Send ("/task new Trial " & Name & " kind=" & To_String (One.Kind)
                                       & (if To_String (One.Kind) = "implementation"
                                          then " component=" & Project else "")
                                       & " notes=" & To_String (One.Notes));
                                 if Wait_For ("created TASK-", 30.0) then
                                    Task_Id := To_Unbounded_String (Made_Task);
                                    Send ("/accept " & To_String (Task_Id));
                                    if Wait_For ("ready", 30.0) then
                                       Send ("/work " & To_String (Task_Id));
                                       Worked := Wait_For ("How it came out",
                                                          Duration (if Max_Seconds = 0 then 3_600 else Max_Seconds)
                                                          + 600.0);
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

                     --  What the screen showed, kept beside the session: what
                     --  the person driving it would have read -- whether a
                     --  display option such as --hide-reasoning did its part
                     --  is a question about this, not about the records.
                     declare
                        Shown : Ada.Text_IO.File_Type;
                     begin
                        Ada.Text_IO.Create
                          (Shown, Ada.Text_IO.Out_File, Root & "/.trial-screen.txt");
                        Ada.Text_IO.Put (Shown, Plain (To_String (Seen)));
                        Ada.Text_IO.Close (Shown);
                     exception
                        when others =>
                           null;
                     end;

                     --  And what is wrong with it, said with the outcome: a
                     --  person reads the screen, and no test in the process
                     --  reaches the screen a model's work writes.
                     declare
                        Screen : constant String := Plain (To_String (Seen));
                        Record_At : constant Natural :=
                          Ada.Strings.Fixed.Index
                            (Screen, "the work as the harness recorded it");
                        procedure Fault (Text : String) is
                        begin
                           Append (Display_Faults, "  display: " & Text & ASCII.LF);
                        end Fault;
                     begin
                        if Record_At > Screen'First
                          and then Screen (Record_At - 1) /= ASCII.LF
                        then
                           Fault ("the harness's record ran on from the line before it");
                        end if;
                        if Ada.Strings.Fixed.Index (Screen, "</think></think>") > 0 then
                           Fault ("a think block's close was shown twice");
                        end if;
                        --  Raw markup the screen then says was a reply cut off
                        --  at its length limit, or by the work's time, is what
                        --  the model wrote, and no call: said as that, not as
                        --  a fault.
                        if Ada.Strings.Fixed.Index (Screen, "<tool_call>") > 0
                          and then not (for all At_It in Screen'Range =>
                                          At_It + 10 > Screen'Last
                                          or else Screen (At_It .. At_It + 10) /= "<tool_call>"
                                          or else Ada.Strings.Fixed.Index
                                                    (Screen (At_It .. Natural'Min (Screen'Last, At_It + 8_000)),
                                                     "reached its length limit before it finished") > 0
                                          or else Ada.Strings.Fixed.Index
                                                    (Screen (At_It .. Natural'Min (Screen'Last, At_It + 8_000)),
                                                     "time ran out while the reply was being written") > 0)
                        then
                           Fault ("a call's raw markup was shown");
                        end if;
                     end;

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

                              --  One of the work's figures, by what it is
                              --  called: its digits, "0" where it is not said.
                              function Figure (Mark : String) return String is
                                 Line  : constant String := To_String (Figures);
                                 At_It : constant Natural := Ada.Strings.Fixed.Index (Line, Mark);
                                 Last  : Natural;
                              begin
                                 if At_It = 0 then
                                    return "0";
                                 end if;
                                 Last := At_It + Mark'Length;
                                 while Last <= Line'Last and then Line (Last) in ' ' | '0' .. '9' loop
                                    Last := Last + 1;
                                 end loop;
                                 return Ada.Strings.Fixed.Trim
                                   (Line (At_It + Mark'Length .. Last - 1), Ada.Strings.Both);
                              end Figure;

                              Closed : constant String := Figure ("thoughts closed at their budget:");
                              Made   : constant String := Figure ("tokens generated:");
                              Held   : constant String := Figure ("context at most:");
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
                                      & Made & " tokens made, " & Held & " held at most, "
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
                              & LF & "  session kept in " & Root
                              & (if Length (Display_Faults) = 0 then ""
                                 else LF & To_String (Display_Faults)));
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
                        --  run makes afresh -- named by the arm it is of, so a
                        --  trial's other arm, run after, keeps it.
                        if Repeats > 1 then
                           Ada.Text_IO.Create
                             (File, Ada.Text_IO.Out_File,
                              Root & (if Whole_Context then "-whole" else "")
                              & (if Knowledge then "" else "-knowledge-off")
                              & "-run" & Ada.Strings.Fixed.Trim (Integer'Image (Round), Ada.Strings.Left)
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
