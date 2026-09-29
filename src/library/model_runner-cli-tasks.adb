with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
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
         for Id of Listed loop
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               State   : constant String := Tk.State_Of (Store, Id);
               Shown_State : constant String :=
                 (if State = "accepted" and then Tk.Ready (Store, Id).Ready then "ready"
                  elsif State = "accepted" then "waiting"
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
                                         elsif To_String (One.Name) = "no_blocking_issue"
                                           and then Model_Runner.Framework.Tasks.State_Of
                                                      (Store, Argument) = "blocked"
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
         --  integrate TASK anyway: taken in whatever the code joins it to.
         Model_Runner.Framework.Work.Take_In
           (Store, First_Word, Done, Outcome, Semantic_Accepted => After_First = "anyway");
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
            [Loc.Named ("name", First_Word),
             Loc.Named ("value", To_String (Done.Final_State))]);
         if Done.Reason /= Null_Unbounded_String then
            Pres.Put_Message
              (Screen, "cli.task.field",
               [Loc.Named ("name", "reason"), Loc.Named ("value", To_String (Done.Reason))]);
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
               Pres.Put_Note (Screen, "cli.project.recovered", [Loc.Named ("detail", Line)]);
            end loop;
            Outcome := E.Success;
         end;
      end if;

      if Action = "list" then
         Show_List;
      elsif Action = "new" then
         Create;
      elsif Action = "accept" then
         Move ("accepted");
      elsif Action = "reject" then
         Move ("rejected");
      elsif Action = "cancel" then
         --  Whatever its state, what it holds goes with it: its agent,
         --  children, leases and workspace.
         if Needs_Task then
            Model_Runner.Framework.Work.Cancel
              (Store, Argument, Outcome, Actor => Model_Runner.Framework.Transitions.User);
            if E.Is_Error (Outcome) then
               Fail (Outcome);
            else
               Pres.Put_Message
                 (Screen, "cli.task.moved",
                  [Loc.Named ("name", Argument), Loc.Named ("value", "cancelled")]);
            end if;
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
               Tk.Move (Store, Change, First_Word, Next, Why, Status => Outcome,
                        Actor => Model_Runner.Framework.Transitions.User);
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
      for Id of Became_Ready loop
         Pres.Put_Note (Screen, "cli.task.ready", [Loc.Named ("name", Id)]);
      end loop;
      S.Close (Store);
   end Run;

end Model_Runner.CLI.Tasks;
