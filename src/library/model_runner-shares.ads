with Model_Runner.Numerics;

--  Work that can be cut into ranges, and something that can run the pieces.
--
--  THIS PACKAGE EXISTS SO THAT A CALLER CAN BE SHARED OUT WITHOUT KNOWING
--  WHAT A HOST IS. The worker pool lives in Model_Runner.Backend.CPU, which
--  asks the platform what it has and creates tasks; a package that decides
--  what a model says has no business depending on any of that. Both sides
--  depend on these two interfaces instead: the pool implements Team, the
--  work implements Work, and neither names the other.
--
--  The shape is the pool's own, unchanged. A job is a count of items, a
--  share is a contiguous range of them, and the answer must not depend on
--  where the cuts fall -- which is a property of the work rather than of
--  the team, and is the whole of what a caller has to think about before
--  handing something over. Work whose answer at an index reads that index
--  and nothing else is safe to cut anywhere. Work that reduces is not,
--  unless it reduces into a slot of its own for each item and something
--  else combines the slots in a fixed order afterwards, which is what the
--  greedy selection in Model_Runner.Sampling does.
--
--  Task safety: a team runs the pieces of one job at the same time, so a
--  Work is written by several tasks at once and must give each item its own
--  memory. Nothing here synchronizes anything; the team's own barrier is
--  what orders a piece's writes against the caller's reads afterwards.
package Model_Runner.Shares is

   subtype Element_Count is Model_Runner.Numerics.Element_Count;

   --  Something a range of items can be asked of.
   type Work is limited interface;

   --  Do the items from First to Last, inclusive.
   --
   --  @param Item The work.
   --  @param First First item of the share, zero based.
   --  @param Last Last item; Last < First is an empty share and must do
   --    nothing.
   procedure Run
     (Item : in out Work; First : Element_Count; Last : Element_Count)
   is abstract;

   type Work_Access is access all Work'Class;

   --  Something that can run the pieces of a job at the same time.
   type Team is limited interface;

   --  Cut Count items into shares and run Over across all of them.
   --
   --  Whole is the contract: True says every item from zero to Count - 1
   --  was run exactly once, so the work's own slots may be read. False says
   --  nothing may be relied on -- the team refused, or a share of it failed
   --  -- and the caller is expected to do the whole of it itself. A caller
   --  that has no team at all is in the same position and takes the same
   --  path, which is why there is no null team here: a null access is the
   --  answer and every caller already handles it.
   --
   --  @param Item The team.
   --  @param Count How many items there are.
   --  @param Over The work; referenced rather than copied, so it stays
   --    alive for the whole call.
   --  @param Whole Whether every item was run.
   --  @param Cost How much arithmetic the whole job is, in elements, or
   --    zero for unsaid. A team may do a small job on the calling task
   --    rather than waking anyone, and this is what it decides on; the
   --    answer is the same either way.
   procedure Divide
     (Item  : in out Team;
      Count : Element_Count;
      Over  : Work_Access;
      Whole : out Boolean;
      Cost  : Element_Count := 0)
   is abstract;

   type Team_Access is access all Team'Class;

   --  Which rows of a batch a product reads, counting from zero: what a
   --  mixture's expert is handed, the positions that chose it.
   type Member_Rows is array (Natural range <>) of Natural;

end Model_Runner.Shares;
