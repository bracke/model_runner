with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Stores;

--  The questions a working agent asks of the project's code, answered from
--  its repository graph as it is now -- brought up to date before each
--  answer, so one asked after a write is about the code as written. The
--  harness does the finding; the model is told what was found.
--
--  Task safety: each call reads the store and the files; no state is kept.
package Model_Runner.Framework.Code_Queries is

   --  The units a file declares, as the graph knows them: its packages, or
   --  the file itself where it declares none.
   --
   --  @param Graph The graph.
   --  @param Path The file, within the project.
   --  @return The units.
   function Units_Of_File
     (Graph : Repository.Graph;
      Path  : String) return Name_Lists.Vector;

   --  What uses a file's units, comma-separated; "" for nothing.
   --
   --  @param Store The store.
   --  @param Path The file, within the project.
   --  @return The units that use it, at most twenty.
   --  @param Root The tree the agent works in -- a workspace's -- whose
   --    graph is asked; "" for the project's.
   function Users_Of_File (Store : Stores.Store; Path : String; Root : String := "") return String;

   --  The graph a question is asked of: the project's as it is now, or,
   --  for a tree of its own -- a workspace the work is done in -- that
   --  tree's, scanned the first time and brought up to date after, so an
   --  answer is about the code the agent sees and changes.
   --
   --  @param Store The store.
   --  @param Root The tree; "" for the project's.
   --  @return The graph.
   function Graph_Of (Store : Stores.Store; Root : String) return Repository.Graph;

   --  A question to the graph, as a tool call: find_symbol and
   --  find_references take name, dependencies and dependents unit -- a unit
   --  or a file -- and impact target -- a file or a name.
   --
   --  @param Store The store.
   --  @param Named The question.
   --  @param Args Its arguments, a JSON object.
   --  @param Failed Whether the call could not be asked: its argument missing.
   --  @return The answer, in lines; saying so where the graph has nothing.
   --  @param Root The tree the agent works in; "" for the project's.
   function Answer
     (Store  : Stores.Store;
      Named  : String;
      Args   : String;
      Failed : out Boolean;
      Root   : String := "") return String;

   --  What the find tool's search and declaration kinds answer, bounded:
   --  search, the hits Retrieval.Search ranks for a query, each with where
   --  it is, its score and why, and how far it is to be taken as said;
   --  declaration, the lines of a name's declarations, of the declaration
   --  holding PATH:LINE, or of the lines a reference PATH:FIRST-LAST@PRINT
   --  names -- refused where that file has changed since. Lines are shown
   --  numbered, as read_file shows them, under where they are from.
   --
   --  @param Store The store.
   --  @param Kind search or declaration.
   --  @param Query What is asked.
   --  @param Root The tree the files are read from; "" for the project's.
   --  @param Records Whether records may be searched.
   --  @param Failed Whether it could not be asked or found nothing to show.
   --  @return The answer, at most Answer_Most characters.
   function Retrieve
     (Store   : Stores.Store;
      Kind    : String;
      Query   : String;
      Root    : String;
      Records : Boolean;
      Failed  : out Boolean) return String;

   --  The most a search or declaration answer says.
   Answer_Most : constant := 12_000;

   --  A finding by its kind, as the find tool asks it: symbol, references,
   --  uses, used_by or impact, of a query -- a name, a unit, a file; or
   --  search and declaration, as Retrieve answers them for the project.
   --
   --  @param Store The store.
   --  @param Kind The kind of finding.
   --  @param Query What it is of.
   --  @param Failed Whether it could not be asked: no query, or a kind
   --    that is none of these.
   --  @return The answer.
   --  @param Root The tree the agent works in; "" for the project's.
   function Find
     (Store  : Stores.Store;
      Kind   : String;
      Query  : String;
      Failed : out Boolean;
      Root   : String := "") return String;

end Model_Runner.Framework.Code_Queries;
