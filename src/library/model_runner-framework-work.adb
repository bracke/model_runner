with Ada.Exceptions;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Hostkit.Fs;

with Model_Runner.Framework.Agents;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Indexes;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Invocations;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Text;

package body Model_Runner.Framework.Work is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Lease_Of (Task_Id : String) return String
   is ("task." & Task_Id);

   ------------------
   -- Instructions --
   ------------------

   --  A task its agent may write nothing for is one to answer: read what
   --  it needs, and say what it found -- not told to change files it may
   --  not, which would only fail it.
   Read_Only_Opening : constant String :=
     "## What to do" & ASCII.LF
     & "Do the task now by reading, with paths relative to the project. This"
     & " task is answered, not written: you may change no file, and a change to"
     & " any file fails the work. Put what you found in summary:, and more of it,"
     & " a finding a line, under findings:." & ASCII.LF & ASCII.LF
     & "When you have the answer, finish with a short report in these lines:"
     & ASCII.LF & ASCII.LF
     & "status: done" & ASCII.LF
     & "summary: one line on what you found" & ASCII.LF
     & "changed_files: none" & ASCII.LF & ASCII.LF;

   --  Only what the agent has is described: a sentence about a tool it
   --  does not hold is tokens spent on nothing, or a call it cannot make.
   function Instructions_For
     (May_Propose  : Boolean;
      May_Split    : Boolean := True;
      May_Write    : Boolean := True;
      May_Delegate : Boolean := True;
      May_Check    : Boolean := True) return String
   is ((if not May_Write then Read_Only_Opening
        else "## What to do" & ASCII.LF
       & "Do the task now with your tools, paths relative to the project. Make each"
       & " change by calling write_file with the whole new content; describing a"
       & " change does not make it."
       & (if May_Delegate
          then " Hand a part better done apart -- a review, an investigation -- to a helper"
               & " with delegate."
          else "")
       & (if May_Check then " Check what you wrote with run_checks." else "")
       & ASCII.LF & ASCII.LF
       & "When the files are written, finish with a short report in these lines:"
       & ASCII.LF & ASCII.LF
       & "status: done" & ASCII.LF
       & "summary: one line on what you did" & ASCII.LF
       & "changed_files: the files you wrote" & ASCII.LF & ASCII.LF)
       & "If you could not do it, status: failed, and the summary says why; blocked is for a"
       & " decision only a person can make. Lines you may add:"
       & (if May_Propose
          then " proposed_tasks: (more work found, TITLE; kind=K a line)"
               & (if May_Split then ", parts: (too large to do as one: say blocked, a part a line)" else "")
               & ", decisions:, specifications:"
          else " issues: (more work found, a line each)")
       & ", waits_for: (a task to wait for), verify: yes"
       & (if May_Delegate then ", instead: (how you did a failed helper's part)" else "")
       & "."
       & ASCII.LF);

   function Instructions return String is (Instructions_For (May_Propose => True));

   --  Names a comma apart.
   function Comma_Separated (Names : Name_Lists.Vector) return String is
      Text : Unbounded_String;
   begin
      for Name of Names loop
         Append (Text, (if Text = Null_Unbounded_String then "" else ", ") & Name);
      end loop;
      return To_String (Text);
   end Comma_Separated;

   --  The fields of a tab-separated line.
   function Fields_Of (Text : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.HT then
            Result.Append (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Fields_Of;

   --  The parts of a line between separators.
   function Split_On (Text : String; Separator : Character) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
      Start  : Natural := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = Separator then
            Result.Append (Text (Start .. Index - 1));
            Start := Index + 1;
         end if;
      end loop;
      return Result;
   end Split_On;

   --  A list written with commas, as one written a line an item.
   function Replaced (Text : String) return String is
      Result : String := Text;
   begin
      for C of Result loop
         if C = ',' then
            C := ASCII.LF;
         end if;
      end loop;
      return Result;
   end Replaced;

   --  Whether a run was stopped by its time running out.
   function Out_Of_Time (Ran : E.Error_Info) return Boolean is
      Found : Boolean;
      Given : E.Parameter;
   begin
      if not E."=" (Ran.Code, E.Framework_Limit_Exceeded) then
         return False;
      end if;
      E.Find_Parameter (Ran, "name", Found, Given);
      return Found and then Model_Runner.Text.To_String (Given.Text_Value) = "time";
   end Out_Of_Time;

   --  Whether a run was stopped by whoever started it.
   function Interrupted (Ran : E.Error_Info) return Boolean
   is (E."=" (Ran.Code, E.Generation_Cancelled));

   --  Why a task could start, as it stood when it did: what it waited for
   --  and what state that was in, that nothing held it or its component,
   --  and what it was to be checked by -- kept, because afterwards the
   --  state that said so is gone.
   function Admission (Item : Stores.Store; Task_Id : String; Isolated : Boolean) return String is
      Defined : Records.Item;
      Status  : E.Error_Info;
      Text    : Unbounded_String;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      Append (Text, "it was " & Tasks.State_Of (Item, Task_Id) & " and ready");
      declare
         Waits : constant Name_Lists.Vector := Lines_Of (Records.Get (Defined, "depends_on"));
      begin
         if Waits.Is_Empty then
            Append (Text, "; it waited for nothing");
         else
            for Other of Waits loop
               Append (Text, "; " & Other & " was " & Tasks.State_Of (Item, Other));
            end loop;
         end if;
      end;
      Append (Text, "; no agent held it");
      Append (Text, (if Isolated then "; it was to write in a workspace of its own"
                     elsif Records.Get (Defined, "component") = "" then "; it named no component"
                     else "; no agent was writing " & Records.Get (Defined, "component")));
      Append (Text, "; kind " & Records.Get (Defined, "kind")
              & ", definition revision" & Natural'Image (Records.Revision (Defined))
              & ", checked by " & Verification.Profile_Of (Item, Task_Id));
      return To_String (Text);
   end Admission;

   --  A task's component.
   function Component_Of (Item : Stores.Store; Task_Id : String) return String is
      Defined : Records.Item;
      Status  : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      return Records.Get (Defined, "component");
   end Component_Of;

   --  A task's kind.
   function Kind_Of (Item : Stores.Store; Task_Id : String) return String is
      Defined : Records.Item;
      Status  : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      return Records.Get (Defined, "kind");
   end Kind_Of;

   --  A number a policy gives, or a default.
   function Number_Of (Text : String; Default : Natural) return Natural
   is (if Text'Length in 1 .. 9 and then (for all C of Text => C in '0' .. '9')
       then Natural'Value (Text) else Default);

   --  A scalar of the configuration.
   function Scalar (Item : Stores.Store; Name : String) return String is
      Config : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Config, Status);
      return Records.Get (Config, "scalar." & Name);
   end Scalar;

   --  A setting of the configuration's work.
   function Work_Setting (Item : Stores.Store; Name : String) return String is
      Config : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Config, Status);
      return Records.Get (Config, "scalar.work." & Name);
   end Work_Setting;

   --  How long an agent holds its task before it must have finished.
   function Lease_Seconds (Item : Stores.Store) return Positive is
      Config : Records.Item;
      Status : E.Error_Info;
   begin
      Configurations.Read (Item, Config, Status);
      declare
         Text : constant String := Records.Get (Config, "scalar.work.lease");
      begin
         return (if Text'Length in 1 .. 7 and then (for all C of Text => C in '0' .. '9')
                   and then Natural'Value (Text) > 0
                 then Natural'Value (Text) else 3600);
      end;
   end Lease_Seconds;

   --  Set a field of a task's runtime record, in the transaction.
   procedure Annotate
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Field   : String;
      Value   : String)
   is
      Held   : Records.Item;
      Staged : Boolean;
      Status : E.Error_Info;
   begin
      Stores.Pending (Change, Tasks_Area, Task_Id & ".state", Held, Staged);
      if not Staged then
         Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Held, Records.Revision (Held) + 1);
      end if;
      Records.Set (Held, Field, Value);
      Stores.Put (Change, Tasks_Area, Task_Id & ".state", Held);
   end Annotate;

   ----------------
   -- File_Print --
   ----------------

   function File_Print (Path : String) return String is
      Text : Unbounded_String;
      Got  : E.Error_Info;
   begin
      if not Ada.Directories.Exists (Path) then
         return "-";
      end if;
      Files.Read_Text (Path, Text, Got);
      return (if E.Is_Ok (Got) then Fingerprint (To_String (Text)) else "-");
   end File_Print;

   -----------------
   -- Note_Undone --
   -----------------

   procedure Note_Undone (Item : in out Stores.Store; Task_Id, Copy : String) is
      Change : Stores.Transaction;
      Status : E.Error_Info;
      Held   : Records.Item;
      Got    : E.Error_Info;
      Event  : Unbounded_String;
   begin
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Got);
      Annotate (Item, Change, Task_Id, "undone_by", Copy);
      --  In its history too, where it changes how its work stands.
      if E.Is_Ok (Got) and then Records.Get (Held, "undone_by") /= Copy then
         Events.Emit (Item, Change, Events.Task_Revised, Task_Id,
                      (if Copy /= "" then "its work undone in the project: " & Copy & " was put back over it"
                       else "its work back in the project, as a kept copy put it there"),
                      Event, Status);
      end if;
      Stores.Commit (Item, Change, Status);
   end Note_Undone;

   -------------------
   -- Note_Restored --
   -------------------

   procedure Note_Restored (Item : in out Stores.Store; Task_Id : String; Files : Name_Lists.Vector) is
      Change  : Stores.Transaction;
      Status  : E.Error_Info;
      Held    : Records.Item;
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
      Prints  : Unbounded_String;
   begin
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      --  Its other files as they were taken in; these as they are now.
      for Line of Lines_Of (Records.Get (Held, "taken_in")) loop
         declare
            Tab : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
         begin
            if Tab = 0 or else not Files.Contains (Line (Line'First .. Tab - 1)) then
               Append (Prints, Line & ASCII.LF);
            end if;
         end;
      end loop;
      for Path of Files loop
         Append (Prints, Path & ASCII.HT & File_Print (Hostkit.Fs.Join (Project, Path)) & ASCII.LF);
      end loop;
      Annotate (Item, Change, Task_Id, "taken_in", To_String (Prints));
      Stores.Commit (Item, Change, Status);
   end Note_Restored;

   ---------------
   -- Holder_Of --
   ---------------

   function Holder_Of (Item : Stores.Store; Path : String) return String is
      Now   : constant String :=
        File_Print (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Stores.Root (Item)), Path));
      Found : Unbounded_String;
   begin
      if Now = "-" then
         return "";
      end if;
      for Id of Tasks.List (Item) loop
         declare
            Held   : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, Id & ".state", Held, Status);
            if E.Is_Ok (Status) then
               for Line of Lines_Of (Records.Get (Held, "taken_in")) loop
                  if Line = Path & ASCII.HT & Now then
                     Found := To_Unbounded_String (Id);
                  end if;
               end loop;
            end if;
         end;
      end loop;
      return To_String (Found);
   end Holder_Of;

   ------------------------
   -- Forget_Last_Answer --
   ------------------------

   procedure Forget_Last_Answer (Item : in out Stores.Store; Task_Id : String) is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      Annotate (Item, Change, Task_Id, "last_result", "");
      Stores.Commit (Item, Change, Status);
   end Forget_Last_Answer;

   --  What was taken in, kept as a result -- the files, and the project's
   --  revision they made, which integration made the state it is in --
   --  named on the task, and said as a change to the source.
   procedure Report_Integration
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Id      : String;
      Task_Id : String;
      Taken   : Name_Lists.Vector;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Listed : Unbounded_String;
      Event  : Unbounded_String;
   begin
      for Path of Taken loop
         Append (Listed, Path & ASCII.LF);
      end loop;
      declare
         Report_Of : Results.Result :=
           (Kind       => Results.Integration_Report,
            Producer   => To_Unbounded_String ("integration"),
            Summary    => To_Unbounded_String
                            (Id & " taken in for " & Task_Id & ", the project now at "
                             & Repository.Graph_Fingerprint (Repository.Now (Item))),
            Payload    => Listed,
            Provenance => To_Unbounded_String (Id),
            others     => <>);
      begin
         Results.Add (Item, Change, Report_Of, Status);
         if E.Is_Ok (Status) then
            Annotate (Item, Change, Task_Id, "integration_report", To_String (Report_Of.Id));
            Events.Emit (Item, Change, Events.Source_Changed, Task_Id,
                         "taken in from " & Id, Event, Status);
         end if;
      end;
   end Report_Integration;

   --  Set an agent record's state, in the transaction.
   procedure Agent_State
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Agent  : String;
      State  : String;
      Note   : String := "";
      Outcome : String := "")
   is
      Held   : Records.Item;
      Staged : Boolean;
      Status : E.Error_Info;
   begin
      Stores.Pending (Change, Runtime_Area, "agent." & Agent, Held, Staged);
      if not Staged then
         Stores.Read (Item, Runtime_Area, "agent." & Agent, Held, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Held, Records.Revision (Held) + 1);
      end if;
      Records.Set (Held, "state", State);
      if State /= "running" then
         Records.Set (Held, "ended_at", Timestamp);
      end if;
      --  Said once: as its summary where it has none, else as a note
      --  beside it.
      if Note /= "" then
         if Records.Get (Held, "summary") = "" then
            Records.Set (Held, "summary", Note);
         elsif Records.Get (Held, "summary") /= Note then
            Records.Set (Held, "note", Note);
         end if;
      end if;
      --  What its attempt left the task as, where that is known here.
      if Outcome /= "" then
         Records.Set (Held, "outcome", Outcome);
      end if;
      Stores.Put (Change, Runtime_Area, "agent." & Agent, Held);
   end Agent_State;

   --  The agent holding a running task, from its lease.
   function Holder_Record (Item : Stores.Store; Task_Id : String) return String is
      Held   : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Runtime_Area, "lease." & Lease_Of (Task_Id), Held, Status);
      return (if E.Is_Ok (Status) then Records.Get (Held, "owner") else "");
   end Holder_Record;

   --  The execution generation a task is in.
   function Generation_Of (Item : Stores.Store; Task_Id : String) return String is
      Held   : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Status);
      return (if E.Is_Ok (Status) then Records.Get (Held, "generation") else "");
   end Generation_Of;

   --  Every file's fingerprint, by path.
   function Snapshot
     (Project : String;
      Within  : Repository.Roots) return Configurations.Value_Maps.Map;

   --  Where a run working in the project itself keeps what the files were
   --  when it started, for an opening after it was killed to say what it
   --  left: runtime/before-TASK, a path and its fingerprint a line.
   function Before_File (Item : Stores.Store; Task_Id : String) return String
   is (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "before-" & Task_Id));

   --  Where a task's files are kept as they were before its agents wrote
   --  them.
   function Before_Copy (Item : Stores.Store; Task_Id : String) return String
   is (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "overwritten-" & Task_Id));

   --  What an answer says in its own words: the instructions' own example
   --  line copied back -- one line on what you did -- is no summary.
   function Own_Words (Summary : String) return String
   is (if Ada.Strings.Fixed.Index (Ada.Characters.Handling.To_Lower (Summary), "one line on what you") > 0
       then "(its summary was the instructions' example line, not its own words)" else Summary);

   --  What a run stopped part way left in the project, and the ways on,
   --  said alike however it stopped.
   function Left_Words
     (Item : Stores.Store; Files_Named, Task_Id : String; Cancelled : Boolean := False) return String
   is ("; what it changed is still in the project: " & Files_Named
       --  Undone by the project's version control where it has one; where
       --  it has none, nothing keeps what was there before.
       --  Copied aside before they were first written: put back from
       --  there, whatever version control knows of them.
       & (if Ada.Directories.Exists (Before_Copy (Item, Task_Id))
          then " -- /task kept restore overwritten-" & Task_Id & " puts back the files it overwrote,"
               & " and removing a file it made undoes that,"
          elsif Ada.Directories.Exists
               (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Stores.Root (Item)), ".git"))
          then " -- git checkout -- FILE undoes a change, and removing a file it made undoes that,"
          else " -- the project has no version control to undo it from: look at each, and put"
               & " back what should not be,")
       --  A cancelled task is not completed but taken up again.
       & (if Cancelled then " or /task reopen " & Task_Id & " takes it up again"
          else " or, where what it changed does the task, /task complete " & Task_Id
               & " takes it as done, its checks passing"));

   --  A task's kind, as its definition says.
   function Kind_Of_Task (Item : Stores.Store; Task_Id : String) return String is
      Defined : Records.Item;
      Read    : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      return (if E.Is_Ok (Read) then Records.Get (Defined, "kind") else "");
   end Kind_Of_Task;

   --  Every child of an agent still going is cancelled with it: a child
   --  outlives nothing it was made for.
   procedure Stop_Children
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Agent  : String;
      Why    : String)
   is
      Stopped : Name_Lists.Vector;
      Status  : E.Error_Info;
   begin
      for Child of Agents.Children (Item, Agent) loop
         Agents.Cancel (Item, Change, Child, Stopped, Status, Why => "it was stopped: " & Why);
      end loop;
   end Stop_Children;

   -------------
   -- Recover --
   -------------

   procedure Recover
     (Item      : in out Stores.Store;
      Recovered : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info)
   is separate;

   function Raw_Why_Of (Condition : E.Error_Info) return String is
      Result : Unbounded_String := To_Unbounded_String (E.Diagnostic_Code (Condition.Code));
   begin
      for Index in 1 .. Condition.Parameter_Total loop
         declare
            One : constant E.Parameter := Condition.Parameters (Index);
         begin
            Append (Result, (if Index = 1 then " (" else "; ")
                            & Model_Runner.Text.To_String (One.Name) & ": "
                            & (case One.Kind is
                                  when E.Param_Integer | E.Param_Bytes | E.Param_Tokens
                                     | E.Param_Offset => Model_Runner.Text.Image (One.Int_Value),
                                  when E.Param_Boolean => (if One.Bool_Value then "yes" else "no"),
                                  when others => Model_Runner.Text.To_String (One.Text_Value)));
         end;
      end loop;
      if Condition.Parameter_Total > 0 then
         Append (Result, ")");
      end if;
      return To_String (Result);
   end Raw_Why_Of;

   --  The words a condition is said in -- the catalog's English, which the
   --  records a person reads later are kept in -- and its code, for looking
   --  it up.
   English : Model_Runner.Localization.Catalog;

   function Why_Of (Condition : E.Error_Info) return String is
   begin
      if not Model_Runner.Localization.Is_Ready (English) then
         Model_Runner.Localization.Open (English, Model_Runner.Platform.Catalog_Path, "en");
      end if;
      if Model_Runner.Localization.Is_Ready (English) then
         declare
            Said : constant String := Model_Runner.Localization.Describe (English, Condition);
         begin
            --  One that will not render -- a value its message names is
            --  missing -- is said as what it holds instead.
            if Said'Length > 0 and then Said (Said'First) /= '<' then
               return Said & " [" & E.Diagnostic_Code (Condition.Code) & "]";
            end if;
         end;
      end if;
      return Raw_Why_Of (Condition);
   end Why_Of;

   --  Why a task stopped for a required helper that failed: the helper's
   --  failure, with the root's own only when it says something more,
   --  and the setting that decides what such a failure does.
   function Child_Failure (Child_Why, Own_Why : String; Policy : String := "") return String is
      --  Without its code -- [MR-...] -- for telling one failure said twice
      --  from two.
      function Bare (Text : String) return String is
         Mark : constant Natural := Ada.Strings.Fixed.Index (Text, " [MR-");
      begin
         return (if Mark = 0 then Text else Text (Text'First .. Mark - 1));
      end Bare;
      Said : constant String :=
        (if Ada.Strings.Fixed.Index (Child_Why, Bare (Own_Why)) > 0
           or else Ada.Strings.Fixed.Index (Own_Why, Bare (Child_Why)) > 0
         then Child_Why
         else Child_Why & "; and then " & Own_Why);
   begin
      --  continue set already, and not gone on: why, not the setting again.
      return Said
        & (if Policy = "continue"
           then " (agents.on_child_failure is continue, which goes on only once the agent finishes and says"
                & " instead: how it did the failed part; this run ended before that)"
           else " (agents.on_child_failure decides what a failed helper does: block, fail or continue)");
   end Child_Failure;

   --  The first few diagnostics a piece of evidence recorded, said after
   --  a colon: what a person looks at first.
   function First_Diagnostics (Item : Stores.Store; Evidence : String) return String is
      Found  : constant Verification.Diagnostic_List :=
        Verification.Diagnostics_Of (Item, Evidence);
      Result : Unbounded_String;
   begin
      for Index in 1 .. Natural'Min (3, Verification.Length (Found)) loop
         declare
            One : constant Verification.Diagnostic := Verification.Element (Found, Index);
         begin
            Append (Result, (if Index = 1 then ": " else "; ")
                    & (if Length (One.File) > 0 and then One.Line > 0
                       then To_String (One.File) & ":" & Trim (Natural'Image (One.Line)) & ": "
                       elsif Length (One.File) > 0 then To_String (One.File) & ": "
                       else "")
                    & To_String (One.Message));
         end;
      end loop;
      if Verification.Length (Found) > 3 then
         Append (Result, "; and" & Natural'Image (Verification.Length (Found) - 3) & " more");
      end if;

      --  No diagnostic read from it: what failed and how it ended.
      if Result = Null_Unbounded_String then
         for Line of Verification.Why_Failed (Item, Evidence, Lines => 3) loop
            Append (Result, (if Result = Null_Unbounded_String then ": " else "; ") & Line);
         end loop;
      end if;
      return To_String (Result);
   end First_Diagnostics;

   ----------------
   -- Reevaluate --
   ----------------

   procedure Reevaluate
     (Item   : in out Stores.Store;
      Said   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is separate;

   ------------------------
   -- Recover_On_Opening --
   ------------------------

   procedure Recover_On_Opening
     (Item   : in out Stores.Store;
      Opened : Stores.Recovery_Report;
      Said   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is separate;

   --  A condition as a reason reads: its code, and what it names -- a
   --  person acts on the detail, not on the name of a code.

   --  What running a profile takes: what the configuration says of it,
   --  scalar profile_capability.NAME -- else, by its name, tests or
   --  analysis, and anything else a build, which may run whatever it names.
   function Check_Capability (Item : Stores.Store; Profile : String) return Permissions.Capability is
      Named : constant String := Ada.Characters.Handling.To_Lower (Profile);
      Said  : constant String := Scalar (Item, "profile_capability." & Profile);
   begin
      return (if Said = "run_tests" then Permissions.Run_Tests
              elsif Said = "run_static_analysis" then Permissions.Run_Static_Analysis
              elsif Said = "run_build" then Permissions.Run_Build
              elsif Ada.Strings.Fixed.Index (Named, "analysis") > 0
                or else Ada.Strings.Fixed.Index (Named, "lint") > 0
              then Permissions.Run_Static_Analysis
              elsif Ada.Strings.Fixed.Index (Named, "test") > 0 then Permissions.Run_Tests
              else Permissions.Run_Build);
   end Check_Capability;

   --  Whether an agent with these permissions is offered run_checks: one
   --  working in the project, let run its task's own profile.
   function Offers_Checks
     (Item : Stores.Store; Allowed : Permissions.Permission_Set; Task_Id : String; Apart : Boolean)
      return Boolean
   is (not Apart and then Task_Id /= ""
       and then Verification.Profile_Of (Item, Task_Id) /= ""
       and then Permissions.Allows_Profile
                  (Allowed, Check_Capability (Item, Verification.Profile_Of (Item, Task_Id)),
                   Verification.Profile_Of (Item, Task_Id)));

   --  What an agent's call may use, as its invocation records it: the
   --  tools it is offered -- reading always, checks, writing and helpers
   --  where its permissions let it -- what those permissions are, and how
   --  many calls it may make.
   function Tool_Policy
     (Item : Stores.Store; Agent_Id : String; Max_Calls : Natural; Task_Id : String; Apart : Boolean;
      Hosted : Boolean := True)
      return String
   is
      Held : Agents.Agent;
      Read : E.Error_Info;
      Said : Unbounded_String := To_Unbounded_String ("tools: read_file, list_directory");
   begin
      Agents.Read (Item, Agent_Id, Held, Read);
      if E.Is_Error (Read) then
         return To_String (Said);
      end if;
      if Hosted and then Offers_Checks (Item, Held.Allowed, Task_Id, Apart) then
         Append (Said, ", run_checks");
      end if;
      if Permissions.Allows (Held.Allowed, Permissions.Write_Source)
        or else Permissions.Allows (Held.Allowed, Permissions.Write_Specs)
      then
         Append (Said, ", write_file");
      end if;
      if Hosted and then Permissions.Allows (Held.Allowed, Permissions.Create_Children)
        and then Held.Allowed (Permissions.Create_Children).Max_Children > 0
        and then Held.Depth + 1 <= Held.Allowed (Permissions.Create_Children).Max_Depth
      then
         Append (Said, ", delegate");
      end if;
      Append (Said, "; calls: " & (if Max_Calls = 0 then "bounded by steps"
                                   else Trim (Natural'Image (Max_Calls))));
      Append (Said, "; permissions: ");
      for Line of Lines_Of (Permissions.Image (Held.Allowed)) loop
         Append (Said, Line & "; ");
      end loop;
      return To_String (Said);
   end Tool_Policy;

   --  Every file's fingerprint, by path.
   function Snapshot
     (Project : String;
      Within  : Repository.Roots) return Configurations.Value_Maps.Map
   is
      Found  : constant Repository.Graph := Repository.Scan (Project, Within);
      Result : Configurations.Value_Maps.Map;
   begin
      for Index in 1 .. Repository.File_Count (Found) loop
         Result.Include
           (To_String (Repository.File_At (Found, Index).Path),
            To_String (Repository.File_At (Found, Index).Fingerprint));
      end loop;
      return Result;
   end Snapshot;

   --  Where the files an agent may not write are kept while it runs, to
   --  be put back should it write them anyway: runtime/kept-AGENT.
   function Kept_Directory (Item : Stores.Store; Agent : String) return String
   is (Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "kept-" & Agent));

   --  Keep a copy of each file an agent may not write, as far as a bound
   --  allows: a file over a megabyte, or past 64 megabytes in all, is not
   --  kept, and cannot be put back. A copy within the bound that cannot be
   --  made fails the keeping, and the agent is not started: it would run
   --  with a file it may not write and nothing to put back should it.
   procedure Keep_Originals
     (Item    : Stores.Store;
      Agent   : String;
      Place   : String;
      Present : Configurations.Value_Maps.Map;
      Allowed : Permissions.Permission_Set;
      Status  : out E.Error_Info)
   is
      Into  : constant String := Kept_Directory (Item, Agent);
      Total : Long_Long_Integer := 0;
   begin
      Status := E.Success;
      for Position in Present.Iterate loop
         declare
            Path : constant String := Configurations.Value_Maps.Key (Position);
            From : constant String := Hostkit.Fs.Join (Place, Path);
         begin
            if not Permissions.Allows (Allowed, Permissions.Write_Source, Path)
              and then not Permissions.Allows (Allowed, Permissions.Write_Specs, Path)
              and then Ada.Directories.Exists (From)
              and then Ada.Directories."=" (Ada.Directories.Kind (From), Ada.Directories.Ordinary_File)
              and then Long_Long_Integer (Ada.Directories.Size (From)) <= 1_048_576
              and then Total + Long_Long_Integer (Ada.Directories.Size (From)) <= 67_108_864
            then
               declare
                  Copy : constant String := Hostkit.Fs.Join (Into, Path);
               begin
                  Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Copy));
                  Ada.Directories.Copy_File (From, Copy);
                  Total := Total + Long_Long_Integer (Ada.Directories.Size (From));
               exception
                  when others =>
                     --  Gone in the meantime is nothing to keep.
                     if Ada.Directories.Exists (From) then
                        Files.Write_Failed (Copy, Status);
                        return;
                     end if;
               end;
            end if;
         exception
            when others =>
               --  Its size or kind could not be had: gone is nothing to
               --  keep, and anything else is a copy not made.
               if Ada.Directories.Exists (From) then
                  Files.Write_Failed (Hostkit.Fs.Join (Into, Path), Status);
                  return;
               end if;
         end;
      end loop;
   end Keep_Originals;

   --  Put a file an agent was not to write back as it was: its kept copy
   --  over it, or, when it was not there before, gone. Where it cannot be,
   --  Status says why -- no copy was kept (the file was over the bound), or
   --  what writing or removing it raised -- with the file as its path.
   procedure Put_Back
     (Item    : Stores.Store;
      Agent   : String;
      Place   : String;
      Path    : String;
      Existed : Boolean;
      Status  : out E.Error_Info)
   is
      Copy   : constant String := Hostkit.Fs.Join (Kept_Directory (Item, Agent), Path);
      Target : constant String := Hostkit.Fs.Join (Place, Path);
   begin
      Status := E.Success;
      if Existed then
         if not Ada.Directories.Exists (Copy) then
            Files.Write_Failed (Target, Status);
            E.Add_Text (Status, "detail", "no copy of it was kept to put back");
            return;
         end if;
         if not Ada.Directories.Exists (Ada.Directories.Containing_Directory (Target)) then
            Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Target));
         end if;
         Ada.Directories.Copy_File (Copy, Target);
      elsif Ada.Directories.Exists (Target) then
         Ada.Directories.Delete_File (Target);
      end if;
   exception
      when Failure : others =>
         Files.Write_Failed (Target, Status);
         E.Add_Text (Status, "detail", Ada.Exceptions.Exception_Name (Failure)
                     & (if Ada.Exceptions.Exception_Message (Failure) = "" then ""
                        else ": " & Ada.Exceptions.Exception_Message (Failure)));
   end Put_Back;

   --  What a child answers with.
   Child_Claim : constant Invocations.Contract :=
     Invocations.Contract_Of
       ("child_result",
        "status = done|failed" & ASCII.LF & "summary" & ASCII.LF
        & "findings?" & ASCII.LF & "changed_files?");

   -----------
   -- Audit --
   -----------

   --  The tasks an agent proposed working on a task, as they are now.
   function Proposals_Of (Item : Stores.Store; Task_Id : String) return String is
      Found : Unbounded_String;
   begin
      for Other of Tasks.List (Item) loop
         declare
            Defined : Records.Item;
            Read    : E.Error_Info;
         begin
            Tasks.Definition (Item, Other, Defined, Read);
            if E.Is_Ok (Read) and then Records.Get (Defined, "origin") = Task_Id
              and then Ada.Strings.Fixed.Index (Records.Get (Defined, "created_by"), "agent ") = 1
            then
               Append (Found, (if Found = Null_Unbounded_String then "" else ", ")
                       & Other & " " & Tasks.State_Of (Item, Other));
            end if;
         end;
      end loop;
      return To_String (Found);
   end Proposals_Of;

   --  An event's kind as words: Task_Became_Ready is "became ready".
   function Words_Of_Kind (Kind : String) return String is
      Lower : constant String :=
        Ada.Strings.Fixed.Translate (Ada.Characters.Handling.To_Lower (Kind), Ada.Strings.Maps.To_Mapping ("_", " "));
   begin
      return (if Lower'Length > 5 and then Lower (Lower'First .. Lower'First + 4) = "task "
              then Lower (Lower'First + 5 .. Lower'Last) else Lower);
   end Words_Of_Kind;

   function Audit (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector is separate;

   ------------------------
   -- Child_Instructions --
   ------------------------

   function Child_Instructions return String
   is ("## What to do" & ASCII.LF
       & "Do what you are asked, with the tools you have, and nothing more."
       & " Paths are relative to the project. Only a write_file call changes a"
       & " file, and only if you were asked to change one." & ASCII.LF & ASCII.LF
       & "When you are done, report in these lines:" & ASCII.LF & ASCII.LF
       & "status: done" & ASCII.LF
       & "summary: one line on what you found or did" & ASCII.LF
       & "findings: what you were asked for, in as many lines as it needs"
       & ASCII.LF & ASCII.LF
       & "If you could not do it, the status is failed and the summary says"
       & " why. Add changed_files: for any file you wrote." & ASCII.LF);

   -------------
   -- Current --
   -------------

   function Current (Host : Child_Host) return String
   is (if Host.Open.Is_Empty then "" else Host.Open.Last_Element);

   ------------------------
   -- Instructions_With --
   ------------------------

   --  What a task's root agent is told after its context, from what it may
   --  do: the tools it holds, how to answer, its permissions and its parts.
   --  The one text /work gives and /task context shows.
   function Instructions_With
     (Item    : Stores.Store;
      Task_Id : String;
      Allowed : Permissions.Permission_Set;
      Apart   : Boolean;
      Helpers : Boolean := True) return String
   is separate;

   -----------------------
   -- Instructions_Of --
   -----------------------

   function Instructions_Of (Item : Stores.Store; Task_Id : String) return String is
      Defined : Records.Item;
      Read    : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      return Instructions_With
        (Item, Task_Id,
         Permissions.Effective (Item, Records.Get (Defined, "kind"), "worker",
                                Task_Level => Records.Get (Defined, "permissions")),
         Apart => (if Tasks.Kind_Policy (Item, Records.Get (Defined, "kind"), "isolation") /= ""
                   then Tasks.Kind_Policy (Item, Records.Get (Defined, "kind"), "isolation")
                   else Work_Setting (Item, "isolation")) = "workspace");
   end Instructions_Of;

   ------------
   -- May_Do --
   ------------

   function May_Do (Item : Stores.Store; Task_Id : String) return String is
      Text  : constant String := Instructions_Of (Item, Task_Id);
      Lead  : constant String := "## What you may do" & ASCII.LF & "You may ";
      Start : constant Natural := Ada.Strings.Fixed.Index (Text, Lead);
   begin
      if Start = 0 then
         return "";
      end if;
      --  To the end of its sentence: a full stop a word ends with.
      for Index in Start + Lead'Length .. Text'Last loop
         if Text (Index) = '.' and then (Index = Text'Last or else Text (Index + 1) in ' ' | ASCII.LF) then
            return Text (Start + Lead'Length .. Index - 1);
         end if;
      end loop;
      return Text (Start + Lead'Length .. Text'Last);
   end May_Do;

   -------------------
   -- Unable_Reason --
   -------------------

   function Unable_Reason (Item : Stores.Store; Task_Id : String) return String is separate;

   -----------------------
   -- Keep_Before_Write --
   -----------------------

   procedure Keep_Before_Write
     (Host   : in out Child_Host;
      Path   : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Host.Item.all));
      From    : constant String := Hostkit.Fs.Join (Project, Path);
      To      : constant String := Hostkit.Fs.Join (Before_Copy (Host.Item.all, To_String (Host.Task_Id)), Path);
   begin
      Status := E.Success;
      if Host.Apart or else Host.Kept_Before.Contains (Path) then
         return;
      end if;
      --  The first copy is the one before any run wrote it: a later run's
      --  does not replace it.
      if Ada.Directories.Exists (From) and then not Ada.Directories.Exists (To)
        and then Ada.Directories."=" (Ada.Directories.Kind (From), Ada.Directories.Ordinary_File)
      then
         Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (To));
         Ada.Directories.Copy_File (From, To);
      end if;
      --  Noted once the copy is there, so a copy that failed is tried
      --  again before the next write rather than taken as made.
      Host.Kept_Before.Append (Path);
   exception
      when others =>
         --  Gone in the meantime is nothing to keep; anything else is a
         --  copy that is not there, and the write waits on it.
         if Ada.Directories.Exists (From) then
            Files.Write_Failed (To, Status);
         else
            Host.Kept_Before.Append (Path);
         end if;
   end Keep_Before_Write;

   ---------
   -- May --
   ---------

   function May
     (Host : Child_Host;
      What : Permissions.Capability;
      Path : String := "") return Boolean
   is
      Held   : Agents.Agent;
      Status : E.Error_Info;
   begin
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      return E.Is_Ok (Status) and then Permissions.Allows (Held.Allowed, What, Path)
        --  Children only where one could be made: room for one, a level
        --  below.
        and then (Permissions."/=" (What, Permissions.Create_Children)
                  or else (Held.Allowed (Permissions.Create_Children).Max_Children > 0
                           and then Held.Depth + 1
                                      <= Held.Allowed (Permissions.Create_Children).Max_Depth));
   end May;

   ------------------
   -- Where_Writes --
   ------------------

   function Where_Writes (Host : Child_Host) return String is
      Held   : Agents.Agent;
      Status : E.Error_Info;
      Said   : Unbounded_String;
   begin
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      if E.Is_Ok (Status) then
         for One in Permissions.Capability loop
            if Permissions."=" (One, Permissions.Write_Source) or else Permissions."=" (One, Permissions.Write_Specs)
            then
               --  Said as places, not as the grant is written: files under
               --  docs/ or README.md, sources anywhere.
               if Held.Allowed (One).Granted then
                  declare
                     Roots  : constant Name_Lists.Vector := Held.Allowed (One).Roots;
                     Places : Unbounded_String;
                  begin
                     for Root of Roots loop
                        Append (Places, (if Places = Null_Unbounded_String then "" else ", ") & Root);
                     end loop;
                     Append (Said, (if Said = Null_Unbounded_String then "" else "; ")
                             & (if Permissions."=" (One, Permissions.Write_Source) then "files" else "specifications")
                             & (if Roots.Is_Empty and then Permissions."=" (One, Permissions.Write_Specs)
                                then " in " & Permissions.Specification_Places
                                elsif Roots.Is_Empty then " anywhere in the project"
                                else " under " & To_String (Places))
                             & (if Held.Allowed (One).Deny.Is_Empty then ""
                                else ", not " & Comma_Separated (Held.Allowed (One).Deny)));
                  end;
               end if;
            end if;
         end loop;
      end if;
      return (if Said = Null_Unbounded_String then "nowhere: this task is answered, not written"
              else To_String (Said));
   end Where_Writes;

   ---------------
   -- Time_Left --
   ---------------

   function Time_Is_Up (Host : Child_Host) return Boolean is
      use type Ada.Calendar.Time;
   begin
      return Host.Bounded and then Ada.Calendar.Clock >= Host.Deadline;
   end Time_Is_Up;

   function Time_Left (Host : Child_Host) return Duration is
      use type Ada.Calendar.Time;
   begin
      if not Host.Bounded then
         return 0.0;
      end if;
      return Duration'Max (1.0, Host.Deadline - Ada.Calendar.Clock);
   end Time_Left;

   -----------------
   -- Tool_Budget --
   -----------------

   function Tool_Budget (Host : Child_Host) return Natural is (Host.Max_Calls);

   ------------------
   -- Token_Budget --
   ------------------

   function Token_Budget (Host : Child_Host) return Positive is
      Held   : Agents.Agent;
      Status : E.Error_Info;
   begin
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      return (if E.Is_Error (Status) or else Held.Used >= Held.Budget then 1
              else Held.Budget - Held.Used);
   end Token_Budget;

   -----------
   -- Steps --
   -----------

   function Steps (Host : Child_Host) return Positive
   is (Positive'Max (1, Host.Max_Steps));

   ------------------
   -- Task_Profile --
   ------------------

   function Task_Profile (Host : Child_Host) return String
   is (Verification.Profile_Of (Host.Item.all, To_String (Host.Task_Id)));

   ---------------
   -- May_Check --
   ---------------

   function May_Check (Host : Child_Host; Profile : String) return Boolean is
      Held   : Agents.Agent;
      Status : E.Error_Info;
      Needed : constant Permissions.Capability := Check_Capability (Host.Item.all, Profile);
   begin
      if Host.Apart or else Profile = "" then
         return False;
      end if;
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      return E.Is_Ok (Status)
        and then Permissions.Allows_Profile (Held.Allowed, Needed, Profile);
   end May_Check;

   ----------------
   -- Run_Checks --
   ----------------

   procedure Run_Checks
     (Host    : in out Child_Host;
      Profile : String;
      Report  : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info)
   is separate;

   ------------------
   -- Usage_Beside --
   ------------------

   function Usage_Beside (Prompt_Path : String) return String
   is (Prompt_Path & ".usage");

   ------------------
   -- Time_Allowed --
   ------------------

   function Steps_Allowed (Item : Stores.Store; Task_Id : String) return Positive is
      Kind : constant String := Kind_Of_Task (Item, Task_Id);
   begin
      return Positive'Max
        (1, Number_Of ((if Tasks.Kind_Policy (Item, Kind, "max_steps") /= ""
                        then Tasks.Kind_Policy (Item, Kind, "max_steps")
                        else Scalar (Item, "agents.max_steps")), 24));
   end Steps_Allowed;

   function Time_Allowed (Item : Stores.Store; Task_Id : String) return Natural is
      Defined : Records.Item;
      Read    : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      declare
         Kind : constant String := Records.Get (Defined, "kind");
      begin
         return Number_Of
           ((if Tasks.Kind_Policy (Item, Kind, "max_seconds") /= ""
             then Tasks.Kind_Policy (Item, Kind, "max_seconds")
             else Scalar (Item, "agents.max_seconds")),
            Lease_Seconds (Item));
      end;
   end Time_Allowed;

   -----------
   -- Spend --
   -----------

   procedure Spend
     (Host          : in out Child_Host;
      Tokens        : Natural;
      Prompt_Tokens : Natural := 0)
   is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      --  What it used is recorded; going over is the loop's to stop, and the
      --  record says so.
      Agents.Charge (Host.Item.all, Change, Current (Host), Tokens, Status);
      if Natural (Host.Open.Length) = 1 and then E."=" (Status.Code, E.Framework_Limit_Exceeded) then
         Host.Root_Over := True;
         Status := E.Success;
      end if;
      Stores.Commit (Host.Item.all, Change, Status);
      if Natural (Host.Open.Length) = 1 then
         Host.Root_Out := Host.Root_Out + Tokens;
         Host.Root_Prompt := Natural'Max (Host.Root_Prompt, Prompt_Tokens);
      end if;
   end Spend;

   ---------------
   -- Note_Call --
   ---------------

   procedure Note_Call
     (Host      : in out Child_Host;
      Named     : String;
      Arguments : String;
      Answer    : String)
   is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      if not Host.Calls.Is_Empty then
         Invocations.Note_Call
           (Host.Item.all, Change, Host.Calls.Last_Element, Named, Arguments, Answer, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
      end if;
   end Note_Call;

   ----------------
   -- Open_Child --
   ----------------

   procedure Open_Child
     (Host     : in out Child_Host;
      Role     : String;
      Need     : String;
      Brief    : String;
      Retry_Of : String;
      Child_Id : out Ada.Strings.Unbounded.Unbounded_String;
      Context  : out Ada.Strings.Unbounded.Unbounded_String;
      Budget   : out Natural;
      Status   : out Model_Runner.Errors.Error_Info)
   is separate;

   -----------------
   -- Close_Child --
   -----------------

   procedure Close_Child
     (Host   : in out Child_Host;
      Answer : String;
      Tokens : Natural;
      Ran    : Model_Runner.Errors.Error_Info;
      Told   : out Ada.Strings.Unbounded.Unbounded_String;
      Retry  : out Boolean;
      Prompt_Tokens : Natural := 0)
   is separate;

   --  Children still open when their parent stopped: each is recorded
   --  failed, so none of them goes missing.
   procedure Abandon (Host : in out Child_Host) is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      while Natural (Host.Open.Length) > 1 loop
         Agents.Finish
           (Host.Item.all, Change, Host.Open.Last_Element, False, "",
            "its parent stopped before it answered", Status);
         if Host.Calls.Last_Element /= "" then
            Invocations.Finish
              (Host.Item.all, Change, Host.Calls.Last_Element, Invocations.Failed,
               (others => 0), "", "its parent stopped before it answered", Status);
         end if;
         Host.Open.Delete_Last;
         Host.Calls.Delete_Last;
         Host.Opened.Delete_Last;
      end loop;
      Stores.Commit (Host.Item.all, Change, Status);
   end Abandon;

   -------------
   -- Execute --
   -------------

   --  The work itself; Execute holds it to ending the task it started.
   procedure Execute_Work
     (Item     : aliased in out Stores.Store;
      Task_Id  : String;
      Runner   : Agent_Runner'Class;
      Model    : Context.Model_Profile;
      Result   : out Report;
      Status   : out Model_Runner.Errors.Error_Info;
      Starting : access procedure (Agent_Id, Manifest_Id, Invocation_Id : String) := null)
   is separate;

   -------------
   -- Execute --
   -------------

   procedure Execute
     (Item     : aliased in out Stores.Store;
      Task_Id  : String;
      Runner   : Agent_Runner'Class;
      Model    : Context.Model_Profile;
      Result   : out Report;
      Status   : out Model_Runner.Errors.Error_Info;
      Starting : access procedure (Agent_Id, Manifest_Id, Invocation_Id : String) := null) is
   begin
      Execute_Work (Item, Task_Id, Runner, Model, Result, Status, Starting);
      Execution.Watch_Lease (null);

      --  Whatever way the work ended, a task it started is not left running
      --  with nobody working it: set aside, with why, its agent ended and
      --  what it held let go -- every path, including those no one wrote a
      --  conclusion for.
      declare
         Agent : constant String := To_String (Result.Agent_Id);
      begin
         if Agent /= "" and then Tasks.State_Of (Item, Task_Id) = "running"
           and then Leases.Holder (Item, Lease_Of (Task_Id)) = Agent
         then
            declare
               Change : Stores.Transaction;
               Moved  : E.Error_Info;
               Why    : constant String :=
                 "its work stopped: "
                 & (if E.Is_Error (Status) then Why_Of (Status) else "it ended with no outcome");
               Holds  : Name_Lists.Vector;
            begin
               Tasks.Move (Item, Change, Task_Id, "blocked", Why, Status => Moved);
               Agent_State (Item, Change, Agent, "failed", Why);
               Holds.Append (Lease_Of (Task_Id));
               Holds.Append (Tasks.Project_Lease);
               if Component_Of (Item, Task_Id) /= "" then
                  Holds.Append (Tasks.Component_Lease (Component_Of (Item, Task_Id)));
               end if;
               for Held of Holds loop
                  if E.Is_Ok (Moved) and then Leases.Holder (Item, Held) = Agent then
                     Leases.Release (Item, Change, Held, Agent, Moved);
                  end if;
               end loop;
               if E.Is_Ok (Moved) then
                  Stores.Commit (Item, Change, Moved);
               end if;
               Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
               Result.Reason := To_Unbounded_String (Why);
            end;
         end if;
      end;
   end Execute;

   -------------
   -- Take_In --
   -------------

   procedure Take_In
     (Item    : in out Stores.Store;
      Task_Id : String;
      Result  : out Report;
      Status  : out Model_Runner.Errors.Error_Info;
      Semantic_Accepted : Boolean := False;
      Text_Resolved     : Boolean := False;
      Replaced_Kept     : String := "")
   is separate;

   ------------
   -- Cancel --
   ------------

   procedure Cancel
     (Item    : in out Stores.Store;
      Task_Id : String;
      Status  : out Model_Runner.Errors.Error_Info;
      Actor   : String := "")
   is
      Change : Stores.Transaction;
      Agent  : constant String := Holder_Record (Item, Task_Id);
   begin
      Tasks.Move (Item, Change, Task_Id, "cancelled", "", Status => Status, Actor => Actor);
      if E.Is_Error (Status) then
         return;
      end if;
      --  The move lets go of what a live agent held and abandons its
      --  workspace; its agent and children are stopped here, and holds a
      --  gone process left are let go of too.
      if Agent /= "" then
         Stop_Children (Item, Change, Agent, "the task was cancelled");
         Agent_State (Item, Change, Agent, "cancelled", "the task was cancelled");
         if Leases.Holder (Item, Lease_Of (Task_Id)) = "" then
            Leases.Release (Item, Change, Lease_Of (Task_Id), Agent, Status);
            if E.Is_Ok (Status) and then Component_Of (Item, Task_Id) /= "" then
               Leases.Release
                 (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)), Agent,
                  Status);
            end if;
            if E.Is_Ok (Status) then
               Leases.Release (Item, Change, Tasks.Project_Lease, Agent, Status);
            end if;
         end if;
         if Status.Code = E.Framework_Lease_Held then
            Status := E.Success;
         end if;
      end if;
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
   end Cancel;

end Model_Runner.Framework.Work;
