with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Model_Runner.CLI.Choosers;
with Model_Runner.Errors;
with Model_Runner.Framework;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;
with Model_Runner.Framework.Tasks;
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
        (if T.Is_Empty (Item.Task_Action) then "list"
         else T.To_String (Item.Task_Action));
      Argument  : constant String := T.To_String (Item.Task_Argument);

      Interactive : constant Boolean := Choosers.Is_Available;

      Store   : S.Store;
      Report  : S.Recovery_Report;
      Outcome : E.Error_Info;
      Change  : S.Transaction;

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

      procedure Show_List is
         Listed : constant Model_Runner.Framework.Name_Lists.Vector :=
           Tk.List (Store);
      begin
         if Listed.Is_Empty then
            Pres.Put_Note (Screen, "cli.task.none");
            return;
         end if;
         for Id of Listed loop
            declare
               Defined : R.Item;
               Read    : E.Error_Info;
               State   : constant String := Tk.State_Of (Store, Id);
            begin
               Tk.Definition (Store, Id, Defined, Read);
               Pres.Put_Message
                 (Screen, "cli.task.item",
                  [Loc.Named ("name", Id),
                   Loc.Named ("value",
                              (if State = "accepted"
                                 and then Tk.Ready (Store, Id).Ready
                               then "ready" else State)),
                   Loc.Named ("detail", R.Get (Defined, "title"))]);
            end;
         end loop;
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
         Tk.Move (Store, Change, Argument, Next, "", Status => Outcome);
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
      elsif Action = "cancel" then
         Move ("cancelled");
      elsif Action = "show" then
         Show;
      else
         Derive;
      end if;
      S.Close (Store);
   end Run;

end Model_Runner.CLI.Tasks;
