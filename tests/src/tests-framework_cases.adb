with Ada.Text_IO;
with Hostkit;
with Interfaces;
with Ada.Environment_Variables;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Model_Runner.CLI.Intents;
with Model_Runner.CLI.Options;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.CLI.Work;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Bootstrap;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Invocations;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Templates;
with Model_Runner.Framework.Traceability;
with Model_Runner.Framework.Transitions;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Work;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Localization;
with Hostkit.Host;
with Hostkit.Process;
with Model_Runner.Platform;
with Model_Runner.Presentation;
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

   --  An agent that does what it is told to do here: writes a file, and
   --  answers.
   type Scripted_Agent is new Model_Runner.Framework.Work.Agent_Runner with record
      File   : Unbounded_String;
      Answer : Unbounded_String;
      Broken : Boolean := False;
   end record;

   overriding procedure Run
     (Self        : Scripted_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

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

      --  One whose process is gone from this machine is stale at once,
      --  however long it had to run; one of a process still there holds.
      Assert (Hostkit.Process."=" (Hostkit.Process.Presence_Of (Hostkit.Host.Own_Process_Id),
                                   Hostkit.Process.Present),
              "this process is not there");
      declare
         Dead : R.Item :=
           R.Create (Model_Runner.Framework.Schemas.Lease_Schema, 1, "LEASE", 1);
      begin
         R.Set (Dead, "resource", "workspace-3");
         R.Set (Dead, "owner", "died");
         R.Set (Dead, "acquired_at", "2020-01-01T00:00:00Z");
         R.Set (Dead, "expires_at", "2999-01-01T00:00:00Z");
         R.Set (Dead, "process", "2000000000");
         R.Set (Dead, "host", Hostkit.Host.Node_Name);
         S.Put (Change, F.Runtime_Area, "lease.workspace-3", Dead);
         S.Commit (Store, Change, Status);
      end;
      Assert (Hostkit.Process."=" (Hostkit.Process.Presence_Of (2_000_000_000),
                                   Hostkit.Process.Absent)
              and then Ls.Holder (Store, "workspace-3") = "",
              "a lease whose process is gone still held");
      Ls.Acquire (Store, Change, "workspace-4", "agent-c", 600, Status);
      S.Commit (Store, Change, Status);
      Assert (Ls.Holder (Store, "workspace-4") = "agent-c",
              "a lease of a process still running did not hold");
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

   --  A task's definition, read.
   function Definition_Of (Store : S.Store; Id : String) return R.Item is
      Value  : R.Item;
      Status : E.Error_Info;
   begin
      Tk.Definition (Store, Id, Value, Status);
      return Value;
   end Definition_Of;

   --  The directory a store's project is in.
   function Fresh_Root (Store : S.Store) return String
   is (Dirs.Containing_Directory (S.Root (Store)));

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
   --  Context and invocations.
   ---------------------------------------------------------------------------

   package Cx renames Model_Runner.Framework.Context;
   package Iv renames Model_Runner.Framework.Invocations;

   --  A context holds what is mandatory whatever it costs, the rest by
   --  priority while it fits, the same text once, and is the same manifest
   --  when built again from the same state.
   procedure Contexts_Are_Budgeted
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Req     : Unbounded_String;
      Id      : Unbounded_String;
      One     : Cx.Built;
      Two     : Cx.Built;
      Profile : Cx.Model_Profile;
      Given   : Tk.Field_Map;
      Big     : constant String (1 .. 4000) := [others => 'x'];
   begin
      Task_Project
        (Store, "context",
         "map model.small = context=900, reserve=100, tools=yes, class=laptop"
         & LF & "map model.tiny = context=120, reserve=100" & LF);
      Dirs.Create_Path (Fresh_Root (Store) & "/src");
      Put_File (Fresh_Root (Store) & "/src/parser.adb", Big);
      Put_File (Fresh_Root (Store) & "/src/parser_copy.adb", Big);
      Nt.Propose (Store, Change, Nt.Requirement, "PARSER", "Read",
                  "It SHALL read.", "a test reads", "user", "", "parser", Req,
                  Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Given := Fields ("Parse", "implementation", "component", "parser");
      Given.Include ("requirements", To_String (Req));
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a task to build context for was not made");

      Profile := Cx.Profile (Store, "small");
      Assert (Profile.Context_Limit = 900 and then Profile.Output_Reserve = 100
              and then Profile.Tools and then To_String (Profile.Resource_Class)
                                              = "laptop",
              "a model profile was not read from the configuration");
      Assert (Cx.Profile (Store, "").Context_Limit = 8192,
              "the default profile is not the default");
      Assert (Cx.Estimate ("abcdefgh") = 2, "a text's cost is not estimated");

      Cx.Build (Store, To_String (Id), Profile, One, Status);
      Assert (E.Is_Ok (Status), "a context was not built: " & Code_Of (Status));
      Assert (Cx.Cost (One) <= 800 and then Cx.Excluded_Count (One) >= 2,
              "a context went over its budget, or left nothing out");
      declare
         Has_Requirement : Boolean := False;
      begin
         for Index in 1 .. Cx.Included_Count (One) loop
            Has_Requirement := Has_Requirement
              or else To_String (Cx.Included_At (One, Index).Id)
                      = To_String (Req) & "@1";
         end loop;
         Assert (Has_Requirement,
                 "the requirement served at its revision was left out");
      end;
      Assert (not Cx.Semantic (One), "a context without a graph claims one");

      Cx.Build (Store, To_String (Id), Cx.Profile (Store, ""), Two, Status);
      Assert (Cx.Excluded_Count (Two) = 1,
              "the same source twice was not given once: "
              & Natural'Image (Cx.Excluded_Count (Two)));
      Cx.Build (Store, To_String (Id), Profile, Two, Status);
      Assert (Cx.Manifest_Id (Two) = Cx.Manifest_Id (One)
              and then Cx.Rendered (Two) = Cx.Rendered (One),
              "one context built twice is two");

      --  A child's context: its rules, the task and what it is asked, and
      --  nothing of the task's own context.
      Cx.Build_Brief (Store, To_String (Id), Profile, "Help it.", "Look at a.adb", Two, Status);
      Assert (E.Is_Ok (Status)
              and then Ada.Strings.Fixed.Index (Cx.Rendered (Two), "What you are asked") > 0
              and then Ada.Strings.Fixed.Index (Cx.Rendered (Two), "Look at a.adb") > 0
              and then Cx.Manifest_Id (Two) /= Cx.Manifest_Id (One)
              and then Cx.Included_Count (Two) = 3,
              "a child's context was not built of its own: " & Code_Of (Status));

      Cx.Keep (Store, Change, One, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status)
              and then S.Exists (Store, F.Invocations_Area,
                                 "manifest." & Cx.Manifest_Id (One)),
              "a manifest was not kept: " & Code_Of (Status));
      Cx.Keep (Store, Change, One, Status);
      Assert (S.Change_Count (Change) = 0, "a manifest was kept twice");

      Cx.Build (Store, To_String (Id), Cx.Profile (Store, "tiny"), Two, Status);
      Assert (Status.Code = E.Framework_Context_Overflow,
              "a context whose mandatory part does not fit was built");
      Cx.Build (Store, "TASK-NONE-001", Profile, Two, Status);
      Assert (Status.Code = E.Framework_Not_Found,
              "a context was built for no task");
      S.Close (Store);
   end Contexts_Are_Budgeted;

   --  A call is recorded when it starts and ends once; an answer is held to
   --  its contract.
   procedure Invocations_Are_Recorded
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      First  : Unbounded_String;
      Second : Unbounded_String;
      Said   : Iv.Claims;
   begin
      Task_Project (Store, "invocations");
      Iv.Start (Store, Change, "AGENT-1", "TASK-1", "1", "default", "CTX-1",
                "none", Iv.Work_Claim, First, Status);
      Assert (E.Is_Ok (Status) and then To_String (First) = "INV-000001",
              "an invocation was not given its identifier");
      S.Commit (Store, Change, Status);
      Assert (Iv.State_Of (Store, To_String (First)) = "started",
              "a started call is not recorded as started");

      Iv.Finish (Store, Change, To_String (First), Iv.Failed,
                 (Prompt_Tokens => 10, Output_Tokens => 2, Seconds => 1), "",
                 "the model stopped", Status);
      S.Commit (Store, Change, Status);
      Assert (Iv.State_Of (Store, To_String (First)) = "failed",
              "a failed call is not recorded as failed");
      Iv.Finish (Store, Change, To_String (First), Iv.Completed, (others => 0),
                 "", "", Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "an ended call was ended again");

      --  The retry is a call of its own.
      Iv.Start (Store, Change, "AGENT-1", "TASK-1", "1", "default", "CTX-1",
                "none", Iv.Work_Claim, Second, Status);
      Assert (To_String (Second) = "INV-000002", "a retry did not get a new record");
      S.Close (Store);

      Iv.Hold (Iv.Work_Claim,
               "Here is what I did." & LF & "status: Done" & LF
               & "summary: added the reader" & LF & "and its test" & LF
               & "changed_files: src/reader.adb", Said, Status);
      Assert (E.Is_Ok (Status) and then Iv.Claim (Said, "status") = "done"
              and then Iv.Claim (Said, "summary")
                       = "added the reader" & LF & "and its test"
              and then Iv.Claim (Said, "issues") = "",
              "an answer keeping to its contract was not read: "
              & Code_Of (Status));
      Iv.Hold (Iv.Work_Claim, "status: finished" & LF & "summary: x", Said,
               Status);
      Assert (Status.Code = E.Framework_Contract_Violation,
              "a status that is none of the contract's words was taken");
      Iv.Hold (Iv.Work_Claim, "status: done", Said, Status);
      Assert (Status.Code = E.Framework_Contract_Violation,
              "an answer missing a required field was taken");
      Assert (Iv.Name_Of (Iv.Contract_Of ("mine", "answer")) = "mine",
              "a contract does not know its name");
   end Invocations_Are_Recorded;

   ---------------------------------------------------------------------------
   --  Verification.
   ---------------------------------------------------------------------------

   package Ex renames Model_Runner.Framework.Execution;
   package Vf renames Model_Runner.Framework.Verification;

   --  Only what the policy allows is run, directly, and what it said is
   --  kept.
   procedure Execution_Follows_Policy
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Rules  : Ex.Policy;
      Ran    : Ex.Outcome;
   begin
      Task_Project (Store, "execution",
                    "set execution.allowed = echo" & LF
                    & "scalar execution.timeout = 20" & LF);
      Rules := Ex.Policy_Of (Store);
      Assert (Rules.Allowed.Contains ("echo") and then not Rules.Shell_Allowed
              and then Rules.Timeout = 20,
              "the execution policy was not read from the configuration");
      Assert (Ex.Needs_Shell ("a && b") and then not Ex.Needs_Shell ("alr build"),
              "a shell's operators are not told from a plain command");
      Assert (Natural (Ex.Words_Of ("echo 'two words' three").Length) = 3,
              "quoted words were not kept whole");

      Ex.Run (Store, Change, Rules, "rm -rf src", "", Ran, Status);
      Assert (Status.Code = E.Framework_Execution_Refused,
              "a program the policy does not name was run");
      Ex.Run (Store, Change, Rules, "echo a && echo b", "", Ran, Status);
      Assert (Status.Code = E.Framework_Execution_Refused,
              "a shell was used when the policy allows none");
      Ex.Run (Store, Change, Rules, "echo x", "../elsewhere", Ran, Status);
      Assert (Status.Code = E.Framework_Execution_Refused,
              "a command was run outside the project");

      Ex.Run (Store, Change, Rules, "echo hello there", "", Ran, Status);
      Assert (E.Is_Ok (Status) and then Ran.Started and then Ran.Exit_Status = 0
              and then Ada.Strings.Fixed.Index (To_String (Ran.Output), "hello there") > 0
              and then Length (Ran.Raw_Log) > 0,
              "an allowed command did not run, or its output was lost: "
              & Code_Of (Status) & Integer'Image (Ran.Exit_Status));
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "the raw output was not kept");
      S.Close (Store);
   end Execution_Follows_Policy;

   --  Diagnostics are read out of tools' output, and a profile's checks out
   --  of its line.
   procedure Diagnostics_Are_Normalized
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Said : constant Vf.Diagnostic_List :=
        Vf.Normalize
          ("gprbuild",
           "Compile" & LF
           & "   [Ada]          parser.adb" & LF
           & "parser.adb:12:7: warning: variable ""X"" is not referenced" & LF
           & "parser.adb:40:1: (style) multiple blank lines" & LF
           & "src/io.ads:3:10: missing "";""" & LF
           & "error: compilation failed" & LF);
      Checks : constant Vf.Check_List :=
        Vf.Parse_Profile ("build: alr build; unit in tests: alr build; lint?: gnatcheck");
   begin
      Assert (Vf.Length (Said) = 4, "the diagnostics in some output were not all read:"
              & Natural'Image (Vf.Length (Said)));
      declare
         First : constant Vf.Diagnostic := Vf.Element (Said, 1);
         Third : constant Vf.Diagnostic := Vf.Element (Said, 3);
      begin
         Assert (To_String (First.File) = "parser.adb" and then First.Line = 12
                 and then First.Column = 7
                 and then To_String (First.Severity) = "warning"
                 and then To_String (First.Tool) = "gprbuild",
                 "a warning was not read as one");
         Assert (To_String (Vf.Element (Said, 2).Severity) = "warning",
                 "a style message is not a warning");
         Assert (To_String (Third.Severity) = "error" and then Third.Column = 10,
                 "an error was not read as one");
      end;

      Assert (Vf.Length (Checks) = 3
              and then To_String (Vf.Element (Checks, 2).Directory) = "tests"
              and then To_String (Vf.Element (Checks, 2).Label) = "unit"
              and then not Vf.Element (Checks, 3).Required
              and then To_String (Vf.Element (Checks, 3).Label) = "lint",
              "a profile's checks were not read");
   end Diagnostics_Are_Normalized;

   --  A task completes only through its gates; a requirement becomes
   --  verified from current evidence and stops being so when the evidence
   --  stops applying.
   procedure Completion_Needs_Current_Evidence
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store    : S.Store;
      Status   : E.Error_Info;
      Change   : S.Transaction;
      Req      : Unbounded_String;
      Id       : Unbounded_String;
      Given    : Tk.Field_Map;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Changed  : Model_Runner.Framework.Name_Lists.Vector;
      Held     : Nt.Entity;
      Reasons  : Model_Runner.Framework.Name_Lists.Vector;

      procedure Move (Next : String) is
      begin
         Tk.Move (Store, Change, To_String (Id), Next, "", Status => Status);
         S.Commit (Store, Change, Status);
      end Move;

      function Gate_Passes (Name : String) return Boolean is
         Judged : constant Vf.Gate_List := Vf.Gates (Store, To_String (Id));
      begin
         for Index in 1 .. Vf.Length (Judged) loop
            if To_String (Vf.Element (Judged, Index).Name) = Name then
               return Vf.Element (Judged, Index).Passed;
            end if;
         end loop;
         return False;
      end Gate_Passes;
   begin
      Task_Project
        (Store, "completion",
         "set execution.allowed = echo" & LF
         & "set execution.allowed = false" & LF
         & "profile checks = say: echo src/a.adb:1:1: warning: fine" & LF
         & "profile broken = fail: false" & LF);
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Given := Fields ("Read", "implementation", "component", "io");
      Given.Include ("requirements", To_String (Req));
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Move ("accepted");
      Move ("running");
      Move ("verification");

      Assert (Vf.Profile_Of (Store, To_String (Id)) = "tests",
              "the task's kind did not choose its profile");
      Assert (not Gate_Passes ("verification"),
              "a task never verified passed its verification gate");
      Vf.Complete_Task (Store, Change, To_String (Id), Status);
      Assert (Status.Code = E.Framework_Task_Not_Ready,
              "a task completed without passing its gates");

      Vf.Run_Profile (Store, Change, "nonsense", To_String (Id), Evidence, Passed,
                      Status);
      Assert (Status.Code = E.Framework_Not_Found, "a profile nobody defined was run");
      Vf.Run_Profile (Store, Change, "broken", To_String (Id), Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then not Passed, "a failing check passed");

      Vf.Run_Profile (Store, Change, "checks", To_String (Id), Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Passed
              and then Vf.Length (Vf.Diagnostics_Of (Store, To_String (Evidence))) = 1,
              "a passing profile's evidence was not kept with its diagnostics: "
              & Code_Of (Status));
      Assert (Vf.Is_Current (Store, To_String (Evidence), Reasons),
              "fresh evidence is not current");
      Assert (Vf.Latest (Store, To_String (Id), "checks") = To_String (Evidence),
              "the latest evidence was not found");
      S.Close (Store);

      --  The task's own profile, pointed at the passing checks.
      Task_Project
        (Store, "completion-gates",
         "set execution.allowed = echo" & LF
         & "profile passing = say: echo all good" & LF
         & "scalar verification.default = passing" & LF);
      Change := S.No_Changes;
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Given := Fields ("Look", "analysis");
      Given.Include ("requirements", To_String (Req));
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Move ("accepted");
      Move ("running");
      Move ("verification");
      Vf.Run_Profile (Store, Change, "passing", To_String (Id), Evidence, Passed,
                      Status);
      S.Commit (Store, Change, Status);
      Assert (Gate_Passes ("verification") and then Gate_Passes ("children")
              and then Gate_Passes ("no_blocking_issue"),
              "a verified task did not pass its gates");

      Vf.Complete_Task (Store, Change, To_String (Id), Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Id)) = "complete",
              "a task passing its gates did not complete: " & Code_Of (Status));
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (To_String (Held.State) = "implemented",
              "completing a task verified its requirement by itself");

      Vf.Reevaluate_Requirements (Store, Change, Changed, Status);
      S.Commit (Store, Change, Status);
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (To_String (Held.State) = "verified" and then Natural (Changed.Length) = 1,
              "a requirement with current evidence was not verified");

      --  A file changes: the evidence no longer applies.
      Put_File (Fresh_Root (Store) & "/changed.txt", "new");
      Assert (not Vf.Is_Current (Store, To_String (Evidence), Reasons)
              and then not Reasons.Is_Empty,
              "evidence still applies after the files changed");
      declare
         Findings : constant Cn.Finding_List := Cn.Check (Store);
         Stale    : Boolean := False;
         use type Cn.Finding_Kind;
      begin
         for Index in 1 .. Cn.Length (Findings) loop
            Stale := Stale or else Cn.Element (Findings, Index).Kind = Cn.Stale_Verification;
         end loop;
         Assert (Stale, "a verification that no longer applies was not found");
      end;
      Vf.Reevaluate_Requirements (Store, Change, Changed, Status);
      S.Commit (Store, Change, Status);
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (To_String (Held.State) = "implemented",
              "a requirement stayed verified on evidence that no longer applies");
      S.Close (Store);
   end Completion_Needs_Current_Evidence;

   ---------------------------------------------------------------------------
   --  Work.
   ---------------------------------------------------------------------------

   package Wk renames Model_Runner.Framework.Work;

   overriding procedure Run
     (Self        : Scripted_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
   begin
      Answer := Self.Answer;
      Status := E.Success;
      if Self.Broken then
         Status := E.Make (E.Generation_Invalid_Request);
         return;
      end if;
      Assert (Dirs.Exists (Prompt_Path), "the agent was not given its context");
      if Self.File /= Null_Unbounded_String then
         Dirs.Create_Path (Project & "/src");
         Put_File (Project & "/" & To_String (Self.File), "procedure Hello is begin null; end;");
      end if;
   end Run;

   --  One task runs from ready to complete, its context, call, changes and
   --  evidence recorded; an answer outside the contract, a blocked one and
   --  a broken agent each end it as they should; a task whose agent
   --  stopped is put back; a running task can be cancelled.
   procedure Work_Runs_A_Task_Through
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Done   : Wk.Report;
      Ids    : array (1 .. 5) of Unbounded_String;
      Back   : Model_Runner.Framework.Name_Lists.Vector;
      Model  : Cx.Model_Profile;
      Good   : constant String :=
        "status: done" & LF & "summary: wrote hello" & LF & "changed_files: src/hello.adb";
   begin
      Task_Project
        (Store, "work",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF);
      Model := Cx.Profile (Store, "");
      for Index in Ids'Range loop
         Tk.Create (Store, Change, Fields ("Work" & Integer'Image (Index), "analysis"),
                    "user", "", Ids (Index), Status);
      end loop;
      S.Commit (Store, Change, Status);
      Wk.Execute (Store, To_String (Ids (1)),
                  Scripted_Agent'(File => Null_Unbounded_String,
                                  Answer => To_Unbounded_String (Good), Broken => False),
                  Model, Done, Status);
      Assert (Status.Code = E.Framework_Task_Not_Ready, "a candidate was worked on");
      for Index in Ids'Range loop
         Tk.Move (Store, Change, To_String (Ids (Index)), "accepted", "", Status => Status);
      end loop;
      S.Commit (Store, Change, Status);

      Wk.Execute (Store, To_String (Ids (1)),
                  Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                  Answer => To_Unbounded_String (Good), Broken => False),
                  Model, Done, Status);
      Assert (E.Is_Ok (Status) and then To_String (Done.Final_State) = "complete",
              "a task done and verified did not complete: " & Code_Of (Status) & " "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      Assert (Done.Changed_Files.Contains ("src/hello.adb")
              and then Length (Done.Evidence_Id) > 0 and then Length (Done.Manifest_Id) > 0
              and then Iv.State_Of (Store, To_String (Done.Invocation_Id)) = "completed",
              "what the work did was not all recorded");
      Assert (Tk.Ready (Store, To_String (Ids (1))).Reasons.First_Element = "it is complete",
              "the task's lease was not let go");

      --  Done, it says; but the check fails once the file is gone.
      Dirs.Delete_File (Fresh_Root (Store) & "/src/hello.adb");
      Wk.Execute (Store, To_String (Ids (2)),
                  Scripted_Agent'(File => Null_Unbounded_String,
                                  Answer => To_Unbounded_String (Good), Broken => False),
                  Model, Done, Status);
      Assert (To_String (Done.Final_State) = "failed" and then Done.Changed_Files.Is_Empty,
              "an agent's claim was taken over the failing check, or a change"
              & " it did not make was put on it: " & To_String (Done.Final_State));

      Wk.Execute (Store, To_String (Ids (3)),
                  Scripted_Agent'(File => Null_Unbounded_String,
                                  Answer => To_Unbounded_String ("I did it!"), Broken => False),
                  Model, Done, Status);
      Assert (To_String (Done.Final_State) = "failed",
              "an answer outside the contract was taken");

      Wk.Execute (Store, To_String (Ids (4)),
                  Scripted_Agent'(File => Null_Unbounded_String,
                                  Answer => To_Unbounded_String
                                    ("status: blocked" & LF & "summary: needs a decision"),
                                  Broken => False),
                  Model, Done, Status);
      Assert (To_String (Done.Final_State) = "blocked"
              and then To_String (Done.Reason) = "needs a decision",
              "a blocked answer did not block the task");

      Wk.Execute (Store, To_String (Ids (5)),
                  Scripted_Agent'(File => Null_Unbounded_String,
                                  Answer => Null_Unbounded_String, Broken => True),
                  Model, Done, Status);
      Assert (To_String (Done.Final_State) = "failed",
              "a broken agent did not fail its task");

      --  A running task whose agent's lease ran out goes back.
      Tk.Move (Store, Change, To_String (Ids (5)), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Ids (5)), "running", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Recover (Store, Back, Status);
      Assert (E.Is_Ok (Status) and then Back.Contains (To_String (Ids (5)))
              and then Tk.State_Of (Store, To_String (Ids (5))) = "blocked",
              "a running task with no agent was left running: " & Code_Of (Status));

      Tk.Move (Store, Change, To_String (Ids (5)), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Ids (5)), "running", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Cancel (Store, To_String (Ids (5)), Status);
      Assert (E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Ids (5))) = "cancelled",
              "a running task was not cancelled");
      Assert (Ada.Strings.Fixed.Index (Wk.Instructions, "status:") > 0,
              "the agent is not told how to answer");
      S.Close (Store);
   end Work_Runs_A_Task_Through;

   --  The command a session's /work runs takes the agent it is handed --
   --  the session's own model there, a scripted one here -- and carries the
   --  task through as the command line's work does.
   procedure Work_Runs_With_A_Given_Agent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Id      : Unbounded_String;
      Root    : Unbounded_String;
      Catalog : aliased Model_Runner.Localization.Catalog;
      Screen  : Model_Runner.Presentation.Console;
      Options : Model_Runner.CLI.Options.Command;
      Exit_Status : Natural;
      Report  : S.Recovery_Report;
   begin
      Task_Project
        (Store, "work-given",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF);
      Tk.Create (Store, Change, Fields ("Given", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Root := To_Unbounded_String (Fresh_Root (Store));
      S.Close (Store);

      Model_Runner.Localization.Open
        (Catalog, Model_Runner.Platform.Catalog_Path, "en");
      Model_Runner.Presentation.Open
        (Screen, Catalog'Unchecked_Access, Model_Runner.CLI.Options.Color_Never,
         (Output_Is_Terminal => False, Error_Is_Terminal => False,
          Input_Is_Terminal  => False, Colour_Suppressed => True),
         Model_Runner.CLI.Options.Quiet);
      Options.Project_Directory := Model_Runner.Text.To_Bounded (To_String (Root));
      Options.Action_Argument := Model_Runner.Text.To_Bounded (To_String (Id));
      Model_Runner.CLI.Work.Run_With
        (Options, Screen,
         Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                         Answer => To_Unbounded_String
                           ("status: done" & LF & "summary: wrote hello" & LF
                            & "changed_files: src/hello.adb"),
                         Broken => False),
         Exit_Status);

      S.Open (Store, To_String (Root), Report, Status);
      Assert (Exit_Status = 0 and then Tk.State_Of (Store, To_String (Id)) = "complete",
              "the given agent's work did not complete the task:"
              & Natural'Image (Exit_Status) & " " & Tk.State_Of (Store, To_String (Id)));
      S.Close (Store);
   end Work_Runs_With_A_Given_Agent;

   package Ws renames Model_Runner.Framework.Workspaces;

   --  Work written in a workspace stays out of the project until it is
   --  taken in; taking it in needs the right and refuses a conflict; and
   --  what is verified afterwards is the project as integrated.
   procedure Workspaces_Isolate_And_Integrate
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Id     : Unbounded_String;
      Other  : Unbounded_String;
      Done   : Wk.Report;
      Made   : Ws.Workspace;
      Taken  : Model_Runner.Framework.Name_Lists.Vector;
      Good   : constant String := "status: done" & LF & "summary: wrote hello";
      use type Ws.Backend;
   begin
      Task_Project
        (Store, "workspaces",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF
         & "scalar work.isolation = workspace" & LF
         & "scalar work.backend = copy" & LF);
      Dirs.Create_Path (Fresh_Root (Store) & "/src");
      Put_File (Fresh_Root (Store) & "/src/shared.adb", "one");
      Tk.Create (Store, Change, Fields ("Hello", "analysis"), "user", "", Id, Status);
      Tk.Create (Store, Change, Fields ("Other", "analysis"), "user", "", Other, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Other), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);

      Wk.Execute (Store, To_String (Id),
                  Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                  Answer => To_Unbounded_String (Good), Broken => False),
                  Cx.Profile (Store, ""), Done, Status);
      Assert (E.Is_Ok (Status) and then To_String (Done.Final_State) = "verification"
              and then Length (Done.Workspace_Id) > 0,
              "isolated work did not wait to be taken in: " & Code_Of (Status) & " "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      Assert (not Dirs.Exists (Fresh_Root (Store) & "/src/hello.adb"),
              "work written in a workspace reached the project before integration");
      Assert (Ws.Changes (Store, To_String (Done.Workspace_Id)).Contains ("src/hello.adb")
              and then Ws.Active_For (Store, To_String (Id)) = To_String (Done.Workspace_Id),
              "the workspace's change was not seen");
      declare
         Judged : constant Vf.Gate_List := Vf.Gates (Store, To_String (Id));
         Blocked_By_Integration : Boolean := False;
      begin
         for Index in 1 .. Vf.Length (Judged) loop
            Blocked_By_Integration := Blocked_By_Integration
              or else (To_String (Vf.Element (Judged, Index).Name) = "integration"
                       and then not Vf.Element (Judged, Index).Passed);
         end loop;
         Assert (Blocked_By_Integration,
                 "a task with work not taken in passed its integration gate");
      end;

      Ws.Integrate (Store, Change, To_String (Done.Workspace_Id), False, Taken, Status);
      Assert (Status.Code = E.Framework_Integration_Refused,
              "work was taken in without the right to integrate");

      Wk.Take_In (Store, To_String (Id), Done, Status);
      Assert (E.Is_Ok (Status) and then To_String (Done.Final_State) = "complete"
              and then Dirs.Exists (Fresh_Root (Store) & "/src/hello.adb"),
              "taken in and verified on the project, the task did not complete: "
              & Code_Of (Status) & " " & To_String (Done.Reason));

      --  A second workspace, changed where the project changes too.
      Ws.Create (Store, Change, To_String (Other), "AG-TEST", "1", False, Made, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Made.Kind = Ws.File_Copy,
              "a copy workspace was not made");
      Put_File (To_String (Made.Path) & "/src/shared.adb", "two");
      Put_File (Fresh_Root (Store) & "/src/shared.adb", "three");
      Assert (Ws.Conflicts (Store, To_String (Made.Id)).Contains ("src/shared.adb"),
              "a file changed on both sides was not a conflict");
      declare
         Findings : constant Cn.Finding_List := Cn.Check (Store);
         Misplaced : Boolean := False;
         use type Cn.Finding_Kind;
      begin
         for Index in 1 .. Cn.Length (Findings) loop
            Misplaced := Misplaced
              or else Cn.Element (Findings, Index).Kind = Cn.Workspace_Assignment;
         end loop;
         Assert (Misplaced, "a workspace for a task nobody works on was not found");
      end;
      Ws.Integrate (Store, Change, To_String (Made.Id), True, Taken, Status);
      Assert (Status.Code = E.Framework_Integration_Conflict,
              "a conflicting workspace was taken in");
      declare
         Held : Ws.Workspace;
      begin
         Ws.Abandon (Store, Change, To_String (Made.Id), Status);
         S.Commit (Store, Change, Status);
         Ws.Read (Store, To_String (Made.Id), Held, Status);
         Assert (To_String (Held.Status) = "abandoned"
                 and then not Dirs.Exists (To_String (Made.Path)),
                 "an abandoned workspace was not removed");
      end;
      S.Close (Store);
   end Workspaces_Isolate_And_Integrate;

   ---------------------------------------------------------------------------
   --  Traceability and impact.
   ---------------------------------------------------------------------------

   package Tc renames Model_Runner.Framework.Traceability;

   --  A change is followed through the graph to what it reaches, each with
   --  the weakest confidence on the way, and the tests chosen widen as the
   --  confidence falls.
   procedure Impact_Is_Traced (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Rp.Confidence;
      use type Tc.Scope;
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Req     : Unbounded_String;
      Id      : Unbounded_String;
      Given   : Tk.Field_Map;
      Graph   : Tc.Graph;
      Changed : Model_Runner.Framework.Name_Lists.Vector;
      Reach   : Tc.Impact;
      Chosen  : Tc.Selection;

      function Reached (Id_Text : String; Sure : out Rp.Confidence) return Boolean is
      begin
         for Index in 1 .. Tc.Length (Reach) loop
            if To_String (Tc.Element (Reach, Index).Id) = Id_Text then
               Sure := Tc.Element (Reach, Index).Sure;
               return True;
            end if;
         end loop;
         Sure := Rp.Uncertain;
         return False;
      end Reached;

      --  Whether a node is reached, however surely.
      function Has (Id_Text : String) return Boolean is
         Ignored : Rp.Confidence;
      begin
         return Reached (Id_Text, Ignored);
      end Has;

      Sure : Rp.Confidence;
   begin
      Task_Project (Store, "impact");
      Dirs.Create_Path (Fresh_Root (Store) & "/src");
      Dirs.Create_Path (Fresh_Root (Store) & "/tests");
      Put_File (Fresh_Root (Store) & "/src/parser.ads",
                "package Parser is" & LF & "   procedure Next;" & LF & "end Parser;" & LF);
      Put_File (Fresh_Root (Store) & "/src/parser.adb",
                "package body Parser is" & LF & "   procedure Next is null;" & LF
                & "end Parser;" & LF);
      Put_File (Fresh_Root (Store) & "/src/main.adb",
                "with Parser;" & LF & "procedure Main is" & LF & "begin" & LF
                & "   Parser.Next;" & LF & "end Main;" & LF);
      Put_File (Fresh_Root (Store) & "/tests/parser_tests.adb",
                "with Parser;" & LF & "procedure Parser_Tests is" & LF & "begin" & LF
                & "   null;" & LF & "end Parser_Tests;" & LF);
      Put_File (Fresh_Root (Store) & "/NOTES.txt", "notes");

      Nt.Propose (Store, Change, Nt.Requirement, "PARSER", "Next", "It SHALL advance.",
                  "", "user", "", "parser", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Given := Fields ("Next", "implementation", "component", "parser");
      Given.Include ("requirements", To_String (Req));
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);

      Graph := Tc.Build (Store, Rp.Scan (Fresh_Root (Store)));
      Assert (Tc.Edge_Count (Graph) > 0
              and then not Tc.Touching (Graph, To_String (Req) & "@1").Is_Empty,
              "the traceability graph does not reach the requirement");
      declare
         One : constant Tc.Edge :=
           Tc.Edge_At (Graph, Natural'Value
                         (Tc.Touching (Graph, To_String (Req) & "@1").First_Element));
         use type Rp.Derivation;
      begin
         Assert (One.Source = Rp.Explicit and then Length (One.Record_Of) > 0,
                 "a recorded edge does not say it was recorded, or where");
      end;

      Changed.Append ("src/parser.ads");
      Reach := Tc.Impact_Of (Graph, Changed);
      Assert (Reached ("unit:Parser", Sure) and then Sure = Rp.Certain,
              "the changed unit was not reached");
      Assert (Has ("symbol:Parser.Next"),
              "a changed symbol was not reached");
      Assert (Has ("unit:Main"), "a dependent was not reached");
      Assert (Has ("file:src/parser.adb"), "the unit's body was not reached");
      Assert (Reached ("file:tests/parser_tests.adb", Sure) and then Sure = Rp.Certain,
              "the test depending on the unit was not certainly reached");
      Assert (Reached ("component:parser", Sure) and then Sure = Rp.Probable,
              "a component reached by name did not stay probable");
      Assert (Has (To_String (Id)), "the task was not reached");
      Assert (Has (To_String (Req) & "@1"), "the requirement was not reached");

      Chosen := Tc.Select_Tests (Store, Reach);
      Assert (Chosen.Tests.Contains ("tests/parser_tests.adb"),
              "the affected test was not chosen");

      Changed.Clear;
      Changed.Append ("NOTES.txt");
      Chosen := Tc.Select_Tests (Store, Tc.Impact_Of (Graph, Changed));
      Assert (Chosen.Width = Tc.Full_Suite,
              "a change nobody knows the reach of was not tested in full");
      S.Close (Store);

      Task_Project (Store, "impact-narrow", "scalar verification.escalation = narrow" & LF);
      Chosen := Tc.Select_Tests (Store, Tc.Impact_Of (Graph, Changed));
      Assert (Chosen.Width = Tc.Certain_Tests,
              "a narrow policy still widened the tests");
      S.Close (Store);
   end Impact_Is_Traced;

   ---------------------------------------------------------------------------
   --  Permissions and recursive agents.
   ---------------------------------------------------------------------------

   package Pm renames Model_Runner.Framework.Permissions;
   package Ag renames Model_Runner.Framework.Agents;
   package Rs renames Model_Runner.Framework.Results;

   --  Permissions are capabilities with scope; levels only take away, and
   --  nothing is granted that nothing grants.
   procedure Permissions_Only_Narrow
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : S.Store;
      Present : Boolean;
      Project : Pm.Permission_Set;
      Kind    : Pm.Permission_Set;
      Both    : Pm.Permission_Set;
   begin
      Task_Project (Store, "permissions-default");
      Project := Pm.Effective (Store, "", "");
      Assert (Pm.Allows (Project, Pm.Write_Source, "src/a.adb")
              and then not Pm.Allows (Project, Pm.Use_Network)
              and then Project (Pm.Create_Children).Max_Depth = 1
              and then Project (Pm.Create_Children).Max_Children = 2,
              "a project that says nothing was not given the least work needs");
      S.Close (Store);

      Task_Project
        (Store, "permissions",
         "map permission.project.write_source = roots=src/|tests/, deny=src/security/" & LF
         & "map permission.project.run_tests = profiles=quick|full" & LF
         & "map permission.project.create_children = max_depth=2, max_children=2" & LF
         & "map permission.kind.analysis.write_source = roots=src/parser/|lib/" & LF
         & "map permission.kind.analysis.use_network =" & LF);
      Project := Pm.Level_Of (Store, "project", Present);
      Assert (Present and then Pm.Allows (Project, Pm.Write_Source, "src/x.adb")
              and then not Pm.Allows (Project, Pm.Write_Source, "src/security/key.adb")
              and then not Pm.Allows (Project, Pm.Write_Source, "docs/x.md"),
              "roots and denied paths were not read");
      Kind := Pm.Level_Of (Store, "kind.analysis", Present);
      Both := Pm.Effective (Store, "analysis", "");
      Assert (Pm.Allows (Both, Pm.Write_Source, "src/parser/a.adb")
              and then not Pm.Allows (Both, Pm.Write_Source, "lib/b.adb")
              and then not Pm.Allows (Both, Pm.Write_Source, "src/other.adb"),
              "a kind's roots did not narrow the project's");
      Assert (not Pm.Allows (Both, Pm.Use_Network),
              "a kind granted what the project does not");
      Assert (Pm.Widening (Kind, Project) = "write_source"
                or else Pm.Widening (Kind, Project) = "use_network",
              "a kind reaching past the project was not seen as widening");
      Assert (Pm.Widening (Both, Project) = "",
              "an intersection was taken for a widening");
      declare
         Back : constant Pm.Permission_Set := Pm.Value (Pm.Image (Both));
      begin
         Assert (Pm.Image (Back) = Pm.Image (Both) and then Pm.Word (Pm.Run_Tests) = "run_tests",
                 "a permission set did not read back as written");
      end;
      Assert (Pm.Intersect (Pm.Unrestricted, Pm.Nothing) (Pm.Read_Source).Granted = False,
              "the intersection with nothing granted something");

      declare
         Findings : constant Cn.Finding_List := Cn.Check (Store);
         Widening : Boolean := False;
         use type Cn.Finding_Kind;
      begin
         for Index in 1 .. Cn.Length (Findings) loop
            Widening := Widening
              or else Cn.Element (Findings, Index).Kind = Cn.Permission_Widening;
         end loop;
         Assert (Widening, "configuration that tries to widen was not found");
      end;
      S.Close (Store);
   end Permissions_Only_Narrow;

   --  Children are made within limits and given no more than their parent;
   --  a required child's failure is its parent's to see; cancelling goes
   --  down the tree; and a parent reads its children's results, not their
   --  transcripts.
   procedure Recursion_Stays_Bounded
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store     : S.Store;
      Status    : E.Error_Info;
      Change    : S.Transaction;
      Root      : Unbounded_String;
      First     : Unbounded_String;
      Second    : Unbounded_String;
      Third     : Unbounded_String;
      Grand     : Unbounded_String;
      Held      : Ag.Agent;
      Reason    : Unbounded_String;
      Cancelled : Model_Runner.Framework.Name_Lists.Vector;
      Transcript : Rs.Result;
   begin
      Task_Project
        (Store, "recursion",
         "map permission.project.read_source =" & LF
         & "map permission.project.write_source = roots=src/" & LF
         & "map permission.project.create_children = max_depth=2, max_children=2" & LF
         & "scalar agents.max_active = 4" & LF
         & "scalar agents.token_budget = 1000" & LF);
      Ag.Start_Root (Store, Change, "TASK-001", "planner", "", Root, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a root agent was not made: " & Code_Of (Status));

      Ag.Spawn_Child (Store, Change, To_String (Root), "coder", Ag.Required,
                      Pm.Unrestricted, 300, First, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a child was not made: " & Code_Of (Status));
      Ag.Read (Store, To_String (First), Held, Status);
      Assert (Held.Depth = 1 and then To_String (Held.Parent) = To_String (Root)
              and then not Pm.Allows (Held.Allowed, Pm.Use_Network)
              and then not Pm.Allows (Held.Allowed, Pm.Write_Source, "docs/x.md")
              and then Pm.Allows (Held.Allowed, Pm.Write_Source, "src/x.adb"),
              "a child asking for everything was given more than its parent");

      Ag.Spawn_Child (Store, Change, To_String (Root), "reviewer", Ag.Optional,
                      Pm.Unrestricted, 900, Second, Status);
      Assert (Status.Code = E.Framework_Limit_Exceeded,
              "a child was given more budget than its parent had left");
      Ag.Spawn_Child (Store, Change, To_String (Root), "reviewer", Ag.Optional,
                      Pm.Unrestricted, 100, Second, Status);
      S.Commit (Store, Change, Status);
      Ag.Spawn_Child (Store, Change, To_String (Root), "extra", Ag.Advisory,
                      Pm.Unrestricted, 10, Third, Status);
      Assert (Status.Code = E.Framework_Limit_Exceeded,
              "a parent made more children than it may");

      Ag.Spawn_Child (Store, Change, To_String (First), "helper", Ag.Required,
                      Pm.Unrestricted, 50, Grand, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a grandchild within depth was refused");
      Ag.Spawn_Child (Store, Change, To_String (Grand), "deeper", Ag.Required,
                      Pm.Unrestricted, 10, Third, Status);
      Assert (Status.Code = E.Framework_Limit_Exceeded,
              "a child past the depth limit was made");

      Ag.Charge (Store, Change, To_String (Grand), 60, Status);
      Assert (Status.Code = E.Framework_Limit_Exceeded,
              "an agent past its budget was not stopped");
      Change := S.No_Changes;

      --  The optional child fails: the parent is not failed by it.
      Ag.Finish (Store, Change, To_String (Second), False, "", "could not review", Status);
      S.Commit (Store, Change, Status);
      Assert (not Ag.May_Complete (Store, To_String (Root), Reason)
              and then Ada.Strings.Fixed.Index (To_String (Reason), "still going") > 0,
              "a parent may complete while a required child is going");

      --  The required child's own child fails: its parent must see it.
      Ag.Finish (Store, Change, To_String (Grand), False, "", "gave up", Status);
      S.Commit (Store, Change, Status);
      Assert (not Ag.May_Complete (Store, To_String (First), Reason)
              and then Ada.Strings.Fixed.Index (To_String (Reason), "failed") > 0,
              "a required child's failure did not reach its parent");
      Ag.Finish (Store, Change, To_String (Grand), True, "", "", Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "an agent that ended was ended again");

      --  What a child said on the way stays out of what its parent reads.
      Transcript :=
        (Kind       => Rs.Child_Result,
         Producer   => First,
         Summary    => To_Unbounded_String ("wrote the reader"),
         Payload    => To_Unbounded_String ("THE WHOLE CONVERSATION OF THE CHILD"),
         Provenance => First,
         others     => <>);
      Change := S.No_Changes;
      Rs.Add (Store, Change, Transcript, Status);
      S.Commit (Store, Change, Status);
      Assert (Ada.Strings.Fixed.Index (Ag.Child_Results (Store, To_String (Root)),
                                       To_String (First)) > 0
              and then Ada.Strings.Fixed.Index
                         (Ag.Child_Results (Store, To_String (Root)),
                          "THE WHOLE CONVERSATION") = 0,
              "a parent was given a child's transcript");

      --  Cancelling the root takes down what is still going beneath it.
      Ag.Cancel (Store, Change, To_String (Root), Cancelled, Status);
      S.Commit (Store, Change, Status);
      Assert (Cancelled.Contains (To_String (Root)) and then Cancelled.Contains (To_String (First))
              and then not Cancelled.Contains (To_String (Second)),
              "cancellation did not go down the tree, or reached what had ended");
      Ag.Read (Store, To_String (First), Held, Status);
      Assert (To_String (Held.Status) = "cancelled", "a child was left running");
      Assert (Ag.Limits_Of (Store).Max_Active = 4, "the limits were not read");
      Assert (Natural (Ag.Children (Store, To_String (Root)).Length) = 2,
              "a parent does not know its children");
      S.Close (Store);

      --  A project that grants no children refuses them.
      Task_Project (Store, "recursion-none",
                    "map permission.project.read_source =" & LF);
      Change := S.No_Changes;
      Ag.Start_Root (Store, Change, "TASK-001", "worker", "", Root, Status);
      S.Commit (Store, Change, Status);
      Ag.Spawn_Child (Store, Change, To_String (Root), "coder", Ag.Required,
                      Pm.Unrestricted, 10, First, Status);
      Assert (Status.Code = E.Framework_Permission_Denied,
              "an agent that may not make children made one");
      S.Close (Store);
   end Recursion_Stays_Bounded;

   --  An agent that writes where it may not fails its task.
   procedure Writes_Stay_In_Bounds
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Id     : Unbounded_String;
      Done   : Wk.Report;
   begin
      Task_Project
        (Store, "bounds",
         "map permission.project.write_source = roots=lib/" & LF
         & "map permission.project.run_tests =" & LF);
      Tk.Create (Store, Change, Fields ("Hello", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Execute (Store, To_String (Id),
                  Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                  Answer => To_Unbounded_String
                                    ("status: done" & LF & "summary: x"),
                                  Broken => False),
                  Cx.Profile (Store, ""), Done, Status);
      Assert (To_String (Done.Final_State) = "failed"
              and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "may not write") > 0,
              "a write outside the agent's roots was accepted: "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      S.Close (Store);
   end Writes_Stay_In_Bounds;

   --  A task narrows what its agent may do, and no further than it says;
   --  a restriction that does not read is refused; a grant scoped to
   --  profiles covers only those; and work an agent proposes becomes
   --  candidate tasks where it may propose, and an issue where it may not.
   procedure Permissions_And_Proposals_Reach_The_Work
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Done   : Wk.Report;
      Level  : Pm.Permission_Set;
      Checks : constant String :=
        "set execution.allowed = test" & LF
        & "profile checks = exists: test -f src/hello.adb" & LF
        & "scalar verification.default = checks" & LF;
      Proposing : constant String :=
        "status: done" & LF & "summary: wrote hello" & LF
        & "proposed_tasks: Test hello" & LF & "Document hello";

      function Contains (Text, Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Text, Part) > 0);

      procedure Work (Answer : String; Extra_Name, Extra_Value : String := "") is
         Id : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Hello", "analysis", Extra_Name, Extra_Value),
                    "user", "", Id, Status);
         Assert (E.Is_Ok (Status), "a task was not made: " & Code_Of (Status));
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id),
                     Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                     Answer => To_Unbounded_String (Answer),
                                     Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
      end Work;
   begin
      Pm.Restriction ("write_source: roots=src/parser/; run_tests: profiles=quick", Level,
                      Status);
      Assert (E.Is_Ok (Status)
              and then Pm.Allows (Level, Pm.Write_Source, "src/parser/a.adb")
              and then not Pm.Allows (Level, Pm.Write_Source, "src/b.adb")
              and then not Pm.Allows (Level, Pm.Read_Source)
              and then Pm.Allows_Profile (Level, Pm.Run_Tests, "quick")
              and then not Pm.Allows_Profile (Level, Pm.Run_Tests, "full"),
              "a task's restriction was not read as written");
      Pm.Restriction ("write_everything", Level, Status);
      Assert (Status.Code = E.Framework_Schema_Violation,
              "a restriction naming no capability was taken");

      Task_Project (Store, "narrowed", Checks);
      declare
         Id : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Bad", "analysis", "permissions", "fly"),
                    "user", "", Id, Status);
         Assert (Status.Code = E.Framework_Schema_Violation,
                 "a task was made with a restriction that does not read");
      end;

      --  Its own restriction keeps its agent out of src/.
      Work ("status: done" & LF & "summary: x", "permissions", "write_source: roots=lib/");
      Assert (To_String (Done.Final_State) = "failed"
              and then Contains (To_String (Done.Reason), "may not write"),
              "a task's own restriction did not narrow its agent: "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));

      --  What it proposes becomes candidates.
      Work (Proposing);
      Assert (To_String (Done.Final_State) = "complete"
              and then Natural (Done.Proposed.Length) = 2
              and then Tk.State_Of (Store, Done.Proposed.First_Element) = "candidate",
              "proposed work did not become candidate tasks");
      S.Close (Store);

      --  Where it may not propose, it is an issue and nothing more.
      Task_Project
        (Store, "no-proposals",
         Checks & "map permission.project.write_source =" & LF
         & "map permission.project.run_tests =" & LF);
      Work (Proposing);
      Assert (To_String (Done.Final_State) = "complete" and then Done.Proposed.Is_Empty
              and then Natural (Tk.List (Store, "candidate").Length) = 0,
              "an agent that may not propose made candidate tasks");
      S.Close (Store);
   end Permissions_And_Proposals_Reach_The_Work;

   --  A schema's records are carried forward by the steps registered for
   --  it and refused where a step is missing; results kept only for a while
   --  go when their time is up and the rest stay; the Ada adapter sees what
   --  is made from what; an agent's proposed parts are candidate children;
   --  and a task waits when no workspace slot is free.
   procedure Schemas_Retention_Adapter_And_Slots
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Sc renames Model_Runner.Framework.Schemas;
      package Rp renames Model_Runner.Framework.Repository;
      use type Rp.Relation_Kind;
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Value  : R.Item;
      Done   : Wk.Report;
   begin
      --  Migration.
      declare
         procedure Step (Old : in out R.Item; Result : out E.Error_Info) is
            Next : R.Item := R.Create (R.Schema_Id (Old), 2, R.Entity_Id (Old), R.Revision (Old));
         begin
            for Index in 1 .. R.Field_Count (Old) loop
               R.Set (Next, R.Field_Name (Old, Index), R.Get (Old, R.Field_Name (Old, Index)));
            end loop;
            R.Set (Next, "carried", "yes");
            Old := Next;
            Result := E.Success;
         end Step;
      begin
         Sc.Register_Migration (Sc.Lease_Schema, 1, Step'Unrestricted_Access);
         Value := R.Create (Sc.Lease_Schema, 1, "LEASE", 1);
         Sc.Migrate (Value, 2, Status);
         Assert (E.Is_Ok (Status) and then R.Schema_Version (Value) = 2
                 and then R.Get (Value, "carried") = "yes",
                 "a record was not carried forward by its step: " & Code_Of (Status));
         Sc.Migrate (Value, 3, Status);
         Assert (Status.Code = E.Framework_Format_Unsupported,
                 "a record was carried where no step goes");
         Sc.Migrate (Value, 1, Status);
         Assert (Status.Code = E.Framework_Format_Unsupported,
                 "a record was carried back");
      end;

      --  Retention.
      Task_Project
        (Store, "retention",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -d ." & LF
         & "scalar verification.default = checks" & LF);
      declare
         Old_Log : Rs.Result :=
           (Kind => Rs.Verification, Producer => To_Unbounded_String ("execution"),
            Summary => To_Unbounded_String ("old"), Payload => To_Unbounded_String ("x"),
            others => <>);
         New_Log : Rs.Result :=
           (Kind => Rs.Verification, Producer => To_Unbounded_String ("execution"),
            Summary => To_Unbounded_String ("new"), Payload => To_Unbounded_String ("y"),
            others => <>);
         Kept    : Rs.Result :=
           (Kind => Rs.Child_Result, Producer => To_Unbounded_String ("AG-1"),
            Summary => To_Unbounded_String ("kept"), Payload => To_Unbounded_String ("z"),
            others => <>);
         Stored  : R.Item;
         Removed : Natural;

         --  Made long ago, as far as its record says.
         procedure Age (Id : String) is
         begin
            S.Read (Store, Model_Runner.Framework.Results_Area, Id, Stored, Status);
            R.Set (Stored, "created_at", "2020-01-01T00:00:00Z");
            R.Set_Revision (Stored, R.Revision (Stored) + 1);
            S.Put (Change, Model_Runner.Framework.Results_Area, Id, Stored);
         end Age;
      begin
         Rs.Add (Store, Change, Old_Log, Status);
         Rs.Add (Store, Change, New_Log, Status);
         Rs.Add (Store, Change, Kept, Status);
         S.Commit (Store, Change, Status);
         Age (To_String (Old_Log.Id));
         Age (To_String (Kept.Id));
         S.Commit (Store, Change, Status);
         Rs.Prune (Store, Change, Raw_Log_Days => 30, Context_Days => 0, Removed => Removed);
         S.Commit (Store, Change, Status);
         Assert (Removed = 1
                 and then not S.Exists (Store, Model_Runner.Framework.Results_Area,
                                        To_String (Old_Log.Id))
                 and then S.Exists (Store, Model_Runner.Framework.Results_Area,
                                    To_String (New_Log.Id))
                 and then S.Exists (Store, Model_Runner.Framework.Results_Area,
                                    To_String (Kept.Id)),
                 "retention let the wrong results go:" & Removed'Image);
      end;

      --  The Ada adapter: instantiation, derivation, interfaces, overriding.
      declare
         Root  : constant String := Fresh_Root (Store);
         Found : Rp.Graph;
         Kinds : array (Rp.Relation_Kind) of Boolean := [others => False];
      begin
         Dirs.Create_Path (Root & "/src");
         Put_File (Root & "/src/shapes.ads",
                   "package Shapes is" & LF
                   & "   type Drawable is interface;" & LF
                   & "   type Shape is abstract tagged null record;" & LF
                   & "   type Circle is new Shape and Drawable with null record;" & LF
                   & "   overriding procedure Draw (Item : Circle);" & LF
                   & "   package Lists is new Ada.Containers.Vectors (Positive, Integer);" & LF
                   & "end Shapes;" & LF);
         Found := Rp.Scan (Root);
         for Index in 1 .. Rp.Relation_Count (Found) loop
            Kinds (Rp.Relation_At (Found, Index).Kind) := True;
         end loop;
         Assert (Kinds (Rp.Instantiates) and then Kinds (Rp.Extends)
                 and then Kinds (Rp.Implements_Interface) and then Kinds (Rp.Overrides),
                 "the adapter missed what is made from what");
      end;

      --  Proposed parts, candidate children.
      declare
         Id : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Big", "analysis"), "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id),
                     Scripted_Agent'(File => Null_Unbounded_String,
                                     Answer => To_Unbounded_String
                                       ("status: blocked" & LF & "summary: too big" & LF
                                        & "parts: First half" & LF & "Second half"),
                                     Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
         Assert (To_String (Done.Final_State) = "blocked"
                 and then Natural (Done.Proposed.Length) = 2
                 and then Tk.State_Of (Store, Done.Proposed.First_Element) = "candidate"
                 and then Tk.Children (Store, To_String (Id)).Contains (Done.Proposed.First_Element),
                 "an agent's proposed parts did not become candidate children");
      end;
      S.Close (Store);

      --  No free workspace slot, and the task waits.
      Task_Project
        (Store, "slots",
         "scalar work.isolation = workspace" & LF
         & "scalar work.max_workspaces = 0" & LF);
      declare
         Id : Unbounded_String;
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Revision : Natural;
      begin
         Changes.Include ("scalar.work.max_workspaces", "1");
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
         for Round in 1 .. 2 loop
            Tk.Create (Store, Change, Fields ("Slot" & Round'Image, "analysis"), "user", "",
                       Id, Status);
            S.Commit (Store, Change, Status);
            Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
            S.Commit (Store, Change, Status);
            Wk.Execute (Store, To_String (Id),
                        Scripted_Agent'(File => Null_Unbounded_String,
                                        Answer => To_Unbounded_String
                                          ("status: done" & LF & "summary: x"),
                                        Broken => False),
                        Cx.Profile (Store, ""), Done, Status);
         end loop;
         Assert (To_String (Done.Final_State) = "blocked"
                 and then To_String (Done.Reason) = "no workspace slot is free",
                 "a task ran with no workspace slot free: " & To_String (Done.Final_State)
                 & " " & To_String (Done.Reason));
      end;
      S.Close (Store);
   end Schemas_Retention_Adapter_And_Slots;

   --  An agent that writes source and its documentation both.
   type Documenting_Agent is new Wk.Agent_Runner with null record;

   overriding procedure Run
     (Self        : Documenting_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Run
     (Self        : Documenting_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      pragma Unreferenced (Self, Prompt_Path);
   begin
      Dirs.Create_Path (Project & "/src");
      Dirs.Create_Path (Project & "/docs");
      Put_File (Project & "/src/greet.adb", "procedure Greet is begin null; end;");
      Put_File (Project & "/docs/greet.md", "Greet greets.");
      Answer := To_Unbounded_String ("status: done" & LF & "summary: greet, documented");
      Status := E.Success;
   end Run;

   --  An agent says more than done or not: it proposes a task of another
   --  kind, a decision, a specification and a dependency -- each kept as a
   --  proposal, none asserted -- and asks for its work to be checked while
   --  it is blocked. And the gates a project names are the ones a task
   --  passes: its work present, traced, documented, and a profile of the
   --  project's own passed.
   procedure Claims_And_Gates
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Done   : Wk.Report;

      procedure Work (Runner : Wk.Agent_Runner'Class; Title : String) is
         Id : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields (Title, "analysis"), "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id), Runner, Cx.Profile (Store, ""), Done, Status);
      end Work;
   begin
      Task_Project
        (Store, "claims-gates",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -d ." & LF
         & "scalar verification.default = checks" & LF
         & "scalar gate.tidy = checks" & LF
         & "set task.gates = verification, implementation_present, traceability_sufficient,"
         & " documentation_current, tidy" & LF);

      Work (Scripted_Agent'(File => Null_Unbounded_String,
                            Answer => To_Unbounded_String
                              ("status: blocked" & LF & "summary: needs a choice" & LF
                               & "proposed_tasks: Write the manual; kind=implementation;"
                               & " component=docs" & LF
                               & "decisions: Use one binary. It keeps installs simple." & LF
                               & "specifications: The tool reads UTF-8." & LF
                               & "waits_for: TASK-999" & LF
                               & "verify: yes"),
                            Broken => False),
            "Claims");
      Assert (To_String (Done.Final_State) = "blocked"
              and then Length (Done.Evidence_Id) > 0
              and then Natural (Done.Proposed.Length) = 3
              and then Done.Waits_For.Contains ("TASK-999"),
              "the agent's claims were not each taken as a proposal: "
              & To_String (Done.Final_State) & Natural'Image (Natural (Done.Proposed.Length)));
      declare
         Defined : R.Item;
      begin
         Tk.Definition (Store, Done.Proposed.First_Element, Defined, Status);
         Assert (R.Get (Defined, "kind") = "implementation" and then R.Get (Defined, "component") = "docs"
                 and then Tk.State_Of (Store, Done.Proposed.First_Element) = "candidate",
                 "a proposed task did not keep its own kind and component");
      end;
      Assert ((for some Id of Done.Proposed => Id'Length > 4 and then Id (Id'First .. Id'First + 3) = "DEC-")
              and then (for some Id of Done.Proposed =>
                          Id'Length > 5 and then Id (Id'First .. Id'First + 4) = "SPEC-"),
              "a proposed decision or specification was not made");

      --  Source alone is not documented.
      Work (Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                            Answer => To_Unbounded_String ("status: done" & LF & "summary: x"),
                            Broken => False),
            "Undocumented");
      Assert (To_String (Done.Final_State) = "blocked"
              and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "documentation_current") > 0,
              "source changed without documentation passed its gates: " & To_String (Done.Reason));

      --  Source and documentation both, and every gate passes.
      Work (Documenting_Agent'(null record), "Documented");
      Assert (To_String (Done.Final_State) = "complete",
              "work that passed every named gate did not complete: " & To_String (Done.Reason));
      S.Close (Store);
   end Claims_And_Gates;

   --  What the project is meant to be is managed without a model: a
   --  requirement proposed, accepted -- and its task derived at once --
   --  revised and linked; a decision proposed, accepted, made to govern a
   --  setting and superseded; a candidate specification decided by the
   --  bare accept. And an agent writing a component in the project itself
   --  holds it: a task of the same component is not ready meanwhile, and
   --  the hold goes when the work ends.
   procedure Intent_Is_Managed_And_Components_Held
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package In_CLI renames Model_Runner.CLI.Intents;
      Store   : aliased S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Catalog : aliased Model_Runner.Localization.Catalog;
      Screen  : Model_Runner.Presentation.Console;
      Held    : Nt.Entity;
      Done    : Wk.Report;

      procedure Say (Kind : Nt.Intent_Kind; Line : String) is
         Words : Model_Runner.Framework.Name_Lists.Vector;
         Start : Natural := Line'First;
      begin
         for Index in Line'First .. Line'Last + 1 loop
            if Index > Line'Last or else Line (Index) = '|' then
               Words.Append (Line (Start .. Index - 1));
               Start := Index + 1;
            end if;
         end loop;
         In_CLI.Run (Store, Kind, Words, Screen);
      end Say;

      --  What a register holds now, to tell the entry a new one made.
      Known : array (Nt.Intent_Kind) of Model_Runner.Framework.Name_Lists.Vector;

      --  The entry that appeared since this was last asked.
      function First_Of (Kind : Nt.Intent_Kind) return String is
         Listed : constant Model_Runner.Framework.Name_Lists.Vector := Nt.List (Store, Kind);
      begin
         for Id of Listed loop
            if not Known (Kind).Contains (Id) then
               Known (Kind) := Listed;
               return Id;
            end if;
         end loop;
         return (if Listed.Is_Empty then "" else Listed.Last_Element);
      end First_Of;
   begin
      Model_Runner.Localization.Open (Catalog, Model_Runner.Platform.Catalog_Path, "en");
      Model_Runner.Presentation.Open
        (Screen, Catalog'Unchecked_Access, Model_Runner.CLI.Options.Color_Never,
         (Output_Is_Terminal => False, Error_Is_Terminal => False,
          Input_Is_Terminal  => False, Colour_Suppressed => True),
         Model_Runner.CLI.Options.Quiet);
      Task_Project (Store, "intent-commands", "scalar task.derived_kind = analysis" & LF);
      for Kind in Nt.Intent_Kind loop
         Known (Kind) := Nt.List (Store, Kind);
      end loop;

      --  A requirement, through its life.
      Say (Nt.Requirement, "new|Read the input|text=The program reads its input.|criteria=It reads a file.");
      declare
         Req : constant String := First_Of (Nt.Requirement);
      begin
         Nt.Read (Store, Nt.Requirement, Req, Held, Status);
         Assert (E.Is_Ok (Status) and then To_String (Held.State) = "candidate"
                 and then To_String (Held.Criteria) = "It reads a file.",
                 "a requirement was not proposed as a candidate: [" & Req & "] "
                 & Code_Of (Status) & " " & To_String (Held.State) & " ["
                 & To_String (Held.Criteria) & "]");
         Assert (In_CLI.Pending (Store).Contains ("requirement:" & Req),
                 "a candidate requirement is not pending");
         Say (Nt.Requirement, "accept|" & Req);
         Nt.Read (Store, Nt.Requirement, Req, Held, Status);
         Assert (To_String (Held.State) = "accepted"
                 and then (for some Id of Tk.List (Store) =>
                             Ada.Strings.Fixed.Index
                               (Model_Runner.Framework.Records.Get
                                  (Definition_Of (Store, Id), "requirements"), Req) > 0),
                 "an accepted requirement did not derive its task");
         declare
            Before : constant Natural := Held.Revision;
         begin
            Say (Nt.Requirement, "revise|" & Req & "|criteria=It reads a file and standard input.");
            Nt.Read (Store, Nt.Requirement, Req, Held, Status);
            Assert (Held.Revision > Before
                    and then To_String (Held.Criteria) = "It reads a file and standard input.",
                    "a requirement was not revised");
         end;
         Say (Nt.Requirement, "link|" & Req & "|test|tests/input");
         Assert (Nt.Links (Store, Nt.Requirement, Req, Nt.Test).Contains ("tests/input"),
                 "a requirement was not linked");
      end;

      --  A decision: accepted, governing, superseded.
      Say (Nt.Decision, "new|Build with Alire|text=Alire builds it.");
      declare
         First : constant String := First_Of (Nt.Decision);
      begin
         Say (Nt.Decision, "accept|" & First);
         Say (Nt.Decision, "govern|" & First & "|scalar.build.command|alr build");
         Say (Nt.Decision, "new|Build with gprbuild|text=gprbuild builds it.");
         declare
            Second : constant String := First_Of (Nt.Decision);
         begin
            Say (Nt.Decision, "supersede|" & First & "|" & Second);
            Nt.Read (Store, Nt.Decision, First, Held, Status);
            Assert (To_String (Held.State) = "superseded"
                    and then To_String (Held.Superseded_By) = Second,
                    "a decision was not superseded: " & To_String (Held.State));
         end;
      end;

      --  A candidate specification, by the bare accept.
      Say (Nt.Specification, "new|The interface|text=It has one command.");
      declare
         Spec : constant String := First_Of (Nt.Specification);
      begin
         In_CLI.Decide (Store, "specification:" & Spec, True, Screen);
         Nt.Read (Store, Nt.Specification, Spec, Held, Status);
         Assert (To_String (Held.State) = "accepted", "a specification was not accepted");
      end;
      S.Close (Store);

      --  A component held while it is written.
      Task_Project (Store, "component-held", "set execution.allowed = test" & LF);
      declare
         First, Second : Unbounded_String;
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Revision : Natural;
      begin
         Changes.Include ("profile.tests", "exists: test -f src/hello.adb");
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
         Tk.Create (Store, Change, Fields ("One", "implementation", "component", "demo"),
                    "user", "", First, Status);
         Tk.Create (Store, Change, Fields ("Two", "implementation", "component", "demo"),
                    "user", "", Second, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (First), "accepted", "", Status => Status);
         Tk.Move (Store, Change, To_String (Second), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Ls.Acquire (Store, Change, Tk.Component_Lease ("demo"), "AG-OTHER", 600, Status);
         S.Commit (Store, Change, Status);
         Assert (not Tk.Ready (Store, To_String (Second)).Ready
                 and then (for some Reason of Tk.Ready (Store, To_String (Second)).Reasons =>
                             Ada.Strings.Fixed.Index (Reason, "being written") > 0),
                 "a task was ready while its component was being written");
         Wk.Execute (Store, To_String (Second),
                     Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                     Answer => To_Unbounded_String
                                       ("status: done" & LF & "summary: x"),
                                     Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
         Assert (Status.Code = E.Framework_Task_Not_Ready,
                 "work started on a component another agent was writing");
         Ls.Release (Store, Change, Tk.Component_Lease ("demo"), "AG-OTHER", Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (First),
                     Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                     Answer => To_Unbounded_String
                                       ("status: done" & LF & "summary: x" & LF
                                        & "changed_files: src/hello.adb"),
                                     Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
         Assert (To_String (Done.Final_State) = "complete"
                 and then Ls.Holder (Store, Tk.Component_Lease ("demo")) = "",
                 "the component was still held after the work ended: "
                 & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      end;
      S.Close (Store);
   end Intent_Is_Managed_And_Components_Held;

   --  Properties, not examples. The task lifecycle allows exactly the moves
   --  the specification lists, the reopen and reconsideration ones only
   --  when granted -- every pair of states, both ways. And over dependency
   --  graphs grown at random from fixed seeds: a dependency is refused
   --  exactly when it would close a cycle, no cycle is ever held, and a
   --  task is ready exactly when everything it waits for is complete.
   procedure State_Machine_And_Graph_Properties
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      type State_Name is access constant String;
      States : constant array (1 .. 9) of State_Name :=
        [new String'("candidate"), new String'("accepted"), new String'("running"),
         new String'("blocked"), new String'("verification"), new String'("complete"),
         new String'("failed"), new String'("cancelled"), new String'("rejected")];

      --  The specification's table, as pairs; the last three need a grant.
      Listed : constant array (1 .. 21) of State_Name :=
        [new String'("candidate>accepted"), new String'("candidate>rejected"),
         new String'("accepted>running"), new String'("accepted>blocked"),
         new String'("accepted>cancelled"), new String'("blocked>accepted"),
         new String'("blocked>cancelled"), new String'("blocked>failed"),
         new String'("running>verification"), new String'("running>blocked"),
         new String'("running>failed"), new String'("running>cancelled"),
         new String'("verification>complete"), new String'("verification>running"),
         new String'("verification>blocked"), new String'("verification>failed"),
         new String'("verification>cancelled"), new String'("failed>accepted"),
         new String'("failed>cancelled"),
         new String'("complete>accepted"), new String'("cancelled>accepted")];
      Granted_Only : constant array (1 .. 3) of State_Name :=
        [new String'("complete>accepted"), new String'("cancelled>accepted"),
         new String'("rejected>candidate")];

      function In_Table (Pair : String) return Boolean
      is ((for some One of Listed => One.all = Pair)
          or else (for some One of Granted_Only => One.all = Pair));
      function Needs_Grant (Pair : String) return Boolean
      is (for some One of Granted_Only => One.all = Pair);

      use type Interfaces.Unsigned_64;
      Machine : constant Tr.Machine := Tk.Lifecycle;
      Status  : E.Error_Info;
      All_Granted : constant Tr.Permissions := [others => True];

      --  A generator with a seed of its own, so a failure can be run again.
      Seed : Interfaces.Unsigned_64;
      function Next (Below : Positive) return Positive is
      begin
         Seed := Seed * 6364136223846793005 + 1442695040888963407;
         return Natural (Interfaces.Shift_Right (Seed, 33) mod Interfaces.Unsigned_64 (Below)) + 1;
      end Next;
   begin
      for From of States loop
         for To of States loop
            declare
               Pair : constant String := From.all & ">" & To.all;
            begin
               Tr.Check (Machine, "T", From.all, To.all, Tr.Ordinary_Only, Status);
               Assert (E.Is_Ok (Status) = (In_Table (Pair) and then not Needs_Grant (Pair)),
                       Pair & " is " & (if E.Is_Ok (Status) then "allowed" else "refused")
                       & " as an ordinary move");
               Tr.Check (Machine, "T", From.all, To.all, All_Granted, Status);
               Assert (E.Is_Ok (Status) = In_Table (Pair),
                       Pair & " is " & (if E.Is_Ok (Status) then "allowed" else "refused")
                       & " with every grant");
            end;
         end loop;
      end loop;

      for Round in 1 .. 3 loop
         Seed := Interfaces.Unsigned_64 (Round) * 7919;
         declare
            Size   : constant := 10;
            Store  : S.Store;
            Change : S.Transaction;
            Ids    : array (1 .. Size) of Unbounded_String;
            Waits  : array (1 .. Size, 1 .. Size) of Boolean := [others => [others => False]];

            --  Whether A reaches B through what waits for what, by the
            --  test's own walk.
            function Reaches (Start, Goal : Positive) return Boolean is
               Seen  : array (1 .. Size) of Boolean := [others => False];
               function Walk (From : Positive) return Boolean is
               begin
                  if From = Goal then
                     return True;
                  end if;
                  Seen (From) := True;
                  for Other in 1 .. Size loop
                     if Waits (From, Other) and then not Seen (Other) and then Walk (Other) then
                        return True;
                     end if;
                  end loop;
                  return False;
               end Walk;
            begin
               return Walk (Start);
            end Reaches;
         begin
            Task_Project (Store, "properties-" & Ada.Strings.Fixed.Trim (Round'Image, Ada.Strings.Both));
            for Index in Ids'Range loop
               Tk.Create (Store, Change, Fields ("T" & Index'Image, "analysis"), "user", "",
                          Ids (Index), Status);
               S.Commit (Store, Change, Status);
               Tk.Move (Store, Change, To_String (Ids (Index)), "accepted", "", Status => Status);
               S.Commit (Store, Change, Status);
            end loop;

            for Try in 1 .. 30 loop
               declare
                  A : constant Positive := Next (Size);
                  B : constant Positive := Next (Size);
                  Closes : constant Boolean :=
                    A = B or else Reaches (Start => B, Goal => A);
               begin
                  Tk.Add_Dependency (Store, Change, To_String (Ids (A)), To_String (Ids (B)), Status);
                  Assert (E.Is_Error (Status) = Closes,
                          "seed" & Round'Image & ": waiting" & A'Image & " on" & B'Image & " was "
                          & (if E.Is_Error (Status) then "refused" else "taken")
                          & " though it " & (if Closes then "closes" else "closes no") & " cycle");
                  if E.Is_Ok (Status) then
                     S.Commit (Store, Change, Status);
                     Waits (A, B) := True;
                  else
                     Change := S.No_Changes;
                  end if;
               end;
            end loop;
            Assert (Tk.Cycles (Store).Is_Empty, "a cycle was held");

            --  Some complete; readiness follows exactly.
            for Index in 1 .. Size loop
               if Next (3) = 1 then
                  Tk.Move (Store, Change, To_String (Ids (Index)), "running", "", Status => Status);
                  Tk.Move (Store, Change, To_String (Ids (Index)), "verification", "",
                           Status => Status);
                  Tk.Move (Store, Change, To_String (Ids (Index)), "complete", "",
                           Gates_Passed => True, Status => Status);
                  S.Commit (Store, Change, Status);
               end if;
            end loop;
            for Index in 1 .. Size loop
               if Tk.State_Of (Store, To_String (Ids (Index))) = "accepted" then
                  declare
                     Expected : Boolean := True;
                  begin
                     for Other in 1 .. Size loop
                        if Waits (Index, Other)
                          and then Tk.State_Of (Store, To_String (Ids (Other))) /= "complete"
                        then
                           Expected := False;
                        end if;
                     end loop;
                     Assert (Tk.Ready (Store, To_String (Ids (Index))).Ready = Expected,
                             "seed" & Round'Image & ": task" & Index'Image & " is "
                             & (if Expected then "not " else "") & "ready against what it waits for");
                  end;
               end if;
            end loop;
            S.Close (Store);
         end;
      end loop;
   end State_Machine_And_Graph_Properties;

   --  Where the project lists its components a task names one of them or
   --  none; a check keeps to its own deadline, tries and severity; the
   --  evidence says which tools and adapters it was taken with and with
   --  what; each check is an event; and evidence taken in another
   --  environment, or with another toolchain where the policy asks, no
   --  longer applies.
   procedure Components_Checks_And_Evidence
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store    : S.Store;
      Status   : E.Error_Info;
      Change   : S.Transaction;
      Id       : Unbounded_String;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Value    : R.Item;
      Reasons  : Model_Runner.Framework.Name_Lists.Vector;
      Revised  : Tk.Field_Map;
   begin
      Task_Project
        (Store, "components-evidence",
         "set components = parser, lexer" & LF
         & "set execution.allowed = test" & LF
         & "set execution.environment = MR_EVIDENCE_PROBE" & LF
         & "scalar verification.toolchain = strict" & LF
         & "profile careful = build[timeout=5, keep=summary]: test -d .;"
         & " flaky[retry=2, severity=warning]: test -f no-such-file" & LF);

      --  Components.
      Tk.Create (Store, Change, Fields ("Lex", "implementation", "component", "lexer"),
                 "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status), "a listed component was refused: " & Code_Of (Status));
      Tk.Create (Store, Change, Fields ("Other", "implementation", "component", "nowhere"),
                 "user", "", Id, Status);
      Assert (Status.Code = E.Framework_Not_Found, "an unlisted component was taken");
      Change := S.No_Changes;
      Tk.Create (Store, Change, Fields ("Lex again", "implementation", "component", "lexer"),
                 "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Revised.Include ("component", "nowhere");
      Tk.Revise (Store, Change, To_String (Id), Revised, Status);
      Assert (Status.Code = E.Framework_Not_Found, "a task was revised to an unlisted component");
      Change := S.No_Changes;

      --  Checks, evidence, events.
      Ada.Environment_Variables.Set ("MR_EVIDENCE_PROBE", "one");
      Vf.Run_Profile (Store, Change, "careful", "", Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Passed,
              "a failing check of warning severity failed the profile: " & Code_Of (Status));
      S.Read (Store, Model_Runner.Framework.Verification_Area, To_String (Evidence), Value, Status);
      Assert (Ada.Strings.Fixed.Index (R.Get (Value, "check.0002"), "warning") > 0
              and then Ada.Strings.Fixed.Index (R.Get (Value, "check.0002"), ASCII.HT & "3") > 0
              and then Ada.Strings.Fixed.Index (R.Get (Value, "parameters.0001"), "timeout=5") > 0
              and then Ada.Strings.Fixed.Index (R.Get (Value, "parameters.0001"), "keep=summary") > 0
              and then R.Has (Value, "tool.test")
              and then R.Has (Value, "template_version"),
              "the evidence does not say how its checks ran and with what: "
              & R.Get (Value, "check.0002"));
      declare
         Seen   : constant Ev.Event_List := Ev.Since (Store, 0);
         Builds : Natural := 0;
         Failed : Natural := 0;
      begin
         for Index in 1 .. Ev.Length (Seen) loop
            if To_String (Ev.Element (Seen, Index).Kind_Word) = Ev.Kind_Name (Ev.Build_Completed)
            then
               Builds := Builds + 1;
            elsif To_String (Ev.Element (Seen, Index).Kind_Word) = Ev.Kind_Name (Ev.Test_Failed)
            then
               Failed := Failed + 1;
            end if;
         end loop;
         Assert (Builds = 1 and then Failed = 1, "the checks were not each an event");
      end;

      Assert (Vf.Is_Current (Store, To_String (Evidence), Reasons),
              "evidence did not apply in the environment and toolchain it was taken with: "
              & (if Reasons.Is_Empty then "" else Reasons.First_Element));
      Ada.Environment_Variables.Set ("MR_EVIDENCE_PROBE", "two");
      Assert (not Vf.Is_Current (Store, To_String (Evidence), Reasons)
              and then (for some Line of Reasons =>
                          Ada.Strings.Fixed.Index (Line, "environment") > 0),
              "evidence still applied in another environment");
      Ada.Environment_Variables.Clear ("MR_EVIDENCE_PROBE");
      S.Close (Store);
   end Components_Checks_And_Evidence;

   --  A task is revised as a new revision of its definition, never in its
   --  kind; split, its parent waits on its parts unless the project lets it
   --  coordinate; an ended task is reopened, and a rejected one
   --  reconsidered, only when that is granted. Its Effective Task says what
   --  governs it, what it may do, where it writes, what bounds it and what
   --  it must pass -- each by its kind where the kind says -- and what
   --  governs it reaches the model's context.
   procedure Tasks_Are_Revised_Split_And_Reopened
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      A, B, C, D, Decision : Unbounded_String;
      Made    : Model_Runner.Framework.Name_Lists.Vector;
      Defined : R.Item;
      View    : R.Item;
      Parts   : Model_Runner.Framework.Name_Lists.Vector;

      procedure Make (Id : out Unbounded_String; Title : String; Accept_It : Boolean := True) is
      begin
         Tk.Create (Store, Change, Fields (Title, "analysis"), "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         if Accept_It then
            Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
            S.Commit (Store, Change, Status);
         end if;
      end Make;

      procedure Configure (Name, Value : String) is
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Revision : Natural;
      begin
         Changes.Include (Name, Value);
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
      end Configure;

      Revise_Fields : Tk.Field_Map;
      Granted       : Model_Runner.Framework.Transitions.Permissions :=
        Model_Runner.Framework.Transitions.Ordinary_Only;
   begin
      Task_Project (Store, "lifecycle-more");

      --  Revised, not re-kinded.
      Make (A, "First");
      Revise_Fields.Include ("title", "First, better");
      Tk.Revise (Store, Change, To_String (A), Revise_Fields, Status);
      S.Commit (Store, Change, Status);
      Tk.Definition (Store, To_String (A), Defined, Status);
      Assert (R.Get (Defined, "title") = "First, better" and then R.Revision (Defined) = 2,
              "a task was not revised as its next revision");
      Revise_Fields.Clear;
      Revise_Fields.Include ("kind", "implementation");
      Tk.Revise (Store, Change, To_String (A), Revise_Fields, Status);
      Assert (Status.Code = E.Framework_Schema_Violation, "a task's kind was revised");
      Change := S.No_Changes;

      --  Split: the parent waits on its parts.
      Parts.Append ("One part");
      Parts.Append ("The other");
      Tk.Decompose (Store, Change, To_String (A), Parts, Made, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Natural (Made.Length) = 2
              and then Tk.State_Of (Store, To_String (A)) = "blocked"
              and then Tk.Children (Store, To_String (A)).Contains (Made.First_Element),
              "a split task did not wait on its parts: " & Code_Of (Status));

      --  Unless its kind lets it coordinate.
      Configure ("scalar.task.coordination.analysis", "parent_runs");
      Make (B, "Coordinator");
      Tk.Decompose (Store, Change, To_String (B), Parts, Made, Status);
      S.Commit (Store, Change, Status);
      Assert (Tk.State_Of (Store, To_String (B)) = "accepted",
              "a coordinating parent was blocked");

      --  Reopened and reconsidered only when granted.
      Make (C, "Done once");
      Tk.Move (Store, Change, To_String (C), "running", "", Status => Status);
      Tk.Move (Store, Change, To_String (C), "verification", "", Status => Status);
      Tk.Move (Store, Change, To_String (C), "complete", "", Gates_Passed => True, Status => Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (C), "accepted", "", Status => Status);
      Assert (E.Is_Error (Status), "a complete task was reopened without a grant");
      Change := S.No_Changes;
      Granted (Model_Runner.Framework.Transitions.Reopen) := True;
      Tk.Move (Store, Change, To_String (C), "accepted", "reopened", Granted, Status => Status);
      S.Commit (Store, Change, Status);
      Assert (Tk.State_Of (Store, To_String (C)) = "accepted", "a granted reopen did not happen");
      Make (D, "Turned down", Accept_It => False);
      Tk.Move (Store, Change, To_String (D), "rejected", "", Status => Status);
      S.Commit (Store, Change, Status);
      Granted := Model_Runner.Framework.Transitions.Ordinary_Only;
      Granted (Model_Runner.Framework.Transitions.Reconsideration) := True;
      Tk.Move (Store, Change, To_String (D), "candidate", "reconsidered", Granted, Status => Status);
      S.Commit (Store, Change, Status);
      Assert (Tk.State_Of (Store, To_String (D)) = "candidate",
              "a granted reconsideration did not happen");

      --  Per kind: its gates and its policies.
      Configure ("set.task.gates.analysis", "verification");
      Configure ("scalar.task.isolation.analysis", "workspace");
      Assert (Natural (Tk.Gate_Names (Store, "analysis").Length) = 1
              and then Natural (Tk.Gate_Names (Store, "implementation").Length) = 4
              and then Tk.Kind_Policy (Store, "analysis", "isolation") = "workspace",
              "a kind's own gates or policies were not read");

      --  What governs it, in its Effective Task and its context.
      Nt.Propose (Store, Change, Nt.Decision, "", "Default checks",
                  "Tasks are checked with checks.", "", "user", "", "project", Decision, Status);
      Nt.Govern (Store, Change, Nt.Decision, To_String (Decision),
                 "scalar.verification.default", "checks", "CONFIG", Status);
      Nt.Move (Store, Change, Nt.Decision, To_String (Decision), "accepted",
               Model_Runner.Framework.Transitions.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Tk.Effective (Store, To_String (C), View, Status);
      Assert (Ada.Strings.Fixed.Index
                (R.Get (View, "authority.scalar.verification.default"), To_String (Decision)) > 0
              and then R.Get (View, "workspace_policy") = "workspace"
              and then R.Get (View, "gates") = "verification"
              and then R.Get (View, "resource.max_steps") = "24"
              and then Ada.Strings.Fixed.Index (R.Get (View, "permissions"), "write_source") > 0,
              "the Effective Task does not say what governs and bounds it: ["
              & R.Get (View, "authority.scalar.verification.default") & "] ["
              & R.Get (View, "workspace_policy") & "] [" & R.Get (View, "gates") & "] ["
              & R.Get (View, "resource.max_steps") & "] [" & R.Get (View, "permissions") & "]");
      declare
         Built : Cx.Built;
      begin
         Cx.Build (Store, To_String (C), Cx.Profile (Store, ""), Built, Status);
         Assert (Ada.Strings.Fixed.Index (Cx.Rendered (Built), "What governs the work") > 0,
                 "what governs the work did not reach the context");
      end;
      S.Close (Store);
   end Tasks_Are_Revised_Split_And_Reopened;

   --  How widely work is verified follows what it changed and the
   --  project's policy: with nothing narrower configured the whole profile
   --  runs and says why; where the policy tests narrowly and names a
   --  profile for that, it runs in the task's profile's place -- given the
   --  scope it runs for -- and completes the task.
   procedure Verification_Follows_What_Changed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Done   : Wk.Report;
      Value  : R.Item;

      procedure Work (Name : String) is
         Change : S.Transaction;
         Id     : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields (Name, "analysis"), "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id),
                     Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                     Answer => To_Unbounded_String
                                       ("status: done" & LF & "summary: x"),
                                     Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
      end Work;
   begin
      Task_Project
        (Store, "scoped",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF);
      Work ("Whole");
      Assert (To_String (Done.Final_State) = "complete"
              and then To_String (Done.Scope) = "full_suite"
              and then Length (Done.Scope_Reason) > 0,
              "work was not verified whole, with why: " & To_String (Done.Scope) & " "
              & To_String (Done.Reason));
      S.Close (Store);

      Task_Project
        (Store, "scoped-narrow",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "profile quick = scoped: test {scope} = certain_tests" & LF
         & "scalar verification.default = checks" & LF
         & "scalar verification.escalation = narrow" & LF
         & "scalar verification.scope.certain = quick" & LF);
      Work ("Narrow");
      Assert (To_String (Done.Final_State) = "complete"
              and then To_String (Done.Scope) = "certain_tests",
              "narrow verification did not stand for the task's profile: "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      S.Read (Store, Model_Runner.Framework.Verification_Area, To_String (Done.Evidence_Id),
              Value, Status);
      Assert (R.Get (Value, "profile") = "quick" and then R.Get (Value, "stands_for") = "checks"
              and then R.Get (Value, "given.scope") = "certain_tests",
              "the evidence does not say what it was run for");
      S.Close (Store);
   end Verification_Follows_What_Changed;

   --  The consistency check sees a task tied to a component the project
   --  does not have, and one held ready while what it depends on is open.
   procedure Consistency_Sees_Components_And_Readiness
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Cs renames Model_Runner.Framework.Consistency;
      use type Cs.Finding_Kind;
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      First  : Unbounded_String;
      Second : Unbounded_String;
      Cache  : R.Item :=
        R.Create (Model_Runner.Framework.Schemas.Readiness_Schema, 1, "READINESS", 1);

      function Has (Kind : Cs.Finding_Kind; Subject : String) return Boolean is
         Found : constant Cs.Finding_List := Cs.Check (Store);
      begin
         return (for some Index in 1 .. Cs.Length (Found) =>
                   Cs.Element (Found, Index).Kind = Kind
                   and then To_String (Cs.Element (Found, Index).Subject) = Subject);
      end Has;
   begin
      Task_Project (Store, "consistency-more");
      Tk.Create (Store, Change, Fields ("First", "implementation", "component", "nowhere"),
                 "user", "", First, Status);
      S.Commit (Store, Change, Status);
      Tk.Create (Store, Change, Fields ("Second", "analysis", "depends_on", To_String (First)),
                 "user", "", Second, Status);
      S.Commit (Store, Change, Status);
      Assert (Has (Cs.Missing_Component, To_String (First)),
              "a component the project does not have went unseen");

      if S.Exists (Store, Model_Runner.Framework.Indexes_Area, "readiness") then
         S.Read (Store, Model_Runner.Framework.Indexes_Area, "readiness", Cache, Status);
         R.Set_Revision (Cache, R.Revision (Cache) + 1);
      end if;
      R.Set (Cache, "task." & To_String (Second), "ready");
      S.Put (Change, Model_Runner.Framework.Indexes_Area, "readiness", Cache);
      S.Commit (Store, Change, Status);
      Assert (Has (Cs.Ready_With_Open_Dependency, To_String (Second)),
              "a task held ready with an open dependency went unseen");
      S.Close (Store);
   end Consistency_Sees_Components_And_Readiness;

   --  A change to the configuration is worked out first -- what it
   --  changes and reaches -- and refused where it touches what is not a
   --  setting or does not read; made, it is a new revision in the history,
   --  with Configuration_Changed, and what was verified before no longer
   --  applies; a plan made against an older revision is refused.
   procedure Configuration_Changes_Explicitly
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store    : S.Store;
      Status   : E.Error_Info;
      Change   : S.Transaction;
      Changes  : Cf.Value_Maps.Map;
      Planned  : Cf.Change_Plan;
      Stale    : Cf.Change_Plan;
      Revision : Natural;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Reasons  : Model_Runner.Framework.Name_Lists.Vector;
      Config   : R.Item;

      function Refused (Name, Value : String) return Boolean is
         One : Cf.Value_Maps.Map;
         Out_Plan : Cf.Change_Plan;
         Got : E.Error_Info;
      begin
         One.Include (Name, Value);
         Cf.Plan_Change (Store, One, Out_Plan, Got);
         return E.Is_Error (Got);
      end Refused;
   begin
      Task_Project
        (Store, "reconfigure",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -d ." & LF
         & "scalar verification.default = checks" & LF);
      Vf.Run_Profile (Store, Change, "checks", "", Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      Assert (Vf.Is_Current (Store, To_String (Evidence), Reasons),
              "fresh evidence did not apply");

      Assert (Refused ("template_id", "other"), "where the configuration came from was changed");
      Assert (Refused ("profile.checks", "no colon here"), "a profile that does not read was taken");
      Assert (Refused ("map.permission.project.fly", ""), "a permission no capability names was taken");

      Changes.Include ("scalar.work.isolation", "workspace");
      Changes.Include ("set.execution.allowed", "test, alr");
      Cf.Plan_Change (Store, Changes, Planned, Status);
      Assert (E.Is_Ok (Status) and then Natural (Planned.Changed.Length) = 2,
              "the change was not worked out: " & Code_Of (Status));
      Assert ((for some Line of Planned.Impact => Ada.Strings.Fixed.Index (Line, "work:") = 1)
              and then (for some Line of Planned.Impact =>
                          Ada.Strings.Fixed.Index (Line, "evidence:") = 1),
              "what the change reaches was not said");
      Cf.Plan_Change (Store, Changes, Stale, Status);

      Cf.Reconfigure (Store, Planned, Revision, Status);
      Assert (E.Is_Ok (Status) and then Revision = 2,
              "the change was not made: " & Code_Of (Status) & Natural'Image (Revision));
      Cf.Read (Store, Config, Status);
      Assert (R.Revision (Config) = 2
              and then R.Get (Config, "scalar.work.isolation") = "workspace"
              and then R.Get (Config, "set.execution.allowed") = "test" & LF & "alr",
              "the new revision is not what was planned");
      S.Read (Store, Model_Runner.Framework.Config_Area, "revision-000002", Config, Status);
      Assert (E.Is_Ok (Status), "the new revision was not kept in the history");
      declare
         Seen : constant Ev.Event_List := Ev.Since (Store, 0);
      begin
         Assert (To_String (Ev.Element (Seen, Ev.Length (Seen)).Kind_Word)
                   = Ev.Kind_Name (Ev.Configuration_Changed),
                 "Configuration_Changed was not emitted");
      end;
      Assert (not Vf.Is_Current (Store, To_String (Evidence), Reasons)
              and then (for some Line of Reasons =>
                          Ada.Strings.Fixed.Index (Line, "configuration") > 0),
              "evidence taken under the old configuration still applied");

      Cf.Reconfigure (Store, Stale, Revision, Status);
      Assert (Status.Code = E.Framework_Revision_Conflict,
              "a change planned against an older revision was made");
      S.Close (Store);
   end Configuration_Changes_Explicitly;

   --  Opening a project puts right what an interruption left: a task left
   --  running with no one running it, an agent and a call no one is
   --  running, a workspace whose directory is gone; it says what it cannot
   --  settle -- a workspace directory with no record -- and a second look
   --  finds nothing to do.
   procedure Opening_Recovers
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Said   : Model_Runner.Framework.Name_Lists.Vector;
      Task_A : Unbounded_String;
      Agent  : Unbounded_String;
      Call   : Unbounded_String;
      Made   : Ws.Workspace;

      function Says (Part : String) return Boolean
      is (for some Line of Said => Ada.Strings.Fixed.Index (Line, Part) > 0);
   begin
      Task_Project (Store, "recovery");
      Tk.Create (Store, Change, Fields ("Left running", "analysis"), "user", "", Task_A, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Task_A), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Task_A), "running", "", Status => Status);
      Ag.Start_Root (Store, Change, To_String (Task_A), "worker", "analysis", Agent, Status);
      S.Commit (Store, Change, Status);
      Iv.Start (Store, Change, To_String (Agent), To_String (Task_A), "1", "p", "CTX-0",
                "files", Iv.Work_Claim, Call, Status);
      Ws.Create (Store, Change, To_String (Task_A), To_String (Agent), "1", False, Made, Status);
      S.Commit (Store, Change, Status);
      Dirs.Delete_Tree (To_String (Made.Path));
      Dirs.Create_Path (Dirs.Containing_Directory (S.Root (Store)) & "/.model_runner/workspaces/WS-999999");

      Wk.Recover_On_Opening (Store, (others => <>), Said, Status);
      Assert (E.Is_Ok (Status), "recovery failed: " & Code_Of (Status));
      Assert (Says (To_String (Task_A) & " was running")
              and then Tk.State_Of (Store, To_String (Task_A)) = "blocked",
              "a task left running was left running");
      Assert (Iv.State_Of (Store, To_String (Call)) = "failed" and then Says (To_String (Call)),
              "a call no one was running was not recorded abandoned");
      Assert (Says (To_String (Made.Id) & ": its directory is gone"),
              "a workspace whose directory is gone was not reconciled");
      Assert (Says ("WS-999999 has no record"),
              "a workspace directory with no record was not reported");

      Dirs.Delete_Tree (Dirs.Containing_Directory (S.Root (Store)) & "/.model_runner/workspaces/WS-999999");
      Wk.Recover_On_Opening (Store, (others => <>), Said, Status);
      Assert (E.Is_Ok (Status) and then Said.Is_Empty,
              "a second look found something to do: "
              & (if Said.Is_Empty then "" else Said.First_Element));

      --  Where the project says so, such a task is accepted again instead.
      declare
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Revision : Natural;
         Task_B   : Unbounded_String;
         Other    : Unbounded_String;
      begin
         Changes.Include ("scalar.recovery.running", "accepted");
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
         Tk.Create (Store, Change, Fields ("Retried", "analysis"), "user", "", Task_B, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Task_B), "accepted", "", Status => Status);
         Tk.Move (Store, Change, To_String (Task_B), "running", "", Status => Status);
         Ag.Start_Root (Store, Change, To_String (Task_B), "worker", "analysis", Other, Status);
         S.Commit (Store, Change, Status);
         Wk.Recover_On_Opening (Store, (others => <>), Said, Status);
         Assert (E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Task_B)) = "accepted",
                 "the recovery policy was not followed: "
                 & Tk.State_Of (Store, To_String (Task_B)) & " " & Code_Of (Status));
      end;
      S.Close (Store);
   end Opening_Recovers;

   --  An agent that asks for children through the host, as a plan says.
   type Parent_Plan is
     (Helped, Fails_Twice, Fails_Then_Good, Optional_Fails, Left_Open, Denied,
      Checks_First, Interrupted, Out_Of_Time);

   type Scripted_Parent is new Wk.Parenting_Runner with record
      Plan : Parent_Plan := Helped;
   end record;

   overriding procedure Run
     (Self        : Scripted_Parent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding procedure Run_Parenting
     (Self        : Scripted_Parent;
      Prompt_Path : String;
      Project     : String;
      Children    : in out Wk.Child_Host'Class;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info);

   overriding function Profile (Self : Scripted_Parent) return Cx.Model_Profile
   is ((Id => To_Unbounded_String ("scripted"), Context_Limit => 4096, others => <>));

   --  What the parent was last told of a child, and the last refusal.
   Parent_Told   : Unbounded_String;
   Parent_Status : E.Error_Info;

   Parent_Done : constant String :=
     "status: done" & LF & "summary: wrote hello" & LF & "changed_files: src/hello.adb";
   Child_Done  : constant String :=
     "status: done" & LF & "summary: looked" & LF & "findings: it is fine";
   Child_Fails : constant String := "status: failed" & LF & "summary: could not look";

   overriding procedure Run
     (Self        : Scripted_Parent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      pragma Unreferenced (Prompt_Path);
   begin
      --  Each plan writes something of its own, so each one changes it.
      Dirs.Create_Path (Project & "/src");
      Put_File (Project & "/src/hello.adb",
                "procedure Hello is begin null; end; -- " & Parent_Plan'Image (Self.Plan));
      Answer := To_Unbounded_String (Parent_Done);
      Status := E.Success;
   end Run;

   overriding procedure Run_Parenting
     (Self        : Scripted_Parent;
      Prompt_Path : String;
      Project     : String;
      Children    : in out Wk.Child_Host'Class;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info)
   is
      Root    : constant String := Children.Current;
      Id      : Unbounded_String;
      Context : Unbounded_String;
      Budget  : Natural;
      Retry   : Boolean := False;

      procedure Ask (Need, Said : String; Retry_Of : String := ""; Close : Boolean := True) is
      begin
         Children.Open_Child
           ("reviewer", Need, "look at hello", Retry_Of, Id, Context, Budget, Parent_Status);
         if E.Is_Ok (Parent_Status) then
            Assert (Ada.Strings.Fixed.Index (To_String (Context), "look at hello") > 0
                    and then Ada.Strings.Fixed.Index (To_String (Context), "status: done") > 0
                    and then Budget > 0 and then Children.Current = To_String (Id),
                    "a child was not given a context and budget of its own");
            if Close then
               Children.Close_Child (Said, 10, E.Success, Parent_Told, Retry);
               Assert (Children.Current = Root, "a closed child was still the one working");
            end if;
         end if;
      end Ask;
   begin
      Parent_Told := Null_Unbounded_String;
      Parent_Status := E.Success;
      Assert (Children.May (Pm.Write_Source, "src/hello.adb"),
              "the root may not write where its task is");
      case Self.Plan is
         when Helped | Denied =>
            Ask ("required", Child_Done);
            Children.Note_Call ("read_file", "{""path"": ""src/hello.adb""}", "procedure");
         when Fails_Twice =>
            Ask ("required", Child_Fails);
            Assert (Retry, "a required child that failed was not run again");
            Ask ("required", Child_Fails, To_String (Id));
            Assert (not Retry, "a child was run again past the limit");
         when Fails_Then_Good =>
            Ask ("required", Child_Fails);
            Ask ("required", Child_Done, To_String (Id));
         when Optional_Fails =>
            Ask ("optional", Child_Fails);
            Assert (not Retry, "an optional child was run again");
         when Left_Open =>
            Ask ("required", Child_Done, Close => False);
         when Checks_First =>
            --  Before the file is written its check fails, and says why.
            Assert (Children.May_Check (Children.Task_Profile),
                    "an agent may not run its own task's checks");
            Assert (not Children.May_Check (""), "an agent may run no profile at all");
            declare
               Report : Unbounded_String;
               Ran    : E.Error_Info;
            begin
               Children.Run_Checks (Children.Task_Profile, Report, Ran);
               Assert (E.Is_Ok (Ran)
                       and then Ada.Strings.Fixed.Index (To_String (Report), "failed") > 0
                       and then Ada.Strings.Fixed.Index (To_String (Report), "exists") > 0,
                       "the checks' report does not say what failed: " & To_String (Report));
            end;
         when Out_Of_Time =>
            --  Bounded by the project's time, and stopped by it.
            Assert (Children.Time_Left > 0.0 and then Children.Time_Left <= 5.0,
                    "the work was not bounded by the project's time:"
                    & Duration'Image (Children.Time_Left));
            Answer := Null_Unbounded_String;
            Status := E.Make (E.Framework_Limit_Exceeded);
            E.Add_Text (Status, "name", "time");
            return;
         when Interrupted =>
            --  Stopped while its child works: both are cancelled.
            Ask ("required", Child_Done, Close => False);
            Children.Close_Child
              ("", 3, E.Make (E.Generation_Cancelled), Parent_Told, Retry);
            Assert (not Retry, "an interrupted child was run again");
            Answer := Null_Unbounded_String;
            Status := E.Make (E.Generation_Cancelled);
            return;
      end case;
      Children.Spend (5, Prompt_Tokens => 100);
      Run (Self, Prompt_Path, Project, Answer, Status);
   end Run_Parenting;

   --  A completed task answers for itself from the records alone -- why it
   --  could start among them -- and what of the state goes into Git is the
   --  project's policy, kept as the state's own .gitignore; Git is asked,
   --  not guessed, how the project stands.
   procedure Audit_Policy_And_Git
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : aliased S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      Id      : Unbounded_String;
      Done    : Wk.Report;
      Written : Boolean;
      Text    : Unbounded_String;

      function Answer (Lines : Model_Runner.Framework.Name_Lists.Vector; Question : String)
        return String is
      begin
         for Line of Lines loop
            if Line'Length > Question'Length + 1
              and then Line (Line'First .. Line'First + Question'Length) = Question & ":"
            then
               return Line (Line'First + Question'Length + 2 .. Line'Last);
            end if;
         end loop;
         return "";
      end Answer;

      function Ignore_File return String is
         File : Ada.Text_IO.File_Type;
      begin
         Text := Null_Unbounded_String;
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, S.Root (Store) & "/.gitignore");
         while not Ada.Text_IO.End_Of_File (File) loop
            Append (Text, Ada.Text_IO.Get_Line (File) & LF);
         end loop;
         Ada.Text_IO.Close (File);
         return To_String (Text);
      end Ignore_File;

      function Has (Whole, Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Whole, Part) > 0);
   begin
      Task_Project
        (Store, "audit",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF);
      Tk.Create (Store, Change, Fields ("Audited", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Execute (Store, To_String (Id),
                  Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                  Answer => To_Unbounded_String ("status: done" & LF & "summary: x"),
                                  Broken => False),
                  Cx.Profile (Store, ""), Done, Status);
      declare
         Said : constant Model_Runner.Framework.Name_Lists.Vector :=
           Wk.Audit (Store, To_String (Id));
      begin
         Assert (Has (Answer (Said, "why it could start"), "it was accepted and ready")
                 and then Has (Answer (Said, "why it could start"), "no agent held it")
                 and then Has (Answer (Said, "files changed"), "src/hello.adb")
                 and then Has (Answer (Said, "verification"), "passed")
                 and then Has (Answer (Said, "context"), "CTX-")
                 and then Has (Answer (Said, "completion"), "its gates passed"),
                 "the task did not answer for itself: " & Answer (Said, "why it could start"));
      end;

      --  The policy, kept.
      Model_Runner.Framework.Git.Keep_Policy (Store, Written, Status);
      Assert (E.Is_Ok (Status)
              and then Has (Ignore_File, "/runtime/") and then Has (Ignore_File, "/indexes/")
              and then not Has (Ignore_File, "/tasks/") and then not Has (Ignore_File, "/config/"),
              "the portable policy does not keep what travels and leave out what does not");
      Model_Runner.Framework.Git.Keep_Policy (Store, Written, Status);
      Assert (not Written, "an unchanged policy was written again");
      declare
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Revision : Natural;
      begin
         Changes.Include ("scalar.repository.state_policy", "local");
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
         Model_Runner.Framework.Git.Keep_Policy (Store, Written, Status);
         Assert (Written and then Has (Ignore_File, "*" & LF),
                 "the local policy does not keep the state out");
         Changes.Clear;
         Changes.Include ("scalar.repository.state_policy", "sometimes");
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
         Model_Runner.Framework.Git.Keep_Policy (Store, Written, Status);
         Assert (Status.Code = E.Framework_Schema_Violation, "a policy that is none was taken");
      end;

      --  Git, asked.
      declare
         Root     : constant String := Dirs.Full_Name (Fresh ("git-status"));
         Args     : Hostkit.String_Vectors.Vector;
         Exit_Code : Integer;
      begin
         Args.Append (To_Unbounded_String ("init"));
         Args.Append (To_Unbounded_String ("-q"));
         Args.Append (To_Unbounded_String (Root));
         if Hostkit.Process.Run ("git", Args, Exit_Code) and then Exit_Code = 0 then
            Put_File (Root & "/new.txt", "x");
            declare
               Said : constant Model_Runner.Framework.Git.Status_Report :=
                 Model_Runner.Framework.Git.Status_Of (Root);
            begin
               Assert (Said.Found and then Length (Said.Branch) > 0
                       and then Said.Changes.Contains ("?? new.txt"),
                       "Git's own view of the project was not read");
            end;
         end if;
      end;
      S.Close (Store);
   end Audit_Policy_And_Git;

   --  /work as typed in a session: by its identifier, and by words of its
   --  title, runs the task on the agent the session hands it.
   procedure Session_Work_Line_Runs_The_Task
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : S.Store;
      Status  : E.Error_Info;
      Change  : S.Transaction;
      First   : Unbounded_String;
      Second  : Unbounded_String;
      Catalog : aliased Model_Runner.Localization.Catalog;
      Screen  : Model_Runner.Presentation.Console;
      Before  : constant String := Dirs.Current_Directory;
      Report  : S.Recovery_Report;
      Agent   : constant Scripted_Agent :=
        (File => To_Unbounded_String ("src/hello.adb"),
         Answer => To_Unbounded_String ("status: done" & LF & "summary: x"),
         Broken => False);
   begin
      Model_Runner.Localization.Open (Catalog, Model_Runner.Platform.Catalog_Path, "en");
      Model_Runner.Presentation.Open
        (Screen, Catalog'Unchecked_Access, Model_Runner.CLI.Options.Color_Never,
         (Output_Is_Terminal => False, Error_Is_Terminal => False,
          Input_Is_Terminal  => False, Colour_Suppressed => True),
         Model_Runner.CLI.Options.Quiet);
      Task_Project
        (Store, "session-work",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF);
      Tk.Create (Store, Change, Fields ("Greet the world", "analysis"), "user", "", First, Status);
      Tk.Create (Store, Change, Fields ("Count the stars", "analysis"), "user", "", Second, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (First), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Second), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      declare
         Root : constant String := Fresh_Root (Store);
      begin
         S.Close (Store);
         Dirs.Set_Directory (Root);
         Model_Runner.CLI.Project_Commands.Run
           ("/work " & To_String (First), Screen, Agent);
         Model_Runner.CLI.Project_Commands.Run ("/work count the stars", Screen, Agent);
         Dirs.Set_Directory (Before);
         S.Open (Store, Root, Report, Status);
      exception
         when others =>
            Dirs.Set_Directory (Before);
            raise;
      end;
      Assert (Tk.State_Of (Store, To_String (First)) = "complete",
              "/work by identifier did not run the task: " & Tk.State_Of (Store, To_String (First)));
      Assert (Tk.State_Of (Store, To_String (Second)) = "complete",
              "/work by title did not run the task: " & Tk.State_Of (Store, To_String (Second)));
      S.Close (Store);
   end Session_Work_Line_Runs_The_Task;

   --  The context says what the task's files declare and which tests bear
   --  on it; after an attempt whose verification failed, what that attempt
   --  left. And work is bounded in time: past it, the task is set aside,
   --  not failed.
   procedure Context_Carries_Symbols_Tests_And_Results
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Id     : Unbounded_String;
      Built  : Cx.Built;
      Done   : Wk.Report;

      function Holds (Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Cx.Rendered (Built), Part) > 0);
   begin
      Task_Project
        (Store, "context-more",
         "set execution.allowed = test" & LF
         & "scalar agents.max_seconds = 5" & LF);
      declare
         Changes  : Cf.Value_Maps.Map;
         Planned  : Cf.Change_Plan;
         Revision : Natural;
      begin
         Changes.Include ("profile.tests", "exists: test -f no-such-file");
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
      end;
      Dirs.Create_Path (Fresh_Root (Store) & "/src");
      Dirs.Create_Path (Fresh_Root (Store) & "/tests");
      Put_File (Fresh_Root (Store) & "/src/parser.ads",
                "package Parser is" & LF & "   procedure Next_Token;" & LF & "end Parser;" & LF);
      Put_File (Fresh_Root (Store) & "/tests/parser_tests.adb",
                "procedure Parser_Tests is begin null; end Parser_Tests;" & LF);
      Tk.Create (Store, Change, Fields ("Parse", "implementation", "component", "parser"),
                 "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);

      Cx.Build (Store, To_String (Id), Cx.Profile (Store, ""), Built, Status);
      Assert (E.Is_Ok (Status) and then Holds ("What its files declare")
              and then Holds ("Parser.Next_Token")
              and then Holds ("The tests that bear on it")
              and then Holds ("tests/parser_tests.adb"),
              "the context does not say what the files declare or which tests bear on them");
      Assert (not Holds ("What the last attempt left"), "a first attempt was told of a last");

      --  An attempt whose verification fails; the next is told why.
      Wk.Execute (Store, To_String (Id),
                  Scripted_Agent'(File => To_Unbounded_String ("src/parser.adb"),
                                  Answer => To_Unbounded_String
                                    ("status: done" & LF & "summary: tried"),
                                  Broken => False),
                  Cx.Profile (Store, ""), Done, Status);
      Assert (To_String (Done.Final_State) = "failed", "the failing attempt did not fail");
      Cx.Build (Store, To_String (Id), Cx.Profile (Store, ""), Built, Status);
      Assert (Holds ("What the last attempt left") and then Holds ("did not pass")
              and then Holds ("tried"),
              "a retry was not told what the last attempt left");

      --  Out of time: set aside.
      Tk.Create (Store, Change, Fields ("Slow", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Execute (Store, To_String (Id), Scripted_Parent'(Plan => Out_Of_Time),
                  Cx.Profile (Store, ""), Done, Status);
      Assert (To_String (Done.Final_State) = "blocked"
              and then To_String (Done.Reason) = "its work ran out of time",
              "work out of time was not set aside: " & To_String (Done.Final_State) & " "
              & To_String (Done.Reason));
      S.Close (Store);
   end Context_Carries_Symbols_Tests_And_Results;

   --  A working agent's children are made by the harness within what the
   --  agent was given, each with a context and budget of its own; their
   --  results are kept and their parent told of them; a required child that
   --  fails is run again once, and if it still fails -- or is left open --
   --  the task cannot complete, while an optional one's failure does not
   --  matter; a project that gives no children refuses them; and cancelling
   --  a task cancels its agent's children.
   procedure Children_Work_Within_Their_Parent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Done   : Wk.Report;
      Checks : constant String :=
        "set execution.allowed = test" & LF & "set execution.allowed = touch" & LF
        & "profile checks = exists: test -f src/hello.adb; stamp: touch src/stamp.ads" & LF
        & "scalar verification.default = checks" & LF;

      function Contains (Text, Part : String) return Boolean
      is (Ada.Strings.Fixed.Index (Text, Part) > 0);

      procedure Work (Plan : Parent_Plan) is
         Id : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields (Parent_Plan'Image (Plan), "analysis"), "user", "",
                    Id, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id), Scripted_Parent'(Plan => Plan),
                     Cx.Profile (Store, ""), Done, Status);
         Assert (E.Is_Ok (Status), "work with children failed outright: " & Code_Of (Status));
      end Work;
   begin
      Task_Project (Store, "children", Checks);

      Work (Helped);
      Assert (To_String (Done.Final_State) = "complete",
              "a task whose child helped did not complete: " & To_String (Done.Reason));
      Assert (Natural (Done.Children.Length) = 1
              and then Contains (Done.Children.First_Element, "completed")
              and then Contains (Done.Children.First_Element, "RES-"),
              "the child's result was not kept");
      Assert (Contains (To_String (Parent_Told), "done")
              and then Contains (To_String (Parent_Told), "it is fine")
              and then not Contains (To_String (Parent_Told), "look at hello"),
              "the parent was not told the child's result, or was told more");

      --  Each agent's call is on record: the child's with a manifest of its
      --  own, the calls it made, and what it used.
      declare
         Root_Call  : R.Item;
         Child_Call : R.Item;
         Read       : E.Error_Info;
      begin
         S.Read (Store, Model_Runner.Framework.Invocations_Area,
                 To_String (Done.Invocation_Id), Root_Call, Read);
         Assert (E.Is_Ok (Read)
                 and then R.Get (Root_Call, "prompt_tokens") = "100"
                 and then R.Get (Root_Call, "output_tokens") = "5",
                 "the root's call does not say what it used: "
                 & R.Get (Root_Call, "prompt_tokens") & "/"
                 & R.Get (Root_Call, "output_tokens"));
         for Name of S.Names (Store, Model_Runner.Framework.Invocations_Area) loop
            if Name /= To_String (Done.Invocation_Id) and then Name'Length > 4
              and then Name (Name'First .. Name'First + 3) = "INV-"
            then
               S.Read (Store, Model_Runner.Framework.Invocations_Area, Name, Child_Call, Read);
            end if;
         end loop;
         Assert (R.Get (Child_Call, "result_contract") = "child_result"
                 and then R.Get (Child_Call, "state") = "completed"
                 and then R.Get (Child_Call, "context_manifest") /= ""
                 and then R.Get (Child_Call, "output_tokens") = "10",
                 "the child's call was not recorded with its own manifest");
         Assert (Contains (R.Get (Root_Call, "call.0001"), "read_file"),
                 "the root's tool call was not recorded on its call");
      end;

      Work (Fails_Twice);
      Assert (To_String (Done.Final_State) = "blocked"
              and then Contains (To_String (Done.Reason), "failed")
              and then Natural (Done.Children.Length) = 2,
              "a required child that failed twice did not hold its parent: "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));

      Work (Fails_Then_Good);
      Assert (To_String (Done.Final_State) = "complete",
              "a child made good on its second run still held its parent: "
              & To_String (Done.Reason));

      Work (Optional_Fails);
      Assert (To_String (Done.Final_State) = "complete",
              "an optional child's failure failed its parent: " & To_String (Done.Reason));

      Work (Left_Open);
      Assert (To_String (Done.Final_State) = "blocked"
              and then Contains (Done.Children.First_Element, "failed")
              and then Contains (Done.Children.First_Element, "stopped before"),
              "a child left open went missing: " & To_String (Done.Reason));

      Dirs.Delete_File (Fresh_Root (Store) & "/src/hello.adb");
      Work (Checks_First);
      Assert (To_String (Done.Final_State) = "complete",
              "a task that ran its checks first did not complete: " & To_String (Done.Reason));
      Assert (Done.Changed_Files.Contains ("src/hello.adb")
              and then not Done.Changed_Files.Contains ("src/stamp.ads"),
              "what the checks wrote was put on the agent");

      Work (Interrupted);
      Assert (To_String (Done.Final_State) = "blocked"
              and then Contains (To_String (Done.Reason), "cancelled")
              and then Iv.State_Of (Store, To_String (Done.Invocation_Id)) = "cancelled"
              and then Contains (Done.Children.First_Element, "cancelled"),
              "an interrupted run was not recorded as cancelled: "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      declare
         Held : Ag.Agent;
      begin
         Ag.Read (Store, To_String (Done.Agent_Id), Held, Status);
         Assert (To_String (Held.Status) = "cancelled", "the interrupted agent was not cancelled");
      end;

      --  Cancelling a task cancels what its agent made.
      declare
         Id    : Unbounded_String;
         Root  : Unbounded_String;
         Child : Unbounded_String;
         Held  : Ag.Agent;
      begin
         Tk.Create (Store, Change, Fields ("Cancelled", "analysis"), "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         Ag.Start_Root (Store, Change, To_String (Id), "worker", "analysis", Root, Status);
         S.Commit (Store, Change, Status);
         Ag.Spawn_Child (Store, Change, To_String (Root), "reviewer", Ag.Required,
                         Pm.Unrestricted, 100, Child, Status);
         Ls.Acquire (Store, Change, "task." & To_String (Id), To_String (Root), 3600, Status);
         Tk.Move (Store, Change, To_String (Id), "running", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Cancel (Store, To_String (Id), Status);
         Ag.Read (Store, To_String (Child), Held, Status);
         Assert (To_String (Held.Status) = "cancelled",
                 "a cancelled task left its agent's child going: " & To_String (Held.Status));
      end;
      S.Close (Store);

      --  A project that gives no children refuses them, and the work goes on.
      Task_Project
        (Store, "no-children",
         Checks & "map permission.project.read_source =" & LF
         & "map permission.project.write_source =" & LF
         & "map permission.project.run_tests =" & LF);
      Work (Denied);
      Assert (Parent_Status.Code = E.Framework_Permission_Denied
              and then To_String (Done.Final_State) = "complete"
              and then Done.Children.Is_Empty,
              "a child was made where the project gives none: " & Code_Of (Parent_Status));
      S.Close (Store);
   end Children_Work_Within_Their_Parent;

   ---------------------------------------------------------------------------
   --  Orchestration.
   ---------------------------------------------------------------------------

   package Or_ch renames Model_Runner.Framework.Orchestration;

   --  Events are acted on once, by the rules, without a model; dispatch
   --  starts the most important ready tasks that fit, one writer to a
   --  component; and what needs judgment is listed.
   procedure Orchestration_Is_Routine
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Req    : Unbounded_String;
      Ids    : array (1 .. 4) of Unbounded_String;
      Done   : Or_ch.Step_Report;
      Plan   : Or_ch.Dispatch_Plan;
      Given  : Tk.Field_Map;
   begin
      Task_Project (Store, "orchestration", "scalar agents.max_active = 2" & LF);
      Assert (Natural (Or_ch.Rules (Store).Length) = 5,
              "a project that says nothing did not get the rules it needs");

      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);

      Or_ch.Step (Store, Done, Status);
      Assert (E.Is_Ok (Status) and then Done.Events_Seen > 0
              and then Natural (Done.Derived.Length) = 1,
              "an accepted requirement's event did not derive its task: "
              & Code_Of (Status));
      --  The second step reads what the first one did, and derives
      --  nothing again; a third has nothing left to read.
      Or_ch.Step (Store, Done, Status);
      Assert (Done.Derived.Is_Empty, "a step run twice derived twice");
      Or_ch.Step (Store, Done, Status);
      Assert (Done.Events_Seen = 0, "a step read events that were read already");

      --  Four ready tasks; two slots; two of them write one component.
      for Index in Ids'Range loop
         Given := Fields ("Work" & Integer'Image (Index), "implementation", "component",
                          (if Index <= 2 then "parser" else "io" & Integer'Image (Index)));
         Given.Include ("priority", (if Index = 2 then "9" else "1"));
         Tk.Create (Store, Change, Given, "user", "", Ids (Index), Status);
      end loop;
      S.Commit (Store, Change, Status);
      for Index in Ids'Range loop
         Tk.Move (Store, Change, To_String (Ids (Index)), "accepted", "", Status => Status);
      end loop;
      S.Commit (Store, Change, Status);

      Or_ch.Step (Store, Done, Status);
      Assert (Natural (Done.Became_Ready.Length) = 4,
              "readiness was not worked out by the step");
      Plan := Or_ch.Plan (Store);
      Assert (Plan.Slots = 2 and then Natural (Plan.Start.Length) = 2
              and then Plan.Start.First_Element = To_String (Ids (2)),
              "dispatch did not start the most important tasks that fit");
      Assert (not Plan.Start.Contains (To_String (Ids (1))),
              "two tasks writing one component were started together");
      Assert (not Plan.Held.Is_Empty, "the tasks held back were not said");

      declare
         Waiting : constant Model_Runner.Framework.Name_Lists.Vector :=
           Or_ch.Needs_Judgment (Store);
         Found   : Boolean := False;
      begin
         for Line of Waiting loop
            Found := Found or else Ada.Strings.Fixed.Index (Line, "candidate") > 0;
         end loop;
         Assert (Found, "the derived candidate was not listed for judgment");
      end;
      S.Close (Store);
   end Orchestration_Is_Routine;

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
        (T, Orchestration_Is_Routine'Access,
         "routine progression is rule-driven, once, and dispatched by"
         & " resources");
      Register_Routine
        (T, Permissions_Only_Narrow'Access,
         "permissions are scoped and every level only narrows");
      Register_Routine
        (T, Recursion_Stays_Bounded'Access,
         "children stay within limits and permissions, failures and"
         & " cancellation are seen");
      Register_Routine
        (T, Audit_Policy_And_Git'Access,
         "a task answers for itself, the repository policy is kept, Git is asked");
      Register_Routine
        (T, Session_Work_Line_Runs_The_Task'Access,
         "/work typed in a session runs the task by identifier or by title");
      Register_Routine
        (T, Context_Carries_Symbols_Tests_And_Results'Access,
         "the context carries symbols, tests and the last attempt, and work is bounded in time");
      Register_Routine
        (T, Claims_And_Gates'Access,
         "an agent's claims are proposals, and the gates a project names are kept");
      Register_Routine
        (T, Intent_Is_Managed_And_Components_Held'Access,
         "intent is managed without a model, and a component is held while written");
      Register_Routine
        (T, Schemas_Retention_Adapter_And_Slots'Access,
         "schemas migrate, results retire, the adapter traces derivation, slots bound work");
      Register_Routine
        (T, State_Machine_And_Graph_Properties'Access,
         "the lifecycle and dependency graphs keep their invariants, generated");
      Register_Routine
        (T, Components_Checks_And_Evidence'Access,
         "components are checked, checks keep their options, evidence says what it ran with");
      Register_Routine
        (T, Tasks_Are_Revised_Split_And_Reopened'Access,
         "tasks are revised, split and reopened, and their kind and authority reach them");
      Register_Routine
        (T, Verification_Follows_What_Changed'Access,
         "how widely work is verified follows what it changed and the policy");
      Register_Routine
        (T, Consistency_Sees_Components_And_Readiness'Access,
         "the consistency check sees missing components and false readiness");
      Register_Routine
        (T, Configuration_Changes_Explicitly'Access,
         "the configuration changes by an explicit, validated, recorded revision");
      Register_Routine
        (T, Opening_Recovers'Access,
         "opening a project puts right what an interruption left");
      Register_Routine
        (T, Permissions_And_Proposals_Reach_The_Work'Access,
         "a task narrows its agent, and proposed work becomes candidates where permitted");
      Register_Routine
        (T, Children_Work_Within_Their_Parent'Access,
         "a working agent's children are made, run and answered for by the harness");
      Register_Routine
        (T, Writes_Stay_In_Bounds'Access,
         "an agent writing where it may not fails its task");
      Register_Routine
        (T, Impact_Is_Traced'Access,
         "a change is traced to what it reaches, and the tests widen with"
         & " doubt");
      Register_Routine
        (T, Workspaces_Isolate_And_Integrate'Access,
         "workspace work is isolated, integrated by right, and verified after");
      Register_Routine
        (T, Work_Runs_A_Task_Through'Access,
         "one task runs from ready through verification to where it ends");
      Register_Routine
        (T, Work_Runs_With_A_Given_Agent'Access,
         "the work command runs a task on the agent it is handed");
      Register_Routine
        (T, Execution_Follows_Policy'Access,
         "only what the policy allows is run, directly, and its output kept");
      Register_Routine
        (T, Diagnostics_Are_Normalized'Access,
         "diagnostics and a profile's checks are read out of text");
      Register_Routine
        (T, Completion_Needs_Current_Evidence'Access,
         "a task completes by its gates and a requirement verifies by current"
         & " evidence");
      Register_Routine
        (T, Contexts_Are_Budgeted'Access,
         "a context is budgeted by priority, deduplicated and reproducible");
      Register_Routine
        (T, Invocations_Are_Recorded'Access,
         "a model call is recorded once ended and its answer held to a"
         & " contract");
      Register_Routine
        (T, Repository_Is_Scanned'Access,
         "a scan finds files, units, symbols and references, and says how");
      Register_Routine
        (T, Derivation_Is_Idempotent'Access,
         "a requirement derives its task once, however often derivation"
         & " runs");
   end Register_Tests;

end Tests.Framework_Cases;
