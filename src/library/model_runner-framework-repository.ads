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
--  declares and where those names are used, and C and C++, Rust and Python
--  have theirs in Repository.Languages.
--
--  What is found is a graph: files, units and symbols, and the relations
--  between them -- a unit is in a file, a body implements a spec, a unit
--  depends on another, a unit declares a symbol, a file refers to one.
--  Every relation says how it was derived and how sure that is: a with
--  clause is explicit and certain, a file named after its unit is a naming
--  convention and probable, a name that matches a symbol is a heuristic
--  and uncertain. What a name in the text names is not resolved, so an
--  instantiation, a derivation or an interface taken on, though written
--  out, is probable rather than certain. The graph is derived state, kept in the indexes and made
--  again whenever it is asked for and missing or stale.
package Model_Runner.Framework.Repository is

   --  What a file is for. A generated one is made by a tool from something
   --  else, and is changed by changing that and making it again.
   type File_Role is (Source, Test, Documentation, Build, Generated, Other);

   --  What a node of the graph is.
   type Node_Kind is (File_Node, Unit_Node, Symbol_Node);

   --  What a relation says.
   type Relation_Kind is
     (Contains,
      Implements,
      Depends_On,
      Declares,
      References,

      --  A subprogram or package made from a generic: X is new G.
      Instantiates,

      --  A type derived from another: type T is new Parent.
      Extends,

      --  A type that takes on an interface: ... and I.
      Implements_Interface,

      --  An operation that replaces the one it inherits: overriding. The
      --  relation names the operation, not the ancestor it came from, which
      --  is not worked out, and is uncertain for that.
      Overrides,

      --  A use of a procedure or function followed by its call: a name
      --  and then ( or ;. Found by name, so probable.
      Calls);

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

      --  Its size and when it last changed, as it was read: what tells a
      --  later scan whether it must be read again.
      Stamp       : Ada.Strings.Unbounded.Unbounded_String;
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

      --  The file whose reading found it, so that its contributions can be
      --  taken out and found again when only it changed.
      Origin : Ada.Strings.Unbounded.Unbounded_String;
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

   --  Once every file is read, so that every symbol is known: find where a
   --  file uses the names it can see.
   --
   --  @param Self The adapter.
   --  @param Path The file's path within the project.
   --  @param Text Its text.
   --  @param Into The graph, to add the references to.
   procedure Read_References
     (Self : Adapter;
      Path : String;
      Text : String;
      Into : in out Graph) is null;

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

   overriding procedure Read_References
     (Self : Ada_Adapter;
      Path : String;
      Text : String;
      Into : in out Graph);

   --  The language a file's name says it is written in.
   --
   --  @param Path The file.
   --  @return Its language, or the empty string for none this knows.
   function Language_Of (Path : String) return String;

   --  Where a project's files are, as its configuration says: the
   --  directories a scan leaves out, and those whose files are tests or
   --  documentation. An entry is a directory's name, found at any depth,
   --  or a path within the project, as src/generated; one that starts
   --  with * is part of a file's name, as *_test. for parser_test.go. A
   --  hidden file or directory is always left out, the project state and
   --  version control with it. Generated names what tools make; a file
   --  whose first lines say it was generated and is not to be edited is
   --  one too, wherever it is.
   type Roots is record
      Skip          : Name_Lists.Vector;
      Tests         : Name_Lists.Vector;
      Documentation : Name_Lists.Vector;
      Generated     : Name_Lists.Vector;
   end record;

   --  The roots a configuration that names none has: build output and
   --  dependencies left out; test, tests and testsuite, and *_test.,
   --  tests; doc and docs documentation; generated, and the files protocol
   --  buffer compilers write, generated.
   --
   --  @return The roots.
   function Default_Roots return Roots;

   --  The project's roots: set repository.skip, repository.tests,
   --  repository.documentation and repository.generated from the resolved
   --  configuration, each the default where the configuration does not set
   --  it.
   --
   --  @param Item The store.
   --  @return The roots.
   function Roots_Of (Item : Stores.Store) return Roots;

   --  A path as the project names it: relative to its directory, with
   --  ./ and a/../ taken out and a whole path into the project made
   --  relative; the project itself is the empty path. One that leads out
   --  of the project is given back with its .. or its leading /, for the
   --  caller to refuse.
   --
   --  @param Project The project's directory, whole.
   --  @param Path The path as it was typed.
   --  @return It as the project names it.
   function Relative_Path (Project, Path : String) return String;

   --  Where a component's files are, as the configuration declares them:
   --  map component.NAME = roots=src/parser/|tests/parser/.
   --
   --  @param Item The store.
   --  @param Component The component.
   --  @return Its roots; none where it declares none.
   function Component_Roots (Item : Stores.Store; Component : String) return Name_Lists.Vector;

   --  Whether a file is a component's by the roots declared for it: at or
   --  under one of them, part by part.
   --
   --  @param Item The store.
   --  @param Component The component.
   --  @param Path The file, relative to the project.
   --  @return True when it lies in one of the component's roots.
   function In_Component (Item : Stores.Store; Component, Path : String) return Boolean;

   --  What a file's place says it is for.
   --
   --  @param Path The file, within the project.
   --  @param Within The project's roots.
   --  @return Its role.
   function Role_Of (Path : String; Within : Roots := Default_Roots) return File_Role;

   --  Whether a file's own first lines say a tool made it and it is not to
   --  be edited: "generated" with "do not edit", or "@generated", or
   --  "automatically generated", in its first five lines.
   --
   --  @param Text The file's text.
   --  @return True when it says so.
   function Says_Generated (Text : String) return Boolean;

   --  Walk a project and read every file into a graph.
   --
   --  @param Project_Directory The project.
   --  @param Within The project's roots.
   --  @return The graph.
   function Scan
     (Project_Directory : String;
      Within            : Roots := Default_Roots) return Graph;

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

   --  Bring a graph up to date with the project as it is now, reading only
   --  what changed: a file whose size and time are those it was read with
   --  is taken as it was, a changed or new one is read again, a removed one
   --  taken out, and the references of every file that can see a changed
   --  unit found again. A file changed in the last two seconds is read
   --  again whatever its stamp says, since a stamp that fine is not one.
   --  What comes out is the graph Scan would make -- the same files in the
   --  same order, the same fingerprint.
   --
   --  @param Project_Directory The project.
   --  @param Kept The graph as it was last made; an empty one reads all.
   --  @param Read_Again How many files had to be read.
   --  @param Within The project's roots; a kept file whose role they
   --    change is read again.
   --  @return The graph.
   function Refresh
     (Project_Directory : String;
      Kept              : Graph;
      Read_Again        : out Natural;
      Within            : Roots := Default_Roots) return Graph;

   --  The project's graph as it is now: the kept one brought up to date,
   --  not kept -- for a reader that only reads the store.
   --
   --  @param Item The store.
   --  @return The graph.
   function Now (Item : Stores.Store) return Graph;

   --  The project's graph as it is now: the kept one brought up to date,
   --  and kept again where that changed it.
   --
   --  @param Item The store.
   --  @param Found The graph.
   --  @param Status A failure keeping it.
   procedure Current
     (Item   : in out Stores.Store;
      Found  : out Graph;
      Status : out Model_Runner.Errors.Error_Info);

   --  The fingerprint of the graph kept in the project state: known in
   --  this process once it has read or kept one, loaded otherwise.
   --
   --  @param Item The store.
   --  @return Its Graph_Fingerprint; empty when none is kept.
   function Kept_Fingerprint (Item : Stores.Store) return String;

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

   --  How many symbols a graph holds.
   --
   --  @param From The graph.
   --  @return The count.
   function Symbol_Count (From : Graph) return Natural;

   --  One of them, in the order found.
   --
   --  @param From The graph.
   --  @param Index 1 .. Symbol_Count.
   --  @return It.
   function Symbol_At (From : Graph; Index : Positive) return Symbol;

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

      --  The file being read, which every relation added meanwhile is from.
      Reading   : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Model_Runner.Framework.Repository;
