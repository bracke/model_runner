with Ada.Directories;
with Ada.Exceptions;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with CryptoLib.Hashes;
with Hostkit.Fs;
with Hostkit.Metadata;

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

   --  Binary and oversized files still take part in a snapshot.  Hash a
   --  bounded sample: all of a small binary, or equal pieces from the start
   --  and end of an oversized file.  Size and a reliable host change identity
   --  cover its unsampled middle.  Without that identity, capture fails closed
   --  instead of making work proportional to an arbitrary artifact's size.
   function Raw_Revision
     (Path     : String;
      Reliable : out Boolean) return String
   is
      package Stream_IO renames Ada.Streams.Stream_IO;
      use Ada.Streams;
      use type Stream_IO.Count;
      Raw_Most : constant Stream_IO.Count :=
        Stream_IO.Count (Model_Runner.Tools.Editing.Text_Most);
      Context : CryptoLib.Hashes.SHA256_Context;
      File    : Stream_IO.File_Type;
      Buffer  : Stream_Element_Array (1 .. 64 * 1_024);
      Digest  : CryptoLib.Hashes.SHA256_Digest;
      Hex     : constant String := "0123456789abcdef";
      Result  : String (1 .. 64);

      procedure Hash_Range
        (First  : Stream_IO.Positive_Count;
         Amount : Stream_IO.Count)
      is
         Remaining : Stream_IO.Count := Amount;
         Last      : Stream_Element_Offset;
      begin
         if Remaining = 0 then
            return;
         end if;
         Stream_IO.Set_Index (File, First);
         while Remaining > 0 loop
            declare
               Want : constant Stream_Element_Offset :=
                 Stream_Element_Offset'Min
                   (Buffer'Length, Stream_Element_Offset (Remaining));
            begin
               Stream_IO.Read
                 (File, Buffer (Buffer'First .. Buffer'First + Want - 1), Last);
            end;
            exit when Last < Buffer'First;
            CryptoLib.Hashes.Update (Context, Buffer (Buffer'First .. Last));
            Remaining := Remaining - Stream_IO.Count (Last - Buffer'First + 1);
         end loop;
      end Hash_Range;
   begin
      Reliable := False;
      CryptoLib.Hashes.Initialize_SHA256 (Context);
      Stream_IO.Open (File, Stream_IO.In_File, Path, Form => "shared=yes");
      declare
         Size : constant Stream_IO.Count := Stream_IO.Size (File);
         Fine : Boolean;
         Stamp : constant String := Hostkit.Metadata.Change_Stamp (Path, Fine);
      begin
         if Size > Raw_Most and then not Fine then
            Stream_IO.Close (File);
            Reliable := False;
            return "metadata unavailable for oversized file";
         elsif Size <= Raw_Most then
            Hash_Range (1, Size);
         else
            Hash_Range (1, Raw_Most / 2);
            Hash_Range
              (Stream_IO.Positive_Count (Size - Raw_Most / 2 + 1),
               Raw_Most / 2);
         end if;
         Stream_IO.Close (File);
         Digest := CryptoLib.Hashes.Finalize (Context);
         for Index in Digest'Range loop
            Result (2 * Index - 1) := Hex (Natural (Digest (Index)) / 16 + 1);
            Result (2 * Index) := Hex (Natural (Digest (Index)) mod 16 + 1);
         end loop;
         Reliable := True;
         return Result & "|size:" & Stream_IO.Count'Image (Size)
           & "|metadata:" & Stamp;
      end;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            begin
               Stream_IO.Close (File);
            exception
               when others =>
                  null;
            end;
         end if;
         declare
            Fine : Boolean;
            Stamp : constant String := Hostkit.Metadata.Change_Stamp (Path, Fine);
         begin
            Reliable := Fine;
            return "metadata:" & Stamp;
         exception
            when others =>
               Reliable := False;
               return "unreadable";
         end;
   end Raw_Revision;

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

   procedure Clear (Changes : in out Change_Set) is
   begin
      Changes.Items.Clear;
      Changes.Id := Null_Unbounded_String;
   end Clear;

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
         Linked : constant Boolean := Hostkit.Fs.Is_Link (Full);
         Actual : constant String :=
           (if Linked then Hostkit.Fs.Real_Path (Full) else Full);
         Actual_Relative : constant String :=
           Model_Runner.Framework.Repository.Relative_Path (Root_Path, Actual);
         Text : Unbounded_String;
         Read : E.Error_Info;
         Raw  : Unbounded_String;
         Reliable : Boolean := True;
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
            Raw := To_Unbounded_String (Raw_Revision (Actual, Reliable));
            if not Reliable then
               Status := E.Make (E.IO_Read_Failed);
               E.Add_Text (Status, "path", Relative, E.Param_Path);
               E.Add_Text
                 (Status, "detail",
                  "the file could neither be read nor identified by reliable metadata");
               return;
            end if;
         end if;
         declare
            Identity : R.Item := R.Create ("code_health.file", 1, "FILE", 1);
            Metadata : constant Hostkit.Metadata.Entry_Revision :=
              Hostkit.Metadata.Entry_Revision_Of (Actual);
         begin
            R.Set
              (Identity, "content",
               (if E.Is_Ok (Read)
                then Model_Runner.Tools.Editing.Revision (To_String (Text))
                else To_String (Raw)));
            R.Set
              (Identity, "link_target",
               (if Linked then Normal (Actual_Relative) else ""));
            R.Set
              (Identity, "mode",
               (if Metadata.Available
                then Hostkit.Metadata.Identity_Field'Image (Metadata.Mode)
                else "unavailable"));
            Result.Files.Append
              (File_State'
                 (Path => To_Unbounded_String (Normal (Relative)),
                  Hash => To_Unbounded_String (R.Fingerprint_Of (Identity))));
         end;
      exception
         when Failure : others =>
            Result.Skipped.Append
              (Normal (Relative) & ": " & Ada.Exceptions.Exception_Name (Failure));
            Status := E.Make (E.IO_Read_Failed);
            E.Add_Text (Status, "path", Relative, E.Param_Path);
            E.Add_Text
              (Status, "detail",
               "the file could not be represented in an authoritative snapshot");
      end Add_File;

      procedure Add_Directory_Link
        (Relative : String;
         Actual   : String)
      is
         Identity : R.Item := R.Create ("code_health.file", 1, "FILE", 1);
      begin
         R.Set (Identity, "content", "directory-link");
         R.Set
           (Identity, "link_target",
            Normal (Model_Runner.Framework.Repository.Relative_Path (Root_Path, Actual)));
         Result.Files.Append
           (File_State'
              (Path => To_Unbounded_String (Normal (Relative)),
               Hash => To_Unbounded_String (R.Fingerprint_Of (Identity))));
      end Add_Directory_Link;

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
                           Add_Directory_Link (Relative, Actual);
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

   function File_Count (From : Snapshot) return Natural is
     (Natural (From.Files.Length));

   function File_At (From : Snapshot; Index : Positive) return String is
     (To_String (From.Files.Element (Index).Path));

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
