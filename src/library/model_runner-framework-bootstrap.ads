private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  Establishing what a project is meant to be from what it already says.
--
--  Bootstrap reads documents the project has and classifies what it finds
--  as a discovered fact, an imported authoritative item, a candidate
--  requirement, decision or specification, or an issue. It makes no tasks:
--  requirements it proposes go through acceptance like any other, and what
--  follows from their acceptance follows from that.
--
--  Each output carries a provenance key -- where in which document it came
--  from, by what it says rather than by its line number -- so bootstrap can
--  run again over the same documents, or the same documents edited, and
--  make only what is new: an output whose key the state already holds is
--  counted and passed over.
--
--  What it proposes is only proposed. Candidates stay candidates; only an
--  item a document states with its own identifier is imported as accepted,
--  because the document has already accepted it.
package Model_Runner.Framework.Bootstrap is

   --  What an output is.
   type Output_Kind is
     (Discovered_Fact,
      Imported_Item,
      Requirement_Candidate,
      Decision_Candidate,
      Specification_Candidate,
      Issue);

   --  One thing found.
   type Output is record
      Kind       : Output_Kind := Issue;

      --  What makes it the same thing when it is found again.
      Provenance : Ada.Strings.Unbounded.Unbounded_String;

      --  The fact's key, or the key identifiers are given under.
      Key        : Ada.Strings.Unbounded.Unbounded_String;

      Title      : Ada.Strings.Unbounded.Unbounded_String;
      Text       : Ada.Strings.Unbounded.Unbounded_String;
      Source     : Ada.Strings.Unbounded.Unbounded_String;

      --  What it is judged by, from the document's Acceptance: lines.
      Criteria   : Ada.Strings.Unbounded.Unbounded_String;

      --  The identifier the document gives it, where it gives one.
      Given_Id   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Things found.
   type Output_List is private;

   --  What applying them did.
   type Report is record
      Created  : Natural := 0;
      Existing : Natural := 0;
      Issues   : Natural := 0;

      --  What it made, by identifier.
      Made     : Name_Lists.Vector;

      --  Each entry a document it read no longer says, and why that
      --  matters: an issue each.
      Stale    : Name_Lists.Vector;
   end record;

   --  Add an output.
   --
   --  @param Into The list.
   --  @param Item The output.
   procedure Append (Into : in out Output_List; Item : Output);

   --  How many outputs a list holds.
   --
   --  @param From The list.
   --  @return The count.
   function Length (From : Output_List) return Natural;

   --  One output.
   --
   --  @param From The list.
   --  @param Index 1 .. Length.
   --  @return The output.
   function Element (From : Output_List; Index : Positive) return Output;

   --  Read a document for what it says the project must be.
   --
   --  Its first heading makes it a specification candidate. A line naming
   --  a requirement by its identifier -- REQ-IO-003: text -- is an item the
   --  document has accepted, and is imported; so is the first normative
   --  line under a heading that names one -- ## REQ-IO-003 Title -- with
   --  the heading's title. Any other line with SHALL, MUST or SHOULD in
   --  capitals is a requirement candidate; a line Acceptance: says what
   --  the requirement before it is judged by. A line starting Decision: is
   --  a decision candidate, and one naming a decision by its identifier --
   --  DEC-001: text -- is one under that identifier. A line Fact: KEY =
   --  VALUE is a discovered fact, and one that does not read an issue; a
   --  normative line said twice is an issue. Identifiers not given are
   --  given under a key made from the document's name.
   --
   --  @param Path The document's path, which provenance keys start with.
   --  @param Text Its text.
   --  @return What it says.
   function Scan (Path : String; Text : String) return Output_List;

   --  The documents the project's bootstrap policy reads: each entry of
   --  set bootstrap.sources is a file, or a directory and a pattern for the
   --  files in it, as docs/*.md, all within the project. Without the
   --  setting, the Markdown at the top and in docs.
   --
   --  @param Item The store.
   --  @return Their paths within the project, sorted, each once.
   function Documents (Item : Stores.Store) return Name_Lists.Vector;

   --  Apply what was found, making only what the state does not already
   --  hold, and only what the bootstrap policy lets it make: set
   --  bootstrap.propose names the kinds made -- facts, imports,
   --  requirements, decisions, specifications, issues; all without it --
   --  and scalar bootstrap.import = candidate has an item a document gives
   --  its own identifier proposed rather than accepted.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Found The outputs.
   --  @param Result What was made and what was passed over.
   --  @param Status A failure staging one of them.
   procedure Apply
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Output_List;
      Result : out Report;
      Status : out Model_Runner.Errors.Error_Info);

private

   package Output_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Output);

   type Output_List is record
      Outputs : Output_Vectors.Vector;
   end record;

end Model_Runner.Framework.Bootstrap;
