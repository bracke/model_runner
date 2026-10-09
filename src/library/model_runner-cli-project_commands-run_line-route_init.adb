separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Init is
begin
   if Word = "/init" then
      --  --directory DIR as the shell takes it: the project started
      --  there, the template the word that is neither.
      declare
         Template : Unbounded_String;
         Index    : Positive := 1;
      begin
         while Index <= Natural (Positional.Length) loop
            if Positional (Index) = "--directory" and then Index < Natural (Positional.Length) then
               Command.Project_Directory := T.To_Bounded (Positional (Index + 1));
               Index := Index + 2;
            elsif Ada.Strings.Fixed.Head (Positional (Index), 12) = "--directory="
              and then Positional (Index) /= "--directory="
            then
               Command.Project_Directory := T.To_Bounded
                 (Ada.Strings.Fixed.Delete (Positional (Index), 1, 12));
               Index := Index + 1;
            elsif Template = Null_Unbounded_String then
               Template := To_Unbounded_String (Positional (Index));
               Index := Index + 1;
            else
               --  One template; an input is NAME=VALUE.
               Outcome := E.Make (E.CLI_Unexpected_Operand);
               E.Add_Text (Outcome, "value", Positional (Index) & "; /init takes one template, and"
                           & " each input as NAME=VALUE");
               Pres.Report (Screen, Outcome);
               return;
            end if;
         end loop;
         Command.Template_Name := T.To_Bounded (To_String (Template));
      end;
      --  A directory named relative is from where the session was
      --  started, as completion and /bootstrap take it.
      declare
         Given : constant String := T.To_String (Command.Project_Directory);
      begin
         if Given /= "" and then Given (Given'First) not in '/' | '~' and then To_String (Below_Top) /= "" then
            Command.Project_Directory := T.To_Bounded (Hostkit.Fs.Join (To_String (Below_Top), Given));
         end if;
      end;
      --  One whose parent is not there either: a mistyped path, refused.
      declare
         Given : constant String := T.To_String (Command.Project_Directory);
      begin
         if Given /= "" and then not Ada.Directories.Exists (Given)
           and then not Ada.Directories.Exists (Ada.Directories.Containing_Directory
                                                  (Ada.Directories.Full_Name (Given)))
         then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "--directory");
            E.Add_Text (Outcome, "value", Ada.Directories.Full_Name (Given));
            E.Add_Text (Outcome, "detail", "neither it nor the directory it would be in is there; nothing was"
                        & " initialized");
            Pres.Report (Screen, Outcome);
            return;
         end if;
      exception
         when others =>
            null;
      end;
      --  Started below a project's top, which has its state: a project
      --  of its own is made where the session was started -- said once
      --  it is, not before a cancel.
      declare
         Below : constant Boolean :=
           T.Is_Empty (Command.Project_Directory) and then To_String (Below_Top) /= ""
           and then S.Is_Initialized (Here)
           and then not S.Is_Initialized (To_String (Below_Top));
      begin
         if Below then
            Command.Project_Directory := T.To_Bounded (To_String (Below_Top));
         end if;
         Model_Runner.CLI.Init.Run (Command, Screen, Status);
         if Below and then Status = 0 and then S.Is_Initialized (To_String (Below_Top)) then
            Pres.Put_Note (Screen, "cli.init.below_top", [Loc.Named ("path", To_String (Below_Top))]);
         end if;
      end;
      Last_Status := Status;
      --  No project here, and one made where --directory named: the
      --  session works on that one, as it would have started there.
      if Status = 0 and then not S.Is_Initialized (Here) and then not T.Is_Empty (Command.Project_Directory)
        and then S.Is_Initialized (T.To_String (Command.Project_Directory))
      then
         declare
            There : constant String := Ada.Directories.Full_Name (T.To_String (Command.Project_Directory));
         begin
            Ada.Directories.Set_Directory (There);
            Below_Top := Null_Unbounded_String;
            Pres.Put_Note (Screen, "cli.project.found_above", [Loc.Named ("path", There)]);
            Recover_Here (Screen);
         exception
            when others =>
               null;
         end;
      --  No project here, and one made above: the session works on it,
      --  as it would have started on it.
      elsif Status = 0 and then not S.Is_Initialized (Here) then
         Recover_Here (Screen);
      end if;

   --  Several tasks named for one move: each moved as if named alone,
   --  and the next step said once, after the last.
   end if;
end Route_Init;
