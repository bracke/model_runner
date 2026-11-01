with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Sampling;
with Model_Runner.Templates;

--  How a model call made for a task is set: its sampling, whether and how
--  much it reasons, and how long its reply may be.
--
--  A project says nothing of it and every call is set as the session is --
--  its command line, then the model file's own settings, then the sampler's
--  defaults: scalar inference.mode is fixed. Set to profile, every call is
--  set by one named profile, scalar inference.default. Set to adaptive, a
--  task's kind picks its profile (scalar inference.task.KIND), a helper's
--  role picks its own (scalar inference.role.ROLE), and what the harness
--  saw happen picks one for the call it makes next (Activity): a call after
--  checks failed is recovery, one asked only for the report is reporting.
--  A kind, role or activity the configuration maps to no profile keeps the
--  one it has; a task no mapping reaches is set as in fixed mode.
--
--  A profile holds only what it changes: a temperature, the probability
--  filters, a reasoning level, whether to think, a reply's length. The
--  built-in ones are analysis, architecture, coding, testing, debugging,
--  exploration, reporting and verification; scalar
--  inference.profile.NAME.FIELD changes a field of one, or makes a profile
--  of its own where NAME is none of them. scalar inference.adapts says
--  which of a profile's fields are taken: both, the default; reasoning --
--  whether and how much to reason, the sampling left as the session has
--  it; or temperature -- the sampling, the reasoning left. It is what tells
--  apart which half of a profile a task's outcome owes. A task's own inference field --
--  profile=NAME and fields as a profile has them -- is the task's say, and
--  stands in any mode.
--
--  Each setting is taken on its own from the first that says it: what the
--  session was started with, then the task's own field, then the project's
--  profile fields, then the profile's built-in values, then the model's
--  and the sampler's defaults. A temperature given on the command line
--  stands under a profile that asks for high reasoning. Then what the model
--  can take holds over all: a reasoning level goes to a template that reads
--  one (reasoning_effort), and to one that only reads whether to think
--  (enable_thinking) as on for high, off for low or minimal, its default
--  for medium -- said, as the fallback it is. Asked of a model that takes
--  no such control, a level the task or project named is refused, not
--  dropped; one a profile chose is dropped, and said. A reply is never
--  given more room than the session keeps for it, and no setting reaches
--  past the task's budgets, its permissions or its checks.
--
--  Everything here is decided from the state and what the call is: the
--  same answer for the same inputs, and no model asked.
package Model_Runner.Framework.Inference_Policy is

   subtype Real is Model_Runner.Sampling.Real;
   subtype Reasoning_Effort is Model_Runner.Templates.Reasoning_Effort;
   subtype Thinking_Choice is Model_Runner.Templates.Thinking_Choice;
   subtype Reasoning_Controls is Model_Runner.Templates.Reasoning_Controls;

   --  How a project's calls are set.
   type Policy_Mode is (Fixed, Profile_Mode, Adaptive);

   --  The mode's word: fixed, profile or adaptive.
   --
   --  @param Mode The mode.
   --  @return Its word.
   function Mode_Word (Mode : Policy_Mode) return String;

   --  What a call is made for, as the harness saw it: the work itself; a
   --  call that is to read a verification's result; one after checks that
   --  failed, to mend what they found; one asked for the report alone.
   type Activity is (Task_Work, Verification_Analysis, Failure_Recovery, Result_Reporting);

   --  The activity's word, as scalar inference.activity.WORD names it.
   --
   --  @param Doing The activity.
   --  @return task_work, verification_analysis, failure_recovery or
   --    result_reporting.
   function Activity_Word (Doing : Activity) return String;

   --  The settings a policy sets.
   type Setting is (Temperature, Top_K, Top_P, Min_P, Thinking, Effort, Output_Limit);

   --  Where a setting's effective value came from, first said first: the
   --  model's own limits; the session's command line; the task's own
   --  inference field; the project's profile fields; the profile's
   --  built-in values; the model file's and the sampler's defaults.
   type Source is (Capability, Invocation, Task_Setting, Project, Profile_Default, Model_Default);

   --  The source's word, as a record keeps it.
   --
   --  @param From The source.
   --  @return capability, invocation, task, project, profile or default.
   function Source_Word (From : Source) return String;

   type Source_Map is array (Setting) of Source;

   --  What a profile, or a task's field, sets: each field only where it is
   --  said.
   type Overrides is record
      Has_Temperature : Boolean := False;
      Temperature     : Real := 0.0;
      Has_Top_K       : Boolean := False;
      Top_K           : Natural := 0;
      Has_Top_P       : Boolean := False;
      Top_P           : Real := 1.0;
      Has_Min_P       : Boolean := False;
      Min_P           : Real := 0.0;
      Thinking        : Thinking_Choice := Model_Runner.Templates.Thinking_Unstated;
      Effort          : Reasoning_Effort := Model_Runner.Templates.Effort_Unstated;
      --  The reply's most tokens; nought for unsaid.
      Output_Limit    : Natural := 0;
   end record;

   No_Overrides : constant Overrides := (others => <>);

   --  The built-in profiles, by name.
   --
   --  @return analysis, architecture, coding, testing, debugging,
   --    exploration, reporting, verification.
   function Built_In_Names return Name_Lists.Vector;

   --  A built-in profile's values.
   --
   --  @param Name The profile.
   --  @param Found Whether it is one.
   --  @return Its values; none where it is not one.
   function Built_In (Name : String; Found : out Boolean) return Overrides;

   --  Read a task's inference field, or one profile field: words of
   --  NAME=VALUE separated by spaces -- profile=NAME, temperature=R,
   --  top_k=N, top_p=R, min_p=R, reasoning=minimal|low|medium|high,
   --  thinking=on|off, max_tokens=N.
   --
   --  @param Text The words.
   --  @param Result What they set.
   --  @param Profile_Name The profile=NAME given; "" for none.
   --  @return What is wrong with them; "" where they read.
   function Parse
     (Text         : String;
      Result       : out Overrides;
      Profile_Name : out Ada.Strings.Unbounded.Unbounded_String) return String;

   --  What a set of overrides sets, as Parse reads it back.
   --
   --  @param Item The overrides.
   --  @return The words; "" where none is set.
   function Image (Item : Overrides) return String;

   --  The profile fields scalar inference.profile.NAME.FIELD may set:
   --  temperature, top_k, top_p, min_p, reasoning, thinking, max_tokens.
   --
   --  @param Field The field.
   --  @return True where it is one.
   function Is_Profile_Field (Field : String) return Boolean;

   --  What is wrong with one inference setting's value, as it is given:
   --  a mode that is none of fixed, profile and adaptive, an activity
   --  that is none of the four, a profile field out of its range, a
   --  profile's name that is no name.
   --
   --  @param Name The setting's whole name, scalar.inference. and the rest.
   --  @param Value Its value.
   --  @return The problem; "" where it reads, or where Name is no inference
   --    setting.
   function Setting_Problem (Name, Value : String) return String;

   --  What is wrong with a whole configuration's inference settings: a
   --  mapping to a profile neither built in nor made by its own fields, a
   --  profile mode with no default, a profile whose fields together do not
   --  make a sampler that takes them.
   --
   --  @param Config The configuration.
   --  @return The first problem; "" for none.
   function Configuration_Problem (Config : Records.Item) return String;

   --  Whether a profile is one a configuration can name: built in, or made
   --  by fields of its own.
   --
   --  @param Config The configuration.
   --  @param Name The profile.
   --  @return True where it is.
   function Is_Profile (Config : Records.Item; Name : String) return Boolean;

   --  What a task's run is to be set by, as the plan for it holds it: the
   --  mode, the profile its kind or its own field picks, its own field's
   --  settings, and the configuration's revision it was read at. Which
   --  model it runs on, and what the call is for, are not known yet: the
   --  settings themselves are resolved for each call (Resolve).
   type Selection is record
      Mode           : Policy_Mode := Fixed;
      Profile        : Ada.Strings.Unbounded.Unbounded_String;
      --  Whether the task named its profile itself: activities and roles
      --  then do not change it.
      Task_Named     : Boolean := False;
      Task_Settings  : Overrides;
      Revision       : Natural := 0;
   end record;

   --  The selection for a task's run.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @return Its selection; fixed where the configuration cannot be read.
   function Select_For (Item : Stores.Store; Task_Id : String) return Selection;

   --  The selection for a helper of an agent: its role's profile where the
   --  project is adaptive and maps it; else, in any mode, for a helper that
   --  writes documents alone, the profile such helpers are set by
   --  (inference.helpers: documents unless named, none for its parent's);
   --  else its parent's; the task's own field, as its parent's. A helper
   --  that writes code keeps its parent's: one that edited code without
   --  thinking measured no faster and made twice the calls, where one
   --  writing prose was a third faster.
   --
   --  @param Item The store.
   --  @param Parent The parent's selection.
   --  @param Role The helper's role, as its parent named it.
   --  @param Documents_Only Whether every output it must write is a document
   --    (Is_Document), and it names one at least.
   --  @return Its selection.
   function For_Child
     (Item : Stores.Store; Parent : Selection; Role : String; Documents_Only : Boolean := False) return Selection;

   --  Whether a path is a document's, by its extension: .md, .txt, .rst or
   --  .adoc, as any case writes them. Anything else may be code, and is
   --  taken for it.
   --
   --  @param Path The path.
   --  @return Whether it names a document.
   function Is_Document (Path : String) return Boolean;

   --  What a helper's own work is for, by the role its parent named: one
   --  whose role says it verifies, reviews, tests or checks, anywhere in it,
   --  analyses what is verified; one that writes or authors -- tests too --
   --  and any other works on the task.
   --
   --  @param Role The helper's role, small letters.
   --  @return Verification_Analysis or Task_Work.
   function Activity_Of_Role (Role : String) return Activity;

   --  What a selection asks of one call, before the model and the session
   --  are weighed: each setting with where it came from. What the session
   --  itself was told and what the model can take are applied by Fit.
   type Request is record
      Chosen   : Selection;
      Doing    : Activity := Task_Work;
      --  The profile the call is set by, after its activity: "" for none.
      Profile  : Ada.Strings.Unbounded.Unbounded_String;
      Settings : Overrides;
      Sources  : Source_Map := [others => Model_Default];
   end record;

   --  The request a call makes.
   --
   --  @param Item The store.
   --  @param Chosen The run's selection.
   --  @param Doing What the call is for.
   --  @param Result The request.
   --  @param Status Failed where the configuration the run was selected
   --    at, or the current one for a run selected before there was one,
   --    cannot be read: never another in its place. None at all is none.
   procedure Merge
     (Item   : Stores.Store;
      Chosen : Selection;
      Doing  : Activity;
      Result : out Request;
      Status : out Model_Runner.Errors.Error_Info);

   --  The configuration a run's calls are set by: at the revision it was
   --  selected at, or the current one where it was selected before there
   --  was one -- an empty one where there is none.
   --
   --  @param Item The store.
   --  @param Revision The run's revision, or 0.
   --  @param Config The configuration.
   --  @param Status Failed where the one asked for cannot be read.
   procedure Configuration_At
     (Item     : Stores.Store;
      Revision : Natural;
      Config   : out Records.Item;
      Status   : out Model_Runner.Errors.Error_Info);

   --  The same, from a configuration in hand: what Merge reads, apart.
   --
   --  @param Config The configuration.
   --  @param Chosen The run's selection.
   --  @param Doing What the call is for.
   --  @return The request.
   function Merge_With (Config : Records.Item; Chosen : Selection; Doing : Activity) return Request;

   --  What the session a call is made in was told: its sampling as its
   --  command line and the model file make it, which of those the command
   --  line named, whether and how much to reason where it named either,
   --  and the reply's room -- what it keeps for one, a bound no policy goes
   --  past -- and whether --max-tokens named that.
   type Invocation_Settings is record
      Base         : Model_Runner.Sampling.Configuration;
      Given        : Model_Runner.Sampling.Key_Set := Model_Runner.Sampling.No_Keys;
      Thinking     : Thinking_Choice := Model_Runner.Templates.Thinking_Unstated;
      Effort       : Reasoning_Effort := Model_Runner.Templates.Effort_Unstated;
      Output_Room  : Positive := 1024;
      Output_Given : Boolean := False;
   end record;

   --  What one call is set to, and why.
   type Effective is record
      Asked        : Request;
      Sampling     : Model_Runner.Sampling.Configuration;
      Thinking     : Thinking_Choice := Model_Runner.Templates.Thinking_Unstated;
      Effort       : Reasoning_Effort := Model_Runner.Templates.Effort_Unstated;
      Output_Limit : Positive := 1024;
      Sources      : Source_Map := [others => Model_Default];
      --  What the model's controls changed of what was asked, in words; ""
      --  where it took everything as asked.
      Fallback     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Settle a request against the session and the model: what the
   --  session was told stands over the request, the reasoning asked is
   --  given the control the model's template reads, the reply is held to
   --  its room, and the sampling is checked as the sampler checks it.
   --
   --  @param Asked The request.
   --  @param Invoked What the session was told.
   --  @param Model The controls its template reads.
   --  @param Result The call's settings.
   --  @param Status Framework_Input_Invalid naming a reasoning level or a
   --    thinking choice the task or the project named that the model takes
   --    no control for, or a sampling the sampler refuses.
   procedure Fit
     (Asked   : Request;
      Invoked : Invocation_Settings;
      Model   : Reasoning_Controls;
      Result  : out Effective;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Merge, then Fit.
   --
   --  @param Item The store.
   --  @param Chosen The run's selection.
   --  @param Doing What the call is for.
   --  @param Invoked What the session was told.
   --  @param Model The controls its template reads.
   --  @param Result The call's settings.
   --  @param Status As Fit says.
   procedure Resolve
     (Item    : Stores.Store;
      Chosen  : Selection;
      Doing   : Activity;
      Invoked : Invocation_Settings;
      Model   : Reasoning_Controls;
      Result  : out Effective;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Resolve every call a run could make before it starts: each activity,
   --  for the run's own selection and for each role the project maps a
   --  profile to -- a setting its model takes no control for is refused
   --  then, not at the first recovery or the first helper of that role.
   --
   --  @param Item The store.
   --  @param Chosen The run's selection.
   --  @param Model The controls its template reads.
   --  @param Status As Fit says of the first that fails.
   procedure Check_Every_Call
     (Item   : Stores.Store;
      Chosen : Selection;
      Model  : Reasoning_Controls;
      Status : out Model_Runner.Errors.Error_Info);

   --  What a selection is, as the record of a run keeps it before any call
   --  is set: mode, profile, the task's own field and the revision, as
   --  NAME=VALUE lines.
   --
   --  @param Chosen The selection.
   --  @return The lines, inference_ before each name.
   function Selection_Lines (Chosen : Selection) return String;

   --  What a call was set to, on one line, as its invocation keeps it:
   --  activity, profile, each setting with its source, and the fallback.
   --  A filter a greedy draw never reads is said to be unused.
   --
   --  @param Policy The call's settings.
   --  @return The line.
   function Line_Of (Policy : Effective) return String;

   --  Where a runner that runs its agent as a process of its own finds the
   --  request its first call is to be set by, beside its prompt: Image_Of
   --  written there, for the process to Fit to its own model and session.
   --
   --  @param Prompt_Path The agent's prompt.
   --  @return The file's path.
   function Policy_Beside (Prompt_Path : String) return String;

   --  A request as Policy_Beside's file holds it.
   --
   --  @param Asked The request.
   --  @return NAME=VALUE lines, each setting with its source.
   function Image_Of (Asked : Request) return String;

   --  A request read back from Image_Of's lines.
   --
   --  @param Text The lines.
   --  @param Asked The request.
   --  @return What is wrong with them; "" where they read.
   function Read_Request (Text : String; Asked : out Request) return String;

end Model_Runner.Framework.Inference_Policy;
