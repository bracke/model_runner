private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  What follows mechanically from known inputs, kept to be used again.
--
--  A derivation is a computation the harness does the same way every time
--  -- the traceability graph, the impact of a change, the tests chosen for
--  it -- named by everything whose change could change its answer: what
--  kind it is, the algorithm and that algorithm's own version, and each
--  input, policy and environment value it read, typed and fingerprinted.
--  That description is written out canonically -- unordered inputs sorted,
--  ordered ones kept at their places, absent told from unreadable and
--  empty from absent -- and its fingerprint is the derivation's key, DRV-
--  and sixteen hexadecimal digits. The same inputs make the same key
--  whatever order they were gathered in, and a changed input, policy or
--  version makes another.
--
--  Its answer is a result (Results), stored once under its content; the
--  derivation's record says why that result exists. Looking one up says
--  what was found: current, missing, stale -- and in what, against the
--  last derivation of the same kind and subject -- corrupt, or not to be
--  decided because an input could not be read. An unreadable input is
--  never taken for an absent one, and a corrupt record never for a miss
--  where the answer rests on it.
--
--  Derived state is never authoritative: the area can be emptied and
--  everything in it worked out again from the rest without changing what
--  the project means. Reuse is valid only when every semantic input still
--  matches.
package Model_Runner.Framework.Derivations is

   --  What a dependency stands for: what the derivation is computed from,
   --  the policy it follows, or the machine it ran on.
   type Dependency_Class is (Input, Policy, Environment);

   --  How a dependency stood when it was read.
   type Presence is (Present, Absent, Unreadable);

   --  The kind of dependency that is another derivation: its name is that
   --  derivation's kind, its print that derivation's key.
   Derived_Kind : constant String := "derived";

   --  What a derivation is: its kind, algorithm and dependencies.
   type Specification is private;

   --  A field of a line an answer is written in, its tabs, line ends and
   --  percents written %09, %0A, %0D and %25, so that any text can be one.
   --
   --  @param Text The text.
   --  @return It, coded.
   function Coded (Text : String) return String;

   --  A coded field read back.
   --
   --  @param Text As Coded wrote it.
   --  @return The text.
   function Decoded (Text : String) return String;

   --  The fields of a line, split at its tabs and each decoded.
   --
   --  @param Line The line.
   --  @return Its fields.
   function Fields_Of (Line : String) return Name_Lists.Vector;

   --  Begin describing a derivation.
   --
   --  @param Kind What it is, as traceability, impact, test_selection.
   --  @param Algorithm What computes it, as traceability.
   --  @param Version The algorithm's version, raised only when what it
   --    computes changes: a different meaning for the same bytes.
   --  @param Subject What successive derivations of the kind are of -- the
   --    project, a task -- so that a new one can be told from the last;
   --    not part of the key.
   --  @return The description, with no dependencies yet.
   function Specify
     (Kind      : String;
      Algorithm : String;
      Version   : String;
      Subject   : String := "project") return Specification;

   --  Add a dependency to a description.
   --
   --  @param Spec The description.
   --  @param Class Input, policy or environment.
   --  @param Kind What sort of thing it is, as file, record, configuration,
   --    or Derived_Kind for another derivation.
   --  @param Name Which one, as src/parser.adb.
   --  @param Print Its fingerprint, or the value itself where it is short;
   --    "" for an empty one, which is not an absent one.
   --  @param State Whether it was there to read.
   --  @param Position Where it stands in an ordered list of inputs, from 1;
   --    0 for one whose order does not matter.
   procedure Depend
     (Spec     : in out Specification;
      Class    : Dependency_Class;
      Kind     : String;
      Name     : String;
      Print    : String;
      State    : Presence := Present;
      Position : Natural := 0);

   --  Add what a derivation found it rested on as it was made -- a file it
   --  looked for -- which is confirmed each time it is looked up rather
   --  than made part of its key: a presence (Print empty, State Present or
   --  Absent) or a file's fingerprint, both by a path within the project.
   --
   --  @param Spec The description.
   --  @param Kind presence or file.
   --  @param Name The path.
   --  @param Print The file's fingerprint; "" for a presence.
   --  @param State Whether it was there.
   procedure Confirm
     (Spec  : in out Specification;
      Kind  : String;
      Name  : String;
      Print : String;
      State : Presence);

   --  Whether every dependency of a description could be read: one that
   --  could not leaves it neither current nor stale.
   --
   --  @param Spec The description.
   --  @return False when one is Unreadable.
   function Readable (Spec : Specification) return Boolean;

   --  The kind a description is of.
   --
   --  @param Spec The description.
   --  @return Its kind.
   function Kind_Of (Spec : Specification) return String;

   --  The description written out canonically: what the key is made from.
   --
   --  @param Spec The description.
   --  @return The text.
   function Canonical (Spec : Specification) return String;

   --  The key of a derivation.
   --
   --  @param Spec The description.
   --  @return DRV- and sixteen upper-case hexadecimal digits.
   function Key_Of (Spec : Specification) return String;

   --  How a derivation stands.
   type Currentness is
     (Current,
      Missing,
      Stale_Input,
      Stale_Algorithm,
      Stale_Policy,
      Stale_Environment,
      Corrupt,
      Input_Unavailable);

   --  What looking a derivation up found.
   type Finding is record
      Standing : Currentness := Missing;

      --  The key asked for.
      Key      : Ada.Strings.Unbounded.Unbounded_String;

      --  Its result, when it is current.
      Result   : Ada.Strings.Unbounded.Unbounded_String;

      --  The last derivation of the same kind and subject, when it is not
      --  this one: what the description was held against.
      Prior    : Ada.Strings.Unbounded.Unbounded_String;

      --  Why it stands so, one cause a line: every difference from the
      --  prior one, or what could not be read.
      Causes   : Name_Lists.Vector;
   end record;

   --  The word a standing is said as.
   --
   --  @param Standing The standing.
   --  @return Its word, as stale_input.
   function Word (Standing : Currentness) return String;

   --  Look a derivation up.
   --
   --  @param Item The store.
   --  @param Spec What it is.
   --  @return What was found.
   function Find_Current (Item : Stores.Store; Spec : Specification) return Finding;

   --  Why a kept derivation is what it is, as a path of causes: what it was
   --  made from, the derivations it rests on, and -- where a later one of
   --  its kind and subject has been made -- what changed between them, each
   --  derivation it rests on followed in turn to the inputs that changed.
   --  The path is bounded and cycles are cut: a damaged chain is said, not
   --  followed for ever.
   --
   --  @param Item The store.
   --  @param Key The derivation.
   --  @return The lines; one saying so when there is no such derivation.
   function Explain (Item : Stores.Store; Key : String) return Name_Lists.Vector;

   --  Derivations worked out and not yet kept: what a computation that
   --  cannot write hands to the transaction that can.
   type Staged is private;

   --  Nothing to keep.
   Nothing_Staged : constant Staged;

   --  Add a derivation and its answer to what is to be kept.
   --
   --  @param Into What is to be kept.
   --  @param Spec What it is.
   --  @param Payload Its answer.
   --  @param Summary What its answer is, in a line.
   procedure Add
     (Into    : in out Staged;
      Spec    : Specification;
      Payload : String;
      Summary : String);

   --  Join what two computations left to be kept.
   --
   --  @param Into What is kept, with From's after it.
   --  @param From The rest.
   procedure Add (Into : in out Staged; From : Staged);

   --  How many derivations are waiting to be kept.
   --
   --  @param From What is to be kept.
   --  @return The count.
   function Length (From : Staged) return Natural;

   --  Stage a derivation and its answer in a transaction: its result, its
   --  record, and the record saying it is the latest of its kind and
   --  subject. A record of the same key already kept is left as it is; one
   --  there that would not read is a damaged cache, discarded and written
   --  again.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Spec What it is.
   --  @param Payload Its answer.
   --  @param Summary What its answer is, in a line.
   --  @param Status A failure staging it.
   procedure Keep
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Spec    : Specification;
      Payload : String;
      Summary : String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Stage everything a computation left to be kept.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param From What is to be kept.
   --  @param Status A failure staging one.
   procedure Keep
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      From   : Staged;
      Status : out Model_Runner.Errors.Error_Info);

   --  The answer of a current derivation.
   --
   --  @param Item The store.
   --  @param Found What looking it up found, Current.
   --  @param Payload Its answer.
   --  @param Status Framework_Not_Found when it is not current, and the
   --    result's own failure when its answer will not read.
   procedure Answer
     (Item    : Stores.Store;
      Found   : Finding;
      Payload : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info);

   --  Hold an answer worked out in this process, for a lookup before it is
   --  kept: a handful, the oldest let go.
   --
   --  @param Spec What it is.
   --  @param Payload Its answer.
   procedure Remember (Spec : Specification; Payload : String);

   --  An answer this process holds for a derivation, its confirmations
   --  holding still.
   --
   --  @param Item The store.
   --  @param Spec What it is.
   --  @param Payload Its answer, when found.
   --  @param Found Whether one is held.
   procedure Recall
     (Item    : Stores.Store;
      Spec    : Specification;
      Payload : out Ada.Strings.Unbounded.Unbounded_String;
      Found   : out Boolean);

   --  Forget every answer this process holds.
   procedure Forget;

   --  How often this process worked out derivations of a kind, and how
   --  often it used one again: what tells reuse from recomputation.
   --
   --  @param Kind The kind.
   --  @return The count.
   function Computed (Kind : String) return Natural;

   --  How often a derivation of a kind was used again.
   --
   --  @param Kind The kind.
   --  @return The count.
   function Reused (Kind : String) return Natural;

   --  Count a derivation worked out, or used again.
   --
   --  @param Kind Its kind.
   --  @param Again Whether it was used again rather than worked out.
   procedure Count (Kind : String; Again : Boolean);

   --  Let derivations go that are older than the policy keeps, and the
   --  answers no derivation kept names any more -- never one another still
   --  names, since one answer may be two derivations'. What goes can be
   --  worked out again from the rest.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Days How old a derivation may grow; zero keeps them.
   --  @param Removed How many records went.
   procedure Prune
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Days    : Natural;
      Removed : out Natural);

private

   use Ada.Strings.Unbounded;

   type Dependency is record
      Class    : Dependency_Class := Input;
      Kind     : Unbounded_String;
      Name     : Unbounded_String;
      Print    : Unbounded_String;
      State    : Presence := Present;
      Position : Natural := 0;
   end record;

   package Dependency_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Dependency);

   type Specification is record
      Kind      : Unbounded_String;
      Algorithm : Unbounded_String;
      Version   : Unbounded_String;
      Subject   : Unbounded_String;
      Needs     : Dependency_Vectors.Vector;
      Confirms  : Dependency_Vectors.Vector;
   end record;

   type Staged_One is record
      Spec    : Specification;
      Payload : Unbounded_String;
      Summary : Unbounded_String;
   end record;

   package Staged_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Staged_One);

   type Staged is record
      Items : Staged_Vectors.Vector;
   end record;

   Nothing_Staged : constant Staged := (Items => Staged_Vectors.Empty_Vector);

end Model_Runner.Framework.Derivations;
