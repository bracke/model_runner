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
   begin
      Annotate (Item, Change, Task_Id, "undone_by", Copy);
      Stores.Commit (Item, Change, Status);
   end Note_Undone;

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
   is
      Change : Stores.Transaction;
   begin
      Recovered.Clear;
      Status := E.Success;
      for Id of Tasks.List (Item, "running") loop
         if Leases.Holder (Item, Lease_Of (Id)) = "" then
            declare
               Agent : constant String := Holder_Record (Item, Id);
               Space : constant String := Workspaces.Active_For (Item, Id);

               --  Where it worked apart, the workspace is given up as an
               --  interrupt gives it up -- a retry starts afresh -- with
               --  what it had changed there named.
               --  Where it worked in the project itself: the files that
               --  differ from what they were when it started, left there.
               function Left_In_Project return String is
                  Mark   : constant String := Before_File (Item, Id);
                  Was    : Unbounded_String;
                  Read   : E.Error_Info;
                  Then_Map : Configurations.Value_Maps.Map;
                  Named  : Unbounded_String;
                  Lines  : Unbounded_String;
               begin
                  if not Ada.Directories.Exists (Mark) then
                     return "";
                  end if;
                  Files.Read_Text (Mark, Was, Read);
                  Files.Discard (Mark);
                  if E.Is_Error (Read) then
                     return "";
                  end if;
                  for Line of Lines_Of (To_String (Was)) loop
                     declare
                        Tab : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                     begin
                        if Tab > Line'First then
                           Then_Map.Include (Line (Line'First .. Tab - 1), Line (Tab + 1 .. Line'Last));
                        end if;
                     end;
                  end loop;
                  declare
                     Now : constant Configurations.Value_Maps.Map :=
                       Snapshot (Ada.Directories.Containing_Directory (Stores.Root (Item)),
                                 Repository.Roots_Of (Item));
                  begin
                     for Position in Now.Iterate loop
                        declare
                           Path : constant String := Configurations.Value_Maps.Key (Position);
                        begin
                           if not Then_Map.Contains (Path)
                             or else Then_Map (Path) /= Configurations.Value_Maps.Element (Position)
                           then
                              Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                                      & Path);
                              Append (Lines, Path & ASCII.LF);
                           end if;
                        end;
                     end loop;
                     for Position in Then_Map.Iterate loop
                        if not Now.Contains (Configurations.Value_Maps.Key (Position)) then
                           Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                                   & Configurations.Value_Maps.Key (Position) & " (removed)");
                           Append (Lines, Configurations.Value_Maps.Key (Position) & ASCII.LF);
                        end if;
                     end loop;
                  end;
                  if Named = Null_Unbounded_String then
                     return "";
                  end if;
                  Annotate (Item, Change, Id, "changed_files", To_String (Lines));
                  return Left_Words (Item, To_String (Named), Id);
               end Left_In_Project;

               function Given_Up return String is
                  Named : Unbounded_String;
                  Lines : Unbounded_String;
                  Held  : E.Error_Info;
               begin
                  if Space = "" then
                     return Left_In_Project;
                  end if;
                  for Path of Workspaces.Changes (Item, Space) loop
                     Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & Path);
                     Append (Lines, Path & ASCII.LF);
                  end loop;
                  --  Kept on the task as a run's are, so its audit says them.
                  if Lines /= Null_Unbounded_String then
                     Annotate (Item, Change, Id, "changed_files", To_String (Lines));
                  end if;
                  Workspaces.Abandon (Item, Change, Space, Held);
                  return (if E.Is_Error (Held) then ""
                          else "; its workspace " & Space & " is given up"
                               & (if Named = Null_Unbounded_String then ""
                                  else ", what it changed there kept in "
                                       & Ada.Directories.Simple_Name (Workspaces.Kept_Copy (Item, Space))
                                       & ": " & To_String (Named)));
               end Given_Up;
            begin
               Tasks.Move
                 (Item, Change, Id, "blocked",
                  "its agent " & (if Agent = "" then "" else Agent & " ")
                  & "stopped without finishing" & Given_Up, Status => Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               if Agent /= "" then
                  Stop_Children (Item, Change, Agent, "its parent stopped without finishing");
                  Agent_State (Item, Change, Agent, "failed", "its agent stopped without finishing",
                               Outcome => "blocked");
               end if;
               Leases.Release (Item, Change, Lease_Of (Id), Agent, Status);
               if E.Is_Ok (Status) and then Component_Of (Item, Id) /= "" then
                  Leases.Release
                    (Item, Change, Tasks.Component_Lease (Component_Of (Item, Id)), Agent, Status);
               end if;
               if E.Is_Ok (Status) and then Leases.Holder (Item, Tasks.Project_Lease) = Agent then
                  Leases.Release (Item, Change, Tasks.Project_Lease, Agent, Status);
               end if;

               --  Blocked, unless the project says otherwise.
               if E.Is_Ok (Status) and then Scalar (Item, "recovery.running") = "failed" then
                  Tasks.Move (Item, Change, Id, "failed", "its agent stopped without finishing",
                              Status => Status);
               elsif E.Is_Ok (Status) and then Scalar (Item, "recovery.running") = "accepted" then
                  Tasks.Move (Item, Change, Id, "accepted", "", Status => Status);
               end if;
               if E.Is_Error (Status) then
                  return;
               end if;
               Recovered.Append (Id);
            end;
         end if;
      end loop;

      --  A task left in verification with nothing to wait for -- no work
      --  written apart waiting to be taken in -- was being verified when
      --  the harness stopped: blocked, saying so, its leases let go.
      for Id of Tasks.List (Item, "verification") loop
         if Workspaces.Active_For (Item, Id) = ""
           and then Leases.Holder (Item, Lease_Of (Id)) = ""
         then
            Tasks.Move (Item, Change, Id, "blocked",
                        "its verification stopped without finishing", Status => Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Leases.Release (Item, Change, Lease_Of (Id), Holder_Record (Item, Id), Status);
            Status := E.Success;
            Recovered.Append (Id);
         end if;
      end loop;
      Stores.Commit (Item, Change, Status);
   end Recover;

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
   is
      Change : Stores.Transaction;
      Became : Name_Lists.Vector;
      Moved  : Name_Lists.Vector;
      Was    : Configurations.Value_Maps.Map;
   begin
      Said.Clear;
      for Id of Intent.List (Item, Intent.Requirement) loop
         Was.Include (Id, Intent.State_Of (Item, Intent.Requirement, Id));
      end loop;
      Tasks.Recompute_Readiness (Item, Change, Became, Status);
      if E.Is_Ok (Status) then
         Verification.Reevaluate_Requirements (Item, Change, Moved, Status);
      end if;
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      --  Only a state that changed is said, with from and to, and what
      --  judges it again.
      for Id of Moved loop
         if not Was.Contains (Id) or else Was (Id) /= Intent.State_Of (Item, Intent.Requirement, Id)
         then
            declare
               Now    : constant String := Intent.State_Of (Item, Intent.Requirement, Id);
               Before : constant String := (if Was.Contains (Id) then Configurations.Value_Maps.Element (Was, Id)
                                            else "");
               function Rank (State : String) return Natural
               is (if State = "verified" then 3 elsif State = "implemented" then 2
                   elsif State = "accepted" then 1 else 0);
            begin
               --  Said as the way it went: back, because what verified it
               --  no longer covers it; or on, because now something does.
               if Before /= "" and then Rank (Now) < Rank (Before) then
                  Said.Append (Id & " drops back from " & Before & " to " & Now
                               & ": what verified it no longer covers it as it stands -- it or its code"
                               & " changed; /check " & Id & " judges it again");
               else
                  Said.Append (Id & " is " & Now & " now" & (if Before = "" then "" else ", from " & Before)
                               & ": what it is judged by covers it as it stands");
               end if;
            end;
         end if;
      end loop;
   end Reevaluate;

   ------------------------
   -- Recover_On_Opening --
   ------------------------

   procedure Recover_On_Opening
     (Item   : in out Stores.Store;
      Opened : Stores.Recovery_Report;
      Said   : out Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Change   : Stores.Transaction;
      Put_Back : Name_Lists.Vector;

      --  The root of an agent: itself, or the first of its ancestors with no
      --  parent.
      function Root_Of (Id : String) return String is
         Held : Agents.Agent;
         Read : E.Error_Info;
      begin
         Agents.Read (Item, Id, Held, Read);
         return (if E.Is_Error (Read) or else Held.Parent = Null_Unbounded_String then Id
                 else Root_Of (To_String (Held.Parent)));
      end Root_Of;

      --  Whether something is running an agent: its root holds its task.
      function Live (Id : String) return Boolean is
         Held : Agents.Agent;
         Read : E.Error_Info;
      begin
         Agents.Read (Item, Id, Held, Read);
         return E.Is_Ok (Read)
           and then Leases.Holder (Item, Lease_Of (To_String (Held.Task_Id))) = Root_Of (Id);
      end Live;
   begin
      Said.Clear;

      --  0: the configuration, which everything after reads, put right from
      --  its history where it cannot be read.
      declare
         Restored : Natural;
         Kept     : E.Error_Info;
      begin
         Configurations.Recover (Item, Restored, Kept);
         if Restored > 0 then
            Said.Append ("the configuration could not be read and was put back from its history,"
                         & " revision" & Natural'Image (Restored));
         end if;
      end;

      --  1, 2 and 6: what opening the store did.
      if Opened.Rolled_Forward > 0 then
         Said.Append ("finished" & Natural'Image (Opened.Rolled_Forward)
                      & " committed changes an interruption had left");
      end if;
      if Opened.Rolled_Back > 0 then
         Said.Append ("threw away" & Natural'Image (Opened.Rolled_Back)
                      & " changes interrupted before they were committed");
      end if;
      if Opened.Partials_Removed > 0 then
         Said.Append ("removed" & Natural'Image (Opened.Partials_Removed)
                      & " half-written files");
      end if;
      if Opened.Index_Rebuilt then
         Said.Append ("built the entity index again");
      end if;

      --  3: what a killed run left running is stopped, and the tasks it
      --  left running with no one running them put back.
      declare
         Stopped : Name_Lists.Vector;
      begin
         Execution.Stop_Left_Groups (Item, Stopped);
         Said.Append (Stopped);
      end;
      Recover (Item, Put_Back, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      for Id of Put_Back loop
         declare
            Held   : Records.Item;
            Read   : E.Error_Info;
            Reason : Unbounded_String;
         begin
            --  A workspace given up with it is said with it.
            Stores.Read (Item, Tasks_Area, Id & ".state", Held, Read);
            if E.Is_Ok (Read) then
               Reason := To_Unbounded_String (Records.Get (Held, "blocking_reasons"));
            end if;
            Said.Append (Id & " was running with no one running it; it is "
                         & Tasks.State_Of (Item, Id) & " now"
                         & (if Index (Reason, "; its workspace") > 0
                            then Slice (Reason, Index (Reason, "; its workspace"), Length (Reason))
                            elsif Index (Reason, "; what it changed is still") > 0
                            then Slice (Reason, Index (Reason, "; what it changed is still"),
                                        Length (Reason))
                            else ""));
         end;
      end loop;

      --  4: agents and invocations no one is running any more.
      for Name of Stores.Names (Item, Runtime_Area) loop
         if Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "agent." then
            declare
               Id   : constant String := Name (Name'First + 6 .. Name'Last);
               Held : Agents.Agent;
               Read : E.Error_Info;
            begin
               Agents.Read (Item, Id, Held, Read);
               if E.Is_Ok (Read)
                 and then To_String (Held.Status) in "created" | "running" | "waiting"
                 and then not Live (Id)
               then
                  Agents.Finish (Item, Change, Id, False, "",
                                 "abandoned: nothing was running it", Read);
                  if E.Is_Ok (Read) then
                     Said.Append (Id & " was abandoned");
                  end if;
               end if;
            end;
         end if;
      end loop;
      for Name of Stores.Names (Item, Invocations_Area) loop
         if Name'Length > 4 and then Name (Name'First .. Name'First + 3) = "INV-"
           and then Invocations.State_Of (Item, Name) = "started"
         then
            declare
               Value : Records.Item;
               Read  : E.Error_Info;
            begin
               Stores.Read (Item, Invocations_Area, Name, Value, Read);
               if E.Is_Ok (Read) and then not Live (Records.Get (Value, "agent")) then
                  Invocations.Finish
                    (Item, Change, Name, Invocations.Failed, (others => 0), "",
                     "abandoned: nothing was running it", Read);
                  if E.Is_Ok (Read) then
                     Said.Append (Name & " was abandoned");
                  end if;
               end if;
            end;
         end if;
      end loop;

      --  5: workspaces, against their directories and their tasks.
      declare
         Home : constant String :=
           Hostkit.Fs.Join (Stores.Root (Item), "workspaces");
         Recorded : Name_Lists.Vector;
      begin
         for Name of Stores.Names (Item, Workspaces_Area) loop
            declare
               Held  : Workspaces.Workspace;
               Read  : E.Error_Info;
            begin
               Workspaces.Read (Item, Name, Held, Read);
               Recorded.Append (To_String (Held.Id));
               if E.Is_Ok (Read) and then To_String (Held.Status) = "active" then
                  declare
                     Now : constant String := Tasks.State_Of (Item, To_String (Held.Task_Id));
                  begin
                     if not Ada.Directories.Exists (To_String (Held.Path)) then
                        Workspaces.Abandon (Item, Change, To_String (Held.Id), Read);
                        Said.Append (To_String (Held.Id) & ": its directory is gone; abandoned");
                     elsif Now in "complete" | "cancelled" | "failed" then
                        Workspaces.Abandon (Item, Change, To_String (Held.Id), Read);
                        Said.Append (To_String (Held.Id) & ": its task is " & Now
                                     & "; abandoned");
                     end if;
                  end;
               end if;
            end;
         end loop;
         if Ada.Directories.Exists (Home) then
            declare
               use Ada.Directories;
               Search : Search_Type;
               Found  : Directory_Entry_Type;
            begin
               Start_Search (Search, Home, "WS-*", [Directory => True, others => False]);
               while More_Entries (Search) loop
                  Get_Next_Entry (Search, Found);
                  if not Recorded.Contains (Simple_Name (Found)) then
                     Said.Append ("workspaces/" & Simple_Name (Found)
                                  & " has no record; it is left for you to remove");
                  end if;
               end loop;
               End_Search (Search);
            end;
         end if;
      end;

      Stores.Commit (Item, Change, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  7: readiness and verification, as the state now stands.
      declare
         Moved : Name_Lists.Vector;
      begin
         Reevaluate (Item, Moved, Status);
         Said.Append (Moved);
      end;

      --  What of the state goes into the repository, as the policy says.
      declare
         Written : Boolean;
         Kept    : E.Error_Info;
      begin
         Git.Keep_Policy (Item, Written, Kept);
         if Written then
            Said.Append ("wrote the state's .gitignore for its repository policy");
         end if;
      end;

      --  Results the project keeps only for a while, let go of.
      declare
         Removed : Natural;
      begin
         Results.Prune
           (Item, Change,
            Raw_Log_Days => Number_Of (Scalar (Item, "retention.raw_log_days"), 0),
            Context_Days => Number_Of (Scalar (Item, "retention.context_days"), 0),
            Removed      => Removed,
            Cache_Days   => Number_Of (Scalar (Item, "retention.cache_days"), 0));
         if Removed > 0 then
            Stores.Commit (Item, Change, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Said.Append ("let go of" & Natural'Image (Removed)
                         & " raw logs and kept contexts past their retention");
         end if;

         --  And the payloads kept apart that nothing refers to now.
         declare
            Collected : Natural;
         begin
            Results.Collect_Payloads (Item, Collected);
         end;
      end;

      --  6: the repository's graph, brought up to date and kept, so what
      --  reads it next reads only what changed since; and the indexes
      --  built again where they are missing or stale.
      declare
         Graph  : Repository.Graph;
         Kept   : E.Error_Info;
         Change : Stores.Transaction;
      begin
         Repository.Current (Item, Graph, Kept);
         if not Indexes.Current (Item, Graph) then
            Indexes.Build (Item, Change, Graph, Kept);
            if E.Is_Ok (Kept) then
               Stores.Commit (Item, Change, Kept);
            end if;
         end if;
      end;

      --  7: the events nothing has acted on yet -- a session that stopped
      --  between an event and what it calls for -- acted on now.
      declare
         Done : Orchestration.Step_Report;
         Ran  : E.Error_Info;
      begin
         --  Routine, and not said as such: only what it made -- a task a
         --  requirement implies -- and what it could not do.
         Orchestration.Step (Item, Done, Ran);
         for Id of Done.Derived loop
            Said.Append ("derived " & Id & " from an accepted requirement");
         end loop;
         if E.Is_Error (Ran) then
            Said.Append ("the rules could not all be acted on: " & Why_Of (Ran));
         end if;
      end;

      --  8: leases run out are let go of, once, and said.
      declare
         Change  : Stores.Transaction;
         Cleared : Name_Lists.Vector;
         Kept    : E.Error_Info;
      begin
         Leases.Clear_Stale (Item, Change, Cleared);
         Stores.Commit (Item, Change, Kept);
         if E.Is_Ok (Kept) then
            for Resource of Cleared loop
               Said.Append (Resource & ": its lease had run out, and is let go of");
            end loop;
         end if;
      end;

      --  9: what is still wrong, for someone to settle.
      declare
         Wrong : constant Consistency.Finding_List := Consistency.Check (Item);

         --  Said once: the same findings as last time are not said again.
         Mark    : constant String :=
           Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "consistency.said");
         Summary : Unbounded_String;
         Before  : Unbounded_String;
         Read    : E.Error_Info;
         Kept    : E.Error_Info;
      begin
         for Index in 1 .. Consistency.Length (Wrong) loop
            Append (Summary, To_String (Consistency.Element (Wrong, Index).Subject) & " "
                    & To_String (Consistency.Element (Wrong, Index).Detail) & ASCII.LF);
         end loop;
         if Ada.Directories.Exists (Mark) then
            Files.Read_Text (Mark, Before, Read);
         end if;
         if Before /= Summary then
            Files.Write_Text (Mark, To_String (Summary), Kept);
         end if;
         if Consistency.Length (Wrong) > 0 and then Before /= Summary then
            Said.Append
              ("what does not hold together in the state:"
               & Natural'Image (Consistency.Length (Wrong)) & ", first "
               & To_String (Consistency.Element (Wrong, 1).Subject) & ": "
               & To_String (Consistency.Element (Wrong, 1).Detail)
               & "; /check consistency lists it all");
         end if;
      end;
   end Recover_On_Opening;

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
   --  kept, and cannot be put back.
   procedure Keep_Originals
     (Item    : Stores.Store;
      Agent   : String;
      Place   : String;
      Present : Configurations.Value_Maps.Map;
      Allowed : Permissions.Permission_Set)
   is
      Into  : constant String := Kept_Directory (Item, Agent);
      Total : Long_Long_Integer := 0;
   begin
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
               end;
            end if;
         exception
            when others =>
               null;
         end;
      end loop;
   end Keep_Originals;

   --  Put a file an agent was not to write back as it was: its kept copy
   --  over it, or, when it was not there before, gone.
   function Put_Back
     (Item    : Stores.Store;
      Agent   : String;
      Place   : String;
      Path    : String;
      Existed : Boolean) return Boolean
   is
      Copy   : constant String := Hostkit.Fs.Join (Kept_Directory (Item, Agent), Path);
      Target : constant String := Hostkit.Fs.Join (Place, Path);
   begin
      if Existed then
         if not Ada.Directories.Exists (Copy) then
            return False;
         end if;
         if not Ada.Directories.Exists (Ada.Directories.Containing_Directory (Target)) then
            Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Target));
         end if;
         Ada.Directories.Copy_File (Copy, Target);
         return True;
      else
         if Ada.Directories.Exists (Target) then
            Ada.Directories.Delete_File (Target);
         end if;
         return True;
      end if;
   exception
      when others =>
         return False;
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

   function Audit (Item : Stores.Store; Task_Id : String) return Name_Lists.Vector is
      Result  : Name_Lists.Vector;
      Defined : Records.Item;
      State   : Records.Item;
      Call    : Records.Item;
      Plan    : Records.Item;
      Proof   : Records.Item;
      Status  : E.Error_Info;

      procedure Say (Question, Answer : String) is
      begin
         Result.Append (Question & ": " & (if Answer = "" then "(nothing recorded)" else Answer));
      end Say;

      --  The fields of a record whose names start with a prefix, as
      --  NAME VALUE, joined; the name without so much of it as Kept says
      --  not to keep.
      function Fields_With
        (Value : Records.Item; Prefix : String; Kept : Natural := 0) return String
      is
         Text : Unbounded_String;
      begin
         for Index in 1 .. Records.Field_Count (Value) loop
            declare
               Field : constant String := Records.Field_Name (Value, Index);
            begin
               if Field'Length > Prefix'Length
                 and then Field (Field'First .. Field'First + Prefix'Length - 1) = Prefix
               then
                  Append (Text, (if Text = Null_Unbounded_String then "" else ", ")
                          & Field (Field'First + Prefix'Length - Kept .. Field'Last) & " "
                          & Records.Get (Value, Field));
               end if;
            end;
         end loop;
         return To_String (Text);
      end Fields_With;

      --  The last invocation made for the task.
      function Last_Call return String is
         Found : Unbounded_String;
      begin
         for Name of Stores.Names (Item, Invocations_Area) loop
            if Name'Length > 4 and then Name (Name'First .. Name'First + 3) = "INV-" then
               declare
                  Value : Records.Item;
                  Read  : E.Error_Info;
               begin
                  Stores.Read (Item, Invocations_Area, Name, Value, Read);
                  if E.Is_Ok (Read) and then Records.Get (Value, "task") = Task_Id
                    and then Records.Get (Value, "result_contract") = "work_claim"
                  then
                     Found := To_Unbounded_String (Name);
                  end if;
               end;
            end if;
         end loop;
         return To_String (Found);
      end Last_Call;

      Invocation : constant String := Last_Call;

      --  What became of a workspace: taken in, given up, or still there.
      function Workspace_Status (Id : String) return String is
         Held : Workspaces.Workspace;
         Read : E.Error_Info;
      begin
         Workspaces.Read (Item, Id, Held, Read);
         return (if E.Is_Ok (Read) then To_String (Held.Status) else "");
      end Workspace_Status;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Status);
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Status);
      if Invocation /= "" then
         Stores.Read (Item, Invocations_Area, Invocation, Call, Status);
         Stores.Read (Item, Invocations_Area, "manifest." & Records.Get (Call, "context_manifest"),
                      Plan, Status);
      end if;
      if Records.Get (State, "current_verification") /= "" then
         Stores.Read (Item, Verification_Area, Records.Get (State, "current_verification"),
                      Proof, Status);
      end if;

      --  The revisions its context read, or, never worked, the one it was
      --  made from.
      if Invocation = "" then
         --  Never worked: where it came from, and that, on lines of their own.
         if Records.Get (Defined, "origin") /= "" then
            Say ("made from", Records.Get (Defined, "origin"));
         end if;
         Say ("worked", "never");
      else
         Say ("requirement revisions", Fields_With (Plan, "applies.REQ", Kept => 3));
      end if;
      Say ("task definition revision", Trim (Natural'Image (Records.Revision (Defined))));
      Say ("why it could start", Records.Get (State, "admission"));
      Say ("decisions", Fields_With (Plan, "applies.DEC", Kept => 3));
      Say ("context", Records.Get (Call, "context_manifest")
           & (if Records.Get (Plan, "rendered") = "" then ""
              else ", rendered as " & Records.Get (Plan, "rendered")));
      Say ("agent", (if Records.Get (State, "runner") /= "" then Records.Get (State, "runner")
                     else Records.Get (Call, "model_profile"))
           & (if Invocation = "" then "" else ", in " & Invocation));
      Say ("answer", Records.Get (Call, "result"));
      Say ("issues", Records.Get (State, "issues"));

      --  Where it came from: a part names its parent and who split it.
      if Records.Get (Defined, "parent") /= "" then
         Say ("part of", Records.Get (Defined, "parent")
              & (if Records.Get (Defined, "created_by") = "" then ""
                 else ", split by " & Records.Get (Defined, "created_by")));
      elsif Records.Get (Defined, "created_by") /= "" then
         Say ("made by", Records.Get (Defined, "created_by")
              & (if Records.Get (Defined, "origin") = "" then ""
                 else ", from " & Records.Get (Defined, "origin")));
      end if;

      --  Every attempt, and every agent that worked for it: those a root
      --  agent started with delegate among them, and how each ended.
      declare
         Attempts : Unbounded_String;
         Workers  : Unbounded_String;
      begin
         for Name of Stores.Names (Item, Runtime_Area) loop
            declare
               Value : Records.Item;
               Read  : E.Error_Info;
            begin
               if Name'Length > 6 and then Name (Name'First .. Name'First + 5) = "agent." then
                  Stores.Read (Item, Runtime_Area, Name, Value, Read);
               else
                  Read := E.Make (E.Framework_Not_Found);
               end if;
               if E.Is_Ok (Read) and then Records.Get (Value, "task") = Task_Id then
                  Append (Workers, (if Workers = Null_Unbounded_String then "" else ", ")
                          & Name (Name'First + 6 .. Name'Last) & " " & Records.Get (Value, "state")
                          & (if Records.Get (Value, "parent") = "" then ""
                             else " (a child of " & Records.Get (Value, "parent")
                                  & (if Records.Get (Value, "retry_of") = "" then ""
                                     else ", a retry of " & Records.Get (Value, "retry_of"))
                                  & ")")
                          --  An ended one says why, where it was stopped.
                          & (if Records.Get (Value, "state") = "cancelled"
                               and then Records.Get (Value, "summary") /= ""
                             then ": " & Records.Get (Value, "summary") else ""));

                  --  An attempt is its root agent's run: how that ended,
                  --  and why, not only that its call returned.
                  if Records.Get (Value, "parent") = "" then
                     declare
                        Why : constant String := Records.Get (Value, "summary");
                     begin
                        Append (Attempts, (if Attempts = Null_Unbounded_String then "" else "; ")
                                & Name (Name'First + 6 .. Name'Last)
                                & (if Records.Get (Value, "invocation") = "" then ""
                                   else " in " & Records.Get (Value, "invocation"))
                                & " " & (if Records.Get (Value, "outcome") /= ""
                                         then "left it " & Records.Get (Value, "outcome")
                                         else Records.Get (Value, "state"))
                                & (if Why = "" then "" else ": " & Why));
                     end;
                  end if;
               end if;
            end;
         end loop;
         Say ("attempts", To_String (Attempts));
         Say ("agents", To_String (Workers));
      end;

      --  Every move it made, when and why, not only the last attempt's.
      declare
         Happened : constant Events.Event_List := Events.Since (Item, 0);
      begin
         for Index in 1 .. Events.Length (Happened) loop
            declare
               One : constant Events.Event := Events.Element (Happened, Index);
            begin
               if To_String (One.Subject) = Task_Id then
                  Result.Append
                    ("history: " & To_String (One.Occurred_At) & " "
                     & To_String (One.Kind_Word)
                     & (if Length (One.Detail) = 0 then "" else " -- " & To_String (One.Detail)));
               end if;
            end;
         end loop;
      end;
      Say ("proposed", Proposals_Of (Item, Task_Id));
      Say ("files changed", Comma_Separated (Lines_Of (Records.Get (State, "changed_files"))));
      Say ("workspace", Records.Get (State, "current_workspace"));
      Say ("verification", Records.Get (State, "current_verification")
           & (if Records.Get (Proof, "profile") = "" then ""
              else ", profile " & Records.Get (Proof, "profile")
                   & (if Records.Get (Proof, "passed") = "true" then ", passed" else ", failed")));
      Say ("tool versions", Fields_With (Proof, "tool."));
      Say ("completion",
           (if Tasks.State_Of (Item, Task_Id) /= "complete"
            then (if Tasks.State_Of (Item, Task_Id) = "failed" then "it has failed"
                  else "it is " & Tasks.State_Of (Item, Task_Id))
            elsif Records.Get (State, "completed_by") = "hand"
            then "completed by hand"
                 & (if Records.Get (State, "current_verification") = "" then ", with no evidence"
                    else ", checked by " & Records.Get (State, "current_verification"))
                 & (if Records.Get (State, "set_aside") = "" then ""
                    else "; set aside: "
                         & Comma_Separated (Lines_Of (Records.Get (State, "set_aside"))))
            elsif Records.Get (State, "current_verification") = ""
            then "its gates passed, with no evidence"
            else "its gates passed on " & Records.Get (State, "current_verification")));
      if Records.Get (State, "replaced_by") /= "" then
         Say ("replaced", Records.Get (State, "replaced_by"));
      end if;
      for Line of Lines_Of (Records.Get (State, "conflicts")) loop
         Say ("conflict", Line);
      end loop;
      if Records.Get (State, "resolution") /= "" then
         Say ("resolution", Records.Get (State, "resolution"));
      end if;
      Say ("integration",
           (if Records.Get (State, "current_workspace") = ""
            then (if Tasks.State_Of (Item, Task_Id) in "candidate" | "accepted" then "none yet"
                  elsif Invocation = "" then "none: it was never worked"
                  else "none: it wrote in the project itself")
            elsif Tasks.State_Of (Item, Task_Id) = "complete"
              and then Workspace_Status (Records.Get (State, "current_workspace")) = "integrated"
            then "the workspace " & Records.Get (State, "current_workspace") & ", taken in"
                 & (if Records.Get (State, "integration_note") = "" then ""
                    else "; " & Records.Get (State, "integration_note"))
            elsif Workspaces.Active_For (Item, Task_Id) /= ""
            then "the workspace " & Records.Get (State, "current_workspace") & ", waiting to be"
                 & " taken in"
            else "the workspace " & Records.Get (State, "current_workspace") & ", given up:"
                 & " nothing of it was taken in"
                 & (if Records.Get (State, "changed_files") = "" then ""
                    else "; what it changed there ("
                         & Comma_Separated (Lines_Of (Records.Get (State, "changed_files")))
                         & (if Ada.Directories.Exists
                              (Workspaces.Kept_Copy (Item, Records.Get (State, "current_workspace")))
                            then ") is kept in "
                                 & Ada.Directories.Simple_Name
                                     (Workspaces.Kept_Copy
                                        (Item, Records.Get (State, "current_workspace")))
                            else ") went with it"))));
      declare
         Became : Unbounded_String;
      begin
         for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
            declare
               Held : Intent.Entity;
               Read : E.Error_Info;
            begin
               Intent.Read (Item, Intent.Requirement, Requirement, Held, Read);
               Append (Became, (if Became = Null_Unbounded_String then "" else ", ")
                       & Requirement & " " & To_String (Held.State));
            end;
         end loop;
         Say ("requirements now", To_String (Became));
      end;
      return Result;
   end Audit;

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
   is
      May_Write   : constant Boolean :=
        Allowed (Permissions.Write_Source).Granted or else Allowed (Permissions.Write_Specs).Granted;
      --  Helpers only where the runner can make them: a model run apart
      --  has no delegate tool.
      May_Delegate : constant Boolean :=
        Helpers and then Allowed (Permissions.Create_Children).Granted
        and then Allowed (Permissions.Create_Children).Max_Children > 0
        and then Allowed (Permissions.Create_Children).Max_Depth >= 1
        --  None allowed by the agents' own bound: no helpers either.
        and then Agents.Limits_Of (Item).Max_Children > 0;
      May_Check   : constant Boolean := Helpers and then Offers_Checks (Item, Allowed, Task_Id, Apart);
      May_Propose : constant Boolean := Permissions.Allows (Allowed, Permissions.Propose_Tasks);

      function May_Split return Boolean is
         Depth : Natural := 0;
         Up    : Unbounded_String := To_Unbounded_String (Task_Id);
         Limit : constant Permissions.Grant :=
           (if Allowed (Permissions.Create_Children).Granted then Allowed (Permissions.Create_Children)
            else Permissions.Effective (Item, "", "", Within_Sandbox => False) (Permissions.Create_Children));
         Bounds : constant Agents.Limits := Agents.Limits_Of (Item);
      begin
         loop
            declare
               Defined_Up : Records.Item;
               Read_Up    : E.Error_Info;
            begin
               Tasks.Definition (Item, To_String (Up), Defined_Up, Read_Up);
               exit when E.Is_Error (Read_Up) or else Records.Get (Defined_Up, "parent") = ""
                 or else Depth > 64;
               Up := To_Unbounded_String (Records.Get (Defined_Up, "parent"));
               Depth := Depth + 1;
            end;
         end loop;
         return Limit.Granted and then Depth + 1 <= Natural'Min (Limit.Max_Depth, Bounds.Max_Depth);
      end May_Split;

      --  The permissions it has a tool for, in plain words.
      function Said_Permissions return String is
         Said : Unbounded_String;
         procedure Add (Text : String) is
         begin
            Append (Said, (if Said = Null_Unbounded_String then "" else "; ") & Text);
         end Add;
      begin
         if Allowed (Permissions.Read_Source).Granted then
            Add ("read the source");
         end if;
         if Allowed (Permissions.Read_Specs).Granted then
            Add ("read the specifications");
         end if;
         if Allowed (Permissions.Write_Source).Granted then
            Add ("write " & (if Allowed (Permissions.Write_Source).Roots.Is_Empty then "files"
                             else "files under " & Comma_Separated (Allowed (Permissions.Write_Source).Roots))
                 --  What it may not, inherited or its own, said with it.
                 & (if Allowed (Permissions.Write_Source).Deny.Is_Empty then ""
                    else " except " & Comma_Separated (Allowed (Permissions.Write_Source).Deny)));
         end if;
         if Allowed (Permissions.Write_Specs).Granted then
            Add ("write specifications "
                 & (if Allowed (Permissions.Write_Specs).Roots.Is_Empty
                    then "(in " & Permissions.Specification_Places & ")"
                    else "under " & Comma_Separated (Allowed (Permissions.Write_Specs).Roots)));
         end if;
         --  Its checks, by the profile that runs them.
         if May_Check then
            declare
               Kind    : constant String := Kind_Of_Task (Item, Task_Id);
               Profile : constant String :=
                 (if Tasks.Kind_Policy (Item, Kind, "profile") /= "" then Tasks.Kind_Policy (Item, Kind, "profile")
                  else Scalar (Item, "verification.default"));
            begin
               Add ("run the project's checks" & (if Profile = "" then "" else " (profile " & Profile & ")"));
            end;
         end if;
         if May_Delegate then
            --  The lower of the grant and the agents' own bound: what an
            --  agent meets.
            Add ("hand parts to helpers (at most"
                 & Natural'Image (Natural'Min (Allowed (Permissions.Create_Children).Max_Children,
                                               Agents.Limits_Of (Item).Max_Children)) & ")");
         end if;
         if May_Propose then
            Add ("propose tasks");
         end if;
         return (if Said = Null_Unbounded_String then "read only what you are given" else To_String (Said));
      end Said_Permissions;

      Parts : Unbounded_String;
   begin
      for Child of Tasks.Children (Item, Task_Id) loop
         declare
            Defined : Records.Item;
            Read    : E.Error_Info;
         begin
            Tasks.Definition (Item, Child, Defined, Read);
            Append (Parts, "- " & Child & " " & Records.Get (Defined, "title") & ": "
                    & Tasks.State_Of (Item, Child) & ASCII.LF);
         end;
      end loop;
      return Instructions_For (May_Propose, May_Split, May_Write,
                               May_Delegate => May_Delegate, May_Check => May_Check)
        & ASCII.LF & "## What you may do" & ASCII.LF
        & "You may " & Said_Permissions & "."
        & (if May_Write then " Change only the files you may write; a change to any other file fails the work."
           else "")
        & (if May_Propose then "" else " You may not propose tasks or parts.")
        & ASCII.LF
        & (if Parts = Null_Unbounded_String then ""
           else ASCII.LF & "## Your parts" & ASCII.LF & To_String (Parts)
                & "Those complete are done: do what is left of the task itself, and do not split"
                & " it into them again." & ASCII.LF);
   end Instructions_With;

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

   function Unable_Reason (Item : Stores.Store; Task_Id : String) return String is
      View : Records.Item;
      Read : E.Error_Info;
   begin
      Tasks.Effective (Item, Task_Id, View, Read);
      if E.Is_Error (Read) then
         return "";
      end if;
      declare
         Allowed : constant Permissions.Permission_Set :=
           Permissions.Effective (Item, Records.Get (View, "definition.kind"), "worker",
                                  Task_Level => Records.Get (View, "definition.permissions"));
         Writes  : constant Boolean :=
           Ada.Strings.Fixed.Index (Records.Get (View, "gates"), "implementation_present") > 0;
         Homes   : constant Name_Lists.Vector :=
           Repository.Component_Roots (Item, Records.Get (View, "definition.component"));
         --  Where its component's files are and it may write none of them.
         Elsewhere : constant Boolean :=
           Writes and then Permissions.Allows (Allowed, Permissions.Write_Source)
           and then not Homes.Is_Empty
           and then not (for some Home of Homes =>
                           Permissions.Allows (Allowed, Permissions.Write_Source,
                                               (if Home'Length > 0 and then Home (Home'Last) = '/'
                                                then Home else Home & "/") & "x"));
         --  The project's files its title or notes name that it may not
         --  write: work on those it could not do.
         function Named_Out_Of_Reach return String is
            Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
            Words   : constant String :=
              Records.Get (View, "definition.title") & " " & Records.Get (View, "definition.notes")
              & " " & Records.Get (View, "definition.question");
            Start   : Natural := Words'First;
            Out_Of  : Unbounded_String;
         begin
            if not Writes then
               return "";
            end if;
            for Index in Words'First .. Words'Last + 1 loop
               if Index > Words'Last or else Words (Index) in ' ' | ',' | ';' | '"' | '(' | ')' then
                  declare
                     Word : constant String :=
                       Ada.Strings.Fixed.Trim (Words (Start .. Index - 1), Ada.Strings.Maps.To_Set (".:`'"),
                                               Ada.Strings.Maps.To_Set (".:`'"));
                  begin
                     if Ada.Strings.Fixed.Index (Word, "/") > 0
                       and then Ada.Strings.Fixed.Index (Word, "..") = 0
                       and then Word (Word'First) /= '/'
                       and then Ada.Directories.Exists (Hostkit.Fs.Join (Project, Word))
                       and then not Permissions.Allows (Allowed, Permissions.Write_Source, Word)
                       and then not Permissions.Allows (Allowed, Permissions.Write_Specs, Word)
                     then
                        Append (Out_Of, (if Out_Of = Null_Unbounded_String then "" else ", ") & Word);
                     end if;
                  exception
                     when others =>
                        null;
                  end;
                  Start := Index + 1;
               end if;
            end loop;
            return To_String (Out_Of);
         end Named_Out_Of_Reach;
         Lacks   : constant String :=
           (if Permissions.Image (Allowed) = "" then "anything"
            --  Specifications alone are writing only for documentation:
            --  an implementation's files are source.
            elsif Writes and then not Permissions.Allows (Allowed, Permissions.Write_Source)
              and then not (Permissions.Allows (Allowed, Permissions.Write_Specs)
                            and then Records.Get (View, "definition.kind") = "documentation")
            then "write a file"
            elsif not Permissions.Allows (Allowed, Permissions.Read_Source) then "read the source"
            elsif Elsewhere then "write where its component's files are"
            elsif Named_Out_Of_Reach /= "" then "write " & Named_Out_Of_Reach & ", which its task names"
            else "");
      begin
         if Lacks = "" then
            return "";
         end if;
         --  The level that withholds it, and the setting that grants it.
         declare
            Kind   : constant String := Records.Get (View, "definition.kind");
            Config : Records.Item;
            Got    : E.Error_Info;
            Kind_Named : Boolean := False;
            Capability : constant String :=
              (if Lacks = "write a file" then "write_source"
               elsif Lacks in "read the source" | "anything" then "read_source" else "");
         begin
            Configurations.Read (Item, Config, Got);
            for Index in 1 .. Records.Field_Count (Config) loop
               Kind_Named := Kind_Named
                 or else Ada.Strings.Fixed.Index (Records.Field_Name (Config, Index),
                                                  "map.permission.kind." & Kind & ".") = 1
                 or else Records.Field_Name (Config, Index) = "map.permission.kind." & Kind;
            end loop;
            declare
               --  Which level withholds it: the task's own field only where
               --  its kind would grant it; else the kind, else the project.
               Of_Kind    : constant Permissions.Permission_Set :=
                 Permissions.Effective (Item, Kind, "worker", Within_Sandbox => False);
               Of_Project : constant Permissions.Permission_Set :=
                 Permissions.Effective (Item, "", "worker", Within_Sandbox => False);
               function Grants (Set : Permissions.Permission_Set) return Boolean
               is (Capability /= ""
                   and then (for some One in Permissions.Capability =>
                               Permissions.Word (One) = Capability and then Set (One).Granted));
               Own_Narrows : constant Boolean :=
                 Records.Get (View, "definition.permissions") /= "" and then Grants (Of_Kind);
               Level : constant String :=
                 (if Kind_Named and then Grants (Of_Project) then "kind." & Kind else "project");
            begin
               return (if Lacks = "anything" then "it may do nothing at all" else "it would not be let " & Lacks)
                 & (if Lacks = "write a file" then ", which its gate implementation_present needs" else "")
                 & (if Capability = "" or else Permissions."/=" (Permissions.Sandbox, Permissions.Unrestricted)
                      or else Own_Narrows
                    then ""
                    else "; " & Level & " withholds " & Capability & " -- /reconfigure map.permission."
                         & Level & "." & Capability & "=on grants it")
                 & (if Elsewhere then " (" & Comma_Separated (Homes) & ")" else "")
                 & (if Permissions."/=" (Permissions.Sandbox, Permissions.Unrestricted)
                    then "; " & Permissions.Sandbox_Source & " confines it -- /sandbox off lifts that"
                    else "")
                 & (if Own_Narrows
                    then "; its own permissions narrow it -- /task grant " & Task_Id & " " & Capability
                         & " gives it back, or /task edit " & Task_Id & " permissions=inherit takes its kind's"
                    else "");
            end;
         end;
      end;
   end Unable_Reason;

   -----------------------
   -- Keep_Before_Write --
   -----------------------

   procedure Keep_Before_Write (Host : in out Child_Host; Path : String) is
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Host.Item.all));
      From    : constant String := Hostkit.Fs.Join (Project, Path);
      To      : constant String := Hostkit.Fs.Join (Before_Copy (Host.Item.all, To_String (Host.Task_Id)), Path);
   begin
      if Host.Apart or else Host.Kept_Before.Contains (Path) then
         return;
      end if;
      Host.Kept_Before.Append (Path);
      --  The first copy is the one before any run wrote it: a later run's
      --  does not replace it.
      if Ada.Directories.Exists (From) and then not Ada.Directories.Exists (To)
        and then Ada.Directories."=" (Ada.Directories.Kind (From), Ada.Directories.Ordinary_File)
      then
         Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (To));
         Ada.Directories.Copy_File (From, To);
      end if;
   exception
      when others =>
         null;
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
   is
      Change   : Stores.Transaction;
      Evidence : Unbounded_String;
      Passed   : Boolean;
      Value    : Records.Item;
      Read     : E.Error_Info;

      --  The last lines of a text, enough to see an error by.
      function Tail (Text : String; Count : Positive) return String is
         Seen : Natural := 0;
      begin
         for Index in reverse Text'Range loop
            if Text (Index) = ASCII.LF and then Index < Text'Last then
               Seen := Seen + 1;
               if Seen = Count then
                  return Text (Index + 1 .. Text'Last);
               end if;
            end if;
         end loop;
         return Text;
      end Tail;
   begin
      Report := Null_Unbounded_String;
      if not May_Check (Host, Profile) then
         Status := E.Make (E.Framework_Permission_Denied);
         E.Add_Text (Status, "name", Current (Host));
         E.Add_Text (Status, "detail", "it may not run the profile " & Profile);
         return;
      end if;
      declare
         Project : constant String :=
           Ada.Directories.Containing_Directory (Stores.Root (Host.Item.all));
         Before  : constant Configurations.Value_Maps.Map := Snapshot (Project, Repository.Roots_Of (Host.Item.all));
      begin
         --  Off the network unless the agent may use it.
         --  Within the time the work has left: a check does not carry it
         --  past its bound.
         if Time_Is_Up (Host) then
            Status := E.Make (E.Framework_Limit_Exceeded);
            E.Add_Text (Status, "name", "time");
            return;
         end if;
         --  Run for its task: credited to it, where its agents work in the
         --  project itself and the checks see what it holds.
         Verification.Run_Profile
           (Host.Item.all, Change, Profile, (if Host.Apart then "" else To_String (Host.Task_Id)),
            Evidence, Passed, Status,
            Offline => not May (Host, Permissions.Use_Network, ""),
            Within  => (if Host.Bounded then Natural (Duration'Max (1.0, Time_Left (Host))) else 0));
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;

         --  A build writes files of its own; they are the checks', not the
         --  agent's.
         declare
            After : constant Configurations.Value_Maps.Map := Snapshot (Project, Repository.Roots_Of (Host.Item.all));
         begin
            for Position in After.Iterate loop
               declare
                  Path : constant String := Configurations.Value_Maps.Key (Position);
                  Now  : constant String := Configurations.Value_Maps.Element (Position);
               begin
                  if not Before.Contains (Path) or else Before (Path) /= Now then
                     Host.Written.Append (Path & ASCII.HT & Now);
                  end if;
               end;
            end loop;
         end;
      end;

      Report := To_Unbounded_String
        (Profile & (if Passed then " passed" else " failed") & ", "
         & To_String (Evidence));
      Stores.Read (Host.Item.all, Verification_Area, To_String (Evidence), Value, Read);
      for Index in 1 .. Records.Field_Count (Value) loop
         declare
            Field : constant String := Records.Field_Name (Value, Index);
            Parts : constant Name_Lists.Vector :=
              (if Field'Length > 6 and then Field (Field'First .. Field'First + 5) = "check."
               then Fields_Of (Records.Get (Value, Field)) else Name_Lists.Empty_Vector);
         begin
            if Natural (Parts.Length) >= 7 then
               Append (Report, ASCII.LF & Parts (1) & ": " & Parts (5));
               if Parts (5) /= "passed" and then Parts (6) = "required" then
                  declare
                     Log  : Results.Result;
                     Held : E.Error_Info;
                  begin
                     Results.Read (Host.Item.all, Parts (7), Log, Held);
                     if E.Is_Ok (Held) then
                        Append (Report, ASCII.LF & Tail (To_String (Log.Payload), 30));
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
   end Run_Checks;

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
   is
      Change  : Stores.Transaction;
      Parent  : constant String := Current (Host);
      Owner   : Agents.Agent;
      Read    : E.Error_Info := E.Success;
      Named   : constant String := (if Trim (Role) = "" then "helper" else Trim (Role));
      Obliged : constant Agents.Obligation :=
        (if Need = "optional" then Agents.Optional
         elsif Need = "advisory" then Agents.Advisory
         else Agents.Required);
   begin
      Child_Id := Null_Unbounded_String;
      Context := Null_Unbounded_String;
      Budget := 0;

      --  Half of what its parent has left: a child that could spend all of
      --  it would leave its parent nothing to finish with.
      Agents.Read (Host.Item.all, Parent, Owner, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Budget := (if Owner.Used >= Owner.Budget then 0 else (Owner.Budget - Owner.Used) / 2);
      if Budget = 0 then
         Status := E.Make (E.Framework_Limit_Exceeded);
         E.Add_Text (Status, "name", Parent);
         E.Add_Text (Status, "detail", "it has no tokens left to give a child");
         return;
      end if;

      Agents.Spawn_Child
        (Host.Item.all, Change, Parent, Named, Obliged, Permissions.Unrestricted, Budget,
         Child_Id, Status, Retry_Of => Retry_Of);
      if E.Is_Ok (Status) then
         Stores.Commit (Host.Item.all, Change, Status);
      end if;
      if E.Is_Error (Status) then
         Child_Id := Null_Unbounded_String;
         Budget := 0;
         return;
      end if;
      Host.Open.Append (To_String (Child_Id));
      Host.Opened.Append (Ada.Calendar.Clock);

      --  A context of its own -- the task it helps with and what it is
      --  asked, nothing of the conversation it was asked from -- with its
      --  manifest kept and its invocation recorded before it is made.
      declare
         Made   : Framework.Context.Built;
         Called : Unbounded_String;

         --  What it may do, told it as the root agent is told: where it
         --  may write, whether it may make helpers or propose work.
         function Child_Allowed return String is
            Held : Agents.Agent;
            Got  : E.Error_Info;
            Said : Unbounded_String;
         begin
            Agents.Read (Host.Item.all, To_String (Child_Id), Held, Got);
            if E.Is_Error (Got) then
               return "";
            end if;
            --  Only what a tool of its own uses: a permission it has no
            --  tool for -- the network, proposing work -- is no use told.
            for Line of Lines_Of (Permissions.Image (Held.Allowed)) loop
               declare
                  Word : constant String := Trim (Line);
               begin
                  if Word /= ""
                    and then (Ada.Strings.Fixed.Index (Word, "read_") = Word'First
                              or else Ada.Strings.Fixed.Index (Word, "write_") = Word'First
                              or else Ada.Strings.Fixed.Index (Word, "run_") = Word'First
                              or else Ada.Strings.Fixed.Index (Word, "create_children") = Word'First)
                  then
                     Append (Said, (if Said = Null_Unbounded_String then "" else ", ")
                             & Permissions.In_Words (Word));
                  end if;
               end;
            end loop;
            declare
               Policy : constant String :=
                 Tool_Policy (Host.Item.all, To_String (Child_Id), Host.Max_Calls, To_String (Host.Task_Id),
                              Host.Apart);
               Tools_End : constant Natural := Ada.Strings.Fixed.Index (Policy, ";");
            begin
               return ASCII.LF & "## What you may do" & ASCII.LF
                 & "Your tools -- these and no others: "
                 & (if Tools_End > 7 then Policy (Policy'First + 7 .. Tools_End - 1) else "read_file, list_directory")
                 & "." & ASCII.LF
                 & "You may " & (if Said = Null_Unbounded_String then "only read what you are given"
                                 else To_String (Said))
                 & "." & ASCII.LF
                 & (if Permissions.Allows (Held.Allowed, Permissions.Write_Source)
                      or else Permissions.Allows (Held.Allowed, Permissions.Write_Specs)
                    then "Change only the files you may write."
                    else "Change no file: read, and report.")
                 & (if Permissions.Allows (Held.Allowed, Permissions.Create_Children) then ""
                    else " You may not make helpers of your own.")
                 & " Work you find beyond your part goes in your findings, for the agent that"
                 & " asked to propose."
                 & ASCII.LF;
            end;
         end Child_Allowed;
      begin
         Framework.Context.Build_Brief
           (Host.Item.all, To_String (Host.Task_Id), Host.Model,
            "You are helping an agent with one part of its task, as its " & Named
            & ". You cannot see its conversation, and it will see only your report.",
            Brief, Made, Read, Instructions => Child_Instructions & Child_Allowed);
         if E.Is_Ok (Read) then
            Framework.Context.Keep (Host.Item.all, Change, Made, Read);
         end if;
         if E.Is_Ok (Read) then
            Invocations.Start
              (Host.Item.all, Change, To_String (Child_Id), To_String (Host.Task_Id),
               Generation_Of (Host.Item.all, To_String (Host.Task_Id)),
               To_String (Host.Model.Id), Framework.Context.Manifest_Id (Made),
               Tool_Policy (Host.Item.all, To_String (Child_Id), Host.Max_Calls,
                            To_String (Host.Task_Id), Host.Apart),
               Child_Claim, Called, Read,
               Resource_Class => To_String (Host.Model.Resource_Class));
            if E.Is_Ok (Read) then
               Agents.Record_Holding
                 (Host.Item.all, Change, To_String (Child_Id), "", To_String (Called), Read);
            end if;
         end if;
         if E.Is_Ok (Read) then
            Stores.Commit (Host.Item.all, Change, Read);
         end if;

         --  Not made after all: the child ends failed, and is no longer the
         --  one working -- its parent goes on as itself, charged and held
         --  as itself, with nothing left open in its name.
         if E.Is_Error (Read) then
            --  Cancelled, not failed: it never worked, and a helper the
            --  model was told was not made holds nothing up.
            declare
               Ended : E.Error_Info;
               Close : Stores.Transaction;
            begin
               Agent_State (Host.Item.all, Close, To_String (Child_Id), "cancelled",
                            "it could not be started: " & Why_Of (Read));
               Stores.Commit (Host.Item.all, Close, Ended);
            end;
            Host.Open.Delete_Last;
            Host.Opened.Delete_Last;
            Child_Id := Null_Unbounded_String;
            Budget := 0;
            Status := Read;
            return;
         end if;
         Host.Calls.Append (To_String (Called));
         Context := To_Unbounded_String (Framework.Context.Rendered (Made));
      end;
   end Open_Child;

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
   is
      Change  : Stores.Transaction;
      Status  : E.Error_Info;
      Charged : E.Error_Info;
      Held    : E.Error_Info;
      Said    : Invocations.Claims;
      Child   : Agents.Agent;
      Good    : Boolean := False;
      Why     : Unbounded_String;
      Kept    : Results.Result;

      --  How many times the child it stands for has been run before it.
      function Runs_Before (Id : String) return Natural is
         Held_Agent : Agents.Agent;
         Read       : E.Error_Info;
      begin
         Agents.Read (Host.Item.all, Id, Held_Agent, Read);
         return (if E.Is_Error (Read) or else Held_Agent.Retry_Of = Null_Unbounded_String
                 then 0 else 1 + Runs_Before (To_String (Held_Agent.Retry_Of)));
      end Runs_Before;

      Retries : constant Natural :=
        (declare
           Text : constant String := Scalar (Host.Item.all, "agents.child_retries");
         begin
           (if Text'Length in 1 .. 3 and then (for all C of Text => C in '0' .. '9')
            then Natural'Value (Text) else 1));
   begin
      Told := Null_Unbounded_String;
      Retry := False;
      if Natural (Host.Open.Length) < 2 then
         Told := To_Unbounded_String ("error: no child is open");
         return;
      end if;

      declare
         Id : constant String := Host.Open.Last_Element;
      begin
         Agents.Read (Host.Item.all, Id, Child, Status);
         Agents.Charge (Host.Item.all, Change, Id, Tokens, Charged);

         if Interrupted (Ran) then
            Why := To_Unbounded_String
              ("it was stopped: the work was "
               & (if Execution.Cancel_Asked_From_Outside then "cancelled" else "interrupted"));
         elsif E.Is_Error (Ran) then
            Why := To_Unbounded_String ("it failed: " & Why_Of (Ran));
         else
            Invocations.Hold (Child_Claim, Answer, Said, Held);
            if E.Is_Error (Held) then
               Why := To_Unbounded_String
                 ("its answer did not keep to the child result contract: "
                  & E.Text_Of (Held, "name") & ": " & E.Text_Of (Held, "detail")
                  & " -- a helper answers with status: done, and summary: one line on what it found");
            elsif E.Is_Error (Charged) then
               Why := To_Unbounded_String ("it went over its budget");
            else
               Good := Invocations.Claim (Said, "status") = "done";
               Why := To_Unbounded_String (Own_Words (Invocations.Claim (Said, "summary")));
               --  Said nothing of what it found: said so, not left blank.
               if Trim (To_String (Why)) = "" then
                  Why := To_Unbounded_String ("(it gave no summary of what it found)");
               end if;

               --  Done, it says -- but a required child of its own that
               --  failed holds it as it holds the root.
               declare
                  Held_Back : Unbounded_String;
               begin
                  if Good and then not Agents.May_Complete (Host.Item.all, Id, Held_Back) then
                     Good := False;
                     Why := Held_Back;
                  end if;
               end;
            end if;
         end if;

         --  Its result is kept, whichever way it went; the parent is told
         --  of it, not of how it was reached.
         Kept :=
           (Kind       => Results.Child_Result,
            Producer   => To_Unbounded_String (Id),
            Summary    => Why,
            Payload    => To_Unbounded_String
              (if E.Is_Ok (Held) and then E.Is_Ok (Ran)
               then Invocations.Claim (Said, "findings")
                    & (if Invocations.Claim (Said, "changed_files") = "" then ""
                       else ASCII.LF & "changed_files: "
                            & Invocations.Claim (Said, "changed_files"))
               else Answer),
            Provenance => Child.Parent,
            others     => <>);
         Results.Add (Host.Item.all, Change, Kept, Status);
         if E.Is_Ok (Status) and then Interrupted (Ran) then
            --  Stopped by whoever started the work: cancelled, with what it
            --  made, and not run again.
            declare
               Stopped : Name_Lists.Vector;
            begin
               Agents.Cancel (Host.Item.all, Change, Id, Stopped, Status,
                              Why => To_String (Why), Result_Id => To_String (Kept.Id));
            end;
         elsif E.Is_Ok (Status) then
            Agents.Finish
              (Host.Item.all, Change, Id, Good, To_String (Kept.Id), To_String (Why), Status);
         end if;
         --  Its invocation ended, with what it used.
         if E.Is_Ok (Status) and then Host.Calls.Last_Element /= "" then
            Invocations.Finish
              (Host.Item.all, Change, Host.Calls.Last_Element,
               (if Interrupted (Ran) then Invocations.Cancelled
                elsif E.Is_Ok (Ran) then Invocations.Completed
                else Invocations.Failed),
               (Prompt_Tokens => Prompt_Tokens,
                Output_Tokens => Tokens,
                Seconds       =>
                  Natural (Duration'Max
                    (0.0, Ada.Calendar."-" (Ada.Calendar.Clock, Host.Opened.Last_Element)))),
               To_String (Kept.Id),
               (if E.Is_Ok (Ran) then "" else Why_Of (Ran)), Status);
         end if;
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
         Host.Open.Delete_Last;
         Host.Calls.Delete_Last;
         Host.Opened.Delete_Last;

         Retry := not Good and then not Interrupted (Ran) and then not Out_Of_Time (Ran)
           and then Agents."=" (Child.Need, Agents.Required)
           and then Runs_Before (Id) < Retries;
         Told := To_Unbounded_String
           (Id & " (" & Ada.Characters.Handling.To_Lower (Agents.Obligation'Image (Child.Need))
            & ") " & (if Good then "done" elsif Interrupted (Ran) then "cancelled" else "failed")
            & (if Kept.Id = Null_Unbounded_String then "" else ", " & To_String (Kept.Id))
            & ": " & To_String (Why)
            & (if Good and then Invocations.Claim (Said, "findings") /= ""
               then ASCII.LF & Invocations.Claim (Said, "findings") else "")
            & (if Retry then ASCII.LF & "It is run once more." else ""));
      end;
   end Close_Child;

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
   is
      Change  : Stores.Transaction;
      Project : constant String :=
        Ada.Directories.Containing_Directory (Stores.Root (Item));
      Built   : Context.Built;
      Answer  : Unbounded_String;
      Ran     : E.Error_Info;
      Said    : Invocations.Claims;
      Held    : E.Error_Info;

      --  The state files an agent run as a process of its own changed, put
      --  back as they were: the project's state is the harness's to change.
      Tampered : Name_Lists.Vector;

      --  What it wrote that it may not, put back as it was.
      Put_Back_Files : Name_Lists.Vector;

      --  Parts it asked for, made proposals of their own as its agent may
      --  not make children.
      Parts_Proposed : Name_Lists.Vector;

      --  The result its answer was kept as, which its end names.
      Last_Result : Unbounded_String;

      --  The parts its answer split the task into, as candidate children,
      --  how many it may have, and why not more.
      Split_Into  : Name_Lists.Vector;
      Split_Room  : Natural := Natural'Last;
      Split_Why   : Unbounded_String;

      --  What an earlier attempt left changed in the project, which this
      --  one may say it changed though it did not touch it again.
      function Changed_Before return Name_Lists.Vector is
         Held : Records.Item;
         Read : E.Error_Info;
      begin
         Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Read);
         return (if E.Is_Ok (Read) then Lines_Of (Records.Get (Held, "changed_files"))
                 else Name_Lists.Empty_Vector);
      end Changed_Before;

      Earlier_Changed : constant Name_Lists.Vector := Changed_Before;

      --  What it changed that its permissions do not let it write.
      function Beyond_Permissions return String is
         Held_Agent : Agents.Agent;
         Read       : E.Error_Info;
         Named      : Unbounded_String;
      begin
         Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Read);
         for Path of Result.Changed_Files loop
            if not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Source, Path)
              and then not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Specs, Path)
            then
               Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & Path);
            end if;
         end loop;
         return To_String (Named);
      end Beyond_Permissions;

      type Permission_Pair is array (1 .. 2) of Permissions.Capability;

      --  What it was allowed to write, which the files were not within.
      function Rule_Said return String is
         Held_Agent : Agents.Agent;
         Read       : E.Error_Info;
         Said       : Unbounded_String;
      begin
         Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Read);
         if E.Is_Error (Read) then
            return "";
         end if;
         for One of Permission_Pair'(Permissions.Write_Source, Permissions.Write_Specs) loop
            Append (Said, (if Said = Null_Unbounded_String then "" else "; ")
                    & Permissions.Word (One) & " "
                    & (if not Held_Agent.Allowed (One).Granted then "not granted"
                       elsif Held_Agent.Allowed (One).Roots.Is_Empty
                       then (if Permissions."=" (One, Permissions.Write_Specs)
                             then "in docs/, doc/, specs/, spec/ and Markdown files" else "anywhere")
                       else "in " & Comma_Separated (Held_Agent.Allowed (One).Roots)));
         end loop;
         return " (its agent may write: " & To_String (Said) & ")";
      end Rule_Said;

      --  Said after the files refused: whether the session's sandbox,
      --  not the project, refused them.
      function Sandbox_Said (Paths : String) return String is
      begin
         for Path of Split_On (Paths, ',') loop
            if Permissions.Sandbox_Refuses (Trim (Path), Writing => True) then
               return " -- " & Permissions.Sandbox_Source & " refused them, not the project's"
                 & " permissions";
            end if;
         end loop;
         return "";
      end Sandbox_Said;

      --  What its agent is told after its context, from what it holds.
      function Instructions_Here return String is
         Held_Agent : Agents.Agent;
         Read       : E.Error_Info;
      begin
         Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Read);
         return (if E.Is_Error (Read) then Instructions_Of (Item, Task_Id)
                 else Instructions_With
                        (Item, Task_Id, Held_Agent.Allowed,
                         (if Tasks.Kind_Policy (Item, Kind_Of (Item, Task_Id), "isolation") /= ""
                          then Tasks.Kind_Policy (Item, Kind_Of (Item, Task_Id), "isolation")
                          else Work_Setting (Item, "isolation")) = "workspace",
                         Helpers => Runner in Parenting_Runner'Class));
      end Instructions_Here;

      --  Whether it went over its token budget.
      Over_Budget : Boolean := False;

      --  What the call used, as the agent reports it.
      Used    : Invocations.Usage;

      --  Where the agent writes: the project, or its workspace, as its
      --  kind says, else the project.
      Kind     : constant String := Kind_Of (Item, Task_Id);
      use type Intent.Intent_Kind;
      Isolated : constant Boolean :=
        (if Tasks.Kind_Policy (Item, Kind, "isolation") /= ""
         then Tasks.Kind_Policy (Item, Kind, "isolation")
         else Work_Setting (Item, "isolation")) = "workspace";
      Place    : Unbounded_String := To_Unbounded_String (Project);

      --  End the work with the task moved and the agent recorded.
      --  Files it changed that its answer did not name, where it named
      --  some: said, as what a person looks at before trusting its report.
      function Unreported_Note return String is
         Said_Changed : constant Name_Lists.Vector :=
           Lines_Of (Replaced (Invocations.Claim (Said, "changed_files")));
         Unreported   : Name_Lists.Vector;
      begin
         for Path of Result.Changed_Files loop
            if not (for some Line of Said_Changed =>
                      Trim (Line) = Path or else Trim (Line) = "./" & Path)
            then
               Unreported.Append (Path);
            end if;
         end loop;
         return (if Unreported.Is_Empty or else Said_Changed.Is_Empty then ""
                 else "it also changed files it did not report: " & Comma_Separated (Unreported));
      end Unreported_Note;

      --  What it said it changed and did not: rewritten as it was, or not
      --  touched at all.
      function Overclaimed_Note return String is
         Said_Changed : constant Name_Lists.Vector :=
           Lines_Of (Replaced (Invocations.Claim (Said, "changed_files")));
         Not_Changed  : Name_Lists.Vector;
      begin
         for Line of Said_Changed loop
            declare
               Path : constant String :=
                 (if Trim (Line)'Length > 2 and then Trim (Line) (Trim (Line)'First .. Trim (Line)'First + 1) = "./"
                  then Trim (Line) (Trim (Line)'First + 2 .. Trim (Line)'Last) else Trim (Line));
            begin
               if Path not in "" | "-" and then not Result.Changed_Files.Contains (Path) then
                  Not_Changed.Append (Path);
               end if;
            end;
         end loop;
         return (if Not_Changed.Is_Empty then ""
                 else "it reported files it did not change: " & Comma_Separated (Not_Changed));
      end Overclaimed_Note;

      --  What an answer that is not taken proposed is not lost with it:
      --  kept as an issue, to be seen and made by hand.
      procedure Keep_Proposals_Aside is
         Lost : Unbounded_String;
         Held : E.Error_Info;
      begin
         for Line of Lines_Of (Invocations.Claim (Said, "proposed_tasks")) loop
            if Trim (Line) not in "" | "-" then
               Append (Lost, ASCII.LF & "not proposed: " & Trim (Line));
               Result.Kept_Back.Append (Trim (Line) & ": its answer was not taken");
            end if;
         end loop;
         for Line of Lines_Of (Invocations.Claim (Said, "parts")) loop
            if Trim (Line) not in "" | "-" then
               Append (Lost, ASCII.LF & "part not made: " & Trim (Line));
               Result.Kept_Back.Append (Trim (Line) & ": its answer was not taken");
            end if;
         end loop;
         if Lost /= Null_Unbounded_String
           or else Trim (Invocations.Claim (Said, "issues")) /= ""
         then
            declare
               Issue : Results.Result :=
                 (Kind       => Results.Diagnostic,
                  Producer   => Result.Agent_Id,
                  Summary    => To_Unbounded_String ("issues found working on " & Task_Id),
                  Payload    => To_Unbounded_String
                                  (Invocations.Claim (Said, "issues") & To_String (Lost)),
                  Provenance => Result.Invocation_Id,
                  others     => <>);
            begin
               Results.Add (Item, Change, Issue, Held);
               if E.Is_Ok (Held) then
                  Result.Issue_Id := Issue.Id;
                  Annotate (Item, Change, Task_Id, "issues", To_String (Issue.Id));
               end if;
            end;
         end if;
      end Keep_Proposals_Aside;

      procedure Conclude (Next, Given_Reason, Agent_End : String) is
         --  Not done, where it worked in the project itself: what it
         --  changed is still there, and said so.
         function Left_Behind return String is
            Named : Unbounded_String;
         begin
            if Isolated or else Next not in "failed" | "blocked" | "cancelled"
              or else Result.Changed_Files.Is_Empty
            then
               return "";
            end if;
            for Path of Result.Changed_Files loop
               Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & Path);
            end loop;
            return Left_Words (Item, To_String (Named), Task_Id, Cancelled => Next = "cancelled");
         end Left_Behind;

         --  Not done, where it worked apart: its workspace is given up --
         --  a retry starts afresh -- and said.
         function Given_Up return String is
            Held : E.Error_Info;
         begin
            if not Isolated or else Next not in "failed" | "blocked"
              or else Result.Workspace_Id = Null_Unbounded_String
              or else Workspaces.Active_For (Item, Task_Id) /= To_String (Result.Workspace_Id)
            then
               return "";
            end if;
            Workspaces.Abandon (Item, Change, To_String (Result.Workspace_Id), Held);
            return (if E.Is_Ok (Held)
                    then "; its workspace " & To_String (Result.Workspace_Id) & " is given up"
                         & (if Result.Changed_Files.Is_Empty then ""
                            else ", what it changed there kept in "
                                 & Ada.Directories.Simple_Name
                                     (Workspaces.Kept_Copy (Item, To_String (Result.Workspace_Id)))
                                 & " (/task kept lists it): "
                                 & Comma_Separated (Result.Changed_Files))
                    else "");
         end Given_Up;

         Reason : constant String := Given_Reason & Left_Behind & Given_Up;
      begin
         if Next /= "" then
            Tasks.Move (Item, Change, Task_Id, Next, Reason, Status => Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end if;
         Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
         Result.Reason := To_Unbounded_String (Reason);
         --  Its end, as any agent's: with the result it gave and an event
         --  saying so -- cancelled is only a state.
         declare
            Ended : E.Error_Info := E.Make (E.Framework_Transition_Invalid);
         begin
            if Agent_End in "completed" | "failed" then
               --  Its summary its own words, where it gave them; the
               --  reason the task stands where it does otherwise.
               Agents.Finish
                 (Item, Change, To_String (Result.Agent_Id), Agent_End = "completed",
                  To_String (Last_Result),
                  (if Reason = "" then To_String (Result.Summary)
                   elsif Result.Summary = Null_Unbounded_String then Reason
                   else To_String (Result.Summary) & " -- " & Reason),
                  Ended);
            end if;
            if E.Is_Error (Ended) then
               Agent_State (Item, Change, To_String (Result.Agent_Id), Agent_End, Reason);
            end if;
         end;
         --  What its attempt came to, beside how its agent ended: the state
         --  it left the task in.
         declare
            Held   : Records.Item;
            Staged : Boolean;
         begin
            Stores.Pending (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id), Held, Staged);
            if Staged then
               --  The state it moves to here, not yet committed.
               Records.Set (Held, "outcome",
                            (if Next /= "" then Next else Tasks.State_Of (Item, Task_Id)));
               --  Why, where its ending did not say: a cancel, an interrupt.
               if Records.Get (Held, "summary") = "" and then Reason /= "" then
                  Records.Set (Held, "summary", Reason);
               end if;
               Stores.Put (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id), Held);
            end if;
         end;
         --  A move lets go of what the task held; staying in verification,
         --  its work waiting to be taken in, it is let go of here.
         if Next = "" then
            Leases.Release
              (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id), Status);
            if E.Is_Ok (Status) and then not Isolated and then Component_Of (Item, Task_Id) /= ""
            then
               Leases.Release
                 (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)),
                  To_String (Result.Agent_Id), Status);
            end if;
            if E.Is_Ok (Status) and then not Isolated then
               Leases.Release
                 (Item, Change, Tasks.Project_Lease, To_String (Result.Agent_Id), Status);
            end if;
         end if;
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
      end Conclude;

      --  Work that did not end as it should -- an answer that broke the
      --  contract, an agent that crashed -- and changed files: kept for a
      --  person. Apart, it waits in its workspace to be taken in as any
      --  finished work does; in the project, the task is set aside with
      --  the files where they are.
      procedure Keep_Work (Why : String) is
      begin
         if Isolated and then Result.Workspace_Id /= Null_Unbounded_String
           and then not Result.Changed_Files.Is_Empty
         then
            Conclude ("verification",
                      Why & "; what it changed is kept in its workspace "
                      & To_String (Result.Workspace_Id) & ": " & Comma_Separated (Result.Changed_Files)
                      & " -- /task integrate " & Task_Id & " checks it and takes it in, /task integrate "
                      & Task_Id & " discard gives it up and does the task afresh",
                      "failed");
         --  What it left in the project, and /task complete for it, are
         --  said once, with the files, where the run's end is said.
         else
            Conclude ("blocked", Why, "failed");
         end if;
      end Keep_Work;

      --  Hold the task -- and, writing in the project itself, its component
      --  and the project -- for so long; taken again by the same agent, a
      --  hold is renewed. Long enough for the work it is allowed, so a live
      --  task is not taken back from it; a process that dies lets go at once.
      procedure Hold (Seconds : Positive) is
      begin
         Leases.Acquire
           (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id), Seconds, Status);

         --  Writing in the project itself, it holds its component too, so
         --  no other agent writes the same component meanwhile.
         if E.Is_Ok (Status) and then not Isolated and then Component_Of (Item, Task_Id) /= ""
         then
            Leases.Acquire
              (Item, Change, Tasks.Component_Lease (Component_Of (Item, Task_Id)),
               To_String (Result.Agent_Id), Seconds, Status);
         end if;

         --  And the project, so that no other agent writes in it meanwhile.
         if E.Is_Ok (Status) and then not Isolated then
            Leases.Acquire
              (Item, Change, Tasks.Project_Lease, To_String (Result.Agent_Id), Seconds, Status);
         end if;
      end Hold;
   begin
      Result := (Task_Id => To_Unbounded_String (Task_Id), others => <>);

      declare
         Now : constant Tasks.Readiness := Tasks.Ready (Item, Task_Id);
      begin
         --  Its permissions leaving its agent unable are not a reason not to
         --  start here: what it is refused is found as it works, and said.
         if not Now.Ready
           and then not (Natural (Now.Reasons.Length) = 1
                         and then Now.Reasons.First_Element = Unable_Reason (Item, Task_Id))
         then
            Status := E.Make (E.Framework_Task_Not_Ready);
            E.Add_Text (Status, "name", Task_Id);
            E.Add_Text
              (Status, "detail",
               (if Now.Reasons.Is_Empty then "" else Now.Reasons.First_Element));
            return;
         end if;
      end;

      --  A runner that cannot start is a setup to put right: said, and the
      --  task left ready, no attempt spent on it.
      Status := E.Success;
      Runner.Check_Start (Item, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  An agent of its own, holding the task, in a new generation, with
      --  what its task's kind and its role allow.
      declare
         Defined : Records.Item;
      begin
         Tasks.Definition (Item, Task_Id, Defined, Status);
         Agents.Start_Root
           (Item, Change, Task_Id, "worker", Records.Get (Defined, "kind"),
            Result.Agent_Id, Status,
            Restriction => Records.Get (Defined, "permissions"),
            Budget      => Number_Of (Tasks.Kind_Policy (Item, Kind, "token_budget"), 0));
      end;
      if E.Is_Error (Status) then
         return;
      end if;
      Hold (Lease_Seconds (Item) + Time_Allowed (Item, Task_Id));
      if E.Is_Ok (Status) then
         Tasks.Move (Item, Change, Task_Id, "running", "", Status => Status);
      end if;

      --  The agent works in the generation the move to running began, not
      --  the one before it.
      if E.Is_Ok (Status) then
         declare
            Task_State, Agent : Records.Item;
            Staged, Held      : Boolean;
         begin
            Stores.Pending (Change, Tasks_Area, Task_Id & ".state", Task_State, Staged);
            Stores.Pending (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id),
                            Agent, Held);
            if Staged and then Held then
               Records.Set (Agent, "generation", Records.Get (Task_State, "generation"));
               Stores.Put (Change, Runtime_Area, "agent." & To_String (Result.Agent_Id), Agent);
            end if;
         end;
      end if;
      if E.Is_Ok (Status) then
         Annotate (Item, Change, Task_Id, "admission", Admission (Item, Task_Id, Isolated));
         declare
            Named : Unbounded_String;
         begin
            Runner.Describe (Named);
            Annotate (Item, Change, Task_Id, "runner", To_String (Named));
         end;
         Annotate (Item, Change, Task_Id, "active_agent", To_String (Result.Agent_Id));
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      --  What it is told, and the call, recorded before it is made.
      Context.Build
        (Item, Task_Id, Model, Built, Held,
         Instructions => Instructions_Here);
      if E.Is_Error (Held) then
         Conclude ("blocked", "its context cannot be built: "
                   & Why_Of (Held), "failed");
         return;
      end if;
      Result.Manifest_Id := To_Unbounded_String (Context.Manifest_Id (Built));
      Context.Keep (Item, Change, Built, Status);
      if E.Is_Ok (Status) then
         Invocations.Start
           (Item, Change, To_String (Result.Agent_Id), Task_Id,
            Generation_Of (Item, Task_Id),
            To_String (Model.Id),
            To_String (Result.Manifest_Id),
            Tool_Policy
              (Item, To_String (Result.Agent_Id),
               Number_Of ((if Tasks.Kind_Policy (Item, Kind, "max_tool_calls") /= ""
                           then Tasks.Kind_Policy (Item, Kind, "max_tool_calls")
                           else Scalar (Item, "agents.max_tool_calls")), 0),
               Task_Id, Isolated, Hosted => Runner in Parenting_Runner'Class),
            Invocations.Work_Claim,
            Result.Invocation_Id, Status, Resource_Class => To_String (Model.Resource_Class));
         if E.Is_Ok (Status) then
            Agents.Record_Holding
              (Item, Change, To_String (Result.Agent_Id), "", To_String (Result.Invocation_Id),
               Status);
         end if;
      end if;
      if E."=" (Status.Code, E.Framework_Limit_Exceeded) then
         --  Out of calls: blocked, deterministically, not run past its bound.
         Change := Stores.No_Changes;
         Conclude ("blocked", "no model call is left to it: " & Why_Of (Status),
                   "failed");
         return;
      end if;
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      --  Its own copy to write in, when the project isolates work.
      if Isolated then
         declare
            Made  : Workspaces.Workspace;
            Stale : constant String := Workspaces.Active_For (Item, Task_Id);
         begin
            --  A workspace an earlier attempt left -- set aside, not taken in
            --  -- is that attempt's: this generation starts from the project
            --  as it is, and the task has one workspace, not two.
            if Stale /= "" then
               Workspaces.Abandon (Item, Change, Stale, Held);
               if E.Is_Error (Held) then
                  Change := Stores.No_Changes;
                  Conclude ("blocked", "its earlier workspace cannot be set aside", "failed");
                  return;
               end if;
            end if;
            Workspaces.Create
              (Item, Change, Task_Id, To_String (Result.Agent_Id),
               Generation_Of (Item, Task_Id), Work_Setting (Item, "backend") /= "copy",
               Made, Held);
            if E.Is_Ok (Held) then
               Agents.Record_Holding
                 (Item, Change, To_String (Result.Agent_Id), To_String (Made.Id), "", Held);
            end if;
            if E.Is_Error (Held) then
               Change := Stores.No_Changes;
               Conclude ("blocked",
                         (if E."=" (Held.Code, E.Framework_Limit_Exceeded)
                          then "no workspace slot is free"
                          else "its workspace cannot be made"),
                         "failed");
               return;
            end if;
            Result.Workspace_Id := Made.Id;
            Place := Made.Path;
            Annotate (Item, Change, Task_Id, "current_workspace", To_String (Made.Id));
            Stores.Commit (Item, Change, Status);
            if E.Is_Error (Status) then
               return;
            end if;
         end;
      end if;

      declare
         Scratch : constant String :=
           Hostkit.Fs.Join (Hostkit.Fs.Join (Stores.Root (Item), "runtime"), "exec");
         Prompt  : constant String :=
           Hostkit.Fs.Join (Scratch, "prompt-" & To_String (Result.Agent_Id) & ".txt");
         Before  : constant Configurations.Value_Maps.Map := Snapshot (To_String (Place), Repository.Roots_Of (Item));
         By_Checks : Name_Lists.Vector;
      begin
         --  Written in the project itself: what the files were, kept for an
         --  opening after a kill to compare with.
         if not Isolated then
            declare
               Lines : Unbounded_String;
               Kept  : E.Error_Info;
            begin
               for Position in Before.Iterate loop
                  Append (Lines, Configurations.Value_Maps.Key (Position) & ASCII.HT
                          & Configurations.Value_Maps.Element (Position) & ASCII.LF);
               end loop;
               Files.Write_Text (Before_File (Item, Task_Id), To_String (Lines), Kept);
            end;
         end if;
         if Files.Make_Directory (Scratch) then
            Files.Write_Text
              (Prompt, Context.Rendered (Built), Status);

            --  What the agent may do, for a runner that starts it as a
            --  process of its own to hold it to.
            if E.Is_Ok (Status) then
               declare
                  Root_Agent : Agents.Agent;
                  Read       : E.Error_Info;
               begin
                  Agents.Read (Item, To_String (Result.Agent_Id), Root_Agent, Read);
                  Files.Write_Text
                    (Permissions.Permissions_Beside (Prompt),
                     (if E.Is_Ok (Read) then Permissions.Image (Root_Agent.Allowed) else ""),
                     Status);
                  if E.Is_Ok (Read) and then not Isolated then
                     Keep_Originals (Item, To_String (Result.Agent_Id), To_String (Place), Before,
                                     Root_Agent.Allowed);
                  end if;
               end;
            end if;
         else
            Files.Write_Failed (Scratch, Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;

         declare
            Host : Child_Host (Item'Access);
         begin
            Host.Task_Id := To_Unbounded_String (Task_Id);
            Host.Apart := Isolated;
            Host.Model := Model;
            declare
               use type Ada.Calendar.Time;
               Seconds : constant Natural := Time_Allowed (Item, Task_Id);
            begin
               Host.Bounded := Seconds > 0;
               Host.Deadline := Ada.Calendar.Clock + Duration (Seconds);
            end;
            Host.Max_Calls := Number_Of
              ((if Tasks.Kind_Policy (Item, Kind, "max_tool_calls") /= ""
                then Tasks.Kind_Policy (Item, Kind, "max_tool_calls")
                else Scalar (Item, "agents.max_tool_calls")), 0);
            Host.Max_Steps := Number_Of
              ((if Tasks.Kind_Policy (Item, Kind, "max_steps") /= ""
                then Tasks.Kind_Policy (Item, Kind, "max_steps")
                else Scalar (Item, "agents.max_steps")), 24);
            Host.Open.Append (To_String (Result.Agent_Id));
            Host.Calls.Append (To_String (Result.Invocation_Id));
            Host.Opened.Append (Ada.Calendar.Clock);

            --  Ended elsewhere meanwhile -- cancelled from another process
            --  -- what runs for it is stopped.
            Execution.Watch_Lease
              (Item'Unchecked_Access, Lease_Of (Task_Id), To_String (Result.Agent_Id));
            if Runner in Parenting_Runner'Class then
               Parenting_Runner'Class (Runner).Run_Parenting
                 (Prompt, To_String (Place), Host, Answer, Ran);
            else
               declare
                  State : Stores.State_Snapshot;
               begin
                  Stores.Snapshot_State (Item, State);
                  if Starting /= null then
                     Starting (To_String (Result.Agent_Id), To_String (Result.Manifest_Id),
                               To_String (Result.Invocation_Id));
                  end if;
                  Runner.Run (Prompt, To_String (Place), Answer, Ran);
                  Stores.Restore_State (Item, State, Tampered);
               end;

               --  What an agent run apart used, as its runner reports it:
               --  charged, and its calls recorded, as the harness's own are.
               if Ada.Directories.Exists (Usage_Beside (Prompt)) then
                  declare
                     Text   : Unbounded_String;
                     Read   : E.Error_Info;
                     Spent  : Natural := 0;
                     Seen   : Natural := 0;
                  begin
                     Files.Read_Text (Usage_Beside (Prompt), Text, Read);
                     for Line of Lines_Of (To_String (Text)) loop
                        if Ada.Strings.Fixed.Index (Line, "output_tokens ") = Line'First then
                           Spent := Number_Of (Trim (Line (Line'First + 14 .. Line'Last)), 0);
                        elsif Ada.Strings.Fixed.Index (Line, "prompt_tokens ") = Line'First then
                           Seen := Number_Of (Trim (Line (Line'First + 14 .. Line'Last)), 0);
                        elsif Ada.Strings.Fixed.Index (Line, "call ") = Line'First then
                           declare
                              Rest : constant String := Line (Line'First + 5 .. Line'Last);
                              Tab  : constant Natural :=
                                Ada.Strings.Fixed.Index (Rest, [1 => ASCII.HT]);
                           begin
                              Note_Call
                                (Host, (if Tab = 0 then Rest else Rest (Rest'First .. Tab - 1)),
                                 (if Tab = 0 then "" else Rest (Tab + 1 .. Rest'Last)), "");
                           end;
                        end if;
                     end loop;
                     Spend (Host, Spent, Seen);
                     Files.Discard (Usage_Beside (Prompt));
                  end;
               end if;
            end if;
            Execution.Watch_Lease (null);
            Abandon (Host);
            By_Checks := Host.Written;
            Over_Budget := Host.Root_Over;
            Used :=
              (Prompt_Tokens =>
                 (if Host.Root_Prompt > 0 then Host.Root_Prompt else Context.Cost (Built)),
               Output_Tokens => Host.Root_Out,
               Seconds       =>
                 Natural (Duration'Max
                   (0.0, Ada.Calendar."-" (Ada.Calendar.Clock, Host.Opened.First_Element))));
         end;
         for Line of Lines_Of (Agents.Child_Results (Item, To_String (Result.Agent_Id))) loop
            Result.Children.Append (Line);
         end loop;
         Files.Discard (Prompt);
         Files.Discard (Permissions.Permissions_Beside (Prompt));

         --  What changed is what the files say, not what the answer says.
         declare
            After : constant Configurations.Value_Maps.Map := Snapshot (To_String (Place), Repository.Roots_Of (Item));
         begin
            for Position in After.Iterate loop
               declare
                  Path : constant String := Configurations.Value_Maps.Key (Position);
               begin
                  if (not Before.Contains (Path)
                      or else Before (Path) /= Configurations.Value_Maps.Element (Position))
                    and then not By_Checks.Contains
                                   (Path & ASCII.HT & Configurations.Value_Maps.Element (Position))
                  then
                     Result.Changed_Files.Append (Path);
                  end if;
               end;
            end loop;
            for Position in Before.Iterate loop
               if not After.Contains (Configurations.Value_Maps.Key (Position)) then
                  Result.Changed_Files.Append (Configurations.Value_Maps.Key (Position));
               end if;
            end loop;
         end;

         --  What it wrote that it may not is put back as it was, where it
         --  can be: the project is not left holding it.
         if not Isolated then
            declare
               Root_Agent : Agents.Agent;
               Read       : E.Error_Info;
               Kept       : Name_Lists.Vector;
            begin
               Agents.Read (Item, To_String (Result.Agent_Id), Root_Agent, Read);
               for Path of Result.Changed_Files loop
                  if E.Is_Ok (Read)
                    and then not Permissions.Allows (Root_Agent.Allowed, Permissions.Write_Source, Path)
                    and then not Permissions.Allows (Root_Agent.Allowed, Permissions.Write_Specs, Path)
                    and then Put_Back (Item, To_String (Result.Agent_Id), To_String (Place), Path,
                                       Before.Contains (Path))
                  then
                     Put_Back_Files.Append (Path);
                  else
                     Kept.Append (Path);
                  end if;
               end loop;
               Result.Changed_Files := Kept;
            end;
            Files.Remove_Tree (Kept_Directory (Item, To_String (Result.Agent_Id)));
         end if;
      end;

      --  The answer, kept, and the call ended.
      declare
         Kept : Results.Result :=
           (Kind       => (if Kind_Of_Task (Item, Task_Id) = "analysis" then Results.Analysis
                           else Results.Implementation),
            Producer   => Result.Agent_Id,
            Summary    => To_Unbounded_String ("answer to " & To_String (Result.Invocation_Id)),
            Payload    => Answer,
            Provenance => Result.Invocation_Id,
            others     => <>);
         Files_Text : Unbounded_String;
      begin
         Results.Add (Item, Change, Kept, Status);
         Last_Result := Kept.Id;
         Invocations.Finish
           (Item, Change, To_String (Result.Invocation_Id),
            (if E.Is_Ok (Ran) then Invocations.Completed
             elsif Interrupted (Ran) then Invocations.Cancelled
             else Invocations.Failed),
            Used,
            To_String (Kept.Id),
            (if E.Is_Ok (Ran) then "" else Why_Of (Ran)), Status);
         Annotate (Item, Change, Task_Id, "last_result", To_String (Kept.Id));
         for Path of Result.Changed_Files loop
            Append (Files_Text, (if Files_Text = Null_Unbounded_String then "" else ASCII.LF & "")
                                & Path);
         end loop;

         --  In the project itself, what an earlier attempt left changed is
         --  still this task's work: counted with this one's.
         if not Isolated then
            for Path of Earlier_Changed loop
               if not Result.Changed_Files.Contains (Path) then
                  Append (Files_Text, (if Files_Text = Null_Unbounded_String then ""
                                       else ASCII.LF & "") & Path);
               end if;
            end loop;
         end if;
         Annotate (Item, Change, Task_Id, "changed_files", To_String (Files_Text));
         Annotate (Item, Change, Task_Id, "undone_by", "");
         if not Result.Changed_Files.Is_Empty and then not Isolated then
            declare
               Event : Unbounded_String;
            begin
               Events.Emit (Item, Change, Events.Source_Changed, Task_Id,
                            To_String (Files_Text), Event, Status);
            end;
         end if;
      end;
      if E.Is_Error (Status) then
         return;
      end if;

      --  Ended elsewhere while it ran: what that did stands, and nothing of
      --  this run is added to a task that is no longer its.
      if Tasks.State_Of (Item, Task_Id) /= "running"
        or else Leases.Holder (Item, Lease_Of (Task_Id)) /= To_String (Result.Agent_Id)
      then
         Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
         Result.Reason := To_Unbounded_String
           (if Tasks.State_Of (Item, Task_Id) = "running"
            then "its hold on the task was taken over elsewhere while it ran -- its lease ran out first;"
                 & " nothing of this run is kept, and /work " & Task_Id & " runs it again"
            else "it was " & Tasks.State_Of (Item, Task_Id) & " elsewhere while it ran; nothing of this"
                 & " run is kept");
         return;
      end if;

      --  Stopped by whoever started it: the agent and what it made are
      --  cancelled, and the task is put aside, not failed -- nothing is
      --  known against it -- until it is accepted again.
      if Interrupted (Ran) and then Execution.Cancel_Asked_From_Outside then
         --  Cancelled from another terminal: cancelled, as asked.
         Stop_Children (Item, Change, To_String (Result.Agent_Id), "the task was cancelled");
         Conclude ("cancelled", "it was cancelled from another terminal", "cancelled");
         return;
      elsif Interrupted (Ran) then
         Stop_Children (Item, Change, To_String (Result.Agent_Id), "the work was interrupted");
         Conclude ("blocked", "you stopped its work (Ctrl-C) before it finished", "cancelled");
         return;
      elsif Out_Of_Time (Ran) then
         --  Out of time is not wrong work: the task is set aside, not
         --  failed, with what its agents made stopped.
         Stop_Children (Item, Change, To_String (Result.Agent_Id), "the work ran out of time");
         declare
            Defined : Records.Item;
            Read    : E.Error_Info;
         begin
            Tasks.Definition (Item, Task_Id, Defined, Read);
            declare
               Own : constant Boolean :=
                 Tasks.Kind_Policy (Item, Records.Get (Defined, "kind"), "max_seconds") /= "";
               --  Which limit it was, and how it is raised: a retry alone
               --  runs out the same way.
               Limit : constant String :=
                 (if Own then "task.max_seconds." & Records.Get (Defined, "kind")
                  elsif Scalar (Item, "agents.max_seconds") /= "" then "agents.max_seconds"
                  else "work.lease");
            begin
               Conclude ("blocked", "its work ran out of time:" & Natural'Image (Time_Allowed (Item, Task_Id))
                         & " s, as " & Limit & " allows; /reconfigure " & Limit & "=N gives it longer",
                         "failed");
            end;
         end;
         return;
      elsif E.Is_Error (Ran) and then Ran.Code = E.Framework_Agent_Failed then
         --  A crash is not wrong work: what it changed is kept to be
         --  looked at, and the task set aside.
         Keep_Work (Why_Of (Ran));
         return;
      elsif E.Is_Error (Ran) then
         --  A required helper that failed is why the work could not go
         --  on, whatever the agent did after: the task set aside as the
         --  policy says, the helper's failure named first.
         declare
            Child_Why : Unbounded_String;
         begin
            if not Agents.May_Complete (Item, To_String (Result.Agent_Id), Child_Why) then
               Conclude ((if Scalar (Item, "agents.on_child_failure") = "fail" then "failed" else "blocked"),
                         Child_Failure (To_String (Child_Why), Why_Of (Ran),
                                        Scalar (Item, "agents.on_child_failure")), "failed");
               return;
            end if;
         end;
         Conclude ("failed", Why_Of (Ran), "failed");
         return;
      end if;

      --  What it used is bounded as its children's is: past its budget the
      --  work is set aside, whatever it says it did.
      if Over_Budget then
         Conclude ("blocked", "it went over its token budget", "failed");
         return;
      end if;

      --  Its state is not the agent's to write, whatever it may; and what
      --  it wrote outside its permissions is named with that, every one.
      if not Tampered.Is_Empty then
         declare
            Named    : Unbounded_String;
            Read_Out : E.Error_Info;
         begin
            Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Read_Out);
            Keep_Proposals_Aside;
            for Path of Tampered loop
               Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                       & State_Directory & "/" & Path);
            end loop;
            Conclude ("failed", "it changed the project's state, which was put back: "
                      & To_String (Named)
                      & (if Beyond_Permissions = "" then ""
                         else "; and it changed files it may not write, which are still there:"
                              & " " & Beyond_Permissions & " -- take them out before /task complete"
                              & Sandbox_Said (Beyond_Permissions))
                      & (if Put_Back_Files.Is_Empty then ""
                         else "; and it changed files it may not write, which were put back as"
                              & " they were: " & Comma_Separated (Put_Back_Files)
                              & Sandbox_Said (Comma_Separated (Put_Back_Files))),
                      "failed");
         end;
         return;
      end if;

      --  What it changed must be what it may write, whatever it says.
      declare
         Held_Agent : Agents.Agent;
         Denied     : Unbounded_String;
      begin
         Agents.Read (Item, To_String (Result.Agent_Id), Held_Agent, Held);
         for Path of Result.Changed_Files loop
            if not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Source, Path)
              and then not Permissions.Allows (Held_Agent.Allowed, Permissions.Write_Specs, Path)
            then
               Append (Denied, (if Denied = Null_Unbounded_String then "" else ", ") & Path);
            end if;
         end loop;
         if Denied /= Null_Unbounded_String or else not Put_Back_Files.Is_Empty then
            declare
               Read_Out : E.Error_Info;
            begin
               Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Read_Out);
               Keep_Proposals_Aside;
            end;
            if Isolated then
               Workspaces.Abandon (Item, Change, To_String (Result.Workspace_Id), Held);
            end if;
            --  Refused by the session's sandbox alone, the work is not
            --  wrong: set aside until the sandbox lets it.
            Conclude ((if Sandbox_Said (Comma_Separated (Put_Back_Files)
                                        & (if Denied = Null_Unbounded_String then ""
                                           else "," & To_String (Denied))) /= ""
                       then "blocked" else "failed"),
                      "it changed files it may not write: "
                      & (if Put_Back_Files.Is_Empty then ""
                         else Comma_Separated (Put_Back_Files) & ", which were put back as they"
                              & " were" & (if Denied = Null_Unbounded_String then "" else "; "))
                      & (if Denied = Null_Unbounded_String then ""
                         else To_String (Denied)
                              & (if Isolated then ""
                                 else ", which are still in the project -- take them out before"
                                      & " /task complete"))
                      & Sandbox_Said (Comma_Separated (Put_Back_Files)
                                      & (if Denied = Null_Unbounded_String then ""
                                         else "," & To_String (Denied)))
                      & Rule_Said,
                      "failed");
            return;
         end if;
      end;

      Invocations.Hold (Invocations.Work_Claim, To_String (Answer), Said, Held);
      if E.Is_Error (Held) then
         Keep_Proposals_Aside;
         declare
            Why : constant String :=
              "its answer did not keep to the work contract: "
              & E.Text_Of (Held, "name") & ": " & E.Text_Of (Held, "detail")
              --  A call written out as text is no call: said, since the
              --  model meant one and nothing ran.
              & (if Index (Answer, """name""") > 0 and then Index (Answer, """arguments""") > 0
                 then "; the answer looks like a tool call written as text, which runs"
                      & " nothing -- a model that writes its calls so needs the model's own"
                      & " call format, or a larger model"
                 else "")
              & "; the answer is kept as "
              & To_String (Last_Result);
         begin
            --  Files it did change are work, whatever it said of them: kept
            --  to be looked at, not thrown away with the answer.
            if not Result.Changed_Files.Is_Empty then
               Keep_Work (Why);
            else
               Conclude ("failed", Why, "failed");
            end if;
         end;
         return;
      end if;
      Result.Claimed := To_Unbounded_String (Invocations.Claim (Said, "status"));
      Result.Summary := To_Unbounded_String (Own_Words (Invocations.Claim (Said, "summary")));

      --  A change it says it made and did not is a claim the files refute:
      --  whatever else it did, its answer cannot be taken.
      if To_String (Result.Claimed) = "done" then
         declare
            Missing       : Unbounded_String;
            Missing_Count : Natural := 0;
         begin
            for Line of Lines_Of (Replaced (Invocations.Claim (Said, "changed_files"))) loop
               declare
                  Named : constant String := Trim (Line);
                  Path  : constant String :=
                    (if Named'Length > 2 and then Named (Named'First .. Named'First + 1) = "./"
                     then Named (Named'First + 2 .. Named'Last) else Named);
               begin
                  --  A file there, written as it was, is no false claim:
                  --  only one that is not there at all is.
                  if Path not in "" | "-" | "none" and then not Result.Changed_Files.Contains (Path)
                    and then not (not Isolated and then Earlier_Changed.Contains (Path))
                    and then not Ada.Directories.Exists (Hostkit.Fs.Join (To_String (Place), Path))
                  then
                     Missing_Count := Missing_Count + 1;
                     if Missing_Count <= 10 then
                        Append (Missing, (if Missing = Null_Unbounded_String then "" else ", ") & Path);
                     end if;
                  end if;
               end;
            end loop;
            if Missing_Count > 10 then
               Append (Missing, " and" & Natural'Image (Missing_Count - 10) & " more");
            end if;
            if Missing /= Null_Unbounded_String then
               Keep_Proposals_Aside;
               --  Kept as an issue, as what an attempt reports is: found
               --  again by /result beside the rest.
               declare
                  Claimed : Results.Result :=
                    (Kind       => Results.Diagnostic,
                     Producer   => Result.Agent_Id,
                     Summary    => To_Unbounded_String
                                     (Task_Id & " failed: its answer says it changed " & To_String (Missing)
                                      & ", which is not there"),
                     Payload    => To_Unbounded_String (Invocations.Claim (Said, "changed_files")),
                     Provenance => Result.Invocation_Id,
                     others     => <>);
                  Held : E.Error_Info;
               begin
                  Results.Add (Item, Change, Claimed, Held);
               end;
               Conclude ("failed", "it says it changed " & To_String (Missing)
                         & ", which is not there", "failed");
               return;
            end if;
         end;
      end if;

      --  An agent does not enlarge its task. Work it found beyond it
      --  becomes candidate tasks, one a line, where it may propose them --
      --  a person still accepts them -- and is kept as an issue where it may
      --  not; issues are kept either way.
      declare
         Proposed  : constant Name_Lists.Vector :=
           Lines_Of (Invocations.Claim (Said, "proposed_tasks"));
         Parts     : constant Name_Lists.Vector :=
           Lines_Of (Invocations.Claim (Said, "parts"));
         Held_Root : Agents.Agent;
         Defined   : Records.Item;
         May_Propose : Boolean;
         Kept_Back : Unbounded_String;

         --  Whether the parts it asks for are children: only where its agent
         --  may create them; otherwise they are proposals of their own.
         Parts_Are_Children : Boolean := True;

         --  What this answer has made so far, by title in lower case, and
         --  as what.
         Made_Titles : Name_Lists.Vector;
         Made_Ids    : Name_Lists.Vector;

         --  A task of that title there already: this one, or one not
         --  ended. What is proposed twice is made once.
         --  A task of that title there already, which this answer's line
         --  is: one made from this same answer; for a proposal, one not
         --  ended; for a part, one of this task's own parts, done or not.
         --  Never this task itself.
         --  A task named as what it is: a part says whose.
         function Described (Other : String) return String is
            Its  : Records.Item;
            Read : E.Error_Info;
         begin
            Tasks.Definition (Item, Other, Its, Read);
            return Other
              & (if E.Is_Ok (Read) and then Records.Get (Its, "parent") /= ""
                 then " (a part of " & Records.Get (Its, "parent") & ")" else "");
         end Described;

         function Same_Title (Title : String; Part : Boolean := False) return String is
            Lower : constant String := Ada.Characters.Handling.To_Lower (Title);
         begin
            for Made in 1 .. Natural (Made_Titles.Length) loop
               if Made_Titles (Made) = Lower then
                  return Made_Ids (Made);
               end if;
            end loop;
            --  A proposal of this very task is this task.
            if not Part then
               declare
                  Its  : Records.Item;
                  Read : E.Error_Info;
               begin
                  Tasks.Definition (Item, Task_Id, Its, Read);
                  if E.Is_Ok (Read)
                    and then Ada.Characters.Handling.To_Lower (Records.Get (Its, "title")) = Lower
                  then
                     return Task_Id;
                  end if;
               end;
            end if;
            --  For a proposal, a task of any state: one a person rejected
            --  or cancelled is not proposed again.
            for Other of Tasks.List (Item) loop
               if Other /= Task_Id then
                  declare
                     Its  : Records.Item;
                     Read : E.Error_Info;
                  begin
                     Tasks.Definition (Item, Other, Its, Read);
                     if E.Is_Ok (Read)
                       and then Ada.Characters.Handling.To_Lower (Records.Get (Its, "title")) = Lower
                       and then (not Part or else Records.Get (Its, "parent") = Task_Id)
                       and then (not Part
                                 or else Tasks.State_Of (Item, Other) not in "cancelled" | "rejected")
                     then
                        return Other;
                     end if;
                  end;
               end if;
            end loop;
            return "";
         end Same_Title;

      begin
         Agents.Read (Item, To_String (Result.Agent_Id), Held_Root, Held);
         May_Propose := E.Is_Ok (Held)
           and then Permissions.Allows (Held_Root.Allowed, Permissions.Propose_Tasks);
         Tasks.Definition (Item, Task_Id, Defined, Held);
         for Line of Proposed loop
            declare
               --  TITLE, then as it may say, ; kind=K ; component=C ;
               --  depends_on=TASK -- a candidate's own, not assumed from this
               --  task; it is proposal data until a person accepts it.
               Parts_Of : constant Name_Lists.Vector := Split_On (Line, ';');
               Title  : constant String :=
                 (if Parts_Of.Is_Empty then "" else Trim (Parts_Of.First_Element));
               Fields : Tasks.Field_Map;
               Made   : Unbounded_String;

               function Said_Of (Name, Default : String) return String is
               begin
                  for Part of Parts_Of loop
                     declare
                        Bare  : constant String := Trim (Part);
                        Equal : constant Natural := Ada.Strings.Fixed.Index (Bare, "=");
                     begin
                        if Equal > Bare'First and then Trim (Bare (Bare'First .. Equal - 1)) = Name
                        then
                           return Trim (Bare (Equal + 1 .. Bare'Last));
                        end if;
                     end;
                  end loop;
                  return Default;
               end Said_Of;
            begin
               if Title = "" or else Title = "-" then
                  null;
               elsif May_Propose and then Made_Titles.Contains
                                            (Ada.Characters.Handling.To_Lower (Title))
               then
                  --  Said twice in this answer: made once, and said so.
                  if not Result.Twice.Contains (Title) then
                     Result.Twice.Append (Title);
                  end if;
               elsif May_Propose and then Same_Title (Title) /= "" then
                  declare
                     Other : constant String := Same_Title (Title);
                     State : constant String := Tasks.State_Of (Item, Other);
                     Said  : constant String :=
                       Title & ": "
                       & (if Other = Task_Id then "it is this task"
                          elsif State in "rejected" | "cancelled"
                          then "it is " & Other & ", which was " & State
                          else "it is " & Described (Other) & " already");
                  begin
                     --  Said once, however often the answer says it.
                     if not Result.Kept_Back.Contains (Said) then
                        Result.Kept_Back.Append (Said);
                     end if;
                  end;
               elsif May_Propose then
                  Fields.Include ("title", Title);
                  Fields.Include ("kind", Said_Of ("kind", Records.Get (Defined, "kind")));
                  if Said_Of ("component", Records.Get (Defined, "component")) /= "" then
                     Fields.Include
                       ("component", Said_Of ("component", Records.Get (Defined, "component")));
                  end if;
                  if Said_Of ("depends_on", "") /= "" then
                     Fields.Include ("depends_on", Said_Of ("depends_on", ""));
                  end if;
                  Fields.Include ("notes", "proposed working on " & Task_Id);
                  --  Made by an agent, from the task it was working on.
                  Tasks.Create
                    (Item, Change, Fields, "agent " & To_String (Result.Agent_Id), Task_Id,
                     Made, Held);
                  if E.Is_Ok (Held) then
                     Result.Proposed.Append (To_String (Made));
                     Made_Titles.Append (Ada.Characters.Handling.To_Lower (Title));
                     Made_Ids.Append (To_String (Made));
                  else
                     Append (Kept_Back, ASCII.LF & "asked for: " & Trim (Line));
                     Result.Kept_Back.Append (Title & ": " & Why_Of (Held));
                  end if;
               --  Kept as the answer said it, kind and component with it, so
               --  that it can be made by hand as it was meant; said once.
               elsif not Result.Kept_Back.Contains
                           (Trim (Line) & ": this task's agent may not propose tasks")
               then
                  Append (Kept_Back, ASCII.LF & "asked for: " & Trim (Line));
                  Result.Kept_Back.Append (Trim (Line) & ": this task's agent may not propose tasks");
               end if;
            end;
         end loop;

         --  The parts it would split its task into: proposal data, not a
         --  split -- candidate children, which a person accepts or not, and
         --  the task itself is left as the answer leaves it.
         --  A split is held to the limits children are: no more parts than
         --  create_children's max_children, and none below its max_depth.
         declare
            --  Parts are proposals, which propose_tasks allows; how many,
            --  and how deep, create_children bounds -- the agent's, or where
            --  it has none, the project's.
            Own   : constant Permissions.Grant := Held_Root.Allowed (Permissions.Create_Children);
            Limit : constant Permissions.Grant :=
              (if Own.Granted then Own
               else Permissions.Effective (Item, "", "", Within_Sandbox => False)
                      (Permissions.Create_Children));
            Depth : Natural := 0;
            Up    : Unbounded_String := To_Unbounded_String (Task_Id);
         begin
            loop
               declare
                  Defined_Up : Records.Item;
                  Read_Up    : E.Error_Info;
               begin
                  Tasks.Definition (Item, To_String (Up), Defined_Up, Read_Up);
                  exit when E.Is_Error (Read_Up) or else Records.Get (Defined_Up, "parent") = ""
                    or else Depth > 64;
                  Up := To_Unbounded_String (Records.Get (Defined_Up, "parent"));
                  Depth := Depth + 1;
               end;
            end loop;
            Parts_Are_Children := Own.Granted;
            --  Bounded as helpers are too: the project's agents.max_depth
            --  and agents.max_children hold for parts as for children.
            declare
               Bounds   : constant Agents.Limits := Agents.Limits_Of (Item);
               Deepest  : constant Natural := Natural'Min (Limit.Max_Depth, Bounds.Max_Depth);
               Most     : constant Natural := Natural'Min (Limit.Max_Children, Bounds.Max_Children);
            begin
               Split_Room := (if not Limit.Granted then 0
                              elsif Depth + 1 > Deepest then 0
                              else Most);
               Split_Why := To_Unbounded_String
                 (if not Limit.Granted
                  then "the project grants no create_children, which bounds parts"
                  elsif Depth + 1 > Deepest
                  then "a part here would be" & Natural'Image (Depth + 1) & " below the task it came"
                       & " from, past "
                       & (if Bounds.Max_Depth < Limit.Max_Depth then "agents.max_depth"
                          else "create_children's max_depth")
                       & Natural'Image (Deepest)
                  else "past " & (if Bounds.Max_Children < Limit.Max_Children then "agents.max_children"
                                  else "create_children's max_children")
                       & Natural'Image (Most));
            end;
         end;
         for Line of Parts loop
            declare
               Title  : constant String := Trim (Line);
               Fields : Tasks.Field_Map;
               Made   : Unbounded_String;
            begin
               if Title = "" or else Title = "-" then
                  null;

               --  Its agent may not make children: the part is a proposal
               --  of its own, with no parent to wait for it.
               elsif May_Propose and then not Parts_Are_Children then
                  if Made_Titles.Contains (Ada.Characters.Handling.To_Lower (Title)) then
                     null;
                  elsif Same_Title (Title) /= "" then
                     Result.Kept_Back.Append (Title & ": it is " & Described (Same_Title (Title))
                                              & " already");
                  else
                     Fields.Include ("title", Title);
                     Fields.Include ("kind", Records.Get (Defined, "kind"));
                     if Records.Get (Defined, "component") /= "" then
                        Fields.Include ("component", Records.Get (Defined, "component"));
                     end if;
                     Fields.Include ("notes", "proposed as a part of " & Task_Id
                                     & ", whose agent may not make children");
                     Tasks.Create
                       (Item, Change, Fields, "agent " & To_String (Result.Agent_Id), Task_Id,
                        Made, Held);
                     if E.Is_Ok (Held) then
                        Result.Proposed.Append (To_String (Made));
                        Parts_Proposed.Append (To_String (Made));
                        Made_Titles.Append (Ada.Characters.Handling.To_Lower (Title));
                        Made_Ids.Append (To_String (Made));
                     else
                        Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
                        Result.Kept_Back.Append (Title & ": " & Why_Of (Held));
                     end if;
                  end if;
               elsif May_Propose and then Same_Title (Title, Part => True) = ""
                 and then Natural (Split_Into.Length) >= Split_Room
               then
                  Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
                  Result.Kept_Back.Append (Title & ": " & To_String (Split_Why));

               --  A part there already -- from an earlier split, or twice in
               --  this answer -- is that part, not another.
               elsif May_Propose and then Same_Title (Title, Part => True) /= "" then
                  if not Split_Into.Contains (Same_Title (Title, Part => True)) then
                     Split_Into.Append (Same_Title (Title, Part => True));
                  end if;
               elsif May_Propose then
                  Fields.Include ("title", Title);
                  Fields.Include ("kind", Records.Get (Defined, "kind"));
                  Fields.Include ("parent", Task_Id);
                  if Records.Get (Defined, "component") /= "" then
                     Fields.Include ("component", Records.Get (Defined, "component"));
                  end if;
                  Tasks.Create
                    (Item, Change, Fields, "agent " & To_String (Result.Agent_Id), Task_Id,
                     Made, Held);
                  if E.Is_Ok (Held) then
                     Result.Proposed.Append (To_String (Made));
                     Split_Into.Append (To_String (Made));
                     Made_Titles.Append (Ada.Characters.Handling.To_Lower (Title));
                     Made_Ids.Append (To_String (Made));
                  else
                     Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
                     Result.Kept_Back.Append (Title & ": " & Why_Of (Held));
                  end if;
               else
                  if not Result.Kept_Back.Contains
                           (Title & ": this task's agent may not propose tasks or parts")
                  then
                     Append (Kept_Back, ASCII.LF & "part asked for: " & Title);
                     Result.Kept_Back.Append (Title & ": this task's agent may not propose tasks or"
                                              & " parts");
                  end if;
               end if;
            end;
         end loop;

         --  Decisions and specifications it proposes: entries in their
         --  registers, proposed or candidate, that govern nothing until a
         --  person accepts them.
         for Register in Intent.Specification .. Intent.Decision loop
            if Register /= Intent.Requirement then
               for Line of Lines_Of
                 (Invocations.Claim
                    (Said, (if Register = Intent.Decision then "decisions" else "specifications")))
               loop
                  declare
                     Text  : constant String := Trim (Line);
                     Stop  : constant Natural := Ada.Strings.Fixed.Index (Text, ". ");
                     Title : constant String :=
                       (if Stop in Text'First .. Text'First + 70 then Text (Text'First .. Stop)
                        elsif Text'Length > 70 then Text (Text'First .. Text'First + 69)
                        else Text);
                     Made  : Unbounded_String;
                  begin
                     if Text = "" or else Text = "-" then
                        null;
                     elsif May_Propose then
                        Intent.Propose
                          (Item, Change, Register, "", Title, Text, "",
                           To_String (Result.Agent_Id), "", "project", Made, Held);
                        if E.Is_Ok (Held) then
                           Result.Proposed.Append (To_String (Made));
                        else
                           Append (Kept_Back, ASCII.LF & "asked for: " & Text);
                        end if;
                     else
                        Append (Kept_Back, ASCII.LF & "asked for: " & Text);
                     end if;
                  end;
               end loop;
            end if;
         end loop;

         --  Tasks it says this one should wait for: said, and kept, never
         --  asserted -- a person makes the dependency with task depend.
         for Line of Lines_Of (Invocations.Claim (Said, "waits_for")) loop
            if Trim (Line) not in "" | "-" then
               Append (Kept_Back, ASCII.LF & "waits for: " & Trim (Line));
               Result.Waits_For.Append (Trim (Line));
            end if;
         end loop;

         declare
            function Not_Proposed return String is
               Why : Unbounded_String;
            begin
               for Line of Result.Kept_Back loop
                  Append (Why, ASCII.LF & "not proposed: " & Line);
               end loop;
               return To_String (Why);
            end Not_Proposed;

            Found : constant String :=
              Invocations.Claim (Said, "issues") & To_String (Kept_Back) & Not_Proposed;
            --  An issue, not a proposal: what it may not propose is
            --  returned to be seen, not kept as work to be accepted.
            Issue : Results.Result :=
              (Kind       => Results.Diagnostic,
               Producer   => Result.Agent_Id,
               Summary    => To_Unbounded_String ("issues found working on " & Task_Id),
               Payload    => To_Unbounded_String (Found),
               Provenance => Result.Invocation_Id,
               others     => <>);
         begin
            if Trim (Found) /= "" then
               Results.Add (Item, Change, Issue, Status);
               if E.Is_Ok (Status) then
                  --  Found again by its identifier: in the report, and in
                  --  the task's audit.
                  Result.Issue_Id := Issue.Id;
                  Annotate (Item, Change, Task_Id, "issues", To_String (Issue.Id));
               end if;
            end if;
         end;
         if E.Is_Ok (Status) then
            Stores.Commit (Item, Change, Status);
         end if;
         if E.Is_Error (Status) then
            return;
         end if;
      end;

      --  Not done, it says, but asks for its work to be checked: the
      --  evidence is taken and kept, and the task still goes where the
      --  answer says.
      if To_String (Result.Claimed) /= "done"
        and then Invocations.Claim (Said, "verify") = "yes"
      then
         declare
            Chosen : constant Verification.Choice :=
              Verification.Choose (Item, Task_Id, Result.Changed_Files);
            Passed : Boolean;
         begin
            if To_String (Chosen.Profile) /= "" then
               Verification.Run_Profile
                 (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed,
                  Held, Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For));
               if E.Is_Ok (Held) then
                  Stores.Commit (Item, Change, Status);
               else
                  Change := Stores.No_Changes;
                  Result.Evidence_Id := Null_Unbounded_String;
               end if;
            end if;
         end;
      end if;

      if To_String (Result.Claimed) in "blocked" | "issue" and then not Split_Into.Is_Empty
        and then (for all Part of Split_Into => Tasks.State_Of (Item, Part) = "complete")
      then
         --  Split again into parts all done: nothing is left to wait for,
         --  and waiting would only bring it back here.
         Conclude ("blocked", "its parts " & Comma_Separated (Split_Into) & " are complete and it"
                   & " asked for them again; /task complete " & Task_Id & " takes it as done",
                   "completed");
         return;
      elsif To_String (Result.Claimed) in "blocked" | "issue" then
         --  Split into parts, it waits for them: once they are accepted and
         --  done it goes back to work on its own, and not before.
         Conclude ("blocked",
                   (if Split_Into.Is_Empty then To_String (Result.Summary)
                    else Tasks.Waiting_For (Split_Into) & " (" & To_String (Result.Summary) & ")")
                   & (if Parts_Proposed.Is_Empty then ""
                      else "; its agent may not make children, so the parts it asked for are"
                           & " proposals of their own (" & Comma_Separated (Parts_Proposed)
                           & "): /task split " & Task_Id & " makes parts of it by hand"),
                   "completed");
         return;
      elsif To_String (Result.Claimed) = "failed" then
         Conclude ("failed", To_String (Result.Summary), "completed");
         return;
      end if;

      --  Done, it says -- but not while a child it needed is going or
      --  failed.
      --  Where the policy lets a parent go on another way, it may -- once
      --  it has said how, which is kept beside the failure it went past.
      declare
         Why     : Unbounded_String;
         Still   : Unbounded_String;
         Instead : constant String := Trim (Invocations.Claim (Said, "instead"));
         Going_On : constant Boolean :=
           Scalar (Item, "agents.on_child_failure") = "continue" and then Instead not in "" | "-";
      begin
         if not Agents.May_Complete (Item, To_String (Result.Agent_Id), Why) then
            if not Going_On
              or else not Agents.May_Complete
                            (Item, To_String (Result.Agent_Id), Still, Past_Failures => True)
            then
               if Going_On then
                  Why := Still;
               elsif Scalar (Item, "agents.on_child_failure") = "continue" then
                  --  continue set, and no instead: said why it did not go on.
                  Append (Why, " (agents.on_child_failure is continue, which goes on only when the agent says"
                               & " instead: how it did the failed part; it said nothing of it)");
               end if;
               Conclude ((if Scalar (Item, "agents.on_child_failure") = "fail" then "failed"
                          else "blocked"),
                         To_String (Why), "completed");
               return;
            end if;
            declare
               Kept : Results.Result :=
                 (Kind       => Results.Diagnostic,
                  Producer   => Result.Agent_Id,
                  Summary    => To_Unbounded_String
                                  ("went on past a failed required child: " & To_String (Why)),
                  Payload    => To_Unbounded_String (Instead),
                  Provenance => Result.Invocation_Id,
                  others     => <>);
            begin
               Results.Add (Item, Change, Kept, Status);
               if E.Is_Ok (Status) then
                  Stores.Commit (Item, Change, Status);
               end if;
               if E.Is_Error (Status) then
                  return;
               end if;
            end;
         end if;
      end;

      --  The routine the project gives the harness, not the model: its
      --  generators, then its formatter, each a profile named by scalar
      --  stage.generate and stage.format, run where the work was written.
      --  What they change is the task's change; one that does not pass
      --  sets the task aside with its evidence.
      for Stage of Name_Lists.Vector'(["generate", "format"]) loop
         declare
            Profile  : constant String := Scalar (Item, "stage." & Stage);
            Evidence : Unbounded_String;
            Passed   : Boolean;
            Ran      : E.Error_Info;
         begin
            if Profile /= "" then
               declare
                  Before : constant Configurations.Value_Maps.Map :=
                    Snapshot (To_String (Place), Repository.Roots_Of (Item));
               begin
                  Verification.Run_Profile
                    (Item, Change, Profile, Task_Id, Evidence, Passed, Ran,
                     Workspace => (if Isolated then To_String (Place) else ""));
                  if E.Is_Ok (Ran) then
                     Stores.Commit (Item, Change, Ran);
                  end if;
                  if E.Is_Error (Ran) or else not Passed then
                     Conclude ("blocked",
                               "its " & Stage & " stage did not pass"
                               & (if Evidence = Null_Unbounded_String then ": " & Why_Of (Ran)
                                  else " (" & To_String (Evidence) & ")"),
                               "completed");
                     return;
                  end if;
                  declare
                     After : constant Configurations.Value_Maps.Map :=
                       Snapshot (To_String (Place), Repository.Roots_Of (Item));
                  begin
                     for Position in After.Iterate loop
                        declare
                           Path : constant String := Configurations.Value_Maps.Key (Position);
                        begin
                           if (not Before.Contains (Path)
                               or else Before (Path) /= Configurations.Value_Maps.Element (Position))
                             and then not Result.Changed_Files.Contains (Path)
                           then
                              Result.Changed_Files.Append (Path);
                           end if;
                        end;
                     end loop;
                     declare
                        Files_Text : Unbounded_String;
                     begin
                        for Path of Result.Changed_Files loop
                           Append (Files_Text, (if Files_Text = Null_Unbounded_String then ""
                                                else [1 => ASCII.LF]) & Path);
                        end loop;
                        Annotate (Item, Change, Task_Id, "changed_files", To_String (Files_Text));
                        Stores.Commit (Item, Change, Status);
                     end;
                  end;
               end;
            end if;
         end;
      end loop;

      --  Done, it says. The harness decides -- held again for as long as
      --  that may take.
      Hold (Lease_Seconds (Item));
      if E.Is_Ok (Status) then
         Tasks.Move (Item, Change, Task_Id, "verification", "", Status => Status);
      end if;
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;

      --  Work written apart is taken in before it is verified: by the
      --  harness when the configuration says so, otherwise left waiting for
      --  whoever has the right.
      if Isolated then
         --  Nothing changed where its kind must change something: there is
         --  nothing to take in, and it is blocked now, as it is where work
         --  is written in the project itself -- not after an integration.
         if Result.Changed_Files.Is_Empty
           and then Tasks.Gate_Names (Item, Kind_Of_Task (Item, Task_Id))
                      .Contains ("implementation_present")
         then
            declare
               Given_Up : E.Error_Info;
            begin
               Workspaces.Abandon (Item, Change, To_String (Result.Workspace_Id), Given_Up);
               Conclude ("blocked", "its work changed no file, so there is nothing in "
                         & To_String (Result.Workspace_Id) & " to take in", "completed");
            end;
            return;
         end if;
         --  Checked where it was written, before anyone takes it in: the
         --  evidence says how it stands, and only work that passed is taken
         --  in on its own.
         declare
            Chosen : constant Verification.Choice :=
              Verification.Choose (Item, Task_Id, Result.Changed_Files);
            Space  : Workspaces.Workspace;
            Passed : Boolean := True;
            Said   : Unbounded_String;
         begin
            Workspaces.Read (Item, To_String (Result.Workspace_Id), Space, Held);
            if E.Is_Ok (Held) and then To_String (Chosen.Profile) /= "" then
               Verification.Run_Profile
                 (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed,
                  Held, Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For),
                  Workspace => To_String (Space.Path));
               if E.Is_Ok (Held) then
                  --  Its evidence, as the task's audit reads it.
                  Annotate (Item, Change, Task_Id, "current_verification",
                            To_String (Result.Evidence_Id));
                  Stores.Commit (Item, Change, Held);
               else
                  Change := Stores.No_Changes;
                  Passed := False;
               end if;
               Said := To_Unbounded_String
                 ("; checked in it: " & (if Passed then "passed" else "did not pass")
                  & (if Result.Evidence_Id = Null_Unbounded_String then ""
                     else " (" & To_String (Result.Evidence_Id) & ")"));
            end if;
            --  Work that does not pass where it was written is not taken in
            --  -- and not thrown away either: what nearly does is what is
            --  put right. It waits in its workspace, with what failed.
            if not Passed and then Result.Evidence_Id /= Null_Unbounded_String then
               declare
                  Evidence : constant String := To_String (Result.Evidence_Id);
                  Space_Id : constant String := To_String (Result.Workspace_Id);
               begin
                  Conclude ("", Evidence & " did not pass in " & Space_Id
                            & ", so nothing was taken in"
                            & First_Diagnostics (Item, Evidence)
                            & "; the work is kept there -- put it right in " & Space_Id
                            & " and /task integrate " & Task_Id & " checks it again, or /task integrate "
                            & Task_Id & " discard gives it up and does the task afresh", "completed");
               end;
               return;
            --  Nothing written, nothing to take in: it goes on at once, as
            --  an analysis's answer is all its work.
            elsif Work_Setting (Item, "integrate") /= "automatic"
              and then not (Ada.Strings.Fixed.Index (May_Do (Item, Task_Id), "write") = 0
                            and then Workspaces.Changes (Item, To_String (Result.Workspace_Id)).Is_Empty)
            then
               --  What it did not report is kept, for the taking in to say.
               if Unreported_Note /= "" then
                  Annotate (Item, Change, Task_Id, "unreported_files",
                            Unreported_Note (Unreported_Note'First + 41 .. Unreported_Note'Last));
               end if;
               Conclude ("", To_String (Result.Workspace_Id) & " waits to be taken in"
                         & To_String (Said)
                         & (if Unreported_Note = "" then "" else "; " & Unreported_Note),
                         "completed");
               return;
            elsif not Passed then
               Conclude ("", To_String (Result.Workspace_Id) & " waits to be taken in"
                         & To_String (Said) & ", so it is not taken in on its own", "completed");
               return;
            end if;
         end;

         --  The harness takes it in for the agent only when the agent may
         --  ask for that.
         declare
            Held_Root : Agents.Agent;
         begin
            Agents.Read (Item, To_String (Result.Agent_Id), Held_Root, Held);
            if (E.Is_Error (Held)
                or else not Permissions.Allows (Held_Root.Allowed, Permissions.Request_Integration))
              and then not (Ada.Strings.Fixed.Index (May_Do (Item, Task_Id), "write") = 0
                            and then Workspaces.Changes (Item, To_String (Result.Workspace_Id)).Is_Empty)
            then
               Conclude ("", To_String (Result.Workspace_Id) & " waits to be taken in: its"
                         & " agent may not request integration", "completed");
               return;
            end if;
         end;
         declare
            Taken : Name_Lists.Vector;
         begin
            Workspaces.Integrate
              (Item, Change, To_String (Result.Workspace_Id), True, Taken, Held);
            if E.Is_Error (Held) then
               Change := Stores.No_Changes;
               Conclude ("blocked", "its workspace cannot be taken in: "
                         & Why_Of (Held), "completed");
               return;
            end if;
            Report_Integration
              (Item, Change, To_String (Result.Workspace_Id), Task_Id, Taken, Status);
            if E.Is_Ok (Status) then
               Stores.Commit (Item, Change, Status);
            end if;
            if E.Is_Error (Status) then
               return;
            end if;
            Workspaces.Release (Item, To_String (Result.Workspace_Id));
         end;
      end if;

      --  Verified as widely as what it changed reaches, by the project's
      --  policy: a model has no say in it.
      declare
         Chosen  : constant Verification.Choice :=
           Verification.Choose (Item, Task_Id, Result.Changed_Files);
         Profile : constant String := To_String (Chosen.Profile);
         Passed  : Boolean := False;
      begin
         Result.Scope := Chosen.Scope;
         Result.Scope_Reason := Chosen.Reason;
         if Profile = "" then
            Conclude ("blocked", "no verification profile applies to it", "completed");
            return;
         end if;
         Verification.Run_Profile
           (Item, Change, Profile, Task_Id, Result.Evidence_Id, Passed, Status,
            Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For));
         if E.Is_Error (Status) then
            Held := Status;
            Status := E.Success;
            Result.Evidence_Id := Null_Unbounded_String;
            Change := Stores.No_Changes;
            Conclude ("blocked", (if Interrupted (Held) then "its verification was cancelled"
                                  else "its verification could not run: " & Why_Of (Held)),
                      "completed");
            return;
         end if;
         Annotate (Item, Change, Task_Id, "current_verification",
                   To_String (Result.Evidence_Id));
         Stores.Commit (Item, Change, Status);
         if E.Is_Error (Status) then
            return;
         end if;

         if not Passed then
            Conclude ("failed", To_String (Result.Evidence_Id) & " did not pass"
                      & First_Diagnostics (Item, To_String (Result.Evidence_Id)),
                      "completed");
            return;
         end if;

         Verification.Complete_Task (Item, Change, Task_Id, Held);
         if E.Is_Error (Held) then
            Change := Stores.No_Changes;
            declare
               Failing : Unbounded_String;
               Judged  : constant Verification.Gate_List := Verification.Gates (Item, Task_Id);
            begin
               for Index in 1 .. Verification.Length (Judged) loop
                  declare
                     Next : constant Verification.Gate := Verification.Element (Judged, Index);
                  begin
                     if not Next.Passed then
                        Append (Failing, (if Failing = Null_Unbounded_String then "" else "; ")
                                         & To_String (Next.Name) & ": "
                                         & To_String (Next.Reason));
                     end if;
                  end;
               end loop;
               Conclude ("blocked", "its gates did not pass: " & To_String (Failing),
                         "completed");
            end;
            return;
         end if;
         --  Committed before the requirements are judged: a requirement is
         --  judged by its tasks as the store holds them, and until then this
         --  one is still in verification.
         Stores.Commit (Item, Change, Status);
         if E.Is_Ok (Status) then
            Verification.Reevaluate_Requirements (Item, Change, Result.Requirements, Status);
         end if;
         if E.Is_Ok (Status) then
            --  Done, and with files changed it did not say it changed, or
            --  files it said it changed and did not: said, as what a person
            --  looks at before trusting its report.
            Conclude ("", Unreported_Note
                      & (if Unreported_Note /= "" and then Overclaimed_Note /= "" then "; " else "")
                      & Overclaimed_Note, "completed");
         end if;
      end;
   end Execute_Work;

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
   is
      Change : Stores.Transaction;
      Id     : constant String := Workspaces.Active_For (Item, Task_Id);
      Taken  : Name_Lists.Vector;
      Passed : Boolean := False;
      Held   : E.Error_Info;
   begin
      Result := (Task_Id => To_Unbounded_String (Task_Id), others => <>);

      --  Work is taken in for a task that waits for it -- in verification,
      --  its agent done -- and not for one set aside or still being worked.
      if Tasks.State_Of (Item, Task_Id) /= "verification" then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Task_Id);
         E.Add_Text (Status, "value", Tasks.State_Of (Item, Task_Id));
         E.Add_Text (Status, "expected", "being taken in");
         declare
            State_Value : Records.Item;
            Read        : E.Error_Info;
            Had         : Unbounded_String;

            --  How a workspace it had ended: integrated, abandoned; "".
            function Space_Status return String is
               Space_Value : Records.Item;
               Space_Read  : E.Error_Info;
            begin
               if Had = Null_Unbounded_String then
                  return "";
               end if;
               Stores.Read (Item, Workspaces_Area, To_String (Had), Space_Value, Space_Read);
               return (if E.Is_Error (Space_Read) then "" else Records.Get (Space_Value, "status"));
            end Space_Status;
         begin
            Stores.Read (Item, Tasks_Area, Task_Id & ".state", State_Value, Read);
            Had := To_Unbounded_String (Records.Get (State_Value, "current_workspace"));
            E.Add_Text
              (Status, "detail",
               (if Id /= "" then "only work that waits to be taken in is taken in"
                elsif Had = Null_Unbounded_String
                  and then Tasks.State_Of (Item, Task_Id) in "candidate" | "accepted" | "ready"
                  and then Records.Get (State_Value, "generation") in "" | "0"
                then "it has not been worked on yet, so nothing of it waits to be taken in; /work " & Task_Id
                     & " does it"
                elsif Had = Null_Unbounded_String
                  and then Tasks.State_Of (Item, Task_Id) in "candidate" | "accepted" | "ready"
                then "no work of it waits to be taken in: what its last attempt wrote is in the project"
                     & " itself; /work " & Task_Id & " does it again"
                elsif Had = Null_Unbounded_String
                then "it has no workspace -- it wrote in the project itself -- so there is nothing"
                     & " to take in"
                elsif Tasks.State_Of (Item, Task_Id) = "complete" and then Space_Status = "abandoned"
                then "it is complete, and " & To_String (Had) & " was given up: nothing of it waits to be"
                     & " taken in"
                elsif Tasks.State_Of (Item, Task_Id) = "complete"
                then To_String (Had) & " was taken in already"
                elsif Tasks.State_Of (Item, Task_Id) = "cancelled"
                then To_String (Had) & " was given up when it was cancelled; /task reopen " & Task_Id
                     & " makes it ready again"
                elsif Tasks.State_Of (Item, Task_Id) = "blocked"
                  and then not Tasks.Children (Item, Task_Id).Is_Empty
                then To_String (Had) & " was given up when it split into parts; it goes on once they"
                     & " are done"
                --  Ready to be worked again: no work of it waits, and /work
                --  is what makes some.
                elsif Tasks.State_Of (Item, Task_Id) = "accepted"
                then "no work of it waits to be taken in -- " & To_String (Had) & " went with its last"
                     & " attempt; /work " & Task_Id & " does it"
                else To_String (Had) & " was given up when it " & Tasks.State_Of (Item, Task_Id)
                     & "; /task accept " & Task_Id & " does its work again"));
         end;
         return;
      end if;
      if Id = "" then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", "a workspace of " & Task_Id);
         return;
      end if;
      Result.Workspace_Id := To_Unbounded_String (Id);

      --  Settled by a person: checked where it was settled before any of it
      --  reaches the project, and left there when it does not pass.
      if Text_Resolved then
         declare
            Chosen : constant Verification.Choice :=
              Verification.Choose (Item, Task_Id, Workspaces.Changes (Item, Id));
            Space  : Workspaces.Workspace;
         begin
            Workspaces.Read (Item, Id, Space, Held);
            if E.Is_Ok (Held) and then To_String (Chosen.Profile) /= "" then
               Verification.Run_Profile
                 (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed,
                  Held, Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For),
                  Workspace => To_String (Space.Path));
               if E.Is_Ok (Held) then
                  Stores.Commit (Item, Change, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  if not Passed then
                     Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
                     Result.Reason := To_Unbounded_String
                       ("it did not pass in " & Id & ", so nothing was taken in: "
                        & To_String (Result.Evidence_Id) & " did not pass"
                        & First_Diagnostics (Item, To_String (Result.Evidence_Id)));
                     Status := E.Success;
                     return;
                  end if;
               else
                  Change := Stores.No_Changes;
               end if;
            end if;
         end;
         Change := Stores.No_Changes;
      end if;

      --  Settled, it says: what is as it was when the conflict was found is
      --  the workspace's copy taken over the project's change, and said.
      declare
         Unsettled : constant Name_Lists.Vector :=
           (if Text_Resolved then Workspaces.Conflict_Files (Item, Id, Unsettled_Only => True)
            else Name_Lists.Empty_Vector);
      begin
         if not Unsettled.Is_Empty then
            declare
               --  The tasks whose change to those files the copy replaced:
               --  those completed after this workspace was made, not those
               --  whose change it was made from.
               Whose   : Name_Lists.Vector;
               History : constant Events.Event_List := Events.Since (Item, 0);
               Made_At : Natural := 0;

               function Done_Since (Other : String) return Boolean is
               begin
                  for Index in 1 .. Events.Length (History) loop
                     declare
                        One : constant Events.Event := Events.Element (History, Index);
                     begin
                        if One.Sequence > Made_At
                          and then ((Events."=" (One.Kind, Events.Task_Completed)
                                     and then To_String (One.Subject) = Other)
                                    or else (Events."=" (One.Kind, Events.Workspace_Integrated)
                                             and then To_String (One.Detail) = Other))
                        then
                           return True;
                        end if;
                     end;
                  end loop;
                  return False;
               end Done_Since;
            begin
               for Index in 1 .. Events.Length (History) loop
                  if Events."=" (Events.Element (History, Index).Kind, Events.Workspace_Created)
                    and then To_String (Events.Element (History, Index).Subject) = Id
                  then
                     Made_At := Events.Element (History, Index).Sequence;
                  end if;
               end loop;
               for Other of Tasks.List (Item, "complete") loop
                  declare
                     State : Records.Item;
                     Read  : E.Error_Info;
                  begin
                     Stores.Read (Item, Tasks_Area, Other & ".state", State, Read);
                     if Other /= Task_Id and then E.Is_Ok (Read)
                       and then (for some Path of Unsettled =>
                                   Lines_Of (Records.Get (State, "changed_files")).Contains (Path))
                       and then Done_Since (Other)
                     then
                        Whose.Append (Other);
                     end if;
                  end;
               end loop;
               Result.Reason := To_Unbounded_String
                 ("not changed since the conflict was found, so the workspace's copy replaced the"
                  & " project's change"
                  & (if Whose.Is_Empty then "" else " (" & Comma_Separated (Whose) & "'s)")
                  & ": " & Comma_Separated (Unsettled));
               Annotate (Item, Change, Task_Id, "integration_note", To_String (Result.Reason));
               --  Each task whose change went says so in its own history, with
               --  how to have it again.
               for Other of Whose loop
                  Annotate (Item, Change, Other, "replaced_by",
                            Task_Id & "'s taking in replaced its change to "
                            & Comma_Separated (Unsettled) & "; /task reopen " & Other
                            & " does it again");
               end loop;
               if not Whose.Is_Empty then
                  Append (Result.Reason, "; /task reopen " & Comma_Separated (Whose)
                          & " does that work again");
               end if;
            end;
         end if;
      end;
      --  How a conflict was got past, in the task's history.
      if Text_Resolved or else Semantic_Accepted then
         Annotate (Item, Change, Task_Id, "resolution",
                   (if Replaced_Kept /= ""
                    then "the workspace's copy replaced the project's (resolved anyway); the project's"
                         & " copy is kept in " & Replaced_Kept
                    elsif Text_Resolved and then Semantic_Accepted then "settled by hand and taken in anyway"
                    elsif Text_Resolved then "settled by hand in " & Id
                    else "taken in anyway, past what the code joins"));
      end if;
      Workspaces.Integrate (Item, Change, Id, True, Taken, Status, Semantic_Accepted,
                            Text_Resolved);

      --  A conflict found: kept in the task's history, each time, apart
      --  from the change that did not happen.
      if Status.Code = E.Framework_Integration_Conflict then
         declare
            Noted  : Stores.Transaction;
            Kept   : E.Error_Info;
            State  : Records.Item;
            Read   : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Read);
            Annotate (Item, Noted, Task_Id, "conflicts",
                      (if Records.Get (State, "conflicts") = "" then ""
                       else Records.Get (State, "conflicts") & ASCII.LF)
                      & Timestamp & " " & Id & ": "
                      & (if Workspaces.Conflict_Files (Item, Id).Is_Empty then E.Text_Of (Status, "detail")
                         else Comma_Separated (Workspaces.Conflict_Files (Item, Id))));
            Stores.Commit (Item, Noted, Kept);
         end;
      end if;

      if E.Is_Ok (Status) then
         Report_Integration (Item, Change, Id, Task_Id, Taken, Status);
      end if;
      --  What it took in, file by file as it was then: what differs later
      --  is not its; and taken in again, it is undone no more.
      if E.Is_Ok (Status) then
         declare
            Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
            Prints  : Unbounded_String;
         begin
            for Path of Taken loop
               Append (Prints, Path & ASCII.HT & File_Print (Hostkit.Fs.Join (Project, Path)) & ASCII.LF);
            end loop;
            Annotate (Item, Change, Task_Id, "taken_in", To_String (Prints));
            Annotate (Item, Change, Task_Id, "undone_by", "");
         end;
      end if;
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
      if E.Is_Ok (Status) then
         Workspaces.Release (Item, Id);
      end if;
      if E.Is_Error (Status) then
         return;
      end if;
      Result.Changed_Files := Taken;

      --  The project as it is now is what is verified, as widely as what was
      --  taken in reaches -- and the task goes where that leaves it, as work
      --  the harness ran goes: failed when the checks failed, blocked when
      --  they could not run or its gates did not hold, never left waiting.
      declare
         Chosen : constant Verification.Choice := Verification.Choose (Item, Task_Id, Taken);

         procedure Leave (Next, Why : String) is
            Moved : E.Error_Info;
         begin
            Change := Stores.No_Changes;
            Tasks.Move (Item, Change, Task_Id, Next, Why, Status => Moved);
            if E.Is_Ok (Moved) then
               Stores.Commit (Item, Change, Moved);
            end if;
            Result.Reason := To_Unbounded_String (Why);
         end Leave;
      begin
         Result.Scope := Chosen.Scope;
         Result.Scope_Reason := Chosen.Reason;
         if To_String (Chosen.Profile) = "" then
            Leave ("blocked", "no verification profile applies to it");
         else
            Verification.Run_Profile
              (Item, Change, To_String (Chosen.Profile), Task_Id, Result.Evidence_Id, Passed, Held,
               Given => Chosen.Given, Stands_For => To_String (Chosen.Stands_For));
            if E.Is_Error (Held) then
               Leave ("blocked", (if Interrupted (Held) then "its verification was cancelled"
                                    else "its verification could not run: " & Why_Of (Held)));
            else
               Annotate (Item, Change, Task_Id, "current_verification",
                         To_String (Result.Evidence_Id));
               Stores.Commit (Item, Change, Status);
               if not Passed then
                  Leave ("failed", To_String (Result.Evidence_Id) & " did not pass"
                         & First_Diagnostics (Item, To_String (Result.Evidence_Id)));
               else
                  Verification.Complete_Task (Item, Change, Task_Id, Held);
                  if E.Is_Ok (Held) then
                     --  Committed first, as Execute does: the requirements
                     --  are judged by the task as complete.
                     Stores.Commit (Item, Change, Status);
                     if E.Is_Ok (Status) then
                        Verification.Reevaluate_Requirements
                          (Item, Change, Result.Requirements, Status);
                     end if;
                     if E.Is_Ok (Status) then
                        Stores.Commit (Item, Change, Status);
                     end if;
                  else
                     declare
                        Failing : Unbounded_String;
                        Judged  : constant Verification.Gate_List :=
                          Verification.Gates (Item, Task_Id);
                     begin
                        for Index in 1 .. Verification.Length (Judged) loop
                           if not Verification.Element (Judged, Index).Passed then
                              Append (Failing,
                                      (if Failing = Null_Unbounded_String then "" else "; ")
                                      & To_String (Verification.Element (Judged, Index).Name) & ": "
                                      & To_String (Verification.Element (Judged, Index).Reason));
                           end if;
                        end loop;
                        Leave ("blocked", "its gates did not pass: " & To_String (Failing));
                     end;
                  end if;
               end if;
            end if;
         end if;
      end;
      Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
   end Take_In;

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
