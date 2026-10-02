with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;

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

         --  The project's files as they are now, kept beside the tree: what
         --  a change made to both sides since is joined against.
         --  Without it, changes to both sides are settled by a person.
         declare
            Kept : constant Boolean :=
              Copy_Tree (Project, Hostkit.Fs.Join (Home, "base"), Repository.Roots_Of (Item));
            pragma Unreferenced (Kept);
         begin
            null;
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
   procedure Remove_Tree (Item : Stores.Store; Held : Workspace) is
      Worked : Boolean;
      Home   : constant String := Dirs.Containing_Directory (To_String (Held.Path));
   begin
      --  Only a tree git keeps as a worktree -- its .git file there -- is
      --  removed through git; another has nothing for git to say of it, and
      --  asking prints git's refusal to the terminal.
      if Held.Kind = Git_Worktree
        and then Dirs.Exists (Hostkit.Fs.Join (To_String (Held.Path), ".git"))
      then
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

      --  A worktree whose tree went some other way is still registered:
      --  git is told it is gone, so git worktree list does not keep it.
      if Held.Kind = Git_Worktree then
         declare
            Said    : constant String :=
              Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "git-prune-output");
            Ignored : constant String :=
              Git (Project_Of (Item), Words ("worktree", "prune"), Said, Worked);
            pragma Unreferenced (Ignored);
         begin
            Files.Discard (Said);
         end;
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

      declare
         Clashes : constant Name_Lists.Vector := Conflicts (Item, Id);
         Listed  : Unbounded_String;
      begin
         if not Clashes.Is_Empty and then not Text_Resolved then
            --  Kept, with each workspace copy as it is now, so that what is
            --  settled since can be told from what is not.
            declare
               Kept    : Unbounded_String;
               Ignored : E.Error_Info;
            begin
               for Path of Clashes loop
                  Append (Kept, Path & ASCII.HT
                          & Print_Of (Hostkit.Fs.Join (To_String (Held.Path), Path)) & ASCII.LF);
               end loop;
               Files.Write_Text (Conflict_Record (Item, Id), To_String (Kept), Ignored);

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
                     Args    : Name_Lists.Vector;
                     Worked  : Boolean;
                  begin
                     if Dirs.Exists (Base) and then Dirs.Exists (Theirs) and then Dirs.Exists (Ours) then
                        Dirs.Create_Path (Dirs.Containing_Directory (Merged));
                        Dirs.Copy_File (Ours, Merged);
                        Args.Append ("merge-file");
                        Args.Append ("-L");
                        Args.Append ("workspace");
                        Args.Append ("-L");
                        Args.Append ("base");
                        Args.Append ("-L");
                        Args.Append ("project");
                        Args.Append (Merged);
                        Args.Append (Base);
                        Args.Append (Theirs);
                        declare
                           Ignored_Said : constant String :=
                             Git (Project_Of (Item), Args, Hostkit.Fs.Join (Home, "merge-output"), Worked);
                           pragma Unreferenced (Ignored_Said);
                        begin
                           null;
                        end;
                     end if;
                  exception
                     when others =>
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
               --  What would change nothing -- the project holds it as the
               --  workspace does, or neither holds it -- is not taken in.
               if (Dirs.Exists (From) and then Dirs.Exists (Target) and then Print_Of (From) = Print_Of (Target))
                 or else (not Dirs.Exists (From) and then not Dirs.Exists (Target))
               then
                  goto Next_Path;
               end if;
               Taken.Append (Path);
               if Dirs.Exists (From) then
                  if not Files.Make_Directory (Dirs.Containing_Directory (Target)) then
                     Files.Write_Failed (Target, Status);
                     Put_Back;
                     return;
                  end if;
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
                           when others =>
                              null;
                        end;
                        Files.Write_Text (Target, To_String (Joined), Wrote);
                        if E.Is_Error (Wrote) then
                           Status := Wrote;
                           Put_Back;
                           return;
                        end if;
                     else
                        Dirs.Copy_File (From, Target);
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
            <<Next_Path>>
         end loop;
      end;

      Set_Status (Item, Change, Id, "integrated",
                  Image (Natural (Taken.Length)) & " files taken in");
      Files.Discard (Conflict_Record (Item, Id));
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
   is (Name /= "" and then Ada.Strings.Fixed.Index (Name, "/") = 0 and then Name /= ".."
       and then (for some Prefix of Name_Lists.Vector'
                   (["given-up-", "overwritten-", "replaced-", "before-restore-"])
                 => Name'Length > Prefix'Length
                    and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix));

   function Kept_Copies (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Stamps : Name_Lists.Vector;
      Search : Dirs.Search_Type;
      Found  : Dirs.Directory_Entry_Type;
   begin
      if not Dirs.Exists (Runtime_Of (Item)) then
         return Result;
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
      return Result;
   exception
      when others =>
         return Result;
   end Kept_Copies;

   ----------------
   -- Kept_Files --
   ----------------

   function Kept_Files (Item : Stores.Store; Name : String) return Name_Lists.Vector is
      package Name_Sorting is new Name_Lists.Generic_Sorting;
      Result : Name_Lists.Vector;

      procedure Walk (Directory, Prefix : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
         Below  : Name_Lists.Vector;
      begin
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
      if Is_Kept_Name (Name) and then Dirs.Exists (Where) then
         Walk (Where, "");
      end if;
      Name_Sorting.Sort (Result);
      return Result;
   exception
      when others =>
         return Result;
   end Kept_Files;

   Restored_Mark : constant String := ".restored";

   function Was_Restored (Item : Stores.Store; Name : String) return Boolean
   is (Is_Kept_Name (Name) and then Dirs.Exists (Hostkit.Fs.Join (Hostkit.Fs.Join (Runtime_Of (Item), Name),
                                                                  Restored_Mark)));

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
      for Number in 2 .. 999 loop
         declare
            Numbered : constant String := Base & "-" & Ada.Strings.Fixed.Trim (Number'Image, Ada.Strings.Both);
         begin
            if not Dirs.Exists (Hostkit.Fs.Join (Runtime_Of (Item), Numbered)) then
               return Numbered;
            end if;
         end;
      end loop;
      return Base;
   end Replaced_Copy;

   procedure Restore_Kept
     (Item   : Stores.Store;
      Name   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Project : constant String := Dirs.Containing_Directory (Stores.Root (Item));
      Where   : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Name);
      Listed  : constant Name_Lists.Vector := Kept_Files (Item, Name);
      Aside   : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Replaced_Copy (Item, Name));
   begin
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
      for Path of Listed loop
         declare
            Target : constant String := Hostkit.Fs.Join (Project, Path);
         begin
            Dirs.Create_Path (Dirs.Containing_Directory (Target));
            Dirs.Copy_File (Hostkit.Fs.Join (Where, Path), Target);
         end;
      end loop;
      --  Marked as put back, for what is said of the task afterwards; the
      --  copy that took what the project held is not put back any more.
      declare
         Ignored : E.Error_Info;
      begin
         Files.Write_Text (Hostkit.Fs.Join (Where, Restored_Mark), "restored", Ignored);
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
   end Restore_Kept;

   ----------------
   -- Prune_Kept --
   ----------------

   procedure Prune_Kept (Item : Stores.Store; Name : String) is
      Project : constant String := Dirs.Containing_Directory (Stores.Root (Item));
      Where   : constant String := Hostkit.Fs.Join (Runtime_Of (Item), Name);
      Differs : constant Name_Lists.Vector := Changed_Since_Kept (Item, Name);
   begin
      if not Is_Kept_Name (Name) or else not Dirs.Exists (Where) then
         return;
      end if;
      for Path of Kept_Files (Item, Name) loop
         if Dirs.Exists (Hostkit.Fs.Join (Project, Path)) and then not Differs.Contains (Path) then
            Dirs.Delete_File (Hostkit.Fs.Join (Where, Path));
         end if;
      end loop;
      if Kept_Files (Item, Name).Is_Empty then
         Files.Remove_Tree (Where);
      end if;
   exception
      when others =>
         null;
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
      Files.Remove_Tree (Where);
      Status := E.Success;
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
               when others =>
                  null;
            end;
         end loop;
         --  The same as a copy kept of an earlier attempt: this one, which
         --  what is said now names, is kept, and the earlier goes.
         declare
            Mine : constant String := Dirs.Simple_Name (Into);
         begin
            for Other of Kept_Copies (Item) loop
               if Other /= Mine and then Dirs.Exists (Into)
                 and then Ada.Strings.Fixed.Index (Other, "given-up-" & To_String (Held.Task_Id) & "-") = Other'First
                 and then Name_Lists."=" (Kept_Files (Item, Other), Kept_Files (Item, Mine))
                 and then (for all Path of Kept_Files (Item, Mine) =>
                             Print_Of (Hostkit.Fs.Join (Into, Path))
                             = Print_Of (Hostkit.Fs.Join (Hostkit.Fs.Join (Runtime_Of (Item), Other), Path)))
               then
                  Files.Remove_Tree (Hostkit.Fs.Join (Runtime_Of (Item), Other));
                  Replaced_Last := To_Unbounded_String (Other);
               end if;
            end loop;
         end;
      end;
      Remove_Tree (Item, Held);
      Set_Status (Item, Change, Id, "abandoned", "");
      Files.Discard (Conflict_Record (Item, Id));
   end Abandon;

end Model_Runner.Framework.Workspaces;
