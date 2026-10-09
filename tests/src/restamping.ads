--  Record the fingerprints docs/measured-figures.txt keeps, where a change
--  is known not to move what they stand for.
--
--  Each figure group's line names its sources and the digest they had when
--  the figures were taken, and the repository check fails when they no
--  longer have it. Most such failures ask for the figures to be taken
--  again. Some do not: a change that touches a source but no path a figure
--  was measured on -- an option only a named flag reaches, a comment --
--  leaves the figures true, and what the record wants is the new digest
--  and a line saying why it was not measured again. This writes both,
--  for every group whose digest moved, with the reason given above each.
--
--  Task safety: one call at a time; it rewrites a file.
package Restamping is

   --  Record every moved digest, the note above each.
   --
   --  @param Root The repository's root.
   --  @param Note Why the figures still stand, a line or several; each is
   --    written as a comment.
   --  @param Moved Groups whose digest was recorded anew.
   --  @param Good False when the record could not be read or written, or
   --    names a source that is not there; nothing is written then.
   procedure Run
     (Root  : String;
      Note  : String;
      Moved : out Natural;
      Good  : out Boolean);

end Restamping;
