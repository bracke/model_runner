with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Version.Diff;
with Version.Files;
with Version.History;
with Version.Hooks;
with Version.Log;
with Version.Merge;
with Version.Objects;
with Version.Pack;
with Version.Pathspec;
with Version.Refs;
with Version.Repository;
with Version.Status;
with Version.Worktrees;

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
      --  The policy file is written from the configuration or not at all.
      Configurations.Read (Item, Config, Read);
      if Configurations.Unreadable (Read) then
         Status := Read;
         return;
      end if;
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

   --  versionlib, one call at a time -- its caches are the process's --
   --  each as if the process stood in the directory asked about, which it
   --  never moves: other tasks keep theirs.
   protected Gate is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Gate;

   protected body Gate is
      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Gate;

   --  Action run from Directory; Worked is False where it raised -- no
   --  repository there, or one versionlib could not read.
   procedure Within
     (Directory : String;
      Action    : not null access procedure;
      Worked    : out Boolean) is
   begin
      Gate.Seize;
      begin
         Standard.Version.Files.In_Directory (Directory, Action);
         Worked := True;
      exception
         when others =>
            Worked := False;
      end;
      --  The pack files read, let go: the session runs on for hours.
      Standard.Version.Pack.Release_Cached_Files;
      Gate.Release;
   end Within;

   --  Each pathspec of Paths, read from where the project stands in the
   --  repository.
   function Specs_Of (Paths : Name_Lists.Vector; Prefix : String)
     return Standard.Version.Pathspec.Pathspec_Vectors.Vector
   is
      Result : Standard.Version.Pathspec.Pathspec_Vectors.Vector;
   begin
      for Path of Paths loop
         Standard.Version.Pathspec.Append_Parse (Result, Path, Prefix);
      end loop;
      return Result;
   end Specs_Of;

   --  A path the repository names, as the project names it.
   function Within_Project (Path, Prefix : String) return String
   is (if Prefix /= "" and then Path'Length > Prefix'Length
         and then Path (Path'First .. Path'First + Prefix'Length - 1) = Prefix
       then Path (Path'First + Prefix'Length .. Path'Last) else Path);

   ---------------
   -- Status_Of --
   ---------------

   function Status_Of (Project_Directory : String) return Status_Report is
      Result : Status_Report;

      procedure Ask is
         Repo   : constant Standard.Version.Repository.Repository_Handle := Standard.Version.Repository.Open;
         Prefix : constant String := Standard.Version.Repository.Prefix (Repo);
         Only   : Name_Lists.Vector;
      begin
         --  What is in the project only, where it is part of a larger
         --  repository: the rest is no task's work. Each new file, not the
         --  new directory it is in: a task's file there is known as its.
         Only.Append (".");
         declare
            Seen : constant Standard.Version.Status.Status_Result :=
              Standard.Version.Status.Current_Status (Specs_Of (Only, Prefix), All_Untracked => True);
         begin
            for Line of Lines_Of (Standard.Version.Status.Branch_Status_Text (Seen)) loop
               if Line'Length > 3 and then Line (Line'First .. Line'First + 2) = "## " then
                  Result.Branch := To_Unbounded_String (Line (Line'First + 3 .. Line'Last));
                  exit;
               end if;
            end loop;
            --  Git names a path from the repository's top: within a project
            --  further down, from the project's, as everything else does.
            for Line of Lines_Of (Standard.Version.Status.Porcelain_Status_Text (Seen)) loop
               if Line'Length > 3 then
                  Result.Changes.Append
                    (Line (Line'First .. Line'First + 2)
                     & Within_Project (Line (Line'First + 3 .. Line'Last), Prefix));
               end if;
            end loop;
         end;
      end Ask;
   begin
      Within (Project_Directory, Ask'Access, Result.Found);
      if not Result.Found then
         Result := (others => <>);
      end if;
      return Result;
   end Status_Of;

   ---------------
   -- Top_Level --
   ---------------

   function Top_Level (Directory : String) return String is
      Top    : Unbounded_String;
      Worked : Boolean;

      procedure Ask is
      begin
         Top := To_Unbounded_String (Standard.Version.Repository.Root_Path (Standard.Version.Repository.Open));
      end Ask;
   begin
      Within (Directory, Ask'Access, Worked);
      return (if Worked then To_String (Top) else "");
   end Top_Level;

   --  The renames of the last commits as of one commit of one repository:
   --  the same for every path asked about until HEAD moves, and a check
   --  of the project asks of each file it misses.
   Renames_Key   : Unbounded_String;
   Renames_Lines : Name_Lists.Vector;

   --  Each file's last commit as of one commit of one repository.
   Commits_Key   : Unbounded_String;
   Commits_Seen  : Name_Lists.Vector;

   ------------------------
   -- Renamed_In_History --
   ------------------------

   function Renamed_In_History (Project_Directory, Path : String) return String is
      Went   : Unbounded_String;
      Worked : Boolean;

      procedure Ask is
         Repo   : constant Standard.Version.Repository.Repository_Handle := Standard.Version.Repository.Open;
         Prefix : constant String := Standard.Version.Repository.Prefix (Repo);
         Head   : constant String := Standard.Version.Refs.Current_Commit_Id (Repo);
         Now    : Unbounded_String := To_Unbounded_String (Prefix & Path);
         Lines  : Name_Lists.Vector;
      begin
         --  The renames of the last commits, newest first: old and new path.
         if Head /= "" and then To_String (Renames_Key) = Standard.Version.Repository.Root_Path (Repo) & "@" & Head
         then
            Lines := Renames_Lines;
         elsif Head /= "" then
            declare
               Start : Standard.Version.History.Commit_Id_Vectors.Vector;
            begin
               Start.Append (Standard.Version.Objects.To_Object_Id (Head));
               Lines := Lines_Of
                 (Standard.Version.Log.Log_List_Text
                    (Repo,
                     Standard.Version.History.Rev_List (Repo, Start, Options => (Max_Count => 200, others => <>)),
                     Name_Status  => True,
                     Rename_Score => 50));
               Renames_Key := To_Unbounded_String (Standard.Version.Repository.Root_Path (Repo) & "@" & Head);
               Renames_Lines := Lines;
            end;
         end if;
         declare
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
                       and then (for all C of Line (Line'First + 1 .. First_Tab - 1) => C in '0' .. '9')
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
         --  as the index has it.
         for Staged of Standard.Version.Status.Current_Status.Staged loop
            if Standard.Version.Status."=" (Staged.Kind, Standard.Version.Status.Renamed_File)
              and then Staged.Old_Path = Now
            then
               Now := Staged.Path;
            end if;
         end loop;
         if To_String (Now) /= Prefix & Path then
            Went := To_Unbounded_String (Within_Project (To_String (Now), Prefix));
         end if;
      end Ask;
   begin
      Within (Project_Directory, Ask'Access, Worked);
      return (if Worked then To_String (Went) else "");
   end Renamed_In_History;

   --------------------
   -- Last_Commit_At --
   --------------------

   function Last_Commit_At (Project_Directory, Path : String) return String is
      use type Ada.Calendar.Time;
      Seconds : Long_Long_Integer := -1;
      Worked  : Boolean;

      procedure Ask is
         Repo   : constant Standard.Version.Repository.Repository_Handle := Standard.Version.Repository.Open;
         Head   : constant String := Standard.Version.Refs.Current_Commit_Id (Repo);
         Start  : Standard.Version.History.Commit_Id_Vectors.Vector;
         Limits : Standard.Version.History.Rev_List_Options := (Max_Count => 1, others => <>);
      begin
         if Head = "" then
            return;
         end if;
         --  Asked already as of this commit: TAB-separated path and seconds.
         declare
            Key : constant String := Standard.Version.Repository.Root_Path (Repo) & "@" & Head;
            Own : constant String := Standard.Version.Repository.Prefix (Repo) & Path & ASCII.HT;
         begin
            if To_String (Commits_Key) /= Key then
               Commits_Key := To_Unbounded_String (Key);
               Commits_Seen.Clear;
            end if;
            for Seen of Commits_Seen loop
               if Seen'Length > Own'Length and then Seen (Seen'First .. Seen'First + Own'Length - 1) = Own then
                  Seconds := Long_Long_Integer'Value (Seen (Seen'First + Own'Length .. Seen'Last));
                  return;
               end if;
            end loop;
         end;
         Start.Append (Standard.Version.Objects.To_Object_Id (Head));
         Limits.Paths.Append (Standard.Version.Repository.Prefix (Repo) & Path);
         declare
            Last : constant Standard.Version.History.Commit_Id_Vectors.Vector :=
              Standard.Version.History.Rev_List (Repo, Start, Options => Limits);
         begin
            if not Last.Is_Empty then
               Seconds := Standard.Version.Objects.Commit_Committer_Time
                 (Standard.Version.Objects.Read_Object (Repo, Last.First_Element));
            end if;
            if Natural (Commits_Seen.Length) < 4096 then
               Commits_Seen.Append
                 (Standard.Version.Repository.Prefix (Repo) & Path & ASCII.HT
                  & Long_Long_Integer'Image (Seconds));
            end if;
         end;
      end Ask;
   begin
      Within (Project_Directory, Ask'Access, Worked);
      if not Worked or else Seconds < 0 then
         return "";
      end if;
      declare
         Image : String :=
           Ada.Calendar.Formatting.Image
             (Ada.Calendar.Formatting.Time_Of (1970, 1, 1, 0.0) + Duration (Seconds));
      begin
         Image (Image'First + 10) := 'T';
         return Image & "Z";
      end;
   end Last_Commit_At;

   ----------------------
   -- Uncommitted_Diff --
   ----------------------

   function Uncommitted_Diff
     (Project_Directory : String; Paths : Name_Lists.Vector; Found : out Boolean) return String
   is
      Text : Unbounded_String;

      procedure Ask is
         Repo   : constant Standard.Version.Repository.Repository_Handle := Standard.Version.Repository.Open;
         Prefix : constant String := Standard.Version.Repository.Prefix (Repo);
         Head   : constant String := Standard.Version.Refs.Current_Commit_Id (Repo);
      begin
         --  No commit, no HEAD to differ from: as git diff HEAD, nothing found.
         if Head = "" then
            raise Program_Error;
         end if;
         --  Each path named from the project, as the project names it.
         Text := To_Unbounded_String
           (Standard.Version.Diff.Diff_Tree_Vs_Working
              (Repo,
               Standard.Version.Objects.Commit_Tree_Id
                 (Standard.Version.Objects.Read_Object (Repo, Standard.Version.Objects.To_Object_Id (Head))),
               Specs_Of (Paths, Prefix),
               (Relative_Set => True, Relative => To_Unbounded_String (Prefix), others => <>)));
      end Ask;
   begin
      Within (Project_Directory, Ask'Access, Found);
      return (if Found then To_String (Text) else "");
   end Uncommitted_Diff;

   ------------------
   -- Add_Worktree --
   ------------------

   procedure Add_Worktree
     (Project_Directory, Tree : String;
      Head                    : out Ada.Strings.Unbounded.Unbounded_String;
      Worked                  : out Boolean)
   is
      Hook : Unbounded_String;

      procedure Make is
         Repo : constant Standard.Version.Repository.Repository_Handle := Standard.Version.Repository.Open;
         Id   : constant String := Standard.Version.Refs.Current_Commit_Id (Repo);
      begin
         --  No commit to check out: no worktree.
         if Id = "" then
            raise Program_Error;
         end if;
         Standard.Version.Worktrees.Add_Detached (Path => Tree, Rev => Id);
         Head := To_Unbounded_String (Id);
         Hook := To_Unbounded_String (Standard.Version.Hooks.Runnable_Hook (Repo, "post-checkout"));
      end Make;
   begin
      Head := Null_Unbounded_String;
      Within (Project_Directory, Make'Access, Worked);
      --  The project's post-checkout hook, as git worktree add runs it: in
      --  the new worktree, told it came from nothing to its commit, a
      --  branch checkout. A child of its own, in that directory: run in
      --  the process, it would move every task's. What it says is the
      --  harness log's; how it ends changes nothing, as with git.
      if Worked and then Length (Hook) > 0 then
         declare
            Arguments : Name_Lists.Vector;
            Happened  : Execution.Outcome;
         begin
            Arguments.Append (String'(1 .. 40 => '0'));
            Arguments.Append (To_String (Head));
            Arguments.Append ("1");
            --  Its output beside the worktree, not in it.
            Execution.Run_Harness
              (Project_Directory, To_String (Hook), Arguments, Tree,
               Tree & ".post-checkout", 600, Happened);
            Files.Discard (Tree & ".post-checkout");
         end;
      end if;
   end Add_Worktree;

   ---------------------
   -- Remove_Worktree --
   ---------------------

   procedure Remove_Worktree (Project_Directory, Tree : String; Worked : out Boolean) is
      procedure Take_Away is
      begin
         --  Its changes and all: what is to be kept was taken in already.
         Standard.Version.Worktrees.Remove (Path => Tree, Force => 1);
      end Take_Away;
   begin
      Within (Project_Directory, Take_Away'Access, Worked);
   end Remove_Worktree;

   ---------------------
   -- Prune_Worktrees --
   ---------------------

   procedure Prune_Worktrees (Project_Directory : String) is
      Worked : Boolean;

      procedure Prune is
      begin
         Standard.Version.Worktrees.Prune;
      end Prune;
   begin
      Within (Project_Directory, Prune'Access, Worked);
   end Prune_Worktrees;

   ----------------
   -- Merge_File --
   ----------------

   procedure Merge_File
     (Merged, Base, Theirs                  : String;
      Ours_Label, Base_Label, Theirs_Label  : String;
      Worked                                : out Boolean)
   is
      Ours_Text, Base_Text, Theirs_Text, Result : Unbounded_String;
      Conflicts : Natural;
      Read      : E.Error_Info;
   begin
      Worked := False;
      Files.Read_Text (Merged, Ours_Text, Read);
      if E.Is_Ok (Read) then
         Files.Read_Text (Base, Base_Text, Read);
      end if;
      if E.Is_Ok (Read) then
         Files.Read_Text (Theirs, Theirs_Text, Read);
      end if;
      if E.Is_Error (Read) then
         return;
      end if;
      --  As git merge-file writes it: a pure merge of texts, no repository.
      Standard.Version.Merge.Merge_File
        (To_String (Ours_Text), To_String (Base_Text), To_String (Theirs_Text),
         (Ours_Label   => To_Unbounded_String (Ours_Label),
          Base_Label   => To_Unbounded_String (Base_Label),
          Theirs_Label => To_Unbounded_String (Theirs_Label),
          others       => <>),
         Result, Conflicts);
      Files.Write_Text (Merged, To_String (Result), Read);
      Worked := E.Is_Ok (Read);
   exception
      when others =>
         Worked := False;
   end Merge_File;

end Model_Runner.Framework.Git;
