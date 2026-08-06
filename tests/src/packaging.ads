--  Assemble a distributable archive.
--
--  What ships is the executable, the message catalog it looks for beside
--  itself, and the documents that say what the program is and what it does
--  not do. The layout inside the archive is the layout `alr install` writes,
--  so unpacking it over a prefix gives a working installation:
--
--     model_runner-<version>/
--        bin/model_runner
--        share/model_runner/messages/catalog.txt
--        LICENSE  README.md  CHANGELOG.md  SECURITY.md
--
--  The archive is a plain USTAR tar written by tarlib. Nothing is compressed
--  and nothing is fetched: this is an assembly step, not a build and not a
--  download.
--
--  It refuses rather than guesses. A missing executable, a missing catalog or
--  an unreadable file stops the run and says which, because an archive that is
--  quietly incomplete is worse than none: it fails at the far end, on someone
--  else's machine.
--
--  Task safety: run from one task.
package Packaging is

   --  Write the archive.
   --
   --  @param Root Project root holding bin, resources and the documents.
   --  @param Target Directory to write the archive into.
   --  @param Written True when the archive was completed.
   procedure Run (Root : String; Target : String; Written : out Boolean);

end Packaging;
