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
   function Users_Of_File (Store : Stores.Store; Path : String) return String;

   --  A question to the graph, as a tool call: find_symbol and
   --  find_references take name, dependencies and dependents unit -- a unit
   --  or a file -- and impact target -- a file or a name.
   --
   --  @param Store The store.
   --  @param Named The question.
   --  @param Args Its arguments, a JSON object.
   --  @param Failed Whether the call could not be asked: its argument missing.
   --  @return The answer, in lines; saying so where the graph has nothing.
   function Answer
     (Store  : Stores.Store;
      Named  : String;
      Args   : String;
      Failed : out Boolean) return String;

end Model_Runner.Framework.Code_Queries;
