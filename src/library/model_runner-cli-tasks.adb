with Ada.Characters.Handling;
with Ada.Text_IO;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Maps.Constants;
with Ada.Strings.Unbounded;

with Hostkit;
with Hostkit.Fs;
with Hostkit.Process;

with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Git;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Framework.Work;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Permissions;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Transitions;
with Model_Runner.Localization;
with Model_Runner.Text;

package body Model_Runner.CLI.Tasks is

   use Ada.Strings.Unbounded;
   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package Loc renames Model_Runner.Localization;
   package Pres renames Model_Runner.Presentation;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package T renames Model_Runner.Text;
   package Tk renames Model_Runner.Framework.Tasks;

   --  A parent's parts let go -- cancelled or rejected -- as said beside
   --  its parts being settled: " (TASK-006 cancelled: its work not done)".
   function Cancelled_Parts (Store : Model_Runner.Framework.Stores.Store; Parent : String) return String is
      Said : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Child of Model_Runner.Framework.Tasks.Children (Store, Parent) loop
         if Model_Runner.Framework.Tasks.State_Of (Store, Child) in "cancelled" | "rejected" then
            Ada.Strings.Unbounded.Append
              (Said, (if Ada.Strings.Unbounded.Length (Said) = 0 then "" else ", ") & Child & " "
                     & Model_Runner.Framework.Tasks.State_Of (Store, Child));
         end if;
      end loop;
      return (if Ada.Strings.Unbounded.Length (Said) = 0 then ""
              else " (" & Ada.Strings.Unbounded.To_String (Said) & ": its work not done)");
   end Cancelled_Parts;

   function Joined
     (Items : Model_Runner.Framework.Name_Lists.Vector) return String
   is
      Result : Unbounded_String;
   begin
      for Item of Items loop
         if Result /= Null_Unbounded_String then
            Append (Result, ", ");
         end if;
         Append (Result, Item);
      end loop;
      return To_String (Result);
   end Joined;

   --  The files of a workspace in conflict with the project, or where it
   --  names none, what to look at.
   --  Each file in conflict as the command that shows its two versions:
   --  the workspace's beside the project's, ready to be pasted.
   function In_Conflict
     (Store : Model_Runner.Framework.Stores.Store;
      Space : String;
      Tree  : String := "") return String
   is
      Files : constant Model_Runner.Framework.Name_Lists.Vector :=
        (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
         else Model_Runner.Framework.Workspaces.Conflict_Files (Store, Space));
      Shown : Unbounded_String;
   begin
      if Files.Is_Empty or else Tree = "" then
         return (if Files.Is_Empty then "the files both changed" else Joined (Files));
      end if;
      for File of Files loop
         declare
            Merged : constant String :=
              Ada.Directories.Containing_Directory (Tree) & "/merge/" & File;
            Project : constant String :=
              Ada.Directories.Containing_Directory (Model_Runner.Framework.Stores.Root (Store));
         begin
            --  Taken away in the project: nothing there to compare, and
            --  keeping that is removing the workspace's.
            if not Ada.Directories.Exists (Project & "/" & File) then
               Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ")
                              & File & " was deleted in the project -- rm " & Tree & "/" & File
                              & " keeps it deleted");
            else
               Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ")
                              & "diff " & Tree & "/" & File & " " & File
                              & (if Ada.Directories.Exists (Merged)
                                 then ", and the two joined with what both touched marked: " & Merged
                                 else ""));
            end if;
         end;
      end loop;
      return To_String (Shown);
   end In_Conflict;

   --  What gives a kind's tasks their permissions, as said to a person:
   --  the kind where it names any, the project where it does not.
   function Giver (Store : Model_Runner.Framework.Stores.Store; Kind : String) return String is
      Config : Model_Runner.Framework.Records.Item;
   begin
      Config := Model_Runner.Framework.Configurations.Required (Store);
      for Index in 1 .. Model_Runner.Framework.Records.Field_Count (Config) loop
         if Ada.Strings.Fixed.Index
              (Model_Runner.Framework.Records.Field_Name (Config, Index), "map.permission.kind." & Kind & ".") = 1
           or else Model_Runner.Framework.Records.Field_Name (Config, Index) = "map.permission.kind." & Kind
         then
            return "its kind " & Kind;
         end if;
      end loop;
      return "the project";
   end Giver;

   --  The level that withholds what a task asks beyond its kind's: the
   --  project, where the project does not grant it -- the kind may -- or
   --  the kind.
   function Withholder
     (Store : Model_Runner.Framework.Stores.Store;
      Kind  : String;
      Asked : Model_Runner.Framework.Permissions.Permission_Set) return String
   is
      package Pm renames Model_Runner.Framework.Permissions;
      Project : constant Pm.Permission_Set := Pm.Effective (Store, "", "", Within_Sandbox => False);
   begin
      if (for some One in Pm.Capability => Asked (One).Granted and then not Project (One).Granted) then
         return "the project";
      end if;
      return Giver (Store, Kind);
   end Withholder;

   --  What a task's own permissions take away from its kind's -- a level
   --  that names anything grants only that -- and what it is left with.
   procedure Say_Narrowing
     (Screen  : in out Model_Runner.Presentation.Console;
      Id      : String;
      Kind    : String;
      Asked   : Model_Runner.Framework.Permissions.Permission_Set;
      Allowed : Model_Runner.Framework.Permissions.Permission_Set)
   is
      package Pm renames Model_Runner.Framework.Permissions;
      Withheld : Unbounded_String;
      Kept     : Unbounded_String;
      Said_Any : constant Boolean := (for some One in Pm.Capability => Asked (One).Granted);
   begin
      --  Nothing of its own: cleared, and its kind's is what it has.
      if not Said_Any then
         for Line of Model_Runner.Framework.Lines_Of (Pm.Image (Allowed)) loop
            Append (Kept, (if Kept = Null_Unbounded_String then "" else "; ") & Line);
         end loop;
         Pres.Put_Note
           (Screen, "cli.task.permissions_cleared",
            [Loc.Named ("name", Id), Loc.Named ("other", Kind),
             Loc.Named ("value", (if Kept = Null_Unbounded_String then "nothing" else To_String (Kept)))]);
         return;
      end if;
      for One in Pm.Capability loop
         if Allowed (One).Granted and then not Asked (One).Granted then
            Append (Withheld, (if Withheld = Null_Unbounded_String then "" else ", ") & Pm.Word (One));
         end if;
      end loop;
      for Line of Model_Runner.Framework.Lines_Of (Pm.Image (Pm.Intersect (Asked, Allowed))) loop
         Append (Kept, (if Kept = Null_Unbounded_String then "" else "; ") & Line);
      end loop;
      if Withheld /= Null_Unbounded_String then
         Pres.Put_Note
           (Screen, "cli.task.narrowed",
            [Loc.Named ("name", Id), Loc.Named ("other", Kind),
             Loc.Named ("detail", To_String (Withheld)),
             Loc.Named ("value", (if Kept = Null_Unbounded_String then "nothing" else To_String (Kept)))]);
      end if;
   end Say_Narrowing;

   ---------
   -- Run --
   ---------

   --  A capability as typed, or the nearest there is: run_check is
   --  run_tests's neighbour, "" where none is near.
   function Capability_Near (Typed : String) return String is
      package Pm renames Model_Runner.Framework.Permissions;
      Words : Model_Runner.Framework.Name_Lists.Vector;
   begin
      --  The names the agent's tools go by, and the words /task show says,
      --  as the capabilities they need.
      if Typed in "write_file" | "write_files" | "write" then
         return "write_source";
      elsif Typed in "read_file" | "list_directory" | "read" then
         return "read_source";
      elsif Typed in "run_checks" | "checks" | "run_check" | "tests" then
         return "run_tests";
      elsif Typed in "delegate" | "helpers" then
         return "create_children";
      elsif Typed in "network" | "http_get" | "web_search" then
         return "use_network";
      end if;
      for One in Pm.Capability loop
         if Pm.Word (One) = Typed then
            return Typed;
         end if;
         Words.Append (Pm.Word (One));
      end loop;
      --  Of the same start -- run_ -- the one sharing most after it.
      declare
         Near : constant String := Model_Runner.Framework.Nearest (Typed, Words);
      begin
         if Near /= "" then
            return Near;
         end if;
         for Word of Words loop
            if Typed'Length >= 4 and then Word'Length >= 4
              and then Word (Word'First .. Word'First + 3) = Typed (Typed'First .. Typed'First + 3)
            then
               return Word;
            end if;
         end loop;
         return "";
      end;
   end Capability_Near;

   --  Words in order: task identifiers lowest first.
   function Sorted_Words
     (Words : Model_Runner.Framework.Name_Lists.Vector) return Model_Runner.Framework.Name_Lists.Vector
   is
      package Sorting is new Model_Runner.Framework.Name_Lists.Generic_Sorting;
      Result : Model_Runner.Framework.Name_Lists.Vector := Words;
   begin
      Sorting.Sort (Result);
      return Result;
   end Sorted_Words;

   -----------------
   -- Ticked_Done --
   -----------------

   function Ticked_Done (Store : Model_Runner.Framework.Stores.Store; Task_Id : String) return String is
      package Nt renames Model_Runner.Framework.Intent;
      package Rs renames Model_Runner.Framework.Results;
      Defined : R.Item;
      Read    : E.Error_Info;
   begin
      Tk.Definition (Store, Task_Id, Defined, Read);
      if E.Is_Error (Read) then
         return "";
      end if;
      for Req of Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")) loop
         declare
            Held : Nt.Entity;
            Got  : E.Error_Info;
         begin
            Nt.Read (Store, Nt.Requirement, Req, Held, Got);
            if E.Is_Ok (Got) and then Ada.Strings.Unbounded.Index (Held.Provenance, "#") > 0 then
               for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
                  declare
                     Result_Id : constant String :=
                       (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                        then Name (Name'First .. Name'Last - 4) else Name);
                     One : Rs.Result;
                     Had : E.Error_Info;
                  begin
                     Rs.Read (Store, Result_Id, One, Had, With_Payload => False);
                     if E.Is_Ok (Had) and then One.Provenance = Held.Provenance & "#done" then
                        declare
                           Whole : constant String := To_String (Held.Provenance);
                           Mark  : constant Natural := Ada.Strings.Fixed.Index (Whole, "#");
                           Label : constant String := Whole (Mark + 1 .. Whole'Last);
                        begin
                           --  Known by a fingerprint, not a label: by its ID.
                           return (if Label'Length >= 12
                                     and then (for all C of Label => C in '0' .. '9' | 'a' .. 'f')
                                   then Req else Label)
                             & " in " & Whole (Whole'First .. Mark - 1);
                        end;
                     end if;
                  end;
               end loop;
            end if;
         end;
      end loop;
      return "";
   end Ticked_Done;

   --  A yes or no read from the person: anything else asked again, a
   --  command typed in its place said and not run, and no answer a no.
   function Answered_Yes (Screen : in out Pres.Console) return Boolean is
   begin
      return Model_Runner.CLI.Choosers.Answered_Yes (Screen);
   end Answered_Yes;

   procedure Run
     (Item   : Model_Runner.CLI.Project_Requests.Request;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Directory : constant String :=
        (if T.Is_Empty (Item.Project_Directory) then "."
         else T.To_String (Item.Project_Directory));
      --  revise, as the registers say it, is edit here.
      Action    : constant String :=
        (if T.Is_Empty (Item.Action) then "list"
         elsif T.To_String (Item.Action) = "revise" then "edit"
         else T.To_String (Item.Action));
      Argument  : constant String := T.To_String (Item.Action_Argument);

      Interactive : constant Boolean := Choosers.Is_Available (Screen);

      Store   : S.Store;
      Report  : S.Recovery_Report;
      Outcome : E.Error_Info;
      Change  : S.Transaction;

      --  A profile as the configuration writes it.
      function Profile_Text (Name : String) return String is
         Config : R.Item;
      begin
         Config := Model_Runner.Framework.Configurations.Required (Store);
         return R.Get (Config, "profile." & Name);
      end Profile_Text;

      --  A field of a task's state record.
      function State_Field (Id, Name : String) return String is
         Held : R.Item;
         Read : E.Error_Info;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", Held, Read);
         return (if E.Is_Error (Read) then "" else R.Get (Held, Name));
      end State_Field;

      --  A task's state as /task list says it, the record's beside it
      --  where they differ: blocked, stopped.
      function Moved_State (Id : String) return String;

      --  How an action is written, as one line.
      function Usage_Of (Name : String) return String
      is (if Name = "split" then "/task split TASK-ID Part A; Part B"
          elsif Name = "move" then "/task move TASK-ID STATE [WHY] -- STATE is accepted, blocked, cancelled,"
                                   & " candidate, failed or rejected"
          elsif Name = "depend" then "/task depend TASK-ID OTHER-ID, or /task depend TASK-ID OTHER-ID remove"
          elsif Name in "grant" | "withhold" then "/task " & Name & " TASK-ID CAPABILITY"
                                                   & (if Name = "grant" then " [roots=PATH|PATH]" else "")
          elsif Name = "note" then "/task note TASK-ID TEXT"
          elsif Name = "edit" then "/task edit TASK-ID NAME=VALUE ..., as title=... or kind=test"
          elsif Name = "link" then "/task link TASK-ID REQ-ID"
          elsif Name = "new" then "/task new TITLE kind=KIND"
          elsif Name = "reconsider" then "/task reconsider TASK-ID -- a rejected task back to a candidate"
          elsif Name = "rehome" then "/task rehome OLD-COMPONENT NEW-COMPONENT -- its tasks moved to the new one"
          elsif Name in "show" | "diff" | "audit" | "context" | "accept" | "reject" | "cancel" | "reopen"
                      | "complete" | "verify" | "integrate" | "step"
          then "/task " & Name & " TASK-ID, as /task " & Name & " TASK-001 or /task " & Name & " 1"
          else "");

      procedure Fail (Condition : E.Error_Info) is
         Said : E.Error_Info := Condition;
         Name : constant String := E.Text_Of (Condition, "name");
         From : constant String := E.Text_Of (Condition, "value");
      begin
         --  A move refused: its state said as /task list says it, and the
         --  way on where there is one.
         if E."=" (Condition.Code, E.Framework_Transition_Invalid)
           and then Ada.Strings.Fixed.Index (Name, "TASK-") = Name'First
           and then From /= "" and then Tk.State_Of (Store, Name) = From
         then
            for Index in 1 .. Said.Parameter_Total loop
               if T.To_String (Said.Parameters (Index).Name) = "value" then
                  Said.Parameters (Index).Text_Value := T.To_Bounded (Moved_State (Name));
               end if;
            end loop;
            Pres.Report (Screen, Said);
            if E.Text_Of (Condition, "expected") = "rejected" and then From in "accepted" | "blocked" then
               Pres.Put_Note (Screen, "cli.next.cancel_not_reject", [Loc.Named ("name", Name)]);
            end if;
         else
            Pres.Report (Screen, Condition);
         end if;
         --  Something left out: how the action is written, with an example.
         if E."=" (Condition.Code, E.Framework_Input_Missing) and then Usage_Of (Action) /= "" then
            Pres.Put_Note (Screen, "cli.task.usage_line", [Loc.Named ("value", Usage_Of (Action))]);
         end if;
         Status := E.Exit_Status (Condition);
      end Fail;

      --  Commit a change, then say which tasks it made ready.
      --  The tasks that became ready, said once what made them so is.
      Became_Ready : Model_Runner.Framework.Name_Lists.Vector;

      --  The tasks said ready already, so as not to say them again.
      Said_Ready : Model_Runner.Framework.Name_Lists.Vector;

      --  Requirements said to have moved, each once.
      Moved_Said : Model_Runner.Framework.Name_Lists.Vector;

      procedure Commit is
         Became : Model_Runner.Framework.Name_Lists.Vector;
      begin
         S.Commit (Store, Change, Outcome);
         if E.Is_Ok (Outcome) then
            Tk.Recompute_Readiness (Store, Change, Became, Outcome);
         end if;
         if E.Is_Ok (Outcome) then
            S.Commit (Store, Change, Outcome);
         end if;
         if E.Is_Ok (Outcome) then
            Became_Ready.Append (Became);
         end if;
         --  What the requirements its tasks serve are now, judged here and
         --  said here, not at the next command's opening.
         if E.Is_Ok (Outcome) then
            declare
               Moved : Model_Runner.Framework.Name_Lists.Vector;
               Judged : E.Error_Info;
            begin
               Model_Runner.Framework.Verification.Reevaluate_Requirements (Store, Change, Moved, Judged);
               if E.Is_Ok (Judged) then
                  S.Commit (Store, Change, Judged);
               end if;
               if E.Is_Ok (Judged) then
                  for Id of Moved loop
                     if not Moved_Said.Contains (Id) then
                        Moved_Said.Append (Id);
                        Pres.Put_Message
                          (Screen, "cli.work.requirement",
                           [Loc.Named ("name", Id),
                            Loc.Named ("value", Model_Runner.Framework.Intent.State_Of
                                                  (Store, Model_Runner.Framework.Intent.Requirement, Id))]);
                     end if;
                  end loop;
               end if;
            end;
         end if;
      end Commit;

      function Needs_Task return Boolean is
      begin
         if Argument = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "task");
            Fail (Outcome);
            return False;
         end if;

         --  One that is not there is said so before anything is done to it.
         declare
            Space : constant Natural := Ada.Strings.Fixed.Index (Argument, " ");
            Id    : constant String :=
              (if Space = 0 then Argument else Argument (Argument'First .. Space - 1));
         begin
            if Ada.Characters.Handling.To_Lower (Id) = "all" then
               --  all where the action takes one at a time: said so.
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the task to " & Action);
               E.Add_Text (Outcome, "value", "all");
               E.Add_Text (Outcome, "detail", "/task " & Action & " takes one task at a time; all is for accept,"
                           & " reject, complete, verify and integrate");
               Fail (Outcome);
               return False;
            --  A state where a task is named: no task, said with what takes
            --  the tasks in it.
            elsif Ada.Characters.Handling.To_Lower (Id)
                    in "failed" | "stopped" | "blocked" | "ready" | "candidate" | "candidates" | "accepted"
                     | "refused" | "complete" | "cancelled" | "rejected"
            then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the task to " & Action);
               E.Add_Text (Outcome, "value", Id);
               E.Add_Text (Outcome, "detail", Id & " is a state, not a task; /task list state="
                           & Ada.Characters.Handling.To_Lower (Id) & " lists those in it"
                           & (if Action = "accept"
                              and then Ada.Characters.Handling.To_Lower (Id) in "failed" | "stopped" | "blocked"
                              then ", and /task accept all takes up the failed and stopped ones"
                              elsif Action in "accept" | "reject"
                              then ", and /task " & Action & " all takes every candidate"
                              else ""));
               Fail (Outcome);
               return False;
            elsif Tk.State_Of (Store, Id) = "" then
               --  Named, with the nearest there is, and where they are.
               declare
                  Near : constant String := Model_Runner.Framework.Nearest (Id, Tk.List (Store));
               begin
                  Outcome := E.Make (E.Framework_Not_Found);
                  E.Add_Text (Outcome, "name", Id);
                  Fail (Outcome);
                  --  The nearest there is after the sentence, not inside it.
                  if Near /= "" then
                     Pres.Put_Note (Screen, "cli.task.did_you_mean", [Loc.Named ("name", Near)]);
                  end if;
                  Pres.Put_Note (Screen, "cli.next.task_list");
               end;
               return False;
            end if;
         end;
         return True;
      end Needs_Task;

      --  The tasks, narrowed by what was given as NAME=VALUE: state (ready
      --  among them, derived), kind, component, requirement, origin and
      --  parent.
      --  The tasks, the ready ones first: what can be worked now leads.
      function Ready_First return Model_Runner.Framework.Name_Lists.Vector is
         Result : Model_Runner.Framework.Name_Lists.Vector;
         Rest   : Model_Runner.Framework.Name_Lists.Vector;
      begin
         for Id of Tk.List (Store) loop
            if Tk.State_Of (Store, Id) = "accepted" and then Tk.Ready (Store, Id).Ready then
               Result.Append (Id);
            else
               Rest.Append (Id);
            end if;
         end loop;
         Result.Append (Rest);
         return Result;
      end Ready_First;

      --  A task's state as /task list says it, and every message after
      --  it: accepted is ready or waiting, a parent blocked on its parts
      --  is waiting for them, work in a workspace waits to be taken in.
      --  Whether every requirement a task serves is retired.
      function Serves_Only_Retired (Id : String) return Boolean is
         Defined : R.Item;
         Read    : E.Error_Info;
      begin
         Tk.Definition (Store, Id, Defined, Read);
         declare
            Served : constant Model_Runner.Framework.Name_Lists.Vector :=
              Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"));
         begin
            return E.Is_Ok (Read) and then not Served.Is_Empty
              and then (for all Req of Served =>
                          Model_Runner.Framework.Intent.State_Of (Store, Model_Runner.Framework.Intent.Requirement, Req)
                            in "obsolete" | "superseded" | "rejected");
         end;
      end Serves_Only_Retired;

      --  The parts of the task shown that failed, a space apart.
      function Failed_Parts return String is
         Said : Unbounded_String;
      begin
         for Child of Tk.Children (Store, Argument) loop
            if Tk.State_Of (Store, Child) = "failed" then
               Append (Said, (if Said = Null_Unbounded_String then "" else " ") & Child);
            end if;
         end loop;
         return To_String (Said);
      end Failed_Parts;

      --  A reason as a person reads it: a task's parts, not its children.
      function Listed_State (Id : String) return String;

      function Parts_Worded (Text : String) return String is
         At_Children : constant Natural := Ada.Strings.Fixed.Index (Text, "waiting for its children");
         At_Child    : constant Natural := Ada.Strings.Fixed.Index (Text, "its child ");
      begin
         if At_Children > 0 then
            return Text (Text'First .. At_Children - 1) & "waiting for its parts"
              & Parts_Worded (Text (At_Children + 24 .. Text'Last));
         elsif At_Child > 0 then
            --  its child TASK-3 is accepted: its part, in the list's word.
            declare
               Rest  : constant String := Text (At_Child + 10 .. Text'Last);
               Is_At : constant Natural := Ada.Strings.Fixed.Index (Rest, " is ");
               Id    : constant String := (if Is_At = 0 then "" else Rest (Rest'First .. Is_At - 1));
            begin
               if Id = "" or else Ada.Strings.Fixed.Index (Id, "TASK-") /= Id'First then
                  return Text;
               end if;
               return Text (Text'First .. At_Child - 1) & "its part " & Id & " is " & Listed_State (Id);
            end;
         end if;
         return Text;
      end Parts_Worded;

      function Listed_State (Id : String) return String is
         State : constant String := Tk.State_Of (Store, Id);
         Space : constant String :=
           (if State = "verification"
            then Model_Runner.Framework.Workspaces.Active_For (Store, Id) else "");
         --  Work waiting to be taken in says so, and whether it is in
         --  conflict: it waits on a person, not on the harness.
      begin
         return
           (if State = "accepted" and then Tk.Ready (Store, Id).Ready then "ready"
            elsif State = "accepted"
              and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                          Ada.Strings.Fixed.Index (Reason, ", which is cancelled") > 0
                          or else Ada.Strings.Fixed.Index (Reason, ", which is rejected") > 0)
            then "waiting on an ended task"
            --  Held back by what it may do, not by another task: refused.
            elsif State = "accepted"
              and then not (for some Reason of Tk.Ready (Store, Id).Reasons =>
                              Ada.Strings.Fixed.Index (Reason, "waits for") > 0
                              or else Ada.Strings.Fixed.Index (Reason, "waiting for") > 0
                              or else Ada.Strings.Fixed.Index (Reason, "a candidate") > 0)
              and then Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= ""
            then "refused"
            elsif State = "accepted" then "waiting"
            elsif Space /= ""
              and then not Model_Runner.Framework.Workspaces.Conflict_Files
                             (Store, Space, Unsettled_Only => True).Is_Empty
            then "conflict"
            elsif Space /= ""
              and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                          Ada.Strings.Fixed.Index (Reason, "did not pass") > 0)
            then "checks failed"
            elsif Space /= "" then "to integrate"
            --  Waiting for its parts -- one failed among them too, as
            --  /state says it, its why naming the one that failed.
            elsif State = "blocked"
              and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                          Ada.Strings.Fixed.Index (Reason, "waiting for its children") > 0
                          or else Ada.Strings.Fixed.Index (Reason, "its child ") = Reason'First)
            then "waiting for parts"
            --  Stopped by the person, not by anything wrong with it.
            elsif State = "blocked"
              and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                          Ada.Strings.Fixed.Index (Reason, "you stopped its work") > 0)
            then "stopped"
            --  Open, and serving only what is retired: work for nothing.
            elsif State in "candidate" | "accepted" and then Serves_Only_Retired (Id) then "serves retired"
            else State);
      end Listed_State;

      --  A state as a move says it: the state itself still named, with how
      --  it stands within it -- accepted, ready -- as /task show has it.
      function Moved_State (Id : String) return String
      is (if Listed_State (Id) = Tk.State_Of (Store, Id) then Tk.State_Of (Store, Id)
          --  Accepted, and its permissions keep it from the work: said so.
          elsif Listed_State (Id) = "refused"
          then "refused (" & Tk.State_Of (Store, Id) & ", but its permissions keep it from starting)"
          --  Named as /state counts them: no blocked beside.
          elsif Listed_State (Id) in "waiting for parts" | "stopped" | "to integrate" | "conflict" | "checks failed"
          then Listed_State (Id)
          --  Complete, its work put back out since.
          elsif Tk.State_Of (Store, Id) = "complete" and then State_Field (Id, "undone_by") /= ""
          then "complete, its work undone"
          --  As /task list names it first, the state it is a case of after.
          else Listed_State (Id) & " (" & Tk.State_Of (Store, Id) & ")");

      --  Every state /task list shows, as its state= filter takes them.
      States_Said : constant String :=
        "a task is candidate, accepted (ready, waiting, refused -- its permissions keep it from the work --"
        & " or waiting on an ended task), running, verification"
        & " (to integrate, conflict or checks failed), blocked (waiting for parts, or stopped), complete,"
        & " failed, cancelled or rejected, and an open one serving only what is retired serves retired";

      procedure Show_List is
         Listed : constant Model_Runner.Framework.Name_Lists.Vector := Ready_First;
         Shown  : Natural := 0;

         --  What it was asked to list, as typed: words and NAME=VALUE.
         function Filters_Said return String is
            Said : Unbounded_String :=
              To_Unbounded_String (Ada.Strings.Fixed.Trim (Argument, Ada.Strings.Both));
         begin
            for Index in 1 .. Item.Input_Count loop
               Append (Said, (if Said = Null_Unbounded_String then "" else " ") & T.To_String (Item.Inputs (Index)));
            end loop;
            return To_String (Said);
         end Filters_Said;

         function Wanted (Name : String) return String is
         begin
            for Index in 1 .. Item.Input_Count loop
               declare
                  Pair : constant String := T.To_String (Item.Inputs (Index));
                  Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
               begin
                  if Cut > Pair'First and then Pair (Pair'First .. Cut - 1) = Name then
                     --  to-integrate, as Tab offers it, is to integrate.
                     return (if Name = "state"
                             then Ada.Strings.Fixed.Translate
                                    (Pair (Cut + 1 .. Pair'Last), Ada.Strings.Maps.To_Mapping ("-_", "  "))
                             else Pair (Cut + 1 .. Pair'Last));
                  end if;
               end;
            end loop;

            --  Or written after list without --set, as the session takes
            --  them: list kind=bugfix state=ready.
            declare
               Start : Natural := Argument'First;
            begin
               for Index in Argument'First .. Argument'Last + 1 loop
                  if Index > Argument'Last or else Argument (Index) = ' ' then
                     declare
                        Pair : constant String := Argument (Start .. Index - 1);
                        Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
                     begin
                        if Cut > Pair'First and then Pair (Pair'First .. Cut - 1) = Name then
                           --  to-integrate and to_integrate as to integrate.
                           return (if Name = "state"
                                   then Ada.Strings.Fixed.Translate
                                          (Pair (Cut + 1 .. Pair'Last), Ada.Strings.Maps.To_Mapping ("-_", "  "))
                                   else Pair (Cut + 1 .. Pair'Last));

                        --  A word alone is a state: list ready, list blocked.
                        elsif Name = "state" and then Cut = 0 and then Pair /= "" then
                           return Pair;
                        end if;
                     end;
                     Start := Index + 1;
                  end if;
               end loop;
            end;
            return "";
         end Wanted;
      begin
         --  A filter it has not is said, not ignored.
         for Index in 1 .. Item.Input_Count loop
            declare
               Pair : constant String := T.To_String (Item.Inputs (Index));
               Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
               Name : constant String := (if Cut = 0 then Pair else Pair (Pair'First .. Cut - 1));
            begin
               if Name not in "state" | "kind" | "component" | "origin" | "parent" | "requirement"
               then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "a filter of /task list");
                  E.Add_Text (Outcome, "value", Name);
                  E.Add_Text (Outcome, "detail", "the filters are state, kind, component, origin,"
                              & " parent and requirement");
                  Fail (Outcome);
                  return;
               --  A kind or a component given is one the project has.
               elsif Name = "kind" and then Cut > 0
                 and then not Tk.Kinds (Store).Contains (Pair (Cut + 1 .. Pair'Last))
               then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "a kind of /task list");
                  E.Add_Text (Outcome, "value", Pair (Cut + 1 .. Pair'Last));
                  E.Add_Text (Outcome, "detail", "the project's kinds are " & Joined (Tk.Kinds (Store)));
                  Fail (Outcome);
                  return;
               elsif Name = "component" and then Cut > 0
                 and then not Tk.Components (Store).Contains (Pair (Cut + 1 .. Pair'Last))
               then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "a component of /task list");
                  E.Add_Text (Outcome, "value", Pair (Cut + 1 .. Pair'Last));
                  E.Add_Text (Outcome, "detail", "the project's components are " & Joined (Tk.Components (Store)));
                  Fail (Outcome);
                  return;
               --  A state given as state=S is one a task can be in.
               elsif Name = "state" and then Cut > 0
                 and then Ada.Strings.Fixed.Translate (Pair (Cut + 1 .. Pair'Last),
                                                       Ada.Strings.Maps.To_Mapping ("-_", "  "))
                            not in "candidate" | "accepted" | "ready" | "waiting" | "running" | "verification"
                                 | "conflict" | "refused" | "blocked" | "complete" | "failed" | "cancelled" | "rejected"
                                 | "stopped" | "waiting for parts" | "to integrate" | "checks failed"
                                 | "serves retired" | "waiting on an ended task"
               then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "a state of /task list");
                  E.Add_Text (Outcome, "value", Pair (Cut + 1 .. Pair'Last));
                  E.Add_Text (Outcome, "detail", States_Said);
                  Fail (Outcome);
                  return;
               end if;
            end;
         end loop;
         --  A word after list is a filter or a state; a state it names is
         --  one a task can be in -- a misspelt one is said, not answered
         --  with nothing.
         declare
            States : Model_Runner.Framework.Name_Lists.Vector;
            Start  : Natural := Argument'First;
         begin
            States.Append ("candidate");
            States.Append ("accepted");
            States.Append ("ready");
            States.Append ("waiting");
            States.Append ("running");
            States.Append ("verification");
            States.Append ("conflict");
            States.Append ("refused");
            States.Append ("blocked");
            States.Append ("complete");
            States.Append ("failed");
            States.Append ("cancelled");
            States.Append ("rejected");
            States.Append ("stopped");
            States.Append ("refused");
            States.Append ("serves");
            for Index in Argument'First .. Argument'Last + 1 loop
               if Index > Argument'Last or else Argument (Index) = ' ' then
                  declare
                     Pair : constant String := Argument (Start .. Index - 1);
                     Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
                     Name : constant String := (if Cut = 0 then "state" else Pair (Pair'First .. Cut - 1));
                     Said : constant String := (if Cut = 0 then Pair else Pair (Cut + 1 .. Pair'Last));
                  begin
                     if Pair = "" then
                        null;
                     elsif Name not in "state" | "kind" | "component" | "origin" | "parent" | "requirement"
                     then
                        Outcome := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Outcome, "name", "a filter of /task list");
                        E.Add_Text (Outcome, "value", Name);
                        E.Add_Text (Outcome, "detail", "the filters are state, kind, component, origin,"
                                    & " parent and requirement; /help task says how");
                        Fail (Outcome);
                        return;
                     elsif Name = "state" and then not States.Contains (Said)
                       and then Said not in "to" | "integrate" | "for" | "parts" | "checks" | "retired" | "on"
                                          | "an" | "ended" | "task"
                     then
                        declare
                           Near : constant String := Model_Runner.Framework.Nearest (Said, States);
                        begin
                           Outcome := E.Make (E.Framework_Input_Invalid);
                           E.Add_Text (Outcome, "name", "a state of /task list");
                           E.Add_Text (Outcome, "value", Said);
                           E.Add_Text (Outcome, "detail",
                                       (if Near /= "" then "did you mean " & Near & "? " else "")
                                       & States_Said);
                           Fail (Outcome);
                           return;
                        end;
                     end if;
                  end;
                  Start := Index + 1;
               end if;
            end loop;
         end;

         --  What still asks for something first, what has ended -- done,
         --  cancelled or turned down -- after it, each in its own order.
         for Ended_Pass in Boolean loop
            for Id of Listed loop
               declare
                  Defined : R.Item;
                  Read    : E.Error_Info;
                  State   : constant String := Tk.State_Of (Store, Id);
                  Shown_State : constant String := Listed_State (Id);

                  function Fits (Name, Held : String) return Boolean
                  is (Wanted (Name) = "" or else Wanted (Name) = Held);
               begin
                  Tk.Definition (Store, Id, Defined, Read);
                  if (State in "complete" | "cancelled" | "rejected") = Ended_Pass
                    --  By the word the list shows, as /state counts them:
                    --  waiting takes waiting for parts too; blocked is blocked,
                    --  not stopped.
                    and then (Fits ("state", Shown_State)
                      or else (Wanted ("state") = "waiting"
                               and then Ada.Strings.Fixed.Index (Shown_State, "waiting") = Shown_State'First)
                      or else (Wanted ("state") = "accepted" and then State = "accepted")
                      or else (Wanted ("state") = "verification" and then State = "verification"))
                    and then Fits ("kind", R.Get (Defined, "kind"))
                    and then Fits ("component", R.Get (Defined, "component"))
                    and then Fits ("origin", R.Get (Defined, "origin"))
                    and then Fits ("parent", R.Get (Defined, "parent"))
                    and then (Wanted ("requirement") = ""
                              or else Model_Runner.Framework.Lines_Of
                                        (R.Get (Defined, "requirements")).Contains
                                           (Wanted ("requirement")))
                  then
                     Shown := Shown + 1;
                     --  Its state coloured by how it stands: ready and done
                     --  apart from what waits and from what went wrong.
                     Pres.Put_Marked
                       (Screen, "cli.task.item",
                        [Loc.Named ("name", Id),
                         Loc.Named ("value", Shown_State),
                         --  Complete, its work put back out since: said beside it.
                         Loc.Named ("detail", R.Get (Defined, "title")
                                              & (if Shown_State = "complete"
                                                   and then State_Field (Id, "undone_by") /= ""
                                                 then " (its work undone by " & State_Field (Id, "undone_by") & ")"
                                                 else ""))],
                        Shown_State,
                        (if Shown_State in "conflict" | "checks failed" | "waiting on an ended task" | "serves retired"
                                       | "refused"
                         then Pres.Bad
                         elsif Shown_State in "to integrate" | "waiting for parts" then Pres.Pending
                         --  Done with: dimmed, so what still asks stands out.
                         elsif Shown_State = "complete" then Pres.Muted
                         else Pres.Tone_Of (Shown_State)));
                  end if;
               end;
            end loop;
         end loop;
         if Shown = 0 and then not Listed.Is_Empty then
            --  Tasks there are, and none of them matches: said so.
            Pres.Put_Note (Screen, "cli.task.none_match",
                           [Loc.Named ("detail", Filters_Said),
                            Loc.Named ("count", T.Image (Long_Long_Integer (Listed.Length)))]);
            --  A state asked for: the states there are, said.
            if Ada.Strings.Fixed.Index (Filters_Said, "state=") > 0 then
               Pres.Put_Note (Screen, "cli.task.states_are", [Loc.Named ("detail", States_Said)]);
            end if;
         elsif Listed.Is_Empty then
            --  None at all: said once, with how one is made.
            Pres.Put_Note (Screen, "cli.next.tasks");
         end if;
      end Show_List;

      procedure Create is
         Fields : Tk.Field_Map;
         Id     : Unbounded_String;
         Offered_Optional : Boolean := False;

         --  A field whose value was refused, asked for again whether or
         --  not its kind requires it.
         Again  : Unbounded_String;

         --  A condition's named value, or "".
         function Parameter_Of (Condition : E.Error_Info; Name : String) return String is
         begin
            for Index in 1 .. Condition.Parameter_Total loop
               if T.To_String (Condition.Parameters (Index).Name) = Name then
                  return T.To_String (Condition.Parameters (Index).Text_Value);
               end if;
            end loop;
            return "";
         end Parameter_Of;
      begin
         for Index in 1 .. Item.Input_Count loop
            declare
               Pair : constant String := T.To_String (Item.Inputs (Index));
            begin
               for Cut in Pair'Range loop
                  if Pair (Cut) = '=' then
                     --  roots= or deny= after permissions=CAPABILITY, unquoted:
                     --  the capability's places, as quoted they would be.
                     if Pair (Pair'First .. Cut - 1) in "roots" | "deny" and then Fields.Contains ("permissions")
                     then
                        Fields.Include ("permissions", Fields ("permissions") & " " & Pair);
                     else
                        Fields.Include
                          (Pair (Pair'First .. Cut - 1), Pair (Cut + 1 .. Pair'Last));
                     end if;
                     exit;
                  end if;
               end loop;
            end;
         end loop;
         if Argument /= "" then
            Fields.Include ("title", Argument);
         end if;

         --  What was given on the line is what was meant: a kind or a value
         --  that is none is said, with the nearest there is, and nothing is
         --  asked in its place.
         if Fields.Contains ("kind") and then not Tk.Kinds (Store).Contains (Fields ("kind")) then
            declare
               --  The nearest by its letters, or one it begins: docs is
               --  documentation.
               function Begun return String is
                  Given : constant String := Fields ("kind");
               begin
                  for Kind of Tk.Kinds (Store) loop
                     if Given'Length >= 3 and then Kind'Length > Given'Length
                       and then Kind (Kind'First .. Kind'First + Given'Length - 1) = Given
                     then
                        return Kind;
                     end if;
                  end loop;
                  return "";
               end Begun;
               Near : constant String :=
                 (if Model_Runner.Framework.Nearest (Fields ("kind"), Tk.Kinds (Store)) /= ""
                  then Model_Runner.Framework.Nearest (Fields ("kind"), Tk.Kinds (Store))
                  else Begun);
            begin
               Outcome := E.Make (E.Framework_Task_Kind_Unknown);
               E.Add_Text (Outcome, "name", Fields ("kind"));
               E.Add_Text (Outcome, "detail",
                           (if Near /= "" then "did you mean " & Near & "? " else "")
                           & "the kinds are " & Joined (Tk.Kinds (Store)));
               Fail (Outcome);
               return;
            end;
         end if;
         --  inherit, as /task edit takes it: its kind's, as if not given.
         if Fields.Contains ("permissions") and then Fields ("permissions") = "inherit" then
            Fields.Exclude ("permissions");
         end if;
         if Fields.Contains ("component") and then Fields ("component") /= ""
           and then not Tk.Components (Store).Contains (Fields ("component"))
         then
            declare
               Near : constant String :=
                 Model_Runner.Framework.Nearest (Fields ("component"), Tk.Components (Store));
            begin
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "component");
               E.Add_Text (Outcome, "value", Fields ("component"));
               E.Add_Text (Outcome, "detail",
                           (if Near /= "" then "did you mean " & Near & "? " else "")
                           & "the project's components are " & Joined (Tk.Components (Store))
                           & "; /reconfigure add set.components " & Fields ("component") & " adds it");
               Fail (Outcome);
               return;
            end;
         end if;
         --  Permissions that would leave it nothing its kind allows: refused
         --  before it is made.
         if Fields.Contains ("permissions") and then Fields.Contains ("kind")
           and then Fields ("permissions") /= ""
         then
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Asked : Pm.Permission_Set;
               Read  : E.Error_Info;
            begin
               Pm.Restriction (Fields ("permissions"), Asked, Read);
               --  A place it names that is not there yet: said, as /task grant
               --  and /reconfigure say it -- an agent may make it.
               if E.Is_Ok (Read)
                 and then Pm.Missing_Places (Ada.Directories.Containing_Directory (S.Root (Store)),
                                             Fields ("permissions")) /= ""
               then
                  Pres.Put_Note (Screen, "cli.project.places_missing",
                                 [Loc.Named ("name", "permissions"),
                                  Loc.Named ("detail", Pm.Missing_Places
                                                         (Ada.Directories.Containing_Directory (S.Root (Store)),
                                                          Fields ("permissions")))]);
               end if;
               --  A root outside its kind's: said as /task grant says it.
               if E.Is_Ok (Read) then
                  declare
                     Of_Kind : constant Pm.Permission_Set :=
                       Pm.Effective (Store, Fields ("kind"), "", Within_Sandbox => False);
                  begin
                     for One in Pm.Capability loop
                        if Asked (One).Granted and then Of_Kind (One).Granted
                          and then not Of_Kind (One).Roots.Is_Empty
                        then
                           for Root of Asked (One).Roots loop
                              if not (for some Kind_Root of Of_Kind (One).Roots =>
                                        Root'Length >= Kind_Root'Length
                                        and then Root (Root'First .. Root'First + Kind_Root'Length - 1) = Kind_Root)
                              then
                                 Outcome := E.Make (E.Framework_Input_Invalid);
                                 E.Add_Text (Outcome, "name", "the roots its permissions= names for "
                                             & Pm.Word (One));
                                 E.Add_Text (Outcome, "value", Root);
                                 E.Add_Text (Outcome, "detail", "it is outside what its kind " & Fields ("kind")
                                             & " gives -- " & Pm.Grant_Text (Of_Kind (One))
                                             & " -- and a task is given no more than its kind; a root within"
                                             & " those narrows it; nothing was made");
                                 Fail (Outcome);
                                 return;
                              end if;
                           end loop;
                        end if;
                     end loop;
                  end;
               end if;
               if E.Is_Ok (Read)
                 and then (for all One in Pm.Capability =>
                             not Pm.Intersect (Asked, Pm.Effective (Store, Fields ("kind"), "",
                                                                     Within_Sandbox => False))
                                   (One).Granted)
               then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "permissions");
                  E.Add_Text (Outcome, "value", Fields ("permissions"));
                  E.Add_Text (Outcome, "detail",
                              "they leave it nothing its kind " & Fields ("kind") & " allows ("
                              & Joined (Model_Runner.Framework.Lines_Of
                                          (Pm.Image (Pm.Effective (Store, Fields ("kind"), "",
                                                                    Within_Sandbox => False))))
                              & "); nothing was made");
                  Fail (Outcome);
                  return;
               end if;
            end;
         end if;
         declare
            Given_On_Line : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Position in Fields.Iterate loop
               Given_On_Line.Append (Model_Runner.Framework.Configurations.Value_Maps.Key (Position));
            end loop;

            --  On a terminal, the form the kind's schema makes: the kind first,
            --  then what it requires, then what it allows -- a choice field
            --  offered its choices, and a value its schema refuses asked for
            --  again, where it was asked for.
            loop
               Tk.Create (Store, Change, Fields, "user", "", Id, Outcome);
               exit when E.Is_Ok (Outcome)
                 or else not Interactive
                 or else Outcome.Code not in E.Framework_Input_Missing
                                           | E.Framework_Task_Kind_Unknown
                                           | E.Framework_Schema_Violation;

               --  A value refused: shown why, and asked for again -- one given
               --  on the line is the caller's to put right, and ends it.
               if Outcome.Code = E.Framework_Schema_Violation then
                  exit when Given_On_Line.Contains (Parameter_Of (Outcome, "name"));
                  Pres.Report (Screen, Outcome);
                  declare
                     Named : constant String := Parameter_Of (Outcome, "name");
                  begin
                     exit when Named = "" or else not Fields.Contains (Named);
                     Fields.Exclude (Named);
                     Again := To_Unbounded_String (Named);
                     Change := S.No_Changes;
                     Outcome := E.Make (E.Framework_Input_Missing);
                  end;
               end if;

               if Outcome.Code = E.Framework_Task_Kind_Unknown
                 or else (Outcome.Code = E.Framework_Input_Missing
                          and then not Fields.Contains ("kind"))
               then
                  declare
                     --  The kind most work is first: what Enter takes.
                     function Ordered return Model_Runner.Framework.Name_Lists.Vector is
                        Result : Model_Runner.Framework.Name_Lists.Vector := Tk.Kinds (Store);
                     begin
                        if Result.Contains ("implementation") then
                           Result.Delete (Result.Find_Index ("implementation"));
                           Result.Prepend ("implementation");
                        end if;
                        return Result;
                     end Ordered;
                     Known : constant Model_Runner.Framework.Name_Lists.Vector := Ordered;
                     Offer : Choosers.Choice_List;
                     Taken : Natural;
                  begin
                     for Kind of Known loop
                        Choosers.Append
                          (Offer,
                           (Label   => To_Unbounded_String (Kind),
                            Details => To_Unbounded_String
                                         (Joined (Tk.Allowed_Fields (Store, Kind))),
                            others  => <>));
                     end loop;
                     Taken := Choosers.Choose (Screen, "cli.task.choose_kind", Offer);
                     --  Left without a kind, on a terminal: nothing made, as
                     --  a field left unanswered is.
                     if Taken = 0 and then Choosers.Is_Available (Screen) then
                        Pres.Put_Note (Screen, "cli.task.cancelled");
                        Status := E.Exit_Cancelled;
                        Outcome := E.Success;
                        return;
                     end if;
                     exit when Taken = 0;
                     Fields.Include ("kind", Known (Taken));
                     --  Said as chosen, as /init says its answers.
                     Pres.Put_Aside (Screen, "cli.choose.picked",
                                     [Loc.Named ("name", "kind"), Loc.Named ("value", Known (Taken))]);
                  end;
               else
                  declare
                     Wanted : Model_Runner.Framework.Name_Lists.Vector :=
                       Tk.Required_Fields
                         (Store, (if Fields.Contains ("kind")
                                  then Fields ("kind") else ""));
                     Typed  : Unbounded_String;
                     Got    : Boolean;
                     Kind   : constant String :=
                       (if Fields.Contains ("kind") then Fields ("kind") else "");

                     --  The choices a choice field offers, as Ask takes them;
                     --  a component is one of the project's.
                     function Choices (Field : String) return String is
                        Schema : constant String := Tk.Field_Schema (Store, Field);
                     begin
                        if Field = "component" then
                           return Joined (Tk.Components (Store));
                        elsif Schema'Length > 7 and then Schema (Schema'First .. Schema'First + 6) = "choice "
                        then
                           return Ada.Strings.Fixed.Translate
                             (Schema (Schema'First + 7 .. Schema'Last),
                              Ada.Strings.Maps.To_Mapping ("|", ","));
                        end if;
                        return "";
                     end Choices;
                  begin
                     Wanted.Prepend ("title");
                     if Again /= Null_Unbounded_String and then not Wanted.Contains (To_String (Again))
                     then
                        Wanted.Append (To_String (Again));
                     end if;
                     Again := Null_Unbounded_String;
                     for Field of Wanted loop
                        if not Fields.Contains (Field)
                          or else Ada.Strings.Fixed.Trim (Fields (Field), Ada.Strings.Both) = ""
                        then
                           --  Required where the kind requires it: one asked again
                           --  because its value was refused stays as optional as
                           --  it was.
                           Choosers.Ask (Screen, Field, Tk.Field_Schema (Store, Field),
                                         Choices (Field), "", Typed, Got,
                                         Required => Field = "title"
                                                     or else Tk.Required_Fields (Store, Kind).Contains (Field));
                           if not Got then
                              Pres.Put_Note (Screen, "cli.task.cancelled");
                              Status := E.Exit_Cancelled;
                              Outcome := E.Success;
                              return;
                           end if;
                           Fields.Include (Field, To_String (Typed));
                        end if;
                     end loop;

                     --  What the kind allows and does not require, once: an
                     --  empty answer leaves it out.
                     if not Offered_Optional and then Kind /= "" then
                        Offered_Optional := True;
                        for Field of Tk.Allowed_Fields (Store, Kind) loop
                           if not Wanted.Contains (Field) and then not Fields.Contains (Field) then
                              Choosers.Ask (Screen,
                                            Field & " " & Pres.Message_Value (Screen, "cli.choose.optional"),
                                            Tk.Field_Schema (Store, Field),
                                            Choices (Field), "", Typed, Got);
                              if Got and then Ada.Strings.Fixed.Trim (To_String (Typed),
                                                                      Ada.Strings.Both) /= ""
                              then
                                 Fields.Include (Field, To_String (Typed));
                              end if;
                           end if;
                        end loop;
                     end if;
                  end;
               end if;
            end loop;
         end;

         if E.Is_Error (Outcome) then
            Fail (Outcome);
            --  A value its field does not take is the caller's to put
            --  right, not a state that failed.
            if Outcome.Code = E.Framework_Schema_Violation then
               Status := E.Exit_Usage;
            end if;

            --  Off a terminal, everything still to give, each as it is
            --  given: the kind with what each kind requires, else the
            --  fields its kind requires with what they may be.
            if Outcome.Code = E.Framework_Input_Missing then
               if not Fields.Contains ("kind") then
                  for Kind of Tk.Kinds (Store) loop
                     Pres.Put_Note
                       (Screen, "cli.input.needed",
                        [Loc.Named ("name", "kind"),
                         Loc.Named ("detail",
                                    Kind & (if Tk.Required_Fields (Store, Kind).Is_Empty
                                            then ", which needs nothing more"
                                            else ", which needs "
                                                 & Joined (Tk.Required_Fields (Store, Kind))))]);
                  end loop;
               else
                  for Field of Tk.Required_Fields (Store, Fields ("kind")) loop
                     if not Fields.Contains (Field) then
                        Pres.Put_Note
                          (Screen, "cli.input.needed",
                           [Loc.Named ("name", Field),
                            Loc.Named ("detail",
                                       (if Field = "component"
                                        then "one of " & Joined (Tk.Components (Store))
                                        else Tk.Field_Schema (Store, Field)))]);
                     end if;
                  end loop;
               end if;
            end if;
            return;
         end if;
         Commit;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.task.created",
            [Loc.Named ("name", To_String (Id)),
             Loc.Named ("detail", Fields ("title"))]);
         --  Its own permissions asking for more than its kind allows: it
         --  gets what its kind allows, and is told so.
         if Fields.Contains ("permissions") and then Fields.Contains ("kind")
           and then not Model_Runner.Framework.Permissions.Only_Withholds (Fields ("permissions"))
         then
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Asked : Pm.Permission_Set;
               Read  : E.Error_Info;
            begin
               Pm.Restriction (Fields ("permissions"), Asked, Read);
               if E.Is_Ok (Read) then
                  declare
                     Allowed : constant Pm.Permission_Set :=
                       Pm.Effective (Store, Fields ("kind"), "", Within_Sandbox => False);
                     Clipped : constant String := Pm.Clipped (Asked, Allowed);
                  begin
                     if Clipped /= "" then
                        Pres.Put_Note
                          (Screen, "cli.task.clipped",
                           [Loc.Named ("name", To_String (Id)),
                            Loc.Named ("other", Withholder (Store, Fields ("kind"), Asked)),
                            Loc.Named ("detail", Clipped)]);
                     end if;
                     Say_Narrowing (Screen, To_String (Id), Giver (Store, Fields ("kind")), Asked, Allowed);
                  end;
               end if;
            end;
         end if;

         --  Said where another task not ended has the same title.
         for Other of Tk.List (Store) loop
            if Other /= To_String (Id)
              and then Tk.State_Of (Store, Other) not in "complete" | "cancelled" | "rejected"
            then
               declare
                  Its  : R.Item;
                  Read : E.Error_Info;
               begin
                  Tk.Definition (Store, Other, Its, Read);
                  if E.Is_Ok (Read)
                    and then Ada.Characters.Handling.To_Lower (R.Get (Its, "title"))
                             = Ada.Characters.Handling.To_Lower (Fields ("title"))
                  then
                     Pres.Put_Note
                       (Screen, "cli.same_title",
                        [Loc.Named ("name", To_String (Id)), Loc.Named ("other", Other)]);
                  end if;
               end;
            end if;
         end loop;

         --  What to do next, after what was said of it: where its agent
         --  would be left unable, that first.
         if Model_Runner.Framework.Work.Unable_Reason (Store, To_String (Id)) /= "" then
            Pres.Put_Note (Screen, "cli.next.permissions_first",
                           [Loc.Named ("name", To_String (Id)),
                            Loc.Named ("detail", Model_Runner.Framework.Work.Unable_Reason (Store, To_String (Id)))]);
         elsif Tk.State_Of (Store, To_String (Id)) = "candidate" then
            Pres.Put_Note (Screen, "cli.next.accept_task", [Loc.Named ("name", To_String (Id))]);
         end if;
      end Create;

      --  Cancelled with parts still waiting: they are left as they are,
      --  and said so, with how to let each go.
      procedure Say_Parts_Left (Parent : String) is
      begin
         for Child of Tk.Children (Store, Parent) loop
            if Tk.State_Of (Store, Child) in "candidate" | "accepted" | "blocked" then
               Pres.Put_Message
                 (Screen, "cli.task.field",
                  [Loc.Named ("name", "left"),
                   Loc.Named ("value", Child & " " & Listed_State (Child)
                              & "; /task " & (if Tk.State_Of (Store, Child) = "candidate"
                                             then "reject " else "cancel ")
                              & Child & " lets it go")]);
            end if;
         end loop;
      end Say_Parts_Left;

      --  Ended: the tasks still waiting for it, and how to free them.
      procedure Say_Left_Waiting (Ended : String) is
         Own  : R.Item;
         Seen : E.Error_Info;
      begin
         --  A part let go: its parent is said, while it still waits for
         --  others -- one that goes on now is said to be ready instead.
         Tk.Definition (Store, Ended, Own, Seen);
         if E.Is_Ok (Seen) and then R.Get (Own, "parent") /= ""
           and then (for some Reason of Tk.Ready (Store, R.Get (Own, "parent")).Reasons =>
                       Ada.Strings.Fixed.Index (Reason, "waiting for its children") > 0)
         then
            Pres.Put_Note
              (Screen, "cli.task.part_of",
               [Loc.Named ("name", R.Get (Own, "parent")), Loc.Named ("value", Ended)]);
         end if;
         for Other of Tk.List (Store) loop
            if Tk.State_Of (Store, Other) not in "complete" | "cancelled" | "rejected" then
               declare
                  Defined : R.Item;
                  Read    : E.Error_Info;
               begin
                  Tk.Definition (Store, Other, Defined, Read);
                  if E.Is_Ok (Read)
                    and then (for some One of Model_Runner.Framework.Lines_Of
                                               (Ada.Strings.Fixed.Translate
                                                  (R.Get (Defined, "depends_on"),
                                                   Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                              => Ada.Strings.Fixed.Trim (One, Ada.Strings.Both) = Ended)
                  then
                     Pres.Put_Note
                       (Screen, "cli.task.left_waiting",
                        [Loc.Named ("name", Other), Loc.Named ("value", Ended),
                         --  A rejected task is reconsidered; one cancelled, reopened.
                         Loc.Named ("other", (if Tk.State_Of (Store, Ended) = "rejected"
                                              then "reconsider" else "reopen"))]);
                  end if;
               end;
            end if;
         end loop;
      end Say_Left_Waiting;

      procedure Move (Next : String) is
      begin
         if not Needs_Task then
            return;
         end if;
         Tk.Move (Store, Change, Argument, Next, "", Status => Outcome,
                  Actor => Model_Runner.Framework.Transitions.User);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         --  Where it went -- which a move's consequences may have taken
         --  further: accepted with its parts open, it waits for them.
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", Argument),
             Loc.Named ("value", Model_Runner.Framework.State_Said (Moved_State (Argument)))]);
         if Next in "rejected" | "cancelled" then
            Say_Left_Waiting (Argument);
            --  How a rejected one is taken up again; a cancel's ask said it.
            if Next = "rejected" then
               Pres.Put_Note (Screen, "cli.next.undo_end",
                              [Loc.Named ("name", Argument), Loc.Named ("value", "reconsider")]);
            end if;
         elsif Next = "accepted" and then Tk.Ready (Store, Argument).Ready then
            Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Argument)]);
         elsif Next = "accepted" and then Tk.State_Of (Store, Argument) = "accepted"
           and then not Tk.Ready (Store, Argument).Reasons.Is_Empty
         then
            --  Accepted, and waiting: for what, and what makes it ready --
            --  a requirement retired is never done, and says what instead.
            declare
               Why : constant String := Tk.Ready (Store, Argument).Reasons.First_Element;
            begin
               if Ada.Strings.Fixed.Index (Why, " is obsolete") > 0
                 or else Ada.Strings.Fixed.Index (Why, " is superseded") > 0
                 or else Ada.Strings.Fixed.Index (Why, " is rejected") > 0
               then
                  Pres.Put_Note
                    (Screen, "cli.task.serves_retired",
                     [Loc.Named ("name", Argument), Loc.Named ("detail", Why)]);
               else
                  Pres.Put_Note
                    (Screen, "cli.task.accepted_waits",
                     [Loc.Named ("name", Argument), Loc.Named ("detail", Why)]);
               end if;
            end;
         end if;
         if Tk.State_Of (Store, Argument) /= Next then
            declare
               Now : constant Tk.Readiness := Tk.Ready (Store, Argument);
               Why : constant String := (if Now.Reasons.Is_Empty then "" else Now.Reasons.First_Element);
               Parts : constant Natural := Ada.Strings.Fixed.Index (Why, "children: ");
               First : constant String :=
                 (if Parts = 0 then "" else Why (Parts + 10 .. Why'Last));
               Comma : constant Natural := Ada.Strings.Fixed.Index (First, ",");
            begin
               --  Said as /task show says it: why it cannot start.
               Pres.Put_Pair (Screen, "cli.task.field", "why it cannot start",
                              Parts_Worded (if Ada.Strings.Fixed.Head (Why, 15) in "it is blocked: " | "it is stopped: "
                                            then Why (Why'First + 15 .. Why'Last) else Why),
                              Pres.Pending);
               --  Waiting for its parts: the first that can be worked is what
               --  to do -- else a failed one taken up again, a candidate accepted.
               if First /= "" then
                  declare
                     Ready_Part, Failed_Part, Candidate_Part : Unbounded_String;
                  begin
                     for Child of Tk.Children (Store, Argument) loop
                        if Ready_Part = Null_Unbounded_String and then Tk.State_Of (Store, Child) = "accepted"
                          and then Tk.Ready (Store, Child).Ready
                        then
                           Ready_Part := To_Unbounded_String (Child);
                        elsif Failed_Part = Null_Unbounded_String and then Tk.State_Of (Store, Child) = "failed" then
                           Failed_Part := To_Unbounded_String (Child);
                        elsif Candidate_Part = Null_Unbounded_String
                          and then Tk.State_Of (Store, Child) = "candidate"
                        then
                           Candidate_Part := To_Unbounded_String (Child);
                        end if;
                     end loop;
                     if Ready_Part /= Null_Unbounded_String then
                        Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", To_String (Ready_Part))]);
                     elsif Failed_Part /= Null_Unbounded_String then
                        Pres.Put_Note (Screen, "cli.next.retry_only", [Loc.Named ("name", To_String (Failed_Part))]);
                     elsif Candidate_Part /= Null_Unbounded_String then
                        Pres.Put_Note (Screen, "cli.next.accept_one_task",
                                       [Loc.Named ("name", To_String (Candidate_Part))]);
                     else
                        Pres.Put_Note (Screen, "cli.next.work",
                                       [Loc.Named ("name", (if Comma = 0 then First
                                                            else First (First'First .. Comma - 1)))]);
                     end if;
                  end;
               end if;
            end;
         end if;
      end Move;

      --  The first word of the argument, and what follows it.
      function First_Word return String is
         Space : constant Natural := Ada.Strings.Fixed.Index (Argument, " ");
      begin
         return (if Space = 0 then Argument else Argument (Argument'First .. Space - 1));
      end First_Word;

      function After_First return String is
         Space : constant Natural := Ada.Strings.Fixed.Index (Argument, " ");
      begin
         return (if Space = 0 then ""
                 else Ada.Strings.Fixed.Trim (Argument (Space + 1 .. Argument'Last),
                                              Ada.Strings.Both));
      end After_First;

      --  Asked at a terminal before work is given up: yes goes on;
      --  anywhere else, what was typed is the answer already.
      function Tk_Definition (Id : String) return R.Item is
         Defined : R.Item;
         Read    : E.Error_Info;
      begin
         Tk.Definition (Store, Id, Defined, Read);
         return Defined;
      end Tk_Definition;

      function Confirmed (Key : String; Name, Detail : String) return Boolean is
      begin
         if not Interactive then
            return True;
         end if;
         Pres.Put_Message (Screen, Key, [Loc.Named ("name", Name), Loc.Named ("detail", Detail)]);
         if Answered_Yes (Screen) then
            return True;
         end if;
         --  Declined: said as what was asked about.
         if Ada.Strings.Fixed.Index (Key, "cli.task.kept_") = Key'First then
            Pres.Put_Message (Screen, "cli.task.kept_left");
         elsif Key = "cli.task.give_up_confirm" then
            Pres.Put_Message (Screen, "cli.task.give_up_kept", [Loc.Named ("name", Name)]);
         else
            Pres.Put_Message (Screen, "cli.project.cancel.kept", [Loc.Named ("name", Name)]);
         end if;
         return False;
      exception
         when Ada.Text_IO.End_Error =>
            return False;
      end Confirmed;

      --  A task's work in its workspace, about to be given up: kept, as
      --  giving a workspace up keeps what it changed -- said where.
      --  The tasks that became ready, each said once.
      --  The newest copy kept of a task's work given up, or "".
      --  One file two ways, as diff -u shows it: the project's beside
      --  another copy of it, named as the project names the file.
      procedure Diff_Files (File, Mine, Theirs : String) is
         Differ : constant String := Hostkit.Process.Locate ("diff");
         Output : constant String := Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "diff-kept");
         Args   : Hostkit.String_Vectors.Vector;
         Ran    : Hostkit.Process.Process_Outcome;
         File_In : Ada.Text_IO.File_Type;
         Had    : constant Boolean := Ada.Environment_Variables.Exists ("LC_ALL");
         Before : constant String := (if Had then Ada.Environment_Variables.Value ("LC_ALL") else "");
      begin
         if Differ = "" then
            return;
         end if;
         Args.Append (To_Unbounded_String ("-u"));
         Args.Append (To_Unbounded_String ("--label"));
         Args.Append (To_Unbounded_String (if Ada.Directories.Exists (Mine) then "a/" & File else "(new)"));
         Args.Append (To_Unbounded_String ("--label"));
         Args.Append (To_Unbounded_String (if Ada.Directories.Exists (Theirs) then "b/" & File else "(removed)"));
         Args.Append (To_Unbounded_String (if Ada.Directories.Exists (Mine) then Mine else Hostkit.Fs.Null_Device));
         Args.Append (To_Unbounded_String
                        (if Ada.Directories.Exists (Theirs) then Theirs else Hostkit.Fs.Null_Device));
         Ada.Environment_Variables.Set ("LC_ALL", "C");
         Ran := Hostkit.Process.Run_Captured
           (Differ, Args, Stdin_Path => Hostkit.Fs.Null_Device,
            Stdout_Path => Output, Stderr_Path => Output, Timeout_Ms => 20_000);
         if Had then
            Ada.Environment_Variables.Set ("LC_ALL", Before);
         else
            Ada.Environment_Variables.Clear ("LC_ALL");
         end if;
         pragma Unreferenced (Ran);
         Ada.Text_IO.Open (File_In, Ada.Text_IO.In_File, Output);
         while not Ada.Text_IO.End_Of_File (File_In) loop
            Pres.Put_Diff_Line (Screen, Ada.Text_IO.Get_Line (File_In));
         end loop;
         Ada.Text_IO.Close (File_In);
         Ada.Directories.Delete_File (Output);
      exception
         when others =>
            if Ada.Text_IO.Is_Open (File_In) then
               Ada.Text_IO.Close (File_In);
            end if;
      end Diff_Files;

      --  The files a task's attempts changed, a comma apart; "" for none.
      --  What a task changed, a line each, as its state keeps it.
      function Changed_By_Lines (Id : String) return String is
         Held : R.Item;
         Read : E.Error_Info;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", Held, Read);
         return (if E.Is_Error (Read) then "" else R.Get (Held, "changed_files"));
      end Changed_By_Lines;

      function Changed_By (Id : String) return String is
         Held : R.Item;
         Read : E.Error_Info;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", Held, Read);
         return (if E.Is_Error (Read) then ""
                 else Joined (Model_Runner.Framework.Lines_Of (R.Get (Held, "changed_files"))));
      end Changed_By;

      --  The other task whose work, taken in, changed a file: the one
      --  complete that names it among what it changed; empty for none.
      function Taken_In_By (Path, Not_Of : String) return String is
         Found : Unbounded_String;
      begin
         for Id of Tk.List (Store, "complete") loop
            if Id /= Not_Of
              and then (for some Line of Model_Runner.Framework.Lines_Of (Changed_By_Lines (Id)) => Line = Path)
            then
               Found := To_Unbounded_String (Id);
            end if;
         end loop;
         return To_String (Found);
      end Taken_In_By;

      --  A complete task's changes the last commit does not hold yet,
      --  shown as git diff shows them; False where there are none to show.
      function Spaced (Listed : String) return String is
         At_Comma : constant Natural := Ada.Strings.Fixed.Index (Listed, ", ");
      begin
         return (if At_Comma = 0 then Listed
                 else Listed (Listed'First .. At_Comma - 1) & " " & Spaced (Listed (At_Comma + 2 .. Listed'Last)));
      end Spaced;

      function Shown_Uncommitted (Id : String) return Boolean is
         package Git renames Model_Runner.Framework.Git;
         Project : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
         Held    : R.Item;
         Read    : E.Error_Info;
         Found   : Boolean;
         Ended   : Unbounded_String;
         Ours    : Model_Runner.Framework.Name_Lists.Vector;
         Not_Its  : Model_Runner.Framework.Name_Lists.Vector;
         Fresh   : Model_Runner.Framework.Name_Lists.Vector;
         --  Files another task changed after it, and which.
         Later    : Model_Runner.Framework.Name_Lists.Vector;
         Later_By : Model_Runner.Framework.Name_Lists.Vector;
         Status  : constant Git.Status_Report := Git.Status_Of (Project);
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", Held, Read);
         --  Undone by a copy put back: none of it is there to show.
         if R.Get (Held, "undone_by") /= "" then
            Pres.Put_Note (Screen, "cli.task.diff_undone",
                           [Loc.Named ("name", Id), Loc.Named ("value", R.Get (Held, "undone_by")),
                            --  The way on its state takes, as the restore said it.
                            Loc.Named ("detail", (if Tk.State_Of (Store, Id) in "failed" | "blocked"
                                                  then "/task accept " & Id & " tries it again"
                                                  else "/task reopen " & Id & " does it again"))]);
            return True;
         end if;
         --  When its last run ended: a commit since holds what it changed,
         --  and what differs from that commit is not its.
         for Call of S.Names (Store, Model_Runner.Framework.Invocations_Area) loop
            declare
               Value : R.Item;
               Got   : E.Error_Info;
            begin
               S.Read (Store, Model_Runner.Framework.Invocations_Area, Call, Value, Got);
               if E.Is_Ok (Got) and then R.Get (Value, "task") = Id
                 and then R.Get (Value, "ended_at") > To_String (Ended)
               then
                  Ended := To_Unbounded_String (R.Get (Value, "ended_at"));
               end if;
            end;
         end loop;
         --  Each other task with when its last run ended: one that changed a
         --  file after this one wrote it holds what is there.
         declare
            Others_Ended : Model_Runner.Framework.Configurations.Value_Maps.Map;
         begin
            for Call of S.Names (Store, Model_Runner.Framework.Invocations_Area) loop
               declare
                  Value : R.Item;
                  Got   : E.Error_Info;
               begin
                  S.Read (Store, Model_Runner.Framework.Invocations_Area, Call, Value, Got);
                  if E.Is_Ok (Got) and then R.Get (Value, "task") not in "" | Id
                    and then (not Others_Ended.Contains (R.Get (Value, "task"))
                              or else R.Get (Value, "ended_at") > Others_Ended (R.Get (Value, "task")))
                  then
                     Others_Ended.Include (R.Get (Value, "task"), R.Get (Value, "ended_at"));
                  end if;
               end;
            end loop;
            for File of Model_Runner.Framework.Lines_Of (R.Get (Held, "changed_files")) loop
               for Position in Others_Ended.Iterate loop
                  declare
                     Other : constant String := Model_Runner.Framework.Configurations.Value_Maps.Key (Position);
                     Their : R.Item;
                     Got   : E.Error_Info;
                  begin
                     S.Read (Store, Model_Runner.Framework.Tasks_Area, Other & ".state", Their, Got);
                     if E.Is_Ok (Got) and then R.Get (Their, "undone_by") = ""
                       and then Model_Runner.Framework.Lines_Of (R.Get (Their, "changed_files")).Contains (File)
                       and then Model_Runner.Framework.Configurations.Value_Maps.Element (Position) > To_String (Ended)
                       and then not Later.Contains (File)
                       --  Its work reached the project: taken in, or written there;
                       --  work still in a workspace changed nothing here yet.
                       and then (Ada.Strings.Fixed.Index (R.Get (Their, "taken_in"), File & ASCII.HT) > 0
                                 or else (R.Get (Their, "current_workspace") = ""
                                          and then R.Get (Their, "taken_in") = ""
                                          and then Model_Runner.Framework.Workspaces.Active_For (Store, Other) = ""
                                          and then Tk.State_Of (Store, Other) not in "verification"))
                     then
                        Later.Append (File);
                        Later_By.Append (Other);
                     end if;
                  end;
               end loop;
            end loop;
            --  What a file holds says whose it is, over when each ran: a copy
            --  put back since makes the order of the runs no guide.
            for File of Model_Runner.Framework.Lines_Of (R.Get (Held, "changed_files")) loop
               declare
                  Holder : constant String := Model_Runner.Framework.Work.Holder_Of (Store, File);
               begin
                  if Holder = Id and then Later.Contains (File) then
                     Later_By.Delete (Later.Find_Index (File));
                     Later.Delete (Later.Find_Index (File));
                  elsif Holder not in "" | Id and then not Later.Contains (File) then
                     Later.Append (File);
                     Later_By.Append (Holder);
                  end if;
               end;
            end loop;
         end;
         for File of Model_Runner.Framework.Lines_Of (R.Get (Held, "changed_files")) loop
            declare
               Committed : constant String := Git.Last_Commit_At (Project, File);
            begin
               if Later.Contains (File) then
                  null;
               elsif Committed = "" or else Ended = Null_Unbounded_String or else To_String (Ended) > Committed then
                  --  Never committed: new to git, shown whole.
                  if Status.Found and then Status.Changes.Contains ("?? " & File) then
                     Fresh.Append (File);
                  else
                     Ours.Append (File);
                  end if;
               else
                  Not_Its.Append (File);
               end if;
            end;
         end loop;
         declare
            Diff : constant String :=
              (if Ours.Is_Empty then "" else Git.Uncommitted_Diff (Project, Ours, Found));
            Since : constant String :=
              (if Not_Its.Is_Empty then "" else Git.Uncommitted_Diff (Project, Not_Its, Found));
         begin
            for Index in Later.First_Index .. Later.Last_Index loop
               Pres.Put_Note (Screen, "cli.task.diff_later",
                              [Loc.Named ("name", Id), Loc.Named ("path", Later (Index)),
                               Loc.Named ("other", Later_By (Index))]);
            end loop;
            if Diff = "" and then Fresh.Is_Empty and then not Later.Is_Empty and then Since = "" then
               return True;
            end if;
            if Diff = "" and then Fresh.Is_Empty then
               --  Changed since its work was committed, by someone else.
               if Since /= "" then
                  Pres.Put_Note (Screen, "cli.task.diff_not_its",
                                 [Loc.Named ("name", Id), Loc.Named ("detail", Spaced (Joined (Not_Its)))]);
                  return True;
               end if;
               return False;
            end if;
            Pres.Put_Message (Screen, "cli.task.diff_uncommitted",
                              [Loc.Named ("name", Id), Loc.Named ("value", Moved_State (Id))]);
            for Line of Model_Runner.Framework.Lines_Of (Diff) loop
               Pres.Put_Diff_Line (Screen, Line);
            end loop;
            for File of Fresh loop
               Pres.Put_Message (Screen, "cli.task.diff_file", [Loc.Named ("path", File & " (new)")]);
               Diff_Files (File, Hostkit.Fs.Join (Project, File & ".absent"), Hostkit.Fs.Join (Project, File));
            end loop;
            if Since /= "" then
               Pres.Put_Note (Screen, "cli.task.diff_not_its",
                              [Loc.Named ("name", Id), Loc.Named ("detail", Spaced (Joined (Not_Its)))]);
            end if;
            --  Changed again after it was taken in: what shows is more than its.
            declare
               Moved_On : Model_Runner.Framework.Name_Lists.Vector;
            begin
               for Line of Model_Runner.Framework.Lines_Of (R.Get (Held, "taken_in")) loop
                  declare
                     Tab  : constant Natural := Ada.Strings.Fixed.Index (Line, [1 => ASCII.HT]);
                     Path : constant String := (if Tab = 0 then Line else Line (Line'First .. Tab - 1));
                     Then_Print : constant String := (if Tab = 0 then "" else Line (Tab + 1 .. Line'Last));
                     Whole : constant String := Hostkit.Fs.Join (Project, Path);
                  begin
                     if (Ours.Contains (Path) or else Fresh.Contains (Path))
                       and then Then_Print /= ""
                       and then Then_Print /= Model_Runner.Framework.Work.File_Print (Whole)
                     then
                        Moved_On.Append (Path);
                     end if;
                  end;
               end loop;
               if not Moved_On.Is_Empty then
                  Pres.Put_Note (Screen, "cli.task.diff_changed_since",
                                 [Loc.Named ("name", Id), Loc.Named ("detail", Joined (Moved_On))]);
               end if;
               --  Joined with the project's own change when taken in: the
               --  project's lines are in what shows too.
               declare
                  Mixed : Model_Runner.Framework.Name_Lists.Vector;
               begin
                  for File of Model_Runner.Framework.Lines_Of (R.Get (Held, "joined_files")) loop
                     if (Ours.Contains (File) or else Fresh.Contains (File)) and then not Moved_On.Contains (File) then
                        Mixed.Append (File);
                     end if;
                  end loop;
                  if not Mixed.Is_Empty then
                     Pres.Put_Note (Screen, "cli.task.diff_joined",
                                    [Loc.Named ("name", Id), Loc.Named ("detail", Joined (Mixed))]);
                  end if;
               end;
            end;
            return True;
         end;
      end Shown_Uncommitted;

      function Kept_For (Id : String) return String is
      begin
         --  Its newest only: one put back since is the work it has now.
         for One of Model_Runner.Framework.Workspaces.Kept_Copies (Store) loop
            if Ada.Strings.Fixed.Index (One, "given-up-" & Id & "-") = One'First then
               return (if Model_Runner.Framework.Workspaces.Was_Restored (Store, One) then "" else One);
            end if;
         end loop;
         return "";
      end Kept_For;

      --  What a task serves, where each of it is retired; "" otherwise.
      function Retired_Only (Id : String) return String is
         Defined : R.Item;
         Read    : E.Error_Info;
         Said    : Unbounded_String;
      begin
         Tk.Definition (Store, Id, Defined, Read);
         for Req of Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")) loop
            declare
               State : constant String :=
                 Model_Runner.Framework.Intent.State_Of (Store, Model_Runner.Framework.Intent.Requirement, Req);
            begin
               if State not in "obsolete" | "rejected" | "superseded" then
                  return "";
               end if;
               Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Req & ", " & State);
            end;
         end loop;
         return To_String (Said);
      end Retired_Only;

      --  Whether a task was never worked: no run of it began.
      function Never_Worked (Id : String) return Boolean is
         Held : R.Item;
         Read : E.Error_Info;
      begin
         S.Read (Store, Model_Runner.Framework.Tasks_Area, Id & ".state", Held, Read);
         return E.Is_Error (Read) or else R.Get (Held, "generation") in "" | "0";
      end Never_Worked;

      procedure Say_Became_Ready is
      begin
         for Id of Became_Ready loop
            --  The one just accepted was said with its next step already,
            --  and one that is done is not ready for anything: only those
            --  that can now be worked are said.
            --  Nor one a completing just failed for: ready to be done is no
            --  news after its check failed.
            if not (Id = Argument and then Action in "accept" | "reopen" | "reconsider" | "move" | "edit")
              and then not (Action = "complete" and then Id = Argument and then Status /= E.Exit_Success)
              and then Tk.State_Of (Store, Id) = "accepted"
              and then not Said_Ready.Contains (Id)
            then
               Said_Ready.Append (Id);
               --  Its parts all let go: ready as a whole, said so.
               if Ada.Strings.Fixed.Index (State_Field (Id, "accepted_by"), "its parts ended") = 1 then
                  Pres.Put_Note (Screen, "cli.task.ready_whole", [Loc.Named ("name", Id)]);
               else
                  Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
               end if;
            end if;
         end loop;
         Became_Ready.Clear;
      end Say_Became_Ready;

      --  What a workspace given up changed, and where that is kept.
      function Given_Up_Detail (Space : String; Lost : Model_Runner.Framework.Name_Lists.Vector) return String
      is (if Lost.Is_Empty then "it changed nothing"
          else "what it changed -- " & Joined (Lost) & " -- is kept in "
               & Ada.Directories.Simple_Name (Model_Runner.Framework.Workspaces.Kept_Copy (Store, Space))
               & " (/task kept lists it)");

      --  Reopen an ended task, or reconsider a rejected one: moves only an
      --  explicit act allows, its history kept.
      procedure Move_Granted (Next : String; Grant : Model_Runner.Framework.Transitions.Permission) is
         Granted : Model_Runner.Framework.Transitions.Permissions :=
           Model_Runner.Framework.Transitions.Ordinary_Only;
      begin
         if not Needs_Task then
            return;
         end if;
         Granted (Grant) := True;
         --  There already: said, not refused as a move to itself.
         if Tk.State_Of (Store, Argument) = Next then
            Pres.Put_Note (Screen, "cli.intent.already",
                           [Loc.Named ("name", Argument), Loc.Named ("value", Next)]);
            return;
         end if;
         Tk.Move (Store, Change, Argument, Next,
                  (if Next = "accepted" then "reopened" else "reconsidered"),
                  Granted, Status => Outcome, Actor => Model_Runner.Framework.Transitions.User);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         --  Where it is now -- a parent with parts open waits for them --
         --  and, given up before, where that work is kept.
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", Argument),
             Loc.Named ("value", Model_Runner.Framework.State_Said (Moved_State (Argument)))]);
         declare
            Kept    : Unbounded_String;
            Search  : Ada.Directories.Search_Type;
            Found   : Ada.Directories.Directory_Entry_Type;
            Runtime : constant String := Hostkit.Fs.Join (S.Root (Store), "runtime");
         begin
            if Ada.Directories.Exists (Runtime) then
               Ada.Directories.Start_Search
                 (Search, Runtime, "given-up-" & Argument & "-*",
                  [Ada.Directories.Directory => True, others => False]);
               while Ada.Directories.More_Entries (Search) loop
                  Ada.Directories.Get_Next_Entry (Search, Found);
                  Kept := To_Unbounded_String (Ada.Directories.Full_Name (Found));
               end loop;
               Ada.Directories.End_Search (Search);
            end if;
            --  Not one older than its work taken in since: that work is the
            --  project's now, and the copy would go over it.
            declare
               Held : R.Item;
               Read : E.Error_Info;
            begin
               S.Read (Store, Model_Runner.Framework.Tasks_Area, Argument & ".state", Held, Read);
               if E.Is_Ok (Read) and then R.Get (Held, "taken_in") /= "" then
                  Kept := Null_Unbounded_String;
               end if;
            end;
            if Kept /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.task.given_up_kept",
                              [Loc.Named ("path", Ada.Directories.Simple_Name (To_String (Kept)))]);
            end if;
         exception
            when others =>
               null;
         end;
         --  Taken up again and able to start: the way on, as accepting says.
         if Next = "accepted" and then Tk.Ready (Store, Argument).Ready then
            Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Argument)]);
         end if;
      end Move_Granted;

      --  One task waits for another: task depend TASK ON.
      procedure Depend is
      begin
         if First_Word = "" or else After_First = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "the task and the task it waits for");
            Fail (Outcome);
            return;
         end if;
         --  depend TASK ON remove: it stops waiting for it.
         declare
            Space  : constant Natural := Ada.Strings.Fixed.Index (After_First, " ");
            On     : constant String :=
              (if Space = 0 then After_First else After_First (After_First'First .. Space - 1));
            Undo   : constant Boolean :=
              Space > 0 and then Ada.Strings.Fixed.Trim
                                   (After_First (Space + 1 .. After_First'Last),
                                    Ada.Strings.Both) = "remove";
            Defined : R.Item;
            Read    : E.Error_Info;
         begin
            --  Waiting for it already: said, and nothing changed.
            Tk.Definition (Store, First_Word, Defined, Read);
            if not Undo and then E.Is_Ok (Read)
              and then Model_Runner.Framework.Lines_Of
                         (Ada.Strings.Fixed.Translate
                            (R.Get (Defined, "depends_on"),
                             Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                         .Contains (On)
            then
               Pres.Put_Note (Screen, "cli.intent.already",
                              [Loc.Named ("name", First_Word),
                               Loc.Named ("value", "waiting for " & On)]);
               return;
            end if;
            if Undo and then E.Is_Ok (Read)
              and then not (for some One of Model_Runner.Framework.Lines_Of
                                              (Ada.Strings.Fixed.Translate
                                                 (R.Get (Defined, "depends_on"),
                                                  Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                            => Ada.Strings.Fixed.Trim (One, Ada.Strings.Both) = On)
            then
               --  Not waiting for it: nothing to take away, and said so.
               Pres.Put_Note (Screen, "cli.task.not_waiting",
                              [Loc.Named ("name", First_Word),
                               Loc.Named ("value", On)]);
               return;
            elsif Undo then
               Tk.Remove_Dependency (Store, Change, First_Word, On, Outcome);
            elsif Tk.State_Of (Store, First_Word) = "complete" then
               --  Done: it waits for nothing, until it is taken up again.
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the task to make wait");
               E.Add_Text (Outcome, "value", First_Word);
               E.Add_Text (Outcome, "detail", First_Word & " is complete; /task reopen " & First_Word
                           & " first, and it can wait for " & On & " then");
            elsif Tk.State_Of (Store, On) = "complete" then
               --  Done already: nothing to wait for, and nothing changed.
               Pres.Put_Note (Screen, "cli.task.depends_done",
                              [Loc.Named ("name", First_Word), Loc.Named ("value", On)]);
               return;
            elsif Tk.State_Of (Store, On) in "cancelled" | "rejected" then
               --  Ended without being done: waiting for it is waiting for
               --  ever, and refused with the way on.
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the task " & First_Word & " waits for");
               E.Add_Text (Outcome, "value", On);
               E.Add_Text (Outcome, "detail", On & " is " & Tk.State_Of (Store, On) & ", so it never completes and "
                           & First_Word & " would wait for ever; /task "
                           & (if Tk.State_Of (Store, On) = "cancelled" then "reopen " else "reconsider ")
                           & On & " takes it up again first");
            else
               Tk.Add_Dependency (Store, Change, First_Word, After_First, Outcome);
            end if;
            if E.Is_Ok (Outcome) then
               Commit;
            end if;
            if E.Is_Error (Outcome) then
               Fail (Outcome);
               return;
            end if;
            Pres.Put_Message
              (Screen, (if Undo then "cli.task.undepends" else "cli.task.depends"),
               [Loc.Named ("name", First_Word), Loc.Named ("value", On)]);
         end;
      end Depend;

      --  A task revised: task edit TASK with NAME=VALUE for each field.
      procedure Edit
        (Id     : String := Argument;
         Given  : Tk.Field_Map := Model_Runner.Framework.Configurations.Value_Maps.Empty_Map;
         Inputs : Boolean := True)
      is
         Fields : Tk.Field_Map := Given;
         --  Kept from the work by its permissions before this edit.
         Was_Refused : constant Boolean :=
           Tk.State_Of (Store, Id) = "accepted" and then not Tk.Ready (Store, Id).Ready
           and then Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= "";
      begin
         if not Needs_Task then
            return;
         end if;
         --  A caller that read the line's NAME=VALUE words itself -- a
         --  grant's roots= -- has them in what it gives.
         for Index in 1 .. (if Inputs then Item.Input_Count else 0) loop
            declare
               Pair : constant String := T.To_String (Item.Inputs (Index));
               Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
            begin
               --  NAME+=VALUE adds to what the field holds: notes after
               --  what they say, a list's items after its own.
               if Cut > Pair'First + 1 and then Pair (Cut - 1) in '+' | '-' then
                  --  Added to, or taken from, by the command that says so.
                  declare
                     Name : constant String := Pair (Pair'First .. Cut - 2);
                     Said : constant String := Pair (Cut + 1 .. Pair'Last);
                  begin
                     Outcome := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Outcome, "name", "how " & Name & " is changed");
                     E.Add_Text (Outcome, "value", Pair (Pair'First .. Cut));
                     E.Add_Text (Outcome, "detail",
                                 (if Name = "notes" then "/task note " & Id & " " & Said & " adds to its notes"
                                  elsif Name = "requirements"
                                  then "/task link " & Id & " " & Said & " adds a requirement it serves"
                                  elsif Name = "depends_on"
                                  then "/task depend " & Id & " " & Said & " adds what it waits for"
                                         & (if Pair (Cut - 1) = '-' then " -- /task depend " & Id & " " & Said
                                                                         & " remove takes it away" else "")
                                  elsif Name = "permissions" and then Capability_Near (Said) = ""
                                  then "/task grant " & Id & " CAPABILITY gives one back, and /task withhold " & Id
                                       & " CAPABILITY takes one away; " & Said & " is no capability -- they are"
                                       & " read_source, write_source, read_specs, write_specs, run_build, run_tests,"
                                       & " run_static_analysis, create_children, propose_tasks, use_network,"
                                       & " request_integration and execute_external_process"
                                  elsif Name = "permissions"
                                  then (if Capability_Near (Said) /= Said
                                        then Said & " is no capability; did you mean " & Capability_Near (Said)
                                             & "? " else "")
                                       & "/task " & (if Pair (Cut - 1) = '+' then "grant " else "withhold ") & Id
                                       & " " & Capability_Near (Said)
                                       & (if Pair (Cut - 1) = '+' then " gives it back that"
                                          else " takes that from it")
                                       & ", the rest of what its kind gives kept"
                                  else Name & " is one value, set whole: /task edit " & Id & " " & Name
                                       & "=VALUE"));
                     Fail (Outcome);
                     return;
                  end;
               elsif Cut > Pair'First then
                  --  permissions=inherit clears a task's own: its kind's
                  --  then, as a level set to inherit takes the one above.
                  Fields.Include (Pair (Pair'First .. Cut - 1),
                                  (if Pair (Pair'First .. Cut - 1) = "permissions"
                                     and then Pair (Cut + 1 .. Pair'Last) = "inherit"
                                   then "" else Pair (Cut + 1 .. Pair'Last)));
               end if;
            end;
         end loop;
         --  Only taking away -- permissions=-read_source -- from a task that
         --  has its own already: taken from those, the rest of them kept, as
         --  /task withhold does.
         if Fields.Contains ("permissions")
           and then Model_Runner.Framework.Permissions.Only_Withholds (Fields ("permissions"))
         then
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
            begin
               Tk.Definition (Store, Id, Defined, Read);
               declare
                  Own : constant String := (if E.Is_Ok (Read) then R.Get (Defined, "permissions") else "");
                  Taken : constant Model_Runner.Framework.Name_Lists.Vector :=
                    Model_Runner.Framework.Lines_Of
                      (Ada.Strings.Fixed.Translate (Fields ("permissions"),
                                                    Ada.Strings.Maps.To_Mapping (";", [1 => ASCII.LF])));
                  Merged : Unbounded_String;
               begin
                  if Own /= "" then
                     for Line of Model_Runner.Framework.Lines_Of
                       (Ada.Strings.Fixed.Translate (Own, Ada.Strings.Maps.To_Mapping (";", [1 => ASCII.LF])))
                     loop
                        declare
                           Trimmed : constant String := Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
                           Blank   : constant Natural := Ada.Strings.Fixed.Index (Trimmed & " ", " ");
                           Word    : constant String := Trimmed (Trimmed'First .. Blank - 1);
                        begin
                           if Trimmed /= "" and then not Taken.Contains ("-" & Word)
                             and then not Taken.Contains (Word)
                           then
                              Append (Merged, (if Merged = Null_Unbounded_String then "" else ASCII.LF & "")
                                              & Trimmed);
                           end if;
                        end;
                     end loop;
                     --  A list of what it may: what is taken simply left out;
                     --  one of what it may not: what is taken added.
                     if Model_Runner.Framework.Permissions.Only_Withholds (Own) then
                        for One of Taken loop
                           Append (Merged, (if Merged = Null_Unbounded_String then "" else ASCII.LF & "") & One);
                        end loop;
                     end if;
                     Fields.Include ("permissions", To_String (Merged));
                  end if;
               end;
            end;
         end if;
         --  A field that must say something, given nothing: refused by name.
         for Position in Fields.Iterate loop
            if Model_Runner.Framework.Configurations.Value_Maps.Element (Position) = ""
              and then Model_Runner.Framework.Configurations.Value_Maps.Key (Position)
                         in "component" | "kind" | "title"
            then
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name", "a value for "
                           & Model_Runner.Framework.Configurations.Value_Maps.Key (Position)
                           & ", as "
                           & Model_Runner.Framework.Configurations.Value_Maps.Key (Position) & "=NAME");
               Fail (Outcome);
               return;
            end if;
         end loop;
         --  Nothing asked of it: said what edit takes.
         if Fields.Is_Empty then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "what to change: /task edit " & Id
                        & " FIELD=VALUE, as title=, notes=, component= or requirements=");
            Fail (Outcome);
            return;
         end if;
         --  Nothing it would change: said, and no revision made.
         declare
            Defined : R.Item;
            Read    : E.Error_Info;
            Same    : Boolean := True;
         begin
            Tk.Definition (Store, Id, Defined, Read);
            for Position in Fields.Iterate loop
               declare
                  Name  : constant String :=
                    Model_Runner.Framework.Configurations.Value_Maps.Key (Position);
                  Given : constant String :=
                    Model_Runner.Framework.Configurations.Value_Maps.Element (Position);
                  Held  : constant String :=
                    (if R.Has (Defined, Name) then R.Get (Defined, Name)
                     else R.Get (Defined, "field." & Name));
               begin
                  Same := Same and then Ada.Strings.Fixed.Trim (Given, Ada.Strings.Both) = Held;
               end;
            end loop;
            if E.Is_Ok (Read) and then Same then
               Pres.Put_Note (Screen, "cli.task.unchanged", [Loc.Named ("name", Id)]);
               return;
            end if;
         end;
         --  Titled after a requirement it no longer serves, as a derived
         --  task is: titled after the one it serves now.
         if Fields.Contains ("requirements") and then not Fields.Contains ("title") then
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               Now     : constant Model_Runner.Framework.Name_Lists.Vector :=
                 Model_Runner.Framework.Lines_Of
                   (Ada.Strings.Fixed.Translate
                      (Fields ("requirements"), Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])));
            begin
               Tk.Definition (Store, Id, Defined, Read);
               declare
                  Title : constant String := R.Get (Defined, "title");
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Title, ": ");
               begin
                  if E.Is_Ok (Read) and then Natural (Now.Length) = 1 and then Colon > Title'First
                    and then Ada.Strings.Fixed.Index (Title, "REQ-") = Title'First
                    and then Title (Title'First .. Colon - 1) /= Ada.Strings.Fixed.Trim
                                                                   (Now.First_Element, Ada.Strings.Both)
                  then
                     declare
                        Held : Model_Runner.Framework.Intent.Entity;
                        Got  : E.Error_Info;
                        Id   : constant String := Ada.Strings.Fixed.Trim (Now.First_Element, Ada.Strings.Both);
                     begin
                        Model_Runner.Framework.Intent.Read
                          (Store, Model_Runner.Framework.Intent.Requirement, Id, Held, Got);
                        if E.Is_Ok (Got) then
                           Fields.Include ("title", Id & ": " & To_String (Held.Title));
                        end if;
                     end;
                  end if;
               end;
            end;
         end if;

         --  Permissions that would leave it nothing at all: refused, not
         --  written -- a task no agent could do anything for is no task
         --  to call ready.
         if Fields.Contains ("permissions") and then Fields ("permissions") /= "" then
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Defined : R.Item;
               Read    : E.Error_Info;
               Asked   : Pm.Permission_Set;
            begin
               Tk.Definition (Store, Id, Defined, Read);
               Pm.Restriction (Fields ("permissions"), Asked, Read);
               --  A place it names that is not there yet: said, as /task grant
               --  and /reconfigure say it -- an agent may make it.
               if E.Is_Ok (Read)
                 and then Pm.Missing_Places (Ada.Directories.Containing_Directory (S.Root (Store)),
                                             Fields ("permissions")) /= ""
               then
                  Pres.Put_Note (Screen, "cli.project.places_missing",
                                 [Loc.Named ("name", "permissions"),
                                  Loc.Named ("detail", Pm.Missing_Places
                                                         (Ada.Directories.Containing_Directory (S.Root (Store)),
                                                          Fields ("permissions")))]);
               end if;
               if E.Is_Ok (Read) then
                  declare
                     Left : constant Pm.Permission_Set :=
                       Pm.Intersect (Asked, Pm.Effective (Store, R.Get (Defined, "kind"), "",
                                                          Within_Sandbox => False));
                  begin
                     if (for all One in Pm.Capability => not Left (One).Granted) then
                        Outcome := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Outcome, "name", "permissions");
                        E.Add_Text (Outcome, "value", Fields ("permissions"));
                        E.Add_Text (Outcome, "detail",
                                    "they leave " & Id & " nothing its kind "
                                    & R.Get (Defined, "kind") & " allows ("
                                    & Joined (Model_Runner.Framework.Lines_Of
                                                (Pm.Image (Pm.Effective (Store, R.Get (Defined, "kind"), "",
                                                                          Within_Sandbox => False))))
                                    & "); nothing was changed");
                        Fail (Outcome);
                        return;
                     end if;
                  end;
               end if;
            end;
         end if;
         --  A derived title names the requirement it served: the one it
         --  serves now, where only that changed.
         if Fields.Contains ("requirements") and then not Fields.Contains ("title") then
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               Now     : constant Model_Runner.Framework.Name_Lists.Vector :=
                 Model_Runner.Framework.Lines_Of
                   (Ada.Strings.Fixed.Translate (Fields ("requirements"),
                                                 Ada.Strings.Maps.To_Mapping (", ", [ASCII.LF, ASCII.LF])));
            begin
               Tk.Definition (Store, Id, Defined, Read);
               if E.Is_Ok (Read) and then not Now.Is_Empty then
                  for Old of Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")) loop
                     declare
                        Title : constant String := R.Get (Defined, "title");
                        At_Id : constant Natural := Ada.Strings.Fixed.Index (Title, "(" & Old & ")");
                     begin
                        if At_Id > 0 and then not Now.Contains (Old) then
                           Fields.Include ("title", Title (Title'First .. At_Id) & Now.First_Element
                                                    & Title (At_Id + 1 + Old'Length .. Title'Last));
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end if;
         Tk.Revise (Store, Change, Id, Fields, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         --  What changed, each field as it now is; a new kind, what its
         --  agent may do now.
         declare
            Said : Unbounded_String;
         begin
            for Position in Fields.Iterate loop
               declare
                  Key   : constant String := Model_Runner.Framework.Configurations.Value_Maps.Key (Position);
                  Value : constant String := Model_Runner.Framework.Configurations.Value_Maps.Element (Position);
               begin
                  --  Permissions in words, on one line; notes as they read.
                  Append (Said, (if Said = Null_Unbounded_String then "" else "; ")
                                & (if Key = "permissions" and then Value = ""
                                   then "its permissions are its kind's again"
                                   --  As /task show says it: what its agent may do now.
                                   elsif Key = "permissions"
                                     and then Model_Runner.Framework.Work.May_Do (Store, Id) /= ""
                                   then "it may " & Ada.Strings.Fixed.Translate
                                                      (Model_Runner.Framework.Work.May_Do (Store, Id),
                                                       Ada.Strings.Maps.To_Mapping (";", ","))
                                   elsif Key = "permissions"
                                   then "it may " & Model_Runner.Framework.Permissions.In_Words (Value)
                                   elsif Key = "notes" then "its notes now read: " & Value
                                   else Key & " is now " & (if Value = "" then "empty" else Value)));
               end;
            end loop;
            Pres.Put_Message (Screen, "cli.task.revised_fields",
                              [Loc.Named ("name", Id), Loc.Named ("detail", To_String (Said))]);
            --  Placed elsewhere: its identifier, made with its old component,
            --  stays -- said, as it names another.
            if Fields.Contains ("component") and then Ada.Strings.Fixed.Count (Id, "-") = 2
              and then Ada.Characters.Handling.To_Upper (Fields ("component"))
                       /= Id (Ada.Strings.Fixed.Index (Id, "-") + 1
                              .. Ada.Strings.Fixed.Index (Id, "-", Ada.Strings.Backward) - 1)
            then
               Pres.Put_Note (Screen, "cli.task.id_keeps_component",
                              [Loc.Named ("name", Id), Loc.Named ("value", Fields ("component"))]);
            end if;
            --  Refused before, and given what it lacked: ready now, said.
            if Was_Refused and then Tk.State_Of (Store, Id) = "accepted" and then Tk.Ready (Store, Id).Ready
              and then Model_Runner.Framework.Work.Unable_Reason (Store, Id) = ""
            then
               Pres.Put_Note (Screen, "cli.task.ready_now", [Loc.Named ("name", Id)]);
            end if;
            --  Narrowed so far its agent could not do it: said now, not at
            --  its acceptance.
            if (Fields.Contains ("permissions") or else Fields.Contains ("kind"))
              and then Model_Runner.Framework.Work.Unable_Reason (Store, Id) /= ""
            then
               --  Accepted already: nothing more to accept once it is put right.
               Pres.Put_Note (Screen, (if Tk.State_Of (Store, Id) = "candidate" then "cli.next.permissions_first"
                                       else "cli.next.permissions_first_open"),
                              [Loc.Named ("name", Id),
                               Loc.Named ("detail", Model_Runner.Framework.Work.Unable_Reason (Store, Id))]);
            --  What its agent may do, only where it could do the work at all.
            elsif Fields.Contains ("kind") and then Model_Runner.Framework.Work.May_Do (Store, Id) /= "" then
               Pres.Put_Note (Screen, "cli.task.kind_changed",
                              [Loc.Named ("name", Id), Loc.Named ("value", Fields ("kind")),
                               Loc.Named ("detail", Model_Runner.Framework.Work.May_Do (Store, Id))]);
            end if;
         end;

         --  Its permissions asking for more than its kind allows: what it
         --  gets, as a new task is told.
         if Fields.Contains ("permissions")
           and then not Model_Runner.Framework.Permissions.Only_Withholds (Fields ("permissions"))
         then
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Defined : R.Item;
               Read    : E.Error_Info;
               Asked   : Pm.Permission_Set;
            begin
               Tk.Definition (Store, Id, Defined, Read);
               Pm.Restriction (Fields ("permissions"), Asked, Read);
               if E.Is_Ok (Read) then
                  declare
                     Allowed : constant Pm.Permission_Set :=
                       Pm.Effective (Store, R.Get (Defined, "kind"), "", Within_Sandbox => False);
                     Clipped : constant String := Pm.Clipped (Asked, Allowed);
                  begin
                     if Clipped /= "" then
                        Pres.Put_Note
                          (Screen, "cli.task.clipped",
                           [Loc.Named ("name", Id),
                            Loc.Named ("other", Withholder (Store, R.Get (Defined, "kind"), Asked)),
                            Loc.Named ("detail", Clipped)]);
                     end if;
                     Say_Narrowing (Screen, Id, Giver (Store, R.Get (Defined, "kind")), Asked, Allowed);
                  end;
               end if;
            end;
         end if;
      end Edit;

      --  /task link TASK REQ...: the requirements it serves, added to
      --  those it names -- an edit of its requirements field.
      procedure Link is
         Given   : Tk.Field_Map;
         Defined : R.Item;
         Read    : E.Error_Info;
         Serves  : Unbounded_String;
      begin
         if not Needs_Task then
            return;
         end if;
         if After_First = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "a requirement to link: /task link " & First_Word & " REQ-ID...");
            Fail (Outcome);
            return;
         end if;
         Tk.Definition (Store, First_Word, Defined, Read);
         Serves := To_Unbounded_String (R.Get (Defined, "requirements"));
         for Word of Model_Runner.Framework.Lines_Of
           (Ada.Strings.Fixed.Translate (After_First, Ada.Strings.Maps.To_Mapping (" ,", [ASCII.LF, ASCII.LF])))
         loop
            declare
               Held : Model_Runner.Framework.Intent.Entity;
               Got  : E.Error_Info;
            begin
               Model_Runner.Framework.Intent.Read
                 (Store, Model_Runner.Framework.Intent.Requirement, Word, Held, Got);
               if E.Is_Error (Got) then
                  Fail (Got);
                  return;
               end if;
               if not Model_Runner.Framework.Lines_Of (To_String (Serves)).Contains (Word) then
                  Serves := (if Serves = Null_Unbounded_String then To_Unbounded_String (Word)
                             else Serves & ASCII.LF & Word);
               end if;
            end;
         end loop;
         Given.Include ("requirements", To_String (Serves));
         Edit (First_Word, Given);
         --  One not accepted yet holds the task back: said, with the step.
         for Word of Model_Runner.Framework.Lines_Of
           (Ada.Strings.Fixed.Translate (After_First, Ada.Strings.Maps.To_Mapping (" ,", [ASCII.LF, ASCII.LF])))
         loop
            if Model_Runner.Framework.Intent.State_Of (Store, Model_Runner.Framework.Intent.Requirement, Word)
                 = "candidate"
            then
               Pres.Put_Note (Screen, "cli.next.req_first",
                              [Loc.Named ("name", First_Word), Loc.Named ("value", Word)]);
            end if;
         end loop;
      end Link;

      --  task grant TASK CAP [CONSTRAINTS], task withhold TASK CAP: one
      --  capability given back to a task, or taken from it, the rest of what
      --  its kind gives it kept.
      procedure Grant_Or_Withhold (Granting : Boolean) is
         package Pm renames Model_Runner.Framework.Permissions;
         Rest    : constant String := Ada.Strings.Fixed.Trim (After_First, Ada.Strings.Both);
         Space   : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
         Typed   : constant String := (if Space = 0 then Rest else Rest (Rest'First .. Space - 1));
         --  A tool's name or a plain word is the capability it needs.
         Cap     : constant String :=
           (if Typed in "write_file" | "write_files" | "read_file" | "list_directory" | "run_checks" | "delegate"
                      | "network"
            then Capability_Near (Typed) else Typed);
         --  Its constraints, however they came: roots=... as a word, or
         --  as the NAME=VALUE the line was taken apart into.
         function Constraints return String is
            Said : Unbounded_String :=
              To_Unbounded_String
                (if Space = 0 then "" else Ada.Strings.Fixed.Trim (Rest (Space + 1 .. Rest'Last), Ada.Strings.Both));
         begin
            for Index in 1 .. Item.Input_Count loop
               Append (Said, (if Said = Null_Unbounded_String then "" else " ") & T.To_String (Item.Inputs (Index)));
            end loop;
            return To_String (Said);
         end Constraints;
         --  Places as the kinds write them: ./src and src are src/.
         function Normal_Places (Text : String) return String is
            Result : Unbounded_String;
            Start  : Natural := Text'First;

            function One_Place (Place : String) return String is
               Bare : constant String :=
                 (if Place'Length > 2 and then Place (Place'First .. Place'First + 1) = "./"
                  then Place (Place'First + 2 .. Place'Last) else Place);
            begin
               return (if Bare /= "" and then Bare (Bare'Last) /= '/'
                         and then Ada.Directories.Exists (Bare)
                         and then Ada.Directories."=" (Ada.Directories.Kind (Bare), Ada.Directories.Directory)
                       then Bare & "/" else Bare);
            exception
               when others =>
                  return Bare;
            end One_Place;

            function One_Word (Word : String) return String is
               Eq : constant Natural := Ada.Strings.Fixed.Index (Word, "=");
            begin
               if Eq = 0 or else Word (Word'First .. Eq) not in "roots=" | "deny=" then
                  return Word;
               end if;
               declare
                  Said  : Unbounded_String := To_Unbounded_String (Word (Word'First .. Eq));
                  From  : Natural := Eq + 1;
               begin
                  for Index in Eq + 1 .. Word'Last + 1 loop
                     if Index > Word'Last or else Word (Index) = '|' then
                        Append (Said, (if From = Eq + 1 then "" else "|") & One_Place (Word (From .. Index - 1)));
                        From := Index + 1;
                     end if;
                  end loop;
                  return To_String (Said);
               end;
            end One_Word;
            --  roots= or deny= given twice is one of each, its places joined:
            --  each checked, none dropping another.
            Roots, Denied : Unbounded_String;
         begin
            for Index in Text'First .. Text'Last + 1 loop
               if Index > Text'Last or else Text (Index) = ' ' then
                  if Index > Start then
                     declare
                        Word : constant String := One_Word (Text (Start .. Index - 1));
                     begin
                        if Word'Length > 6 and then Word (Word'First .. Word'First + 5) = "roots=" then
                           Append (Roots, (if Roots = Null_Unbounded_String then "" else "|")
                                          & Word (Word'First + 6 .. Word'Last));
                        elsif Word'Length > 5 and then Word (Word'First .. Word'First + 4) = "deny=" then
                           Append (Denied, (if Denied = Null_Unbounded_String then "" else "|")
                                           & Word (Word'First + 5 .. Word'Last));
                        else
                           Append (Result, (if Result = Null_Unbounded_String then "" else " ") & Word);
                        end if;
                     end;
                  end if;
                  Start := Index + 1;
               end if;
            end loop;
            if Roots /= Null_Unbounded_String then
               Append (Result, (if Result = Null_Unbounded_String then "" else " ") & "roots=" & Roots);
            end if;
            if Denied /= Null_Unbounded_String then
               Append (Result, (if Result = Null_Unbounded_String then "" else " ") & "deny=" & Denied);
            end if;
            return To_String (Result);
         end Normal_Places;
         Limits  : constant String := Normal_Places (Constraints);
         Defined : R.Item;
         Read    : E.Error_Info;
         Given   : Tk.Field_Map;
         Which   : Pm.Capability := Pm.Capability'First;
         Known   : Boolean := False;
         Kept    : Unbounded_String;
      begin
         if not Needs_Task then
            return;
         end if;
         for One in Pm.Capability loop
            if Pm.Word (One) = Cap then
               Which := One;
               Known := True;
            end if;
         end loop;
         if not Known then
            Outcome := (if Cap = "" then E.Make (E.Framework_Input_Missing) else E.Make (E.Framework_Input_Invalid));
            E.Add_Text (Outcome, "name", "the capability to " & (if Granting then "grant" else "withhold"));
            if Cap'Length > 1 and then Cap (Cap'First) = '-' then
               --  -CAP is how permissions= takes one away: withhold it.
               E.Add_Text (Outcome, "value", Cap);
               E.Add_Text (Outcome, "detail", "-CAP is written in permissions=; /task withhold " & First_Word & " "
                           & Cap (Cap'First + 1 .. Cap'Last) & " takes it away");
            elsif Cap /= "" then
               E.Add_Text (Outcome, "value", Cap);
               E.Add_Text (Outcome, "detail", (if Capability_Near (Cap) /= ""
                                               then "did you mean " & Capability_Near (Cap) & "? " else "")
                           & "they are read_source, write_source, read_specs, write_specs,"
                           & " run_build, run_tests, run_static_analysis, create_children, propose_tasks,"
                           & " request_integration, use_network and execute_external_process");
            end if;
            Fail (Outcome);
            return;
         end if;
         Tk.Definition (Store, First_Word, Defined, Read);
         if E.Is_Error (Read) then
            Fail (Read);
            return;
         end if;
         declare
            Kind     : constant String := R.Get (Defined, "kind");
            Own      : constant String := R.Get (Defined, "permissions");
            Of_Kind  : constant Pm.Permission_Set := Pm.Effective (Store, Kind, "", Within_Sandbox => False);
            Mine     : constant Pm.Permission_Set :=
              Pm.Effective (Store, Kind, "", Task_Level => Own, Within_Sandbox => False);
            Now_Held : constant String :=
              (if Own = "" then Pm.Image (Of_Kind)
               elsif (for all Line of Model_Runner.Framework.Lines_Of
                                        (Ada.Strings.Fixed.Translate
                                           (Own, Ada.Strings.Maps.To_Mapping (";", [1 => ASCII.LF])))
                      => Ada.Strings.Fixed.Index (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both), "-") = 1)
               then Pm.Image (Mine)
               else Ada.Strings.Fixed.Translate (Own, Ada.Strings.Maps.To_Mapping (";", [1 => ASCII.LF])));
            --  Its own permissions only take away -- -use_network -- or it
            --  has none: it follows its kind, and what is taken is all it
            --  says, so later changes above still reach it.
            Minus_Line : constant String := "-" & Cap;
            Own_Lines  : constant Model_Runner.Framework.Name_Lists.Vector :=
              Model_Runner.Framework.Lines_Of
                (Ada.Strings.Fixed.Translate (Own, Ada.Strings.Maps.To_Mapping (";", [1 => ASCII.LF])));
            Minus_Only : constant Boolean :=
              (for all Line of Own_Lines =>
                 Ada.Strings.Fixed.Index (Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both), "-") = 1);
         begin
            --  Several capabilities named: one at a time, said so.
            for Word of Model_Runner.Framework.Lines_Of
                          (Ada.Strings.Fixed.Translate (Limits, Ada.Strings.Maps.To_Mapping (" ", [1 => ASCII.LF])))
            loop
               if (for some One in Pm.Capability => Pm.Word (One) = Word) then
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "what to " & (if Granting then "grant" else "withhold"));
                  E.Add_Text (Outcome, "value", Cap & " " & Word);
                  E.Add_Text (Outcome, "detail", "/task " & (if Granting then "grant" else "withhold")
                              & " takes one capability at a time: /task " & (if Granting then "grant" else "withhold")
                              & " " & First_Word & " " & Cap & ", then /task "
                              & (if Granting then "grant" else "withhold") & " " & First_Word & " " & Word
                              & "; nothing was changed");
                  Fail (Outcome);
                  return;
               end if;
            end loop;
            --  The kind gives it and the role of an agent at work takes it
            --  away: no grant to a task gives it back, the role's does.
            if Granting and then Of_Kind (Which).Granted
              and then not Pm.Effective (Store, Kind, "worker", Within_Sandbox => False) (Which).Granted
            then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the capability to grant");
               E.Add_Text (Outcome, "value", Cap);
               E.Add_Text (Outcome, "detail", "role.worker withholds it from every agent at work, and a task is"
                           & " given no more; /reconfigure map.permission.role.worker." & Cap
                           & "=inherit gives it back");
               Fail (Outcome);
               return;
            end if;
            --  Had already, as asked: said, and no revision made.
            if Granting and then Limits = ""
              and then (Own_Lines.Contains (Cap)
                        or else (Minus_Only and then not Own_Lines.Contains (Minus_Line)
                                 and then Of_Kind (Which).Granted and then Of_Kind (Which).Roots.Is_Empty))
            then
               Pres.Put_Note (Screen, "cli.task.granted_already",
                              [Loc.Named ("name", First_Word), Loc.Named ("value", Cap)]);
               return;
            end if;
            if not Granting and then Limits /= "" then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "what to withhold");
               E.Add_Text (Outcome, "value", Limits);
               E.Add_Text (Outcome, "detail", "/task withhold takes a capability alone; /task grant " & First_Word
                           & " " & Cap & " " & Limits & " narrows it to that");
               Fail (Outcome);
               return;
            end if;
            if Minus_Only and then not Granting then
               if Own_Lines.Contains (Minus_Line) or else not Of_Kind (Which).Granted then
                  Pres.Put_Note (Screen, "cli.task.withheld_already",
                                 [Loc.Named ("name", First_Word), Loc.Named ("value", Cap)]);
                  return;
               end if;
               Given.Include ("permissions", (if Own = "" then Minus_Line else Own & ASCII.LF & Minus_Line));
               Edit (First_Word, Given, Inputs => False);
               return;
            elsif Minus_Only and then Granting and then Limits = "" and then Own_Lines.Contains (Minus_Line) then
               --  Given back: what took it away goes.
               declare
                  Left : Unbounded_String;
               begin
                  for Line of Own_Lines loop
                     if Line /= Minus_Line then
                        Append (Left, (if Left = Null_Unbounded_String then "" else ASCII.LF & "") & Line);
                     end if;
                  end loop;
                  Given.Include ("permissions", To_String (Left));
                  Edit (First_Word, Given, Inputs => False);
               end;
               return;
            end if;
            --  A task narrows its kind; it is not given past it -- and the
            --  level that withholds it named, the kind's or the project's.
            if Granting and then not Of_Kind (Which).Granted then
               declare
                  Present  : Boolean;
                  Of_Level : constant Pm.Permission_Set := Pm.Level_Of (Store, "kind." & Kind, Present);
                  By_Kind  : constant Boolean := Present and then not Of_Level (Which).Granted;
                  --  The project above withholding it too: both said at once.
                  By_Project : constant Boolean :=
                    not Pm.Effective (Store, "", "", Within_Sandbox => False) (Which).Granted;
                  --  A decision ruling the setting the hint would change:
                  --  named, as changing it would go against the ruling.
                  function Ruled (Setting : String) return String is
                     package Nt renames Model_Runner.Framework.Intent;
                     Said : Unbounded_String;
                  begin
                     for Dec of Nt.List (Store, Nt.Decision) loop
                        if Nt.State_Of (Store, Nt.Decision, Dec) = "accepted" then
                           declare
                              All_Of : Model_Runner.Framework.Name_Lists.Vector :=
                                Nt.Also_Governs (Store, Nt.Decision, Dec);
                           begin
                              All_Of.Append (Nt.Governs (Store, Nt.Decision, Dec));
                              for One of All_Of loop
                                 if Ada.Strings.Fixed.Index (One, Setting & " = ") = One'First then
                                    Append (Said, "; " & Dec & " rules it " & One (One'First + Setting'Length + 3
                                                                                  .. One'Last)
                                            & " -- /decision govern " & Dec & " " & Setting
                                            & " on, or a decision superseding it, first");
                                 end if;
                              end loop;
                           end;
                        end if;
                     end loop;
                     return To_String (Said);
                  end Ruled;
                  Rulings : constant String :=
                    (if By_Project then Ruled ("map.permission.project." & Cap) else "")
                    & (if By_Kind then Ruled ("map.permission.kind." & Kind & "." & Cap) else "");
               begin
                  Outcome := E.Make (E.Framework_Input_Invalid);
                  E.Add_Text (Outcome, "name", "the capability to grant");
                  E.Add_Text (Outcome, "value", Cap);
                  E.Add_Text (Outcome, "detail",
                              (if By_Kind and then By_Project
                               then "its kind " & Kind & " and the project both withhold it, and a task is given"
                                    & " no more than either; /reconfigure map.permission.project." & Cap
                                    & "=on and /reconfigure map.permission.kind." & Kind & "." & Cap
                                    & "=on grant it to both"
                               elsif By_Kind
                               then "its kind " & Kind & " withholds it, and a task is given no more than its kind;"
                                    & " /reconfigure map.permission.kind." & Kind & "." & Cap
                                    & "=on grants it to the kind"
                               else "the project withholds it, and neither a kind nor a task is given more than the"
                                    & " project; /reconfigure map.permission.project." & Cap & "=on grants it")
                              & Rulings);
               end;
               Fail (Outcome);
               return;
            --  Roots wider than the kind's: a task is not given past it.
            elsif Granting and then not Of_Kind (Which).Roots.Is_Empty
              and then Ada.Strings.Fixed.Index (Limits, "roots=") > 0
            then
               declare
                  At_Roots : constant Natural := Ada.Strings.Fixed.Index (Limits, "roots=");
                  Stop     : constant Natural := Ada.Strings.Fixed.Index (Limits & " ", " ", At_Roots);
                  Asked    : constant String := Limits (At_Roots + 6 .. Stop - 1);
                  Start    : Natural := Asked'First;
               begin
                  for Index in Asked'First .. Asked'Last + 1 loop
                     if Index > Asked'Last or else Asked (Index) = '|' then
                        declare
                           One : constant String := Asked (Start .. Index - 1);
                        begin
                           if not (for some Root of Of_Kind (Which).Roots =>
                                     One'Length >= Root'Length
                                     and then One (One'First .. One'First + Root'Length - 1) = Root)
                           then
                              Outcome := E.Make (E.Framework_Input_Invalid);
                              E.Add_Text (Outcome, "name", "the roots to grant");
                              E.Add_Text (Outcome, "value", One);
                              E.Add_Text (Outcome, "detail", "it is outside what its kind " & Kind & " gives -- "
                                          & Pm.Grant_Text (Of_Kind (Which)) & " -- and a task is given no more"
                                          & " than its kind; a root within those narrows it");
                              Fail (Outcome);
                              return;
                           --  Wholly inside what the kind denies: nothing.
                           elsif (for some Denied of Of_Kind (Which).Deny =>
                                    One'Length >= Denied'Length
                                    and then One (One'First .. One'First + Denied'Length - 1) = Denied)
                           then
                              Outcome := E.Make (E.Framework_Input_Invalid);
                              E.Add_Text (Outcome, "name", "the roots to grant");
                              E.Add_Text (Outcome, "value", One);
                              E.Add_Text (Outcome, "detail", "its kind " & Kind & " denies it -- "
                                          & Pm.Grant_Text (Of_Kind (Which)) & " -- and a task is given no more"
                                          & " than its kind; a root within those, outside what is denied, narrows it");
                              Fail (Outcome);
                              return;
                           end if;
                        end;
                        Start := Index + 1;
                     end if;
                  end loop;
               end;
            elsif Granting and then Own = "" and then Limits = "" then
               declare
                  Present : Boolean;
                  Ignored : constant Pm.Permission_Set := Pm.Level_Of (Store, "kind." & Kind, Present);
                  pragma Unreferenced (Ignored);
               begin
                  --  Where it comes from, as /task show names it.
                  Pres.Put_Note (Screen, "cli.task.granted_already",
                                 [Loc.Named ("name", First_Word), Loc.Named ("value", Cap),
                                  Loc.Named ("other",
                                             (if Present then "its kind " & Kind
                                              else "the project's permissions, which its kind " & Kind
                                                   & " takes"))]);
               end;
               return;
            end if;
            for Line of Model_Runner.Framework.Lines_Of (Now_Held) loop
               declare
                  Trimmed : constant String := Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
                  Blank   : constant Natural := Ada.Strings.Fixed.Index (Trimmed & " ", " ");
               begin
                  if Trimmed /= "" and then Trimmed (Trimmed'First .. Blank - 1) /= Cap then
                     Append (Kept, (if Kept = Null_Unbounded_String then "" else ASCII.LF & "") & Trimmed);
                  end if;
               end;
            end loop;
            --  Its places given anew, not added to: said, with what they were.
            if Granting and then Ada.Strings.Fixed.Index (Limits, "roots=") > 0 then
               for Line of Model_Runner.Framework.Lines_Of (Now_Held) loop
                  declare
                     Trimmed : constant String := Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
                  begin
                     if Ada.Strings.Fixed.Index (Trimmed, Cap & " ") = Trimmed'First
                       and then Ada.Strings.Fixed.Index (Trimmed, "roots=") > 0
                       and then Ada.Strings.Fixed.Index (Trimmed, Limits) = 0
                     then
                        Pres.Put_Note (Screen, "cli.task.roots_replaced",
                                       [Loc.Named ("name", First_Word), Loc.Named ("value", Trimmed),
                                        Loc.Named ("detail", Cap & " " & Limits)]);
                     end if;
                  end;
               end loop;
            end if;
            if Granting then
               Append (Kept, (if Kept = Null_Unbounded_String then "" else ASCII.LF & "") & Cap
                             & (if Limits = "" then "" else " " & Limits));
            elsif Kept = Null_Unbounded_String then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the capability to withhold");
               E.Add_Text (Outcome, "value", Cap);
               E.Add_Text (Outcome, "detail", "it is all " & First_Word & " may do; withheld, it could do"
                           & " nothing -- /task cancel " & First_Word & " lets it go");
               Fail (Outcome);
               return;
            elsif Ada.Strings.Fixed.Index (Now_Held, Cap) = 0 then
               Pres.Put_Note (Screen, "cli.task.withheld_already",
                              [Loc.Named ("name", First_Word), Loc.Named ("value", Cap)]);
               return;
            end if;
            Given.Include ("permissions", To_String (Kept));
            Edit (First_Word, Given, Inputs => False);
            --  A place it names that the project has not: said, as a typo
            --  grants nothing where it was meant to.
            if Granting
              and then Pm.Missing_Places (Ada.Directories.Containing_Directory (S.Root (Store)), Limits) /= ""
            then
               Pres.Put_Note (Screen, "cli.project.places_missing",
                              [Loc.Named ("name", First_Word & " " & Cap),
                               Loc.Named ("detail",
                                          Pm.Missing_Places
                                            (Ada.Directories.Containing_Directory (S.Root (Store)), Limits))]);
            end if;
         end;
      end Grant_Or_Withhold;

      --  task note TASK TEXT: words added to its notes, what they said kept.
      procedure Note is
         Defined : R.Item;
         Read    : E.Error_Info;
         Given   : Tk.Field_Map;
         Text    : constant String := Ada.Strings.Fixed.Trim (After_First, Ada.Strings.Both);
      begin
         if First_Word = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "the task and what to note: /task note TASK-ID TEXT");
            Fail (Outcome);
            return;
         elsif not Needs_Task then
            return;
         end if;
         if Text = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "what to note: /task note " & First_Word & " TEXT");
            Fail (Outcome);
            return;
         end if;
         Tk.Definition (Store, First_Word, Defined, Read);
         Given.Include ("notes", (if E.Is_Error (Read) or else R.Get (Defined, "notes") = "" then Text
                                  else R.Get (Defined, "notes") & " -- " & Text));
         Edit (First_Word, Given);
      end Note;

      --  A task decomposed: task split TASK FIRST TITLE; SECOND TITLE.
      procedure Split_Task is
         Titles : Model_Runner.Framework.Name_Lists.Vector;
         Made   : Model_Runner.Framework.Name_Lists.Vector;
         Rest   : constant String := After_First;
         Start  : Natural := Rest'First;
      begin
         for Index in Rest'First .. Rest'Last + 1 loop
            if Index > Rest'Last or else Rest (Index) = ';' then
               declare
                  Title : constant String :=
                    Ada.Strings.Fixed.Trim (Rest (Start .. Index - 1), Ada.Strings.Both);
               begin
                  if Title /= "" then
                     Titles.Append (Title);
                  end if;
               end;
               Start := Index + 1;
            end if;
         end loop;
         if First_Word = "" or else Titles.Is_Empty then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "the task and its parts' titles, separated by ;");
            Fail (Outcome);
            return;
         end if;
         --  Parts it has, which these join: said, not added unsaid; and one
         --  part alone, where it has none, is the task itself.
         declare
            Had : constant Model_Runner.Framework.Name_Lists.Vector := Tk.Children (Store, First_Word);
         begin
            if Natural (Titles.Length) = 1 and then Had.Is_Empty then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the parts of " & First_Word);
               E.Add_Text (Outcome, "value", Titles.First_Element);
               E.Add_Text (Outcome, "detail", "one part is the task itself: name two or more, a ; apart,"
                           & " or /task edit " & First_Word & " title=... renames it");
               Fail (Outcome);
               return;
            elsif not Had.Is_Empty then
               Pres.Put_Note (Screen, "cli.task.parts_added",
                              [Loc.Named ("name", First_Word), Loc.Named ("detail", Joined (Had))]);
            end if;
         end;

         --  A part it has already, or one named twice, is that part: said,
         --  and not made again.
         declare
            Kept : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Title of Titles loop
               declare
                  Lower_Title : constant String := Ada.Characters.Handling.To_Lower (Title);
                  Existing    : Unbounded_String;
               begin
                  for Child of Tk.Children (Store, First_Word) loop
                     declare
                        Defined : R.Item;
                        Read    : E.Error_Info;
                     begin
                        Tk.Definition (Store, Child, Defined, Read);
                        if E.Is_Ok (Read)
                          and then Ada.Characters.Handling.To_Lower (R.Get (Defined, "title"))
                                   = Lower_Title
                          and then Tk.State_Of (Store, Child) not in "cancelled" | "rejected"
                        then
                           Existing := To_Unbounded_String (Child);
                        end if;
                     end;
                  end loop;
                  if Existing /= Null_Unbounded_String then
                     Pres.Put_Note
                       (Screen, "cli.task.part_there",
                        [Loc.Named ("name", To_String (Existing)), Loc.Named ("detail", Title)]);
                  elsif not (for some Other of Kept =>
                               Ada.Characters.Handling.To_Lower (Other) = Lower_Title)
                  then
                     Kept.Append (Title);
                  end if;
               end;
            end loop;
            Titles := Kept;
         end;
         if Titles.Is_Empty then
            return;
         end if;
         Tk.Decompose (Store, Change, First_Word, Titles, Made, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         --  Parts a person split it into are the parts they want: accepted,
         --  not candidates waiting on the same person again -- unless the
         --  task itself is still a candidate, whose parts wait with it.
         if E.Is_Ok (Outcome) and then Tk.State_Of (Store, First_Word) /= "candidate" then
            for Part of Made loop
               if Tk.State_Of (Store, Part) = "candidate" then
                  Tk.Move (Store, Change, Part, "accepted", "", Status => Outcome,
                           Actor => Model_Runner.Framework.Transitions.User);
                  exit when E.Is_Error (Outcome);
               end if;
            end loop;
            if E.Is_Ok (Outcome) then
               Commit;
            end if;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         for Index in 1 .. Natural (Made.Length) loop
            Pres.Put_Message (Screen, "cli.task.created",
                              [Loc.Named ("name", Made (Index)),
                               Loc.Named ("detail", Titles (Index))]);
         end loop;
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", First_Word),
             Loc.Named ("value", Model_Runner.Framework.State_Said (Moved_State (First_Word)))]);
         --  Its parts are of its kind: said, with how one is made another.
         if R.Get (Tk_Definition (First_Word), "kind") /= "" then
            declare
               function Test_Part return String is
               begin
                  for One of Made loop
                     if Ada.Strings.Fixed.Index
                          (Ada.Characters.Handling.To_Lower (R.Get (Tk_Definition (One), "title")), "test") > 0
                     then
                        return One;
                     end if;
                  end loop;
                  return Made.First_Element;
               end Test_Part;
            begin
               Pres.Put_Note (Screen, "cli.task.parts_kind",
                              [Loc.Named ("name", First_Word),
                               Loc.Named ("value", R.Get (Tk_Definition (First_Word), "kind")),
                               --  The part its title says is a test, where one does.
                               Loc.Named ("detail", Test_Part)]);
            end;
         end if;
         --  What became ready, before what to do with it.
         Say_Became_Ready;
         --  What comes next: a candidate parent is accepted with its parts,
         --  or it is left a candidate once they are done; accepted, the
         --  first part ready is worked.
         declare
            Waiting : Unbounded_String :=
              (if Tk.State_Of (Store, First_Word) = "candidate" then To_Unbounded_String (First_Word)
               else Null_Unbounded_String);
            Ready   : Unbounded_String;
         begin
            for Part of Made loop
               if Tk.State_Of (Store, Part) = "candidate" then
                  Append (Waiting, (if Waiting = Null_Unbounded_String then "" else " ") & Part);
               elsif Ready = Null_Unbounded_String and then Tk.Ready (Store, Part).Ready then
                  Ready := To_Unbounded_String (Part);
               end if;
            end loop;
            if Waiting /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.next.parts", [Loc.Named ("detail", To_String (Waiting))]);
            elsif Ready /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", To_String (Ready))]);
            end if;
         end;
      end Split_Task;

      --  Every open task of one component placed in another: task rehome
      --  OLD NEW.
      procedure Rehome is
         Space   : constant Natural := Ada.Strings.Fixed.Index (After_First, " ");
         Moved   : Model_Runner.Framework.Name_Lists.Vector;
         Left    : Model_Runner.Framework.Name_Lists.Vector;
         Kept_Home : Model_Runner.Framework.Name_Lists.Vector;
         Homes     : Model_Runner.Framework.Name_Lists.Vector;
         Busy      : Model_Runner.Framework.Name_Lists.Vector;
         Belongs   : Model_Runner.Framework.Name_Lists.Vector;

         procedure Refuse (Name, Value, Detail : String) is
         begin
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", Name);
            E.Add_Text (Outcome, "value", Value);
            E.Add_Text (Outcome, "detail", Detail);
            Fail (Outcome);
         end Refuse;
      begin
         if First_Word = "" or else After_First = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "the component its tasks are in, and the one to place"
                        & " them in: /task rehome OLD NEW");
            Fail (Outcome);
            return;
         elsif Space /= 0 then
            Refuse ("/task rehome", Argument, "it takes two words, OLD and NEW, and was given more");
            return;
         end if;

         --  From a component some task is in, into one of the project's.
         for Id of Tk.List (Store) loop
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
            begin
               Tk.Definition (Store, Id, Defined, Read);
               if E.Is_Ok (Read) and then R.Get (Defined, "component") = First_Word then
                  if Tk.State_Of (Store, Id) in "complete" | "cancelled" | "rejected" then
                     Left.Append (Id);

                  --  Being worked, or its work waiting to be taken in: not
                  --  revised now.
                  elsif Tk.State_Of (Store, Id) in "running" | "verification" then
                     Busy.Append (Id);

                  --  Serving a requirement that belongs to the component it is
                  --  in: where it belongs.
                  elsif (for some Requirement of Model_Runner.Framework.Lines_Of
                                                   (R.Get (Defined, "requirements")) =>
                           Model_Runner.Framework.Intent.Links
                             (Store, Model_Runner.Framework.Intent.Requirement, Requirement,
                              Model_Runner.Framework.Intent.Component).Contains (First_Word))
                  then
                     Belongs.Append (Id);

                  --  Serving a requirement that belongs to another component:
                  --  its place is that one, not the one named here.
                  elsif (for some Requirement of Model_Runner.Framework.Lines_Of
                                                   (R.Get (Defined, "requirements")) =>
                           (for some Linked of Model_Runner.Framework.Intent.Links
                                                 (Store, Model_Runner.Framework.Intent.Requirement,
                                                  Requirement,
                                                  Model_Runner.Framework.Intent.Component) =>
                              Linked /= After_First))
                  then
                     Kept_Home.Append (Id);
                     for Requirement of Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                     loop
                        for Linked of Model_Runner.Framework.Intent.Links
                                        (Store, Model_Runner.Framework.Intent.Requirement, Requirement,
                                         Model_Runner.Framework.Intent.Component)
                        loop
                           if Linked /= First_Word and then not Homes.Contains (Linked) then
                              Homes.Append (Linked);
                           end if;
                        end loop;
                     end loop;
                  else
                     Moved.Append (Id);
                  end if;
               end if;
            end;
         end loop;
         if Ada.Strings.Fixed.Index (First_Word, "TASK-") = First_Word'First then
            --  A task, not a component: one is placed by editing it.
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the component whose tasks move");
            E.Add_Text (Outcome, "value", First_Word);
            E.Add_Text (Outcome, "detail", "rehome moves every open task of a component; /task edit "
                        & First_Word & " component="
                        & (if Tk.Components (Store).Contains (After_First) then After_First else "COMPONENT")
                        & " moves one -- the project's components are " & Joined (Tk.Components (Store)));
            Fail (Outcome);
            return;
         elsif Moved.Is_Empty and then not (Busy.Is_Empty and then Belongs.Is_Empty) then
            Outcome := E.Make (E.Framework_Task_Not_Ready);
            E.Add_Text (Outcome, "name", "the open tasks in " & First_Word);
            E.Add_Text (Outcome, "detail",
                    "none of them moves: "
                    & (if Belongs.Is_Empty then ""
                       else Joined (Belongs) & (if Natural (Belongs.Length) = 1 then " serves" else " serve")
                            & " requirements that belong to " & First_Word
                            & ", where they are" & (if Busy.Is_Empty then "" else "; "))
                    & (if Busy.Is_Empty then ""
                       else Joined (Busy) & (if Natural (Busy.Length) = 1 then " is" else " are")
                            & " being worked or waiting to be taken in"));
            Fail (Outcome);
            return;
         elsif Moved.Is_Empty and then not Kept_Home.Is_Empty then
            Outcome := E.Make (E.Framework_Task_Not_Ready);
            E.Add_Text (Outcome, "name", "the open tasks in " & First_Word);
            E.Add_Text (Outcome, "detail",
                        Joined (Kept_Home) & " serve requirements that belong to " & Joined (Homes)
                        & "; /task edit ID component=" & Homes.First_Element & " places one there");
            Fail (Outcome);
            return;
         elsif Moved.Is_Empty then
            Refuse ("the component its tasks are in", First_Word,
                    (if Left.Is_Empty then "no task is in it"
                     else "only ended tasks are in it (" & Joined (Left)
                          & "), and ended tasks stay where they were done"));
            return;
         elsif First_Word = After_First then
            Pres.Put_Note (Screen, "cli.intent.already",
                           [Loc.Named ("name", Joined (Moved)), Loc.Named ("value", "in " & After_First)]);
            return;
         elsif not Tk.Components (Store).Contains (After_First) then
            Refuse ("the component to place them in", After_First,
                    "the project's components are " & Joined (Tk.Components (Store))
                    & "; /reconfigure add set.components " & After_First & " makes it one, and"
                    & " /reconfigure map.component." & After_First & "=roots=DIR places it once its"
                    & " files are there");
            return;
         end if;

         for Id of Moved loop
            declare
               Fields : Tk.Field_Map;
            begin
               Fields.Include ("component", After_First);
               Tk.Revise (Store, Change, Id, Fields, Outcome);
               if E.Is_Error (Outcome) then
                  Fail (Outcome);
                  return;
               end if;
            end;
         end loop;
         Commit;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.task.rehomed",
            [Loc.Named ("name", First_Word), Loc.Named ("value", After_First),
             Loc.Named ("detail", Joined (Moved))]);
         --  What stayed is part of what it did: said however quiet.
         if not Left.Is_Empty then
            Pres.Put_Message (Screen, "cli.task.rehome_left",
                              [Loc.Named ("name", First_Word), Loc.Named ("detail", Joined (Left))]);
         end if;
         if not Kept_Home.Is_Empty then
            Pres.Put_Message (Screen, "cli.task.rehome_kept",
                              [Loc.Named ("name", First_Word), Loc.Named ("value", Joined (Homes)),
                               Loc.Named ("detail", Joined (Kept_Home))]);
         end if;
         if not Belongs.Is_Empty then
            Pres.Put_Message (Screen, "cli.task.rehome_belongs",
                              [Loc.Named ("name", First_Word), Loc.Named ("detail", Joined (Belongs))]);
         end if;
         if not Busy.Is_Empty then
            Pres.Put_Message (Screen, "cli.task.rehome_busy",
                              [Loc.Named ("name", First_Word), Loc.Named ("detail", Joined (Busy))]);
         end if;
      end Rehome;

      procedure Show is
         View : R.Item;
      begin
         if not Needs_Task then
            return;
         end if;
         Tk.Effective (Store, Argument, View, Outcome);
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         --  In groups, each under its title: what it is, where it stands,
         --  how it is judged, what its agent may do, and what governs it.
         declare

            --  A field by its own name, the record's grouping left out --
            --  definition.title is title -- and one that says nothing, or
            --  is the harness's own bookkeeping, not shown.
            --  A field of a group, its value coloured by how it stands
            --  where the terminal shows colour: a state, what stops it.
            procedure Grouped (Name, Value : String) is
               Field : constant String := Ada.Strings.Fixed.Trim (Name, Ada.Strings.Both);
               First : constant String :=
                 (if Ada.Strings.Fixed.Index (Value & ",", ",") > 0
                  then Value (Value'First .. Ada.Strings.Fixed.Index (Value & ",", ",") - 1) else Value);
            begin
               Pres.Put_Pair
                 (Screen, "cli.task.grouped", Name, Value,
                  (if Field = "state" and then First = "complete" then Pres.Good
                   elsif Field = "state" and then First in "failed" | "blocked" | "cancelled" | "rejected"
                     and then Ada.Strings.Fixed.Index (Value, "waiting for its parts") = 0
                   then Pres.Bad
                   elsif Field in "why it stopped" then Pres.Bad
                   elsif Field = "state" or else Field in "blocked_by" | "why it cannot start" | "to start"
                   then Pres.Pending
                   elsif Field = "ready" and then Value = "true" then Pres.Good
                   else Pres.Plain));
            end Grouped;

            --  A task's gates in words: what each asks of it.
            function Gates_Said (Listed : String) return String is
               Said : Unbounded_String;
            begin
               for Gate of Model_Runner.Framework.Lines_Of
                 (Ada.Strings.Fixed.Translate (Listed, Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
               loop
                  declare
                     G : constant String := Ada.Strings.Fixed.Trim (Gate, Ada.Strings.Both);
                  begin
                     --  Its parts, where it has none: nothing to say.
                     if G = "children" and then Tk.Children (Store, Argument).Is_Empty then
                        goto Next_Gate;
                     end if;
                     Append (Said, (if Said = Null_Unbounded_String then "" else ", ")
                             & (if G = "children" then "its parts are done"
                                elsif G = "implementation_present" then "it changed something"
                                elsif G = "integration" then "its work is taken in"
                                elsif G = "no_blocking_issue" then "no issue blocks it"
                                elsif G = "verification" then "its checks pass"
                                else G));
                  end;
                  <<Next_Gate>>
               end loop;
               return To_String (Said);
            end Gates_Said;

            --  Capabilities granted that the agent has no way to use here,
            --  said after what it may do; "" where there are none.
            --  Its checks run when its work is taken in, not by it in its
            --  workspace -- where there is work to take in: not an analysis's.
            function Checks_Later return Boolean
            is (R.Get (View, "workspace_policy") = "workspace"
                and then R.Get (View, "definition.kind") /= "analysis"
                and then (Ada.Strings.Fixed.Index (R.Get (View, "permissions"), "run_tests") > 0
                          or else Ada.Strings.Fixed.Index (R.Get (View, "permissions"), "run_build") > 0));

            function Granted_Unused return String is
               package Pm renames Model_Runner.Framework.Permissions;
               Allowed : constant Pm.Permission_Set :=
                 Pm.Effective (Store, R.Get (View, "definition.kind"), "",
                               Task_Level => R.Get (View, "definition.permissions"), Within_Sandbox => True);
               Said    : Unbounded_String;
            begin
               for One in Pm.Capability loop
                  if Allowed (One).Granted
                    and then Pm.Word (One) in "use_network" | "run_build" | "execute_external_process"
                                             | "request_integration"
                    --  A build its checks run is used.
                    and then not (Pm.Word (One) = "run_build"
                                  and then (Checks_Later
                                            or else Ada.Strings.Fixed.Index
                                                      (Model_Runner.Framework.Work.May_Do (Store, Argument), "checks")
                                                    > 0))
                  then
                     Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Pm.Word (One));
                  end if;
               end loop;
               return (if Said = Null_Unbounded_String then ""
                       else "; also granted, though nothing it does here uses them: " & To_String (Said));
            end Granted_Unused;

            procedure Line (Name : String) is
               function Starts (Prefix : String) return Boolean
               is (Name'Length > Prefix'Length
                   and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix);

               function Shown_Name return String
               is (if Starts ("definition.") then Name (Name'First + 11 .. Name'Last)
                   elsif Starts ("runtime.") then Name (Name'First + 8 .. Name'Last)
                   elsif Starts ("authority.") then "rule " & Name (Name'First + 10 .. Name'Last)
                   else Name);
               --  What the configuration holds for a setting; "" where unset.
               function Configured (Setting : String) return String is
                  Config : R.Item;
                  Read   : E.Error_Info;
               begin
                  Model_Runner.Framework.Configurations.Read (Store, Config, Read);
                  return (if E.Is_Ok (Read) then R.Get (Config, Setting) else "");
               end Configured;

               --  Whether a ruling on a capability holds as the configuration
               --  now gives it, however that is written.
               function Holds (Setting, Ruling : String) return Boolean is
                  Config : R.Item;
                  Read   : E.Error_Info;
               begin
                  Model_Runner.Framework.Configurations.Read (Store, Config, Read);
                  return E.Is_Ok (Read)
                    and then Model_Runner.Framework.Permissions.Ruling_Agrees (Store, Config, Setting, Ruling);
               end Holds;

               --  A rule's text without where the baseline keeps it.
               function Shown_Value return String is
                  Raw   : constant String := R.Get (View, Name);
                  Parts : constant Natural := Ada.Strings.Fixed.Index (Raw, "waiting for its children: ");
                  --  Its parts, as /task list says them, and listed below once.
                  --  A copy its reason says to restore, put back since: the
                  --  reason as it stands now, not as it was written.
                  Restore_At : constant Natural := Ada.Strings.Fixed.Index (Raw, "/task kept restore ");
                  Copy_End   : constant Natural :=
                    (if Restore_At = 0 then 0
                     else Ada.Strings.Fixed.Index (Raw & " ", " ", Restore_At + 19) - 1);
                  Put_Back   : constant Boolean :=
                    Restore_At > 0 and then Copy_End > Restore_At + 19
                    and then Model_Runner.Framework.Workspaces.Was_Restored
                               (Store, Raw (Restore_At + 19 .. Copy_End));
                  Still_At   : constant Natural :=
                    Ada.Strings.Fixed.Index (Raw, "what it changed is still in the project");
                  Held  : constant String :=
                    (if Name = "blocked_by" and then Put_Back and then Still_At > 0
                     then Raw (Raw'First .. Still_At - 1) & "what it changed was undone: "
                          & Raw (Restore_At + 19 .. Copy_End) & " was put back"
                     elsif Name = "blocked_by" and then Parts > 0
                     then Raw (Raw'First .. Parts - 1) & "waiting for its parts (listed under parts)"
                     --  As /task list says it: accepted is ready, or waiting;
                     --  blocked waits for its parts, or was stopped.
                     elsif Name = "runtime.state" then Moved_State (Argument)
                     else Raw);
                  --  A list of identifiers on one line.
                  --  Gates in one order for every kind: by name.
                  function Sorted (Text : String) return String is
                     package Sorting is new Model_Runner.Framework.Name_Lists.Generic_Sorting;
                     Items : Model_Runner.Framework.Name_Lists.Vector;
                  begin
                     for Part of Model_Runner.Framework.Lines_Of
                       (Ada.Strings.Fixed.Translate (Text, Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                     loop
                        if Ada.Strings.Fixed.Trim (Part, Ada.Strings.Both) /= "" then
                           Items.Append (Ada.Strings.Fixed.Trim (Part, Ada.Strings.Both));
                        end if;
                     end loop;
                     Sorting.Sort (Items);
                     return Joined (Items);
                  end Sorted;
                  --  What it waits for, the done ones said apart: a task
                  --  complete is waited for no longer.
                  function Waits_For return String is
                     Open, Done : Unbounded_String;
                  begin
                     for One of Model_Runner.Framework.Lines_Of (Held) loop
                        if Tk.State_Of (Store, One) = "complete" then
                           Append (Done, (if Done = Null_Unbounded_String then "" else ", ") & One);
                        else
                           Append (Open, (if Open = Null_Unbounded_String then "" else ", ") & One);
                        end if;
                     end loop;
                     return (if Open = Null_Unbounded_String then "nothing now" else To_String (Open))
                       & (if Done = Null_Unbounded_String then "" else " (" & To_String (Done) & " done)");
                  end Waits_For;
                  Value : constant String :=
                    (if Name = "definition.depends_on" then Waits_For
                     elsif Name in "definition.requirements" | "definition.depends_on"
                     then Ada.Strings.Fixed.Trim
                            (Joined (Model_Runner.Framework.Lines_Of (Held)),
                             Ada.Strings.Both)
                     elsif Name = "gates" then Sorted (Held)
                     --  Its parent with how it stands: an ended one said.
                     elsif Name = "definition.parent" and then Held /= ""
                     then Held & " (" & Listed_State (Held) & ")"
                     else Held);
                  --  A rule's LEVEL SOURCE: TEXT is TEXT, and (SOURCE) after
                  --  it where a person or an entry said it.
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Value, ": ");
                  Space : constant Natural := Ada.Strings.Fixed.Index (Value, " ");
                  Level : constant String :=
                    (if Colon = 0 or else Space = 0 or else Space > Colon then ""
                     else Value (Value'First .. Space - 1));
               begin
                  return (if Ada.Strings.Fixed.Index (Name, "authority.") /= Name'First or else Level = ""
                            or else not (for all C of Level => C in 'a' .. 'z' | '_')
                          then Value
                          elsif Level in "project_baseline" | "language_baseline"
                          then Value (Colon + 2 .. Value'Last)
                          --  An instruction on a setting is told to the agent,
                          --  not applied: said, so it is not read as the limit.
                          --  Held by the configuration already: applied.
                          elsif (Ada.Strings.Fixed.Index (Name, "authority.scalar.") = Name'First
                                 or else Ada.Strings.Fixed.Index (Name, "authority.map.") = Name'First
                                 or else Ada.Strings.Fixed.Index (Name, "authority.set.") = Name'First)
                            and then (if Ada.Strings.Fixed.Index (Name, "authority.map.permission.") = Name'First
                                      --  A capability as it holds: off withheld
                                      --  however, by default or written whole.
                                      then Holds (Name (Name'First + 10 .. Name'Last), Value (Colon + 2 .. Value'Last))
                                      else Configured (Name (Name'First + 10 .. Name'Last))
                                           = Value (Colon + 2 .. Value'Last))
                          then Value (Colon + 2 .. Value'Last) & " (" & Value (Space + 1 .. Colon - 1)
                               & "; applied: the configuration holds it)"
                          elsif Ada.Strings.Fixed.Index (Name, "authority.scalar.") = Name'First
                            or else Ada.Strings.Fixed.Index (Name, "authority.map.") = Name'First
                            or else Ada.Strings.Fixed.Index (Name, "authority.set.") = Name'First
                          then Value (Colon + 2 .. Value'Last) & " (" & Value (Space + 1 .. Colon - 1)
                               & "; told to the agent, not applied -- /reconfigure "
                               & Name (Name'First + 10 .. Name'Last) & "=" & Value (Colon + 2 .. Value'Last)
                               & " sets it)"
                          else Value (Colon + 2 .. Value'Last) & " (" & Value (Space + 1 .. Colon - 1) & ")");
               end Shown_Value;
            begin
               --  Also left out: what a derived task was made from, kept to
               --  know it again, and a move said already by its acceptance.
               if R.Get (View, Name) = ""
                 or else Name in "fingerprint" | "runtime.generation" | "definition.revision"
                               | "definition.created_by" | "definition.origin"
                               | "definition.derivation_key" | "kind.fields"
                 or else Ada.Strings.Fixed.Index (Name, "resource.") = Name'First
                 or else (Name = "definition.acceptance" and then R.Get (View, "definition.requirements") = "")
                 or else Ada.Strings.Fixed.Index (Shown_Name, "requirement.") = 1
                 or else (Shown_Name = "moved_by"
                          and then (R.Get (View, Name)
                                      = R.Get (View, (if R.Has (View, "runtime.accepted_by") then "runtime.accepted_by"
                                                      else "accepted_by"))
                                    --  Rejected by them: said once, as that.
                                    or else R.Get (View, Name)
                                              = R.Get (View, (if R.Has (View, "runtime.rejected_by")
                                                              then "runtime.rejected_by" else "rejected_by"))))
               then
                  return;
               end if;
               --  Not ready: blocked_by says that, and why, already.
               if Name = "ready" and then R.Get (View, Name) /= "true" and then R.Get (View, "blocked_by") /= "" then
                  return;
               end if;
               --  Why it is blocked or failed, said once: what blocked_by
               --  says already is not said again under its own name.
               if Shown_Name in "blocking_reasons" | "current_failure"
                 and then R.Get (View, "blocked_by") /= ""
                 and then Ada.Strings.Fixed.Index (R.Get (View, "blocked_by"), R.Get (View, Name)) > 0
               then
                  return;
               end if;
               --  A decision that governs it: by its title and what it says,
               --  not by its revision alone.
               if Starts ("decision.") then
                  declare
                     Held : Model_Runner.Framework.Intent.Entity;
                     Got  : E.Error_Info;
                  begin
                     Model_Runner.Framework.Intent.Read
                       (Store, Model_Runner.Framework.Intent.Decision, Name (Name'First + 9 .. Name'Last), Held, Got);
                     if E.Is_Ok (Got) then
                        Grouped ("  decision " & Name (Name'First + 9 .. Name'Last),
                                 To_String (Held.Title)
                                 --  Its text only where it says more than its title.
                                 & (if Ada.Strings.Fixed.Index (To_String (Held.Text), To_String (Held.Title)) = 1
                                       and then Length (Held.Text) <= Length (Held.Title) + 1
                                    then "" else ": " & To_String (Held.Text)));
                        return;
                     end if;
                  end;
               end if;
               --  What its agent may do, in words, not by the permissions'
               --  own names.
               if Name = "permissions" then
                  --  As its agent is told it: only what it has a tool or
                  --  a way to do, not every capability granted.
                  Grouped ("  " & "may",
                    (if Model_Runner.Framework.Work.May_Do (Store, Argument) /= ""
                     then Ada.Strings.Fixed.Translate
                            (Model_Runner.Framework.Work.May_Do (Store, Argument),
                             Ada.Strings.Maps.To_Mapping (";", ","))
                     else Model_Runner.Framework.Permissions.In_Words (R.Get (View, Name)))
                    --  Granted, and nothing its agent does uses it: said, so a
                    --  grant is seen to have been made.
                    --  Apart in a workspace its checks are not its to run:
                    --  they run when its work is taken in.
                    & (if Checks_Later
                       then " -- its checks (run_build, run_tests) run when its work is taken in, not while it"
                            & " works in its workspace"
                       else "")
                    & Granted_Unused);
                  --  The capabilities by the names /task grant and withhold
                  --  take, beside the words above.
                  declare
                     package Pm renames Model_Runner.Framework.Permissions;
                     --  As its agent has them, at work: what role.worker
                     --  withholds is not among them, and said apart.
                     Allowed : constant Pm.Permission_Set :=
                       Pm.Effective (Store, R.Get (View, "definition.kind"), "worker",
                                     Task_Level => R.Get (View, "definition.permissions"), Within_Sandbox => True);
                     Unroled : constant Pm.Permission_Set :=
                       Pm.Effective (Store, R.Get (View, "definition.kind"), "",
                                     Task_Level => R.Get (View, "definition.permissions"), Within_Sandbox => True);
                     Named   : Unbounded_String;
                     By_Role : Unbounded_String;
                  begin
                     for One in Pm.Capability loop
                        if Allowed (One).Granted then
                           Append (Named, (if Named = Null_Unbounded_String then "" else ", ") & Pm.Word (One));
                        elsif Unroled (One).Granted then
                           Append (By_Role, (if By_Role = Null_Unbounded_String then "" else ", ") & Pm.Word (One));
                        end if;
                     end loop;
                     Grouped ("  " & "by name", (if Named = Null_Unbounded_String then "none" else To_String (Named))
                                                & (if By_Role = Null_Unbounded_String then ""
                                                   else " (role.worker withholds " & To_String (By_Role) & ")"));
                  end;
                  return;
               end if;
               --  The checks it is verified by, said once: the profile, then
               --  what it runs -- not profile, label and command stacked.
               if Name = "verification_profile" then
                  declare
                     Held  : constant String := R.Get (View, Name);
                     Colon : constant Natural := Ada.Strings.Fixed.Index (Held, ": ");
                     Checks : constant Model_Runner.Framework.Verification.Check_List :=
                       Model_Runner.Framework.Verification.Parse_Profile
                         (if Colon = 0 then "" else Held (Colon + 2 .. Held'Last));
                     Runs   : Unbounded_String;
                  begin
                     for Index in 1 .. Model_Runner.Framework.Verification.Length (Checks) loop
                        --  Where it runs, where that is not the project's top.
                        declare
                           One : constant Model_Runner.Framework.Verification.Check :=
                             Model_Runner.Framework.Verification.Element (Checks, Index);
                           Dir : constant String := To_String (One.Directory);
                        begin
                           Append (Runs, (if Runs = Null_Unbounded_String then "" else ", ")
                                         & To_String (One.Command)
                                         & (if Dir in "" | "." | "./" then "" else " (in " & Dir & ")"));
                        end;
                     end loop;
                     Grouped ("  " & "checked by",
                    (if Colon = 0 then Held
                                     else "profile " & Held (Held'First .. Colon - 1)
                                          & (if Runs = Null_Unbounded_String then ""
                                             --  A check that is only true checks nothing yet.
                                             elsif To_String (Runs) = "true"
                                             then ", which checks nothing yet (it runs true); /reconfigure "
                                                  & "profile." & Held (Held'First .. Colon - 1)
                                                  & "=""check: COMMAND"" sets what it runs"
                                             else ", which runs " & To_String (Runs))));
                     return;
                  end;
               end if;
               --  Ready as its state goes, and yet its agent left unable:
               --  said as not ready, with why.
               if Name = "ready" and then R.Get (View, Name) = "true"
                 and then Model_Runner.Framework.Work.Unable_Reason (Store, Argument) /= ""
               then
                  Grouped ("  " & "ready",
                    "no -- " & Model_Runner.Framework.Work.Unable_Reason (Store, Argument));
                  return;
               end if;
               --  Ready, where its state says so already: not said twice.
               if Name = "ready" and then R.Get (View, Name) = "true" then
                  return;
               end if;
               --  In words, not by the record's own names.
               declare
                  State : constant String := R.Get (View, "runtime.state");
                  Label : constant String :=
                    (if Shown_Name = "blocked_by"
                     then (if State = "candidate" then "to start"
                           --  Run, its work waiting: where it is, not why it cannot start.
                           elsif State = "verification" then "where its work is"
                           elsif State = "failed" then "why it stopped"
                           --  Stopped by the person: no reason it cannot start.
                           elsif State = "blocked"
                             and then Ada.Strings.Fixed.Index (R.Get (View, "runtime.blocked_by"), "you stopped") > 0
                           then "why it stopped"
                           --  Blocked by how a run of it ended: why it stopped.
                           elsif State = "blocked" and then not Never_Worked (Argument)
                             and then Ada.Strings.Fixed.Index (R.Get (View, "runtime.blocked_by"), "children") = 0
                           then "why it stopped"
                           else "why it cannot start")
                     elsif Shown_Name = "depends_on" then "waits for"
                     elsif Shown_Name = "accepted_by" then "accepted by"
                     elsif Shown_Name = "moved_by" then "moved by"
                     --  Taken back since: said in the past.
                     elsif Shown_Name = "rejected_by" and then State /= "rejected" then "was rejected by"
                     elsif Shown_Name = "rejected_by" then "rejected by"
                     elsif Shown_Name = "acceptance" then "judged by"
                     elsif Shown_Name = "gates" then "done when"
                     else Shown_Name);
                  --  The requirements it serves that state no criteria,
                  --  "" where one does: those judge it by their words.
                  function Without_Criteria return String is
                     Said : Unbounded_String;
                  begin
                     for Req of Model_Runner.Framework.Lines_Of (R.Get (View, "definition.requirements")) loop
                        declare
                           Held : Model_Runner.Framework.Intent.Entity;
                           Read : E.Error_Info;
                        begin
                           Model_Runner.Framework.Intent.Read
                             (Store, Model_Runner.Framework.Intent.Requirement, Req, Held, Read);
                           if E.Is_Ok (Read) and then Length (Held.Criteria) > 0 then
                              return "";
                           end if;
                           --  A retired one is revised no more: not offered.
                           if not (E.Is_Ok (Read)
                                   and then To_String (Held.State) in "obsolete" | "superseded" | "rejected")
                           then
                              Append (Said, (if Said = Null_Unbounded_String then "" else ", ") & Req);
                           end if;
                        end;
                     end loop;
                     return To_String (Said);
                  end Without_Criteria;
                  Unstated : constant String :=
                    (if Shown_Name = "acceptance" and then Shown_Value = "from_requirements"
                     then Without_Criteria else "");
                  Value : constant String :=
                    (if Unstated /= ""
                     then Unstated & (if Ada.Strings.Fixed.Index (Unstated, ",") > 0
                                      then " state no criteria: only their titles and texts judge it"
                                      else " states no criteria: only its title and text judge it")
                          & " -- /req revise "
                          & Model_Runner.Framework.Lines_Of (R.Get (View, "definition.requirements")).First_Element
                          & " criteria=... gives some"
                     elsif Shown_Name = "acceptance" and then Shown_Value = "from_requirements"
                     then "the criteria of the requirements it serves"
                     elsif Shown_Name = "gates" then Gates_Said (Shown_Value)
                     elsif Shown_Name = "rejected_by" and then State /= "rejected"
                     then Shown_Value & ", and reconsidered since"
                     elsif Shown_Name = "accepted_by"
                       and then Ada.Strings.Fixed.Index (Shown_Value, "its children are done") > 0
                     then "its parts are done"
                     --  Its state is said above: not again before why.
                     elsif Shown_Name = "blocked_by" and then Shown_Value'Length > 15
                       and then Ada.Strings.Fixed.Head (Shown_Value, 15) in "it is blocked: " | "it is stopped: "
                     then Parts_Worded (Shown_Value (Shown_Value'First + 15 .. Shown_Value'Last))
                     elsif Shown_Name = "blocked_by" then Parts_Worded (Shown_Value)
                     else Shown_Value)
                    --  Waiting for parts, one of them failed: which, and how on.
                    & (if Shown_Name = "blocked_by" and then Failed_Parts /= ""
                       then " -- " & Failed_Parts & " failed: /task accept " & Failed_Parts & " tries "
                            & (if Ada.Strings.Fixed.Index (Failed_Parts, " ") > 0 then "them" else "it") & " again"
                       else "");
               begin
                  Grouped ("  " & Label, Value);
               end;
            end Line;

            --  Whether its agent may write at all: one that may not is
            --  told no rule for writing, and none is listed here either.
            function Writes return Boolean is
               Allowed : constant Model_Runner.Framework.Permissions.Permission_Set :=
                 Model_Runner.Framework.Permissions.Effective
                   (Store, R.Get (View, "definition.kind"), "",
                    Task_Level => R.Get (View, "definition.permissions"));
            begin
               return Model_Runner.Framework.Permissions.Allows
                        (Allowed, Model_Runner.Framework.Permissions.Write_Source)
                 or else Model_Runner.Framework.Permissions.Allows
                           (Allowed, Model_Runner.Framework.Permissions.Write_Specs);
            end Writes;

            --  A baseline rule, as the record keeps it: LEVEL SOURCE: TEXT.
            function Baseline (Name : String) return Boolean
            is (Ada.Strings.Fixed.Index (R.Get (View, Name), "project_baseline ") = R.Get (View, Name)'First
                or else Ada.Strings.Fixed.Index (R.Get (View, Name), "language_baseline ") = R.Get (View, Name)'First);

            function Governing (Name : String) return Boolean
            is (((Name'Length > 10 and then Name (Name'First .. Name'First + 9) = "authority.")
                 and then not (Baseline (Name) and then not Writes))
                or else Ada.Strings.Fixed.Index (Name, "decision.") = Name'First
                or else Ada.Strings.Fixed.Index (Name, "override.") = Name'First
                or else Ada.Strings.Fixed.Index (Name, "conflict.") = Name'First);

            --  Each field said once, in the group it belongs to.
            Said : Model_Runner.Framework.Name_Lists.Vector;

            procedure Once (Name : String) is
            begin
               if not Said.Contains (Name) and then R.Has (View, Name) then
                  Said.Append (Name);
                  Line (Name);
               end if;
            end Once;

            --  A group's title, a blank line before it.
            procedure Section (Key : String) is
            begin
               Pres.Put_Line (Screen, "");
               Pres.Put_Header (Screen, Key);
            end Section;

            Ended : constant Boolean :=
              R.Get (View, "runtime.state") in "complete" | "cancelled" | "rejected";
         begin
            --  It, by its identifier and title.
            Pres.Put_Header (Screen, "cli.task.heading",
                              [Loc.Named ("name", Argument),
                               Loc.Named ("value", R.Get (View, "definition.title"))]);
            Said.Append ("definition.title");
            --  Its own permissions are what the agent group says it may do.
            Said.Append ("definition.permissions");

            --  What it is: its kind, where, what it serves, and what it is
            --  judged by as a task.
            Section ("cli.task.section.what");
            Once ("definition.kind");
            Once ("definition.component");
            Once ("definition.requirements");
            Once ("definition.acceptance");
            if R.Get (View, "definition.requirements") = ""
              and then R.Get (View, "definition.acceptance") in "" | "from_requirements"
            then
               Grouped ("  " & "judged by",
                    "its title and notes -- it serves no requirement; /task link "
                                       & Argument & " REQ-ID ties it to one");
            end if;
            Once ("definition.notes");
            for Index in 1 .. R.Field_Count (View) loop
               if Ada.Strings.Fixed.Index (R.Field_Name (View, Index), "definition.") = 1
                 and then R.Field_Name (View, Index) not in "definition.depends_on" | "definition.permissions"
                                                         | "definition.parent"
               then
                  Once (R.Field_Name (View, Index));
               end if;
            end loop;

            --  Where it stands: its state and what holds it, what it waits
            --  for, its parts and its waiting work.
            Section ("cli.task.section.stands");
            Once ("runtime.state");
            --  Its work put back out of the project since: said where it
            --  stands, not left to /task diff.
            if State_Field (Argument, "undone_by") /= "" then
               Grouped ("  its work", "undone in the project: " & State_Field (Argument, "undone_by")
                                      & " was put back over it"
                                      --  The way on only where reopening is one.
                                      & (if Tk.State_Of (Store, Argument) = "complete"
                                         then " -- /task reopen " & Argument & " does it again"
                                         elsif Tk.State_Of (Store, Argument) = "accepted"
                                         then " -- /work " & Argument & " does it again"
                                         else ""));
            end if;
            if Ended then
               Said.Append ("blocked_by");
            end if;
            if R.Get (View, "blocked_by") = "" then
               Said.Append ("blocked_by");
            end if;
            Once ("blocked_by");
            Once ("ready");
            Once ("definition.parent");
            Once ("definition.depends_on");
            declare
               Parts : Unbounded_String;
            begin
               for Child of Tk.Children (Store, Argument) loop
                  Append (Parts, (if Parts = Null_Unbounded_String then "" else ", ")
                                 & Child & " " & Listed_State (Child));
               end loop;
               if Parts /= Null_Unbounded_String then
                  Grouped ("  " & "parts",
                    To_String (Parts));
               end if;
            end;
            if Model_Runner.Framework.Workspaces.Active_For (Store, Argument) /= "" then
               declare
                  Place : Model_Runner.Framework.Workspaces.Workspace;
                  Read  : E.Error_Info;
               begin
                  Model_Runner.Framework.Workspaces.Read
                    (Store, Model_Runner.Framework.Workspaces.Active_For (Store, Argument), Place, Read);
                  Grouped ("  " & "workspace",
                    Model_Runner.Framework.Workspaces.Active_For (Store, Argument)
                                          & " " & To_String (Place.Path));
               end;
            end if;
            --  The rest of where it stands: who moved it, what failed.
            for Index in 1 .. R.Field_Count (View) loop
               declare
                  Name : constant String := R.Field_Name (View, Index);
               begin
                  if Ada.Strings.Fixed.Index (Name, "runtime.") = 1
                    or else Name in "accepted_by" | "moved_by" | "rejected_by" | "blocking_reasons"
                                  | "current_failure"
                  then
                     Once (Name);
                  end if;
               end;
            end loop;

            --  How it is judged: the gates it passes, and the checks.
            Section ("cli.task.section.judged");
            Once ("gates");
            Once ("verification_profile");

            --  What its agent may do, from where, where it writes, and how
            --  long and how much.
            Section ("cli.task.section.agent");
            Once ("permissions");
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Kind    : constant String := R.Get (View, "definition.kind");
               Own     : constant String := R.Get (View, "definition.permissions");
               Config  : R.Item;
               Named   : Boolean := False;
            begin
               Config := Model_Runner.Framework.Configurations.Required (Store);
               for Index in 1 .. R.Field_Count (Config) loop
                  Named := Named
                    or else Ada.Strings.Fixed.Index (R.Field_Name (Config, Index),
                                                     "map.permission.kind." & Kind & ".") = 1
                    or else R.Field_Name (Config, Index) = "map.permission.kind." & Kind;
               end loop;
               declare
                  Role_Present : Boolean;
                  Role_Level   : constant Pm.Permission_Set := Pm.Level_Of (Store, "role.worker", Role_Present);
                  pragma Unreferenced (Role_Level);
                  Role_Said    : constant Boolean := Role_Present;
               begin
                  Grouped ("  " & "permissions from",
                       (if Own /= "" then "its own permissions field, within "
                                  else "")
                                 & (if Named then "kind." & Kind & " (/config permission.kind." & Kind & ")"
                                    else "the project's (/config permission.project)")
                                 --  The role its agent works in, where it says anything.
                                 & (if Role_Said then ", and role.worker (/config permission.role.worker)" else ""));
               end;
               if Pm.Sandbox_Problem /= "" then
                  Pres.Put_Note (Screen, "cli.task.sandbox_bad", [Loc.Named ("detail", Pm.Sandbox_Problem)]);
               elsif Pm.Sandbox_Source /= "" then
                  declare
                     Free     : constant Pm.Permission_Set :=
                       Pm.Effective (Store, Kind, "", Task_Level => Own, Within_Sandbox => False);
                     Confined : constant Pm.Permission_Set :=
                       Pm.Effective (Store, Kind, "", Task_Level => Own);
                     Withheld : Unbounded_String;
                  begin
                     for One in Pm.Capability loop
                        if Free (One).Granted and then not Confined (One).Granted then
                           Append (Withheld, (if Withheld = Null_Unbounded_String then "" else ", ")
                                             & Pm.Word (One));
                        end if;
                     end loop;
                     Grouped ("  " & "sandbox",
                    Pm.Sandbox_Source & ": "
                                    & Joined (Model_Runner.Framework.Lines_Of (Pm.Image (Pm.Sandbox)))
                                    & (if Withheld = Null_Unbounded_String then ""
                                       else " -- withholds " & To_String (Withheld)));
                  end;
               end if;
            end;
            --  Where it works, in words: the project itself, or apart.
            if R.Has (View, "workspace_policy") then
               Said.Append ("workspace_policy");
               --  Ended: where it worked, without a step that is past.
               Grouped ("  " & (if Tk.State_Of (Store, Argument) in "complete" | "cancelled" | "rejected"
                                then "worked in" else "works in"),
                        (if R.Get (View, "workspace_policy") = "workspace"
                           and then Tk.State_Of (Store, Argument) in "complete" | "cancelled" | "rejected"
                         then "a workspace of its own"
                         elsif R.Get (View, "workspace_policy") = "workspace"
                         then "a workspace of its own, taken in by /task integrate " & Argument
                         elsif R.Get (View, "workspace_policy") = "project" then "the project itself"
                         else R.Get (View, "workspace_policy")));
            end if;
            --  How long, how many steps, how many tokens -- the time with the
            --  setting it comes from, as that is what stops a run.
            declare
               Config  : R.Item;
               Kind    : constant String := R.Get (View, "definition.kind");
               Seconds : constant Natural := Model_Runner.Framework.Work.Time_Allowed (Store, Argument);
            begin
               Config := Model_Runner.Framework.Configurations.Required (Store);
               Grouped ("  " & "limits",
                        T.Image (Long_Long_Integer (Seconds))
                        & (if Seconds = 1 then " second (" else " seconds (")
                        & (if Tk.Kind_Policy (Store, Kind, "max_seconds") /= "" then "task.max_seconds." & Kind
                           elsif R.Get (Config, "scalar.agents.max_seconds") /= "" then "agents.max_seconds"
                           else "work.lease")
                        & ")"
                        & (if R.Get (View, "resource.max_steps") = "" then ""
                           else ", " & R.Get (View, "resource.max_steps") & " steps")
                        & (if R.Get (View, "resource.token_budget") = "" then ""
                           else ", " & R.Get (View, "resource.token_budget") & " tokens"));
               --  A ruling on the agents' limit its kind's own goes past: the
               --  ruling kept in sight, with which holds.
               for Limit of Model_Runner.Framework.Name_Lists.Vector'
                              (["max_seconds", "max_steps", "max_tool_calls", "token_budget"])
               loop
                  for Dec of Model_Runner.Framework.Intent.List (Store, Model_Runner.Framework.Intent.Decision) loop
                     declare
                        Rule : constant String :=
                          Model_Runner.Framework.Intent.Governs (Store, Model_Runner.Framework.Intent.Decision, Dec);
                        Lead : constant String := "scalar.agents." & Limit & " = ";
                        Own  : constant String := R.Get (Config, "scalar.task." & Limit & "." & Kind);
                     begin
                        if Own /= "" and then Ada.Strings.Fixed.Index (Rule, Lead) = Rule'First
                          and then Model_Runner.Framework.Intent.State_Of
                                     (Store, Model_Runner.Framework.Intent.Decision, Dec) = "accepted"
                        then
                           Grouped ("  " & "past a ruling",
                                    "task." & Limit & "." & Kind & " = " & Own & " holds for it, though " & Dec
                                    & " rules agents." & Limit & " = " & Rule (Rule'First + Lead'Length .. Rule'Last)
                                    & " -- /reconfigure task." & Limit & "." & Kind & "= keeps to the ruling");
                        end if;
                     end;
                  end loop;
               end loop;
            end;

            --  What governs it: the rules above the configuration, and every
            --  override and conflict among them.
            declare
               Rules : Boolean := False;
            begin
               for Index in 1 .. R.Field_Count (View) loop
                  Rules := Rules or else Governing (R.Field_Name (View, Index));
               end loop;
               --  And the specifications in force where it works, which its
               --  agent is given as /task context shows.
               declare
                  Component : constant String := R.Get (View, "definition.component");
                  Specs     : Model_Runner.Framework.Name_Lists.Vector;
               begin
                  for Id of Model_Runner.Framework.Intent.List (Store, Model_Runner.Framework.Intent.Specification)
                  loop
                     declare
                        Held : Model_Runner.Framework.Intent.Entity;
                        Got  : E.Error_Info;
                     begin
                        Model_Runner.Framework.Intent.Read
                          (Store, Model_Runner.Framework.Intent.Specification, Id, Held, Got);
                        if E.Is_Ok (Got) and then To_String (Held.State) = "accepted"
                          and then To_String (Held.Scope) in "" | "project" | Component
                        then
                           Specs.Append (Id);
                        end if;
                     end;
                  end loop;
                  if Rules or else not Specs.Is_Empty then
                     Section ("cli.task.section.governs");
                     for Index in 1 .. R.Field_Count (View) loop
                        if Governing (R.Field_Name (View, Index)) then
                           Once (R.Field_Name (View, Index));
                        end if;
                     end loop;
                     for Id of Specs loop
                        declare
                           Held : Model_Runner.Framework.Intent.Entity;
                           Got  : E.Error_Info;
                           Text : Unbounded_String;
                        begin
                           Model_Runner.Framework.Intent.Read
                             (Store, Model_Runner.Framework.Intent.Specification, Id, Held, Got);
                           Text := Held.Text;
                           --  Its first line: a whole document is /spec show's.
                           if Index (Text, [1 => ASCII.LF]) > 0 then
                              Text := Head (Text, Index (Text, [1 => ASCII.LF]) - 1) & " ...";
                           end if;
                           Grouped ("  spec " & Id, To_String (Held.Title) & ": " & To_String (Text));
                        end;
                     end loop;
                  end if;
               end;
            end;

            --  An analysis is done for what it found: its last answer's
            --  summary and findings, under their own title.
            if R.Get (View, "definition.kind") = "analysis" and then R.Get (View, "runtime.last_result") /= "" then
               declare
                  Held     : Model_Runner.Framework.Results.Result;
                  Got      : E.Error_Info;
                  Summary  : Unbounded_String;
                  Findings : Unbounded_String;
                  In_Found : Boolean := False;
               begin
                  Model_Runner.Framework.Results.Read (Store, R.Get (View, "runtime.last_result"), Held, Got);
                  if E.Is_Ok (Got) then
                     for Line of Model_Runner.Framework.Lines_Of (To_String (Held.Payload)) loop
                        declare
                           Bare  : constant String := Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both);
                           Lower : constant String := Ada.Characters.Handling.To_Lower (Bare);
                        begin
                           if Ada.Strings.Fixed.Index (Lower, "summary:") = 1 then
                              Summary := To_Unbounded_String
                                (Ada.Strings.Fixed.Trim (Bare (Bare'First + 8 .. Bare'Last), Ada.Strings.Both));
                              In_Found := False;
                           elsif Ada.Strings.Fixed.Index (Lower, "findings:") = 1 then
                              Findings := To_Unbounded_String
                                (Ada.Strings.Fixed.Trim (Bare (Bare'First + 9 .. Bare'Last), Ada.Strings.Both));
                              In_Found := True;
                           elsif In_Found and then Ada.Strings.Fixed.Index (Lower, ":") in 2 .. 20
                             and then (for all C of Lower (Lower'First .. Ada.Strings.Fixed.Index (Lower, ":") - 1)
                                       => C in 'a' .. 'z' | '_')
                           then
                              In_Found := False;
                           elsif In_Found and then Bare /= "" then
                              Append (Findings, (if Findings = Null_Unbounded_String then "" else "; ") & Bare);
                           end if;
                        end;
                     end loop;
                     --  The instructions' own example line is no finding.
                     if Index (Translate (Summary, Ada.Strings.Maps.Constants.Lower_Case_Map),
                               "one line on what you") > 0
                     then
                        Summary := To_Unbounded_String ("(the instructions' example line, not its own words)");
                     end if;
                     if Index (Translate (Findings, Ada.Strings.Maps.Constants.Lower_Case_Map),
                               "one line on what you") > 0
                     then
                        Findings := Null_Unbounded_String;
                     end if;
                     if Summary /= Null_Unbounded_String or else Findings /= Null_Unbounded_String then
                        Section ("cli.task.section.found");
                        if Summary /= Null_Unbounded_String then
                           Grouped ("  summary", To_String (Summary));
                        end if;
                        if Findings /= Null_Unbounded_String then
                           Grouped ("  findings", To_String (Findings));
                        end if;
                     end if;
                  end if;
               end;
            end if;

            --  Anything else it holds, so nothing is hidden by the grouping
            --  -- but a rule that governs nothing it may do, which is left
            --  out above for that, is not said below the wrong heading.
            for Index in 1 .. R.Field_Count (View) loop
               if Ada.Strings.Fixed.Index (R.Field_Name (View, Index), "authority.") /= 1 then
                  Once (R.Field_Name (View, Index));
               end if;
            end loop;

            --  Stopped: the way on, as /work says it.
            if R.Get (View, "runtime.state") in "failed" | "blocked"
              and then Ada.Strings.Fixed.Index (R.Get (View, "blocked_by"), "waiting for its children") = 0
            then
               Pres.Put_Note (Screen, "cli.next.retry", [Loc.Named ("name", Argument)]);
            --  Done by an agent: what it answered is a command away.
            elsif R.Get (View, "runtime.state") = "complete" and then R.Get (View, "definition.kind") = "analysis" then
               Pres.Put_Note (Screen, "cli.next.result_answer", [Loc.Named ("name", Argument)]);
            end if;
         end;
      end Show;

      --  The context a model would be given for the task, kept so that
      --  what it was can be looked up by its identifier afterwards.
      procedure Show_Context is
         Built : Model_Runner.Framework.Context.Built;
         Id    : constant String := First_Word;

         --  profile=NAME: the profile it is planned with, as /work takes
         --  it; nothing else is taken.
         function Profile_Given return String is
            Words : constant String := After_First;
            Start : Natural := Words'First;
         begin
            for Index in Words'First .. Words'Last + 1 loop
               if Index > Words'Last or else Words (Index) = ' ' then
                  if Index > Start and then Ada.Strings.Fixed.Head (Words (Start .. Index - 1), 8) = "profile=" then
                     return Words (Start + 8 .. Index - 1);
                  end if;
                  Start := Index + 1;
               end if;
            end loop;
            return "";
         end Profile_Given;

         --  A word it does not take: the first, or none.
         function Not_Taken return String is
            Words : constant String := After_First;
            Start : Natural := Words'First;
         begin
            for Index in Words'First .. Words'Last + 1 loop
               if Index > Words'Last or else Words (Index) = ' ' then
                  if Index > Start and then Ada.Strings.Fixed.Head (Words (Start .. Index - 1), 8) /= "profile=" then
                     return Words (Start .. Index - 1);
                  end if;
                  Start := Index + 1;
               end if;
            end loop;
            return "";
         end Not_Taken;
      begin
         if not Needs_Task then
            return;
         end if;
         if Not_Taken /= "" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "what /task context takes");
            E.Add_Text (Outcome, "value", Not_Taken);
            E.Add_Text (Outcome, "detail", "a task, and profile=NAME to plan it with another model profile, as"
                        & " /task context " & Id & " profile=small; --verbose shows it whole");
            Fail (Outcome);
            return;
         end if;
         --  A profile it names is one the configuration has, as /work's.
         declare
            Config : R.Item;
         begin
            Config := Model_Runner.Framework.Configurations.Required (Store);
            if Profile_Given not in "" | "default" and then not R.Has (Config, "map.model." & Profile_Given) then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "profile");
               E.Add_Text (Outcome, "value", Profile_Given);
               E.Add_Text (Outcome, "detail", "there is no map.model." & Profile_Given
                           & "; /config map.model lists those there are");
               Fail (Outcome);
               return;
            end if;
         end;
         --  Built as /work builds it: for the model it would run on, with
         --  the instructions after it counted in.
         Model_Runner.Framework.Context.Build
           (Store, Id,
            (if Profile_Given /= "" then Model_Runner.Framework.Context.Profile (Store, Profile_Given)
             elsif Item.Has_Session_Profile
             then Model_Runner.Framework.Context.Within_Configured (Store, Item.Session_Profile)
             else Model_Runner.Framework.Context.Profile (Store, "")),
            Built, Outcome, Instructions => Model_Runner.Framework.Work.Instructions_Of (Store, Id));
         if E.Is_Ok (Outcome) then
            Model_Runner.Framework.Context.Keep (Store, Change, Built, Outcome);
         end if;
         if E.Is_Ok (Outcome) then
            S.Commit (Store, Change, Outcome);
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;

         Pres.Put_Message
           (Screen, "cli.task.context",
            [Loc.Named ("name", Model_Runner.Framework.Context.Manifest_Id (Built)),
             Loc.Named ("count", T.Image (Long_Long_Integer
                          (Model_Runner.Framework.Context.Included_Count (Built)))),
             Loc.Named ("total", T.Image (Long_Long_Integer
                          (Model_Runner.Framework.Context.Cost (Built)))),
             Loc.Named ("extra", T.Image (Long_Long_Integer
                          (Model_Runner.Framework.Context.Excluded_Count (Built)))),
             Loc.Named ("detail", T.Image (Long_Long_Integer
                          (Model_Runner.Framework.Context.Budget (Built)))),
             Loc.Named ("value",
                        (if Model_Runner.Framework.Context.Semantic (Built)
                         then "semantic" else "textual"))]);
         for Index in 1 .. Model_Runner.Framework.Context.Included_Count (Built) loop
            Pres.Put_Message
              (Screen, "cli.task.context_item",
               [Loc.Named
                  ("name",
                   To_String (Model_Runner.Framework.Context.Included_At
                                (Built, Index).Id))]);
         end loop;
         --  The whole of it, as the agent reads it, with --verbose.
         if Model_Runner.CLI.Options."=" (Item.Level, Model_Runner.CLI.Options.Verbose) then
            Pres.Put_Line (Screen, Model_Runner.Framework.Context.Rendered (Built));
         else
            Pres.Put_Note (Screen, "cli.next.context_whole", [Loc.Named ("name", Id)]);
         end if;
      end Show_Context;

      --  Run the task's verification profile, keep the evidence and say
      --  what it found.
      procedure Verify is
         Profile  : constant String :=
           Model_Runner.Framework.Verification.Profile_Of (Store, Argument);
         Evidence : Unbounded_String;
         Passed   : Boolean;
      begin
         if not Needs_Task then
            return;
         end if;
         --  Checked again is work done: complete, or waiting to be taken in.
         if Action = "verify" and then Tk.State_Of (Store, Argument) not in "complete" | "verification" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the task to verify");
            E.Add_Text (Outcome, "value", Argument);
            E.Add_Text (Outcome, "detail", "it is " & Listed_State (Argument) & ": /task verify checks again work"
                        & " that is done -- /task complete " & Argument & " checks it and takes it as done");
            Fail (Outcome);
            return;
         end if;
         if Profile = "" then
            Outcome := E.Make (E.Framework_Not_Found);
            E.Add_Text (Outcome, "name", "the verification profile of " & Argument);
            Fail (Outcome);
            return;
         end if;
         --  Its work waiting in a workspace: checked there, where it is, not
         --  in the project it has not reached.
         declare
            Space : constant String := Model_Runner.Framework.Workspaces.Active_For (Store, Argument);
            Held  : Model_Runner.Framework.Workspaces.Workspace;
            Read  : E.Error_Info;
         begin
            if Space /= "" then
               Model_Runner.Framework.Workspaces.Read (Store, Space, Held, Read);
            end if;
            Model_Runner.Framework.Verification.Run_Profile
              (Store, Change, Profile, Argument, Evidence, Passed, Outcome,
               Workspace => (if Space /= "" and then E.Is_Ok (Read) then To_String (Held.Path) else ""));
            if Space /= "" and then E.Is_Ok (Outcome) then
               Pres.Put_Note (Screen, "cli.task.checked_in", [Loc.Named ("name", Space)]);
            end if;
         end;
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;

         --  New evidence: the requirements it bears on are judged again.
         declare
            Changed : Model_Runner.Framework.Name_Lists.Vector;
         begin
            Model_Runner.Framework.Verification.Reevaluate_Requirements
              (Store, Change, Changed, Outcome);
            if E.Is_Ok (Outcome) then
               Commit;
            end if;
            for Requirement of Changed loop
               declare
                  Held : Model_Runner.Framework.Intent.Entity;
                  Read : E.Error_Info;
               begin
                  Model_Runner.Framework.Intent.Read
                    (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Read);
                  Pres.Put_Message
                    (Screen, "cli.task.requirement",
                     [Loc.Named ("name", Requirement), Loc.Named ("value", To_String (Held.State))]);
               end;
            end loop;
            Outcome := E.Success;
         end;

         declare
            Said : constant Model_Runner.Framework.Verification.Diagnostic_List :=
              Model_Runner.Framework.Verification.Diagnostics_Of
                (Store, To_String (Evidence));
         begin
            for Index in 1 .. Model_Runner.Framework.Verification.Length (Said) loop
               declare
                  One : constant Model_Runner.Framework.Verification.Diagnostic :=
                    Model_Runner.Framework.Verification.Element (Said, Index);
               begin
                  Pres.Put_Message
                    (Screen, "cli.task.diagnostic",
                     --  Where, as far as it is known: no file, or no line,
                     --  is not said as :0.
                     [Loc.Named ("path", (if Length (One.File) = 0 then "(the check)"
                                          elsif One.Line = 0 then To_String (One.File)
                                          else To_String (One.File) & ":"
                                               & T.Image (Long_Long_Integer (One.Line)))),
                      Loc.Named ("severity", To_String (One.Severity)),
                      Loc.Named ("detail", To_String (One.Message)
                                 & (if Length (One.Code) = 0 then ""
                                    else " [" & To_String (One.Code) & "]"))]);
               end;
            end loop;
            --  Its outcome in its colour.
            Pres.Put_Marked
              (Screen, "cli.task.verified",
               --  Named with its task: verify all says several.
               [Loc.Named ("name", Argument & " " & To_String (Evidence)),
                Loc.Named ("value", (if Passed then "passed" else "failed")),
                Loc.Named ("count", T.Image (Long_Long_Integer
                             (Model_Runner.Framework.Verification.Length
                                (Model_Runner.Framework.Verification.Parse_Profile
                                   (Profile_Text (Profile)))))),
                Loc.Named ("total", T.Image (Long_Long_Integer
                             (Model_Runner.Framework.Verification.Length (Said))))],
               (if Passed then "passed" else "failed"), (if Passed then Pres.Good else Pres.Bad));
            --  Passed with no test to run: said, not read as tests passing.
            if Passed and then Model_Runner.Framework.Verification.Found_No_Tests (Store, To_String (Evidence)) then
               Pres.Put_Note (Screen, "cli.check.no_tests_yet",
                              [Loc.Named ("name", Profile),
                               --  A test task open already: that, not another.
                               Loc.Named ("detail",
                                          (if Model_Runner.Framework.Tasks.First_Open_Of_Kind (Store, "test") /= ""
                                           then "/work " & Model_Runner.Framework.Tasks.First_Open_Of_Kind
                                                             (Store, "test") & " writes one"
                                           else "a test task, /task new TITLE kind=test, writes the first"))]);
            end if;
            --  Its work put back out since: what passed is the project, not it.
            if State_Field (Argument, "undone_by") /= "" then
               Pres.Put_Note (Screen, "cli.task.work_undone",
                              [Loc.Named ("name", Argument), Loc.Named ("value", State_Field (Argument, "undone_by"))]);
            end if;
         end;
         if not Passed then
            declare
               Failed : E.Error_Info := E.Make (E.Framework_Verification_Failed);
               Why    : Unbounded_String;
            begin
               for Line of Model_Runner.Framework.Verification.Why_Failed
                             (Store, To_String (Evidence))
               loop
                  Append (Why, (if Why = Null_Unbounded_String then "" else ASCII.LF & "") & Line);
               end loop;
               E.Add_Text (Failed, "name", To_String (Evidence));
               E.Add_Text (Failed, "detail", To_String (Why));
               Fail (Failed);
               --  The way on: what it found is put right, or the check is
               --  not the one the project means.
               Pres.Put_Note (Screen, "cli.next.check_failed",
                              [Loc.Named ("name", Profile), Loc.Named ("value", Profile_Text (Profile))]);
               --  Completing, it stays where it is: said, with how to finish.
               if Action = "complete" then
                  Pres.Put_Note (Screen, "cli.task.stays",
                                 [Loc.Named ("name", Argument), Loc.Named ("value", Tk.State_Of (Store, Argument))]);
               end if;
            end;
         elsif Action = "verify"
           and then Tk.State_Of (Store, Argument) in "failed" | "blocked" | "accepted"
         then
            --  Passing now, and not done yet: what finishes it -- or, where
            --  it still waits for another, what that is.
            declare
               Now : constant Tk.Readiness := Tk.Ready (Store, Argument);
            begin
               if not Now.Ready and then not Now.Reasons.Is_Empty
                 and then Ada.Strings.Fixed.Index (Now.Reasons.First_Element, "wait") > 0
               then
                  Pres.Put_Note (Screen, "cli.task.accepted_waits",
                                 [Loc.Named ("name", Argument), Loc.Named ("detail", Now.Reasons.First_Element)]);
               else
                  Pres.Put_Note (Screen, "cli.next.complete", [Loc.Named ("name", Argument)]);
               end if;
            end;
         end if;
      end Verify;

      --  The last of a task's parent's parts done: the parent goes on.
      procedure Say_Parent_Ready (Id : String) is
         Defined : R.Item;
         Read    : E.Error_Info;
      begin
         Tk.Definition (Store, Id, Defined, Read);
         if E.Is_Ok (Read) and then R.Get (Defined, "parent") /= ""
           and then Tk.State_Of (Store, R.Get (Defined, "parent")) = "accepted"
           and then Tk.Ready (Store, R.Get (Defined, "parent")).Ready
         then
            Pres.Put_Note
              (Screen, "cli.work.parent_ready",
               [Loc.Named ("name", R.Get (Defined, "parent")),
                --  A part let go is no part done: named.
                Loc.Named ("detail", Cancelled_Parts (Store, R.Get (Defined, "parent")))]);
            Said_Ready.Append (R.Get (Defined, "parent"));
         end if;
      end Say_Parent_Ready;

      --  Complete a task through its gates, then work out which
      --  requirements that verified.
      procedure Complete_Judged;

      procedure Complete is
         package Vf renames Model_Runner.Framework.Verification;

         --  Whether its verification gate passes on the evidence there is.
         function Verified return Boolean is
            Now : constant Vf.Gate_List := Vf.Gates (Store, Argument);
         begin
            for Index in 1 .. Vf.Length (Now) loop
               if To_String (Vf.Element (Now, Index).Name) = "verification"
                 and then not Vf.Element (Now, Index).Passed
               then
                  return False;
               end if;
            end loop;
            return True;
         end Verified;

         --  An analysis is done for what it found: at a terminal, that is
         --  asked for and kept as its notes before it is completed -- or
         --  accepted on the way, so giving up leaves it as it was.
         procedure Ask_Findings (Given_Up : out Boolean) is
            Defined : R.Item;
            Read    : E.Error_Info;
            Fields  : Tk.Field_Map;
         begin
            Given_Up := False;
            Tk.Definition (Store, Argument, Defined, Read);
            if Interactive and then E.Is_Ok (Read) and then R.Get (Defined, "kind") = "analysis"
              and then Ada.Strings.Fixed.Index (R.Get (Defined, "notes"), "found: ") = 0
            then
               Pres.Put_Message (Screen, "cli.task.analysis_findings", [Loc.Named ("name", Argument)]);
               declare
                  --  Read as any answer is: Escape or Ctrl-C give the
                  --  completing up, and a command typed is no finding.
                  use type Choosers.Line_End;
                  Ending : Choosers.Line_End;
                  Raw    : constant String := Choosers.Typed_Line (Ending);
                  Found  : constant String :=
                    Ada.Strings.Fixed.Trim ((if Ending = Choosers.Unavailable then Ada.Text_IO.Get_Line else Raw),
                                            Ada.Strings.Both);
               begin
                  if Ending in Choosers.Escaped | Choosers.Interrupted | Choosers.Ended then
                     Pres.Put_Message (Screen, "cli.task.complete_given_up", [Loc.Named ("name", Argument)]);
                     Given_Up := True;
                     return;
                  elsif Found'Length > 1 and then Found (Found'First) = '/' then
                     Pres.Put_Note (Screen, "cli.choose.command_typed",
                                    [Loc.Named ("value", Found), Loc.Named ("name", "what it found")]);
                     Pres.Put_Message (Screen, "cli.task.complete_given_up", [Loc.Named ("name", Argument)]);
                     Given_Up := True;
                     return;
                  --  Kept beside what its notes asked, not over it.
                  elsif Found /= "" then
                     Fields.Include ("notes", (if R.Get (Defined, "notes") = "" then ""
                                               else R.Get (Defined, "notes") & " -- ")
                                              & "found: " & Found);
                     Tk.Revise (Store, Change, Argument, Fields, Outcome);
                     if E.Is_Ok (Outcome) then
                        Commit;
                     end if;
                     if E.Is_Error (Outcome) then
                        Fail (Outcome);
                        Given_Up := True;
                        return;
                     end if;
                  end if;
               end;
            end if;
         exception
            when Ada.Text_IO.End_Error =>
               Given_Up := True;
         end Ask_Findings;

      begin
         if not Needs_Task then
            return;
         end if;
         --  Parts not done: refused before any check runs, with the way on.
         declare
            Open : Unbounded_String;
            First_Open : Unbounded_String;
         begin
            for Child of Tk.Children (Store, Argument) loop
               if Tk.State_Of (Store, Child) not in "complete" | "cancelled" | "rejected" then
                  Append (Open, (if Open = Null_Unbounded_String then "" else ", ") & Child);
                  if First_Open = Null_Unbounded_String then
                     First_Open := To_Unbounded_String (Child);
                  end if;
               end if;
            end loop;
            if Open /= Null_Unbounded_String then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "the task to complete");
               E.Add_Text (Outcome, "value", Argument);
               E.Add_Text (Outcome, "detail", "its parts " & To_String (Open) & " are not done: "
                           & (if Tk.State_Of (Store, To_String (First_Open)) = "candidate"
                              then "/task accept " else "/work ")
                           & To_String (First_Open) & " does the first, or /task cancel lets one go;"
                           & " nothing was checked");
               Fail (Outcome);
               return;
            end if;
         end;
         --  Ended, it is not completed: said before anything is checked.
         if Tk.State_Of (Store, Argument) in "cancelled" | "rejected" | "complete" then
            Outcome := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Outcome, "name", Argument);
            E.Add_Text (Outcome, "value", Tk.State_Of (Store, Argument));
            E.Add_Text (Outcome, "expected", "complete");
            E.Add_Text (Outcome, "detail",
                        (if Tk.State_Of (Store, Argument) = "complete" then "it is complete already"
                         elsif Tk.State_Of (Store, Argument) = "cancelled"
                         then "/task reopen " & Argument & " takes it up again first"
                         else "/task reconsider " & Argument & " makes it a candidate again first"));
            Fail (Outcome);
            return;
         end if;

         --  What an analysis found, asked before anything moves.
         declare
            Given_Up : Boolean;
         begin
            Ask_Findings (Given_Up);
            if Given_Up then
               return;
            end if;
         end;

         --  A candidate completed by hand is accepted on the way: saying the
         --  work is done is saying it was wanted.
         if Tk.State_Of (Store, Argument) = "candidate" then
            Tk.Move (Store, Change, Argument, "accepted", "completed by hand",
                     Status => Outcome, Actor => Model_Runner.Framework.Transitions.User);
            if E.Is_Ok (Outcome) then
               Commit;
            end if;
            if E.Is_Error (Outcome) then
               Fail (Outcome);
               return;
            end if;
            Pres.Put_Message (Screen, "cli.task.moved",
                              [Loc.Named ("name", Argument), Loc.Named ("value", "accepted")]);
         end if;

         --  Its work still in a workspace: taken in first, and nothing run.
         if Tk.State_Of (Store, Argument) = "verification"
           and then Model_Runner.Framework.Workspaces.Active_For (Store, Argument) /= ""
         then
            Outcome := E.Make (E.Framework_Task_Not_Ready);
            E.Add_Text (Outcome, "name", Argument);
            E.Add_Text (Outcome, "detail", "its work waits in "
                        & Model_Runner.Framework.Workspaces.Active_For (Store, Argument)
                        & " to be taken in");
            Fail (Outcome);
            declare
               Space : constant String :=
                 Model_Runner.Framework.Workspaces.Active_For (Store, Argument);
               Place : Model_Runner.Framework.Workspaces.Workspace;
               Read  : E.Error_Info;
            begin
               if Model_Runner.Framework.Workspaces.Conflict_Files (Store, Space).Is_Empty then
                  Pres.Put_Note (Screen, "cli.next.integrate", [Loc.Named ("name", Argument)]);
               else
                  --  In conflict: settled first, then taken in as settled.
                  Model_Runner.Framework.Workspaces.Read (Store, Space, Place, Read);
                  Pres.Put_Note (Screen, "cli.next.conflict",
                                 [Loc.Named ("name", Argument),
                                  Loc.Named ("path", To_String (Place.Path)),
                                  Loc.Named ("detail", In_Conflict (Store, Space, To_String (Place.Path)))]);
               end if;
            end;
            return;
         end if;

         --  Its work given up with its workspace: completed by hand only
         --  for work done by hand, which is said before it is taken so.
         declare
            Held_State : R.Item;
            Read       : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Tasks_Area, Argument & ".state", Held_State, Read);
            if E.Is_Ok (Read) and then R.Get (Held_State, "current_workspace") /= ""
              and then Tk.State_Of (Store, Argument) in "failed" | "blocked"
              and then Model_Runner.Framework.Workspaces.Active_For (Store, Argument) = ""
            then
               --  Its work is kept and not put back: asked first, with how.
               if Kept_For (Argument) /= ""
                 and then not Confirmed ("cli.task.complete_without_kept", Argument, Kept_For (Argument))
               then
                  return;
               end if;
               --  A workspace it wrote nothing in -- an analysis -- gave
               --  up nothing worth a word.
               if Ada.Directories.Exists (Model_Runner.Framework.Workspaces.Kept_Copy
                                            (Store, R.Get (Held_State, "current_workspace")))
               then
                  Pres.Put_Note (Screen,
                                 (if Model_Runner.Framework.Workspaces.Was_Restored
                                       (Store, Ada.Directories.Simple_Name
                                                 (Model_Runner.Framework.Workspaces.Kept_Copy
                                                    (Store, R.Get (Held_State, "current_workspace"))))
                                  then "cli.task.given_up_restored" else "cli.task.given_up_by_hand"),
                                 [Loc.Named ("name", Argument),
                                  Loc.Named ("value", R.Get (Held_State, "current_workspace"))]);
               end if;
            end if;
         end;

         --  Already complete: said, and nothing run.
         if Tk.State_Of (Store, Argument) = "complete" then
            Pres.Put_Note (Screen, "cli.intent.already",
                           [Loc.Named ("name", Argument), Loc.Named ("value", "complete")]);
            return;
         end if;

         --  Waiting for another, it is not complete whatever its checks say:
         --  said first, with what to do, and nothing is run.
         declare
            Defined : R.Item;
            Read    : E.Error_Info;
         begin
            Tk.Definition (Store, Argument, Defined, Read);
            for Other of Model_Runner.Framework.Lines_Of
              (Ada.Strings.Fixed.Translate (R.Get (Defined, "depends_on"),
                                            Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
            loop
               declare
                  Named : constant String := Ada.Strings.Fixed.Trim (Other, Ada.Strings.Both);
               begin
                  if Named /= "" and then Tk.State_Of (Store, Named) /= "complete" then
                     Outcome := E.Make (E.Framework_Task_Not_Ready);
                     E.Add_Text (Outcome, "name", Argument);
                     E.Add_Text (Outcome, "detail", "it waits for " & Named & ", which is "
                                 & Model_Runner.Framework.State_Said (Moved_State (Named)));
                     Fail (Outcome);
                     if Tk.State_Of (Store, Named) = "blocked"
                       and then (for some Child of Tk.Children (Store, Named) =>
                                   Tk.State_Of (Store, Child) not in "complete" | "cancelled" | "rejected")
                     then
                        --  Waiting for its parts: the first of them is the way on.
                        for Child of Tk.Children (Store, Named) loop
                           if Tk.State_Of (Store, Child) not in "complete" | "cancelled" | "rejected" then
                              Pres.Put_Note
                                (Screen, "cli.next.waits_on_parts",
                                 [Loc.Named ("name", Argument), Loc.Named ("value", Named),
                                  Loc.Named ("detail", (if Tk.State_Of (Store, Child) = "candidate"
                                                        then "/task accept " else "/work ") & Child)]);
                              exit;
                           end if;
                        end loop;
                     elsif Tk.State_Of (Store, Named) in "blocked" | "failed" then
                        Pres.Put_Note
                          (Screen, "cli.next.waits_on_stopped",
                           [Loc.Named ("name", Argument), Loc.Named ("value", Named),
                            Loc.Named ("state", Model_Runner.Framework.State_Said (Tk.State_Of (Store, Named)))]);
                     else
                        Pres.Put_Note
                          (Screen, "cli.next.waits_first",
                           [Loc.Named ("name", Argument), Loc.Named ("value", Named),
                            Loc.Named ("detail",
                                       (if Tk.State_Of (Store, Named) = "candidate"
                                        then "/task accept " & Named else "/work " & Named))]);
                     end if;
                     return;
                  end if;
               end;
            end loop;
         end;

         --  Its evidence missing or stale, it is verified now: a task done
         --  by hand is checked as the harness would check it. Stale too where
         --  a file of its work holds otherwise than its work left it -- a
         --  copy put back, an edit -- since its last check.
         if not Verified
           or else (State_Field (Argument, "taken_in") /= ""
                    and then (for some File of Model_Runner.Framework.Lines_Of (Changed_By_Lines (Argument)) =>
                                Model_Runner.Framework.Work.Holder_Of (Store, File) /= Argument))
         then
            Verify;
            if Status /= E.Exit_Success then
               return;
            end if;
         else
            --  Its evidence current: said, as a check run says itself.
            declare
               Now : constant Vf.Gate_List := Vf.Gates (Store, Argument);
            begin
               for Index in 1 .. Vf.Length (Now) loop
                  if To_String (Vf.Element (Now, Index).Name) = "verification" then
                     Pres.Put_Message (Screen, "cli.task.verified_already",
                                       [Loc.Named ("name", Argument),
                                        Loc.Named ("detail",
                                                   Vf.Latest (Store, Argument, Vf.Profile_Of (Store, Argument))
                                                   & " passed")]);
                  end if;
               end loop;
            end;
         end if;
         Complete_Judged;
      end Complete;

      procedure Complete_Judged is
         Changed : Model_Runner.Framework.Name_Lists.Vector;
         Judged  : constant Model_Runner.Framework.Verification.Gate_List :=
           Model_Runner.Framework.Verification.Gates (Store, Argument);

         --  The place in Judged of the gate that comes so many by name.
         function Gate_Order (Position : Positive) return Positive is
            package Sorting is new Model_Runner.Framework.Name_Lists.Generic_Sorting;
            Names : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for Index in 1 .. Model_Runner.Framework.Verification.Length (Judged) loop
               Names.Append (To_String (Model_Runner.Framework.Verification.Element (Judged, Index).Name));
            end loop;
            Sorting.Sort (Names);
            for Index in 1 .. Model_Runner.Framework.Verification.Length (Judged) loop
               if To_String (Model_Runner.Framework.Verification.Element (Judged, Index).Name) = Names (Position) then
                  return Index;
               end if;
            end loop;
            return Position;
         end Gate_Order;

         --  The workspace its agent's work was given up with, if it was:
         --  what that work changed and took in is none of this.
         function Given_Up return String is
            Held_State : R.Item;
            Read       : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Tasks_Area, Argument & ".state", Held_State, Read);
            if E.Is_Ok (Read) and then R.Get (Held_State, "current_workspace") /= ""
              and then Tk.State_Of (Store, Argument) in "failed" | "blocked"
              and then Model_Runner.Framework.Workspaces.Active_For (Store, Argument) = ""
            then
               --  Taken in is not given up: its work is in the project.
               declare
                  Place : Model_Runner.Framework.Workspaces.Workspace;
                  Got   : E.Error_Info;
               begin
                  Model_Runner.Framework.Workspaces.Read
                    (Store, R.Get (Held_State, "current_workspace"), Place, Got);
                  if E.Is_Ok (Got) and then To_String (Place.Status) = "integrated" then
                     return "";
                  end if;
               end;
               return R.Get (Held_State, "current_workspace");
            end if;
            return "";
         end Given_Up;
         Space : constant String := Given_Up;

         --  Worked apart as the project says work is, yet never given a
         --  workspace: its integration is nothing, not a pass.
         function Never_Apart return Boolean is
            Config     : R.Item;
            Held_State : R.Item;
            Read       : E.Error_Info;
         begin
            Model_Runner.Framework.Configurations.Read (Store, Config, Read);
            if E.Is_Error (Read) or else R.Get (Config, "scalar.work.isolation") /= "workspace" then
               return False;
            end if;
            S.Read (Store, Model_Runner.Framework.Tasks_Area, Argument & ".state", Held_State, Read);
            return E.Is_Ok (Read) and then R.Get (Held_State, "current_workspace") = "";
         end Never_Apart;
      begin
         for Position in 1 .. Model_Runner.Framework.Verification.Length (Judged) loop
            declare
               --  In one order every time: by name.
               Index : constant Positive := Gate_Order (Position);
               One : constant Model_Runner.Framework.Verification.Gate :=
                 Model_Runner.Framework.Verification.Element (Judged, Index);
               Detail : constant String :=
                                        (if To_String (One.Name) = "integration" and then Space = ""
                                           and then Never_Apart
                                         then "set aside: it had no workspace, and nothing to take in"
                                         --  Given up, and its kept copy put back since: the
                                         --  change is there, as taking it in would have made it.
                                         elsif Space /= ""
                                           and then To_String (One.Name)
                                                      in "implementation_present" | "integration"
                                           and then Model_Runner.Framework.Workspaces.Was_Restored
                                                      (Store, "given-up-" & Argument & "-" & Space)
                                         then "passed: what " & Space & " changed was put back from its kept copy"
                                         elsif Space /= ""
                                           and then To_String (One.Name)
                                                      in "implementation_present" | "integration"
                                         then "set aside: " & Space & " was given up, and it is"
                                              & " completed by hand"
                                         elsif One.Passed then "passed"
                                         elsif To_String (One.Name) = "no_blocking_issue"
                                           and then Model_Runner.Framework.Tasks.State_Of
                                                      (Store, Argument) = "blocked"
                                         then "set aside: it is completed by hand"
                                         elsif To_String (One.Name) = "implementation_present"
                                           and then Tk.State_Of (Store, Argument)
                                                    in "accepted" | "failed" | "blocked"
                                         then "set aside: it is completed by hand"
                                         else To_String (One.Reason));
               Lead : constant String :=
                 (if Detail = "passed" or else Ada.Strings.Fixed.Index (Detail, "passed: ") = Detail'First
                  then "passed"
                  elsif Ada.Strings.Fixed.Index (Detail, "set aside") = Detail'First then "set aside"
                  else "");
               --  The gate in words, as /task show's "done when" has it.
               Named : constant String :=
                 (if To_String (One.Name) = "children" then "its parts"
                  elsif To_String (One.Name) = "implementation_present" then "something changed"
                  elsif To_String (One.Name) = "integration" then "its work taken in"
                  elsif To_String (One.Name) = "no_blocking_issue" then "no blocking issue"
                  elsif To_String (One.Name) = "verification" then "its checks"
                  else To_String (One.Name));
            begin
               if Position = 1 then
                  Pres.Put_Section (Screen, "cli.task.section.judged");
               end if;
               --  Each check's outcome in its colour: passed, set aside,
               --  or what stopped it -- its parts not said where it has none.
               if To_String (One.Name) = "children" and then One.Passed
                 and then Model_Runner.Framework.Tasks.Children (Store, Argument).Is_Empty
               then
                  null;
               elsif Lead = "" then
                  Pres.Put_Pair (Screen, "cli.task.field", Named, Detail, Pres.Bad, Indent => 2);
               else
                  Pres.Put_Marked
                    (Screen, "cli.task.gate",
                     [Loc.Named ("name", "  " & Named),
                      Loc.Named ("detail", Detail & (if To_String (One.Name) = "children"
                                                     then Cancelled_Parts (Store, Argument) else ""))],
                     Lead, (if Lead = "passed" then Pres.Good else Pres.Muted));
               end if;
            end;
         end loop;

         Model_Runner.Framework.Verification.Complete_Task
           (Store, Change, Argument, Outcome);
         if E.Is_Ok (Outcome) then
            S.Commit (Store, Change, Outcome);
         end if;
         if E.Is_Ok (Outcome) then
            Model_Runner.Framework.Verification.Reevaluate_Requirements
              (Store, Change, Changed, Outcome);
         end if;
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            if E."=" (Outcome.Code, E.Framework_Task_Not_Ready) then
               Pres.Put_Note (Screen, "cli.next.gates", [Loc.Named ("name", Argument)]);
            end if;
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", Argument), Loc.Named ("value", "complete")]);
         for Requirement of Changed loop
            declare
               Held : Model_Runner.Framework.Intent.Entity;
               Read : E.Error_Info;
            begin
               Model_Runner.Framework.Intent.Read
                 (Store, Model_Runner.Framework.Intent.Requirement, Requirement, Held, Read);
               Pres.Put_Message
                 (Screen, "cli.task.requirement",
                  [Loc.Named ("name", Requirement),
                   Loc.Named ("value", To_String (Held.State))]);
            end;
         end loop;

         --  The requirements it serves that its completing leaves short of
         --  verified: each said, with what it still lacks.
         declare
            Defined : R.Item;
            Got     : E.Error_Info;
         begin
            Tk.Definition (Store, Argument, Defined, Got);
            --  An analysis is done for what it found: one completed with
            --  nothing of that kept is said to be, and where to keep it.
            if E.Is_Ok (Got) and then R.Get (Defined, "kind") = "analysis"
              and then Ada.Strings.Fixed.Index (R.Get (Defined, "notes"), "found: ") = 0
            then
               Pres.Put_Note (Screen, "cli.task.analysis_no_findings", [Loc.Named ("name", Argument)]);
            end if;
            if E.Is_Ok (Got) then
               for Requirement of Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements")) loop
                  declare
                     State : constant String :=
                       Model_Runner.Framework.Intent.State_Of
                         (Store, Model_Runner.Framework.Intent.Requirement, Requirement);
                  begin
                     if State not in "" | "verified" | "obsolete" | "rejected" then
                        declare
                           Why : constant String :=
                             Model_Runner.Framework.Verification.Why_Not_Verified (Store, Requirement);
                        begin
                           --  Marked implemented by a task done by hand that
                           --  changed nothing: said as that, not as a
                           --  contradiction.
                           if State = "implemented"
                             and then Ada.Strings.Fixed.Index (Why, "no implementation is known") = 1
                           then
                              declare
                                 package Rp renames Model_Runner.Framework.Repository;
                                 Graph : constant Rp.Graph := Rp.Now (Store);
                                 Named : Unbounded_String;
                              begin
                                 --  A source file naming it: the one to link, named.
                                 for Index in 1 .. Rp.File_Count (Graph) loop
                                    exit when Named /= Null_Unbounded_String;
                                    declare
                                       use type Rp.File_Role;
                                       Path : constant String := To_String (Rp.File_At (Graph, Index).Path);
                                       File_In : Ada.Text_IO.File_Type;
                                    begin
                                       if Rp."=" (Rp.File_At (Graph, Index).Role, Rp.Source) then
                                          Ada.Text_IO.Open (File_In, Ada.Text_IO.In_File, Path);
                                          while not Ada.Text_IO.End_Of_File (File_In) loop
                                             if Ada.Strings.Fixed.Index
                                                  (Ada.Text_IO.Get_Line (File_In), Requirement) > 0
                                             then
                                                Named := To_Unbounded_String (Path);
                                                exit;
                                             end if;
                                          end loop;
                                          Ada.Text_IO.Close (File_In);
                                       end if;
                                    exception
                                       when others =>
                                          if Ada.Text_IO.Is_Open (File_In) then
                                             Ada.Text_IO.Close (File_In);
                                          end if;
                                    end;
                                 end loop;
                                 Pres.Put_Note
                                   (Screen, "cli.task.requirement_no_file",
                                    [Loc.Named ("name", Requirement), Loc.Named ("other", Argument),
                                     Loc.Named ("path", (if Named = Null_Unbounded_String then "FILE"
                                                         else To_String (Named)))]);
                              end;
                           else
                              Pres.Put_Note
                                (Screen, "cli.task.requirement_unverified",
                                 [Loc.Named ("name", Requirement), Loc.Named ("value", State),
                                  Loc.Named ("detail", Why)]);
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end if;
         end;

         Say_Parent_Ready (Argument);
      end Complete_Judged;

      --  Take a task's workspace in, and verify and complete it.
      procedure Integrate is
         Done : Model_Runner.Framework.Work.Report;
         Anyway_Unneeded : Boolean := False;
      begin
         --  The way it is taken in, with the task left out: said which,
         --  and the tasks whose work waits named.
         if First_Word in "" | "resolved" | "anyway" then
            declare
               Waiting : Unbounded_String;
               Way     : constant String :=
                 Ada.Strings.Fixed.Trim (Argument, Ada.Strings.Both);
            begin
               for Id of Tk.List (Store, "verification") loop
                  if Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= "" then
                     Append (Waiting, (if Waiting = Null_Unbounded_String then "" else ", ")
                             & "/task integrate " & Id & (if Way = "" then "" else " " & Way));
                  end if;
               end loop;
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name",
                           "the task whose work is taken in"
                           & (if Waiting = Null_Unbounded_String then " (none waits)"
                              elsif Ada.Strings.Unbounded.Index (Waiting, ", ") > 0 and then Way = ""
                              then ": " & To_String (Waiting) & ", or /task integrate all for every one"
                              else ": " & To_String (Waiting)));
               Fail (Outcome);
               return;
            end;
         end if;
         if not Needs_Task then
            return;
         end if;
         --  A word it does not take is refused, not ignored.
         if After_First not in "" | "anyway" | "resolved" | "resolved anyway" | "discard" then
            Outcome := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Outcome, "value", After_First & "; /task integrate takes resolved, anyway,"
                        & " resolved anyway, or discard after the task");
            Fail (Outcome);
            return;
         end if;

         --  discard: the work in its workspace given up, and the task
         --  accepted to be done afresh.
         if After_First = "discard" then
            declare
               Space : constant String :=
                 Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
               Lost  : constant Model_Runner.Framework.Name_Lists.Vector :=
                 (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
                  else Model_Runner.Framework.Workspaces.Changes (Store, Space));
            begin
               if Space = "" or else Tk.State_Of (Store, First_Word) /= "verification" then
                  --  Nothing waits: said as a state, with where its work is.
                  Pres.Put_Note
                    (Screen, "cli.task.diff_none",
                     [Loc.Named ("name", First_Word), Loc.Named ("value", Moved_State (First_Word)),
                      Loc.Named ("detail",
                                 (if Never_Worked (First_Word) then "it has not been worked on yet"
                                  elsif Tk.State_Of (Store, First_Word) in "failed" | "blocked"
                                  then "a workspace is given up when its work fails, what it changed kept;"
                                       & " /task kept lists those copies"
                                  else "there is nothing to discard"))]);
                  return;
               end if;
               if not Confirmed ("cli.task.give_up_confirm", First_Word,
                                 (if Lost.Is_Empty then "nothing" else Joined (Lost))
                                 & "? a copy is kept as given-up-" & First_Word & "-" & Space)
               then
                  return;
               end if;
               Tk.Move (Store, Change, First_Word, "failed",
                        "its work in " & Space & " was given up by hand, to be done afresh",
                        Status => Outcome, Actor => Model_Runner.Framework.Transitions.User);
               if E.Is_Ok (Outcome) then
                  Commit;
               end if;
               if E.Is_Ok (Outcome) then
                  Tk.Move (Store, Change, First_Word, "accepted", "to be done afresh",
                           Status => Outcome, Actor => Model_Runner.Framework.Transitions.User);
               end if;
               if E.Is_Ok (Outcome) then
                  Commit;
               end if;
               --  Afresh: what that attempt answered is not told the next.
               if E.Is_Ok (Outcome) then
                  Model_Runner.Framework.Work.Forget_Last_Answer (Store, First_Word);
               end if;
               if E.Is_Error (Outcome) then
                  Fail (Outcome);
                  return;
               end if;
               Pres.Put_Note (Screen, "cli.task.workspace_given_up",
                              [Loc.Named ("name", Space), Loc.Named ("detail", Given_Up_Detail (Space, Lost))]);
               Pres.Put_Message (Screen, "cli.task.moved",
                                 [Loc.Named ("name", First_Word),
                                  Loc.Named ("value", Model_Runner.Framework.State_Said (Moved_State (First_Word)))]);
               Said_Ready.Append (First_Word);
               Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", First_Word)]);
               return;
            end;
         end if;
         --  integrate TASK anyway: taken in whatever the code joins it to.
         --  Settled, it says, with a file as it was when the conflict was
         --  found: taken over the project's change only when that is said.
         if After_First = "resolved" then
            --  A file settled in merge/, its markers gone: taken as the
            --  workspace's, as if settled there.
            declare
               Space : constant String := Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
               Place : Model_Runner.Framework.Workspaces.Workspace;
               Read  : E.Error_Info;
            begin
               if Space /= "" then
                  Model_Runner.Framework.Workspaces.Read (Store, Space, Place, Read);
                  if E.Is_Ok (Read) then
                     for File of Model_Runner.Framework.Workspaces.Conflict_Files
                                   (Store, Space, Unsettled_Only => True)
                     loop
                        declare
                           Merged : constant String :=
                             Hostkit.Fs.Join (Hostkit.Fs.Join (Ada.Directories.Containing_Directory
                                                                 (To_String (Place.Path)), "merge"), File);
                           Tree   : constant String := Hostkit.Fs.Join (To_String (Place.Path), File);
                           Text   : Unbounded_String;
                           File_In : Ada.Text_IO.File_Type;
                        begin
                           if Ada.Directories.Exists (Merged) then
                              Ada.Text_IO.Open (File_In, Ada.Text_IO.In_File, Merged);
                              while not Ada.Text_IO.End_Of_File (File_In) loop
                                 Append (Text, Ada.Text_IO.Get_Line (File_In) & ASCII.LF);
                              end loop;
                              Ada.Text_IO.Close (File_In);
                              if Index (Text, "<<<<<<<") = 0 and then Index (Text, ">>>>>>>") = 0 then
                                 Ada.Directories.Copy_File (Merged, Tree);
                                 Pres.Put_Note (Screen, "cli.task.merge_taken", [Loc.Named ("path", File)]);
                              end if;
                           end if;
                        exception
                           when others =>
                              if Ada.Text_IO.Is_Open (File_In) then
                                 Ada.Text_IO.Close (File_In);
                              end if;
                        end;
                     end loop;
                  end if;
               end if;
            end;
            declare
               Space     : constant String :=
                 Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
               Unsettled : constant Model_Runner.Framework.Name_Lists.Vector :=
                 (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
                  else Model_Runner.Framework.Workspaces.Conflict_Files
                         (Store, Space, Unsettled_Only => True));
            begin
               if not Unsettled.Is_Empty then
                  declare
                     Held  : Model_Runner.Framework.Workspaces.Workspace;
                     Got   : E.Error_Info;
                     --  merge/ only where one was written: a file both sides
                     --  made has no lines in common to mark.
                     Merge : Boolean := False;
                  begin
                     Model_Runner.Framework.Workspaces.Read (Store, Space, Held, Got);
                     if E.Is_Ok (Got) and then Length (Held.Path) > 0 then
                        Merge := (for some File of Unsettled =>
                                    Ada.Directories.Exists
                                      (Ada.Directories.Containing_Directory (To_String (Held.Path))
                                       & "/merge/" & File));
                     end if;
                     Outcome := E.Make (E.Framework_Integration_Conflict);
                     E.Add_Text (Outcome, "name", Space);
                     E.Add_Text (Outcome, "detail", Joined (Unsettled)
                                 & ", not changed since the conflict was found; settle "
                                 & (if Natural (Unsettled.Length) = 1 then "it" else "them")
                                 & " in " & (if E.Is_Ok (Got) then To_String (Held.Path) else "the workspace")
                                 & (if Merge
                                    then " -- or in "
                                         & Ada.Directories.Containing_Directory (To_String (Held.Path))
                                         & "/merge/, its markers taken out --"
                                    else " -- both sides rewrote the whole file, so no merged copy could be"
                                         & " made --")
                                 & " /task diff " & First_Word & " shows the two; or"
                                 & " /task integrate " & First_Word
                                 & " resolved anyway takes the workspace's copy over the project's");
                  end;
                  Fail (Outcome);
                  return;
               end if;
            end;
         end if;
         --  resolved anyway: the workspace's copy of each file still as it was
         --  when the conflict was found goes over the project's -- asked at a
         --  terminal, and the project's kept, so a person's own edit is not
         --  lost unseen.
         if After_First = "resolved anyway" then
            declare
               Space     : constant String :=
                 Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
               Unsettled : constant Model_Runner.Framework.Name_Lists.Vector :=
                 (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
                  else Model_Runner.Framework.Workspaces.Conflict_Files
                         (Store, Space, Unsettled_Only => True));
               Project   : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
               Kept_In   : constant String :=
                 Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"),
                                  "replaced-" & First_Word & (if Space = "" then "" else "-" & Space));
            begin
               if not Unsettled.Is_Empty then
                  if Interactive then
                     Pres.Put_Message (Screen, "cli.task.anyway_confirm",
                                       [Loc.Named ("name", First_Word),
                                        Loc.Named ("detail", Joined (Unsettled))]);
                     if not Answered_Yes (Screen) then
                        Pres.Put_Message (Screen, "cli.task.anyway_kept", [Loc.Named ("name", First_Word)]);
                        return;
                     end if;
                  end if;
                  for File of Unsettled loop
                     declare
                        From : constant String := Hostkit.Fs.Join (Project, File);
                        To   : constant String := Hostkit.Fs.Join (Kept_In, File);
                     begin
                        if Ada.Directories.Exists (From) then
                           Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (To));
                           Ada.Directories.Copy_File (From, To);
                        end if;
                     exception
                        when others =>
                           null;
                     end;
                  end loop;
                  Pres.Put_Note (Screen, "cli.task.anyway_saved",
                                 [Loc.Named ("path", Ada.Directories.Simple_Name (Kept_In))]);
               end if;
            end;
         end if;

         --  anyway where nothing stood in the way: taken in all the same, and
         --  said that it was not needed -- once taken in, not before a
         --  conflict the taking in finds.
         Anyway_Unneeded :=
           After_First = "anyway"
           and then Model_Runner.Framework.Workspaces.Active_For (Store, First_Word) /= ""
           and then Model_Runner.Framework.Workspaces.Conflict_Files
                      (Store, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)).Is_Empty
           and then Model_Runner.Framework.Workspaces.Semantic_Conflicts
                      (Store, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)).Is_Empty;
         --  Settled, or taken anyway, with no conflict recorded yet but one
         --  there: found now, as a plain integrate finds it -- recorded, the
         --  project untouched -- and gone on with, not refused to be asked again.
         if After_First in "resolved" | "resolved anyway"
           and then Model_Runner.Framework.Workspaces.Active_For (Store, First_Word) /= ""
           and then Model_Runner.Framework.Workspaces.Conflict_Files
                      (Store, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)).Is_Empty
           and then not Model_Runner.Framework.Workspaces.Conflicts
                          (Store, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)).Is_Empty
         then
            declare
               Scratch : S.Transaction;
               Taken   : Model_Runner.Framework.Name_Lists.Vector;
               Found   : E.Error_Info;
            begin
               Model_Runner.Framework.Workspaces.Integrate
                 (Store, Scratch, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word),
                  Permitted => True, Taken => Taken, Status => Found);
            end;
         end if;
         declare
            Space : constant String := Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
            --  Settled means a conflict was found first: without one, the
            --  project is checked for one as a plain integrate checks it.
            Found : constant Boolean :=
              Space /= "" and then not Model_Runner.Framework.Workspaces.Conflict_Files (Store, Space).Is_Empty;
         begin
            if After_First in "resolved" | "resolved anyway" and then not Found and then Space /= "" then
               Pres.Put_Note (Screen, "cli.task.no_conflict_yet", [Loc.Named ("name", First_Word)]);
            end if;
            --  Settled means settled: a file still holding conflict marks --
            --  <<<<<<<, =======, >>>>>>> lines -- is not taken in.
            if After_First in "resolved" | "resolved anyway" and then Found then
               declare
                  Place   : Model_Runner.Framework.Workspaces.Workspace;
                  Read    : E.Error_Info;
                  Marked  : Unbounded_String;
               begin
                  Model_Runner.Framework.Workspaces.Read (Store, Space, Place, Read);
                  for File of Model_Runner.Framework.Workspaces.Conflict_Files (Store, Space) loop
                     declare
                        Path : constant String := Hostkit.Fs.Join (To_String (Place.Path), File);
                        In_File : Ada.Text_IO.File_Type;
                        Has  : Boolean := False;
                     begin
                        if Ada.Directories.Exists (Path) then
                           Ada.Text_IO.Open (In_File, Ada.Text_IO.In_File, Path);
                           while not Has and then not Ada.Text_IO.End_Of_File (In_File) loop
                              declare
                                 Line : constant String := Ada.Text_IO.Get_Line (In_File);
                              begin
                                 Has := (Line'Length >= 7
                                         and then Line (Line'First .. Line'First + 6) in "<<<<<<<" | ">>>>>>>")
                                   or else Line = "=======";
                              end;
                           end loop;
                           Ada.Text_IO.Close (In_File);
                        end if;
                        if Has then
                           Append (Marked, (if Marked = Null_Unbounded_String then "" else ", ") & File);
                        end if;
                     exception
                        when others =>
                           if Ada.Text_IO.Is_Open (In_File) then
                              Ada.Text_IO.Close (In_File);
                           end if;
                     end;
                  end loop;
                  if Marked /= Null_Unbounded_String then
                     Outcome := E.Make (E.Framework_Input_Invalid);
                     E.Add_Text (Outcome, "name", "what " & Space & " settled");
                     E.Add_Text (Outcome, "value", To_String (Marked));
                     E.Add_Text (Outcome, "detail", "it still holds conflict marks (<<<<<<<,"
                                 & " =======, >>>>>>>); settle it in the workspace, keeping what it should say"
                                 & " and taking the marks out, then /task integrate " & First_Word & " "
                                 & After_First & " again");
                     Fail (Outcome);
                     return;
                  end if;
               end;
            end if;
            Model_Runner.Framework.Work.Take_In
              (Store, First_Word, Done, Outcome, Semantic_Accepted => After_First = "anyway",
               Text_Resolved => Found and then After_First in "resolved" | "resolved anyway",
               Replaced_Kept => (if After_First = "resolved anyway" and then Found and then Space /= ""
                                   and then Ada.Directories.Exists
                                              (Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"),
                                                                "replaced-" & First_Word & "-" & Space))
                                 then Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"),
                                                       "replaced-" & First_Word & "-" & Space)
                                 else ""));
         end;
         if E.Is_Ok (Outcome) and then Anyway_Unneeded then
            Pres.Put_Note (Screen, "cli.task.anyway_unneeded");
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);

            --  A conflict is not the end: where the work is, and the ways on.
            if E."=" (Outcome.Code, E.Framework_Integration_Conflict)
              and then After_First = "anyway"
              and then Ada.Strings.Fixed.Index (E.Text_Of (Outcome, "detail"), "what the code joins")
                       = 0
            then
               Pres.Put_Note (Screen, "cli.next.anyway_text", [Loc.Named ("name", First_Word)]);
            end if;
            if E."=" (Outcome.Code, E.Framework_Integration_Conflict) then
               declare
                  Place : Model_Runner.Framework.Workspaces.Workspace;
                  Read  : E.Error_Info;
               begin
                  Model_Runner.Framework.Workspaces.Read
                    (Store, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word),
                     Place, Read);
                  if E.Is_Ok (Read) then
                     Pres.Put_Note
                       (Screen, "cli.next.conflict",
                        [Loc.Named ("name", First_Word),
                         Loc.Named ("path", To_String (Place.Path)),
                         Loc.Named ("detail", In_Conflict
                                                (Store, Model_Runner.Framework.Workspaces.Active_For
                                                          (Store, First_Word),
                                                 To_String (Place.Path)))]);
                  end if;
               end;
            end if;
            return;
         end if;

         --  Settled, but not passing where it was settled: nothing taken
         --  in, and the work still where it can be put right.
         if Done.Changed_Files.Is_Empty and then To_String (Done.Final_State) = "verification" then
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", "reason"), Loc.Named ("value", To_String (Done.Reason))]);
            declare
               Place : Model_Runner.Framework.Workspaces.Workspace;
               Read  : E.Error_Info;
            begin
               Model_Runner.Framework.Workspaces.Read
                 (Store, To_String (Done.Workspace_Id), Place, Read);
               --  Settled, and its checks failed there: that is what is
               --  put right, not a conflict.
               Pres.Put_Note
                 (Screen, "cli.next.recheck_failed",
                  [Loc.Named ("name", First_Word), Loc.Named ("path", To_String (Place.Path))]);
            end;
            Status := E.Exit_Input_Output;
            return;
         end if;
         declare
            Project : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
            Said    : Model_Runner.Framework.Name_Lists.Vector;
         begin
            --  A file the work took away is said removed.
            for Path of Done.Changed_Files loop
               Said.Append (Path & (if not Ada.Directories.Exists (Hostkit.Fs.Join (Project, Path)) then " (removed)"
                                    elsif Model_Runner.Framework.Workspaces.Last_Joined.Contains (Path)
                                    then " (joined with the project's own change to it)"
                                    else ""));
            end loop;
            Pres.Put_Message
              (Screen, "cli.task.integrated",
               [Loc.Named ("name", To_String (Done.Workspace_Id)),
                Loc.Named ("detail", (if Said.Is_Empty then "nothing" else Joined (Said)))]);
         end;
         --  The project as it is after, checked: said with its evidence.
         --  Passed or not by its own record: a task held back by a gate
         --  of its own -- parts still open -- was checked all the same.
         if Length (Done.Evidence_Id) > 0 then
            declare
               Evidence : R.Item;
               Read     : E.Error_Info;
            begin
               S.Read (Store, Model_Runner.Framework.Verification_Area, To_String (Done.Evidence_Id),
                       Evidence, Read);
               Pres.Put_Message
                 (Screen, "cli.task.field",
                  [Loc.Named ("name", "checked after"),
                   Loc.Named ("value", To_String (Done.Evidence_Id)
                                       & (if E.Is_Ok (Read) and then R.Get (Evidence, "passed") = "true"
                                          then " passed" else " did not pass"))]);
            end;
         end if;
         --  Files its agent changed and did not report are in the project
         --  now too: named, however they got there.
         declare
            Held_State : R.Item;
            Read       : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Tasks_Area, First_Word & ".state", Held_State, Read);
            if E.Is_Ok (Read) and then R.Get (Held_State, "unreported_files") /= "" then
               Pres.Put_Message (Screen, "cli.task.integrated_unreported",
                                 [Loc.Named ("detail", R.Get (Held_State, "unreported_files"))]);
            end if;
         end;
         --  Why, before where it ended: the outcome last.
         if Done.Reason /= Null_Unbounded_String then
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", (if To_String (Done.Final_State) = "complete" then "note" else "reason")),
                Loc.Named ("value", To_String (Done.Reason))]);
         end if;
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", First_Word),
             Loc.Named ("value", Model_Runner.Framework.State_Said (Moved_State (First_Word)))]);
         --  Held back by its parts: the first of them is what to do; a
         --  retry would only wait for them again.
         if To_String (Done.Final_State) in "failed" | "blocked" then
            declare
               Parts : constant Model_Runner.Framework.Name_Lists.Vector := Tk.Children (Store, First_Word);
               Open  : Unbounded_String;
            begin
               for Part of Parts loop
                  if Open = Null_Unbounded_String
                    and then Tk.State_Of (Store, Part) not in "complete" | "cancelled" | "rejected"
                  then
                     Open := To_Unbounded_String (Part);
                  end if;
               end loop;
               if Open /= Null_Unbounded_String
                 and then Ada.Strings.Fixed.Index (To_String (Done.Reason), "children") > 0
               then
                  Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", To_String (Open))]);
               else
                  Pres.Put_Note (Screen, "cli.next.retry", [Loc.Named ("name", First_Word)]);
               end if;
            end;
         end if;
         if To_String (Done.Final_State) = "complete" then
            --  What its end lets go on, named as any change's is.
            declare
               Became : Model_Runner.Framework.Name_Lists.Vector;
            begin
               Tk.Recompute_Readiness (Store, Change, Became, Outcome);
               if E.Is_Ok (Outcome) then
                  S.Commit (Store, Change, Outcome);
                  Became_Ready.Append (Became);
               end if;
               Outcome := E.Success;
            end;
            Say_Parent_Ready (First_Word);
         end if;
         if To_String (Done.Final_State) /= "complete" then
            Status := E.Exit_Input_Output;
         end if;
      end Integrate;

      --  One step of the orchestrator: every event acted on by the rules.
      procedure Step is
         Done : Model_Runner.Framework.Orchestration.Step_Report;
      begin
         Model_Runner.Framework.Orchestration.Step (Store, Done, Outcome);
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.task.step",
            [Loc.Named ("count", T.Image (Long_Long_Integer (Done.Events_Seen))),
             Loc.Named ("total", T.Image (Long_Long_Integer (Done.Actions_Taken)))]);
         for Id of Done.Derived loop
            Pres.Put_Message
              (Screen, "cli.task.derived",
               [Loc.Named ("name", Id),
                Loc.Named ("value", Model_Runner.Framework.Tasks.Component_Of_Task (Store, Id))]);
         end loop;
         for Id of Done.Became_Ready loop
            Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
         end loop;
      end Step;

      --  What can start now, what waits, and what needs judgment.
      procedure Show_Plan is
         Planned : constant Model_Runner.Framework.Orchestration.Dispatch_Plan :=
           Model_Runner.Framework.Orchestration.Plan (Store);

         --  The task a line is about: its first word.
         function Task_In (Line : String) return String is
            Stop : constant Natural := Ada.Strings.Fixed.Index (Line & " ", " ");
         begin
            return Ada.Strings.Fixed.Trim (Line (Line'First .. Stop - 1), Ada.Strings.Maps.To_Set (":,"),
                                           Ada.Strings.Maps.To_Set (":,"));
         end Task_In;
      begin
         --  Each task in the colour of how it stands: to start, waiting,
         --  or wanting a person's judgment.
         for Id of Planned.Start loop
            Pres.Put_Marked (Screen, "cli.task.start", [Loc.Named ("name", Id)], Id, Pres.Good);
         end loop;
         for Line of Planned.Held loop
            Pres.Put_Marked (Screen, "cli.task.held", [Loc.Named ("detail", Line)], Task_In (Line), Pres.Pending);
         end loop;
         --  Every accepted task is somewhere in the plan: one neither to
         --  start nor held above waits, and is said with what for.
         for Id of Tk.List (Store, "accepted") loop
            if not Planned.Start.Contains (Id)
              and then not (for some Line of Planned.Held => Task_In (Line) = Id)
            then
               declare
                  Now : constant Tk.Readiness := Tk.Ready (Store, Id);
               begin
                  Pres.Put_Marked (Screen, "cli.task.held",
                                   [Loc.Named ("detail", Id & ": " & (if Now.Reasons.Is_Empty then "waiting"
                                                                       else Now.Reasons.First_Element))],
                                   Id, Pres.Pending);
               end;
            end if;
         end loop;
         for Line of Model_Runner.Framework.Orchestration.Needs_Judgment (Store) loop
            Pres.Put_Marked (Screen, "cli.task.judgment", [Loc.Named ("detail", Line)], Task_In (Line), Pres.Pending);
         end loop;
      end Show_Plan;

      procedure Derive is
         Made : Model_Runner.Framework.Name_Lists.Vector;
      begin
         Tk.Derive (Store, Change, Made, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         if Made.Is_Empty
           and then Model_Runner.Framework.Intent.List
                      (Store, Model_Runner.Framework.Intent.Requirement, "accepted").Is_Empty
         then
            Pres.Put_Note (Screen, "cli.task.nothing_to_derive");
         elsif Made.Is_Empty then
            --  An accepted requirement whose derived task ended rejected or
            --  cancelled is served by nothing, and derivation makes it once:
            --  said, with the ways back.
            declare
               Said : Boolean := False;
            begin
               for Requirement of Model_Runner.Framework.Intent.List
                                    (Store, Model_Runner.Framework.Intent.Requirement, "accepted")
               loop
                  declare
                     Live  : Boolean := False;
                     Ended : Unbounded_String;
                  begin
                     for Id of Tk.List (Store) loop
                        declare
                           Defined : R.Item;
                           Got     : E.Error_Info;
                        begin
                           Tk.Definition (Store, Id, Defined, Got);
                           if E.Is_Ok (Got)
                             and then Model_Runner.Framework.Lines_Of (R.Get (Defined, "requirements"))
                                        .Contains (Requirement)
                           then
                              if Tk.State_Of (Store, Id) in "rejected" | "cancelled" then
                                 Ended := To_Unbounded_String (Id);
                              else
                                 Live := True;
                              end if;
                           end if;
                        end;
                     end loop;
                     if not Live and then Ended /= Null_Unbounded_String then
                        Said := True;
                        Pres.Put_Note
                          (Screen, "cli.task.derived_ended",
                           [Loc.Named ("name", Requirement), Loc.Named ("value", To_String (Ended)),
                            Loc.Named ("detail", Tk.State_Of (Store, To_String (Ended))),
                            Loc.Named ("other", (if Tk.State_Of (Store, To_String (Ended)) = "rejected"
                                                 then "/task reconsider " else "/task reopen ")
                                                & To_String (Ended))]);
                     end if;
                  end;
               end loop;
               if not Said then
                  Pres.Put_Note (Screen, "cli.task.nothing_derived");
               end if;
            end;
         end if;
         for Id of Made loop
            Pres.Put_Message
              (Screen, "cli.task.derived",
               [Loc.Named ("name", Id),
                Loc.Named ("value", Model_Runner.Framework.Tasks.Component_Of_Task (Store, Id))]);
         end loop;
      end Derive;
   begin
      Status := E.Exit_Success;

      --  accept or reject of several tasks at once: each in turn, as if
      --  named alone, the worst of how they went the command's.
      --  all, for verify and integrate: each complete task verified again,
      --  each one whose work waits in a workspace taken in.
      if Action in "verify" | "integrate" and then Ada.Characters.Handling.To_Lower (Argument) = "all" then
         declare
            Each : Model_Runner.Framework.Name_Lists.Vector;
         begin
            S.Open_To_Read (Store, Directory, Outcome);
            if E.Is_Ok (Outcome) then
               for Id of Tk.List (Store, (if Action = "verify" then "complete" else "verification")) loop
                  if Action = "verify"
                    or else Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= ""
                  then
                     Each.Append (Id);
                  end if;
               end loop;
            end if;
            S.Close (Store);
            if Each.Is_Empty then
               Pres.Put_Note (Screen, (if Action = "verify" then "cli.task.verify_none"
                                       else "cli.task.integrate_none"));
               return;
            end if;
            for Id of Each loop
               declare
                  One  : Model_Runner.CLI.Project_Requests.Request := Item;
                  Went : Natural;
               begin
                  One.Action_Argument := T.To_Bounded (Id);
                  Run (One, Screen, Went);
                  Status := Natural'Max (Status, Went);
               end;
            end loop;
         end;
         return;
      end if;

      if Action in "accept" | "reject" and then Ada.Strings.Fixed.Index (Argument, " ") > 0
        and then (for all Word of Model_Runner.Framework.Lines_Of
                                    (Ada.Strings.Fixed.Translate
                                       (Argument, Ada.Strings.Maps.To_Mapping (" ", [1 => ASCII.LF])))
                  => Ada.Strings.Fixed.Index (Word, "TASK-") = Word'First)
      then
         --  Each one's way on held, and the first that can be worked said
         --  once at the end: not the last one's.
         Pres.Hold_Next_Steps (Screen, True);
         for Word of Model_Runner.Framework.Lines_Of
                       (Ada.Strings.Fixed.Translate
                          (Argument, Ada.Strings.Maps.To_Mapping (" ", [1 => ASCII.LF])))
         loop
            declare
               One  : Model_Runner.CLI.Project_Requests.Request := Item;
               Went : Natural;
            begin
               One.Action_Argument := T.To_Bounded (Word);
               Run (One, Screen, Went);
               Status := Natural'Max (Status, Went);
            end;
         end loop;
         Pres.Hold_Next_Steps (Screen, False);
         if Action = "accept" then
            S.Open_To_Read (Store, Directory, Outcome);
            if E.Is_Ok (Outcome) then
               --  One the document ticks as done: completed, not worked.
               for Word of Sorted_Words (Model_Runner.Framework.Lines_Of
                             (Ada.Strings.Fixed.Translate
                                (Argument, Ada.Strings.Maps.To_Mapping (" ", [1 => ASCII.LF]))))
               loop
                  if Tk.State_Of (Store, Word) = "accepted" and then Ticked_Done (Store, Word) /= "" then
                     Pres.Put_Note (Screen, "cli.next.complete_ticked",
                                    [Loc.Named ("name", Word), Loc.Named ("detail", Ticked_Done (Store, Word))]);
                  end if;
               end loop;
               --  Several ready: all of them, in turn, as /state says it.
               declare
                  Ready_Ones : Model_Runner.Framework.Name_Lists.Vector;
               begin
                  for Id of Tk.List (Store, "accepted") loop
                     if Tk.Ready (Store, Id).Ready then
                        Ready_Ones.Append (Id);
                     end if;
                  end loop;
                  if Natural (Ready_Ones.Length) > 1 then
                     Pres.Put_Note (Screen, "cli.next.work_all",
                                    [Loc.Named ("count", T.Image (Long_Long_Integer (Ready_Ones.Length))),
                                     Loc.Named ("name", Ready_Ones.First_Element)]);
                     S.Close (Store);
                     return;
                  end if;
               end;
               --  The lowest that can start, as /state names it.
               for Word of Sorted_Words (Model_Runner.Framework.Lines_Of
                             (Ada.Strings.Fixed.Translate
                                (Argument, Ada.Strings.Maps.To_Mapping (" ", [1 => ASCII.LF]))))
               loop
                  if Tk.Ready (Store, Word).Ready and then Ticked_Done (Store, Word) = "" then
                     Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Word)]);
                     exit;
                  end if;
               end loop;
            end if;
            S.Close (Store);
         end if;
         return;
      end if;

      S.Open (Store, Directory, Report, Outcome);

      --  Held by a run working on the task to cancel: that run is asked to
      --  stop it, which is all another process can do.
      if E."=" (Outcome.Code, E.Framework_Locked) and then Action = "cancel" and then Argument /= ""
      then
         S.Open_To_Read (Store, Directory, Outcome);
         if E.Is_Ok (Outcome) and then Tk.State_Of (Store, First_Word) = "running" then
            --  Asked once is asked: a second time says so.
            if Ada.Directories.Exists
                 (Hostkit.Fs.Join (Hostkit.Fs.Join (Hostkit.Fs.Join
                    (Directory, Model_Runner.Framework.State_Directory), "runtime"),
                    "stop." & First_Word))
            then
               Pres.Put_Note (Screen, "cli.task.stop_asked_already", [Loc.Named ("name", First_Word)]);
            else
               Model_Runner.Framework.Execution.Ask_To_Stop (Directory, First_Word);
               Pres.Put_Note (Screen, "cli.task.stop_asked", [Loc.Named ("name", First_Word)]);
            end if;
            S.Close (Store);
            return;
         end if;
         S.Close (Store);
         S.Open (Store, Directory, Report, Outcome);
      end if;

      --  Held by a run in progress, it can still be looked at.
      if E."=" (Outcome.Code, E.Framework_Locked)
        and then Action in "" | "list" | "show" | "plan" | "audit" | "context"
      then
         S.Open_To_Read (Store, Directory, Outcome);
         if E.Is_Ok (Outcome) then
            Pres.Put_Note (Screen, "cli.project.read_only");
         end if;
      end if;
      if E.Is_Error (Outcome) then
         Fail (Outcome);
         return;
      end if;

      --  What an interruption left is put right first, and said.
      if not S.Is_Read_Only (Store) then
         declare
            Said : Model_Runner.Framework.Name_Lists.Vector;
         begin
            Model_Runner.Framework.Work.Recover_On_Opening (Store, Report, Said, Outcome);
            for Line of Said loop
               --  In a session, what does not hold together was said as it opened.
               --  What does not hold together is said where it can be put
               --  right, not across a listing: in a session it was said as
               --  it opened, and state and check consistency say it.
               if not ((Pres.In_Session (Screen)
                        or else Action in "list" | "show" | "audit" | "plan" | "context" | "diff")
                       and then Ada.Strings.Fixed.Index (Line, "what does not hold together") = Line'First)
               then
                  Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
               end if;
            end loop;
            Outcome := E.Success;
         end;
      end if;

      --  Already where it is asked to go: said, and nothing done.
      if Action in "accept" | "reject" | "cancel" and then Argument /= ""
        and then Tk.State_Of (Store, Argument)
                   = (if Action = "accept" then "accepted"
                      elsif Action = "reject" then "rejected" else "cancelled")
      then
         Pres.Put_Note (Screen, "cli.intent.already",
                        [Loc.Named ("name", Argument),
                         Loc.Named ("value", Tk.State_Of (Store, Argument))]);
         S.Close (Store);
         return;
      elsif Action = "move" and then First_Word /= ""
        and then (After_First = "ready" or else Ada.Strings.Fixed.Head (After_First, 6) = "ready ")
      then
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "the state to move " & First_Word & " to");
         E.Add_Text (Outcome, "value", "ready");
         E.Add_Text (Outcome, "detail", "ready is no state of its own: a task is ready when it"
                     & " is accepted and waits for nothing; "
                     & (if Tk.State_Of (Store, First_Word) = "accepted"
                          and then not Tk.Ready (Store, First_Word).Reasons.Is_Empty
                        then First_Word & " is accepted, and "
                             & Tk.Ready (Store, First_Word).Reasons.First_Element
                        elsif Tk.State_Of (Store, First_Word) = "accepted"
                        then First_Word & " is ready already"
                        else "/task accept " & First_Word & " accepts it"));
         Fail (Outcome);
         S.Close (Store);
         return;
      end if;

      if Action = "help" then
         --  What task does is the help's to say.
         Pres.Put_Message (Screen, "cli.task.help_is");
         S.Close (Store);
         return;
      elsif Action = "list" then
         Show_List;
      elsif Action = "new" then
         Create;
      elsif Action = "accept" and then Argument /= ""
        and then Tk.State_Of (Store, Argument) in "cancelled" | "complete"
      then
         --  Ended: accepted again only by being reopened.
         Outcome := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Outcome, "name", Argument);
         E.Add_Text (Outcome, "value", Tk.State_Of (Store, Argument));
         E.Add_Text (Outcome, "expected", "accepted");
         E.Add_Text (Outcome, "detail", "an ended task is not accepted again; /task reopen "
                     & Argument & " makes it ready again");
         Fail (Outcome);
      elsif Action = "accept" and then Argument /= ""
        and then Tk.State_Of (Store, Argument) = "verification"
        and then Model_Runner.Framework.Workspaces.Active_For (Store, Argument) /= ""
      then
         --  Its work waits in a workspace: taken in, or given up to be done
         --  afresh -- not accepted over it.
         Outcome := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Outcome, "name", Argument);
         E.Add_Text (Outcome, "value", "verification");
         E.Add_Text (Outcome, "expected", "accepted");
         E.Add_Text (Outcome, "detail", "its work waits in "
                     & Model_Runner.Framework.Workspaces.Active_For (Store, Argument)
                     & "; /task integrate " & Argument & " takes it in, or /task integrate "
                     & Argument & " discard gives it up and accepts the task to be done afresh");
         Fail (Outcome);
      elsif Action = "accept" and then Argument /= "" and then Retired_Only (Argument) /= "" then
         --  It serves only what is retired: it could never become ready.
         Outcome := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Outcome, "name", Argument);
         E.Add_Text (Outcome, "value", Tk.State_Of (Store, Argument));
         E.Add_Text (Outcome, "expected", "accepted");
         E.Add_Text (Outcome, "detail", "it serves only " & Retired_Only (Argument) & ", so it would never be"
                     & " ready; /task reject " & Argument & " lets it go");
         Fail (Outcome);
      elsif Action = "accept" then
         Move ("accepted");
      elsif Action = "reject" then
         Move ("rejected");
      elsif Action = "cancel" then
         --  Whatever its state, what it holds goes with it: its agent,
         --  children, leases and workspace -- work waiting to be taken in
         --  only when that is said: task cancel ID anyway.
         if First_Word = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "task");
            Fail (Outcome);
         elsif After_First not in "" | "anyway" then
            Outcome := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Outcome, "value", After_First);
            Fail (Outcome);
         --  Not one it can go from: said before anything is asked.
         elsif Tk.State_Of (Store, First_Word) in "candidate" | "cancelled" | "complete" | "rejected" then
            Outcome := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Outcome, "name", First_Word);
            E.Add_Text (Outcome, "value", Tk.State_Of (Store, First_Word));
            E.Add_Text (Outcome, "expected", "cancelled");
            E.Add_Text (Outcome, "detail",
                        (if Tk.State_Of (Store, First_Word) = "candidate"
                         then "a candidate is not cancelled but rejected: /task reject " & First_Word
                         else "it is ended already"));
            Fail (Outcome);
         elsif After_First /= "anyway" and then Tk.State_Of (Store, First_Word) = "verification"
           and then Model_Runner.Framework.Workspaces.Active_For (Store, First_Word) /= ""
         then
            Outcome := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Outcome, "name", First_Word);
            E.Add_Text (Outcome, "value", "verification");
            E.Add_Text (Outcome, "expected", "cancelled");
            E.Add_Text (Outcome, "detail", "its work waits in "
                        & Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)
                        & " to be taken in, and cancelling gives it up; /task integrate "
                        & First_Word & " takes it in, /task cancel " & First_Word
                        & " anyway gives it up");
            Fail (Outcome);
         else
            declare
               Space : constant String :=
                 Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
               Lost  : constant Model_Runner.Framework.Name_Lists.Vector :=
                 (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
                  else Model_Runner.Framework.Workspaces.Changes (Store, Space));
            begin
               --  Work waiting to be taken in: asked, and kept aside.
               if Space /= "" and then not Lost.Is_Empty then
                  if not Confirmed ("cli.task.give_up_confirm", First_Word,
                                    Joined (Lost) & "? a copy is kept as given-up-" & First_Word & "-" & Space)
                  then
                     S.Close (Store);
                     return;
                  end if;
               --  Otherwise asked as /cancel asks, unless it asked already.
               elsif not Item.Cancel_Confirmed then
                  declare
                     Defined : R.Item;
                     Read    : E.Error_Info;
                  begin
                     Tk.Definition (Store, First_Word, Defined, Read);
                     if not Confirmed ("cli.project.cancel.confirm", First_Word,
                                       R.Get (Defined, "title") & ", " & Listed_State (First_Word)
                                       & Waiting_On_It (Store, First_Word))
                     then
                        S.Close (Store);
                        return;
                     end if;
                  end;
               end if;
               Model_Runner.Framework.Work.Cancel
                 (Store, First_Word, Outcome, Actor => Model_Runner.Framework.Transitions.User);
               if E.Is_Error (Outcome) then
                  Fail (Outcome);
               else
                  Pres.Put_Message
                    (Screen, "cli.task.moved",
                     [Loc.Named ("name", First_Word), Loc.Named ("value", "cancelled")]);
                  if Space /= "" then
                     Pres.Put_Note (Screen, "cli.task.workspace_given_up",
                                    [Loc.Named ("name", Space),
                                     Loc.Named ("detail", Given_Up_Detail (Space, Lost))]);
                  end if;
                  --  What became ready said before what to do next.
                  Change := S.No_Changes;
                  Commit;
                  Say_Became_Ready;
                  Say_Parts_Left (First_Word);
                  Say_Left_Waiting (First_Word);
               end if;
            end;
         end if;
      elsif Action = "audit" then
         if Needs_Task then
            for Line of Model_Runner.Framework.Work.Audit (Store, Argument) loop
               declare
                  Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ": ");
               begin
                  Pres.Put_Message
                    (Screen, "cli.task.field",
                     [Loc.Named ("name", Line (Line'First .. Colon - 1)),
                      Loc.Named ("value", Line (Colon + 2 .. Line'Last))]);
               end;
            end loop;
            --  Never worked: little to audit yet, and how it comes to have.
            if Never_Worked (Argument) and then Tk.State_Of (Store, Argument) = "accepted" then
               Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Argument)]);
            elsif Never_Worked (Argument) and then Tk.State_Of (Store, Argument) = "candidate" then
               Pres.Put_Note (Screen, "cli.next.accept_one_task", [Loc.Named ("name", Argument)]);
            end if;
         end if;
      elsif Action = "reopen" and then Argument /= "" and then Tk.State_Of (Store, Argument) = "rejected"
      then
         --  A rejected one is reconsidered, not reopened: said so.
         Outcome := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Outcome, "name", Argument);
         E.Add_Text (Outcome, "value", "rejected");
         E.Add_Text (Outcome, "expected", "accepted");
         E.Add_Text (Outcome, "detail", "a rejected task is reconsidered, not reopened: /task reconsider "
                     & Argument & " makes it a candidate again");
         Fail (Outcome);
      elsif Action = "reopen" and then Argument /= "" and then Tk.State_Of (Store, Argument) = "verification"
        and then Model_Runner.Framework.Workspaces.Active_For (Store, Argument) /= ""
      then
         --  Its work waits: the ways on that keep it, first.
         Outcome := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Outcome, "name", Argument);
         E.Add_Text (Outcome, "value", "verification");
         E.Add_Text (Outcome, "expected", "accepted");
         E.Add_Text (Outcome, "detail", "its work waits to be taken in; /task diff " & Argument & " shows it,"
                     & " /task integrate " & Argument & " takes it in, and /task integrate " & Argument
                     & " discard sets it aside, kept as a copy, and makes it ready to be worked again");
         Fail (Outcome);
      elsif Action = "reopen" and then Argument /= ""
        and then Tk.State_Of (Store, Argument) not in "cancelled" | "complete" | "failed" | "blocked" | ""
      then
         --  Reopened is what was ended: a candidate is accepted, and one
         --  open is open already.
         Outcome := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Outcome, "name", Argument);
         E.Add_Text (Outcome, "value", Tk.State_Of (Store, Argument));
         E.Add_Text (Outcome, "expected", "accepted");
         E.Add_Text (Outcome, "detail",
                     (if Tk.State_Of (Store, Argument) = "candidate"
                      then "a candidate is not reopened but accepted: /task accept " & Argument
                      else "only an ended, failed or blocked task is reopened; it is "
                           & Tk.State_Of (Store, Argument) & " and open"));
         Fail (Outcome);
      elsif Action = "reopen" then
         declare
            Was_Complete : constant Boolean := Tk.State_Of (Store, Argument) = "complete";
            Had_Changed  : constant String := Changed_By (Argument);
         begin
            --  Its work done before is not undone: said, so a run starts
            --  from it knowingly -- before what comes next is.
            --  Put back out of the project by a restore: gone, said so.
            if Was_Complete and then Had_Changed /= "" and then State_Field (Argument, "undone_by") /= "" then
               Pres.Put_Note (Screen, "cli.task.reopened_work_gone",
                              [Loc.Named ("name", Argument), Loc.Named ("detail", Had_Changed),
                               Loc.Named ("value", State_Field (Argument, "undone_by"))]);
            elsif Was_Complete and then Had_Changed /= "" then
               Pres.Put_Note (Screen, "cli.task.reopened_work_stays",
                              [Loc.Named ("name", Argument), Loc.Named ("detail", Had_Changed)]);
            end if;
            Move_Granted ("accepted", Model_Runner.Framework.Transitions.Reopen);
         end;
      elsif Action = "reconsider" and then Argument /= ""
        and then Tk.State_Of (Store, First_Word) not in "rejected" | ""
      then
         --  Reconsidered is what was rejected: said, with what this one takes.
         Outcome := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Outcome, "name", "the task to reconsider");
         E.Add_Text (Outcome, "value", First_Word);
         E.Add_Text (Outcome, "detail", "reconsider takes a rejected task back to a candidate; " & First_Word
                     & " is " & Moved_State (First_Word)
                     & (if Tk.State_Of (Store, First_Word) in "cancelled" | "complete" | "failed" | "blocked"
                        then " -- /task reopen " & First_Word & " takes it up again" else ""));
         Fail (Outcome);
      elsif Action = "reconsider" then
         Move_Granted ("candidate", Model_Runner.Framework.Transitions.Reconsideration);
         if Tk.State_Of (Store, First_Word) = "candidate" then
            Pres.Put_Note (Screen, "cli.next.accept_one_task", [Loc.Named ("name", First_Word)]);
         end if;
      elsif Action = "move" then
         --  To any state the project's lifecycle allows: move TASK STATE.
         if First_Word = "" or else After_First = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name",
                        (if First_Word = "" then "the task and the state: /task move TASK-ID STATE"
                         else "the state to move " & First_Word & " to: /task move " & First_Word
                              & " accepted, blocked or cancelled"));
            Fail (Outcome);
         elsif Tk.State_Of (Store, First_Word)
                 = Ada.Strings.Fixed.Head
                     (After_First & " ", Ada.Strings.Fixed.Index (After_First & " ", " ") - 1)
         then
            Pres.Put_Note (Screen, "cli.intent.already",
                           [Loc.Named ("name", First_Word),
                            Loc.Named ("value", Moved_State (First_Word))]);
         elsif Ada.Strings.Fixed.Head (After_First & " ", 8) in "ready   " | "waiting " then
            --  How /task list says accepted, not states of their own.
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the state to move " & First_Word & " to");
            E.Add_Text (Outcome, "value", After_First);
            E.Add_Text (Outcome, "detail", "ready and waiting are how /task list says accepted -- ready when"
                        & " nothing stands in its way; /task move " & First_Word & " accepted moves it there");
            Fail (Outcome);
         elsif Ada.Strings.Fixed.Head (After_First & " ", 8) = "stopped "
           or else Ada.Strings.Fixed.Head (After_First & " ", 13) = "to integrate "
           or else Ada.Strings.Fixed.Head (After_First & " ", 8) = "refused "
         then
            --  How /task list says a state, not one of its own: which.
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the state to move " & First_Word & " to");
            E.Add_Text (Outcome, "value", After_First);
            E.Add_Text (Outcome, "detail",
                        (if Ada.Strings.Fixed.Head (After_First & " ", 8) = "stopped "
                         then "stopped is how /task list says blocked by you; /task move " & First_Word
                              & " blocked stops it"
                         elsif Ada.Strings.Fixed.Head (After_First & " ", 8) = "refused "
                         then "refused is how /task list says accepted and kept from the work by its permissions;"
                              & " /task grant gives it what it lacks"
                         else "to integrate is how /task list says verification with its work waiting; /work "
                              & First_Word & " puts it there"));
            Fail (Outcome);
         elsif Ada.Strings.Fixed.Head (After_First & " ", 9) in "complete " | "running  " then
            --  The harness's moves: by work, or completed by hand.
            Outcome := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Outcome, "name", First_Word);
            E.Add_Text (Outcome, "value", Tk.State_Of (Store, First_Word));
            E.Add_Text (Outcome, "expected", Ada.Strings.Fixed.Trim (Ada.Strings.Fixed.Head (After_First, 8),
                                                                     Ada.Strings.Both));
            --  Failed or stopped, it is taken up again first.
            E.Add_Text (Outcome, "detail",
                        (if Tk.State_Of (Store, First_Word) in "failed" | "blocked"
                         then "/task accept " & First_Word & " takes it up again, and /work " & First_Word
                              & " then does it -- or /task complete " & First_Word & " once it is done by hand"
                         else "/work " & First_Word & " does it, or /task complete "
                              & First_Word & " once it is done by hand"));
            Fail (Outcome);
         elsif After_First = "cancelled"
           and then not Confirmed ("cli.project.cancel.confirm", First_Word,
                                   R.Get (Tk_Definition (First_Word), "title") & ", "
                                   & Listed_State (First_Word) & Waiting_On_It (Store, First_Word))
         then
            --  Asked as /task cancel asks, and kept on a no.
            null;
         elsif After_First = "cancelled" then
            --  Cancelled the way cancel does it: what it holds goes with it.
            Model_Runner.Framework.Work.Cancel
              (Store, First_Word, Outcome, Actor => Model_Runner.Framework.Transitions.User);
            if E.Is_Error (Outcome) then
               Fail (Outcome);
            else
               Pres.Put_Message
                 (Screen, "cli.task.moved",
                  [Loc.Named ("name", First_Word),
                   Loc.Named ("value", Model_Runner.Framework.State_Said (After_First))]);
               Say_Left_Waiting (First_Word);
            end if;
         else
            --  move TASK STATE WHY: the state, and why, which the move's
            --  event keeps.
            declare
               Rest  : constant String := After_First;
               Space : constant Natural := Ada.Strings.Fixed.Index (Rest, " ");
               Next  : constant String :=
                 (if Space = 0 then Rest else Rest (Rest'First .. Space - 1));
               Why   : constant String :=
                 (if Space = 0 then ""
                  else Ada.Strings.Fixed.Trim (Rest (Space + 1 .. Rest'Last), Ada.Strings.Both));
            begin
               --  Work waiting in a workspace is not given up unsaid.
               if Next = "failed" and then Why /= "anyway"
                 and then Tk.State_Of (Store, First_Word) = "verification"
                 and then Model_Runner.Framework.Workspaces.Active_For (Store, First_Word) /= ""
               then
                  Outcome := E.Make (E.Framework_Transition_Invalid);
                  E.Add_Text (Outcome, "name", First_Word);
                  E.Add_Text (Outcome, "value", "verification");
                  E.Add_Text (Outcome, "expected", "failed");
                  E.Add_Text (Outcome, "detail", "its work waits in "
                              & Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)
                              & " to be taken in; /task integrate " & First_Word
                              & " takes it in, /task move " & First_Word & " failed anyway gives it up");
                  Fail (Outcome);
                  S.Close (Store);
                  return;
               end if;
               declare
                  --  Given up with "anyway": said as what happened, and the
                  --  work it held named.
                  Space : constant String :=
                    Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
                  Lost  : constant Model_Runner.Framework.Name_Lists.Vector :=
                    (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
                     else Model_Runner.Framework.Workspaces.Changes (Store, Space));
                  Said  : constant String :=
                    (if Why = "anyway" and then Space /= ""
                     then "moved to " & Next & " by hand; " & Space & " is given up"
                     elsif Why = "anyway" then "moved to " & Next & " by hand"
                     else Why);
               begin
                  if Why = "anyway" and then Space /= "" and then not Lost.Is_Empty then
                     if not Confirmed ("cli.task.give_up_confirm", First_Word,
                                       Joined (Lost) & "? a copy is kept as given-up-" & First_Word & "-" & Space)
                     then
                        S.Close (Store);
                        return;
                     end if;
                  end if;
                  Tk.Move (Store, Change, First_Word, Next, Said, Status => Outcome,
                           Actor => Model_Runner.Framework.Transitions.User);
                  if E.Is_Ok (Outcome) and then Space /= "" then
                     Pres.Put_Note (Screen, "cli.task.workspace_given_up",
                                    [Loc.Named ("name", Space),
                                     Loc.Named ("detail", Given_Up_Detail (Space, Lost))]);
                  end if;
               end;
               if E.Is_Ok (Outcome) then
                  Commit;
               end if;
               if E.Is_Error (Outcome) then
                  Fail (Outcome);
               else
                  Pres.Put_Message
                    (Screen, "cli.task.moved",
                     [Loc.Named ("name", First_Word), Loc.Named ("value", Model_Runner.Framework.State_Said (Next))]);
                  --  Blocked by hand: how it goes on, and how to say why --
                  --  the why only where none was given.
                  if Next = "blocked" then
                     Pres.Put_Note (Screen, (if Why in "" | "anyway" then "cli.task.blocked_by_hand"
                                             else "cli.task.blocked_with_reason"),
                                    [Loc.Named ("name", First_Word)]);
                  end if;
               end if;
            end;
         end if;
      elsif Action = "depend" then
         Depend;
      elsif Action = "edit" then
         Edit;
      elsif Action = "link" then
         Link;
      elsif Action = "note" then
         Note;
      elsif Action in "grant" | "withhold" then
         Grant_Or_Withhold (Granting => Action = "grant");
      elsif Action = "rehome" then
         Rehome;
      elsif Action = "split" then
         Split_Task;
      elsif Action = "show" then
         Show;
      elsif Action = "context" then
         Show_Context;
      elsif Action = "verify" then
         Verify;
      elsif Action = "complete" then
         Complete;
      elsif Action = "integrate" then
         Integrate;
      elsif Action = "step" then
         Step;
      elsif Action = "kept" then
         --  The copies kept of work given up or overwritten: listed, put
         --  back, or removed.
         declare
            package Ws renames Model_Runner.Framework.Workspaces;
            Copies : constant Model_Runner.Framework.Name_Lists.Vector := Ws.Kept_Copies (Store);
            Verb   : constant String := First_Word;

            --  A task's identifier, as typed, is its copy where it has one.
            function Copy_Named (Given : String) return String is
               Upper : constant String := Ada.Characters.Handling.To_Upper (Given);
               Id    : constant String :=
                 (if Given /= "" and then (for all C of Given => C in '0' .. '9')
                  then "TASK-" & (if Given'Length >= 3 then Given else [1 .. 3 - Given'Length => '0'] & Given)
                  else Upper);
               Found : Model_Runner.Framework.Name_Lists.Vector;
            begin
               if Copies.Contains (Given) or else Ada.Strings.Fixed.Index (Id, "TASK-") /= Id'First then
                  return Given;
               end if;
               for One of Copies loop
                  if Ada.Strings.Fixed.Index (One & "-", "-" & Id & "-") > 0 then
                     Found.Append (One);
                  end if;
               end loop;
               --  Several: the newest, which is the first listed.
               return (if Found.Is_Empty then Given else Found.First_Element);
            end Copy_Named;
            Name   : constant String := Copy_Named (After_First);

            --  A task's copies, every one, where a task is named.
            function Copies_Of_Task return Model_Runner.Framework.Name_Lists.Vector is
               Upper : constant String := Ada.Characters.Handling.To_Upper (After_First);
               Id    : constant String :=
                 (if After_First /= "" and then (for all C of After_First => C in '0' .. '9')
                  then "TASK-" & (if After_First'Length >= 3 then After_First
                                  else [1 .. 3 - After_First'Length => '0'] & After_First)
                  else Upper);
               Found : Model_Runner.Framework.Name_Lists.Vector;
            begin
               if Ada.Strings.Fixed.Index (Id, "TASK-") = Id'First and then not Copies.Contains (After_First) then
                  for One of Copies loop
                     if Ada.Strings.Fixed.Index (One & "-", "-" & Id & "-") > 0 then
                        Found.Append (One);
                     end if;
                  end loop;
               end if;
               return Found;
            end Copies_Of_Task;
            --  What a copy holds, by how it was kept: an agent's work, or
            --  the project's own files from before something wrote over them.
            function Holds (One : String) return String is
               function Starts (Prefix : String) return Boolean
               is (Ada.Strings.Fixed.Index (One, Prefix) = One'First);
            begin
               return (if Starts ("given-up-") then "its agent's work, given up"
                       --  The only copy, until it is put back: then the project
                       --  holds them as well.
                       elsif Starts ("overwritten-") and then Ws.Was_Restored (Store, One)
                         and then Ws.Changed_Since_Kept (Store, One).Is_Empty
                       then "the project's files from before its agent wrote them -- put back, and the project"
                            & " holds them so: dropping it loses nothing"
                       elsif Starts ("overwritten-")
                       then "the project's files from before its agent wrote them -- the only copy of those"
                       elsif Starts ("replaced-given-up-") or else Starts ("replaced-overwritten-")
                         or else Starts ("replaced-replaced-") or else Starts ("before-restore-")
                       then "the project's files from before a copy was put back over them"
                       elsif Starts ("replaced-") then "the project's files its work replaced when it was taken in"
                       else "kept")
                 & (if Ws.Was_Restored (Store, One)
                      and then not (Starts ("overwritten-") and then Ws.Changed_Since_Kept (Store, One).Is_Empty)
                    then "; put back already" else "");
            end Holds;

            --  Copies, each with what it holds.
            function Said (Listed : Model_Runner.Framework.Name_Lists.Vector) return String is
               Text : Unbounded_String;
            begin
               for One of Listed loop
                  Append (Text, (if Text = Null_Unbounded_String then "" else "; ") & One & " (" & Holds (One) & ")");
               end loop;
               return To_String (Text);
            end Said;
         begin
            if Verb = "" then
               if Copies.Is_Empty then
                  Pres.Put_Note (Screen, "cli.task.kept_none");
               else
                  for One of Copies loop
                     Pres.Put_Message
                       (Screen, "cli.task.kept_line",
                        [Loc.Named ("name", One),
                         Loc.Named ("value", T.Image (Long_Long_Integer (Ws.Kept_Files (Store, One).Length))
                                             & (if Natural (Ws.Kept_Files (Store, One).Length) = 1 then " file"
                                                else " files")
                                             & ", " & Holds (One)),
                         Loc.Named ("detail", Joined (Ws.Kept_Files (Store, One)))]);
                  end loop;
                  Pres.Put_Note (Screen, "cli.next.kept");
               end if;
            elsif Verb = "list" and then Name = "" then
               --  /task kept list: the list, as /task kept alone gives it.
               if Copies.Is_Empty then
                  Pres.Put_Note (Screen, "cli.task.kept_none");
               else
                  for One of Copies loop
                     Pres.Put_Message
                       (Screen, "cli.task.kept_line",
                        [Loc.Named ("name", One),
                         Loc.Named ("value", T.Image (Long_Long_Integer (Ws.Kept_Files (Store, One).Length))
                                             & (if Natural (Ws.Kept_Files (Store, One).Length) = 1 then " file"
                                                else " files")
                                             & ", " & Holds (One)),
                         Loc.Named ("detail", Joined (Ws.Kept_Files (Store, One)))]);
                  end loop;
                  Pres.Put_Note (Screen, "cli.next.kept");
               end if;
            elsif Verb in "restore" | "drop" | "diff" and then Name = "" then
               --  Which copy: asked by name, the copies listed.
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name", "which copy: /task kept " & Verb & " NAME"
                           & (if Copies.Is_Empty then ", though none is kept"
                              else ", one of " & Joined (Copies)));
               Fail (Outcome);
            elsif Verb not in "restore" | "drop" | "diff" then
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "/task kept");
               E.Add_Text (Outcome, "value", Ada.Strings.Fixed.Trim (Argument, Ada.Strings.Both));
               E.Add_Text (Outcome, "detail", "/task kept lists the copies, /task kept diff NAME shows what one"
                           & " would change in the project, /task kept restore NAME puts one back, and /task kept"
                           & " drop NAME (or all) removes it");
               Fail (Outcome);
            elsif Verb = "diff" and then Natural (Copies_Of_Task.Length) > 1 then
               --  Several for one task: which, asked, as restore asks.
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "/task kept diff");
               E.Add_Text (Outcome, "value", After_First);
               E.Add_Text (Outcome, "detail", After_First & " has several kept copies: " & Said (Copies_Of_Task)
                           & " -- /task kept diff NAME shows the one named");
               Fail (Outcome);
            elsif Verb = "diff" and then Copies.Contains (Name) then
               --  What putting it back would change: the project's file
               --  beside the copy's, each.
               declare
                  Project : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
                  Where   : constant String := Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), Name);
                  Shown   : Natural := 0;
               begin
                  for File of Ws.Kept_Files (Store, Name) loop
                     --  Headed as /task diff heads a file.
                     Pres.Put_Message (Screen, "cli.task.diff_file",
                                       [Loc.Named ("path", File
                                                   & (if not Ada.Directories.Exists (Hostkit.Fs.Join (Project, File))
                                                      then " (new)" else ""))]);
                     Diff_Files (File, Hostkit.Fs.Join (Project, File), Hostkit.Fs.Join (Where, File));
                     Shown := Shown + 1;
                  end loop;
                  --  The same only where every file it holds is in the project
                  --  as it holds it: one the project lacks is a difference.
                  if Natural (Ws.Changed_Since_Kept (Store, Name).Length) = 0
                    and then (for all File of Ws.Kept_Files (Store, Name) =>
                                Ada.Directories.Exists (Hostkit.Fs.Join (Project, File)))
                  then
                     Pres.Put_Note (Screen, "cli.task.kept_diff_same", [Loc.Named ("name", Name)]);
                  else
                     Pres.Put_Note (Screen, "cli.next.kept_diffed", [Loc.Named ("name", Name)]);
                  end if;
               end;
            elsif Verb = "restore" and then Natural (Copies_Of_Task.Length) > 1 then
               --  A task with several: which is put back is asked, not
               --  guessed -- its work and the files it overwrote undo
               --  each other.
               Outcome := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Outcome, "name", "/task kept restore");
               E.Add_Text (Outcome, "value", After_First);
               E.Add_Text (Outcome, "detail", After_First & " has several kept copies: " & Said (Copies_Of_Task)
                           & " -- /task kept restore NAME puts the one named back");
               Fail (Outcome);
            elsif Verb = "drop" and then Natural (Copies_Of_Task.Length) > 1 then
               --  A task named: all its copies, each said with what it holds.
               if Confirmed ("cli.task.kept_drop_several_confirm", After_First, Said (Copies_Of_Task)) then
                  for One of Copies_Of_Task loop
                     Ws.Drop_Kept (Store, One, Outcome);
                     exit when E.Is_Error (Outcome);
                     Pres.Put_Message (Screen, "cli.task.kept_dropped", [Loc.Named ("name", One)]);
                  end loop;
                  if E.Is_Error (Outcome) then
                     Fail (Outcome);
                  end if;
               end if;
            elsif Verb = "drop" and then Name = "all" then
               if Copies.Is_Empty then
                  Pres.Put_Note (Screen, "cli.task.kept_none");
               elsif Confirmed ("cli.task.kept_drop_all_confirm", "all", Joined (Copies)) then
                  for One of Copies loop
                     Ws.Drop_Kept (Store, One, Outcome);
                     exit when E.Is_Error (Outcome);
                     Pres.Put_Message (Screen, "cli.task.kept_dropped", [Loc.Named ("name", One)]);
                  end loop;
                  if E.Is_Error (Outcome) then
                     Fail (Outcome);
                  end if;
               end if;
            elsif not Copies.Contains (Name) then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", "a kept copy called " & Name
                           & (if Copies.Is_Empty then "" else " (there are " & Joined (Copies) & ")"));
               Fail (Outcome);
            elsif Verb = "drop" then
               if Confirmed ("cli.task.kept_drop_confirm", Name,
                             Joined (Ws.Kept_Files (Store, Name)) & " (" & Holds (Name) & ")")
               then
                  Ws.Drop_Kept (Store, Name, Outcome);
                  if E.Is_Error (Outcome) then
                     Fail (Outcome);
                  else
                     Pres.Put_Message (Screen, "cli.task.kept_dropped", [Loc.Named ("name", Name)]);
                  end if;
               end if;
            else
               --  What the project holds otherwise now is said, and kept.
               declare
                  Changed : constant Model_Runner.Framework.Name_Lists.Vector := Ws.Changed_Since_Kept (Store, Name);
                  Aside   : constant String := Ws.Replaced_Copy (Store, Name);
                  --  A complete task's work among what it goes over: named,
                  --  as that task's work goes from the project.
                  --  The task whose work a file holds now: one overwritten-TASK-N
                  --  was kept from is N's; else the last other task that wrote it.
                  --  The copy's own task's work coming back is no loss.
                  Own_Task : constant String :=
                    (if Ada.Strings.Fixed.Index (Name, "TASK-") > 0
                     then Name (Ada.Strings.Fixed.Index (Name, "TASK-")
                                .. Ada.Strings.Fixed.Index (Name & "-", "-",
                                                            Ada.Strings.Fixed.Index (Name, "TASK-") + 5) - 1)
                     else "");
                  function Holder (File : String) return String is
                     Found : Unbounded_String;
                     --  By what the file holds, where a task's work is just that.
                     By_Content : constant String := Model_Runner.Framework.Work.Holder_Of (Store, File);
                  begin
                     if By_Content /= "" then
                        return (if By_Content = Own_Task then "" else By_Content);
                     elsif Ada.Strings.Fixed.Index (Name, "overwritten-") = Name'First then
                        return (if Model_Runner.Framework.Lines_Of (Changed_By_Lines (Own_Task)).Contains (File)
                                then Own_Task else "");
                     end if;
                     for Id of Tk.List (Store) loop
                        if Id /= Own_Task and then Tk.State_Of (Store, Id) not in "candidate" | "rejected"
                          and then Model_Runner.Framework.Lines_Of (Changed_By_Lines (Id)).Contains (File)
                        then
                           Found := To_Unbounded_String (Id);
                        end if;
                     end loop;
                     return To_String (Found);
                  end Holder;
                  function Whose_Work return String is
                     Said : Unbounded_String;
                  begin
                     for File of Changed loop
                        if Holder (File) /= "" then
                           Append (Said, " " & File & " holds " & Holder (File) & "'s work ("
                                   & Moved_State (Holder (File)) & "): putting this back undoes it.");
                        end if;
                     end loop;
                     return To_String (Said);
                  end Whose_Work;
                  Over    : constant String :=
                    (if Natural (Changed.Length) = 0 then ""
                     else " The project's " & Joined (Changed)
                          & (if Natural (Changed.Length) = 1 then " differs" else " differ")
                          & " from these now, and " & (if Natural (Changed.Length) = 1 then "is" else "are")
                          & " kept first as " & Aside & "." & Whose_Work);

                  --  Each file, said as going over the project's or added.
                  function Files_Said return String is
                     Project : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
                     Text    : Unbounded_String;
                  begin
                     for File of Ws.Kept_Files (Store, Name) loop
                        Append (Text, (if Text = Null_Unbounded_String then "" else ", ") & File
                                & (if Ada.Directories.Exists (Hostkit.Fs.Join (Project, File))
                                   then " (over the project's)" else " (added: the project has none)"));
                     end loop;
                     return To_String (Text);
                  end Files_Said;
               begin
                  --  The project holds it as kept already: nothing to put back.
                  if Natural (Changed.Length) = 0
                    and then (for all File of Ws.Kept_Files (Store, Name) =>
                                Ada.Directories.Exists
                                  (Hostkit.Fs.Join (Ada.Directories.Containing_Directory (S.Root (Store)), File)))
                  then
                     Pres.Put_Note (Screen, "cli.task.kept_diff_same", [Loc.Named ("name", Name)]);
                  elsif Confirmed ("cli.task.kept_restore_confirm", Name, Files_Said & "?" & Over)
                  then
                     Ws.Restore_Kept (Store, Name, Outcome);
                     if E.Is_Error (Outcome) then
                        Fail (Outcome);
                     else
                        Pres.Put_Message (Screen, "cli.task.kept_restored",
                                          [Loc.Named ("name", Name),
                                           Loc.Named ("detail", Joined (Ws.Kept_Files (Store, Name)))]);
                        if Natural (Changed.Length) > 0 then
                           Pres.Put_Note (Screen, "cli.task.kept_replaced",
                                          [Loc.Named ("name", Aside),
                                           Loc.Named ("detail", Joined (Changed))]);
                        end if;
                        --  What the task it came from is now, and the way on.
                        declare
                           At_Task : constant Natural := Ada.Strings.Fixed.Index (Name, "TASK-");
                           Stop    : Natural := At_Task + 5;
                        begin
                           if At_Task > 0 then
                              while Stop <= Name'Last and then Name (Stop) in '0' .. '9' loop
                                 Stop := Stop + 1;
                              end loop;
                              declare
                                 Owner : constant String := Name (At_Task .. Stop - 1);
                                 State : constant String := Tk.State_Of (Store, Owner);
                                 --  Whether what was put back is the task's own
                                 --  work: each replaced- swaps it with what the
                                 --  project held, given up and overwritten copies
                                 --  holding the work and the project's files.
                                 function Holds_Work return Boolean is
                                    Rest  : Unbounded_String := To_Unbounded_String (Name);
                                    Swaps : Natural := 0;
                                 begin
                                    loop
                                       if Length (Rest) > 9 and then Slice (Rest, 1, 9) = "replaced-" then
                                          Rest := Unbounded_Slice (Rest, 10, Length (Rest));
                                       elsif Length (Rest) > 15 and then Slice (Rest, 1, 15) = "before-restore-"
                                       then
                                          Rest := Unbounded_Slice (Rest, 16, Length (Rest));
                                       else
                                          exit;
                                       end if;
                                       Swaps := Swaps + 1;
                                    end loop;
                                    return (if Index (Rest, "given-up-") = 1 then Swaps mod 2 = 0
                                            elsif Index (Rest, "overwritten-") = 1 then Swaps mod 2 = 1
                                            --  replaced-TASK: what its work replaced.
                                            else Swaps mod 2 = 0);
                                 end Holds_Work;
                                 Undo  : constant Boolean := not Holds_Work;
                              begin
                                 --  Its work gone from the project: kept in its
                                 --  history, so nothing there is credited to it.
                                 if Undo and then State /= "" then
                                    Model_Runner.Framework.Work.Note_Undone (Store, Owner, Name);
                                 --  Its work back in the project: undone no more,
                                 --  and the files as they are now its.
                                 elsif State /= "" then
                                    Model_Runner.Framework.Work.Note_Undone (Store, Owner, "");
                                    Model_Runner.Framework.Work.Note_Restored
                                      (Store, Owner, Ws.Kept_Files (Store, Name));
                                 end if;
                                 --  Work a restore brings back of another task --
                                 --  what its file holds is that task's again --
                                 --  undone no more; work it puts out, undone.
                                 for File of Ws.Kept_Files (Store, Name) loop
                                    declare
                                       Now_Holder : constant String :=
                                         Model_Runner.Framework.Work.Holder_Of (Store, File);
                                    begin
                                       for Other of Tk.List (Store) loop
                                          if Other /= Owner and then Tk.State_Of (Store, Other) = "complete"
                                            and then Model_Runner.Framework.Lines_Of (Changed_By_Lines (Other))
                                                       .Contains (File)
                                          then
                                             if Now_Holder = Other then
                                                Model_Runner.Framework.Work.Note_Undone (Store, Other, "");
                                             elsif Now_Holder /= "" and then State_Field (Other, "undone_by") = ""
                                             then
                                                Model_Runner.Framework.Work.Note_Undone (Store, Other, Name);
                                             end if;
                                          end if;
                                       end loop;
                                    end;
                                 end loop;
                                 if State /= "" then
                                    Pres.Put_Note
                                      (Screen, "cli.task.after_restore",
                                       [Loc.Named ("name", Owner), Loc.Named ("value", Listed_State (Owner)),
                                        Loc.Named ("detail",
                                                   (if Undo and then State = "complete"
                                                    then "its work is undone in the project now: /task reopen "
                                                         & Owner & " takes it up again"
                                                    --  Taken up already: worked again, not accepted.
                                                    elsif Undo and then State = "accepted"
                                                    then "its work is undone in the project now: /work "
                                                         & Owner & " does it again"
                                                    elsif Undo
                                                    then "its work is undone in the project now: /task accept "
                                                         & Owner & " tries it again"
                                                    elsif State in "failed" | "blocked" | "accepted"
                                                    then "its work is in the project now: /task complete "
                                                         & Owner & " takes it as done, its checks passing"
                                                    else "its work is in the project now"))]);
                                 end if;
                              end;
                           end if;
                        end;
                     end if;
                  end if;
               end;
            end if;
         end;
      elsif Action = "diff" then
         --  What a task's work waiting in its workspace changes: each file,
         --  as diff -u shows the project's beside the workspace's.
         declare
            Space : constant String :=
              (if First_Word = "" then "" else Model_Runner.Framework.Workspaces.Active_For (Store, First_Word));
            Place : Model_Runner.Framework.Workspaces.Workspace;
            Read  : E.Error_Info;
         begin
            if not Needs_Task then
               null;
            --  Its work in the project, uncommitted: shown, complete or
            --  reopened since -- what it wrote is there all the same.
            elsif Space = "" and then Tk.State_Of (Store, First_Word) in "complete" | "accepted" | "failed" | "blocked"
              and then Changed_By (First_Word) /= ""
              and then Shown_Uncommitted (First_Word)
            then
               --  Its state is in what heads it: no more to say.
               null;
            elsif Space = "" then
               --  Nothing waits: said as a state, with where its work is.
               Pres.Put_Note
                 (Screen, "cli.task.diff_none",
                  [Loc.Named ("name", First_Word), Loc.Named ("value", Moved_State (First_Word)),
                   Loc.Named ("detail",
                              --  Waiting on something: that, not a /work refused.
                              (if Tk.State_Of (Store, First_Word) = "accepted"
                                 and then not Tk.Ready (Store, First_Word).Ready
                                 and then not Tk.Ready (Store, First_Word).Reasons.Is_Empty
                               then "nothing of it is there to show, and it cannot be worked yet: "
                                    & Tk.Ready (Store, First_Word).Reasons.First_Element
                                    & "; /task plan says what comes first"
                               elsif Tk.State_Of (Store, First_Word) in "candidate" | "accepted" | "ready"
                                 and then Never_Worked (First_Word)
                               then "it has not been worked on yet; /work " & First_Word & " does it"
                               elsif Tk.State_Of (Store, First_Word) in "candidate" | "accepted" | "ready"
                                 and then Kept_For (First_Word) /= ""
                               then "its last attempt's workspace was given up, what it changed kept in "
                                    & Kept_For (First_Word) & "; /task kept diff " & Kept_For (First_Word)
                                    & " shows it, and /work " & First_Word & " does it again"
                               elsif Tk.State_Of (Store, First_Word) in "candidate" | "accepted" | "ready"
                                 and then Changed_By (First_Word) = ""
                               then "no attempt of it changed anything; /work " & First_Word & " does it again"
                               elsif Tk.State_Of (Store, First_Word) in "candidate" | "accepted" | "ready"
                               then "what its last attempt wrote -- " & Changed_By (First_Word)
                                    & " -- is in the project itself; /work " & First_Word & " does it again"
                               elsif Tk.State_Of (Store, First_Word) = "complete" and then Changed_By (First_Word) /= ""
                               then "its work is in the project already, and committed: git log -p -- "
                                    & Spaced (Changed_By (First_Word))
                                    & " shows what it changed"
                               elsif Tk.State_Of (Store, First_Word) = "complete"
                               then "its work is in the project already"
                                    & (if Model_Runner.Framework.Git.Status_Of
                                            (Ada.Directories.Containing_Directory (S.Root (Store))).Found
                                       then "; /git shows what changed"
                                       else "; with no repository there is nothing to compare it with -- git init"
                                            & " in the project lets /git and /task diff show what tasks change")
                               elsif Kept_For (First_Word) /= ""
                               then "its workspace was given up, what it changed kept in " & Kept_For (First_Word)
                                    & "; /task kept diff " & Kept_For (First_Word) & " shows it, and /task kept"
                                    & " restore " & Kept_For (First_Word) & " puts it in the project"
                               --  Ended, never worked: nothing of it anywhere.
                               elsif Never_Worked (First_Word)
                               then "it was never worked on, so nothing of it is anywhere"
                               --  Put back out: undone, by which copy.
                               elsif State_Field (First_Word, "undone_by") /= ""
                               then "its work was undone when " & State_Field (First_Word, "undone_by")
                                    & " was put back: nothing of it is in the project"
                               --  Worked in a workspace never taken in: nothing reached here.
                               elsif State_Field (First_Word, "current_workspace") /= ""
                                 and then State_Field (First_Word, "taken_in") = ""
                               then "its workspace " & State_Field (First_Word, "current_workspace")
                                    & " was given up and never taken in: nothing of it reached the project"
                               --  The files said where it names them; /git only
                               --  where there is a repository to ask.
                               else (if Changed_By (First_Word) /= ""
                                     then "what it changed -- " & Changed_By (First_Word)
                                          & " -- is in the project itself"
                                     else "any work it did is in the project itself")
                                    & (if not Model_Runner.Framework.Git.Status_Of
                                                (Ada.Directories.Containing_Directory (S.Root (Store))).Found
                                       then ""
                                       --  Committed since -- none of its files among what
                                       --  is uncommitted: the log holds it, not /git.
                                       elsif Changed_By (First_Word) /= ""
                                         and then not (for some Change of Model_Runner.Framework.Git.Status_Of
                                                                            (Ada.Directories.Containing_Directory
                                                                               (S.Root (Store))).Changes =>
                                                         (for some File of Model_Runner.Framework.Lines_Of
                                                                             (Ada.Strings.Fixed.Translate
                                                                                (Changed_By (First_Word),
                                                                                 Ada.Strings.Maps.To_Mapping
                                                                                   (",", [1 => ASCII.LF]))) =>
                                                            Ada.Strings.Fixed.Index
                                                              (Change, Ada.Strings.Fixed.Trim
                                                                         (File, Ada.Strings.Both)) > 0))
                                       then "; it is committed: git log -p -- "
                                            & Spaced (Changed_By (First_Word)) & " shows it"
                                       else "; /git shows what changed")))]);
            else
               Model_Runner.Framework.Workspaces.Read (Store, Space, Place, Read);
               declare
                  Project : constant String := Ada.Directories.Containing_Directory (S.Root (Store));
                  Differ  : constant String := Hostkit.Process.Locate ("diff");
                  Output  : constant String :=
                    Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "diff-" & First_Word);
                  --  Files the project made or changed too: taking it in
                  --  meets them as a conflict.
                  Clashing : Model_Runner.Framework.Name_Lists.Vector;
               begin
                  --  Nothing changed: said, with what finishes it.
                  if Model_Runner.Framework.Workspaces.Changes (Store, Space).Is_Empty then
                     Pres.Put_Message (Screen, "cli.task.diff_empty", [Loc.Named ("name", First_Word)]);
                  end if;
                  for File of Model_Runner.Framework.Workspaces.Changes (Store, Space) loop
                     declare
                        --  What the work changed: the file as the workspace
                        --  began from, beside the workspace's -- not the
                        --  project's now, which may have moved on since.
                        Base   : constant String :=
                          Hostkit.Fs.Join (Hostkit.Fs.Join (Ada.Directories.Containing_Directory
                                                              (To_String (Place.Path)), "base"), File);
                        Mine   : constant String := Hostkit.Fs.Join (Project, File);
                        Theirs : constant String := Hostkit.Fs.Join (To_String (Place.Path), File);
                        From   : constant String :=
                          (if Ada.Directories.Exists (Base) then Base
                           elsif Ada.Directories.Exists (Mine) then Mine
                           else Hostkit.Fs.Null_Device);
                        function Same (Left, Right : String) return Boolean is
                           function Whole (Path : String) return String is
                              use Ada.Streams.Stream_IO;
                              File : File_Type;
                           begin
                              Open (File, In_File, Path);
                              declare
                                 Text : String (1 .. Natural (Size (File)));
                              begin
                                 String'Read (Stream (File), Text);
                                 Close (File);
                                 return Text;
                              end;
                           end Whole;
                        begin
                           return Ada.Directories."=" (Ada.Directories.Size (Left), Ada.Directories.Size (Right))
                             and then Whole (Left) = Whole (Right);
                        exception
                           when others =>
                              return False;
                        end Same;
                     begin
                        Pres.Put_Message
                          (Screen, "cli.task.diff_file",
                           [Loc.Named ("path", File
                                       & (if not Ada.Directories.Exists (Theirs) then " (removed)"
                                          elsif not Ada.Directories.Exists (From) then " (new)"
                                          else ""))]);
                        --  The project's copy moved on as well: said, as what
                        --  taking it in will check.
                        if From = Base and then Ada.Directories.Exists (Mine) and then not Same (Base, Mine) then
                           --  Said as taking it in will find it: joined, or a conflict.
                           if Model_Runner.Framework.Workspaces.Joins_Cleanly (Store, Space, File) then
                              Pres.Put_Note (Screen, "cli.task.diff_project_moved",
                                             [Loc.Named ("path", File), Loc.Named ("name", First_Word)]);
                           else
                              Pres.Put_Note (Screen, "cli.task.diff_project_clashes",
                                             [Loc.Named ("path", File), Loc.Named ("name", First_Word)]);
                              Clashing.Append (File);
                           end if;
                        --  Made in the project too since the work began: what
                        --  the diff shows taken away is the project's own.
                        elsif From = Mine and then Ada.Directories.Exists (Theirs) then
                           Pres.Put_Note (Screen, "cli.task.diff_project_made",
                                          [Loc.Named ("path", File), Loc.Named ("name", First_Word)]);
                           Clashing.Append (File);
                        end if;
                        --  The project's change since: by which task, where one
                        --  took it in.
                        if (From = Mine or else not Same (Base, Mine)) and then Ada.Directories.Exists (Mine)
                          and then Taken_In_By (File, First_Word) /= ""
                        then
                           Pres.Put_Note (Screen, "cli.task.diff_changed_by",
                                          [Loc.Named ("path", File),
                                           Loc.Named ("name", Taken_In_By (File, First_Word))]);
                        end if;
                        --  Another task's work waiting to be taken in changes
                        --  it too: the second of the two taken in meets the first.
                        for Other of Tk.List (Store, "verification") loop
                           if Other /= First_Word
                             and then Model_Runner.Framework.Workspaces.Active_For (Store, Other) /= ""
                             and then Model_Runner.Framework.Workspaces.Changes
                                        (Store, Model_Runner.Framework.Workspaces.Active_For (Store, Other))
                                        .Contains (File)
                           then
                              Pres.Put_Note (Screen, "cli.task.diff_other_waiting",
                                             [Loc.Named ("path", File), Loc.Named ("name", Other)]);
                           end if;
                        end loop;
                     end;
                     if Differ /= "" then
                        declare
                           Args : Hostkit.String_Vectors.Vector;
                           Ran  : Hostkit.Process.Process_Outcome;
                           Base : constant String :=
                             Hostkit.Fs.Join (Hostkit.Fs.Join (Ada.Directories.Containing_Directory
                                                                 (To_String (Place.Path)), "base"), File);
                           Mine : constant String :=
                             (if Ada.Directories.Exists (Base) then Base
                              else Hostkit.Fs.Join (Project, File));
                           Theirs : constant String := Hostkit.Fs.Join (To_String (Place.Path), File);
                        begin
                           --  Named as the project names the file, not by the
                           --  places it was compared from, and without times.
                           Args.Append (To_Unbounded_String ("-u"));
                           Args.Append (To_Unbounded_String ("--label"));
                           Args.Append (To_Unbounded_String
                                          (if Ada.Directories.Exists (Mine) then "a/" & File else "(new)"));
                           Args.Append (To_Unbounded_String ("--label"));
                           Args.Append (To_Unbounded_String
                                          (if Ada.Directories.Exists (Theirs) then "b/" & File else "(removed)"));
                           Args.Append (To_Unbounded_String
                                          (if Ada.Directories.Exists (Mine) then Mine
                                           else Hostkit.Fs.Null_Device));
                           Args.Append (To_Unbounded_String
                                          (if Ada.Directories.Exists (Theirs) then Theirs
                                           else Hostkit.Fs.Null_Device));
                           --  In the program's own words, not the host's
                           --  language: its notes are read beside this one's.
                           declare
                              Had    : constant Boolean := Ada.Environment_Variables.Exists ("LC_ALL");
                              Before : constant String :=
                                (if Had then Ada.Environment_Variables.Value ("LC_ALL") else "");
                           begin
                              Ada.Environment_Variables.Set ("LC_ALL", "C");
                              Ran := Hostkit.Process.Run_Captured
                                (Differ, Args, Stdin_Path => Hostkit.Fs.Null_Device,
                                 Stdout_Path => Output, Stderr_Path => Output, Timeout_Ms => 20_000);
                              if Had then
                                 Ada.Environment_Variables.Set ("LC_ALL", Before);
                              else
                                 Ada.Environment_Variables.Clear ("LC_ALL");
                              end if;
                           end;
                           pragma Unreferenced (Ran);
                           declare
                              File_In : Ada.Text_IO.File_Type;
                           begin
                              Ada.Text_IO.Open (File_In, Ada.Text_IO.In_File, Output);
                              while not Ada.Text_IO.End_Of_File (File_In) loop
                                 Pres.Put_Diff_Line (Screen, Ada.Text_IO.Get_Line (File_In));
                              end loop;
                              Ada.Text_IO.Close (File_In);
                              Ada.Directories.Delete_File (Output);
                           exception
                              when others =>
                                 if Ada.Text_IO.Is_Open (File_In) then
                                    Ada.Text_IO.Close (File_In);
                                 end if;
                           end;
                        end;
                     end if;
                  end loop;
                  --  A conflict found already: settled before it is taken in.
                  if not Model_Runner.Framework.Workspaces.Conflict_Files (Store, Space, Unsettled_Only => True)
                           .Is_Empty
                  then
                     --  Said as /task integrate says it.
                     Pres.Put_Note (Screen, "cli.next.conflict",
                                    [Loc.Named ("name", First_Word),
                                     Loc.Named ("path", To_String (Place.Path)),
                                     Loc.Named ("detail", In_Conflict (Store, Space, To_String (Place.Path)))]);
                  elsif not Clashing.Is_Empty then
                     Pres.Put_Note (Screen, "cli.next.integrate_will_conflict",
                                    [Loc.Named ("name", First_Word), Loc.Named ("detail", Joined (Clashing))]);
                  else
                     Pres.Put_Note (Screen, "cli.next.integrate_diffed", [Loc.Named ("name", First_Word)]);
                  end if;
               end;
            end if;
         end;
      elsif Action = "plan" then
         Show_Plan;
      elsif Action = "derive" then
         Derive;
      else
         --  Nothing the command does: said, not taken for another -- with
         --  the action it most likely meant.
         declare
            Actions : Model_Runner.Framework.Name_Lists.Vector;
         begin
            for One of Model_Runner.Framework.Lines_Of
              ("list" & ASCII.LF & "new" & ASCII.LF & "accept" & ASCII.LF & "reject" & ASCII.LF
               & "cancel" & ASCII.LF & "move" & ASCII.LF & "edit" & ASCII.LF & "link" & ASCII.LF & "depend" & ASCII.LF
               & "note" & ASCII.LF & "grant" & ASCII.LF & "withhold" & ASCII.LF
               & "split" & ASCII.LF & "rehome" & ASCII.LF & "reopen" & ASCII.LF & "reconsider"
               & ASCII.LF & "complete" & ASCII.LF & "verify" & ASCII.LF & "diff" & ASCII.LF & "integrate" & ASCII.LF
               & "show" & ASCII.LF & "audit" & ASCII.LF & "derive" & ASCII.LF & "plan" & ASCII.LF & "kept")
            loop
               Actions.Append (One);
            end loop;
            Outcome := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Outcome, "value",
                        Action
                        & (if Model_Runner.Framework.Nearest (Action, Actions) /= ""
                           then "; did you mean /task " & Model_Runner.Framework.Nearest (Action, Actions)
                                & "?"
                           else "")
                        & " (/help task lists what /task does)");
            Fail (Outcome);
         end;
      end if;
      --  What a change to the tasks makes of the requirements they serve,
      --  judged before the command ends, however the change was made.
      if Action not in "list" | "show" | "audit" | "plan" | "context" | "help" | "diff"
        and then not S.Is_Read_Only (Store)
      then
         Change := S.No_Changes;
         Commit;
      end if;
      Say_Became_Ready;
      S.Close (Store);
   end Run;

   -------------------
   -- Waiting_On_It --
   -------------------

   function Waiting_On_It (Store : Model_Runner.Framework.Stores.Store; Id : String) return String is
      Waiting : Unbounded_String;
      Count   : Natural := 0;
   begin
      for Other of Tk.List (Store) loop
         declare
            Defined : R.Item;
            Read    : E.Error_Info;
         begin
            Tk.Definition (Store, Other, Defined, Read);
            if E.Is_Ok (Read) and then Tk.State_Of (Store, Other) not in "complete" | "cancelled" | "rejected"
              and then Model_Runner.Framework.Lines_Of
                         (Ada.Strings.Fixed.Translate (R.Get (Defined, "depends_on"),
                                                       Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                         .Contains (Id)
            then
               Append (Waiting, (if Waiting = Null_Unbounded_String then "" else ", ") & Other);
               Count := Count + 1;
            end if;
         end;
      end loop;
      declare
         --  Its parts still open, said too: ending it leaves them.
         Parts : Unbounded_String;
      begin
         for Child of Tk.Children (Store, Id) loop
            if Tk.State_Of (Store, Child) not in "complete" | "cancelled" | "rejected" then
               Append (Parts, (if Parts = Null_Unbounded_String then "" else ", ") & Child);
            end if;
         end loop;
         return (if Count = 0 then "" else "; " & To_String (Waiting) & (if Count = 1 then " waits" else " wait")
                 & " on it")
           & (if Parts = Null_Unbounded_String then ""
              else "; its parts " & To_String (Parts) & " stay open -- /task cancel each lets it go");
      end;
   end Waiting_On_It;

end Model_Runner.CLI.Tasks;
