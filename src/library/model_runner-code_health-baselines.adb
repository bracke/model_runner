with Model_Runner.Framework;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Code_Health.Baselines is

   use Ada.Strings.Unbounded;

   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;
   package F renames Model_Runner.Framework;
   package R renames Model_Runner.Framework.Records;
   package S renames Model_Runner.Framework.Stores;

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

   procedure Refuse (Status : out E.Error_Info; Detail : String) is
   begin
      Status := E.Make (E.Framework_Input_Invalid);
      E.Add_Text (Status, "name", "Code Health baseline");
      E.Add_Text (Status, "detail", Detail);
   end Refuse;

   function Valid (Context : Comparison_Context) return Boolean is
     (Length (Context.Snapshot) > 0
      and then Length (Context.Policy_Fingerprint) > 0
      and then Length (Context.Provider_Fingerprint) > 0
      and then Length (Context.Toolchain_Fingerprint) > 0
      and then Length (Context.Environment_Fingerprint) > 0
      and then Length (Context.Scope) > 0);

   procedure Create
     (Context     : Comparison_Context;
      Findings    : D.Diagnostic_List;
      Result      : out Baseline;
      Status      : out E.Error_Info) is
   begin
      Result := (others => <>);
      if not Valid (Context) then
         Refuse (Status, "comparison context is incomplete");
         return;
      end if;
      for Index in 1 .. D.Length (Findings) loop
         if To_String (D.Element (Findings, Index).Snapshot) /= To_String (Context.Snapshot) then
            Refuse (Status, "a finding belongs to another source snapshot");
            return;
         end if;
      end loop;
      Result.Context := Context;
      Result.Findings := Findings;
      Status := E.Success;
   end Create;

   function Identifier (Item : Baseline) return String is (To_String (Item.Id));
   function Context_Of (Item : Baseline) return Comparison_Context is (Item.Context);
   function Findings_Of (Item : Baseline) return D.Diagnostic_List is (Item.Findings);
   function Task_Of (Item : Baseline) return String is (To_String (Item.Context.Task_Id));
   function Generation_Of (Item : Baseline) return Natural is (Item.Context.Generation);
   function Workspace_Of (Item : Baseline) return String is (To_String (Item.Context.Workspace));

   procedure Keep
     (Item     : S.Store;
      Change   : in out S.Transaction;
      Value    : in out Baseline;
      Status   : out E.Error_Info)
   is
      Number : Natural;
   begin
      if Length (Value.Id) > 0 then
         Status := E.Make (E.Framework_Result_Conflict);
         E.Add_Text (Status, "name", To_String (Value.Id));
         E.Add_Text (Status, "detail", "an immutable baseline cannot be replaced");
         return;
      elsif not Valid (Value.Context) then
         Refuse (Status, "comparison context is incomplete");
         return;
      end if;
      S.Allocate_Number (Item, Change, "CHB", "", Number, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         Id   : constant String := "CHB-" & R.Numbered (Number, 3);
         Now  : constant String := F.Timestamp;
         Held : R.Item := R.Create (Model_Runner.Framework.Schemas.Evidence_Schema, 1, Id, 1);
      begin
         R.Set (Held, "profile", "code-health-baseline");
         R.Set (Held, "task", To_String (Value.Context.Task_Id));
         R.Set (Held, "started_at", Now);
         R.Set (Held, "ended_at", Now);
         R.Set (Held, "repository_revision", To_String (Value.Context.Snapshot));
         R.Set (Held, "configuration_fingerprint", To_String (Value.Context.Policy_Fingerprint));
         R.Set (Held, "passed", "true");
         R.Set (Held, "code_health.kind", "baseline");
         R.Set (Held, "code_health.provider_fingerprint", To_String (Value.Context.Provider_Fingerprint));
         R.Set (Held, "code_health.toolchain_fingerprint", To_String (Value.Context.Toolchain_Fingerprint));
         R.Set (Held, "code_health.environment_fingerprint", To_String (Value.Context.Environment_Fingerprint));
         R.Set (Held, "code_health.scope", To_String (Value.Context.Scope));
         R.Set (Held, "code_health.generation", Image (Value.Context.Generation));
         R.Set (Held, "code_health.workspace", To_String (Value.Context.Workspace));
         for Index in 1 .. D.Length (Value.Findings) loop
            R.Set
              (Held, "diagnostic." & R.Numbered (Index, D.Length (Value.Findings)),
               D.Serialize (D.Element (Value.Findings, Index)));
         end loop;
         S.Put (Change, F.Verification_Area, Id, Held);
         Value.Id := To_Unbounded_String (Id);
         Status := E.Success;
      end;
   end Keep;

   procedure Read
     (Item     : S.Store;
      Id       : String;
      Value    : out Baseline;
      Status   : out E.Error_Info)
   is
      Held : R.Item;
      Good : Boolean;
   begin
      Value := (others => <>);
      S.Read (Item, F.Verification_Area, Id, Held, Status);
      if E.Is_Error (Status) then
         return;
      elsif R.Get (Held, "code_health.kind") /= "baseline" then
         Refuse (Status, Id & " is not a Code Health baseline");
         return;
      end if;
      Value.Id := To_Unbounded_String (Id);
      Value.Context.Task_Id := To_Unbounded_String (R.Get (Held, "task"));
      Value.Context.Workspace := To_Unbounded_String (R.Get (Held, "code_health.workspace"));
      Value.Context.Generation := Number (R.Get (Held, "code_health.generation"), Good);
      if not Good then
         Refuse (Status, Id & " has an invalid generation");
         return;
      end if;
      Value.Context.Snapshot := To_Unbounded_String (R.Get (Held, "repository_revision"));
      Value.Context.Policy_Fingerprint := To_Unbounded_String (R.Get (Held, "configuration_fingerprint"));
      Value.Context.Provider_Fingerprint :=
        To_Unbounded_String (R.Get (Held, "code_health.provider_fingerprint"));
      Value.Context.Toolchain_Fingerprint :=
        To_Unbounded_String (R.Get (Held, "code_health.toolchain_fingerprint"));
      Value.Context.Environment_Fingerprint :=
        To_Unbounded_String (R.Get (Held, "code_health.environment_fingerprint"));
      Value.Context.Scope := To_Unbounded_String (R.Get (Held, "code_health.scope"));
      if not Valid (Value.Context) then
         Refuse (Status, Id & " has incomplete comparison bindings");
         return;
      end if;
      for Index in 1 .. R.Field_Count (Held) loop
         declare
            Field : constant String := R.Field_Name (Held, Index);
            One   : D.Diagnostic;
         begin
            if Field'Length > 11 and then Field (Field'First .. Field'First + 10) = "diagnostic." then
               D.Parse (R.Get (Held, Field), One, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               D.Append_Validated (Value.Findings, One, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
            end if;
         end;
      end loop;
      Status := E.Success;
   end Read;

   function Comparable
     (Before : Baseline;
      Now    : Comparison_Context) return Boolean
   is
     (Valid (Now)
      and then Before.Context.Policy_Fingerprint = Now.Policy_Fingerprint
      and then Before.Context.Provider_Fingerprint = Now.Provider_Fingerprint
      and then Before.Context.Toolchain_Fingerprint = Now.Toolchain_Fingerprint
      and then Before.Context.Environment_Fingerprint = Now.Environment_Fingerprint
      and then Before.Context.Scope = Now.Scope
      and then Before.Context.Task_Id = Now.Task_Id
      and then Before.Context.Generation = Now.Generation
      and then Before.Context.Workspace = Now.Workspace);

   function Correspondence (Item : D.Diagnostic) return String is
      Meaning : R.Item := R.Create ("code_health.correspondence", 1, "FINDING", 1);
   begin
      R.Set (Meaning, "provider", To_String (Item.Provider));
      R.Set (Meaning, "rule", To_String (Item.Rule_Id));
      R.Set (Meaning, "path", To_String (Item.Path));
      R.Set (Meaning, "symbol", To_String (Item.Symbol));
      R.Set (Meaning, "native_code", To_String (Item.Native_Code));
      return R.Fingerprint_Of (Meaning);
   end Correspondence;

   procedure Compare
     (Before   : Baseline;
      Now      : Comparison_Context;
      Findings : D.Diagnostic_List;
      Result   : out Classification_List)
   is
      Used : array (1 .. D.Length (Before.Findings)) of Boolean := [others => False];
   begin
      Result := (others => <>);
      if not Comparable (Before, Now) then
         for Index in 1 .. D.Length (Findings) loop
            Result.Items.Append
              (Classified_Finding'
                 (State => Unknown_Finding, Current => D.Element (Findings, Index), others => <>));
         end loop;
         for Index in 1 .. D.Length (Before.Findings) loop
            Result.Items.Append
              (Classified_Finding'
                 (State => Unknown_Finding,
                  Previous => D.Element (Before.Findings, Index), others => <>));
         end loop;
         return;
      end if;

      for Current_Index in 1 .. D.Length (Findings) loop
         declare
            Current : constant D.Diagnostic := D.Element (Findings, Current_Index);
            Match   : Natural := 0;
         begin
            for Previous_Index in 1 .. D.Length (Before.Findings) loop
               if not Used (Previous_Index)
                 and then To_String (D.Element (Before.Findings, Previous_Index).Fingerprint)
                            = To_String (Current.Fingerprint)
               then
                  Match := Previous_Index;
                  exit;
               end if;
            end loop;
            if Match = 0 then
               for Previous_Index in 1 .. D.Length (Before.Findings) loop
                  if not Used (Previous_Index)
                    and then Correspondence (D.Element (Before.Findings, Previous_Index))
                               = Correspondence (Current)
                  then
                     Match := Previous_Index;
                     exit;
                  end if;
               end loop;
            end if;
            if Match = 0 then
               Result.Items.Append
                 (Classified_Finding'(State => New_Finding, Current => Current, others => <>));
            else
               Used (Match) := True;
               Result.Items.Append
                 (Classified_Finding'
                  (State    =>
                     (if To_String (D.Element (Before.Findings, Match).Fingerprint)
                           = To_String (Current.Fingerprint)
                        and then D.Element (Before.Findings, Match).Severity = Current.Severity
                      then Existing_Finding else Changed_Finding),
                   Current  => Current,
                   Previous => D.Element (Before.Findings, Match)));
            end if;
         end;
      end loop;
      for Index in Used'Range loop
         if not Used (Index) then
            Result.Items.Append
              (Classified_Finding'
                 (State => Resolved_Finding,
                  Previous => D.Element (Before.Findings, Index), others => <>));
         end if;
      end loop;
   end Compare;

   function Length (Item : Classification_List) return Natural is (Natural (Item.Items.Length));

   function Element (Item : Classification_List; Index : Positive) return Classified_Finding is
     (Item.Items.Element (Index));

   function Count (Item : Classification_List; State : Finding_State) return Natural is
   begin
      return Result : Natural := 0 do
         for One of Item.Items loop
            if One.State = State then
               Result := Result + 1;
            end if;
         end loop;
      end return;
   end Count;

   procedure Append (To : in out Classification_List; Item : Classified_Finding) is
   begin
      To.Items.Append (Item);
   end Append;

   procedure Clear (Item : in out Classification_List) is
   begin
      Item.Items.Clear;
   end Clear;

   function Has_Regression
     (Item      : Classification_List;
      Threshold : Diagnostic_Severity) return Boolean is
   begin
      for One of Item.Items loop
         if One.State = Unknown_Finding
           or else (One.State = New_Finding and then D.Blocks (One.Current, Threshold))
           or else (One.State = Changed_Finding and then One.Current.Severity > One.Previous.Severity)
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Regression;

end Model_Runner.Code_Health.Baselines;
