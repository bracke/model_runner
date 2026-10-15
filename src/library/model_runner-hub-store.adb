with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;

with Hostkit.Fs;
with Hostkit.Locks;

package body Model_Runner.Hub.Store is

   package T renames Model_Runner.Text;
   package Lines is new Ada.Containers.Indefinite_Vectors (Positive, String);

   Tab : constant Character := ASCII.HT;

   --  A line's fields, split at its tabs: Reference, Repo, Index, Count,
   --  Local, Name, Size, SHA-256 (or "-"), Revision (or "-").
   Field_Count : constant := 9;
   type Field_Bounds is array (1 .. Field_Count) of Natural;

   procedure Split
     (Line : String; Firsts, Lasts : out Field_Bounds; Ok : out Boolean)
   is
      Field : Positive := 1;
      Start : Positive := Line'First;
   begin
      Firsts := [others => 1];
      Lasts := [others => 0];
      Ok := False;
      for I in Line'First .. Line'Last + 1 loop
         if I > Line'Last or else Line (I) = Tab then
            if Field > Field_Count then
               return;
            end if;
            Firsts (Field) := Start;
            Lasts (Field) := I - 1;
            Field := Field + 1;
            Start := I + 1;
         end if;
      end loop;
      Ok := Field = Field_Count + 1;
   end Split;

   function Manifest (Directory : String) return String
   is (Hostkit.Fs.Join (Directory, Manifest_Name));

   package IO renames Ada.Streams.Stream_IO;

   --  The manifest's lines, read whole: a file of a few lines a model.
   function Read_All (Directory : String) return Lines.Vector is
      Result : Lines.Vector;
      File   : IO.File_Type;
   begin
      if not Ada.Directories.Exists (Manifest (Directory)) then
         return Result;
      end if;
      IO.Open (File, IO.In_File, Manifest (Directory));
      declare
         Text  : String (1 .. Natural (IO.Size (File)));
         Start : Positive := 1;
      begin
         String'Read (IO.Stream (File), Text);
         IO.Close (File);
         for I in Text'Range loop
            if Text (I) = ASCII.LF then
               if I > Start then
                  Result.Append
                    (Text (Start .. (if Text (I - 1) = ASCII.CR then I - 2
                                     else I - 1)));
               end if;
               Start := I + 1;
            end if;
         end loop;
         if Start <= Text'Last then
            Result.Append (Text (Start .. Text'Last));
         end if;
      end;
      return Result;
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
         return Result;
   end Read_All;

   --  The manifest rewritten whole and put in its place in one step.
   procedure Write_All (Directory : String; Items : Lines.Vector) is
      Part : constant String := Manifest (Directory) & ".part";
      File : IO.File_Type;
   begin
      IO.Create (File, IO.Out_File, Part);
      for Line of Items loop
         String'Write (IO.Stream (File), Line & ASCII.LF);
      end loop;
      IO.Close (File);
      if not Hostkit.Fs.Replace_File (Part, Manifest (Directory)) then
         Ada.Directories.Delete_File (Part);
      end if;
   exception
      when others =>
         if IO.Is_Open (File) then
            IO.Close (File);
         end if;
   end Write_All;

   function Field (Line : String; Which : Positive) return String is
      Firsts, Lasts : Field_Bounds;
      Ok : Boolean;
   begin
      Split (Line, Firsts, Lasts, Ok);
      return (if Ok then Line (Firsts (Which) .. Lasts (Which)) else "");
   end Field;

   ------------
   -- Origin --
   ------------

   function Origin (Directory, Local : String) return String is
   begin
      for Line of Read_All (Directory) loop
         if Field (Line, 5) = Local then
            return Field (Line, 2);
         end if;
      end loop;
      return "";
   end Origin;

   -----------
   -- Place --
   -----------

   function Place (Directory, Repo, Name : String) return String is
      Was : constant String := Origin (Directory, Name);
   begin
      if Was = "" or else Was = Repo
        or else not Is_Safe_File_Name (Repo & "/" & Name)
      then
         return Name;
      end if;
      return Repo & "/" & Name;
   end Place;

   ----------
   -- Note --
   ----------

   procedure Note
     (Directory : String;
      Reference : String;
      Repo      : String;
      Files     : File_Set;
      Locals    : Local_Names;
      Count     : Natural)
   is
      Held  : Hostkit.Locks.Lock;
      Kept  : Lines.Vector;
      Outcome : Hostkit.Locks.Lock_Outcome;
      pragma Unreferenced (Outcome);

      function Is_Ours (Local : String) return Boolean is
      begin
         for I in 1 .. Count loop
            if T.To_String (Locals (I)) = Local then
               return True;
            end if;
         end loop;
         return False;
      end Is_Ours;

      function Image (Value : Natural) return String
      is (T.Trim (Natural'Image (Value)));
   begin
      --  A reference or a repository with a tab or a line end in it would
      --  read back as other fields; none the hub names has one.
      declare
         Both : constant String := Reference & Repo;
      begin
         for C of Both loop
            if C in Tab | ASCII.LF | ASCII.CR then
               return;
            end if;
         end loop;
      end;

      Outcome := Hostkit.Locks.Acquire
        (Manifest (Directory) & ".lock", Hostkit.Locks.Lock_Exclusive,
         Wait => True, Item => Held);
      for Line of Read_All (Directory) loop
         if Field (Line, 1) /= Reference and then not Is_Ours (Field (Line, 5)) then
            Kept.Append (Line);
         end if;
      end loop;
      for I in 1 .. Count loop
         Kept.Append
           (Reference & Tab & Repo & Tab & Image (I) & Tab & Image (Count)
            & Tab & T.To_String (Locals (I))
            & Tab & T.To_String (Files (I).Name)
            & Tab & T.Trim (Interfaces.Unsigned_64'Image (Files (I).Size))
            & Tab & (if Files (I).Has_Hash then Files (I).SHA256 else "-")
            & Tab & (if T.Is_Empty (Files (I).Revision) then "-"
                     else T.To_String (Files (I).Revision)));
      end loop;
      Write_All (Directory, Kept);
      if Hostkit.Locks.Is_Held (Held) then
         Hostkit.Locks.Release (Held);
      end if;
   exception
      when others =>
         if Hostkit.Locks.Is_Held (Held) then
            Hostkit.Locks.Release (Held);
         end if;
   end Note;

   ----------
   -- Find --
   ----------

   procedure Find
     (Directory : String;
      Reference : String;
      Repo      : out Model_Runner.Text.Bounded;
      Files     : out File_Set;
      Locals    : out Local_Names;
      Count     : out Natural;
      Found     : out Boolean)
   is
      Seen : array (1 .. Max_Files) of Boolean := [others => False];
   begin
      Repo := T.Empty;
      Files := [others => <>];
      Locals := [others => T.Empty];
      Count := 0;
      Found := False;

      for Line of Read_All (Directory) loop
         if Field (Line, 1) = Reference then
            declare
               Index : constant Natural := Natural'Value (Field (Line, 3));
               Total : constant Natural := Natural'Value (Field (Line, 4));
               Local : constant String := Field (Line, 5);
               Digest : constant String := Field (Line, 8);
               Revision : constant String := Field (Line, 9);
            begin
               if Total in 1 .. Max_Files and then Index in 1 .. Total
                 and then (Count = 0 or else Count = Total)
                 and then Is_Safe_File_Name (Local)
               then
                  Count := Total;
                  Repo := T.To_Bounded (Field (Line, 2));
                  Seen (Index) := True;
                  Locals (Index) := T.To_Bounded (Local);
                  Files (Index) :=
                    (Name     => T.To_Bounded (Field (Line, 6)),
                     Size     => Interfaces.Unsigned_64'Value (Field (Line, 7)),
                     SHA256   => (if Digest'Length = 64 then Digest else [1 .. 64 => '0']),
                     Has_Hash => Digest'Length = 64,
                     Revision => (if Revision = "-" then T.Empty else T.To_Bounded (Revision)));
               end if;
            exception
               when Constraint_Error =>
                  null;
            end;
         end if;
      end loop;

      Found := Count > 0 and then (for all I in 1 .. Count => Seen (I));
      if not Found then
         Count := 0;
      end if;
   end Find;

   ------------
   -- Forget --
   ------------

   procedure Forget (Directory, Local : String) is
      Held  : Hostkit.Locks.Lock;
      Kept  : Lines.Vector;
      Dropped : Boolean := False;
      Outcome : Hostkit.Locks.Lock_Outcome;
      pragma Unreferenced (Outcome);
   begin
      if not Ada.Directories.Exists (Manifest (Directory)) then
         return;
      end if;
      Outcome := Hostkit.Locks.Acquire
        (Manifest (Directory) & ".lock", Hostkit.Locks.Lock_Exclusive,
         Wait => True, Item => Held);
      --  A reference is dropped whole where one of its files goes: what is
      --  left of it is no model to open offline.
      declare
         All_Lines : constant Lines.Vector := Read_All (Directory);
         Gone      : Lines.Vector;
      begin
         for Line of All_Lines loop
            if Field (Line, 5) = Local then
               Gone.Append (Field (Line, 1));
               Dropped := True;
            end if;
         end loop;
         for Line of All_Lines loop
            if not Gone.Contains (Field (Line, 1)) then
               Kept.Append (Line);
            end if;
         end loop;
      end;
      if Dropped then
         Write_All (Directory, Kept);
      end if;
      if Hostkit.Locks.Is_Held (Held) then
         Hostkit.Locks.Release (Held);
      end if;
   exception
      when others =>
         if Hostkit.Locks.Is_Held (Held) then
            Hostkit.Locks.Release (Held);
         end if;
   end Forget;

end Model_Runner.Hub.Store;
