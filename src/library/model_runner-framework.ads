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
      Indexes_Area);

   --  Names, in the order an operation gives them: the files in an area,
   --  the fields of a record, the keys of the facts.
   package Name_Lists is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => String);

   --  What kind of state an area holds.
   --
   --  Authored state is what people and the harness decided; runtime state
   --  is what is going on now; historical state is what happened and is
   --  never rewritten; derived state can be thrown away and computed again
   --  from the rest without changing what the project means.
   type State_Class is
     (Authored_State,
      Runtime_State,
      Historical_State,
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

end Model_Runner.Framework;
