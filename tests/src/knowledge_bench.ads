--  What the knowledge layer costs, on a project made for it.
--
--  A project of many tasks, source files and observations is made fresh
--  under obj/knowledge-bench, and the operations that grow with it timed:
--  the effective view of a task (its readiness scans every task), a
--  context built with its retrieval worked out and with it used again,
--  recording an observation (each is matched against those kept), and the
--  pages of what was learned made again with nothing changed. Each is the
--  best of three, after the files are old enough for what is read of them
--  to be remembered against their stamps.
package Knowledge_Bench is

   --  Make the project and say what each operation took.
   --
   --  @param Tasks How many tasks the project holds.
   --  @param Files How many source files.
   --  @param Observations How many observations.
   procedure Run (Tasks, Files, Observations : Positive);

end Knowledge_Bench;
