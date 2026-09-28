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
--  Git's own view of the project is asked of Git directly and read, never
--  guessed: the branch, and each path as Git sees it.
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
   --  @return What it said; Found is False where there is no repository or
   --    no git.
   function Status_Of (Project_Directory : String) return Status_Report;

end Model_Runner.Framework.Git;
