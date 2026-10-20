with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Hash;

with Hostkit.Durability;
with Hostkit.Directory_Listing;
with Hostkit.Fs;
with Hostkit.Host;
with Hostkit.Process;

with Model_Runner.Framework.Files;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Stores is

   --  The records commits wrote, each as its root and its name a tab
   --  apart, with the number of the commit that last wrote it: what
   --  Restore_State leaves as the harness's own. One entry a record, so it
   --  grows with the records, not the commits. Several tasks of one
   --  session commit, so it is guarded.
   package Seen_At is new Ada.Containers.Indefinite_Hashed_Maps
     (Key_Type => String, Element_Type => Natural, Hash => Ada.Strings.Hash, Equivalent_Keys => "=");

   --  What the harness has under way beside the store -- a taking in's
   --  journal -- each as its root and the start of its path a tab apart:
   --  its own to settle, not put back by Restore_State; one an agent made
   --  is not among them, and is.
   protected Own_Files is
      procedure Hold (Root_Path, Prefix : String);
      procedure Release (Root_Path, Prefix : String);
      function Holds (Root_Path, Relative : String) return Boolean;
   private
      Held : Name_Lists.Vector;
   end Own_Files;

   protected body Own_Files is
      procedure Hold (Root_Path, Prefix : String) is
      begin
         if not Held.Contains (Root_Path & ASCII.HT & Prefix) then
            Held.Append (Root_Path & ASCII.HT & Prefix);
         end if;
      end Hold;

      procedure Release (Root_Path, Prefix : String) is
         At_Index : constant Natural := Held.Find_Index (Root_Path & ASCII.HT & Prefix);
      begin
         if At_Index /= Name_Lists.No_Index then
            Held.Delete (At_Index);
         end if;
      end Release;

      function Holds (Root_Path, Relative : String) return Boolean is
      begin
         for Line of Held loop
            declare
               Tab    : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
               Prefix : constant String := Line (Tab + 1 .. Line'Last);
            begin
               --  The path itself, or one under it or beside it as its own
               --  -- integrating-WS-1 and integrating-WS-1.before, not
               --  integrating-WS-10.
               if Line (Line'First .. Tab - 1) = Root_Path and then Relative'Length >= Prefix'Length
                 and then Relative (Relative'First .. Relative'First + Prefix'Length - 1) = Prefix
                 and then (Relative'Length = Prefix'Length
                           or else Relative (Relative'First + Prefix'Length) in '.' | '/')
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Holds;
   end Own_Files;

   procedure Hold_Own (Item : Store; Prefix : String) is
   begin
      Own_Files.Hold (Root (Item), Prefix);
   end Hold_Own;

   procedure Release_Own (Item : Store; Prefix : String) is
   begin
      Own_Files.Release (Root (Item), Prefix);
   end Release_Own;

   protected Written is
      procedure Add (Root_Path : String; Names : Name_Lists.Vector);
      --  The print of what a commit installed under a name: a record the
      --  harness wrote is told from one changed behind it after.
      procedure Note_Print (Root_Path, Name, Print : String);
      function Print_Of (Root_Path, Name : String) return String;
      function Count return Natural;
      function Since (Root_Path : String; From : Natural) return Name_Lists.Vector;
   private
      Commits : Natural := 0;
      Last    : Seen_At.Map;
      Prints  : Text_Maps.Map;
   end Written;

   protected body Written is
      procedure Add (Root_Path : String; Names : Name_Lists.Vector) is
      begin
         Commits := Commits + 1;
         for Name of Names loop
            Last.Include (Root_Path & ASCII.HT & Name, Commits);
         end loop;
      end Add;

      procedure Note_Print (Root_Path, Name, Print : String) is
      begin
         Prints.Include (Root_Path & ASCII.HT & Name, To_Unbounded_String (Print));
      end Note_Print;

      function Print_Of (Root_Path, Name : String) return String
      is (if Prints.Contains (Root_Path & ASCII.HT & Name)
          then To_String (Prints.Element (Root_Path & ASCII.HT & Name)) else "");

      function Count return Natural is (Commits);

      function Since (Root_Path : String; From : Natural) return Name_Lists.Vector is
         Result : Name_Lists.Vector;
         Prefix : constant String := Root_Path & ASCII.HT;
      begin
         for Position in Last.Iterate loop
            declare
               Key : constant String := Seen_At.Key (Position);
            begin
               if Seen_At.Element (Position) > From and then Key'Length > Prefix'Length
                 and then Key (Key'First .. Key'First + Prefix'Length - 1) = Prefix
               then
                  Result.Append (Key (Key'First + Prefix'Length .. Key'Last));
               end if;
            end;
         end loop;
         return Result;
      end Since;
   end Written;

   package E renames Model_Runner.Errors;
   package Dirs renames Ada.Directories;

   use type Hostkit.Locks.Lock_Outcome;
   use Model_Runner.Framework.Files;

   Record_Suffix  : constant String := ".rec";

   Format_File   : constant String := "format.rec";
   Lock_File     : constant String := "lock";
   Journal_Name  : constant String := "journal";
   Manifest_File : constant String := "manifest.rec";
   Pending_File  : constant String := "manifest" & Partial_Suffix;

   Identity_Name : constant String := "identity";
   Counters_Name : constant String := "counters";
   Index_Name    : constant String := "entities";

   Identity_Entity : constant String := "PROJECT";
   Root_Entity     : constant String := "ROOT";
   Index_Entity    : constant String := "INDEX";
   Journal_Entity  : constant String := "JOURNAL";

   ---------------------------------------------------------------------------
   --  Paths.
   ---------------------------------------------------------------------------

   function Join (Base, Part : String) return String
   renames Hostkit.Fs.Join;

   function Area_Directory (Root : String; Where : Area) return String
   is (Join (Root, Directory_Name (Where)));

   function Record_Path
     (Root : String; Where : Area; Name : String) return String
   is (Join (Area_Directory (Root, Where), Name & Record_Suffix));

   --  A record's name under the state root as the snapshot and the
   --  written log both spell it, "/" between its parts on every host.
   function Record_Name (Where : Area; Name : String) return String
   is (Directory_Name (Where) & "/" & Name & Record_Suffix);

   function Journal_Directory (Root : String) return String
   is (Join (Area_Directory (Root, Runtime_Area), Journal_Name));

   --  How a record is named in a diagnostic and in the index.
   function Place_Of (Where : Area; Name : String) return String
   is (Directory_Name (Where) & "/" & Name);

   --  Six digits, for the operations of a journal.
   function Six (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
      Plain : constant String := Image (Image'First + 1 .. Image'Last);
   begin
      return [1 .. Integer'Max (0, 6 - Plain'Length) => '0'] & Plain;
   end Six;

   --  Nine digits, which is what a sequence is written with so that its
   --  names sort as its numbers do.
   function Nine (Value : Natural) return String is
      Image : constant String := Natural'Image (Value);
      Plain : constant String := Image (Image'First + 1 .. Image'Last);
   begin
      return [1 .. Integer'Max (0, 9 - Plain'Length) => '0'] & Plain;
   end Nine;

   function Image (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   --  The area a directory name is, if it is one.
   procedure Area_Of
     (Directory : String;
      Where     : out Area;
      Found     : out Boolean)
   is
   begin
      for Candidate in Area loop
         if Directory_Name (Candidate) = Directory then
            Where := Candidate;
            Found := True;
            return;
         end if;
      end loop;
      Where := Project_Area;
      Found := False;
   end Area_Of;

   --  Whether the index keeps the records of an area. Runtime state names
   --  the same entities the authored state does, and the index is itself
   --  derived, so only authored and historical records are in it.
   function Indexed (Where : Area) return Boolean
   is (Class_Of (Where) in Authored_State | Historical_State);

   --  The words of an operation line.
   function Word (Text : String; Which : Positive) return String is
      Count : Natural := 0;
      Start : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ' ' then
            Count := Count + 1;
            if Count = Which then
               return Text (Start .. Index - 1);
            end if;
            Start := Index + 1;
         end if;
      end loop;
      return "";
   end Word;

   --  Read a record from a file and check it against its schema.
   --  The large records this process parsed last, each with the text it
   --  was parsed from: a record read again whose text is the same text is
   --  the same record, and a derived index of megabytes is read by every
   --  command that opens the project. Compared whole, so a rewrite of the
   --  same size in the same second is still seen.
   Parsed_Least : constant := 256 * 1024;
   Parsed_Count : constant := 4;

   type Parsed_Record is record
      Path  : Unbounded_String;
      Text  : Unbounded_String;
      Value : Records.Item;
   end record;

   Parsed : array (1 .. Parsed_Count) of Parsed_Record;

   --  Held while Parsed is read or written.
   protected Parsed_Lock is
      entry Seize;
      procedure Release;
   private
      Held : Boolean := False;
   end Parsed_Lock;

   protected body Parsed_Lock is
      entry Seize when not Held is
      begin
         Held := True;
      end Seize;

      procedure Release is
      begin
         Held := False;
      end Release;
   end Parsed_Lock;

   --  A directory as its whole path, for saying where: . is no place.
   function Whole (Directory : String) return String is
   begin
      return (if Dirs.Exists (Directory) then Dirs.Full_Name (Directory) else Directory);
   exception
      when others =>
         return Directory;
   end Whole;

   procedure Read_Record
     (Path   : String;
      Origin : String;
      Value  : out Records.Item;
      Status : out E.Error_Info)
   is
      Text  : Unbounded_String;
      Large : Boolean := False;
      Key   : constant String := Path & ASCII.NUL & Origin;
   begin
      Value := Records.Create ("", 1, "", 0);
      Read_Text (Path, Text, Status);
      if E.Is_Ok (Status) and then Length (Text) >= Parsed_Least then
         Large := True;
         Parsed_Lock.Seize;
         for One of Parsed loop
            if One.Path = Key and then One.Text = Text then
               Value := One.Value;
               Parsed_Lock.Release;
               return;
            end if;
         end loop;
         Parsed_Lock.Release;
      end if;
      if E.Is_Ok (Status) then
         Records.Parse (To_String (Text), Origin, Value, Status);
      end if;
      --  Written at an earlier version of its schema, it is carried forward
      --  first; a later one is left to Validate to refuse.
      if E.Is_Ok (Status)
        and then Schemas.Current_Version (Records.Schema_Id (Value)) > 0
        and then Records.Schema_Version (Value)
                   < Schemas.Current_Version (Records.Schema_Id (Value))
      then
         Schemas.Migrate
           (Value, Schemas.Current_Version (Records.Schema_Id (Value)), Status);
      end if;
      if E.Is_Ok (Status) then
         Schemas.Validate (Value, Origin, Status);
      end if;
      if Large and then E.Is_Ok (Status) then
         Parsed_Lock.Seize;
         Parsed (2 .. Parsed'Last) := Parsed (1 .. Parsed'Last - 1);
         Parsed (1) := (To_Unbounded_String (Key), Text, Value);
         Parsed_Lock.Release;
      end if;
   end Read_Record;

   ---------------------------------------------------------------------------
   --  Names and paths a caller sees.
   ---------------------------------------------------------------------------

   -------------
   -- Is_Name --
   -------------

   function Is_Name (Name : String) return Boolean is
   begin
      if Name'Length = 0 or else Name'Length > 128
        or else Name (Name'First) not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
        or else Ends_With (Name, Partial_Suffix)
      then
         return False;
      end if;
      return
        (for all Char of Name =>
           Char in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '-');
   end Is_Name;

   ----------------
   -- State_Root --
   ----------------

   function State_Root (Project_Directory : String) return String
   is (Join (Project_Directory, State_Directory));

   --------------------
   -- Is_Initialized --
   --------------------

   function Is_Initialized (Project_Directory : String) return Boolean
   is (Dirs.Exists (Join (State_Root (Project_Directory), Format_File)));

   -------------
   -- Is_Open --
   -------------

   function Is_Open (Item : Store) return Boolean
   is (Item.Opened);

   ----------
   -- Root --
   ----------

   function Root (Item : Store) return String
   is (To_String (Item.Root));

   ----------------
   -- Project_Id --
   ----------------

   function Project_Id (Item : Store) return String
   is (To_String (Item.Project_Id));

   ------------------
   -- Project_Name --
   ------------------

   function Project_Name (Item : Store) return String
   is (To_String (Item.Project_Name));

   ---------------------------------------------------------------------------
   --  Reading.
   ---------------------------------------------------------------------------

   procedure Not_Open (Item : Store; Status : out E.Error_Info) is
   begin
      Status := E.Make (E.Framework_Not_Initialized);
      E.Add_Text (Status, "path", Root (Item), E.Param_Path);
   end Not_Open;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : Store;
      Where  : Area;
      Name   : String;
      Value  : out Records.Item;
      Status : out Model_Runner.Errors.Error_Info) is
   begin
      Value := Records.Create ("", 1, "", 0);
      if not Item.Opened then
         Not_Open (Item, Status);
      elsif not Is_Name (Name) then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Name);
      elsif not Exists (Item, Where, Name) then
         --  Said as what is missing -- TASK-001, not tasks/TASK-001.state.
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text
           (Status, "name",
            (declare
               Dot : constant Natural := Ada.Strings.Fixed.Index (Name, ".");
             begin
               (if Dot > Name'First then Name (Name'First .. Dot - 1) else Name)));
         E.Add_Text (Status, "path", Place_Of (Where, Name), E.Param_Path);
      else
         Read_Record
           (Record_Path (Root (Item), Where, Name), Place_Of (Where, Name),
            Value, Status);
      end if;
   end Read;

   ------------
   -- Exists --
   ------------

   function Exists (Item : Store; Where : Area; Name : String) return Boolean
   is (Item.Opened and then Is_Name (Name)
       and then Dirs.Exists (Record_Path (Root (Item), Where, Name)));

   -----------
   -- Names --
   -----------

   function Names (Item : Store; Where : Area) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      if not Item.Opened then
         return Result;
      end if;

      for File of Files_In (Area_Directory (Root (Item), Where)) loop
         if Ends_With (File, Record_Suffix) then
            declare
               Name : constant String :=
                 File (File'First .. File'Last - Record_Suffix'Length);
            begin
               if Is_Name (Name) then
                  Result.Append (Name);
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Names;

   ----------------------
   -- Current_Revision --
   ----------------------

   function Current_Revision
     (Item  : Store;
      Where : Area;
      Name  : String) return Natural
   is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Read (Item, Where, Name, Value, Status);
      return (if E.Is_Ok (Status) then Records.Revision (Value) else 0);
   end Current_Revision;

   ---------------------------------------------------------------------------
   --  Transactions.
   ---------------------------------------------------------------------------

   --  Where a transaction already changes a record, or zero.
   function Position
     (Change : Transaction;
      Where  : Area;
      Name   : String) return Natural is
   begin
      for Index in 1 .. Natural (Change.Operations.Length) loop
         if Change.Operations (Index).Where = Where
           and then To_String (Change.Operations (Index).Name) = Name
         then
            return Index;
         end if;
      end loop;
      return 0;
   end Position;

   ---------
   -- Put --
   ---------

   procedure Put
     (Change : in out Transaction;
      Where  : Area;
      Name   : String;
      Value  : Records.Item)
   is
      Held : constant Natural := Position (Change, Where, Name);
      Next : constant Operation :=
        (Kind  => Put_Operation,
         Where => Where,
         Name  => To_Unbounded_String (Name),
         Value => Value);
   begin
      if Held = 0 then
         Change.Operations.Append (Next);
      else
         Change.Operations (Held) := Next;
      end if;
   end Put;

   ------------
   -- Remove --
   ------------

   procedure Remove
     (Change : in out Transaction;
      Where  : Area;
      Name   : String;
      Seen   : Natural := 0)
   is
      Held : constant Natural := Position (Change, Where, Name);
      --  The revision it was read at, carried as its value's.
      Next : constant Operation :=
        (Kind  => Remove_Operation,
         Where => Where,
         Name  => To_Unbounded_String (Name),
         Value => Records.Create ("", 1, "", Seen));
   begin
      if Held = 0 then
         Change.Operations.Append (Next);
      else
         Change.Operations (Held) := Next;
      end if;
   end Remove;

   -------------
   -- Pending --
   -------------

   procedure Pending
     (Change : Transaction;
      Where  : Area;
      Name   : String;
      Value  : out Records.Item;
      Found  : out Boolean)
   is
      Held : constant Natural := Position (Change, Where, Name);
   begin
      Found := Held /= 0
        and then Change.Operations (Held).Kind = Put_Operation;
      Value :=
        (if Found then Change.Operations (Held).Value
         else Records.Create ("", 1, "", 0));
   end Pending;

   function Pending_Names (Change : Transaction; Where : Area) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for One of Change.Operations loop
         if One.Kind = Put_Operation and then One.Where = Where
           and then not Result.Contains (To_String (One.Name))
         then
            Result.Append (To_String (One.Name));
         end if;
      end loop;
      return Result;
   end Pending_Names;

   ------------------
   -- Change_Count --
   ------------------

   function Change_Count (Change : Transaction) return Natural
   is (Natural (Change.Operations.Length));

   ---------------------
   -- Allocate_Number --
   ---------------------

   function Last_Number (Item : Store; Namespace : String) return Natural is
      Counters : Records.Item;
      Status   : E.Error_Info;
   begin
      if not Exists (Item, Project_Area, Counters_Name) then
         return 0;
      end if;
      Read (Item, Project_Area, Counters_Name, Counters, Status);
      if E.Is_Error (Status) then
         return 0;
      end if;
      declare
         Held : constant String := Records.Get (Counters, "next." & Namespace);
         Next : Natural := 0;
      begin
         for Char of Held loop
            exit when Char not in '0' .. '9' or else Next > 99_999_999;
            Next := Next * 10 + (Character'Pos (Char) - Character'Pos ('0'));
         end loop;
         return (if Next = 0 then 0 else Next - 1);
      end;
   end Last_Number;

   procedure Allocate_Number
     (Item      : Store;
      Change    : in out Transaction;
      Namespace : String;
      Key       : String;
      Number    : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Held     : constant Natural :=
        Position (Change, Project_Area, Counters_Name);
      Counters : Records.Item;
   begin
      Number := 0;
      Status := E.Success;

      if Held /= 0
        and then Change.Operations (Held).Kind = Put_Operation
      then
         Counters := Change.Operations (Held).Value;
      elsif Exists (Item, Project_Area, Counters_Name) then
         Read (Item, Project_Area, Counters_Name, Counters, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Counters, Records.Revision (Counters) + 1);
      else
         Counters := Identifiers.Empty_Counters;
      end if;

      Number := Identifiers.Allocate_Number (Counters, Namespace, Key);
      if Number = 0 then
         Status := E.Make (E.Framework_Identifier_Invalid);
         E.Add_Text
           (Status, "value",
            (if Key = "" then Namespace else Namespace & "-" & Key));
         return;
      end if;

      Put (Change, Project_Area, Counters_Name, Counters);
   end Allocate_Number;

   -------------------------
   -- Allocate_Identifier --
   -------------------------

   procedure Allocate_Identifier
     (Item      : Store;
      Change    : in out Transaction;
      Namespace : String;
      Key       : String;
      Id        : out Ada.Strings.Unbounded.Unbounded_String;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Number : Natural;
   begin
      Id := Null_Unbounded_String;
      Allocate_Number (Item, Change, Namespace, Key, Number, Status);
      if E.Is_Ok (Status) then
         Id := To_Unbounded_String (Identifiers.Format (Namespace, Key, Number));
      end if;
   end Allocate_Identifier;

   --------------
   -- Identify --
   --------------

   procedure Identify
     (Item   : Store;
      Change : in out Transaction;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Number : Natural;
   begin
      Status := E.Success;
      if Change.Id = Null_Unbounded_String then
         Allocate_Number (Item, Change, "TXN", "", Number, Status);
         if E.Is_Error (Status) then
            Id := Null_Unbounded_String;
            return;
         end if;
         Change.Id := To_Unbounded_String ("TXN-" & Nine (Number));
      end if;
      Id := Change.Id;
   end Identify;

   ---------------------------------------------------------------------------
   --  The index.
   ---------------------------------------------------------------------------

   function Index_Path (Root : String) return String
   is (Record_Path (Root, Indexes_Area, Index_Name));

   procedure Write_Index
     (Item   : Store;
      Index  : in out Records.Item;
      Status : out E.Error_Info) is
   begin
      Records.Remove (Index, "entries");
      Records.Set (Index, "entries", Image (Records.Field_Count (Index)));
      Write_Whole (Index_Path (Root (Item)), Records.Serialize (Index), Status);
   end Write_Index;

   ---------------------
   -- Journal_Pending --
   ---------------------

   function Journal_Pending (Item : Store) return Boolean
   is (Item.Opened
       and then not Files_In (Journal_Directory (Root (Item))).Is_Empty);

   -------------------
   -- Rebuild_Index --
   -------------------

   procedure Rebuild_Index
     (Item    : in out Store;
      Status  : out Model_Runner.Errors.Error_Info;
      Written : out Boolean)
   is
      Index : Records.Item :=
        Records.Create (Schemas.Index_Schema, 1, Index_Entity, 1);
      First : E.Error_Info := E.Success;
   begin
      Written := False;
      if not Item.Opened then
         Not_Open (Item, Status);
         return;
      end if;

      for Where in Area loop
         if Indexed (Where) then
            for Name of Names (Item, Where) loop
               declare
                  Value : Records.Item;
                  Read_Status : E.Error_Info;
               begin
                  Read (Item, Where, Name, Value, Read_Status);
                  if E.Is_Ok (Read_Status) then
                     Records.Set
                       (Index, "entity." & Records.Entity_Id (Value),
                        Place_Of (Where, Name));
                  elsif E.Is_Ok (First) then
                     First := Read_Status;
                  end if;
               end;
            end loop;
         end if;
      end loop;

      Write_Index (Item, Index, Status);
      Written := E.Is_Ok (Status);
      if E.Is_Ok (Status) then
         Status := First;
      end if;
   end Rebuild_Index;

   procedure Rebuild_Index
     (Item   : in out Store;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Written : Boolean;
   begin
      Rebuild_Index (Item, Status, Written);
   end Rebuild_Index;

   ------------
   -- Lookup --
   ------------

   procedure Lookup
     (Item      : in out Store;
      Entity_Id : String;
      Where     : out Area;
      Name      : out Ada.Strings.Unbounded.Unbounded_String;
      Found     : out Boolean)
   is
      Index  : Records.Item;
      Status : E.Error_Info;
   begin
      Where := Project_Area;
      Name := Null_Unbounded_String;
      Found := False;

      if not Item.Opened or else not Identifiers.Is_Valid (Entity_Id) then
         return;
      end if;

      Read (Item, Indexes_Area, Index_Name, Index, Status);
      if E.Is_Error (Status) and then Item.Read_Only then
         --  Not the reader's to write: the session holding the store may
         --  be writing it now. Built here, for this lookup only.
         Index := Records.Create (Schemas.Index_Schema, 1, Index_Entity, 1);
         for Kept in Area loop
            if Indexed (Kept) then
               for Named of Names (Item, Kept) loop
                  declare
                     Value : Records.Item;
                     Got   : E.Error_Info;
                  begin
                     Read (Item, Kept, Named, Value, Got);
                     if E.Is_Ok (Got) then
                        Records.Set (Index, "entity." & Records.Entity_Id (Value), Place_Of (Kept, Named));
                     end if;
                  end;
               end loop;
            end if;
         end loop;
      elsif E.Is_Error (Status) then
         Rebuild_Index (Item, Status);
         Read (Item, Indexes_Area, Index_Name, Index, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;

      declare
         Place : constant String := Records.Get (Index, "entity." & Entity_Id);
         Slash : Natural := 0;
         Known : Boolean;
      begin
         for Char_At in Place'Range loop
            if Place (Char_At) = '/' then
               Slash := Char_At;
               exit;
            end if;
         end loop;

         if Slash = 0 then
            return;
         end if;

         Area_Of (Place (Place'First .. Slash - 1), Where, Known);
         if Known then
            Name := To_Unbounded_String (Place (Slash + 1 .. Place'Last));
            Found := True;
         end if;
      end;
   end Lookup;

   ---------------------------------------------------------------------------
   --  Committing.
   ---------------------------------------------------------------------------

   --  Remove every file in the journal, the commit mark last, so that an
   --  interruption part way leaves either a journal that is still
   --  committed or one that is not there.
   function Clear_Journal (Root : String) return Boolean is
      Journal : constant String := Journal_Directory (Root);
      Cleared : Boolean := True;
      Listed  : Name_Lists.Vector;
      Read    : E.Error_Info;
   begin
      --  A journal that cannot be listed whole is not cleared: its mark
      --  stays, and the step that asked fails.
      Files_In (Journal, Listed, Read);
      if E.Is_Error (Read) then
         return False;
      end if;
      for File of Listed loop
         if File /= Manifest_File
           and then not Delete_If_Present (Join (Journal, File))
         then
            Cleared := False;
         end if;
      end loop;

      --  The mark stays while anything it covers does.
      return Cleared
        and then Delete_If_Present (Join (Journal, Manifest_File));
   end Clear_Journal;

   --  Put what was written on the device, before anything that depends on
   --  it: a commit is durable before it is exposed. A host that cannot say
   --  whether it is goes on -- it has no better answer -- and one that
   --  says it failed fails the step.
   procedure Made_Durable
     (Path      : String;
      Directory : Boolean;
      Status    : in out Model_Runner.Errors.Error_Info)
   is
      use type Hostkit.Durability.Outcome;
      Got : constant Hostkit.Durability.Outcome :=
        (if Directory then Hostkit.Durability.Sync_Directory (Path)
         else Hostkit.Durability.Sync_File (Path));
   begin
      if E.Is_Ok (Status) and then Got = Hostkit.Durability.Failed then
         Write_Failed (Path, Status);
      end if;
   end Made_Durable;

   -----------
   -- Stage --
   -----------

   procedure Stage
     (Item   : in out Store;
      Change : Transaction;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Journal  : constant String := Journal_Directory (Root (Item));
      Manifest : Records.Item :=
        Records.Create (Schemas.Manifest_Schema, 1, Journal_Entity, 1);
   begin
      Status := E.Success;
      if not Item.Opened then
         Not_Open (Item, Status);
         return;
      end if;

      --  A journal marked and not finished is a change made: finished
      --  before anything else is staged over it, or nothing is staged.
      if Ada.Directories.Exists (Join (Journal, Manifest_File)) then
         Finish (Item, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;

      --  A journal staged and never marked is not a change anybody made.
      if not Make_Directory (Journal) or else not Clear_Journal (Root (Item))
      then
         Write_Failed (Journal, Status);
         return;
      end if;

      for Index in 1 .. Natural (Change.Operations.Length) loop
         declare
            Next   : Operation renames Change.Operations (Index);
            Name   : constant String := To_String (Next.Name);
            Origin : constant String := Place_Of (Next.Where, Name);
            Held   : Records.Item;
            Found  : Boolean := False;
         begin
            if not Is_Name (Name) then
               Status := E.Make (E.Framework_Name_Invalid);
               E.Add_Text (Status, "value", Name);
               return;
            end if;

            if Exists (Item, Next.Where, Name) then
               Read (Item, Next.Where, Name, Held, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Found := True;
            end if;

            case Next.Kind is
               when Put_Operation =>
                  Schemas.Validate (Next.Value, Origin, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  declare
                     Current : constant Natural :=
                       (if Found then Records.Revision (Held) else 0);
                  begin
                     if Records.Revision (Next.Value) /= Current + 1 then
                        Status := E.Make (E.Framework_Revision_Conflict);
                        E.Add_Text (Status, "name", Origin);
                        E.Add_Integer
                          (Status, "actual", Long_Long_Integer (Current));
                        E.Add_Integer
                          (Status, "expected",
                           Long_Long_Integer
                             (Records.Revision (Next.Value)) - 1);
                        return;
                     end if;
                  end;

                  Write_Text
                    (Join (Journal, "op-" & Six (Index) & Record_Suffix),
                     Records.Serialize (Next.Value), Status);
                  Made_Durable
                    (Join (Journal, "op-" & Six (Index) & Record_Suffix), False, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;

                  Records.Set
                    (Manifest, "op." & Six (Index),
                     "put " & Directory_Name (Next.Where) & " " & Name & " "
                     & Records.Entity_Id (Next.Value));

               when Remove_Operation =>
                  --  Removed on what it said at a revision since replaced:
                  --  the newer is not taken away unseen.
                  if Found and then Records.Revision (Next.Value) > 0
                    and then Records.Revision (Held) /= Records.Revision (Next.Value)
                  then
                     Status := E.Make (E.Framework_Revision_Conflict);
                     E.Add_Text (Status, "name", Name);
                     E.Add_Integer (Status, "actual", Long_Long_Integer (Records.Revision (Held)));
                     E.Add_Integer (Status, "expected", Long_Long_Integer (Records.Revision (Next.Value)));
                     return;
                  end if;
                  Records.Set
                    (Manifest, "op." & Six (Index),
                     "remove " & Directory_Name (Next.Where) & " " & Name & " "
                     & (if Found then Records.Entity_Id (Held) else "-"));
            end case;
         end;
      end loop;

      Records.Set
        (Manifest, "operations", Image (Natural (Change.Operations.Length)));
      if Change.Id /= Null_Unbounded_String then
         Records.Set (Manifest, "transaction", To_String (Change.Id));
      end if;
      Write_Text
        (Join (Journal, Pending_File), Records.Serialize (Manifest), Status);
      Made_Durable (Join (Journal, Pending_File), False, Status);
      Made_Durable (Journal, True, Status);
   end Stage;

   ----------
   -- Mark --
   ----------

   procedure Mark
     (Item   : in out Store;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Journal : constant String := Journal_Directory (Root (Item));
   begin
      Status := E.Success;
      if not Item.Opened then
         Not_Open (Item, Status);
      elsif not Dirs.Exists (Join (Journal, Pending_File))
        or else not Hostkit.Fs.Replace_File
                      (Join (Journal, Pending_File),
                       Join (Journal, Manifest_File))
      then
         Write_Failed (Journal, Status);
      else
         --  The mark itself on the device: a commit once it says so.
         Made_Durable (Journal, True, Status);
      end if;
   end Mark;

   ------------
   -- Finish --
   ------------

   --  Where the next commit is to be stopped short, for a test.
   Crash_Armed : Crash_Point := No_Crash;

   procedure Crash_At (Point : Crash_Point) is
   begin
      Crash_Armed := Point;
   end Crash_At;

   --  Stop short here, where a test asked for this point: once.
   procedure Crash_Here (Point : Crash_Point) is
   begin
      if Crash_Armed = Point and then Point /= No_Crash then
         Crash_Armed := No_Crash;
         raise Simulated_Crash;
      end if;
   end Crash_Here;

   procedure Finish
     (Item   : in out Store;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Journal  : constant String := Journal_Directory (Root (Item));
      Manifest : Records.Item;
      Count    : Natural := 0;
      Index    : Records.Item;
      Incremental : Boolean;

      procedure Unrecoverable (Detail : String) is
      begin
         Status := E.Make (E.Framework_Recovery_Required);
         E.Add_Text (Status, "path", Journal, E.Param_Path);
         E.Add_Text (Status, "detail", Detail);
      end Unrecoverable;
   begin
      Status := E.Success;
      if not Item.Opened then
         Not_Open (Item, Status);
         return;
      elsif not Dirs.Exists (Join (Journal, Manifest_File)) then
         return;
      end if;

      Read_Record
        (Join (Journal, Manifest_File), "journal/" & Manifest_File, Manifest,
         Status);
      if E.Is_Error (Status)
        or else Records.Schema_Id (Manifest) /= Schemas.Manifest_Schema
      then
         Unrecoverable ("its list of changes cannot be read");
         return;
      end if;

      --  A count of digits: the manifest's schema holds it to one.
      for Char of Records.Get (Manifest, "operations") loop
         Count := Count * 10 + (Character'Pos (Char) - Character'Pos ('0'));
      end loop;

      --  Apply every change. Each one is a rename or a removal, and one
      --  already done is recognised and passed over, so a journal that was
      --  interrupted while this ran is finished by running it again.
      --
      --  What it writes is said first, in the log a snapshot of the state is
      --  compared with: a change the harness made is not taken for one made
      --  behind its back.
      declare
         Said : Name_Lists.Vector;
      begin
         for Op in 1 .. Count loop
            declare
               Line  : constant String := Records.Get (Manifest, "op." & Six (Op));
               Where : Area;
               Known : Boolean;
            begin
               Area_Of (Word (Line, 2), Where, Known);
               if Known and then Is_Name (Word (Line, 3)) then
                  Said.Append (Record_Name (Where, Word (Line, 3)));
               end if;
            end;
         end loop;
         Said.Append (Record_Name (Indexes_Area, Index_Name));
         Written.Add (Root (Item), Said);
      end;

      for Op in 1 .. Count loop
         --  Some of it applied and the rest not, where a test stops it so.
         if Op = 2 then
            Crash_Here (Mid_Apply);
         end if;
         declare
            Line   : constant String := Records.Get (Manifest, "op." & Six (Op));
            Verb   : constant String := Word (Line, 1);
            Name   : constant String := Word (Line, 3);
            Where  : Area;
            Known  : Boolean;
         begin
            Area_Of (Word (Line, 2), Where, Known);
            if not Known or else not Is_Name (Name)
              or else Verb not in "put" | "remove"
            then
               Unrecoverable ("change" & Natural'Image (Op) & " is not one");
               return;
            end if;

            declare
               Target : constant String := Record_Path (Root (Item), Where, Name);
               Staged : constant String :=
                 Join (Journal, "op-" & Six (Op) & Record_Suffix);
            begin
               if Verb = "put" then
                  --  What is installed is a record: a staged file cut short
                  --  -- by a machine that went down before it was on the
                  --  device -- is not taken for one.
                  if Dirs.Exists (Staged) then
                     declare
                        Text   : Unbounded_String;
                        Read   : E.Error_Info;
                        Parsed : Records.Item;
                     begin
                        Files.Read_Text (Staged, Text, Read);
                        if E.Is_Ok (Read) then
                           Records.Parse (To_String (Text), Staged, Parsed, Read);
                        end if;
                        if E.Is_Error (Read) then
                           Unrecoverable
                             ("the change to " & Place_Of (Where, Name) & " is not a whole record");
                           return;
                        end if;
                        Written.Note_Print (Root (Item), Record_Name (Where, Name), Fingerprint (To_String (Text)));
                     end;
                  end if;
                  if Dirs.Exists (Staged) then
                     if not Make_Directory
                              (Area_Directory (Root (Item), Where))
                       or else not Hostkit.Fs.Replace_File (Staged, Target)
                     then
                        Write_Failed (Target, Status);
                        return;
                     end if;
                  elsif not Dirs.Exists (Target) then
                     Unrecoverable
                       ("the change to " & Place_Of (Where, Name)
                        & " was lost");
                     return;
                  end if;
               elsif not Delete_If_Present (Target) then
                  Write_Failed (Target, Status);
                  return;
               end if;
            end;
         end;
      end loop;

      --  What was installed on the device before the journal that installs
      --  it again can go: each area it went into.
      for Op in 1 .. Count loop
         declare
            Line  : constant String := Records.Get (Manifest, "op." & Six (Op));
            Where : Area;
            Known : Boolean;
         begin
            Area_Of (Word (Line, 2), Where, Known);
            if Known and then Dirs.Exists (Area_Directory (Root (Item), Where)) then
               Made_Durable (Area_Directory (Root (Item), Where), True, Status);
            end if;
         end;
      end loop;
      if E.Is_Error (Status) then
         return;
      end if;

      --  Then the index, which is derived and so is brought up to date
      --  rather than journaled: from the changes when it can be read, and
      --  from the records when it cannot. It is done before the journal
      --  goes, so an interruption here is finished by the next open too.
      Read (Item, Indexes_Area, Index_Name, Index, Status);
      Incremental := E.Is_Ok (Status);
      if Incremental then
         for Op in 1 .. Count loop
            declare
               Line   : constant String :=
                 Records.Get (Manifest, "op." & Six (Op));
               Entity : constant String := Word (Line, 4);
               Place  : constant String := Word (Line, 2) & "/" & Word (Line, 3);
               Where  : Area;
               Known  : Boolean;
            begin
               Area_Of (Word (Line, 2), Where, Known);
               if Known and then Indexed (Where)
                 and then Identifiers.Is_Valid (Entity)
               then
                  if Word (Line, 1) = "put" then
                     Records.Set (Index, "entity." & Entity, Place);
                  elsif Records.Get (Index, "entity." & Entity) = Place then
                     Records.Remove (Index, "entity." & Entity);
                  end if;
               end if;
            end;
         end loop;
         Write_Index (Item, Index, Status);
      else
         Rebuild_Index (Item, Status);
      end if;

      --  An index that could not be written is thrown away, to be built
      --  again when it is next asked for; the change itself stands.
      if E.Is_Error (Status) then
         Discard (Index_Path (Root (Item)));
      end if;
      Status := E.Success;

      if not Clear_Journal (Root (Item)) then
         Write_Failed (Journal, Status);
      end if;
   end Finish;

   -----------
   -- Spoil --
   -----------

   procedure Spoil (Change : in out Transaction; Why : Model_Runner.Errors.Error_Info) is
   begin
      if E.Is_Ok (Change.Spoiled) then
         Change.Spoiled := Why;
      end if;
   end Spoil;

   ------------
   -- Commit --
   ------------

   --  A commit, saying whether this change's own mark was made: failed
   --  after it, the journal holds this change for the next opening;
   --  failed before -- a leftover not finished first among them -- it
   --  holds none of it, whatever journal is there.
   procedure Commit_Marking
     (Item     : in out Store;
      Change   : in out Transaction;
      Status   : out Model_Runner.Errors.Error_Info;
      Own_Mark : out Boolean) is
   begin
      Own_Mark := False;
      Status := E.Success;
      if E.Is_Error (Change.Spoiled) then
         Status := Change.Spoiled;
         Change := No_Changes;
         return;
      end if;
      if Change_Count (Change) = 0 then
         return;
      end if;
      if Item.Read_Only then
         Status := E.Make (E.Framework_Locked);
         E.Add_Text (Status, "path", Root (Item), E.Param_Path);
         E.Add_Text (Status, "detail", "it was opened to be read, while another session holds it");
         return;
      end if;

      --  An earlier change marked and not finished is finished first, and
      --  apart: not finished, it stays for the next opening -- clearing
      --  what this one staged would take its mark with it.
      if Ada.Directories.Exists (Join (Journal_Directory (Root (Item)), Manifest_File)) then
         Finish (Item, Status);
         if E.Is_Error (Status) then
            return;
         end if;
      end if;

      Stage (Item, Change, Status);
      --  Refused while staged -- a record that does not keep to its schema
      --  -- nothing of it is left to be found as an interrupted change.
      if E.Is_Error (Status) and then Clear_Journal (Root (Item)) then
         return;
      elsif E.Is_Error (Status) then
         return;
      end if;
      Crash_Here (After_Journal);
      if E.Is_Ok (Status) then
         Mark (Item, Status);
         --  Its mark is there once renamed in, whatever failed after: any
         --  earlier one was finished before this was staged.
         Own_Mark := Dirs.Exists (Join (Journal_Directory (Root (Item)), Manifest_File));
      end if;
      Crash_Here (After_Mark);
      --  For a test: failed once marked, the change left for the next
      --  opening to finish.
      if E.Is_Ok (Status) and then Crash_Armed = Fail_After_Mark then
         Crash_Armed := No_Crash;
         Write_Failed (Journal_Directory (Root (Item)), Status);
         return;
      end if;
      if E.Is_Ok (Status) then
         Finish (Item, Status);
      end if;
      if E.Is_Ok (Status) then
         Change.Operations.Clear;
         Change.Id := Null_Unbounded_String;
      end if;
   end Commit_Marking;

   procedure Commit
     (Item   : in out Store;
      Change : in out Transaction;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Own_Mark : Boolean;
   begin
      Commit_Marking (Item, Change, Status, Own_Mark);
   end Commit;

   procedure Commit
     (Item   : in out Store;
      Change : in out Transaction;
      Status : out Model_Runner.Errors.Error_Info;
      Marked : out Boolean)
   is
      Own_Mark : Boolean;
   begin
      Commit_Marking (Item, Change, Status, Own_Mark);
      --  Failed after its own mark, the journal holds this change, which
      --  the next opening rolls forward; another's left there is not it.
      Marked := E.Is_Ok (Status) or else (Own_Mark and then Dirs.Exists
                                             (Join (Journal_Directory (Root (Item)), Manifest_File)));
   end Commit;

   ---------------------------------------------------------------------------
   --  Opening.
   ---------------------------------------------------------------------------

   --  Make every area's directory that is not there.
   function Make_Areas (Root : String) return Boolean is
      Made : Boolean := Make_Directory (Root);
   begin
      for Where in Area loop
         Made := Made and then Make_Directory (Area_Directory (Root, Where));
      end loop;
      return Made and then Make_Directory (Journal_Directory (Root));
   end Make_Areas;

   --  What this program was asked to do, as its command line said it.
   function Command_Said return String is
      Text : Unbounded_String := To_Unbounded_String ("model_runner");
   begin
      for Index in 1 .. Ada.Command_Line.Argument_Count loop
         Append (Text, " " & Ada.Command_Line.Argument (Index));
      end loop;
      return To_String (Text);
   end Command_Said;

   --  Beside the lock, the process that holds it.
   Holder_Suffix : constant String := ".holder";

   --  Who holds the lock, as far as can be said: its process, and what to
   --  do about it.
   function Holder_Of (Lock_Path : String) return String is
      use type Hostkit.Process.Presence;
      Held   : Unbounded_String;
      Read   : E.Error_Info;
      Pid    : Integer := 0;
      Doing  : Unbounded_String;
   begin
      if Dirs.Exists (Lock_Path & Holder_Suffix) then
         Files.Read_Text (Lock_Path & Holder_Suffix, Held, Read);
      end if;
      declare
         Text  : constant String := Ada.Strings.Fixed.Trim (To_String (Held), Ada.Strings.Both);
         Space : constant Natural := Ada.Strings.Fixed.Index (Text & " ", " ");
         Num   : constant String := Text (Text'First .. Space - 1);
      begin
         if Num'Length in 1 .. 9 and then (for all C of Num => C in '0' .. '9') then
            Pid := Integer'Value (Num);
         end if;
         if Space < Text'Last then
            Doing := To_Unbounded_String (Text (Space + 1 .. Text'Last));
         end if;
      end;
      if Pid = 0 then
         return "a run in progress, or one that ended and left a program it started";
      elsif Hostkit.Process.Presence_Of (Pid) = Hostkit.Process.Absent then
         return "process" & Pid'Image & " took it and has ended; a program it started still"
           & " holds it -- end that program";
      end if;
      return "process" & Pid'Image
        & (if Doing = Null_Unbounded_String then "" else " (" & To_String (Doing) & ")")
        & "; stop it there, or wait for it to finish";
   end Holder_Of;

   --  Take the state directory for this session.
   procedure Take
     (Item   : in out Store;
      Root   : String;
      Status : out E.Error_Info)
   is
      Lock_Path : constant String := Join (Area_Directory (Root, Runtime_Area),
                                           Lock_File);
      Outcome   : Hostkit.Locks.Lock_Outcome;
   begin
      Status := E.Success;
      if not Make_Areas (Root) then
         Write_Failed (Root, Status);
         return;
      end if;

      Outcome :=
        Hostkit.Locks.Acquire
          (Lock_Path, Hostkit.Locks.Lock_Exclusive, Wait => False,
           Item => Item.Lock);

      --  A host with no locking over this directory is one this program
      --  runs on alone, which is what it is for.
      if Outcome = Hostkit.Locks.Lock_Busy then
         Status := E.Make (E.Framework_Locked);
         E.Add_Text (Status, "path", Root, E.Param_Path);
         E.Add_Text (Status, "detail", Holder_Of (Lock_Path)
                     & "; one command changes a project at a time, work in workspaces too, so"
                     & " this one stops: run it again once that ends -- /task list and /state read"
                     & " the project meanwhile");
      elsif Outcome = Hostkit.Locks.Lock_Error then
         Write_Failed (Lock_Path, Status);
      else
         Item.Root := To_Unbounded_String (Root);
         Item.Opened := True;

         --  Who holds it, for the session that finds it held.
         declare
            Ignored : E.Error_Info;
         begin
            Files.Write_Whole
              (Lock_Path & Holder_Suffix,
               Ada.Strings.Fixed.Trim (Hostkit.Host.Own_Process_Id'Image, Ada.Strings.Both)
               & " " & Command_Said,
               Ignored);
         end;
      end if;
   end Take;

   --  Finish or undo an interrupted change, and remove what writes left
   --  half made.
   procedure Recover
     (Item   : in out Store;
      Report : in out Recovery_Report;
      Status : out E.Error_Info)
   is
      Journal : constant String := Journal_Directory (Root (Item));
   begin
      Status := E.Success;

      if Dirs.Exists (Join (Journal, Manifest_File)) then
         Finish (Item, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Report.Rolled_Forward := Report.Rolled_Forward + 1;
      elsif not Files_In (Journal).Is_Empty then
         if not Clear_Journal (Root (Item)) then
            Write_Failed (Journal, Status);
            return;
         end if;
         Report.Rolled_Back := Report.Rolled_Back + 1;
      end if;

      declare
         procedure Sweep (Directory : String) is
         begin
            for File of Files_In (Directory) loop
               --  And what a whole-file write left part way: its own
               --  partial, hidden beside the file (Editing.Replace). Only the
               --  session holding the lock writes here, and it is opening.
               if (Ends_With (File, Partial_Suffix)
                   or else Ada.Strings.Fixed.Index (File, ".model_runner-partial.") > 0)
                 and then Delete_If_Present (Join (Directory, File))
               then
                  Report.Partials_Removed := Report.Partials_Removed + 1;
               end if;
            end loop;
         end Sweep;
      begin
         Sweep (Root (Item));
         for Where in Area loop
            Sweep (Area_Directory (Root (Item), Where));
         end loop;
      end;
   end Recover;

   --  Read the project's identity into an open store.
   procedure Know_Identity (Item : in out Store; Status : out E.Error_Info) is
      Identity : Records.Item;
   begin
      Read (Item, Project_Area, Identity_Name, Identity, Status);
      if E.Is_Ok (Status) then
         Item.Project_Id :=
           To_Unbounded_String (Records.Get (Identity, "project_id"));
         Item.Project_Name :=
           To_Unbounded_String (Records.Get (Identity, "name"));
      end if;
   end Know_Identity;

   ------------
   -- Create --
   ------------

   procedure Create
     (Item              : in out Store;
      Project_Directory : String;
      Project_Name      : String;
      Status            : out Model_Runner.Errors.Error_Info;
      Initial           : Transaction := No_Changes)
   is
      State  : constant String := State_Root (Project_Directory);
      Report : Recovery_Report;
      Change : Transaction := Initial;
   begin
      Close (Item);

      if Is_Initialized (Project_Directory) then
         Status := E.Make (E.Framework_Already_Initialized);
         E.Add_Text (Status, "path", State, E.Param_Path);
         return;
      elsif Project_Name = ""
        or else (for some Char of Project_Name => Char < ' ')
      then
         Status := E.Make (E.Framework_Name_Invalid);
         E.Add_Text (Status, "value", Project_Name);
         return;
      end if;

      Take (Item, State, Status);
      if E.Is_Ok (Status) then
         Recover (Item, Report, Status);
      end if;

      --  A creation interrupted after its identity was committed is
      --  finished with the identity it had.
      if E.Is_Ok (Status)
        and then not Exists (Item, Project_Area, Identity_Name)
      then
         declare
            Created  : constant String := Timestamp;
            Identity : Records.Item :=
              Records.Create (Schemas.Identity_Schema, 1, Identity_Entity, 1);
         begin
            Records.Set
              (Identity, "project_id",
               "PROJECT-"
               & Ada.Characters.Handling.To_Upper
                   (Fingerprint (Project_Name & Created)));
            Records.Set (Identity, "name", Project_Name);
            Records.Set (Identity, "created_at", Created);
            Put (Change, Project_Area, Identity_Name, Identity);
         end;

         if not Exists (Item, Project_Area, Counters_Name)
           and then Position (Change, Project_Area, Counters_Name) = 0
         then
            Put (Change, Project_Area, Counters_Name,
                 Identifiers.Empty_Counters);
         end if;
         Commit (Item, Change, Status);
      end if;

      if E.Is_Ok (Status) then
         Know_Identity (Item, Status);
      end if;

      if E.Is_Ok (Status) then
         declare
            Root_Record : Records.Item :=
              Records.Create (Schemas.Root_Schema, 1, Root_Entity, 1);
         begin
            Records.Set (Root_Record, "format", Format_Name);
            Records.Set (Root_Record, "state_version", Image (State_Version));
            Records.Set
              (Root_Record, "created_by",
               Model_Runner.Program_Name & " " & Model_Runner.Version);
            Write_Whole
              (Join (State, Format_File), Records.Serialize (Root_Record),
               Status);
         end;
      end if;

      if E.Is_Error (Status) then
         Close (Item);
      end if;
   end Create;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item              : in out Store;
      Project_Directory : String;
      Report            : out Recovery_Report;
      Status            : out Model_Runner.Errors.Error_Info)
   is
      State       : constant String := State_Root (Project_Directory);
      Format_Path : constant String := Join (State, Format_File);
      Root_Record : Records.Item;
      Text        : Unbounded_String;
      --  An index written whole but for records that would not read: the
      --  project opens, and what was left out is said.
      Written : Boolean := False;

      procedure Index_Kept_Without (Built : in out E.Error_Info) is
      begin
         if E.Is_Error (Built) and then Written then
            Report.Index_Unread := To_Unbounded_String
              (E.Text_Of (Built, "path") & E.Text_Of (Built, "name") & " ("
               & E.Error_Code'Image (Built.Code) & ")");
            Built := E.Success;
         end if;
      end Index_Kept_Without;
   begin
      Close (Item);
      Report := (others => <>);

      if not Dirs.Exists (Format_Path) then
         Status := E.Make (E.Framework_Not_Initialized);
         E.Add_Text (Status, "path", Whole (Project_Directory), E.Param_Path);
         return;
      end if;

      Read_Text (Format_Path, Text, Status);
      if E.Is_Ok (Status) then
         Records.Parse (To_String (Text), Format_Path, Root_Record, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      --  The version is looked at before anything else in the record, so
      --  that a later layout is refused as one rather than as a record
      --  that breaks this build's rules.
      declare
         Version : constant String := Records.Get (Root_Record, "state_version");
      begin
         if Version'Length in 1 .. 9
           and then (for all Char of Version => Char in '0' .. '9')
           and then Natural'Value (Version) > State_Version
         then
            Status := E.Make (E.Framework_Format_Unsupported);
            E.Add_Text (Status, "path", State, E.Param_Path);
            E.Add_Integer
              (Status, "version", Long_Long_Integer'Value (Version));
            return;
         end if;
      end;

      Schemas.Validate (Root_Record, Format_Path, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Take (Item, State, Status);
      if E.Is_Ok (Status) then
         Recover (Item, Report, Status);
      end if;
      if E.Is_Ok (Status) then
         Know_Identity (Item, Status);
      end if;

      if E.Is_Ok (Status)
        and then not Dirs.Exists (Index_Path (State))
      then
         Rebuild_Index (Item, Status, Written);
         Report.Index_Rebuilt := True;
         Index_Kept_Without (Status);
      elsif E.Is_Ok (Status) then
         declare
            Index : Records.Item;
         begin
            Read (Item, Indexes_Area, Index_Name, Index, Status);
            if E.Is_Error (Status) then
               Rebuild_Index (Item, Status, Written);
               Report.Index_Rebuilt := True;
               Index_Kept_Without (Status);
            end if;
         end;
      end if;

      if E.Is_Error (Status) then
         Close (Item);
      end if;
   end Open;

   ------------------
   -- Open_To_Read --
   ------------------

   procedure Open_To_Read
     (Item              : in out Store;
      Project_Directory : String;
      Status            : out Model_Runner.Errors.Error_Info)
   is
      State : constant String := State_Root (Project_Directory);
   begin
      Close (Item);
      if not Dirs.Exists (Join (State, Format_File)) then
         Status := E.Make (E.Framework_Not_Initialized);
         E.Add_Text (Status, "path", Whole (Project_Directory), E.Param_Path);
         return;
      end if;
      Item.Root := To_Unbounded_String (State);
      Item.Opened := True;
      Item.Read_Only := True;
      Know_Identity (Item, Status);
      if E.Is_Error (Status) then
         Close (Item);
      end if;
   end Open_To_Read;

   function Is_Read_Only (Item : Store) return Boolean is (Item.Read_Only);

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Store) is
   begin
      if Hostkit.Locks.Is_Held (Item.Lock) then
         Hostkit.Locks.Release (Item.Lock);
      end if;
      Item.Opened := False;
      Item.Read_Only := False;
      Item.Root := Null_Unbounded_String;
      Item.Project_Id := Null_Unbounded_String;
      Item.Project_Name := Null_Unbounded_String;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Store) is
   begin
      Close (Item);
   end Finalize;

   --------------------
   -- Snapshot_State --
   --------------------

   --  Every state file below a directory, relative to the root, with what
   --  it holds; the scratch, the lock and a workspace's tree are left out.
   --  What a snapshot holds of a file that would not read: no text a
   --  record has.
   Unread_Mark : constant String := ASCII.NUL & "unread";

   --  And a link's: kept so, neither read nor walked into -- with what it
   --  names, so a restore makes it again as it was.
   Link_Mark : constant String := ASCII.NUL & "link";

   function Link_Value (Path : String) return Unbounded_String is
      Target : Unbounded_String;
   begin
      if Hostkit.Fs.Read_Link_Target (Path, Target) then
         return To_Unbounded_String (Link_Mark & " ") & Target;
      end if;
      return To_Unbounded_String (Link_Mark);
   end Link_Value;

   function Is_Link_Value (Value : Unbounded_String) return Boolean
   is (Length (Value) >= Link_Mark'Length and then Slice (Value, 1, Link_Mark'Length) = Link_Mark);

   procedure Gather
     (Root, Under : String;
      Into        : in out Text_Maps.Map)
   is
      Search : Ada.Directories.Search_Type;
      Found  : Ada.Directories.Directory_Entry_Type;
      Here   : constant String := (if Under = "" then Root else Hostkit.Fs.Join (Root, Under));
      Listed : Hostkit.Directory_Listing.Entry_Vectors.Vector;
   begin
      --  The links from the folder's own list: one that names nothing is
      --  passed over by the search, which looks at what each names, and
      --  was left by a restore.
      if Hostkit.Directory_Listing.List (Here, Listed) then
         for One of Listed loop
            if One.Name not in "." | ".."
              and then Hostkit.Fs.Is_Link (Hostkit.Fs.Join (Here, One.Name))
            then
               Into.Include ((if Under = "" then One.Name else Under & "/" & One.Name),
                             Link_Value (Hostkit.Fs.Join (Here, One.Name)));
            end if;
         end loop;
      end if;
      --  A folder that will not be listed is there all the same: kept as
      --  that, as a file that will not read is -- raised, nothing at all
      --  was put back after a run that made one so.
      begin
         Ada.Directories.Start_Search (Search, Here, "");
      exception
         when others =>
            Into.Include ((if Under = "" then "." else Under), To_Unbounded_String (Unread_Mark));
            return;
      end;
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found);
         declare
            use type Ada.Directories.File_Kind;
            Name     : constant String := Ada.Directories.Simple_Name (Found);
            Relative : constant String := (if Under = "" then Name else Under & "/" & Name);
         begin
            if Name in "." | ".." then
               null;
            --  A link is the state's as a link, never followed: walked into,
            --  what it named outside was read as the state's, and a restore
            --  deleted every file of it as new.
            elsif Hostkit.Fs.Is_Link (Hostkit.Fs.Join (Here, Name)) then
               Into.Include (Relative, Link_Value (Hostkit.Fs.Join (Here, Name)));
            elsif Ada.Directories.Kind (Found) = Ada.Directories.Directory then
               --  Payloads are the harness's, written as a result is kept --
               --  by name, from what they hold -- not by a commit.
               --  Nor the copies kept of work given up or files it
               --  replaced: kept for a person, written by no commit.
               --  Nor the journal: a change under way, or one left for the
               --  next opening, is the commit's own, put right by it.
               --  Nor the pages made for a person to read: made from the
               --  state, by no commit, and made again from it.
               if Relative not in "runtime/exec" | "runtime/slots" | "results/payloads" | "runtime/journal"
                                | "views"

                 and then not (Under = "workspaces")
                 and then not (Under = "runtime"
                               and then (Ada.Strings.Fixed.Index (Name, "overwritten-") = Name'First
                                         or else Ada.Strings.Fixed.Index (Name, "given-up-") = Name'First
                                         or else Ada.Strings.Fixed.Index (Name, "replaced-") = Name'First
                                         or else Ada.Strings.Fixed.Index (Name, "before-restore-") = Name'First))
               then
                  Gather (Root, Relative, Into);
               end if;
            elsif Ada.Directories.Kind (Found) = Ada.Directories.Ordinary_File
              and then Relative not in "runtime/lock" | "runtime/lock.holder" | "runtime/written.log"
                                     | "runtime/harness.log" | "runtime/consistency.said"
              and then not (Relative'Length > 13
                            and then Relative (Relative'First .. Relative'First + 12) = "runtime/stop.")
              and then not (Relative'Length > 14
                            and then Relative (Relative'First .. Relative'First + 13) = "runtime/group.")
            then
               declare
                  Text : Unbounded_String;
                  Read : E.Error_Info;
               begin
                  Files.Read_Text (Ada.Directories.Full_Name (Found), Text, Read);
                  --  One that will not read is there all the same: kept as
                  --  that, so it is neither put back nor taken for new.
                  Into.Include (Relative, (if E.Is_Ok (Read) then Text else To_Unbounded_String (Unread_Mark)));
               end;
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
   end Gather;

   procedure Snapshot_State (Item : Store; Into : out State_Snapshot) is
   begin
      Into.Files.Clear;
      Into.Logged := 0;
      if Ada.Directories.Exists (Root (Item)) then
         Gather (Root (Item), "", Into.Files);
         Into.Logged := Written.Count;
      end if;
   end Snapshot_State;

   -------------------
   -- Restore_State --
   -------------------

   procedure Restore_State
     (Item    : Store;
      From    : State_Snapshot;
      Changed : out Name_Lists.Vector;
      Left    : out Name_Lists.Vector)
   is
      Now    : State_Snapshot;
      Status : E.Error_Info;

      --  What commits wrote since: the harness's own changes, by this
      --  process or another -- a cancel, another task's work -- and not put
      --  back.
      Committed : Name_Lists.Vector;

      --  Links made since, taken away before anything is written back.
      Unlinked : Name_Lists.Vector;

      --  Whether a map holds a name below NAME, as a folder's.
      function Holds_Below (Map : Text_Maps.Map; Name : String) return Boolean is
         Next : constant Text_Maps.Cursor := Map.Ceiling (Name & "/");
      begin
         return Text_Maps.Has_Element (Next)
           and then Text_Maps.Key (Next)'Length > Name'Length + 1
           and then Text_Maps.Key (Next) (Text_Maps.Key (Next)'First .. Text_Maps.Key (Next)'First + Name'Length)
                    = Name & "/";
      end Holds_Below;

      --  Whether NAME lies below one of NAMES, or in a folder now listed as
      --  one that would not be read.
      function Below (Names : Name_Lists.Vector; Name : String) return Boolean
      is (for some Folder of Names =>
            Name'Length > Folder'Length + 1
            and then Name (Name'First .. Name'First + Folder'Length) = Folder & "/");

      --  Whether NAME lies in a folder the snapshot could not list: what
      --  it held then is unknown, and what is there now is left as it is --
      --  taken for a folder that held nothing, all of it was removed.
      function Unknown_Before (Name : String) return Boolean is
      begin
         for Index in Name'Range loop
            if Name (Index) = '/' and then Index > Name'First
              and then From.Files.Contains (Name (Name'First .. Index - 1))
              and then To_String (From.Files (Name (Name'First .. Index - 1))) = Unread_Mark
            then
               return True;
            end if;
         end loop;
         return False;
      end Unknown_Before;

      --  Whether a folder on NAME's way is a link: written back there, the
      --  record went where the link names.
      function Through_Link (Name : String) return Boolean is
      begin
         for Index in Name'Range loop
            if Name (Index) = '/' and then Index > Name'First
              and then Hostkit.Fs.Is_Link (Hostkit.Fs.Join (Root (Item), Name (Name'First .. Index - 1)))
            then
               return True;
            end if;
         end loop;
         return False;
      end Through_Link;

      function Below_Unread (Name : String) return Boolean is
      begin
         for Index in Name'Range loop
            if Name (Index) = '/' and then Index > Name'First
              and then Now.Files.Contains (Name (Name'First .. Index - 1))
              and then To_String (Now.Files (Name (Name'First .. Index - 1))) = Unread_Mark
            then
               return True;
            end if;
         end loop;
         return False;
      end Below_Unread;
   begin
      Snapshot_State (Item, Now);
      Changed.Clear;
      Left.Clear;
      --  The state not listed at all, before or now: nothing is known to
      --  put back or take away -- taken for a state that held nothing,
      --  every record was removed.
      if (From.Files.Contains (".") and then To_String (From.Files (".")) = Unread_Mark)
        or else (Now.Files.Contains (".") and then To_String (Now.Files (".")) = Unread_Mark)
      then
         Left.Append ("the state could not be listed, before the run or now, so nothing of it is put back");
         return;
      end if;
      Committed := Written.Since (Root (Item), From.Logged);
      --  A link made since is taken away first: a folder of records made
      --  a link, the records written back went through it to where it
      --  named, and the link was then removed with them -- the folder,
      --  and every record in it, gone from the state, and nothing said.
      for Position in Now.Files.Iterate loop
         declare
            Name : constant String := Text_Maps.Key (Position);
         begin
            if Unknown_Before (Name) then
               null;
            elsif Is_Link_Value (Text_Maps.Element (Position))
              and then not Committed.Contains (Name)
              and then not Own_Files.Holds (Root (Item), Name)
              and then (not From.Files.Contains (Name) or else From.Files (Name) /= Text_Maps.Element (Position))
            then
               Unlinked.Append (Name);
               Changed.Append (Name);
               if not Files.Delete_If_Present (Hostkit.Fs.Join (Root (Item), Name)) then
                  Left.Append (Name & ": cannot be removed");
               end if;
            --  So too a file where a folder of records was, and a folder
            --  where a record was: written back after, each write failed
            --  on it, and it was then removed -- the records it stood in
            --  the place of lost though the snapshot held them.
            elsif not From.Files.Contains (Name)
              and then not Committed.Contains (Name)
              and then not Own_Files.Holds (Root (Item), Name)
              and then To_String (Text_Maps.Element (Position)) /= Unread_Mark
              and then Holds_Below (From.Files, Name)
            then
               Unlinked.Append (Name);
               Changed.Append (Name);
               if not Files.Delete_If_Present (Hostkit.Fs.Join (Root (Item), Name)) then
                  Left.Append (Name & ": cannot be removed");
               end if;
            end if;
         end;
      end loop;
      for Position in From.Files.Iterate loop
         declare
            Name : constant String := Text_Maps.Key (Position);
         begin
            if not Now.Files.Contains (Name) and then Holds_Below (Now.Files, Name)
              and then To_String (Text_Maps.Element (Position)) /= Unread_Mark
              and then not Below (Unlinked, Name)
            then
               declare
                  Gone : E.Error_Info;
               begin
                  Files.Remove_Tree (Hostkit.Fs.Join (Root (Item), Name), Gone);
                  Unlinked.Append (Name);
                  if E.Is_Error (Gone) then
                     Left.Append (Name & ": a folder in its place cannot be removed");
                  end if;
               end;
            end if;
         end;
      end loop;
      --  What a commit wrote under a folder made a link went where the link
      --  named: not in the state now, and said -- passed over as the
      --  harness's own, it was lost with nothing said.
      for Name of Committed loop
         if Below (Unlinked, Name) and then not Left.Contains (Name) then
            Changed.Append (Name);
            Left.Append (Name & ": written by the harness through a link put in its folder's place, so it is not"
                         & " as the harness left it");
         end if;
      end loop;
      for Position in From.Files.Iterate loop
         declare
            Name : constant String := Text_Maps.Key (Position);
            Path : constant String := Hostkit.Fs.Join (Root (Item), Name);
         begin
            --  Written by a commit since, and as that commit wrote it: the
            --  harness's own. Changed after it -- an agent's edit to a
            --  record the harness had just written -- it is said, though
            --  what the commit wrote is not kept to put back.
            if Committed.Contains (Name)
              and then Now.Files.Contains (Name)
              and then Written.Print_Of (Root (Item), Name) /= ""
              and then Fingerprint (To_String (Now.Files (Name))) /= Written.Print_Of (Root (Item), Name)
            then
               Changed.Append (Name);
               Left.Append (Name & ": changed after the harness wrote it, so it is not as the harness left it");
            elsif Committed.Contains (Name) or else Own_Files.Holds (Root (Item), Name) then
               null;
            --  In a folder that will not be read now: not put back, said.
            elsif Below_Unread (Name) then
               Changed.Append (Name);
               Left.Append (Name & ": its folder cannot be read, so it is not put back");
            --  A link, made again as it was -- gone, made a file, or named
            --  elsewhere: written back as text, the mark went into a file
            --  where the link was, and one named elsewhere was kept.
            elsif Is_Link_Value (Text_Maps.Element (Position)) then
               --  Not through a link left in a folder's place: the link it
               --  was made again in was in the folder the link names.
               if (not Now.Files.Contains (Name) or else Now.Files (Name) /= Text_Maps.Element (Position))
                 and then Through_Link (Name)
               then
                  Changed.Append (Name);
                  Left.Append (Name & ": a folder on its way is a link, so it is not made again");
               elsif not Now.Files.Contains (Name) or else Now.Files (Name) /= Text_Maps.Element (Position) then
                  if not Unlinked.Contains (Name) then
                     Changed.Append (Name);
                  end if;
                  declare
                     Was    : constant String := To_String (Text_Maps.Element (Position));
                     Target : constant String :=
                       (if Was'Length > Link_Mark'Length + 1 then Was (Was'First + Link_Mark'Length + 1 .. Was'Last)
                        else "");
                  begin
                     if Target = "" or else not Files.Delete_If_Present (Path)
                       or else not Hostkit.Fs.Create_Link (Target, Path)
                     then
                        Left.Append (Name & ": a link, which cannot be made again as it was");
                     end if;
                  exception
                     when others =>
                        Left.Append (Name & ": a link, which cannot be made again as it was");
                  end;
               end if;
            elsif (not Now.Files.Contains (Name)
                   or else Now.Files (Name) /= Text_Maps.Element (Position))
              and then (To_String (Text_Maps.Element (Position)) = Unread_Mark
                        or else (Now.Files.Contains (Name)
                                 and then To_String (Now.Files (Name)) = Unread_Mark))
            then
               --  What it was, or is, cannot be read: not put back, said.
               Changed.Append (Name);
               Left.Append (Name & ": it could not be read, before or now, so it is not put back");
            elsif (not Now.Files.Contains (Name) or else Now.Files (Name) /= Text_Maps.Element (Position))
              and then Through_Link (Name)
            then
               --  A link left in a folder's place, that could not be taken
               --  away: not written through.
               Changed.Append (Name);
               Left.Append (Name & ": a folder on its way is a link, so it is not put back");
            elsif not Now.Files.Contains (Name)
              or else Now.Files (Name) /= Text_Maps.Element (Position)
            then
               Changed.Append (Name);
               if Files.Make_Directory (Ada.Directories.Containing_Directory (Path)) then
                  --  Whole or not at all: a write cut short is no record.
                  Files.Write_Whole (Path, To_String (Text_Maps.Element (Position)), Status);
                  if E.Is_Error (Status) then
                     Left.Append (Name & ": cannot be written back");
                  end if;
               else
                  Left.Append (Name & ": its directory cannot be made");
               end if;
            end if;
         end;
      end loop;
      for Position in Now.Files.Iterate loop
         --  Made by a commit since, and changed after it: said, as one
         --  that was there before is -- and kept, the harness's record.
         if not From.Files.Contains (Text_Maps.Key (Position))
           and then Committed.Contains (Text_Maps.Key (Position))
           and then Written.Print_Of (Root (Item), Text_Maps.Key (Position)) /= ""
           and then Fingerprint (To_String (Text_Maps.Element (Position)))
                    /= Written.Print_Of (Root (Item), Text_Maps.Key (Position))
         then
            Changed.Append (Text_Maps.Key (Position));
            Left.Append (Text_Maps.Key (Position)
                         & ": changed after the harness wrote it, so it is not as the harness left it");
         --  A folder that will not be read: not removed, said.
         elsif not From.Files.Contains (Text_Maps.Key (Position))
           and then To_String (Text_Maps.Element (Position)) = Unread_Mark
           and then Ada.Directories.Exists (Hostkit.Fs.Join (Root (Item), Text_Maps.Key (Position)))
           and then Ada.Directories."=" (Ada.Directories.Kind (Hostkit.Fs.Join (Root (Item), Text_Maps.Key (Position))),
                                         Ada.Directories.Directory)
         then
            Changed.Append (Text_Maps.Key (Position));
            Left.Append (Text_Maps.Key (Position) & ": a folder that cannot be read, so it is left as it is");
         elsif not From.Files.Contains (Text_Maps.Key (Position))
           and then not Committed.Contains (Text_Maps.Key (Position))
           and then not Own_Files.Holds (Root (Item), Text_Maps.Key (Position))
           and then not Unlinked.Contains (Text_Maps.Key (Position))
           and then not Below (Unlinked, Text_Maps.Key (Position))
           and then not Unknown_Before (Text_Maps.Key (Position))
         then
            Changed.Append (Text_Maps.Key (Position));
            if not Files.Delete_If_Present (Hostkit.Fs.Join (Root (Item), Text_Maps.Key (Position))) then
               Left.Append (Text_Maps.Key (Position) & ": cannot be removed");
            end if;
         end if;
      end loop;
   end Restore_State;

end Model_Runner.Framework.Stores;
