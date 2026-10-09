with Model_Runner.Tools.Runner;
with Model_Runner.Tools.Schemas;

--  Every tool the harness can offer a model, described once.
--
--  A tool is a descriptor: its name, its definition -- what a model is told
--  of it, built from Tools.Schemas -- what its call does to the state later
--  calls read, and the capability it needs. What an agent is offered is not
--  every tool with the unavailable ones refused at the call, and not a list
--  each way of running an agent keeps for itself: it is the tools whose
--  capability the agent's environment has, selected here. run's agent and
--  /work's agents are offered from this one registry, and the approval that
--  fences /work asks it whether a call is one the agent may make.
--
--  The set offered is kept small on purpose. A local model choosing among
--  twenty similar tools spends its capacity telling them apart, so one tool
--  reads a file whole or by its lines, and one finds -- text in a file or a
--  tree, a name's declaration, its uses, what a unit uses and what uses it,
--  what a change reaches -- by the kind of finding asked for. The narrower
--  tools those replaced are still run when a model calls one by name; they
--  are not offered.
--
--  Task safety: no state.
package Model_Runner.Tools.Registry is

   --  What a tool needs of the environment that offers it.
   type Capability is
     (Facts,          --  the four answers that need nothing: sums, lengths, a lookup
      Text,           --  text transformed: base64
      Clock,          --  the time of day
      Memory,         --  a scratchpad kept across calls
      Read_Files,     --  reading the files of the tree
      Write_Files,    --  changing them
      Run_Programs,   --  starting a program
      Network,        --  the web
      Retrieval,      --  ranking a folder's passages
      Ask_User,       --  somebody to put a question to
      Delegation,     --  a helper to hand part of the work to
      Project_Graph,  --  a project's repository graph to ask of its code
      Project_Checks  --  a project's checks to run
     );

   type Capabilities is array (Capability) of Boolean;

   Nothing : constant Capabilities := [others => False];

   --  The tools a capability set is offered, as a JSON array in the order a
   --  model is best shown them -- reading before writing, finding before
   --  both, the narrow tools last.
   --
   --  @param Can What the environment can do.
   --  @param Roles The roles a helper may be given, where delegation takes
   --    one from a project's configuration; empty for any.
   --  @return The definitions.
   function Offered
     (Can   : Capabilities;
      Roles : Schemas.Choice_Lists.Vector := Schemas.Choice_Lists.Empty_Vector) return String;

   --  Whether a tool is one the harness knows, offered or run by name.
   --
   --  @param Named The tool.
   --  @return Whether it is.
   function Known (Named : String) return Boolean;

   --  What a known tool needs.
   --
   --  @param Named The tool, known.
   --  @return Its capability.
   function Needs (Named : String) return Capability
   with Pre => Known (Named);

   --  Whether an environment may make a call to a tool: it is known, and
   --  its capability is the environment's.
   --
   --  @param Can What the environment can do.
   --  @param Named The tool.
   --  @return Whether the call may be made.
   function Allows (Can : Capabilities; Named : String) return Boolean;

   --  What a call to a tool does to the state later calls read: Reads for
   --  the reading, finding and asking tools, Varies for the clock, Changes
   --  for the rest -- and for a tool not known.
   --
   --  @param Named The tool.
   --  @return Its kind.
   function Kind_Of (Named : String) return Runner.Call_Kind;

   --  Whether a kind of finding find takes is one that asks the project's
   --  graph, rather than searching text.
   --
   --  @param Kind The kind.
   --  @return Whether it asks the graph.
   function Graph_Finding (Kind : String) return Boolean is
     (Kind in "symbol" | "references" | "uses" | "used_by" | "impact");

end Model_Runner.Tools.Registry;
