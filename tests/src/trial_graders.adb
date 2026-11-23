with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Characters.Handling;
with Hostkit;
with Hostkit.Fs;
with Hostkit.Process;
with Project_Tools.Files;
with Project_Tools.Text;
with Trial_Confinement;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Model_Runner.Errors;
with Model_Runner.Trajectories;

package body Trial_Graders is

   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Size;
   use type Agent_Trial.Verdict;

   function Uses_Reference_Edit (Capture_Path : String) return Boolean is
      package J renames Jsonlib.Documents;
      package T renames Model_Runner.Trajectories;
      use type J.Value_Kind;
      Checked : T.Validation;
      Status : Model_Runner.Errors.Error_Info;
      Reference_Call : array (1 .. 1_024) of Boolean := [others => False];
      Success : Boolean := False;
      function Text (Doc : J.Document; Node : J.Node; Key : String) return String is
      begin
         if J.Kind (Doc, Node) = J.Object_Value and then J.Has_Member (Doc, Node, Key)
           and then J.Kind (Doc, J.Member (Doc, Node, Key)) = J.String_Value
         then
            return J.As_String (Doc, J.Member (Doc, Node, Key));
         end if;
         return "";
      end Text;
   begin
      if not Ada.Directories.Exists (Capture_Path) or else Hostkit.Fs.Is_Link (Capture_Path)
        or else Ada.Directories.Size (Capture_Path) > 16 * 1_024 * 1_024
      then
         return False;
      end if;
      T.Validate (Capture_Path, Checked, Status);
      if Model_Runner.Errors.Is_Error (Status) or else not Checked.Complete or else not Checked.Exact_Tokens then
         return False;
      end if;
      declare
         Raw : constant String := Project_Tools.Files.Read_Raw_File (Capture_Path);
         First : Positive := Raw'First;
      begin
         for Last in Raw'Range loop
            if Raw (Last) = ASCII.LF then
               declare
                  Envelope, Payload, Args : J.Document;
                  Error : Jsonlib.Errors.Error_Info;
                  Body_Node : J.Node;
                  Id : Long_Long_Integer;
               begin
                  Jsonlib.Parsers.Parse (Raw (First .. Last - 1), Envelope, Error);
                  if Jsonlib.Errors.Failed (Error) then
                     return False;
                  end if;
                  if Text (Envelope, J.Root (Envelope), "kind") in "tool_call" | "tool_result" then
                     Jsonlib.Parsers.Parse (Text (Envelope, J.Root (Envelope), "payload"), Payload, Error);
                     if Jsonlib.Errors.Failed (Error) then
                        return False;
                     end if;
                     Body_Node := J.Root (Payload);
                     Id := J.As_Integer (Payload, J.Member (Payload, Body_Node, "id"));
                     if Id not in 1 .. Reference_Call'Length then
                        return False;
                     end if;
                     if Text (Envelope, J.Root (Envelope), "kind") = "tool_call" then
                        if Text (Payload, Body_Node, "name") in "write_file" | "delegate" then
                           return False;
                        elsif Text (Payload, Body_Node, "name") = "edit_file" then
                           Jsonlib.Parsers.Parse (Text (Payload, Body_Node, "arguments"), Args, Error);
                           if Jsonlib.Errors.Failed (Error) or else J.Kind (Args, J.Root (Args)) /= J.Object_Value
                             or else J.Has_Member (Args, J.Root (Args), "old_text")
                             or else Text (Args, J.Root (Args), "path") /= "src/calc.adb"
                             or else Text (Args, J.Root (Args), "ref") = ""
                           then
                              return False;
                           end if;
                           Reference_Call (Natural (Id)) := True;
                        end if;
                     elsif Reference_Call (Natural (Id))
                       and then Ada.Strings.Fixed.Index
                         (Text (Payload, Body_Node, "text"), "replaced Calc.Add in src/calc.adb;") = 1
                     then
                        Success := True;
                     end if;
                  end if;
               end;
               First := Last + 1;
            end if;
         end loop;
      end;
      return Success;
   exception
      when others => return False;
   end Uses_Reference_Edit;

   procedure Preserve (Root : String) is
      Where : constant String := Root & "-verifier";
      Ran : Hostkit.Process.Process_Outcome;
   begin
      if Ada.Directories.Exists (Where) then
         Ada.Directories.Delete_Tree (Where);
      end if;
      Ada.Directories.Create_Path (Where & "/obj");
      if Ada.Directories.Exists (Root & "/src/test_add.adb") then
         Ada.Directories.Copy_File (Root & "/src/test_add.adb", Where & "/test_add.adb");
      end if;
      if Ada.Directories.Exists (Root & "/src/test_math.c") then
         Ada.Directories.Copy_File (Root & "/src/test_math.c", Where & "/test_math.c");
      end if;
      Ran := Hostkit.Process.Run_Captured
        ("git", [To_Unbounded_String ("clone"), To_Unbounded_String ("--quiet"),
                 To_Unbounded_String ("--bare"), To_Unbounded_String ("--no-hardlinks"),
                 To_Unbounded_String (Ada.Directories.Full_Name (Root)),
                 To_Unbounded_String (Ada.Directories.Full_Name (Where & "/baseline.git"))],
         Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Where & "/baseline-errors.txt",
         Timeout_Ms => 10_000);
      if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
         return;
      end if;
      Ran := Hostkit.Process.Run_Captured
        ("git", [To_Unbounded_String ("--git-dir=" & Ada.Directories.Full_Name (Where & "/baseline.git")),
                 To_Unbounded_String ("read-tree"), To_Unbounded_String ("HEAD")],
         Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Where & "/baseline-errors.txt",
         Timeout_Ms => 10_000);
      if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
         return;
      end if;
   end Preserve;

   function Seal (Root : String) return Boolean is
      Base : constant Hostkit.String_Vectors.Vector :=
        [To_Unbounded_String ("--git-dir=" & Ada.Directories.Full_Name (Root & "-verifier/baseline.git")),
         To_Unbounded_String ("--work-tree=" & Ada.Directories.Full_Name (Root)),
         To_Unbounded_String ("-c"), To_Unbounded_String ("core.hooksPath=/dev/null"),
         To_Unbounded_String ("-c"), To_Unbounded_String ("commit.gpgsign=false"),
         To_Unbounded_String ("-c"), To_Unbounded_String ("user.name=trial"),
         To_Unbounded_String ("-c"), To_Unbounded_String ("user.email=trial@example.invalid")];
      Words : Hostkit.String_Vectors.Vector := Base;
      Ran : Hostkit.Process.Process_Outcome;
   begin
      Words.Append_Vector
        ([To_Unbounded_String ("add"), To_Unbounded_String ("--force"), To_Unbounded_String ("--all"),
          To_Unbounded_String ("--"), To_Unbounded_String ("."), To_Unbounded_String (":(exclude).git"),
          To_Unbounded_String (":(exclude).model_runner"), To_Unbounded_String (":(exclude).trial-runtime"),
          To_Unbounded_String (":(exclude)model_runner"), To_Unbounded_String (":(exclude)obj"),
          To_Unbounded_String (":(exclude).trial-screen.txt"), To_Unbounded_String (":(exclude).trial-session.txt"),
          To_Unbounded_String (":(exclude).trial-diff")]);
      Ran := Hostkit.Process.Run_Captured
        ("git", Words, Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Root & "-verifier/seal-errors.txt",
         Timeout_Ms => 10_000);
      if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0 then
         return False;
      end if;
      Words := Base;
      Words.Append_Vector
        ([To_Unbounded_String ("commit"), To_Unbounded_String ("--allow-empty"),
          To_Unbounded_String ("-qm"), To_Unbounded_String ("trusted trial initialization")]);
      Ran := Hostkit.Process.Run_Captured
        ("git", Words, Stdout_Path => Hostkit.Fs.Null_Device, Stderr_Path => Root & "-verifier/seal-errors.txt",
         Timeout_Ms => 10_000);
      return Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 0;
   exception
      when others => return False;
   end Seal;

   function Check_Changes (Root, Task_Name : String) return Agent_Trial.Verdict is
      Words : Hostkit.String_Vectors.Vector;
      Ran : Hostkit.Process.Process_Outcome;
      Path : constant String := Root & "-verifier/changes.txt";
      function Allowed (Name : String) return Boolean is
        (if Task_Name in "large" | "described" then Name = "src/ledger.adb"
         elsif Task_Name = "subtract" then Name in "src/calc.adb" | "src/calc.ads"
         elsif Task_Name = "c-boundary" then Name = "src/math.c"
         elsif Task_Name = "c-multi" then Name in "src/math.c" | "src/math.h"
         elsif Task_Name = "delegate" then Name = "docs/calc.md"
         elsif Task_Name in "edit" | "edit-ref" | "styled" | "convention" | "times-negative" | "delegate-edit"
         then Name = "src/calc.adb"
         else False);
   begin
      if Hostkit.Fs.Is_Link (Root & "/src") or else Hostkit.Fs.Is_Link (Root & "/docs") then
         return Agent_Trial.Failed;
      end if;
      for Pass in 1 .. 2 loop
         Words := [To_Unbounded_String ("--git-dir=" & Ada.Directories.Full_Name (Root & "-verifier/baseline.git")),
                   To_Unbounded_String ("--work-tree=" & Ada.Directories.Full_Name (Root)),
                   To_Unbounded_String ("-c"), To_Unbounded_String ("core.fsmonitor=false")];
         if Pass = 1 then
            Words.Append_Vector
              ([To_Unbounded_String ("diff"), To_Unbounded_String ("--name-only"),
                To_Unbounded_String ("--no-ext-diff"), To_Unbounded_String ("--no-textconv"),
                To_Unbounded_String ("HEAD"), To_Unbounded_String ("--")]);
         else
            --  No --exclude-standard: an ignore rule cannot hide an output.
            --  Exclude only the native fixture's reserved runtime directories.
            Words.Append_Vector
              ([To_Unbounded_String ("ls-files"), To_Unbounded_String ("--others"),
                To_Unbounded_String ("--full-name"), To_Unbounded_String ("--"), To_Unbounded_String ("."),
                To_Unbounded_String (":(exclude).git"), To_Unbounded_String (":(exclude).model_runner"),
                To_Unbounded_String (":(exclude).trial-runtime"), To_Unbounded_String (":(exclude)model_runner"),
                To_Unbounded_String (":(exclude)obj"), To_Unbounded_String (":(exclude).trial-screen.txt"),
                To_Unbounded_String (":(exclude).trial-session.txt"), To_Unbounded_String (":(exclude).trial-diff")]);
         end if;
         Ran := Hostkit.Process.Run_Captured
           ("git", Words, Stdout_Path => Path, Stderr_Path => Hostkit.Fs.Null_Device, Timeout_Ms => 10_000);
         if not Ran.Started or else Ran.Timed_Out or else Ran.Exit_Status /= 0
           or else Ada.Directories.Size (Path) > 65_536
         then
            return Agent_Trial.Infrastructure_Error;
         end if;
         declare
            Text : constant String := Project_Tools.Files.Read_Raw_File (Path);
            Start : Positive := Text'First;
         begin
            for I in Text'First .. Text'Last + 1 loop
               if I > Text'Last or else Text (I) = ASCII.LF then
                  if I > Start and then (not Allowed (Text (Start .. I - 1))
                    or else Hostkit.Fs.Is_Link (Root & "/" & Text (Start .. I - 1)))
                  then
                     return Agent_Trial.Failed;
                  end if;
                  Start := I + 1;
               end if;
            end loop;
         end;
      end loop;
      return Agent_Trial.Passed;
   exception
      when others => return Agent_Trial.Infrastructure_Error;
   end Check_Changes;

   function Verify
     (Root, Task_Name, Expect, Transcript : String;
      Completed : Boolean; Confine : Boolean := False) return Agent_Trial.Verdict
   is
      Where : constant String := Ada.Directories.Full_Name (Root & "-verifier");
      Words : Hostkit.String_Vectors.Vector;
      Ran   : Hostkit.Process.Process_Outcome;
      function Run_Check (Program, Output, Errors : String; Timeout : Natural)
        return Hostkit.Process.Process_Outcome
      is
         Native : constant String := Hostkit.Process.Locate (Program);
      begin
         if not Confine then
            return Hostkit.Process.Run_Captured
              (Program, Words, Stdout_Path => Output, Stderr_Path => Errors, Timeout_Ms => Timeout);
         elsif Native = "" or else Trial_Confinement.Executable = "" then
            return (others => <>);
         end if;
         return Hostkit.Process.Run_Captured
           (Trial_Confinement.Executable, Trial_Confinement.Wrap
              (Native, Words, Where & "/obj", Readable =>
                 [To_Unbounded_String (Ada.Directories.Full_Name (Root)), To_Unbounded_String (Where)]),
            Stdout_Path => Output, Stderr_Path => Errors, Timeout_Ms => Timeout);
      end Run_Check;
      function Has (Text, Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Text, Part) > 0);
      function Final_Answer return String is
         At_It : constant Natural := Ada.Strings.Fixed.Index (Transcript, "status:", Ada.Strings.Backward);
         Last : Natural;
      begin
         if At_It = 0 then
            return "";
         end if;
         Last := Ada.Strings.Fixed.Index
           (Transcript (At_It .. Transcript'Last), "the work as the harness recorded it");
         return Ada.Characters.Handling.To_Lower
           (Transcript (At_It .. (if Last = 0 then Transcript'Last else Last - 1)));
      end Final_Answer;
      function Has_Line_Five (Text : String) return Boolean is
         function Reference (Part : String) return Boolean is
            At_It : constant Natural := Ada.Strings.Fixed.Index (Text, Part);
         begin
            return At_It > 0 and then
              (At_It + Part'Length > Text'Last or else Text (At_It + Part'Length) not in '0' .. '9');
         end Reference;
      begin
         return Reference ("src/calc.ads:5") or else Reference ("line 5")
           or else Reference ("line `5`") or else Reference ("line **5**");
      end Has_Line_Five;
   begin
      if not Completed then
         return Agent_Trial.Failed;
      elsif Task_Name = "edit-ref" and then not Uses_Reference_Edit
        (Root & "/.trial-runtime/captures/episode-1/events.jsonl")
      then
         return Agent_Trial.Failed;
      end if;
      if Task_Name = "convention" then
         declare
            Path : constant String := Root & "/src/calc.adb";
            License : constant String := "--  SPDX-License-Identifier: MIT" & ASCII.LF;
         begin
            if not Ada.Directories.Exists (Path) or else Ada.Directories.Size (Path) > 1_048_576 then
               return Agent_Trial.Failed;
            end if;
            declare
               Source : constant String := Project_Tools.Files.Read_Raw_File (Path);
            begin
               if Source'Length < License'Length
                 or else Source (Source'First .. Source'First + License'Length - 1) /= License
               then
                  return Agent_Trial.Failed;
               end if;
            end;
         end;
      end if;

      if Ada.Directories.Exists (Where & "/test_math.c") then
         if Hostkit.Process.Locate ("cc") = "" then
            return Agent_Trial.Infrastructure_Error;
         elsif not Ada.Directories.Exists (Root & "/src/test_math.c")
           or else Ada.Directories.Size (Root & "/src/test_math.c") > 16_384
         then
            return Agent_Trial.Failed;
         elsif Project_Tools.Files.Read_Raw_File (Where & "/test_math.c")
           /= Project_Tools.Files.Read_Raw_File (Root & "/src/test_math.c")
         then
            return Agent_Trial.Failed;
         end if;
         Words := [To_Unbounded_String ("-std=c99"), To_Unbounded_String ("-Wall"),
                   To_Unbounded_String ("-Wextra"), To_Unbounded_String ("-Werror"),
                   To_Unbounded_String ("-I" & Ada.Directories.Full_Name (Root & "/src")),
                   To_Unbounded_String (Ada.Directories.Full_Name (Root & "/src/math.c")),
                   To_Unbounded_String (Where & "/test_math.c"), To_Unbounded_String ("-o"),
                   To_Unbounded_String (Where & "/obj/check")];
         Ran := Run_Check ("cc", Where & "/build.txt", Where & "/build-errors.txt", 60_000);
         if not Ran.Started or else Ran.Timed_Out then
            return Agent_Trial.Infrastructure_Error;
         elsif Ran.Exit_Status /= 0 then
            return Agent_Trial.Failed;
         end if;
         Words.Clear;
         Ran := Run_Check (Where & "/obj/check", Where & "/check.txt", Where & "/check-errors.txt", 10_000);
         return (if not Ran.Started then Agent_Trial.Infrastructure_Error
                 elsif Ran.Timed_Out then Agent_Trial.Failed
                 elsif Ran.Exit_Status = 0 then Agent_Trial.Passed else Agent_Trial.Failed);
      elsif Ada.Directories.Exists (Where & "/test_add.adb") then
         if not Ada.Directories.Exists (Root & "/src/test_add.adb")
           or else Ada.Directories.Size (Root & "/src/test_add.adb") > 16_384
         then
            return Agent_Trial.Failed;
         end if;
         declare
            Original : constant String := Project_Tools.Files.Read_Raw_File (Where & "/test_add.adb");
            Current : constant String := Project_Tools.Files.Read_Raw_File (Root & "/src/test_add.adb");
            License : constant String := "--  SPDX-License-Identifier: MIT" & ASCII.LF;
         begin
            if Current /= Original and then Current /= License & Original then
               return Agent_Trial.Failed;
            end if;
         end;
         if Hostkit.Process.Locate ("gnatmake") = "" then
            return Agent_Trial.Infrastructure_Error;
         end if;
         --  Force a rebuild into trusted storage, ignoring any objects produced by the agent.
         Words := [To_Unbounded_String ("-q"), To_Unbounded_String ("-f"),
                   To_Unbounded_String ("-D"), To_Unbounded_String (Where & "/obj"),
                   To_Unbounded_String ("-aI" & Ada.Directories.Full_Name (Root & "/src")),
                   To_Unbounded_String (Where & "/test_add.adb"), To_Unbounded_String ("-o"),
                   To_Unbounded_String (Where & "/obj/check")];
         if Task_Name = "styled" then
            Words.Append (To_Unbounded_String ("-gnatyy"));
            Words.Append (To_Unbounded_String ("-gnatwae"));
         end if;
         Ran := Run_Check ("gnatmake", Where & "/build.txt", Where & "/build-errors.txt", 60_000);
         if not Ran.Started or else Ran.Timed_Out then
            return Agent_Trial.Infrastructure_Error;
         elsif Ran.Exit_Status /= 0 then
            return Agent_Trial.Failed;
         end if;
         Words.Clear;
         Ran := Run_Check (Where & "/obj/check", Where & "/check.txt", Where & "/check-errors.txt", 10_000);
         return (if not Ran.Started then Agent_Trial.Infrastructure_Error
                 elsif Ran.Timed_Out then Agent_Trial.Failed
                 elsif Ran.Exit_Status = 0 then Agent_Trial.Passed else Agent_Trial.Failed);
      elsif Task_Name = "find" or else Expect /= "" then
         if Check_Changes (Root, Task_Name) /= Agent_Trial.Passed then
            return Agent_Trial.Failed;
         end if;
         return (if Expect /= "" then
                   (if Has (Final_Answer, Ada.Characters.Handling.To_Lower (Expect))
                    then Agent_Trial.Passed else Agent_Trial.Failed)
                 elsif Has (Final_Answer, "src/calc.ads") and then Has (Final_Answer, "src/main.adb")
                   and then Has (Final_Answer, "times") and then Has_Line_Five (Final_Answer)
                 then Agent_Trial.Passed else Agent_Trial.Failed);
      elsif Task_Name = "delegate" then
         if not Ada.Directories.Exists (Root & "/docs/calc.md")
           or else Ada.Directories.Size (Root & "/docs/calc.md") > 1_048_576
         then
            return Agent_Trial.Failed;
         end if;
         declare
            Text : constant String := To_String (Project_Tools.Text.Read_Text_File (Root & "/docs/calc.md"));
         begin
            return (if Has (Text, "Add") and then Has (Text, "Times")
                      and then Has (Transcript, "delegate {")
                    then Agent_Trial.Passed else Agent_Trial.Failed);
         end;
      end if;
      return Agent_Trial.Ungraded;
   exception
      when others =>
         return Agent_Trial.Infrastructure_Error;
   end Verify;

end Trial_Graders;
