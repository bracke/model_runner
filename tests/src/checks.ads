--  Repository and dependency-boundary checks.
--
--  These are the checks that keep the architecture honest between reviews: the
--  layering rules, the crate structure, the absence of scripting-language
--  tooling and the agreement between the version in the manifest and the
--  version in the code. They are Ada, they live in the tests crate, and they
--  read the repository as data.
--
--  Task safety: a run uses one task.
package Checks is

   --  Totals for a run.
   type Report is record
      Performed : Natural := 0;
      Failed    : Natural := 0;
   end record;

   --  Report whether every check passed.
   --
   --  @param Item Report to classify.
   --  @return True when nothing failed.
   function Is_Clean (Item : Report) return Boolean is (Item.Failed = 0);

   --  Run every check against a repository tree.
   --
   --  Each failure is described on standard error as it is found, so a run
   --  reports everything that is wrong rather than only the first thing.
   --
   --  @param Root Repository root directory.
   --  @param Result Totals.
   procedure Run (Root : String; Result : out Report);

end Checks;
