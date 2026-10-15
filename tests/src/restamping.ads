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

   --  Record the moved digests of the groups named, the note above each.
   --
   --  Only the groups named: one note re-blessed every group that had moved,
   --  a group moved for a reason nobody had looked at -- an engine change
   --  awaiting its re-measure -- along with the one the note was about, and
   --  the staleness gate passed without anyone deciding it. A moved group
   --  not named is left as it was -- stale, so the check still fails on it
   --  -- unless All_Groups says the note is for all of them; two reasons
   --  for two sets of groups are two restamps.
   --
   --  @param Root The repository's root.
   --  @param Note Why the figures still stand, a line or several; each is
   --    written as a comment.
   --  @param Groups The groups the note is for, separated by spaces.
   --  @param All_Groups Whether the note is for every group that moved.
   --  @param Moved Groups whose digest was recorded anew.
   --  @param Good False when the record could not be read or written, names
   --    a source that is not there, or a group named is not in it; nothing
   --    is written then.
   procedure Run
     (Root       : String;
      Note       : String;
      Groups     : String;
      All_Groups : Boolean;
      Moved      : out Natural;
      Good       : out Boolean);

end Restamping;
