with Model_Runner.CLI.Execute.Support;

--  Part of the command line's execution: see Model_Runner.CLI.Execute.
private package Model_Runner.CLI.Execute.Transcribe_Command is

   use Model_Runner.CLI.Execute.Support;

   --  The transcribe command: a recording heard by a Whisper model and what
   --  was said written to standard output -- the text, or with
   --  --speech-timestamps a line a segment with its times.
   --
   --  @param Item The command.
   --  @param Screen Where it goes.
   --  @param Status The exit status.
   procedure Do_Transcribe
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural);

end Model_Runner.CLI.Execute.Transcribe_Command;
