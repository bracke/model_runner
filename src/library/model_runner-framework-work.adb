with Interfaces;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Exceptions;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Hostkit.Durability;
with Hostkit.Fs;
with Hostkit.Process;

with Model_Runner.Agent_Runtime;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Consistency;
with Model_Runner.Framework.Derivations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Indexes;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Invocations;
with Model_Runner.Framework.Observations;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;
with Model_Runner.Tools.Registry;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Platform.Signals;
with Model_Runner.Text;

package body Model_Runner.Framework.Work is
   use type Tasks.Core_State;

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
       & "Do the task now with your tools, paths relative to the project. Change part"
       & " of a file with edit_file -- the exact text to replace and what replaces it"
       & " -- and make a new file with write_file; describing a change does not make"
       & " it. Ask find -- kind symbol, references or used_by -- where a name is"
       & " declared and used, rather than reading files to find it."
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
       & " decision only a person can make."
       --  One line each, said what it is for: written as a list on one
       --  line, a 4B copied it whole -- verify: yes, instead: (...) -- and
       --  the answer was refused.
       & " Only where one applies, add it on a line of its own:" & ASCII.LF
       & (if May_Propose
          then "proposed_tasks: TITLE; kind=KIND -- more work you found, one a line" & ASCII.LF
               & (if May_Split
                  then "parts: TITLE -- the task is too large to do as one: say status: blocked, a part a line"
                       & ASCII.LF
                  else "")
               & "decisions: a decision the work needs a person to take, one a line" & ASCII.LF
               & "specifications: a specification the work needs, one a line" & ASCII.LF
          else "issues: more work you found, one a line" & ASCII.LF)
       & "waits_for: TASK-ID -- a task this one has to wait for" & ASCII.LF
       & "verify: yes -- not done, but have what you changed checked all the same" & ASCII.LF
       & (if May_Delegate then "instead: how you did a failed helper's part yourself" & ASCII.LF else ""));

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

   --  Whether a run was ended for going round: its model repeating calls
   --  it had made, and getting no further.
   function Went_Round (Ran : E.Error_Info) return Boolean is
      Found : Boolean;
      Given : E.Parameter;
   begin
      if not E."=" (Ran.Code, E.Framework_Limit_Exceeded) then
         return False;
      end if;
      E.Find_Parameter (Ran, "name", Found, Given);
      return Found and then Model_Runner.Text.To_String (Given.Text_Value) = "the model";
   end Went_Round;

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
   begin
      Config := Configurations.Required (Item);
      return Records.Get (Config, "scalar." & Name);
   end Scalar;

   --  A setting of the configuration's work.
   function Work_Setting (Item : Stores.Store; Name : String) return String is
      Config : Records.Item;
   begin
      Config := Configurations.Required (Item);
      return Records.Get (Config, "scalar.work." & Name);
   end Work_Setting;

   --  How long an agent holds its task before it must have finished.
   function Lease_Seconds (Item : Stores.Store) return Positive is
      Config : Records.Item;
   begin
      Config := Configurations.Required (Item);
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
         --  Not staged is not left out quietly: the change it was to be
         --  part of is refused whole.
         if E.Is_Error (Status) then
            Stores.Spoil (Change, Status);
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

   --  Read a piece at a time and taken as Fingerprint takes a whole text,
   --  so a file of any size has one and it is the one a text read whole
   --  would have; a file that will not read is not one that is absent.
   function File_Print (Path : String) return String is
      use type Interfaces.Unsigned_64;
      use type Ada.Streams.Stream_Element_Offset;
      Digits_Of : constant String := "0123456789abcdef";
      Value     : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
      Result    : String (1 .. 16);
      File      : Ada.Streams.Stream_IO.File_Type;
      Piece     : Ada.Streams.Stream_Element_Array (1 .. 1_048_576);
      Last      : Ada.Streams.Stream_Element_Offset;
   begin
      if not Ada.Directories.Exists (Path) then
         return Absent_Print;
      end if;
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      loop
         Ada.Streams.Stream_IO.Read (File, Piece, Last);
         exit when Last < Piece'First;
         for Byte of Piece (Piece'First .. Last) loop
            Value := (Value xor Interfaces.Unsigned_64 (Byte)) * 16#0000_0100_0000_01B3#;
         end loop;
         exit when Last < Piece'Last;
      end loop;
      Ada.Streams.Stream_IO.Close (File);
      for Index in reverse Result'Range loop
         Result (Index) := Digits_Of (Natural (Value and 16#F#) + 1);
         Value := Interfaces.Shift_Right (Value, 4);
      end loop;
      return Result;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return Unreadable_Print;
   end File_Print;

   function Same_File_Print (Then_Print, Now_Print : String) return Boolean
   is (Then_Print /= Unreadable_Print and then Now_Print /= Unreadable_Print
       and then Then_Print = Now_Print);

   -----------------
   -- Note_Undone --
   -----------------

   procedure Note_Undone
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Copy    : String;
      Status  : out Model_Runner.Errors.Error_Info)
   is
      Held   : Records.Item;
      Got    : E.Error_Info;
      Event  : Unbounded_String;
   begin
      Status := E.Success;
      Stores.Read (Item, Tasks_Area, Task_Id & ".state", Held, Got);
      Annotate (Item, Change, Task_Id, "undone_by", Copy);
      --  In its history too, where it changes how its work stands.
      if E.Is_Ok (Got) and then Records.Get (Held, "undone_by") /= Copy then
         Events.Emit (Item, Change, Events.Task_Revised, Task_Id,
                      (if Copy /= "" then "its work undone in the project: " & Copy & " was put back over it"
                       else "its work back in the project, as a kept copy put it there"),
                      Event, Status);
         if E.Is_Error (Status) then
            Stores.Spoil (Change, Status);
         end if;
      end if;
   end Note_Undone;

   procedure Note_Undone
     (Item : in out Stores.Store; Task_Id, Copy : String; Status : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;
   begin
      Note_Undone (Item, Change, Task_Id, Copy, Status);
      Stores.Commit (Item, Change, Status);
   end Note_Undone;

   -------------------
   -- Note_Restored --
   -------------------

   procedure Note_Restored
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Files   : Name_Lists.Vector;
      Status  : out Model_Runner.Errors.Error_Info)
   is
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
   end Note_Restored;

   procedure Note_Restored
     (Item : in out Stores.Store; Task_Id : String; Files : Name_Lists.Vector;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;
   begin
      Note_Restored (Item, Change, Task_Id, Files, Status);
      if E.Is_Ok (Status) then
         Stores.Commit (Item, Change, Status);
      end if;
   end Note_Restored;

   ---------------
   -- Holder_Of --
   ---------------

   function Holder_Of (Item : Stores.Store; Path : String) return String is
      Now   : constant String :=
        File_Print (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (Stores.Root (Item)), Path));
      Found : Unbounded_String;
   begin
      --  Absent, or not read: no task's work is it, as far as can be told.
      if Now in Absent_Print | Unreadable_Print then
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

   procedure Forget_Last_Answer
     (Item : in out Stores.Store; Task_Id : String; Status : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;
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
         --  An agent's state is what completion reads: not staged, the
         --  change it was to be part of is refused whole.
         if E.Is_Error (Status) then
            Stores.Spoil (Change, Status);
            return;
         end if;
         Records.Set_Revision (Held, Records.Revision (Held) + 1);
      end if;
      Records.Set (Held, "state", State);
      if State /= Tasks.Running then
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
      First   : E.Error_Info := E.Success;
   begin
      for Child of Agents.Children (Item, Agent) loop
         Agents.Cancel (Item, Change, Child, Stopped, Status, Why => "it was stopped: " & Why);
         if E.Is_Error (Status) and then E.Is_Ok (First) then
            First := Status;
         end if;
      end loop;
      --  A helper that could not be told ended is not said to be: the change
      --  that would say the work was stopped is refused, with why.
      if E.Is_Error (First) then
         Stores.Spoil (Change, First);
      end if;
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

   --  A path as a report writes it, read as the path: spaces, tabs and
   --  no-break spaces about it, a mark of code or emphasis round it, a
   --  note after it -- `src/a.adb`, **src/a.adb**, src/a.adb (new) -- and
   --  ./ before it taken off; the words for none read as none, however
   --  written. A note is only cut where the whole is no file changed
   --  (Known) or there under Place: docs/Notes (draft).md is a name, not
   --  docs/Notes and a note. The root's report and a helper's are read so.
   function Path_Claimed
     (Line : String; Known : Name_Lists.Vector; Place : String) return String
   is
      No_Break : constant String := Character'Val (16#C2#) & Character'Val (16#A0#);
      function Trimmed (Text : String) return String is
         First : Natural := Text'First;
         Last  : Natural := Text'Last;
      begin
         loop
            if First <= Last and then Text (First) in ' ' | ASCII.HT then
               First := First + 1;
            elsif First + 1 <= Last and then Text (First .. First + 1) = No_Break then
               First := First + 2;
            elsif Last >= First and then Text (Last) in ' ' | ASCII.HT then
               Last := Last - 1;
            elsif Last - 1 >= First and then Text (Last - 1 .. Last) = No_Break then
               Last := Last - 2;
            else
               exit;
            end if;
         end loop;
         return Text (First .. Last);
      end Trimmed;
      function Unwrapped (Text : String) return String is
      begin
         for Mark of Name_Lists.Vector'(["**", "`", "*", """", "'"]) loop
            if Text'Length > 2 * Mark'Length
              and then Text (Text'First .. Text'First + Mark'Length - 1) = Mark
              and then Text (Text'Last - Mark'Length + 1 .. Text'Last) = Mark
            then
               return Unwrapped (Trimmed (Text (Text'First + Mark'Length .. Text'Last - Mark'Length)));
            end if;
         end loop;
         return Text;
      end Unwrapped;
      function Without_Dot (Path : String) return String is
        (if Path'Length > 2 and then Path (Path'First .. Path'First + 1) = "./"
         then Path (Path'First + 2 .. Path'Last) else Path);
      Whole : constant String := Without_Dot (Unwrapped (Trimmed (Line)));
      Bare  : constant String := Unwrapped (Trimmed (Line));
      Note  : constant Natural := Ada.Strings.Fixed.Index (Bare, " (");
      Dash  : constant Natural := Ada.Strings.Fixed.Index (Bare, " " & Character'Val (16#E2#) & Character'Val (16#80#)
                                                                & Character'Val (16#94#) & " ");
      Cut   : constant Natural :=
        (if Note > 0 and then (Dash = 0 or else Note < Dash) then Note else Dash);
      Path  : constant String := Unwrapped (Trimmed (if Cut > 0 then Bare (Bare'First .. Cut - 1) else Bare));
      Plain : constant String := Without_Dot (Path);
      Lower : constant String := Ada.Characters.Handling.To_Lower (Plain);
   begin
      if Lower in "" | "-" | "none" | "none." | "nothing" | "nothing." | "n/a" | "(none)" then
         return "";
      elsif Cut > 0 and then Whole /= ""
        and then (for all C of Whole => C >= ' ')
        and then (Known.Contains (Whole)
                  or else Ada.Directories.Exists (Hostkit.Fs.Join (Place, Whole)))
      then
         return Whole;
      end if;
      return Plain;
   exception
      when others =>
         return Plain;
   end Path_Claimed;

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
   --  How often a failed required helper is run again: scalar
   --  agents.child_retries, else once.
   function Retries_Allowed (Item : Stores.Store) return Natural is
      Text : constant String := Scalar (Item, "agents.child_retries");
   begin
      return (if Text'Length in 1 .. 3 and then (for all C of Text => C in '0' .. '9')
              then Natural'Value (Text) else 1);
   end Retries_Allowed;

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
   --  let run its task's own profile -- in the project, or in its own
   --  workspace where it works apart.
   function Offers_Checks
     (Item : Stores.Store; Allowed : Permissions.Permission_Set; Task_Id : String)
      return Boolean
   is (Task_Id /= ""
       and then Verification.Profile_Of (Item, Task_Id) /= ""
       and then Permissions.Allows_Profile
                  (Allowed, Check_Capability (Item, Verification.Profile_Of (Item, Task_Id)),
                   Verification.Profile_Of (Item, Task_Id)));

   --  What an agent's call may use, as its invocation records it: the
   --  tools it is offered -- reading always, checks, writing and helpers
   --  where its permissions let it -- what those permissions are, and how
   --  many calls it may make.
   function Tools_Of
     (Item : Stores.Store; Agent_Id : String; Task_Id : String;
      Hosted : Boolean := True) return Model_Runner.Tools.Registry.Capabilities
   is
      package Rg renames Model_Runner.Tools.Registry;
      Held : Agents.Agent;
      Read : E.Error_Info;
      Can  : Rg.Capabilities := Rg.Nothing;
   begin
      Can (Rg.Read_Files) := True;
      Can (Rg.Project_Graph) := Hosted;
      Can (Rg.Project_Knowledge) := Hosted;
      Agents.Read (Item, Agent_Id, Held, Read);
      if E.Is_Error (Read) then
         return Can;
      end if;
      Can (Rg.Project_Checks) := Hosted and then Offers_Checks (Item, Held.Allowed, Task_Id);
      Can (Rg.Write_Files) :=
        Permissions.Allows (Held.Allowed, Permissions.Write_Source)
        or else Permissions.Allows (Held.Allowed, Permissions.Write_Specs);
      Can (Rg.Delegation) :=
        Hosted and then Permissions.Allows (Held.Allowed, Permissions.Create_Children)
        and then Held.Allowed (Permissions.Create_Children).Max_Children > 0
        and then Held.Depth + 1 <= Held.Allowed (Permissions.Create_Children).Max_Depth;
      return Can;
   end Tools_Of;

   function Tool_Policy
     (Item : Stores.Store; Agent_Id : String; Max_Calls : Natural; Task_Id : String;
      Hosted : Boolean := True)
      return String
   is
      Held : Agents.Agent;
      Read : E.Error_Info;
      --  The tools as the registry offers them, by the names the agent is
      --  shown: the narrow ones find took over were named here after they
      --  were no longer offered, and a helper was told of tools it had not.
      Said : Unbounded_String :=
        To_Unbounded_String
          ("tools: " & Model_Runner.Tools.Registry.Offered_Names (Tools_Of (Item, Agent_Id, Task_Id, Hosted)));
   begin
      Agents.Read (Item, Agent_Id, Held, Read);
      if E.Is_Error (Read) then
         return To_String (Said);
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
      --  And the files of bytes, by their stamps: written by the work,
      --  they are changes as any file is -- reported, held to what it may
      --  write, put back.
      for Line of Repository.Binary_Files (Found) loop
         declare
            Tab : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
         begin
            if Tab > Line'First then
               Result.Include (Line (Line'First .. Tab - 1), "bytes:" & Line (Tab + 1 .. Line'Last));
            end if;
         end;
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

   --------------------
   -- Report_Refusal --
   --------------------

   --  Whether a root's answer reports its work done, read as the harness
   --  reads every report -- lines or JSON alike -- not by its text: a
   --  done said in JSON is done as surely as one said in a line.
   function Says_Done (Answer : String; Root : Boolean := True) return Boolean is
      Said : Invocations.Claims;
      Held : E.Error_Info;
   begin
      --  Read as its own kind of report: a helper's is held to the child
      --  result contract, not the root's.
      Invocations.Hold ((if Root then Invocations.Work_Claim else Child_Claim), Answer, Said, Held);
      return Ada.Characters.Handling.To_Lower (Invocations.Claim (Said, "status")) = "done";
   end Says_Done;

   function Next_Step (State : Round_State) return Round_Step is
      Rounds : constant Positive := (if State.Root then 3 else 2);
      Said   : constant String := To_String (State.Answer);
   begin
      --  Given up -- or said done -- on checks that failed, with time
      --  left: sent back once to fix what they reported. A small model
      --  that saw one compile error ended the task failed at once.
      if State.Root and then State.Answered and then State.Round < 3 and then not State.Asked_To_Fix
        and then State.Hosted and then State.Checks_Failing and then State.Time_Left
      then
         return Ask_To_Fix;
      --  Said done with no check run at all, where it may run them: the
      --  harness runs them, and a failure sends it back once with what
      --  they said -- in a workspace qwen3-8b answered done three runs out
      --  of three without a check, and its work waited there failed.
      elsif State.Root and then State.Answered and then State.Round < 3 and then not State.Asked_To_Fix
        and then State.Hosted and then State.Check_Runs = 0 and then State.May_Check and then State.Time_Left
        and then Says_Done (Said)
      then
         return Check_For_It;
      --  A report the harness cannot take -- a required line missing, a
      --  status none of its words -- handed back once, saying what is
      --  wrong, as an unreadable call is: a 8B wrote status: blocked and
      --  parts: with no summary:, and the task was blocked for it.
      elsif State.Answered and then State.Hosted and then State.Round < Rounds and then not State.Asked_To_Mend
        and then Said /= "" and then Report_Refusal (State.Root, Said) /= ""
      then
         return Ask_To_Mend;
      --  Written, then only repeating what is done: the work is there, and
      --  what is missing is its report -- asked for once, not the work
      --  failed for it.
      elsif State.Repeating and then State.Wrote and then State.Round < Rounds
        and then not State.Asked_To_Report
      then
         return Ask_To_Report;
      --  A helper that says it is done having called nothing at all is
      --  told so once, as a root that answered without a call is: gemma-
      --  3-4b's helper said it had written docs/calc.md and had made no
      --  call, and its parent's task failed for the file at the end.
      elsif not State.Root and then State.Answered and then State.Calls = 0
        and then State.Round < Rounds and then Says_Done (Said, Root => False)
      then
         return Ask_To_Call;
      elsif State.Calls > 0 or else State.Round = 3 or else not State.Root or else not State.Answered then
         return Finish;
      else
         return Ask_To_Call;
      end if;
   end Next_Step;

   function Report_Refusal (Root : Boolean; Answer : String) return String is
      Said : Invocations.Claims;
      Held : E.Error_Info;
   begin
      Invocations.Hold ((if Root then Invocations.Work_Claim else Child_Claim), Answer, Said, Held);
      return (if E.Is_Ok (Held) then ""
              else E.Text_Of (Held, "name") & ": " & E.Text_Of (Held, "detail"));
   end Report_Refusal;

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

   --  How a helper works and reports: the rules every helper is given,
   --  run's and /work's alike.
   function Child_Instructions return String
   is (Model_Runner.Agent_Runtime.Helper_Rules);

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
   function Plan_For
     (Item    : Stores.Store;
      Task_Id : String;
      Allowed : Permissions.Permission_Set;
      Apart   : Boolean;
      Helpers : Boolean := True) return Execution_Plan
   is separate;

   ---------------------
   -- Permitted_Words --
   ---------------------

   function Permitted_Words (Plan : Execution_Plan) return String is
      Said : Unbounded_String;
      procedure Add (Text : String) is
      begin
         Append (Said, (if Said = Null_Unbounded_String then "" else "; ") & Text);
      end Add;
   begin
      if Plan.Read_Source then
         Add ("read the source");
      end if;
      if Plan.Read_Specs then
         Add ("read the specifications");
      end if;
      if Plan.Write_Source then
         Add ("write " & (if Plan.Source_Roots.Is_Empty then "files"
                          else "files under " & Comma_Separated (Plan.Source_Roots))
              --  What it may not, inherited or its own, said with it.
              & (if Plan.Source_Denied.Is_Empty then ""
                 else " except " & Comma_Separated (Plan.Source_Denied)));
      end if;
      if Plan.Write_Specs then
         Add ("write specifications "
              & (if Plan.Spec_Roots.Is_Empty
                 then "(in " & Permissions.Specification_Places & ")"
                 else "under " & Comma_Separated (Plan.Spec_Roots)));
      end if;
      --  Its checks, by the profile that runs them.
      if Plan.May_Check then
         Add ("run the project's checks"
              & (if Length (Plan.Profile) = 0 then "" else " (profile " & To_String (Plan.Profile) & ")"));
      end if;
      if Plan.May_Delegate then
         Add ("hand parts to helpers (at most" & Natural'Image (Plan.Max_Helpers) & ")");
      end if;
      if Plan.May_Propose then
         Add ("propose tasks");
      end if;
      return (if Said = Null_Unbounded_String then "read only what you are given" else To_String (Said));
   end Permitted_Words;

   --------------
   -- Rendered --
   --------------

   function Rendered (Plan : Execution_Plan) return String is
      Parts : Unbounded_String;
   begin
      for One of Plan.Parts loop
         Append (Parts, "- " & To_String (One.Id) & " " & To_String (One.Title) & ": "
                 & To_String (One.State) & ASCII.LF);
      end loop;
      return Instructions_For (Plan.May_Propose, Plan.May_Split, Plan.May_Write,
                               May_Delegate => Plan.May_Delegate, May_Check => Plan.May_Check)
        & ASCII.LF & "## What you may do" & ASCII.LF
        & "You may " & Permitted_Words (Plan) & "."
        & (if Plan.May_Write
           then " Change only the files you may write; a change to any other file fails the work."
           else "")
        & (if Plan.May_Propose then "" else " You may not propose tasks or parts.")
        & ASCII.LF
        --  Its budget, where it has one: a small model told how many calls
        --  it has spends them on the work.
        & (if Plan.Max_Calls = 0 then ""
           else "You have at most" & Natural'Image (Plan.Max_Calls) & " tool calls." & ASCII.LF)
        & (if Plan.Parts.Is_Empty then ""
           else ASCII.LF & "## Your parts" & ASCII.LF & To_String (Parts)
                & "Those complete are done: do what is left of the task itself, and do not split"
                & " it into them again." & ASCII.LF);
   end Rendered;

   --  What a task's root agent is told after its context, from what it may
   --  do: its plan, rendered.
   function Instructions_With
     (Item    : Stores.Store;
      Task_Id : String;
      Allowed : Permissions.Permission_Set;
      Apart   : Boolean;
      Helpers : Boolean := True) return String
   is (Rendered (Plan_For (Item, Task_Id, Allowed, Apart, Helpers)));

   -----------------------
   -- Instructions_Of --
   -----------------------

   --  The plan /work would make for a task now, for its worker, as its
   --  kind and its own permissions give it.
   function Plan_Now (Item : Stores.Store; Task_Id : String) return Execution_Plan is
      Defined : Records.Item;
      Read    : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      return Plan_For
        (Item, Task_Id,
         Permissions.Effective (Item, Records.Get (Defined, "kind"), "worker",
                                Task_Level => Records.Get (Defined, "permissions")),
         Apart => (if Tasks.Kind_Policy (Item, Records.Get (Defined, "kind"), "isolation") /= ""
                   then Tasks.Kind_Policy (Item, Records.Get (Defined, "kind"), "isolation")
                   else Work_Setting (Item, "isolation")) = "workspace");
   end Plan_Now;

   function Instructions_Of (Item : Stores.Store; Task_Id : String) return String
   is (Rendered (Plan_Now (Item, Task_Id)));

   ------------
   -- May_Do --
   ------------

   function May_Do (Item : Stores.Store; Task_Id : String) return String is
      Defined : Records.Item;
      Read    : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      --  The plan Instructions_Of renders, read as the plan it is.
      return (if E.Is_Error (Read) then "" else Permitted_Words (Plan_Now (Item, Task_Id)));
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
      if not Host.Edited.Contains (Path) then
         Host.Edited.Append (Path);
      end if;
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

   --  What the project allows the task's work as its configuration and
   --  the task's own permissions stand now: the most any agent of it holds.
   --  By the agent's own role: a helper's role may be granted what a
   --  worker's is not. Where the task it is held by cannot be read, what
   --  the project allows now cannot be known, and nothing is allowed: a
   --  live limit that lapses when its authority is unreadable is none.
   function Allowed_For
     (Item : Stores.Store; Task_Id : String; Role : String) return Permissions.Permission_Set
   is
      Defined : Records.Item;
      Read    : E.Error_Info;
   begin
      Tasks.Definition (Item, Task_Id, Defined, Read);
      if E.Is_Error (Read) then
         return Permissions.Nothing;
      end if;
      return Permissions.Effective (Item, Records.Get (Defined, "kind"),
                                    (if Role = "" then "worker" else Role),
                                    Task_Level => Records.Get (Defined, "permissions"));
   end Allowed_For;

   function Allowed_Now (Host : Child_Host; Role : String) return Permissions.Permission_Set
   is (Allowed_For (Host.Item.all, To_String (Host.Task_Id), Role));

   --  Holds_Now for a caller that has the agent and not a host: what the
   --  harness decides for a run once it is over -- what it wrote that it
   --  may not, whether it may propose or be taken in -- is decided as the
   --  project allows it now, as the run's own calls were.
   function Allows_Now
     (Item    : Stores.Store;
      Task_Id : String;
      Held    : Agents.Agent;
      What    : Permissions.Capability;
      Path    : String := "") return Boolean
   is (Permissions.Allows (Held.Allowed, What, Path)
       and then Permissions.Allows
                  (Allowed_For (Item, Task_Id, To_String (Held.Role)), What, Path));

   --  Whether an agent holds a capability now: as it was given when it
   --  started, which is the most it has, and as the project allows its
   --  work now -- a permission taken away since, /reconfigure from another
   --  terminal, is gone at once, not at the next run; a grant waits for
   --  the next. A check's profile is asked of both the same way. The one
   --  place either kind of call is decided.
   function Holds_Now
     (Host    : Child_Host;
      Held    : Agents.Agent;
      What    : Permissions.Capability;
      Path    : String := "";
      Profile : String := "") return Boolean
   is
      Now : constant Permissions.Permission_Set :=
        Allowed_Now (Host, To_String (Held.Role));
   begin
      if Profile /= "" then
         return Permissions.Allows_Profile (Held.Allowed, What, Profile)
           and then Permissions.Allows_Profile (Now, What, Profile);
      end if;
      return Permissions.Allows (Held.Allowed, What, Path)
        and then Permissions.Allows (Now, What, Path);
   end Holds_Now;

   function Grants_Now (Host : Child_Host) return Permissions.Permission_Set is
      Held   : Agents.Agent;
      Status : E.Error_Info;
   begin
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      if E.Is_Error (Status) then
         return Permissions.Nothing;
      end if;
      return Permissions.Intersect (Held.Allowed, Allowed_Now (Host, To_String (Held.Role)));
   end Grants_Now;

   function May
     (Host : Child_Host;
      What : Permissions.Capability;
      Path : String := "") return Boolean
   is
      Held   : Agents.Agent;
      Status : E.Error_Info;
   begin
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      return E.Is_Ok (Status) and then Holds_Now (Host, Held, What, Path)
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

   function Store_Of (Host : Child_Host) return not null access Stores.Store is (Host.Item.all'Unchecked_Access);

   function Task_Profile (Host : Child_Host) return String
   is (if Host.Profile_Frozen then To_String (Host.Profile)
       else Verification.Profile_Of (Host.Item.all, To_String (Host.Task_Id)));

   ---------------
   -- May_Check --
   ---------------

   function May_Check (Host : Child_Host; Profile : String) return Boolean is
      Held   : Agents.Agent;
      Status : E.Error_Info;

      --  What running it takes: for the work's own profile, as it was
      --  when the work started; for another, as the configuration says.
      Needed : constant Permissions.Capability :=
        (if Host.Profile_Frozen and then Profile = To_String (Host.Profile)
         then Host.Profile_Need
         else Check_Capability (Host.Item.all, Profile));
   begin
      if Profile = "" then
         return False;
      end if;
      Agents.Read (Host.Item.all, Current (Host), Held, Status);
      return E.Is_Ok (Status)
        and then Holds_Now (Host, Held, Needed, Profile => Profile);
   end May_Check;

   ----------------
   -- Run_Checks --
   ----------------

   function Checks_Failing (Host : Child_Host) return Boolean is (Host.Checks_Failed);

   ---------------
   -- Judged_By --
   ---------------

   --  Whether a path is one a check's command names as what it judges by:
   --  a word of it, as its parts say it -- a script or a list it reads --
   --  and, where it is a source, what the check runs: its first word, or
   --  what an interpreter is given. A source a check only looks at -- test
   --  -f src/x.adb -- is the work's to write.
   --  A program's name without where it is: /usr/bin/python3 is python3.
   function Last_Part (Word : String) return String is
      Slash : constant Natural := Ada.Strings.Fixed.Index (Word, "/", Ada.Strings.Backward);
   begin
      return (if Slash = 0 then Word else Word (Slash + 1 .. Word'Last));
   end Last_Part;

   function Named_By_Checks (Item : Stores.Store; Profile_Text, Bare : String) return Boolean is
      Checks : constant Verification.Check_List := Verification.Parse_Profile (Profile_Text);
      Source : constant Boolean :=
        Repository."=" (Repository.Role_Of (Bare, Repository.Roots_Of (Item)), Repository.Source);
   begin
      for At_Check in 1 .. Verification.Length (Checks) loop
         declare
            Words : constant Name_Lists.Vector :=
              Execution.Words_Of (To_String (Verification.Element (Checks, At_Check).Command));
         begin
            for Index in 1 .. Natural (Words.Length) loop
               if Permissions.Normal (Words (Index)) = Bare
                 and then (not Source
                           or else Index = 1
                           or else Last_Part (Words (Index - 1))
                                     in "sh" | "bash" | "python" | "python3" | "perl" | "ruby" | "node"
                                      | "tclsh" | "lua" | "php" | "Rscript")
               then
                  return True;
               end if;
            end loop;
         end;
      end loop;
      return False;
   end Named_By_Checks;

   function Judged_By (Host : Child_Host; Path : String) return Boolean is
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Host.Item.all));
      --  As its parts say it: ././x and src//x are x and src/x.
      Bare    : constant String := Permissions.Normal (Path);
      Existing : constant Boolean := Bare /= "" and then Ada.Directories.Exists (Hostkit.Fs.Join (Project, Bare));

      --  Where it lands, through any link on the way: a link to a test is
      --  that test.
      function Landed return String is
         Real : constant String := Hostkit.Fs.Real_Path (Hostkit.Fs.Join (Project, Bare));
         Base : constant String := Hostkit.Fs.Real_Path (Project);
      begin
         if Base /= "" and then Real'Length > Base'Length + 1
           and then Real (Real'First .. Real'First + Base'Length) = Base & "/"
         then
            return Permissions.Normal (Real (Real'First + Base'Length + 1 .. Real'Last));
         end if;
         return Bare;
      end Landed;

      --  Under the tests, or a word of a check's command that is this
      --  file -- a script it runs, a list it reads -- and not a source the
      --  work is to write, which a check names to look at.
      function Judged (Where : String) return Boolean
      is (Repository.Under_Roots (Repository.Roots_Of (Host.Item.all).Tests, Where)
          or else Named_By_Checks
                    (Host.Item.all,
                     (if Host.Profile_Frozen then To_String (Host.Profile_Text)
                      else Records.Get (Configurations.Required (Host.Item.all), "profile." & Task_Profile (Host))),
                     Where));
   begin
      if Kind_Of_Task (Host.Item.all, To_String (Host.Task_Id)) = "test" or else not Existing then
         --  A new file judges nothing yet: tests may be added.
         return False;
      end if;
      return Judged (Bare) or else Judged (Landed);
   end Judged_By;

   ------------------
   -- Judged_Files --
   ------------------

   function Judged_Files
     (Item         : Stores.Store;
      Task_Id      : String;
      Profile_Text : String) return Name_Lists.Vector
   is
      Project : constant String := Ada.Directories.Containing_Directory (Stores.Root (Item));
      Result  : Name_Lists.Vector;
      Tests   : constant Name_Lists.Vector := Repository.Roots_Of (Item).Tests;
      Files   : constant Repository.Graph := Repository.Now (Item);
      Checks  : constant Verification.Check_List := Verification.Parse_Profile (Profile_Text);
   begin
      if Kind_Of_Task (Item, Task_Id) = "test" then
         return Result;
      end if;
      for Index in 1 .. Repository.File_Count (Files) loop
         declare
            Path : constant String := To_String (Repository.File_At (Files, Index).Path);
         begin
            if Repository.Under_Roots (Tests, Path) then
               Result.Append (Path);
            end if;
         end;
      end loop;
      for At_Check in 1 .. Verification.Length (Checks) loop
         for Word of Execution.Words_Of (To_String (Verification.Element (Checks, At_Check).Command)) loop
            declare
               Bare : constant String := Permissions.Normal (Word);
            begin
               if Bare /= "" and then not Result.Contains (Bare)
                 and then Ada.Directories.Exists (Hostkit.Fs.Join (Project, Bare))
                 and then Ada.Directories."=" (Ada.Directories.Kind (Hostkit.Fs.Join (Project, Bare)),
                                               Ada.Directories.Ordinary_File)
                 and then Named_By_Checks (Item, Profile_Text, Bare)
               then
                  Result.Append (Bare);
               end if;
            end;
         end loop;
      end loop;
      return Result;
   end Judged_Files;

   procedure Run_Checks
     (Host     : in out Child_Host;
      Profile  : String;
      Report   : out Ada.Strings.Unbounded.Unbounded_String;
      Status   : out Model_Runner.Errors.Error_Info;
      Affected : Boolean := False)
   is separate;

   ------------------------
   -- Record_Observation --
   ------------------------

   procedure Record_Observation
     (Host      : in out Child_Host;
      Arguments : String;
      Report    : out Ada.Strings.Unbounded.Unbounded_String;
      Status    : out Model_Runner.Errors.Error_Info)
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

   --  Kept as the first record the state could not keep.
   procedure Keep_Unkept (Host : in out Child_Host; Status : E.Error_Info) is
   begin
      if E.Is_Error (Status) and then E.Is_Ok (Host.Unkept) then
         Host.Unkept := Status;
      end if;
   end Keep_Unkept;

   function Unkept (Host : Child_Host) return Model_Runner.Errors.Error_Info is (Host.Unkept);

   function Authority_Changed (Item : Stores.Store; Manifest_Id : String) return String is
      Held    : Records.Item;
      Read    : E.Error_Info;
      Changed : Unbounded_String;
   begin
      if Manifest_Id = "" then
         return "";
      end if;
      Stores.Read (Item, Invocations_Area, "manifest." & Manifest_Id, Held, Read);
      --  What the work was told cannot be read back: whether the words it
      --  was done against still stand cannot be told, which is not that
      --  they do.
      if E.Is_Error (Read) then
         return Manifest_Id & " (what it was told cannot be read back)";
      end if;
      for Index in 1 .. Records.Field_Count (Held) loop
         declare
            Field : constant String := Records.Field_Name (Held, Index);
         begin
            if Field'Length > 8 and then Field (Field'First .. Field'First + 7) = "meaning." then
               declare
                  Id   : constant String := Field (Field'First + 8 .. Field'Last);
                  Now  : Intent.Entity;
                  Got  : E.Error_Info;
               begin
                  Intent.Read (Item, (if Id'Length > 4 and then Id (Id'First .. Id'First + 3) = "DEC-"
                                      then Intent.Decision else Intent.Requirement), Id, Now, Got);
                  if E.Is_Error (Got) or else To_String (Now.Meaning) /= Records.Get (Held, Field) then
                     Append (Changed, (if Changed = Null_Unbounded_String then "" else ", ") & Id);
                  end if;
               end;
            end if;
         end;
      end loop;
      return To_String (Changed);
   end Authority_Changed;

   function Shown_Revisions (Host : Child_Host) return Name_Lists.Vector is
      Call     : Records.Item;
      Manifest : Records.Item;
      Read     : E.Error_Info;
      Mark     : constant String := "source_revision.";
   begin
      return Result : Name_Lists.Vector do
         if Host.Calls.Is_Empty or else Host.Calls.Last_Element = "" then
            return;
         end if;
         Stores.Read (Host.Item.all, Invocations_Area, Host.Calls.Last_Element, Call, Read);
         if E.Is_Ok (Read) then
            Stores.Read (Host.Item.all, Invocations_Area,
                         "manifest." & Records.Get (Call, "context_manifest"), Manifest, Read);
         end if;
         if E.Is_Error (Read) then
            return;
         end if;
         for Index in 1 .. Records.Field_Count (Manifest) loop
            declare
               Field : constant String := Records.Field_Name (Manifest, Index);
            begin
               if Field'Length > Mark'Length and then Field (Field'First .. Field'First + Mark'Length - 1) = Mark then
                  Result.Append (Field (Field'First + Mark'Length .. Field'Last) & ASCII.HT
                                 & Records.Get (Manifest, Field));
               end if;
            end;
         end loop;
      end return;
   end Shown_Revisions;

   function Authority_Readable (Host : Child_Host) return Boolean is
      Defined : Records.Item;
      Read    : E.Error_Info;
   begin
      Tasks.Definition (Host.Item.all, To_String (Host.Task_Id), Defined, Read);
      return E.Is_Ok (Read);
   end Authority_Readable;

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
      --  Not charged is not committed half, and is kept to be said: the
      --  budget is what stops the next run.
      if E.Is_Ok (Status) then
         Stores.Commit (Host.Item.all, Change, Status);
      end if;
      Keep_Unkept (Host, Status);
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
      Answer    : String;
      Number    : Natural := 0;
      Ended     : String := "")
   is
      Change : Stores.Transaction;
      Status : E.Error_Info;
   begin
      if not Host.Calls.Is_Empty then
         Invocations.Note_Call
           (Host.Item.all, Change, Host.Calls.Last_Element, Named, Arguments, Answer, Status,
            Number => Number, Ended => Ended);
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
         Keep_Unkept (Host, Status);
      end if;
   end Note_Call;

   ----------------
   -- Note_Start --
   ----------------

   procedure Note_Start
     (Host      : in out Child_Host;
      Named     : String;
      Arguments : String;
      Number    : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Change : Stores.Transaction;
   begin
      Number := 0;
      Status := E.Success;
      if not Host.Calls.Is_Empty then
         Invocations.Note_Start
           (Host.Item.all, Change, Host.Calls.Last_Element, Named, Arguments, Number, Status);
         if E.Is_Ok (Status) then
            Stores.Commit (Host.Item.all, Change, Status);
         end if;
         if E.Is_Error (Status) then
            Number := 0;
         end if;
      end if;
   end Note_Start;

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
         --  A helper not ended is not committed with the others ended:
         --  all of them, or none and said.
         if E.Is_Error (Status) then
            Stores.Spoil (Change, Status);
         end if;
         if Host.Calls.Last_Element /= "" then
            Invocations.Finish
              (Host.Item.all, Change, Host.Calls.Last_Element, Invocations.Failed,
               (others => 0), "", "its parent stopped before it answered", Status);
            if E.Is_Error (Status) then
               Stores.Spoil (Change, Status);
            end if;
         end if;
         Host.Open.Delete_Last;
         Host.Calls.Delete_Last;
         Host.Opened.Delete_Last;
      end loop;
      Stores.Commit (Host.Item.all, Change, Status);
      Keep_Unkept (Host, Status);
   end Abandon;

   ------------------
   -- Quoted_Lines --
   ------------------

   function Quoted_Lines (Text : String; Project : String; Known : Name_Lists.Vector) return String is
      Said  : Unbounded_String;
      Given : Natural := 0;
      Seen  : Name_Lists.Vector;
      Index : Natural := Text'First;

      function Name_Char (C : Character) return Boolean
      is (C in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '.' | '/' | '-');

      --  What an Ada line holds of another language's spelling, said as Ada
      --  spells it: qwen3-8b wrote elif, then else if, ten edits running,
      --  told only that elif is undefined.
      function Ada_Slips (Path, Line : String) return String is
         --  What the output says went wrong: an overflow or a range check,
         --  where a guard that does not stop the sum it guards is the
         --  usual cause.
         Overflowed : constant Boolean :=
           Ada.Strings.Fixed.Index (Text, "overflow check failed") > 0
           or else Ada.Strings.Fixed.Index (Text, "range check failed") > 0;
         Lower : String := Ada.Characters.Handling.To_Lower (Line);
         Said  : Unbounded_String;

         function Ada_Source return Boolean
         is (Path'Length > 4
             and then Ada.Characters.Handling.To_Lower (Path (Path'Last - 3 .. Path'Last)) in ".adb" | ".ads");

         --  Whether Word stands in the line as a word of its own.
         function Has_Word (Word : String) return Boolean is
            At_Word : Natural := Ada.Strings.Fixed.Index (Lower, Word);
         begin
            while At_Word > 0 loop
               if (At_Word = Lower'First or else not Name_Char (Lower (At_Word - 1)))
                 and then (At_Word + Word'Length > Lower'Last
                           or else not Name_Char (Lower (At_Word + Word'Length)))
               then
                  return True;
               end if;
               At_Word := Ada.Strings.Fixed.Index (Lower, Word, At_Word + 1);
            end loop;
            return False;
         end Has_Word;

         procedure Say (Words : String) is
         begin
            Append (Said, (if Said = Null_Unbounded_String then " -- in Ada: " else "; ") & Words);
         end Say;
      begin
         if not Ada_Source then
            return "";
         end if;
         --  Strings and comments are not code.
         declare
            Quoted : Boolean := False;
         begin
            for Index in Lower'Range loop
               if Lower (Index) = '"' then
                  Quoted := not Quoted;
               elsif Quoted then
                  Lower (Index) := ' ';
               elsif Index < Lower'Last and then Lower (Index .. Index + 1) = "--" then
                  Lower (Index .. Lower'Last) := [others => ' '];
                  exit;
               end if;
            end loop;
         end;
         if Has_Word ("elif") or else Has_Word ("elseif") then
            Say ("elsif, not elif");
         end if;
         if Ada.Strings.Fixed.Index (Lower, "else if ") > 0 then
            Say ("else if opens a second if, which needs an end if of its own; one chain is elsif");
         end if;
         if Ada.Strings.Fixed.Index (Lower, "&&") > 0 then
            Say ("and then, not &&");
         end if;
         if Ada.Strings.Fixed.Index (Lower, "||") > 0 then
            Say ("or else, not ||");
         end if;
         if Ada.Strings.Fixed.Index (Lower, "!=") > 0 then
            Say ("/=, not !=");
         end if;
         if Ada.Strings.Fixed.Index (Lower, "==") > 0 then
            Say ("=, not ==");
         end if;
         --  A plain and or or in a line that overflowed: both sides are
         --  worked out whatever the first is. qwen3-8b guarded
         --  Integer'Last - B with B > 0 and, and it overflowed for every
         --  negative B, run after run.
         if Overflowed and then Has_Word ("and") and then Ada.Strings.Fixed.Index (Lower, "and then") = 0 then
            Say ("and works out both sides even where the first is False; a guard that keeps the second"
                 & " from overflowing needs and then");
         end if;
         if Overflowed and then Has_Word ("or") and then Ada.Strings.Fixed.Index (Lower, "or else") = 0 then
            Say ("or works out both sides even where the first is True; a guard needs or else");
         end if;
         --  The guard's own sum overflowing: T'Last - X for a negative X,
         --  T'First - X for a positive one. qwen3-8b guarded the sum with
         --  A > Integer'Last - B, and seven rewrites kept that guard, each
         --  told only that line 5 overflowed.
         if Overflowed then
            for Bound in 1 .. 2 loop
               declare
                  Mark  : constant String := (if Bound = 1 then "'last - " else "'first - ");
                  At_It : constant Natural := Ada.Strings.Fixed.Index (Lower, Mark);
                  Last  : Natural := At_It + Mark'Length - 1;
               begin
                  if At_It > 0 then
                     while Last < Lower'Last and then Name_Char (Lower (Last + 1)) loop
                        Last := Last + 1;
                     end loop;
                     declare
                        Low     : constant String := Lower (At_It + Mark'Length .. Last);
                        --  As the line spells it: Lower numbers from one.
                        Operand : constant String :=
                          Line (Line'First + (At_It + Mark'Length - Lower'First)
                                .. Line'First + (Last - Lower'First));
                        Sign    : constant String := (if Bound = 1 then " > 0" else " < 0");
                     begin
                        if Low /= ""
                          and then Ada.Strings.Fixed.Index (Lower, Low & Sign) = 0
                          and then Ada.Strings.Fixed.Index (Lower, Low & " >= 0") = 0
                          and then Ada.Strings.Fixed.Index (Lower, Low & " <= 0") = 0
                        then
                           Say ((if Bound = 1 then "T'Last - " & Operand & " itself overflows where "
                                   & Operand & " is negative"
                                 else "T'First - " & Operand & " itself overflows where " & Operand
                                   & " is positive")
                                & "; test its sign first: " & Operand & Sign & " and then the comparison");
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;
         if Ada.Strings.Fixed.Index (Lower, "+=") > 0 or else Ada.Strings.Fixed.Index (Lower, "-=") > 0
           or else Ada.Strings.Fixed.Index (Lower, "++") > 0
         then
            Say ("X := X + 1, not += or ++");
         end if;
         --  And the line as Ada writes it, to copy: told and then eleven
         --  times, qwen3-8b kept its and -- the words did not reach it, a
         --  line it can take as it stands may.
         declare
            Fixed : Unbounded_String;
            At_C  : Natural := Lower'First;

            --  Lower's place in Line: To_Lower numbers from one.
            function Of_Line (Index : Positive) return Character
            is (Line (Line'First + (Index - Lower'First)));

            function Starts (Index : Positive; Word : String) return Boolean
            is (Index + Word'Length - 1 <= Lower'Last
                and then Lower (Index .. Index + Word'Length - 1) = Word);

            function Word_At (Index : Positive; Word : String) return Boolean
            is (Starts (Index, Word)
                and then (Index = Lower'First or else not Name_Char (Lower (Index - 1)))
                and then (Index + Word'Length > Lower'Last or else not Name_Char (Lower (Index + Word'Length))));
         begin
            while At_C <= Lower'Last loop
               if Word_At (At_C, "elif") then
                  Append (Fixed, "elsif");
                  At_C := At_C + 4;
               elsif Word_At (At_C, "elseif") then
                  Append (Fixed, "elsif");
                  At_C := At_C + 6;
               elsif Starts (At_C, "&&") then
                  Append (Fixed, "and then");
                  At_C := At_C + 2;
               elsif Starts (At_C, "||") then
                  Append (Fixed, "or else");
                  At_C := At_C + 2;
               elsif Starts (At_C, "!=") then
                  Append (Fixed, "/=");
                  At_C := At_C + 2;
               elsif Starts (At_C, "==") then
                  Append (Fixed, "=");
                  At_C := At_C + 2;
               elsif Overflowed and then Word_At (At_C, "and") and then not Starts (At_C + 3, " then") then
                  Append (Fixed, "and then");
                  At_C := At_C + 3;
               elsif Overflowed and then Word_At (At_C, "or") and then not Starts (At_C + 2, " else") then
                  Append (Fixed, "or else");
                  At_C := At_C + 2;
               else
                  Append (Fixed, Of_Line (At_C));
                  At_C := At_C + 1;
               end if;
            end loop;
            if To_String (Fixed) /= Line then
               Say ("as Ada writes it: " & Ada.Strings.Fixed.Trim (To_String (Fixed), Ada.Strings.Both));
            end if;
         end;
         return To_String (Said);
      end Ada_Slips;

      --  The project file a name means: itself, or the one file whose
      --  path ends in it.
      function Resolved (Name : String) return String is
         Found : Unbounded_String;
         Count : Natural := 0;
      begin
         for Path of Known loop
            if Path = Name then
               return Path;
            elsif Path'Length > Name'Length
              and then Path (Path'Last - Name'Length .. Path'Last) = "/" & Name
            then
               Found := To_Unbounded_String (Path);
               Count := Count + 1;
            end if;
         end loop;
         return (if Count = 1 then To_String (Found) else "");
      end Resolved;

      --  Line Number of a project file, without its line end.
      function Line_Of (Path : String; Number : Positive) return String is
         Held    : Unbounded_String;
         Got     : E.Error_Info;
         At_Line : Positive := 1;
         Start   : Positive;
      begin
         Files.Read_Text (Hostkit.Fs.Join (Project, Path), Held, Got);
         if E.Is_Error (Got) then
            return "";
         end if;
         declare
            Whole : constant String := To_String (Held);
         begin
            Start := Whole'First;
            for Position in Whole'Range loop
               if Whole (Position) = ASCII.LF then
                  if At_Line = Number then
                     return Ada.Strings.Fixed.Trim
                       (Whole (Start .. Position - 1), Ada.Strings.Maps.Null_Set,
                        Ada.Strings.Maps.To_Set (ASCII.CR));
                  end if;
                  At_Line := At_Line + 1;
                  Start := Position + 1;
               end if;
            end loop;
            return (if At_Line = Number and then Start <= Whole'Last then Whole (Start .. Whole'Last) else "");
         end;
      end Line_Of;
   begin
      while Index <= Text'Last and then Given < 3 loop
         if Text (Index) = ':' and then Index > Text'First and then Name_Char (Text (Index - 1))
           and then Index < Text'Last and then Text (Index + 1) in '0' .. '9'
         then
            declare
               First : Natural := Index - 1;
               Last  : Natural := Index + 1;
            begin
               while First > Text'First and then Name_Char (Text (First - 1)) loop
                  First := First - 1;
               end loop;
               while Last < Text'Last and then Text (Last + 1) in '0' .. '9' loop
                  Last := Last + 1;
               end loop;
               declare
                  Name   : constant String := Text (First .. Index - 1);
                  Number : constant String := Text (Index + 1 .. Last);
                  Path   : constant String :=
                    (if Ada.Strings.Fixed.Index (Name, ".") > 0 and then Number'Length <= 7
                     then Resolved (Name) else "");
               begin
                  if Path /= "" and then not Seen.Contains (Path & ":" & Number)
                    and then Natural'Value (Number) > 0
                  then
                     Seen.Append (Path & ":" & Number);
                     declare
                        Line : constant String := Line_Of (Path, Natural'Value (Number));
                     begin
                        if Line /= "" then
                           Append (Said, ASCII.LF & Path & " line " & Number & " is: "
                                   & Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both) & Ada_Slips (Path, Line));
                           Given := Given + 1;
                        end if;
                     end;
                  end if;
               end;
               Index := Last + 1;
            end;
         else
            Index := Index + 1;
         end if;
      end loop;
      return To_String (Said);
   end Quoted_Lines;

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
      Starting : access procedure (Agent_Id, Manifest_Id, Invocation_Id : String) := null)
   is
      Faulted : Boolean := False;
   begin
      --  A fault anywhere in the work is a way it ended, as any other is:
      --  said as one, and what follows -- the task set aside, its leases
      --  let go, its call ended -- still done.
      begin
         Execute_Work (Item, Task_Id, Runner, Model, Result, Status, Starting);
      exception
         when Fault : others =>
            Status := E.Unexpected (Fault, "work on " & Task_Id);
            Faulted := True;
      end;
      Execution.Watch_Lease (null);

      --  Stopped by a fault part way, nothing of how far it got is known
      --  here: put right as an opening puts right work a stopped process
      --  left -- its hold on the task let go, then the task set aside with
      --  what it changed named, its workspace given up, its helpers
      --  stopped, its agent ended.
      if Faulted and then Length (Result.Agent_Id) > 0
        and then Tasks.State_Of (Item, Task_Id) = "running"
        and then Leases.Owner_Of (Item, Lease_Of (Task_Id)) = To_String (Result.Agent_Id)
      then
         declare
            Change : Stores.Transaction;
            Let_Go : E.Error_Info;
            Said   : Name_Lists.Vector;
         begin
            --  Every hold of its own let go: the task's, and the project's
            --  and its component's, which a recovery leaves to their owner.
            Leases.Release (Item, Change, Lease_Of (Task_Id), To_String (Result.Agent_Id), Let_Go);
            for Held of Name_Lists.Vector'([Tasks.Project_Lease,
                                            (if Component_Of (Item, Task_Id) = "" then ""
                                             else Tasks.Component_Lease (Component_Of (Item, Task_Id)))])
            loop
               if E.Is_Ok (Let_Go) and then Held /= ""
                 and then Leases.Owner_Of (Item, Held) = To_String (Result.Agent_Id)
               then
                  Leases.Release (Item, Change, Held, To_String (Result.Agent_Id), Let_Go);
               end if;
            end loop;
            if E.Is_Ok (Let_Go) then
               Stores.Commit (Item, Change, Let_Go);
            end if;
            if E.Is_Ok (Let_Go) then
               Recover (Item, Said, Let_Go);
               Result.Final_State := To_Unbounded_String (Tasks.State_Of (Item, Task_Id));
               Result.Reason := To_Unbounded_String ("its work stopped: " & Why_Of (Status));
            end if;
         end;
      end if;

      --  Whatever way the work ended, a task it started is not left running
      --  with nobody working it: set aside, with why, its agent ended and
      --  what it held let go -- every path, including those no one wrote a
      --  conclusion for.
      declare
         Agent : constant String := To_String (Result.Agent_Id);
      begin
         --  Its own by the lease's record, as Execute_Work asks it.
         if Agent /= "" and then Tasks.State_Of (Item, Task_Id) = "running"
           and then Leases.Owner_Of (Item, Lease_Of (Task_Id)) = Agent
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
                  if E.Is_Ok (Moved) and then Leases.Owner_Of (Item, Held) = Agent then
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

      --  Its model call recorded as started and never ended -- the work
      --  stopped before the model ran: its workspace, its prompt, its
      --  files not made -- is ended now, failed, with why: "started" is
      --  said of a call that crossed into the model, and an opening would
      --  have found it only later.
      if Length (Result.Invocation_Id) > 0
        and then Invocations.State_Of (Item, To_String (Result.Invocation_Id)) = "started"
      then
         declare
            Change : Stores.Transaction;
            Ended  : E.Error_Info;
         begin
            Invocations.Finish
              (Item, Change, To_String (Result.Invocation_Id), Invocations.Failed, (others => 0), "",
               (if Faulted then "the work stopped on a fault, where in it is not known, and what the model"
                                & " spent with it"
                else "the work stopped before its model ran")
               & (if E.Is_Error (Status) then ": " & Why_Of (Status)
                  elsif Length (Result.Reason) > 0 then ": " & To_String (Result.Reason)
                  else ""),
               Ended);
            if E.Is_Ok (Ended) then
               Stores.Commit (Item, Change, Ended);
            end if;
         end;
      end if;

      --  The run over, its baseline goes with it: left, it would stand for
      --  what the files were before a later run that kept none. A state
      --  that will not read may be running still: kept for the opening
      --  that puts it right.
      if Tasks.State_Of (Item, Task_Id) not in "running" | "" then
         Files.Discard (Before_File (Item, Task_Id));
      end if;
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
