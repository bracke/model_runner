with Model_Runner.Framework.Observations;

separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Route_Knowledge is

   package Ob renames Model_Runner.Framework.Observations;
   use type Ob.Lifecycle;
   use type Ob.Applicability;

   --  An observation as asked for: a number alone is one's, 4 is OBS-004.
   function Asked_Id (Index : Positive) return String is
      Given : constant String := Ada.Characters.Handling.To_Upper (Argument (Index));
   begin
      return (if Given /= "" and then Given'Length <= 6 and then (for all C of Given => C in '0' .. '9')
              then "OBS-" & [1 .. Integer'Max (0, 3 - Given'Length) => '0'] & Given
              else Given);
   end Asked_Id;

   --  A setting given, NAME=VALUE: its value, or "".
   function Setting (Name : String) return String is
   begin
      for Index in 1 .. Command.Input_Count loop
         declare
            One   : constant String := T.To_String (Command.Inputs (Index));
            Equal : constant Natural := Ada.Strings.Fixed.Index (One, "=");
         begin
            if Equal > One'First and then One (One'First .. Equal - 1) = Name then
               return One (Equal + 1 .. One'Last);
            end if;
         end;
      end loop;
      return "";
   end Setting;

   procedure Fail (Status : E.Error_Info) is
   begin
      Outcome := Status;
      Pres.Report (Screen, Outcome);
      Last_Status := E.Exit_Status (Outcome);
   end Fail;

   function Shortened (Text : String; Most : Positive) return String
   is (if Text'Length <= Most then Text else Text (Text'First .. Text'First + Most - 4) & "...");

   -------------
   -- Listing --
   -------------

   procedure Listing (Store : in out S.Store) is
      Everything : constant Boolean := Verb = "all";
      Hidden     : Natural := 0;
      Shown      : Natural := 0;
   begin
      for Id of Ob.List (Store) loop
         declare
            Value  : Ob.Observation;
            Read   : E.Error_Info;
            Why    : Unbounded_String;
         begin
            Ob.Read (Store, Id, Value, Read);
            if E.Is_Error (Read) then
               Shown := Shown + 1;
               Pres.Put_Row (Screen, Id, "would not read", Main_Tone => Pres.Bad);
            elsif not Everything and then Value.Status /= Ob.Active then
               Hidden := Hidden + 1;
            else
               Shown := Shown + 1;
               declare
                  Standing : constant Ob.Applicability := Ob.Applicability_Of (Store, Value, Why);
               begin
                  Pres.Put_Row
                    (Screen,
                     Id & "  " & Ob.Word (Value.Kind) & "  " & Ob.Word (Value.Status),
                     Shortened (To_String (Value.Summary), 72)
                     & (if Standing /= Ob.Applicable then "  [" & Ob.Word (Standing) & "]" else "")
                     & (if Length (Value.Task_Id) > 0 then "  " & To_String (Value.Task_Id) else ""),
                     Main_Tone => (if Value.Status /= Ob.Active then Pres.Muted
                                   elsif Standing /= Ob.Applicable then Pres.Pending
                                   else Pres.Plain));
               end;
            end if;
         end;
      end loop;
      if Shown = 0 and then Hidden = 0 then
         Pres.Put_Note (Screen, "cli.obs.none");
      elsif Hidden > 0 then
         Pres.Put_Note (Screen, "cli.obs.hidden", [Loc.Named ("count", Image (Hidden))]);
      end if;
   end Listing;

   -------------
   -- Showing --
   -------------

   procedure Showing (Store : in out S.Store) is
      Id    : constant String := Asked_Id (if Verb = "show" then 2 else 1);
      Value : Ob.Observation;
      Read  : E.Error_Info;
      Why   : Unbounded_String;
   begin
      Ob.Read (Store, Id, Value, Read);
      if E.Is_Error (Read) then
         Fail (Read);
         return;
      end if;
      declare
         Standing : constant Ob.Applicability := Ob.Applicability_Of (Store, Value, Why);
      begin
         Pres.Put_Header (Screen, "cli.obs.heading", [Loc.Named ("name", Id)]);
         Sectioned := False;
         Field ("kind", Ob.Word (Value.Kind));
         Field ("status",
                Ob.Word (Value.Status)
                & (case Value.Status is
                     when Ob.Promoted   => " into " & To_String (Value.Promoted_To),
                     when Ob.Superseded => " by " & To_String (Value.Superseded_By),
                     when Ob.Dismissed  => (if Length (Value.Reason) > 0 then ": " & To_String (Value.Reason)
                                            else ""),
                     when Ob.Active     => ""),
                (if Value.Status = Ob.Active then Pres.Plain else Pres.Muted));
         if Length (Value.Retired) > 0 then
            Field ("retired", To_String (Value.Retired), Pres.Muted);
         else
            Field ("says", To_String (Value.Summary));
         end if;
         Field ("grounding",
                (case Value.Ground is
                   when Ob.Observed => "observed: evidence the harness holds stands behind it",
                   when Ob.Reported => "reported: on its producer's word alone"));
         Field ("applies", Ob.Word (Standing) & (if Length (Why) > 0 then ": " & To_String (Why) else ""),
                (if Standing = Ob.Applicable then Pres.Good else Pres.Pending));
         Field ("found",
                (case Value.Producer is
                   when Ob.Agent_Producer   => "by an agent",
                   when Ob.Harness_Producer => "by the harness",
                   when Ob.User_Producer    => "by a person")
                & (if Length (Value.Task_Id) > 0 then " in " & To_String (Value.Task_Id) else "")
                & (if Length (Value.Generation) > 0 then " generation " & To_String (Value.Generation) else "")
                & (if Length (Value.Agent) > 0 then ", " & To_String (Value.Agent) else "")
                & (if Length (Value.Parent) > 0 then " under " & To_String (Value.Parent) else "")
                & (if Length (Value.Invocation) > 0 then ", " & To_String (Value.Invocation) else "")
                & ", " & To_String (Value.Created_At));
         Field ("seen", Image (Value.Occurrences) & (if Value.Occurrences = 1 then " time" else " times")
                & ", last " & To_String (Value.Seen_At));
         if Natural (Value.Sightings.Length) > 1 then
            Field ("sightings", Joined_Names (Value.Sightings));
         end if;
         if not Value.Evidence.Is_Empty then
            Field ("evidence", Joined_Names (Value.Evidence));
         end if;
         if not Value.Files.Is_Empty then
            Field ("files", Joined_Names (Value.Files));
         end if;
         if not Value.Symbols.Is_Empty then
            Field ("symbols", Joined_Names (Value.Symbols));
         end if;
         if Length (Value.Similar_To) > 0 then
            Field ("similar", "says nearly what " & To_String (Value.Similar_To) & " says; told once with it");
         end if;
         Pres.Put_Note (Screen, "cli.obs.not_authoritative", [Loc.Named ("name", Id)]);
      end;
   end Showing;

   ------------
   -- Acting --
   ------------

   procedure Acting (Store : in out S.Store) is
      Change : S.Transaction;
      Status : E.Error_Info;
      Id     : constant String := Asked_Id (2);
      Made   : Unbounded_String;

      procedure Commit_Then (Key : String; Arguments : Loc.Argument_List) is
      begin
         if E.Is_Ok (Status) then
            S.Commit (Store, Change, Status);
         end if;
         if E.Is_Error (Status) then
            Fail (Status);
         else
            Pres.Put_Message (Screen, Key, Arguments);
         end if;
      end Commit_Then;
   begin
      if Verb = "record" then
         declare
            Said  : Ob.Draft;
            Found : Boolean;
            Fresh : Boolean;
         begin
            Ob.Kind_Of (Argument (2), Said.Kind, Found);
            if not Found then
               Status := E.Make (E.Framework_Input_Invalid);
               E.Add_Text (Status, "name", "the kind of observation");
               E.Add_Text (Status, "value", Argument (2));
               E.Add_Text (Status, "detail", "finding, experiment, failure_pattern, environment_constraint,"
                           & " tool_behavior or implementation_note");
               Fail (Status);
               return;
            end if;
            Said.Summary := To_Unbounded_String (Argument (3));
            Ob.Record_Observation
              (Store, Change, Said, (Producer => Ob.User_Producer, others => <>), Made, Fresh, Status);
            Commit_Then ((if Fresh then "cli.obs.recorded" else "cli.obs.seen_again"),
                         [Loc.Named ("name", To_String (Made))]);
            --  Kept, and nearly what another says: said, with how to make
            --  the two one.
            declare
               Kept : Ob.Observation;
               Read : E.Error_Info;
            begin
               if Fresh and then E.Is_Ok (Status) then
                  Ob.Read (Store, To_String (Made), Kept, Read);
                  if E.Is_Ok (Read) and then Length (Kept.Similar_To) > 0 then
                     Pres.Put_Note (Screen, "cli.obs.similar",
                                    [Loc.Named ("name", To_String (Made)),
                                     Loc.Named ("value", To_String (Kept.Similar_To))]);
                  end if;
               end if;
            end;
         end;
      elsif Verb = "dismiss" then
         Ob.Dismiss (Store, Change, Id,
                     (if Argument (3) /= "" then Argument (3) else "dismissed by a person"), Status);
         Commit_Then ("cli.obs.dismissed", [Loc.Named ("name", Id)]);
      elsif Verb = "supersede" then
         Ob.Supersede (Store, Change, Id, Asked_Id (3), Status);
         Commit_Then ("cli.obs.superseded", [Loc.Named ("name", Id), Loc.Named ("value", Asked_Id (3))]);
      elsif Verb = "promote" and then Ada.Characters.Handling.To_Lower (Argument (3)) = "task" then
         declare
            Fields : Tk.Field_Map;
         begin
            for Index in 1 .. Command.Input_Count loop
               declare
                  One   : constant String := T.To_String (Command.Inputs (Index));
                  Equal : constant Natural := Ada.Strings.Fixed.Index (One, "=");
               begin
                  if Equal > One'First then
                     Fields.Include (One (One'First .. Equal - 1), One (Equal + 1 .. One'Last));
                  end if;
               end;
            end loop;
            Ob.Promote_To_Task (Store, Change, Id, Fields, Made, Status);
            Commit_Then ("cli.obs.promoted",
                         [Loc.Named ("name", Id), Loc.Named ("value", To_String (Made)),
                          Loc.Named ("detail",
                                     (if E.Is_Ok (Status) and then Tk.State_Of (Store, To_String (Made)) = Tk.Candidate
                                      then "a candidate task: /task accept " & To_String (Made) & " makes it work"
                                      else "a task, " & Tk.State_Of (Store, To_String (Made))))]);
         end;
      elsif Verb = "promote" and then Ada.Characters.Handling.To_Lower (Argument (3)) = "fact" then
         if Command.Input_Count /= 1 then
            Status := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Status, "name", "the fact, as KEY=VALUE");
            Fail (Status);
            return;
         end if;
         declare
            One   : constant String := T.To_String (Command.Inputs (1));
            Equal : constant Natural := Ada.Strings.Fixed.Index (One, "=");
         begin
            Ob.Promote_To_Fact (Store, Change, Id, One (One'First .. Equal - 1), One (Equal + 1 .. One'Last),
                                Status);
            Commit_Then ("cli.obs.promoted",
                         [Loc.Named ("name", Id), Loc.Named ("value", "fact " & One (One'First .. Equal - 1)),
                          Loc.Named ("detail", "a fact no surer than the observation was, and never authoritative")]);
         end;
      elsif Verb = "promote" and then Ada.Characters.Handling.To_Lower (Argument (3)) = "decision" then
         Ob.Promote_To_Decision
           (Store, Change, Id,
            (if Argument (4) /= "" then Ada.Characters.Handling.To_Upper (Argument (4)) else ""),
            Setting ("title"), Setting ("text"), Setting ("scope"), Made, Status);
         Commit_Then ("cli.obs.promoted",
                      [Loc.Named ("name", Id), Loc.Named ("value", To_String (Made)),
                       Loc.Named ("detail", "a candidate decision: /decision accept " & To_String (Made)
                                  & " decides it")]);
      else
         Status := E.Make (E.Framework_Input_Invalid);
         E.Add_Text (Status, "name", "what to promote it into");
         E.Add_Text (Status, "value", Argument (3));
         E.Add_Text (Status, "detail", "/obs promote ID task [NAME=VALUE...], fact KEY=VALUE or decision [KEY]");
         Fail (Status);
      end if;
   end Acting;

begin
   if Verb in "" | "list" | "all" then
      With_Store (Listing'Access);
   elsif Verb = "show" or else Ada.Strings.Fixed.Index (Asked_Id (1), "OBS-") = 1 then
      With_Store (Showing'Access);
   elsif Verb in "record" | "dismiss" | "supersede" | "promote" then
      if Argument (2) = "" or else (Verb in "supersede" | "promote" and then Argument (3) = "") then
         Outcome := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Outcome, "name",
                     (if Verb = "record" then "the kind and what was found: /obs record KIND TEXT"
                      elsif Verb = "supersede" then "the observation and the one it is superseded by"
                      elsif Verb = "promote" then "the observation and what it becomes: task, fact or decision"
                      else "the observation"));
         Pres.Report (Screen, Outcome);
         Last_Status := E.Exit_Status (Outcome);
      else
         With_Store (Acting'Access);
      end if;
   else
      Outcome := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Outcome, "name", "/obs's actions");
      E.Add_Text (Outcome, "value", Argument (1));
      E.Add_Text (Outcome, "detail", "/obs lists, shows an ID, or takes all, record, dismiss, supersede or promote");
      Pres.Report (Screen, Outcome);
      Last_Status := E.Exit_Status (Outcome);
   end if;
end Route_Knowledge;
