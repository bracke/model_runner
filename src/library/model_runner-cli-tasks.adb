with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;

with Hostkit.Fs;

with Model_Runner.CLI.Choosers;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Context;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Execution;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Orchestration;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Framework.Work;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
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
   function In_Conflict (Store : Model_Runner.Framework.Stores.Store; Space : String) return String is
      Files : constant Model_Runner.Framework.Name_Lists.Vector :=
        (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
         else Model_Runner.Framework.Workspaces.Conflict_Files (Store, Space));
   begin
      return (if Files.Is_Empty then "the files both changed" else Joined (Files));
   end In_Conflict;

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

   procedure Run
     (Item   : Model_Runner.CLI.Project_Requests.Request;
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

      Interactive : constant Boolean := Choosers.Is_Available (Screen);

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
      --  The tasks that became ready, said once what made them so is.
      Became_Ready : Model_Runner.Framework.Name_Lists.Vector;

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
            if Tk.State_Of (Store, Id) = "" then
               Outcome := E.Make (E.Framework_Not_Found);
               E.Add_Text (Outcome, "name", Id);
               Fail (Outcome);
               return False;
            end if;
         end;
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
                           return Pair (Cut + 1 .. Pair'Last);

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
                  E.Add_Text (Outcome, "name", "a filter of task list");
                  E.Add_Text (Outcome, "value", Name);
                  E.Add_Text (Outcome, "detail", "the filters are state, kind, component, origin,"
                              & " parent and requirement");
                  Fail (Outcome);
                  return;
               end if;
            end;
         end loop;
         for Id of Listed loop
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               State   : constant String := Tk.State_Of (Store, Id);
               Space : constant String :=
                 (if State = "verification"
                  then Model_Runner.Framework.Workspaces.Active_For (Store, Id) else "");
               --  Work waiting to be taken in says so, and whether it is in
               --  conflict: it waits on a person, not on the harness.
               Shown_State : constant String :=
                 (if State = "accepted" and then Tk.Ready (Store, Id).Ready then "ready"
                  elsif State = "accepted"
                    and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                                Ada.Strings.Fixed.Index (Reason, ", which is cancelled") > 0
                                or else Ada.Strings.Fixed.Index (Reason, ", which is rejected") > 0)
                  then "waiting on an ended task"
                  elsif State = "accepted" then "waiting"
                  elsif Space /= ""
                    and then not Model_Runner.Framework.Workspaces.Conflict_Files (Store, Space).Is_Empty
                  then "conflict"
                  elsif Space /= "" then "to integrate"
                  elsif State = "blocked"
                    and then (for some Reason of Tk.Ready (Store, Id).Reasons =>
                                Ada.Strings.Fixed.Index (Reason, "waiting for its children") > 0
                                or else Ada.Strings.Fixed.Index (Reason, "its child ") = Reason'First)
                  then "waiting for parts"
                  else State);

               function Fits (Name, Held : String) return Boolean
               is (Wanted (Name) = "" or else Wanted (Name) = Held);
            begin
               Tk.Definition (Store, Id, Defined, Read);
               if (Fits ("state", Shown_State)
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
         if Listed.Is_Empty then
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

         --  On a terminal, the form the kind's schema makes: the kind first,
         --  then what it requires, then what it allows -- a choice field
         --  offered its choices, and a value its schema refuses asked for
         --  again.
         loop
            Tk.Create (Store, Change, Fields, "user", "", Id, Outcome);
            exit when E.Is_Ok (Outcome)
              or else not Interactive
              or else Outcome.Code not in E.Framework_Input_Missing
                                        | E.Framework_Task_Kind_Unknown
                                        | E.Framework_Schema_Violation;

            --  A value refused: shown why, and asked for again.
            if Outcome.Code = E.Framework_Schema_Violation then
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
                        Choosers.Ask (Screen, Field, Tk.Field_Schema (Store, Field),
                                      Choices (Field), "", Typed, Got, Required => True);
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
         if Tk.State_Of (Store, To_String (Id)) = "candidate" then
            Pres.Put_Note (Screen, "cli.next.accept_task", [Loc.Named ("name", To_String (Id))]);
         end if;

         --  Its own permissions asking for more than its kind allows: it
         --  gets what its kind allows, and is told so.
         if Fields.Contains ("permissions") and then Fields.Contains ("kind") then
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
                           [Loc.Named ("name", To_String (Id)), Loc.Named ("other", Fields ("kind")),
                            Loc.Named ("detail", Clipped)]);
                     end if;
                     Say_Narrowing (Screen, To_String (Id), Fields ("kind"), Asked, Allowed);
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
                   Loc.Named ("value", Child & " " & Tk.State_Of (Store, Child)
                              & "; task " & (if Tk.State_Of (Store, Child) = "candidate"
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
         --  A part let go: its parent is said.
         Tk.Definition (Store, Ended, Own, Seen);
         if E.Is_Ok (Seen) and then R.Get (Own, "parent") /= "" then
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
                        [Loc.Named ("name", Other), Loc.Named ("value", Ended)]);
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
            [Loc.Named ("name", Argument), Loc.Named ("value", Tk.State_Of (Store, Argument))]);
         if Next in "rejected" | "cancelled" then
            Say_Left_Waiting (Argument);
         elsif Next = "accepted" and then Tk.Ready (Store, Argument).Ready then
            Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Argument)]);
         elsif Next = "accepted" and then Tk.State_Of (Store, Argument) = "accepted"
           and then not Tk.Ready (Store, Argument).Reasons.Is_Empty
         then
            --  Accepted, and waiting: for what, and what makes it ready.
            Pres.Put_Note
              (Screen, "cli.task.accepted_waits",
               [Loc.Named ("name", Argument),
                Loc.Named ("detail", Tk.Ready (Store, Argument).Reasons.First_Element)]);
         end if;
         if Tk.State_Of (Store, Argument) /= Next then
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", "reason"),
                Loc.Named ("value", (declare
                                        Now : constant Tk.Readiness := Tk.Ready (Store, Argument);
                                     begin
                                        (if Now.Reasons.Is_Empty then "" else Now.Reasons.First_Element)))]);
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
               Pres.Put_Note (Screen, "cli.intent.already",
                              [Loc.Named ("name", First_Word),
                               Loc.Named ("value", "not waiting for " & On)]);
               return;
            elsif Undo then
               Tk.Remove_Dependency (Store, Change, First_Word, On, Outcome);
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
                  --  permissions=inherit clears a task's own: its kind's
                  --  then, as a level set to inherit takes the one above.
                  Fields.Include (Pair (Pair'First .. Cut - 1),
                                  (if Pair (Pair'First .. Cut - 1) = "permissions"
                                     and then Pair (Cut + 1 .. Pair'Last) = "inherit"
                                   then "" else Pair (Cut + 1 .. Pair'Last)));
               end if;
            end;
         end loop;
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
            E.Add_Text (Outcome, "name", "what to change: task edit " & Argument
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
            Tk.Definition (Store, Argument, Defined, Read);
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
               Pres.Put_Note (Screen, "cli.task.unchanged", [Loc.Named ("name", Argument)]);
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
               Tk.Definition (Store, Argument, Defined, Read);
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
         Tk.Revise (Store, Change, Argument, Fields, Outcome);
         if E.Is_Ok (Outcome) then
            Commit;
         end if;
         if E.Is_Error (Outcome) then
            Fail (Outcome);
            return;
         end if;
         Pres.Put_Message (Screen, "cli.task.revised", [Loc.Named ("name", Argument)]);

         --  Its permissions asking for more than its kind allows: what it
         --  gets, as a new task is told.
         if Fields.Contains ("permissions") then
            declare
               package Pm renames Model_Runner.Framework.Permissions;
               Defined : R.Item;
               Read    : E.Error_Info;
               Asked   : Pm.Permission_Set;
            begin
               Tk.Definition (Store, Argument, Defined, Read);
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
                           [Loc.Named ("name", Argument), Loc.Named ("other", R.Get (Defined, "kind")),
                            Loc.Named ("detail", Clipped)]);
                     end if;
                     Say_Narrowing (Screen, Argument, R.Get (Defined, "kind"), Asked, Allowed);
                  end;
               end if;
            end;
         end if;
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
                           & " or task edit " & First_Word & " title=... renames it");
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
             Loc.Named ("value", Tk.State_Of (Store, First_Word))]);
         declare
            Waiting : Unbounded_String;
         begin
            for Part of Made loop
               if Tk.State_Of (Store, Part) = "candidate" then
                  Append (Waiting, (if Waiting = Null_Unbounded_String then "" else " ") & Part);
               end if;
            end loop;
            if Waiting /= Null_Unbounded_String then
               Pres.Put_Note (Screen, "cli.next.parts", [Loc.Named ("detail", To_String (Waiting))]);
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
                        & " them in: task rehome OLD NEW");
            Fail (Outcome);
            return;
         elsif Space /= 0 then
            Refuse ("task rehome", After_First, "it takes two words, OLD and NEW, and was given more");
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
            E.Add_Text (Outcome, "detail", "rehome moves every open task of a component; task edit "
                        & First_Word & " component=" & After_First & " moves one");
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
                        & "; task edit ID component=" & Homes.First_Element & " places one there");
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
                    & "; reconfigure map.component." & After_First & "=roots=DIR makes it one,"
                    & " placed where its files are");
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
         --  What it is and where it stands first; what governs it last.
         declare
            First : constant Model_Runner.Framework.Name_Lists.Vector :=
              ["definition.title", "runtime.state", "blocked_by", "definition.kind",
               "definition.component", "definition.requirements", "definition.depends_on"];

            procedure Line (Name : String) is
            begin
               Pres.Put_Message
                 (Screen, "cli.task.field",
                  [Loc.Named ("name", Name), Loc.Named ("value", R.Get (View, Name))]);
            end Line;

            function Leading (Name : String) return Boolean
            is (First.Contains (Name));

            function Governing (Name : String) return Boolean
            is (Name'Length > 10 and then Name (Name'First .. Name'First + 9) = "authority.");
         begin
            for One of First loop
               --  What it waits for, only where it waits.
               if R.Has (View, One) and then not (One = "blocked_by" and then R.Get (View, One) = "")
               then
                  Line (One);
               end if;
            end loop;
            for Index in 1 .. R.Field_Count (View) loop
               if not Leading (R.Field_Name (View, Index))
                 and then not Governing (R.Field_Name (View, Index))
               then
                  Line (R.Field_Name (View, Index));
               end if;
            end loop;
            for Index in 1 .. R.Field_Count (View) loop
               if Governing (R.Field_Name (View, Index)) then
                  Line (R.Field_Name (View, Index));
               end if;
            end loop;
         end;

         --  A sandbox the environment sets confines its agent further: said,
         --  and said when it does not read.
         if Model_Runner.Framework.Permissions.Sandbox_Problem /= "" then
            Pres.Put_Note
              (Screen, "cli.task.sandbox_bad",
               [Loc.Named ("detail", Model_Runner.Framework.Permissions.Sandbox_Problem)]);
         elsif Ada.Environment_Variables.Exists (Model_Runner.Framework.Permissions.Sandbox_Variable)
           and then Ada.Environment_Variables.Value
                      (Model_Runner.Framework.Permissions.Sandbox_Variable) /= ""
         then
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", "sandbox"),
                Loc.Named ("value", Ada.Environment_Variables.Value
                                      (Model_Runner.Framework.Permissions.Sandbox_Variable))]);
         end if;

         --  Its parts, each with how it stands, whatever the parent's state.
         declare
            Parts : Unbounded_String;
         begin
            for Child of Tk.Children (Store, Argument) loop
               Append (Parts, (if Parts = Null_Unbounded_String then "" else ", ")
                              & Child & " " & Tk.State_Of (Store, Child));
            end loop;
            if Parts /= Null_Unbounded_String then
               Pres.Put_Message
                 (Screen, "cli.task.field",
                  [Loc.Named ("name", "parts"), Loc.Named ("value", To_String (Parts))]);
            end if;
         end;

         --  Work waiting in a workspace: which, and where.
         if Model_Runner.Framework.Workspaces.Active_For (Store, Argument) /= "" then
            declare
               Place : Model_Runner.Framework.Workspaces.Workspace;
               Read  : E.Error_Info;
            begin
               Model_Runner.Framework.Workspaces.Read
                 (Store, Model_Runner.Framework.Workspaces.Active_For (Store, Argument), Place, Read);
               Pres.Put_Message
                 (Screen, "cli.task.field",
                  [Loc.Named ("name", "workspace"),
                   Loc.Named ("value", Model_Runner.Framework.Workspaces.Active_For (Store, Argument)
                                       & " " & To_String (Place.Path))]);
            end;
         end if;
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
            end;
         elsif Action = "verify"
           and then Tk.State_Of (Store, Argument) in "failed" | "blocked" | "accepted"
         then
            --  Passing now, and not done yet: what finishes it.
            Pres.Put_Note (Screen, "cli.next.complete", [Loc.Named ("name", Argument)]);
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
              (Screen, "cli.work.parent_ready", [Loc.Named ("name", R.Get (Defined, "parent"))]);
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
      begin
         if not Needs_Task then
            return;
         end if;

         --  A candidate is accepted first: nothing is run for one.
         if Tk.State_Of (Store, Argument) = "candidate" then
            Outcome := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Outcome, "name", Argument);
            E.Add_Text (Outcome, "value", "candidate");
            E.Add_Text (Outcome, "expected", "complete");
            E.Add_Text (Outcome, "detail", "a candidate is accepted first: task accept " & Argument);
            Fail (Outcome);
            return;
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
                                  Loc.Named ("detail", In_Conflict (Store, Space))]);
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
               Pres.Put_Note (Screen, "cli.task.given_up_by_hand",
                              [Loc.Named ("name", Argument),
                               Loc.Named ("value", R.Get (Held_State, "current_workspace"))]);
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
                                 & Model_Runner.Framework.State_Said (Tk.State_Of (Store, Named)));
                     Fail (Outcome);
                     Pres.Put_Note
                       (Screen, "cli.next.waits_first",
                        [Loc.Named ("name", Argument), Loc.Named ("value", Named),
                         Loc.Named ("detail",
                                    (if Tk.State_Of (Store, Named) = "candidate"
                                     then "task accept " & Named else "work " & Named))]);
                     return;
                  end if;
               end;
            end loop;
         end;

         --  Its evidence missing or stale, it is verified now: a task done
         --  by hand is checked as the harness would check it.
         if not Verified then
            Verify;
            if Status /= E.Exit_Success then
               return;
            end if;
         end if;
         Complete_Judged;
      end Complete;

      procedure Complete_Judged is
         Changed : Model_Runner.Framework.Name_Lists.Vector;
         Judged  : constant Model_Runner.Framework.Verification.Gate_List :=
           Model_Runner.Framework.Verification.Gates (Store, Argument);

         --  The workspace its agent's work was given up with, if it was:
         --  what that work changed and took in is none of this.
         function Given_Up return String is
            Held_State : R.Item;
            Read       : E.Error_Info;
         begin
            S.Read (Store, Model_Runner.Framework.Tasks_Area, Argument & ".state", Held_State, Read);
            return (if E.Is_Ok (Read) and then R.Get (Held_State, "current_workspace") /= ""
                      and then Tk.State_Of (Store, Argument) in "failed" | "blocked"
                      and then Model_Runner.Framework.Workspaces.Active_For (Store, Argument) = ""
                    then R.Get (Held_State, "current_workspace") else "");
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
         for Index in 1 .. Model_Runner.Framework.Verification.Length (Judged) loop
            declare
               One : constant Model_Runner.Framework.Verification.Gate :=
                 Model_Runner.Framework.Verification.Element (Judged, Index);
            begin
               Pres.Put_Message
                 (Screen, "cli.task.gate",
                  [Loc.Named ("name", To_String (One.Name)),
                   Loc.Named ("detail", (if To_String (One.Name) = "integration" and then Space = ""
                                           and then Never_Apart
                                         then "set aside: it had no workspace, and nothing to take in"
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

         Say_Parent_Ready (Argument);
      end Complete_Judged;

      --  Take a task's workspace in, and verify and complete it.
      procedure Integrate is
         Done : Model_Runner.Framework.Work.Report;
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
                             & "task integrate " & Id & (if Way = "" then "" else " " & Way));
                  end if;
               end loop;
               Outcome := E.Make (E.Framework_Input_Missing);
               E.Add_Text (Outcome, "name",
                           "the task whose work is taken in"
                           & (if Waiting = Null_Unbounded_String then " (none waits)"
                              else ": " & To_String (Waiting)));
               Fail (Outcome);
               return;
            end;
         end if;
         if not Needs_Task then
            return;
         end if;
         --  A word it does not take is refused, not ignored.
         if After_First not in "" | "anyway" | "resolved" | "resolved anyway" then
            Outcome := E.Make (E.CLI_Unexpected_Operand);
            E.Add_Text (Outcome, "value", After_First & "; integrate takes resolved, anyway, or"
                        & " resolved anyway after the task");
            Fail (Outcome);
            return;
         end if;
         --  integrate TASK anyway: taken in whatever the code joins it to.
         --  Settled, it says, with a file as it was when the conflict was
         --  found: taken over the project's change only when that is said.
         if After_First = "resolved" then
            declare
               Space     : constant String :=
                 Model_Runner.Framework.Workspaces.Active_For (Store, First_Word);
               Unsettled : constant Model_Runner.Framework.Name_Lists.Vector :=
                 (if Space = "" then Model_Runner.Framework.Name_Lists.Empty_Vector
                  else Model_Runner.Framework.Workspaces.Conflict_Files
                         (Store, Space, Unsettled_Only => True));
            begin
               if not Unsettled.Is_Empty then
                  Outcome := E.Make (E.Framework_Integration_Conflict);
                  E.Add_Text (Outcome, "name", Space);
                  E.Add_Text (Outcome, "detail", Joined (Unsettled)
                              & ", not changed since the conflict was found; settle "
                              & (if Natural (Unsettled.Length) = 1 then "it" else "them")
                              & " in the workspace, or task integrate " & First_Word
                              & " resolved anyway takes the workspace's copy over the project's");
                  Fail (Outcome);
                  return;
               end if;
            end;
         end if;
         --  anyway where nothing stood in the way: taken in all the same, and
         --  said that it was not needed.
         if After_First = "anyway"
           and then Model_Runner.Framework.Workspaces.Active_For (Store, First_Word) /= ""
           and then Model_Runner.Framework.Workspaces.Conflict_Files
                      (Store, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)).Is_Empty
           and then Model_Runner.Framework.Workspaces.Semantic_Conflicts
                      (Store, Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)).Is_Empty
         then
            Pres.Put_Note (Screen, "cli.task.anyway_unneeded");
         end if;
         Model_Runner.Framework.Work.Take_In
           (Store, First_Word, Done, Outcome, Semantic_Accepted => After_First = "anyway",
            Text_Resolved => After_First in "resolved" | "resolved anyway");
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
                                                          (Store, First_Word)))]);
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
               Pres.Put_Note
                 (Screen, "cli.next.conflict",
                  [Loc.Named ("name", First_Word), Loc.Named ("path", To_String (Place.Path)),
                   Loc.Named ("detail", In_Conflict (Store, To_String (Done.Workspace_Id)))]);
            end;
            Status := E.Exit_Input_Output;
            return;
         end if;
         Pres.Put_Message
           (Screen, "cli.task.integrated",
            [Loc.Named ("name", To_String (Done.Workspace_Id)),
             Loc.Named ("detail", (if Done.Changed_Files.Is_Empty then "nothing"
                                   else Joined (Done.Changed_Files)))]);
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
         Pres.Put_Message
           (Screen, "cli.task.moved",
            [Loc.Named ("name", First_Word),
             Loc.Named ("value", To_String (Done.Final_State))]);
         if Done.Reason /= Null_Unbounded_String then
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", "reason"), Loc.Named ("value", To_String (Done.Reason))]);
         end if;
         if To_String (Done.Final_State) in "failed" | "blocked" then
            Pres.Put_Note (Screen, "cli.next.retry", [Loc.Named ("name", First_Word)]);
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
                                                 then "task reconsider " else "task reopen ")
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
      if Action in "accept" | "reject" and then Ada.Strings.Fixed.Index (Argument, " ") > 0
        and then (for all Word of Model_Runner.Framework.Lines_Of
                                    (Ada.Strings.Fixed.Translate
                                       (Argument, Ada.Strings.Maps.To_Mapping (" ", [1 => ASCII.LF])))
                  => Ada.Strings.Fixed.Index (Word, "TASK-") = Word'First)
      then
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
                        or else Action in "list" | "show" | "audit" | "plan" | "context")
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
                        else "task accept " & First_Word & " accepts it"));
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
         E.Add_Text (Outcome, "detail", "an ended task is not accepted again; task reopen "
                     & Argument & " makes it ready again");
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
         elsif After_First /= "anyway" and then Tk.State_Of (Store, First_Word) = "verification"
           and then Model_Runner.Framework.Workspaces.Active_For (Store, First_Word) /= ""
         then
            Outcome := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Outcome, "name", First_Word);
            E.Add_Text (Outcome, "value", "verification");
            E.Add_Text (Outcome, "expected", "cancelled");
            E.Add_Text (Outcome, "detail", "its work waits in "
                        & Model_Runner.Framework.Workspaces.Active_For (Store, First_Word)
                        & " to be taken in, and cancelling gives it up; task integrate "
                        & First_Word & " takes it in, task cancel " & First_Word
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
                                     Loc.Named ("detail", (if Lost.Is_Empty then "nothing"
                                                           else Joined (Lost)))]);
                  end if;
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
         end if;
      elsif Action = "reopen" and then Argument /= "" and then Tk.State_Of (Store, Argument) = "rejected"
      then
         --  A rejected one is reconsidered, not reopened: said so.
         Outcome := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Outcome, "name", Argument);
         E.Add_Text (Outcome, "value", "rejected");
         E.Add_Text (Outcome, "expected", "accepted");
         E.Add_Text (Outcome, "detail", "a rejected task is reconsidered, not reopened: task reconsider "
                     & Argument & " makes it a candidate again");
         Fail (Outcome);
      elsif Action = "reopen" then
         Move_Granted ("accepted", Model_Runner.Framework.Transitions.Reopen);
      elsif Action = "reconsider" then
         Move_Granted ("candidate", Model_Runner.Framework.Transitions.Reconsideration);
      elsif Action = "move" then
         --  To any state the project's lifecycle allows: move TASK STATE.
         if First_Word = "" or else After_First = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "the task and the state");
            Fail (Outcome);
         elsif Tk.State_Of (Store, First_Word)
                 = Ada.Strings.Fixed.Head
                     (After_First & " ", Ada.Strings.Fixed.Index (After_First & " ", " ") - 1)
         then
            Pres.Put_Note (Screen, "cli.intent.already",
                           [Loc.Named ("name", First_Word),
                            Loc.Named ("value", Tk.State_Of (Store, First_Word))]);
         elsif Ada.Strings.Fixed.Head (After_First & " ", 9) in "complete " | "running  " then
            --  The harness's moves: by work, or completed by hand.
            Outcome := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Outcome, "name", First_Word);
            E.Add_Text (Outcome, "value", Tk.State_Of (Store, First_Word));
            E.Add_Text (Outcome, "expected", Ada.Strings.Fixed.Trim (Ada.Strings.Fixed.Head (After_First, 8),
                                                                     Ada.Strings.Both));
            E.Add_Text (Outcome, "detail", "work " & First_Word & " does it, or task complete "
                        & First_Word & " once it is done by hand");
            Fail (Outcome);
         elsif After_First = "cancelled" then
            --  Cancelled the way cancel does it: what it holds goes with it.
            Model_Runner.Framework.Work.Cancel
              (Store, First_Word, Outcome, Actor => Model_Runner.Framework.Transitions.User);
            if E.Is_Error (Outcome) then
               Fail (Outcome);
            else
               Pres.Put_Message
                 (Screen, "cli.task.moved",
                  [Loc.Named ("name", First_Word), Loc.Named ("value", After_First)]);
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
                              & " to be taken in; task integrate " & First_Word
                              & " takes it in, task move " & First_Word & " failed anyway gives it up");
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
                  Tk.Move (Store, Change, First_Word, Next, Said, Status => Outcome,
                           Actor => Model_Runner.Framework.Transitions.User);
                  if E.Is_Ok (Outcome) and then Space /= "" then
                     Pres.Put_Note (Screen, "cli.task.workspace_given_up",
                                    [Loc.Named ("name", Space),
                                     Loc.Named ("detail", (if Lost.Is_Empty then "nothing"
                                                           else Joined (Lost)))]);
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
                     [Loc.Named ("name", First_Word), Loc.Named ("value", Next)]);
               end if;
            end;
         end if;
      elsif Action = "depend" then
         Depend;
      elsif Action = "edit" then
         Edit;
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
      elsif Action = "plan" then
         Show_Plan;
      elsif Action = "derive" then
         Derive;
      else
         --  Nothing the command does: said, not taken for another.
         Outcome := E.Make (E.CLI_Unexpected_Operand);
         E.Add_Text (Outcome, "value", Action);
         Fail (Outcome);
      end if;
      --  What a change to the tasks makes of the requirements they serve,
      --  judged before the command ends, however the change was made.
      if Action not in "list" | "show" | "audit" | "plan" | "context" | "help"
        and then not S.Is_Read_Only (Store)
      then
         Change := S.No_Changes;
         Commit;
      end if;
      for Id of Became_Ready loop
         --  The one just accepted was said with its next step already.
         if not (Action = "accept" and then Id = Argument) then
            Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
         end if;
      end loop;
      S.Close (Store);
   end Run;

end Model_Runner.CLI.Tasks;
