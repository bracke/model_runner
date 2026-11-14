with Model_Runner.Presentation;
with Model_Runner.Text;

--  The conversations kept: every conversation is written to a file of its
--  own as it goes, so it can be taken up again -- the latest with
--  --continue, any with --resume.
--
--  They are kept under conversations-dir, MODEL_RUNNER_CONVERSATIONS where
--  it is set, else model_runner's data home's conversations folder. A
--  conversation is the file /save writes, named for when it began and the
--  model it began with; beside it, NAME.model holds the path of the model
--  it was last spoken with, so taking it up starts that one again.
package Model_Runner.CLI.Conversations is

   --  Where conversations are kept, or "" where no home is known.
   function Directory return String;

   --  A new conversation's file: the folder made, the name the time it
   --  began and the model's name. "" where there is no folder.
   --
   --  @param Model The model's path or name.
   --  @return The path to write it to.
   function New_Path (Model : String) return String;

   --  Note the model a conversation was last spoken with, beside it.
   --
   --  @param Conversation The conversation's file.
   --  @param Model The model's path.
   procedure Note_Model (Conversation, Model : String);

   --  The model noted beside a conversation, or "" where none was.
   --
   --  @param Conversation The conversation's file.
   --  @return The model's path.
   function Model_Of (Conversation : String) return String;

   --  The conversation written last, or "" where there is none.
   function Latest return String;

   --  The conversations kept, newest first, in the shared selector: when
   --  each began, its model and its first message.
   --
   --  @param Screen Where the list goes.
   --  @param Path The chosen conversation's file.
   --  @param Picked Whether one was chosen.
   procedure Choose
     (Screen : Model_Runner.Presentation.Console;
      Path   : out Model_Runner.Text.Bounded;
      Picked : out Boolean);

end Model_Runner.CLI.Conversations;
