separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Repository is
begin
   if Word = "/search" then
      --  Every word after it is the query: names, paths, identifiers, words.
      Command.Action := T.To_Bounded ("search");
      --  Less --verbose, which is how much is said, not what is looked for.
      declare
         function Words_Asked return String is
            Text : Unbounded_String;
         begin
            for One of Positional loop
               if One /= "--verbose" then
                  Append (Text, (if Text = Null_Unbounded_String then "" else " ") & One);
               end if;
            end loop;
            return To_String (Text);
         end Words_Asked;
         Query : constant String := Words_Asked;
      begin
         Command.Action_Argument :=
           T.To_Bounded (Query (Query'First .. Query'First - 1 + Natural'Min (Query'Length, 400)));
      end;
      if All_Words.Contains ("--verbose") then
         Command.Level := Opt.Verbose;
      end if;
      Model_Runner.CLI.Repo.Run (Command, Screen, Status);
      Last_Status := Status;
   elsif Word in "/scan" | "/tree" | "/sym" | "/refs" | "/deps" | "/users" | "/impact" | "/trace" then
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
