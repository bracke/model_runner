separate (Model_Runner.CLI.Project_Commands.Run_Line)
procedure Show_Result (Store : in out S.Store) is
   package Rs renames Model_Runner.Framework.Results;
   Held  : Rs.Result;
   Read  : E.Error_Info;
   Size  : constant Natural := Rs.Payload_Size (Store, Argument (1));
   --  A large payload is read only when asked for: /result ID full.
   Whole : constant Boolean := Size <= Rs.Inline_Limit or else Argument (2) = "full";
   --  As the harness writes it: ag-000001 is AG-000001, and AG-1 is
   --  AG-000001 where its kind is numbered so.
   function Normalized (Given : String) return String is
      Upper : constant String := Ada.Characters.Handling.To_Upper (Given);
      Dash  : constant Natural := Ada.Strings.Fixed.Index (Upper, "-");
   begin
      if Dash = 0 or else Upper (Upper'First .. Dash - 1) not in "AG" | "INV" | "VER" | "RES" | "CTX"
      then
         return Given;
      end if;
      declare
         Rest : constant String := Upper (Dash + 1 .. Upper'Last);
      begin
         if Upper (Upper'First .. Dash - 1) in "AG" | "INV" | "VER"
           and then Rest'Length in 1 .. 5 and then (for all C of Rest => C in '0' .. '9')
         then
            return Upper (Upper'First .. Dash) & [1 .. 6 - Rest'Length => '0'] & Rest;
         end if;
         return Upper;
      end;
   end Normalized;
   --  A result by the start of its identifier, where one alone
   --  begins so: RES-F510 or F510 is RES-F510869C5653C6C4.
   --  A start that several results begin with: those, as said.
   Several : Unbounded_String;

   function Unique (Given : String) return String is
      Upper : constant String := Ada.Characters.Handling.To_Upper (Given);
      Whole : constant String :=
        (if Upper'Length >= 4 and then Upper (Upper'First .. Upper'First + 3) = "RES-" then Upper
         elsif Upper = "RES" then "RES-"
         else "RES-" & Upper);
      Found : Unbounded_String;
      Count : Natural := 0;
   begin
      --  Only a start of a result's identifier is looked for: hex
      --  digits, with RES- or without.
      if Given = "" or else S.Exists (Store, Model_Runner.Framework.Results_Area, Given)
        or else not (for all C of Whole (Whole'First + 4 .. Whole'Last) => C in '0' .. '9' | 'A' .. 'F')
      then
         return Given;
      end if;
      for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
         if Name'Length >= Whole'Length and then Name (Name'First .. Name'First + Whole'Length - 1) = Whole
         then
            Count := Count + 1;
            Found := To_Unbounded_String
              (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
               then Name (Name'First .. Name'Last - 4) else Name);
            if Count <= 5 then
               Append (Several, (if Count = 1 then "" else ", ") & To_String (Found));
            end if;
         end if;
      end loop;
      if Count > 1 then
         Several := To_Unbounded_String (Given & " is the start of" & Natural'Image (Count)
                                         & " results -- " & To_String (Several)
                                         & (if Count > 5 then ", ..." else "")
                                         & "; give more of the one meant");
      else
         Several := Null_Unbounded_String;
      end if;
      return (if Count = 1 then To_String (Found) else Given);
   end Unique;

   --  A task's: the newest issue its runs left, where there is one.
   function Latest_Of_Task (Named : String) return String is
      Found : Unbounded_String;
      When_Made : Unbounded_String;
   begin
      if Ada.Strings.Fixed.Index (Named, "TASK-") /= Named'First then
         return Named;
      end if;
      for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
         declare
            Result_Id : constant String :=
              (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
               then Name (Name'First .. Name'Last - 4) else Name);
            One : Rs.Result;
            Got : E.Error_Info;
         begin
            Rs.Read (Store, Result_Id, One, Got);
            --  An issue its runs left; of a complete task, its answer.
            if E.Is_Ok (Got)
              and then (Rs."=" (One.Kind, Rs.Diagnostic)
                        or else (Model_Runner.Framework.Tasks.State_Of (Store, Named)
                                   in "complete" | "failed" | "blocked"
                                 and then Rs.Kind_Word (One.Kind) in "analysis" | "implementation"))
              and then Task_Of_Issue (Store, One) = Named
              and then One.Created_At > When_Made
            then
               Found := To_Unbounded_String (Result_Id);
               When_Made := One.Created_At;
            end if;
         end;
      end loop;
      return (if Found = Null_Unbounded_String then Named else To_String (Found));
   end Latest_Of_Task;
   --  A number alone is a task's, as /task show 2 takes it -- of four
   --  digits or more, a result's start first, where one begins so.
   Digits_Only : constant Boolean :=
     Argument (1) /= "" and then Argument (1)'Length <= 6
     and then (for all C of Argument (1) => C in '0' .. '9');
   As_Result : constant String :=
     (if Digits_Only and then Argument (1)'Length < 4 then "" else Unique (Normalized (Argument (1))));
   Asked_Id : constant String :=
     (if Digits_Only and then (As_Result = "" or else As_Result = Argument (1))
      then "TASK-" & (if Argument (1)'Length >= 3 then Argument (1)
                      else [1 .. 3 - Argument (1)'Length => '0'] & Argument (1))
      else As_Result);
   Id    : constant String := Latest_Of_Task (Asked_Id);
   Asked_Several : constant Unbounded_String := Several;
   --  How the run a result came from ended, where it did not finish.
   Run_Ended : Unbounded_String;

   function Task_Of (One : Rs.Result) return String
   is (Task_Of_Issue (Store, One));

   --  Any identifier the harness prints: an invocation, a context's
   --  manifest, evidence or an agent is shown as it is recorded.
   function Starts (Prefix : String) return Boolean
   is (Id'Length > Prefix'Length and then Id (Id'First .. Id'First + Prefix'Length - 1) = Prefix);

   procedure Show_Record (Where : Model_Runner.Framework.Area; Name : String) is
      Value : R.Item;

      --  A record's field in words, not by its own name.
      function Words_For (Key : String) return String
      is (if Key = "ended_at" then "ended"
          --  A run's own state is its call's, not its task's.
          elsif Key = "state" and then Ada.Strings.Fixed.Index (Name, "INV-") = Name'First
          then "the call"
          elsif Key = "started_at" then "started"
          elsif Key = "failure_result" then "what its failure left"
          elsif Key = "result" then "what it left"
          elsif Key = "result_contract" then "what it was to give"
          elsif Key = "repository_revision" then "the project at"
          elsif Key = "template_version" then "its template's version"
          elsif Key = "exit_status" then "exit status"
          elsif Key = "passed" then "passed"
          elsif Key = "task" and then Ada.Strings.Fixed.Index (R.Get (Value, "task"), "REQ-") = 1
          then "requirement"
          elsif Key'Length > 12 and then Key (Key'First .. Key'First + 11) = "requirement."
          then Key (Key'First + 12 .. Key'Last) & " at revision"
          else Ada.Strings.Fixed.Translate (Key, Ada.Strings.Maps.To_Mapping ("_", " ")));

      --  One field, as its kind is said.
      procedure Show_One (Named : String) is
      begin
         --  A check's columns by what each is; other columns a tab
         --  apart shown as columns.
         if Named'Length > 6 and then Named (Named'First .. Named'First + 5) = "check."
         then
            declare
               function Split_Cells (Text : String) return Names.Vector is
                  Result : Names.Vector;
                  Start  : Positive := Text'First;
               begin
                  for Index in Text'First .. Text'Last + 1 loop
                     if Index > Text'Last or else Text (Index) = ASCII.HT then
                        Result.Append (Ada.Strings.Fixed.Trim
                                         (Text (Start .. Index - 1), Ada.Strings.Both));
                        Start := Index + 1;
                     end if;
                  end loop;
                  return Result;
               end Split_Cells;
               Cells : constant Names.Vector := Split_Cells (R.Get (Value, Named));
               function Cell (At_Index : Positive) return String
               is (if Natural (Cells.Length) >= At_Index then Cells (At_Index) else "");
            begin
               Field (Named, Cell (1) & ": " & Cell (5)
                      & " (exit " & Cell (3)
                      & ", " & Cell (4) & " s, " & Cell (6)
                      & (if Cell (8) = "warning" then ", a warning" else "")
                      & (if Cell (9) not in "" | "1" then ", tries " & Cell (9) else "")
                      & ")" & (if Cell (7) = "" then "" else "; log " & Cell (7))
                      & (if Cell (2) = "" then "" else "; ran " & Cell (2)));
            end;
         elsif Named = "summary" and then R.Has (Value, "depth") and then R.Get (Value, Named) = ""
         then
            Field (Named, "(it gave none)");
         elsif Named = "permissions" and then R.Has (Value, "depth") then
            --  An agent's: a line each, and create_children said
            --  spent where its depth leaves it none.
            declare
               Depth : constant Natural :=
                 Natural'Value ("0" & R.Get (Value, "depth"));
               Shown : Unbounded_String;
            begin
               for Line of Model_Runner.Framework.Lines_Of (R.Get (Value, Named)) loop
                  declare
                     Mark  : constant Natural := Ada.Strings.Fixed.Index (Line, "max_depth=");
                     Limit : Natural := Natural'Last;
                     Stop  : Natural;
                  begin
                     if Ada.Strings.Fixed.Index (Line, "create_children") = Line'First
                       and then Mark > 0
                     then
                        Stop := Mark + 10;
                        while Stop <= Line'Last and then Line (Stop) in '0' .. '9' loop
                           Stop := Stop + 1;
                        end loop;
                        if Stop > Mark + 10 then
                           Limit := Natural'Value (Line (Mark + 10 .. Stop - 1));
                        end if;
                     end if;
                     if Ada.Strings.Fixed.Trim (Line, Ada.Strings.Both) /= "" then
                        Append (Shown, (if Shown = Null_Unbounded_String then "" else "; ")
                                & Line
                                & (if Depth >= Limit then " (none at its depth)" else ""));
                     end if;
                  end;
               end loop;
               Field (Named, To_String (Shown));
            end;
         elsif Named not in "schema_id" | "schema_version" | "entity_id" | "revision" then
            Field (Words_For (Named), Ada.Strings.Fixed.Translate
                                        (R.Get (Value, Named),
                                         Ada.Strings.Maps.To_Mapping ([1 => ASCII.HT], " ")));
         end if;
      end Show_One;

      --  A check's record: what was checked, apart from how it came out.
      function Outcome_Field (Named : String) return Boolean
      is (Named in "passed" | "started_at" | "ended_at" | "diagnostics" | "summary"
          or else Ada.Strings.Fixed.Index (Named, "check.") = Named'First);
      function Hidden (Named : String) return Boolean
      is (R.Get (Value, Named) = ""
          or else Ada.Strings.Fixed.Index (Named, "environment.") = Named'First
          or else Ada.Strings.Fixed.Index (Named, "fingerprint") > 0
          --  What a requirement meant when checked: a digest, the
          --  harness's to compare, nothing to read.
          or else Ada.Strings.Fixed.Index (Named, "meaning.") = Named'First
          --  How the harness ran it, kept to run it again: not to read.
          or else Ada.Strings.Fixed.Index (Named, "adapter.") = Named'First
          or else Ada.Strings.Fixed.Index (Named, "given.") = Named'First
          or else Ada.Strings.Fixed.Index (Named, "parameters.") = Named'First
          or else Named in "schema_id" | "schema_version" | "entity_id" | "revision");
   begin
      S.Read (Store, Where, Name, Value, Read);
      if E.Is_Error (Read) and then not S.Exists (Store, Where, Name) then
         --  Named as it was asked for, not as it is kept.
         Read := E.Make (E.Framework_Not_Found);
         E.Add_Text (Read, "name", Id);
      end if;
      if E.Is_Error (Read) then
         Pres.Report (Screen, Read);
         return;
      end if;
      --  A run in groups, as a result is: what it was, how it ended,
      --  and its calls in order.
      if Ada.Strings.Fixed.Index (Name, "INV-") = Name'First then
         declare
            function Ending (Field_Name : String) return Boolean
            is (Field_Name in "state" | "outcome" | "ended_at" | "summary" | "reason" | "exit_status"
                  | "answer" | "status"
                or else Ada.Strings.Fixed.Index (Field_Name, "fail") > 0
                or else Ada.Strings.Fixed.Index (Field_Name, "result") > 0);
            function Call (Field_Name : String) return Boolean
            is (Ada.Strings.Fixed.Index (Field_Name, "call.") = Field_Name'First);
         begin
            Sectioned := True;
            Pres.Put_Header (Screen, "cli.result.heading", [Loc.Named ("name", Id)]);
            Pres.Put_Section (Screen, "cli.result.section.run");
            for Index in 1 .. R.Field_Count (Value) loop
               if not Ending (R.Field_Name (Value, Index)) and then not Call (R.Field_Name (Value, Index))
                 and then R.Get (Value, R.Field_Name (Value, Index)) /= ""
               then
                  declare
                     Key   : constant String := R.Field_Name (Value, Index);
                     Said  : constant String :=
                       Ada.Strings.Fixed.Trim (R.Get (Value, Key), Ada.Strings.Maps.Null_Set,
                                               Ada.Strings.Maps.To_Set ("; "));
                  begin
                     --  In words, not by the record's own names.
                     Field ((if Key = "context_manifest" then "context"
                             elsif Key = "resource_class" then "where it ran"
                             elsif Key = "result_contract" then "what it was to give"
                             elsif Key = "tool_policy" then "tools and permissions"
                             elsif Key = "started_at" then "started"
                             else Ada.Strings.Fixed.Translate (Key, Ada.Strings.Maps.To_Mapping ("_", " "))),
                            (if Key = "result_contract" and then Said = "work_claim"
                             then "a claim of work done, with what it changed"
                             elsif Key = "result_contract"
                             then Ada.Strings.Fixed.Translate (Said, Ada.Strings.Maps.To_Mapping ("_", " "))
                             else Said));
                  end;
               end if;
            end loop;
            Pres.Put_Section (Screen, "cli.result.section.ended");
            for Index in 1 .. R.Field_Count (Value) loop
               if Ending (R.Field_Name (Value, Index)) and then R.Get (Value, R.Field_Name (Value, Index)) /= ""
               then
                  Field (Words_For (R.Field_Name (Value, Index)),
                         (if R.Field_Name (Value, Index) = "result_contract"
                            and then R.Get (Value, "result_contract") = "work_claim"
                          then "a claim of work done, with what it changed"
                          else R.Get (Value, R.Field_Name (Value, Index))));
               end if;
            end loop;
            if (for some Index in 1 .. R.Field_Count (Value) => Call (R.Field_Name (Value, Index))) then
               Pres.Put_Section (Screen, "cli.result.section.calls");
               for Index in 1 .. R.Field_Count (Value) loop
                  if Call (R.Field_Name (Value, Index)) then
                     --  NAME, its arguments, and what came back: as the
                     --  trace shows a call, not a tab apart.
                     declare
                        Raw    : constant String := R.Get (Value, R.Field_Name (Value, Index));
                        First  : constant Natural := Ada.Strings.Fixed.Index (Raw, [1 => ASCII.HT]);
                        Second : constant Natural :=
                          (if First = 0 then 0
                           else Ada.Strings.Fixed.Index (Raw (First + 1 .. Raw'Last), [1 => ASCII.HT]));
                        --  And how it ended, where that is kept after it:
                        --  the last part, an answer having tabs of its own.
                        Last   : constant Natural :=
                          Ada.Strings.Fixed.Index (Raw, [1 => ASCII.HT], Ada.Strings.Backward);
                        Ended  : constant String := (if Last = 0 then "" else Raw (Last + 1 .. Raw'Last));
                        Third  : constant Natural :=
                          (if Last > Second and then Second > 0
                             and then (Ada.Strings.Fixed.Index (Ended, "answered") = Ended'First
                                       or else Ada.Strings.Fixed.Index (Ended, "failed") = Ended'First
                                       or else Ada.Strings.Fixed.Index (Ended, "refused") = Ended'First)
                           then Last
                           else 0);
                     begin
                        Field (R.Field_Name (Value, Index),
                               (if Third > 0
                                then Raw (Raw'First .. First - 1) & " " & Raw (First + 1 .. Second - 1)
                                     & " -> " & Ada.Strings.Fixed.Translate
                                                  (Raw (Second + 1 .. Third - 1),
                                                   Ada.Strings.Maps.To_Mapping ([1 => ASCII.HT], " "))
                                     & " [" & Raw (Third + 1 .. Raw'Last) & "]"
                                elsif Second > 0
                                then Raw (Raw'First .. First - 1) & " " & Raw (First + 1 .. Second - 1)
                                     & " -> " & Ada.Strings.Fixed.Translate
                                                  (Raw (Second + 1 .. Raw'Last),
                                                   Ada.Strings.Maps.To_Mapping ([1 => ASCII.HT], " "))
                                elsif First > 0
                                then Raw (Raw'First .. First - 1) & " " & Raw (First + 1 .. Raw'Last)
                                else Raw));
                     end;
                  end if;
               end loop;
            end if;
            Sectioned := False;
            if R.Get (Value, "task") /= "" then
               Pres.Put_Note (Screen, "cli.next.result_run", [Loc.Named ("name", R.Get (Value, "task"))]);
            end if;
         end;
         return;
      end if;
      if Ada.Strings.Fixed.Index (Name, "VER-") = Name'First then
         Sectioned := True;
         Pres.Put_Header (Screen, "cli.result.heading", [Loc.Named ("name", Id)]);
         Pres.Put_Section (Screen, "cli.result.section.checked");
         for Index in 1 .. R.Field_Count (Value) loop
            if not Outcome_Field (R.Field_Name (Value, Index)) and then not Hidden (R.Field_Name (Value, Index))
            then
               Show_One (R.Field_Name (Value, Index));
            end if;
         end loop;
         Pres.Put_Section (Screen, "cli.result.section.ended");
         for Index in 1 .. R.Field_Count (Value) loop
            if Outcome_Field (R.Field_Name (Value, Index)) and then not Hidden (R.Field_Name (Value, Index))
            then
               Show_One (R.Field_Name (Value, Index));
            end if;
         end loop;
         Sectioned := False;
         --  Its way on: the requirement or task it checked, or the
         --  project's checks.
         if Ada.Strings.Fixed.Index (R.Get (Value, "task"), "REQ-") = 1 then
            Pres.Put_Note (Screen, "cli.next.result_requirement", [Loc.Named ("name", R.Get (Value, "task"))]);
         elsif R.Get (Value, "task") /= "" then
            Pres.Put_Note (Screen, "cli.next.result_run", [Loc.Named ("name", R.Get (Value, "task"))]);
         else
            Pres.Put_Note (Screen, "cli.next.result_check");
         end if;
         return;
      end if;
      for Index in 1 .. R.Field_Count (Value) loop
         Show_One (R.Field_Name (Value, Index));
      end loop;
      --  An agent's two ends told apart where they differ.
      if R.Has (Value, "outcome") and then R.Has (Value, "state")
        and then R.Get (Value, "outcome") /= R.Get (Value, "state")
      then
         Field ("read as", "state is how its own run ended; outcome is where that left the task");
      end if;
   end Show_Record;
begin
   --  A start several begin with: which, asked.
   --  An analysis completed by hand: what the person found is its
   --  answer, over what its agent's run said.
   if Ada.Strings.Fixed.Index (Asked_Id, "TASK-") = Asked_Id'First
     and then Model_Runner.Framework.Tasks.State_Of (Store, Asked_Id) = Tk.Complete
   then
      declare
         Defined : R.Item;
         Got     : E.Error_Info;
         Notes   : Unbounded_String;
         At_Found : Natural;
      begin
         Model_Runner.Framework.Tasks.Definition (Store, Asked_Id, Defined, Got);
         Notes := To_Unbounded_String (R.Get (Defined, "notes"));
         At_Found := Ada.Strings.Unbounded.Index (Notes, "found: ");
         if E.Is_Ok (Got) and then R.Get (Defined, "kind") = "analysis" and then At_Found > 0 then
            Sectioned := True;
            Pres.Put_Header (Screen, "cli.result.heading", [Loc.Named ("name", Asked_Id)]);
            Pres.Put_Section (Screen, "cli.result.section.says");
            Field ("found", Slice (Notes, At_Found + 7, Length (Notes)));
            Sectioned := False;
            if Id /= Asked_Id then
               Pres.Put_Note (Screen, "cli.result.found_over_run",
                              [Loc.Named ("name", Asked_Id), Loc.Named ("value", Id)]);
            end if;
            return;
         --  Completed by hand with nothing found said, and no run's
         --  answer: how to say what was found.
         elsif E.Is_Ok (Got) and then R.Get (Defined, "kind") = "analysis" and then Id = Asked_Id then
            Pres.Put_Note (Screen, "cli.result.no_finding", [Loc.Named ("name", Asked_Id)]);
            return;
         end if;
      end;
   end if;
   --  A task's: how it stands said first -- failed and why, stopped
   --  in which run, complete and checked -- then its newest result.
   if Ada.Strings.Fixed.Index (Asked_Id, "TASK-") = Asked_Id'First and then Id /= Asked_Id then
      declare
         package Tks renames Model_Runner.Framework.Tasks;
         One      : Rs.Result;
         Got      : E.Error_Info;
         Last_Run : Unbounded_String;
         Ended    : Unbounded_String;
         State    : constant String := Tks.State_Of (Store, Asked_Id);
         Reasons  : constant Names.Vector := Tks.Ready (Store, Asked_Id).Reasons;
         Why      : constant String := (if Reasons.Is_Empty then "" else Reasons.First_Element);
         --  The result is of that run: its summary names it.
         function Of_Last_Run return Boolean
         is (Last_Run /= Null_Unbounded_String
             and then Ada.Strings.Unbounded.Index (One.Summary, To_String (Last_Run)) > 0);
      begin
         Rs.Read (Store, Id, One, Got);
         for Call of S.Names (Store, Model_Runner.Framework.Invocations_Area) loop
            declare
               Value : R.Item;
               Read  : E.Error_Info;
            begin
               S.Read (Store, Model_Runner.Framework.Invocations_Area, Call, Value, Read);
               if E.Is_Ok (Read) and then R.Get (Value, "task") = Asked_Id
                 and then R.Get (Value, "started_at") >= To_String (Ended)
                 and then Ada.Strings.Fixed.Index (Call, "INV-") = Call'First
               then
                  Ended := To_Unbounded_String (R.Get (Value, "started_at"));
                  Last_Run := To_Unbounded_String
                    (if Call'Length > 4 and then Call (Call'Last - 3 .. Call'Last) = ".rec"
                     then Call (Call'First .. Call'Last - 4) else Call);
               end if;
            end;
         end loop;
         if State = Tk.Blocked and then Ada.Strings.Fixed.Index (Why, "you stopped its work") > 0 then
            Pres.Put_Note (Screen,
                           (if Of_Last_Run then "cli.result.stopped_left" else "cli.result.since_stopped"),
                           [Loc.Named ("name", Asked_Id), Loc.Named ("value", Id),
                            Loc.Named ("other", To_String (Last_Run))]);
         elsif State = Tk.Failed then
            Pres.Put_Note (Screen, "cli.result.task_failed",
                           [Loc.Named ("name", Asked_Id),
                            Loc.Named ("detail", (if Ada.Strings.Fixed.Index (Why, "it failed: ") = Why'First
                                                  then Why (Why'First + 11 .. Why'Last) else Why)),
                            Loc.Named ("other", To_String (Last_Run))]);
         elsif State = Tk.Complete then
            declare
               Held  : R.Item;
               Read  : E.Error_Info;
            begin
               S.Read (Store, Model_Runner.Framework.Tasks_Area, Asked_Id & ".state", Held, Read);
               Pres.Put_Note (Screen, "cli.result.since_completed",
                              [Loc.Named ("name", Asked_Id), Loc.Named ("value", Id),
                               Loc.Named ("detail",
                                          (if E.Is_Ok (Read) and then R.Get (Held, "current_verification") /= ""
                                           then ", its checks passing in " & R.Get (Held, "current_verification")
                                           else ""))]);
            end;
         end if;
      end;
   end if;
   if Asked_Several /= Null_Unbounded_String then
      Outcome := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Outcome, "name", "the result");
      E.Add_Text (Outcome, "value", Argument (1));
      E.Add_Text (Outcome, "detail", To_String (Asked_Several));
      Pres.Report (Screen, Outcome);
      return;
   end if;

   --  result dismissed: the issues taken off the list, each with what
   --  it says; result restore ID|all: back on it.
   if Id = "dismissed" then
      declare
         Dismissed : constant Names.Vector := Dismissed_List (Store);
         Shown     : Natural := 0;
      begin
         for One_Id of Dismissed loop
            declare
               One : Rs.Result;
               Got : E.Error_Info;
            begin
               Rs.Read (Store, One_Id, One, Got, With_Payload => False);
               if E.Is_Ok (Got) then
                  --  Said as the list said it.
                  Field (One_Id, Issue_Said (Store, One_Id, To_String (One.Summary)));
                  Shown := Shown + 1;
               end if;
            end;
         end loop;
         if Shown = 0 then
            Pres.Put_Message (Screen, "cli.result.none_dismissed");
         else
            Pres.Put_Note (Screen, "cli.next.result_restore");
         end if;
      end;
      return;
   elsif Id = "restore" then
      declare
         Kept  : constant String :=
           Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "dismissed");
         --  Each dismissed once, and only what is still kept.
         function Still_Dismissed return Names.Vector is
            Result : Names.Vector;
         begin
            for One of Dismissed_List (Store) loop
               if not Result.Contains (One)
                 and then S.Exists (Store, Model_Runner.Framework.Results_Area, One)
               then
                  Result.Append (One);
               end if;
            end loop;
            return Result;
         end Still_Dismissed;
         Dismissed : constant Names.Vector := Still_Dismissed;
         Asked     : constant String :=
           (if Argument (2)'Length >= 4
              and then Ada.Characters.Handling.To_Upper
                         (Argument (2) (Argument (2)'First .. Argument (2)'First + 3)) = "RES-"
            then Ada.Characters.Handling.To_Upper (Argument (2))
            else "RES-" & Ada.Characters.Handling.To_Upper (Argument (2)));
         --  A start of one, among the dismissed only.
         function Matching return Names.Vector is
            Result : Names.Vector;
         begin
            for One of Dismissed loop
               if One'Length >= Asked'Length and then One (One'First .. One'First + Asked'Length - 1) = Asked
               then
                  Result.Append (One);
               end if;
            end loop;
            return Result;
         end Matching;
         Named : constant String :=
           (if Ada.Characters.Handling.To_Lower (Argument (2)) = "all" then "all"
            elsif Natural (Matching.Length) = 1 then Matching.First_Element
            else Argument (2));
         File  : Ada.Text_IO.File_Type;
      begin
         --  Several named: each one dismissed, or none is restored.
         if Natural (Positional.Length) > 2 then
            declare
               Back : Names.Vector;
            begin
               for Index in 2 .. Natural (Positional.Length) loop
                  declare
                     Word  : constant String := Ada.Characters.Handling.To_Upper (Argument (Index));
                     Start : constant String :=
                       (if Word'Length >= 4 and then Word (Word'First .. Word'First + 3) = "RES-" then Word
                        else "RES-" & Word);
                     Found : Names.Vector;
                  begin
                     for One of Dismissed loop
                        if One'Length >= Start'Length
                          and then One (One'First .. One'First + Start'Length - 1) = Start
                        then
                           Found.Append (One);
                        end if;
                     end loop;
                     if Natural (Found.Length) /= 1 then
                        Outcome := E.Make (E.Framework_Input_Invalid);
                        E.Add_Text (Outcome, "name", "an issue to restore");
                        E.Add_Text (Outcome, "value", Argument (Index));
                        E.Add_Text (Outcome, "detail",
                                    (if Found.Is_Empty then "it is no dismissed issue; /result dismissed lists"
                                                            & " them; nothing was restored"
                                     else "it is the start of several dismissed issues; nothing was"
                                          & " restored"));
                        Pres.Report (Screen, Outcome);
                        return;
                     end if;
                     Back.Append (Found.First_Element);
                  end;
               end loop;
               Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Kept);
               for One_Id of Dismissed loop
                  if not Back.Contains (One_Id) then
                     Ada.Text_IO.Put_Line (File, One_Id);
                  end if;
               end loop;
               Ada.Text_IO.Close (File);
               for One_Id of Back loop
                  Pres.Put_Message (Screen, "cli.result.restored", [Loc.Named ("name", One_Id)]);
               end loop;
               return;
            end;
         end if;
         if Natural (Matching.Length) > 1 and then Named /= "all" then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the issue to restore");
            E.Add_Text (Outcome, "value", Argument (2));
            E.Add_Text (Outcome, "detail", Argument (2) & " is the start of"
                        & Natural'Image (Natural (Matching.Length))
                        & " dismissed issues; give more of the one meant");
            Pres.Report (Screen, Outcome);
            return;
         end if;
         if Argument (2) = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "the issue to restore: /result restore RES-ID, as /result dismissed"
                        & " lists them, or all");
            Pres.Report (Screen, Outcome);
            return;
         elsif Named /= "all" and then not Dismissed.Contains (Named)
           and then S.Exists (Store, Model_Runner.Framework.Results_Area, Unique (Argument (2)))
         then
            --  On the list already: said, as a dismiss of a dismissed one
            --  is -- or what it is, where it is no issue or not listed.
            declare
               One : Rs.Result;
               Had : E.Error_Info;
            begin
               Rs.Read (Store, Unique (Argument (2)), One, Had, With_Payload => False);
               if E.Is_Ok (Had) and then not Rs."=" (One.Kind, Rs.Diagnostic) then
                  Pres.Put_Note (Screen, "cli.result.not_an_issue",
                                 [Loc.Named ("name", Unique (Argument (2))),
                                  Loc.Named ("value", Ada.Strings.Fixed.Translate
                                                        (Rs.Kind_Word (One.Kind),
                                                         Ada.Strings.Maps.To_Mapping ("_", " ")))]);
               elsif not Open_Issues (Store).Contains (Unique (Argument (2))) then
                  Pres.Put_Note (Screen, "cli.result.not_listed",
                                 [Loc.Named ("name", Unique (Argument (2))),
                                  Loc.Named ("detail", "it was dealt with already")]);
               else
                  Pres.Put_Note (Screen, "cli.result.listed_already",
                                 [Loc.Named ("name", Unique (Argument (2)))]);
               end if;
            end;
            return;
         elsif Named /= "all" and then not Dismissed.Contains (Named) then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the issue to restore");
            E.Add_Text (Outcome, "value", Argument (2));
            E.Add_Text (Outcome, "detail", "it is not dismissed; /result dismissed lists those that are");
            Pres.Report (Screen, Outcome);
            return;
         end if;
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Kept);
         for One_Id of Dismissed loop
            if Named /= "all" and then One_Id /= Named then
               Ada.Text_IO.Put_Line (File, One_Id);
            end if;
         end loop;
         Ada.Text_IO.Close (File);
         if Named = "all" and then Dismissed.Is_Empty then
            --  Nothing was dismissed: said as dismiss says nothing to do.
            Pres.Put_Message (Screen, "cli.result.nothing_dismissed");
         elsif Named = "all" then
            Pres.Put_Message (Screen, "cli.result.restored_all",
                              [Loc.Named ("count", Image (Natural (Dismissed.Length)))]);
         else
            Pres.Put_Message (Screen, "cli.result.restored", [Loc.Named ("name", Named)]);
         end if;
      end;
      return;
   end if;

   --  result dismiss ID: an issue a person has taken as read leaves the
   --  listing; the result itself is kept.
   if Id = "dismiss" then
      declare
         Named   : constant String := Unique (Argument (2));
         Ambiguous : constant Unbounded_String := Several;
         Kept    : constant String :=
           Hostkit.Fs.Join (Hostkit.Fs.Join (S.Root (Store), "runtime"), "dismissed");
         Got     : Rs.Result;
      begin
         Rs.Read (Store, Named, Got, Read, With_Payload => False);
         --  Words it keeps nothing of: refused, not dropped unsaid.
         if Command.Input_Count > 0 then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "what /result dismiss takes");
            E.Add_Text (Outcome, "value", T.To_String (Command.Inputs (1)));
            E.Add_Text (Outcome, "detail", "it takes issues' identifiers, or all, and keeps no reason");
            Pres.Report (Screen, Outcome);
            return;
         end if;
         --  all: every issue the listing shows, each as if named.
         if Ada.Characters.Handling.To_Lower (Argument (2)) = "all" then
            declare
               Count : Natural := 0;
               Counted : Names.Vector;
               File  : Ada.Text_IO.File_Type;
               Dismissed : constant Names.Vector := Dismissed_List (Store);
            begin
               if Ada.Directories.Exists (Kept) then
                  Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Kept);
               else
                  Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Kept);
               end if;
               for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
                  declare
                     Result_Id : constant String :=
                       (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                        then Name (Name'First .. Name'Last - 4) else Name);
                     One : Rs.Result;
                     Had : E.Error_Info;
                  begin
                     Rs.Read (Store, Result_Id, One, Had);
                     --  What the listing shows, counted as it shows it:
                     --  one said twice in the same words is one.
                     if E.Is_Ok (Had) and then Rs."=" (One.Kind, Rs.Diagnostic)
                       and then not Dismissed.Contains (Result_Id)
                       and then not Acted_On (Store, Result_Id, To_String (One.Summary))
                       and then not (Task_Of (One) /= ""
                                     and then Tk.State_Of (Store, Task_Of (One))
                                                in "accepted" | "running" | "verification" | "complete"
                                                 | "cancelled" | "rejected")
                     then
                        Ada.Text_IO.Put_Line (File, Result_Id);
                        if not Counted.Contains (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
                        then
                           Counted.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
                           Count := Count + 1;
                        end if;
                     end if;
                  end;
               end loop;
               Ada.Text_IO.Close (File);
               if Count = 0 then
                  Pres.Put_Note (Screen, "cli.result.nothing_to_dismiss");
               else
                  Pres.Put_Message (Screen, "cli.result.dismissed_all",
                                    [Loc.Named ("count", Image (Count))]);
               end if;
            end;
            return;
         end if;
         if Ambiguous /= Null_Unbounded_String then
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the issue to dismiss");
            E.Add_Text (Outcome, "value", Argument (2));
            E.Add_Text (Outcome, "detail", To_String (Ambiguous));
            Pres.Report (Screen, Outcome);
            return;
         elsif Named = "" then
            Outcome := E.Make (E.Framework_Input_Missing);
            E.Add_Text (Outcome, "name", "the issue to dismiss: /result dismiss RES-ID, as /result"
                        & " lists them, or all");
            Pres.Report (Screen, Outcome);
            return;
         elsif Dismissed_List (Store).Contains (Named) then
            Pres.Put_Note (Screen, "cli.result.dismissed_already", [Loc.Named ("name", Named)]);
            return;
         --  A record of another kind -- a check's log -- is no issue.
         elsif E.Is_Ok (Read) and then not Rs."=" (Got.Kind, Rs.Diagnostic) then
            Pres.Put_Note (Screen, "cli.result.not_an_issue",
                           [Loc.Named ("name", Named),
                            Loc.Named ("value", Ada.Strings.Fixed.Translate
                                                  (Rs.Kind_Word (Got.Kind),
                                                   Ada.Strings.Maps.To_Mapping ("_", " ")))]);
            return;
         --  Not on the list: nothing to take off, and why said.
         elsif E.Is_Ok (Read) and then Rs."=" (Got.Kind, Rs.Diagnostic)
           and then not Open_Issues (Store).Contains (Named)
         then
            Pres.Put_Note
              (Screen, "cli.result.not_listed",
               [Loc.Named ("name", Named),
                Loc.Named ("detail",
                           (if Task_Of (Got) /= ""
                              and then Tk.State_Of (Store, Task_Of (Got)) in "failed" | "blocked"
                            then "it is " & Task_Of (Got) & "'s, which /result lists as the task: /task show "
                                 & Task_Of (Got) & " says where it stands"
                            else "it was dealt with already"))]);
            return;
         elsif Named /= ""
           and then (E.Is_Ok (Read) or else Ada.Strings.Fixed.Index (Named, "-") > Named'First)
           and then (E.Is_Error (Read) or else not Rs."=" (Got.Kind, Rs.Diagnostic))
           and then Ada.Strings.Fixed.Index (Named, "RES-") /= Named'First
         then
            --  Something else the harness names: not an issue.
            Outcome := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Outcome, "name", "the issue to dismiss");
            E.Add_Text (Outcome, "value", Named);
            E.Add_Text (Outcome, "detail",
                        (if Ada.Strings.Fixed.Head (Named, 5) = "TASK-"
                         then Named & " is a task, not an issue: it leaves the list when /task accept "
                              & Named & " takes it up again, /task complete " & Named & " takes it as done"
                              & " or /task cancel " & Named & " lets it go"
                         else Named & " is not an issue; /result lists the issues"));
            Pres.Report (Screen, Outcome);
            return;
         elsif Named = "" or else E.Is_Error (Read) then
            Outcome := E.Make (E.Framework_Not_Found);
            E.Add_Text (Outcome, "name", (if Named = "" then "the issue to dismiss" else Named));
            Pres.Report (Screen, Outcome);
            return;
         end if;
         declare
            File : Ada.Text_IO.File_Type;
         begin
            if Ada.Directories.Exists (Kept) then
               Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Kept);
            else
               Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Kept);
            end if;
            Ada.Text_IO.Put_Line (File, Named);
            Ada.Text_IO.Close (File);
         end;
         Pres.Put_Message (Screen, "cli.result.dismissed", [Loc.Named ("name", Named)]);
         --  Several named: each after the first, alike.
         for Index in 3 .. Natural (Positional.Length) loop
            declare
               Other : constant String := Unique (Argument (Index));
               One   : Rs.Result;
               Had   : E.Error_Info;
               File  : Ada.Text_IO.File_Type;
            begin
               Rs.Read (Store, Other, One, Had, With_Payload => False);
               if E.Is_Ok (Had) and then not Rs."=" (One.Kind, Rs.Diagnostic) then
                  Pres.Put_Note (Screen, "cli.result.not_an_issue",
                                 [Loc.Named ("name", Other),
                                  Loc.Named ("value", Ada.Strings.Fixed.Translate
                                                        (Rs.Kind_Word (One.Kind),
                                                         Ada.Strings.Maps.To_Mapping ("_", " ")))]);
               elsif E.Is_Error (Had) then
                  Outcome := E.Make (E.Framework_Not_Found);
                  E.Add_Text (Outcome, "name", "the issue " & Argument (Index));
                  Pres.Report (Screen, Outcome);
               elsif Dismissed_List (Store).Contains (Other) then
                  Pres.Put_Note (Screen, "cli.result.dismissed_already", [Loc.Named ("name", Other)]);
               else
                  Ada.Text_IO.Open (File, Ada.Text_IO.Append_File, Kept);
                  Ada.Text_IO.Put_Line (File, Other);
                  Ada.Text_IO.Close (File);
                  Pres.Put_Message (Screen, "cli.result.dismissed", [Loc.Named ("name", Other)]);
               end if;
            end;
         end loop;
      end;
      return;
   end if;

   if Id = "" or else Id = "all" then
      --  None named: the issues kept -- what bootstrap raised, what
      --  agents reported -- each by its identifier and what it says;
      --  not a command's output, which its evidence shows, and not
      --  one about an entry since retired or replaced: acted on.
      declare
         Shown : Natural := 0;
         Tasks_Shown : Natural := 0;
         --  The tasks the issues listed name: said there already.
         Issue_Tasks : Names.Vector;
         Said_Before : Names.Vector;

         Dismissed : constant Names.Vector := Dismissed_List (Store);

         --  Each as WHEN TAB ID TAB LINE, to be said newest first.
         Listed : Names.Vector;
         package Listed_Sorting is new Names.Generic_Sorting;
      begin
         for Name of S.Names (Store, Model_Runner.Framework.Results_Area) loop
            declare
               Result_Id : constant String :=
                 (if Name'Length > 4 and then Name (Name'Last - 3 .. Name'Last) = ".rec"
                  then Name (Name'First .. Name'Last - 4) else Name);
               One       : Rs.Result;
               Got       : E.Error_Info;
            begin
               Rs.Read (Store, Result_Id, One, Got);
               if E.Is_Ok (Got) and then Rs."=" (One.Kind, Rs.Diagnostic)
                 and then not Dismissed.Contains (Result_Id)
                 and then not Acted_On (Store, Result_Id, To_String (One.Summary))
                 --  An attempt's issue whose task was taken up again
                 --  since, or ended: acted on.
                 and then not (Task_Of (One) /= ""
                               and then Tk.State_Of (Store, Task_Of (One))
                                          in "accepted" | "running" | "verification" | "complete"
                                           | "cancelled" | "rejected")
                 --  Said the same, in the same words, once: two attempts
                 --  that report one thing are one issue here.
                 and then not Said_Before.Contains
                                (To_String (One.Summary) & ASCII.LF & To_String (One.Payload))
               then
                  Said_Before.Append (To_String (One.Summary) & ASCII.LF & To_String (One.Payload));
                  Listed.Append (To_String (One.Created_At) & ASCII.HT & Result_Id & ASCII.HT
                                 & (if Task_Of (One) /= ""
                                      and then Ada.Strings.Fixed.Index
                                                 (To_String (One.Summary), Task_Of (One)) = 0
                                    then Task_Of (One) & ": " else "")
                                 & Issue_Said (Store, Result_Id, To_String (One.Summary)));
                  Shown := Shown + 1;
               end if;
            end;
         end loop;
         Listed_Sorting.Sort (Listed);
         --  A task's newest issue only: an older attempt's is behind
         --  it, as the run since says.
         declare
            Newest_Of : Names.Vector;
            Kept      : Names.Vector;
         begin
            for One of reverse Listed loop
               declare
                  First_Tab : constant Natural := Ada.Strings.Fixed.Index (One, [1 => ASCII.HT]);
                  Second    : constant Natural :=
                    Ada.Strings.Fixed.Index (One (First_Tab + 1 .. One'Last), [1 => ASCII.HT]);
                  Text      : constant String := One (Second + 1 .. One'Last);
                  At_Task   : constant Natural := Ada.Strings.Fixed.Index (Text, "TASK-");
                  Stop      : Natural := At_Task + 5;
               begin
                  if At_Task > 0 then
                     while Stop <= Text'Last and then Text (Stop) in '0' .. '9' loop
                        Stop := Stop + 1;
                     end loop;
                  end if;
                  declare
                     Owner : constant String := (if At_Task = 0 then "" else Text (At_Task .. Stop - 1));
                     Run_Failure : constant Boolean := Ada.Strings.Fixed.Index (Text, " failed") > 0;
                  begin
                     if Owner /= "" and then Run_Failure and then Newest_Of.Contains (Owner) then
                        Shown := Shown - 1;
                     else
                        if Owner /= "" and then Run_Failure then
                           Newest_Of.Append (Owner);
                        end if;
                        Kept.Prepend (One);
                     end if;
                  end;
               end;
            end loop;
            Listed := Kept;
         end;
         if not Listed.Is_Empty then
            Pres.Put_Section (Screen, "cli.result.section.issues");
         end if;
         for One of reverse Listed loop
            declare
               First_Tab  : constant Natural := Ada.Strings.Fixed.Index (One, [1 => ASCII.HT]);
               Second_Tab : constant Natural :=
                 Ada.Strings.Fixed.Index (One (First_Tab + 1 .. One'Last), [1 => ASCII.HT]);
               Text       : constant String := One (Second_Tab + 1 .. One'Last);
               At_Task    : constant Natural := Ada.Strings.Fixed.Index (Text, "TASK-");
               Stop       : Natural := At_Task + 5;
            begin
               Field (One (First_Tab + 1 .. Second_Tab - 1), Text);
               --  Its task said once: here, not again below.
               if At_Task > 0 then
                  while Stop <= Text'Last and then Text (Stop) in '0' .. '9' loop
                     Stop := Stop + 1;
                  end loop;
                  Issue_Tasks.Append (Text (At_Task .. Stop - 1));
               end if;
            end;
         end loop;
         --  The tasks whose last run failed or was stopped, each with
         --  why: what went wrong is found here, not only in /work's
         --  output -- one line a task, its newest attempt.
         declare
            Ended_Badly : Names.Vector := Tk.List (Store, "failed");
            Said_Any    : Boolean := False;
         begin
            Ended_Badly.Append (Tk.List (Store, "blocked"));
            for Id of Ended_Badly loop
               declare
                  Reasons : constant Names.Vector := Tk.Ready (Store, Id).Reasons;
                  Why     : constant String := (if Reasons.Is_Empty then "" else Reasons.First_Element);
               begin
                  --  Waiting for its parts is no failure.
                  if Why /= "" and then Ada.Strings.Fixed.Index (Why, "waiting for its children") = 0
                    and then Ada.Strings.Fixed.Index (Why, "its child ") /= Why'First
                    and then not Issue_Tasks.Contains (Id)
                  then
                     if not Said_Any then
                        Pres.Put_Section (Screen, "cli.result.section.tasks");
                        Said_Any := True;
                     end if;
                     --  Its state once: failed, then why -- not "failed: it failed".
                     Field (Id, (if Ada.Strings.Fixed.Index (Why, "it failed: ") = Why'First
                                 then "failed: " & Why (Why'First + 11 .. Why'Last)
                                 --  Stopped, as /task list says it.
                                 elsif Ada.Strings.Fixed.Index (Why, "it is blocked: you stopped") = Why'First
                                   or else Ada.Strings.Fixed.Index (Why, "it is stopped: you stopped") = Why'First
                                 then "stopped: " & Why (Why'First + 15 .. Why'Last)
                                 elsif Ada.Strings.Fixed.Index (Why, "it ") = Why'First
                                 then Why
                                 else Tk.State_Of (Store, Id) & ": " & Why));
                     Shown := Shown + 1;
                     Tasks_Shown := Tasks_Shown + 1;
                  end if;
               end;
            end loop;
         end;
         if Shown = 0 then
            Pres.Put_Message (Screen, "cli.result.none");
            --  The project's last check failed: that is what to look at.
            declare
               Last : constant Names.Vector := S.Names (Store, Model_Runner.Framework.Verification_Area);
               Held : R.Item;
               Got  : E.Error_Info;
            begin
               if not Last.Is_Empty then
                  S.Read (Store, Model_Runner.Framework.Verification_Area, Last.Last_Element, Held, Got);
                  if E.Is_Ok (Got) and then R.Get (Held, "passed") /= "true" then
                     Pres.Put_Note (Screen, "cli.result.last_check_failed",
                                    [Loc.Named ("name", Last.Last_Element)]);
                  end if;
               end if;
            end;
         elsif Shown > Tasks_Shown then
            Pres.Put_Note (Screen, "cli.next.result_dismiss");
         end if;
         --  A failed task is dealt with as a task, not dismissed.
         if Tasks_Shown > 0 then
            Pres.Put_Note (Screen, "cli.next.result_tasks");
         end if;
      end;
      return;
   elsif (Starts ("TASK-") and then Tk.State_Of (Store, Id) = "")
     or else (Starts ("REQ-") and then Nt.State_Of (Store, Nt.Requirement, Id) = "")
     or else (Starts ("DEC-") and then Nt.State_Of (Store, Nt.Decision, Id) = "")
     or else (Starts ("SPEC-") and then Nt.State_Of (Store, Nt.Specification, Id) = "")
   then
      Read := E.Make (E.Framework_Not_Found);
      E.Add_Text (Read, "name", Id);
      Pres.Report (Screen, Read);
      return;
   elsif Starts ("TASK-") or else Starts ("REQ-") or else Starts ("DEC-") or else Starts ("SPEC-")
   then
      --  A task with nothing kept of a run: said so first.
      if Starts ("TASK-") and then Tk.State_Of (Store, Id) in "candidate" | "accepted" | "rejected" | "cancelled"
      then
         Pres.Put_Note (Screen, "cli.result.task_not_run", [Loc.Named ("name", Id)]);
         --  How it comes to have one.
         if Tk.State_Of (Store, Id) = Tk.Accepted and then Tk.Ready (Store, Id).Ready then
            Pres.Put_Note (Screen, "cli.next.work", [Loc.Named ("name", Id)]);
            return;
         elsif Tk.State_Of (Store, Id) = Tk.Candidate then
            Pres.Put_Note (Screen, "cli.next.accept_one_task", [Loc.Named ("name", Id)]);
            return;
         end if;
      end if;
      --  Its work waiting to be taken in: where, and the way on.
      if Starts ("TASK-") and then Tk.State_Of (Store, Id) = Tk.Verification
        and then Model_Runner.Framework.Workspaces.Active_For (Store, Id) /= ""
      then
         Pres.Put_Note (Screen, "cli.result.waits_integration",
                        [Loc.Named ("name", Id),
                         Loc.Named ("value", Model_Runner.Framework.Workspaces.Active_For (Store, Id))]);
         return;
      end if;
      Pres.Put_Note
        (Screen, "cli.result.elsewhere",
         [Loc.Named ("name", Id),
          Loc.Named ("value", (if Starts ("TASK-") then "/task show " & Id & " and /task audit " & Id
                               elsif Starts ("REQ-") then "/req show " & Id
                               elsif Starts ("DEC-") then "/decision show " & Id
                               else "/spec show " & Id))]);
      return;
   elsif Starts ("INV-") then
      Show_Record (Model_Runner.Framework.Invocations_Area, Id);
      return;
   elsif Starts ("CTX-") then
      Show_Record (Model_Runner.Framework.Invocations_Area, "manifest." & Id);
      return;
   elsif Starts ("VER-") then
      Show_Record (Model_Runner.Framework.Verification_Area, Id);
      return;
   elsif Starts ("AG-") then
      Show_Record (Model_Runner.Framework.Runtime_Area, "agent." & Id);
      return;
   end if;
   Rs.Read (Store, Id, Held, Read, With_Payload => Whole);
   if E.Is_Error (Read) then
      Pres.Report (Screen, Read);
      return;
   end if;
   --  In groups, as /task show is: what it is, what it says, and
   --  where it came from.
   Sectioned := True;
   Pres.Put_Header (Screen, "cli.result.heading", [Loc.Named ("name", Id)]);
   --  Left by a run that failed or was stopped: what it is, not the
   --  work its kind names.
   declare
      Summary : constant String := To_String (Held.Summary);
      At_Inv  : constant Natural := Ada.Strings.Fixed.Index (Summary, "INV-");
      Inv_End : constant Natural :=
        (if At_Inv = 0 then 0
         else Ada.Strings.Fixed.Index (Summary & " ", Ada.Strings.Maps.To_Set (" ,;)"), At_Inv) - 1);
      Run     : R.Item;
      Got     : E.Error_Info;
   begin
      if At_Inv > 0 and then Rs.Kind_Word (Held.Kind) /= "diagnostic" then
         S.Read (Store, Model_Runner.Framework.Invocations_Area, Summary (At_Inv .. Inv_End), Run, Got);
         if E.Is_Ok (Got) and then R.Get (Run, "state") in "failed" | "cancelled" then
            Run_Ended :=
              To_Unbounded_String (if R.Get (Run, "state") = "failed" then "failed" else "was stopped");
         end if;
      end if;
   end;
   if Asked_Id /= Id then
      --  Completed by hand after a run that did not finish: that first.
      if Run_Ended /= Null_Unbounded_String
        and then Ada.Strings.Fixed.Index (Asked_Id, "TASK-") = Asked_Id'First
        and then Model_Runner.Framework.Tasks.State_Of (Store, Asked_Id) = Tk.Complete
      then
         Pres.Put_Note (Screen, "cli.result.hand_after_run",
                        [Loc.Named ("name", Asked_Id), Loc.Named ("value", To_String (Run_Ended))]);
      end if;
      Pres.Put_Note (Screen, "cli.result.latest_of", [Loc.Named ("name", Asked_Id), Loc.Named ("value", Id)]);
   end if;
   Pres.Put_Section (Screen, "cli.result.section.what");
   --  In words: an issue, of which task, made when and by what.
   Field ("kind", (if Run_Ended /= Null_Unbounded_String
                   then "what a run that " & To_String (Run_Ended) & " left -- no implementation"
                   elsif Rs.Kind_Word (Held.Kind) = "diagnostic" and then Task_Of (Held) /= ""
                     and then Model_Runner.Framework.Tasks.State_Of (Store, Task_Of (Held))
                              in "failed" | "blocked"
                   then "a failed run of " & Task_Of (Held) & " (/result lists it as the task)"
                   elsif Rs.Kind_Word (Held.Kind) = "diagnostic" then "an issue"
                   else Ada.Strings.Fixed.Translate (Rs.Kind_Word (Held.Kind),
                                                     Ada.Strings.Maps.To_Mapping ("_", " "))));
   if Task_Of (Held) /= "" then
      Field ("task", Task_Of (Held));
   end if;
   Field ("made by", (if To_String (Held.Producer) = "bootstrap" then "bootstrap, reading the documents"
                      elsif Ada.Strings.Fixed.Index (To_String (Held.Producer), "AG-") = 1
                      then "the agent " & To_String (Held.Producer)
                      else To_String (Held.Producer)));
   declare
      When_Made : constant String := To_String (Held.Created_At);
      Dot       : constant Natural := Ada.Strings.Fixed.Index (When_Made, ".");
      Cut       : constant String := (if Dot > 0 then When_Made (When_Made'First .. Dot - 1) else When_Made);
   begin
      Field ("made", Ada.Strings.Fixed.Translate
                       (Ada.Strings.Fixed.Trim (Cut, Ada.Strings.Maps.To_Set ("Z"),
                                                Ada.Strings.Maps.To_Set ("Z")),
                        Ada.Strings.Maps.To_Mapping ("T", " ")) & " UTC");
   end;
   if Dismissed_List (Store).Contains (Id) then
      Field ("dismissed", "yes: /result no longer lists it");
   elsif Rs."=" (Held.Kind, Rs.Diagnostic) and then not Open_Issues (Store).Contains (Id)
     and then not (Task_Of (Held) /= ""
                   and then Model_Runner.Framework.Tasks.State_Of (Store, Task_Of (Held)) in "failed" | "blocked")
   then
      Field ("state", "dealt with: /result no longer lists it");
   end if;
   Pres.Put_Section (Screen, "cli.result.section.says");
   --  A stopped or failed run's leftover named by its call alone:
   --  said as what it is.
   Field ("summary", (if Run_Ended /= Null_Unbounded_String
                        and then Ada.Strings.Fixed.Index (To_String (Held.Summary), "answer to INV-") = 1
                      then (if To_String (Run_Ended) = "was stopped" then "stopped before it answered"
                            else "failed before it answered")
                           & " (" & Ada.Strings.Fixed.Tail (To_String (Held.Summary),
                                                            Length (Held.Summary) - 10) & ")"
                      else Issue_Said (Store, Id, To_String (Held.Summary))));
   --  An answer to a run that failed: how, beside what it says.
   declare
      From : constant String :=
        Ada.Strings.Fixed.Trim (To_String (Held.Provenance),
                                Ada.Strings.Maps.To_Set (": "), Ada.Strings.Maps.Null_Set);
      Run  : R.Item;
      Got  : E.Error_Info;
   begin
      if Ada.Strings.Fixed.Index (From, "INV-") = From'First and then From'Length >= 10 then
         S.Read (Store, Model_Runner.Framework.Invocations_Area, From (From'First .. From'First + 9), Run, Got);
         --  Not the result shown itself.
         if E.Is_Ok (Got) and then R.Get (Run, "failure_result") not in "" | Id then
            Field ("the run failed", R.Get (Run, "failure_result"));
         end if;
      end if;
   end;
   --  What it holds, where it says more than its summary.
   if Whole and then (Length (Held.Payload) = 0
                      or else Ada.Strings.Unbounded.Index (Held.Summary, To_String (Held.Payload)) > 0)
   then
      null;
   --  Whole, as it is: a line at a time, not cut to fit a message.
   elsif Whole and then Pres.Is_Structured (Screen) then
      Field ("payload", To_String (Held.Payload));
   elsif Whole then
      Field ("payload", "");
      --  A line said over and over -- a model gone round -- shown a
      --  few times and then counted, as the run's own view does.
      declare
         Last    : Unbounded_String;
         Same    : Natural := 0;
         Skipped : Natural := 0;
      begin
         for Line of Model_Runner.Framework.Lines_Of (To_String (Held.Payload)) loop
            if Line /= "" and then To_String (Last) = Line then
               Same := Same + 1;
            else
               if Skipped > 0 then
                  Pres.Put_Line (Screen, "      ... the same line" & Natural'Image (Skipped) & " times more");
                  Skipped := 0;
               end if;
               Same := 0;
               Last := To_Unbounded_String (Line);
            end if;
            if Same >= 3 then
               Skipped := Skipped + 1;
            else
               --  JSON coloured as JSON where colour shows.
               Pres.Put_Line (Screen, "      "
                                      & (if Pres.Styles_Answers (Screen)
                                           and then Pres.Looks_Like_JSON (To_String (Held.Payload))
                                         then Pres.JSON_Coloured (Line) else Line));
            end if;
         end loop;
         if Skipped > 0 then
            Pres.Put_Line (Screen, "      ... the same line" & Natural'Image (Skipped) & " times more");
         end if;
      end;
   else
      Field ("payload", "(" & Image (Size) & " bytes; /result " & Argument (1)
             & " full shows them)");
   end if;
   Pres.Put_Section (Screen, "cli.result.section.from");
   --  What it came from, without an empty part before its colon.
   declare
      From : constant String :=
        Ada.Strings.Fixed.Trim (To_String (Held.Provenance),
                                Ada.Strings.Maps.To_Set (": "), Ada.Strings.Maps.Null_Set);
   begin
      --  A model call by what it is: a run, /result INV-... showing it.
      if From /= "" then
         Field ("from", (if Ada.Strings.Fixed.Index (From, "INV-") = 1
                         then "the run " & From & " (/result " & From & " shows it)"
                         --  A document's line: the document, not the key it is kept by.
                         elsif Ada.Strings.Fixed.Index (From, "#") > From'First
                         then From (From'First .. Ada.Strings.Fixed.Index (From, "#") - 1)
                         else From));
      end if;
   end;
   for Other of Model_Runner.Framework.Lines_Of (To_String (Held.References)) loop
      Field ("references", Other);
   end loop;
   Sectioned := False;
   --  An issue still open: how to let it go.
   --  Of a task that failed or was stopped: dealt with as the task.
   if Task_Of (Held) /= ""
     and then Model_Runner.Framework.Tasks.State_Of (Store, Task_Of (Held)) in "failed" | "blocked"
   then
      Pres.Put_Note (Screen, "cli.next.result_task_retry", [Loc.Named ("name", Task_Of (Held))]);
   end if;
   --  One of a failed task is dealt with as the task: no dismissing.
   if Rs."=" (Held.Kind, Rs.Diagnostic) and then not Dismissed_List (Store).Contains (Id)
     and then Open_Issues (Store).Contains (Id)
     and then not (Task_Of (Held) /= ""
                   and then Model_Runner.Framework.Tasks.State_Of (Store, Task_Of (Held)) in "failed" | "blocked")
   then
      Pres.Put_Note (Screen, "cli.next.result_dismiss_one", [Loc.Named ("name", Id)]);
   end if;
end Show_Result;
