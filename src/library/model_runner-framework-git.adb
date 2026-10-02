with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit;
with Hostkit.Fs;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Records;

package body Model_Runner.Framework.Git is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   -----------------
   -- Keep_Policy --
   -----------------

   procedure Keep_Policy
     (Item    : Stores.Store;
      Written : out Boolean;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Config : Records.Item;
      Read   : E.Error_Info;
      Path   : constant String := Hostkit.Fs.Join (Stores.Root (Item), ".gitignore");
      Text   : Unbounded_String;
      Held   : Unbounded_String;
   begin
      Written := False;
      Configurations.Read (Item, Config, Read);
      declare
         Policy : constant String :=
           (if Records.Get (Config, "scalar.repository.state_policy") = ""
            then "portable" else Records.Get (Config, "scalar.repository.state_policy"));
      begin
         Append (Text, "# Written by model_runner from scalar repository.state_policy = "
                 & Policy & "." & ASCII.LF & "# Change the policy, not this file." & ASCII.LF);
         if Policy = "local" then
            Append (Text, "*" & ASCII.LF & "!.gitignore" & ASCII.LF);
         elsif Policy = "portable" then
            for Where in Area loop
               if Portability_Of (Where) /= Repository_Portable then
                  Append (Text, "/" & Directory_Name (Where) & "/" & ASCII.LF);
               end if;
            end loop;
         elsif Policy /= "all" then
            Status := E.Make (E.Framework_Schema_Violation);
            E.Add_Text (Status, "name", "repository.state_policy");
            E.Add_Text (Status, "detail", Policy & " is not portable, local or all");
            return;
         end if;
      end;

      Status := E.Success;
      if Ada.Directories.Exists (Path) then
         Files.Read_Text (Path, Held, Read);
      end if;
      if Held /= Text then
         Files.Write_Text (Path, To_String (Text), Status);
         Written := E.Is_Ok (Status);
      end if;
   end Keep_Policy;

   ---------------
   -- Status_Of --
   ---------------

   function Status_Of (Project_Directory : String) return Status_Report is
      Result    : Status_Report;
      Arguments : Name_Lists.Vector;
      --  Outside the project, or Git would see the file it writes to.
      Output    : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Temp_Directory,
                         "model_runner-git-status-" & Fingerprint (Project_Directory) & ".txt");
      Happened  : Execution.Outcome;
      Text      : Unbounded_String;
      Read      : E.Error_Info;
   begin
      Arguments.Append ("status");
      Arguments.Append ("--porcelain=v1");
      Arguments.Append ("--branch");
      --  Each new file, not the new directory it is in: a task's file
      --  there is known as its.
      Arguments.Append ("--untracked-files=all");
      --  What is in the project only, where it is part of a larger
      --  repository: the rest is no task's work.
      Arguments.Append ("--");
      Arguments.Append (".");
      Execution.Run_Harness
        (Project_Directory, "git", Arguments, Project_Directory, Output, 60, Happened);
      if Ada.Directories.Exists (Output) then
         Files.Read_Text (Output, Text, Read);
         Files.Discard (Output);
      end if;
      Result.Found := Happened.Started and then not Happened.Timed_Out
        and then Happened.Exit_Status = 0;
      if not Result.Found then
         return Result;
      end if;
      declare
         --  Git names a path from the repository's top: within a project
         --  further down, from the project's, as everything else does.
         Top    : constant String := Top_Level (Project_Directory);
         Here   : constant String := Ada.Directories.Full_Name (Project_Directory);
         Prefix : constant String :=
           (if Top /= "" and then Here'Length > Top'Length + 1
              and then Here (Here'First .. Here'First + Top'Length - 1) = Top
            then Here (Here'First + Top'Length + 1 .. Here'Last) & "/" else "");
      begin
         for Line of Lines_Of (To_String (Text)) loop
            if Line'Length > 3 and then Line (Line'First .. Line'First + 2) = "## " then
               Result.Branch := To_Unbounded_String (Line (Line'First + 3 .. Line'Last));
            elsif Line'Length > 3 then
               declare
                  Path : constant String := Line (Line'First + 3 .. Line'Last);
               begin
                  Result.Changes.Append
                    (if Prefix /= "" and then Path'Length > Prefix'Length
                       and then Path (Path'First .. Path'First + Prefix'Length - 1) = Prefix
                     then Line (Line'First .. Line'First + 2) & Path (Path'First + Prefix'Length .. Path'Last)
                     else Line);
               end;
            end if;
         end loop;
      end;
      return Result;
   end Status_Of;

   ---------------
   -- Top_Level --
   ---------------

   function Top_Level (Directory : String) return String is
      Arguments : Name_Lists.Vector;
      Output    : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Temp_Directory,
                         "model_runner-git-top-" & Fingerprint (Directory) & ".txt");
      Happened  : Execution.Outcome;
      Text      : Unbounded_String;
      Read      : E.Error_Info;
   begin
      Arguments.Append ("rev-parse");
      Arguments.Append ("--show-toplevel");
      Execution.Run_Harness (Directory, "git", Arguments, Directory, Output, 60, Happened);
      if Ada.Directories.Exists (Output) then
         Files.Read_Text (Output, Text, Read);
         Files.Discard (Output);
      end if;
      if not (Happened.Started and then not Happened.Timed_Out and then Happened.Exit_Status = 0) then
         return "";
      end if;
      for Line of Lines_Of (To_String (Text)) loop
         if Line /= "" then
            return Line;
         end if;
      end loop;
      return "";
   end Top_Level;

   ------------------------
   -- Renamed_In_History --
   ------------------------

   function Renamed_In_History (Project_Directory, Path : String) return String is
      Arguments : Name_Lists.Vector;
      Output    : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Temp_Directory,
                         "model_runner-git-renames-" & Fingerprint (Project_Directory) & ".txt");
      Happened  : Execution.Outcome;
      Text      : Unbounded_String;
      Read      : E.Error_Info;
      Top       : constant String := Top_Level (Project_Directory);
      Here      : constant String := Ada.Directories.Full_Name (Project_Directory);
      Prefix    : constant String :=
        (if Top /= "" and then Here'Length > Top'Length + 1
           and then Here (Here'First .. Here'First + Top'Length - 1) = Top
         then Here (Here'First + Top'Length + 1 .. Here'Last) & "/" else "");
      Now       : Unbounded_String := To_Unbounded_String (Prefix & Path);
   begin
      --  The renames of the last commits, newest first: old and new path.
      Arguments.Append ("log");
      Arguments.Append ("-M");
      Arguments.Append ("--diff-filter=R");
      Arguments.Append ("--name-status");
      Arguments.Append ("--format=");
      Arguments.Append ("-n");
      Arguments.Append ("200");
      Execution.Run_Harness (Project_Directory, "git", Arguments, Project_Directory, Output, 60, Happened);
      if Ada.Directories.Exists (Output) then
         Files.Read_Text (Output, Text, Read);
         Files.Discard (Output);
      end if;
      if not (Happened.Started and then not Happened.Timed_Out and then Happened.Exit_Status = 0) then
         return "";
      end if;
      declare
         Lines   : constant Name_Lists.Vector := Lines_Of (To_String (Text));
         Changed : Boolean := True;
         Rounds  : Natural := 0;
      begin
         --  Oldest rename first, then each one after it.
         while Changed and then Rounds < 10 loop
            Changed := False;
            Rounds := Rounds + 1;
            for Line of reverse Lines loop
               declare
                  First_Tab  : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                  Second_Tab : constant Natural :=
                    (if First_Tab = 0 then 0
                     else Ada.Strings.Fixed.Index (Line (First_Tab + 1 .. Line'Last), [1 => ASCII.HT]));
               begin
                  if Line'Length > 1 and then Line (Line'First) = 'R' and then Second_Tab > 0
                    and then Line (First_Tab + 1 .. Second_Tab - 1) = To_String (Now)
                  then
                     Now := To_Unbounded_String (Line (Second_Tab + 1 .. Line'Last));
                     Changed := True;
                  end if;
               end;
            end loop;
         end loop;
      end;
      --  And a rename not yet committed -- git mv, edited since or not:
      --  as the index has it, R  old -> new.
      declare
         Staged : Name_Lists.Vector;
         Seen   : Unbounded_String;
         Got    : E.Error_Info;
      begin
         Staged.Append ("status");
         Staged.Append ("--porcelain=v1");
         Staged.Append ("-M");
         Execution.Run_Harness (Project_Directory, "git", Staged, Project_Directory, Output, 60, Happened);
         if Ada.Directories.Exists (Output) then
            Files.Read_Text (Output, Seen, Got);
            Files.Discard (Output);
         end if;
         if Happened.Started and then not Happened.Timed_Out and then Happened.Exit_Status = 0 then
            for Line of Lines_Of (To_String (Seen)) loop
               declare
                  Arrow : constant Natural := Ada.Strings.Fixed.Index (Line, " -> ");
               begin
                  if Line'Length > 3 and then Line (Line'First) = 'R' and then Arrow > Line'First + 3
                    and then Line (Line'First + 3 .. Arrow - 1) = To_String (Now)
                  then
                     Now := To_Unbounded_String (Line (Arrow + 4 .. Line'Last));
                  end if;
               end;
            end loop;
         end if;
      end;
      if To_String (Now) = Prefix & Path then
         return "";
      end if;
      declare
         Went : constant String := To_String (Now);
      begin
         return (if Prefix /= "" and then Went'Length > Prefix'Length
                   and then Went (Went'First .. Went'First + Prefix'Length - 1) = Prefix
                 then Went (Went'First + Prefix'Length .. Went'Last) else Went);
      end;
   end Renamed_In_History;

   --------------------
   -- Last_Commit_At --
   --------------------

   function Last_Commit_At (Project_Directory, Path : String) return String is
      use type Ada.Calendar.Time;
      Arguments : Name_Lists.Vector;
      Output    : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Temp_Directory,
                         "model_runner-git-when-" & Fingerprint (Project_Directory) & ".txt");
      Happened  : Execution.Outcome;
      Text      : Unbounded_String;
      Read      : E.Error_Info;
   begin
      Arguments.Append ("log");
      Arguments.Append ("-1");
      Arguments.Append ("--format=%ct");
      Arguments.Append ("--");
      Arguments.Append (Path);
      Execution.Run_Harness (Project_Directory, "git", Arguments, Project_Directory, Output, 60, Happened);
      if Ada.Directories.Exists (Output) then
         Files.Read_Text (Output, Text, Read);
         Files.Discard (Output);
      end if;
      declare
         Seconds : constant String := Ada.Strings.Fixed.Trim (To_String (Text), Ada.Strings.Both);
         Digits_Only : constant Boolean :=
           Seconds /= ""
           and then (for all C of Seconds => C in '0' .. '9' | ASCII.LF | ASCII.CR);
      begin
         if not (Happened.Started and then Happened.Exit_Status = 0 and then Digits_Only) then
            return "";
         end if;
         declare
            Image : String :=
              Ada.Calendar.Formatting.Image
                (Ada.Calendar.Formatting.Time_Of (1970, 1, 1, 0.0)
                 + Duration (Long_Long_Integer'Value (Lines_Of (Seconds).First_Element)));
         begin
            Image (Image'First + 10) := 'T';
            return Image & "Z";
         end;
      end;
   end Last_Commit_At;

   ----------------------
   -- Uncommitted_Diff --
   ----------------------

   function Uncommitted_Diff
     (Project_Directory : String; Paths : Name_Lists.Vector; Found : out Boolean) return String
   is
      Arguments : Name_Lists.Vector;
      Output    : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Temp_Directory,
                         "model_runner-git-diff-" & Fingerprint (Project_Directory) & ".txt");
      Happened  : Execution.Outcome;
      Text      : Unbounded_String;
      Read      : E.Error_Info;
   begin
      Arguments.Append ("diff");
      Arguments.Append ("--no-color");
      Arguments.Append ("--relative");
      Arguments.Append ("HEAD");
      Arguments.Append ("--");
      Arguments.Append_Vector (Paths);
      Execution.Run_Harness (Project_Directory, "git", Arguments, Project_Directory, Output, 60, Happened);
      if Ada.Directories.Exists (Output) then
         Files.Read_Text (Output, Text, Read);
         Files.Discard (Output);
      end if;
      Found := Happened.Started and then not Happened.Timed_Out and then Happened.Exit_Status = 0;
      return (if Found then To_String (Text) else "");
   end Uncommitted_Diff;

end Model_Runner.Framework.Git;
