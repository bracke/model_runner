with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit;
with Hostkit.Fs;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Workspaces is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package Dirs renames Ada.Directories;
   package Maps renames Configurations.Value_Maps;

   package Sorting is new Name_Lists.Generic_Sorting;

   Tab : constant Character := ASCII.HT;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Image (Value : Natural) return String
   is (Trim (Natural'Image (Value)));

   function Project_Of (Item : Stores.Store) return String
   is (Dirs.Containing_Directory (Stores.Root (Item)));

   function Sorted (Items : Name_Lists.Vector) return Name_Lists.Vector is
      Result : Name_Lists.Vector := Items;
   begin
      Sorting.Sort (Result);
      return Result;
   end Sorted;

   --  Every file's fingerprint in a tree, by path.
   function Snapshot (Directory : String; Within : Repository.Roots) return Maps.Map is
      Found  : constant Repository.Graph := Repository.Scan (Directory, Within);
      Result : Maps.Map;
   begin
      for Index in 1 .. Repository.File_Count (Found) loop
         Result.Include
           (To_String (Repository.File_At (Found, Index).Path),
            To_String (Repository.File_At (Found, Index).Fingerprint));
      end loop;
      return Result;
   end Snapshot;

   --  The fingerprint of one file, or the empty string when it is not there.
   function Print_Of (Path : String) return String is
      Text   : Unbounded_String;
      Status : E.Error_Info;
   begin
      if not Dirs.Exists (Path) then
         return "";
      end if;
      Files.Read_Text (Path, Text, Status);
      return (if E.Is_Ok (Status) then Fingerprint (To_String (Text)) else "?");
   end Print_Of;

   --  Run git in a directory, and what it wrote.
   function Git
     (Directory : String;
      Words     : Name_Lists.Vector;
      Output    : String;
      Worked    : out Boolean) return String
   is
      Happened  : Execution.Outcome;
      Text      : Unbounded_String;
      Status    : E.Error_Info;
   begin
      --  The project a workspace's git is run for keeps the log: the one
      --  whose state the directory is in, or the directory itself.
      Execution.Run_Harness
        ((if Ada.Strings.Fixed.Index (Directory, "/" & State_Directory & "/") > 0
          then Directory (Directory'First
                          .. Ada.Strings.Fixed.Index (Directory, "/" & State_Directory & "/") - 1)
          else Directory),
         "git", Words, Directory, Output, 120, Happened);
      Worked := Happened.Started and then not Happened.Timed_Out
        and then Happened.Exit_Status = 0;
      if Dirs.Exists (Output) then
         Files.Read_Text (Output, Text, Status);
         Files.Discard (Output);
      end if;
      --  Its first line, which is all a command asked of here says.
      declare
         Lines : constant Name_Lists.Vector := Lines_Of (To_String (Text));
      begin
         return (if Lines.Is_Empty then "" else Trim (Lines.First_Element));
      end;
   end Git;

   --  A command's words, the empty ones left out.
   function Words (A, B, C, D, F : String := "") return Name_Lists.Vector is
      Result : Name_Lists.Vector;

      procedure Add (Word : String) is
      begin
         if Word /= "" then
            Result.Append (Word);
         end if;
      end Add;
   begin
      Add (A);
      Add (B);
      Add (C);
      Add (D);
      Add (F);
      return Result;
   end Words;

   --  Copy the files of one tree into another, as a scan finds them.
   function Copy_Tree (From, Into : String; Within : Repository.Roots) return Boolean is
      Found : constant Repository.Graph := Repository.Scan (From, Within);
   begin
      if not Files.Make_Directory (Into) then
         return False;
      end if;
      for Index in 1 .. Repository.File_Count (Found) loop
         declare
            Path   : constant String := To_String (Repository.File_At (Found, Index).Path);
            Target : constant String := Hostkit.Fs.Join (Into, Path);
         begin
            if not Files.Make_Directory (Dirs.Containing_Directory (Target)) then
               return False;
            end if;
            Dirs.Copy_File (Hostkit.Fs.Join (From, Path), Target);
         end;
      end loop;
      return True;
   exception
      when others =>
         return False;
   end Copy_Tree;

   procedure Failed (Detail : String; Status : out E.Error_Info) is
   begin
      Status := E.Make (E.Framework_Workspace_Failed);
      E.Add_Text (Status, "detail", Detail);
   end Failed;

   ------------
   -- Create --
   ------------

   procedure Create
     (Item       : Stores.Store;
      Change     : in out Stores.Transaction;
      Task_Id    : String;
      Agent      : String;
      Generation : String;
      Prefer_Git : Boolean;
      Result     : out Workspace;
      Status     : out Model_Runner.Errors.Error_Info)
   is
      Project : constant String := Project_Of (Item);
      Number  : Natural;
      Worked  : Boolean := False;
      Event   : Unbounded_String;
   begin
      Result := (others => <>);

      --  No more at once than the project allows: a workspace is a copy of
      --  the tree, and a slot is what bounds how many there are.
      declare
         Config : Records.Item;
         Got    : E.Error_Info;
         Active : Natural := 0;
      begin
         Configurations.Read (Item, Config, Got);
         declare
            Limit_Text : constant String := Records.Get (Config, "scalar.work.max_workspaces");
            Limit      : constant Natural :=
              (if Limit_Text'Length in 1 .. 6
                 and then (for all C of Limit_Text => C in '0' .. '9')
               then Natural'Value (Limit_Text) else 0);
         begin
            if Limit > 0 then
               for Name of Stores.Names (Item, Workspaces_Area) loop
                  declare
                     Held : Workspace;
                  begin
                     Read (Item, Name, Held, Got);
                     if E.Is_Ok (Got) and then To_String (Held.Status) = "active" then
                        Active := Active + 1;
                     end if;
                  end;
               end loop;
               if Active >= Limit then
                  Status := E.Make (E.Framework_Limit_Exceeded);
                  E.Add_Text (Status, "name", "workspaces");
                  E.Add_Text (Status, "detail", "all" & Natural'Image (Limit)
                              & " workspace slots are taken");
                  return;
               end if;
            end if;
         end;
      end;

      Stores.Allocate_Number (Item, Change, "WS", "", Number, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Id    : constant String :=
           "WS-" & [1 .. Integer'Max (0, 6 - Image (Number)'Length) => '0'] & Image (Number);
         Home  : constant String :=
           Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "workspaces"), Id);
         Tree  : constant String := Hostkit.Fs.Join (Home, "tree");
         Scratch : constant String := Hostkit.Fs.Join (Home, "git-output");
      begin
         Result.Id := To_Unbounded_String (Id);
         Result.Path := To_Unbounded_String (Tree);
         Result.Agent := To_Unbounded_String (Agent);
         Result.Task_Id := To_Unbounded_String (Task_Id);
         Result.Generation := To_Unbounded_String (Generation);
         Result.Status := To_Unbounded_String ("active");

         if not Files.Make_Directory (Home) then
            Failed ("its directory cannot be made", Status);
            return;
         end if;

         if Prefer_Git and then Dirs.Exists (Hostkit.Fs.Join (Project, ".git")) then
            declare
               Head : constant String :=
                 Git (Project, Words ("rev-parse", "HEAD"), Scratch, Worked);
            begin
               if Worked then
                  declare
                     Ignored : constant String :=
                       Git (Project, Words ("worktree", "add", "--detach", Tree, Head),
                            Scratch, Worked);
                     pragma Unreferenced (Ignored);
                  begin
                     if Worked then
                        Result.Kind := Git_Worktree;
                        Result.Base := To_Unbounded_String (Head);

                        --  The project as it is, not as it was committed:
                        --  what is modified or new is copied over, and what
                        --  is gone is gone there too, so the work starts
                        --  from -- and is compared with -- what is here.
                        declare
                           Here  : constant Maps.Map := Snapshot (Project, Repository.Roots_Of (Item));
                           There : constant Maps.Map := Snapshot (Tree, Repository.Roots_Of (Item));
                        begin
                           for Position in Here.Iterate loop
                              if not There.Contains (Maps.Key (Position))
                                or else There (Maps.Key (Position)) /= Maps.Element (Position)
                              then
                                 declare
                                    Target : constant String :=
                                      Hostkit.Fs.Join (Tree, Maps.Key (Position));
                                 begin
                                    if Files.Make_Directory (Dirs.Containing_Directory (Target)) then
                                       Dirs.Copy_File
                                         (Hostkit.Fs.Join (Project, Maps.Key (Position)), Target);
                                    end if;
                                 end;
                              end if;
                           end loop;
                           for Position in There.Iterate loop
                              if not Here.Contains (Maps.Key (Position)) then
                                 Files.Discard (Hostkit.Fs.Join (Tree, Maps.Key (Position)));
                              end if;
                           end loop;
                        exception
                           when others =>
                              --  Copied instead, whole, as without Git.
                              declare
                                 Gone : constant String :=
                                   Git (Project, Words ("worktree", "remove", "--force", Tree),
                                        Scratch, Worked);
                                 pragma Unreferenced (Gone);
                              begin
                                 if Dirs.Exists (Tree) then
                                    Files.Remove_Tree (Tree);
                                 end if;
                                 Worked := False;
                              end;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;

         if not Worked then
            if not Copy_Tree (Project, Tree, Repository.Roots_Of (Item)) then
               Failed ("the project's files cannot be copied", Status);
               return;
            end if;
            Result.Kind := File_Copy;
         end if;

         declare
            Baseline : constant Maps.Map := Snapshot (Tree, Repository.Roots_Of (Item));
            Value    : Records.Item := Records.Create (Schemas.Workspace_Schema, 1, Id, 1);
            Count    : Natural := 0;
         begin
            if Result.Kind = File_Copy then
               declare
                  Text : Unbounded_String;
               begin
                  for Position in Baseline.Iterate loop
                     Append (Text, Maps.Key (Position) & Tab & Maps.Element (Position) & ASCII.LF);
                  end loop;
                  Result.Base := To_Unbounded_String (Fingerprint (To_String (Text)));
               end;
            end if;
            Records.Set (Value, "backend",
                         Ada.Characters.Handling.To_Lower (Backend'Image (Result.Kind)));
            Records.Set (Value, "path", Tree);
            Records.Set (Value, "base", To_String (Result.Base));
            Records.Set (Value, "agent", Agent);
            Records.Set (Value, "task", Task_Id);
            Records.Set (Value, "generation", Generation);
            Records.Set (Value, "status", "active");
            for Position in Baseline.Iterate loop
               Count := Count + 1;
               Records.Set (Value, "baseline." & Image (Count),
                            Maps.Key (Position) & Tab & Maps.Element (Position));
            end loop;
            Stores.Put (Change, Workspaces_Area, Id, Value);
         end;

         Events.Emit (Item, Change, Events.Workspace_Created, Id, Task_Id, Event, Status);
      end;
   end Create;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Result : out Workspace;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
   begin
      Result := (others => <>);
      Stores.Read (Item, Workspaces_Area, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Result :=
        (Id         => To_Unbounded_String (Id),
         Kind       => (if Records.Get (Value, "backend") = "git_worktree"
                        then Git_Worktree else File_Copy),
         Path       => To_Unbounded_String (Records.Get (Value, "path")),
         Base       => To_Unbounded_String (Records.Get (Value, "base")),
         Agent      => To_Unbounded_String (Records.Get (Value, "agent")),
         Task_Id    => To_Unbounded_String (Records.Get (Value, "task")),
         Generation => To_Unbounded_String (Records.Get (Value, "generation")),
         Status     => To_Unbounded_String (Records.Get (Value, "status")));
   end Read;

   --  The baseline a workspace was made with.
   function Baseline_Of (Item : Stores.Store; Id : String) return Maps.Map is
      Value  : Records.Item;
      Status : E.Error_Info;
      Result : Maps.Map;
   begin
      Stores.Read (Item, Workspaces_Area, Id, Value, Status);
      if E.Is_Error (Status) then
         return Result;
      end if;
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
            Text  : constant String := Records.Get (Value, Field);
            Cut   : constant Natural := Ada.Strings.Fixed.Index (Text, [1 => Tab]);
         begin
            if Field'Length > 9 and then Field (Field'First .. Field'First + 8) = "baseline."
              and then Cut > Text'First
            then
               Result.Include (Text (Text'First .. Cut - 1), Text (Cut + 1 .. Text'Last));
            end if;
         end;
      end loop;
      return Result;
   end Baseline_Of;

   ----------------
   -- Active_For --
   ----------------

   function Active_For (Item : Stores.Store; Task_Id : String) return String is
      Found : Unbounded_String;
   begin
      for Name of Stores.Names (Item, Workspaces_Area) loop
         declare
            Held   : Workspace;
            Status : E.Error_Info;
         begin
            Read (Item, Name, Held, Status);
            if E.Is_Ok (Status) and then To_String (Held.Task_Id) = Task_Id
              and then To_String (Held.Status) = "active"
            then
               Found := Held.Id;
            end if;
         end;
      end loop;
      return To_String (Found);
   end Active_For;

   -------------
   -- Changes --
   -------------

   function Changes (Item : Stores.Store; Id : String) return Name_Lists.Vector is
      Held     : Workspace;
      Status   : E.Error_Info;
      Result   : Name_Lists.Vector;
   begin
      Read (Item, Id, Held, Status);
      if E.Is_Error (Status) then
         return Result;
      end if;
      declare
         Baseline : constant Maps.Map := Baseline_Of (Item, Id);
         Now      : constant Maps.Map := Snapshot (To_String (Held.Path), Repository.Roots_Of (Item));
      begin
         for Position in Now.Iterate loop
            if not Baseline.Contains (Maps.Key (Position))
              or else Baseline (Maps.Key (Position)) /= Maps.Element (Position)
            then
               Result.Append (Maps.Key (Position));
            end if;
         end loop;
         for Position in Baseline.Iterate loop
            if not Now.Contains (Maps.Key (Position)) then
               Result.Append (Maps.Key (Position));
            end if;
         end loop;
      end;
      return Sorted (Result);
   end Changes;

   ---------------
   -- Conflicts --
   ---------------

   function Conflicts (Item : Stores.Store; Id : String) return Name_Lists.Vector is
      Baseline : constant Maps.Map := Baseline_Of (Item, Id);
      Project  : constant String := Project_Of (Item);
      Result   : Name_Lists.Vector;
   begin
      for Path of Changes (Item, Id) loop
         declare
            Before : constant String :=
              (if Baseline.Contains (Path) then Baseline (Path) else "");
         begin
            if Print_Of (Hostkit.Fs.Join (Project, Path)) /= Before then
               Result.Append (Path);
            end if;
         end;
      end loop;
      return Result;
   end Conflicts;

   ------------------------
   -- Semantic_Conflicts --
   ------------------------

   function Semantic_Conflicts (Item : Stores.Store; Id : String) return Name_Lists.Vector is
      use type Repository.Relation_Kind;
      Held      : Workspace;
      Status    : E.Error_Info;
      Result    : Name_Lists.Vector;
      Baseline  : constant Maps.Map := Baseline_Of (Item, Id);
      Roots     : constant Repository.Roots := Repository.Roots_Of (Item);
      Here      : constant Name_Lists.Vector := Changes (Item, Id);
      There     : Name_Lists.Vector;
   begin
      Read (Item, Id, Held, Status);
      if E.Is_Error (Status) then
         return Result;
      end if;

      --  What the project changed since the baseline, apart from what the
      --  workspace changed too, which is a conflict of text.
      declare
         Now : constant Maps.Map := Snapshot (Project_Of (Item), Roots);
      begin
         for Position in Now.Iterate loop
            declare
               Path : constant String := Maps.Key (Position);
            begin
               if (not Baseline.Contains (Path) or else Baseline (Path) /= Maps.Element (Position))
                 and then not Here.Contains (Path)
               then
                  There.Append (Path);
               end if;
            end;
         end loop;
         for Position in Baseline.Iterate loop
            if not Now.Contains (Maps.Key (Position)) and then not Here.Contains (Maps.Key (Position))
            then
               There.Append (Maps.Key (Position));
            end if;
         end loop;
      end;
      if There.Is_Empty or else Here.Is_Empty then
         return Result;
      end if;

      declare
         Ours   : constant Repository.Graph := Repository.Scan (To_String (Held.Path), Roots);
         Theirs : constant Repository.Graph := Repository.Now (Item);

         function Units_Of (From : Repository.Graph; Path : String) return Name_Lists.Vector is
            Units : Name_Lists.Vector;
         begin
            for Index in 1 .. Repository.Relation_Count (From) loop
               declare
                  Link : constant Repository.Relation := Repository.Relation_At (From, Index);
               begin
                  if Link.Kind = Repository.Contains and then To_String (Link.From) = Path then
                     Units.Append (To_String (Link.To));
                  end if;
               end;
            end loop;
            return Units;
         end Units_Of;

         function Depends (From : Repository.Graph; Unit, On : String) return Boolean
         is (Repository.Dependencies_Of (From, Unit).Contains (On));
      begin
         for Mine of Here loop
            for Other of Sorted (There) loop
               declare
                  Why : Unbounded_String;
               begin
                  for Unit of Units_Of (Ours, Mine) loop
                     for Changed of Units_Of (Theirs, Other) loop
                        if Why = Null_Unbounded_String then
                           if Unit = Changed then
                              Why := To_Unbounded_String ("both change " & Unit);
                           elsif Depends (Ours, Unit, Changed) then
                              Why := To_Unbounded_String (Unit & " depends on " & Changed);
                           elsif Depends (Theirs, Changed, Unit) then
                              Why := To_Unbounded_String (Changed & " depends on " & Unit);
                           end if;
                        end if;
                     end loop;
                  end loop;
                  if Why /= Null_Unbounded_String then
                     Result.Append (Mine & " and " & Other & ": " & To_String (Why));
                  end if;
               end;
            end loop;
         end loop;
      end;
      return Result;
   end Semantic_Conflicts;

   --  Remove a workspace's files, and a worktree's registration.
   procedure Remove_Tree (Item : Stores.Store; Held : Workspace) is
      Worked : Boolean;
      Home   : constant String := Dirs.Containing_Directory (To_String (Held.Path));
   begin
      if Held.Kind = Git_Worktree then
         declare
            Ignored : constant String :=
              Git (Project_Of (Item),
                   Words ("worktree", "remove", "--force", To_String (Held.Path)),
                   Hostkit.Fs.Join (Home, "git-output"), Worked);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      end if;
      if Dirs.Exists (Home) then
         Files.Remove_Tree (Home);
      end if;
   exception
      when others =>
         null;
   end Remove_Tree;

   procedure Set_Status
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      State  : String;
      Note   : String)
   is
      Value  : Records.Item;
      Staged : Boolean;
      Status : E.Error_Info;
   begin
      Stores.Pending (Change, Workspaces_Area, Id, Value, Staged);
      if not Staged then
         Stores.Read (Item, Workspaces_Area, Id, Value, Status);
         Records.Set_Revision (Value, Records.Revision (Value) + 1);
      end if;
      Records.Set (Value, "status", State);
      if Note /= "" then
         Records.Set (Value, "outcome", Note);
      end if;
      Stores.Put (Change, Workspaces_Area, Id, Value);
   end Set_Status;

   ---------------
   -- Integrate --
   ---------------

   procedure Integrate
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Permitted : Boolean;
      Taken     : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info;
      Semantic_Accepted : Boolean := False)
   is
      Held    : Workspace;
      Project : constant String := Project_Of (Item);
      Event   : Unbounded_String;
   begin
      Taken.Clear;
      Read (Item, Id, Held, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if To_String (Held.Status) /= "active" then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", To_String (Held.Status));
         E.Add_Text (Status, "expected", "integrated");
         E.Add_Text (Status, "detail", "only an active workspace is taken in");
         return;
      elsif not Permitted then
         Status := E.Make (E.Framework_Integration_Refused);
         E.Add_Text (Status, "name", Id);
         return;
      end if;

      declare
         Clashes : constant Name_Lists.Vector := Conflicts (Item, Id);
         Listed  : Unbounded_String;
      begin
         if not Clashes.Is_Empty then
            for Path of Clashes loop
               Append (Listed, (if Listed = Null_Unbounded_String then "" else ", ") & Path);
            end loop;
            Status := E.Make (E.Framework_Integration_Conflict);
            E.Add_Text (Status, "name", Id);
            E.Add_Text (Status, "detail", To_String (Listed));
            return;
         end if;
      end;

      --  What only the code joins is for a person to judge.
      if not Semantic_Accepted then
         declare
            Joined : constant Name_Lists.Vector := Semantic_Conflicts (Item, Id);
            Listed : Unbounded_String;
         begin
            if not Joined.Is_Empty then
               for Line of Joined loop
                  Append (Listed, (if Listed = Null_Unbounded_String then "" else "; ") & Line);
               end loop;
               Status := E.Make (E.Framework_Integration_Conflict);
               E.Add_Text (Status, "name", Id);
               E.Add_Text (Status, "detail", "what the code joins -- " & To_String (Listed));
               return;
            end if;
         end;
      end if;

      --  All or nothing: what each file was is kept, and put back should
      --  any of them fail to be written.
      declare
         Wanted : constant Name_Lists.Vector := Changes (Item, Id);
         Before : Maps.Map;
         Absent : Name_Lists.Vector;

         procedure Put_Back is
            Ignored : E.Error_Info;
         begin
            for Path of Taken loop
               declare
                  Target : constant String := Hostkit.Fs.Join (Project, Path);
               begin
                  if Absent.Contains (Path) then
                     Files.Discard (Target);
                  elsif Before.Contains (Path) then
                     Files.Write_Text (Target, Before (Path), Ignored);
                  end if;
               end;
            end loop;
            Taken.Clear;
         end Put_Back;
      begin
         for Path of Wanted loop
            declare
               Target : constant String := Hostkit.Fs.Join (Project, Path);
               Text   : Unbounded_String;
               Read   : E.Error_Info;
            begin
               if Dirs.Exists (Target) then
                  Files.Read_Text (Target, Text, Read);
                  if E.Is_Error (Read) then
                     Status := Read;
                     return;
                  end if;
                  Before.Include (Path, To_String (Text));
               else
                  Absent.Append (Path);
               end if;
            end;
         end loop;

         for Path of Wanted loop
            declare
               From   : constant String := Hostkit.Fs.Join (To_String (Held.Path), Path);
               Target : constant String := Hostkit.Fs.Join (Project, Path);
            begin
               Taken.Append (Path);
               if Dirs.Exists (From) then
                  if not Files.Make_Directory (Dirs.Containing_Directory (Target)) then
                     Files.Write_Failed (Target, Status);
                     Put_Back;
                     return;
                  end if;
                  Dirs.Copy_File (From, Target);
               elsif not Files.Delete_If_Present (Target) then
                  Files.Write_Failed (Target, Status);
                  Put_Back;
                  return;
               end if;
            exception
               when others =>
                  Files.Write_Failed (Target, Status);
                  Put_Back;
                  return;
            end;
         end loop;
      end;

      Set_Status (Item, Change, Id, "integrated",
                  Image (Natural (Taken.Length)) & " files taken in");
      Events.Emit (Item, Change, Events.Workspace_Integrated, Id,
                   To_String (Held.Task_Id), Event, Status);
      --  Its tree stays until the integration is kept: Release removes it.
   end Integrate;

   -------------
   -- Release --
   -------------

   procedure Release (Item : Stores.Store; Id : String) is
      Held   : Workspace;
      Status : E.Error_Info;
   begin
      Read (Item, Id, Held, Status);
      if E.Is_Ok (Status) and then To_String (Held.Status) = "integrated" then
         Remove_Tree (Item, Held);
      end if;
   end Release;

   -------------
   -- Abandon --
   -------------

   procedure Abandon
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Held : Workspace;
   begin
      Read (Item, Id, Held, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Remove_Tree (Item, Held);
      Set_Status (Item, Change, Id, "abandoned", "");
   end Abandon;

end Model_Runner.Framework.Workspaces;
