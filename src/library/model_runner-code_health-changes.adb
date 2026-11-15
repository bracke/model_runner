with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Tools.Editing;

package body Model_Runner.Code_Health.Changes is

   use Ada.Strings.Unbounded;

   package Dirs renames Ada.Directories;
   package E renames Model_Runner.Errors;
   package R renames Model_Runner.Framework.Records;
   use type Dirs.File_Kind;
   use type E.Error_Code;
   use type Hostkit.Fs.Entry_Kind;

   function Word (Value : Change_Kind) return String is
     (case Value is
         when Created  => "created",
         when Modified => "modified",
         when Deleted  => "deleted",
         when Renamed  => "renamed");

   function Word (Value : Source_Kind) return String is
     (case Value is
         when Direct_Tool      => "direct_tool",
         when External_Command => "external_command",
         when Delegated_Agent  => "delegated_agent",
         when Reconciliation   => "reconciliation");

   function Normal (Path : String) return String is
     (Model_Runner.Framework.Permissions.Normal (Path));

   function Is_Within (Path, Root : String) return Boolean is
     (Path = Root
      or else (Path'Length > Root'Length
               and then Path (Path'First .. Path'First + Root'Length - 1) = Root
               and then Path (Path'First + Root'Length) in '/' | '\'));

   procedure Set_Id (Item : in out Change_Set) is
      Meaning : R.Item := R.Create ("code_health.change_set", 1, "CHANGE", 1);
   begin
      for Index in 1 .. Natural (Item.Items.Length) loop
         declare
            Change : constant File_Change := Item.Items.Element (Index);
            Prefix : constant String := "change." & R.Numbered (Index, Natural (Item.Items.Length));
         begin
            R.Set (Meaning, Prefix & ".kind", Word (Change.Kind));
            R.Set (Meaning, Prefix & ".source", Word (Change.Source));
            R.Set (Meaning, Prefix & ".path", To_String (Change.Path));
            R.Set (Meaning, Prefix & ".old_path", To_String (Change.Old_Path));
            R.Set (Meaning, Prefix & ".before", To_String (Change.Before_Hash));
            R.Set (Meaning, Prefix & ".after", To_String (Change.After_Hash));
         end;
      end loop;
      Item.Id := To_Unbounded_String (R.Fingerprint_Of (Meaning));
   end Set_Id;

   function Same_Key (Left, Right : File_Change) return Boolean is
     (To_String (Left.Path) = To_String (Right.Path)
      and then Left.Kind /= Renamed and then Right.Kind /= Renamed);

   procedure Record_Change
     (Changes : in out Change_Set;
      Item    : File_Change)
   is
      Incoming : File_Change := Item;
   begin
      Incoming.Path := To_Unbounded_String (Normal (To_String (Item.Path)));
      if Length (Item.Old_Path) > 0 then
         Incoming.Old_Path := To_Unbounded_String (Normal (To_String (Item.Old_Path)));
      end if;

      for Index in 1 .. Natural (Changes.Items.Length) loop
         if Same_Key (Changes.Items.Element (Index), Incoming) then
            declare
               Existing : File_Change := Changes.Items.Element (Index);
            begin
               if Existing.Kind = Created and then Incoming.Kind = Deleted then
                  Changes.Items.Delete (Index);
               elsif Existing.Kind = Deleted and then Incoming.Kind = Created then
                  if To_String (Existing.Before_Hash) = To_String (Incoming.After_Hash) then
                     Changes.Items.Delete (Index);
                  else
                     Existing.Kind := Modified;
                     Existing.After_Hash := Incoming.After_Hash;
                     Changes.Items.Replace_Element (Index, Existing);
                  end if;
               elsif Incoming.Kind = Deleted then
                  Existing.Kind := Deleted;
                  Existing.After_Hash := Null_Unbounded_String;
                  Changes.Items.Replace_Element (Index, Existing);
               else
                  Existing.After_Hash := Incoming.After_Hash;
                  if To_String (Existing.Before_Hash) = To_String (Existing.After_Hash) then
                     Changes.Items.Delete (Index);
                  else
                     Changes.Items.Replace_Element (Index, Existing);
                  end if;
               end if;
               Set_Id (Changes);
               return;
            end;
         end if;
      end loop;

      if To_String (Incoming.Before_Hash) /= To_String (Incoming.After_Hash) then
         Changes.Items.Append (Incoming);
      end if;
      Set_Id (Changes);
   end Record_Change;

   procedure Normalize (Changes : in out Change_Set) is
      Normalized : Change_Set;
   begin
      for Item of Changes.Items loop
         Record_Change (Normalized, Item);
      end loop;

      --  A unique deletion and creation with one content identity is a
      --  rename.  Ambiguous matches remain deletion plus creation.
      declare
         Count : constant Natural := Natural (Normalized.Items.Length);
         Used  : array (Natural range 1 .. Count) of Boolean := [others => False];
         Result : File_Change_Lists.Vector;
      begin
         for Old_Index in 1 .. Count loop
            if not Used (Old_Index) and then Normalized.Items.Element (Old_Index).Kind = Deleted then
               declare
                  Old_Item : constant File_Change := Normalized.Items.Element (Old_Index);
                  Match    : Natural := 0;
                  Matches  : Natural := 0;
               begin
                  for New_Index in 1 .. Count loop
                     if not Used (New_Index)
                       and then Normalized.Items.Element (New_Index).Kind = Created
                       and then To_String (Normalized.Items.Element (New_Index).After_Hash)
                         = To_String (Old_Item.Before_Hash)
                     then
                        Match := New_Index;
                        Matches := Matches + 1;
                     end if;
                  end loop;
                  if Matches = 1 then
                     declare
                        Reverse_Matches : Natural := 0;
                        New_Item : constant File_Change := Normalized.Items.Element (Match);
                     begin
                        for Another in 1 .. Count loop
                           if not Used (Another)
                             and then Normalized.Items.Element (Another).Kind = Deleted
                             and then To_String (Normalized.Items.Element (Another).Before_Hash)
                               = To_String (New_Item.After_Hash)
                           then
                              Reverse_Matches := Reverse_Matches + 1;
                           end if;
                        end loop;
                        if Reverse_Matches = 1 then
                           Result.Append
                             (File_Change'(Kind        => Renamed,
                               Source      => New_Item.Source,
                               Path        => New_Item.Path,
                               Old_Path    => Old_Item.Path,
                               Before_Hash => Old_Item.Before_Hash,
                               After_Hash  => New_Item.After_Hash));
                           Used (Old_Index) := True;
                           Used (Match) := True;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end loop;
         for Index in 1 .. Count loop
            if not Used (Index) then
               Result.Append (Normalized.Items.Element (Index));
            end if;
         end loop;
         Normalized.Items := Result;
      end;
      Set_Id (Normalized);
      Changes := Normalized;
   end Normalize;

   function Length (From : Change_Set) return Natural is
     (Natural (From.Items.Length));

   function Element
     (From  : Change_Set;
      Index : Positive) return File_Change is
     (From.Items.Element (Index));

   function Identifier (From : Change_Set) return String is
     (To_String (From.Id));

   procedure Capture
     (Project_Root : String;
      Result       : out Snapshot;
      Status       : out E.Error_Info)
   is
      Root_Path : constant String := Hostkit.Fs.Real_Path (Project_Root);
      package Name_Sorting is new String_Lists.Generic_Sorting;

      function File_Less (Left, Right : File_State) return Boolean is
        (To_String (Left.Path) < To_String (Right.Path));
      package File_Sorting is new File_State_Lists.Generic_Sorting (File_Less);

      procedure Add_File (Full, Relative : String) is
         Actual : constant String :=
           (if Hostkit.Fs.Is_Link (Full) then Hostkit.Fs.Real_Path (Full) else Full);
         Actual_Relative : constant String :=
           Model_Runner.Framework.Repository.Relative_Path (Root_Path, Actual);
         Text : Unbounded_String;
         Read : E.Error_Info;
      begin
         if Actual = "" or else not Is_Within (Actual, Root_Path) then
            Status := E.Make (E.Framework_Permission_Denied);
            E.Add_Text (Status, "path", Relative, E.Param_Path);
            E.Add_Text (Status, "detail", "symbolic link escapes project root");
            return;
         end if;
         Model_Runner.Tools.Editing.Read_Text (Actual, Text, Read);
         if E.Is_Error (Read) then
            Result.Skipped.Append
              (Normal (Relative) & ": "
               & (if Read.Code = E.IO_File_Too_Large then "file is too large"
                  elsif Read.Code = E.IO_Read_Failed then "binary or unreadable file"
                  else "file could not be read"));
            return;
         end if;
         Result.Files.Append
           (File_State'(Path => To_Unbounded_String (Normal (Actual_Relative)),
             Hash => To_Unbounded_String (Model_Runner.Tools.Editing.Revision (To_String (Text)))));
      exception
         when Failure : others =>
            Result.Skipped.Append
              (Normal (Relative) & ": " & Ada.Exceptions.Exception_Name (Failure));
      end Add_File;

      procedure Walk (Directory, Prefix : String) is
         Search : Dirs.Search_Type;
         Found  : Dirs.Directory_Entry_Type;
         Here   : String_Lists.Vector;
      begin
         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Found);
            if Dirs.Simple_Name (Found) not in "." | ".." then
               Here.Append (Dirs.Simple_Name (Found));
            end if;
         end loop;
         Dirs.End_Search (Search);
         Name_Sorting.Sort (Here);
         for Name of Here loop
            declare
               Relative : constant String := (if Prefix = "" then Name else Prefix & "/" & Name);
               Full     : constant String := Hostkit.Fs.Join (Directory, Name);
               Excluded : constant Boolean :=
                 Name in ".git" | ".hg" | ".svn" | ".model_runner"
                 or else Ada.Strings.Fixed.Index (Name, ".model_runner-partial.") > 0
                 or else Model_Runner.Framework.Repository.Under_Roots
                   (Model_Runner.Framework.Repository.Default_Roots.Skip, Relative);
            begin
               if not Excluded then
                  if Hostkit.Fs.Is_Link (Full) then
                     declare
                        Actual : constant String := Hostkit.Fs.Real_Path (Full);
                     begin
                        if Actual = "" or else not Is_Within (Actual, Root_Path) then
                           Status := E.Make (E.Framework_Permission_Denied);
                           E.Add_Text (Status, "path", Relative, E.Param_Path);
                           E.Add_Text (Status, "detail", "symbolic link escapes project root");
                           return;
                        elsif Hostkit.Fs.Kind_Of (Actual) = Hostkit.Fs.Directory_Entry then
                           Result.Skipped.Append (Normal (Relative) & ": directory symbolic link not followed");
                        else
                           Add_File (Full, Relative);
                        end if;
                     end;
                  elsif Dirs.Kind (Full) = Dirs.Directory then
                     Walk (Full, Relative);
                     if E.Is_Error (Status) then
                        return;
                     end if;
                  elsif Dirs.Kind (Full) = Dirs.Ordinary_File then
                     Add_File (Full, Relative);
                     if E.Is_Error (Status) then
                        return;
                     end if;
                  end if;
               end if;
            end;
         end loop;
      exception
         when Failure : others =>
            Status := E.Make (E.IO_Read_Failed);
            E.Add_Text (Status, "path", Directory, E.Param_Path);
            E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
      end Walk;
   begin
      Result := (others => <>);
      Status := E.Success;
      if Root_Path = "" or else not Dirs.Exists (Root_Path)
        or else Dirs.Kind (Root_Path) /= Dirs.Directory
      then
         Status := E.Make (E.IO_Not_A_Regular_File);
         E.Add_Text (Status, "path", Project_Root, E.Param_Path);
         return;
      end if;
      Result.Project_Root := To_Unbounded_String (Root_Path);
      Walk (Root_Path, "");
      if E.Is_Error (Status) then
         return;
      end if;

      File_Sorting.Sort (Result.Files);

      --  Internal links can name the same resolved file.  Keep it once.
      declare
         Deduplicated : File_State_Lists.Vector;
      begin
         for File of Result.Files loop
            if Deduplicated.Is_Empty
              or else To_String (Deduplicated.Last_Element.Path) /= To_String (File.Path)
            then
               Deduplicated.Append (File);
            end if;
         end loop;
         Result.Files := Deduplicated;
      end;

      declare
         Meaning : R.Item := R.Create ("code_health.snapshot", 1, "SNAPSHOT", 1);
      begin
         for Index in 1 .. Natural (Result.Files.Length) loop
            R.Set (Meaning, "file." & R.Numbered (Index, Natural (Result.Files.Length)) & ".path",
                   To_String (Result.Files.Element (Index).Path));
            R.Set (Meaning, "file." & R.Numbered (Index, Natural (Result.Files.Length)) & ".hash",
                   To_String (Result.Files.Element (Index).Hash));
         end loop;
         Result.Id := To_Unbounded_String (R.Fingerprint_Of (Meaning));
      end;
   exception
      when Failure : others =>
         Result := (others => <>);
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Project_Root, E.Param_Path);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure));
   end Capture;

   function Identifier (From : Snapshot) return String is
     (To_String (From.Id));

   function Root (From : Snapshot) return String is
     (To_String (From.Project_Root));

   function Skipped_Count (From : Snapshot) return Natural is
     (Natural (From.Skipped.Length));

   function Skipped_At
     (From  : Snapshot;
      Index : Positive) return String is
     (From.Skipped.Element (Index));

   procedure Reconcile
     (Before : Snapshot;
      After  : Snapshot;
      Source : Source_Kind;
      Result : out Change_Set;
      Status : out E.Error_Info)
   is
      Left  : Natural := 1;
      Right : Natural := 1;
   begin
      Result := (others => <>);
      if Root (Before) /= Root (After) then
         Status := E.Make (E.Framework_Contract_Violation);
         E.Add_Text (Status, "detail", "snapshots have different project roots");
         return;
      end if;
      while Left <= Natural (Before.Files.Length) or else Right <= Natural (After.Files.Length) loop
         if Left > Natural (Before.Files.Length) then
            declare
               New_File : constant File_State := After.Files.Element (Right);
            begin
               Result.Items.Append
                 (File_Change'(Kind => Created, Source => Source, Path => New_File.Path,
                   Old_Path => Null_Unbounded_String, Before_Hash => Null_Unbounded_String,
                   After_Hash => New_File.Hash));
               Right := Right + 1;
            end;
         elsif Right > Natural (After.Files.Length) then
            declare
               Old_File : constant File_State := Before.Files.Element (Left);
            begin
               Result.Items.Append
                 (File_Change'(Kind => Deleted, Source => Source, Path => Old_File.Path,
                   Old_Path => Null_Unbounded_String, Before_Hash => Old_File.Hash,
                   After_Hash => Null_Unbounded_String));
               Left := Left + 1;
            end;
         else
            declare
               Old_File : constant File_State := Before.Files.Element (Left);
               New_File : constant File_State := After.Files.Element (Right);
               Old_Path : constant String := To_String (Old_File.Path);
               New_Path : constant String := To_String (New_File.Path);
            begin
               if Old_Path < New_Path then
                  Result.Items.Append
                    (File_Change'(Kind => Deleted, Source => Source, Path => Old_File.Path,
                      Old_Path => Null_Unbounded_String, Before_Hash => Old_File.Hash,
                      After_Hash => Null_Unbounded_String));
                  Left := Left + 1;
               elsif New_Path < Old_Path then
                  Result.Items.Append
                    (File_Change'(Kind => Created, Source => Source, Path => New_File.Path,
                      Old_Path => Null_Unbounded_String, Before_Hash => Null_Unbounded_String,
                      After_Hash => New_File.Hash));
                  Right := Right + 1;
               else
                  if To_String (Old_File.Hash) /= To_String (New_File.Hash) then
                     Result.Items.Append
                       (File_Change'(Kind => Modified, Source => Source, Path => New_File.Path,
                         Old_Path => Null_Unbounded_String, Before_Hash => Old_File.Hash,
                         After_Hash => New_File.Hash));
                  end if;
                  Left := Left + 1;
                  Right := Right + 1;
               end if;
            end;
         end if;
      end loop;
      Normalize (Result);
      Status := E.Success;
   end Reconcile;

end Model_Runner.Code_Health.Changes;
