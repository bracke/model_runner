with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  What an agent may do, as capabilities with scope.
--
--  A permission is a capability -- write_source, run_tests, create_children
--  and the rest -- and what limits it: the roots it applies under and the
--  paths denied inside them, the profiles it may run, how deep and how many
--  children it may make. What an agent may do is the intersection of every
--  level that says: the project's maximum, its task kind's maximum, its
--  role's restriction and whatever the run itself restricts. Each level can
--  only take away; nothing below the project can give what the project does
--  not. A capability nothing grants is not granted.
--
--  The configuration writes a level as map permission.LEVEL.CAPABILITY =
--  CONSTRAINTS, where LEVEL is project, kind.KIND or role.ROLE and the
--  constraints are roots=A|B, deny=C|D, profiles=P|Q, max_depth=N and
--  max_children=N, separated by commas; an empty value grants the
--  capability without limit. A project that says nothing gets the least
--  that work needs: reading and writing source and specifications,
--  running builds and tests, proposing tasks, and making at most two
--  children one level down.
--
--  A task may narrow what its agent gets further with a permissions field:
--  CAPABILITY or CAPABILITY: CONSTRAINTS, separated by semicolons, as
--  write_source: roots=src/parser/; run_tests: profiles=quick. What it does
--  not name, its agent may not do.
package Model_Runner.Framework.Permissions is

   --  What may be done.
   type Capability is
     (Read_Source,
      Write_Source,
      Read_Specs,
      Write_Specs,
      Run_Build,
      Run_Tests,
      Run_Static_Analysis,
      Create_Children,
      Propose_Tasks,
      Request_Integration,
      Use_Network,
      Execute_External_Process);

   --  One capability's grant.
   type Grant is record
      Granted      : Boolean := False;

      --  Where it applies; empty for everywhere.
      Roots        : Name_Lists.Vector;

      --  Where it does not, inside its roots.
      Deny         : Name_Lists.Vector;

      --  The profiles it covers; empty for all.
      Profiles     : Name_Lists.Vector;

      Max_Depth    : Natural := Natural'Last;
      Max_Children : Natural := Natural'Last;
   end record;

   --  Every capability's grant.
   type Permission_Set is array (Capability) of Grant;

   --  Everything, without limit: the identity of intersection.
   Unrestricted : constant Permission_Set;

   --  Nothing at all.
   Nothing : constant Permission_Set;

   --  The word a capability is written as.
   --
   --  @param Item The capability.
   --  @return Its word, as write_source.
   function Word (Item : Capability) return String;

   --  A grant's constraints as a setting's value writes them.
   --
   --  @param Given The grant.
   --  @return Its constraints, a space apart; empty for none.
   function Grant_Text (Given : Grant) return String;

   --  A level as the configuration writes it.
   --
   --  @param Item The store.
   --  @param Level project, kind.KIND or role.ROLE.
   --  @param Present Whether the configuration says anything at that
   --    level.
   --  @return The grants it makes.
   function Level_Of
     (Item    : Stores.Store;
      Level   : String;
      Present : out Boolean) return Permission_Set;

   --  The environment variable a sandbox is set by.
   Sandbox_Variable : constant String := "MODEL_RUNNER_SANDBOX";

   --  What the run itself is confined to: the sandbox level, below every
   --  other. MODEL_RUNNER_SANDBOX, written as a task's permissions field
   --  writes a restriction, confines every agent the process starts --
   --  from the shell that starts it, or from /sandbox in a session. Unset
   --  or empty, it confines nothing; one that does not read confines to
   --  nothing.
   --
   --  @return The sandbox level.
   function Sandbox return Permission_Set;

   --  Confine the session, or free it: what Sandbox reads afterwards,
   --  within whatever MODEL_RUNNER_SANDBOX confines the process to -- a
   --  session narrows the shell's sandbox, and never lifts it.
   --
   --  @param Text The restriction; empty to lift the session's own.
   --  @param Status Framework_Schema_Violation when it does not read, and
   --    then nothing changes.
   procedure Set_Sandbox
     (Text   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Where the confinement in force comes from, to be said with what it
   --  refused: MODEL_RUNNER_SANDBOX, the session's /sandbox, both, or none.
   --
   --  @return As said; empty where nothing confines the run.
   function Sandbox_Source return String;

   --  What is wrong with the sandbox the environment sets, if anything:
   --  one that does not read confines an agent to nothing.
   --
   --  @return Why it does not read, or the empty string.
   function Sandbox_Problem return String;

   --  Whether the session's sandbox, rather than the project, keeps a
   --  path from being written or read.
   --
   --  @param Path The path within the project.
   --  @param Writing Whether it is written.
   --  @return True when a sandbox is set and does not allow it.
   function Sandbox_Refuses (Path : String; Writing : Boolean) return Boolean;

   --  What two levels both allow.
   --
   --  @param Left One level.
   --  @param Right The other.
   --  @return Their intersection.
   function Intersect (Left, Right : Permission_Set) return Permission_Set;

   --  What an agent working on a task of a kind, in a role, may do.
   --
   --  @param Item The store.
   --  @param Kind The task's kind; empty for none.
   --  @param Role The agent's role; empty for none.
   --  @param Runtime What the caller restricts to, beside the Sandbox,
   --    which always applies.
   --  @param Task_Level The task's own restriction, as its permissions field
   --    writes it; empty for none. One that does not read restricts to
   --    nothing.
   --  @param Within_Sandbox Whether the session's sandbox narrows it too:
   --    False for what the configuration itself allows.
   --  @return The effective permissions.
   function Effective
     (Item    : Stores.Store;
      Kind    : String;
      Role    : String;
      Runtime : Permission_Set := Unrestricted;
      Task_Level : String := "";
      Within_Sandbox : Boolean := True) return Permission_Set;

   --  A task's own restriction, as its permissions field writes it.
   --
   --  @param Text The field.
   --  @param Result What it allows.
   --  @param Status Framework_Schema_Violation naming a word that is no
   --    capability.
   procedure Restriction
     (Text   : String;
      Result : out Permission_Set;
      Status : out Model_Runner.Errors.Error_Info);

   --  Whether a capability is granted for a verification profile.
   --
   --  @param Set The permissions.
   --  @param Item The capability.
   --  @param Profile The profile.
   --  @return True when it is granted and its profiles, if any, name it.
   function Allows_Profile
     (Set     : Permission_Set;
      Item    : Capability;
      Profile : String) return Boolean;

   --  Whether a capability is granted at a path.
   --
   --  @param Set The permissions.
   --  @param Item The capability.
   --  @param Path A path within the project; empty to ask of the
   --    capability alone.
   --  @return True when it is.
   function Allows
     (Set  : Permission_Set;
      Item : Capability;
      Path : String := "") return Boolean;

   --  An agent the harness starts as a process of its own is told where it
   --  works and what it may do by these, and its file tools hold it to
   --  them as the session's hold its agents: the tree, and the agent's
   --  permissions as Image writes them.
   Agent_Root_Variable        : constant String := "MODEL_RUNNER_AGENT_ROOT";
   Agent_Permissions_Variable : constant String := "MODEL_RUNNER_AGENT_PERMISSIONS";

   --  What the harness passes such an agent: the file, beside its prompt,
   --  that holds its permissions.
   --
   --  @param Prompt_Path The agent's prompt.
   --  @return The file's path.
   function Permissions_Beside (Prompt_Path : String) return String;

   --  Why an agent's file tool may not touch a path, or nothing when it
   --  may. The path is relative to the tree the agent works in and stays
   --  there, every link on the way followed; the project's state is the
   --  harness's and neither read nor written, whatever a grant says, since
   --  it changes only through the harness's own transactions; version
   --  control is not written; and what is left must be within the source or
   --  specification grants of the set.
   --
   --  @param Root The tree the agent works in: the project, or its
   --    workspace.
   --  @param Path The path the tool was given.
   --  @param Writing Whether the tool writes.
   --  @param Allowed The agent's permissions.
   --  @return The refusal, as the agent is told it, or "".
   function Path_Refusal
     (Root    : String;
      Path    : String;
      Writing : Boolean;
      Allowed : Permission_Set := Unrestricted) return String;

   --  Whether one set gives anything the other does not: a capability, a
   --  root outside the other's, a profile, a larger limit.
   --
   --  @param Wider The set that may be wider.
   --  @param Than The set it should stay within.
   --  @return The first capability that widens, as its word, or the empty
   --    string when none does.
   function Widening (Wider, Than : Permission_Set) return String;

   --  Every capability one set gives beyond the other, as Widening finds
   --  the first.
   --
   --  @param Wider The set that may be wider.
   --  @param Than The set it should stay within.
   --  @return Their words, in the order of Capability; empty for none.
   function Widenings (Wider, Than : Permission_Set) return Name_Lists.Vector;

   --  What a set that asks for more than another gets of each capability it
   --  asks too much of: each word, with what both allow of it.
   --
   --  @param Asked What is asked.
   --  @param Allowed What the level above allows.
   --  @return As "create_children (gets max_depth=1 max_children=2),
   --    use_network (gets none)"; empty where nothing is asked too much.
   function Clipped (Asked, Allowed : Permission_Set) return String;

   --  A set, written as one line a granted capability.
   --
   --  @param Set The permissions.
   --  @return The text.
   function Image (Set : Permission_Set) return String;

   --  A set as Image writes it.
   --
   --  @param Text The text.
   --  @return The permissions; what the text does not name is not granted.
   function Value (Text : String) return Permission_Set;

private

   Unrestricted : constant Permission_Set := [others => (Granted => True, others => <>)];
   Nothing      : constant Permission_Set := [others => (others => <>)];

end Model_Runner.Framework.Permissions;
