private with Ada.Containers.Vectors;

with Ada.Strings.Unbounded;

with Model_Runner.Errors;
with Model_Runner.Framework.Stores;

--  What the repository holds, found without a model.
--
--  A scan walks the project's files -- leaving out version control, the
--  project state, build output and anything hidden -- and gives each a
--  language by its extension and a role by where it is. Each file is
--  handed to the adapter for its language. Every language has at least
--  the generic one, which records the file and nothing in it; Ada has an
--  adapter that reads compilation units, what each withs, what each spec
--  declares and where those names are used.
--
--  What is found is a graph: files, units and symbols, and the relations
--  between them -- a unit is in a file, a body implements a spec, a unit
--  depends on another, a unit declares a symbol, a file refers to one.
--  Every relation says how it was derived and how sure that is: a with
--  clause is explicit and certain, a file named after its unit is a naming
--  convention and probable, a name that matches a symbol is a heuristic
--  and uncertain. The graph is derived state, kept in the indexes and made
--  again whenever it is asked for and missing or stale.
package Model_Runner.Framework.Repository is

   --  What a file is for.
   type File_Role is (Source, Test, Documentation, Build, Other);

   --  What a node of the graph is.
   type Node_Kind is (File_Node, Unit_Node, Symbol_Node);

   --  What a relation says.
   type Relation_Kind is
     (Contains,
      Implements,
      Depends_On,
      Declares,
      References);

   --  How a relation was found.
   type Derivation is
     (Explicit,
      Semantic_Analysis,
      Build_Metadata,
      Naming_Convention,
      Heuristic);

   --  How sure it is.
   type Confidence is (Authoritative, Certain, Probable, Uncertain);

   --  One file.
   type File_Entry is record
      Path        : Ada.Strings.Unbounded.Unbounded_String;
      Language    : Ada.Strings.Unbounded.Unbounded_String;
      Role        : File_Role := Other;
      Fingerprint : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  One symbol a unit declares.
   type Symbol is record
      --  The unit's name and the symbol's, as Parser.Next_Token.
      Name : Ada.Strings.Unbounded.Unbounded_String;

      --  What it is: package, procedure, function, type, subtype, task,
      --  protected, entry, exception, constant.
      Kind : Ada.Strings.Unbounded.Unbounded_String;

      Path : Ada.Strings.Unbounded.Unbounded_String;
      Line : Natural := 0;
   end record;

   --  One relation.
   type Relation is record
      Kind   : Relation_Kind := Contains;
      From   : Ada.Strings.Unbounded.Unbounded_String;
      To     : Ada.Strings.Unbounded.Unbounded_String;
      Source : Derivation := Explicit;
      Sure   : Confidence := Certain;

      --  Where it was seen, as path:line, for a reference.
      Where  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  What a scan found.
   type Graph is private;

   --  A language adapter: what can be read out of a file of its language.
   type Adapter is interface;

   --  The language an adapter reads.
   --
   --  @param Self The adapter.
   --  @return Its name, as Ada.
   function Language (Self : Adapter) return String is abstract;

   --  Read one file into a graph.
   --
   --  @param Self The adapter.
   --  @param Path The file's path within the project.
   --  @param Text Its text.
   --  @param Into The graph, to add what the file holds.
   procedure Read
     (Self : Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is abstract;

   --  The adapter for a language no other reads: the file is recorded and
   --  nothing in it.
   type Generic_Adapter is new Adapter with null record;

   overriding function Language (Self : Generic_Adapter) return String;

   overriding procedure Read
     (Self : Generic_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   --  The adapter for Ada.
   type Ada_Adapter is new Adapter with null record;

   overriding function Language (Self : Ada_Adapter) return String;

   overriding procedure Read
     (Self : Ada_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   --  The language a file's name says it is written in.
   --
   --  @param Path The file.
   --  @return Its language, or the empty string for none this knows.
   function Language_Of (Path : String) return String;

   --  What a file's place says it is for.
   --
   --  @param Path The file, within the project.
   --  @return Its role.
   function Role_Of (Path : String) return File_Role;

   --  Walk a project and read every file into a graph.
   --
   --  @param Project_Directory The project.
   --  @return The graph.
   function Scan (Project_Directory : String) return Graph;

   --  Keep a graph in the project state's indexes, replacing the last.
   --
   --  @param Item The store.
   --  @param Change The transaction.
   --  @param Found The graph.
   --  @param Status A failure staging it.
   procedure Keep
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Found  : Graph;
      Status : out Model_Runner.Errors.Error_Info);

   --  The graph kept in the project state.
   --
   --  @param Item The store.
   --  @param Found The graph; empty when none is kept.
   --  @param Status Framework_Not_Found when none is kept.
   procedure Load
     (Item   : Stores.Store;
      Found  : out Graph;
      Status : out Model_Runner.Errors.Error_Info);

   --  How many files a graph holds.
   --
   --  @param From The graph.
   --  @return The count.
   function File_Count (From : Graph) return Natural;

   --  One file.
   --
   --  @param From The graph.
   --  @param Index 1 .. File_Count.
   --  @return The file.
   function File_At (From : Graph; Index : Positive) return File_Entry;

   --  The fingerprint of a whole graph: of every file's, so that one
   --  changed file changes it.
   --
   --  @param From The graph.
   --  @return Sixteen hexadecimal digits.
   function Graph_Fingerprint (From : Graph) return String;

   --  The symbols a name matches: the full name, or the last part of it,
   --  in any case.
   --
   --  @param From The graph.
   --  @param Name The name.
   --  @return The matching symbols, sorted.
   function Find_Symbols (From : Graph; Name : String) return Name_Lists.Vector;

   --  A symbol by its full name.
   --
   --  @param From The graph.
   --  @param Name The full name.
   --  @param Found Whether it is there.
   --  @return The symbol.
   function Symbol_Of
     (From  : Graph;
      Name  : String;
      Found : out Boolean) return Symbol;

   --  The places a symbol is referred to, as path:line.
   --
   --  @param From The graph.
   --  @param Name The symbol's full name.
   --  @return The places, sorted.
   function References_To
     (From : Graph;
      Name : String) return Name_Lists.Vector;

   --  The units a unit depends on.
   --
   --  @param From The graph.
   --  @param Unit The unit.
   --  @return Their names, sorted.
   function Dependencies_Of
     (From : Graph;
      Unit : String) return Name_Lists.Vector;

   --  The units that depend on a unit.
   --
   --  @param From The graph.
   --  @param Unit The unit.
   --  @return Their names, sorted.
   function Dependents_Of
     (From : Graph;
      Unit : String) return Name_Lists.Vector;

   --  How many relations a graph holds.
   --
   --  @param From The graph.
   --  @return The count.
   function Relation_Count (From : Graph) return Natural;

   --  One relation.
   --
   --  @param From The graph.
   --  @param Index 1 .. Relation_Count.
   --  @return The relation.
   function Relation_At (From : Graph; Index : Positive) return Relation;

   --  Add a file.
   --
   --  @param Into The graph.
   --  @param Item The file.
   procedure Add_File (Into : in out Graph; Item : File_Entry);

   --  Add a symbol.
   --
   --  @param Into The graph.
   --  @param Item The symbol.
   procedure Add_Symbol (Into : in out Graph; Item : Symbol);

   --  Add a relation.
   --
   --  @param Into The graph.
   --  @param Item The relation.
   procedure Add_Relation (Into : in out Graph; Item : Relation);

private

   package File_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => File_Entry);

   package Symbol_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Symbol);

   package Relation_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Relation);

   type Graph is record
      Files     : File_Vectors.Vector;
      Symbols   : Symbol_Vectors.Vector;
      Relations : Relation_Vectors.Vector;
   end record;

end Model_Runner.Framework.Repository;
