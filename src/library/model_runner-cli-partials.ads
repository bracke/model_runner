--  Where a file the command line saves is written before it is renamed into
--  its place.
--
--  Beside the file, on the same filesystem, which the rename needs, and named
--  for this process and this write: one name for the file alone -- PATH and
--  ".partial" -- was shared by any two runs saving it, the prefill cache of
--  two runs of one model among them, and the second's create emptied the
--  first's before it was renamed in; their writes interleaved and either
--  rename could win.
package Model_Runner.CLI.Partials is

   --  A name beside Path no other write uses: Path, this process's
   --  number, a count of this process's writes, and ".partial".
   --
   --  @param Path The file to be written.
   --  @return The name to write it under first.
   function Beside (Path : String) return String;

end Model_Runner.CLI.Partials;
