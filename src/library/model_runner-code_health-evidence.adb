with Model_Runner.Code_Health.Diagnostics;
with Model_Runner.Framework;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Code_Health.Evidence is

   use Ada.Strings.Unbounded;

   package B renames Model_Runner.Code_Health.Baselines;
   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;
   package F renames Model_Runner.Framework;
   package P renames Model_Runner.Code_Health.Providers;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;
   package V renames Model_Runner.Framework.Verification;

   use type E.Error_Code;
   use type P.Check_Status;
   use type V.Applicability;

   function Image (Value : Natural) return String is
      Said : constant String := Natural'Image (Value);
   begin
      return Said (Said'First + 1 .. Said'Last);
   end Image;

   function Number (Text : String; Good : out Boolean) return Natural is
      Result : Natural := 0;
   begin
      Good := Text /= "";
      for Letter of Text loop
         if Letter not in '0' .. '9' or else Result > (Natural'Last - 9) / 10 then
            Good := False;
            return 0;
         end if;
         Result := Result * 10 + Character'Pos (Letter) - Character'Pos ('0');
      end loop;
      return Result;
   end Number;

   function Level_Word (Value : Check_Level) return String is
     (case Value is when Fast => "fast", when Focused => "focused", when Full => "full");

   function State_Word (Value : Health_State) return String is
     (case Value is
         when Not_Started      => "not_started",
         when Checking         => "checking",
         when Passed           => "passed",
         when Findings_Present => "findings_present",
         when Blocked          => "blocked",
         when Unavailable      => "unavailable",
         when Stale            => "stale",
         when Cancelled        => "cancelled");

   function Check_Word (Value : P.Check_Status) return String is
     (case Value is
         when P.Check_Not_Run     => "not_run",
         when P.Check_Passed      => "passed",
         when P.Check_Findings    => "findings",
         when P.Check_Unavailable => "unavailable",
         when P.Check_Timed_Out   => "timed_out",
         when P.Check_Cancelled   => "cancelled",
         when P.Check_Failed      => "failed",
         when P.Check_Stale       => "stale");

   function Finding_Word (Value : B.Finding_State) return String is
     (case Value is
         when B.New_Finding      => "new",
         when B.Existing_Finding => "existing",
         when B.Resolved_Finding => "resolved",
         when B.Changed_Finding  => "changed",
         when B.Unknown_Finding  => "unknown");

   procedure Refuse (Status : out E.Error_Info; Detail : String) is
   begin
      Status := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Status, "name", "Code Health assessment");
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   function Valid (Context : Assessment_Context) return Boolean is
     (Length (Context.Project) > 0
      and then Length (Context.Snapshot) > 0
      and then Length (Context.Configuration_Fingerprint) > 0
      and then Length (Context.Toolchain_Fingerprint) > 0
      and then Length (Context.Environment_Fingerprint) > 0
      and then Length (Context.Profile) > 0);

   function Cacheable (Value : Assessment) return Boolean is
      Checks : Natural := 0;
   begin
      if Length (Value.Cache_Key) = 0
        or else Value.State not in Passed | Findings_Present | Blocked
        or else Value.Results.Is_Empty
      then
         return False;
      end if;
      for Result of Value.Results loop
         for Check of Result.Checks loop
            Checks := Checks + 1;
            if Check.Status not in P.Check_Passed | P.Check_Findings then
               return False;
            end if;
         end loop;
      end loop;
      return Checks > 0;
   end Cacheable;

   procedure Create
     (Context         : Assessment_Context;
      Level           : Check_Level;
      State           : Health_State;
      Results         : Analysis_Result_Lists.Vector;
      Classifications : B.Classification_List;
      Baseline_Id     : String;
      Cache_Key       : String;
      Result          : out Assessment;
      Status          : out E.Error_Info)
   is
      Required_Unavailable : Boolean := False;
      Required_Cancelled   : Boolean := False;
      Required_Stale       : Boolean := False;
      Has_Findings         : Boolean := False;
   begin
      Result := (others => <>);
      if not Valid (Context) then
         Refuse (Status, "assessment context is incomplete");
         return;
      elsif State in Not_Started | Checking then
         Refuse (Status, "only completed assessments can become evidence");
         return;
      end if;
      for One of Results loop
         P.Validate_Result
           (One, Status, Expected_Snapshot => To_String (Context.Snapshot),
            Project_Root => To_String (Context.Project));
         if E.Is_Error (Status) then
            Refuse (Status, "provider result failed structural validation");
            return;
         elsif To_String (One.Input_Fingerprint) /= To_String (Context.Snapshot) then
            Refuse (Status, "a provider result belongs to another source snapshot");
            return;
         elsif To_String (One.Configuration_Fingerprint)
                 /= To_String (Context.Configuration_Fingerprint)
         then
            Refuse (Status, "a provider result belongs to another configuration");
            return;
         end if;
         for Index in 1 .. D.Length (One.Diagnostics) loop
            Has_Findings := True;
            if To_String (D.Element (One.Diagnostics, Index).Snapshot) /= To_String (Context.Snapshot) then
               Refuse (Status, "a diagnostic belongs to another source snapshot");
               return;
            end if;
         end loop;
         for Check of One.Checks loop
            Has_Findings := Has_Findings or else Check.Status = P.Check_Findings;
            if Check.Required then
               Required_Unavailable :=
                 Required_Unavailable
                 or else Check.Status in
                   P.Check_Not_Run | P.Check_Unavailable | P.Check_Timed_Out | P.Check_Failed;
               Required_Cancelled := Required_Cancelled or else Check.Status = P.Check_Cancelled;
               Required_Stale := Required_Stale or else Check.Status = P.Check_Stale;
            end if;
         end loop;
      end loop;
      if State = Passed
        and then (Results.Is_Empty or else Has_Findings
                  or else Required_Unavailable or else Required_Cancelled or else Required_Stale)
      then
         Refuse (Status, "passing evidence does not contain a complete clean assessment");
         return;
      elsif State in Passed | Findings_Present | Blocked
        and then (Required_Unavailable or else Required_Cancelled or else Required_Stale)
      then
         Refuse (Status, "a required operational failure cannot become passing assessment evidence");
         return;
      elsif State = Cancelled and then not Required_Cancelled and then not Results.Is_Empty then
         Refuse (Status, "cancelled evidence contains no cancelled required check");
         return;
      elsif State = Stale and then not Required_Stale and then not Results.Is_Empty then
         Refuse (Status, "stale evidence contains no stale required check");
         return;
      end if;
      Result.Context := Context;
      Result.Level := Level;
      Result.State := State;
      Result.Results := Results;
      Result.Classifications := Classifications;
      Result.Baseline := To_Unbounded_String (Baseline_Id);
      Result.Cache_Key := To_Unbounded_String (Cache_Key);
      Status := E.Success;
   end Create;

   function Identifier (Item : Assessment) return String is (To_String (Item.Id));
   function Context_Of (Item : Assessment) return Assessment_Context is (Item.Context);
   function Level_Of (Item : Assessment) return Check_Level is (Item.Level);
   function State_Of (Item : Assessment) return Health_State is (Item.State);
   function Results_Of (Item : Assessment) return Analysis_Result_Lists.Vector is (Item.Results);
   function Classifications_Of (Item : Assessment) return B.Classification_List is (Item.Classifications);
   function Baseline_Of (Item : Assessment) return String is (To_String (Item.Baseline));
   function Cache_Key_Of (Item : Assessment) return String is (To_String (Item.Cache_Key));

   function Make_Cache_Key
     (Provider_Id               : String;
      Provider_Version          : String;
      Check_Id                  : String;
      Input_Snapshot            : String;
      Configuration_Fingerprint : String;
      Toolchain_Fingerprint     : String;
      Environment_Fingerprint   : String) return String
   is
      Key : R.Item := R.Create ("code_health.cache_key", 1, "CACHE", 1);
   begin
      R.Set (Key, "provider", Provider_Id);
      R.Set (Key, "provider_version", Provider_Version);
      R.Set (Key, "check", Check_Id);
      R.Set (Key, "input", Input_Snapshot);
      R.Set (Key, "configuration", Configuration_Fingerprint);
      R.Set (Key, "toolchain", Toolchain_Fingerprint);
      R.Set (Key, "environment", Environment_Fingerprint);
      return R.Fingerprint_Of (Key);
   end Make_Cache_Key;

   function Result_Record (Value : P.Analysis_Result) return R.Item is
      Held : R.Item := R.Create ("code_health.provider_result", 1, "RESULT", 1);
   begin
      R.Set (Held, "provider", To_String (Value.Provider_Id));
      R.Set (Held, "provider_version", To_String (Value.Provider_Version));
      R.Set (Held, "input", To_String (Value.Input_Fingerprint));
      R.Set (Held, "configuration", To_String (Value.Configuration_Fingerprint));
      R.Set (Held, "toolchain", To_String (Value.Toolchain_Fingerprint));
      R.Set (Held, "environment", To_String (Value.Environment_Fingerprint));
      R.Set (Held, "timed_out", (if Value.Timed_Out then "true" else "false"));
      R.Set (Held, "cancelled", (if Value.Cancelled then "true" else "false"));
      R.Set (Held, "exit_status", Integer'Image (Value.Exit_Status));
      R.Set (Held, "duration", Standard.Duration'Image (Value.Duration));
      R.Set (Held, "resources", To_String (Value.Resource_Summary));
      for Index in 1 .. Natural (Value.Files_Analyzed.Length) loop
         R.Set
           (Held, "file." & R.Numbered (Index, Natural (Value.Files_Analyzed.Length)),
            Value.Files_Analyzed.Element (Index));
      end loop;
      for Index in 1 .. Natural (Value.Evidence.Length) loop
         R.Set
           (Held, "evidence." & R.Numbered (Index, Natural (Value.Evidence.Length)),
            Value.Evidence.Element (Index));
      end loop;
      return Held;
   end Result_Record;

   function Check_Record (Value : P.Check_Result) return R.Item is
      Held : R.Item := R.Create ("code_health.check_result", 1, "CHECK", 1);
   begin
      R.Set (Held, "identifier", To_String (Value.Identifier));
      R.Set (Held, "status", Check_Word (Value.Status));
      R.Set (Held, "required", (if Value.Required then "true" else "false"));
      R.Set (Held, "detail", To_String (Value.Detail));
      R.Set (Held, "evidence", To_String (Value.Evidence));
      return Held;
   end Check_Record;

   procedure Keep
     (Item     : S.Store;
      Change   : in out S.Transaction;
      Value    : in out Assessment;
      Status   : out E.Error_Info)
   is
      Number : Natural;
   begin
      if Length (Value.Id) > 0 then
         Status := E.Make (E.Framework_Result_Conflict);
         E.Add_Text (Status, "name", To_String (Value.Id));
         E.Add_Text (Status, "detail", "immutable assessment evidence cannot be replaced");
         return;
      elsif not Valid (Value.Context) then
         Refuse (Status, "assessment context is incomplete");
         return;
      end if;
      S.Allocate_Number (Item, Change, "CH", "", Number, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         Id   : constant String := "CH-" & R.Numbered (Number, 3);
         Now  : constant String := F.Timestamp;
         Held : R.Item := R.Create (Model_Runner.Framework.Schemas.Evidence_Schema, 1, Id, 1);
      begin
         R.Set (Held, "profile", To_String (Value.Context.Profile));
         R.Set (Held, "task", To_String (Value.Context.Task_Id));
         R.Set (Held, "started_at", Now);
         R.Set (Held, "ended_at", Now);
         R.Set (Held, "repository_revision", To_String (Value.Context.Snapshot));
         R.Set (Held, "configuration_fingerprint", To_String (Value.Context.Configuration_Fingerprint));
         R.Set (Held, "passed", (if Value.State in Passed | Findings_Present then "true" else "false"));
         R.Set (Held, "code_health.kind", "assessment");
         R.Set (Held, "code_health.level", Level_Word (Value.Level));
         R.Set (Held, "code_health.state", State_Word (Value.State));
         R.Set (Held, "code_health.project", To_String (Value.Context.Project));
         R.Set (Held, "code_health.generation", Image (Value.Context.Generation));
         R.Set (Held, "code_health.agent", To_String (Value.Context.Agent_Id));
         R.Set (Held, "code_health.invocation", To_String (Value.Context.Invocation_Id));
         R.Set (Held, "code_health.workspace", To_String (Value.Context.Workspace));
         R.Set (Held, "code_health.toolchain_fingerprint", To_String (Value.Context.Toolchain_Fingerprint));
         R.Set (Held, "code_health.environment_fingerprint", To_String (Value.Context.Environment_Fingerprint));
         R.Set (Held, "code_health.baseline", To_String (Value.Baseline));
         R.Set (Held, "code_health.cache_key", To_String (Value.Cache_Key));
         R.Set (Held, "code_health.cacheable", (if Cacheable (Value) then "true" else "false"));
         for Result_Index in 1 .. Natural (Value.Results.Length) loop
            declare
               One : constant P.Analysis_Result := Value.Results.Element (Result_Index);
               Prefix : constant String := R.Numbered (Result_Index, Natural (Value.Results.Length));
            begin
               R.Set (Held, "code_health.result." & Prefix, R.Serialize (Result_Record (One)));
               for Check_Index in 1 .. Natural (One.Checks.Length) loop
                  R.Set
                    (Held, "code_health.check." & Prefix & "."
                       & R.Numbered (Check_Index, Natural (One.Checks.Length)),
                     R.Serialize (Check_Record (One.Checks.Element (Check_Index))));
               end loop;
               for Diagnostic_Index in 1 .. D.Length (One.Diagnostics) loop
                  R.Set
                    (Held, "code_health.diagnostic." & Prefix & "."
                       & R.Numbered (Diagnostic_Index, D.Length (One.Diagnostics)),
                     D.Serialize (D.Element (One.Diagnostics, Diagnostic_Index)));
               end loop;
            end;
         end loop;
         for Index in 1 .. B.Length (Value.Classifications) loop
            declare
               One : constant B.Classified_Finding := B.Element (Value.Classifications, Index);
               Classification : R.Item :=
                 R.Create ("code_health.classification", 1, "CLASSIFICATION", 1);
            begin
               R.Set (Classification, "state", Finding_Word (One.State));
               R.Set (Classification, "current", To_String (One.Current.Fingerprint));
               R.Set (Classification, "previous", To_String (One.Previous.Fingerprint));
               R.Set
                 (Held, "code_health.classification."
                    & R.Numbered (Index, B.Length (Value.Classifications)),
                  R.Serialize (Classification));
            end;
         end loop;
         S.Put (Change, F.Verification_Area, Id, Held);
         Value.Id := To_Unbounded_String (Id);
         Status := E.Success;
      end;
   end Keep;

   function Check_Status_Of (Text : String; Found : out Boolean) return P.Check_Status is
   begin
      Found := True;
      if Text = "not_run" then
         return P.Check_Not_Run;
      elsif Text = "passed" then
         return P.Check_Passed;
      elsif Text = "findings" then
         return P.Check_Findings;
      elsif Text = "unavailable" then
         return P.Check_Unavailable;
      elsif Text = "timed_out" then
         return P.Check_Timed_Out;
      elsif Text = "cancelled" then
         return P.Check_Cancelled;
      elsif Text = "failed" then
         return P.Check_Failed;
      elsif Text = "stale" then
         return P.Check_Stale;
      else
         Found := False;
         return P.Check_Not_Run;
      end if;
   end Check_Status_Of;

   procedure Read
     (Item     : S.Store;
      Id       : String;
      Value    : out Assessment;
      Status   : out E.Error_Info)
   is
      Held : R.Item;
      Good : Boolean;
   begin
      Value := (others => <>);
      S.Read (Item, F.Verification_Area, Id, Held, Status);
      if E.Is_Error (Status) then
         return;
      elsif R.Get (Held, "code_health.kind") /= "assessment" then
         Refuse (Status, Id & " is not Code Health assessment evidence");
         return;
      end if;
      Value.Id := To_Unbounded_String (Id);
      Value.Context.Project := To_Unbounded_String (R.Get (Held, "code_health.project"));
      Value.Context.Task_Id := To_Unbounded_String (R.Get (Held, "task"));
      Value.Context.Generation := Number (R.Get (Held, "code_health.generation"), Good);
      if not Good then
         Refuse (Status, Id & " has an invalid generation");
         return;
      end if;
      Value.Context.Agent_Id := To_Unbounded_String (R.Get (Held, "code_health.agent"));
      Value.Context.Invocation_Id := To_Unbounded_String (R.Get (Held, "code_health.invocation"));
      Value.Context.Workspace := To_Unbounded_String (R.Get (Held, "code_health.workspace"));
      Value.Context.Snapshot := To_Unbounded_String (R.Get (Held, "repository_revision"));
      Value.Context.Configuration_Fingerprint :=
        To_Unbounded_String (R.Get (Held, "configuration_fingerprint"));
      Value.Context.Toolchain_Fingerprint :=
        To_Unbounded_String (R.Get (Held, "code_health.toolchain_fingerprint"));
      Value.Context.Environment_Fingerprint :=
        To_Unbounded_String (R.Get (Held, "code_health.environment_fingerprint"));
      Value.Context.Profile := To_Unbounded_String (R.Get (Held, "profile"));
      Value.Baseline := To_Unbounded_String (R.Get (Held, "code_health.baseline"));
      Value.Cache_Key := To_Unbounded_String (R.Get (Held, "code_health.cache_key"));
      declare
         Level_Text : constant String := R.Get (Held, "code_health.level");
         Said : constant String := R.Get (Held, "code_health.state");
      begin
         if Level_Text not in "fast" | "focused" | "full" then
            Refuse (Status, Id & " has an invalid assessment level");
            return;
         end if;
         Value.Level :=
           (if Level_Text = "fast" then Fast
            elsif Level_Text = "focused" then Focused else Full);
         if Said not in "passed" | "findings_present" | "blocked" | "unavailable" | "stale" | "cancelled" then
            Refuse (Status, Id & " has an invalid completed assessment state");
            return;
         end if;
         Value.State :=
           (if Said = "passed" then Passed
            elsif Said = "findings_present" then Findings_Present
            elsif Said = "blocked" then Blocked
            elsif Said = "unavailable" then Unavailable
            elsif Said = "stale" then Stale
            elsif Said = "cancelled" then Cancelled
            else Stale);
      end;
      --  Provider records are ordered fields. Checks and diagnostics are
      --  attached in a second pass by their result-number prefix.
      for Field_Index in 1 .. R.Field_Count (Held) loop
         declare
            Field : constant String := R.Field_Name (Held, Field_Index);
         begin
            if Field'Length > 19
              and then Field (Field'First .. Field'First + 18) = "code_health.result."
            then
               declare
                  Embedded : R.Item;
                  One      : P.Analysis_Result;
               begin
                  R.Parse (R.Get (Held, Field), Id & " provider result", Embedded, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  One.Provider_Id := To_Unbounded_String (R.Get (Embedded, "provider"));
                  One.Provider_Version := To_Unbounded_String (R.Get (Embedded, "provider_version"));
                  One.Input_Fingerprint := To_Unbounded_String (R.Get (Embedded, "input"));
                  One.Configuration_Fingerprint := To_Unbounded_String (R.Get (Embedded, "configuration"));
                  One.Toolchain_Fingerprint := To_Unbounded_String (R.Get (Embedded, "toolchain"));
                  One.Environment_Fingerprint := To_Unbounded_String (R.Get (Embedded, "environment"));
                  One.Timed_Out := R.Get (Embedded, "timed_out") = "true";
                  One.Cancelled := R.Get (Embedded, "cancelled") = "true";
                  One.Resource_Summary := To_Unbounded_String (R.Get (Embedded, "resources"));
                  begin
                     One.Exit_Status := Integer'Value (R.Get (Embedded, "exit_status"));
                     One.Duration := Standard.Duration'Value (R.Get (Embedded, "duration"));
                  exception
                     when Constraint_Error =>
                        Refuse (Status, Id & " has an invalid provider execution outcome");
                        return;
                  end;
                  for Nested_Index in 1 .. R.Field_Count (Embedded) loop
                     declare
                        Nested : constant String := R.Field_Name (Embedded, Nested_Index);
                     begin
                        if Nested'Length > 5 and then Nested (Nested'First .. Nested'First + 4) = "file." then
                           One.Files_Analyzed.Append (R.Get (Embedded, Nested));
                        elsif Nested'Length > 9
                          and then Nested (Nested'First .. Nested'First + 8) = "evidence."
                        then
                           One.Evidence.Append (R.Get (Embedded, Nested));
                        end if;
                     end;
                  end loop;
                  Value.Results.Append (One);
               end;
            end if;
         end;
      end loop;
      for Result_Index in 1 .. Natural (Value.Results.Length) loop
         declare
            Prefix : constant String := R.Numbered (Result_Index, Natural (Value.Results.Length));
            One    : P.Analysis_Result := Value.Results.Element (Result_Index);
         begin
            for Field_Index in 1 .. R.Field_Count (Held) loop
               declare
                  Field : constant String := R.Field_Name (Held, Field_Index);
                  Check_Prefix : constant String := "code_health.check." & Prefix & ".";
                  Diagnostic_Prefix : constant String := "code_health.diagnostic." & Prefix & ".";
               begin
                  if Field'Length > Check_Prefix'Length
                    and then Field (Field'First .. Field'First + Check_Prefix'Length - 1) = Check_Prefix
                  then
                     declare
                        Embedded : R.Item;
                        Check    : P.Check_Result;
                     begin
                        R.Parse (R.Get (Held, Field), Id & " check", Embedded, Status);
                        if E.Is_Error (Status) then
                           return;
                        end if;
                        Check.Identifier := To_Unbounded_String (R.Get (Embedded, "identifier"));
                        Check.Status := Check_Status_Of (R.Get (Embedded, "status"), Good);
                        if not Good then
                           Refuse (Status, Id & " has an invalid check status");
                           return;
                        end if;
                        Check.Required := R.Get (Embedded, "required") = "true";
                        Check.Detail := To_Unbounded_String (R.Get (Embedded, "detail"));
                        Check.Evidence := To_Unbounded_String (R.Get (Embedded, "evidence"));
                        One.Checks.Append (Check);
                     end;
                  elsif Field'Length > Diagnostic_Prefix'Length
                    and then Field (Field'First .. Field'First + Diagnostic_Prefix'Length - 1)
                               = Diagnostic_Prefix
                  then
                     declare
                        Diagnostic : D.Diagnostic;
                     begin
                        D.Parse (R.Get (Held, Field), Diagnostic, Status);
                        if E.Is_Error (Status) then
                           return;
                        end if;
                        D.Append_Validated (One.Diagnostics, Diagnostic, Status);
                        if E.Is_Error (Status) then
                           return;
                        end if;
                     end;
                  end if;
               end;
            end loop;
            Value.Results.Replace_Element (Result_Index, One);
         end;
      end loop;
      for Field_Index in 1 .. R.Field_Count (Held) loop
         declare
            Field : constant String := R.Field_Name (Held, Field_Index);
            Prefix : constant String := "code_health.classification.";
         begin
            if Field'Length > Prefix'Length
              and then Field (Field'First .. Field'First + Prefix'Length - 1) = Prefix
            then
               declare
                  Embedded : R.Item;
                  One      : B.Classified_Finding;
                  Said     : Unbounded_String;
               begin
                  R.Parse (R.Get (Held, Field), Id & " classification", Embedded, Status);
                  if E.Is_Error (Status) then
                     return;
                  end if;
                  Said := To_Unbounded_String (R.Get (Embedded, "state"));
                  One.State :=
                    (if Said = "new" then B.New_Finding
                     elsif Said = "existing" then B.Existing_Finding
                     elsif Said = "resolved" then B.Resolved_Finding
                     elsif Said = "changed" then B.Changed_Finding
                     else B.Unknown_Finding);
                  One.Current.Fingerprint := To_Unbounded_String (R.Get (Embedded, "current"));
                  One.Previous.Fingerprint := To_Unbounded_String (R.Get (Embedded, "previous"));
                  B.Append (Value.Classifications, One);
               end;
            end if;
         end;
      end loop;
      if not Valid (Value.Context) then
         Refuse (Status, Id & " has incomplete applicability bindings");
         return;
      end if;
      Status := E.Success;
   end Read;

   function Applicable
     (Item     : S.Store;
      Id       : String;
      Current  : Assessment_Context) return V.Applicability_Report
   is
      Value  : R.Item;
      Status : E.Error_Info;
      Result : V.Applicability_Report;

      procedure Note (Kind : V.Applicability; Why : String) is
      begin
         if Result.Reasons.Is_Empty then
            Result.Kind := Kind;
         end if;
         Result.Reasons.Append (Why);
      end Note;
   begin
      S.Read (Item, F.Verification_Area, Id, Value, Status);
      if E.Is_Error (Status) then
         Note ((if Status.Code = E.Framework_Not_Found then V.Missing else V.Corrupt),
               Id & (if Status.Code = E.Framework_Not_Found then " is not there" else " cannot be read"));
         return Result;
      elsif R.Get (Value, "code_health.kind") /= "assessment" then
         Note (V.Corrupt, Id & " is not Code Health assessment evidence");
         return Result;
      end if;
      if not Valid (Current) then
         Note (V.Corrupt, "the current Code Health applicability context is incomplete");
         return Result;
      end if;
      if R.Get (Value, "code_health.project") /= To_String (Current.Project) then
         Note (V.Stale_Authority, Id & " belongs to another project");
      end if;
      if R.Get (Value, "task") /= To_String (Current.Task_Id) then
         Note (V.Stale_Authority, Id & " belongs to another task");
      elsif R.Get (Value, "code_health.generation") /= Image (Current.Generation) then
         Note (V.Stale_Generation, Id & " belongs to another task generation");
      end if;
      if R.Get (Value, "code_health.workspace") /= To_String (Current.Workspace) then
         Note (V.Workspace_Only, Id & " belongs to another workspace");
      end if;
      if R.Get (Value, "code_health.agent") /= To_String (Current.Agent_Id)
        or else R.Get (Value, "code_health.invocation") /= To_String (Current.Invocation_Id)
      then
         Note (V.Stale_Authority, Id & " belongs to another agent invocation");
      end if;
      if R.Get (Value, "repository_revision") /= To_String (Current.Snapshot) then
         Note (V.Stale_Repository, "the source snapshot has changed since " & Id);
      end if;
      if R.Get (Value, "configuration_fingerprint")
           /= To_String (Current.Configuration_Fingerprint)
      then
         Note (V.Stale_Configuration, "the Code Health policy has changed since " & Id);
      end if;
      if R.Get (Value, "code_health.toolchain_fingerprint")
           /= To_String (Current.Toolchain_Fingerprint)
      then
         Note (V.Stale_Toolchain, "the analysis toolchain has changed since " & Id);
      end if;
      if R.Get (Value, "code_health.environment_fingerprint")
           /= To_String (Current.Environment_Fingerprint)
      then
         Note (V.Stale_Environment, "the analysis environment has changed since " & Id);
      end if;
      if R.Get (Value, "profile") /= To_String (Current.Profile) then
         Note (V.Stale_Configuration, "the Code Health profile has changed since " & Id);
      end if;
      return Result;
   end Applicable;

   function Find_Reusable
     (Item      : S.Store;
      Cache_Key : String;
      Current   : Assessment_Context) return String is
   begin
      if Cache_Key = "" then
         return "";
      end if;
      declare
         Names : constant F.Name_Lists.Vector := S.Names (Item, F.Verification_Area);
      begin
         for Index in reverse 1 .. Natural (Names.Length) loop
            declare
               Id     : constant String := Names.Element (Index);
               Value  : R.Item;
               Status : E.Error_Info;
            begin
               S.Read (Item, F.Verification_Area, Id, Value, Status);
               if E.Is_Ok (Status)
                 and then R.Get (Value, "code_health.kind") = "assessment"
                 and then R.Get (Value, "code_health.cacheable") = "true"
                 and then R.Get (Value, "code_health.cache_key") = Cache_Key
                 and then Applicable (Item, Id, Current).Kind = V.Current
               then
                  return Id;
               end if;
            end;
         end loop;
      end;
      return "";
   end Find_Reusable;

end Model_Runner.Code_Health.Evidence;
