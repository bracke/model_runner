with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Model_Runner.CLI.Interactive;
with Model_Runner.CLI.Intents;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.Errors;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Platform;

package body Model_Runner.CLI.Completion is

   package Names renames Model_Runner.Framework.Name_Lists;
   package E renames Model_Runner.Errors;
   package S renames Model_Runner.Framework.Stores;
   package Nt renames Model_Runner.Framework.Intent;
   package Tk renames Model_Runner.Framework.Tasks;
   package R renames Model_Runner.Framework.Records;

   package Sorting is new Names.Generic_Sorting;

   --  The project's own commands, beside the session's.
   Project_Commands : constant String :=
     " /init /bootstrap /state /config /reconfigure /task /accept /reject /work /cancel /check /req /decision"
     & " /spec /result /scan /tree /sym /refs /deps /users /impact /trace /git /sandbox /instruct ";

   --  Words a space apart, as a list.
   function Words_Of (Text : String) return Names.Vector is
      Result : Names.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ' ' then
            if Index > Start then
               Result.Append (Text (Start .. Index - 1));
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Words_Of;

   --  The actions each command takes as its second word.
   function Actions_Of (Command : String) return String
   is (if Command = "/task"
       then "list new show accept reject cancel reopen reconsider complete verify diff integrate kept edit note"
            & " grant withhold link depend split rehome move plan derive audit context"
       elsif Command = "/req"
       then "list new show accept reject reconsider obsolete verify revise renumber link unlink supersede move block"
            & " unblock"
       elsif Command in "/spec" | "/decision"
       then "list new show accept reject reconsider obsolete revise renumber link unlink supersede govern"
       elsif Command = "/reconfigure" then "add remove"
       elsif Command = "/result" then "dismiss dismissed restore"
       elsif Command = "/instruct" then "withdraw"
       elsif Command = "/sandbox" then "on off"
       elsif Command = "/check" then "consistency"
       else "");

   --  Every file and directory under a path's directory that its last part
   --  begins: a directory with its slash, to go on into.
   function Paths (Prefix : String) return Names.Vector is
      Result : Names.Vector;
      Slash  : constant Natural := Ada.Strings.Fixed.Index (Prefix, "/", Ada.Strings.Backward);
      Dir    : constant String := (if Slash = 0 then "" else Prefix (Prefix'First .. Slash));
      --  Where the session was started, below the project's top: what is
      --  typed is from there, as the commands take it.
      Below  : constant String := Model_Runner.CLI.Project_Commands.Started_Below;
      --  ../ is from where the session was started, always.
      Up     : constant Boolean := Dir'Length >= 2 and then Dir (Dir'First .. Dir'First + 1) = "..";
      Where  : constant String :=
        (if Below /= "" and then Ada.Directories.Exists (Below & "/" & (if Dir = "" then "." else Dir))
           and then (Up or else not (Dir /= "" and then Ada.Directories.Exists (Dir)))
         then Below & "/" & (if Dir = "" then "." else Dir)
         elsif Dir = "" then "." else Dir);
      --  Nothing outside the project is one of its files.
      Inside : constant Boolean :=
        not Up
        or else (Ada.Directories.Exists (Where)
                 and then Ada.Strings.Fixed.Index (Ada.Directories.Full_Name (Where) & "/",
                                                   Ada.Directories.Current_Directory & "/") = 1);
      Search : Ada.Directories.Search_Type;
      Found  : Ada.Directories.Directory_Entry_Type;
   begin
      if not Ada.Directories.Exists (Where) or else not Inside then
         return Result;
      end if;
      Ada.Directories.Start_Search (Search, Where, "");
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found);
         declare
            Simple : constant String := Ada.Directories.Simple_Name (Found);
         begin
            if Simple not in "." | ".." and then (Simple (Simple'First) /= '.' or else Prefix'Length > Dir'Length)
            then
               Result.Append (Dir & Simple
                              & (if Ada.Directories."=" (Ada.Directories.Kind (Found), Ada.Directories.Directory)
                                 then "/" else ""));
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      return Result;
   exception
      when others =>
         return Result;
   end Paths;

   --  The values a setting takes, where they are a few words: what Tab
   --  offers after its =.
   function Values_Of (Name : String) return Names.Vector is
      Bare : constant String :=
        (if Ada.Strings.Fixed.Index (Name, "scalar.") = Name'First then Name (Name'First + 7 .. Name'Last)
         else Name);
      Result : Names.Vector;
   begin
      if Ada.Strings.Fixed.Index (Bare, "permission.") > 0 then
         --  A capability: on, off, as the level above, or its places; a
         --  level whole: none, or as the level above.
         if (for some One in Model_Runner.Framework.Permissions.Capability =>
               Ada.Strings.Fixed.Tail (Bare, Model_Runner.Framework.Permissions.Word (One)'Length + 1)
               = "." & Model_Runner.Framework.Permissions.Word (One))
         then
            --  What the capability takes: places for reading and writing,
            --  bounds for helpers, profiles for checks.
            declare
               Word : constant String := Bare (Ada.Strings.Fixed.Index (Bare, ".", Ada.Strings.Backward) + 1
                                               .. Bare'Last);
            begin
               Result := Words_Of
                 ("on off inherit"
                  & (if Word in "read_source" | "write_source" | "read_specs" | "write_specs" then " roots= deny="
                     elsif Word = "create_children" then " max_depth= max_children="
                     elsif Word in "run_build" | "run_tests" | "run_static_analysis" then " profiles="
                     else ""));
            end;
         else
            Result := Words_Of ("none inherit");
         end if;
      elsif Bare = "work.isolation" or else Ada.Strings.Fixed.Index (Bare, "task.isolation.") = Bare'First then
         Result := Words_Of ("project workspace");
      elsif Bare = "task.auto_accept" then
         Result := Words_Of ("true false");
      elsif Bare = "task.coordination" or else Ada.Strings.Fixed.Index (Bare, "task.coordination.") = Bare'First
      then
         Result := Words_Of ("parent_waits parent_runs");
      elsif Bare = "agents.on_child_failure" then
         Result := Words_Of ("block fail continue");
      elsif Bare = "verification.escalation" then
         Result := Words_Of ("conservative narrow");
      elsif Bare = "bootstrap.import" then
         Result := Words_Of ("candidate accepted");
      elsif Bare in "execution.network" | "execution.shell" then
         Result := Words_Of ("allowed denied");
      elsif Bare = "verification.toolchain" then
         Result := Words_Of ("recorded strict");
      elsif Bare = "recovery.running" then
         Result := Words_Of ("blocked failed accepted");
      elsif Bare = "requirement.after_text_change" then
         Result := Words_Of ("accepted blocked");
      elsif Bare = "requirement.after_criteria_change" then
         Result := Words_Of ("implemented accepted");
      end if;
      return Result;
   end Values_Of;

   --  Whether a template is only a part others include: standalone = false.
   function Is_Part (Path : String) return Boolean is
      File : Ada.Text_IO.File_Type;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
         begin
            if Ada.Strings.Fixed.Index (Line, "standalone") = Line'First
              and then Ada.Strings.Fixed.Index (Line, "false") > 0
            then
               Ada.Text_IO.Close (File);
               return True;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      return False;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return False;
   end Is_Part;

   function Candidates (Before : String) return Names.Vector is
      Words   : constant Names.Vector := Words_Of (Before);
      --  The word being completed: the last, or a new one after a space.
      Fresh   : constant Boolean := Before = "" or else Before (Before'Last) = ' ';
      Current : constant String := (if Fresh or else Words.Is_Empty then "" else Words.Last_Element);
      Position : constant Positive := Natural (Words.Length) + (if Fresh then 1 else 0);
      Command : constant String :=
        (if Words.Is_Empty then "" else Ada.Characters.Handling.To_Lower (Words.First_Element));
      Action  : constant String := (if Natural (Words.Length) >= 2 then Words (2) else "");
      Offered : Names.Vector;
      Result  : Names.Vector;

      procedure Offer (Word : String) is
      begin
         if not Offered.Contains (Word) then
            Offered.Append (Word);
         end if;
      end Offer;

      procedure Offer_All (Listed : Names.Vector) is
      begin
         for One of Listed loop
            Offer (One);
         end loop;
      end Offer_All;

      procedure Offer_Words (Text : String) is
      begin
         Offer_All (Words_Of (Text));
      end Offer_Words;

      --  What the project holds, where there is one here.
      procedure From_Project is
         Store : S.Store;
         Read  : E.Error_Info;

         function Register (Prefix : String) return Nt.Intent_Kind
         is (if Prefix = "/req" then Nt.Requirement elsif Prefix = "/spec" then Nt.Specification
             else Nt.Decision);

         procedure Settings is
            package Pm renames Model_Runner.Framework.Permissions;
            Config : R.Item;
            Got    : E.Error_Info;
            Before : constant Natural := Natural (Offered.Length);
         begin
            Offer_All (Model_Runner.Framework.Configurations.Known_Names);
            Model_Runner.Framework.Configurations.Read (Store, Config, Got);
            if E.Is_Ok (Got) then
               for Index in 1 .. R.Field_Count (Config) loop
                  if (for some Prefix of Names.Vector'(["scalar.", "set.", "list.", "map.", "profile."]) =>
                        Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), Prefix) = 1)
                  then
                     Offer (R.Field_Name (Config, Index));
                  end if;
               end loop;
            end if;
            --  Those there may be, set or not: every level's capability,
            --  and every kind's own limits and profile.
            Offer ("map.permission.project");
            Offer ("map.permission.role.worker");
            Offer ("map.model.default");
            for One in Pm.Capability loop
               Offer ("map.permission.project." & Pm.Word (One));
            end loop;
            for Kind of Tk.Kinds (Store) loop
               Offer ("map.permission.kind." & Kind);
               for One in Pm.Capability loop
                  Offer ("map.permission.kind." & Kind & "." & Pm.Word (One));
               end loop;
               for Limit of Names.Vector'
                 (["max_seconds", "max_tool_calls", "max_steps", "token_budget", "profile", "coordination",
                   "isolation"])
               loop
                  Offer ("scalar.task." & Limit & "." & Kind);
               end loop;
            end loop;
            --  Typed without its kind -- work.isolation -- as the commands
            --  take it: offered so too.
            if Current /= ""
              and then not (for some Prefix of Names.Vector'(["scalar.", "set.", "list.", "map."]) =>
                              Prefix'Length <= Current'Length
                              and then Current (Current'First .. Current'First + Prefix'Length - 1) = Prefix)
            then
               for Index in Before + 1 .. Natural (Offered.Length) loop
                  declare
                     Name : constant String := Offered (Index);
                     Dot  : constant Natural := Ada.Strings.Fixed.Index (Name, ".");
                  begin
                     if Dot > 0 and then Name (Name'First .. Dot) in "scalar." | "set." | "list." | "map." then
                        Offer (Name (Dot + 1 .. Name'Last));
                     end if;
                  end;
               end loop;
            end if;
         end Settings;

         --  The model profiles the configuration names: map.model.ID.
         function Profiles return Names.Vector is
            Config : R.Item;
            Got    : E.Error_Info;
            --  The built-in one is there whether named or not.
            Result : Names.Vector := ["default"];
         begin
            Model_Runner.Framework.Configurations.Read (Store, Config, Got);
            if E.Is_Ok (Got) then
               for Index in 1 .. R.Field_Count (Config) loop
                  declare
                     Field : constant String := R.Field_Name (Config, Index);
                  begin
                     if Ada.Strings.Fixed.Index (Field, "map.model.") = Field'First
                       and then Field /= "map.model.default"
                     then
                        Result.Append (Field (Field'First + 10 .. Field'Last));
                     end if;
                  end;
               end loop;
            end if;
            return Result;
         end Profiles;

         procedure Capabilities is
         begin
            for One in Model_Runner.Framework.Permissions.Capability loop
               Offer (Model_Runner.Framework.Permissions.Word (One));
            end loop;
         end Capabilities;
      begin
         if not S.Is_Initialized (Ada.Directories.Current_Directory) then
            return;
         end if;
         S.Open_To_Read (Store, Ada.Directories.Current_Directory, Read);
         if E.Is_Error (Read) then
            return;
         end if;
         --  A setting as NAME=: its values where it has a few.
         if (Command = "/reconfigure" or else (Command in "/spec" | "/decision" and then Action = "govern"
                                                and then Position >= 4))
           and then Ada.Strings.Fixed.Index (Current, "=") > Current'First
           and then Ada.Strings.Fixed.Index (Current, "model=") /= Current'First
         then
            declare
               Eq   : constant Natural := Ada.Strings.Fixed.Index (Current, "=");
               Name : constant String := Current (Current'First .. Eq - 1);
            begin
               for Value of Values_Of (Name) loop
                  Offer (Name & "=" & Value);
               end loop;
               --  profiles= after a check's capability: the profiles there are.
               if Ada.Strings.Fixed.Index (Current, "=profiles=") > 0 then
                  declare
                     Config : R.Item;
                     Got    : E.Error_Info;
                  begin
                     Model_Runner.Framework.Configurations.Read (Store, Config, Got);
                     for Index in 1 .. (if E.Is_Ok (Got) then R.Field_Count (Config) else 0) loop
                        if Ada.Strings.Fixed.Index (R.Field_Name (Config, Index), "profile.") = 1 then
                           Offer (Current (Current'First .. Ada.Strings.Fixed.Index (Current, "=profiles=") + 9)
                                  & R.Field_Name (Config, Index) (R.Field_Name (Config, Index)'First + 8
                                                                  .. R.Field_Name (Config, Index)'Last));
                        end if;
                     end loop;
                  end;
               end if;
               --  What it holds now, to change rather than type again.
               declare
                  Config : R.Item;
                  Got    : E.Error_Info;
               begin
                  Model_Runner.Framework.Configurations.Read (Store, Config, Got);
                  if E.Is_Ok (Got) then
                     for Full of Names.Vector'([Name, "scalar." & Name, "map." & Name]) loop
                        declare
                           Held : constant String := R.Get (Config, Full);
                        begin
                           if Held /= "" and then Ada.Strings.Fixed.Index (Held, [1 => ASCII.LF]) = 0
                             and then Ada.Strings.Fixed.Index (Held, """") = 0
                           then
                              Offer (Name & "=" & (if Ada.Strings.Fixed.Index (Held, " ") > 0
                                                   then """" & Held & """" else Held));
                           end if;
                        end;
                     end loop;
                  end if;
               end;
               --  A kind's profile, or the default: the profiles there are.
               if Ada.Strings.Fixed.Index (Name, "task.profile.") > 0
                 or else Name in "model.default" | "scalar.model.default"
               then
                  for Profile of Profiles loop
                     Offer (Name & "=" & Profile);
                  end loop;
               end if;
            end;
         elsif Ada.Strings.Fixed.Index (Current, "permissions=") = Current'First then
            --  A task's permissions: a capability, or one taken away.
            for One in Model_Runner.Framework.Permissions.Capability loop
               Offer ("permissions=" & Model_Runner.Framework.Permissions.Word (One));
               Offer ("permissions=-" & Model_Runner.Framework.Permissions.Word (One));
            end loop;
            Offer ("permissions=inherit");
         elsif Ada.Strings.Fixed.Index (Current, "kind=") = Current'First then
            for Kind of Tk.Kinds (Store) loop
               Offer ("kind=" & Kind);
            end loop;
         elsif ((Command = "/task" and then Action = "edit")
                or else (Command in "/req" | "/spec" | "/decision" and then Action = "revise"))
           and then Position >= 4
           and then (for some Key of Names.Vector'(["title=", "notes=", "text=", "criteria="]) =>
                       Current = Key)
         then
            --  What the field says now, to change rather than type again.
            declare
               Key   : constant String := Current (Current'First .. Current'Last - 1);
               Typed : constant String := Words (3);
               Id    : constant String :=
                 (if Typed /= "" and then (for all C of Typed => C in '0' .. '9')
                  then "TASK-" & (if Typed'Length >= 3 then Typed else [1 .. 3 - Typed'Length => '0'] & Typed)
                  else Ada.Characters.Handling.To_Upper (Typed));
               Now   : Ada.Strings.Unbounded.Unbounded_String;
            begin
               if Command = "/task" then
                  declare
                     Defined : R.Item;
                     Got     : E.Error_Info;
                  begin
                     Tk.Definition (Store, Id, Defined, Got);
                     if E.Is_Ok (Got) then
                        Now := Ada.Strings.Unbounded.To_Unbounded_String (R.Get (Defined, Key));
                     end if;
                  end;
               else
                  declare
                     Held : Nt.Entity;
                     Got  : E.Error_Info;
                  begin
                     Nt.Read (Store, Register (Command), Id, Held, Got);
                     if E.Is_Ok (Got) then
                        Now := (if Key = "title" then Held.Title elsif Key = "text" then Held.Text
                                elsif Key = "criteria" then Held.Criteria else Now);
                     end if;
                  end;
               end if;
               declare
                  Said : constant String := Ada.Strings.Unbounded.To_String (Now);
               begin
                  --  On one line, its quotes kept out of it.
                  if Said /= "" and then Ada.Strings.Fixed.Index (Said, [1 => ASCII.LF]) = 0
                    and then Ada.Strings.Fixed.Index (Said, """") = 0
                  then
                     Offer (Current & (if Ada.Strings.Fixed.Index (Said, " ") > 0 then """" & Said & """" else Said));
                  end if;
               end;
            end;
         elsif (for some Key of Names.Vector'(["component=", "requirement=", "requirements=", "depends_on=",
                                               "parent=", "profile=", "model=", "scope="]) =>
                  Ada.Strings.Fixed.Index (Current, Key) = Current'First)
         then
            --  A field's values; in a list, the item after the last comma,
            --  those before kept and not offered again.
            declare
               Eq     : constant Natural := Ada.Strings.Fixed.Index (Current, "=");
               Key    : constant String := Current (Current'First .. Eq - 1);
               Comma  : constant Natural := Ada.Strings.Fixed.Index (Current, ",", Ada.Strings.Backward);
               Kept   : constant String := Current (Current'First .. Natural'Max (Eq, Comma));
               Listed : constant Names.Vector :=
                 Words_Of (Ada.Strings.Fixed.Translate (Kept (Eq + 1 .. Kept'Last),
                                                        Ada.Strings.Maps.To_Mapping (",", " ")));
               Values : Names.Vector;
            begin
               if Key = "component" then
                  Values := Tk.Components (Store);
               --  An entry's scope: the whole project, or a component.
               elsif Key = "scope" then
                  Values := Tk.Components (Store);
                  Values.Prepend ("project");
               elsif Key in "requirement" | "requirements" then
                  Values := Nt.List (Store, Nt.Requirement);
               elsif Key in "depends_on" | "parent" then
                  Values := Tk.List (Store);
               elsif Key = "profile" then
                  Values := Profiles;
               elsif Ada.Strings.Fixed.Index (Current, "/") > 0 then
                  --  A model by its path.
                  for Path of Paths (Current (Eq + 1 .. Current'Last)) loop
                     if Path (Path'Last) = '/'
                       or else (Path'Length > 5 and then Path (Path'Last - 4 .. Path'Last) = ".gguf")
                     then
                        Values.Append (Path);
                     end if;
                  end loop;
               else
                  --  A model by its name among the models, as model= takes it.
                  declare
                     Where  : constant String := Model_Runner.Platform.Models_Directory;
                     Search : Ada.Directories.Search_Type;
                     Found  : Ada.Directories.Directory_Entry_Type;
                  begin
                     if Where /= "" and then Ada.Directories.Exists (Where) then
                        Ada.Directories.Start_Search (Search, Where, "*.gguf");
                        while Ada.Directories.More_Entries (Search) loop
                           Ada.Directories.Get_Next_Entry (Search, Found);
                           Values.Append (Ada.Directories.Simple_Name (Found));
                        end loop;
                        Ada.Directories.End_Search (Search);
                     end if;
                  exception
                     when others =>
                        null;
                  end;
               end if;
               for Value of Values loop
                  if not Listed.Contains (Value) then
                     Offer (Kept & Value);
                  end if;
               end loop;
            end;
         elsif Ada.Strings.Fixed.Index (Current, "state=") = Current'First then
            Offer_Words ("state=candidate state=accepted state=ready state=waiting state=refused state=running"
                         & " state=verification state=to-integrate state=conflict state=checks-failed"
                         & " state=blocked state=stopped state=waiting-for-parts state=failed state=complete"
                         & " state=cancelled state=rejected");
         elsif Command = "/task" and then Position = 3 then
            if Action = "kept" then
               Offer_Words ("list diff restore drop");
            elsif Action in "list" | "plan" | "new" then
               Offer_Words ("kind= component= state= requirement=");
            else
               --  Only those the action takes, by their state.
               for Id of Tk.List (Store) loop
                  declare
                     State : constant String := Tk.State_Of (Store, Id);
                  begin
                     if (if Action = "accept" then State in "candidate" | "failed" | "blocked"
                         elsif Action = "reject" then State = "candidate"
                         elsif Action = "complete" then State in "accepted" | "failed" | "blocked" | "verification"
                         elsif Action = "integrate"
                         then Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= ""
                         elsif Action in "cancel" | "split" | "depend" | "edit" | "note" | "grant" | "withhold"
                         then State not in "complete" | "cancelled" | "rejected"
                         elsif Action = "reopen" then State in "complete" | "cancelled" | "failed" | "blocked"
                         elsif Action = "reconsider" then State = "rejected"
                         elsif Action = "verify" then State in "complete" | "verification"
                         else True)
                     then
                        Offer (Id);
                     end if;
                  end;
               end loop;
               --  All of them, where there is one at least.
               if Action in "accept" | "reject" | "complete" | "verify" | "integrate"
                 and then Natural (Offered.Length) > 0
               then
                  Offer ("all");
               end if;
            end if;
         elsif Command = "/task" and then Position = 4 then
            if Action = "kept" then
               Offer_All (Model_Runner.Framework.Workspaces.Kept_Copies (Store));
               if Words (3) = "drop" then
                  Offer ("all");
               end if;
            elsif Action in "grant" | "withhold" then
               --  Those it could be given -- its kind's -- or has, to take away.
               declare
                  package Pm renames Model_Runner.Framework.Permissions;
                  Typed   : constant String := Words (3);
                  Id      : constant String :=
                    (if Typed /= "" and then (for all C of Typed => C in '0' .. '9')
                     then "TASK-" & (if Typed'Length >= 3 then Typed else [1 .. 3 - Typed'Length => '0'] & Typed)
                     else Ada.Characters.Handling.To_Upper (Typed));
                  Defined : R.Item;
                  Got     : E.Error_Info;
               begin
                  Tk.Definition (Store, Id, Defined, Got);
                  if E.Is_Error (Got) then
                     Capabilities;
                  else
                     declare
                        Of_Kind : constant Pm.Permission_Set :=
                          Pm.Effective (Store, R.Get (Defined, "kind"), "", Within_Sandbox => False);
                        Has     : constant Pm.Permission_Set :=
                          Pm.Effective (Store, R.Get (Defined, "kind"), "",
                                        Task_Level => R.Get (Defined, "permissions"), Within_Sandbox => False);
                        Any     : Boolean := False;
                     begin
                        --  To withhold, what it has; to grant, what its kind
                        --  gives that it has not -- or, having all, any of
                        --  its kind's, to narrow by roots=.
                        for One in Pm.Capability loop
                           if (if Action = "withhold" then Has (One).Granted
                               else Of_Kind (One).Granted and then not Has (One).Granted)
                           then
                              Offer (Pm.Word (One));
                              Any := True;
                           end if;
                        end loop;
                        if not Any and then Action = "grant" then
                           for One in Pm.Capability loop
                              if Of_Kind (One).Granted then
                                 Offer (Pm.Word (One));
                              end if;
                           end loop;
                        end if;
                     end;
                  end if;
               end;
            elsif Action = "link" then
               Offer_All (Nt.List (Store, Nt.Requirement));
            elsif Action = "depend" then
               Offer_All (Tk.List (Store));
            elsif Action = "move" then
               Offer_Words ("accepted blocked cancelled");
            elsif Action = "edit" then
               Offer_Words ("title= kind= component= requirements= notes= permissions= depends_on= parent=");
            end if;
         elsif Command = "/task" and then Position = 5 and then Action = "depend" then
            Offer ("remove");
         elsif Command in "/req" | "/spec" | "/decision" and then Position = 3 then
            --  Accepting or rejecting is of what waits: the candidates.
            if Action in "accept" | "reject" then
               Offer_All (Nt.List (Store, Register (Command), "candidate"));
            else
               --  What is retired is shown, not revised or linked; what a move
               --  takes, only those its lifecycle lets make it.
               for Id of Nt.List (Store, Register (Command)) loop
                  declare
                     Now     : constant String := Nt.State_Of (Store, Register (Command), Id);
                     Checked : Model_Runner.Errors.Error_Info := Model_Runner.Errors.Success;
                  begin
                     if Action in "block" | "unblock" | "obsolete" then
                        Model_Runner.Framework.Transitions.Check
                          (Nt.Lifecycle_Of (Store, Register (Command)), Id, Now,
                           (if Action = "block" then "blocked" elsif Action = "obsolete" then "obsolete"
                            else "accepted"),
                           Model_Runner.Framework.Transitions.Ordinary_Only, Checked);
                     end if;
                     if Model_Runner.Errors.Is_Ok (Checked)
                       and then (Action in "show" | "reconsider"
                                 or else Now not in "obsolete" | "superseded" | "rejected")
                     then
                        Offer (Id);
                     end if;
                  end;
               end loop;
            end if;
            if Action in "accept" | "reject" | "obsolete" | "verify" and then Natural (Offered.Length) > 0 then
               Offer ("all");
            end if;
         elsif Command in "/req" | "/spec" | "/decision" and then Position = 4 then
            if Action in "link" | "unlink" then
               Offer_Words ("dependency component implementation task test verification");
            elsif Action = "govern" then
               Settings;
            elsif Action = "supersede" then
               Offer_All (Nt.List (Store, Register (Command)));
            elsif Action = "move" then
               --  The states it may move to from where it is, as its
               --  register's lifecycle allows.
               declare
                  Machine : constant Model_Runner.Framework.Transitions.Machine :=
                    Nt.Lifecycle_Of (Store, Register (Command));
                  Id      : constant String := Ada.Characters.Handling.To_Upper (Words (3));
                  Now     : constant String := Nt.State_Of (Store, Register (Command), Id);
               begin
                  for Next of Model_Runner.Framework.Name_Lists.Vector'
                                (if Command = "/req"
                                 then ["candidate", "accepted", "blocked", "implemented", "obsolete", "rejected"]
                                 else ["candidate", "accepted", "rejected", "obsolete", "superseded"])
                  loop
                     declare
                        Checked : Model_Runner.Errors.Error_Info;
                     begin
                        if Now = "" then
                           Offer (Next);
                        else
                           Model_Runner.Framework.Transitions.Check
                             (Machine, Id, Now, Next, Model_Runner.Framework.Transitions.Ordinary_Only, Checked);
                           if Model_Runner.Errors.Is_Ok (Checked) then
                              Offer (Next);
                           end if;
                        end if;
                     end;
                  end loop;
               end;
            elsif Action = "revise" then
               Offer_Words ("from-document title= text= criteria=");
            end if;
         elsif Command in "/req" | "/spec" | "/decision" and then Position = 5 and then Action = "unlink" then
            --  Only what it is linked to -- a file gone since too.
            declare
               Relation : constant String := Words (4);
            begin
               for One in Nt.Link_Kind loop
                  if (case One is
                        when Nt.Dependency     => Relation = "dependency",
                        when Nt.Component      => Relation = "component",
                        when Nt.Implementation => Relation = "implementation",
                        when Nt.Task_Link      => Relation = "task",
                        when Nt.Test           => Relation = "test",
                        when Nt.Verification   => Relation = "verification")
                  then
                     Offer_All (Nt.Links (Store, Register (Command), Words (3), One));
                  end if;
               end loop;
            end;
         elsif Command in "/spec" | "/decision" and then Position = 5 and then Action = "govern" then
            --  The ruling: what the setting takes, and what it holds now.
            for Value of Values_Of (Words (4)) loop
               Offer (Value);
            end loop;
            declare
               Config : R.Item;
               Got    : E.Error_Info;
            begin
               Model_Runner.Framework.Configurations.Read (Store, Config, Got);
               for Full of Names.Vector'([Words (4), "scalar." & Words (4), "map." & Words (4)]) loop
                  if E.Is_Ok (Got) and then R.Get (Config, Full) /= ""
                    and then Ada.Strings.Fixed.Index (R.Get (Config, Full), " ") = 0
                    and then Ada.Strings.Fixed.Index (R.Get (Config, Full), [1 => ASCII.LF]) = 0
                  then
                     Offer (R.Get (Config, Full));
                  end if;
               end loop;
               --  Unset, what holds instead: its default.
               for Full of Names.Vector'([Words (4), "scalar." & Words (4)]) loop
                  if Model_Runner.Framework.Configurations.Default_Of (Full) /= ""
                    and then Ada.Strings.Fixed.Index (Model_Runner.Framework.Configurations.Default_Of (Full), " ") = 0
                  then
                     Offer (Model_Runner.Framework.Configurations.Default_Of (Full));
                  end if;
               end loop;
            end;
            if Ada.Strings.Fixed.Index (Words (4), "task.profile.") > 0
              or else Words (4) in "model.default" | "scalar.model.default"
            then
               Offer_All (Profiles);
            end if;
         elsif Command in "/spec" | "/decision" and then Position >= 6 and then Action = "govern" then
            Offer ("overrides=CONFIG");
         elsif Command in "/req" | "/spec" | "/decision" and then Position = 5 and then Action = "link"
         then
            if Words (4) = "task" then
               Offer_All (Tk.List (Store));
            elsif Words (4) = "dependency" then
               Offer_All (Nt.List (Store, Register (Command)));
            elsif Words (4) = "component" then
               Offer_All (Tk.Components (Store));
            else
               Offer_All (Paths (Current));
            end if;
         elsif Command in "/accept" | "/reject" and then Position = 2 then
            Offer_All (Tk.List (Store, "candidate"));
            for Which of Model_Runner.CLI.Intents.Pending (Store) loop
               Offer (Which (Ada.Strings.Fixed.Index (Which, ":") + 1 .. Which'Last));
            end loop;
            if Natural (Offered.Length) > 0 then
               Offer ("all");
            end if;
         elsif Command = "/work" and then Position >= 2 then
            --  Only those it would start: ready.
            for Id of Tk.List (Store, "accepted") loop
               if Tk.Ready (Store, Id).Ready then
                  Offer (Id);
               end if;
            end loop;
            if Position = 2 and then Natural (Offered.Length) > 0 then
               Offer ("all");
            end if;
            Offer_Words ("model= steps= profile=");
         elsif Command = "/cancel" and then Position = 2 then
            for Id of Tk.List (Store) loop
               if Tk.State_Of (Store, Id) not in "complete" | "cancelled" | "rejected" then
                  Offer (Id);
               end if;
            end loop;
         elsif Command = "/result" and then Position = 2 then
            --  Tasks first, then the issues it lists and the runs and checks
            --  it shows -- not every log a check kept.
            Offer ("all");
            --  Tasks that have run: those with something to show.
            for Id of Tk.List (Store) loop
               if Tk.State_Of (Store, Id) in "failed" | "blocked" | "complete" | "verification" then
                  Offer (Id);
               end if;
            end loop;
            Offer_All (Model_Runner.CLI.Project_Commands.Open_Issues (Store));
            for Name of S.Names (Store, Model_Runner.Framework.Invocations_Area) loop
               if Ada.Strings.Fixed.Index (Name, "INV-") = Name'First then
                  Offer (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                         then Name (Name'First .. Name'Last - 4) else Name);
               end if;
            end loop;
            for Name of S.Names (Store, Model_Runner.Framework.Verification_Area) loop
               if Ada.Strings.Fixed.Index (Name, "VER-") = Name'First then
                  Offer (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                         then Name (Name'First .. Name'Last - 4) else Name);
               end if;
            end loop;
         elsif Command = "/result" and then Position = 3 and then Action = "restore" then
            --  Only those dismissed come back; all only where there are any.
            if not Model_Runner.CLI.Project_Commands.Dismissed_Issues (Store).Is_Empty then
               Offer ("all");
            end if;
            Offer_All (Model_Runner.CLI.Project_Commands.Dismissed_Issues (Store));
         elsif Command = "/result" and then Position >= 3 and then Action = "dismiss" then
            if not Model_Runner.CLI.Project_Commands.Open_Issues (Store).Is_Empty then
               Offer ("all");
            end if;
            Offer_All (Model_Runner.CLI.Project_Commands.Open_Issues (Store));
         elsif Command = "/config" and then Position = 2 then
            Settings;
            Capabilities;
         elsif Command = "/reconfigure" and then Position >= 2 then
            --  What a set holds, to take out; a path, to add to one of paths.
            if Action = "remove" and then Position >= 4 then
               declare
                  Config : R.Item;
                  Got    : E.Error_Info;
               begin
                  Model_Runner.Framework.Configurations.Read (Store, Config, Got);
                  if E.Is_Ok (Got) then
                     Offer_All (Model_Runner.Framework.Lines_Of
                                  (Ada.Strings.Fixed.Translate
                                     (R.Get (Config, Words (3)) & ASCII.LF & R.Get (Config, "set." & Words (3)),
                                      Ada.Strings.Maps.To_Mapping (", ", ASCII.LF & ASCII.LF))));
                  end if;
               end;
            elsif Action = "add" and then Position >= 4 then
               Offer_All (Paths (Current));
            elsif Action in "add" | "remove" and then Position = 3 then
               for Name of Model_Runner.Framework.Configurations.Known_Names loop
                  if Ada.Strings.Fixed.Index (Name, "set.") = 1 or else Ada.Strings.Fixed.Index (Name, "list.") = 1
                  then
                     Offer (Name);
                  end if;
               end loop;
            elsif Action not in "add" | "remove" then
               declare
                  Before_Settings : constant Natural := Natural (Offered.Length);
               begin
                  Settings;
                  --  A setting is given its value after =.
                  for Index in Before_Settings + 1 .. Natural (Offered.Length) loop
                     Offered.Replace_Element (Index, String'(Offered (Index)) & "=");
                  end loop;
               end;
            end if;
         elsif Command = "/instruct" and then Position = 3 and then Action = "withdraw" then
            for Line of Model_Runner.Framework.Authority.Standing_Instructions (Store) loop
               Offer (Line (Line'First .. Ada.Strings.Fixed.Index (Line & ":", ":") - 1));
            end loop;
         elsif Command = "/check" and then Position = 2 then
            Offer_All (Nt.List (Store, Nt.Requirement));
         elsif Command = "/trace" and then Position = 2 then
            Offer_All (Nt.List (Store, Nt.Requirement));
            Offer_All (Nt.List (Store, Nt.Specification));
            Offer_All (Nt.List (Store, Nt.Decision));
            Offer_All (Tk.List (Store));
            Offer_All (Paths (Current));
         end if;
         S.Close (Store);
      exception
         when others =>
            S.Close (Store);
      end From_Project;
   begin
      if Position = 1 then
         --  The command itself.
         for Kind in Model_Runner.CLI.Interactive.Command_Kind loop
            if Model_Runner.CLI.Interactive.Command_Word (Kind) /= "" then
               Offer (Model_Runner.CLI.Interactive.Command_Word (Kind));
            end if;
         end loop;
         Offer_Words (Project_Commands);
      elsif Command = "/help" and then Position = 2 then
         for Kind in Model_Runner.CLI.Interactive.Command_Kind loop
            declare
               Word : constant String := Model_Runner.CLI.Interactive.Command_Word (Kind);
            begin
               if Word'Length > 1 then
                  Offer (Word (Word'First + 1 .. Word'Last));
               end if;
            end;
         end loop;
         for Word of Words_Of (Project_Commands) loop
            Offer (Word (Word'First + 1 .. Word'Last));
         end loop;
         Offer ("project");
      --  A project here already: no template to start one with.
      elsif Command = "/init" and then Position = 2
        and then S.Is_Initialized (Ada.Directories.Current_Directory)
      then
         null;
      elsif Command = "/init" and then Position = 2 then
         declare
            Search : Ada.Directories.Search_Type;
            Found  : Ada.Directories.Directory_Entry_Type;
            Where  : constant String := Model_Runner.Platform.Installed_Templates_Directory;
         begin
            if Ada.Directories.Exists (Where) then
               Ada.Directories.Start_Search (Search, Where, "*.template");
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  --  A kind of project, not a part others include.
                  if not Is_Part (Ada.Directories.Full_Name (Found)) then
                     Offer (Ada.Directories.Base_Name (Ada.Directories.Simple_Name (Found)));
                  end if;
               end loop;
               Ada.Directories.End_Search (Search);
            end if;
         exception
            when others =>
               null;
         end;
      elsif Position = 2 and then Actions_Of (Command) /= "" then
         Offer_Words (Actions_Of (Command));
         From_Project;
      elsif Command = "/bootstrap" then
         --  What it reads: documents, and directories to go on into.
         for Path of Paths (Current) loop
            declare
               Lower : constant String := Ada.Characters.Handling.To_Lower (Path);
            begin
               if Path (Path'Last) = '/'
                 or else (for some Ending of Names.Vector'([".md", ".rst", ".adoc", ".txt"]) =>
                            Lower'Length > Ending'Length
                            and then Lower (Lower'Last - Ending'Length + 1 .. Lower'Last) = Ending)
               then
                  Offer (Path);
               end if;
            end;
         end loop;
      elsif Command = "/init" and then Position >= 3 and then Words (Position - 1) = "--directory" then
         for Path of Paths (Current) loop
            if Path (Path'Last) = '/' then
               Offer (Path);
            end if;
         end loop;
      elsif Command = "/init" and then Position >= 3 then
         Offer_Words ("--directory --set");
      elsif Command in "/refs" | "/sym" | "/deps" | "/users" | "/impact" | "/tree" | "/save"
                     | "/load" | "/image" | "/video"
      then
         Offer_All (Paths (Current));
         --  The symbols the repository knows, where a name is asked for:
         --  whole, and by their last part.
         if Command in "/refs" | "/sym" | "/users" | "/impact" and then Current /= ""
           and then Ada.Strings.Fixed.Index (Current, "/") = 0
           and then S.Is_Initialized (Ada.Directories.Current_Directory)
         then
            declare
               package Rp renames Model_Runner.Framework.Repository;
               Store : S.Store;
               Read  : E.Error_Info;
            begin
               S.Open_To_Read (Store, Ada.Directories.Current_Directory, Read);
               if E.Is_Ok (Read) then
                  declare
                     Graph : constant Rp.Graph := Rp.Now (Store);
                  begin
                     for Index in 1 .. Rp.Symbol_Count (Graph) loop
                        declare
                           Name : constant String := Ada.Strings.Unbounded.To_String (Rp.Symbol_At (Graph, Index).Name);
                           Dot  : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Ada.Strings.Backward);
                        begin
                           Offer (Name);
                           if Dot > 0 then
                              Offer (Name (Dot + 1 .. Name'Last));
                           end if;
                        end;
                     end loop;
                  end;
                  S.Close (Store);
               end if;
            exception
               when others =>
                  S.Close (Store);
            end;
         end if;
      else
         From_Project;
      end if;
      --  Those the word typed begins, in order; whatever its case where
      --  none begins with it as typed; and, none begun by it, those it is
      --  part of -- /figure is /reconfigure.
      declare
         Lower_Current : constant String := Ada.Characters.Handling.To_Lower (Current);
         function Lower (Text : String) return String renames Ada.Characters.Handling.To_Lower;
      begin
         --  A word already given before it -- an ID among several -- is not
         --  offered again.
         for Index in reverse 1 .. Natural (Offered.Length) loop
            if (for some Place in 2 .. Natural (Words.Length) - (if Fresh then 0 else 1) =>
                  Words (Place) = Offered (Index))
            then
               Offered.Delete (Index);
            end if;
         end loop;
         for One of Offered loop
            if One'Length >= Current'Length and then One (One'First .. One'First + Current'Length - 1) = Current
            then
               Result.Append (One);
            end if;
         end loop;
         if Result.Is_Empty then
            for One of Offered loop
               if One'Length >= Current'Length
                 and then Lower (One (One'First .. One'First + Current'Length - 1)) = Lower_Current
               then
                  Result.Append (One);
               end if;
            end loop;
         end if;
         --  A number, as the commands take one for an ID: those it numbers,
         --  and those whose number it begins.
         if Result.Is_Empty and then Current /= "" and then (for all C of Current => C in '0' .. '9') then
            declare
               Typed : constant String := Ada.Strings.Fixed.Trim (Current, Ada.Strings.Maps.To_Set ("0"),
                                                                    Ada.Strings.Maps.Null_Set);
            begin
               for One of Offered loop
                  declare
                     Dash   : constant Natural := Ada.Strings.Fixed.Index (One, "-", Ada.Strings.Backward);
                     Number : constant String :=
                       (if Dash = 0 then "" else Ada.Strings.Fixed.Trim (One (Dash + 1 .. One'Last),
                                                                         Ada.Strings.Maps.To_Set ("0"),
                                                                         Ada.Strings.Maps.Null_Set));
                  begin
                     if Dash > One'First and then Number /= "" and then (for all C of Number => C in '0' .. '9')
                       and then Number'Length >= Typed'Length
                       and then Number (Number'First .. Number'First + Typed'Length - 1) = Typed
                     then
                        Result.Append (One);
                     end if;
                  end;
               end loop;
            end;
         end if;
         --  Part of a word: only for a few letters typed, and not a path's.
         if Result.Is_Empty and then Current'Length >= 3
           and then Ada.Strings.Fixed.Index (Current, "/", Current'First + 1) = 0
         then
            declare
               Bare : constant String :=
                 (if Lower_Current (Lower_Current'First) = '/'
                  then Lower_Current (Lower_Current'First + 1 .. Lower_Current'Last) else Lower_Current);
            begin
               for One of Offered loop
                  if Bare /= "" and then Ada.Strings.Fixed.Index (Lower (One), Bare) > 0
                    and then (Lower_Current (Lower_Current'First) /= '/' or else One (One'First) = '/')
                  then
                     Result.Append (One);
                  end if;
               end loop;
            end;
         end if;
      end;
      --  Nothing at all: the one it was most likely meant to be, a letter
      --  or two off -- /tsak is /task.
      if Result.Is_Empty and then Current'Length >= 3 then
         declare
            Near : constant String := Model_Runner.Framework.Nearest (Current, Offered);
         begin
            if Near /= "" then
               Result.Append (Near);
            else
               --  Two letters typed the other way round: /tsak.
               for One of Offered loop
                  if One'Length = Current'Length
                    and then (for some At_Index in 0 .. Current'Length - 2 =>
                                One (One'First + At_Index) = Current (Current'First + At_Index + 1)
                                and then One (One'First + At_Index + 1) = Current (Current'First + At_Index)
                                and then One (One'First .. One'First + At_Index - 1)
                                         = Current (Current'First .. Current'First + At_Index - 1)
                                and then One (One'First + At_Index + 2 .. One'Last)
                                         = Current (Current'First + At_Index + 2 .. Current'Last))
                  then
                     Result.Append (One);
                  end if;
               end loop;
            end if;
         end;
      end if;
      Sorting.Sort (Result);
      return Result;
   exception
      --  Tab never ends the session: what cannot be worked out offers nothing.
      when others =>
         return Names.Empty_Vector;
   end Candidates;

   ---------------
   -- Described --
   ---------------

   function Described (Word : String) return String is
      Store : S.Store;
      Read  : E.Error_Info;
      Said  : Ada.Strings.Unbounded.Unbounded_String;
   begin
      if Word'Length < 5 or else not S.Is_Initialized (Ada.Directories.Current_Directory)
        or else not (for some Prefix of Names.Vector'(["TASK-", "REQ-", "SPEC-", "DEC-"]) =>
                       Word'Length > Prefix'Length
                       and then Word (Word'First .. Word'First + Prefix'Length - 1) = Prefix)
      then
         return "";
      end if;
      S.Open_To_Read (Store, Ada.Directories.Current_Directory, Read);
      if E.Is_Error (Read) then
         return "";
      end if;
      if Word (Word'First .. Word'First + 4) = "TASK-" then
         declare
            Defined : R.Item;
            Got     : E.Error_Info;
         begin
            Tk.Definition (Store, Word, Defined, Got);
            if E.Is_Ok (Got) then
               declare
                  State   : constant String := Tk.State_Of (Store, Word);
                  Reasons : constant Names.Vector := Tk.Ready (Store, Word).Reasons;
                  function Said_For (Part : String) return Boolean
                  is (for some Reason of Reasons => Ada.Strings.Fixed.Index (Reason, Part) > 0);
                  --  Named as /task list names it.
                  Shown   : constant String :=
                    (if State = "verification" and then Model_Runner.Framework.Workspaces.Active_For (Store, Word) /= ""
                     then "to integrate"
                     elsif State = "blocked" and then Said_For ("you stopped its work") then "stopped"
                     elsif State = "blocked" and then Said_For ("waiting for its children") then "waiting for parts"
                     elsif State = "accepted" and then Tk.Ready (Store, Word).Ready then "ready"
                     elsif State = "accepted" then "waiting"
                     else State);
               begin
                  Said := Ada.Strings.Unbounded.To_Unbounded_String
                    (Word & "  " & Shown & "  " & R.Get (Defined, "title"));
               end;
            end if;
         end;
      else
         declare
            Kind : constant Nt.Intent_Kind :=
              (if Word (Word'First .. Word'First + 3) = "REQ-" then Nt.Requirement
               elsif Word (Word'First .. Word'First + 4) = "SPEC-" then Nt.Specification else Nt.Decision);
            Held : Nt.Entity;
            Got  : E.Error_Info;
         begin
            Nt.Read (Store, Kind, Word, Held, Got);
            if E.Is_Ok (Got) then
               Said := Ada.Strings.Unbounded.To_Unbounded_String
                 (Word & "  " & Ada.Strings.Unbounded.To_String (Held.State) & "  "
                  & Ada.Strings.Unbounded.To_String (Held.Title));
            end if;
         end;
      end if;
      S.Close (Store);
      return Ada.Strings.Unbounded.To_String (Said);
   exception
      when others =>
         S.Close (Store);
         return "";
   end Described;

end Model_Runner.CLI.Completion;
