separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Git_Status (Store : in out S.Store) is
   Said : constant Model_Runner.Framework.Git.Status_Report :=
     Model_Runner.Framework.Git.Status_Of (Here);
begin
   if not Said.Found then
      Pres.Put_Note (Screen, "cli.project.git.none");
      return;
   end if;
   Pres.Put_Header
     (Screen, "cli.project.git.branch", [Loc.Named ("name", To_String (Said.Branch))]);
   --  The changes by the task that made them, each group under its
   --  title, each change said in a word in its colour.
   declare
      Groups : Names.Vector;
      Of_Each : Names.Vector;
      State_Files : Natural := 0;

      --  A change to the project's own state, under .model_runner/.
      function Is_State (Line : String) return Boolean
      is (Line'Length > 17 and then Line (Line'First + 3 .. Line'First + 16) = ".model_runner/");
      --  A project of its own below: its state is its, said apart.
      function Is_Nested_State (Line : String) return Boolean
      is (Line'Length > 4 and then Ada.Strings.Fixed.Index (Line (Line'First + 3 .. Line'Last), "/.model_runner")
                                     > 0);

      --  Each task with when its last run ended, read once: a task
      --  whose change a later commit holds changed nothing left here.
      Ran_Tasks : Names.Vector;
      Ended     : Names.Vector;

      function Ended_At (Id : String) return String is
      begin
         for Index in Ran_Tasks.First_Index .. Ran_Tasks.Last_Index loop
            if Ran_Tasks (Index) = Id then
               return Ended (Index);
            end if;
         end loop;
         return "";
      end Ended_At;

      function Made_By (Path : String) return String is
         By        : Unbounded_String;
         Committed : constant String :=
           Model_Runner.Framework.Git.Last_Commit_At (Here, Path);
         Latest : Unbounded_String;
         Latest_At : Unbounded_String;
         --  Whose work it holds, by what it holds: that, whatever order
         --  the runs and the copies put back came in.
         Holder : constant String := Model_Runner.Framework.Work.Holder_Of (Store, Path);
      begin
         if Holder /= "" then
            return Holder;
         end if;
         for Id of Tk.List (Store) loop
            declare
               State : R.Item;
               Read  : E.Error_Info;
            begin
               S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", State, Read);
               if E.Is_Ok (Read)
                 and then Model_Runner.Framework.Lines_Of (R.Get (State, "changed_files")).Contains (Path)
                 and then (Committed = "" or else Ended_At (Id) = "" or else Ended_At (Id) > Committed)
                 --  Its work put back out of the project: not its change.
                 and then R.Get (State, "undone_by") = ""
               then
                  --  The last to change it: what is there is its, not
                  --  what an earlier one wrote over.
                  if Latest = Null_Unbounded_String or else Ended_At (Id) > To_String (Latest_At) then
                     Latest := To_Unbounded_String (Id);
                     Latest_At := To_Unbounded_String (Ended_At (Id));
                  end if;
               end if;
            end;
         end loop;
         By := Latest;
         if Latest /= Null_Unbounded_String then
            declare
               State : R.Item;
               Read  : E.Error_Info;
               Earlier : Unbounded_String;
            begin
               S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Latest) & ".state", State, Read);
               --  Joined with what an earlier task made of it: both.
               if E.Is_Ok (Read)
                 and then Model_Runner.Framework.Lines_Of (R.Get (State, "joined_files")).Contains (Path)
               then
                  for Id of Tk.List (Store) loop
                     declare
                        Other : R.Item;
                        Got   : E.Error_Info;
                     begin
                        S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", Other, Got);
                        if Id /= To_String (Latest) and then E.Is_Ok (Got)
                          and then Model_Runner.Framework.Lines_Of (R.Get (Other, "changed_files"))
                                     .Contains (Path)
                          and then R.Get (Other, "undone_by") = ""
                        then
                           Earlier := To_Unbounded_String (Id);
                        end if;
                     end;
                  end loop;
                  if Earlier /= Null_Unbounded_String then
                     By := Earlier & " and " & Latest;
                  end if;
               end if;
               --  Edited after its work was taken in: said, as not all its.
               if E.Is_Ok (Read) then
                  for Line of Model_Runner.Framework.Lines_Of (R.Get (State, "taken_in")) loop
                     declare
                        Tab : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                     begin
                        if Tab > Line'First and then Line (Line'First .. Tab - 1) = Path
                          and then Line (Tab + 1 .. Line'Last) /= ""
                          and then Line (Tab + 1 .. Line'Last)
                                   /= Model_Runner.Framework.Work.File_Print (Hostkit.Fs.Join (Here, Path))
                        then
                           Append (By, ", edited after");
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end if;
         return To_String (By);
      end Made_By;
   begin
      for Call of S.Names (Store, Model_Runner.Framework.Invocations_Area) loop
         declare
            Held : R.Item;
            Read : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Invocations_Area, Call, Held, Read);
            if E.Is_Ok (Read) and then R.Get (Held, "task") /= "" then
               if not Ran_Tasks.Contains (R.Get (Held, "task")) then
                  Ran_Tasks.Append (R.Get (Held, "task"));
                  Ended.Append (R.Get (Held, "ended_at"));
               elsif R.Get (Held, "ended_at") > Ended_At (R.Get (Held, "task")) then
                  Ended.Replace_Element (Ran_Tasks.Find_Index (R.Get (Held, "task")), R.Get (Held, "ended_at"));
               end if;
            end if;
         end;
      end loop;
      for Line of Said.Changes loop
         Of_Each.Append (Made_By (Line (Line'First + 3 .. Line'Last)));
         if not Is_State (Line) and then not Is_Nested_State (Line)
           and then not Groups.Contains (Of_Each.Last_Element)
         then
            Groups.Append (Of_Each.Last_Element);
         end if;
      end loop;
      for Group of Groups loop
         if Group = "" then
            Pres.Put_Section (Screen, "cli.project.git.by_no_task");
         else
            Pres.Put_Line (Screen, "");
            Pres.Put_Header (Screen, "cli.project.git.by_task", [Loc.Named ("name", Group)]);
         end if;
         for Index in 1 .. Natural (Said.Changes.Length) loop
            --  The project's own state: counted, said once below.
            if Is_State (Said.Changes (Index)) then
               if Group = "" then
                  State_Files := State_Files + 1;
               end if;
            elsif Is_Nested_State (Said.Changes (Index)) then
               null;
            elsif Of_Each (Index) = Group then
               declare
                  Line : constant String := Said.Changes (Index);
                  Code : constant String := Ada.Strings.Fixed.Trim (Line (Line'First .. Line'First + 1),
                                                                    Ada.Strings.Both);
                  Word : constant String :=
                    (if Code = "??" then "new"
                     elsif Ada.Strings.Fixed.Index (Code, "D") > 0 then "deleted"
                     elsif Ada.Strings.Fixed.Index (Code, "A") > 0 then "added"
                     elsif Ada.Strings.Fixed.Index (Code, "R") > 0 then "renamed"
                     else "modified");
               begin
                  Pres.Put_Row (Screen, Ada.Strings.Fixed.Head (Word, 8), Line (Line'First + 3 .. Line'Last),
                                Indent => 2,
                                Main_Tone => (if Word in "new" | "added" then Pres.Good
                                              elsif Word = "deleted" then Pres.Bad else Pres.Pending),
                                Mute_Aside => False);
               end;
            end if;
         end loop;
      end loop;
      for Line of Said.Changes loop
         if Is_Nested_State (Line) then
            Pres.Put_Row (Screen, "state   ",
                          Line (Line'First + 3 .. Line'Last)
                          & " -- the state of a project of its own there, committed with it",
                          Indent => 2, Main_Tone => Pres.Muted, Mute_Aside => False);
         end if;
      end loop;
      if State_Files > 0 then
         Pres.Put_Row (Screen, "state   ",
                       ".model_runner/ -- the project's state: " & Image (State_Files)
                       & (if State_Files = 1 then " file" else " files") & " changed",
                       Indent => 2, Main_Tone => Pres.Pending, Mute_Aside => False);
      end if;
   end;
   if Said.Changes.Is_Empty then
      Pres.Put_Note (Screen, "cli.project.git.clean");
   --  The project's state not yet in the repository at all: what it
   --  is, and how it goes in.
   elsif (for some Line of Said.Changes =>
            Line in "?? .model_runner/" | "?? .model_runner")
   then
      if To_String (Below_Top) /= "" then
         --  Typed where the session was started, below the top.
         Pres.Put_Note (Screen, "cli.next.git_state_below",
                        [Loc.Named ("path", Ada.Directories.Current_Directory)]);
      else
         Pres.Put_Note (Screen, "cli.next.git_state");
      end if;
   end if;
end Git_Status;
