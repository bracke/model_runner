with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Templates;
with Model_Runner.Framework.Transitions;
with Model_Runner.Text;

package body Tests.Framework_Cases is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Framework.Area;
   use type Model_Runner.Framework.Records.Item;
   use type Model_Runner.Framework.Facts.Derivation_Source;
   use type Model_Runner.Framework.Facts.Confidence_Level;
   use type Model_Runner.Framework.Stores.Recovery_Report;
   use type Model_Runner.Framework.Results.Result_Kind;
   use type Model_Runner.Framework.Events.Event_Kind;
   use type Model_Runner.Framework.Name_Lists.Vector;

   package E renames Model_Runner.Errors;
   package F renames Model_Runner.Framework;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package Dirs renames Ada.Directories;

   --  Where the projects of this case are made.
   Scratch : constant String := "obj/framework-fixtures";

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("the project state");
   end Name;

   --  A project directory made anew, whatever was there.
   function Fresh (Leaf : String) return String is
      Path : constant String := Scratch & "/" & Leaf;
   begin
      if Dirs.Exists (Path) then
         Dirs.Delete_Tree (Path);
      end if;
      Dirs.Create_Path (Path);
      return Path;
   end Fresh;

   --  A file holding exactly these bytes.
   procedure Put_File (Path, Content : String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      String'Write (Ada.Streams.Stream_IO.Stream (File), Content);
      Ada.Streams.Stream_IO.Close (File);
   end Put_File;

   --  A condition's code and the text of its parameters, for a message
   --  that says what went wrong and not only that something did.
   function Code_Of (Status : E.Error_Info) return String is
      Result : Unbounded_String :=
        To_Unbounded_String (E.Error_Code'Image (Status.Code));
   begin
      for Index in 1 .. Status.Parameter_Total loop
         Append (Result, " " & Model_Runner.Text.To_String
                                 (Status.Parameters (Index).Text_Value));
      end loop;
      return To_String (Result);
   end Code_Of;

   --  A fact, staged and committed.
   procedure Commit_Fact
     (Store : in out S.Store;
      Key   : String;
      Value : String)
   is
      Change : S.Transaction;
      Status : E.Error_Info;
   begin
      Model_Runner.Framework.Facts.Record_Fact
        (Store, Change,
         (Key        => To_Unbounded_String (Key),
          Value      => To_Unbounded_String (Value),
          Source     => Model_Runner.Framework.Facts.Build_Metadata,
          Confidence => Model_Runner.Framework.Facts.Certain),
         Status);
      Assert (E.Is_Ok (Status), "a fact was refused: " & Code_Of (Status));
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a fact was not committed: " & Code_Of (Status));
   end Commit_Fact;

   ---------------------------------------------------------------------------
   --  Records.
   ---------------------------------------------------------------------------

   --  A record reads back as it was written, bytes and all, and two records
   --  holding the same fields are one text whatever order they were set in.
   procedure Records_Round_Trip (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Awkward : constant String :=
        "two" & ASCII.LF & "lines, a 7 and a space " & ASCII.LF;
      First   : R.Item := R.Create ("project.fact", 1, "FACT-LANGUAGE", 3);
      Second  : R.Item := R.Create ("project.fact", 1, "FACT-LANGUAGE", 3);
      Back    : R.Item;
      Status  : E.Error_Info;
   begin
      R.Set (First, "value", Awkward);
      R.Set (First, "key", "language");
      R.Set (First, "vendor:note", "kept, never acted on");
      R.Set (Second, "vendor:note", "kept, never acted on");
      R.Set (Second, "key", "language");
      R.Set (Second, "value", Awkward);

      Assert (R.Serialize (First) = R.Serialize (Second),
              "the order fields were set in changed the text");
      Assert (R.Fingerprint_Of (First) = R.Fingerprint_Of (Second),
              "the order fields were set in changed the fingerprint");

      R.Parse (R.Serialize (First), "memory", Back, Status);
      Assert (E.Is_Ok (Status), "a record did not read back: "
              & Code_Of (Status));
      Assert (Back = First, "a record read back different");
      Assert (R.Get (Back, "value") = Awkward, "a value lost its bytes");
      Assert (R.Revision (Back) = 3 and then R.Entity_Id (Back)
              = "FACT-LANGUAGE", "the header did not read back");
      Assert (R.Field_Count (Back) = 3
              and then R.Field_Name (Back, 1) = "key",
              "the fields are not in their order");

      R.Remove (Back, "vendor:note");
      Assert (not R.Has (Back, "vendor:note"), "a field was not removed");
      R.Set_Revision (Back, 4);
      Assert (R.Get (Back, "revision") = "4", "the revision did not change");
      Assert (R.Schema_Version (Back) = 1, "the schema version changed");

      Assert (R.Is_Field_Name ("next.REQ-PARSER")
              and then not R.Is_Field_Name ("two words")
              and then not R.Is_Field_Name ("9lives"),
              "field names are not what they should be");
      Assert (F.Fingerprint ("") = "cbf29ce484222325",
              "the fingerprint is not FNV-1a");
   end Records_Round_Trip;

   --  Text that is not a record is refused, and says why.
   procedure Records_Refuse_What_Is_Not_One
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Good  : constant String :=
        R.Serialize (R.Create ("project.fact", 1, "FACT-X", 1));
      Value : R.Item;

      procedure Refused (Text, Why : String) is
         Status : E.Error_Info;
      begin
         R.Parse (Text, "memory", Value, Status);
         Assert (Status.Code = E.Framework_Record_Malformed,
                 "a record " & Why & " was read");
      end Refused;
   begin
      Refused ("not a record" & ASCII.LF, "without its signature");
      Refused (Good & "key 99" & ASCII.LF & "short" & ASCII.LF,
               "whose field runs past the end");
      Refused (Good & "key 1" & ASCII.LF & "a" & ASCII.LF
               & "key 1" & ASCII.LF & "b" & ASCII.LF,
               "with a field given twice");
      Refused (R.Signature & ASCII.LF & "key 1" & ASCII.LF & "a" & ASCII.LF,
               "without a header");
      Refused (Good & "key x" & ASCII.LF, "with a length that is not one");
   end Records_Refuse_What_Is_Not_One;

   ---------------------------------------------------------------------------
   --  Schemas.
   ---------------------------------------------------------------------------

   --  Each schema keeps its records to what it says, keeps what it does not
   --  name where it may, and refuses a version later than it knows.
   procedure Schemas_Are_Enforced (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Sc renames Model_Runner.Framework.Schemas;

      function Fact return R.Item is
         Value : R.Item := R.Create (Sc.Fact_Schema, 1, "FACT-LANGUAGE", 1);
      begin
         R.Set (Value, "key", "language");
         R.Set (Value, "value", "Ada_2022");
         R.Set (Value, "source", "explicit");
         R.Set (Value, "confidence", "authoritative");
         return Value;
      end Fact;

      function Outcome (Value : R.Item) return E.Error_Code is
         Status : E.Error_Info;
      begin
         Sc.Validate (Value, "test", Status);
         return Status.Code;
      end Outcome;

      Value : R.Item;
   begin
      Assert (Outcome (Fact) = E.No_Error, "a good fact was refused");
      Assert (Sc.Current_Version (Sc.Fact_Schema) = 1
              and then Sc.Current_Version ("no.such") = 0,
              "schema versions are not what they should be");

      Value := Fact;
      R.Remove (Value, "value");
      Assert (Outcome (Value) = E.Framework_Schema_Violation,
              "a fact without its value was accepted");

      Value := Fact;
      R.Set (Value, "confidence", "sure");
      Assert (Outcome (Value) = E.Framework_Schema_Violation,
              "a confidence that is none of the choices was accepted");

      Value := Fact;
      R.Set (Value, "later_field", "from a later build");
      Assert (Outcome (Value) = E.No_Error,
              "a field the schema does not name was not kept");

      Value := R.Create (Sc.Fact_Schema, 2, "FACT-LANGUAGE", 1);
      Assert (Outcome (Value) = E.Framework_Format_Unsupported,
              "a later schema version was read as this one");

      Value := R.Create ("no.such", 1, "X", 1);
      Assert (Outcome (Value) = E.Framework_Schema_Violation,
              "a schema nobody defined was accepted");

      Value := R.Create
        (Model_Runner.Framework.Identifiers.Counters_Schema, 1, "COUNTERS", 1);
      R.Set (Value, "next.REQ", "4");
      R.Set (Value, "vendor:owner", "kept");
      Assert (Outcome (Value) = E.No_Error,
              "counters with an extension field were refused");
      R.Set (Value, "stray", "1");
      Assert (Outcome (Value) = E.Framework_Schema_Violation,
              "a stray field on the counters was accepted");

      Value := Fact;
      R.Set_Revision (Value, 0);
      Assert (Outcome (Value) = E.Framework_Schema_Violation,
              "a record with no revision was accepted");
   end Schemas_Are_Enforced;

   ---------------------------------------------------------------------------
   --  Identifiers.
   ---------------------------------------------------------------------------

   --  Identifiers are words and a number, and are handed out in turn.
   procedure Identifiers_Are_Handed_Out
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package I renames Model_Runner.Framework.Identifiers;
      Counters : R.Item := I.Empty_Counters;
   begin
      Assert (I.Is_Valid ("REQ-PARSER-017") and then I.Is_Valid ("CONFIG"),
              "an identifier was refused");
      Assert (not I.Is_Valid ("req-1") and then not I.Is_Valid ("REQ--1")
              and then not I.Is_Valid ("REQ-") and then not I.Is_Valid ("")
              and then not I.Is_Valid ("1REQ"),
              "something that is not an identifier was accepted");
      Assert (I.Format ("DEC", "IO", 3) = "DEC-IO-003"
              and then I.Format ("TASK", "", 1234) = "TASK-1234",
              "an identifier was not written as it should be");

      Assert (I.Allocate (Counters, "REQ", "PARSER") = "REQ-PARSER-001"
              and then I.Allocate (Counters, "REQ", "PARSER") = "REQ-PARSER-002"
              and then I.Allocate (Counters, "REQ", "IO") = "REQ-IO-001",
              "identifiers were not handed out in turn");
      Assert (I.Allocate (Counters, "req", "") = "",
              "a namespace that is not one was given a number");
   end Identifiers_Are_Handed_Out;

   ---------------------------------------------------------------------------
   --  The store.
   ---------------------------------------------------------------------------

   --  State made in one session is there in the next: the identity, the
   --  facts, and the counters identifiers are handed out from.
   procedure State_Survives_Restart
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("restart");
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Id      : Unbounded_String;
      Known   : Unbounded_String;
      Found   : Model_Runner.Framework.Facts.Fact;
   begin
      S.Open (Store, Project, Report, Status);
      Assert (Status.Code = E.Framework_Not_Initialized,
              "a directory with no state was opened");
      Assert (not S.Is_Initialized (Project), "an empty project has state");

      S.Create (Store, Project, "", Status);
      Assert (Status.Code = E.Framework_Name_Invalid,
              "a project with no name was made");

      S.Create (Store, Project, "Parser", Status);
      Assert (E.Is_Ok (Status), "a project was not made: " & Code_Of (Status));
      Assert (S.Is_Open (Store) and then S.Is_Initialized (Project),
              "a project made is not open");
      Known := To_Unbounded_String (S.Project_Id (Store));
      Assert (S.Project_Name (Store) = "Parser"
              and then Length (Known) = 24,
              "the project's identity is not what it was given");
      Assert (S.Root (Store) = S.State_Root (Project),
              "the store is not where the project's state is");

      S.Allocate_Identifier (Store, Change, "REQ", "PARSER", Id, Status);
      Assert (E.Is_Ok (Status) and then To_String (Id) = "REQ-PARSER-001",
              "the first identifier was not the first");
      S.Allocate_Identifier (Store, Change, "REQ", "PARSER", Id, Status);
      Assert (To_String (Id) = "REQ-PARSER-002",
              "a second identifier in one change was not the second");
      Assert (S.Change_Count (Change) = 1,
              "the counters were staged more than once");
      S.Allocate_Identifier (Store, Change, "req", "", Id, Status);
      Assert (Status.Code = E.Framework_Identifier_Invalid,
              "a namespace that is not one was given a number");
      declare
         Number : Natural;
      begin
         S.Allocate_Number (Store, Change, "REQ", "PARSER", Number, Status);
         Assert (E.Is_Ok (Status) and then Number = 3,
                 "a number is not counted with the identifiers of its key");
         S.Allocate_Number (Store, Change, "REQ", "IO", Number, Status);
         Assert (Number = 1, "a key's numbers are not its own");
      end;
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "the counters were not committed");
      Assert (S.Change_Count (Change) = 0, "a committed change was kept");
      Commit_Fact (Store, "build_system", "Alire");

      S.Create (Store, Project, "Again", Status);
      Assert (Status.Code = E.Framework_Already_Initialized,
              "a project was made twice");

      S.Close (Store);
      Assert (not S.Is_Open (Store), "a closed store is open");

      S.Open (Store, Project, Report, Status);
      Assert (E.Is_Ok (Status), "the project did not open again: "
              & Code_Of (Status));
      Assert (Report = (others => <>), "a clean close left something to do");
      Assert (S.Project_Id (Store) = To_String (Known),
              "the project came back as another");

      Model_Runner.Framework.Facts.Find (Store, "build_system", Found, Status);
      Assert (E.Is_Ok (Status) and then To_String (Found.Value) = "Alire"
              and then Found.Source = Model_Runner.Framework.Facts.Build_Metadata
              and then Found.Confidence = Model_Runner.Framework.Facts.Certain,
              "a fact did not come back as it was stored");
      Assert (Model_Runner.Framework.Facts.Keys (Store).First_Element
              = "build_system", "the facts are not listed");

      Commit_Fact (Store, "build_system", "Alire 2");
      Assert (S.Current_Revision (Store, F.Project_Area, "fact.build_system")
              = 2, "a changed fact is not its second revision");

      S.Allocate_Identifier (Store, Change, "REQ", "PARSER", Id, Status);
      Assert (To_String (Id) = "REQ-PARSER-004",
              "the counters did not survive the restart");

      Model_Runner.Framework.Facts.Find (Store, "Bad Key", Found, Status);
      Assert (Status.Code = E.Framework_Name_Invalid, "a bad key was read");
      Model_Runner.Framework.Facts.Find (Store, "language", Found, Status);
      Assert (Status.Code = E.Framework_Not_Found,
              "a fact nobody stored was found");

      S.Close (Store);
   end State_Survives_Restart;

   --  One session holds the state; a second is told so.
   procedure Second_Session_Is_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("locked");
      First   : S.Store;
      Second  : S.Store;
      Report  : S.Recovery_Report;
      Status  : E.Error_Info;
   begin
      S.Create (First, Project, "Held", Status);
      Assert (E.Is_Ok (Status), "a project was not made");

      S.Open (Second, Project, Report, Status);
      Assert (Status.Code = E.Framework_Locked,
              "a second session opened state another holds: "
              & Code_Of (Status));

      S.Close (First);
      S.Open (Second, Project, Report, Status);
      Assert (E.Is_Ok (Status), "state let go of could not be opened");
      S.Close (Second);
   end Second_Session_Is_Refused;

   --  A change committed and interrupted before it was applied is applied
   --  when the state is next opened.
   procedure Committed_Change_Rolls_Forward
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("forward");
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Value   : R.Item := R.Create ("project.fact", 1, "FACT-LANGUAGE", 1);
      Where   : F.Area;
      Name    : Unbounded_String;
      Found   : Boolean;
   begin
      S.Create (Store, Project, "Forward", Status);
      R.Set (Value, "key", "language");
      R.Set (Value, "value", "Ada_2022");
      R.Set (Value, "source", "explicit");
      R.Set (Value, "confidence", "authoritative");
      S.Put (Change, F.Project_Area, "fact.language", Value);
      S.Remove (Change, F.Project_Area, "never.there");

      S.Stage (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a change was not staged: " & Code_Of (Status));
      S.Mark (Store, Status);
      Assert (E.Is_Ok (Status), "a staged change was not marked");
      Assert (not S.Exists (Store, F.Project_Area, "fact.language"),
              "a change was applied before it was finished");

      --  The session ends here, as a crash would end it.
      S.Close (Store);

      S.Open (Store, Project, Report, Status);
      Assert (E.Is_Ok (Status), "state with a committed journal did not open: "
              & Code_Of (Status));
      Assert (Report.Rolled_Forward = 1 and then Report.Rolled_Back = 0,
              "the committed change was not reported as finished");
      Assert (S.Exists (Store, F.Project_Area, "fact.language"),
              "a committed change was lost");

      S.Lookup (Store, "FACT-LANGUAGE", Where, Name, Found);
      Assert (Found and then Where = F.Project_Area
              and then To_String (Name) = "fact.language",
              "the index does not know what the finished change wrote");

      --  Finishing again finds nothing to do.
      S.Finish (Store, Status);
      Assert (E.Is_Ok (Status), "finishing twice failed");
      S.Close (Store);
   end Committed_Change_Rolls_Forward;

   --  A change interrupted before it was committed is thrown away, and so
   --  is a file a write left half made.
   procedure Uncommitted_Change_Rolls_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("back");
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Value   : R.Item := R.Create ("project.fact", 1, "FACT-LANGUAGE", 1);
   begin
      S.Create (Store, Project, "Back", Status);
      R.Set (Value, "key", "language");
      R.Set (Value, "value", "Ada_2022");
      R.Set (Value, "source", "explicit");
      R.Set (Value, "confidence", "authoritative");
      S.Put (Change, F.Project_Area, "fact.language", Value);

      S.Mark (Store, Status);
      Assert (Status.Code = E.Framework_Transaction_Failed,
              "nothing staged was marked committed");

      S.Stage (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a change was not staged");
      Put_File (S.Root (Store) & "/specs/half.rec.partial", "model_runner-re");
      S.Close (Store);

      S.Open (Store, Project, Report, Status);
      Assert (E.Is_Ok (Status), "state with a torn journal did not open: "
              & Code_Of (Status));
      Assert (Report.Rolled_Back = 1 and then Report.Rolled_Forward = 0,
              "the uncommitted change was not reported as undone");
      Assert (Report.Partials_Removed = 1,
              "a half-made file was not removed");
      Assert (not S.Exists (Store, F.Project_Area, "fact.language"),
              "an uncommitted change was applied");
      Assert (not Dirs.Exists (S.Root (Store) & "/specs/half.rec.partial"),
              "a half-made file is still there");
      S.Close (Store);
   end Uncommitted_Change_Rolls_Back;

   --  A change made against an old revision, or breaking its schema, is
   --  refused whole: nothing of it is written.
   procedure Bad_Changes_Write_Nothing
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("refused");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Other   : S.Transaction;
      Good    : R.Item := R.Create ("project.fact", 1, "FACT-LANGUAGE", 1);
      Value   : R.Item;
   begin
      S.Create (Store, Project, "Refused", Status);
      R.Set (Good, "key", "language");
      R.Set (Good, "value", "Ada_2022");
      R.Set (Good, "source", "explicit");
      R.Set (Good, "confidence", "authoritative");
      S.Put (Change, F.Project_Area, "fact.language", Good);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a good change was refused");

      --  The same first revision again is a change made against nothing,
      --  when there is now something.
      S.Put (Change, F.Project_Area, "fact.language", Good);
      S.Commit (Store, Change, Status);
      Assert (Status.Code = E.Framework_Revision_Conflict,
              "a change against an old revision was committed: "
              & Code_Of (Status));

      Value := Good;
      R.Set_Revision (Value, 2);
      R.Remove (Value, "source");
      S.Put (Change, F.Project_Area, "fact.language", Value);
      S.Put (Change, F.Project_Area, "fact.other", Good);
      S.Commit (Store, Change, Status);
      Assert (Status.Code = E.Framework_Schema_Violation,
              "a record breaking its schema was committed");
      Assert (not S.Exists (Store, F.Project_Area, "fact.other"),
              "part of a refused change was written");

      S.Put (Other, F.Project_Area, "not/a/name", Good);
      S.Commit (Store, Other, Status);
      Assert (Status.Code = E.Framework_Name_Invalid,
              "a name with a path in it was committed");

      S.Read (Store, F.Project_Area, "nothing.here", Value, Status);
      Assert (Status.Code = E.Framework_Not_Found,
              "a record nobody wrote was read");
      S.Read (Store, F.Project_Area, "../escape", Value, Status);
      Assert (Status.Code = E.Framework_Name_Invalid,
              "a name reaching out of its area was read");
      S.Read (Store, F.Project_Area, "fact.language", Value, Status);
      Assert (E.Is_Ok (Status) and then R.Revision (Value) = 1,
              "the record a refused change was aimed at changed");
      S.Close (Store);
   end Bad_Changes_Write_Nothing;

   --  The entity index can be thrown away and is built again to the same
   --  thing.
   procedure Index_Is_Rebuilt (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("index");
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Status  : E.Error_Info;
      Before  : R.Item;
      After   : R.Item;
      Where   : F.Area;
      Name    : Unbounded_String;
      Found   : Boolean;
   begin
      S.Create (Store, Project, "Index", Status);
      Commit_Fact (Store, "language", "Ada_2022");
      Commit_Fact (Store, "build_system", "Alire");
      S.Read (Store, F.Indexes_Area, "entities", Before, Status);
      Assert (E.Is_Ok (Status), "the index was not kept as changes were made");
      S.Close (Store);

      Dirs.Delete_Tree (S.State_Root (Project) & "/indexes");

      S.Open (Store, Project, Report, Status);
      Assert (E.Is_Ok (Status), "state without its index did not open");
      Assert (Report.Index_Rebuilt, "a missing index was not reported rebuilt");
      S.Read (Store, F.Indexes_Area, "entities", After, Status);
      Assert (E.Is_Ok (Status) and then After = Before,
              "the index built again is not the index kept");

      S.Lookup (Store, "FACT-BUILD_SYSTEM", Where, Name, Found);
      Assert (Found and then To_String (Name) = "fact.build_system",
              "the rebuilt index does not know an entity");
      S.Lookup (Store, "PROJECT", Where, Name, Found);
      Assert (Found and then To_String (Name) = "identity",
              "the rebuilt index does not know the project");
      S.Lookup (Store, "NOBODY", Where, Name, Found);
      Assert (not Found, "the index knows an entity nobody made");

      S.Rebuild_Index (Store, Status);
      S.Read (Store, F.Indexes_Area, "entities", After, Status);
      Assert (After = Before, "building the index twice changed it");
      Assert (Natural (S.Names (Store, F.Project_Area).Length) = 4,
              "the project area does not hold what was written to it");
      S.Close (Store);
   end Index_Is_Rebuilt;

   --  A result is stored once under its content and is never changed; one
   --  whose content no longer matches is reported rather than returned.
   procedure Results_Are_Immutable (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Res renames Model_Runner.Framework.Results;
      Project : constant String := Fresh ("results");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Made    : Res.Result :=
        (Kind       => Res.Impact_Report,
         Producer   => To_Unbounded_String ("harness"),
         Summary    => To_Unbounded_String ("three files touched"),
         Payload    => To_Unbounded_String ("a.adb" & ASCII.LF & "b.adb"),
         Provenance => To_Unbounded_String ("test"),
         others     => <>);
      Again   : Res.Result := Made;
      Back    : Res.Result;
      Stored  : R.Item;
   begin
      S.Create (Store, Project, "Results", Status);
      Res.Add (Store, Change, Made, Status);
      Assert (E.Is_Ok (Status), "a result was refused");
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a result was not committed");
      Assert (Slice (Made.Id, 1, 4) = "RES-"
              and then To_String (Made.Id) = Res.Identifier_Of (Made),
              "a result was not named by its content");
      Assert (Res.Kind_Word (Res.Impact_Report) = "impact_report",
              "a kind of result is not stored as its word");

      Res.Read (Store, To_String (Made.Id), Back, Status);
      Assert (E.Is_Ok (Status) and then Back.Payload = Made.Payload
              and then Back.Kind = Res.Impact_Report,
              "a result did not read back as stored");

      Res.Add (Store, Change, Again, Status);
      Assert (E.Is_Ok (Status) and then S.Change_Count (Change) = 0
              and then Again.Id = Made.Id
              and then Again.Created_At = Made.Created_At,
              "a result stored twice was stored again");

      --  Change the stored payload under its identifier.
      S.Read (Store, F.Results_Area, To_String (Made.Id), Stored, Status);
      R.Set (Stored, "payload", "something else");
      Put_File (S.Root (Store) & "/results/" & To_String (Made.Id) & ".rec",
                R.Serialize (Stored));
      Res.Read (Store, To_String (Made.Id), Back, Status);
      Assert (Status.Code = E.Framework_Integrity_Failed,
              "a result changed under its identifier was returned");
      S.Close (Store);
   end Results_Are_Immutable;

   --  State this build cannot read, or a journal that cannot be finished,
   --  stops the open and says so.
   procedure Unreadable_State_Is_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("unreadable");
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Status  : E.Error_Info;
      Later   : R.Item :=
        R.Create (Model_Runner.Framework.Schemas.Root_Schema, 1, "ROOT", 1);
   begin
      S.Create (Store, Project, "Unreadable", Status);
      Put_File (S.Root (Store) & "/runtime/journal/manifest.rec", "torn");
      S.Close (Store);

      S.Open (Store, Project, Report, Status);
      Assert (Status.Code = E.Framework_Recovery_Required,
              "a journal that cannot be read was passed over: "
              & Code_Of (Status));
      Assert (not S.Is_Open (Store), "state needing recovery was left open");
      Dirs.Delete_File
        (S.State_Root (Project) & "/runtime/journal/manifest.rec");

      R.Set (Later, "format", F.Format_Name);
      R.Set (Later, "state_version", "2");
      Put_File (S.State_Root (Project) & "/format.rec", R.Serialize (Later));
      S.Open (Store, Project, Report, Status);
      Assert (Status.Code = E.Framework_Format_Unsupported,
              "state of a later version was opened: " & Code_Of (Status));
   end Unreadable_State_Is_Refused;

   --  Each area says what kind of state it holds.
   procedure Areas_Are_Classified (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type F.State_Class;
      use type F.Portability;
   begin
      Assert (F.Class_Of (F.Requirements_Area) = F.Authored_State
              and then F.Class_Of (F.Runtime_Area) = F.Runtime_State
              and then F.Class_Of (F.Events_Area) = F.Historical_State
              and then F.Class_Of (F.Indexes_Area) = F.Derived_State,
              "an area holds the wrong kind of state");
      Assert (F.Portability_Of (F.Specs_Area) = F.Repository_Portable
              and then F.Portability_Of (F.Workspaces_Area) = F.Machine_Local
              and then F.Portability_Of (F.Indexes_Area) = F.Derived_Cache,
              "an area travels where it should not");
      Assert (F.Directory_Name (F.Invocations_Area) = "invocations",
              "an area is not kept where the layout says");
      Assert (F.Timestamp'Length = 20
              and then F.Timestamp (F.Timestamp'First + 10) = 'T',
              "a timestamp is not ISO 8601");
   end Areas_Are_Classified;

   ---------------------------------------------------------------------------
   --  Templates and configuration.
   ---------------------------------------------------------------------------

   package Tp renames Model_Runner.Framework.Templates;
   package Cf renames Model_Runner.Framework.Configurations;

   LF : constant Character := ASCII.LF;

   --  Templates for a small language family, composed the way an installed
   --  set would be.
   Base_Text : constant String :=
     "# a language" & LF
     & "template = lang" & LF
     & "name = A Language" & LF
     & "version = 3" & LF
     & "language = Lang" & LF
     & "fact language = Lang_2022" & LF
     & "set tags = lang" & LF
     & "list verify.steps = compile" & LF
     & "scalar build.command = make" & LF
     & "directory src" & LF;

   Tool_Text : constant String :=
     "template = tool" & LF
     & "name = A Build Tool" & LF
     & "version = 1" & LF
     & "discover tool.toml fact build_system = Tool" & LF
     & "discover tool.toml input project_name = from_tool" & LF
     & "set tags = tool" & LF
     & "list verify.steps = compile" & LF
     & "list verify.steps = test" & LF
     & "override scalar build.command = tool build" & LF
     & "adapter build = tool" & LF;

   App_Text : constant String :=
     "template = app" & LF
     & "name = An Application" & LF
     & "description = A program in the language, built with the tool." & LF
     & "version = 2" & LF
     & "category = application" & LF
     & "includes = lang, tool" & LF
     & "" & LF
     & "input project_name" & LF
     & "  type = identifier" & LF
     & "  label = Project name" & LF
     & "  required = true" & LF
     & "input style" & LF
     & "  type = choice" & LF
     & "  choices = terse, verbose" & LF
     & "  default = terse" & LF
     & "input token" & LF
     & "  type = text" & LF
     & "  secret = true" & LF
     & "" & LF
     & "set tags = app" & LF
     & "file src/${project_name}.txt = hello\n" & LF
     & "file src/main.txt = the ${project_name} program, ${style}\n" & LF
     & "profile quick = ${project_name} check" & LF;

   function Parsed (Text : String) return Tp.Template is
      Value  : Tp.Template;
      Status : E.Error_Info;
   begin
      Tp.Parse (Text, "memory", Value, Status);
      Assert (E.Is_Ok (Status), "a template was refused: " & Code_Of (Status));
      return Value;
   end Parsed;

   function Family return Tp.Registry is
      Result : Tp.Registry;
   begin
      Tp.Add (Result, Parsed (App_Text));
      Tp.Add (Result, Parsed (Base_Text));
      Tp.Add (Result, Parsed (Tool_Text));
      return Result;
   end Family;

   --  A template declares; composing puts its includes first and merges by
   --  what each declaration is.
   procedure Templates_Compose (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Registry : constant Tp.Registry := Family;
      Composed : Tp.Composition;
      Status   : E.Error_Info;

      function Value_Of (Kind : Tp.Setting_Kind; Key : String) return String
      is
         Result : Unbounded_String;
      begin
         for Index in 1 .. Tp.Setting_Count (Composed) loop
            declare
               Held : constant Tp.Setting := Tp.Setting_At (Composed, Index);
               use type Tp.Setting_Kind;
            begin
               if Held.Kind = Kind and then To_String (Held.Key) = Key then
                  if Result /= Null_Unbounded_String then
                     Append (Result, ",");
                  end if;
                  Append (Result, Held.Value);
               end if;
            end;
         end loop;
         return To_String (Result);
      end Value_Of;
   begin
      Assert (Tp.Count (Registry) = 3
              and then Tp.Id (Tp.Template_At (Registry, 1)) = "app",
              "the registry is not sorted by identifier");
      Assert (E.Is_Ok (Tp.Problem (Registry, 1)), "a whole template is unavailable");
      Assert (Tp.Display_Name (Tp.Template_At (Registry, 1)) = "An Application"
              and then Tp.Details (Tp.Template_At (Registry, 1)) = "application"
              and then Tp.Version (Tp.Template_At (Registry, 1)) = "2"
              and then Tp.Description (Tp.Template_At (Registry, 1))'Length > 0,
              "a template does not say what it is");

      Tp.Compose (Registry, "app", Composed, Status);
      Assert (E.Is_Ok (Status), "a family did not compose: " & Code_Of (Status));
      Assert (Tp.Order (Composed).First_Element = "lang"
              and then Tp.Order (Composed).Last_Element = "app"
              and then Natural (Tp.Order (Composed).Length) = 3,
              "includes were not composed first, in order");
      Assert (Value_Of (Tp.Set_Setting, "tags") = "app,lang,tool",
              "a set is not the union of its parts");
      Assert (Value_Of (Tp.List_Setting, "verify.steps") = "compile,test",
              "a list did not keep its first value where it was first");
      Assert (Value_Of (Tp.Scalar_Setting, "build.command") = "tool build",
              "an override did not win");
      Assert (Tp.Input_Count (Composed) = 3 and then Tp.Rule_Count (Composed) = 2,
              "inputs or discoveries were lost in composing");
      Assert (Tp.Kind_Word (Tp.Task_Kind_Setting) = "task_kind",
              "a kind is not written as its word");
      Assert (Tp.Id (Tp.Root (Composed)) = "app"
              and then Tp.Template_Fingerprint (Tp.Root (Composed))'Length = 16,
              "a composition does not know its template");
   end Templates_Compose;

   --  What templates cannot agree on, and what they cannot be, is refused.
   procedure Template_Conflicts_Are_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Registry : Tp.Registry := Family;
      Composed : Tp.Composition;
      Status   : E.Error_Info;
      Value    : Tp.Template;
   begin
      Tp.Add (Registry, Parsed ("template = clash" & LF & "name = C" & LF
                                & "version = 1" & LF & "includes = lang" & LF
                                & "scalar build.command = other" & LF));
      Tp.Compose (Registry, "clash", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Conflict,
              "two values for one scalar composed: " & Code_Of (Status));

      Tp.Add (Registry, Parsed ("template = loop-a" & LF & "name = A" & LF
                                & "version = 1" & LF & "includes = loop-b"
                                & LF));
      Tp.Add (Registry, Parsed ("template = loop-b" & LF & "name = B" & LF
                                & "version = 1" & LF & "includes = loop-a"
                                & LF));
      Tp.Compose (Registry, "loop-a", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a template including itself composed");

      Tp.Add (Registry, Parsed ("template = lonely" & LF & "name = L" & LF
                                & "version = 1" & LF & "includes = absent"
                                & LF));
      Tp.Compose (Registry, "lonely", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Not_Found,
              "a template including one that is not there composed");
      Tp.Compose (Registry, "nobody", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Not_Found,
              "a template that is not there composed");

      Tp.Parse ("template = x" & LF & "name = X" & LF & "version = 1" & LF
                & "colour blue = yes" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a line nobody understands was read");
      Tp.Parse ("name = X" & LF & "version = 1" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a template that does not say which it is was read");
      Tp.Parse ("template = x" & LF & "name = X" & LF & "version = 1" & LF
                & "file ../outside = no" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a file outside the project was declared");
   end Template_Conflicts_Are_Refused;

   --  Inputs are given, found or defaulted, checked, and asked for by name
   --  when none of those; a secret stays out of the configuration.
   procedure Inputs_Are_Resolved (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project  : constant String := Fresh ("inputs");
      Registry : constant Tp.Registry := Family;
      Composed : Tp.Composition;
      Status   : E.Error_Info;
      Given    : Cf.Value_Maps.Map;
      Planned  : Cf.Plan;
   begin
      Tp.Compose (Registry, "app", Composed, Status);

      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Assert (Status.Code = E.Framework_Input_Missing
              and then Natural (Planned.Missing.Length) = 1
              and then Planned.Missing.First_Element = "project_name",
              "a required input with no value was not asked for");

      declare
         Checked : E.Error_Info;
         Style   : constant Tp.Input_Declaration := Tp.Input_At (Composed, 2);
      begin
         Cf.Check_Input (Style, "verbose", Checked);
         Assert (E.Is_Ok (Checked), "one of an input's choices was refused");
         Cf.Check_Input (Style, "shout", Checked);
         Assert (Checked.Code = E.Framework_Input_Invalid,
                 "a value none of an input's choices was taken");
      end;

      Given.Include ("project_name", "not an identifier");
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Assert (Status.Code = E.Framework_Input_Invalid,
              "a value of the wrong kind was taken");

      Given.Include ("project_name", "demo");
      Given.Include ("style", "loud");
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Assert (Status.Code = E.Framework_Input_Invalid,
              "a choice that is none of them was taken");

      Given.Delete ("style");
      Given.Include ("token", "s3cret");
      Given.Include ("colour", "blue");
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Assert (Status.Code = E.Framework_Input_Invalid,
              "an input no template asks for was taken");
      Given.Delete ("colour");

      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Assert (E.Is_Ok (Status), "good inputs were refused: " & Code_Of (Status));
      Assert (Planned.Inputs ("style") = "terse", "a default was not taken");
      Assert (To_String (Planned.Project_Name) = "demo",
              "the project is not called what it was named");
      Assert (not R.Has (Planned.Configuration, "input.token")
              and then R.Get (Planned.Configuration, "input.project_name")
                       = "demo",
              "a secret was written into the configuration");
      Assert (Planned.Files.Contains ("src/main.txt")
              and then Planned.Files ("src/main.txt")
                       = "the demo program, terse" & LF,
              "a file was not written with its inputs");
      Assert (R.Get (Planned.Configuration, "profile.quick") = "demo check",
              "a declaration was not written with its inputs");

      --  Discovery answers what it can, and a caller's value outranks it.
      Put_File (Project & "/tool.toml", "");
      Given.Clear;
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Assert (E.Is_Ok (Status) and then Planned.Inputs ("project_name")
              = "from_tool", "a discovered input was asked for again");
      Assert (Planned.Discovered_Facts ("build_system") = "Tool"
              and then R.Get (Planned.Configuration, "fact.build_system")
                       = "Tool", "a discovered fact was not recorded");
      Given.Include ("project_name", "given");
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Assert (Planned.Inputs ("project_name") = "given",
              "discovery outranked what the caller gave");
   end Inputs_Are_Resolved;

   --  The same template and inputs make the same configuration, whatever
   --  order its declarations came in and wherever the template was read.
   procedure Configuration_Fingerprint_Is_Stable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project  : constant String := Fresh ("stable");
      First    : Tp.Registry;
      Second   : Tp.Registry;
      One, Two : Tp.Composition;
      Status   : E.Error_Info;
      Given    : Cf.Value_Maps.Map;
      A, B     : Cf.Plan;
      Moved    : Tp.Template;
   begin
      Tp.Add (First, Parsed ("template = t" & LF & "name = T" & LF
                             & "version = 1" & LF & "scalar a = 1" & LF
                             & "set s = x" & LF & "set s = y" & LF));
      Tp.Parse ("template = t" & LF & "name = T" & LF & "version = 1" & LF
                & "set s = y" & LF & "set s = x" & LF & "scalar a = 1" & LF,
                "elsewhere/t.template", Moved, Status);
      Tp.Add (Second, Moved);

      Tp.Compose (First, "t", One, Status);
      Tp.Compose (Second, "t", Two, Status);
      Cf.Prepare (One, Project, Given, A, Status);
      Cf.Prepare (Two, Project, Given, B, Status);
      Assert (R.Get (A.Configuration, "configuration_fingerprint")
              = R.Get (B.Configuration, "configuration_fingerprint")
              and then R.Get (A.Configuration, "set.s") = "x" & LF & "y",
              "one configuration in two orders has two fingerprints");
      Assert (Cf.Configuration_Fingerprint (A.Configuration)
              = R.Get (A.Configuration, "configuration_fingerprint"),
              "a configuration's fingerprint is not of itself");

      Given.Include ("nothing", "x");
      Cf.Prepare (One, Project, Given, A, Status);
      Assert (Status.Code = E.Framework_Input_Invalid,
              "an input for a template with none was taken");
   end Configuration_Fingerprint_Is_Stable;

   --  A project initialized from templates opens and reads its
   --  configuration with the templates gone.
   procedure Initialized_Project_Outlives_Template
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project   : constant String := Fresh ("initialized");
      Installed : constant String := Fresh ("installed-templates");
      Registry  : Tp.Registry;
      Composed  : Tp.Composition;
      Status    : E.Error_Info;
      Given     : Cf.Value_Maps.Map;
      Planned   : Cf.Plan;
      Done      : Cf.Outcome;
      Store     : S.Store;
      Report    : S.Recovery_Report;
      Config    : R.Item;
      Found     : Model_Runner.Framework.Facts.Fact;
      Places    : Model_Runner.Framework.Name_Lists.Vector;
   begin
      Put_File (Installed & "/app.template", App_Text);
      Put_File (Installed & "/lang.template", Base_Text);
      Put_File (Installed & "/tool.template", Tool_Text);
      Put_File (Installed & "/broken.template", "not a template" & LF);
      Places.Append (Installed);
      Tp.Discover (Places, Registry);
      Assert (Tp.Count (Registry) = 4, "installed templates were not found");
      Assert (Tp.Problem (Registry, 2).Code = E.Framework_Template_Invalid
              and then Tp.Id (Tp.Template_At (Registry, 2)) = "broken",
              "a broken template was not kept as unavailable");
      Assert (Tp.Origin (Tp.Template_At (Registry, 1))
              = Installed & "/app.template",
              "a template does not say where it was read");

      Put_File (Project & "/keep.txt", "mine");
      Tp.Compose (Registry, "app", Composed, Status);
      Given.Include ("project_name", "demo");
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Cf.Initialize (Store, Project, Planned, Done, Status);
      Assert (E.Is_Ok (Status), "a project was not initialized: "
              & Code_Of (Status));
      Assert (Natural (Done.Made_Directories.Length) = 1
              and then Natural (Done.Written_Files.Length) = 2
              and then Dirs.Exists (Project & "/src/demo.txt"),
              "the template's directories and files were not made");
      S.Close (Store);

      Cf.Initialize (Store, Project, Planned, Done, Status);
      Assert (Status.Code = E.Framework_Already_Initialized,
              "a project was initialized twice");

      Dirs.Delete_Tree (Installed);

      S.Open (Store, Project, Report, Status);
      Assert (E.Is_Ok (Status), "an initialized project did not reopen");
      Cf.Read (Store, Config, Status);
      Assert (E.Is_Ok (Status) and then R.Revision (Config) = 1
              and then R.Get (Config, "template_id") = "app"
              and then R.Get (Config, "template_order") = "lang, tool, app",
              "the configuration did not outlive its template");
      Assert (S.Exists (Store, F.Config_Area, "revision-000001"),
              "the configuration's first revision was not kept");
      Assert (S.Project_Name (Store) = "demo",
              "the project is not called by its input");
      Model_Runner.Framework.Facts.Find (Store, "language", Found, Status);
      Assert (E.Is_Ok (Status) and then To_String (Found.Value) = "Lang_2022"
              and then Found.Source = Model_Runner.Framework.Facts.Template,
              "a template's fact was not recorded as the template's");

      --  A configuration changed under its fingerprint is found out.
      R.Set (Config, "scalar.build.command", "something else");
      R.Set_Revision (Config, 2);
      declare
         Change : S.Transaction;
      begin
         S.Put (Change, F.Config_Area, "resolved", Config);
         S.Commit (Store, Change, Status);
      end;
      Cf.Read (Store, Config, Status);
      Assert (Status.Code = E.Framework_Integrity_Failed,
              "a configuration that no longer matches its fingerprint was read");
      S.Close (Store);
   end Initialized_Project_Outlives_Template;

   ---------------------------------------------------------------------------
   --  Events, transitions, leases and consistency.
   ---------------------------------------------------------------------------

   package Ev renames Model_Runner.Framework.Events;
   package Tr renames Model_Runner.Framework.Transitions;
   package Ls renames Model_Runner.Framework.Leases;
   package Cn renames Model_Runner.Framework.Consistency;

   --  A task-like record, for the machine to move.
   function Task_Record (Entity, State : String) return R.Item is
      Value : R.Item := R.Create ("project.fact", 1, Entity, 1);
   begin
      R.Set (Value, "key", "k");
      R.Set (Value, "value", "v");
      R.Set (Value, "source", "explicit");
      R.Set (Value, "confidence", "certain");
      R.Set (Value, "state", State);
      return Value;
   end Task_Record;

   --  An event is committed with its change, never without it, and names
   --  the transaction it came from.
   procedure Events_Commit_With_Their_Change
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("events");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Id      : Unbounded_String;
      Txn     : Unbounded_String;
      Before  : Natural;
      Listed  : Ev.Event_List;
   begin
      S.Create (Store, Project, "Events", Status);
      Before := Ev.Length (Ev.Since (Store, 0));

      S.Put (Change, F.Project_Area, "fact.a", Task_Record ("FACT-A", "x"));
      Ev.Emit (Store, Change, Ev.Requirement_Accepted, "FACT-A", "why", Id,
               Status);
      Assert (E.Is_Ok (Status), "an event was not staged: " & Code_Of (Status));
      S.Identify (Store, Change, Txn, Status);
      Assert (Ev.Length (Ev.Since (Store, 0)) = Before,
              "an event was there before its change was committed");
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "an event's change was not committed");

      Listed := Ev.Since (Store, Before);
      Assert (Ev.Length (Listed) = 1, "a committed event is not there");
      declare
         Got : constant Ev.Event := Ev.Element (Listed, 1);
      begin
         Assert (Got.Id = Id and then Got.Known
                 and then Got.Kind = Ev.Requirement_Accepted
                 and then To_String (Got.Subject) = "FACT-A"
                 and then Got.Transaction = Txn
                 and then To_String (Got.Detail) = "why"
                 and then Got.Sequence = Before + 1,
                 "an event did not come back as it was written");
         Assert (Ev.Kind_Name (Got.Kind) = "Requirement_Accepted",
                 "an event kind is not written as its name");
      end;

      --  A change that fails takes its event with it.
      S.Put (Change, F.Project_Area, "fact.a", Task_Record ("FACT-A", "y"));
      Ev.Emit (Store, Change, Ev.Requirement_Revised, "FACT-A", "", Id, Status);
      S.Commit (Store, Change, Status);
      Assert (Status.Code = E.Framework_Revision_Conflict,
              "a change against an old revision was committed");
      Assert (Ev.Length (Ev.Since (Store, 0)) = Before + 1,
              "a refused change left its event behind");

      Ev.Emit (Store, Change, Ev.Requirement_Revised, "not an id", "", Id,
               Status);
      Assert (Status.Code = E.Framework_Identifier_Invalid,
              "an event about no entity was staged");
      S.Close (Store);
   end Events_Commit_With_Their_Change;

   --  An event acted on is recognised when it comes again, whether in the
   --  same transaction or after a restart.
   procedure Consumption_Is_Idempotent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("consumed");
      Store   : S.Store;
      Report  : S.Recovery_Report;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Id      : Unbounded_String;
      Fresh_1 : Boolean;
      Fresh_2 : Boolean;
   begin
      S.Create (Store, Project, "Consumed", Status);
      Ev.Emit (Store, Change, Ev.Build_Completed, "PROJECT", "", Id, Status);
      S.Commit (Store, Change, Status);

      Ev.Consume (Store, Change, "counter", To_String (Id), Fresh_1, Status);
      Ev.Consume (Store, Change, "counter", To_String (Id), Fresh_2, Status);
      Assert (Fresh_1 and then not Fresh_2,
              "an event delivered twice in one change was acted on twice");
      Commit_Fact (Store, "builds", "1");
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a consumption was not committed");
      S.Close (Store);

      S.Open (Store, Project, Report, Status);
      Ev.Consume (Store, Change, "counter", To_String (Id), Fresh_1, Status);
      Assert (E.Is_Ok (Status) and then not Fresh_1,
              "an event replayed after a restart was acted on again");
      Ev.Consume (Store, Change, "another", To_String (Id), Fresh_1, Status);
      Assert (Fresh_1, "one consumer's record answered for another");
      Ev.Consume (Store, Change, "no/name", To_String (Id), Fresh_1, Status);
      Assert (Status.Code = E.Framework_Name_Invalid,
              "a consumer that is no name was recorded");
      S.Close (Store);
   end Consumption_Is_Idempotent;

   --  The task lifecycle allows exactly its moves, the policy moves only
   --  with their policy, and an illegal move changes nothing.
   procedure Task_Transition_Matrix
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Machine : Tr.Machine := Tr.Task_Machine;
      type Name is access constant String;
      States  : constant array (1 .. 9) of Name :=
        [new String'("candidate"), new String'("accepted"),
         new String'("running"), new String'("blocked"),
         new String'("verification"), new String'("complete"),
         new String'("failed"), new String'("cancelled"),
         new String'("rejected")];
      Allowed : constant String :=
        "candidate>accepted candidate>rejected accepted>running "
        & "accepted>blocked accepted>cancelled blocked>accepted "
        & "blocked>cancelled blocked>failed running>verification "
        & "running>blocked running>failed running>cancelled "
        & "verification>complete verification>running verification>blocked "
        & "verification>failed verification>cancelled failed>accepted "
        & "failed>cancelled ";
      Policy  : constant String :=
        "complete>accepted cancelled>accepted rejected>candidate ";
      Status  : E.Error_Info;
      All_Granted : constant Tr.Permissions := [others => True];
   begin
      --  Every pair of states, against the table in the specification.
      for From of States loop
         for To of States loop
            declare
               Pair : constant String := From.all & ">" & To.all & " ";
               Ordinary_Move : constant Boolean :=
                 Ada.Strings.Fixed.Index (Allowed, Pair) > 0
                 and then (Ada.Strings.Fixed.Index (Allowed, Pair) = 1
                           or else Allowed
                             (Ada.Strings.Fixed.Index (Allowed, Pair) - 1)
                             = ' ');
               Policy_Move : constant Boolean :=
                 Ada.Strings.Fixed.Index (Policy, Pair) > 0
                 and then (Ada.Strings.Fixed.Index (Policy, Pair) = 1
                           or else Policy
                             (Ada.Strings.Fixed.Index (Policy, Pair) - 1)
                             = ' ');
            begin
               Tr.Check (Machine, "TASK-1", From.all, To.all, Tr.Ordinary_Only,
                         Status);
               Assert (E.Is_Ok (Status) = Ordinary_Move,
                       "the move " & Pair & "is wrongly "
                       & (if Ordinary_Move then "refused" else "allowed"));
               Tr.Check (Machine, "TASK-1", From.all, To.all, All_Granted,
                         Status);
               Assert (E.Is_Ok (Status) = (Ordinary_Move or else Policy_Move),
                       "the move " & Pair & "is wrong under its policy");
            end;
         end loop;
      end loop;

      Assert (Tr.Is_State (Machine, "verification")
              and then not Tr.Is_State (Machine, "ready"),
              "ready is a stored state; it is derived");

      --  A project can narrow the machine, and widen it.
      Tr.Forbid (Machine, "running", "cancelled");
      Tr.Check (Machine, "TASK-1", "running", "cancelled", Tr.Ordinary_Only,
                Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a forbidden move was allowed");
      Tr.Allow (Machine, "blocked", "review");
      Tr.Add_State (Machine, "archived");
      Tr.Check (Machine, "TASK-1", "blocked", "review", Tr.Ordinary_Only,
                Status);
      Assert (E.Is_Ok (Status), "an added move was refused");
      Tr.Check (Machine, "TASK-1", "archived", "nowhere", Tr.Ordinary_Only,
                Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a move to no state was allowed");
   end Task_Transition_Matrix;

   --  A move applied to a record writes its next revision and its event
   --  together; an illegal one writes neither.
   procedure Transitions_Are_Applied_Whole
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("transitions");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Value   : R.Item;
      Before  : Natural;
   begin
      S.Create (Store, Project, "Transitions", Status);
      S.Put (Change, F.Tasks_Area, "task-1", Task_Record ("TASK-1", "candidate"));
      S.Commit (Store, Change, Status);
      Before := Ev.Length (Ev.Since (Store, 0));

      Tr.Apply (Store, Change, Tr.Task_Machine, F.Tasks_Area, "task-1",
                "running", Tr.Ordinary_Only, Ev.Task_Started, Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a candidate was started");
      Assert (S.Change_Count (Change) = 0, "a refused move staged something");

      Tr.Apply (Store, Change, Tr.Task_Machine, F.Tasks_Area, "task-1",
                "accepted", Tr.Ordinary_Only, Ev.Task_Accepted, Status);
      Tr.Apply (Store, Change, Tr.Task_Machine, F.Tasks_Area, "task-1",
                "running", Tr.Ordinary_Only, Ev.Task_Started, Status);
      Assert (E.Is_Ok (Status), "two legal moves in one change were refused");
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "legal moves were not committed: "
              & Code_Of (Status));

      S.Read (Store, F.Tasks_Area, "task-1", Value, Status);
      Assert (R.Get (Value, "state") = "running" and then R.Revision (Value) = 2,
              "the moves did not make one next revision");
      Assert (Ev.Length (Ev.Since (Store, Before)) = 2
              and then To_String (Ev.Element (Ev.Since (Store, Before), 1).Detail)
                       = "candidate -> accepted",
              "the moves did not each leave their event");
      S.Close (Store);
   end Transitions_Are_Applied_Whole;

   --  A lease is held by one owner until it runs out, and then is stale.
   procedure Leases_Run_Out (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("leases");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Gone    : R.Item := R.Create
        (Model_Runner.Framework.Schemas.Lease_Schema, 1, "LEASE", 1);
   begin
      S.Create (Store, Project, "Leases", Status);
      Ls.Acquire (Store, Change, "workspace-1", "agent-a", 600, Status);
      S.Commit (Store, Change, Status);
      Assert (Ls.Holder (Store, "workspace-1") = "agent-a",
              "a lease taken is not held");

      Ls.Acquire (Store, Change, "workspace-1", "agent-b", 600, Status);
      Assert (Status.Code = E.Framework_Lease_Held,
              "a second owner took a held lease");
      Ls.Release (Store, Change, "workspace-1", "agent-b", Status);
      Assert (Status.Code = E.Framework_Lease_Held,
              "a lease was let go by somebody who does not hold it");
      Ls.Acquire (Store, Change, "workspace-1", "agent-a", 600, Status);
      Assert (E.Is_Ok (Status), "an owner could not renew its lease");
      S.Commit (Store, Change, Status);
      Ls.Release (Store, Change, "workspace-1", "agent-a", Status);
      S.Commit (Store, Change, Status);
      Assert (Ls.Holder (Store, "workspace-1") = "",
              "a released lease is still held");
      Ls.Acquire (Store, Change, "no/name", "agent-a", 1, Status);
      Assert (Status.Code = E.Framework_Name_Invalid,
              "a lease on no name was taken");

      --  One whose owner stopped renewing it.
      R.Set (Gone, "resource", "workspace-2");
      R.Set (Gone, "owner", "crashed");
      R.Set (Gone, "acquired_at", "2020-01-01T00:00:00Z");
      R.Set (Gone, "expires_at", "2020-01-01T00:10:00Z");
      S.Put (Change, F.Runtime_Area, "lease.workspace-2", Gone);
      S.Commit (Store, Change, Status);
      Assert (Ls.Holder (Store, "workspace-2") = ""
              and then Natural (Ls.Stale (Store).Length) = 1,
              "a lease that ran out is still held, or not seen as stale");
      Ls.Acquire (Store, Change, "workspace-2", "agent-b", 600, Status);
      Assert (E.Is_Ok (Status), "a stale lease could not be taken over");
      S.Close (Store);
   end Leases_Run_Out;

   --  The consistency check finds what does not hold together, and finds
   --  nothing in state that does.
   procedure Consistency_Finds_What_Is_Wrong
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("consistency");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Gone    : R.Item := R.Create
        (Model_Runner.Framework.Schemas.Lease_Schema, 1, "LEASE", 1);
      Findings : Cn.Finding_List;

      function Has (Kind : Cn.Finding_Kind) return Boolean is
         use type Cn.Finding_Kind;
      begin
         for Index in 1 .. Cn.Length (Findings) loop
            if Cn.Element (Findings, Index).Kind = Kind then
               return True;
            end if;
         end loop;
         return False;
      end Has;
   begin
      S.Create (Store, Project, "Consistency", Status);
      Commit_Fact (Store, "language", "Ada_2022");
      Findings := Cn.Check (Store);
      Assert (Cn.Length (Findings) = 0,
              "state that holds together was found wanting: "
              & (if Cn.Length (Findings) > 0
                 then Cn.Kind_Word (Cn.Element (Findings, 1).Kind) & " "
                      & To_String (Cn.Element (Findings, 1).Detail)
                 else ""));

      --  Two records claiming one entity.
      S.Put (Change, F.Specs_Area, "copy", Task_Record ("FACT-LANGUAGE", "x"));
      S.Commit (Store, Change, Status);

      --  A lease that ran out.
      R.Set (Gone, "resource", "w");
      R.Set (Gone, "owner", "crashed");
      R.Set (Gone, "acquired_at", "2020-01-01T00:00:00Z");
      R.Set (Gone, "expires_at", "2020-01-01T00:10:00Z");
      S.Put (Change, F.Runtime_Area, "lease.w", Gone);
      S.Commit (Store, Change, Status);

      --  A record that is no longer one, and a change left staged.
      Put_File (S.Root (Store) & "/decisions/broken.rec", "broken");
      S.Put (Change, F.Project_Area, "fact.later", Task_Record ("FACT-L", "x"));
      S.Stage (Store, Change, Status);

      Findings := Cn.Check (Store);
      Assert (Has (Cn.Duplicate_Identifier), "a duplicate entity was not found");
      Assert (Has (Cn.Stale_Lease), "a stale lease was not found");
      Assert (Has (Cn.Schema_Mismatch), "a broken record was not found");
      Assert (Has (Cn.Incomplete_Transaction),
              "a change left in the journal was not found");
      Assert (Cn.Kind_Word (Cn.Index_Mismatch) = "index_mismatch",
              "a kind of finding is not written as its word");

      --  An index that says something the records do not.
      declare
         Index : R.Item;
      begin
         S.Read (Store, F.Indexes_Area, "entities", Index, Status);
         R.Set (Index, "entity.NOBODY", "project/nobody");
         Put_File (S.Root (Store) & "/indexes/entities.rec", R.Serialize (Index));
      end;
      Findings := Cn.Check (Store);
      Assert (Has (Cn.Index_Mismatch), "a wrong index was not found");
      S.Close (Store);
   end Consistency_Finds_What_Is_Wrong;

   ---------------------------------------------------------------------------
   --  Specifications, requirements, decisions, authority and bootstrap.
   ---------------------------------------------------------------------------

   package Nt renames Model_Runner.Framework.Intent;
   package Au renames Model_Runner.Framework.Authority;
   package Bs renames Model_Runner.Framework.Bootstrap;

   --  A requirement goes through its lifecycle, and a revision that
   --  changes its meaning undoes what no longer applies without rewriting
   --  what was.
   procedure Requirement_Revisions_Invalidate
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("requirements");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Id      : Unbounded_String;
      Value   : Nt.Entity;
      Effect  : Nt.Impact;
      Kept    : R.Item;

      procedure Move (Next : String) is
      begin
         Nt.Move (Store, Change, Nt.Requirement, To_String (Id), Next,
                   Tr.Ordinary_Only, Status);
         Assert (E.Is_Ok (Status), "the move to " & Next & " was refused: "
                 & Code_Of (Status));
         S.Commit (Store, Change, Status);
      end Move;
   begin
      S.Create (Store, Project, "Requirements", Status);
      Nt.Propose
        (Store, Change, Nt.Requirement, "PARSER", "Reject bad UTF-8",
         "The parser SHALL reject invalid UTF-8.", "a test feeds 0xC0 0x80",
         "user", "", "parser", Id, Status);
      Assert (E.Is_Ok (Status) and then To_String (Id) = "REQ-PARSER-001",
              "a requirement was not given its identifier");
      S.Commit (Store, Change, Status);

      Nt.Move (Store, Change, Nt.Requirement, To_String (Id), "verified",
                Tr.Ordinary_Only, Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a candidate was verified");
      Move ("accepted");
      Move ("implemented");
      Move ("verified");

      --  A reworded title is not a change of meaning.
      Nt.Revise (Store, Change, Nt.Requirement, To_String (Id),
                  "Refuse bad UTF-8", "The parser SHALL reject invalid UTF-8.",
                  "a test feeds 0xC0 0x80", Effect, Status);
      Assert (E.Is_Ok (Status) and then not Effect.Normative
              and then To_String (Effect.After) = "verified",
              "a new title undid a verification");
      S.Commit (Store, Change, Status);

      --  New criteria: the evidence was for the old ones.
      Nt.Revise (Store, Change, Nt.Requirement, To_String (Id),
                  "Refuse bad UTF-8", "The parser SHALL reject invalid UTF-8.",
                  "a test feeds every overlong form", Effect, Status);
      Assert (Effect.Normative and then Effect.Invalidated
              and then To_String (Effect.After) = "implemented",
              "new criteria left a requirement verified");
      S.Commit (Store, Change, Status);

      --  A new statement: the implementation was for the old one.
      Nt.Revise (Store, Change, Nt.Requirement, To_String (Id),
                  "Refuse bad UTF-8", "The parser SHALL reject and report"
                  & " invalid UTF-8.", "a test feeds every overlong form",
                  Effect, Status);
      Assert (To_String (Effect.After) = "accepted"
              and then not Effect.Invalidated,
              "a new statement left an implemented requirement implemented");
      S.Commit (Store, Change, Status);

      Nt.Read (Store, Nt.Requirement, To_String (Id), Value, Status);
      Assert (E.Is_Ok (Status) and then Value.Revision = 7
              and then To_String (Value.State) = "accepted",
              "the requirement is not at its last revision: "
              & Natural'Image (Value.Revision));
      S.Read (Store, F.Requirements_Area,
              To_String (Id) & ".rev-000005", Kept, Status);
      Assert (E.Is_Ok (Status)
              and then R.Get (Kept, "criteria") = "a test feeds 0xC0 0x80"
              and then R.Get (Kept, "state") = "verified",
              "an earlier revision was not kept as it was");
      Assert (Natural (Nt.List (Store, Nt.Requirement).Length) = 1,
              "the kept revisions are listed as requirements");

      declare
         Invalidated : Boolean := False;
         Listed      : constant Ev.Event_List := Ev.Since (Store, 0);
      begin
         for Index in 1 .. Ev.Length (Listed) loop
            Invalidated := Invalidated
              or else Ev.Element (Listed, Index).Kind
                        = Ev.Requirement_Verification_Invalidated;
         end loop;
         Assert (Invalidated, "the lost verification was not recorded");
      end;

      Move ("obsolete");
      Nt.Revise (Store, Change, Nt.Requirement, To_String (Id), "x", "y", "z",
                  Effect, Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "an obsolete requirement was revised");

      Nt.Read (Store, Nt.Requirement, "REQ-NONE-001", Value, Status);
      Assert (Status.Code = E.Framework_Not_Found,
              "a requirement nobody proposed was read");
      Assert (Nt.First_State (Nt.Decision) = "proposed"
              and then Nt.Namespace (Nt.Specification) = "SPEC"
              and then Tr.Is_State (Nt.Machine_Of (Nt.Requirement),
                                    "implemented"),
              "the registers are not what they should be");
      S.Close (Store);
   end Requirement_Revisions_Invalidate;

   --  A decision replaced says by what, and the decisions that apply to a
   --  component are its own and the project's.
   procedure Decisions_Supersede_And_Apply
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project  : constant String := Fresh ("decisions");
      Store    : S.Store;
      Status   : E.Error_Info;
      Change   : S.Transaction;
      Old_Id   : Unbounded_String;
      New_Id   : Unbounded_String;
      Other_Id : Unbounded_String;
      Req_Id   : Unbounded_String;
      Value    : Nt.Entity;
   begin
      S.Create (Store, Project, "Decisions", Status);
      Nt.Propose (Store, Change, Nt.Decision, "IO", "Blocking reads",
                   "Reads block.", "simplest", "user", "", "io", Old_Id,
                   Status);
      Nt.Propose (Store, Change, Nt.Decision, "IO", "Asynchronous reads",
                   "Reads are asynchronous.", "throughput", "user", "", "io",
                   New_Id, Status);
      Nt.Propose (Store, Change, Nt.Decision, "", "Ada 2022",
                   "Code is Ada 2022.", "", "user", "", "project", Other_Id,
                   Status);
      S.Commit (Store, Change, Status);
      Nt.Move (Store, Change, Nt.Decision, To_String (Old_Id), "accepted",
                Tr.Ordinary_Only, Status);
      Nt.Move (Store, Change, Nt.Decision, To_String (Other_Id), "accepted",
                Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);

      Nt.Supersede (Store, Change, Nt.Decision, To_String (Old_Id),
                     To_String (New_Id), Status);
      Assert (E.Is_Ok (Status), "a decision was not superseded: "
              & Code_Of (Status));
      S.Commit (Store, Change, Status);

      Nt.Read (Store, Nt.Decision, To_String (Old_Id), Value, Status);
      Assert (To_String (Value.State) = "superseded"
              and then Value.Superseded_By = New_Id,
              "the decision replaced does not say by what");
      Nt.Read (Store, Nt.Decision, To_String (New_Id), Value, Status);
      Assert (To_String (Value.State) = "accepted"
              and then Value.Supersedes = Old_Id,
              "the replacing decision does not say what it replaced");

      Assert (Natural (Nt.Applicable_Decisions (Store, "io").Length) = 2
              and then Natural (Nt.Applicable_Decisions (Store, "ui").Length)
                       = 1,
              "the decisions applying to a component are not its own and the"
              & " project's");

      --  Links are kept once, in the order made.
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "t", "x", "", "user",
                   "", "io", Req_Id, Status);
      Nt.Link (Store, Change, Nt.Requirement, To_String (Req_Id),
                Nt.Dependency, "REQ-IO-009", Status);
      Nt.Link (Store, Change, Nt.Requirement, To_String (Req_Id),
                Nt.Dependency, "REQ-IO-009", Status);
      Nt.Link (Store, Change, Nt.Requirement, To_String (Req_Id),
                Nt.Test, "tests/io", Status);
      S.Commit (Store, Change, Status);
      Assert (Natural (Nt.Links (Store, Nt.Requirement, To_String (Req_Id),
                                  Nt.Dependency).Length) = 1
              and then Nt.Links (Store, Nt.Requirement, To_String (Req_Id),
                                  Nt.Test).First_Element = "tests/io",
              "links were not kept once each");

      --  A dependency on a requirement nobody made is found.
      declare
         Findings : constant Cn.Finding_List := Cn.Check (Store);
         Undefined : Boolean := False;
         use type Cn.Finding_Kind;
      begin
         for Index in 1 .. Cn.Length (Findings) loop
            Undefined := Undefined
              or else Cn.Element (Findings, Index).Kind
                        = Cn.Undefined_Requirement;
         end loop;
         Assert (Undefined, "a dependency on no requirement was not found");
      end;
      S.Close (Store);
   end Decisions_Supersede_And_Apply;

   --  The highest statement governs; the others agree, refine, are
   --  overridden by name, or conflict.
   procedure Authority_Is_Resolved (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Given  : Au.Statement_List;
      Result : Au.Resolution;
      Found  : Boolean;

      function Said
        (Standing : Au.Level; Source, Subject, Value : String;
         Overrides : String := "") return Au.Statement
      is (Standing  => Standing,
          Source    => To_Unbounded_String (Source),
          Subject   => To_Unbounded_String (Subject),
          Value     => To_Unbounded_String (Value),
          Overrides => To_Unbounded_String (Overrides));

      function Relation_Of (Source : String) return Au.Relation is
      begin
         for Index in 1 .. Au.Length (Result) loop
            if To_String (Au.Element (Result, Index).Other.Source) = Source then
               return Au.Element (Result, Index).Relation;
            end if;
         end loop;
         return Au.Agreement;
      end Relation_Of;

      use type Au.Relation;
   begin
      Au.Append (Given, Said (Au.Resolved_Configuration, "CONFIG",
                              "scalar.build.command", "alr build"));
      Au.Append (Given, Said (Au.Project_Decision, "DEC-001",
                              "scalar.build.command", "alr build --release",
                              Overrides => "CONFIG"));
      Au.Append (Given, Said (Au.Language_Baseline, "BASE",
                              "scalar.build.command", "gprbuild"));
      Au.Append (Given, Said (Au.Agent_Assumption, "GUESS",
                              "scalar.build.command", "alr build --release"));
      Au.Append (Given, Said (Au.Project_Specification, "SPEC-001",
                              "scalar.build.command.flags", "-gnatwa"));
      Assert (Au.Count (Given) = 5, "a statement was lost");

      Result := Au.Resolve (Given);
      Assert (To_String (Au.Governing (Result, "scalar.build.command", Found)
                           .Source) = "DEC-001" and then Found,
              "the highest standing does not govern");
      Assert (Relation_Of ("CONFIG") = Au.Explicit_Override,
              "an override naming what it overrides was not one");
      Assert (Relation_Of ("BASE") = Au.Conflict,
              "a disagreement nobody resolved was not a conflict");
      Assert (Relation_Of ("GUESS") = Au.Agreement,
              "a statement saying the same did not agree");
      Assert (Relation_Of ("DEC-001") = Au.Refinement,
              "a narrower subject did not refine a broader one");
      declare
         Nothing : constant Au.Statement :=
           Au.Governing (Result, "nobody.said", Found);
         pragma Unreferenced (Nothing);
      begin
         Assert (not Found, "a subject nobody spoke to has a ruling");
      end;
   end Authority_Is_Resolved;

   --  What decisions and the configuration say is gathered from the state,
   --  and a conflict between them is found by the consistency check.
   procedure Authority_Conflicts_Are_Found
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project  : constant String := Fresh ("authority");
      Store    : S.Store;
      Status   : E.Error_Info;
      Change   : S.Transaction;
      Registry : Tp.Registry;
      Composed : Tp.Composition;
      Given    : Cf.Value_Maps.Map;
      Planned  : Cf.Plan;
      Done     : Cf.Outcome;
      Id       : Unbounded_String;
      Findings : Cn.Finding_List;

      function Conflicted return Boolean is
         use type Cn.Finding_Kind;
      begin
         for Index in 1 .. Cn.Length (Findings) loop
            if Cn.Element (Findings, Index).Kind = Cn.Conflicting_Authority then
               return True;
            end if;
         end loop;
         return False;
      end Conflicted;
   begin
      Tp.Add (Registry, Parsed ("template = t" & LF & "name = T" & LF
                                & "version = 1" & LF
                                & "scalar build.command = make" & LF));
      Tp.Compose (Registry, "t", Composed, Status);
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Cf.Initialize (Store, Project, Planned, Done, Status);

      Nt.Propose (Store, Change, Nt.Decision, "", "Build with Alire",
                   "Alire builds it.", "", "user", "", "project", Id, Status);
      Nt.Govern (Store, Change, Nt.Decision, To_String (Id),
                  "scalar.build.command", "alr build", "", Status);
      Nt.Move (Store, Change, Nt.Decision, To_String (Id), "accepted",
                Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a governing decision was not committed: "
              & Code_Of (Status));
      Assert (Au.Count (Au.Gather (Store)) = 2,
              "the decision and the setting were not both gathered");

      Findings := Cn.Check (Store);
      Assert (Conflicted, "a decision contradicting the configuration without"
              & " saying so was not found");

      Nt.Govern (Store, Change, Nt.Decision, To_String (Id),
                  "scalar.build.command", "alr build", "CONFIG", Status);
      S.Commit (Store, Change, Status);
      Findings := Cn.Check (Store);
      Assert (not Conflicted, "an explicit override was reported as a conflict");
      S.Close (Store);
   end Authority_Conflicts_Are_Found;

   --  Bootstrap classifies what a document says, and running it again
   --  makes only what is new.
   procedure Bootstrap_Is_Repeatable
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("bootstrap");
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Report  : Bs.Report;
      Document : constant String :=
        "# The parser" & LF
        & "" & LF
        & "- REQ-PARSE-003: Input is read in one pass." & LF
        & "The parser SHALL reject invalid UTF-8." & LF
        & "It MUST report the offset of the first bad byte." & LF
        & "Decision: errors are values, not exceptions." & LF
        & "Nothing here is normative." & LF
        & "The parser SHALL reject invalid UTF-8." & LF
        & "The MUSTARD is SHALLOW." & LF;
      Found   : constant Bs.Output_List := Bs.Scan ("docs/parser.md", Document);

      function Count_Of (Kind : Bs.Output_Kind) return Natural is
         use type Bs.Output_Kind;
         Total : Natural := 0;
      begin
         for Index in 1 .. Bs.Length (Found) loop
            if Bs.Element (Found, Index).Kind = Kind then
               Total := Total + 1;
            end if;
         end loop;
         return Total;
      end Count_Of;
   begin
      Assert (Count_Of (Bs.Specification_Candidate) = 1
              and then Count_Of (Bs.Imported_Item) = 1
              and then Count_Of (Bs.Requirement_Candidate) = 2
              and then Count_Of (Bs.Decision_Candidate) = 1
              and then Count_Of (Bs.Issue) = 1,
              "a document was not classified as it says");

      S.Create (Store, Project, "Bootstrap", Status);
      Bs.Apply (Store, Change, Found, Report, Status);
      Assert (E.Is_Ok (Status), "bootstrap was refused: " & Code_Of (Status));
      S.Commit (Store, Change, Status);
      Assert (Report.Created = 5 and then Report.Issues = 1,
              "bootstrap did not make what it found");
      Assert (Natural (Nt.List (Store, Nt.Requirement, "accepted").Length) = 1
              and then Natural (Nt.List (Store, Nt.Requirement, "candidate")
                                  .Length) = 2,
              "only the imported item should be accepted");

      --  Again, and again with a line added.
      Bs.Apply (Store, Change, Found, Report, Status);
      S.Commit (Store, Change, Status);
      Assert (Report.Created = 0 and then Report.Existing = 5,
              "bootstrap run again made its findings twice");
      Bs.Apply (Store, Change,
                Bs.Scan ("docs/parser.md",
                         Document & "Output MUST be flushed." & LF),
                Report, Status);
      S.Commit (Store, Change, Status);
      Assert (Report.Created = 1,
              "bootstrap over an edited document did not make only what is"
              & " new");
      Assert (Natural (Nt.List (Store, Nt.Requirement).Length) = 4
              and then Nt.Find_By_Provenance
                         (Store, Nt.Requirement, "docs/parser.md#REQ-PARSE-003")
                       /= "",
              "the requirements bootstrap made are not the ones it found");

      --  A discovered fact, made once.
      declare
         Facts_Found : Bs.Output_List;
      begin
         Bs.Append (Facts_Found,
                    (Kind       => Bs.Discovered_Fact,
                     Key        => To_Unbounded_String ("language"),
                     Text       => To_Unbounded_String ("Ada_2022"),
                     others     => <>));
         Bs.Apply (Store, Change, Facts_Found, Report, Status);
         S.Commit (Store, Change, Status);
         Bs.Apply (Store, Change, Facts_Found, Report, Status);
         Assert (Report.Existing = 1 and then Report.Created = 0,
                 "a discovered fact was recorded twice");
      end;
      S.Close (Store);
   end Bootstrap_Is_Repeatable;

   ---------------------------------------------------------------------------
   --  Tasks.
   ---------------------------------------------------------------------------

   package Tk renames Model_Runner.Framework.Tasks;

   --  A project whose configuration defines two kinds of task, and a
   --  requirement accepted in it.
   procedure Task_Project
     (Store  : in out S.Store;
      Leaf   : String;
      Policy : String := "")
   is
      Project  : constant String := Fresh (Leaf);
      Registry : Tp.Registry;
      Composed : Tp.Composition;
      Given    : Cf.Value_Maps.Map;
      Planned  : Cf.Plan;
      Done     : Cf.Outcome;
      Status   : E.Error_Info;
   begin
      Tp.Add (Registry, Parsed
        ("template = work" & LF & "name = W" & LF & "version = 1" & LF
         & "task_kind implementation = component, requirements?, notes?" & LF
         & "task_kind analysis = estimate?" & LF
         & "scalar task.profile.implementation = tests" & LF
         & "profile tests = run the tests" & LF & Policy));
      Tp.Compose (Registry, "work", Composed, Status);
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Cf.Initialize (Store, Project, Planned, Done, Status);
      Assert (E.Is_Ok (Status), "a task project was not made: "
              & Code_Of (Status));
   end Task_Project;

   function Fields
     (Title, Kind : String; Extra_Name, Extra_Value : String := "")
      return Tk.Field_Map
   is
      Result : Tk.Field_Map;
   begin
      Result.Include ("title", Title);
      Result.Include ("kind", Kind);
      if Extra_Name /= "" then
         Result.Include (Extra_Name, Extra_Value);
      end if;
      return Result;
   end Fields;

   --  A task is created against its kind's schema, refused for what the
   --  schema does not allow, and goes through its lifecycle only by legal
   --  moves: approved, blocked, retried, cancelled and completed.
   procedure Tasks_Follow_Their_Lifecycle
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Id     : Unbounded_String;
      Other  : Unbounded_String;

      procedure Move (Task_Id, Next : String; Gates : Boolean := False) is
      begin
         Tk.Move (Store, Change, Task_Id, Next, "because",
                  Gates_Passed => Gates, Status => Status);
         Assert (E.Is_Ok (Status), "the move of " & Task_Id & " to " & Next
                 & " was refused: " & Code_Of (Status));
         S.Commit (Store, Change, Status);
      end Move;
   begin
      Task_Project (Store, "tasks");
      Assert (Natural (Tk.Kinds (Store).Length) = 2
              and then Tk.Required_Fields (Store, "implementation")
                         .First_Element = "component",
              "the project's kinds of task were not read from its"
              & " configuration");

      Tk.Create (Store, Change, Fields ("x", "bugfix"), "user", "", Id, Status);
      Assert (Status.Code = E.Framework_Task_Kind_Unknown,
              "a kind the project does not define was taken");
      Tk.Create (Store, Change, Fields ("x", "implementation"), "user", "", Id,
                 Status);
      Assert (Status.Code = E.Framework_Input_Missing,
              "a field the kind requires was not asked for");
      Tk.Create (Store, Change,
                 Fields ("x", "analysis", "colour", "blue"), "user", "", Id,
                 Status);
      Assert (Status.Code = E.Framework_Schema_Violation,
              "a field no kind defines was carried");
      Tk.Create (Store, Change,
                 Fields ("x", "analysis", "depends_on", "TASK-NONE-001"), "user",
                 "", Id, Status);
      Assert (Status.Code = E.Framework_Not_Found,
              "a dependency on no task was taken");

      Tk.Create (Store, Change,
                 Fields ("Parse the input", "implementation", "component",
                         "parser"), "user", "", Id, Status);
      Assert (E.Is_Ok (Status) and then To_String (Id) = "TASK-PARSER-001",
              "a task was not created: " & Code_Of (Status));
      Tk.Create (Store, Change,
                 Fields ("Look at the input", "analysis", "estimate", "2h"),
                 "user", "", Other, Status);
      S.Commit (Store, Change, Status);
      Assert (Tk.State_Of (Store, To_String (Id)) = "candidate",
              "a new task is not a candidate");
      Assert (not Tk.Ready (Store, To_String (Id)).Ready,
              "a candidate is ready");

      Tk.Move (Store, Change, To_String (Id), "running", "", Status => Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a candidate was started");

      --  Waiting for another task.
      Tk.Add_Dependency (Store, Change, To_String (Id), To_String (Other),
                         Status);
      Assert (E.Is_Ok (Status), "a dependency was refused");
      S.Commit (Store, Change, Status);
      Tk.Add_Dependency (Store, Change, To_String (Other), To_String (Id),
                         Status);
      Assert (Status.Code = E.Framework_Dependency_Cycle,
              "a dependency cycle was made");

      Move (To_String (Id), "accepted");
      Assert (not Tk.Ready (Store, To_String (Id)).Ready,
              "a task waiting for another is ready");
      Tk.Move (Store, Change, To_String (Id), "running", "", Status => Status);
      Assert (Status.Code = E.Framework_Task_Not_Ready,
              "a task that is not ready was started");

      Move (To_String (Other), "accepted");
      Move (To_String (Other), "running");
      Move (To_String (Other), "verification");
      Tk.Move (Store, Change, To_String (Other), "complete", "",
               Status => Status);
      Assert (Status.Code = E.Framework_Task_Not_Ready,
              "a task whose gates did not pass was completed");
      Move (To_String (Other), "complete", Gates => True);
      Assert (Tk.Ready (Store, To_String (Id)).Ready,
              "a task whose dependency completed is not ready");

      --  Blocked, retried after a failure, then done.
      Move (To_String (Id), "running");
      Move (To_String (Id), "blocked");
      Move (To_String (Id), "accepted");
      Move (To_String (Id), "running");
      Move (To_String (Id), "failed");
      Move (To_String (Id), "accepted");
      Move (To_String (Id), "running");
      Move (To_String (Id), "verification");
      Move (To_String (Id), "complete", Gates => True);

      declare
         View : R.Item;
      begin
         Tk.Effective (Store, To_String (Id), View, Status);
         Assert (E.Is_Ok (Status)
                 and then R.Get (View, "runtime.state") = "complete"
                 and then R.Get (View, "runtime.generation") = "3"
                 and then R.Get (View, "verification_profile")
                          = "tests: run the tests"
                 and then R.Get (View, "fingerprint")'Length = 16,
                 "the effective task is not what the task is");
      end;

      --  Reopening needs its policy, and so does cancelling a done task.
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a complete task was reopened without the policy");
      Tk.Move (Store, Change, To_String (Id), "accepted", "",
               Granted => [others => True], Status => Status);
      Assert (E.Is_Ok (Status), "a complete task could not be reopened");
      S.Commit (Store, Change, Status);
      Move (To_String (Id), "cancelled");
      Assert (Natural (Tk.List (Store, "cancelled").Length) = 1
              and then Natural (Tk.List (Store).Length) = 2,
              "the tasks are not listed by state");
      S.Close (Store);
   end Tasks_Follow_Their_Lifecycle;

   --  A parent handed wholly to its children waits for them, and goes back
   --  to work, not to complete, when they are done.
   procedure Parents_Wait_For_Children
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Parent : Unbounded_String;
      Child  : Unbounded_String;
      Became : Model_Runner.Framework.Name_Lists.Vector;
   begin
      Task_Project (Store, "parents");
      Tk.Create (Store, Change, Fields ("The whole", "analysis"), "user", "",
                 Parent, Status);
      S.Commit (Store, Change, Status);
      Tk.Create (Store, Change,
                 Fields ("A part", "analysis", "parent", To_String (Parent)),
                 "user", "", Child, Status);
      S.Commit (Store, Change, Status);
      Assert (Tk.Children (Store, To_String (Parent)).First_Element
              = To_String (Child), "a child does not know its parent");

      Tk.Move (Store, Change, To_String (Parent), "accepted", "",
               Status => Status);
      Tk.Move (Store, Change, To_String (Child), "accepted", "",
               Status => Status);
      S.Commit (Store, Change, Status);
      Tk.Block_On_Children (Store, Change, To_String (Parent), Status);
      Assert (E.Is_Ok (Status), "a parent could not wait for its children");
      S.Commit (Store, Change, Status);
      Tk.Block_On_Children (Store, Change, To_String (Child), Status);
      Assert (Status.Code = E.Framework_Not_Found,
              "a task with no children waited for them");

      Tk.Recompute_Readiness (Store, Change, Became, Status);
      S.Commit (Store, Change, Status);
      Assert (Natural (Became.Length) = 1
              and then Became.First_Element = To_String (Child),
              "only the child should have become ready");

      Tk.Move (Store, Change, To_String (Child), "running", "",
               Status => Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Child), "verification", "",
               Status => Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Child), "complete", "",
               Gates_Passed => True, Status => Status);
      S.Commit (Store, Change, Status);

      Tk.Recompute_Readiness (Store, Change, Became, Status);
      Assert (E.Is_Ok (Status), "readiness was not worked out: "
              & Code_Of (Status));
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "readiness was not committed: "
              & Code_Of (Status));
      Assert (Tk.State_Of (Store, To_String (Parent)) = "accepted"
              and then Became.Contains (To_String (Parent)),
              "a parent whose children are done did not go back to work");

      Tk.Recompute_Readiness (Store, Change, Became, Status);
      Assert (Became.Is_Empty, "a task was announced ready twice");
      S.Close (Store);
   end Parents_Wait_For_Children;

   --  Tasks derived from accepted requirements are made once, however
   --  often derivation runs, and automatic acceptance is the policy's to
   --  give.
   procedure Derivation_Is_Idempotent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Req    : Unbounded_String;
      Made   : Model_Runner.Framework.Name_Lists.Vector;
      Effect : Nt.Impact;
   begin
      Task_Project (Store, "derivation");
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.",
                  "", "user", "", "io", Req, Status);
      S.Commit (Store, Change, Status);
      Tk.Derive (Store, Change, Made, Status);
      Assert (Made.Is_Empty, "a candidate requirement derived a task");

      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Tk.Derive (Store, Change, Made, Status);
      Assert (E.Is_Ok (Status) and then Natural (Made.Length) = 1,
              "an accepted requirement derived no task: " & Code_Of (Status));
      S.Commit (Store, Change, Status);
      declare
         Derived : constant String := Made.First_Element;
         Defined : R.Item;
      begin
         Assert (Tk.State_Of (Store, Derived) = "candidate",
                 "a derived task was accepted without the policy");
         Tk.Definition (Store, Derived, Defined, Status);
         Assert (R.Get (Defined, "created_by") = "requirement_derivation"
                 and then R.Get (Defined, "origin") = To_String (Req) & "@2"
                 and then R.Get (Defined, "component") = "io",
                 "a derived task does not say where it came from");
      end;

      Tk.Derive (Store, Change, Made, Status);
      Assert (Made.Is_Empty, "derivation run again made a task twice");

      --  A new meaning is new work; a new title is not.
      Nt.Revise (Store, Change, Nt.Requirement, To_String (Req), "Read it",
                 "It SHALL read.", "", Effect, Status);
      S.Commit (Store, Change, Status);
      Tk.Derive (Store, Change, Made, Status);
      Assert (Made.Is_Empty, "a reworded requirement derived new work");
      S.Close (Store);

      Change := S.No_Changes;
      Task_Project (Store, "derivation-automatic",
                    "scalar task.auto_accept = true" & LF);
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.",
                  "", "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      Assert (E.Is_Ok (Status), "a requirement proposed and accepted in one"
              & " change was refused: " & Code_Of (Status));
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a requirement proposed and accepted in one"
              & " change was not committed: " & Code_Of (Status));
      Tk.Derive (Store, Change, Made, Status);
      Assert (E.Is_Ok (Status) and then not Made.Is_Empty,
              "the automatic project derived nothing: " & Code_Of (Status));
      S.Commit (Store, Change, Status);
      Assert (Tk.State_Of (Store, Made.First_Element) = "accepted",
              "the policy's automatic acceptance was not applied");
      Assert (Tk.Cycles (Store).Is_Empty, "a cycle was found where none is");
      S.Close (Store);
   end Derivation_Is_Idempotent;

   ---------------------------------------------------------------------------
   --  The repository.
   ---------------------------------------------------------------------------

   package Rp renames Model_Runner.Framework.Repository;

   --  A scan finds the files and what the Ada in them declares, withs and
   --  uses, says how it knows each relation, and finds the same the second
   --  time; the graph kept in the state reads back whole.
   procedure Repository_Is_Scanned
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Rp.File_Role;
      use type Rp.Relation_Kind;
      use type Rp.Derivation;
      use type Rp.Confidence;

      Project : constant String := Fresh ("repository");
      Found   : Rp.Graph;
      Again   : Rp.Graph;
      Kept    : Rp.Graph;
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Here    : Boolean;
      Named   : Rp.Symbol;
   begin
      Dirs.Create_Path (Project & "/src");
      Dirs.Create_Path (Project & "/tests");
      Dirs.Create_Path (Project & "/obj");
      Dirs.Create_Path (Project & "/.git");
      Put_File (Project & "/src/parser.ads",
                "--  Next is only a comment here." & LF
                & "package Parser is" & LF
                & "   type Token is record" & LF
                & "      Kind : Natural := 0;" & LF
                & "   end record;" & LF
                & "   procedure Next (Item : out Token);" & LF
                & "   Limit : constant := 3;" & LF
                & "   Broken : exception;" & LF
                & "end Parser;" & LF);
      Put_File (Project & "/src/parser.adb",
                "package body Parser is" & LF
                & "   procedure Next (Item : out Token) is" & LF
                & "   begin" & LF
                & "      Item.Kind := Limit;" & LF
                & "   end Next;" & LF
                & "end Parser;" & LF);
      Put_File (Project & "/src/main.adb",
                "with Parser;" & LF
                & "procedure Main is" & LF
                & "   Item : Parser.Token;" & LF
                & "   Said : constant String := ""Next"";" & LF
                & "begin" & LF
                & "   Parser.Next (Item);" & LF
                & "end Main;" & LF);
      Put_File (Project & "/tests/parser_tests.adb",
                "with Parser;" & LF & "procedure Parser_Tests is" & LF
                & "begin" & LF & "   null;" & LF & "end Parser_Tests;" & LF);
      Put_File (Project & "/README.md", "# A parser" & LF);
      Put_File (Project & "/alire.toml", "name = ""parser""" & LF);
      Put_File (Project & "/obj/parser.o", "not source");
      Put_File (Project & "/.git/HEAD", "ref");

      Found := Rp.Scan (Project);
      Assert (Rp.File_Count (Found) = 6,
              "the scan did not leave out build output and hidden files:"
              & Natural'Image (Rp.File_Count (Found)));
      for Index in 1 .. Rp.File_Count (Found) loop
         declare
            File : constant Rp.File_Entry := Rp.File_At (Found, Index);
            Path : constant String := To_String (File.Path);
         begin
            if Path = "tests/parser_tests.adb" then
               Assert (File.Role = Rp.Test, "a test file is not one");
            elsif Path = "README.md" then
               Assert (File.Role = Rp.Documentation, "documentation is not");
            elsif Path = "src/parser.ads" then
               Assert (File.Role = Rp.Source
                       and then To_String (File.Language) = "Ada",
                       "a spec is not Ada source");
            end if;
         end;
      end loop;

      Assert (Rp.Find_Symbols (Found, "next").First_Element = "Parser.Next"
              and then Natural (Rp.Find_Symbols (Found, "Parser").Length) = 1,
              "a symbol was not found by its name");
      Named := Rp.Symbol_Of (Found, "Parser.Limit", Here);
      Assert (Here and then To_String (Named.Kind) = "constant"
              and then Named.Line = 7,
              "a constant was not declared where it is");
      Named := Rp.Symbol_Of (Found, "Parser.Broken", Here);
      Assert (Here and then To_String (Named.Kind) = "exception",
              "an exception was not found");
      Named := Rp.Symbol_Of (Found, "Parser.Kind", Here);
      Assert (not Here, "a record component was taken for a declaration");

      Assert (Rp.Dependencies_Of (Found, "Main").First_Element = "Parser",
              "a with clause was not a dependency");
      Assert (Natural (Rp.Dependents_Of (Found, "Parser").Length) = 2,
              "the units depending on a unit were not found");
      Assert (Rp.References_To (Found, "Parser.Next").Contains
                ("src/main.adb:6")
              and then not Rp.References_To (Found, "Parser.Next").Contains
                             ("src/main.adb:4"),
              "a reference was missed, or a string taken for one");

      declare
         Explicit_With : Boolean := False;
      begin
         for Index in 1 .. Rp.Relation_Count (Found) loop
            declare
               Link : constant Rp.Relation := Rp.Relation_At (Found, Index);
            begin
               if Link.Kind = Rp.Depends_On then
                  Explicit_With := Link.Source = Rp.Explicit
                    and then Link.Sure = Rp.Certain;
               elsif Link.Kind = Rp.References then
                  Assert (Link.Source = Rp.Heuristic,
                          "a name match claims more than a heuristic");
               end if;
            end;
         end loop;
         Assert (Explicit_With, "a with clause is not explicit and certain");
      end;

      Again := Rp.Scan (Project);
      Assert (Rp.Graph_Fingerprint (Again) = Rp.Graph_Fingerprint (Found)
              and then Rp.Relation_Count (Again) = Rp.Relation_Count (Found),
              "two scans of one tree differ");

      S.Create (Store, Project, "Repository", Status);
      Rp.Keep (Store, Change, Found, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "the graph was not kept: " & Code_Of (Status));
      Rp.Load (Store, Kept, Status);
      Assert (E.Is_Ok (Status)
              and then Rp.Graph_Fingerprint (Kept) = Rp.Graph_Fingerprint (Found)
              and then Rp.Relation_Count (Kept) = Rp.Relation_Count (Found)
              and then Rp.References_To (Kept, "Parser.Next")
                       = Rp.References_To (Found, "Parser.Next"),
              "the kept graph did not read back whole");

      Put_File (Project & "/src/extra.ads", "package Extra is" & LF
                & "end Extra;" & LF);
      Assert (Rp.Graph_Fingerprint (Rp.Scan (Project))
              /= Rp.Graph_Fingerprint (Found),
              "a new file did not change the graph's fingerprint");
      Assert (Rp.Language_Of ("x.rs") = "Rust"
              and then Rp.Role_Of ("Makefile") = Rp.Build
              and then Rp.Role_Of ("notes.txt") = Rp.Other
              and then Rp.Role_Of ("build.gpr") = Rp.Build,
              "languages or roles are not what the names say");
      S.Close (Store);

      --  What another language's adapter would write, by hand.
      declare
         Built : Rp.Graph;
      begin
         Rp.Add_File (Built, (Path => To_Unbounded_String ("lib.c"),
                              Language => To_Unbounded_String ("C"),
                              Role => Rp.Source,
                              Fingerprint => To_Unbounded_String ("0")));
         Rp.Add_Symbol (Built, (Name => To_Unbounded_String ("lib.open"),
                                Kind => To_Unbounded_String ("function"),
                                Path => To_Unbounded_String ("lib.c"),
                                Line => 3));
         Rp.Add_Relation
           (Built, (Kind => Rp.Depends_On, From => To_Unbounded_String ("app"),
                    To => To_Unbounded_String ("lib"), Source => Rp.Build_Metadata,
                    Sure => Rp.Probable, Where => Null_Unbounded_String));
         Assert (Rp.Find_Symbols (Built, "open").First_Element = "lib.open"
                 and then Rp.Dependents_Of (Built, "lib").First_Element = "app"
                 and then Rp.Relation_Count (Built) = 2,
                 "a graph built by an adapter is not queried as one");
      end;
   end Repository_Is_Scanned;

   ---------------------------------------------------------------------------
   -- Register_Tests --
   ---------------------------------------------------------------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Records_Round_Trip'Access,
         "a record reads back as written and its text is canonical");
      Register_Routine
        (T, Records_Refuse_What_Is_Not_One'Access,
         "text that is not a record is refused");
      Register_Routine
        (T, Schemas_Are_Enforced'Access,
         "schemas require, choose, keep unknown fields and refuse later"
         & " versions");
      Register_Routine
        (T, Identifiers_Are_Handed_Out'Access,
         "identifiers are checked and handed out in turn");
      Register_Routine
        (T, State_Survives_Restart'Access,
         "project state made in one session is there in the next");
      Register_Routine
        (T, Second_Session_Is_Refused'Access,
         "a second session is refused state another holds");
      Register_Routine
        (T, Committed_Change_Rolls_Forward'Access,
         "a committed change interrupted before it was applied is finished");
      Register_Routine
        (T, Uncommitted_Change_Rolls_Back'Access,
         "an uncommitted change and a half-made file are thrown away");
      Register_Routine
        (T, Bad_Changes_Write_Nothing'Access,
         "a change against an old revision or a schema writes nothing");
      Register_Routine
        (T, Index_Is_Rebuilt'Access,
         "the entity index is built again to the same thing");
      Register_Routine
        (T, Results_Are_Immutable'Access,
         "a result is stored once under its content and never changed");
      Register_Routine
        (T, Unreadable_State_Is_Refused'Access,
         "state that cannot be read or finished stops the open");
      Register_Routine
        (T, Areas_Are_Classified'Access,
         "each area says what kind of state it holds");
      Register_Routine
        (T, Templates_Compose'Access,
         "templates compose includes first and merge by kind");
      Register_Routine
        (T, Template_Conflicts_Are_Refused'Access,
         "templates that conflict, cycle or are malformed are refused");
      Register_Routine
        (T, Inputs_Are_Resolved'Access,
         "inputs are given, discovered or defaulted, and checked");
      Register_Routine
        (T, Configuration_Fingerprint_Is_Stable'Access,
         "one configuration has one fingerprint whatever its order or origin");
      Register_Routine
        (T, Initialized_Project_Outlives_Template'Access,
         "an initialized project reopens with its templates gone");
      Register_Routine
        (T, Events_Commit_With_Their_Change'Access,
         "an event is committed with its change and never without it");
      Register_Routine
        (T, Consumption_Is_Idempotent'Access,
         "an event delivered twice is acted on once");
      Register_Routine
        (T, Task_Transition_Matrix'Access,
         "the task lifecycle allows exactly the moves of its matrix");
      Register_Routine
        (T, Transitions_Are_Applied_Whole'Access,
         "a move writes its revision and event together, an illegal one"
         & " neither");
      Register_Routine
        (T, Leases_Run_Out'Access,
         "a lease is held by one owner until it runs out");
      Register_Routine
        (T, Consistency_Finds_What_Is_Wrong'Access,
         "the consistency check finds what does not hold together");
      Register_Routine
        (T, Requirement_Revisions_Invalidate'Access,
         "a requirement's new meaning undoes what no longer applies");
      Register_Routine
        (T, Decisions_Supersede_And_Apply'Access,
         "a decision replaced says by what, and applies where it should");
      Register_Routine
        (T, Authority_Is_Resolved'Access,
         "the highest statement governs and the others stand to it");
      Register_Routine
        (T, Authority_Conflicts_Are_Found'Access,
         "a conflict between decision and configuration is found");
      Register_Routine
        (T, Bootstrap_Is_Repeatable'Access,
         "bootstrap classifies a document and makes only what is new");
      Register_Routine
        (T, Tasks_Follow_Their_Lifecycle'Access,
         "a task is approved, blocked, retried, cancelled and completed only"
         & " by legal moves");
      Register_Routine
        (T, Parents_Wait_For_Children'Access,
         "a parent waits for its children and goes back to work after them");
      Register_Routine
        (T, Repository_Is_Scanned'Access,
         "a scan finds files, units, symbols and references, and says how");
      Register_Routine
        (T, Derivation_Is_Idempotent'Access,
         "a requirement derives its task once, however often derivation"
         & " runs");
   end Register_Tests;

end Tests.Framework_Cases;
