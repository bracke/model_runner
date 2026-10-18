with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;

--  What was learned while working, kept, and never taken for what the
--  project means.
--
--  An observation is a finding -- a compiler option that fails, an API that
--  does not do what its name says, an approach tried and why it failed, a
--  constraint of the machine or a tool -- kept with where it came from: the
--  task and its execution generation, the agent and its invocation, the
--  results and evidence it rests on, and the files it is about at the
--  revisions they were at. It survives the conversation that found it, its
--  compaction and the process; a later attempt is told it.
--
--  Persistence does not imply authority. An observation satisfies no gate,
--  makes no task ready, overrides no decision, grants nothing, verifies no
--  requirement and changes no configuration. It becomes part of what the
--  project means only by being promoted -- into a fact, a candidate task or
--  a candidate decision, each made by the machinery that makes them and each
--  naming the observation as where it came from -- and the observation
--  stays, marked promoted, for the record.
--
--  The same finding found again is the same observation, seen once more:
--  its sightings are counted and their provenance added, never a second
--  record. A finding that says something else is another observation.
--
--  What it says was true when it was seen. Whether it still applies is
--  worked out, not assumed: a file it is about that changed since makes it
--  stale, one that will not read leaves it unknowable, a configuration
--  changed since makes it uncertain -- and it stays, labelled.
package Model_Runner.Framework.Observations is

   --  What an observation is of. A small fixed set: an unknown word is not
   --  given a meaning.
   type Observation_Kind is
     (Finding,
      Experiment,
      Failure_Pattern,
      Environment_Constraint,
      Tool_Behavior,
      Implementation_Note);

   --  Where an observation is in its life.
   type Lifecycle is (Active, Superseded, Dismissed, Promoted);

   --  Who said it.
   type Producer_Kind is (Agent_Producer, Harness_Producer, User_Producer);

   --  How it was known: from evidence the harness holds, or on a producer's
   --  word alone.
   type Grounding is (Observed, Reported);

   --  Whether it applies now.
   type Applicability is (Applicable, Stale, Superseded, Dismissed, Uncertain, Unreadable);

   --  What a producer says: the finding, and what it rests on. The rest of
   --  an observation -- whose it is and when -- the harness supplies.
   type Draft is record
      Kind     : Observation_Kind := Finding;
      Summary  : Ada.Strings.Unbounded.Unbounded_String;

      --  Results (RES-) and evidence (VER-) it rests on, each kept.
      Evidence : Name_Lists.Vector;

      --  The files it is about, relative to the project, and the symbols.
      Files    : Name_Lists.Vector;
      Symbols  : Name_Lists.Vector;
   end record;

   --  Where it came from, as the harness knows it; never a producer's word.
   type Origin is record
      Producer   : Producer_Kind := Harness_Producer;
      Task_Id    : Ada.Strings.Unbounded.Unbounded_String;
      Generation : Ada.Strings.Unbounded.Unbounded_String;
      Agent      : Ada.Strings.Unbounded.Unbounded_String;

      --  The agent's parent, where it is a helper.
      Parent     : Ada.Strings.Unbounded.Unbounded_String;
      Invocation : Ada.Strings.Unbounded.Unbounded_String;

      --  The tree its files were read in: a workspace's, where the work is
      --  apart; "" for the project's.
      Tree       : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  An observation, as kept.
   type Observation is record
      Id          : Ada.Strings.Unbounded.Unbounded_String;
      Revision    : Natural := 0;
      Kind        : Observation_Kind := Finding;
      Summary     : Ada.Strings.Unbounded.Unbounded_String;
      Status      : Lifecycle := Active;
      Ground      : Grounding := Reported;
      Producer    : Producer_Kind := Harness_Producer;

      --  Its first sighting's task, generation, agent and invocation, and
      --  every sighting's, a line each as TASK GENERATION AGENT INVOCATION.
      Task_Id     : Ada.Strings.Unbounded.Unbounded_String;
      Generation  : Ada.Strings.Unbounded.Unbounded_String;
      Agent       : Ada.Strings.Unbounded.Unbounded_String;
      Parent      : Ada.Strings.Unbounded.Unbounded_String;
      Invocation  : Ada.Strings.Unbounded.Unbounded_String;
      Sightings   : Name_Lists.Vector;

      --  The component of its task when it was first seen.
      Component   : Ada.Strings.Unbounded.Unbounded_String;

      Evidence    : Name_Lists.Vector;
      Files       : Name_Lists.Vector;

      --  Each file's fingerprint when it was last seen, in Files' order;
      --  "-" for one that was not there.
      File_Prints : Name_Lists.Vector;
      Symbols     : Name_Lists.Vector;

      --  The configuration's fingerprint when it was last seen.
      Configuration : Ada.Strings.Unbounded.Unbounded_String;

      Created_At  : Ada.Strings.Unbounded.Unbounded_String;
      Seen_At     : Ada.Strings.Unbounded.Unbounded_String;
      Occurrences : Positive := 1;

      --  What replaced it, what it was promoted to, and why it was
      --  dismissed or retired.
      Superseded_By : Ada.Strings.Unbounded.Unbounded_String;
      Promoted_To   : Ada.Strings.Unbounded.Unbounded_String;
      Reason        : Ada.Strings.Unbounded.Unbounded_String;

      --  An active observation it says nearly the same as, when it was
      --  first kept: the same kind, about the same files where both name
      --  any, and most of the same words. A claim worded otherwise is not
      --  merged into it -- what it says may differ -- but is not told
      --  beside it either.
      Similar_To    : Ada.Strings.Unbounded.Unbounded_String;

      --  Why its text is gone, where retention let it go: the setting, and
      --  when. A record that names it finds it retired, not missing.
      Retired       : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  The word a kind is written and asked for as.
   --
   --  @param Kind The kind.
   --  @return As failure_pattern.
   function Word (Kind : Observation_Kind) return String;

   --  The kind a word names.
   --
   --  @param Text The word.
   --  @param Kind The kind, when Found.
   --  @param Found Whether it names one.
   procedure Kind_Of (Text : String; Kind : out Observation_Kind; Found : out Boolean);

   --  The word a lifecycle state is written as.
   --
   --  @param Status The state.
   --  @return As superseded.
   function Word (Status : Lifecycle) return String;

   --  The word a standing is said as.
   --
   --  @param Standing The standing.
   --  @return As stale.
   function Word (Standing : Applicability) return String;

   --  Whether two observations say nearly the same: the same kind, about
   --  at least one file in common where both name files, and of the words
   --  of three letters or more in their summaries, at least three shared
   --  and at least three in five of all of them.
   --
   --  @param Left One observation.
   --  @param Right The other.
   --  @return True when they do.
   function Nearly_Same (Left, Right : Observation) return Boolean;

   --  The longest summary an observation keeps.
   Summary_Most : constant := 600;

   --  The claim an observation makes, as its sightings are matched by: its
   --  kind, its summary with case, spacing and closing stops set aside, and
   --  the files and symbols it is about, sorted.
   --
   --  @param Said The finding.
   --  @return The claim's fingerprint.
   function Claim_Of (Said : Draft) return String;

   --  Record a finding: a new observation, or a sighting of the one that
   --  makes the same claim. Its kind and summary are checked, its files
   --  held to the project, its evidence to what the store keeps -- evidence
   --  that is not there is refused, not taken on trust -- and its
   --  provenance taken from Origin alone.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Said What was found.
   --  @param From Where it came from.
   --  @param Id The observation.
   --  @param Fresh Whether it is new, rather than seen again.
   --  @param Status Framework_Input_Invalid naming what is wrong with it,
   --    Framework_Not_Found for evidence that is not kept.
   procedure Record_Observation
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Said   : Draft;
      From   : Origin;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Fresh  : out Boolean;
      Status : out Model_Runner.Errors.Error_Info);

   --  Read an observation.
   --
   --  @param Item The store.
   --  @param Id It.
   --  @param Value It, when Status is a success.
   --  @param Status Framework_Not_Found when there is none, and the read's
   --    own failure when it will not read.
   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Value  : out Observation;
      Status : out Model_Runner.Errors.Error_Info);

   --  Every observation, by number.
   --
   --  @param Item The store.
   --  @return Their identifiers.
   function List (Item : Stores.Store) return Name_Lists.Vector;

   --  Whether an observation applies now, and why not where it does not.
   --
   --  @param Item The store.
   --  @param Value The observation.
   --  @param Why What changed, or could not be read; "" where it applies.
   --  @return Its standing.
   function Applicability_Of
     (Item  : Stores.Store;
      Value : Observation;
      Why   : out Ada.Strings.Unbounded.Unbounded_String) return Applicability;

   --  Dismiss an observation: it is wrong, or of no use. Kept, for the
   --  record, and never told to an agent again.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id It.
   --  @param Reason Why.
   --  @param Status Framework_Not_Found, or Framework_Transition_Invalid for
   --    one dismissed, superseded or promoted already.
   procedure Dismiss
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Reason : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Supersede an observation by another that says better what it said.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id It.
   --  @param By The other, kept and active.
   --  @param Status As Dismiss, and Framework_Input_Invalid for itself.
   procedure Supersede
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      By     : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  What an observation is promoted into.
   type Promotion_Target is (To_Task, To_Fact, To_Decision);

   --  Promote an observation into a candidate task: made as any task is,
   --  created by observation_promotion and from the observation, accepted
   --  only where the project's policy accepts that class unasked.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The observation.
   --  @param Fields What the task is; its title the observation's summary
   --    where none is given.
   --  @param Task_Id The task made.
   --  @param Status The task's own failure, or as Dismiss.
   procedure Promote_To_Task
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Id      : String;
      Fields  : Tasks.Field_Map;
      Task_Id : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Promote an observation into a fact, as sure as its grounding allows
   --  and never authoritative: probable where evidence stands behind it,
   --  uncertain on a producer's word.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The observation.
   --  @param Key The fact's key.
   --  @param Value Its value.
   --  @param Status Framework_Name_Invalid for a key that is not one, or as
   --    Dismiss.
   procedure Promote_To_Fact
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Key    : String;
      Value  : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Promote an observation into a decision, a candidate a person or the
   --  policy then accepts or not.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The observation.
   --  @param Key What the decision is keyed under, as PARSER.
   --  @param Title Its title; the summary where empty.
   --  @param Text What it decides; the summary where empty.
   --  @param Scope Its component, or project.
   --  @param Decision_Id The decision made.
   --  @param Status The register's own failure, or as Dismiss.
   procedure Promote_To_Decision
     (Item        : Stores.Store;
      Change      : in out Stores.Transaction;
      Id          : String;
      Key         : String;
      Title       : String;
      Text        : String;
      Scope       : String;
      Decision_Id : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info);

   --  How readily a piece of knowledge is told to work: always where it is
   --  relevant, when the work's scope matches, or not unless asked for.
   --  Beside an item's priority -- how much it matters -- not instead of it.
   type Temperature is (Hot, Warm, Cold);

   --  An observation as one piece of work would be told it.
   type Considered is record
      Id        : Ada.Strings.Unbounded.Unbounded_String;
      Revision  : Natural := 0;
      Heat      : Temperature := Cold;
      Standing  : Applicability := Applicable;

      --  Why it is that warm, as same task, same file src/x.adb.
      Reason    : Ada.Strings.Unbounded.Unbounded_String;

      --  What it is told as: marked as an observation and not
      --  authoritative, its standing said where it does not apply.
      Text      : Ada.Strings.Unbounded.Unbounded_String;

      --  When it was last seen: the most recent are offered first.
      Seen_At   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Considered_Vectors is new Ada.Containers.Vectors (Positive, Considered);

   --  What a task's work is told of what was learned: the observations
   --  relevant to it, deterministically -- the same task, the files its work
   --  changed or failed in, the requirements it serves, its component, the
   --  project's tool and environment caveats -- each hot or warm, those
   --  that no longer apply no hotter than warm, the dismissed, superseded
   --  and promoted cold and left out; the hottest first, then the most
   --  recently seen; no more than the project's scalar knowledge.max_hot and
   --  knowledge.max_warm of each (five unless set), and none at all where
   --  knowledge.observations is off.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @param Excluded Each observation left cold or past the bound, as ID,
   --    a colon and why: what the manifest records was not considered.
   --  @return The hot and the warm, in the order to offer them.
   function Relevant
     (Item     : Stores.Store;
      Task_Id  : String;
      Excluded : out Name_Lists.Vector) return Considered_Vectors.Vector;

   --  The harness's own finding from a verification that failed: where a
   --  task's checks fail again as they failed before in an earlier
   --  generation -- the same check, the same first error -- the failure is
   --  a pattern, recorded once and seen again each time after. A first
   --  failure is not one, and nothing is recorded for it.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Task_Id The task.
   --  @param Evidence The verification that failed.
   --  @param From Where it came from.
   --  @param Id The observation recorded or seen again; "" for none.
   --  @param Status A failure staging it.
   procedure Observe_Failure
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Task_Id  : String;
      Evidence : String;
      From     : Origin;
      Id       : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Record what a task's checks passing after they failed shows: what
   --  failed first -- its first error, or the check that failed where none
   --  was read -- and the files changed since, which made it pass. Only
   --  where the task's verification before this one failed; one passing
   --  after a pass, or with nothing changed, says nothing.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Task_Id The task.
   --  @param Evidence The verification that passed.
   --  @param Changed The files the work changed, as the harness saw them.
   --  @param From Where it came from.
   --  @param Id The observation recorded or seen again; "" for none.
   --  @param Status A failure staging it.
   --  @param Fixed_By What the change was, as Change_Said says it, where
   --    the harness held the files as they were when the checks failed.
   procedure Observe_Fix
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Task_Id  : String;
      Evidence : String;
      Changed  : Name_Lists.Vector;
      From     : Origin;
      Id       : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info;
      Fixed_By : String := "");

   --  The lines a change took out and put in, as a fix observation says
   --  them: PATH: - LINE | + LINE, in the order they stand, blank lines and
   --  leading space set aside, at most eight lines of a hundred characters;
   --  "" where nothing changed.
   --
   --  @param Path The file.
   --  @param Before What it held.
   --  @param After What it holds.
   --  @return The lines.
   function Change_Said (Path, Before, After : String) return String;

   --  Record a call the harness refused -- a permission, the sandbox, the
   --  execution policy, the project's edge -- as a constraint later work
   --  is told: the tool, why, and the file it was for where that is one of
   --  the project's.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Tool The tool called.
   --  @param Why What the refusal said.
   --  @param Path The path the call named, or "".
   --  @param From Where it came from.
   --  @param Id The observation recorded or seen again; "" for none.
   --  @param Status A failure staging it.
   procedure Observe_Refusal
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Tool   : String;
      Why    : String;
      Path   : String;
      From   : Origin;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Record where a completed task's work was done: the files it changed
   --  and the verification that passed -- what later work on those files
   --  or that component starts from rather than searches for.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Task_Id The task, complete.
   --  @param Evidence The verification that passed.
   --  @param Changed The files its work changed.
   --  @param From Where it came from.
   --  @param Id The observation recorded; "" for none.
   --  @param Status A failure staging it.
   procedure Observe_Done
     (Item     : Stores.Store;
      Change   : in out Stores.Transaction;
      Task_Id  : String;
      Evidence : String;
      Changed  : Name_Lists.Vector;
      From     : Origin;
      Id       : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info);

   --  Let observations go that are dismissed or superseded and older than
   --  the policy keeps: each left as a tombstone -- its identifier, what it
   --  was and why it went -- so a record naming it finds it retired. The
   --  active and the promoted stay whatever their age.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Days How old one may grow; zero keeps them.
   --  @param Retired How many were let go.
   procedure Prune
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Days    : Natural;
      Retired : out Natural);

end Model_Runner.Framework.Observations;
