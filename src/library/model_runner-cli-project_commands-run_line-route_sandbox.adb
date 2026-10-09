separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Sandbox is
begin
   if Word = "/sandbox" then
      --  The run's own confinement, below every other level: it needs
      --  no project, and lasts until changed or the session ends.
      if Natural (All_Words.Length) > 1 then
         declare
            --  All of it, constraints such as roots=src/ included.
            Said : Unbounded_String;
         begin
            for Index in 2 .. Natural (All_Words.Length) loop
               Append (Said, (if Index = 2 then "" else " ") & All_Words (Index));
            end loop;
            Model_Runner.Framework.Permissions.Set_Sandbox
              ((if To_String (Said) = "off" then "" else To_String (Said)), Outcome);
            --  A place it names that is not there: said, as a grant's is.
            if E.Is_Ok (Outcome)
              and then Model_Runner.Framework.Permissions.Missing_Places (Here, To_String (Said)) /= ""
            then
               Pres.Put_Note (Screen, "cli.project.places_missing",
                              [Loc.Named ("name", "/sandbox"),
                               Loc.Named ("detail", Model_Runner.Framework.Permissions.Missing_Places
                                                      (Here, To_String (Said)))]);
            end if;
         end;
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            return;
         end if;
      end if;
      --  A variable that does not read is refused here as work refuses
      --  it, not shown as confining to nothing.
      if Model_Runner.Framework.Permissions.Sandbox_Problem /= "" then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", Model_Runner.Framework.Permissions.Sandbox_Variable);
         E.Add_Text (Outcome, "value", Ada.Environment_Variables.Value
                                         (Model_Runner.Framework.Permissions.Sandbox_Variable));
         E.Add_Text (Outcome, "detail", Model_Runner.Framework.Permissions.Sandbox_Problem);
         Pres.Report (Screen, Outcome);
         return;
      end if;
      declare
         use type Model_Runner.Framework.Permissions.Permission_Set;
         Now : constant Model_Runner.Framework.Permissions.Permission_Set :=
           Model_Runner.Framework.Permissions.Sandbox;
      begin
         if Now = Model_Runner.Framework.Permissions.Unrestricted then
            Pres.Put_Note (Screen, "cli.project.sandbox.none");
            --  And what that is, where there is a project to say it.
            if S.Is_Initialized (".") then
               declare
                  package Pm renames Model_Runner.Framework.Permissions;
                  Store : S.Store;
                  Read  : E.Error_Info;
                  Left  : Unbounded_String;
               begin
                  S.Open_To_Read (Store, ".", Read);
                  if E.Is_Ok (Read) then
                     for Line of Model_Runner.Framework.Lines_Of
                       (Pm.Image (Pm.Effective (Store, "", "", Within_Sandbox => False)))
                     loop
                        Append (Left, (if Left = Null_Unbounded_String then "" else "; ") & Line);
                     end loop;
                     S.Close (Store);
                     Pres.Put_Message
                       (Screen, "cli.project.sandbox.effective",
                        [Loc.Named ("value", (if Left = Null_Unbounded_String then "nothing"
                                              else To_String (Left)))]);
                  end if;
               end;
            end if;
         else
            --  In the form /sandbox takes back: capabilities a ; apart.
            declare
               Shown : Unbounded_String;
            begin
               for Line of Model_Runner.Framework.Lines_Of
                 (Model_Runner.Framework.Permissions.Image (Now))
               loop
                  Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ") & Line);
               end loop;
               Pres.Put_Message
                 (Screen, "cli.project.sandbox.set",
                  [Loc.Named ("value", (if Shown = Null_Unbounded_String then "nothing"
                                        else To_String (Shown))),
                   Loc.Named ("name", Model_Runner.Framework.Permissions.Sandbox_Source)]);
               --  What that leaves agents here, the project's own
               --  permissions being below it: a sandbox grants nothing
               --  the project does not.
               if S.Is_Initialized (".") then
                  declare
                     package Pm renames Model_Runner.Framework.Permissions;
                     Store : S.Store;
                     Read  : E.Error_Info;
                     Left  : Unbounded_String;
                  begin
                     S.Open_To_Read (Store, ".", Read);
                     if E.Is_Ok (Read) then
                        for Line of Model_Runner.Framework.Lines_Of
                          (Pm.Image (Pm.Effective (Store, "", "", Within_Sandbox => True)))
                        loop
                           Append (Left, (if Left = Null_Unbounded_String then "" else "; ") & Line);
                        end loop;
                        S.Close (Store);
                        if To_String (Left) /= To_String (Shown) then
                           Pres.Put_Note
                             (Screen, "cli.project.sandbox.effective",
                              [Loc.Named ("value", (if Left = Null_Unbounded_String then "nothing"
                                                    else To_String (Left)))]);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end if;
      end;
   end if;
end Route_Sandbox;
