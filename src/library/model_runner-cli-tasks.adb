with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.CLI.Choosers;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Work;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
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

   ---------
   -- Run --
   ---------

   procedure Run
     (Item   : Model_Runner.CLI.Options.Command;
      Screen : in out Model_Runner.Presentation.Console;
      Status : out Natural)
   is
      Directory : constant String :=
        (if T.Is_Empty (Item.Project_Directory) then "."
         else T.To_String (Item.Project_Directory));
      Action    : constant String :=
        (if T.Is_Empty (Item.Action) then "list"
         else T.To_String (Item.Action));
      Argument  : constant String := T.To_String (Item.Action_Argument);

      Interactive : constant Boolean := Choosers.Is_Available;

      Store   : S.Store;
      Report  : S.Recovery_Report;
      Outcome : E.Error_Info;
      Change  : S.Transaction;

      --  A profile as the configuration writes it.
      function Profile_Text (Name : String) return String is
         Config : R.Item;
         Read   : E.Error_Info;
      begin
         Model_Runner.Framework.Configurations.Read (Store, Config, Read);
         return R.Get (Config, "profile." & Name);
      end Profile_Text;

      procedure Fail (Condition : E.Error_Info) is
      begin
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
      end Fail;

      --  Commit a change, then say which tasks it made ready.
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
            for Id of Became loop
               Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
            end loop;
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
         return True;
      end Needs_Task;

      --  The tasks, narrowed by what was given as NAME=VALUE: state (ready
      --  among them, derived), kind, component, requirement, origin and
      --  parent.
      procedure Show_List is
         Listed : constant Model_Runner.Framework.Name_Lists.Vector :=
           Tk.List (Store);
         Shown  : Natural := 0;

         function Wanted (Name : String) return String is
         begin
            for Index in 1 .. Item.Input_Count loop
               declare
                  Pair : constant String := T.To_String (Item.Inputs (Index));
                  Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
               begin
                  if Cut > Pair'First and then Pair (Pair'First .. Cut - 1) = Name then
                     return Pair (Cut + 1 .. Pair'Last);
                  end if;
               end;
            end loop;
            return "";
         end Wanted;
      begin
         for Id of Listed loop
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               State   : constant String := Tk.State_Of (Store, Id);
               Shown_State : constant String :=
                 (if State = "accepted" and then Tk.Ready (Store, Id).Ready then "ready"
                  else State);

               function Fits (Name, Held : String) return Boolean
               is (Wanted (Name) = "" or else Wanted (Name) = Held);
            begin
               Tk.Definition (Store, Id, Defined, Read);
               if (Fits ("state", Shown_State)
                   or else (Wanted ("state") = "accepted" and then State = "accepted"))
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
                  Pres.Put_Message
                    (Screen, "cli.task.item",
                     [Loc.Named ("name", Id),
                      Loc.Named ("value", Shown_State),
                      Loc.Named ("detail", R.Get (Defined, "title"))]);
               end if;
            end;
         end loop;
         if Shown = 0 then
            Pres.Put_Note (Screen, "cli.task.none");
         end if;
      end Show_List;

      procedure Create is
         Fields : Tk.Field_Map;
         Id     : Unbounded_String;
      begin
         for Index in 1 .. Item.Input_Count loop
            declare
               Pair : constant String := T.To_String (Item.Inputs (Index));
            begin
               for Cut in Pair'Range loop
                  if Pair (Cut) = '=' then
                     Fields.Include
                       (Pair (Pair'First .. Cut - 1), Pair (Cut + 1 .. Pair'Last));
                     exit;
                  end if;
               end loop;
            end;
         end loop;
         if Argument /= "" then
            Fields.Include ("title", Argument);
         end if;

         --  On a terminal, what the kind requires and was not given is
         --  asked for, the kind first.
         loop
            Tk.Create (Store, Change, Fields, "user", "", Id, Outcome);
            exit when E.Is_Ok (Outcome)
              or else not Interactive
              or else Outcome.Code not in E.Framework_Input_Missing
                                        | E.Framework_Task_Kind_Unknown;

            if Outcome.Code = E.Framework_Task_Kind_Unknown then
               declare
                  Known : constant Model_Runner.Framework.Name_Lists.Vector :=
                    Tk.Kinds (Store);
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
                  exit when Taken = 0;
                  Fields.Include ("kind", Known (Taken));
               end;
            else
               declare
                  Wanted : Model_Runner.Framework.Name_Lists.Vector :=
                    Tk.Required_Fields
                      (Store, (if Fields.Contains ("kind")
                               then Fields ("kind") else ""));
                  Typed  : Unbounded_String;
                  Got    : Boolean;
               begin
                  Wanted.Prepend ("title");
                  for Field of Wanted loop
                     if not Fields.Contains (Field)
                       or else Ada.Strings.Fixed.Trim (Fields (Field), Ada.Strings.Both) = ""
                     then
                        Choosers.Ask (Screen, Field, "", "", "", Typed, Got);
                        if not Got then
                           Pres.Put_Note (Screen, "cli.task.cancelled");
                           Status := E.Exit_Cancelled;
                           Outcome := E.Success;
                           return;
                        end if;
                        Fields.Include (Field, To_String (Typed));
                     end if;
                  end loop;
               end;
            end if;
         end loop;

         if E.Is_Error (Outcome) then
            Fail (Outcome);
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
      end Create;

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
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", Argument), Loc.Named ("value", Next)]);
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
         Pres.Put_Message
           (Screen, "cli.task.moved", [Loc.Named ("name", Argument), Loc.Named ("value", Next)]);
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
         Tk.Add_Dependency (Store, Change, First_Word, After_First, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.task.depends", [Loc.Named ("name", First_Word),
                                         Loc.Named ("value", After_First)]);
      end Depend;

      --  A task revised: task edit TASK with NAME=VALUE for each field.
      procedure Edit is
         Fields : Tk.Field_Map;
      begin
         if not Needs_Task then
            return;
         end if;
         for Index in 1 .. Item.Input_Count loop
            declare
               Pair : constant String := T.To_String (Item.Inputs (Index));
               Cut  : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
            begin
               if Cut > Pair'First then
                  Fields.Include (Pair (Pair'First .. Cut - 1), Pair (Cut + 1 .. Pair'Last));
               end if;
            end;
         end loop;
         Tk.Revise (Store, Change, Argument, Fields, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         Pres.Put_Message (Screen, "cli.task.revised", [Loc.Named ("name", Argument)]);
      end Edit;

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
         Tk.Decompose (Store, Change, First_Word, Titles, Made, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
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
             Loc.Named ("value", Tk.State_Of (Store, First_Word))]);
      end Split_Task;

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
         for Index in 1 .. R.Field_Count (View) loop
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", R.Field_Name (View, Index)),
                Loc.Named ("value", R.Get (View, R.Field_Name (View, Index)))]);
         end loop;
      end Show;

      --  The context a model would be given for the task, kept so that
      --  what it was can be looked up by its identifier afterwards.
      procedure Show_Context is
         Built : Model_Runner.Framework.Context.Built;
      begin
         if not Needs_Task then
            return;
         end if;
         Model_Runner.Framework.Context.Build
           (Store, Argument, Model_Runner.Framework.Context.Profile (Store, ""),
            Built, Outcome);
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
         if Profile = "" then
            Outcome := E.Make (E.Framework_Not_Found);
            E.Add_Text (Outcome, "name", "the verification profile of " & Argument);
            Fail (Outcome);
            return;
         end if;
         Model_Runner.Framework.Verification.Run_Profile
           (Store, Change, Profile, Argument, Evidence, Passed, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;

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
                     [Loc.Named ("path", To_String (One.File) & ":"
                                 & T.Image (Long_Long_Integer (One.Line))),
                      Loc.Named ("severity", To_String (One.Severity)),
                      Loc.Named ("detail", To_String (One.Message)
                                 & (if Length (One.Code) = 0 then ""
                                    else " [" & To_String (One.Code) & "]"))]);
               end;
            end loop;
            Pres.Put_Message
              (Screen, "cli.task.verified",
               [Loc.Named ("name", To_String (Evidence)),
                Loc.Named ("value", (if Passed then "passed" else "failed")),
                Loc.Named ("count", T.Image (Long_Long_Integer
                             (Model_Runner.Framework.Verification.Length
                                (Model_Runner.Framework.Verification.Parse_Profile
                                   (Profile_Text (Profile)))))),
                Loc.Named ("total", T.Image (Long_Long_Integer
                             (Model_Runner.Framework.Verification.Length (Said))))]);
         end;
         if not Passed then
            Status := E.Exit_Input_Output;
         end if;
      end Verify;

      --  Complete a task through its gates, then work out which
      --  requirements that verified.
      procedure Complete is
         Changed : Model_Runner.Framework.Name_Lists.Vector;
         Judged  : constant Model_Runner.Framework.Verification.Gate_List :=
           Model_Runner.Framework.Verification.Gates (Store, Argument);
      begin
         if not Needs_Task then
            return;
         end if;
         for Index in 1 .. Model_Runner.Framework.Verification.Length (Judged) loop
            declare
               One : constant Model_Runner.Framework.Verification.Gate :=
                 Model_Runner.Framework.Verification.Element (Judged, Index);
            begin
               Pres.Put_Message
                 (Screen, "cli.task.gate",
                  [Loc.Named ("name", To_String (One.Name)),
                   Loc.Named ("detail", (if One.Passed then "passed"
                                         else To_String (One.Reason)))]);
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
      end Complete;

      --  Take a task's workspace in, and verify and complete it.
      procedure Integrate is
         Done : Model_Runner.Framework.Work.Report;
      begin
         if not Needs_Task then
            return;
         end if;
         Model_Runner.Framework.Work.Take_In (Store, Argument, Done, Outcome);
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.task.integrated",
            [Loc.Named ("name", To_String (Done.Workspace_Id)),
             Loc.Named ("count", T.Image (Long_Long_Integer
                          (Natural (Done.Changed_Files.Length))))]);
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", Argument),
             Loc.Named ("value", To_String (Done.Final_State))]);
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
            Pres.Put_Message (Screen, "cli.task.derived", [Loc.Named ("name", Id)]);
         end loop;
         for Id of Done.Became_Ready loop
            Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
         end loop;
      end Step;

      --  What can start now, what waits, and what needs judgment.
      procedure Show_Plan is
         Planned : constant Model_Runner.Framework.Orchestration.Dispatch_Plan :=
           Model_Runner.Framework.Orchestration.Plan (Store);
      begin
         for Id of Planned.Start loop
            Pres.Put_Message (Screen, "cli.task.start", [Loc.Named ("name", Id)]);
         end loop;
         for Line of Planned.Held loop
            Pres.Put_Message (Screen, "cli.task.held", [Loc.Named ("detail", Line)]);
         end loop;
         for Line of Model_Runner.Framework.Orchestration.Needs_Judgment (Store) loop
            Pres.Put_Message (Screen, "cli.task.judgment", [Loc.Named ("detail", Line)]);
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
         for Id of Made loop
            Pres.Put_Message (Screen, "cli.task.derived", [Loc.Named ("name", Id)]);
         end loop;
      end Derive;
   begin
      Status := E.Exit_Success;

      S.Open (Store, Directory, Report, Outcome);
      if E.Is_Error (Outcome) then
         Fail (Outcome);
         return;
      end if;

      if Action = "list" then
         Show_List;
      elsif Action = "new" then
         Create;
      elsif Action = "accept" then
         Move ("accepted");
      elsif Action = "reject" then
         Move ("rejected");
      elsif Action = "cancel"
        and then Model_Runner.Framework.Tasks.State_Of (Store, Argument) = "running"
      then
         --  Its agent is stopped and its lease let go with it.
         Model_Runner.Framework.Work.Cancel (Store, Argument, Outcome);
         if E.Is_Error (Outcome) then
            Fail (Outcome);
         else
            Pres.Put_Message
              (Screen, "cli.task.moved",
               [Loc.Named ("name", Argument), Loc.Named ("value", "cancelled")]);
         end if;
      elsif Action = "cancel" then
         Move ("cancelled");
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
         end if;
      elsif Action = "reopen" then
         Move_Granted ("accepted", Model_Runner.Framework.Transitions.Reopen);
      elsif Action = "reconsider" then
         Move_Granted ("candidate", Model_Runner.Framework.Transitions.Reconsideration);
      elsif Action = "depend" then
         Depend;
      elsif Action = "edit" then
         Edit;
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
      elsif Action = "plan" then
         Show_Plan;
      else
         Derive;
      end if;
      S.Close (Store);
   end Run;

end Model_Runner.CLI.Tasks;
