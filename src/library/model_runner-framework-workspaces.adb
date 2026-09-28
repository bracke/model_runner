with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit;
with Hostkit.Fs;
with Hostkit.Process;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
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
   function Snapshot (Directory : String) return Maps.Map is
      Found  : constant Repository.Graph := Repository.Scan (Directory);
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
      Arguments : Hostkit.String_Vectors.Vector;
      Happened  : Hostkit.Process.Process_Outcome;
      Text      : Unbounded_String;
      Status    : E.Error_Info;
   begin
      for Word of Words loop
         Arguments.Append (To_Unbounded_String (Word));
      end loop;
      Happened :=
        Hostkit.Process.Run_Captured
          (Program           => "git",
           Arguments         => Arguments,
           Working_Directory => Directory,
           Stdin_Path        => Hostkit.Fs.Null_Device,
           Stdout_Path       => Output,
           Stderr_Path       => Hostkit.Fs.Null_Device,
           Timeout_Ms        => 120_000);
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
   function Copy_Tree (From, Into : String) return Boolean is
      Found : constant Repository.Graph := Repository.Scan (From);
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
                     end if;
                  end;
               end if;
            end;
         end if;

         if not Worked then
            if not Copy_Tree (Project, Tree) then
               Failed ("the project's files cannot be copied", Status);
               return;
            end if;
            Result.Kind := File_Copy;
         end if;

         declare
            Baseline : constant Maps.Map := Snapshot (Tree);
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
         Now      : constant Maps.Map := Snapshot (To_String (Held.Path));
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
         Dirs.Delete_Tree (Home);
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
      Status    : out Model_Runner.Errors.Error_Info)
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

      for Path of Changes (Item, Id) loop
         declare
            From   : constant String := Hostkit.Fs.Join (To_String (Held.Path), Path);
            Target : constant String := Hostkit.Fs.Join (Project, Path);
         begin
            if Dirs.Exists (From) then
               if not Files.Make_Directory (Dirs.Containing_Directory (Target)) then
                  Files.Write_Failed (Target, Status);
                  return;
               end if;
               Dirs.Copy_File (From, Target);
            elsif not Files.Delete_If_Present (Target) then
               Files.Write_Failed (Target, Status);
               return;
            end if;
            Taken.Append (Path);
         exception
            when others =>
               Files.Write_Failed (Target, Status);
               return;
         end;
      end loop;

      Set_Status (Item, Change, Id, "integrated",
                  Image (Natural (Taken.Length)) & " files taken in");
      Events.Emit (Item, Change, Events.Workspace_Integrated, Id,
                   To_String (Held.Task_Id), Event, Status);
      Remove_Tree (Item, Held);
   end Integrate;

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
