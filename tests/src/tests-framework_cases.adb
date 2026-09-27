with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Stores;

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

   function Code_Of (Status : E.Error_Info) return String
   is (E.Error_Code'Image (Status.Code));

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
      Assert (To_String (Id) = "REQ-PARSER-003",
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
   end Register_Tests;

end Tests.Framework_Cases;
