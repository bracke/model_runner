separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Repository is
begin
   if Word in "/scan" | "/tree" | "/sym" | "/refs" | "/deps" | "/users" | "/impact" | "/trace" then
      Command.Action := T.To_Bounded (Word (Word'First + 1 .. Word'Last));
      --  --verbose among the words: all of it, as the shell's option.
      Command.Action_Argument :=
        T.To_Bounded (if Argument (1) = "--verbose" then Argument (2) else Argument (1));
      if All_Words.Contains ("--verbose") then
         Command.Level := Opt.Verbose;
      end if;
      Model_Runner.CLI.Repo.Run (Command, Screen, Status);
      Last_Status := Status;

   end if;
end Route_Repository;
