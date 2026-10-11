with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  The project's state and Git, without a model.
--
--  Which of the state goes into the repository is the project's policy,
--  scalar repository.state_policy: portable, the default, commits what
--  travels with the project -- its configuration, intent, tasks, results,
--  events and evidence -- and keeps out what belongs to one machine and
--  what can be built again; local keeps all of it out; all commits all of
--  it. The policy is kept as the state root's own .gitignore, written by
--  the harness and never by hand.
--
--  Git's own view of the project is read from the repository, never
--  guessed: the branch, and each path as Git sees it -- by versionlib, in
--  the process, so no git program is needed.
package Model_Runner.Framework.Git is

   --  Make the state root's .gitignore say what the policy says.
   --
   --  @param Item The store.
   --  @param Written Whether it had to change.
   --  @param Status A failure to write it; Framework_Schema_Violation for a
   --    policy that is none of the three.
   procedure Keep_Policy
     (Item    : Stores.Store;
      Written : out Boolean;
      Status  : out Model_Runner.Errors.Error_Info);

   --  What Git says of the project.
   type Status_Report is record
      --  Whether the project is in a Git repository Git could read.
      Found   : Boolean := False;

      --  The branch line, as Git writes it: the branch and how it stands
      --  to its upstream.
      Branch  : Ada.Strings.Unbounded.Unbounded_String;

      --  One line a changed path: Git's two-letter state and the path.
      Changes : Name_Lists.Vector;
   end record;

   --  Ask Git how the project stands.
   --
   --  @param Project_Directory The project.
   --  @return What it said; Found is False where there is no repository, or
   --    none versionlib can read.
   function Status_Of (Project_Directory : String) return Status_Report;

   --  The root of the repository a directory is in, as Git finds it.
   --
   --  @param Directory The directory asked about.
   --  @return The repository's top directory; "" where there is none.
   function Top_Level (Directory : String) return String;

   --  Where the repository's history says a file went: the path a commit
   --  renamed it to, followed through later renames, as the project names
   --  paths; "" where no commit renamed it, or there is no repository.
   --
   --  @param Project_Directory The project.
   --  @param Path The file's path, as the project names it.
   --  @return Its path now.
   function Renamed_In_History (Project_Directory, Path : String) return String;

   --  When the last commit to a file was made, as Timestamp says a time.
   --
   --  @param Project_Directory The project.
   --  @param Path The file, as the project names it.
   --  @return The commit's time; "" where no commit holds it, or there is no
   --    repository.
   function Last_Commit_At (Project_Directory, Path : String) return String;

   --  What some files hold beyond the last commit, as git diff shows it.
   --
   --  @param Project_Directory The project.
   --  @param Paths The files, as the project names them.
   --  @param Found False where there is no repository, or no commit.
   --  @return The diff; "" where they are as committed.
   function Uncommitted_Diff
     (Project_Directory : String; Paths : Name_Lists.Vector; Found : out Boolean) return String;

   --  Make a directory a worktree of the project's repository, detached at
   --  its last commit, as git worktree add --detach makes one.
   --
   --  @param Project_Directory The project, at its repository's top.
   --  @param Tree Where the worktree goes: a full path, not there yet.
   --  @param Head The commit it was made at.
   --  @param Worked False where there is no repository, no commit, or it
   --    could not be made.
   procedure Add_Worktree
     (Project_Directory, Tree : String;
      Head                    : out Ada.Strings.Unbounded.Unbounded_String;
      Worked                  : out Boolean);

   --  Take a worktree away, its changes with it, and its registration.
   --
   --  @param Project_Directory The project.
   --  @param Tree The worktree, a full path.
   --  @param Worked False where it could not be taken away.
   procedure Remove_Worktree (Project_Directory, Tree : String; Worked : out Boolean);

   --  Forget the worktrees whose directory went some other way, as git
   --  worktree prune does.
   --
   --  @param Project_Directory The project.
   procedure Prune_Worktrees (Project_Directory : String);

   --  Merge in place three versions of a file -- Merged holds one side
   --  and is rewritten -- the conflicts marked, as git merge-file does.
   --
   --  @param Merged The first side, and where the merge is written.
   --  @param Base What both sides came from.
   --  @param Theirs The other side.
   --  @param Ours_Label The label of Merged's side at a conflict.
   --  @param Base_Label The label of the base.
   --  @param Theirs_Label The label of the other side.
   --  @param Worked False where a file could not be read or written.
   procedure Merge_File
     (Merged, Base, Theirs                  : String;
      Ours_Label, Base_Label, Theirs_Label  : String;
      Worked                                : out Boolean);

end Model_Runner.Framework.Git;
