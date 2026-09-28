with Ada.Directories;

with Hostkit;
with Hostkit.Fs;
with Hostkit.Process;

with Model_Runner.Framework.Configurations;
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
      Arguments : Hostkit.String_Vectors.Vector;
      --  Outside the project, or Git would see the file it writes to.
      Output    : constant String :=
        Hostkit.Fs.Join (Hostkit.Fs.Temp_Directory,
                         "model_runner-git-status-" & Fingerprint (Project_Directory) & ".txt");
      Happened  : Hostkit.Process.Process_Outcome;
      Text      : Unbounded_String;
      Read      : E.Error_Info;
   begin
      Arguments.Append (To_Unbounded_String ("status"));
      Arguments.Append (To_Unbounded_String ("--porcelain=v1"));
      Arguments.Append (To_Unbounded_String ("--branch"));
      Happened :=
        Hostkit.Process.Run_Captured
          (Program           => "git",
           Arguments         => Arguments,
           Working_Directory => Project_Directory,
           Stdin_Path        => Hostkit.Fs.Null_Device,
           Stdout_Path       => Output,
           Stderr_Path       => Hostkit.Fs.Null_Device,
           Timeout_Ms        => 60_000);
      if Ada.Directories.Exists (Output) then
         Files.Read_Text (Output, Text, Read);
         Files.Discard (Output);
      end if;
      Result.Found := Happened.Started and then not Happened.Timed_Out
        and then Happened.Exit_Status = 0;
      if not Result.Found then
         return Result;
      end if;
      for Line of Lines_Of (To_String (Text)) loop
         if Line'Length > 3 and then Line (Line'First .. Line'First + 2) = "## " then
            Result.Branch := To_Unbounded_String (Line (Line'First + 3 .. Line'Last));
         elsif Line'Length > 3 then
            Result.Changes.Append (Line);
         end if;
      end loop;
      return Result;
   end Status_Of;

end Model_Runner.Framework.Git;
