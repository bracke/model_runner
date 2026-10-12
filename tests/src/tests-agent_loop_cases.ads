with AUnit;
with Tests.Fresh_Cases;

--  Tests for the agent loop itself, held to a script of replies.
--
--  The tiny model renders each turn as a model's conversation is rendered,
--  and the replies are taken from a script instead of generated (Agent.Run's
--  Script), so what the loop does with a reply -- the calls it runs, the
--  notes it adds after them, what it refuses as a repeat, what it carries
--  from one run to the next, which calls it asks its approver about -- is
--  asserted without weights that could write the reply.
package Tests.Agent_Loop_Cases is

   type Case_Type is new Tests.Fresh_Cases.Fresh_Case with null record;

   --  Name shown by the reporter.
   --
   --  @param T Test case instance.
   --  @return Case name.
   overriding function Name (T : Case_Type) return AUnit.Message_String;

   --  Register the routines of this case.
   --
   --  @param T Test case instance.
   overriding procedure Register_Tests (T : in out Case_Type);

end Tests.Agent_Loop_Cases;
