--  Build and check a clone of what git carries.
--
--  The repository is not the working tree. A file that is ignored, generated
--  or simply never committed is present here and absent for everyone else,
--  and the difference is invisible from inside: three tests read a model
--  from `fixtures/`, that path is ignored on purpose, and the suite passed
--  here and failed on every clean checkout for forty consecutive pushes
--  before anybody read the runner's log.
--
--  This does what the README describes and what continuous integration does:
--  clone the repository beside its siblings, so the path pins resolve
--  without anything being copied or linked, then build and run the suite and
--  the repository checks in that clone. It needs git and Alire; it fetches
--  nothing, because every pin is a path.
--
--  It is a command rather than a step in the release checklist because it
--  rebuilds the world -- minutes, not seconds -- and because the checklist
--  runs on a machine that already has the tree. Run it before a release, and
--  after anything that changes what the suite reads.
--
--  Task safety: run from one task.
package Pristine is

   --  What the run found.
   type Report is record
      Ran     : Boolean := False;
      Detail  : String (1 .. 200) := [others => ' '];
      Used    : Natural := 0;
      Where   : String (1 .. 400) := [others => ' '];
      Where_L : Natural := 0;
   end record;

   --  Clone, build, and check.
   --
   --  @param Root Repository to clone; the clone is made beside it so that
   --    the sibling pins resolve.
   --  @param Result What happened, and where the clone was left.
   procedure Run (Root : String; Result : out Report);

   --  One line describing what happened.
   --
   --  @param Item Report to describe.
   --  @return Human-readable summary.
   function Summary (Item : Report) return String;

end Pristine;
