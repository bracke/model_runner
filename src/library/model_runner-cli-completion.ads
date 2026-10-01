with Model_Runner.Framework;

--  What Tab completes at the session's prompt: a command's word, its
--  actions, and what it is given -- a task's, a requirement's or a
--  decision's identifier, a setting's name, a capability, a kind of task,
--  a template, a kept copy, a file -- from the project as it stands here.
package Model_Runner.CLI.Completion is

   --  The words the last word of a line may be completed to.
   --
   --  @param Before What is typed before the cursor.
   --  @return Each whole word the last word of Before begins, sorted, each
   --    once; empty where nothing fits.
   function Candidates (Before : String) return Model_Runner.Framework.Name_Lists.Vector;

end Model_Runner.CLI.Completion;
