private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  What a model is told, worked out from the project state and nothing else.
--
--  A context is built for a task and a model profile. It gathers what
--  applies -- the harness's rules, the configuration, the Effective Task,
--  the requirements it serves at their revisions, the decisions for its
--  component, the accepted specifications, its runtime state, and source
--  from the repository -- as items, each with a priority and an estimated
--  cost. Items saying the same thing appear once. Then the budget: the
--  profile's context less what is kept for the answer. Mandatory items go
--  in whatever they cost, and a context they do not fit is refused rather
--  than trimmed; the rest go in by priority while they fit, and what did
--  not is written down with why.
--
--  What went in is the Context Manifest, kept with the project's history
--  under an identifier made from its content, with the text the model was
--  given kept as a result beside it. Built twice from the same state, a
--  context is the same manifest -- which is what lets a model's behaviour
--  be audited, and a call be made again, without any conversation.
package Model_Runner.Framework.Context is

   --  What a model can do, as far as budgeting and calling it goes.
   type Model_Profile is record
      Id             : Ada.Strings.Unbounded.Unbounded_String;
      Provider       : Ada.Strings.Unbounded.Unbounded_String;
      Context_Limit  : Positive := 8192;
      Output_Reserve : Natural := 1024;
      Tool_Overhead  : Natural := 0;
      Tools          : Boolean := False;
      Structured     : Boolean := True;
      Reasoning      : Boolean := False;
      Streaming      : Boolean := True;
      Parallel_Calls : Boolean := False;
      Resource_Class : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  How much an item matters, most first.
   type Priority is (Mandatory, High, Normal, Low);

   --  One thing a context may hold.
   type Item is record
      --  What it is, as TASK-X#definition, REQ-X@3, file:src/x.adb.
      Id       : Ada.Strings.Unbounded.Unbounded_String;
      Kind     : Ada.Strings.Unbounded.Unbounded_String;
      Rank     : Priority := Normal;
      Text     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  A context, built.
   type Built is private;

   --  A model's profile: the configuration's map model.ID, as
   --  context=N, reserve=N, tools=yes|no, structured=yes|no,
   --  reasoning=yes|no, streaming=yes|no, parallel=yes|no, class=WORD,
   --  provider=WORD; the default one when the configuration names none.
   --
   --  @param Item The store.
   --  @param Id The profile; empty for the default.
   --  @return The profile.
   function Profile (Item : Stores.Store; Id : String) return Model_Profile;

   --  What a text is estimated to cost: a token for every four bytes.
   --
   --  @param Text The text.
   --  @return The estimate.
   function Estimate (Text : String) return Natural;

   --  Build the context for a task.
   --
   --  @param Item The store.
   --  @param Task_Id The task.
   --  @param Model The profile to budget for.
   --  @param Result The context.
   --  @param Status Framework_Not_Found when there is no such task, and
   --    Framework_Context_Overflow when what is mandatory does not fit.
   procedure Build
     (Item    : Stores.Store;
      Task_Id : String;
      Model   : Model_Profile;
      Result  : out Built;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Build the context of a child agent: its rules, the task it helps with
   --  and what it is asked, all mandatory, fitted and fingerprinted as a
   --  task's is.
   --
   --  @param Item The store.
   --  @param Task_Id The task the child helps with.
   --  @param Model The profile the context is budgeted for.
   --  @param Rules What the child is told of itself.
   --  @param Brief What it is asked, in its parent's words.
   --  @param Result The context and its manifest.
   --  @param Status Framework_Context_Overflow when it does not fit.
   procedure Build_Brief
     (Item    : Stores.Store;
      Task_Id : String;
      Model   : Model_Profile;
      Rules   : String;
      Brief   : String;
      Result  : out Built;
      Status  : out Model_Runner.Errors.Error_Info);

   --  The context's identifier: CTX- and its fingerprint.
   --
   --  @param From The context.
   --  @return The identifier.
   function Manifest_Id (From : Built) return String;

   --  The text the model is given.
   --
   --  @param From The context.
   --  @return The rendered context.
   function Rendered (From : Built) return String;

   --  What the context is estimated to cost.
   --
   --  @param From The context.
   --  @return The estimate, in tokens.
   function Cost (From : Built) return Natural;

   --  The room the context had: the model's window less what is kept for
   --  its answer -- the task kind's own reserve where it has one -- and
   --  for the tools.
   --
   --  @param From The context.
   --  @return The room, in tokens.
   function Budget (From : Built) return Natural;

   --  How many items went in, and how many did not.
   --
   --  @param From The context.
   --  @return The count of items included.
   function Included_Count (From : Built) return Natural;

   --  How many candidate items were left out.
   --
   --  @param From The context.
   --  @return The count.
   function Excluded_Count (From : Built) return Natural;

   --  One item that went in, in the order it is rendered.
   --
   --  @param From The context.
   --  @param Index 1 .. Included_Count.
   --  @return The item.
   function Included_At (From : Built; Index : Positive) return Item;

   --  Whether the context was built with the repository's graph, or with
   --  the textual fallback because there was none.
   --
   --  @param From The context.
   --  @return True when the graph was used.
   function Semantic (From : Built) return Boolean;

   --  Keep a context: its manifest in the invocations area and its text as
   --  a result. Keeping the same context again stages nothing.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param From The context.
   --  @param Status A failure staging it.
   procedure Keep
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      From   : Built;
      Status : out Model_Runner.Errors.Error_Info);

private

   package Item_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Item);

   type Built is record
      Task_Id    : Ada.Strings.Unbounded.Unbounded_String;
      Generation : Ada.Strings.Unbounded.Unbounded_String;
      Model      : Model_Profile;
      Included   : Item_Vectors.Vector;
      Excluded   : Item_Vectors.Vector;

      --  Why each excluded item was left out, in the same order.
      Reasons    : Name_Lists.Vector;

      --  The requirement and decision revisions that apply, as ID@N.
      Revisions  : Name_Lists.Vector;

      Config_Revision    : Natural := 0;
      Config_Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
      Semantic   : Boolean := False;
      Budget     : Natural := 0;
      Cost       : Natural := 0;
      Print      : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Model_Runner.Framework.Context;
