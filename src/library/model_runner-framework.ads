with Ada.Containers.Indefinite_Vectors;
with Interfaces;

--  The project state a development session keeps, and what it is made of.
--
--  A project that is being developed with this program keeps its state in
--  one directory, .model_runner, beside the code: what was asked for, what
--  was decided, what is to be done and what has been done. None of it is
--  held in a conversation. A session that ends, a model that forgets and a
--  machine that crashes all leave the state where the last committed change
--  put it, and the next session reads it back from there.
--
--  This package names the parts of that directory and what each part is.
--  The children do the work: Records is the one format every file in it is
--  written in, Schemas says what a record of each kind must hold,
--  Identifiers makes and checks the names entities are known by, Stores
--  opens the directory and changes it only through transactions, Results
--  keeps what was produced and Facts what is known about the project.
--
--  Nothing here asks a model anything. Every operation is bookkeeping that
--  gives the same answer from the same state.
package Model_Runner.Framework is

   --  Name of the state directory inside a project.
   State_Directory : constant String := ".model_runner";

   --  What the state directory says it is, so that a directory of the same
   --  name made by something else is not read as one.
   Format_Name : constant String := "model_runner-framework";

   --  Version of the layout and the record schemas together. A state root
   --  written by a later version is refused rather than half understood.
   State_Version : constant := 1;

   --  The parts of the state directory, each a subdirectory of it.
   type Area is
     (Project_Area,
      Config_Area,
      Specs_Area,
      Requirements_Area,
      Decisions_Area,
      Tasks_Area,
      Runtime_Area,
      Results_Area,
      Events_Area,
      Verification_Area,
      Invocations_Area,
      Workspaces_Area,
      Indexes_Area,
      Derivations_Area,
      Observations_Area);

   --  Names, in the order an operation gives them: the files in an area,
   --  the fields of a record, the keys of the facts.
   package Name_Lists is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   --  A state as a sentence says it: a candidate, but accepted.
   --
   --  @param State The state.
   --  @return It with the article a noun takes.
   function State_Said (State : String) return String
   is (if State = "candidate" then "a candidate"
       elsif State = "verification" then "waiting in verification"
       else State);

   --  How a process recorded by its id and identity stands: the same one
   --  there still; another, or none -- gone; or not known. One answer for
   --  every record that names a process -- a lease, a process slot, a
   --  process group left to stop -- since an id is reused once its process
   --  is gone, and "a process with that id is there" is not "it is".
   type Process_Standing is (Same_Process, Other_Process, Not_Known);

   --  A process as a record keeps it: its id, a space, its identity
   --  (Hostkit.Process.Identity_Of), the identity left off where the host
   --  cannot give one.
   --
   --  @param Process_Id The process.
   --  @return The line.
   function Process_Line (Process_Id : Integer) return String;

   --  How a process a record kept stands now. An id with no identity --
   --  kept by an older build, or on a host that gives none -- is never the
   --  same process: present, it is not known; gone, it is gone.
   --
   --  @param Line As Process_Line made it, or an id alone.
   --  @return The standing.
   function Standing_Of (Line : String) return Process_Standing;

   --  Whether one record's name is later than another's by the number in
   --  it -- VER-1000000 after VER-999999, which sort the other way -- and,
   --  the numbers equal, by the name; any name is later than "".
   --
   --  @param Name The candidate.
   --  @param Than The latest so far, or "".
   --  @return True when Name is later.
   function Later (Name, Than : String) return Boolean;

   --  The lines of a text, empty ones left out: how a field holding a
   --  list keeps it.
   --
   --  @param Text The text.
   --  @return Its lines.
   function Lines_Of (Text : String) return Name_Lists.Vector;

   --  The name a mistyped one most likely meant: one of those given a
   --  letter or two from it, whatever the case; the nearest first.
   --
   --  @param Word What was typed.
   --  @param Among The names it may have meant.
   --  @return The nearest, or an empty string when none is that near.
   function Nearest (Word : String; Among : Name_Lists.Vector) return String;

   --  Whether a path names a place from the root of a machine rather than
   --  from the project: begun with '/' or '\', or '~', or a drive letter
   --  and a colon. A project's own paths are none of these on any host; a
   --  check for a leading '/' alone let Windows' C:\ and \ through.
   --
   --  @param Path The path as given.
   --  @return True when it is rooted outside the project.
   function Is_Rooted (Path : String) return Boolean
   is (Path'Length > 0
       and then (Path (Path'First) in '/' | '\' | '~'
                 or else (Path'Length > 1 and then Path (Path'First + 1) = ':')));

   --  What kind of state an area holds.
   --
   --  Authored state is what people and the harness decided; runtime state
   --  is what is going on now; historical state is what happened and is
   --  never rewritten; observational state is what was learned while
   --  working, kept and never authoritative; derived state can be thrown
   --  away and computed again from the rest without changing what the
   --  project means. Persistence does not imply authority: none of the
   --  last two becomes the first except through what makes authored state.
   type State_Class is
     (Authored_State,
      Runtime_State,
      Historical_State,
      Observational_State,
      Derived_State);

   --  Where an area belongs: with the repository, on this machine only, or
   --  nowhere in particular because it is a cache.
   type Portability is
     (Repository_Portable,
      Machine_Local,
      Derived_Cache);

   --  The subdirectory an area is kept in.
   --
   --  @param Where The area.
   --  @return Its directory name, relative to the state directory.
   function Directory_Name (Where : Area) return String;

   --  The kind of state an area holds.
   --
   --  @param Where The area.
   --  @return Its state class.
   function Class_Of (Where : Area) return State_Class;

   --  Whether an area travels with the repository.
   --
   --  @param Where The area.
   --  @return Its portability.
   function Portability_Of (Where : Area) return Portability;

   --  The present moment as the state records it: ISO 8601, in UTC, to
   --  the second, as 2026-09-27T14:03:11Z.
   --
   --  @return The timestamp.
   function Timestamp return String;

   --  A moment some seconds from now, written as Timestamp writes one.
   --  Timestamps compare as text in the order they happen, which is what a
   --  lease's expiry is checked by.
   --
   --  @param Seconds How far ahead.
   --  @return The timestamp.
   function Timestamp_After (Seconds : Natural) return String;

   --  The 64-bit FNV-1a hash of some bytes.
   --
   --  The one hash the state uses to fingerprint what it stores. It is not
   --  a defence against somebody who means harm; it is how a record that
   --  changed under its fingerprint, or two contents given one name, are
   --  noticed.
   --
   --  @param Text The bytes.
   --  @return The hash.
   function Hash (Text : String) return Interfaces.Unsigned_64;

   --  The fingerprint of some bytes: their hash as sixteen lower-case
   --  hexadecimal digits.
   --
   --  @param Text The bytes.
   --  @return The fingerprint.
   function Fingerprint (Text : String) return String;

   --  The hash of bytes that follow bytes already hashed to Before: Hash of
   --  the two joined, without joining them -- for a text of hundreds of
   --  megabytes given a line at a time.
   --
   --  @param Text The bytes that follow.
   --  @param Before The hash of the bytes before; Hash ("") for none.
   --  @return The hash of all of them.
   function Hash_On (Text : String; Before : Interfaces.Unsigned_64) return Interfaces.Unsigned_64;

   --  A hash as a fingerprint: sixteen lower-case hexadecimal digits, as
   --  Fingerprint gives the hash it takes.
   --
   --  @param Value The hash.
   --  @return The fingerprint.
   function Fingerprint_Of (Value : Interfaces.Unsigned_64) return String;

end Model_Runner.Framework;
