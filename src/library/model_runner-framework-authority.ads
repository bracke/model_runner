private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Which statement about a subject governs, and how the others stand to it.
--
--  Statements come from sources of different standing: an explicit
--  instruction outranks an accepted decision, which outranks a component's
--  specification, and so on down to what an agent assumed. The highest
--  governs. The others are not erased by it: one that says the same agrees;
--  one about a narrower subject -- build.command.flags under build.command
--  -- refines; one that says otherwise is overridden only when the higher
--  statement names it as what it overrides, and is otherwise a conflict to
--  be resolved, which is reported rather than decided here.
package Model_Runner.Framework.Authority is

   --  Standing, highest first.
   type Level is
     (Human_Instruction,
      Project_Decision,
      Component_Specification,
      Project_Specification,
      Resolved_Configuration,
      Project_Baseline,
      Language_Baseline,
      Agent_Assumption);

   --  One normative statement.
   type Statement is record
      Standing  : Level := Agent_Assumption;

      --  The entity or setting that makes it.
      Source    : Ada.Strings.Unbounded.Unbounded_String;

      --  What it is about, as build.command.
      Subject   : Ada.Strings.Unbounded.Unbounded_String;

      --  What it says.
      Value     : Ada.Strings.Unbounded.Unbounded_String;

      --  The source whose statement it overrides, when it says so.
      Overrides : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  How a statement stands to the one that governs its subject.
   type Relation is (Agreement, Refinement, Explicit_Override, Conflict);

   --  One statement, set against the one governing it.
   type Standing_Of is record
      Governing : Statement;
      Other     : Statement;
      Relation  : Authority.Relation := Agreement;
   end record;

   --  Statements to resolve.
   type Statement_List is private;

   --  What resolving them found.
   type Resolution is private;

   --  Add a statement.
   --
   --  @param Into The list.
   --  @param Item The statement.
   procedure Append (Into : in out Statement_List; Item : Statement);

   --  How many statements a list holds.
   --
   --  @param From The list.
   --  @return The count.
   function Count (From : Statement_List) return Natural;

   --  Give an explicit instruction: a person's word on a subject, which
   --  governs it above every decision, specification and setting while it
   --  stands, and which says what it overrides when it overrides something.
   --  Kept, with who gave it and when, until it is withdrawn.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Subject What it is about, as a decision's governs names it.
   --  @param Value What it says.
   --  @param Overrides The source it overrides, or "".
   --  @param Given_By Who gave it.
   --  @param Id Its identifier, INSTR-number.
   --  @param Status Framework_Input_Missing for no subject or value.
   procedure Instruct
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Subject   : String;
      Value     : String;
      Overrides : String;
      Given_By  : String;
      Id        : out Ada.Strings.Unbounded.Unbounded_String;
      Status    : out Model_Runner.Errors.Error_Info);

   --  Withdraw an instruction: it stops governing, and stays on record.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Id The instruction.
   --  @param By Who withdrew it.
   --  @param Status Framework_Not_Found when there is no standing one.
   procedure Withdraw
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      By     : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  The instructions standing, each as ID: SUBJECT = VALUE.
   --
   --  @param Item The store.
   --  @return Them, in the order given.
   function Standing_Instructions (Item : Stores.Store) return Name_Lists.Vector;

   --  Every statement the project state makes: standing instructions,
   --  accepted decisions and specifications that govern a subject, the
   --  resolved configuration's settings and the baselines.
   --
   --  @param Item The store.
   --  @return The statements.
   function Gather (Item : Stores.Store) return Statement_List;

   --  Resolve statements.
   --
   --  @param From The statements.
   --  @return For each statement not governing its subject, how it stands
   --    to the one that does.
   function Resolve (From : Statement_List) return Resolution;

   --  The statement governing a subject.
   --
   --  @param From What resolving found.
   --  @param Subject The subject.
   --  @param Found Whether any statement is about it.
   --  @return The governing statement, when Found.
   function Governing
     (From    : Resolution;
      Subject : String;
      Found   : out Boolean) return Statement;

   --  How many subjects a resolution has a governing statement for.
   --
   --  @param From What resolving found.
   --  @return The count.
   function Governing_Count (From : Resolution) return Natural;

   --  The statement governing one of them, in the order resolved.
   --
   --  @param From What resolving found.
   --  @param Index 1 .. Governing_Count.
   --  @return It.
   function Governing_At (From : Resolution; Index : Positive) return Statement;

   --  How many standings a resolution holds.
   --
   --  @param From What resolving found.
   --  @return The count.
   function Length (From : Resolution) return Natural;

   --  One standing.
   --
   --  @param From What resolving found.
   --  @param Index 1 .. Length.
   --  @return The standing.
   function Element (From : Resolution; Index : Positive) return Standing_Of;

private

   package Statement_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Statement);

   package Standing_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Standing_Of);

   type Statement_List is record
      Statements : Statement_Vectors.Vector;
   end record;

   type Resolution is record
      Governing : Statement_Vectors.Vector;
      Standings : Standing_Vectors.Vector;
   end record;

end Model_Runner.Framework.Authority;
