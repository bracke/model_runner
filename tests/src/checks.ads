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

   --  Which line stops a catalog loading, found by halving.
   --
   --  The runtime refuses a catalog whole: one line it cannot compile and
   --  nothing renders, with no indication of where. Each candidate is the
   --  header plus a range of lines, written with line feeds on every host;
   --  a line ended the Windows way is read as the same logical line.
   --
   --  @param Source Catalog to search.
   --  @param Scratch Where to write candidates.
   --  @return The offending line without its line ending, or the empty
   --    string when the catalog loads or when no single line accounts for
   --    it.
   function Offending_Line (Source, Scratch : String) return String;

   --  Whether a crate's build has left compilation evidence -- an .ali in
   --  one of its object directories: the two profiles', or one named after
   --  the crate, as some projects name theirs. An object directory with no
   --  .ali in it is a crate that was prepared and not compiled.
   --
   --  @param Place The crate's root directory.
   --  @param Name The crate's name, for a project whose object directory
   --    is named after it; empty for none.
   --  @return True when any compiled unit's .ali is there.
   function Compiled_Anything
     (Place : String; Name : String := "") return Boolean;

   --  What a crate's compilation evidence says about it.
   --
   --  Compiled: units of its sources were compiled here, and they are
   --  judged. Not_Built: this build did not compile it -- a crate pinned
   --  for a build-time tool that did not run, or a crate the job did not
   --  ask for -- and there is nothing here to judge. Unmatched: it was
   --  compiled, and none of what was compiled matches a source in its tree,
   --  which is a check reading the wrong place.
   type Build_Evidence is (Compiled, Not_Built, Unmatched);

   --  @param Evidence Whether the crate left compilation evidence.
   --  @param Matched Its sources that compiled units were matched to.
   --  @return What the crate's evidence says.
   function Evidence_Of
     (Evidence : Boolean; Matched : Natural) return Build_Evidence
   is (if Matched > 0 then Compiled
       elsif not Evidence then Not_Built
       else Unmatched);

   --  Run every check against a repository tree.
   --
   --  Each failure is described on standard error as it is found, so a run
   --  reports everything that is wrong rather than only the first thing.
   --
   --  @param Root Repository root directory.
   --  @param Result Totals.
   --  @param Root Repository root to read.
   --  @param Result What was performed and what failed.
   --  @param Record_Warnings Rewrite docs/dependency-warnings.txt with the
   --    counts observed on this run instead of comparing against it. For
   --    bringing a number down after a pinned crate is tidied, which
   --    otherwise means reading a failure and editing a file by hand -- and
   --    a number kept by hand is a number that drifts.
   procedure Run
     (Root             : String;
      Result           : out Report;
      Record_Warnings  : Boolean := False);

end Checks;
