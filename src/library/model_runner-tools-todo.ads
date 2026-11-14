--  The to-do list a model keeps with the todo tool: the whole list each
--  call, one item a line, "[ ] " before one still to do and "[x] " before
--  one done. The session shows it to the user when a turn has changed it.
--
--  Task safety: one list, set and read by the conversation's own task.
package Model_Runner.Tools.Todo is

   --  The most items kept; past that, the rest is left out.
   Most_Items : constant := 64;

   --  The list as the model gave it, its lines read: blank ones left out,
   --  each without a mark taken as still to do.
   --
   --  @param Items The list, one item a line.
   --  @return What the model is answered: how many to do and done.
   function Set (Items : String) return String;

   --  The list, one item a line, each "[ ] " or "[x] " before it; "" where
   --  none was kept.
   function Items return String;

   --  Whether the list changed since this was last asked, and so is to be
   --  shown again.
   function Changed return Boolean;

   --  The list forgotten: a conversation started over.
   procedure Clear;

end Model_Runner.Tools.Todo;
