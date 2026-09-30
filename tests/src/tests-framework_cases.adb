with Ada.Calendar;
with Model_Runner.Platform.Signals;
with Ada.Text_IO;
with GNAT.OS_Lib;
with Hostkit;
with Interfaces;
with Ada.Environment_Variables;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Model_Runner.Cancellation;
with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Intents;
with Model_Runner.CLI.Options;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.CLI.Project_Requests;
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
with Model_Runner.Tools.Builtin;
with Model_Runner.Framework.Identifiers;
with Model_Runner.Framework.Indexes;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Invocations;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Repository.Languages;
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
with Hostkit.Fs;
with Hostkit.Pty;
with Hostkit.Spawn;
with Hostkit.Terminal_Control;
with Hostkit.Terminal_Control.Differences;
with Hostkit.Descriptors;
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

   --  One run apart, as a process of its own is: it says what it used
   --  where the harness reads it.
   type Accounting_Agent is new Scripted_Agent with record
      Usage : Unbounded_String;
   end record;

   overriding procedure Run
     (Self        : Accounting_Agent;
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

   --  Remove a directory and what is in it, a link as a link: Delete_Tree
   --  follows a link a case left behind into what it points at.
   procedure Remove_Tree (Path : String) is
      Search : Dirs.Search_Type;
      Found  : Dirs.Directory_Entry_Type;
      Names  : Model_Runner.Framework.Name_Lists.Vector;
   begin
      if Hostkit.Fs.Is_Link (Path) then
         Assert (Hostkit.Fs.Delete_Link (Path), "a link stays: " & Path);
         return;
      elsif not Dirs.Exists (Path) then
         return;
      elsif Dirs."/=" (Dirs.Kind (Path), Dirs.Directory) then
         Dirs.Delete_File (Path);
         return;
      end if;
      Dirs.Start_Search (Search, Path, "");
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Found);
         if Dirs.Simple_Name (Found) not in "." | ".." then
            Names.Append (Dirs.Simple_Name (Found));
         end if;
      end loop;
      Dirs.End_Search (Search);
      for Name of Names loop
         Remove_Tree (Path & "/" & Name);
      end loop;
      Dirs.Delete_Directory (Path);
   end Remove_Tree;

   --  A project directory made anew, whatever was there.
   function Fresh (Leaf : String) return String is
      Path : constant String := Scratch & "/" & Leaf;
   begin
      Remove_Tree (Path);
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

   --  A whole file, or nothing when it is not there.
   function Read_Whole (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      if not Dirs.Exists (Path) then
         return "";
      end if;
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      declare
         Text : String (1 .. Natural (Ada.Streams.Stream_IO.Size (File)));
      begin
         String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
         Ada.Streams.Stream_IO.Close (File);
         return Text;
      end;
   end Read_Whole;

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
          Confidence => Model_Runner.Framework.Facts.Certain,
          Origin     => <>),
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

      --  Marked and not finished, then another change in the same session:
      --  the first is finished before the second is staged over it.
      declare
         Other  : S.Transaction;
         Second : S.Transaction;
         More   : R.Item := R.Create ("project.fact", 1, "FACT-BUILD", 1);
         Again  : R.Item := R.Create ("project.fact", 1, "FACT-TARGET", 1);
      begin
         R.Set (More, "key", "build");
         R.Set (More, "value", "alire");
         R.Set (More, "source", "explicit");
         R.Set (More, "confidence", "authoritative");
         S.Put (Other, F.Project_Area, "fact.build", More);
         S.Stage (Store, Other, Status);
         S.Mark (Store, Status);
         R.Set (Again, "key", "target");
         R.Set (Again, "value", "native");
         R.Set (Again, "source", "explicit");
         R.Set (Again, "confidence", "authoritative");
         S.Put (Second, F.Project_Area, "fact.target", Again);
         S.Commit (Store, Second, Status);
         Assert (E.Is_Ok (Status)
                 and then S.Exists (Store, F.Project_Area, "fact.build")
                 and then S.Exists (Store, F.Project_Area, "fact.target"),
                 "a marked change was wiped by the next commit: " & Code_Of (Status));
      end;

      --  Finishing again finds nothing to do.
      S.Finish (Store, Status);
      Assert (E.Is_Ok (Status), "finishing twice failed");

      --  Marked, and a record it installs cut short -- as a machine that
      --  went down before it was on the device leaves it: not installed.
      declare
         Torn  : S.Transaction;
         Value : R.Item := R.Create ("project.fact", 1, "FACT-TORN", 1);
      begin
         R.Set (Value, "key", "torn");
         R.Set (Value, "value", "x");
         R.Set (Value, "source", "explicit");
         R.Set (Value, "confidence", "authoritative");
         S.Put (Torn, F.Project_Area, "fact.torn", Value);
         S.Stage (Store, Torn, Status);
         S.Mark (Store, Status);
         Put_File (S.Root (Store) & "/runtime/journal/op-000001.rec", "model_runner-re");
         S.Close (Store);
         S.Open (Store, Project, Report, Status);
         Assert (Status.Code = E.Framework_Recovery_Required,
                 "a record cut short was installed: " & Code_Of (Status));
      end;
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
     & "name = A Language" & LF & "description = D" & LF
     & "version = 3" & LF
     & "language = Lang" & LF
     & "fact language = Lang_2022" & LF
     & "set tags = lang" & LF
     & "list verify.steps = compile" & LF
     & "scalar build.command = make" & LF
     & "directory src" & LF;

   Tool_Text : constant String :=
     "template = tool" & LF
     & "name = A Build Tool" & LF & "description = D" & LF
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
      Tp.Add (Registry, Parsed ("template = clash" & LF & "name = C" & LF & "description = D" & LF
                                & "version = 1" & LF & "includes = lang" & LF
                                & "scalar build.command = other" & LF));
      Tp.Compose (Registry, "clash", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Conflict,
              "two values for one scalar composed: " & Code_Of (Status));

      --  Override wins whichever comes first; two overrides disagree.
      declare
         Holding : Tp.Registry;
         Made    : Tp.Composition;
      begin
         Tp.Add (Holding, Parsed ("template = first" & LF & "name = F" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "override scalar k = strong" & LF));
         Tp.Add (Holding, Parsed ("template = second" & LF & "name = S" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "scalar k = weak" & LF));
         Tp.Add (Holding, Parsed ("template = both" & LF & "name = B" & LF & "description = D" & LF & "version = 1" & LF
                                  & "includes = first, second" & LF));
         Tp.Compose (Holding, "both", Made, Status);
         Assert (E.Is_Ok (Status), "an override met first was taken for a conflict: "
                 & Code_Of (Status));
         Tp.Add (Holding, Parsed ("template = rival" & LF & "name = R" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "override scalar k = other" & LF));
         Tp.Add (Holding, Parsed ("template = rivals" & LF & "name = RR" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "includes = first, rival" & LF));
         Tp.Compose (Holding, "rivals", Made, Status);
         Assert (Status.Code = E.Framework_Template_Conflict,
                 "two overrides that disagree composed: " & Code_Of (Status));
         --  Two that disagree, and an override after them: the override is
         --  what they compose to, whatever order they came in.
         Tp.Add (Holding, Parsed ("template = third" & LF & "name = T" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "scalar k = middling" & LF));
         Tp.Add (Holding, Parsed ("template = trio" & LF & "name = T3" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "includes = second, third, first" & LF));
         Tp.Compose (Holding, "trio", Made, Status);
         Assert (E.Is_Ok (Status), "an override after two that disagree was a conflict: "
                 & Code_Of (Status));
      end;

      Tp.Add (Registry, Parsed ("template = loop-a" & LF & "name = A" & LF & "description = D" & LF
                                & "version = 1" & LF & "includes = loop-b"
                                & LF));
      Tp.Add (Registry, Parsed ("template = loop-b" & LF & "name = B" & LF & "description = D" & LF
                                & "version = 1" & LF & "includes = loop-a"
                                & LF));
      Tp.Compose (Registry, "loop-a", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a template including itself composed");

      Tp.Add (Registry, Parsed ("template = lonely" & LF & "name = L" & LF & "description = D" & LF
                                & "version = 1" & LF & "includes = absent"
                                & LF));
      Tp.Compose (Registry, "lonely", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Not_Found,
              "a template including one that is not there composed");
      Tp.Compose (Registry, "nobody", Composed, Status);
      Assert (Status.Code = E.Framework_Template_Not_Found,
              "a template that is not there composed");

      Tp.Parse ("template = x" & LF & "name = X" & LF & "description = D" & LF & "version = 1" & LF
                & "colour blue = yes" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a line nobody understands was read");
      Tp.Parse ("name = X" & LF & "version = 1" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a template that does not say which it is was read");
      Tp.Parse ("template = x" & LF & "name = X" & LF & "version = 1" & LF, "memory", Value,
                Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a template that does not say what it is for was read");
      Tp.Parse ("template = x" & LF & "name = X" & LF & "description = D" & LF & "version = 1" & LF
                & "file ../outside = no" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a file outside the project was declared");
      Tp.Parse ("template = x" & LF & "name = X" & LF & "description = D" & LF & "version = 1" & LF
                & "baseline tests = yes" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a baseline of neither the project nor its language was declared");

      --  Every keyed kind merges by the same rule: two templates that give
      --  one key two values, and neither says override, do not compose --
      --  a map, an adapter, a profile, a task kind, a schema, an input.
      declare
         procedure Clash (Word, Key, One, Two : String) is
            Holding : Tp.Registry;
            Made    : Tp.Composition;
         begin
            Tp.Add (Holding, Parsed ("template = a" & LF & "name = A" & LF & "description = D" & LF
                                     & "version = 1" & LF & Word & " " & Key & " = " & One & LF));
            Tp.Add (Holding, Parsed ("template = b" & LF & "name = B" & LF & "description = D" & LF
                                     & "version = 1" & LF & Word & " " & Key & " = " & Two & LF));
            Tp.Add (Holding, Parsed ("template = both" & LF & "name = AB" & LF & "description = D"
                                     & LF & "version = 1" & LF & "includes = a, b" & LF));
            Tp.Compose (Holding, "both", Made, Status);
            Assert (Status.Code = E.Framework_Template_Conflict,
                    "two values for one " & Word & " composed: " & Code_Of (Status));
         end Clash;
         Holding : Tp.Registry;
         Made    : Tp.Composition;
      begin
         Clash ("map", "permission.kind.x.read_source", "roots=src/", "roots=lib/");
         Clash ("adapter", "build", "alire", "make");
         Clash ("profile", "tests", "run: make test", "run: alr test");
         Clash ("task_kind", "review", "notes?", "component?");
         Clash ("schema", "task_field.verdict", "choice pass|fail", "text");
         Tp.Add (Holding, Parsed ("template = a" & LF & "name = A" & LF & "description = D" & LF
                                  & "version = 1" & LF & "input x" & LF & "  type = text" & LF));
         Tp.Add (Holding, Parsed ("template = b" & LF & "name = B" & LF & "description = D" & LF
                                  & "version = 1" & LF & "input x" & LF & "  type = identifier"
                                  & LF));
         Tp.Add (Holding, Parsed ("template = both" & LF & "name = AB" & LF & "description = D" & LF
                                  & "version = 1" & LF & "includes = a, b" & LF));
         Tp.Compose (Holding, "both", Made, Status);
         Assert (Status.Code = E.Framework_Template_Conflict,
                 "an input declared two ways composed: " & Code_Of (Status));
      end;

      --  Two files that are one once the inputs are in, with different
      --  text, are a conflict.
      declare
         Holding : Tp.Registry;
         Made    : Tp.Composition;
         Planned : Cf.Plan;
         Given   : Cf.Value_Maps.Map;
      begin
         Tp.Add (Holding, Parsed ("template = clashing" & LF & "name = C" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "input x" & LF & "  type = text" & LF & "  required = true" & LF
                                  & "file src/${x}.adb = one" & LF
                                  & "file src/main.adb = two" & LF));
         Tp.Compose (Holding, "clashing", Made, Status);
         Given.Include ("x", "main");
         Cf.Prepare (Made, Fresh ("file-clash"), Given, Planned, Status);
         Assert (Status.Code = E.Framework_Template_Conflict,
                 "two files the same once the inputs were in were written over each other: "
                 & Code_Of (Status));
      end;

      --  The agent command's prompt marker is no input, and passes through.
      declare
         Holding : Tp.Registry;
         Made    : Tp.Composition;
         Planned : Cf.Plan;
         Given   : Cf.Value_Maps.Map;
      begin
         Tp.Add (Holding, Parsed ("template = agent" & LF & "name = A" & LF
                                  & "description = D" & LF & "version = 1" & LF
                                  & "scalar work.agent = my-agent ${prompt}" & LF));
         Tp.Compose (Holding, "agent", Made, Status);
         Cf.Prepare (Made, Fresh ("agent-marker"), Given, Planned, Status);
         Assert (E.Is_Ok (Status)
                 and then R.Get (Planned.Configuration, "scalar.work.agent") = "my-agent ${prompt}",
                 "a template's agent command lost its prompt marker: " & Code_Of (Status));
      end;
      Tp.Parse ("template = x" & LF & "name = X" & LF & "description = D" & LF & "version = 1" & LF
                & "baseline tests = yes" & LF, "memory", Value, Status);
      Assert (Status.Code = E.Framework_Template_Invalid,
              "a baseline of neither the project nor its language was declared");
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

      --  Rules beyond an input's type: a range, a length, a pattern.
      declare
         Ruled   : Tp.Template;
         Checked : E.Error_Info;
         Holding : Tp.Registry;
         Made    : Tp.Composition;
      begin
         Tp.Parse ("template = r" & LF & "name = R" & LF & "description = D" & LF & "version = 1" & LF
                   & "input port" & LF & "  type = natural" & LF
                   & "  minimum = 1024" & LF & "  maximum = 65535" & LF
                   & "input tag" & LF & "  type = text" & LF & "  max_length = 8" & LF
                   & "  pattern = v*.*" & LF, "memory", Ruled, Status);
         Assert (E.Is_Ok (Status), "input rules were not read: " & Code_Of (Status));
         Tp.Add (Holding, Ruled);
         Tp.Compose (Holding, "r", Made, Status);
         Cf.Check_Input (Tp.Input_At (Made, 1), "80", Checked);
         Assert (Checked.Code = E.Framework_Input_Invalid, "a number out of range was taken");
         Cf.Check_Input (Tp.Input_At (Made, 1), "8080", Checked);
         Assert (E.Is_Ok (Checked), "a number in range was refused");
         Cf.Check_Input (Tp.Input_At (Made, 2), "v1.2", Checked);
         Assert (E.Is_Ok (Checked), "a value matching the pattern was refused");
         Cf.Check_Input (Tp.Input_At (Made, 2), "1.2", Checked);
         Assert (Checked.Code = E.Framework_Input_Invalid, "a value off the pattern was taken");
         Cf.Check_Input (Tp.Input_At (Made, 2), "v1.2.3.4.5", Checked);
         Assert (Checked.Code = E.Framework_Input_Invalid, "a value too long was taken");

         --  Choices the project provides: its directories, nothing hidden.
         declare
            Where    : constant String := Fresh ("provided");
            Offering : Tp.Template;
            Holding2 : Tp.Registry;
            Made2    : Tp.Composition;
         begin
            Dirs.Create_Path (Where & "/src");
            Dirs.Create_Path (Where & "/lib");
            Dirs.Create_Path (Where & "/.git");
            Tp.Parse ("template = p" & LF & "name = P" & LF & "description = D" & LF & "version = 1" & LF
                      & "input root" & LF & "  type = text" & LF
                      & "  provider = directories" & LF, "memory", Offering, Status);
            Tp.Add (Holding2, Offering);
            Tp.Compose (Holding2, "p", Made2, Status);
            declare
               Given : constant Tp.Input_Declaration :=
                 Cf.Resolved (Tp.Input_At (Made2, 1), Where);
            begin
               Assert (To_String (Given.Choices) = "lib, src",
                       "an input's provider did not offer the project's directories: "
                       & To_String (Given.Choices));
               Cf.Check_Input (Given, "docs", Checked);
               Assert (Checked.Code = E.Framework_Input_Invalid,
                       "a value none of the provided choices was taken");
            end;
            Tp.Parse ("template = q" & LF & "name = Q" & LF & "description = D" & LF & "version = 1" & LF
                      & "input root" & LF & "  provider = elsewhere" & LF, "memory", Offering,
                      Status);
            Assert (Status.Code = E.Framework_Template_Invalid,
                    "a provider nobody knows was taken");
         end;
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
      Tp.Add (First, Parsed ("template = t" & LF & "name = T" & LF & "description = D" & LF
                             & "version = 1" & LF & "scalar a = 1" & LF
                             & "set s = x" & LF & "set s = y" & LF));
      Tp.Parse ("template = t" & LF & "name = T" & LF & "description = D" & LF & "version = 1" & LF
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
      Tp.Add (Registry, Parsed ("template = t" & LF & "name = T" & LF & "description = D" & LF
                                & "version = 1" & LF
                                & "scalar build.command = make" & LF
                                & "baseline project.tests = a change comes with its test" & LF
                                & "baseline language.ada.style = style checks are clean" & LF));
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
      Assert (Au.Count (Au.Gather (Store)) = 4,
              "the decision, the setting and the baselines were not all gathered");
      declare
         use type Au.Level;
         Resolved : constant Au.Resolution := Au.Resolve (Au.Gather (Store));
         Found    : Boolean;
         Also     : Boolean;
         Project  : constant Au.Statement := Au.Governing (Resolved, "tests", Found);
         Language : constant Au.Statement := Au.Governing (Resolved, "ada.style", Also);
      begin
         Assert (Found and then Also and then Project.Standing = Au.Project_Baseline
                 and then Language.Standing = Au.Language_Baseline
                 and then To_String (Language.Value) = "style checks are clean",
                 "a baseline does not stand at its level");
      end;

      Findings := Cn.Check (Store);
      Assert (Conflicted, "a decision contradicting the configuration without"
              & " saying so was not found");

      Nt.Govern (Store, Change, Nt.Decision, To_String (Id),
                  "scalar.build.command", "alr build", "CONFIG", Status);
      S.Commit (Store, Change, Status);
      Findings := Cn.Check (Store);
      Assert (not Conflicted, "an explicit override was reported as a conflict");

      --  A person's instruction outranks the decision while it stands, and
      --  says which it overrides; withdrawn, the decision governs again.
      declare
         use type Au.Level;
         Given : Unbounded_String;
         First : Unbounded_String;
         Found : Boolean;
      begin
         Au.Instruct (Store, Change, "scalar.build.command", "alr build --release",
                      To_String (Id), "user tester", Given, Status);
         S.Commit (Store, Change, Status);
         Assert (E.Is_Ok (Status)
                 and then Au.Governing (Au.Resolve (Au.Gather (Store)), "scalar.build.command", Found)
                          .Standing = Au.Human_Instruction
                 and then Natural (Au.Standing_Instructions (Store).Length) = 1,
                 "a standing instruction did not govern: " & Code_Of (Status));
         Findings := Cn.Check (Store);
         Assert (not Conflicted, "an instruction naming what it overrides was a conflict");
         First := Given;
         Au.Instruct (Store, Change, "", "x", "", "user", Given, Status);
         Assert (Status.Code = E.Framework_Input_Missing, "an instruction about nothing was given");
         Change := S.No_Changes;
         Au.Withdraw (Store, Change, To_String (Given), "user tester", Status);
         Assert (Status.Code = E.Framework_Not_Found, "an instruction nobody gave was withdrawn");
         Change := S.No_Changes;
         Au.Withdraw (Store, Change, To_String (First), "user tester", Status);
         S.Commit (Store, Change, Status);
         Assert (E.Is_Ok (Status)
                 and then Au.Standing_Instructions (Store).Is_Empty
                 and then Au.Governing (Au.Resolve (Au.Gather (Store)), "scalar.build.command", Found)
                          .Standing = Au.Project_Decision,
                 "a withdrawn instruction still governed: " & Code_Of (Status));
      end;
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
      declare
         Said : constant Bs.Output_List :=
           Bs.Scan ("docs/facts.md",
                    "Fact: build_system = Alire" & LF & "Fact: nothing here" & LF);
      begin
         Assert (Bs.Length (Said) = 2
                 and then Bs."=" (Bs.Element (Said, 1).Kind, Bs.Discovered_Fact)
                 and then To_String (Bs.Element (Said, 1).Key) = "build_system"
                 and then To_String (Bs.Element (Said, 1).Text) = "Alire"
                 and then Bs."=" (Bs.Element (Said, 2).Kind, Bs.Issue),
                 "a document's facts were not read, or one that does not read not said");
      end;
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
      --  The new line made, and the specification the document is revised.
      Assert (Report.Created = 1 and then Natural (Report.Revised.Length) = 1,
              "bootstrap over an edited document did not make only what is"
              & " new and revise what changed:" & Report.Created'Image);
      Assert (Natural (Nt.List (Store, Nt.Requirement).Length) = 4
              and then Nt.Find_By_Provenance
                         (Store, Nt.Requirement, "docs/parser.md#REQ-PARSE-003")
                       = "REQ-PARSE-003",
              "the requirements bootstrap made are not the ones it found, under"
              & " the identifier the document gives");

      --  The imported line changed: its next revision, not another item.
      Bs.Apply (Store, Change,
                Bs.Scan ("docs/parser.md",
                         "- REQ-PARSE-003: Input is read in one pass, and never twice." & LF),
                Report, Status);
      S.Commit (Store, Change, Status);
      declare
         Held : Nt.Entity;
      begin
         Nt.Read (Store, Nt.Requirement, "REQ-PARSE-003", Held, Status);
         Assert (E.Is_Ok (Status) and then Report.Created = 0 and then Natural (Report.Revised.Length) = 1
                 and then Held.Revision = 2
                 and then Ada.Strings.Fixed.Index (To_String (Held.Text), "never twice") > 0
                 and then Natural (Nt.List (Store, Nt.Requirement).Length) = 4,
                 "a changed imported line was not revised: " & Code_Of (Status));
      end;

      --  An imported requirement made obsolete is not revised, and does
      --  not stop bootstrap.
      declare
         Imported : constant String := "REQ-PARSE-003";
      begin
         Nt.Move (Store, Change, Nt.Requirement, Imported, "obsolete", Tr.Ordinary_Only, Status);
         S.Commit (Store, Change, Status);
      end;
      Bs.Apply (Store, Change,
                Bs.Scan ("docs/parser.md",
                         "- REQ-PARSE-003: Input is read in two passes." & LF),
                Report, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status),
              "an obsolete import stopped bootstrap: " & Code_Of (Status));

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

      --  A document does not outweigh what the template says: an issue,
      --  and the fact as it was. What it does record says where from.
      declare
         Held : Model_Runner.Framework.Facts.Fact;
      begin
         Change := S.No_Changes;
         Model_Runner.Framework.Facts.Record_Fact
           (Store, Change,
            (Key        => To_Unbounded_String ("build_system"),
             Value      => To_Unbounded_String ("Alire"),
             Source     => Model_Runner.Framework.Facts.Template,
             Confidence => Model_Runner.Framework.Facts.Authoritative,
             Origin     => <>),
            Status);
         S.Commit (Store, Change, Status);
         Bs.Apply (Store, Change,
                   Bs.Scan ("docs/build.md",
                            "Fact: build_system = Make" & LF & "Fact: vcs = git" & LF),
                   Report, Status);
         S.Commit (Store, Change, Status);
         Model_Runner.Framework.Facts.Find (Store, "build_system", Held, Status);
         Assert (To_String (Held.Value) = "Alire" and then Report.Issues = 1,
                 "a document outweighed the template's fact, or unsaid");
         Model_Runner.Framework.Facts.Find (Store, "vcs", Held, Status);
         Assert (To_String (Held.Value) = "git" and then To_String (Held.Origin) = "docs/build.md",
                 "a document's fact does not say where it came from");
         declare
            Reports : Natural := 0;
            Stored  : R.Item;
         begin
            for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
               S.Read (Store, Model_Runner.Framework.Results_Area, Name, Stored, Status);
               if R.Get (Stored, "result_type") = "bootstrap_report" then
                  Reports := Reports + 1;
               end if;
            end loop;
            Assert (Reports > 0, "bootstrap kept no report of what it did");
         end;
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
        ("template = work" & LF & "name = W" & LF & "description = D" & LF & "version = 1" & LF
         & "task_kind implementation = component, requirements?, notes?" & LF
         & "task_kind analysis = estimate?" & LF
         & "map task_field.estimate = text" & LF
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
      Assert (Status.Code = E.Framework_Input_Invalid
              and then Ada.Strings.Fixed.Index (E.Text_Of (Status, "detail"), "they are title") > 0,
              "a field no kind defines was carried, or refused without the fields there are");
      Tk.Create (Store, Change,
                 Fields ("x", "analysis", "depends_on", "TASK-NONE-001"), "user",
                 "", Id, Status);
      Assert (Status.Code = E.Framework_Not_Found,
              "a dependency on no task was taken");

      Tk.Create (Store, Change,
                 Fields ("Parse the input", "implementation", "component",
                         "parser"), "user", "", Id, Status);
      --  Keyed by its component where the project has several.
      Assert (E.Is_Ok (Status)
              and then To_String (Id)
                       = (if Natural (Tk.Components (Store).Length) > 1 then "TASK-PARSER-001"
                          else "TASK-001"),
              "a task was not created: " & Code_Of (Status) & " " & To_String (Id));
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
      --  Accepted before its part is made: accepted after, it would wait on
      --  it at once.
      Tk.Move (Store, Change, To_String (Parent), "accepted", "",
               Status => Status);
      S.Commit (Store, Change, Status);
      Tk.Create (Store, Change,
                 Fields ("A part", "analysis", "parent", To_String (Parent)),
                 "user", "", Child, Status);
      S.Commit (Store, Change, Status);
      Assert (Tk.Children (Store, To_String (Parent)).First_Element
              = To_String (Child), "a child does not know its parent");

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

      --  A new meaning while its task has not started is that task's work
      --  now, not a second task beside it.
      Nt.Revise (Store, Change, Nt.Requirement, To_String (Req), "Read it",
                 "It SHALL read and then close.", "", Effect, Status);
      S.Commit (Store, Change, Status);
      Tk.Derive (Store, Change, Made, Status);
      S.Commit (Store, Change, Status);
      declare
         Defined : R.Item;
      begin
         Tk.Definition (Store, Tk.List (Store).First_Element, Defined, Status);
         Assert (Made.Is_Empty and then Natural (Tk.List (Store).Length) = 1
                 and then R.Get (Defined, "origin") = To_String (Req) & "@4",
                 "a requirement's new meaning left a second task, or the first unchanged: "
                 & R.Get (Defined, "origin"));
      end;
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
      declare
         View : R.Item;
      begin
         Tk.Effective (Store, Made.First_Element, View, Status);
         Assert (R.Get (View, "runtime.accepted_by")
                 = "policy task.auto_accept requirement_derivation",
                 "an automatic acceptance does not say it was the policy's: "
                 & R.Get (View, "runtime.accepted_by"));
      end;
      Assert (Tk.Cycles (Store).Is_Empty, "a cycle was found where none is");
      declare
         View : R.Item;
      begin
         Tk.Effective (Store, Made.First_Element, View, Status);
         Assert (Ada.Strings.Fixed.Index (R.Get (View, "permissions"), [1 => ASCII.LF]) = 0
                 and then Ada.Strings.Fixed.Index (R.Get (View, "permissions"), "; ") > 0,
                 "a task's permissions were not shown on one line");
      end;
      S.Close (Store);

      --  The policy names the classes it accepts: here what an agent
      --  proposes, and not what a person does. A person's acceptance and
      --  rejection say who it was.
      Change := S.No_Changes;
      Task_Project (Store, "acceptance-by-class",
                    "set task.auto_accept = agent" & LF
                    & "baseline project.tests = a change comes with its test" & LF
                    & "set repository.tests = checks" & LF);
      Assert (Model_Runner.Framework.Repository.Roots_Of (Store).Tests
              = Model_Runner.Framework.Name_Lists.To_Vector ("checks", 1)
              and then Model_Runner.Framework.Repository.Roots_Of (Store).Skip
                       = Model_Runner.Framework.Repository.Default_Roots.Skip,
              "the configuration's roots were not taken, or the defaults not kept");
      declare
         Fields   : Tk.Field_Map;
         Proposed : Unbounded_String;
         Mine     : Unbounded_String;
         Other    : Unbounded_String;
         View     : R.Item;
         Listed   : Ev.Event_List;
         Named    : Boolean := False;
      begin
         Fields.Include ("title", "Look");
         Fields.Include ("kind", "analysis");
         Tk.Create (Store, Change, Fields, "AG-000001", "TASK-X", Proposed, Status);
         Tk.Create (Store, Change, Fields, "user", "", Mine, Status);
         Tk.Create (Store, Change, Fields, "user", "", Other, Status);
         S.Commit (Store, Change, Status);
         Assert (E.Is_Ok (Status)
                 and then Tk.State_Of (Store, To_String (Proposed)) = "accepted"
                 and then Tk.State_Of (Store, To_String (Mine)) = "candidate",
                 "the policy did not accept by class: " & Code_Of (Status));

         Tk.Move (Store, Change, To_String (Mine), "accepted", "",
                  Status => Status, Actor => Tr.User);
         Tk.Move (Store, Change, To_String (Other), "rejected", "",
                  Status => Status, Actor => Tr.User);
         S.Commit (Store, Change, Status);
         Tk.Effective (Store, To_String (Mine), View, Status);
         Assert (Ada.Strings.Fixed.Index (Tr.User, "user") = 1
                 and then R.Get (View, "runtime.accepted_by") = Tr.User
                 and then R.Get (View, "runtime.moved_by") = Tr.User,
                 "an acceptance does not say who accepted");
         Assert (Ada.Strings.Fixed.Index (R.Get (View, "authority.tests"), "project_baseline") = 1,
                 "the project baseline does not govern the task: "
                 & R.Get (View, "authority.tests"));
         Tk.Effective (Store, To_String (Other), View, Status);
         Assert (R.Get (View, "runtime.rejected_by") = Tr.User,
                 "a rejection does not say who rejected");
         Listed := Ev.Since (Store, 0);
         for Index in 1 .. Ev.Length (Listed) loop
            Named := Named
              or else (Ev.Element (Listed, Index).Kind = Ev.Task_Rejected
                       and then Ada.Strings.Fixed.Index
                                  (To_String (Ev.Element (Listed, Index).Detail),
                                   "by " & Tr.User) > 0);
         end loop;
         Assert (Named, "the rejection's event does not name who");
      end;
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
                & "   Other.Next (Item);" & LF
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
                             ("src/main.adb:4")
              and then not Rp.References_To (Found, "Parser.Next").Contains
                             ("src/main.adb:7"),
              "a reference was missed, a string taken for one, or another unit's name");

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
                  --  A with clause names its unit for certain; a name
                  --  matched is a heuristic.
                  Assert (Link.Source = Rp.Heuristic
                          or else (Link.Source = Rp.Explicit
                                   and then not Rp.Dependents_Of (Found, To_String (Link.To))
                                                  .Is_Empty),
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

      --  Brought up to date, reading only what changed, it is the graph a
      --  whole scan makes.
      delay 2.1;
      declare
         Whole     : constant Rp.Graph := Rp.Scan (Project);
         Refreshed : Rp.Graph;
         Read      : Natural;
      begin
         Refreshed := Rp.Refresh (Project, Whole, Read);
         Assert (Read = 0
                 and then Rp.Graph_Fingerprint (Refreshed)
                          = Rp.Graph_Fingerprint (Whole),
                 "an unchanged tree was read again:" & Natural'Image (Read));
         Refreshed := Rp.Refresh (Project, Found, Read);
         Assert (Rp.Graph_Fingerprint (Refreshed) = Rp.Graph_Fingerprint (Whole)
                 and then Rp.Relation_Count (Refreshed)
                          = Rp.Relation_Count (Whole),
                 "a new file was not brought in as a scan would");
         Put_File (Project & "/src/parser.ads",
                   "package Parser is" & LF
                   & "   type Token is null record;" & LF
                   & "   procedure Next (Item : out Token);" & LF
                   & "   procedure Skip;" & LF
                   & "   Limit : constant := 3;" & LF
                   & "end Parser;" & LF);
         Refreshed := Rp.Refresh (Project, Whole, Read);
         Again := Rp.Scan (Project);
         Assert (Rp.Graph_Fingerprint (Refreshed) = Rp.Graph_Fingerprint (Again)
                 and then Rp.Relation_Count (Refreshed)
                          = Rp.Relation_Count (Again)
                 and then Rp.Symbol_Count (Refreshed) = Rp.Symbol_Count (Again)
                 and then Rp.File_Count (Refreshed) = Rp.File_Count (Again)
                 and then Rp.References_To (Refreshed, "Parser.Next")
                          = Rp.References_To (Again, "Parser.Next"),
                 "a changed spec was not brought in as a scan would");
         Assert (Read >= 1 and then Read < Rp.File_Count (Again),
                 "the refresh read more than changed:" & Natural'Image (Read));
      end;
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
                              Fingerprint => To_Unbounded_String ("0"),
                              others => <>));
         Rp.Add_Symbol (Built, (Name => To_Unbounded_String ("lib.open"),
                                Kind => To_Unbounded_String ("function"),
                                Path => To_Unbounded_String ("lib.c"),
                                Line => 3));
         Rp.Add_Relation
           (Built, (Kind => Rp.Depends_On, From => To_Unbounded_String ("app"),
                    To => To_Unbounded_String ("lib"), Source => Rp.Build_Metadata,
                    Sure => Rp.Probable, Where => Null_Unbounded_String,
                    others => <>));
         Assert (Rp.Find_Symbols (Built, "open").First_Element = "lib.open"
                 and then Rp.Dependents_Of (Built, "lib").First_Element = "app"
                 and then Rp.Relation_Count (Built) = 2,
                 "a graph built by an adapter is not queried as one");
      end;

      --  The roots the configuration gives say what is a test and what a
      --  scan leaves out.
      declare
         Mine : Rp.Roots := Rp.Default_Roots;
      begin
         Mine.Tests := Model_Runner.Framework.Name_Lists.To_Vector ("checks", 1);
         Mine.Skip.Append ("tests");
         Assert (Rp.Role_Of ("checks/a.adb", Mine) = Rp.Test
                 and then Rp.Role_Of ("tests/a.adb", Mine) /= Rp.Test
                 and then Rp.Role_Of ("tests/a.adb") = Rp.Test
                 and then Rp.Role_Of ("src/io_test.go") = Rp.Test,
                 "a test was not where the roots say");
         Assert (Rp.File_Count (Rp.Scan (Project, Mine)) + 1
                 = Rp.File_Count (Rp.Scan (Project)),
                 "a directory the roots skip was scanned");

         --  What a tool made: by where it is, or by what it says.
         Assert (Rp.Role_Of ("generated/api.ads") = Rp.Generated
                 and then Rp.Role_Of ("src/api_pb2.py") = Rp.Generated
                 and then Rp.Says_Generated ("-- Code generated by gen. DO NOT EDIT." & LF & "x")
                 and then not Rp.Says_Generated ("-- Written by hand; edit freely." & LF),
                 "a generated file was not known as one");
         Put_File (Project & "/src/tables.ads",
                   "--  This file was automatically generated by make_tables." & LF
                   & "package Tables is" & LF & "end Tables;" & LF);
         declare
            Read   : Natural;
            Whole  : constant Rp.Graph := Rp.Scan (Project);
            Marked : Boolean := False;
         begin
            for Index in 1 .. Rp.File_Count (Whole) loop
               Marked := Marked
                 or else (To_String (Rp.File_At (Whole, Index).Path) = "src/tables.ads"
                          and then Rp.File_At (Whole, Index).Role = Rp.Generated);
            end loop;
            delay 2.1;
            Assert (Marked and then Rp.Graph_Fingerprint (Rp.Refresh (Project, Whole, Read))
                                    = Rp.Graph_Fingerprint (Whole)
                    and then Read = 0,
                    "a file that says it was generated was not, or was read again unchanged");
            Dirs.Delete_File (Project & "/src/tables.ads");
         end;
      end;

      --  The file tools stay inside the project, a link out of it included.
      --  The link points at a directory of its own, so that nothing that
      --  follows it can harm anything else.
      declare
         package Pc renames Model_Runner.CLI.Project_Commands;
         Away : constant String :=
           Hostkit.Fs.Create_Temporary_Directory ("model-runner-away");
         Link : constant String := Scratch & "/away";
         Gone : Boolean;
      begin
         Assert (Pc.Within_Project ("src/none.adb")
                 and then not Pc.Within_Project ("../x")
                 and then not Pc.Within_Project ("src/../../x")
                 and then not Pc.Within_Project ("/etc/passwd"),
                 "a path was placed wrongly inside or outside the project");
         if Away /= "" then
            Gone := Hostkit.Fs.Delete_Link (Link);
            if Hostkit.Fs.Create_Link (Away, Link) then
               Assert (not Pc.Within_Project (Link & "/x")
                       and then not Pc.Within_Project (Link),
                       "a link out of the project was followed");
               Gone := Hostkit.Fs.Delete_Link (Link);
            end if;
            Dirs.Delete_Directory (Away);
         end if;
         pragma Unreferenced (Gone);
      end;
   end Repository_Is_Scanned;

   --  C, Rust and Python are read by their own adapters: units, what each
   --  brings in, what each declares, and where those names are used.
   procedure Other_Languages_Are_Read
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project : constant String := Fresh ("languages");
      Found   : Rp.Graph;
      Named   : Rp.Symbol;
      Here    : Boolean;

      function Has_Relation
        (Kind : Rp.Relation_Kind; From, To : String) return Boolean is
      begin
         for Index in 1 .. Rp.Relation_Count (Found) loop
            declare
               use type Rp.Relation_Kind;
               Link : constant Rp.Relation := Rp.Relation_At (Found, Index);
            begin
               if Link.Kind = Kind and then To_String (Link.From) = From
                 and then To_String (Link.To) = To
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Has_Relation;
   begin
      Dirs.Create_Path (Project & "/c");
      Dirs.Create_Path (Project & "/src/io");
      Dirs.Create_Path (Project & "/py/shop");
      Put_File (Project & "/c/buffer.h",
                "#include <stdio.h>" & LF
                & "#define BUFFER_SIZE 64" & LF
                & "typedef struct { int n; } buffer_t;" & LF
                & "/* int hidden(void); */" & LF
                & "int buffer_fill(buffer_t *b, const char *text);" & LF);
      Put_File (Project & "/c/main.c",
                "#include ""buffer.h""" & LF
                & "static const char *said = ""buffer_fill(x)"";" & LF
                & "int main(void) {" & LF
                & "   buffer_t b;" & LF
                & "   if (buffer_fill(&b, said)) { return 1; }" & LF
                & "   return 0;" & LF
                & "}" & LF);
      Put_File (Project & "/src/lib.rs",
                "pub mod io;" & LF & "use crate::io::reader::Reader;" & LF
                & "pub fn run() -> usize { let r = Reader::new(); r.count() }" & LF);
      Put_File (Project & "/src/io/reader.rs",
                "pub trait Count { fn count(&self) -> usize; }" & LF
                & "pub struct Reader { n: usize }" & LF
                & "impl Reader { pub fn new() -> Self { Reader { n: 0 } } }" & LF
                & "impl Count for Reader { fn count(&self) -> usize { self.n } }" & LF
                & "// fn gone() {}" & LF);
      Put_File (Project & "/py/shop/__init__.py", "");
      Put_File (Project & "/py/shop/cart.py",
                "from .prices import total, TAX" & LF
                & "import json" & LF
                & "LIMIT = 10" & LF
                & "class Cart(Base):" & LF
                & "    """"""def hidden(): a docstring""""""" & LF
                & "    def add(self, item):" & LF
                & "        def inner():" & LF
                & "            pass" & LF
                & "        return total([item])  # total() in a comment" & LF);
      Put_File (Project & "/py/shop/prices.py",
                "TAX = 0.25" & LF & "def total(items):" & LF & "    return sum(items)" & LF);

      Found := Rp.Scan (Project);

      --  C.
      Named := Rp.Symbol_Of (Found, "buffer.buffer_fill", Here);
      Assert (Here and then To_String (Named.Kind) = "function" and then Named.Line = 5,
              "a C prototype was not a symbol where it is");
      Named := Rp.Symbol_Of (Found, "buffer.buffer_t", Here);
      Assert (Here and then To_String (Named.Kind) = "type", "a typedef was not a type");
      Named := Rp.Symbol_Of (Found, "buffer.BUFFER_SIZE", Here);
      Assert (Here and then To_String (Named.Kind) = "macro", "a macro was not found");
      Named := Rp.Symbol_Of (Found, "buffer.hidden", Here);
      Assert (not Here, "a commented declaration was taken for one");
      Assert (Has_Relation (Rp.Depends_On, "main", "buffer")
              and then not Has_Relation (Rp.Depends_On, "main", "stdio"),
              "an include was not a dependency, or a system header was");
      Assert (Rp.References_To (Found, "buffer.buffer_fill").Contains ("c/main.c:5")
              and then not Rp.References_To (Found, "buffer.buffer_fill").Contains ("c/main.c:2")
              and then Has_Relation (Rp.Calls, "main", "buffer.buffer_fill"),
              "a C call was missed, or a string taken for one");

      --  Read_References is what finds them, once every file is read.
      declare
         Extra  : Rp.Graph := Found;
         Before : constant Natural := Rp.Relation_Count (Found);
      begin
         Model_Runner.Framework.Repository.Languages.Adapter_For ("C").Read_References
           ("c/main.c", "int y(void) { return buffer_fill(0, 0); }", Extra);
         Assert (Rp.Relation_Count (Extra) = Before + 2,
                 "a file's references were not found once asked for");
      end;

      --  Rust.
      Named := Rp.Symbol_Of (Found, "crate::io::reader.Reader", Here);
      Assert (Here and then To_String (Named.Kind) = "type",
              "a Rust struct was not a symbol of its module");
      Named := Rp.Symbol_Of (Found, "crate::io::reader.Reader.new", Here);
      Assert (Here and then To_String (Named.Kind) = "method",
              "a function in an impl was not its type's");
      Named := Rp.Symbol_Of (Found, "crate::io::reader.gone", Here);
      Assert (not Here, "a commented Rust function was taken for one");
      Assert (Has_Relation (Rp.Implements_Interface, "crate::io::reader.Reader", "Count")
              and then Has_Relation (Rp.Overrides, "crate::io::reader.Reader.count", "count"),
              "impl Trait for Type did not take the trait on");
      Assert (Has_Relation (Rp.Depends_On, "crate", "crate::io::reader"),
              "a use of a type was not a dependency on its module");
      Assert (not Rp.References_To (Found, "crate::io::reader.Reader").Is_Empty,
              "a Rust type's use was missed");

      --  Python.
      Named := Rp.Symbol_Of (Found, "py.shop.cart.Cart.add", Here);
      Assert (Here and then To_String (Named.Kind) = "method" and then Named.Line = 6,
              "a method was not its class's");
      Named := Rp.Symbol_Of (Found, "py.shop.cart.Cart.add.inner", Here);
      Assert (not Here, "a function inside a function was declared");
      Named := Rp.Symbol_Of (Found, "py.shop.cart.hidden", Here);
      Assert (not Here, "a docstring was read as code");
      Named := Rp.Symbol_Of (Found, "py.shop.cart.LIMIT", Here);
      Assert (Here and then To_String (Named.Kind) = "constant", "a constant was not found");
      Assert (Has_Relation (Rp.Depends_On, "py.shop.cart", "py.shop.prices")
              and then Has_Relation (Rp.Depends_On, "py.shop.cart", "json")
              and then Has_Relation (Rp.Extends, "py.shop.cart.Cart", "Base"),
              "an import, relative or not, or a base was missed");
      Assert (Rp.References_To (Found, "py.shop.prices.total").Contains ("py/shop/cart.py:9")
              and then Has_Relation (Rp.Calls, "py.shop.cart", "py.shop.prices.total")
              and then Natural (Rp.References_To (Found, "py.shop.prices.total").Length) = 2,
              "a Python call was missed, or a comment read as one");

      --  A change in one language's file is brought in as a scan would.
      delay 2.1;
      declare
         Read  : Natural;
         Again : Rp.Graph;
      begin
         Put_File (Project & "/py/shop/prices.py",
                   "TAX = 0.25" & LF & "def total(items):" & LF & "    return sum(items)" & LF
                   & "def discount(items):" & LF & "    return 0" & LF);
         Again := Rp.Refresh (Project, Found, Read);
         Assert (Rp.Graph_Fingerprint (Again) = Rp.Graph_Fingerprint (Rp.Scan (Project))
                 and then Rp.Relation_Count (Again) = Rp.Relation_Count (Rp.Scan (Project))
                 and then Rp.Symbol_Count (Again) = Rp.Symbol_Count (Rp.Scan (Project)),
                 "a refresh of a Python change differs from a scan");
      end;
   end Other_Languages_Are_Read;

   --  A chooser cancelled with Ctrl-C leaves the terminal as it found it:
   --  task new, on a pseudo-terminal, offers the kinds in raw mode, and
   --  the mode read back after the cancellation is the mode before.
   procedure Terminal_Restored_After_Cancel
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Hostkit.Descriptors.Descriptor;
      use type Hostkit.Spawn.Spawn_Outcome;
      use type Ada.Streams.Stream_Element_Offset;
      Store   : S.Store;
      Pair    : Hostkit.Pty.Pair;
      Options : Hostkit.Spawn.Options;
      Child   : Hostkit.Spawn.Process_Handle;
      Result  : Hostkit.Spawn.Status;
      Before  : Hostkit.Terminal_Control.Mode;
      During  : Hostkit.Terminal_Control.Mode;
      After   : Hostkit.Terminal_Control.Mode;
      Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
      Last    : Ada.Streams.Stream_Element_Offset;
      Was     : Interfaces.Unsigned_8;
      Became  : Interfaces.Unsigned_8;
      Words   : Hostkit.String_Vectors.Vector;

      procedure Keep_Variable (Name, Value : String) is
      begin
         if Name /= "TERM" then
            Options.Environment.Append (To_Unbounded_String (String'(Name & "=" & Value)));
         end if;
      end Keep_Variable;
   begin
      if not Hostkit.Pty.Is_Supported or else not Hostkit.Pty.Open (Pair)
        or else Pair.Device = Hostkit.Descriptors.Invalid
      then
         Ada.Text_IO.Put_Line ("note: no pseudo-terminal device here; not checked");
         return;
      end if;
      Task_Project (Store, "terminal");
      S.Close (Store);

      Ada.Environment_Variables.Iterate (Keep_Variable'Access);
      Options.Environment.Append (To_Unbounded_String ("TERM=xterm"));
      Options.Replace_Environment := True;
      Options.Working_Directory :=
        To_Unbounded_String (Dirs.Full_Name (Scratch & "/terminal"));
      Assert (Hostkit.Pty.Set_Size (Pair, (Rows => 24, Columns => 80)),
              "the pseudo-terminal was not sized");
      Assert (Hostkit.Pty.Attach (Pair, Options), "the pseudo-terminal was not attached");
      Assert (Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, Before),
              "the terminal's mode was not read");
      Words.Append (To_Unbounded_String ("session-command"));
      Words.Append (To_Unbounded_String ("/task"));
      Words.Append (To_Unbounded_String ("new"));
      Assert (Hostkit.Spawn.Start (Dirs.Full_Name ("bin/tests"), Words, Options, Child)
              = Hostkit.Spawn.Spawn_Ok, "model_runner did not start");
      Hostkit.Pty.Close_Device (Pair);

      --  The kinds are drawn once raw mode is set; then Ctrl-C.
      Assert (Hostkit.Descriptors."=" (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                                      Hostkit.Descriptors.Transfer_Ok)
              and then Last >= Buffer'First,
              "task new drew nothing on a terminal");
      --  What it says first may come before the chooser: wait, reading,
      --  until the terminal is raw.
      for Try in 1 .. 30 loop
         exit when Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, During)
           and then Hostkit.Terminal_Control.Differences.First_Difference
                      (Before, During, Was, Became) /= 0;
         if Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 100) then
            Last := Buffer'First - 1;
            exit when Hostkit.Descriptors."/="
                        (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                         Hostkit.Descriptors.Transfer_Ok);
         end if;
      end loop;
      Assert (Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, During)
              and then Hostkit.Terminal_Control.Differences.First_Difference
                         (Before, During, Was, Became) /= 0,
              "the chooser did not put the terminal in raw mode, so nothing is checked");
      Assert (Hostkit.Descriptors."=" (Hostkit.Descriptors.Write
                                         (Pair.To_Child, [1 => 3], Last),
                                       Hostkit.Descriptors.Transfer_Ok),
              "Ctrl-C was not sent");
      loop
         exit when Hostkit.Descriptors."/=" (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                                             Hostkit.Descriptors.Transfer_Ok)
           or else Last < Buffer'First;
      end loop;
      Assert (Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Block, Result),
              "task new was not waited for");
      Assert (Hostkit.Terminal_Control.Save_Mode (Pair.To_Child, After),
              "the terminal's mode was not read afterwards");
      Assert (Hostkit.Terminal_Control.Differences.First_Difference (Before, After, Was, Became) = 0,
              "the terminal was left as the chooser set it after Ctrl-C");
      Hostkit.Pty.Close (Pair);
   end Terminal_Restored_After_Cancel;

   --  On a pseudo-terminal: the selector redraws when the window is
   --  resized while nobody types, and a secret input is typed unseen.
   procedure Terminal_Follows_Resize_And_Hides_Secrets
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Hostkit.Descriptors.Descriptor;
      use type Hostkit.Spawn.Spawn_Outcome;
      use type Ada.Streams.Stream_Element_Offset;

      --  Run model_runner with these words on a fresh pseudo-terminal in a
      --  directory; Act is given the pair once it has drawn something, and
      --  what it wrote in all is returned. Empty where there is no device.
      function Run_On_Terminal
        (Words     : Hostkit.String_Vectors.Vector;
         Directory : String;
         Extra     : String;
         Act       : not null access procedure (Pair : Hostkit.Pty.Pair; Seen : String))
         return String
      is
         Pair    : Hostkit.Pty.Pair;
         Options : Hostkit.Spawn.Options;
         Child   : Hostkit.Spawn.Process_Handle;
         Result  : Hostkit.Spawn.Status;
         Buffer  : Ada.Streams.Stream_Element_Array (1 .. 4096);
         Last    : Ada.Streams.Stream_Element_Offset;
         Said    : Unbounded_String;

         procedure Keep_Variable (Name, Value : String) is
         begin
            if Name /= "TERM" then
               Options.Environment.Append (To_Unbounded_String (String'(Name & "=" & Value)));
            end if;
         end Keep_Variable;

         --  What arrives within a few seconds.
         procedure Gather is
         begin
            while Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 3000) loop
               exit when Hostkit.Descriptors."/="
                           (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                            Hostkit.Descriptors.Transfer_Ok)
                 or else Last < Buffer'First;
               for Byte of Buffer (Buffer'First .. Last) loop
                  Append (Said, Character'Val (Byte));
               end loop;
               exit when Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 300) = False;
            end loop;
         end Gather;
      begin
         if not Hostkit.Pty.Is_Supported or else not Hostkit.Pty.Open (Pair)
           or else Pair.Device = Hostkit.Descriptors.Invalid
         then
            return "";
         end if;
         Ada.Environment_Variables.Iterate (Keep_Variable'Access);
         Options.Environment.Append (To_Unbounded_String ("TERM=xterm"));
         if Extra /= "" then
            Options.Environment.Append (To_Unbounded_String (Extra));
         end if;
         Options.Replace_Environment := True;
         Options.Working_Directory := To_Unbounded_String (Directory);
         Assert (Hostkit.Pty.Set_Size (Pair, (Rows => 24, Columns => 80))
                 and then Hostkit.Pty.Attach (Pair, Options),
                 "the pseudo-terminal was not made ready");
         --  The words as a session takes them, run by the tests' own
         --  program at this terminal: the command line has none of these.
         declare
            Line : Hostkit.String_Vectors.Vector;
         begin
            Line.Append (To_Unbounded_String ("session-command"));
            for Index in Words.First_Index .. Words.Last_Index loop
               declare
                  One : constant String := To_String (Words (Index));
               begin
                  if Index = Words.First_Index then
                     Line.Append (To_Unbounded_String ("/" & One));
                  elsif One = "--set" then
                     null;
                  elsif Ada.Strings.Fixed.Index (One, " ") > 0 then
                     Line.Append (To_Unbounded_String ('"' & One & '"'));
                  else
                     Line.Append (To_Unbounded_String (One));
                  end if;
               end;
            end loop;
            Assert (Hostkit.Spawn.Start (Dirs.Full_Name ("bin/tests"), Line, Options, Child)
                    = Hostkit.Spawn.Spawn_Ok, "the session's command did not start");
         end;
         Hostkit.Pty.Close_Device (Pair);
         Gather;
         Act (Pair, To_String (Said));
         Gather;
         loop
            exit when Hostkit.Descriptors."/="
                        (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                         Hostkit.Descriptors.Transfer_Ok)
              or else Last < Buffer'First;
            for Byte of Buffer (Buffer'First .. Last) loop
               Append (Said, Character'Val (Byte));
            end loop;
         end loop;
         Assert (Hostkit.Spawn.Wait (Child, Hostkit.Spawn.Wait_Block, Result), "not waited for");
         Hostkit.Pty.Close (Pair);
         return To_String (Said);
      end Run_On_Terminal;

      Store  : S.Store;
      Redrew : Boolean := False;

      procedure Resize_Then_Cancel (Pair : Hostkit.Pty.Pair; Seen : String) is
         Buffer : Ada.Streams.Stream_Element_Array (1 .. 4096);
         Last   : Ada.Streams.Stream_Element_Offset;
         Sent   : Hostkit.Descriptors.Transfer_Outcome;
      begin
         Assert (Seen /= "", "the selector drew nothing");
         Assert (Hostkit.Pty.Set_Size (Pair, (Rows => 30, Columns => 100)), "not resized");
         Redrew := Hostkit.Descriptors.Wait_Readable (Pair.From_Child, 3000)
           and then Hostkit.Descriptors."=" (Hostkit.Descriptors.Read (Pair.From_Child, Buffer, Last),
                                            Hostkit.Descriptors.Transfer_Ok)
           and then Last >= Buffer'First;
         Sent := Hostkit.Descriptors.Write (Pair.To_Child, [1 => 3], Last);
         Assert (Hostkit.Descriptors."=" (Sent, Hostkit.Descriptors.Transfer_Ok) and then Last = 1,
                 "Ctrl-C was not sent");
      end Resize_Then_Cancel;

      --  The kind's choice field offers its choices: a return takes the first;
      --  the optional field is left empty.
      procedure Choose_Then_Skip (Pair : Hostkit.Pty.Pair; Seen : String) is
         Last : Ada.Streams.Stream_Element_Offset;
         Sent : Hostkit.Descriptors.Transfer_Outcome;
      begin
         Assert (Ada.Strings.Fixed.Index (Seen, "pass") > 0
                 and then Ada.Strings.Fixed.Index (Seen, "fail") > 0,
                 "a choice field did not offer its choices: " & Seen);
         Sent := Hostkit.Descriptors.Write (Pair.To_Child, [1 => 13], Last);
         Assert (Hostkit.Descriptors."=" (Sent, Hostkit.Descriptors.Transfer_Ok) and then Last = 1,
                 "a choice was not made");
         delay 1.5;
         Sent := Hostkit.Descriptors.Write (Pair.To_Child, [1 => 10], Last);
         Assert (Hostkit.Descriptors."=" (Sent, Hostkit.Descriptors.Transfer_Ok) and then Last = 1,
                 "an optional field was not passed over");
      end Choose_Then_Skip;

      --  A cursor key sent in two pieces, as SSH or tmux may send it: the
      --  second choice, not the selector given up on.
      procedure Split_Key_Then_Choose (Pair : Hostkit.Pty.Pair; Seen : String) is
         pragma Unreferenced (Seen);

         procedure Send (Bytes : Ada.Streams.Stream_Element_Array) is
            Last : Ada.Streams.Stream_Element_Offset;
            Sent : constant Hostkit.Descriptors.Transfer_Outcome :=
              Hostkit.Descriptors.Write (Pair.To_Child, Bytes, Last);
            Whole : constant Boolean := Last = Bytes'Last;
         begin
            Assert (Hostkit.Descriptors."=" (Sent, Hostkit.Descriptors.Transfer_Ok) and then Whole,
                    "a key was not sent");
         end Send;
      begin
         Send ([1 => 27]);
         delay 0.01;
         Send ([1 => Character'Pos ('['), 2 => Character'Pos ('B')]);
         delay 0.3;
         Send ([1 => 13]);
         delay 1.5;
         Send ([1 => 10]);
      end Split_Key_Then_Choose;

      procedure Type_Secret (Pair : Hostkit.Pty.Pair; Seen : String) is
         Last : Ada.Streams.Stream_Element_Offset;
         Word : constant String := "hunter2" & ASCII.CR;
         Keys : Ada.Streams.Stream_Element_Array (1 .. Word'Length);
         Sent : Hostkit.Descriptors.Transfer_Outcome;
      begin
         Assert (Ada.Strings.Fixed.Index (Seen, "Token") > 0, "the secret was not asked for: " & Seen);
         for Index in Word'Range loop
            Keys (Ada.Streams.Stream_Element_Offset (Index)) := Character'Pos (Word (Index));
         end loop;
         Sent := Hostkit.Descriptors.Write (Pair.To_Child, Keys, Last);
         Assert (Hostkit.Descriptors."=" (Sent, Hostkit.Descriptors.Transfer_Ok)
                 and then Last = Keys'Last, "the secret was not typed");
      end Type_Secret;

      Words : Hostkit.String_Vectors.Vector;
   begin
      if not Hostkit.Pty.Is_Supported then
         Ada.Text_IO.Put_Line ("note: no pseudo-terminal here; not checked");
         return;
      end if;
      Task_Project (Store, "terminal-resize");
      S.Close (Store);
      Words.Append (To_Unbounded_String ("task"));
      Words.Append (To_Unbounded_String ("new"));
      declare
         Said : constant String :=
           Run_On_Terminal (Words, Dirs.Full_Name (Scratch & "/terminal-resize"), "",
                            Resize_Then_Cancel'Access);
      begin
         Assert (Said = "" or else Redrew, "a resize while nobody typed was not drawn");
      end;

      --  task new on a terminal: the form its kind's schema makes.
      Task_Project (Store, "terminal-form",
                    "task_kind review = verdict, notes?" & LF
                    & "map task_field.verdict = choice pass|fail" & LF);
      S.Close (Store);
      Words.Clear;
      Words.Append (To_Unbounded_String ("task"));
      Words.Append (To_Unbounded_String ("new"));
      Words.Append (To_Unbounded_String ("Judge it"));
      Words.Append (To_Unbounded_String ("--set"));
      Words.Append (To_Unbounded_String ("kind=review"));
      declare
         Said : constant String :=
           Run_On_Terminal (Words, Dirs.Full_Name (Scratch & "/terminal-form"), "",
                            Choose_Then_Skip'Access);
         Form : S.Store;
         Rep  : S.Recovery_Report;
         Got  : E.Error_Info;
         View : R.Item;
      begin
         if Said /= "" then
            S.Open (Form, Scratch & "/terminal-form", Rep, Got);
            Tk.Effective (Form, "TASK-001", View, Got);
            Assert (R.Get (View, "definition.field.verdict") = "pass",
                    "the form did not make the task its schema asks for: " & Said);
            S.Close (Form);
         end if;
      end;

      --  The same form, the choice made with a cursor key sent in pieces.
      Task_Project (Store, "terminal-split",
                    "task_kind review = verdict, notes?" & LF
                    & "map task_field.verdict = choice pass|fail" & LF);
      S.Close (Store);
      declare
         Said : constant String :=
           Run_On_Terminal (Words, Dirs.Full_Name (Scratch & "/terminal-split"), "",
                            Split_Key_Then_Choose'Access);
         Form : S.Store;
         Rep  : S.Recovery_Report;
         Got  : E.Error_Info;
         View : R.Item;
      begin
         if Said /= "" then
            S.Open (Form, Scratch & "/terminal-split", Rep, Got);
            Tk.Effective (Form, "TASK-001", View, Got);
            Assert (R.Get (View, "definition.field.verdict") = "fail",
                    "a cursor key sent in pieces was not read as one: " & Said);
            S.Close (Form);
         end if;
      end;

      --  A template with a secret input, found beside a settings file.
      declare
         Home    : constant String := Dirs.Full_Name (Fresh ("secret-home"));
         Project : constant String := Dirs.Full_Name (Fresh ("secret-project"));
      begin
         Dirs.Create_Path (Home & "/templates");
         Put_File (Home & "/settings.conf", "");
         Put_File (Home & "/templates/secret-demo.template",
                   "template = secret-demo" & LF & "name = Secret demo" & LF
                   & "description = D" & LF & "version = 1" & LF
                   & "input token" & LF
                   & "  type = text" & LF & "  label = Token" & LF
                   & "  description = the service's token" & LF
                   & "  required = true" & LF & "  secret = true" & LF);
         Words.Clear;
         Words.Append (To_Unbounded_String ("init"));
         Words.Append (To_Unbounded_String ("secret-demo"));
         declare
            Said : constant String :=
              Run_On_Terminal (Words, Project, "MODEL_RUNNER_CONFIG=" & Home & "/settings.conf",
                               Type_Secret'Access);
         begin
            Assert (Said = ""
                    or else (Ada.Strings.Fixed.Index (Said, "hunter2") = 0
                             and then Ada.Strings.Fixed.Index (Said, "*******") > 0
                             and then Dirs.Exists (Project & "/.model_runner")),
                    "a secret was shown as it was typed, or the project not made: " & Said);
         end;
      end;
   end Terminal_Follows_Resize_And_Hides_Secrets;

   --  The derived indexes are made at init, known to be stale once the
   --  state or the repository moves on, and say what they were built from.
   procedure Indexes_Are_Derived
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Ix renames Model_Runner.Framework.Indexes;
      Store  : S.Store;
      Change : S.Transaction;
      Status : E.Error_Info;
      Id     : Unbounded_String;
      Given  : Tk.Field_Map;
   begin
      Task_Project (Store, "indexes");
      Assert (Ix.Current (Store, Rp.Now (Store)),
              "init did not build the indexes");
      Given.Include ("title", "Look");
      Given.Include ("kind", "analysis");
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Assert (not Ix.Current (Store, Rp.Now (Store)),
              "an index built before a task was made was taken as current");
      Dirs.Create_Path (Fresh_Root (Store) & "/src");
      Put_File (Fresh_Root (Store) & "/src/io.ads", "package IO is" & LF
                & "   procedure Read;" & LF & "end IO;" & LF);
      Ix.Build (Store, Change, Rp.Now (Store), Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Ix.Current (Store, Rp.Now (Store)),
              "indexes just built were not current: " & Code_Of (Status));
      Assert (Ada.Strings.Fixed.Index (Ix.Entries (Store, Ix.Tasks_Index).First_Element,
                                       To_String (Id)) = 1
              and then Ix.Entries (Store, Ix.Search_Index).Contains ("read" & ASCII.HT & "IO.Read")
              and then Ix.Entries (Store, Ix.Dependency_Index).Is_Empty,
              "an index does not say what the state and the repository hold");
      S.Close (Store);
   end Indexes_Are_Derived;

   --  An agent's file tools never reach the project's state, whatever its
   --  grants, nor write version control -- in a session, and in a process
   --  of its own; and the harness's own programs run with only what it
   --  passes them, and are logged.
   procedure Agents_Stay_Out_Of_The_State
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Pm renames Model_Runner.Framework.Permissions;
      package Ex renames Model_Runner.Framework.Execution;
      package Env renames Ada.Environment_Variables;
      Store : S.Store;
   begin
      Task_Project (Store, "state-guard");
      declare
         Root : constant String := Dirs.Full_Name (Fresh_Root (Store));
         Link : constant String := Root & "/state-link";
         Gone : Boolean;
      begin
         Assert (Pm.Path_Refusal (Root, ".model_runner/tasks/TASK-001.rec", Writing => True) /= ""
                 and then Pm.Path_Refusal (Root, "./.model_runner/config/x", Writing => False) /= ""
                 and then Pm.Path_Refusal (Root, ".git/config", Writing => True) /= ""
                 and then Pm.Path_Refusal (Root, ".git/config", Writing => False) = ""
                 and then Pm.Path_Refusal (Root, "src/new.adb", Writing => True) = ""
                 and then Pm.Path_Refusal (Root, "../x", Writing => False) /= "",
                 "an agent's path into the state or version control was allowed");
         --  A path is judged as its parts say it, however it is spelled,
         --  and a root holds what lies under it, not what begins like it.
         declare
            Rules : constant Pm.Permission_Set :=
              Pm.Value ("write_source roots=src/|lib/parser, deny=src/security/");
         begin
            Assert (not Pm.Allows (Rules, Pm.Write_Source, "./src/security/x.adb")
                    and then not Pm.Allows (Rules, Pm.Write_Source, "src//security/x.adb")
                    and then not Pm.Allows (Rules, Pm.Write_Source, "src/./security/x.adb")
                    and then Pm.Allows (Rules, Pm.Write_Source, "./src/main.adb")
                    and then Pm.Allows (Rules, Pm.Write_Source, "lib/parser/x.adb")
                    and then not Pm.Allows (Rules, Pm.Write_Source, "lib/parser_other/x.adb"),
                    "a path spelled otherwise reached past its rule");
            --  Written and read back, as an agent process is given them.
            Assert (Pm.Allows (Pm.Value (Pm.Image (Rules)), Pm.Write_Source, "lib/parser/x.adb")
                    and then not Pm.Allows (Pm.Value (Pm.Image (Rules)), Pm.Write_Source,
                                            "src/security/x.adb"),
                    "a permission written and read back was not the same: " & Pm.Image (Rules));
         end;
         Assert (Pm.Path_Refusal (Root, "src/new.adb", True, Pm.Value ("write_source roots=docs/"))
                 = "you may not write src/new.adb",
                 "the grants did not narrow what may be written");
         if Hostkit.Fs.Create_Link (Root & "/.model_runner", Link) then
            Assert (Pm.Path_Refusal (Root, "state-link/tasks/x", Writing => True) /= "",
                    "a link into the state was followed");
            Gone := Hostkit.Fs.Delete_Link (Link);
         end if;
         pragma Unreferenced (Gone);

         --  In a process of its own: the file tools hold it where the
         --  harness said, and nowhere when it said nothing.
         declare
            Runner : Model_Runner.Tools.Builtin.Instance;
            Said   : String (1 .. 4096);
            Last   : Natural;
            Status : E.Error_Info;
         begin
            Env.Set (Pm.Agent_Root_Variable, Root);
            Env.Set (Pm.Agent_Permissions_Variable, Pm.Image (Pm.Unrestricted));
            Model_Runner.Tools.Builtin.Run
              (Runner, "write_file", "{""path"": "".model_runner/evil"", ""content"": ""x""}",
               Said, Last, Status);
            Env.Clear (Pm.Agent_Root_Variable);
            Env.Clear (Pm.Agent_Permissions_Variable);
            Assert (Ada.Strings.Fixed.Index (Said (1 .. Last), "error:") = 1
                    and then not Dirs.Exists (".model_runner/evil")
                    and then not Dirs.Exists (Root & "/.model_runner/evil"),
                    "a confined agent process wrote the state: " & Said (1 .. Last));

            --  Nor does it read a whole folder, while a tool that reaches
            --  nothing still works.
            Env.Set (Pm.Agent_Root_Variable, Root);
            Model_Runner.Tools.Builtin.Run
              (Runner, "retrieve", "{""folder"": ""."", ""query"": ""state""}", Said, Last, Status);
            Assert (Ada.Strings.Fixed.Index (Said (1 .. Last), "does not use retrieve") > 0,
                    "a confined agent process read a whole folder: " & Said (1 .. Last));
            Model_Runner.Tools.Builtin.Run
              (Runner, "calculator", "{""a"": 2, ""b"": 2, ""op"": ""+""}", Said, Last, Status);
            Env.Clear (Pm.Agent_Root_Variable);
            Assert (Ada.Strings.Fixed.Index (Said (1 .. Last), "4") > 0,
                    "a confined agent process lost a tool that reaches nothing: "
                    & Said (1 .. Last));

            --  A program is the harness's to run, by its checks, through
            --  its execution policy: never the agent's own, whatever it holds.
            Env.Set (Pm.Agent_Root_Variable, Root);
            Env.Set (Pm.Agent_Permissions_Variable,
                     Pm.Image (Pm.Value ("read_source" & ASCII.LF & "execute_external_process")));
            Model_Runner.Tools.Builtin.Run
              (Runner, "shell", "{""command"": ""echo ran-it""}", Said, Last, Status);
            Env.Clear (Pm.Agent_Root_Variable);
            Env.Clear (Pm.Agent_Permissions_Variable);
            Assert (Ada.Strings.Fixed.Index (Said (1 .. Last), "ran-it") = 0
                    and then Ada.Strings.Fixed.Index (Said (1 .. Last), "harness runs programs") > 0,
                    "a confined agent ran a program past the harness: " & Said (1 .. Last));
         end;

         --  The harness's own program: only PATH, HOME and what is given.
         declare
            Output : constant String := Root & "/harness-env.txt";
            Ran    : Ex.Outcome;
            Text   : Unbounded_String;
            Read   : E.Error_Info;
         begin
            Env.Set ("MODEL_RUNNER_TEST_SECRET", "kept");
            Ex.Run_Harness (Root, "env", Model_Runner.Framework.Name_Lists.Empty_Vector, Root, Output,
                            30, Ran, Added => Model_Runner.Framework.Name_Lists.To_Vector
                                                ("GIVEN_HERE=yes", 1));
            Env.Clear ("MODEL_RUNNER_TEST_SECRET");
            Text := To_Unbounded_String (Read_Whole (Output));
            Assert (Ran.Started and then Ran.Exit_Status = 0
                    and then Index (Text, "GIVEN_HERE=yes") > 0
                    and then Index (Text, "MODEL_RUNNER_TEST_SECRET") = 0,
                    "a harness program got more, or less, than it was given");
            Assert (Dirs.Exists (Ex.Harness_Log (Root))
                    and then Ada.Strings.Fixed.Index (Read_Whole (Ex.Harness_Log (Root)), "env") > 0,
                    "a harness program was not logged");
            pragma Unreferenced (Read);
         end;
      end;
      S.Close (Store);
   end Agents_Stay_Out_Of_The_State;

   --  An initialization's result is checked before it is left standing:
   --  what the check finds is said, and only a state that did not come out
   --  whole is undone.
   procedure Init_Undone_When_Unsound
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Project  : constant String := Fresh ("unsound");
      Registry : Tp.Registry;
      Composed : Tp.Composition;
      Given    : Cf.Value_Maps.Map;
      Planned  : Cf.Plan;
      Done     : Cf.Outcome;
      Status   : E.Error_Info;
      Store    : S.Store;
   begin
      Tp.Add (Registry, Parsed
        ("template = unsound" & LF & "name = U" & LF & "description = D" & LF & "version = 1" & LF
         & "task_kind analysis = notes?" & LF
         & "map permission.kind.analysis.use_network =" & LF
         & "file NOTES.txt = made by init" & LF));
      Tp.Compose (Registry, "unsound", Composed, Status);
      Cf.Prepare (Composed, Project, Given, Planned, Status);
      Cf.Initialize (Store, Project, Planned, Done, Status);
      --  What the configuration says and is not granted is said, and the
      --  project stands: its state came out whole.
      --  A kind asking more than the project allows is given what the
      --  project allows: clamped, and nothing that does not hold together.
      Assert (E.Is_Ok (Status)
              and then not (for some Line of Done.Findings =>
                              Ada.Strings.Fixed.Index (Line, "permission_widening") > 0)
              and then S.Is_Initialized (Project)
              and then Dirs.Exists (Project & "/NOTES.txt"),
              "what the check of a sound initialization found was not said, or it was undone: "
              & Code_Of (Status));
      S.Close (Store);
   end Init_Undone_When_Unsound;

   --  Where the project verifies requirements themselves, a requirement is
   --  verified only with its own evidence, taken by that profile.
   procedure Requirements_Verified_By_Policy
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store    : S.Store;
      Change   : S.Transaction;
      Status   : E.Error_Info;
      Req      : Unbounded_String;
      Id       : Unbounded_String;
      Given    : Tk.Field_Map;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Changed  : Model_Runner.Framework.Name_Lists.Vector;
      Held     : Nt.Entity;
   begin
      Task_Project
        (Store, "requirement-policy",
         "set execution.allowed = echo" & LF
         & "profile passing = say: echo all good" & LF
         & "profile acceptance = accept: echo checking {requirement} with {tests}" & LF
         & "scalar profile_capability.acceptance = run_tests" & LF
         & "scalar verification.default = passing" & LF
         & "scalar verification.requirements = acceptance" & LF);
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted", Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Given := Fields ("Look", "analysis");
      Given.Include ("requirements", To_String (Req));
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Id), "running", "", Status => Status);
      Tk.Move (Store, Change, To_String (Id), "verification", "", Status => Status);
      Model_Runner.Framework.Verification.Run_Profile
        (Store, Change, "passing", To_String (Id), Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      Model_Runner.Framework.Verification.Complete_Task (Store, Change, To_String (Id), Status);
      S.Commit (Store, Change, Status);
      declare
         Runtime_Value : R.Item;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Id) & ".state",
                 Runtime_Value, Status);
         R.Set_Revision (Runtime_Value, R.Revision (Runtime_Value) + 1);
         R.Set (Runtime_Value, "changed_files", "src/io.adb");
         S.Put (Change, Model_Runner.Framework.Tasks_Area, To_String (Id) & ".state", Runtime_Value);
      end;
      S.Commit (Store, Change, Status);

      Model_Runner.Framework.Verification.Reevaluate_Requirements (Store, Change, Changed, Status);
      S.Commit (Store, Change, Status);
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (To_String (Held.State) = "implemented",
              "a requirement was verified without its own evidence");

      Model_Runner.Framework.Verification.Verify_Requirement (Store, Change, To_String (Req), Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      Model_Runner.Framework.Verification.Reevaluate_Requirements (Store, Change, Changed, Status);
      S.Commit (Store, Change, Status);
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (Passed and then To_String (Held.State) = "verified",
              "a requirement with its own evidence was not verified: " & To_String (Held.State));
      S.Close (Store);
   end Requirements_Verified_By_Policy;

   --  Bootstrap reads what its policy names, makes only the kinds it lets
   --  it, and proposes rather than accepts an import when it says so.
   procedure Bootstrap_Follows_Its_Policy
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Change : S.Transaction;
      Status : E.Error_Info;
      Report : Bs.Report;
      Found  : Bs.Output_List;
   begin
      Task_Project (Store, "bootstrap-policy",
                    "set bootstrap.sources = notes/*.txt" & LF
                    & "set bootstrap.propose = imports, requirements" & LF
                    & "scalar bootstrap.import = candidate" & LF
                    & "scalar task.derived_kind = analysis" & LF);
      Dirs.Create_Path (Fresh_Root (Store) & "/notes");
      Put_File (Fresh_Root (Store) & "/README.md", "The tool SHALL be ignored here." & LF);
      Put_File (Fresh_Root (Store) & "/notes/io.txt",
                "- REQ-IO-001: Input is read once." & LF
                & "The reader SHALL stop at the end." & LF
                & "Decision: errors are values." & LF);
      Assert (Bs.Documents (Store) = Model_Runner.Framework.Name_Lists.To_Vector ("notes/io.txt", 1),
              "bootstrap did not read what its policy names, and only that");
      Found := Bs.Scan ("notes/io.txt", Read_Whole (Fresh_Root (Store) & "/notes/io.txt"));
      Bs.Apply (Store, Change, Found, Report, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status)
              and then Natural (Nt.List (Store, Nt.Requirement).Length) = 2
              and then Nt.List (Store, Nt.Decision).Is_Empty
              and then Nt.List (Store, Nt.Requirement, "accepted").Is_Empty,
              "bootstrap made what its policy does not let it, or accepted an import: "
              & Code_Of (Status));

      --  An import accepted is followed as any accepted requirement is.
      declare
         Screen   : Model_Runner.Presentation.Console;
         Imported : constant String := Nt.List (Store, Nt.Requirement).First_Element;
      begin
         Nt.Move (Store, Change, Nt.Requirement, Imported, "accepted", Tr.Ordinary_Only, Status);
         S.Commit (Store, Change, Status);
         Model_Runner.CLI.Intents.Move_Along (Store, Screen);
         declare
            Followed : Boolean := False;
            Defined  : R.Item;
         begin
            for Id of Tk.List (Store) loop
               Tk.Definition (Store, Id, Defined, Status);
               Followed := Followed
                 or else Ada.Strings.Fixed.Index (R.Get (Defined, "requirements"), Imported) > 0;
            end loop;
            Assert (Followed, "an accepted import was not followed by its task");
         end;

         --  A person revises it; bootstrap run again over the same document
         --  leaves the person's words, and over a changed one raises it for
         --  a person rather than rewriting what was agreed.
         declare
            Effect : Nt.Impact;
            Held   : Nt.Entity;
         begin
            Nt.Revise (Store, Change, Nt.Requirement, Imported, "Read", "Input is read twice.", "",
                       Effect, Status);
            S.Commit (Store, Change, Status);
            Bs.Apply (Store, Change,
                      Bs.Scan ("notes/io.txt", Read_Whole (Fresh_Root (Store) & "/notes/io.txt")),
                      Report, Status);
            S.Commit (Store, Change, Status);
            Nt.Read (Store, Nt.Requirement, Imported, Held, Status);
            Assert (To_String (Held.Text) = "Input is read twice.",
                    "bootstrap run again put the document's words over a person's: "
                    & To_String (Held.Text));
            Bs.Apply (Store, Change,
                      Bs.Scan ("notes/io.txt", "- REQ-IO-001: Input is read in chunks." & LF),
                      Report, Status);
            S.Commit (Store, Change, Status);
            Nt.Read (Store, Nt.Requirement, Imported, Held, Status);
            Assert (To_String (Held.Text) = "Input is read twice." and then Report.Issues >= 1,
                    "a changed document rewrote an agreed requirement unasked: "
                    & To_String (Held.Text));
         end;
      end;
      S.Close (Store);

      --  An import whose identifier the project already gives something
      --  else is made under another, not accepted, and raised.
      Task_Project (Store, "bootstrap-clash",
                    "set bootstrap.sources = notes/*.txt" & LF
                    & "set bootstrap.propose = imports" & LF
                    & "scalar bootstrap.import = accepted" & LF);
      declare
         Req : Unbounded_String;
      begin
         Nt.Propose (Store, Change, Nt.Requirement, "IO", "Other", "It SHALL be other.", "",
                     "user", "", "io", Req, Status, Given => "REQ-IO-001");
         S.Commit (Store, Change, Status);
         Assert (To_String (Req) = "REQ-IO-001", "the identifier given was not taken");
      end;
      Found := Bs.Scan ("notes/io.txt", "- REQ-IO-001: Input is read once." & LF);
      Bs.Apply (Store, Change, Found, Report, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Report.Issues = 1
              and then Natural (Nt.List (Store, Nt.Requirement).Length) = 2
              and then Nt.List (Store, Nt.Requirement, "accepted").Is_Empty,
              "an import whose identifier was taken was accepted, or not raised: "
              & Code_Of (Status) & Report.Issues'Image);
      S.Close (Store);
   end Bootstrap_Follows_Its_Policy;

   --  A project adds requirement states of its own, each with what it
   --  means, and the moves to and from them; the core states' meaning
   --  stays the harness's, and a move to a state nobody defined is refused.
   procedure Requirement_Lifecycle_Is_The_Projects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : S.Store;
      Change  : S.Transaction;
      Status  : E.Error_Info;
      Req     : Unbounded_String;
      Screen  : Model_Runner.Presentation.Console;
      Planned : Model_Runner.Framework.Configurations.Change_Plan;

      function Refused (Name, Value : String) return Boolean is
         One : Model_Runner.Framework.Configurations.Value_Maps.Map;
         Got : E.Error_Info;
      begin
         One.Include (Name, Value);
         Model_Runner.Framework.Configurations.Plan_Change (Store, One, Planned, Got);
         return E.Is_Error (Got);
      end Refused;
   begin
      Task_Project (Store, "requirement-lifecycle",
                    "map requirement.state.in_review = accepted, and waiting for sign-off" & LF
                    & "set requirement.transitions = accepted -> in_review" & LF
                    & "set requirement.transitions = in_review -> accepted" & LF);
      Assert (Nt.Core_Requirement_States.Contains ("verified")
              and then Tr.Is_State (Nt.Lifecycle_Of (Store, Nt.Requirement), "in_review")
              and then not Tr.Is_State (Nt.Machine_Of (Nt.Requirement), "in_review"),
              "the project's own state was not in its lifecycle");
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.",
                  "", "user", "", "project", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted", Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Model_Runner.CLI.Intents.Run
        (Store, Nt.Requirement,
         Model_Runner.Framework.Name_Lists.To_Vector ("move", 1)
         & To_String (Req) & "in_review", Screen);
      declare
         Held : Nt.Entity;
      begin
         Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
         Assert (To_String (Held.State) = "in_review",
                 "a move the project's lifecycle allows was not made: " & To_String (Held.State));
      end;
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "verified", Tr.Ordinary_Only, Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a move the project's lifecycle does not allow was made");
      Change := S.No_Changes;

      --  Nor does a person say a requirement is implemented or verified.
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted", Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "implemented", Tr.Ordinary_Only,
               Status, Actor => Tr.User);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a person said a requirement was implemented");
      Change := S.No_Changes;
      Assert (Refused ("set.requirement.transitions", "accepted -> limbo"),
              "a move to a state whose meaning nobody said was taken");
      Assert (Refused ("map.requirement.state.verified", "whatever"),
              "a core state was given a meaning by the project");
      Assert (Refused ("map.requirement.state.pending", "waiting on someone"),
              "a project state that says nothing of how it counts was taken");
      Assert (Nt.Counts_As (Store, "in_review") = "accepted",
              "a project requirement state did not count as the core state it says");

      --  A setting read as one of some words, or as a count, is one.
      Assert (Refused ("scalar.bootstrap.import", "maybe")
              and then Refused ("scalar.execution.network", "sometimes")
              and then Refused ("scalar.execution.timeout", "long")
              and then Refused ("scalar.agents.max_steps", "-1")
              and then not Refused ("scalar.execution.network", "denied")
              and then not Refused ("scalar.execution.timeout", "30"),
              "a setting's value was not held to what the harness reads it as");

      --  A kind's own field has a schema, and its values are held to it.
      Assert (Refused ("task_kind.review", "verdict?"),
              "a kind's own field without a schema was taken");
      declare
         One : Model_Runner.Framework.Configurations.Value_Maps.Map;
         Revision : Natural;
         Id  : Unbounded_String;
      begin
         One.Include ("task_kind.review", "verdict?");
         One.Include ("map.task_field.verdict", "choice pass|fail");
         Model_Runner.Framework.Configurations.Plan_Change (Store, One, Planned, Status);
         Model_Runner.Framework.Configurations.Reconfigure (Store, Planned, Revision, Status);
         Assert (E.Is_Ok (Status), "a field with its schema was refused: " & Code_Of (Status));
         Tk.Create (Store, Change, Fields ("Judge", "review", "verdict", "maybe"), "user", "", Id,
                    Status);
         Assert (Status.Code = E.Framework_Schema_Violation
                 and then Tk.Field_Problem (Store, "verdict", "maybe") /= ""
                 and then Tk.Field_Problem (Store, "verdict", "pass") = ""
                 and then Tk.Is_Core_Field ("notes"),
                 "a value its schema does not allow was taken");
         Change := S.No_Changes;
         Tk.Create (Store, Change, Fields ("Judge", "review", "verdict", "pass"), "user", "", Id,
                    Status);
         Assert (E.Is_Ok (Status), "a value its schema allows was refused: " & Code_Of (Status));
         S.Commit (Store, Change, Status);
      end;
      S.Close (Store);
   end Requirement_Lifecycle_Is_The_Projects;

   --  A project adds task states with their meaning and moves to and from
   --  them, and takes away moves a person makes; the harness's own moves
   --  and the core states' meaning stay its.
   procedure Task_Lifecycle_Is_The_Projects
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store   : S.Store;
      Change  : S.Transaction;
      Status  : E.Error_Info;
      Id      : Unbounded_String;
      Planned : Model_Runner.Framework.Configurations.Change_Plan;

      function Refused (Name, Value : String) return Boolean is
         One : Model_Runner.Framework.Configurations.Value_Maps.Map;
         Got : E.Error_Info;
      begin
         One.Include (Name, Value);
         Model_Runner.Framework.Configurations.Plan_Change (Store, One, Planned, Got);
         return E.Is_Error (Got);
      end Refused;
   begin
      Task_Project (Store, "task-lifecycle",
                    "map task.state.parked = accepted, and set aside until the next release" & LF
                    & "set task.transitions = accepted -> parked" & LF
                    & "set task.transitions = parked -> accepted" & LF
                    & "set task.forbidden = candidate -> rejected" & LF);
      Assert (Tr.Is_State (Tk.Lifecycle_Of (Store), "parked")
              and then Tk.Core_Task_States.Contains ("verification")
              and then Tk.Forbiddable ("candidate", "rejected")
              and then not Tk.Forbiddable ("accepted", "running"),
              "the project's task lifecycle was not made");
      Tk.Create (Store, Change, Fields ("Look", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "rejected", "", Status => Status);
      Assert (Status.Code = E.Framework_Transition_Invalid, "a forbidden move was made");
      Change := S.No_Changes;
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Id), "parked", "", Status => Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Id)) = "parked",
              "a move the project added was not made: " & Code_Of (Status));
      declare
         Seen    : constant Ev.Event_List := Ev.Since (Store, 0);
         Revised : Tk.Field_Map;
      begin
         Assert (Ev.Element (Seen, Ev.Length (Seen)).Kind = Ev.Task_Moved,
                 "a move into a project's state was recorded as something else");
         Revised.Include ("notes", "waits for the release");
         Tk.Revise (Store, Change, To_String (Id), Revised, Status);
         Assert (E.Is_Ok (Status), "a task in a project's state was not revised: "
                 & Code_Of (Status));
         S.Commit (Store, Change, Status);
         Tk.Revise (Store, Change, "TASK-404", Revised, Status);
         Assert (Status.Code = E.Framework_Not_Found, "a task nobody made was revised");
         Change := S.No_Changes;
      end;
      Tk.Move (Store, Change, To_String (Id), "running", "", Status => Status);
      Assert (Status.Code = E.Framework_Transition_Invalid,
              "a move the project did not add was made from its own state");
      Change := S.No_Changes;

      --  A person does not start work, nor take a task to verification.
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "running", "", Status => Status, Actor => Tr.User);
      Assert (Status.Code = E.Framework_Transition_Invalid
              and then Tr.By_Person (Tr.User) and then not Tr.By_Person ("policy x"),
              "a person started a task without work");
      Change := S.No_Changes;
      Assert (Refused ("set.task.forbidden", "accepted -> running"),
              "a move the harness makes was taken away");
      Assert (Refused ("map.task.state.shelved", "set aside for later"),
              "a task state that says nothing of how it counts was taken");
      Assert (Tk.Counts_As (Store, "parked") = "accepted" and then Tk.Counts_As (Store, "running")
                = "running", "a project state did not count as the core state it says");
      Assert (Refused ("map.task.state.running", "whatever"),
              "a core task state was given a meaning by the project");
      Assert (Refused ("set.task.transitions", "accepted -> limbo"),
              "a move to a task state nobody defined was taken");
      S.Close (Store);
   end Task_Lifecycle_Is_The_Projects;

   --  An agent run apart is accounted as the harness's own are: what it
   --  used charged, its calls recorded; and its time is the policy's.
   procedure Work_Apart_Is_Accounted
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Id     : Unbounded_String;
      Done   : Model_Runner.Framework.Work.Report;
      Call   : R.Item;
      Held   : Model_Runner.Framework.Agents.Agent;
   begin
      Task_Project (Store, "work-apart",
                    "scalar agents.max_seconds = 900" & LF
                    & "scalar task.max_seconds.analysis = 120" & LF);
      Tk.Create (Store, Change, Fields ("Look", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Assert (Model_Runner.Framework.Work.Time_Allowed (Store, To_String (Id)) = 120,
              "a kind's own time was not the time it was allowed");
      Model_Runner.Framework.Work.Execute
        (Store, To_String (Id),
         Accounting_Agent'(Scripted_Agent'(File   => Null_Unbounded_String,
                                           Answer => To_Unbounded_String
                                                       ("status: done" & LF & "summary: looked"),
                                           Broken => False)
                           with Usage => To_Unbounded_String
                             ("prompt_tokens 300" & LF & "output_tokens 42" & LF
                              & "call read_file" & ASCII.HT & "{""path"": ""README.md""}" & LF)),
         Model_Runner.Framework.Context.Profile (Store, ""), Done, Status);
      S.Read (Store, Model_Runner.Framework.Invocations_Area, To_String (Done.Invocation_Id),
              Call, Status);
      Model_Runner.Framework.Agents.Read (Store, To_String (Done.Agent_Id), Held, Status);
      Assert (R.Get (Call, "output_tokens") = "42" and then R.Get (Call, "prompt_tokens") = "300"
              and then Ada.Strings.Fixed.Index (R.Get (Call, "call.0001"), "read_file") = 1
              and then Held.Used = 42,
              "what an agent run apart used was not accounted: " & R.Get (Call, "output_tokens")
              & " " & R.Get (Call, "call.0001"));
      S.Close (Store);
   end Work_Apart_Is_Accounted;

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
         & LF & "map model.tiny = context=120, reserve=100" & LF
         & "scalar task.output_reserve.analysis = 300" & LF);
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

      --  Without a kept graph: init keeps one, so it is taken away.
      Dirs.Delete_File (S.Root (Store) & "/indexes/repository.rec");
      Cx.Build (Store, To_String (Id), Profile, One, Status);
      Assert (E.Is_Ok (Status), "a context was not built: " & Code_Of (Status));
      Assert (Cx.Cost (One) <= 800 and then Cx.Excluded_Count (One) >= 2
              and then Cx.Budget (One) = 800,
              "a context went over its budget, or left nothing out");

      --  A kind that asks for more room for its answer gets it.
      declare
         Looked : Unbounded_String;
         Three  : Cx.Built;
      begin
         Tk.Create (Store, Change, Fields ("Look", "analysis"), "user", "", Looked, Status);
         S.Commit (Store, Change, Status);
         Cx.Build (Store, To_String (Looked), Profile, Three, Status);
         Assert (E.Is_Ok (Status) and then Cx.Budget (Three) = 600,
                 "a kind's own output reserve was not kept:" & Natural'Image (Cx.Budget (Three)));
      end;
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

      --  What the agent is told after it counts: in the cost, the
      --  manifest and the text, and in what does not fit.
      declare
         Told : Cx.Built;
      begin
         Cx.Build (Store, To_String (Id), Profile, Told, Status,
                   Instructions => "Answer in three lines.");
         Assert (E.Is_Ok (Status)
                 and then Cx.Manifest_Id (Told) /= Cx.Manifest_Id (One)
                 and then Ada.Strings.Fixed.Index (Cx.Rendered (Told), "Answer in three lines.") > 0,
                 "the instructions were not part of the context");
         Cx.Build (Store, To_String (Id), Profile, Told, Status,
                   Instructions => [1 .. 4000 => 'x']);
         Assert (Status.Code = E.Framework_Context_Overflow,
                 "instructions past the model's room were not counted");
      end;

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
      Task_Project (Store, "invocations", "scalar agents.max_invocations = 2" & LF);
      Iv.Start (Store, Change, "AGENT-1", "TASK-1", "1", "default", "CTX-1",
                "none", Iv.Work_Claim, First, Status, Resource_Class => "model 700 MiB");
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
      S.Commit (Store, Change, Status);

      --  Two calls is all this execution of the task may make; the next
      --  generation starts again.
      Iv.Start (Store, Change, "AGENT-2", "TASK-1", "1", "default", "CTX-1",
                "none", Iv.Work_Claim, Second, Status);
      Assert (Status.Code = E.Framework_Limit_Exceeded,
              "a call past the policy's bound was made");
      Change := S.No_Changes;
      Iv.Start (Store, Change, "AGENT-3", "TASK-1", "2", "default", "CTX-1",
                "none", Iv.Work_Claim, Second, Status);
      Assert (E.Is_Ok (Status), "a new execution did not get calls of its own");
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

      --  Limits set on each command where prlimit is there to set them.
      Rules.Memory_MB := 512;
      Rules.CPU_Seconds := 10;
      Ex.Run (Store, Change, Rules, "echo limited", "", Ran, Status);
      Assert ((E.Is_Ok (Status) and then Ran.Exit_Status = 0
               and then Hostkit.Process.Locate ("prlimit") /= "")
              or else (Status.Code = E.Framework_Execution_Refused
                       and then Hostkit.Process.Locate ("prlimit") = ""),
              "a limited command was neither run within its limits nor refused: "
              & Code_Of (Status));
      Rules.Memory_MB := 0;
      Rules.CPU_Seconds := 0;
      Change := S.No_Changes;

      --  No network where the policy denies it: taken away where the host
      --  can, and the command still runs either way.
      Rules.No_Network := True;
      Ex.Run (Store, Change, Rules, "echo apart", "", Ran, Status);
      Assert (E.Is_Ok (Status) and then Ran.Exit_Status = 0
              and then Index (Ran.Output, "apart") > 0,
              "a command denied the network did not run: " & Code_Of (Status));
      Rules.No_Network := False;
      Change := S.No_Changes;

      --  One process slot, held by a process that is running: nothing more
      --  runs; held by one that is gone, it is taken back.
      Rules.Process_Slots := 1;
      Dirs.Create_Path (S.Root (Store) & "/runtime/slots");
      Put_File (S.Root (Store) & "/runtime/slots/process-1",
                Ada.Strings.Fixed.Trim (Integer'Image (Hostkit.Host.Own_Process_Id),
                                        Ada.Strings.Both));
      Ex.Run (Store, Change, Rules, "echo slot", "", Ran, Status);
      Assert (Status.Code = E.Framework_Limit_Exceeded, "a command ran with no slot free");
      Put_File (S.Root (Store) & "/runtime/slots/process-1", "999999999");
      Ex.Run (Store, Change, Rules, "echo slot", "", Ran, Status);
      Assert (E.Is_Ok (Status) and then Ran.Exit_Status = 0
              and then not Dirs.Exists (S.Root (Store) & "/runtime/slots/process-1"),
              "a slot a gone process held was not taken back, or not given back: "
              & Code_Of (Status));
      Rules.Process_Slots := 0;
      Change := S.No_Changes;

      --  A cancelled run stops the command it waits on.
      declare
         Token : aliased Model_Runner.Cancellation.Token;
         use type Ada.Calendar.Time;
         Began : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      begin
         Rules.Allowed.Append ("sleep");
         Token.Request;
         Ex.Watch (Token'Unchecked_Access);
         Ex.Run (Store, Change, Rules, "sleep 20", "", Ran, Status);
         Ex.Watch (null);
         Assert (E.Is_Ok (Status) and then Ran.Cancelled
                 and then Ada.Calendar.Clock - Began < 10.0,
                 "a cancelled run did not stop its command");
      end;
      S.Close (Store);

      --  A program the harness runs itself keeps what it said on its
      --  error stream.
      declare
         Said : Ex.Outcome;
         Out_Path : constant String := Dirs.Full_Name (Scratch) & "/harness-out.txt";
      begin
         Ex.Run_Harness
           (Project   => "",
            Program   => "sh",
            Arguments => Model_Runner.Framework.Lines_Of
                           ("-c" & LF & "echo it would not start >&2; exit 3"),
            Directory => Dirs.Full_Name (Scratch),
            Output    => Out_Path,
            Timeout   => 10,
            Result    => Said);
         Assert (Said.Exit_Status = 3
                 and then Ada.Strings.Fixed.Index (To_String (Said.Output), "would not start") > 0,
                 "what a harness program said on its error stream was lost: "
                 & To_String (Said.Output));
      end;

      --  A profile whose check is cancelled judges nothing: no evidence,
      --  and the cancellation said, not a failure.
      Task_Project (Store, "cancelled-check",
                    "set execution.allowed = sleep" & LF & "profile slow = wait: sleep 20" & LF);
      declare
         Token    : aliased Model_Runner.Cancellation.Token;
         Evidence : Unbounded_String;
         Passed   : Boolean;
      begin
         Token.Request;
         Ex.Watch (Token'Unchecked_Access);
         Vf.Run_Profile (Store, Change, "slow", "", Evidence, Passed, Status);
         Ex.Watch (null);
         Change := S.No_Changes;
         Assert (Status.Code = E.Generation_Cancelled and then Length (Evidence) = 0,
                 "a cancelled check was judged: " & Code_Of (Status));
      end;
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

      --  What else a diagnostic can say: its code, the name it is about,
      --  the places it points at, and where in the raw output it was said.
      declare
         More : constant Vf.Diagnostic_List :=
           Vf.Normalize
             ("gprbuild",
              "a.adb:3:10: warning: variable ""Count"" is not referenced [-gnatwu]" & LF
              & "b.adb:5:1: error: non-visible declaration at c.ads:87" & LF
              & "d.adb:9:4: error: missing ""end"" for ""if"" at line 12" & LF
              & "error: Command [""gprbuild"", ""-s""] exited with code 4" & LF,
              Raw_Log => "RES-1");
      begin
         Assert (Vf.Length (More) = 4
                 and then To_String (Vf.Element (More, 4).Code) = ""
                 and then To_String (Vf.Element (More, 1).Code) = "-gnatwu"
                 and then To_String (Vf.Element (More, 1).Symbol) = "Count"
                 and then To_String (Vf.Element (More, 1).Raw) = "RES-1:1"
                 and then To_String (Vf.Element (More, 2).Related) = "c.ads:87"
                 and then To_String (Vf.Element (More, 3).Related) = "d.adb:12"
                 and then To_String (Vf.Element (More, 3).Raw) = "RES-1:3",
                 "a diagnostic's code, symbol, related place or raw reference was not read: ["
                 & To_String (Vf.Element (More, 1).Code) & "] ["
                 & To_String (Vf.Element (More, 2).Related) & "] ["
                 & To_String (Vf.Element (More, 3).Related) & "]");
      end;

      --  Other tools' ways of saying where: rustc's --> below the error,
      --  MSVC's FILE(LINE,COL), and the failures of AUnit and pytest.
      declare
         Foreign : constant Vf.Diagnostic_List :=
           Vf.Normalize
             ("mixed",
              "error[E0308]: mismatched types" & LF
              & "  --> src/main.rs:4:5" & LF
              & "src\\x.c(12,5): warning C4101: unreferenced local" & LF
              & "FAIL parser : rejects bad input" & LF
              & "    expected an error" & LF
              & "    at parser_tests.adb:42" & LF
              & "FAILED tests/test_io.py::test_read - AssertionError: 3 != 4" & LF);
      begin
         Assert (Vf.Length (Foreign) = 4
                 and then To_String (Vf.Element (Foreign, 1).File) = "src/main.rs"
                 and then Vf.Element (Foreign, 1).Line = 4
                 and then To_String (Vf.Element (Foreign, 1).Code) = "E0308"
                 and then Vf.Element (Foreign, 2).Line = 12 and then Vf.Element (Foreign, 2).Column = 5
                 and then To_String (Vf.Element (Foreign, 2).Severity) = "warning"
                 and then To_String (Vf.Element (Foreign, 3).File) = "parser_tests.adb"
                 and then Vf.Element (Foreign, 3).Line = 42
                 and then To_String (Vf.Element (Foreign, 4).File) = "tests/test_io.py",
                 "another tool's diagnostics were not read:" & Vf.Length (Foreign)'Image);
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
         & "scalar profile_capability.passing = run_tests" & LF
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

      --  Nothing implements it yet: its task changed no files, and no
      --  implementation is linked.
      Vf.Reevaluate_Requirements (Store, Change, Changed, Status);
      S.Commit (Store, Change, Status);
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (To_String (Held.State) = "implemented",
              "a requirement nothing implements was verified");

      --  Its task changed files: it is implemented, and verified.
      declare
         Runtime_Value : R.Item;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Id) & ".state",
                 Runtime_Value, Status);
         R.Set_Revision (Runtime_Value, R.Revision (Runtime_Value) + 1);
         R.Set (Runtime_Value, "changed_files", "src/io.adb");
         S.Put (Change, Model_Runner.Framework.Tasks_Area, To_String (Id) & ".state", Runtime_Value);
         S.Commit (Store, Change, Status);
      end;
      Vf.Reevaluate_Requirements (Store, Change, Changed, Status);
      S.Commit (Store, Change, Status);
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (To_String (Held.State) = "verified" and then Natural (Changed.Length) = 1,
              "a requirement with current evidence was not verified");

      --  Its criteria say how they are shown: one naming a check that was
      --  not run holds it back; one naming a check that passed does not.
      declare
         Effect : Nt.Impact;
      begin
         Nt.Revise (Store, Change, Nt.Requirement, To_String (Req), "Read", "It SHALL read.",
                    "It reads [check: absent]", Effect, Status);
         S.Commit (Store, Change, Status);
         Vf.Run_Profile (Store, Change, "passing", To_String (Id), Evidence, Passed, Status);
         S.Commit (Store, Change, Status);
         Vf.Reevaluate_Requirements (Store, Change, Changed, Status);
         S.Commit (Store, Change, Status);
         Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
         Assert (To_String (Held.State) = "implemented",
                 "a requirement whose criterion's check never ran was verified: "
                 & To_String (Held.State));
         Nt.Revise (Store, Change, Nt.Requirement, To_String (Req), "Read", "It SHALL read.",
                    "It reads [check: say]", Effect, Status);
         S.Commit (Store, Change, Status);
         Vf.Run_Profile (Store, Change, "passing", To_String (Id), Evidence, Passed, Status);
         S.Commit (Store, Change, Status);
         Vf.Reevaluate_Requirements (Store, Change, Changed, Status);
         S.Commit (Store, Change, Status);
         Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
         Assert (To_String (Held.State) = "verified",
                 "a requirement whose criterion's check passed was not verified: "
                 & To_String (Held.State));
      end;

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

   overriding procedure Run
     (Self        : Accounting_Agent;
      Prompt_Path : String;
      Project     : String;
      Answer      : out Unbounded_String;
      Status      : out E.Error_Info) is
   begin
      Run (Scripted_Agent (Self), Prompt_Path, Project, Answer, Status);
      Put_File (Model_Runner.Framework.Work.Usage_Beside (Prompt_Path), To_String (Self.Usage));
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
      Assert (Tk.Ready (Store, To_String (Ids (1))).Reasons.First_Element = "it is complete already",
              "the task's lease was not let go");

      --  Its agent worked in the generation its move to running began, and
      --  ended as any agent does: with its result, and an event saying so.
      declare
         Agent : R.Item;
         State : R.Item;
         Events : constant Model_Runner.Framework.Events.Event_List :=
           Model_Runner.Framework.Events.Since (Store, 0);
         Said   : Boolean := False;
         Moved  : Boolean := False;
      begin
         S.Read (Store, Model_Runner.Framework.Runtime_Area, "agent." & To_String (Done.Agent_Id),
                 Agent, Status);
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Ids (1)) & ".state",
                 State, Status);
         for Index in 1 .. Model_Runner.Framework.Events.Length (Events) loop
            Said := Said
              or else (Model_Runner.Framework.Events.Element (Events, Index).Kind
                         = Model_Runner.Framework.Events.Agent_Completed
                       and then To_String (Model_Runner.Framework.Events.Element
                                             (Events, Index).Subject) = To_String (Done.Agent_Id));
            --  A task's move is about the task, not its state record.
            Moved := Moved
              or else (Model_Runner.Framework.Events.Element (Events, Index).Kind
                         = Model_Runner.Framework.Events.Task_Completed
                       and then To_String (Model_Runner.Framework.Events.Element
                                             (Events, Index).Subject) = To_String (Ids (1)));
         end loop;
         Assert (Moved, "a task's completion was not an event about the task");
         Assert (R.Get (Agent, "generation") = R.Get (State, "generation")
                 and then R.Get (Agent, "state") = "completed"
                 and then R.Get (Agent, "result") /= "" and then Said,
                 "the root agent's generation or end was not recorded: ["
                 & R.Get (Agent, "generation") & "] [" & R.Get (State, "generation") & "] "
                 & R.Get (Agent, "state") & " [" & R.Get (Agent, "result") & "]");
      end;

      --  Done, it says; but the check fails once the file is gone.
      Dirs.Delete_File (Fresh_Root (Store) & "/src/hello.adb");
      Wk.Execute (Store, To_String (Ids (2)),
                  Scripted_Agent'(File => Null_Unbounded_String,
                                  Answer => To_Unbounded_String (Good), Broken => False),
                  Model, Done, Status);
      Assert (To_String (Done.Final_State) = "failed" and then Done.Changed_Files.Is_Empty,
              "an agent's claim was taken over the failing check, or a change"
              & " it did not make was put on it: " & To_String (Done.Final_State));
      declare
         View : R.Item;
      begin
         Tk.Effective (Store, To_String (Ids (2)), View, Status);
         Assert (R.Get (View, "runtime.current_failure") = To_String (Done.Reason)
                 and then R.Get (View, "runtime.current_failure") /= "",
                 "the effective task does not say why it failed");
      end;

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
      declare
         Call : R.Item;
         Kept : Model_Runner.Framework.Results.Result;
      begin
         S.Read (Store, Model_Runner.Framework.Invocations_Area, To_String (Done.Invocation_Id),
                 Call, Status);
         Model_Runner.Framework.Results.Read (Store, R.Get (Call, "failure_result"), Kept, Status);
         Assert (E.Is_Ok (Status) and then Length (Kept.Payload) > 0,
                 "a failed call did not refer to a record of its failure: "
                 & R.Get (Call, "failure_result"));
      end;
      Assert (To_String (Done.Final_State) = "failed"
              and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "MR-") > 0,
              "a broken agent did not fail its task, saying why by its code: "
              & To_String (Done.Reason));

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
      Options : Model_Runner.CLI.Project_Requests.Request;
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

      --  Checked where it was written, before it was taken in: evidence of
      --  the workspace, which never stands for the project.
      declare
         Taken_There : R.Item;
         Reasons     : Model_Runner.Framework.Name_Lists.Vector;
      begin
         S.Read (Store, Model_Runner.Framework.Verification_Area, To_String (Done.Evidence_Id),
                 Taken_There, Status);
         Assert (E.Is_Ok (Status) and then R.Get (Taken_There, "passed") = "true"
                 and then R.Get (Taken_There, "workspace") /= ""
                 and then R.Get (Taken_There, "workspace_revision")
                          /= R.Get (Taken_There, "repository_revision")
                 and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "checked in it: passed") > 0,
                 "isolated work was not checked in its workspace: " & To_String (Done.Reason));
         Assert (not Vf.Is_Current (Store, To_String (Done.Evidence_Id), Reasons)
                 and then Ada.Strings.Fixed.Index (Reasons.First_Element, "workspace") > 0,
                 "evidence of a workspace stood for the project");
      end;
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

      declare
         Other : Unbounded_String;
         Taken : Wk.Report;
      begin
         Tk.Create (Store, Change, Fields ("Not waiting", "analysis"), "user", "", Other, Status);
         S.Commit (Store, Change, Status);
         Wk.Take_In (Store, To_String (Other), Taken, Status);
         Assert (Status.Code = E.Framework_Transition_Invalid,
                 "work was taken in for a task not waiting for it: " & Code_Of (Status));
      end;
      Wk.Take_In (Store, To_String (Id), Done, Status);
      Assert (E.Is_Ok (Status) and then To_String (Done.Final_State) = "complete"
              and then Dirs.Exists (Fresh_Root (Store) & "/src/hello.adb"),
              "taken in and verified on the project, the task did not complete: "
              & Code_Of (Status) & " " & To_String (Done.Reason));
      declare
         Runtime_Value : R.Item;
         Report_Held   : Model_Runner.Framework.Results.Result;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Id) & ".state",
                 Runtime_Value, Status);
         Model_Runner.Framework.Results.Read
           (Store, R.Get (Runtime_Value, "integration_report"), Report_Held, Status);
         Assert (R.Get (Runtime_Value, "current_verification") /= ""
                 and then E.Is_Ok (Status)
                 and then Ada.Strings.Fixed.Index (To_String (Report_Held.Payload), "src/hello.adb") > 0,
                 "work taken in by hand left no verification or integration report behind");
      end;

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

      --  No file on both sides, but the code joins them: the workspace
      --  changes Parser, the project changes Lexer, which Parser withs.
      Put_File (Fresh_Root (Store) & "/src/lexer.ads", "package Lexer is" & LF & "end Lexer;" & LF);
      Put_File (Fresh_Root (Store) & "/src/parser.ads",
                "with Lexer;" & LF & "package Parser is" & LF & "end Parser;" & LF);
      Ws.Create (Store, Change, To_String (Other), "AG-TEST", "2", False, Made, Status);
      S.Commit (Store, Change, Status);
      Put_File (To_String (Made.Path) & "/src/parser.ads",
                "with Lexer;" & LF & "package Parser is" & LF & "   procedure Next;" & LF
                & "end Parser;" & LF);
      Put_File (Fresh_Root (Store) & "/src/lexer.ads",
                "package Lexer is" & LF & "   Limit : constant := 1;" & LF & "end Lexer;" & LF);
      Assert (Ws.Conflicts (Store, To_String (Made.Id)).Is_Empty
              and then Natural (Ws.Semantic_Conflicts (Store, To_String (Made.Id)).Length) = 1
              and then Ada.Strings.Fixed.Index
                         (Ws.Semantic_Conflicts (Store, To_String (Made.Id)).First_Element,
                          "Parser depends on Lexer") > 0,
              "a change the project's own change reaches through the code was not seen");
      Ws.Integrate (Store, Change, To_String (Made.Id), True, Taken, Status);
      Assert (Status.Code = E.Framework_Integration_Conflict,
              "work the code joins to the project's change was taken in unasked");
      Change := S.No_Changes;
      Ws.Integrate (Store, Change, To_String (Made.Id), True, Taken, Status,
                    Semantic_Accepted => True);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then Taken.Contains ("src/parser.ads"),
              "work taken in anyway was not taken in: " & Code_Of (Status));

      --  Taken in and failing its checks, a task fails and says why; it is
      --  never left waiting in verification.
      declare
         Fourth : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Fourth", "analysis"), "user", "", Fourth, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Fourth), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Fourth),
                     Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                     Answer => To_Unbounded_String (Good), Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
         --  The work removes the file the checks want.
         declare
            Space : Ws.Workspace;
         begin
            Ws.Read (Store, To_String (Done.Workspace_Id), Space, Status);
            Dirs.Delete_File (To_String (Space.Path) & "/src/hello.adb");
         end;
         Wk.Take_In (Store, To_String (Fourth), Done, Status);
         Assert (E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Fourth)) = "failed"
                 and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "did not pass") > 0,
                 "work taken in that failed its checks was left waiting: " & Code_Of (Status) & " "
                 & Tk.State_Of (Store, To_String (Fourth)) & " " & To_String (Done.Reason));
      end;

      --  A task waiting in verification with its workspace, cancelled: the
      --  workspace goes with it, and who cancelled it is kept.
      declare
         Third : Unbounded_String;
         Place : Unbounded_String;
         Held  : Ws.Workspace;
         View  : R.Item;
      begin
         Tk.Create (Store, Change, Fields ("Third", "analysis"), "user", "", Third, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Third), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         --  Its work passes its checks where it was written -- the file
         --  they want is written back -- so it waits to be taken in.
         Wk.Execute (Store, To_String (Third),
                     Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                     Answer => To_Unbounded_String (Good), Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
         Place := Done.Workspace_Id;
         Assert (To_String (Done.Final_State) = "verification" and then Length (Place) > 0,
                 "the third task did not wait in verification with a workspace");
         Wk.Cancel (Store, To_String (Third), Status, Actor => Tr.User);
         Ws.Read (Store, To_String (Place), Held, Status);
         Tk.Effective (Store, To_String (Third), View, Status);
         Assert (Tk.State_Of (Store, To_String (Third)) = "cancelled"
                 and then To_String (Held.Status) = "abandoned"
                 and then Ws.Active_For (Store, To_String (Third)) = ""
                 and then R.Get (View, "runtime.moved_by") = Tr.User,
                 "cancelling a task in verification kept its workspace: "
                 & To_String (Held.Status));
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
      Put_File (Fresh_Root (Store) & "/tests/acceptance.adb",
                "procedure Acceptance is" & LF & "begin" & LF & "   null;" & LF
                & "end Acceptance;" & LF);

      Nt.Propose (Store, Change, Nt.Requirement, "PARSER", "Next", "It SHALL advance.",
                  "", "user", "", "parser", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);

      --  A test the requirement names, which nothing in the code links to.
      Nt.Link (Store, Change, Nt.Requirement, To_String (Req), Nt.Test,
               "tests/acceptance.adb", Status);
      S.Commit (Store, Change, Status);
      Given := Fields ("Next", "implementation", "component", "parser");
      Given.Include ("requirements", To_String (Req));
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);

      Graph := Tc.Build (Store, Rp.Scan (Fresh_Root (Store)));
      Assert (Tc.Edge_Count (Graph) > 0
              and then not Tc.Touching (Graph, To_String (Req) & "@1").Is_Empty,
              "the traceability graph does not reach the requirement");
      Assert (not Tc.Touching (Graph, To_String (Req)).Is_Empty
              and then not Tc.Touching (Graph, "src/parser.ads").Is_Empty,
              "a requirement or a file named as a person names it was not traced");
      declare
         One : constant Tc.Edge :=
           Tc.Edge_At (Graph, Natural'Value
                         (Tc.Touching (Graph, To_String (Req) & "@1").First_Element));
         use type Rp.Derivation;
      begin
         Assert (One.Source = Rp.Explicit and then Length (One.Record_Of) > 0
                 and then Length (One.Created_At) > 0,
                 "a recorded edge does not say it was recorded, or where, or when");
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
      Assert (Chosen.Tests.Contains ("tests/acceptance.adb"),
              "the test a reached requirement names was not chosen");

      --  From a symbol rather than a file: what refers to it is reached.
      Changed.Clear;
      Changed.Append ("symbol:Parser.Next");
      Reach := Tc.Impact_Of (Graph, Changed);
      Assert (Reached ("symbol:Parser.Next", Sure) and then Sure = Rp.Certain
              and then Has ("file:src/main.adb"),
              "a changed symbol did not reach what refers to it");

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
         Assert (not Widening, "configuration clamped to the project's was taken for broken");
      end;

      --  The run's own sandbox is the lowest level: set, it narrows every
      --  agent; one that does not read changes nothing; off, it is gone.
      --  What is found is asserted once the sandbox is off again, so that a
      --  failure here does not confine the cases after it.
      declare
         Status  : E.Error_Info;
         Screen  : Model_Runner.Presentation.Console;
         Agent   : Scripted_Agent;
         Narrows, Kept, Freed, Whole : Boolean;
      begin
         Pm.Set_Sandbox ("run_tests: profiles=quick", Status);
         Narrows := E.Is_Ok (Status)
           and then not Pm.Allows (Pm.Effective (Store, "", ""), Pm.Write_Source, "src/x.adb")
           and then Pm.Allows_Profile (Pm.Effective (Store, "", ""), Pm.Run_Tests, "quick")
           and then not Pm.Allows_Profile (Pm.Effective (Store, "", ""), Pm.Run_Tests, "full");
         Pm.Set_Sandbox ("fly", Status);
         Kept := E.Is_Error (Status) and then not Pm.Sandbox (Pm.Write_Source).Granted
           and then Pm.Sandbox (Pm.Run_Tests).Granted;
         Model_Runner.CLI.Project_Commands.Run ("/sandbox off", Screen, Agent);
         Freed := Pm.Allows (Pm.Effective (Store, "", ""), Pm.Write_Source, "src/x.adb")
           and then Ada.Environment_Variables.Value (Pm.Sandbox_Variable, "") = "";
         Model_Runner.CLI.Project_Commands.Run ("/sandbox write_source: roots=src/", Screen, Agent);
         Whole := Pm.Allows (Pm.Sandbox, Pm.Write_Source, "src/x.adb")
           and then not Pm.Allows (Pm.Sandbox, Pm.Write_Source, "docs/x.md");
         Pm.Set_Sandbox ("", Status);
         Assert (Narrows, "a sandbox did not narrow what agents may do");
         Assert (Kept, "a sandbox that does not read changed the one there");
         Assert (Freed, "/sandbox off did not free the run");
         Assert (Whole, "/sandbox did not take its constraints whole");
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
      Apart_Search : Dirs.Search_Type;
      Apart_Entry  : Dirs.Directory_Entry_Type;
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
      declare
         Held : Ag.Agent;
      begin
         Ag.Record_Holding (Store, Change, To_String (First), "WS-000009", "INV-000009", Status);
         S.Commit (Store, Change, Status);
         Ag.Read (Store, To_String (First), Held, Status);
         Assert (To_String (Held.Children) = To_String (Grand)
                 and then To_String (Held.Workspace) = "WS-000009"
                 and then To_String (Held.Invocation) = "INV-000009",
                 "an agent's record does not say what it holds: " & To_String (Held.Children));
      end;
      Ag.Spawn_Child (Store, Change, To_String (Grand), "deeper", Ag.Required,
                      Pm.Unrestricted, 10, Third, Status);
      Assert (Status.Code = E.Framework_Limit_Exceeded,
              "a child past the depth limit was made");
      declare
         At_Limit : Ag.Agent;
         Read     : E.Error_Info;
      begin
         Ag.Read (Store, To_String (Grand), At_Limit, Read);
         Assert (E.Is_Ok (Read) and then not At_Limit.Allowed (Pm.Create_Children).Granted,
                 "an agent at the depth limit was said to be able to make children");
      end;

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
      Assert (Ag.May_Complete (Store, To_String (First), Reason, Past_Failures => True),
              "a parent the policy lets go on another way was held by a failed child");
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

      --  A payload too large for its record is kept apart, read when asked
      --  for, and found out when it is damaged.
      declare
         Large : Rs.Result :=
           (Kind       => Rs.Verification,
            Producer   => To_Unbounded_String ("execution"),
            Summary    => To_Unbounded_String ("a long build"),
            Payload    => To_Unbounded_String (String'(1 .. Rs.Inline_Limit + 10 => 'y')),
            others     => <>);
         Back  : Rs.Result;
         Files_Apart : Model_Runner.Framework.Name_Lists.Vector;
      begin
         Change := S.No_Changes;
         Rs.Add (Store, Change, Large, Status);
         S.Commit (Store, Change, Status);
         Rs.Read (Store, To_String (Large.Id), Back, Status, With_Payload => False);
         Assert (E.Is_Ok (Status) and then Length (Back.Payload) = 0
                 and then Rs.Payload_Size (Store, To_String (Large.Id)) = Rs.Inline_Limit + 10,
                 "a large payload was read when it was not asked for");
         Rs.Read (Store, To_String (Large.Id), Back, Status);
         Assert (E.Is_Ok (Status) and then Back.Payload = Large.Payload,
                 "a large payload did not read back whole: " & Code_Of (Status));
         Dirs.Start_Search (Apart_Search, S.Root (Store) & "/results/payloads", "*.txt");
         while Dirs.More_Entries (Apart_Search) loop
            Dirs.Get_Next_Entry (Apart_Search, Apart_Entry);
            Files_Apart.Append (Dirs.Full_Name (Apart_Entry));
         end loop;
         Dirs.End_Search (Apart_Search);
         Assert (Natural (Files_Apart.Length) = 1, "a large payload was not kept apart");
         Put_File (Files_Apart.First_Element, "damaged");
         Rs.Read (Store, To_String (Large.Id), Back, Status);
         Assert (Status.Code = E.Framework_Integrity_Failed,
                 "a damaged payload kept apart was returned");

         --  Stored again, a damaged payload is written whole again; one
         --  nothing refers to is collected, and one a result does is kept.
         Change := S.No_Changes;
         Rs.Add (Store, Change, Large, Status);
         S.Commit (Store, Change, Status);
         Rs.Read (Store, To_String (Large.Id), Back, Status);
         Assert (E.Is_Ok (Status) and then Back.Payload = Large.Payload,
                 "a damaged payload was not written again: " & Code_Of (Status));
         Put_File (S.Root (Store) & "/results/payloads/ORPHAN.txt", "left behind");
         declare
            Collected : Natural;
         begin
            Rs.Collect_Payloads (Store, Collected);
            Assert (Collected = 1
                    and then not Dirs.Exists (S.Root (Store) & "/results/payloads/ORPHAN.txt")
                    and then Dirs.Exists (Files_Apart.First_Element),
                    "payloads were not collected as their results say");
         end;
      end;

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
      --  And what it wrote there is put back as it was: a file it made,
      --  gone.
      Assert (Ada.Strings.Fixed.Index (To_String (Done.Reason), "put back") > 0
              and then not Dirs.Exists (Dirs.Containing_Directory (S.Root (Store)) & "/src/hello.adb"),
              "a file an agent may not write was left in the project: " & To_String (Done.Reason));
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
      declare
         Defined : R.Item;
      begin
         Tk.Definition (Store, Done.Proposed.First_Element, Defined, Status);
         Assert (R.Get (Defined, "created_by") = "agent " & To_String (Done.Agent_Id)
                 and then R.Get (Defined, "origin") = To_String (Done.Task_Id),
                 "a proposed task does not say which agent made it, from which task: "
                 & R.Get (Defined, "created_by") & " / " & R.Get (Defined, "origin"));
      end;

      --  Proposed again, it is made once; one that cannot be made is said
      --  with why, not dropped.
      Work (Proposing & LF & "Fix the parser; kind=nowhere");
      Assert (Done.Proposed.Is_Empty and then Natural (Done.Kept_Back.Length) = 3
              and then Contains (Done.Kept_Back.First_Element, "already")
              and then Contains (Done.Kept_Back.Last_Element, "nowhere is not a kind"),
              "proposals made twice or dropped unsaid: "
              & (if Done.Kept_Back.Is_Empty then "" else Done.Kept_Back.Last_Element));

      --  A runner is asked whether it can start before its task moves,
      --  and says what it is for the record.
      declare
         Runner : constant Scripted_Agent :=
           (File => Null_Unbounded_String, Answer => Null_Unbounded_String, Broken => False);
         Asked  : E.Error_Info := E.Success;
         Named  : Unbounded_String;
      begin
         Runner.Check_Start (Store, Asked);
         Runner.Describe (Named);
         Assert (E.Is_Ok (Asked) and then Named = Null_Unbounded_String,
                 "a runner that says nothing stopped its start or said something");
      end;
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

         --  What is only a cache goes after its own days.
         declare
            Cached : Rs.Result :=
              (Kind => Rs.Impact_Report, Producer => To_Unbounded_String ("impact"),
               Summary => To_Unbounded_String ("cached"), Payload => To_Unbounded_String ("w"),
               others => <>);
         begin
            Rs.Add (Store, Change, Cached, Status);
            S.Commit (Store, Change, Status);
            Age (To_String (Cached.Id));
            S.Commit (Store, Change, Status);
            Rs.Prune (Store, Change, Raw_Log_Days => 0, Context_Days => 0, Removed => Removed,
                      Cache_Days => 7);
            S.Commit (Store, Change, Status);
            Assert (Removed = 1
                    and then not S.Exists (Store, Model_Runner.Framework.Results_Area,
                                           To_String (Cached.Id))
                    and then S.Exists (Store, Model_Runner.Framework.Results_Area,
                                       To_String (Kept.Id)),
                    "a cache-like result was not let go after its days, or a kept one was");
         end;
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
            declare
               use type Rp.Confidence;
               One : constant Rp.Relation := Rp.Relation_At (Found, Index);
            begin
               Kinds (One.Kind) := True;
               --  Names in the text are not resolved: no more than probable,
               --  and which operation is overridden not known at all.
               Assert ((One.Kind not in Rp.Instantiates | Rp.Extends | Rp.Implements_Interface
                        or else One.Sure = Rp.Probable)
                       and then (One.Kind /= Rp.Overrides or else One.Sure = Rp.Uncertain),
                       "the adapter claimed a certainty it does not have");
            end;
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
      --  What it says without being able to propose is an issue, kept to be
      --  seen, not a proposal.
      declare
         Held  : Model_Runner.Framework.Results.Result;
         Found : Boolean := False;
      begin
         for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
            Model_Runner.Framework.Results.Read (Store, Name, Held, Status);
            Found := Found
              or else (E.Is_Ok (Status)
                       and then Held.Kind = Model_Runner.Framework.Results.Diagnostic
                       and then Ada.Strings.Fixed.Index (To_String (Held.Payload), "TASK-999") > 0);
         end loop;
         Assert (Found, "what an agent says it waits for was not kept as an issue");
      end;
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

      --  A parent whose work its children did has what they changed.
      declare
         Parent, Child : Unbounded_String;
         Runtime_Value : R.Item;
         Judged        : Vf.Gate_List;
         Present       : Boolean := False;
      begin
         Tk.Create (Store, Change, Fields ("Whole", "analysis"), "user", "", Parent, Status);
         S.Commit (Store, Change, Status);
         Tk.Create (Store, Change, Fields ("Part", "analysis", "parent", To_String (Parent)),
                    "user", "", Child, Status);
         S.Commit (Store, Change, Status);
         for Next of Model_Runner.Framework.Name_Lists.Vector'
           (["accepted", "running", "verification"])
         loop
            Tk.Move (Store, Change, To_String (Child), Next, "", Status => Status);
            S.Commit (Store, Change, Status);
         end loop;
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Child) & ".state",
                 Runtime_Value, Status);
         R.Set_Revision (Runtime_Value, R.Revision (Runtime_Value) + 1);
         R.Set (Runtime_Value, "changed_files", "src/part.adb");
         S.Put (Change, Model_Runner.Framework.Tasks_Area, To_String (Child) & ".state",
                Runtime_Value);
         Tk.Move (Store, Change, To_String (Child), "complete", "", Gates_Passed => True,
                  Status => Status);
         S.Commit (Store, Change, Status);
         Judged := Vf.Gates (Store, To_String (Parent));
         for Index in 1 .. Vf.Length (Judged) loop
            if To_String (Vf.Element (Judged, Index).Name) = "implementation_present" then
               Present := Vf.Element (Judged, Index).Passed;
            end if;
         end loop;
         Assert (Present, "a parent's children's changes were not its implementation");
      end;

      --  Complete without having changed anything its gate asks for: the
      --  consistency check sees it.
      declare
         Hollow   : Unbounded_String;
         Found_It : Boolean := False;
      begin
         Tk.Create (Store, Change, Fields ("Hollow", "analysis"), "user", "", Hollow, Status);
         S.Commit (Store, Change, Status);
         for Next of Model_Runner.Framework.Name_Lists.Vector'
           (["accepted", "running", "verification"])
         loop
            Tk.Move (Store, Change, To_String (Hollow), Next, "", Status => Status);
            S.Commit (Store, Change, Status);
         end loop;
         Tk.Move (Store, Change, To_String (Hollow), "complete", "", Gates_Passed => True,
                  Status => Status);
         S.Commit (Store, Change, Status);
         declare
            Findings : constant Cn.Finding_List := Cn.Check (Store);
         begin
            for Index in 1 .. Cn.Length (Findings) loop
               Found_It := Found_It
                 or else (To_String (Cn.Element (Findings, Index).Subject) = To_String (Hollow)
                          and then Ada.Strings.Fixed.Index
                                     (To_String (Cn.Element (Findings, Index).Detail),
                                      "implementation_present") > 0);
            end loop;
         end;
         Assert (Found_It, "a complete task whose gate does not hold was not found");
      end;
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
      Machine : constant Tr.Machine := Tr.Task_Machine;
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
         & "map component.parser = roots=src/parse/|tests/parse/" & LF
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
      Change := S.No_Changes;
      Tk.Create (Store, Change, Fields ("Kindless", ""), "user", "", Id, Status);
      Assert (Status.Code = E.Framework_Input_Missing
              and then Ada.Strings.Fixed.Index
                         (Model_Runner.Text.To_String (Status.Parameters (1).Text_Value),
                          "kind (") = 1,
              "a missing kind did not say which it may be");
      Change := S.No_Changes;
      Tk.Create (Store, Change, Fields ("Other", "implementation", "component", "nowhere"),
                 "user", "", Id, Status);
      Assert (Model_Runner.Framework.Repository.In_Component (Store, "parser", "src/parse/x.adb")
              and then Model_Runner.Framework.Repository.In_Component (Store, "parser", "./tests/parse/t.adb")
              and then not Model_Runner.Framework.Repository.In_Component
                             (Store, "parser", "src/parser_other/x.adb"),
              "a component's declared roots did not say which files are its");
      Assert (not Model_Runner.Framework.Repository.In_Component (Store, "lexer", "src/lexer.adb")
              and then Model_Runner.Framework.Repository.Component_Roots (Store, "lexer").Is_Empty,
              "a component with no roots declared was given some");
      Assert (Status.Code = E.Framework_Schema_Violation
              and then Tk.Components (Store).Contains ("lexer")
              and then not Tk.Components (Store).Contains ("nowhere"),
              "an unlisted component was taken");
      Change := S.No_Changes;
      Tk.Create (Store, Change, Fields ("Lex again", "implementation", "component", "lexer"),
                 "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Revised.Include ("component", "nowhere");
      Tk.Revise (Store, Change, To_String (Id), Revised, Status);
      Assert (Status.Code = E.Framework_Input_Invalid,
              "a task was revised to an unlisted component");
      Change := S.No_Changes;

      --  A decision for one component governs that component's work, not
      --  another's, and two for different components do not conflict.
      declare
         For_Lexer, For_Parser : Unbounded_String;
         View     : R.Item;
         Clash    : Boolean := False;
         use type Model_Runner.Framework.Consistency.Finding_Kind;
      begin
         Nt.Propose (Store, Change, Nt.Decision, "", "Lexer isolated", "Apart.", "",
                     "user", "", "lexer", For_Lexer, Status);
         Nt.Propose (Store, Change, Nt.Decision, "", "Parser in place", "In place.", "",
                     "user", "", "parser", For_Parser, Status);
         S.Commit (Store, Change, Status);
         for Dec of Model_Runner.Framework.Name_Lists.Vector'([To_String (For_Lexer),
                                                              To_String (For_Parser)])
         loop
            Nt.Move (Store, Change, Nt.Decision, Dec, "accepted", Tr.Ordinary_Only, Status);
         end loop;
         S.Commit (Store, Change, Status);
         Nt.Govern (Store, Change, Nt.Decision, To_String (For_Lexer), "scalar.work.isolation",
                    "workspace", "", Status);
         Nt.Govern (Store, Change, Nt.Decision, To_String (For_Parser), "scalar.work.isolation",
                    "project", "", Status);
         S.Commit (Store, Change, Status);
         Tk.Effective (Store, To_String (Id), View, Status);
         declare
            Findings : constant Model_Runner.Framework.Consistency.Finding_List :=
              Model_Runner.Framework.Consistency.Check (Store);
         begin
            for Index in 1 .. Model_Runner.Framework.Consistency.Length (Findings) loop
               Clash := Clash
                 or else Model_Runner.Framework.Consistency.Element (Findings, Index).Kind
                           = Model_Runner.Framework.Consistency.Conflicting_Authority;
            end loop;
         end;
         Assert (Ada.Strings.Fixed.Index (R.Get (View, "authority.scalar.work.isolation"),
                                          To_String (For_Lexer)) > 0
                 and then Ada.Strings.Fixed.Index (R.Get (View, "authority.scalar.work.isolation"),
                                                   To_String (For_Parser)) = 0
                 and then not Clash,
                 "a component's decision governed another's work, or clashed with it: "
                 & R.Get (View, "authority.scalar.work.isolation"));
      end;

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
      Assert (R.Get (Value, "harness_version") = Model_Runner.Version,
              "evidence did not say which harness -- and so which adapters -- took it");
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
      declare
         Before : R.Item;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (A) & ".rev-000001", Before,
                 Status);
         Assert (E.Is_Ok (Status) and then R.Get (Before, "title") = "First"
                 and then not Tk.List (Store).Contains (To_String (A) & ".rev-000001"),
                 "a task's earlier revision was written over, or taken for a task");
      end;
      Revise_Fields.Clear;
      Revise_Fields.Include ("kind", "implementation");
      Tk.Revise (Store, Change, To_String (A), Revise_Fields, Status);
      Assert (Status.Code = E.Framework_Input_Invalid, "a task's kind was revised");
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

      --  A part cannot wait for the parent that waits for it.
      Tk.Add_Dependency (Store, Change, Made.First_Element, To_String (A), Status);
      Assert (Status.Code = E.Framework_Dependency_Cycle,
              "a part was made to wait for its own parent");
      Change := S.No_Changes;

      --  Split while a candidate, it waits on its parts once accepted.
      declare
         Early : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Split early", "analysis"), "user", "", Early, Status);
         S.Commit (Store, Change, Status);
         Tk.Decompose (Store, Change, To_String (Early), Parts, Made, Status);
         S.Commit (Store, Change, Status);
         Assert (Tk.State_Of (Store, To_String (Early)) = "candidate",
                 "a candidate split was moved");
         Tk.Move (Store, Change, To_String (Early), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Assert (E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Early)) = "blocked",
                 "a candidate split and then accepted did not wait on its parts: "
                 & Tk.State_Of (Store, To_String (Early)) & " " & Code_Of (Status));

         --  Its parts turned down, it goes back to work, and they hold
         --  nothing of its completion.
         declare
            Became : Model_Runner.Framework.Name_Lists.Vector;
            Judged : Vf.Gate_List;
         begin
            for Part of Made loop
               Tk.Move (Store, Change, Part, "rejected", "", Status => Status);
            end loop;
            S.Commit (Store, Change, Status);
            Tk.Recompute_Readiness (Store, Change, Became, Status);
            S.Commit (Store, Change, Status);
            Judged := Vf.Gates (Store, To_String (Early));
            Assert (Tk.State_Of (Store, To_String (Early)) = "accepted"
                    and then (for all Index in 1 .. Vf.Length (Judged) =>
                                To_String (Vf.Element (Judged, Index).Name) /= "children"
                                or else Vf.Element (Judged, Index).Passed),
                    "a parent whose parts were rejected still waits on them: "
                    & Tk.State_Of (Store, To_String (Early)));
         end;
      end;

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
      Tk.Decompose (Store, Change, To_String (C), Parts, Made, Status);
      Assert (Status.Code = E.Framework_Transition_Invalid, "an ended task was split");
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
      Evidence : Unbounded_String;
      Reasons  : Model_Runner.Framework.Name_Lists.Vector;

      --  Evidence taken for one test, and then a file changed that no test
      --  is known to depend on.
      procedure Scoped (Name, Policy : String) is
         Change : S.Transaction;
         Id     : Unbounded_String;
         Passed : Boolean;
      begin
         Task_Project
           (Store, Name,
            "set execution.allowed = test" & LF
            & "profile checks = exists: test -f src/hello.adb" & LF & Policy);
         Ada.Directories.Create_Path (Fresh_Root (Store) & "/src");
         Put_File (Fresh_Root (Store) & "/src/hello.adb", "procedure Hello is begin null; end Hello;");
         Tk.Create (Store, Change, Fields ("Scoped", "analysis"), "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         Vf.Run_Profile
           (Store, Change, "checks", To_String (Id), Evidence, Passed, Status,
            Given => Model_Runner.Framework.Lines_Of
                       ("scope=certain_tests" & LF & "tests=tests/hello_test.adb"));
         S.Commit (Store, Change, Status);
         S.Read (Store, Model_Runner.Framework.Verification_Area, To_String (Evidence),
                 Value, Status);
         Assert (Passed and then R.Get (Value, "scope_files") /= "",
                 "scoped evidence did not record the files it was taken on");
         Put_File (Fresh_Root (Store) & "/changed.txt", "new");
      end Scoped;

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
         & "scalar profile_capability.checks = run_tests" & LF
         & "scalar verification.default = checks" & LF);
      Work ("Whole");
      Assert (To_String (Done.Final_State) = "complete"
              and then To_String (Done.Scope) = "full_suite"
              and then Length (Done.Scope_Reason) > 0,
              "work was not verified whole, with why: " & To_String (Done.Scope) & " "
              & To_String (Done.Reason));

      --  A requirement the work served is judged with the task complete:
      --  judged before that was kept, the task still stood in verification.
      declare
         Change : S.Transaction;
         Req, Id : Unbounded_String;
         Given  : Tk.Field_Map := Fields ("Served", "analysis");
         Held   : Nt.Entity;
      begin
         Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                     "user", "", "io", Req, Status);
         Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
                  Tr.Ordinary_Only, Status);
         S.Commit (Store, Change, Status);
         Given.Include ("requirements", To_String (Req));
         Tk.Create (Store, Change, Given, "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id),
                     Scripted_Agent'(File => To_Unbounded_String ("src/served.adb"),
                                     Answer => To_Unbounded_String
                                       ("status: done" & LF & "summary: x"),
                                     Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
         Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
         Assert (To_String (Done.Final_State) = "complete"
                 and then To_String (Held.State) = "verified"
                 and then Natural (Done.Requirements.Length) = 1,
                 "work that completed did not verify the requirement it served: "
                 & To_String (Held.State));
      end;
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

      --  Evidence for some tests stays current while what changes does
      --  not reach them, and not once something does.
      S.Close (Store);
      Scoped ("scoped-current", "scalar verification.escalation = narrow" & LF);
      Assert (Vf.Is_Current (Store, To_String (Evidence), Reasons),
              "evidence for some tests went stale over a change that reaches none of them: "
              & (if Reasons.Is_Empty then "" else Reasons.First_Element));
      S.Close (Store);
      Scoped ("scoped-stale", "");
      Assert (not Vf.Is_Current (Store, To_String (Evidence), Reasons)
              and then not Reasons.Is_Empty,
              "evidence for some tests stayed current over a change nothing can trace");
      S.Close (Store);
   end Verification_Follows_What_Changed;

   --  Work taken in by the harness on its own is reported as work taken in
   --  by hand is, and its workspace goes once that is kept; a Git
   --  workspace starts from the project as it is, not as it was committed.
   procedure Workspaces_Start_And_End_Whole
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Id     : Unbounded_String;
      Done   : Wk.Report;
      Made   : Ws.Workspace;
      Taken  : Model_Runner.Framework.Name_Lists.Vector;
   begin
      Task_Project
        (Store, "auto-integrate",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF
         & "scalar work.isolation = workspace" & LF
         & "scalar work.integrate = automatic" & LF
         & "map permission.project.read_source =" & LF
         & "map permission.project.write_source =" & LF
         & "map permission.project.run_tests =" & LF
         & "map permission.project.request_integration =" & LF);
      Tk.Create (Store, Change, Fields ("Apart", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Execute (Store, To_String (Id),
                  Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                  Answer => To_Unbounded_String
                                    ("status: done" & LF & "summary: x"),
                                  Broken => False),
                  Cx.Profile (Store, ""), Done, Status);
      declare
         Runtime_Value : R.Item;
         Held          : Ws.Workspace;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Id) & ".state",
                 Runtime_Value, Status);
         Ws.Read (Store, To_String (Done.Workspace_Id), Held, Status);
         Assert (To_String (Done.Final_State) = "complete"
                 and then R.Get (Runtime_Value, "integration_report") /= ""
                 and then To_String (Held.Status) = "integrated"
                 and then not Dirs.Exists (To_String (Held.Path)),
                 "work taken in on its own left no report, or its workspace: "
                 & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      end;
      S.Close (Store);

      --  Set aside and tried again, a task has one workspace: the earlier
      --  attempt's is abandoned, not left standing beside the new one.
      Task_Project
        (Store, "retry-workspace",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF
         & "scalar work.isolation = workspace" & LF);
      Tk.Create (Store, Change, Fields ("Again", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Execute (Store, To_String (Id),
                  Scripted_Agent'(File => Null_Unbounded_String,
                                  Answer => To_Unbounded_String
                                    ("status: blocked" & LF & "summary: needs a decision"),
                                  Broken => False),
                  Cx.Profile (Store, ""), Done, Status);
      declare
         First_Space : constant String := To_String (Done.Workspace_Id);
         Held        : Ws.Workspace;
      begin
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id),
                     Scripted_Agent'(File => To_Unbounded_String ("src/hello.adb"),
                                     Answer => To_Unbounded_String
                                       ("status: done" & LF & "summary: x"),
                                     Broken => False),
                     Cx.Profile (Store, ""), Done, Status);
         Ws.Read (Store, First_Space, Held, Status);
         Assert (First_Space /= ""
                 and then To_String (Held.Status) = "abandoned"
                 and then Ws.Active_For (Store, To_String (Id)) = To_String (Done.Workspace_Id)
                 and then To_String (Done.Workspace_Id) /= First_Space,
                 "a task tried again kept its earlier workspace beside the new one: "
                 & First_Space & " " & To_String (Held.Status));
      end;
      S.Close (Store);

      Task_Project (Store, "git-workspace", "");
      declare
         Root      : constant String := Dirs.Full_Name (Fresh_Root (Store));
         Exit_Code : Integer;

         function Git (A, B, C, D, F : String := "") return Boolean is
            Args : Hostkit.String_Vectors.Vector;
         begin
            for Word of Model_Runner.Framework.Name_Lists.Vector'
              (["-C", Root, "-c", "user.name=t", "-c", "user.email=t@t", A, B, C, D, F])
            loop
               if Word /= "" then
                  Args.Append (To_Unbounded_String (Word));
               end if;
            end loop;
            return Hostkit.Process.Locate ("git") /= ""
              and then Hostkit.Process.Run (Hostkit.Process.Locate ("git"), Args, Exit_Code)
              and then Exit_Code = 0;
         end Git;
      begin
         Dirs.Create_Path (Root & "/src");
         Put_File (Root & "/src/a.adb", "one");
         if Git ("init", "-q") and then Git ("add", "src") and then Git ("commit", "-q", "-m", "one")
         then
            Put_File (Root & "/src/a.adb", "two");
            Put_File (Root & "/src/new.adb", "new");
            Tk.Create (Store, Change, Fields ("Git", "analysis"), "user", "", Id, Status);
            S.Commit (Store, Change, Status);
            Ws.Create (Store, Change, To_String (Id), "AG-TEST", "1", True, Made, Status);
            S.Commit (Store, Change, Status);
            Assert (E.Is_Ok (Status) and then Ws."=" (Made.Kind, Ws.Git_Worktree)
                    and then Read_Whole (To_String (Made.Path) & "/src/a.adb") = "two"
                    and then Dirs.Exists (To_String (Made.Path) & "/src/new.adb")
                    and then Ws.Changes (Store, To_String (Made.Id)).Is_Empty,
                    "a Git workspace did not start from the project as it is: " & Code_Of (Status));
            Put_File (To_String (Made.Path) & "/src/a.adb", "three");
            Ws.Integrate (Store, Change, To_String (Made.Id), True, Taken, Status);
            Assert (E.Is_Ok (Status) and then Natural (Taken.Length) = 1
                    and then Dirs.Exists (To_String (Made.Path)),
                    "only the workspace's own change was not taken in, or its tree went"
                    & " before the integration was kept: " & Code_Of (Status));
            S.Commit (Store, Change, Status);
            Ws.Release (Store, To_String (Made.Id));
            Assert (Read_Whole (Root & "/src/a.adb") = "three"
                    and then not Dirs.Exists (To_String (Made.Path)),
                    "a kept integration left its tree, or did not take the change in");
         end if;
      end;
      S.Close (Store);
   end Workspaces_Start_And_End_Whole;

   --  A model profile says what the model can do; a context holds the
   --  decisions and specifications that govern the work, within what the
   --  model leaves room for; its manifest names the decision revisions it
   --  took; evidence says when and in which generation and configuration it
   --  was taken, and stops applying when a requirement's words change; the
   --  project is made with an event saying so; and neither the events nor
   --  what is machine-local is needed to know what the project is.
   procedure Contexts_Models_And_Evidence_Say_What_They_Must
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store    : S.Store;
      Status   : E.Error_Info;
      Change   : S.Transaction;
      Dec, Spec, Req, Id : Unbounded_String;
      Built    : Cx.Built;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Value    : R.Item;
      Reasons  : Model_Runner.Framework.Name_Lists.Vector;
      Report   : S.Recovery_Report;
      Root     : Unbounded_String;
      Given    : Tk.Field_Map := Fields ("Governed", "analysis");
      Model    : Cx.Model_Profile;
   begin
      Task_Project
        (Store, "contexts-say",
         "set execution.allowed = echo" & LF
         & "profile passing = say: echo all good" & LF
         & "scalar verification.default = passing" & LF
         & "map model.full = context=6000, reserve=100, overhead=300, provider=remote,"
         & " structured=no, reasoning=yes, streaming=no, parallel=yes" & LF);
      Model := Cx.Profile (Store, "full");
      Assert (To_String (Model.Provider) = "remote" and then Model.Tool_Overhead = 300
              and then not Model.Structured and then Model.Reasoning
              and then not Model.Streaming and then Model.Parallel_Calls,
              "a model profile did not say what the model can do");

      declare
         Seen : constant Model_Runner.Framework.Events.Event_List :=
           Model_Runner.Framework.Events.Since (Store, 0);
      begin
         Assert ((for some Index in 1 .. Model_Runner.Framework.Events.Length (Seen) =>
                    Model_Runner.Framework.Events.Element (Seen, Index).Kind
                      = Model_Runner.Framework.Events.Project_Initialized),
                 "the project was made with no event saying so");
      end;

      Nt.Propose (Store, Change, Nt.Decision, "", "One binary", "Ship one binary.", "",
                  "user", "", "project", Dec, Status);
      Nt.Propose (Store, Change, Nt.Specification, "", "Formats", "Reads UTF-8 only.", "",
                  "user", "", "project", Spec, Status);
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "project", Req, Status);
      S.Commit (Store, Change, Status);
      Nt.Move (Store, Change, Nt.Decision, To_String (Dec), "accepted", Tr.Ordinary_Only, Status);
      Nt.Move (Store, Change, Nt.Specification, To_String (Spec), "accepted", Tr.Ordinary_Only,
               Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted", Tr.Ordinary_Only,
               Status);
      S.Commit (Store, Change, Status);
      Given.Include ("requirements", To_String (Req));
      Tk.Create (Store, Change, Given, "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);

      Cx.Build (Store, To_String (Id), Model, Built, Status);
      Assert (E.Is_Ok (Status)
              and then Ada.Strings.Fixed.Index (Cx.Rendered (Built), "Ship one binary.") > 0
              and then Ada.Strings.Fixed.Index (Cx.Rendered (Built), "Reads UTF-8 only.") > 0
              and then Cx.Budget (Built) = 6000 - 100 - 300,
              "the context did not hold what governs the work, or took no account of the"
              & " tools' room: " & Code_Of (Status) & Cx.Budget (Built)'Image);
      Cx.Keep (Store, Change, Built, Status);
      S.Commit (Store, Change, Status);
      S.Read (Store, Model_Runner.Framework.Invocations_Area, "manifest." & Cx.Manifest_Id (Built),
              Value, Status);
      Assert (R.Get (Value, "applies." & To_String (Dec)) /= "",
              "the manifest did not name the decision revision it took");

      Vf.Run_Profile (Store, Change, "passing", To_String (Id), Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      S.Read (Store, Model_Runner.Framework.Verification_Area, To_String (Evidence), Value, Status);
      Assert (R.Get (Value, "generation") /= "" and then R.Get (Value, "configuration_revision") /= ""
              and then R.Get (Value, "started_at") /= "" and then R.Get (Value, "ended_at") /= "",
              "evidence did not say when, in which generation, under which configuration");
      declare
         Effect : Nt.Impact;
      begin
         Nt.Revise (Store, Change, Nt.Requirement, To_String (Req), "Read", "It SHALL read fast.",
                    "", Effect, Status);
         S.Commit (Store, Change, Status);
      end;
      Assert (not Vf.Is_Current (Store, To_String (Evidence), Reasons)
              and then Ada.Strings.Fixed.Index (Reasons.First_Element, To_String (Req)) > 0,
              "evidence held after the requirement it was taken for changed its words");

      --  Without the events and what is machine-local, the project is the
      --  same project.
      Root := To_Unbounded_String (Fresh_Root (Store));
      S.Close (Store);
      Remove_Tree (To_String (Root) & "/.model_runner/events");
      Remove_Tree (To_String (Root) & "/.model_runner/runtime");
      S.Open (Store, To_String (Root), Report, Status);
      Assert (E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Id)) = "accepted"
              and then Tk.List (Store).Contains (To_String (Id)),
              "the project was not what it was without its events and machine-local state: "
              & Code_Of (Status));
      S.Close (Store);
   end Contexts_Models_And_Evidence_Say_What_They_Must;

   --  The consistency check sees every kind of wrong reference: a task
   --  that waits for, or is part of, one that is not there; tasks that wait
   --  for each other, or are each other's parts; a task of no kind the
   --  project has; and a requirement implemented by a symbol the repository
   --  does not declare.
   procedure Consistency_Sees_Every_Wrong_Reference
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Cn.Finding_Kind;
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Ids    : array (1 .. 6) of Unbounded_String;
      Req    : Unbounded_String;

      --  Written straight into the record, past every check that would
      --  refuse it -- as a hand edit, or a bug, would.
      procedure Set (Which : Positive; Field, Value : String) is
         Defined : R.Item;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, To_String (Ids (Which)), Defined, Status);
         R.Set (Defined, Field, Value);
         R.Set_Revision (Defined, R.Revision (Defined) + 1);
         S.Put (Change, Model_Runner.Framework.Tasks_Area, To_String (Ids (Which)), Defined);
         S.Commit (Store, Change, Status);
      end Set;

      function Has (Kind : Cn.Finding_Kind; Subject : String) return Boolean is
         Found : constant Cn.Finding_List := Cn.Check (Store);
      begin
         return (for some Index in 1 .. Cn.Length (Found) =>
                   Cn.Element (Found, Index).Kind = Kind
                   and then Ada.Strings.Fixed.Index
                              (To_String (Cn.Element (Found, Index).Subject), Subject) > 0);
      end Has;
   begin
      Task_Project (Store, "wrong-references");
      for Index in Ids'Range loop
         Tk.Create (Store, Change, Fields ("Task" & Index'Image, "analysis"), "user", "",
                    Ids (Index), Status);
      end loop;
      S.Commit (Store, Change, Status);
      Set (1, "depends_on", "TASK-NOPE");
      Set (2, "parent", "TASK-GONE");
      Set (3, "depends_on", To_String (Ids (4)));
      Set (4, "depends_on", To_String (Ids (3)));
      Set (5, "parent", To_String (Ids (6)));
      Set (6, "parent", To_String (Ids (5)));
      Set (1, "kind", "nonsense");
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      S.Commit (Store, Change, Status);
      Nt.Link (Store, Change, Nt.Requirement, To_String (Req), Nt.Implementation,
               "Nowhere.Missing", Status);
      S.Commit (Store, Change, Status);
      declare
         Graph : Rp.Graph;
      begin
         Rp.Current (Store, Graph, Status);
      end;
      Assert (Has (Cn.Unknown_Task_Reference, To_String (Ids (1))),
              "a task waiting for one that is not there was not found");
      Assert (Has (Cn.Unknown_Task_Reference, To_String (Ids (2))),
              "a task part of one that is not there was not found");
      Assert (Has (Cn.Cyclic_Dependency, To_String (Ids (3)))
              or else Has (Cn.Cyclic_Dependency, To_String (Ids (4))),
              "tasks waiting for each other were not found");
      Assert (Has (Cn.Cyclic_Dependency, To_String (Ids (5)))
              or else Has (Cn.Cyclic_Dependency, To_String (Ids (6))),
              "tasks each other's parts were not found");
      Assert (Has (Cn.Invalid_Task_Kind, To_String (Ids (1))),
              "a task of no kind the project has was not found");
      Assert (Has (Cn.Missing_Symbol, To_String (Req)),
              "a requirement implemented by a symbol nobody declares was not found");
      S.Close (Store);
   end Consistency_Sees_Every_Wrong_Reference;

   --  The routine is the harness's: a project's generators and formatter
   --  run after the work, before it is verified, their changes the task's,
   --  and one that does not pass sets the task aside.
   procedure Harness_Runs_Routine_Stages
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Done   : Wk.Report;

      procedure Work (Name, Stage_Profile : String) is
         Id : Unbounded_String;
      begin
         Task_Project
           (Store, Name,
            "set execution.allowed = test" & LF & "set execution.allowed = touch" & LF
            & "set execution.allowed = false" & LF
            & "profile checks = exists: test -f src/hello.adb" & LF
            & "profile tidy = format: touch src/formatted.adb" & LF
            & "profile broken = format: false" & LF
            & "scalar verification.default = checks" & LF
            & "scalar stage.format = " & Stage_Profile & LF);
         Tk.Create (Store, Change, Fields ("Formatted", "analysis"), "user", "", Id, Status);
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
      Work ("format-stage", "tidy");
      Assert (To_String (Done.Final_State) = "complete"
              and then Done.Changed_Files.Contains ("src/formatted.adb"),
              "the harness's format stage did not run, or its change was not the task's: "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));
      S.Close (Store);
      Work ("format-stage-broken", "broken");
      Assert (To_String (Done.Final_State) = "blocked"
              and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "format stage") > 0,
              "a format stage that did not pass let the task go on: " & To_String (Done.Reason));
      S.Close (Store);
   end Harness_Runs_Routine_Stages;

   --  A task is ready only while what it serves is agreed; it names only
   --  tasks and requirements, not records beside them; and a requirement
   --  is implemented once every task serving it is complete.
   procedure Readiness_Follows_What_Is_Served
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Req    : Unbounded_String;
      First, Second, Other : Unbounded_String;
      Held   : Nt.Entity;
      Evidence : Unbounded_String;
      Passed : Boolean;

      function Serving (Title : String) return Tk.Field_Map is
         Given : Tk.Field_Map := Fields (Title, "analysis");
      begin
         Given.Include ("requirements", To_String (Req));
         return Given;
      end Serving;
   begin
      Task_Project
        (Store, "readiness-served",
         "set execution.allowed = echo" & LF
         & "profile passing = say: echo all good" & LF
         & "scalar verification.default = passing" & LF);
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Tk.Create (Store, Change, Serving ("One"), "user", "", First, Status);
      Tk.Create (Store, Change, Serving ("Two"), "user", "", Second, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (First), "accepted", "", Status => Status);
      Tk.Move (Store, Change, To_String (Second), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Assert (Tk.Ready (Store, To_String (First)).Ready, "a task serving an accepted requirement waits");

      --  Another agent writing in the project holds it up: one writer in a
      --  tree at a time.
      Model_Runner.Framework.Leases.Acquire
        (Store, Change, Tk.Project_Lease, "AG-ELSEWHERE", 60, Status);
      S.Commit (Store, Change, Status);
      Assert (not Tk.Ready (Store, To_String (First)).Ready
              and then Ada.Strings.Fixed.Index
                         (Tk.Ready (Store, To_String (First)).Reasons.First_Element,
                          "the project is being written by AG-ELSEWHERE") > 0,
              "a task was ready while another agent wrote in the project");
      Model_Runner.Framework.Leases.Release
        (Store, Change, Tk.Project_Lease, "AG-ELSEWHERE", Status);
      S.Commit (Store, Change, Status);

      --  The profile that will run is what the effective task says, the
      --  default among them; a title is not revised away; and why a task
      --  was blocked stays in the move's event.
      declare
         View    : R.Item;
         Revised : Tk.Field_Map;
         Events  : Model_Runner.Framework.Events.Event_List;
         Kept    : Boolean := False;
      begin
         Tk.Effective (Store, To_String (First), View, Status);
         Assert (Ada.Strings.Fixed.Index (R.Get (View, "verification_profile"), "passing") = 1,
                 "the effective task left out the default profile: "
                 & R.Get (View, "verification_profile"));
         Revised.Include ("title", "");
         Tk.Revise (Store, Change, To_String (First), Revised, Status);
         Assert (Status.Code = E.Framework_Input_Invalid, "a task's title was revised away");
         Change := S.No_Changes;
         Tk.Move (Store, Change, To_String (Second), "blocked", "waiting on the design",
                  Status => Status);
         S.Commit (Store, Change, Status);
         Events := Model_Runner.Framework.Events.Since (Store, 0);
         for Index in 1 .. Model_Runner.Framework.Events.Length (Events) loop
            Kept := Kept
              or else (Model_Runner.Framework.Events.Element (Events, Index).Kind
                         = Model_Runner.Framework.Events.Task_Blocked
                       and then Ada.Strings.Fixed.Index
                                  (To_String (Model_Runner.Framework.Events.Element
                                                (Events, Index).Detail),
                                   "waiting on the design") > 0);
         end loop;
         Assert (Kept, "why a task was blocked was not kept in its event");
         Assert (Ada.Strings.Fixed.Index
                   (Tk.Ready (Store, To_String (Second)).Reasons.First_Element,
                    "waiting on the design") > 0,
                 "a blocked task's readiness did not say why it is blocked");
         Tk.Move (Store, Change, To_String (Second), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
      end;

      --  A decision made to govern is revised: the one before kept, what
      --  it governs part of its meaning.
      declare
         Dec    : Unbounded_String;
         Before : Nt.Entity;
         After  : Nt.Entity;
      begin
         Nt.Propose (Store, Change, Nt.Decision, "", "One binary", "Ship one binary.", "",
                     "user", "", "project", Dec, Status);
         S.Commit (Store, Change, Status);
         Nt.Read (Store, Nt.Decision, To_String (Dec), Before, Status);
         Nt.Govern (Store, Change, Nt.Decision, To_String (Dec), "work.isolation", "project", "",
                    Status);
         S.Commit (Store, Change, Status);
         Nt.Read (Store, Nt.Decision, To_String (Dec), After, Status);
         Assert (E.Is_Ok (Status)
                 and then S.Exists (Store, Model_Runner.Framework.Decisions_Area,
                                    To_String (Dec) & ".rev-" & "000001")
                 and then To_String (After.Meaning) /= To_String (Before.Meaning),
                 "a governing decision was rewritten in place: " & Code_Of (Status));
      end;

      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "blocked", Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Assert (E.Is_Ok (Status) and then not Tk.Ready (Store, To_String (First)).Ready,
              "a task serving a blocked requirement was ready: " & Code_Of (Status));

      --  The revision a move leaves behind is kept, as a revise's is.
      declare
         Kept  : R.Item;
         Found : Boolean := False;
      begin
         for Name of S.Names (Store, Model_Runner.Framework.Requirements_Area) loop
            if Ada.Strings.Fixed.Index (Name, To_String (Req) & ".rev-") = 1 then
               S.Read (Store, Model_Runner.Framework.Requirements_Area, Name, Kept, Status);
               Found := Found or else R.Get (Kept, "state") = "accepted";
            end if;
         end loop;
         Assert (Found, "a moved requirement's earlier revision was not kept");
      end;
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted", Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);

      --  A record beside a task or a requirement is neither.
      Tk.Create (Store, Change, Fields ("Waits", "analysis", "depends_on",
                                        To_String (First) & ".state"),
                 "user", "", Other, Status);
      Assert (E.Is_Error (Status), "a task was made to wait on a runtime record");
      Change := S.No_Changes;
      Tk.Create (Store, Change, Fields ("Serves", "analysis", "requirements",
                                        To_String (Req) & ".rev-000001"),
                 "user", "", Other, Status);
      Assert (E.Is_Error (Status), "a task was made to serve a kept revision");
      Change := S.No_Changes;

      --  One of two tasks done: the requirement is not implemented yet.
      Tk.Move (Store, Change, To_String (First), "running", "", Status => Status);
      Tk.Move (Store, Change, To_String (First), "verification", "", Status => Status);
      S.Commit (Store, Change, Status);
      Vf.Run_Profile (Store, Change, "passing", To_String (First), Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      Vf.Complete_Task (Store, Change, To_String (First), Status);
      S.Commit (Store, Change, Status);
      Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
      Assert (Tk.State_Of (Store, To_String (First)) = "complete"
              and then To_String (Held.State) = "accepted",
              "a requirement was implemented with a task serving it still open: "
              & To_String (Held.State));

      --  Evidence holds while the decisions governing the work mean what
      --  they meant, and not once one says something else.
      declare
         Dec     : Unbounded_String;
         Reasons : Model_Runner.Framework.Name_Lists.Vector;
      begin
         Nt.Propose (Store, Change, Nt.Decision, "", "Isolate", "Work apart.", "",
                     "user", "", "project", Dec, Status);
         S.Commit (Store, Change, Status);
         Nt.Move (Store, Change, Nt.Decision, To_String (Dec), "accepted", Tr.Ordinary_Only,
                  Status);
         S.Commit (Store, Change, Status);
         Vf.Run_Profile (Store, Change, "passing", To_String (Second), Evidence, Passed, Status);
         S.Commit (Store, Change, Status);
         Assert (Vf.Is_Current (Store, To_String (Evidence), Reasons),
                 "fresh evidence under a decision was not current");
         Nt.Govern (Store, Change, Nt.Decision, To_String (Dec), "work.isolation", "workspace", "",
                    Status);
         S.Commit (Store, Change, Status);
         Assert (not Vf.Is_Current (Store, To_String (Evidence), Reasons)
                 and then Ada.Strings.Fixed.Index (Reasons.First_Element, To_String (Dec)) > 0,
                 "evidence held after a decision governing the work changed its meaning");
      end;

      --  A task made to wait for its own parent is a cycle; one being
      --  worked or ended is not made to wait; one that is keeps what it was.
      declare
         Given : Tk.Field_Map := Fields ("Cyclic", "analysis", "parent", To_String (Second));
         Third : Unbounded_String;
      begin
         Given.Include ("depends_on", To_String (Second));
         Tk.Create (Store, Change, Given, "user", "", Other, Status);
         Assert (Status.Code = E.Framework_Dependency_Cycle,
                 "a task was made waiting for its own parent: " & Code_Of (Status));
         Change := S.No_Changes;
         Tk.Add_Dependency (Store, Change, To_String (First), To_String (Second), Status);
         Assert (Status.Code = E.Framework_Transition_Invalid,
                 "a complete task was made to wait: " & Code_Of (Status));
         Change := S.No_Changes;
         Tk.Create (Store, Change, Fields ("Third", "analysis"), "user", "", Third, Status);
         S.Commit (Store, Change, Status);
         Tk.Add_Dependency (Store, Change, To_String (Third), To_String (Second), Status);
         S.Commit (Store, Change, Status);
         Assert (E.Is_Ok (Status)
                 and then S.Exists (Store, Model_Runner.Framework.Tasks_Area,
                                    To_String (Third) & ".rev-000001"),
                 "a dependency added did not keep the task as it was: " & Code_Of (Status));
      end;

      --  A requirement whose tasks are all complete is implemented, however
      --  it came to be accepted again.
      declare
         Req2  : Unbounded_String;
         Done2 : Unbounded_String;
         Held2 : Nt.Entity;
         Moved : Model_Runner.Framework.Name_Lists.Vector;
         Given : Tk.Field_Map := Fields ("Serves two", "analysis");
      begin
         Nt.Propose (Store, Change, Nt.Requirement, "IO", "Write", "It SHALL write.", "",
                     "user", "", "io", Req2, Status);
         S.Commit (Store, Change, Status);
         Nt.Move (Store, Change, Nt.Requirement, To_String (Req2), "accepted", Tr.Ordinary_Only,
                  Status);
         S.Commit (Store, Change, Status);
         Given.Include ("requirements", To_String (Req2));
         Tk.Create (Store, Change, Given, "user", "", Done2, Status);
         S.Commit (Store, Change, Status);
         for Next of Model_Runner.Framework.Name_Lists.Vector'
           (["accepted", "running", "verification"])
         loop
            Tk.Move (Store, Change, To_String (Done2), Next, "", Status => Status);
            S.Commit (Store, Change, Status);
         end loop;
         Tk.Move (Store, Change, To_String (Done2), "complete", "", Gates_Passed => True,
                  Status => Status);
         S.Commit (Store, Change, Status);
         Vf.Reevaluate_Requirements (Store, Change, Moved, Status);
         S.Commit (Store, Change, Status);
         Nt.Read (Store, Nt.Requirement, To_String (Req2), Held2, Status);
         Assert (To_String (Held2.State) = "implemented" and then Moved.Contains (To_String (Req2)),
                 "an accepted requirement whose tasks were all complete stayed accepted: "
                 & To_String (Held2.State));

         --  Revised to say something else, what was done for the old words
         --  implements nothing of the new.
         declare
            Effect : Nt.Impact;
         begin
            Nt.Revise (Store, Change, Nt.Requirement, To_String (Req2), "Write",
                       "It SHALL write twice.", "", Effect, Status);
            S.Commit (Store, Change, Status);
            Vf.Reevaluate_Requirements (Store, Change, Moved, Status);
            S.Commit (Store, Change, Status);
            Nt.Read (Store, Nt.Requirement, To_String (Req2), Held2, Status);
            Assert (To_String (Held2.State) = "accepted",
                    "work done for a requirement's old words implemented its new ones: "
                    & To_String (Held2.State));
         end;
      end;

      --  A part an agent proposed holds its parent only once accepted.
      declare
         Whole, Part : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Whole thing", "analysis"), "user", "", Whole, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Whole), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Tk.Create (Store, Change, Fields ("A part", "analysis", "parent", To_String (Whole)),
                    "agent AG-000001", To_String (Whole), Part, Status);
         S.Commit (Store, Change, Status);
         Assert (Tk.Ready (Store, To_String (Whole)).Ready,
                 "a part an agent proposed held its parent before it was accepted");
         Tk.Move (Store, Change, To_String (Part), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Assert (not Tk.Ready (Store, To_String (Whole)).Ready,
                 "an accepted part did not hold its parent");
      end;

      --  A move's consequences are the move's, whoever makes it: a person
      --  failing a task in verification lets go of what its agent held and
      --  abandons its workspace.
      declare
         Held_Task : Unbounded_String;
         Space     : Ws.Workspace;
         Kept      : Ws.Workspace;
      begin
         Tk.Create (Store, Change, Fields ("Held", "analysis"), "user", "", Held_Task, Status);
         S.Commit (Store, Change, Status);
         for Next of Model_Runner.Framework.Name_Lists.Vector'
           (["accepted", "running", "verification"])
         loop
            Tk.Move (Store, Change, To_String (Held_Task), Next, "", Status => Status);
            S.Commit (Store, Change, Status);
         end loop;
         Model_Runner.Framework.Leases.Acquire
           (Store, Change, "task." & To_String (Held_Task), "AG-WORKER", 600, Status);
         Ws.Create (Store, Change, To_String (Held_Task), "AG-WORKER", "1", False, Space, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Held_Task), "failed", "not wanted",
                  Status => Status, Actor => Tr.User);
         S.Commit (Store, Change, Status);
         Ws.Read (Store, To_String (Space.Id), Kept, Status);
         Assert (Model_Runner.Framework.Leases.Holder (Store, "task." & To_String (Held_Task)) = ""
                 and then To_String (Kept.Status) = "abandoned",
                 "a person's move left the task held, or its workspace standing: "
                 & To_String (Kept.Status));
      end;

      --  What supersedes keeps what it was.
      declare
         Dec2 : Unbounded_String;
         Dec1 : Unbounded_String;
      begin
         Nt.Propose (Store, Change, Nt.Decision, "", "Old", "Old way.", "", "user", "", "project",
                     Dec1, Status);
         Nt.Propose (Store, Change, Nt.Decision, "", "New", "New way.", "", "user", "", "project",
                     Dec2, Status);
         S.Commit (Store, Change, Status);
         Nt.Move (Store, Change, Nt.Decision, To_String (Dec1), "accepted", Tr.Ordinary_Only,
                  Status);
         S.Commit (Store, Change, Status);
         Nt.Supersede (Store, Change, Nt.Decision, To_String (Dec1), To_String (Dec2), Status);
         S.Commit (Store, Change, Status);
         Assert (E.Is_Ok (Status)
                 and then S.Exists (Store, Model_Runner.Framework.Decisions_Area,
                                    To_String (Dec2) & ".rev-000001"),
                 "what superseded did not keep what it was: " & Code_Of (Status));
      end;
      S.Close (Store);

      --  What a revision does to a requirement is the project's to say.
      Task_Project (Store, "revision-policy", "scalar requirement.after_text_change = blocked" & LF);
      declare
         Held   : Nt.Entity;
         Effect : Nt.Impact;
      begin
         Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                     "user", "", "io", Req, Status);
         S.Commit (Store, Change, Status);
         for Next of Model_Runner.Framework.Name_Lists.Vector'(["accepted", "implemented"]) loop
            Nt.Move (Store, Change, Nt.Requirement, To_String (Req), Next, Tr.Ordinary_Only, Status);
            S.Commit (Store, Change, Status);
         end loop;
         Nt.Revise (Store, Change, Nt.Requirement, To_String (Req), "Read", "It SHALL read twice.",
                    "", Effect, Status);
         S.Commit (Store, Change, Status);
         Nt.Read (Store, Nt.Requirement, To_String (Req), Held, Status);
         Assert (To_String (Held.State) = "blocked",
                 "a revision did not do what the project's policy says: " & To_String (Held.State));
      end;
      S.Close (Store);
   end Readiness_Follows_What_Is_Served;

   --  The project's state is the harness's: an agent run as a process of
   --  its own that writes it, and checks that do, find it put back and
   --  their work failed.
   procedure State_Is_The_Harness_Own
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Done   : Wk.Report;
      Id     : Unbounded_String;
      Evidence : Unbounded_String;
      Passed : Boolean;
      Value  : R.Item;
   begin
      Task_Project
        (Store, "state-protected",
         "set execution.allowed = touch" & LF
         & "profile checks = meddle: touch .model_runner/evil.rec" & LF
         & "scalar verification.default = checks" & LF);
      Tk.Create (Store, Change, Fields ("Meddle", "analysis"), "user", "", Id, Status);
      S.Commit (Store, Change, Status);
      Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
      S.Commit (Store, Change, Status);
      Wk.Execute (Store, To_String (Id),
                  Scripted_Agent'(File => To_Unbounded_String (".model_runner/tasks/evil.rec"),
                                  Answer => To_Unbounded_String
                                    ("status: done" & LF & "summary: x"),
                                  Broken => False),
                  Cx.Profile (Store, ""), Done, Status);
      Assert (To_String (Done.Final_State) = "failed"
              and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "tasks/evil.rec") > 0
              and then not Dirs.Exists (Fresh_Root (Store) & "/.model_runner/tasks/evil.rec"),
              "an agent's write to the project's state was kept, or its work taken: "
              & To_String (Done.Final_State) & " " & To_String (Done.Reason));

      Vf.Run_Profile (Store, Change, "checks", To_String (Id), Evidence, Passed, Status);
      S.Commit (Store, Change, Status);
      S.Read (Store, Model_Runner.Framework.Verification_Area, To_String (Evidence), Value, Status);
      Assert (not Passed and then R.Get (Value, "state_changed") = "evil.rec"
              and then not Dirs.Exists (Fresh_Root (Store) & "/.model_runner/evil.rec"),
              "a check's write to the project's state was kept, or passed");

      --  Left alone, nothing is put back.
      declare
         Taken   : S.State_Snapshot;
         Changed : Model_Runner.Framework.Name_Lists.Vector;
      begin
         S.Snapshot_State (Store, Taken);
         S.Restore_State (Store, Taken, Changed);
         Assert (Changed.Is_Empty, "a state left alone was put back");
      end;

      --  What the harness commits meanwhile -- by this process or another --
      --  is not put back; only what was written behind its back.
      declare
         Taken   : S.State_Snapshot;
         Changed : Model_Runner.Framework.Name_Lists.Vector;
         Other   : Unbounded_String;
      begin
         S.Snapshot_State (Store, Taken);
         Tk.Create (Store, Change, Fields ("Meanwhile", "analysis"), "user", "", Other, Status);
         S.Commit (Store, Change, Status);
         Put_File (Fresh_Root (Store) & "/.model_runner/sneaked.rec", "x");
         S.Restore_State (Store, Taken, Changed);
         Assert (Tk.State_Of (Store, To_String (Other)) = "candidate"
                 and then Changed.Contains ("sneaked.rec")
                 and then not Dirs.Exists (Fresh_Root (Store) & "/.model_runner/sneaked.rec"),
                 "a commit made meanwhile was put back, or a write behind the harness kept");
      end;

      --  Work whose lease no longer names its agent is withdrawn.
      Model_Runner.Framework.Execution.Watch_Lease (Store'Unchecked_Access, "task.NOBODY", "AG-X");
      delay 1.1;
      Assert (Model_Runner.Framework.Execution.Work_Withdrawn,
              "work whose lease went was not seen withdrawn");
      Model_Runner.Framework.Execution.Watch_Lease (null);
      Assert (not Model_Runner.Framework.Execution.Work_Withdrawn,
              "unwatched work was taken for withdrawn");
      S.Close (Store);
   end State_Is_The_Harness_Own;

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
      Assert (Has (Cs.Missing_Component, "nowhere"),
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

      --  A task complete without the evidence its gates want; a field value
      --  its schema no longer takes; a role granting beyond the project.
      Change := S.No_Changes;
      Task_Project (Store, "consistency-gates",
                    "set task.gates = verification" & LF
                    & "map permission.role.helper.use_network =" & LF);
      declare
         Planned  : Model_Runner.Framework.Configurations.Change_Plan;
         One      : Model_Runner.Framework.Configurations.Value_Maps.Map;
         Revision : Natural;
         Third    : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Look", "analysis", "estimate", "2h"), "user", "",
                    First, Status);
         Tk.Create (Store, Change, Fields ("Build", "implementation", "component", "x"),
                    "user", "", Third, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Third), "accepted", "", Status => Status);
         Tk.Move (Store, Change, To_String (Third), "running", "", Status => Status);
         Tk.Move (Store, Change, To_String (Third), "verification", "", Status => Status);
         Tk.Move (Store, Change, To_String (Third), "complete", "", Status => Status,
                  Gates_Passed => True);
         S.Commit (Store, Change, Status);
         One.Include ("map.task_field.estimate", "number");
         Model_Runner.Framework.Configurations.Plan_Change (Store, One, Planned, Status);
         Model_Runner.Framework.Configurations.Reconfigure (Store, Planned, Revision, Status);
         Assert (Has (Cs.Completed_Without_Gate, To_String (Third)),
                 "a task complete with no evidence its gates want went unseen");
         Assert (Has (Cs.Invalid_Task_Field, To_String (First)),
                 "a field value its schema does not take went unseen");
         Assert (not Has (Cs.Permission_Widening, "role.helper"),
                 "a role clamped to the project's was taken for broken");
      end;
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
      Assert (Refused ("scalar.verification.default", "nosuch"),
              "a setting naming a profile that is not there was taken");
      Assert (Refused ("baseline.tests", "x")
              and then not Refused ("baseline.project.tests", "a change comes with its test")
              and then not Refused ("schema.release", "semver"),
              "baselines and schemas were not changed as settings");
      declare
         One : Cf.Value_Maps.Map;
         Got : Cf.Change_Plan;
      begin
         One.Include ("set.repository.skip", "obj, vendor");
         Cf.Plan_Change (Store, One, Got, Status);
         Assert ((for some Line of Got.Impact =>
                    Ada.Strings.Fixed.Index (Line, "repository graph") > 0),
                 "the derived state a change of roots invalidates was not named");

         --  Staged, and held against the configuration it would make: the
         --  evidence of the one in force is not current against it.
         Change := S.No_Changes;
         Cf.Stage_Change (Store, Change, Got, Status);
         Assert (E.Is_Ok (Status)
                 and then Vf.Is_Current (Store, To_String (Evidence), Reasons)
                 and then not Vf.Is_Current
                                (Store, To_String (Evidence), Reasons,
                                 Configuration => Cf.Verification_Fingerprint (Got.After)),
                 "evidence was not held to the configuration being staged");
         Change := S.No_Changes;
      end;

      Changes.Include ("scalar.work.isolation", "workspace");
      Changes.Include ("set.execution.allowed", "test, alr");
      Cf.Plan_Change (Store, Changes, Planned, Status);
      Assert (E.Is_Ok (Status) and then Natural (Planned.Changed.Length) = 2,
              "the change was not worked out: " & Code_Of (Status));
      --  Who works and what it may run: work is reached, evidence is not.
      Assert ((for some Line of Planned.Impact => Ada.Strings.Fixed.Index (Line, "work:") = 1)
              and then not (for some Line of Planned.Impact =>
                              Ada.Strings.Fixed.Index (Line, "evidence:") = 1),
              "what the change reaches was not said, or evidence was said to be reached");
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
         Findings  : constant Cn.Finding_List := Cn.Check (Store);
         Duplicate : Boolean := False;
         use type Cn.Finding_Kind;
      begin
         for Index in 1 .. Cn.Length (Findings) loop
            Duplicate := Duplicate
              or else Cn.Element (Findings, Index).Kind in Cn.Duplicate_Identifier
                                                          | Cn.Index_Mismatch;
         end loop;
         Assert (not Duplicate, "a configuration's history made the state look inconsistent");
      end;
      declare
         Seen : constant Ev.Event_List := Ev.Since (Store, 0);
      begin
         Assert (To_String (Ev.Element (Seen, Ev.Length (Seen)).Kind_Word)
                   = Ev.Kind_Name (Ev.Configuration_Changed),
                 "Configuration_Changed was not emitted");
      end;
      --  Who works and what it may run bear on no check: evidence stands.
      if not Vf.Is_Current (Store, To_String (Evidence), Reasons) then
         Assert (not (for some Line of Reasons =>
                        Ada.Strings.Fixed.Index (Line, "configuration") > 0),
                 "evidence was made stale by a change of isolation and allowed programs");
      end if;
      Assert (Cf.Verification_Fingerprint (Planned.Before)
                = Cf.Verification_Fingerprint (Planned.After)
              and then Cf.Configuration_Fingerprint (Planned.Before)
                         /= Cf.Configuration_Fingerprint (Planned.After),
              "the verification fingerprint followed settings that bear on no check");

      Cf.Reconfigure (Store, Stale, Revision, Status);
      Assert (Status.Code = E.Framework_Revision_Conflict,
              "a change planned against an older revision was made");

      --  A fact set is the registry's too, and a key no fact has is refused.
      Assert (Refused ("fact.Bad-Key", "x"), "a fact with no key a fact has was taken");
      Changes.Clear;
      Changes.Include ("fact.build_system", "make");
      Cf.Plan_Change (Store, Changes, Planned, Status);
      Cf.Reconfigure (Store, Planned, Revision, Status);
      declare
         Held : Model_Runner.Framework.Facts.Fact;
      begin
         Model_Runner.Framework.Facts.Find (Store, "build_system", Held, Status);
         Assert (E.Is_Ok (Status) and then To_String (Held.Value) = "make",
                 "a fact reconfigured left the registry saying otherwise: " & Code_Of (Status));
         Changes.Clear;
         Changes.Include ("fact.build_system", "");
         Cf.Plan_Change (Store, Changes, Planned, Status);
         Cf.Reconfigure (Store, Planned, Revision, Status);
         Model_Runner.Framework.Facts.Find (Store, "build_system", Held, Status);
         Assert (Status.Code = E.Framework_Not_Found,
                 "a fact no longer set stayed in the registry: " & Code_Of (Status));
         Model_Runner.Framework.Facts.Retire (Store, Change, "never_said");
         Assert (S.Change_Count (Change) = 0, "a fact nobody held was retired");
      end;
      S.Close (Store);
   end Configuration_Changes_Explicitly;

   --  What another process can do to a run, and what a run says of itself:
   --  a stop asked from outside is seen; leases run out are let go of; a
   --  session's next steps are said as it types them; and checks that did
   --  not pass, and a requirement not verified, say why.
   procedure Runs_Answer_From_Outside
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Store  : aliased S.Store;
      Status : E.Error_Info;
      Change : S.Transaction;
      Task_A : Unbounded_String;
      Req    : Unbounded_String;
   begin
      Task_Project
        (Store, "outside",
         "set execution.allowed = false" & LF
         & "profile failing = check: false" & LF
         & "scalar verification.default = failing" & LF);
      Tk.Create (Store, Change, Fields ("Stopped", "analysis"), "user", "", Task_A, Status);
      S.Commit (Store, Change, Status);

      --  Asked to stop from outside, the run watching the task sees it.
      Model_Runner.Framework.Leases.Acquire
        (Store, Change, "task." & To_String (Task_A), "AG-1", 60, Status);
      S.Commit (Store, Change, Status);
      Model_Runner.Framework.Execution.Watch_Lease
        (Store'Unchecked_Access, "task." & To_String (Task_A), "AG-1");
      Assert (not Model_Runner.Framework.Execution.Work_Withdrawn, "a run was stopped unasked");
      Model_Runner.Framework.Execution.Ask_To_Stop
        (Dirs.Containing_Directory (S.Root (Store)), To_String (Task_A));
      delay 1.1;
      Assert (Model_Runner.Framework.Execution.Work_Withdrawn
              and then Model_Runner.Framework.Execution.Cancel_Asked_From_Outside,
              "a cancel asked from outside was not seen as one");
      Model_Runner.Framework.Execution.Watch_Lease (null);
      Assert (Model_Runner.Framework.Execution.Cancel_Asked_From_Outside,
              "ending the watch forgot that the run was cancelled from outside, before it was"
              & " concluded");

      --  A sandbox that refuses a path is named as what refused it.
      declare
         Set : E.Error_Info;
      begin
         Model_Runner.Framework.Permissions.Set_Sandbox ("write_source roots=docs/; read_source", Set);
         Assert (E.Is_Ok (Set)
                 and then Model_Runner.Framework.Permissions.Sandbox_Refuses ("src/x.adb", True)
                 and then not Model_Runner.Framework.Permissions.Sandbox_Refuses ("docs/x.md", True),
                 "a sandbox written as it is shown was not taken, or not said to refuse");
         Assert (Model_Runner.Framework.Permissions.Sandbox_Source = "the session's /sandbox",
                 "a session's sandbox was not said to be the session's");
         declare
            package Pm renames Model_Runner.Framework.Permissions;
            Asked, Allowed : Pm.Permission_Set;
            Read           : E.Error_Info;
         begin
            Pm.Restriction ("read_source; use_network; create_children max_depth=5", Asked, Read);
            Pm.Restriction ("read_source; create_children max_depth=1", Allowed, Read);
            Assert (Natural (Pm.Widenings (Asked, Allowed).Length) = 2
                    and then Ada.Strings.Fixed.Index (Pm.Clipped (Asked, Allowed),
                                                      "use_network (gets none)") > 0
                    and then Ada.Strings.Fixed.Index (Pm.Clipped (Asked, Allowed),
                                                      "create_children (gets max_depth=1)") > 0,
                    "what asks for more than allowed was not all said, with what it gets: "
                    & Pm.Clipped (Asked, Allowed));
         end;
         Model_Runner.Framework.Permissions.Set_Sandbox ("", Set);
         Assert (not Model_Runner.Framework.Permissions.Sandbox_Refuses ("src/x.adb", True)
                 and then Model_Runner.Framework.Permissions.Sandbox_Problem = "",
                 "no sandbox refused a path, or was said to be wrong");
         Ada.Environment_Variables.Set ("MODEL_RUNNER_SANDBOX", "bogus_cap roots=x");
         Assert (Ada.Strings.Fixed.Index
                   (Model_Runner.Framework.Permissions.Sandbox_Problem, "bogus_cap") > 0,
                 "a sandbox naming no capability was not said to be wrong");
         Ada.Environment_Variables.Clear ("MODEL_RUNNER_SANDBOX");
         --  Told to end with nothing waited for, it does not end here; the
         --  flag is only asked.
         Model_Runner.Platform.Signals.Set_Waiting_For_Input (True, Note => "dropped");
         Model_Runner.Platform.Signals.Set_Waiting_For_Input (False);
         Assert (not Model_Runner.Platform.Signals.Ending_Asked
                 and then not Model_Runner.Platform.Signals.Interrupt_Noted,
                 "an ending or an interrupt's note was said with none sent");

         --  A path as the project names it, whatever way it was typed.
         Assert (Model_Runner.Framework.Repository.Relative_Path ("/p/proj", "./docs/x.md") = "docs/x.md"
                 and then Model_Runner.Framework.Repository.Relative_Path ("/p/proj", "/p/proj/src/a.adb")
                          = "src/a.adb"
                 and then Model_Runner.Framework.Repository.Relative_Path ("/p/proj", "src/../docs/")
                          = "docs/"
                 and then Model_Runner.Framework.Repository.Relative_Path ("/p/proj", ".") = ""
                 and then Model_Runner.Framework.Repository.Relative_Path ("/p/proj", "../x") = "../x",
                 "a path was not made the one the project names");
         Assert (Model_Runner.Framework.State_Said ("candidate") = "a candidate"
                 and then Model_Runner.Framework.State_Said ("accepted") = "accepted",
                 "a state was not said as a sentence says it");

         --  A level's grants from a configuration not yet kept: what a
         --  reconfigure's preview judges.
         declare
            package Pm renames Model_Runner.Framework.Permissions;
            Config  : Model_Runner.Framework.Records.Item :=
              Model_Runner.Framework.Records.Create ("configuration", 1, "config", 1);
            Present : Boolean;
            Given   : Pm.Permission_Set;
         begin
            Model_Runner.Framework.Records.Set
              (Config, "map.permission.kind.test.write_source", "roots=tests/");
            Given := Pm.Level_Of (Config, "kind.test", Present);
            Assert (Present and then Given (Pm.Write_Source).Granted
                    and then not Given (Pm.Read_Source).Granted,
                    "a level read from a configuration not kept did not grant what it names");
            Given := Pm.Level_Of (Config, "kind.analysis", Present);
            Assert (not Present and then not Given (Pm.Write_Source).Granted,
                    "a level a configuration says nothing of was said to be there");
            --  inherit: the level above's, and the project's default at the
            --  top.
            Model_Runner.Framework.Records.Set
              (Config, "map.permission.kind.test.read_source", "inherit");
            Given := Pm.Level_Of (Config, "kind.test", Present);
            Assert (Given (Pm.Read_Source).Granted and then Given (Pm.Read_Source).Roots.Is_Empty,
                    "a capability a level inherits was not taken from above");
            Model_Runner.Framework.Records.Set
              (Config, "map.permission.project.create_children", "inherit");
            Given := Pm.Level_Of (Config, "project", Present);
            Assert (Present
                    and then Given (Pm.Create_Children).Max_Depth
                             = Pm.Project_Default (Pm.Create_Children).Max_Depth,
                    "the project's inherit was not its default");
         end;
      end;

      --  What makes a task that cannot wait so say why.
      Tk.Add_Dependency (Store, Change, To_String (Task_A), To_String (Task_A), Status);
      Assert (Status.Code = E.Framework_Dependency_Cycle
              and then Ada.Strings.Fixed.Index (E.Text_Of (Status, "detail"), "itself") > 0,
              "a task waiting for itself was not said so");
      Change := S.No_Changes;

      --  What a killed run left running is stopped when the project opens.
      if Dirs.Exists ("/usr/bin/setsid") then
         declare
            Args    : GNAT.OS_Lib.Argument_List (1 .. 2) :=
              [new String'("sleep"), new String'("30")];
            Child   : constant GNAT.OS_Lib.Process_Id :=
              GNAT.OS_Lib.Non_Blocking_Spawn ("/usr/bin/setsid", Args);
            Stopped : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for A of Args loop
               GNAT.OS_Lib.Free (A);
            end loop;
            delay 0.3;
            Put_File (S.Root (Store) & "/runtime/group." & To_String (Task_A),
                      Ada.Strings.Fixed.Trim
                        (Integer'Image (GNAT.OS_Lib.Pid_To_Integer (Child)), Ada.Strings.Both));
            Model_Runner.Framework.Execution.Stop_Left_Groups (Store, Stopped);
            Assert (Natural (Stopped.Length) = 1
                    and then not Dirs.Exists (S.Root (Store) & "/runtime/group." & To_String (Task_A)),
                    "what a killed run left running was not stopped");
         end;
      end if;

      --  Links and waits taken off again; the settings known unset.
      declare
         Other : Unbounded_String;
         R1    : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Other", "analysis"), "user", "", Other, Status);
         S.Commit (Store, Change, Status);
         Tk.Add_Dependency (Store, Change, To_String (Task_A), To_String (Other), Status);
         S.Commit (Store, Change, Status);
         Tk.Remove_Dependency (Store, Change, To_String (Task_A), To_String (Other), Status);
         S.Commit (Store, Change, Status);
         declare
            Defined : R.Item;
         begin
            Tk.Definition (Store, To_String (Task_A), Defined, Status);
            Assert (E.Is_Ok (Status) and then R.Get (Defined, "depends_on") = "",
                    "a dependency taken off still held");
         end;
         Nt.Propose (Store, Change, Nt.Requirement, "IO", "Linked", "It SHALL link.", "",
                     "user", "", "project", R1, Status);
         Nt.Link (Store, Change, Nt.Requirement, To_String (R1), Nt.Component, "nowhere", Status);
         Nt.Unlink (Store, Change, Nt.Requirement, To_String (R1), Nt.Component, "nowhere", Status);
         S.Commit (Store, Change, Status);
         Assert (E.Is_Ok (Status)
                 and then Nt.Links (Store, Nt.Requirement, To_String (R1), Nt.Component).Is_Empty,
                 "a link was not taken off");
         Assert (Tk.Component_Of_Task (Store, To_String (Other)) /= "",
                 "the component of a task was not said");
         Assert (Nt.State_Of (Store, Nt.Requirement, To_String (R1)) = "candidate"
                 and then Nt.State_Of (Store, Nt.Requirement, "REQ-NONE-999") = "",
                 "the state of an entry, or of none, was not said");
         Nt.Govern (Store, Change, Nt.Requirement, To_String (R1), "scalar.work.isolation",
                    "workspace", "", Status);
         S.Commit (Store, Change, Status);
         Assert (Nt.Governs (Store, Nt.Requirement, To_String (R1))
                   = "scalar.work.isolation = workspace",
                 "what an entry governs was not said: "
                 & Nt.Governs (Store, Nt.Requirement, To_String (R1)));
         --  A second setting kept beside the first, not over it.
         Nt.Govern (Store, Change, Nt.Requirement, To_String (R1), "scalar.work.agent",
                    "scripted", "", Status);
         S.Commit (Store, Change, Status);
         Assert (Nt.Governs (Store, Nt.Requirement, To_String (R1)) = "scalar.work.agent = scripted"
                 and then Nt.Also_Governs (Store, Nt.Requirement, To_String (R1)).Contains
                            ("scalar.work.isolation = workspace"),
                 "governing a second setting dropped the first");
         Assert (Model_Runner.Framework.Configurations.Known_Names.Contains ("scalar.work.agent"),
                 "the settings the harness reads were not known");
      end;

      --  A lease run out is let go of, once.
      declare
         Cleared : Model_Runner.Framework.Name_Lists.Vector;
      begin
         Model_Runner.Framework.Leases.Acquire (Store, Change, "project.write", "AG-2", 1, Status);
         S.Commit (Store, Change, Status);
         delay 1.2;
         Model_Runner.Framework.Leases.Clear_Stale (Store, Change, Cleared);
         S.Commit (Store, Change, Status);
         Assert (Cleared.Contains ("project.write")
                 and then Model_Runner.Framework.Leases.Stale (Store).Is_Empty,
                 "a lease run out was not let go of");
      end;

      --  Checks that did not pass say which, and how they ended.
      declare
         Evidence : Unbounded_String;
         Passed   : Boolean;
      begin
         Vf.Run_Profile (Store, Change, "failing", To_String (Task_A), Evidence, Passed, Status);
         S.Commit (Store, Change, Status);
         Assert (E.Exit_Status (E.Make (E.Framework_Verification_Failed)) = E.Exit_Input_Output,
                 "checks that did not pass are not a failure of what was read");
         Assert (not Passed and then not Vf.Why_Failed (Store, To_String (Evidence)).Is_Empty
                 and then Ada.Strings.Fixed.Index
                            (Vf.Why_Failed (Store, To_String (Evidence)).First_Element,
                             "(false) failed") > 0,
                 "checks that did not pass did not say why");
      end;

      --  A requirement not verified says what it lacks.
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "project", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted", Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Assert (Ada.Strings.Fixed.Index (Vf.Why_Not_Verified (Store, To_String (Req)), "no task serves it")
              > 0,
              "a requirement nothing serves did not say so: " & Vf.Why_Not_Verified (Store, To_String (Req)));
      Assert (not Vf.Passed_After (Store, "VER-999999")
              and then Model_Runner.Framework.Workspaces.Conflict_Files (Store, "WS-999999").Is_Empty,
              "a later passing run, or a conflict, was found where there is none");
      S.Close (Store);

      --  In a session, a next step is the command typed there.
      declare
         use Ada.Text_IO;
         Catalog : aliased Model_Runner.Localization.Catalog;
         Screen  : Model_Runner.Presentation.Console;
         Said    : File_Type;
      begin
         Model_Runner.Localization.Open (Catalog, Model_Runner.Platform.Catalog_Path, "en");
         Model_Runner.Presentation.Open
           (Screen, Catalog'Unchecked_Access, Model_Runner.CLI.Options.Color_Never,
            (Output_Is_Terminal => False, Error_Is_Terminal => False,
             Input_Is_Terminal  => False, Colour_Suppressed => True),
            Model_Runner.CLI.Options.Normal);
         Model_Runner.Presentation.Use_Session (Screen, True);
         Assert (Model_Runner.Presentation.In_Session (Screen), "a session was not said to be one");
         Create (Said, Out_File, "obj/session-next.txt");
         Set_Error (Said);
         Model_Runner.Presentation.Put_Note
           (Screen, "cli.next.retry", [Model_Runner.Localization.Named ("name", "TASK-7")]);
         Model_Runner.Presentation.Put_Aside (Screen, "cli.interactive.help.projects");
         Assert (Model_Runner.Presentation.Session_Form (Screen, "or reconfigure x+=y")
                   = "or /reconfigure x+=y"
                 and then Ada.Strings.Fixed.Index
                            (Model_Runner.Presentation.Next_Step_Value
                               (Screen, "cli.next.accept_task",
                                [Model_Runner.Localization.Named ("name", "TASK-8")]),
                             "/task accept TASK-8") > 0,
                 "text naming a command was not written as a session types it");
         Set_Error (Standard_Error);
         Close (Said);
         Assert (Ada.Strings.Fixed.Index (Read_Whole ("obj/session-next.txt"),
                                          ASCII.LF & "project commands:") > 0,
                 "a line put aside was written with the program's name before it");
         Assert (Ada.Strings.Fixed.Index (Read_Whole ("obj/session-next.txt"), "/task accept TASK-7") > 0,
                 "a next step in a session was not its slash command: "
                 & Read_Whole ("obj/session-next.txt"));
      exception
         when others =>
            Set_Error (Standard_Error);
            raise;
      end;
   end Runs_Answer_From_Outside;

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
      --  The running task's workspace is given up with it, and said so.
      Assert (Says (To_String (Made.Id) & ": its directory is gone")
              or else Says ("its workspace " & To_String (Made.Id) & " is given up"),
              "a workspace whose directory is gone was not reconciled");
      Assert (Says ("WS-999999 has no record"),
              "a workspace directory with no record was not reported");

      Dirs.Delete_Tree (Dirs.Containing_Directory (S.Root (Store)) & "/.model_runner/workspaces/WS-999999");
      Wk.Recover_On_Opening (Store, (others => <>), Said, Status);
      Assert (E.Is_Ok (Status) and then Said.Is_Empty,
              "a second look found something to do: "
              & (if Said.Is_Empty then "" else Said.First_Element));

      --  A task left in verification with nothing to wait for is blocked,
      --  and a person may fail one that waits there.
      declare
         Task_V : Unbounded_String;
         Task_W : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Left verifying", "analysis"), "user", "", Task_V, Status);
         Tk.Create (Store, Change, Fields ("Waiting", "analysis"), "user", "", Task_W, Status);
         S.Commit (Store, Change, Status);
         for Id of Model_Runner.Framework.Name_Lists.Vector'([To_String (Task_V), To_String (Task_W)])
         loop
            Tk.Move (Store, Change, Id, "accepted", "", Status => Status);
            Tk.Move (Store, Change, Id, "running", "", Status => Status);
            Tk.Move (Store, Change, Id, "verification", "", Status => Status);
         end loop;
         S.Commit (Store, Change, Status);
         Wk.Recover_On_Opening (Store, (others => <>), Said, Status);
         Assert (Tk.State_Of (Store, To_String (Task_V)) = "blocked",
                 "a task left in verification was left there");
         Tk.Move (Store, Change, To_String (Task_V), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Change := S.No_Changes;
      end;

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

      --  The configuration cut short on disk is put back from its history,
      --  and an event nothing acted on is acted on.
      declare
         Config : R.Item;
         Req    : Unbounded_String;
         Said_Back, Acted : Boolean := False;
      begin
         Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                     "user", "", "io", Req, Status);
         Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted", Tr.Ordinary_Only,
                  Status);
         S.Commit (Store, Change, Status);
         Put_File (S.Root (Store) & "/config/resolved.rec", "model_runner-rec");
         Wk.Recover_On_Opening (Store, (others => <>), Said, Status);
         for Line of Said loop
            Said_Back := Said_Back or else Ada.Strings.Fixed.Index (Line, "from its history") > 0;
            Acted := Acted or else Ada.Strings.Fixed.Index (Line, "derived TASK-") > 0;
         end loop;
         Cf.Read (Store, Config, Status);
         Assert (E.Is_Ok (Status) and then Said_Back,
                 "a configuration that could not be read was not put back from its history: "
                 & Code_Of (Status));
         Assert (Acted, "events nothing had acted on were not acted on at opening");
      end;
      S.Close (Store);
   end Opening_Recovers;

   --  An agent that asks for children through the host, as a plan says.
   type Parent_Plan is
     (Helped, Fails_Twice, Fails_Then_Good, Optional_Fails, Left_Open, Denied,
      Checks_First, Interrupted, Out_Of_Time, Grandchild_Fails, Child_Unstarted);

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
            Assert (Children.Token_Budget >= 1, "an agent was given no tokens to spend");
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
         when Child_Unstarted =>
            --  A helper that cannot be started is not left the one working:
            --  its parent goes on as itself, and nothing is held up by it.
            Children.Open_Child
              ("reviewer", "required", "look at hello", "", Id, Context, Budget, Parent_Status);
            Assert (E.Is_Error (Parent_Status) and then Children.Current = Root,
                    "a helper that could not be started was left the one working: "
                    & Children.Current);
         when Grandchild_Fails =>
            --  Where the project may test but not build, a check is judged
            --  by what the configuration says it takes, and by its name
            --  only where it says nothing -- a compile is a build.
            Assert (Children.May_Check ("quick") and then not Children.May_Check ("compile"),
                    "what a check takes was guessed from its name over what is declared");
            Assert (Children.Tool_Budget = 40,
                    "the agent was not held to the tool calls the project allows:"
                    & Children.Tool_Budget'Image);

            --  A child whose own required child fails is not done, whatever
            --  it says: it is run again, as any failed required child is.
            Ask ("required", Child_Done, Close => False);
            declare
               Child   : constant String := To_String (Id);
               Grand   : Unbounded_String;
               Told    : Unbounded_String;
            begin
               for Attempt in 1 .. 2 loop
                  Children.Open_Child
                    ("reviewer", "required", "look deeper",
                     (if Attempt = 1 then "" else To_String (Grand)),
                     Grand, Context, Budget, Parent_Status);
                  Assert (E.Is_Ok (Parent_Status),
                          "a child could not ask for one of its own: " & Code_Of (Parent_Status));
                  Children.Close_Child (Child_Fails, 5, E.Success, Told, Retry);
               end loop;
               Children.Close_Child (Child_Done, 10, E.Success, Parent_Told, Retry);
               Assert (Retry, "a child whose required child failed was taken as done: "
                       & To_String (Parent_Told));
               Ask ("required", Child_Done, Child);
            end;
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
      declare
         Req   : Unbounded_String;
         Given : Tk.Field_Map := Fields ("Audited", "analysis");
      begin
         Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                     "user", "", "io", Req, Status);
         Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
                  Tr.Ordinary_Only, Status);
         S.Commit (Store, Change, Status);
         Given.Include ("requirements", To_String (Req));
         Tk.Create (Store, Change, Given, "user", "", Id, Status);
         S.Commit (Store, Change, Status);
      end;
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
                 and then Has (Answer (Said, "completion"), "its gates passed")
                 and then Has (Answer (Said, "requirement revisions"), "REQ-"),
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
         Assert (Status.Code = E.CLI_Invalid_Option_Value, "a policy that is none was taken");
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
         if Hostkit.Process.Locate ("git") /= ""
           and then Hostkit.Process.Run (Hostkit.Process.Locate ("git"), Args, Exit_Code)
           and then Exit_Code = 0
         then
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
         Model_Runner.CLI.Options.Normal);

      --  A console writing for a program never asks.
      Model_Runner.Presentation.Use_Structured (Screen, True);
      Assert (Model_Runner.Presentation.Is_Structured (Screen)
              and then not Model_Runner.CLI.Choosers.Is_Available (Screen),
              "a console writing for a program would ask");
      Model_Runner.Presentation.Use_Structured (Screen, False);
      Task_Project
        (Store, "session-work",
         "set execution.allowed = test" & LF
         & "profile checks = exists: test -f src/hello.adb" & LF
         & "scalar verification.default = checks" & LF);
      Tk.Create (Store, Change, Fields ("Greet the world", "analysis"), "user", "", First, Status);
      Tk.Create (Store, Change, Fields ("Count the stars", "analysis"), "user", "", Second, Status);
      S.Commit (Store, Change, Status);
      declare
         Zebra : Unbounded_String;
      begin
         for Title of Model_Runner.Framework.Name_Lists.Vector'(["Zebra one", "Zebra two"]) loop
            Tk.Create (Store, Change, Fields (Title, "analysis"), "user", "", Zebra, Status);
            S.Commit (Store, Change, Status);
            Tk.Move (Store, Change, To_String (Zebra), "accepted", "", Status => Status);
            S.Commit (Store, Change, Status);
         end loop;
      end;
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

         --  /task ID shows it, an action the command does not have says
         --  so, and /req show ID shows the requirement.
         declare
            use Ada.Text_IO;
            Said : File_Type;
            Path : constant String := "said.txt";
         begin
            Create (Said, Out_File, Path);
            Set_Output (Said);
            Set_Error (Said);
            Model_Runner.CLI.Project_Commands.Run ("/task " & To_String (First), Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/task nonsense", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/work zebra", Screen, Agent);
            --  For a program, the tasks it could be are a field of their own.
            Model_Runner.Presentation.Use_Structured (Screen, True);
            Model_Runner.CLI.Project_Commands.Run ("/work zebra", Screen, Agent);
            Model_Runner.Presentation.Use_Structured (Screen, False);
            Model_Runner.CLI.Project_Commands.Run ("/req new Stars counted text=the stars are counted", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/req new Other thing text=another thing is done", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/accept", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/trace REQ-001", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/check", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/check full", Screen, Agent);
            declare
               Search : Dirs.Search_Type;
               Found  : Dirs.Directory_Entry_Type;
               Name   : Unbounded_String := To_Unbounded_String ("RES-NONE.rec");
            begin
               Dirs.Start_Search (Search, ".model_runner/results", "RES-*.rec");
               if Dirs.More_Entries (Search) then
                  Dirs.Get_Next_Entry (Search, Found);
                  Name := To_Unbounded_String (Dirs.Simple_Name (Found));
               end if;
               Dirs.End_Search (Search);
               Model_Runner.CLI.Project_Commands.Run
                 ("/result " & Slice (Name, 1, Length (Name) - 4), Screen, Agent);
            end;
            Model_Runner.CLI.Project_Commands.Run ("/cancel", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/state", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/accept REQ-002", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/accept REQ-404", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/bootstrap nowhere.md", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/req show REQ-001", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/req move REQ-001 accepted", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run
              ("/req revise REQ-001 text=the stars are counted twice", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/reconfigure scalar.work.lease=120", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run
              ("/reconfigure scalar.work.lease=90 confirm=yes", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run
              ("/reconfigure profile.checks=exists: test -d src confirm=yes", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run
              ("/req new 'the program's name' --set text=it is said", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/req new Bogus text=x bogus=1", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/result TASK-099", Screen, Agent);
            Model_Runner.CLI.Project_Commands.Run ("/result dismiss REQ-001", Screen, Agent);
            Set_Output (Standard_Output);
            Set_Error (Standard_Error);
            Close (Said);
            declare
               Text : constant String := Read_Whole (Path);
            begin
               Assert (Ada.Strings.Fixed.Index (Text, "more than one matches: TASK-") > 0,
                       "an ambiguous work selector off a terminal did not fail with its matches");
               Assert (Ada.Strings.Fixed.Index (Text, """matches"": ""TASK-") > 0,
                       "an ambiguous work selector for a program did not give its matches: " & Text);
               Assert (Ada.Strings.Fixed.Index (Text, "decide one by name") > 0,
                       "a bare /accept with more than one waiting did not refuse and list them");
               Assert (Ada.Strings.Fixed.Index (Text, "the program's name") > 0
                       and then Ada.Strings.Fixed.Index (Text, "it is said --set") = 0,
                       "an apostrophe inside quotes, or --set on a requirement, was not taken as"
                       & " typed: " & Text);
               Assert (Ada.Strings.Fixed.Index (Text, "bogus is not one") > 0,
                       "a field a requirement does not take was dropped unsaid");
               Assert (Ada.Strings.Fixed.Index (Text, "TASK-099 is not in the project state") > 0
                       and then Ada.Strings.Fixed.Index (Text, "REQ-001 is not an issue") > 0,
                       "a result asked of what is not there, or dismissed that is no issue, was"
                       & " not refused by name");
               Assert (Ada.Strings.Fixed.Index (Text, "open issues (result lists them)") > 0,
                       "state did not count the open issues");
               Assert (Ada.Strings.Fixed.Index (Text, "REQ-001") > 0
                       and then Ada.Strings.Fixed.Index (Text, "checks:") > 0,
                       "/trace or /check said nothing of what it was asked: " & Text);
               Assert (Ada.Strings.Fixed.Index (Text, "kind: ") > 0
                       and then Ada.Strings.Fixed.Index (Text, "payload: ") > 0,
                       "/result did not show the result it names");
               Assert (Ada.Strings.Fixed.Index (Text, "nothing is running in the foreground") > 0,
                       "/cancel with nothing running did not say so");
               Assert (Ada.Strings.Fixed.Index (Text, "complete tasks: 2") > 0
                       and then Ada.Strings.Fixed.Index (Text, "candidate tasks: 0") > 0,
                       "/state did not count the tasks as the state holds them: " & Text);
               Assert (Ada.Strings.Fixed.Index (Text, "runtime.state") > 0
                       and then Ada.Strings.Fixed.Index (Text, "nonsense") > 0
                       and then Ada.Strings.Fixed.Index (Text, "Stars counted") > 0
                       and then Ada.Strings.Fixed.Index (Text, "moved from") > 0
                       and then Ada.Strings.Fixed.Index (Text, "a proposal REQ-404") > 0
                       and then Ada.Strings.Fixed.Index (Text, "nowhere.md is not a value for a document"
                                                           & " to read: there is no such file") > 0
                       and then Ada.Strings.Fixed.Index (Text, "not given: confirm") > 0,
                       "/task ID, an unknown /task action or /req show said nothing: " & Text);
            end;
         exception
            when others =>
               Set_Output (Standard_Output);
               Set_Error (Standard_Error);
               raise;
         end;
         Dirs.Set_Directory (Before);
         S.Open (Store, Root, Report, Status);
      exception
         when others =>
            Dirs.Set_Directory (Before);
            raise;
      end;
      declare
         Held : Nt.Entity;
      begin
         Nt.Read (Store, Nt.Requirement, "REQ-002", Held, Status);
         Assert (To_String (Held.State) = "accepted",
                 "/accept ID did not decide the one it names: " & To_String (Held.State));
         Nt.Read (Store, Nt.Requirement, "REQ-001", Held, Status);
         Assert (To_String (Held.Text) = "the stars are counted twice",
                 "a revised text was cut to its first word: " & To_String (Held.Text));
      end;
      declare
         Config : R.Item;
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Status);
         Assert (R.Get (Config, "scalar.work.lease") = "90",
                 "/reconfigure was not refused unconfirmed off a terminal, or not taken"
                 & " confirmed: " & R.Get (Config, "scalar.work.lease"));
         Assert (R.Get (Config, "profile.checks") = "exists: test -d src",
                 "a value of several words was not taken whole: " & R.Get (Config, "profile.checks"));
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
      declare
         Named : Boolean := False;
      begin
         for Index in 1 .. Cx.Included_Count (Built) loop
            Named := Named
              or else (Ada.Strings.Fixed.Index (To_String (Cx.Included_At (Built, Index).Id),
                                                "#results:RES-") > 0
                       and then Ada.Strings.Fixed.Index
                                  (To_String (Cx.Included_At (Built, Index).Id), "VER-") > 0);
         end loop;
         Assert (Named, "the manifest did not name the results and evidence the context took in");
      end;

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
         Assert (Contains (R.Get (Root_Call, "tool_policy"), "tools: read_file")
                 and then Contains (R.Get (Root_Call, "tool_policy"), "delegate")
                 and then Contains (R.Get (Root_Call, "tool_policy"), "permissions:"),
                 "the call did not record what it could use: " & R.Get (Root_Call, "tool_policy"));
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
              and then Contains (To_String (Done.Reason), "interrupted")
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

      --  Two deep: a child whose own required child failed.
      Task_Project
        (Store, "grandchildren",
         Checks
         & "map permission.project.read_source =" & LF
         & "map permission.project.write_source =" & LF
         & "map permission.project.run_tests =" & LF
         & "map permission.project.create_children = max_depth=2, max_children=8" & LF
         & "scalar agents.max_depth = 2" & LF
         & "scalar agents.max_children = 8" & LF
         & "scalar agents.max_active = 8" & LF
         & "scalar profile_capability.quick = run_tests" & LF
         & "scalar agents.max_tool_calls = 40" & LF);
      Work (Grandchild_Fails);
      Assert (To_String (Done.Final_State) = "complete",
              "a child run again past its failed child did not let the task complete: "
              & To_String (Done.Reason));
      S.Close (Store);

      --  Stopped where nothing concludes it -- its prompt cannot be written --
      --  a task is still not left running.
      Task_Project (Store, "unwritable-prompt", Checks);
      if Dirs.Exists (S.Root (Store) & "/runtime/exec") then
         Remove_Tree (S.Root (Store) & "/runtime/exec");
      end if;
      Put_File (S.Root (Store) & "/runtime/exec", "not a directory");
      declare
         Id : Unbounded_String;
      begin
         Tk.Create (Store, Change, Fields ("Nowhere to write", "analysis"), "user", "", Id, Status);
         S.Commit (Store, Change, Status);
         Tk.Move (Store, Change, To_String (Id), "accepted", "", Status => Status);
         S.Commit (Store, Change, Status);
         Wk.Execute (Store, To_String (Id), Scripted_Parent'(Plan => Helped),
                     Cx.Profile (Store, ""), Done, Status);
         Assert (Tk.State_Of (Store, To_String (Id)) = "blocked"
                 and then Contains (To_String (Done.Reason), "its work stopped"),
                 "work that stopped with no conclusion left its task "
                 & Tk.State_Of (Store, To_String (Id)));
      end;
      S.Close (Store);

      --  Two calls allowed: the root's and its helper's -- the context kept
      --  beside a call is no call of its own.
      Task_Project (Store, "two-invocations", Checks & "scalar agents.max_invocations = 2" & LF);
      Work (Helped);
      Assert (To_String (Done.Final_State) = "complete",
              "a helper within the calls allowed was refused: " & To_String (Done.Reason));
      S.Close (Store);

      --  No invocation left for a helper: it is not made, and the work goes on.
      Task_Project (Store, "child-unstarted", Checks & "scalar agents.max_invocations = 1" & LF);
      Work (Child_Unstarted);
      Assert (To_String (Done.Final_State) = "complete",
              "a helper that could not be started held its task: " & To_String (Done.Reason));
      S.Close (Store);

      --  The root is held to its token budget as its children are.
      Task_Project (Store, "root-budget", Checks & "scalar agents.token_budget = 3" & LF);
      Work (Checks_First);
      Assert (To_String (Done.Final_State) = "blocked"
              and then Contains (To_String (Done.Reason), "budget"),
              "a root past its token budget went on: " & To_String (Done.Final_State) & " "
              & To_String (Done.Reason));
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
      Assert (Natural (Or_ch.Rules (Store).Length) = 9,
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

      --  One action failing holds back neither the others nor the events.
      S.Close (Store);
      Task_Project (Store, "orchestration-failing",
                    "list automation.rules = *: verify" & LF
                    & "list automation.rules = Requirement_Accepted: derive_tasks" & LF
                    & "profile broken = go: nosuchprogram" & LF
                    & "scalar verification.default = broken" & LF);
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Or_ch.Step (Store, Done, Status);
      Assert (E.Is_Error (Status) and then Natural (Done.Derived.Length) = 1,
              "a failing action held back the others, or was not said: " & Code_Of (Status));
      --  The events whose action failed wait to be acted on again; what
      --  was done is not done twice.
      Or_ch.Step (Store, Done, Status);
      Assert (Done.Events_Seen > 0 and then Done.Derived.Is_Empty,
              "events a failed action called for were dropped, or acted on twice");
      S.Close (Store);
      Task_Project (Store, "orchestration-again", "scalar agents.max_active = 2" & LF);
      Nt.Propose (Store, Change, Nt.Requirement, "IO", "Read", "It SHALL read.", "",
                  "user", "", "io", Req, Status);
      Nt.Move (Store, Change, Nt.Requirement, To_String (Req), "accepted",
               Tr.Ordinary_Only, Status);
      S.Commit (Store, Change, Status);
      Or_ch.Step (Store, Done, Status);
      Or_ch.Step (Store, Done, Status);

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
      --  Two slots, but one tree: in the project itself, one writer.
      Assert (Plan.Slots = 2 and then Natural (Plan.Start.Length) = 1
              and then Plan.Start.First_Element = To_String (Ids (2)),
              "dispatch did not start the most important task alone in the project");
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
        (T, Contexts_Models_And_Evidence_Say_What_They_Must'Access,
         "contexts, model profiles, manifests and evidence say what they must");
      Register_Routine
        (T, Consistency_Sees_Every_Wrong_Reference'Access,
         "the consistency check sees every kind of wrong reference");
      Register_Routine
        (T, Harness_Runs_Routine_Stages'Access,
         "the harness runs a project's generators and formatter before verifying the work");
      Register_Routine
        (T, Workspaces_Start_And_End_Whole'Access,
         "workspaces start from the project as it is and end once their work is kept");
      Register_Routine
        (T, Readiness_Follows_What_Is_Served'Access,
         "a task is ready only while what it serves is agreed, and names only what is there");
      Register_Routine
        (T, State_Is_The_Harness_Own'Access,
         "the project's state is put back after an agent or a check writes it");
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
        (T, Runs_Answer_From_Outside'Access,
         "a run answers what is asked from outside it, and says why checks did not pass");
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
        (T, Other_Languages_Are_Read'Access,
         "C, Rust and Python files are read for their units, symbols and uses");
      Register_Routine
        (T, Terminal_Restored_After_Cancel'Access,
         "a chooser cancelled with Ctrl-C leaves the terminal as it found it");
      Register_Routine
        (T, Terminal_Follows_Resize_And_Hides_Secrets'Access,
         "the selector redraws on a resize, and a secret is typed unseen");
      Register_Routine
        (T, Indexes_Are_Derived'Access,
         "the derived indexes are made at init and known to be stale when they are");
      Register_Routine
        (T, Agents_Stay_Out_Of_The_State'Access,
         "agents never reach the project's state, and harness programs get only what is passed");
      Register_Routine
        (T, Requirements_Verified_By_Policy'Access,
         "a requirement is verified by its own evidence where the project says so");
      Register_Routine
        (T, Init_Undone_When_Unsound'Access,
         "an initialization's result is checked, and said, before it stands");
      Register_Routine
        (T, Bootstrap_Follows_Its_Policy'Access,
         "bootstrap reads, makes and accepts what its policy says");
      Register_Routine
        (T, Requirement_Lifecycle_Is_The_Projects'Access,
         "a project adds requirement states with their meaning, and moves between them");
      Register_Routine
        (T, Task_Lifecycle_Is_The_Projects'Access,
         "a project extends and restricts the task lifecycle, within the harness's own moves");
      Register_Routine
        (T, Work_Apart_Is_Accounted'Access,
         "an agent run apart is accounted, and given the time the policy allows");
      Register_Routine
        (T, Derivation_Is_Idempotent'Access,
         "a requirement derives its task once, however often derivation"
         & " runs");
   end Register_Tests;

end Tests.Framework_Cases;
