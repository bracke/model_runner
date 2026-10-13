with Model_Runner.Text;
with Ada.IO_Exceptions;
with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

with Hostkit;
with Hostkit.Fs;
with Hostkit.Metadata;

with Model_Runner.Framework.Events;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Schemas;
with Model_Runner.Tools.Editing;

package body Model_Runner.Framework.Workspaces is

   --  What the last Integrate joined, for Last_Joined.
   Joined_Last : Name_Lists.Vector;

   --  The earlier copy the last Abandon's copy replaced, for
   --  Last_Replaced_Copy.
   Replaced_Last : Ada.Strings.Unbounded.Unbounded_String;

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

   --  What a scan's fingerprint is for a file it could not read: one no
   --  file's text has, so a file that cannot be read is never taken for one
   --  that is unchanged, nor -- being in the map -- for one that is gone.
   Unknown_Print : constant String := "?";

   --  Every file's fingerprint in a tree, by path; a file the scan could
   --  not read is in it with Unknown_Print, and in Unread.
   procedure Snapshot
     (Directory : String;
      Within    : Repository.Roots;
      Result    : out Maps.Map;
      Unread    : out Name_Lists.Vector)
   is
      Found : constant Repository.Graph := Repository.Scan (Directory, Within);
   begin
      Result.Clear;
      for Index in 1 .. Repository.File_Count (Found) loop
         Result.Include
           (To_String (Repository.File_At (Found, Index).Path),
            To_String (Repository.File_At (Found, Index).Fingerprint));
      end loop;
      Unread := Repository.Unread_Paths (Found);
      for Path of Unread loop
         Result.Include (Path, Unknown_Print);
      end loop;
   end Snapshot;

   --  The same, for a caller that weighs an unread file as changed: it is
   --  in the map, with a fingerprint nothing matches.
   function Snapshot (Directory : String; Within : Repository.Roots) return Maps.Map is
      Result : Maps.Map;
      Unread : Name_Lists.Vector;
   begin
      Snapshot (Directory, Within, Result, Unread);
      return Result;
   end Snapshot;

   --  A list's paths, joined for a message.
   function Joined (Paths : Name_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Path of Paths loop
         Append (Text, (if Length (Text) = 0 then "" else ", ") & Path);
      end loop;
      return To_String (Text);
   end Joined;

   --  The fingerprint of one file, or the empty string when it is not there.
   --  Where the files a workspace was found in conflict over are kept.
   function Conflict_Record (Item : Stores.Store; Id : String) return String
   is (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "conflict." & Id));

   function Print_Of (Path : String) return String is
      Text   : Unbounded_String;
      Status : E.Error_Info;
   begin
      if not Dirs.Exists (Path) then
         return "";
      end if;
      Files.Read_Text (Path, Text, Status);
      return (if E.Is_Ok (Status) then Fingerprint (To_String (Text)) else Unknown_Print);
   end Print_Of;

   --  Whether two files are known to hold the same: both read, and alike.
   --  Two that cannot be read are not the same as far as anyone knows.
   function Same_Print (Left, Right : String) return Boolean is
      Was : constant String := Print_Of (Left);
   begin
      return Was /= Unknown_Print and then Was = Print_Of (Right);
   end Same_Print;

   procedure Failed (Detail : String; Status : out E.Error_Info) is
   begin
      Status := E.Make (E.Framework_Workspace_Failed);
      E.Add_Text (Status, "detail", Detail);
   end Failed;

   --  Copy the files of one tree into another, as a scan finds them -- all
   --  of them, or a failure naming what was not: a file the scan could not
   --  read, a directory that could not be made, a copy that failed. A copy
   --  missing a file is not a copy of the project.
   procedure Copy_Tree
     (From, Into : String;
      Within     : Repository.Roots;
      Status     : out E.Error_Info)
   is
      Found  : constant Repository.Graph := Repository.Scan (From, Within);
      Unread : constant Name_Lists.Vector := Repository.Unread_Paths (Found);
   begin
      Status := E.Success;
      if not Unread.Is_Empty then
         Failed ("the project's files cannot all be read, so it cannot be copied whole: "
                 & Joined (Unread), Status);
         return;
      end if;
      if not Files.Make_Directory (Into) then
         Failed ("the directory " & Into & " cannot be made", Status);
         return;
      end if;
      for Index in 1 .. Repository.File_Count (Found) loop
         declare
            Path   : constant String := To_String (Repository.File_At (Found, Index).Path);
            Target : constant String := Hostkit.Fs.Join (Into, Path);
         begin
            if not Files.Make_Directory (Dirs.Containing_Directory (Target)) then
               Failed ("the directory " & Dirs.Containing_Directory (Target) & " cannot be made", Status);
               return;
            end if;
            Dirs.Copy_File (Hostkit.Fs.Join (From, Path), Target);
         exception
            when Failure : others =>
               Failed (Path & " could not be copied to " & Target & ": "
                       & Ada.Exceptions.Exception_Name (Failure) & " "
                       & Ada.Exceptions.Exception_Message (Failure), Status);
               return;
         end;
      end loop;
   end Copy_Tree;

   --  What a baseline comes to: its paths and prints, in path order, a
   --  line each.
   function Baseline_Print (Baseline : Maps.Map) return String is
      Text : Unbounded_String;
   begin
      for Position in Baseline.Iterate loop
         Append (Text, Maps.Key (Position) & Tab & Maps.Element (Position) & ASCII.LF);
      end loop;
      return Fingerprint (To_String (Text));
   end Baseline_Print;

   ------------------
   -- Create_Whole --
   ------------------

   --  Create's work; Create below takes away what it leaves on failure.
   procedure Create_Whole
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
         --  No limit read is no limit known, not none: unread, the
         --  workspace is not made.
         Configurations.Read (Item, Config, Got);
         if Configurations.Unreadable (Got) then
            Status := Got;
            return;
         end if;
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
               Head : Unbounded_String;
            begin
               Git.Add_Worktree (Project, Dirs.Full_Name (Tree), Head, Worked);
               if Worked then
                  Result.Kind := Git_Worktree;
                  Result.Base := Head;

                  --  The project as it is, not as it was committed:
                  --  what is modified or new is copied over, and what
                  --  is gone is gone there too, so the work starts
                  --  from -- and is compared with -- what is here.
                  declare
                     Here, There  : Maps.Map;
                     Unread_Here  : Name_Lists.Vector;
                     Unread_There : Name_Lists.Vector;
                     Not_Read     : exception;
                  begin
                     Snapshot (Project, Repository.Roots_Of (Item), Here, Unread_Here);
                     Snapshot (Tree, Repository.Roots_Of (Item), There, Unread_There);
                     --  Not brought up to date from what cannot be
                     --  read: copied whole instead, which refuses it.
                     if not Unread_Here.Is_Empty or else not Unread_There.Is_Empty then
                        raise Not_Read;
                     end if;
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
                        begin
                           Git.Remove_Worktree (Project, Dirs.Full_Name (Tree), Worked);
                           if Dirs.Exists (Tree) then
                              Files.Discard_Tree (Tree);
                           end if;
                           Worked := False;
                        end;
                  end;
               end if;
            end;
         end if;

         if not Worked then
            --  What git began there, gone first: a copy over the rest of a
            --  worktree would be neither.
            if Dirs.Exists (Tree) or else Hostkit.Fs.Is_Link (Tree) then
               Files.Remove_Tree (Tree, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
            Copy_Tree (Project, Tree, Repository.Roots_Of (Item), Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Result.Kind := File_Copy;
         end if;

         --  The project's files as the tree was made from them, kept beside
         --  it: what a change made to both sides since is joined against.
         --  Copied from the tree and not from the project, which an editor
         --  may have changed meanwhile: the base, the tree and the baseline
         --  below are one set of bytes, or the join and the conflict check
         --  would each take a different file for what the work began from.
         --  Without it, changes to both sides are settled by a person.
         --  A base that could not be kept whole is none: a later change to
         --  both sides is then settled by a person, not joined from it.
         declare
            Kept : E.Error_Info;
         begin
            Copy_Tree (Tree, Hostkit.Fs.Join (Home, "base"), Repository.Roots_Of (Item), Kept);
            --  And a partial one left behind would be joined from: gone,
            --  or the workspace is not made.
            if E.Is_Error (Kept) then
               Files.Remove_Tree (Hostkit.Fs.Join (Home, "base"), Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         end;

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
            --  And how many, and what they come to, so that a baseline read
            --  back with one missing or changed is known for that.
            Records.Set (Value, "baseline_count", Image (Count));
            Records.Set (Value, "baseline_fingerprint", Baseline_Print (Baseline));
            Stores.Put (Change, Workspaces_Area, Id, Value);
         end;

         Events.Emit (Item, Change, Events.Workspace_Created, Id, Task_Id, Event, Status);
      end;
   end Create_Whole;

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

   --  The baseline a workspace was made with, held to what its record says
   --  of it: as many entries as it counts, numbered one on from one, each
   --  a path and a print, coming to the fingerprint it keeps. Anything else
   --  is a record that cannot be believed, not a smaller baseline: a file
   --  missing from it would read as one the work created.
   procedure Read_Baseline
     (Item     : Stores.Store;
      Id       : String;
      Baseline : out Maps.Map;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;

      procedure Damaged (Detail : String) is
      begin
         Baseline.Clear;
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "detail", "its baseline " & Detail);
      end Damaged;

      Entries : Natural := 0;
   begin
      Baseline.Clear;
      Stores.Read (Item, Workspaces_Area, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
         begin
            if Field'Length > 9 and then Field (Field'First .. Field'First + 8) = "baseline." then
               Entries := Entries + 1;
            end if;
         end;
      end loop;

      declare
         Counted : constant String := Records.Get (Value, "baseline_count");
         Printed : constant String := Records.Get (Value, "baseline_fingerprint");
      begin
         --  A workspace made before the count was kept says nothing of it:
         --  held to its entries running one on from one, well formed.
         if Counted /= "" then
            if Counted'Length > 9 or else (for some C of Counted => C not in '0' .. '9') then
               Damaged ("count " & Counted & " is not a number");
               return;
            elsif Natural'Value (Counted) /= Entries then
               Damaged ("counts" & Natural'Image (Natural'Value (Counted))
                        & " files and holds" & Natural'Image (Entries));
               return;
            end if;
         end if;

         for Number in 1 .. Entries loop
            declare
               Text : constant String := Records.Get (Value, "baseline." & Image (Number));
               Cut  : constant Natural := Ada.Strings.Fixed.Index (Text, [1 => Tab]);
            begin
               if Text = "" then
                  Damaged ("has no entry" & Natural'Image (Number));
                  return;
               elsif Cut <= Text'First or else Cut = Text'Last then
                  Damaged ("entry" & Natural'Image (Number) & " is not a path and a print");
                  return;
               elsif Baseline.Contains (Text (Text'First .. Cut - 1)) then
                  Damaged ("names " & Text (Text'First .. Cut - 1) & " twice");
                  return;
               end if;
               Baseline.Insert (Text (Text'First .. Cut - 1), Text (Cut + 1 .. Text'Last));
            end;
         end loop;

         if Counted /= "" and then Printed /= Baseline_Print (Baseline) then
            Damaged ("does not come to the fingerprint kept with it");
            return;
         end if;
      end;
   end Read_Baseline;

   --  The baseline where only a list is wanted: empty where it cannot be
   --  believed, which Integrate refuses before anything is decided by it.
   function Baseline_Of (Item : Stores.Store; Id : String) return Maps.Map is
      Result : Maps.Map;
      Status : E.Error_Info;
   begin
      Read_Baseline (Item, Id, Result, Status);
      return Result;
   end Baseline_Of;

   ----------------
   -- Active_For --
   ----------------

   function Every_Active (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector is
      Found : Name_Lists.Vector;
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
               Found.Append (To_String (Held.Id));
            end if;
         end;
      end loop;
      return Found;
   end Every_Active;

   function Unreadable_Records (Item : Stores.Store) return Name_Lists.Vector is
      Found : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Workspaces_Area) loop
         declare
            Held   : Workspace;
            Status : E.Error_Info;
         begin
            Read (Item, Name, Held, Status);
            if E.Is_Error (Status) then
               Found.Append (Name);
            end if;
         end;
      end loop;
      return Found;
   end Unreadable_Records;

   function Active_For (Item : Stores.Store; Task_Id : String) return String is
      Found : constant Name_Lists.Vector := Every_Active (Item, Task_Id);
   begin
      return (if Found.Is_Empty then "" else Found.First_Element);
   end Active_For;

   ----------------------
   -- Active_Workspace --
   ----------------------

   procedure Active_Workspace
     (Item    : Stores.Store;
      Task_Id : String;
      Id      : out Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Found : constant Name_Lists.Vector := Every_Active (Item, Task_Id);
   begin
      Id := Null_Unbounded_String;
      Status := E.Success;
      --  One that cannot be read may be the task's: which it works in
      --  cannot be told, and none is chosen.
      if not Unreadable_Records (Item).Is_Empty then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "name", Unreadable_Records (Item).First_Element);
         E.Add_Text (Status, "detail", "a workspace record cannot be read, so which workspace "
                     & Task_Id & " has cannot be told; /check says what it is");
      elsif Natural (Found.Length) > 1 then
         Status := E.Make (E.Framework_Integrity_Failed);
         E.Add_Text (Status, "name", Task_Id);
         E.Add_Text (Status, "value",
                     Trim (Natural'Image (Natural (Found.Length))) & " active workspaces");
      elsif not Found.Is_Empty then
         Id := To_Unbounded_String (Found.First_Element);
      end if;
   end Active_Workspace;

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

   --------------------
   -- Conflict_Files --
   --------------------

   function Conflict_Files
     (Item           : Stores.Store;
      Id             : String;
      Unsettled_Only : Boolean := False) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
      Text   : Unbounded_String;
      Status : E.Error_Info;
      Held   : Workspace;
   begin
      if not Dirs.Exists (Conflict_Record (Item, Id)) then
         return Result;
      end if;
      Files.Read_Text (Conflict_Record (Item, Id), Text, Status);
      Read (Item, Id, Held, Status);
      for Line of Lines_Of (To_String (Text)) loop
         declare
            Tab  : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
            Path : constant String := (if Tab = 0 then Line else Line (Line'First .. Tab - 1));
            Then_Print : constant String := (if Tab = 0 then "" else Line (Tab + 1 .. Line'Last));
         begin
            if not Unsettled_Only
              or else (E.Is_Ok (Status)
                       and then Print_Of (Hostkit.Fs.Join (To_String (Held.Path), Path)) = Then_Print)
            then
               Result.Append (Path);
            end if;
         end;
      end loop;
      return Result;
   end Conflict_Files;

   ---------------
   -- Conflicts --
   ---------------

   ---------------------------------------------------------------------------
   --  Joining two changes to one file, line by line.
   ---------------------------------------------------------------------------

   --  A file's lines, empty ones kept, and whether it ended with a line feed.
   function Lines_Kept (Text : String; Ends_Line : out Boolean) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Positive := Text'First;
   begin
      Ends_Line := Text'Length > 0 and then Text (Text'Last) = ASCII.LF;
      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            Result.Append (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      if Start <= Text'Last then
         Result.Append (Text (Start .. Text'Last));
      end if;
      return Result;
   end Lines_Kept;

   --  One change from the base: its lines First .. Last - 1 replaced by
   --  With (an insertion where First = Last).
   type Hunk is record
      First, Last : Natural := 0;
      With_Lines  : Name_Lists.Vector;
   end record;

   package Hunk_Lists is new Ada.Containers.Vectors (Positive, Hunk);

   --  The hunks that make Other of Base, by their longest common run of
   --  lines; Fits is False where the two are too long to compare.
   procedure Differ
     (Base, Other : Name_Lists.Vector;
      Result      : out Hunk_Lists.Vector;
      Fits        : out Boolean)
   is
      N : constant Natural := Natural (Base.Length);
      M : constant Natural := Natural (Other.Length);
   begin
      Result.Clear;
      Fits := Long_Long_Integer (N + 1) * Long_Long_Integer (M + 1) <= 4_000_000;
      if not Fits then
         return;
      end if;
      declare
         type Table is array (Natural range <>, Natural range <>) of Natural;
         type Table_Access is access Table;
         procedure Free is new Ada.Unchecked_Deallocation (Table, Table_Access);
         L : Table_Access := new Table (0 .. N, 0 .. M);
         I : Natural := 0;
         J : Natural := 0;
         Open : Boolean := False;
         Now  : Hunk;
      begin
         --  L (I, J): the longest common run of Base (I + 1 ..) and Other (J + 1 ..).
         for A in reverse 0 .. N loop
            for B in reverse 0 .. M loop
               if A = N or else B = M then
                  L (A, B) := 0;
               elsif Base (A + 1) = Other (B + 1) then
                  L (A, B) := L (A + 1, B + 1) + 1;
               else
                  L (A, B) := Natural'Max (L (A + 1, B), L (A, B + 1));
               end if;
            end loop;
         end loop;
         while I < N or else J < M loop
            if I < N and then J < M and then Base (I + 1) = Other (J + 1) then
               if Open then
                  Now.Last := I;
                  Result.Append (Now);
                  Open := False;
               end if;
               I := I + 1;
               J := J + 1;
            else
               if not Open then
                  Now := (First => I, Last => I, With_Lines => Name_Lists.Empty_Vector);
                  Open := True;
               end if;
               if J < M and then (I = N or else L (I, J + 1) >= L (I + 1, J)) then
                  Now.With_Lines.Append (Other (J + 1));
                  J := J + 1;
               else
                  I := I + 1;
               end if;
            end if;
         end loop;
         if Open then
            Now.Last := I;
            Result.Append (Now);
         end if;
         Free (L);
      end;
   end Differ;

   --  Base changed two ways joined, where no line is changed both ways
   --  differently; Clean says whether it was.
   procedure Join_Changes
     (Base, Ours, Theirs : String;
      Joined             : out Unbounded_String;
      Clean              : out Boolean)
   is
      Base_End, Ours_End, Theirs_End : Boolean;
      B  : constant Name_Lists.Vector := Lines_Kept (Base, Base_End);
      O  : constant Name_Lists.Vector := Lines_Kept (Ours, Ours_End);
      T  : constant Name_Lists.Vector := Lines_Kept (Theirs, Theirs_End);
      HO, HT : Hunk_Lists.Vector;
      Fits_O, Fits_T : Boolean;
      Lines  : Name_Lists.Vector;
      P      : Natural := 0;
      IO, IT : Positive := 1;

      function Touch (A, C : Hunk) return Boolean
      is ((A.First < C.Last and then C.First < A.Last)
          or else A.First = C.First
          or else (A.First = A.Last and then C.First < A.First and then A.First < C.Last)
          or else (C.First = C.Last and then A.First < C.First and then C.First < A.Last));

      --  Which side the last line joined came from: its end -- a line
      --  break or none -- is that side's.
      Last_From : Character := 'B';

      procedure Take (One : Hunk; From : Character) is
      begin
         for Index in P + 1 .. One.First loop
            Lines.Append (B (Index));
            Last_From := 'B';
         end loop;
         for Line of One.With_Lines loop
            Lines.Append (Line);
            Last_From := From;
         end loop;
         P := One.Last;
      end Take;
   begin
      Joined := Null_Unbounded_String;
      Clean := False;
      Differ (B, O, HO, Fits_O);
      Differ (B, T, HT, Fits_T);
      if not (Fits_O and then Fits_T) then
         return;
      end if;
      while IO <= Natural (HO.Length) or else IT <= Natural (HT.Length) loop
         if IO <= Natural (HO.Length) and then IT <= Natural (HT.Length)
           and then Touch (HO (IO), HT (IT))
         then
            --  Both change the same lines: joined only when they change
            --  them alike.
            if HO (IO).First = HT (IT).First and then HO (IO).Last = HT (IT).Last
              and then Name_Lists."=" (HO (IO).With_Lines, HT (IT).With_Lines)
            then
               Take (HO (IO), 'O');
               IO := IO + 1;
               IT := IT + 1;
            else
               return;
            end if;
         elsif IT > Natural (HT.Length)
           or else (IO <= Natural (HO.Length) and then HO (IO).First <= HT (IT).First)
         then
            Take (HO (IO), 'O');
            IO := IO + 1;
         else
            Take (HT (IT), 'T');
            IT := IT + 1;
         end if;
      end loop;
      for Index in P + 1 .. Natural (B.Length) loop
         Lines.Append (B (Index));
         Last_From := 'B';
      end loop;
      declare
         Ends : constant Boolean :=
           (case Last_From is
               when 'O'    => Ours_End,
               when 'T'    => Theirs_End,
               when others =>
                 (if Ours_End /= Base_End then Ours_End
                  elsif Theirs_End /= Base_End then Theirs_End
                  else Base_End));
      begin
         for Index in 1 .. Natural (Lines.Length) loop
            Append (Joined, Lines (Index));
            if Index < Natural (Lines.Length) or else Ends then
               Append (Joined, ASCII.LF);
            end if;
         end loop;
      end;
      Clean := True;
   end Join_Changes;

   --  Where a workspace keeps the project's files as they were when it was
   --  made, to join changes against.
   function Base_Tree (Held : Workspace) return String
   is (Hostkit.Fs.Join (Dirs.Containing_Directory (To_String (Held.Path)), "base"));

   --  A file changed in the workspace and in the project since, joined, when
   --  the two change different lines.
   procedure Joined_File
     (Item   : Stores.Store;
      Held   : Workspace;
      Path   : String;
      Joined : out Unbounded_String;
      Clean  : out Boolean)
   is
      Base_Path   : constant String := Hostkit.Fs.Join (Base_Tree (Held), Path);
      Ours_Path   : constant String := Hostkit.Fs.Join (Project_Of (Item), Path);
      Theirs_Path : constant String := Hostkit.Fs.Join (To_String (Held.Path), Path);
      Base, Ours, Theirs : Unbounded_String;
      R1, R2, R3 : E.Error_Info;
   begin
      Joined := Null_Unbounded_String;
      Clean := False;
      if not (Dirs.Exists (Base_Path) and then Dirs.Exists (Ours_Path) and then Dirs.Exists (Theirs_Path))
      then
         return;
      end if;
      Files.Read_Text (Base_Path, Base, R1);
      Files.Read_Text (Ours_Path, Ours, R2);
      Files.Read_Text (Theirs_Path, Theirs, R3);
      if E.Is_Error (R1) or else E.Is_Error (R2) or else E.Is_Error (R3) then
         return;
      end if;
      Join_Changes (To_String (Base), To_String (Ours), To_String (Theirs), Joined, Clean);
   exception
      when others =>
         Clean := False;
   end Joined_File;

   -------------------
   -- Joins_Cleanly --
   -------------------

   function Joins_Cleanly (Item : Stores.Store; Id, Path : String) return Boolean is
      Held   : Workspace;
      Got    : E.Error_Info;
      Joined : Unbounded_String;
      Clean  : Boolean;
   begin
      Read (Item, Id, Held, Got);
      if E.Is_Error (Got) then
         return False;
      end if;
      Joined_File (Item, Held, Path, Joined, Clean);
      return Clean;
   end Joins_Cleanly;

   function Conflicts (Item : Stores.Store; Id : String) return Name_Lists.Vector is
      Baseline : constant Maps.Map := Baseline_Of (Item, Id);
      Project  : constant String := Project_Of (Item);
      Result   : Name_Lists.Vector;
      Held     : Workspace;
      Read_It  : E.Error_Info;
   begin
      Read (Item, Id, Held, Read_It);
      for Path of Changes (Item, Id) loop
         declare
            Before : constant String :=
              (if Baseline.Contains (Path) then Baseline (Path) else "");
            Now    : constant String := Print_Of (Hostkit.Fs.Join (Project, Path));
         begin
            --  Changed in the project since, and not to what the workspace
            --  has: a project that already says the same is no conflict.
            if Now /= Before
              and then (E.Is_Error (Read_It)
                        or else Now /= Print_Of (Hostkit.Fs.Join (To_String (Held.Path), Path)))
            then
               --  Changed on both sides, on lines apart: joined when it is
               --  taken in, no conflict.
               declare
                  Joined : Unbounded_String;
                  Clean  : Boolean := False;
               begin
                  if E.Is_Ok (Read_It) then
                     Joined_File (Item, Held, Path, Joined, Clean);
                  end if;
                  if not Clean then
                     Result.Append (Path);
                  end if;
               end;
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
   procedure Remove_Tree
     (Item   : Stores.Store;
      Held   : Workspace;
      Status : out E.Error_Info)
   is
      Worked : Boolean;
      Home   : constant String := Dirs.Containing_Directory (To_String (Held.Path));
   begin
      Status := E.Success;
      --  Only a tree git keeps as a worktree -- its .git file there -- is
      --  removed through git; another has nothing for git to say of it, and
      --  asking prints git's refusal to the terminal.
      if Held.Kind = Git_Worktree
        and then Dirs.Exists (Hostkit.Fs.Join (To_String (Held.Path), ".git"))
      then
         Git.Remove_Worktree (Project_Of (Item), Dirs.Full_Name (To_String (Held.Path)), Worked);
      end if;
      if Dirs.Exists (Home) then
         Files.Remove_Tree (Home, Status);
      end if;

      --  A worktree whose tree went some other way is still registered:
      --  git is told it is gone, so git worktree list does not keep it.
      if Held.Kind = Git_Worktree then
         Git.Prune_Worktrees (Project_Of (Item));
      end if;
   exception
      when Failure : others =>
         Files.Write_Failed (Home, Status);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
   end Remove_Tree;

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
      Status     : out Model_Runner.Errors.Error_Info) is
   begin
      Create_Whole (Item, Change, Task_Id, Agent, Generation, Prefer_Git, Result, Status);
      --  Refused once its directory was begun -- a copy, a base, its event
      --  -- what it made is nobody's: its number goes with the change the
      --  caller drops, and the next workspace would be given this one's
      --  leftover tree. Taken away here, for every caller.
      if E.Is_Error (Status) and then Length (Result.Id) > 0
        and then Dirs.Exists (Dirs.Containing_Directory (To_String (Result.Path)))
      then
         declare
            Gone : E.Error_Info;
         begin
            Remove_Tree (Item, Result, Gone);
         end;
      end if;
   end Create;

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
         --  A record there and not readable is left for the consistency
         --  check to find, not written over with one field of its own.
         --  And the change it was to be part of refused whole: an
         --  integration staged without its workspace's status would say
         --  it was taken in while the workspace stood active.
         if E.Is_Error (Status) and then E."/=" (Status.Code, E.Framework_Not_Found) then
            Stores.Spoil (Change, Status);
            return;
         end if;
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

   --  Where an integration's journal is kept, and what each file it
   --  touches was: runtime/integrating-WS and runtime/integrating-WS.before.
   function Journal_Of (Item : Stores.Store; Id : String) return String
   is (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "integrating-" & Id));

   function Saved_Of (Item : Stores.Store; Id, Path : String) return String
   is (Hostkit.Fs.Join (Journal_Of (Item, Id) & ".before", Path));

   --  A project file written as the agent's edits are written -- a partial
   --  file of its own, synced, renamed over, its permissions kept -- and,
   --  made new, given Mode where one is known: a script put back keeps its
   --  executable bit.
   procedure Put_File (Target, Text : String; Mode : Natural; Has_Mode : Boolean; Status : out E.Error_Info) is
      Put : Model_Runner.Tools.Editing.Said;
   begin
      Status := E.Success;
      if not Files.Make_Directory (Dirs.Containing_Directory (Target)) then
         Files.Write_Failed (Target, Status);
         return;
      end if;
      Model_Runner.Tools.Editing.Replace (Target, Text, Put);
      if Put.Failed then
         Files.Write_Failed (Target, Status);
      elsif Put.Created and then Has_Mode then
         declare
            Ignored : constant Boolean := Hostkit.Metadata.Set_Permissions (Target, Mode);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      end if;
   end Put_File;

   --  A journal's line in its fields, a tab apart.
   function Split_Tabs (Line : String) return Name_Lists.Vector is
      Start : Positive := Line'First;
   begin
      return Result : Name_Lists.Vector do
         for Index in Line'First .. Line'Last + 1 loop
            if Index > Line'Last or else Line (Index) = ASCII.HT then
               Result.Append (Line (Start .. Index - 1));
               Start := Index + 1;
            end if;
         end loop;
      end return;
   end Split_Tabs;

   --  The project's files put back as an integration's journal says they
   --  were: present, from the copy kept, with their mode; absent, removed.
   --  What cannot be is named in Status, and the journal kept for another
   --  try; all of it put back, the journal goes.
   procedure Roll_Back (Item : Stores.Store; Id : String; Status : out E.Error_Info) is
      Text    : Unbounded_String;
      Read_It : E.Error_Info;
      Left    : Unbounded_String;
      Project : constant String := Project_Of (Item);
   begin
      Status := E.Success;
      if not Dirs.Exists (Journal_Of (Item, Id)) then
         return;
      end if;
      Files.Read_Text (Journal_Of (Item, Id), Text, Read_It);
      if E.Is_Error (Read_It) then
         Status := Read_It;
         return;
      end if;
      for Line of Lines_Of (To_String (Text)) loop
         declare
            Fields : constant Name_Lists.Vector := Split_Tabs (Line);
         begin
            if Natural (Fields.Length) >= 2 and then Fields (1) /= "task" then
               declare
                  Path   : constant String := Fields (1);
                  Target : constant String := Hostkit.Fs.Join (Project, Path);
                  Done   : Boolean := True;
               begin
                  if Fields (2) = "absent" then
                     Done := Files.Delete_If_Present (Target);
                  else
                     declare
                        Was   : Unbounded_String;
                        Got   : E.Error_Info;
                        Wrote : E.Error_Info;
                        Mode  : constant String := (if Natural (Fields.Length) >= 3 then Fields (3) else "-");
                     begin
                        Files.Read_Text (Saved_Of (Item, Id, Path), Was, Got);
                        if E.Is_Ok (Got) then
                           Put_File (Target, To_String (Was),
                                     (if Mode /= "-" and then (for all C of Mode => C in '0' .. '9')
                                      then Natural'Value (Mode) else 0),
                                     Mode /= "-" and then (for all C of Mode => C in '0' .. '9'), Wrote);
                        end if;
                        Done := E.Is_Ok (Got) and then E.Is_Ok (Wrote);
                     end;
                  end if;
                  if not Done then
                     Append (Left, (if Length (Left) = 0 then "" else ", ") & Path);
                  end if;
               end;
            end if;
         end;
      end loop;
      if Length (Left) > 0 then
         Status := E.Make (E.Framework_Transaction_Failed);
         E.Add_Text (Status, "path", Journal_Of (Item, Id), E.Param_Path);
         E.Add_Text (Status, "detail", "what " & Id & " took in could not all be put back: " & To_String (Left));
         return;
      end if;
      Files.Discard (Journal_Of (Item, Id));
      Files.Discard_Tree (Journal_Of (Item, Id) & ".before");
   end Roll_Back;

   --  A journal begun for files about to be written in the project: each
   --  one's content kept aside and its mode, or that it was absent; the
   --  journal written last, so that there, it names copies all kept.
   procedure Begin_Journal
     (Item   : Stores.Store;
      Id     : String;
      Owner  : String;
      Paths  : Name_Lists.Vector;
      Absent : out Name_Lists.Vector;
      Status : out E.Error_Info)
   is
      Project : constant String := Project_Of (Item);
      Journal : Unbounded_String := To_Unbounded_String ("task" & ASCII.HT & Owner & ASCII.LF);
   begin
      Absent.Clear;
      Status := E.Success;
      for Path of Paths loop
         declare
            Target : constant String := Hostkit.Fs.Join (Project, Path);
            Text   : Unbounded_String;
            Read   : E.Error_Info;
            Saved  : E.Error_Info;
         begin
            if Dirs.Exists (Target) then
               Files.Read_Text (Target, Text, Read);
               if E.Is_Error (Read) then
                  Status := Read;
                  Files.Discard_Tree (Journal_Of (Item, Id) & ".before");
                  return;
               end if;
               if not Files.Make_Directory (Dirs.Containing_Directory (Saved_Of (Item, Id, Path))) then
                  Files.Write_Failed (Saved_Of (Item, Id, Path), Status);
                  Files.Discard_Tree (Journal_Of (Item, Id) & ".before");
                  return;
               end if;
               Files.Write_Whole (Saved_Of (Item, Id, Path), To_String (Text), Saved);
               if E.Is_Error (Saved) then
                  Status := Saved;
                  Files.Discard_Tree (Journal_Of (Item, Id) & ".before");
                  return;
               end if;
               declare
                  Known : Boolean;
                  Mode  : constant Natural := Hostkit.Metadata.File_Permission_Bits (Target, Known);
               begin
                  Append (Journal, Path & ASCII.HT & "present" & ASCII.HT
                          & (if Known then Ada.Strings.Fixed.Trim (Natural'Image (Mode), Ada.Strings.Left)
                             else "-") & ASCII.LF);
               end;
            else
               Absent.Append (Path);
               Append (Journal, Path & ASCII.HT & "absent" & ASCII.LF);
            end if;
         end;
      end loop;
      Files.Write_Whole (Journal_Of (Item, Id), To_String (Journal), Status);
      if E.Is_Error (Status) then
         Files.Discard_Tree (Journal_Of (Item, Id) & ".before");
      end if;
   end Begin_Journal;

   ------------------------
   -- Settle_Integration --
   ------------------------

   procedure Settle_Integration
     (Item   : Stores.Store;
      Id     : String;
      Kept   : Boolean;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Status := E.Success;
      if Kept then
         Files.Discard (Journal_Of (Item, Id));
         Files.Discard_Tree (Journal_Of (Item, Id) & ".before");
      else
         Roll_Back (Item, Id, Status);
      end if;
   end Settle_Integration;

   --------------------------
   -- Recover_Integrations --
   --------------------------

   procedure Recover_Integrations
     (Item     : Stores.Store;
      Put_Back : out Name_Lists.Vector;
      Status   : out Model_Runner.Errors.Error_Info)
   is
      Runtime : constant String := Hostkit.Fs.Join (Stores.Root (Item), "runtime");
      Search  : Dirs.Search_Type;
      Found   : Dirs.Directory_Entry_Type;
      Ids     : Name_Lists.Vector;
      Mark    : constant String := "integrating-";
   begin
      Put_Back.Clear;
      Status := E.Success;
      if not Dirs.Exists (Runtime) then
         return;
      end if;
      Dirs.Start_Search (Search, Runtime, Mark & "*", [Dirs.Ordinary_File => True, others => False]);
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Found);
         declare
            Name : constant String := Dirs.Simple_Name (Found);
         begin
            Ids.Append (Name (Name'First + Mark'Length .. Name'Last));
         end;
      end loop;
      Dirs.End_Search (Search);
      for Id of Ids loop
         declare
            Held : Workspace;
            Got  : E.Error_Info;
            Back : E.Error_Info;
         begin
            Read (Item, Id, Held, Got);
            --  A kept copy put back: done where it is marked so -- what is
            --  said of the task reads the mark -- put back where not.
            if Id'Length > 8 and then Id (Id'First .. Id'First + 7) = "restore-" then
               if Was_Restored (Item, Id (Id'First + 8 .. Id'Last)) then
                  Settle_Integration (Item, Id, True, Back);
               else
                  Roll_Back (Item, Id, Back);
                  if E.Is_Ok (Back) then
                     Put_Back.Append (Id);
                  end if;
               end if;
            elsif E.Is_Ok (Got) and then To_String (Held.Status) = "integrated" then
               Settle_Integration (Item, Id, True, Back);
            else
               Roll_Back (Item, Id, Back);
               if E.Is_Ok (Back) then
                  Put_Back.Append (Id);
               end if;
            end if;
            if E.Is_Error (Back) and then E.Is_Ok (Status) then
               Status := Back;
            end if;
         end;
      end loop;
   end Recover_Integrations;

   procedure Integrate
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Permitted : Boolean;
      Taken     : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info;
      Semantic_Accepted : Boolean := False;
      Text_Resolved     : Boolean := False)
   is
      Held    : Workspace;
      Project : constant String := Project_Of (Item);
      Event   : Unbounded_String;
   begin
      Taken.Clear;
      Joined_Last.Clear;
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

      --  Nothing taken in by a baseline that cannot be believed: what the
      --  work changed, and what the project did since, are both told by it.
      declare
         Baseline : Maps.Map;
      begin
         Read_Baseline (Item, Id, Baseline, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end;

      declare
         Clashes : constant Name_Lists.Vector := Conflicts (Item, Id);
         Listed  : Unbounded_String;
      begin
         if not Clashes.Is_Empty and then not Text_Resolved then
            --  Kept, with each workspace copy as it is now, so that what is
            --  settled since can be told from what is not.
            declare
               Kept    : Unbounded_String;
               Noted   : E.Error_Info;
            begin
               for Path of Clashes loop
                  Append (Kept, Path & ASCII.HT
                          & Print_Of (Hostkit.Fs.Join (To_String (Held.Path), Path)) & ASCII.LF);
               end loop;
               --  What conflicted, and how the workspace held it then, is
               --  what settling it is later told by: not kept, there is no
               --  conflict to settle, only a failure said.
               Files.Write_Whole (Conflict_Record (Item, Id), To_String (Kept), Noted);
               if E.Is_Error (Noted) then
                  Status := E.Make (E.Framework_Transaction_Failed);
                  E.Add_Text (Status, "path", Conflict_Record (Item, Id), E.Param_Path);
                  E.Add_Text (Status, "detail",
                              "the integration's conflicts could not be recorded, which settling them is"
                              & " told by: nothing was taken in");
                  return;
               end if;

               --  For each, the two changes joined with the lines both
               --  touched marked, beside the tree -- merge/PATH -- for a
               --  person to settle from: git merge-file over the base.
               for Path of Clashes loop
                  declare
                     Home    : constant String := Dirs.Containing_Directory (To_String (Held.Path));
                     Merged  : constant String := Hostkit.Fs.Join (Hostkit.Fs.Join (Home, "merge"), Path);
                     Base    : constant String := Hostkit.Fs.Join (Base_Tree (Held), Path);
                     Theirs  : constant String := Hostkit.Fs.Join (Project_Of (Item), Path);
                     Ours    : constant String := Hostkit.Fs.Join (To_String (Held.Path), Path);
                     Worked  : Boolean;
                  begin
                     if Dirs.Exists (Base) and then Dirs.Exists (Theirs) and then Dirs.Exists (Ours) then
                        Dirs.Create_Path (Dirs.Containing_Directory (Merged));
                        Dirs.Copy_File (Ours, Merged);
                        Git.Merge_File (Merged, Base, Theirs, "workspace", "base", "project", Worked);
                     end if;
                  exception
                     when others =>
                        --  An aid beside the conflict, which is reported whatever happens here.
                        null;
                  end;
               end loop;
            end;
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

      --  All or nothing, and so across a stop: what each file was is kept
      --  in a journal before any is written -- its content and its mode --
      --  and put back should any fail to be written, or the change these
      --  files go with not be committed (Settle_Integration), or the
      --  process stop between (Recover_Integrations). The files written
      --  first and the records after said two things a stop could leave
      --  apart, and a retry skipped what was already copied, taking in
      --  less than it said.
      declare
         Wanted  : constant Name_Lists.Vector := Changes (Item, Id);
         Absent  : Name_Lists.Vector;

         --  Everything taken so far back as it was, from the journal. What
         --  cannot be is said with the failure that stopped the taking in.
         procedure Put_Back is
            Back : E.Error_Info;
         begin
            Roll_Back (Item, Id, Back);
            if E.Is_Error (Back) then
               E.Add_Text (Status, "detail", "and " & E.Text_Of (Back, "detail"));
            end if;
            Taken.Clear;
         end Put_Back;
      begin
         Begin_Journal (Item, Id, To_String (Held.Task_Id), Wanted, Absent, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         for Path of Wanted loop
            declare
               From   : constant String := Hostkit.Fs.Join (To_String (Held.Path), Path);
               Target : constant String := Hostkit.Fs.Join (Project, Path);
            begin
               --  What would change nothing -- the project holds it as the
               --  workspace does, or neither holds it -- is not taken in.
               if (Dirs.Exists (From) and then Dirs.Exists (Target) and then Same_Print (From, Target))
                 or else (not Dirs.Exists (From) and then not Dirs.Exists (Target))
               then
                  goto Next_Path;
               end if;
               Taken.Append (Path);
               if Dirs.Exists (From) then
                  --  Changed in the project since, on other lines: the two
                  --  joined; otherwise the workspace's copy, as settled.
                  declare
                     Base   : constant Maps.Map := Baseline_Of (Item, Id);
                     Joined : Unbounded_String;
                     Clean  : Boolean := False;
                     Wrote  : E.Error_Info;
                  begin
                     if not Text_Resolved and then Dirs.Exists (Target)
                       and then Base.Contains (Path) and then Print_Of (Target) /= Base (Path)
                     then
                        Joined_File (Item, Held, Path, Joined, Clean);
                     end if;
                     if Clean then
                        Joined_Last.Append (Path);
                        --  The project's own change, as it was before they
                        --  were joined, kept: a join can be put back too.
                        declare
                           Aside : constant String :=
                             Hostkit.Fs.Join (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"),
                                                               "replaced-" & To_String (Held.Task_Id)
                                                               & "-" & Id),
                                              Path);
                        begin
                           Dirs.Create_Path (Dirs.Containing_Directory (Aside));
                           Dirs.Copy_File (Target, Aside);
                        exception
                           --  Not kept aside, not joined: a join that could
                           --  not be put back is not made.
                           when others =>
                              Files.Write_Failed (Aside, Status);
                              E.Add_Text (Status, "detail",
                                          "the project's own change to " & Path
                                          & " could not be kept aside, so the two are not joined");
                              Put_Back;
                              return;
                        end;
                        Put_File (Target, To_String (Joined), 0, False, Wrote);
                        if E.Is_Error (Wrote) then
                           Status := Wrote;
                           Put_Back;
                           return;
                        end if;
                     else
                        --  The workspace's copy, written as an edit is, a
                        --  new file given the workspace file's mode.
                        declare
                           Content : Unbounded_String;
                           Got     : E.Error_Info;
                           Known   : Boolean;
                           Mode    : constant Natural := Hostkit.Metadata.File_Permission_Bits (From, Known);
                        begin
                           Files.Read_Text (From, Content, Got);
                           if E.Is_Ok (Got) then
                              Put_File (Target, To_String (Content), Mode, Known, Wrote);
                           elsif E."=" (Got.Code, E.IO_File_Too_Large) then
                              --  Past what is read whole: copied as it was.
                              Got := E.Success;
                              Dirs.Copy_File (From, Target);
                           end if;
                           if E.Is_Error (Got) or else E.Is_Error (Wrote) then
                              Status := (if E.Is_Error (Got) then Got else Wrote);
                              Put_Back;
                              return;
                           end if;
                        end;
                     end if;
                  end;
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
            --  Outside the file's own failure: a stop here is a stop, not a
            --  write that failed and was put back.
            Stores.Crash_Here (Stores.Mid_Integration);
            <<Next_Path>>
         end loop;
      end;

      Set_Status (Item, Change, Id, "integrated",
                  Image (Natural (Taken.Length)) & " files taken in");
      Events.Emit (Item, Change, Events.Workspace_Integrated, Id,
                   To_String (Held.Task_Id), Event, Status);
      --  Its event refused, the records say nothing of the files taken in:
      --  put back, as a write that failed puts them back, so no caller is
      --  left with a project holding work its records do not.
      if E.Is_Error (Status) then
         declare
            Back : E.Error_Info;
         begin
            Roll_Back (Item, Id, Back);
            if E.Is_Error (Back) then
               E.Add_Text (Status, "detail", "and " & E.Text_Of (Back, "detail"));
            end if;
            Taken.Clear;
         end;
         return;
      end if;
      Files.Discard (Conflict_Record (Item, Id));
      --  Its tree stays until the integration is kept: Release removes it.
   end Integrate;

   -------------
   -- Release --
   -------------

   procedure Release
     (Item   : Stores.Store;
      Id     : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Held : Workspace;
   begin
      Read (Item, Id, Held, Status);
      --  What was taken in is the project's now: a tree that stays is room
      --  taken, not work lost, and released all the same -- said, and
      --  tried again at the next opening.
      if E.Is_Ok (Status) and then To_String (Held.Status) = "integrated" then
         Remove_Tree (Item, Held, Status);
      end if;
   end Release;

   -----------------------
   -- Release_Leftovers --
   -----------------------

   procedure Release_Leftovers
     (Item     : Stores.Store;
      Released : out Name_Lists.Vector;
      Left     : out Name_Lists.Vector) is
   begin
      Released.Clear;
      Left.Clear;
      for Name of Stores.Names (Item, Workspaces_Area) loop
         declare
            Held   : Workspace;
            Status : E.Error_Info;
         begin
            Read (Item, Name, Held, Status);
            if E.Is_Ok (Status) and then To_String (Held.Status) = "integrated"
              and then Length (Held.Path) > 0
              and then Dirs.Exists (Dirs.Containing_Directory (To_String (Held.Path)))
            then
               Remove_Tree (Item, Held, Status);
               if E.Is_Ok (Status) then
                  Released.Append (To_String (Held.Id));
               else
                  Left.Append (To_String (Held.Id));
               end if;
            end if;
         end;
      end loop;
   end Release_Leftovers;

   --  Where Discard_Unrecorded marks a workspace it could not remove: its
   --  tree's place and how it was kept, a line each.
   function Aborted_Mark (Item : Stores.Store; Id : String) return String
   is (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"),
                        "aborted-" & Id & ".txt"));

   ------------------------
   -- Discard_Unrecorded --
   ------------------------

   procedure Discard_Unrecorded
     (Item   : Stores.Store;
      Made   : Workspace;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Marked : E.Error_Info;
   begin
      Remove_Tree (Item, Made, Status);
      if E.Is_Error (Status) then
         Files.Write_Text
           (Aborted_Mark (Item, To_String (Made.Id)),
            To_String (Made.Path) & ASCII.LF
            & Ada.Characters.Handling.To_Lower (Backend'Image (Made.Kind)) & ASCII.LF,
            Marked);
      end if;
   end Discard_Unrecorded;

   function Aborted (Item : Stores.Store; Id : String) return Boolean
   is (Dirs.Exists (Aborted_Mark (Item, Id)));

   ---------------------
   -- Discard_Aborted --
   ---------------------

   procedure Discard_Aborted
     (Item    : Stores.Store;
      Removed : out Name_Lists.Vector)
   is
      Home : constant String := Hostkit.Fs.Join (Stores.Root (Item), "runtime");
   begin
      Removed.Clear;
      if not Dirs.Exists (Home) then
         return;
      end if;
      for Name of Files.Files_In (Home) loop
         if Name'Length > 12
           and then Name (Name'First .. Name'First + 7) = "aborted-"
           and then Name (Name'Last - 3 .. Name'Last) = ".txt"
         then
            declare
               Id     : constant String := Name (Name'First + 8 .. Name'Last - 4);
               Text   : Unbounded_String;
               Status : E.Error_Info;
            begin
               Files.Read_Text (Hostkit.Fs.Join (Home, Name), Text, Status);
               --  Never one the store has a record of: that one is the
               --  store's to settle, whatever a mark says.
               if E.Is_Ok (Status) and then not Stores.Exists (Item, Workspaces_Area, Id) then
                  declare
                     Lines : constant Name_Lists.Vector := Lines_Of (To_String (Text));
                     Made  : Workspace;
                  begin
                     if Natural (Lines.Length) >= 2 then
                        Made.Id := To_Unbounded_String (Id);
                        Made.Path := To_Unbounded_String (Lines (1));
                        Made.Kind := (if Lines (2) = "git_worktree" then Git_Worktree
                                      else File_Copy);
                        Remove_Tree (Item, Made, Status);
                        if E.Is_Ok (Status) then
                           Files.Discard (Hostkit.Fs.Join (Home, Name));
                           Removed.Append (Id);
                        end if;
                     end if;
                  end;
               end if;
            end;
         end if;
      end loop;
   end Discard_Aborted;

   -------------
   -- Abandon --
   -------------

   function Last_Joined return Name_Lists.Vector is (Joined_Last);

   ------------------------
   -- Last_Replaced_Copy --
   ------------------------

   function Last_Replaced_Copy return String is
      Said : constant String := To_String (Replaced_Last);
   begin
      --  Said once: a later run that replaced nothing does not say it again.
      Replaced_Last := Null_Unbounded_String;
      return Said;
   end Last_Replaced_Copy;

   function Kept_Copy (Item : Stores.Store; Id : String) return String is
      Held : Workspace;
      Got  : E.Error_Info;
   begin
      Read (Item, Id, Held, Got);
      return Hostkit.Fs.Join
        (Hostkit.Fs.Join (Stores.Root (Item), "runtime"),
         "given-up-" & (if E.Is_Ok (Got) then To_String (Held.Task_Id) & "-" else "") & Id);
   end Kept_Copy;

   -----------------
   -- Kept_Copies --
   -----------------

   function Runtime_Of (Item : Stores.Store) return String
   is (Hostkit.Fs.Join (Stores.Root (Item), "runtime"));

   function Is_Kept_Name (Name : String) return Boolean
   --  One folder's name and nothing that steps out of it on any host: no
   --  separator of either kind, no drive, no control character.
   is (Name /= "" and then Name /= ".." and then Name /= "."
       and then (for all C of Name => C not in '/' | '\' | ':' and then Character'Pos (C) >= 32)
       and then (for some Prefix of Name_Lists.Vector'
                   (["given-up-", "overwritten-", "replaced-", "before-restore-"])
                 => Name'Length > Prefix'Length
                    and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix));

   procedure Kept_Copies
     (Item   : Stores.Store;
      Result : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Stamps : Name_Lists.Vector;
      Search : Dirs.Search_Type;
      Found  : Dirs.Directory_Entry_Type;
   begin
      Result.Clear;
      Status := E.Success;
      if not Dirs.Exists (Runtime_Of (Item)) then
         return;
      end if;
      Dirs.Start_Search (Search, Runtime_Of (Item), "", [Dirs.Directory => True, others => False]);
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Found);
         if Is_Kept_Name (Dirs.Simple_Name (Found))
           and then not Hostkit.Fs.Is_Link (Dirs.Full_Name (Found))
         then
            --  Newest first: by when each was made, then by name.
            declare
               Stamp : constant String :=
                 Ada.Calendar.Formatting.Image (Dirs.Modification_Time (Found)) & " " & Dirs.Simple_Name (Found);
               Place : Natural := 0;
            begin
               for Index in 1 .. Natural (Stamps.Length) loop
                  if Stamp > Stamps (Index) then
                     Place := Index;
                     exit;
                  end if;
               end loop;
               if Place = 0 then
                  Stamps.Append (Stamp);
                  Result.Append (Dirs.Simple_Name (Found));
               else
                  Stamps.Insert (Place, Stamp);
                  Result.Insert (Place, Dirs.Simple_Name (Found));
               end if;
            end;
         end if;
      end loop;
      Dirs.End_Search (Search);
   exception
      when Failure : others =>
         Result.Clear;
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Runtime_Of (Item), E.Param_Path);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
   end Kept_Copies;

   --  A listing's failure, raised for the caller with none of its own.
   procedure Raise_Unlisted (Status : E.Error_Info) is
      Found : Boolean;
      Said  : E.Parameter;
   begin
      E.Find_Parameter (Status, "path", Found, Said);
      raise Ada.IO_Exceptions.Use_Error with
        (if Found then Model_Runner.Text.To_String (Said.Text_Value) else "a kept copy")
        & " could not be listed whole";
   end Raise_Unlisted;

   function Kept_Copies (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Status : E.Error_Info;
   begin
      Kept_Copies (Item, Result, Status);
      if E.Is_Error (Status) then
         Raise_Unlisted (Status);
      end if;
      return Result;
   end Kept_Copies;

   ----------------
   -- Kept_Files --
   ----------------

   procedure Kept_Files
     (Item   : Stores.Store;
      Name   : String;
      Result : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      package Name_Sorting is new Name_Lists.Generic_Sorting;
      Walking : Unbounded_String;

      procedure Walk (Directory, Prefix : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
         Below  : Name_Lists.Vector;
      begin
         Walking := To_Unbounded_String (Directory);
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            declare
               Simple   : constant String := Dirs.Simple_Name (Found);
               Relative : constant String := (if Prefix = "" then Simple else Prefix & "/" & Simple);
            begin
               --  Its own mark -- .restored -- is not one of the files kept.
               if Simple (Simple'First) /= '.' and then not Hostkit.Fs.Is_Link (Dirs.Full_Name (Found)) then
                  if Dirs."=" (Dirs.Kind (Found), Dirs.Directory) then
                     Below.Append (Simple);
                  elsif Dirs."=" (Dirs.Kind (Found), Dirs.Ordinary_File) then
                     Result.Append (Relative);
                  end if;
               end if;
            end;
         end loop;
         Dirs.End_Search (Search);
         for Simple of Below loop
            Walk (Hostkit.Fs.Join (Directory, Simple), (if Prefix = "" then Simple else Prefix & "/" & Simple));
         end loop;
      end Walk;
      Where : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Name);
   begin
      Result.Clear;
      Status := E.Success;
      if Is_Kept_Name (Name) and then Dirs.Exists (Where) then
         Walk (Where, "");
      end if;
      Name_Sorting.Sort (Result);
   exception
      when Failure : others =>
         Result.Clear;
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", To_String (Walking), E.Param_Path);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
   end Kept_Files;

   function Kept_Files (Item : Stores.Store; Name : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Status : E.Error_Info;
   begin
      Kept_Files (Item, Name, Result, Status);
      if E.Is_Error (Status) then
         Raise_Unlisted (Status);
      end if;
      return Result;
   end Kept_Files;

   Restored_Mark : constant String := ".restored";

   function Was_Restored (Item : Stores.Store; Name : String) return Boolean
   is (Is_Kept_Name (Name)
       and then Dirs.Exists (Hostkit.Fs.Join (Hostkit.Fs.Join (Runtime_Of (Item), Name), Restored_Mark))
       and then Dirs."=" (Dirs.Kind (Hostkit.Fs.Join (Hostkit.Fs.Join (Runtime_Of (Item), Name), Restored_Mark)),
                         Dirs.Ordinary_File));

   ------------------
   -- Restore_Kept --
   ------------------

   function Changed_Since_Kept (Item : Stores.Store; Name : String) return Name_Lists.Vector is
      Project : constant String := Dirs.Containing_Directory (Stores.Root (Item));
      Where   : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Name);
      Result  : Name_Lists.Vector;
   begin
      for Path of Kept_Files (Item, Name) loop
         if Dirs.Exists (Hostkit.Fs.Join (Project, Path))
           and then Print_Of (Hostkit.Fs.Join (Project, Path)) /= Print_Of (Hostkit.Fs.Join (Where, Path))
         then
            Result.Append (Path);
         end if;
      end loop;
      return Result;
   end Changed_Since_Kept;

   --  What a restore swaps out is kept as before-restore-NAME; putting that
   --  back swaps the two again, the files going back to the copy that was
   --  restored -- only while the project holds what that copy put there:
   --  edited since, they are kept under a number of their own, and the
   --  copy left as it was. The names never stack.
   function Replaced_Copy (Item : Stores.Store; Name : String) return String is
      function Starts (Prefix : String) return Boolean
      is (Name'Length > Prefix'Length and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
          and then Is_Kept_Name (Name (Name'First + Prefix'Length .. Name'Last)));
      Back : constant String :=
        (if Starts ("before-restore-") then Name (Name'First + 15 .. Name'Last)
         elsif Starts ("replaced-") then Name (Name'First + 9 .. Name'Last)
         else "");
      Base : constant String := (if Back /= "" then Name else "before-restore-" & Name);
   begin
      if Back /= ""
        and then (not Dirs.Exists (Hostkit.Fs.Join (Runtime_Of (Item), Back))
                  or else Changed_Since_Kept (Item, Back).Is_Empty)
      then
         return Back;
      elsif not Dirs.Exists (Hostkit.Fs.Join (Runtime_Of (Item), Base)) then
         return Base;
      end if;
      --  A number no copy has, however many there are: a ceiling here
      --  handed back Base, which is taken, and the next restore wrote into
      --  a recovery copy that was already someone's.
      for Number in 2 .. Natural'Last loop
         declare
            Numbered : constant String := Base & "-" & Ada.Strings.Fixed.Trim (Number'Image, Ada.Strings.Both);
         begin
            if not Dirs.Exists (Hostkit.Fs.Join (Runtime_Of (Item), Numbered)) then
               return Numbered;
            end if;
         end;
      end loop;
      raise Program_Error with "no free name for a recovery copy of " & Name;
   end Replaced_Copy;

   procedure Restore_Kept
     (Item   : Stores.Store;
      Name   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Project : constant String := Dirs.Containing_Directory (Stores.Root (Item));
      Where   : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Name);
      Listed  : Name_Lists.Vector;
      Aside   : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Replaced_Copy (Item, Name));
   begin
      --  Read whole, or not put back at all: part of a copy put back and
      --  said to be is worse than none.
      Kept_Files (Item, Name, Listed, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      if Listed.Is_Empty then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", "a kept copy called " & Name);
         return;
      end if;
      --  What the project holds otherwise now is kept before it is
      --  overwritten: putting a copy back loses nothing either.
      for Path of Changed_Since_Kept (Item, Name) loop
         declare
            Target : constant String := Hostkit.Fs.Join (Aside, Path);
         begin
            Dirs.Create_Path (Dirs.Containing_Directory (Target));
            Dirs.Copy_File (Hostkit.Fs.Join (Project, Path), Target);
         end;
      end loop;
      --  What the project held of these files kept in a journal before
      --  they are written, as a taking in keeps it: a stop part way, or
      --  records of whose work it is that cannot be kept after, puts them
      --  back (Settle_Restore, Recover_Integrations), where files written
      --  first and records after could say two things.
      declare
         Absent : Name_Lists.Vector;
      begin
         Begin_Journal (Item, "restore-" & Name, Name, Listed, Absent, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end;
      for Path of Listed loop
         declare
            Target  : constant String := Hostkit.Fs.Join (Project, Path);
            From    : constant String := Hostkit.Fs.Join (Where, Path);
            Content : Unbounded_String;
            Got     : E.Error_Info;
            Wrote   : E.Error_Info := E.Success;
            Known   : Boolean;
            Mode    : constant Natural := Hostkit.Metadata.File_Permission_Bits (From, Known);
            Back    : E.Error_Info;
         begin
            Files.Read_Text (From, Content, Got);
            if E.Is_Ok (Got) then
               Put_File (Target, To_String (Content), Mode, Known, Wrote);
            elsif E."=" (Got.Code, E.IO_File_Too_Large) then
               Got := E.Success;
               Dirs.Create_Path (Dirs.Containing_Directory (Target));
               Dirs.Copy_File (From, Target);
            end if;
            if E.Is_Error (Got) or else E.Is_Error (Wrote) then
               Status := (if E.Is_Error (Got) then Got else Wrote);
               Roll_Back (Item, "restore-" & Name, Back);
               return;
            end if;
         end;
      end loop;
      --  Marked as put back, for what is said of the task afterwards; the
      --  copy that took what the project held is not put back any more.
      --  The mark is part of putting it back: what is said of the task,
      --  and what a later restore swaps, read it. Not written, the restore
      --  is not done, whatever the files say.
      declare
         Marked : E.Error_Info;
      begin
         Files.Write_Text (Hostkit.Fs.Join (Where, Restored_Mark), "restored", Marked);
         if E.Is_Error (Marked) then
            Status := Marked;
            --  Not marked, not put back: the files back as they were.
            declare
               Back : E.Error_Info;
            begin
               Roll_Back (Item, "restore-" & Name, Back);
               E.Add_Text (Status, "detail",
                           "the files of " & Name & " could not be marked put back"
                           & (if E.Is_Ok (Back) then ", so they were left as they were"
                              else ", and " & E.Text_Of (Back, "detail")));
            end;
            return;
         end if;
         if Dirs.Exists (Hostkit.Fs.Join (Aside, Restored_Mark)) then
            Dirs.Delete_File (Hostkit.Fs.Join (Aside, Restored_Mark));
         end if;
      end;
      Status := E.Success;
   exception
      when Occurrence : others =>
         Status := E.Make (E.Framework_Transaction_Failed);
         E.Add_Text (Status, "name", Name);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Message (Occurrence));
         declare
            Back : E.Error_Info;
         begin
            Roll_Back (Item, "restore-" & Name, Back);
         end;
   end Restore_Kept;

   --------------------
   -- Settle_Restore --
   --------------------

   procedure Settle_Restore
     (Item   : Stores.Store;
      Name   : String;
      Kept   : Boolean;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Status := E.Success;
      if Kept then
         Settle_Integration (Item, "restore-" & Name, True, Status);
      else
         Roll_Back (Item, "restore-" & Name, Status);
         --  Not put back: not marked so.
         Files.Discard (Hostkit.Fs.Join (Hostkit.Fs.Join (Runtime_Of (Item), Name), Restored_Mark));
      end if;
   end Settle_Restore;

   ----------------
   -- Prune_Kept --
   ----------------

   procedure Prune_Kept
     (Item   : Stores.Store;
      Name   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Project : constant String := Dirs.Containing_Directory (Stores.Root (Item));
      Where   : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Name);
      Differs : constant Name_Lists.Vector := Changed_Since_Kept (Item, Name);
   begin
      Status := E.Success;
      if not Is_Kept_Name (Name) or else not Dirs.Exists (Where) then
         return;
      end if;
      for Path of Kept_Files (Item, Name) loop
         if Dirs.Exists (Hostkit.Fs.Join (Project, Path)) and then not Differs.Contains (Path) then
            Dirs.Delete_File (Hostkit.Fs.Join (Where, Path));
         end if;
      end loop;
      if Kept_Files (Item, Name).Is_Empty then
         Files.Remove_Tree (Where, Status);
      end if;
   exception
      --  Said, not swallowed: what is left is still a recovery copy -- each
      --  file taken out was the project's own just so -- but the caller
      --  says what it holds, and must not say it from what it meant to do.
      when Occurrence : others =>
         Status := E.Make (E.Framework_Transaction_Failed);
         E.Add_Text (Status, "name", Name);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Message (Occurrence));
   end Prune_Kept;

   ---------------
   -- Drop_Kept --
   ---------------

   procedure Drop_Kept
     (Item   : Stores.Store;
      Name   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Where : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Name);
   begin
      if not Is_Kept_Name (Name) or else not Dirs.Exists (Where) then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", "a kept copy called " & Name);
         return;
      end if;
      Files.Remove_Tree (Where, Status);
   end Drop_Kept;

   procedure Abandon
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Held : Workspace;
   begin
      Replaced_Last := Null_Unbounded_String;
      Read (Item, Id, Held, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      --  What it changed, kept before its tree goes: given up is not lost.
      --  All of it, or the workspace stays -- a file that could not be kept
      --  is still in its tree, and the tree is what would go.
      declare
         Into : constant String := Kept_Copy (Item, Id);
      begin
         for Path of Changes (Item, Id) loop
            declare
               From : constant String := Hostkit.Fs.Join (To_String (Held.Path), Path);
               To   : constant String := Hostkit.Fs.Join (Into, Path);
            begin
               if Dirs.Exists (From) then
                  Dirs.Create_Path (Dirs.Containing_Directory (To));
                  Dirs.Copy_File (From, To);
               end if;
            exception
               when Failure : others =>
                  Files.Write_Failed (To, Status);
                  E.Add_Text (Status, "detail",
                              Path & " could not be kept, so the workspace is not given up: "
                              & Ada.Exceptions.Exception_Name (Failure));
                  return;
            end;
         end loop;
         --  The same as a copy kept of an earlier attempt: this one, which
         --  what is said now names, is kept, and the earlier goes -- where
         --  both can be read whole and the earlier can be removed; anything
         --  less keeps both, which loses nothing.
         declare
            Mine   : constant String := Dirs.Simple_Name (Into);
            Copies : Name_Lists.Vector;
            Listed : E.Error_Info;
         begin
            Kept_Copies (Item, Copies, Listed);
            if E.Is_Ok (Listed) then
               for Other of Copies loop
                  if Other /= Mine and then Dirs.Exists (Into)
                    and then Ada.Strings.Fixed.Index (Other, "given-up-" & To_String (Held.Task_Id) & "-")
                             = Other'First
                    and then Name_Lists."=" (Kept_Files (Item, Other), Kept_Files (Item, Mine))
                    and then (for all Path of Kept_Files (Item, Mine) =>
                                Same_Print (Hostkit.Fs.Join (Into, Path),
                                            Hostkit.Fs.Join (Hostkit.Fs.Join (Runtime_Of (Item), Other), Path)))
                  then
                     declare
                        Gone : E.Error_Info;
                     begin
                        Files.Remove_Tree (Hostkit.Fs.Join (Runtime_Of (Item), Other), Gone);
                        if E.Is_Ok (Gone) then
                           Replaced_Last := To_Unbounded_String (Other);
                        end if;
                     end;
                  end if;
               end loop;
            end if;
         exception
            when Ada.IO_Exceptions.Use_Error =>
               null;
         end;
      end;
      --  Its tree gone, or not given up: a workspace said to be abandoned
      --  whose tree is still there would be one nothing removes again.
      Remove_Tree (Item, Held, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Set_Status (Item, Change, Id, "abandoned", "");
      Files.Discard (Conflict_Record (Item, Id));
   end Abandon;

end Model_Runner.Framework.Workspaces;
