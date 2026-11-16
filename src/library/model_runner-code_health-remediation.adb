with Model_Runner.Framework.Records;
with Model_Runner.UTF8;

package body Model_Runner.Code_Health.Remediation is

   use Ada.Strings.Unbounded;

   package D renames Model_Runner.Code_Health.Diagnostics;
   package E renames Model_Runner.Errors;
   package P renames Model_Runner.Code_Health.Providers;
   package R renames Model_Runner.Framework.Records;

   use type P.Check_Status;

   function Check_Less (Left, Right : P.Check_Result) return Boolean is
      Left_Id  : constant String := To_String (Left.Identifier);
      Right_Id : constant String := To_String (Right.Identifier);
   begin
      if Left_Id /= Right_Id then
         return Left_Id < Right_Id;
      elsif Left.Status /= Right.Status then
         return P.Check_Status'Pos (Left.Status) < P.Check_Status'Pos (Right.Status);
      else
         return not Left.Required and then Right.Required;
      end if;
   end Check_Less;

   package Check_Sorting is new P.Check_Result_Lists.Generic_Sorting
     ("<" => Check_Less);

   function State_Of (Self : Controller) return Remediation_State is (Self.Progress);
   function Last_Stop (Self : Controller) return Stop_Cause is (Self.Stopped);
   function Progress_Of (Self : Completion_Gate) return Remediation_State is
     (State_Of (Self.Controller));
   function Stop_Of (Self : Completion_Gate) return Stop_Cause is
     (Last_Stop (Self.Controller));

   function Stop_Words (Cause : Stop_Cause) return String is
     (case Cause is
         when No_Stop              => "not stopped",
         when Stagnation_Limit     => "stagnation limit reached",
         when Oscillation_Detected => "repairs are oscillating",
         when Assessment_Limit     => "assessment limit reached",
         when Analysis_Cancelled   => "analysis was cancelled",
         when Permission_Lost      => "analysis permission is unavailable",
         when Policy_Changed       => "the active quality policy changed");

   procedure Initialize (Self : out Controller; Rules : Limits := (others => <>)) is
   begin
      Self := (Rules => Rules, others => <>);
   end Initialize;

   function Status_Word (Value : P.Check_Status) return String is
     (case Value is
         when P.Check_Not_Run     => "not_run",
         when P.Check_Passed      => "passed",
         when P.Check_Findings    => "findings",
         when P.Check_Unavailable => "unavailable",
         when P.Check_Timed_Out   => "timed_out",
         when P.Check_Cancelled   => "cancelled",
         when P.Check_Failed      => "failed",
         when P.Check_Stale       => "stale");

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

   function Summarize
     (Result    : Assessment;
      Threshold : Diagnostic_Severity) return Assessment_Summary
   is
      Meaning : R.Item := R.Create ("code_health.remediation", 1, "ASSESSMENT", 1);
      Findings : D.Diagnostic_List := Result.Diagnostics;
      Checks   : P.Check_Result_Lists.Vector := Result.Checks;
      Summary  : Assessment_Summary;
   begin
      D.Sort (Findings);
      Check_Sorting.Sort (Checks);
      R.Set (Meaning, "snapshot", To_String (Result.Snapshot));
      R.Set (Meaning, "policy", To_String (Result.Policy_Fingerprint));
      R.Set (Meaning, "state", State_Word (Result.State));
      for Index in 1 .. D.Length (Findings) loop
         declare
            One : constant D.Diagnostic := D.Element (Findings, Index);
         begin
            R.Set
              (Meaning, "finding." & R.Numbered (Index, D.Length (Findings)),
               To_String (One.Fingerprint) & ":" & Diagnostic_Severity'Image (One.Severity));
            if D.Blocks (One, Threshold) then
               Summary.Blockers := Summary.Blockers + 1;
               if One.Severity > Summary.Highest then
                  Summary.Highest := One.Severity;
               end if;
            end if;
         end;
      end loop;
      for Index in 1 .. Natural (Checks.Length) loop
         declare
            Check : constant P.Check_Result := Checks.Element (Index);
         begin
            R.Set
              (Meaning, "check." & R.Numbered (Index, Natural (Checks.Length)),
               To_String (Check.Identifier) & ":" & Status_Word (Check.Status)
               & (if Check.Required then ":required" else ":optional"));
            if Check.Required
              and then Check.Status not in P.Check_Passed | P.Check_Findings
            then
               Summary.Required_Failed := Summary.Required_Failed + 1;
            end if;
         end;
      end loop;
      if Result.State = Blocked and then Summary.Blockers = 0
        and then Summary.Required_Failed = 0
      then
         Summary.Blockers := 1;
      end if;
      Summary.Available :=
        Result.State in Passed | Findings_Present | Blocked
        and then Summary.Required_Failed = 0;
      Summary.Signature := To_Unbounded_String (R.Fingerprint_Of (Meaning));
      return Summary;
   end Summarize;

   function Is_Clean (Result : Assessment; Summary : Assessment_Summary) return Boolean is
     (Result.State in Passed | Findings_Present
      and then Summary.Blockers = 0
      and then Summary.Required_Failed = 0);

   function Improved (Before, Now : Assessment_Summary) return Boolean is
      Worse : constant Boolean :=
        Now.Highest > Before.Highest
        or else Now.Required_Failed > Before.Required_Failed;
   begin
      return not Worse
        and then ((not Before.Available and then Now.Available)
                  or else Now.Highest < Before.Highest
                  or else Now.Blockers < Before.Blockers
                  or else Now.Required_Failed < Before.Required_Failed);
   end Improved;

   function Seen_Before (Self : Controller; Signature : Unbounded_String) return Boolean is
   begin
      if Natural (Self.History.Length) < 2
        or else (Self.Has_Previous and then Self.Previous.Signature = Signature)
      then
         return False;
      end if;
      for Index in Self.History.First_Index .. Self.History.Last_Index - 1 loop
         if Self.History.Element (Index).Signature = Signature then
            return True;
         end if;
      end loop;
      return False;
   end Seen_Before;

   procedure Observe
     (Self     : in out Controller;
      Result   : Assessment;
      Decision : out Action;
      Cause    : out Stop_Cause)
   is
      Summary : constant Assessment_Summary := Summarize (Result, Self.Rules.Threshold);
      Progressed : Boolean := False;
   begin
      Decision := Stop_Incomplete;
      Cause := No_Stop;
      if Self.Stopped /= No_Stop then
         Cause := Self.Stopped;
         return;
      end if;

      Self.Progress.Assessments := Self.Progress.Assessments + 1;
      Self.Progress.Last_Snapshot := Result.Snapshot;
      Self.Progress.Last_Findings := Summary.Signature;
      Self.Progress.Best_Blockers := Natural'Min (Self.Progress.Best_Blockers, Summary.Blockers);

      if Result.Policy_Fingerprint = Null_Unbounded_String then
         Self.Stopped := Policy_Changed;
      elsif Self.Active_Policy = Null_Unbounded_String then
         Self.Active_Policy := Result.Policy_Fingerprint;
      end if;

      if Self.Stopped /= No_Stop then
         null;
      elsif Self.Active_Policy /= Result.Policy_Fingerprint then
         Self.Stopped := Policy_Changed;
      elsif Result.State = Cancelled then
         Self.Stopped := Analysis_Cancelled;
      elsif not Result.Permissions_Valid then
         Self.Stopped := Permission_Lost;
      elsif Is_Clean (Result, Summary) then
         Self.Awaiting_Repair := False;
         Self.Progress.Stagnant_Attempts := 0;
         Decision := Proceed;
         Self.Previous := Summary;
         Self.Has_Previous := True;
         Self.History.Append (Summary);
         return;
      elsif Self.Progress.Assessments >= Self.Rules.Max_Assessments then
         Self.Stopped := Assessment_Limit;
      elsif Seen_Before (Self, Summary.Signature) then
         Self.Stopped := Oscillation_Detected;
      else
         if Self.Has_Previous and then Self.Awaiting_Repair then
            Progressed := Improved (Self.Previous, Summary);
            if Progressed then
               Self.Progress.Stagnant_Attempts := 0;
            else
               Self.Progress.Stagnant_Attempts := Self.Progress.Stagnant_Attempts + 1;
            end if;
         end if;
         if Self.Progress.Stagnant_Attempts >= Self.Rules.Max_Stagnant then
            Self.Stopped := Stagnation_Limit;
         else
            Self.Progress.Repair_Attempts := Self.Progress.Repair_Attempts + 1;
            Self.Awaiting_Repair := True;
            Decision := Repair_And_Recheck;
         end if;
      end if;

      Self.Previous := Summary;
      Self.Has_Previous := True;
      Self.History.Append (Summary);
      Cause := Self.Stopped;
   end Observe;

   procedure Initialize
     (Self   : out Completion_Gate;
      Source : not null Assessment_Source_Reference;
      Rules  : Limits := (others => <>)) is
   begin
      Self.Source := Source;
      Initialize (Self.Controller, Rules);
   end Initialize;

   function Bounded (Text : String; Limit : Positive) return String is
      Repaired : constant String := Model_Runner.UTF8.Repaired (Text);
   begin
      if Repaired'Length <= Limit then
         return Repaired;
      end if;
      declare
         Candidate : constant String := Repaired (Repaired'First .. Repaired'First + Limit - 1);
         Safe      : constant Natural := Model_Runner.UTF8.Safe_Prefix_Length (Candidate);
      begin
         return Candidate (Candidate'First .. Candidate'First + Safe - 1);
      end;
   end Bounded;

   overriding procedure Evaluate
     (Self     : in out Completion_Gate;
      Answer   : String;
      Decision : out Model_Runner.Agent.Answer_Decision;
      Feedback : out Unbounded_String;
      Status   : out E.Error_Info)
   is
      Result : Assessment;
      Said   : Unbounded_String;
      Next   : Action;
      Cause  : Stop_Cause;
   begin
      Decision := Model_Runner.Agent.Refuse_Answer;
      Feedback := Null_Unbounded_String;
      Assess (Self.Source.all, Before_Agent_Answer, Answer, Result, Said, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Observe (Self.Controller, Result, Next, Cause);
      case Next is
         when Proceed =>
            Decision := Model_Runner.Agent.Accept_Answer;
         when Repair_And_Recheck =>
            Decision := Model_Runner.Agent.Continue_After_Feedback;
            if Said = Null_Unbounded_String then
               Said := To_Unbounded_String
                 ("CODE HEALTH: BLOCKED" & ASCII.LF
                  & "Required checks still have blocking findings." & ASCII.LF
                  & "Repair them, then revalidate before reporting completion.");
            end if;
         when Stop_Incomplete =>
            Decision := Model_Runner.Agent.Refuse_Answer;
            if Said = Null_Unbounded_String then
               Said := To_Unbounded_String
                 ("CODE HEALTH: INCOMPLETE" & ASCII.LF
                  & Stop_Words (Cause) & ". Required checks remain unresolved.");
            end if;
      end case;
      Feedback := To_Unbounded_String (Bounded (To_String (Said), Self.Controller.Rules.Feedback_Limit));
      Status := E.Success;
   end Evaluate;

end Model_Runner.Code_Health.Remediation;
