--  Worked examples for the chat-template rows of the support matrix.
--
--  The matrix is what a reader consults to find out whether their model's
--  template will render, and it was hand-maintained: a table of claims beside
--  the code rather than about it. The formats and the tokenizer vocabularies
--  are asked of the code now; this was the largest registry left that nobody
--  could check.
--
--  Nothing here can invent a row for a construct somebody adds. What it does
--  is stop a row from outliving what it says: every row must have an example
--  with exactly its label, and every example is compiled and rendered and
--  must end the way its row claims. A construct that moves out of the subset
--  fails; one that moves in fails while its row still says it is refused,
--  which is what happened when `set` and the filters arrived and the table
--  went on saying they were rejected.
package Template_Registry is

   --  What running an example does.
   type Outcome is
     (Works,               --  compiles and renders
      Refused_At_Compile,  --  the shape cannot be read
      Refused_At_Render);  --  the value cannot be computed

   type Text_Access is access constant String;

   type Example is record
      --  The row's first cell, character for character. Editing one means
      --  editing the other, which is the point: a label nobody can find is a
      --  row nobody checked.
      Label  : Text_Access;
      Source : Text_Access;
      State  : Outcome;
   end record;

   --  Number of examples.
   --
   --  @return How many examples this registry holds.
   function Count return Natural;

   --  One example.
   --
   --  @param Index Position, from one.
   --  @return The example at that position.
   function Item (Index : Positive) return Example;

   --  Compile and render an example, and report what happened.
   --
   --  @param Source Template text.
   --  @param Detail Error code name when it was refused, empty otherwise.
   --  @return Where it ended.
   function Run (Source : String; Detail : out Text_Access) return Outcome;

end Template_Registry;
