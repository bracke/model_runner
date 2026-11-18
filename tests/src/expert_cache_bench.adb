with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Model_Runner;
with Model_Runner.Backend;
with Model_Runner.Expert_Cache_Recommendations;
with Model_Runner.Generation;
with Model_Runner.Llama;
with Model_Runner.Text;

package body Expert_Cache_Bench is

   package IO renames Ada.Text_IO;
   package L renames Model_Runner.Llama;
   package T renames Model_Runner.Text;

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Generation.Token_Id;
   use type Model_Runner.Numerics.Real;

   Max_Candidates : constant := 8;
   type Cache_List is
     array (Positive range 1 .. Max_Candidates) of Interfaces.Unsigned_64;
   type Report_List is
     array (Positive range 1 .. Max_Candidates) of Speed_Run.Report;
   type Comparison_List is
     array (Positive range 1 .. Max_Candidates) of Comparison;
   subtype ABBA_Leg is Positive range 1 .. 4;
   type Trial_Report_List is
     array (Positive range 1 .. Max_Candidates, ABBA_Leg) of Speed_Run.Report;

   function Bool (Value : Boolean) return String is
     (if Value then "true" else "false");

   function Seconds (Value : Duration) return String is
     (T.Image (Long_Float (Value), 6));

   function Number (Value : Long_Float) return String is
     (T.Image (Value, 6));

   function Device_Of (Item : Speed_Run.Report) return String is
     (if Item.Device_Name_Up = 0 then ""
      else Item.Device_Name (1 .. Item.Device_Name_Up));

   function Is_Software (Name : String) return Boolean is
      Lower : constant String := Ada.Characters.Handling.To_Lower (Name);
   begin
      return Ada.Strings.Fixed.Index (Lower, "llvmpipe") /= 0
        or else Ada.Strings.Fixed.Index (Lower, "lavapipe") /= 0
        or else Ada.Strings.Fixed.Index (Lower, "swiftshader") /= 0
        or else Ada.Strings.Fixed.Index (Lower, "software") /= 0;
   end Is_Software;

   function Turn_Count (Directory : String) return Positive is
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      Count  : Natural := 0;
   begin
      if Directory = "" or else not Ada.Directories.Exists (Directory) then
         return 1;
      end if;
      Ada.Directories.Start_Search
        (Search, Directory, "",
         [Ada.Directories.Ordinary_File => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         Count := Count + 1;
      end loop;
      Ada.Directories.End_Search (Search);
      return Positive'Max (1, Natural'Min (Count, 256));
   end Turn_Count;

   function Compare
     (Baseline        : Speed_Run.Report;
      Candidate       : Speed_Run.Report;
      Baseline_Turns  : Speed_Run.Report;
      Candidate_Turns : Speed_Run.Report;
      Has_Turns       : Boolean;
      Minimum_Gain    : Long_Float;
      Logit_Tolerance : Model_Runner.Numerics.Real;
      Hardware        : Boolean) return Comparison
   is
      Result : Comparison;
      Base_Time : constant Duration :=
        Baseline.Wall
        + (if Has_Turns then Baseline_Turns.Wall else 0.0);
      Candidate_Time : constant Duration :=
        Candidate.Wall
        + (if Has_Turns then Candidate_Turns.Wall else 0.0);
      Base : Speed_Run.Probability_Ledger renames Baseline.Probabilities;
      Seen : Speed_Run.Probability_Ledger renames Candidate.Probabilities;
   begin
      Result.Prompt_Output_Match :=
        Baseline.Ran and then Candidate.Ran
        and then Baseline.Digest = Candidate.Digest;
      Result.Turn_Output_Match :=
        not Has_Turns
        or else (Baseline_Turns.Ran and then Candidate_Turns.Ran
                 and then Baseline_Turns.Digest = Candidate_Turns.Digest);
      Result.Output_Match :=
        Result.Prompt_Output_Match and then Result.Turn_Output_Match;

      Result.Logits_Comparable :=
        Base.Positions > 0 and then Base.Positions = Seen.Positions;
      Result.Top_Tokens_Match := Result.Logits_Comparable;
      Result.Max_Logprob_Delta := 0.0;

      if Result.Logits_Comparable then
         for Position in 1 .. Base.Positions loop
            if Base.Chosen (Position) /= Seen.Chosen (Position)
              or else Base.Counts (Position) /= Seen.Counts (Position)
            then
               Result.Top_Tokens_Match := False;
            end if;

            for Alternative in 1 .. Base.Counts (Position) loop
               declare
                  Found : Natural := 0;
               begin
                  for Other in 1 .. Seen.Counts (Position) loop
                     if Base.Tokens (Position, Alternative)
                       = Seen.Tokens (Position, Other)
                     then
                        Found := Other;
                        exit;
                     end if;
                  end loop;
                  if Found = 0 then
                     Result.Top_Tokens_Match := False;
                  else
                     Result.Max_Logprob_Delta := Long_Float'Max
                       (Result.Max_Logprob_Delta,
                        abs Long_Float
                          (Base.Values (Position, Alternative)
                           - Seen.Values (Position, Found)));
                  end if;
               end;
            end loop;
         end loop;
      end if;

      if Base_Time > 0.0 then
         Result.Improvement :=
           (Long_Float (Base_Time) - Long_Float (Candidate_Time))
           / Long_Float (Base_Time) * 100.0;
      end if;

      Result.Physical_Work :=
        Candidate.Expert_Cache_Requested > 0
        and then Candidate.Experts.Device_Runs > 0
        and then Candidate.Experts.Resident_Bytes > 0
        and then Candidate.Experts.Resident_Bytes
                 <= Candidate.Experts.Reserve_Bytes;
      Result.Hardware_Qualified := Hardware;
      Result.Timing_Stable := True;
      Result.Load_Qualified :=
        Baseline.Load_Qualified and then Candidate.Load_Qualified
        and then (not Has_Turns
                  or else (Baseline_Turns.Load_Qualified
                           and then Candidate_Turns.Load_Qualified));
      Result.Passes :=
        Result.Output_Match
        and then Result.Logits_Comparable
        and then Result.Top_Tokens_Match
        and then Result.Max_Logprob_Delta <= Long_Float (Logit_Tolerance)
        and then Result.Improvement >= Minimum_Gain
        and then Result.Physical_Work
        and then Hardware
        and then Result.Load_Qualified;
      return Result;
   end Compare;

   function Maximum_Leg_Drift
     (A1, B1, B2, A2 : Duration) return Long_Float
   is
      function Drift (Left, Right : Duration) return Long_Float is
         Smaller : constant Duration := Duration'Min (Left, Right);
      begin
         if Smaller <= 0.0 then
            return Long_Float'Last;
         end if;
         return abs (Long_Float (Left) - Long_Float (Right))
           / Long_Float (Smaller) * 100.0;
      end Drift;
   begin
      return Long_Float'Max (Drift (A1, A2), Drift (B1, B2));
   end Maximum_Leg_Drift;

   procedure Run
     (Model           : String;
      Prompt          : String;
      Turns           : String;
      Cache_Sizes     : String;
      Report_Path     : String;
      Recommendation_Path : String;
      Tokens          : Positive;
      Threads         : Positive;
      Context         : Natural;
      Repeats         : Positive;
      Device_Memory   : Interfaces.Unsigned_64;
      Minimum_Gain    : Long_Float;
      Logit_Tolerance : Model_Runner.Numerics.Real;
      Leg_Drift_Limit : Long_Float;
      Success         : out Boolean)
   is
      Caches      : Cache_List := [others => 0];
      Baselines   : Report_List;
      Reports     : Report_List;
      Turn_Reports : Report_List;
      Baseline_Turns : Report_List;
      Prompt_Trials : Trial_Report_List;
      Turn_Trials   : Trial_Report_List;
      Judgements  : Comparison_List;
      Count       : Natural := 1;
      First       : Positive := Cache_Sizes'First;
      Has_Turns   : constant Boolean := Turns /= "";
      Turns_Count : constant Positive := Turn_Count (Turns);
      Recommended : Interfaces.Unsigned_64 := 0;
      Best_Gain   : Long_Float := Long_Float'First;
      Hardware    : Boolean := False;

      procedure Add (Word : String) is
         Value : Interfaces.Unsigned_64;
      begin
         if Word = "" then
            return;
         end if;
         Value := Interfaces.Unsigned_64'Value (Word);
         if Value = 0 then
            return;
         end if;
         for Index in 1 .. Count loop
            if Caches (Index) = Value then
               return;
            end if;
         end loop;
         if Count = Max_Candidates then
            raise Constraint_Error;
         end if;
         Count := Count + 1;
         Caches (Count) := Value;
      end Add;

      procedure Measure
        (Reserve : Interfaces.Unsigned_64;
         Turns_At : String;
         Result : out Speed_Run.Report)
      is
      begin
         Speed_Run.Run
           (Path          => Model,
            Prompt_Path   => Prompt,
            Tokens        => Tokens,
            Threads       => Threads,
            Batch         => Model_Runner.Generation.Request'(others => <>).Batch_Size,
            Repack        => L.No_Repack,
            Cache         => L.Exact,
            Backend       => Model_Runner.Backend.Backend_Device,
            Draft_Tokens  => 0,
            Draft_Tokens_Set => True,
            Repeats       => (if Turns_At = "" then Repeats else Turns_Count),
            Context       => Context,
            Device_Bytes  => Device_Memory,
            Device_Named  => True,
            Expert_Cache  => Reserve,
            Capture_Probabilities => Turns_At = "",
            Capture_Conditions => True,
            Paged         => True,
            Ignore_End    => True,
            Result        => Result,
            Turns         => Turns_At);
      end Measure;

      --  The two A legs and the two B legs each become one result.  Timing
      --  uses their mean, while every qualification flag is conservative:
      --  one contaminated leg contaminates the aggregate.  Numerical
      --  stability is checked separately below before a recommendation can
      --  be made.
      function Combined
        (Left, Right : Speed_Run.Report) return Speed_Run.Report
      is
         Result : Speed_Run.Report := Left;
      begin
         Result.Ran := Left.Ran and then Right.Ran;
         Result.Cold_Ran := Left.Cold_Ran and then Right.Cold_Ran;
         Result.Load := (Left.Load + Right.Load) / 2;
         Result.Cold_Wall := (Left.Cold_Wall + Right.Cold_Wall) / 2;
         Result.Cold_Evaluate :=
           (Left.Cold_Evaluate + Right.Cold_Evaluate) / 2;
         Result.Cold_Generate :=
           (Left.Cold_Generate + Right.Cold_Generate) / 2;
         Result.Wall := (Left.Wall + Right.Wall) / 2;
         Result.Evaluate := (Left.Evaluate + Right.Evaluate) / 2;
         Result.Generate := (Left.Generate + Right.Generate) / 2;
         Result.Processor := (Left.Processor + Right.Processor) / 2;
         Result.Load_Before :=
           (Left.Load_Before + Right.Load_Before) / 2.0;
         Result.Load_After := (Left.Load_After + Right.Load_After) / 2.0;
         Result.Background_Max :=
           Long_Float'Max (Left.Background_Max, Right.Background_Max);
         Result.Background_Before_Max :=
           Long_Float'Max
             (Left.Background_Before_Max, Right.Background_Before_Max);
         Result.Background_After_Max :=
           Long_Float'Max
             (Left.Background_After_Max, Right.Background_After_Max);
         Result.Background_Uses_Processors :=
           Left.Background_Uses_Processors
           and then Right.Background_Uses_Processors;
         Result.Device_Background_Before_Max :=
           Natural'Max
             (Left.Device_Background_Before_Max,
              Right.Device_Background_Before_Max);
         Result.Device_Background_After_Max :=
           Natural'Max
             (Left.Device_Background_After_Max,
              Right.Device_Background_After_Max);
         Result.Device_Background_Seen :=
           Left.Device_Background_Seen and then Right.Device_Background_Seen;
         Result.Device_Load_Qualified :=
           Left.Device_Load_Qualified and then Right.Device_Load_Qualified;
         Result.Load_Qualified :=
           Left.Load_Qualified and then Right.Load_Qualified
           and then Result.Device_Load_Qualified;
         Result.Warm_Before := Long_Float'Max (Left.Warm_Before, Right.Warm_Before);
         Result.Warm_After := Long_Float'Max (Left.Warm_After, Right.Warm_After);
         Result.Experts.Device_Runs :=
           Interfaces.Unsigned_64'Min
             (Left.Experts.Device_Runs, Right.Experts.Device_Runs);
         Result.Experts.Resident_Bytes :=
           Interfaces.Unsigned_64'Min
             (Left.Experts.Resident_Bytes, Right.Experts.Resident_Bytes);
         Result.Experts.Reserve_Bytes :=
           Interfaces.Unsigned_64'Min
             (Left.Experts.Reserve_Bytes, Right.Experts.Reserve_Bytes);
         return Result;
      end Combined;

      procedure Constrain
        (Result           : in out Comparison;
         By_Result        : Comparison;
         Require_Physical : Boolean := False)
      is
      begin
         Result.Prompt_Output_Match :=
           Result.Prompt_Output_Match and then By_Result.Prompt_Output_Match;
         Result.Turn_Output_Match :=
           Result.Turn_Output_Match and then By_Result.Turn_Output_Match;
         Result.Output_Match :=
           Result.Prompt_Output_Match and then Result.Turn_Output_Match;
         Result.Logits_Comparable :=
           Result.Logits_Comparable and then By_Result.Logits_Comparable;
         Result.Top_Tokens_Match :=
           Result.Top_Tokens_Match and then By_Result.Top_Tokens_Match;
         Result.Max_Logprob_Delta :=
           Long_Float'Max
             (Result.Max_Logprob_Delta, By_Result.Max_Logprob_Delta);
         Result.Load_Qualified :=
           Result.Load_Qualified and then By_Result.Load_Qualified;
         if Require_Physical then
            Result.Physical_Work :=
              Result.Physical_Work and then By_Result.Physical_Work;
         end if;
      end Constrain;

      function Total
        (Prompt_Report : Speed_Run.Report;
         Turn_Report   : Speed_Run.Report) return Duration
      is (Prompt_Report.Wall
          + (if Has_Turns then Turn_Report.Wall else 0.0));

      procedure Explain_Failure
        (Label : String; Item : Speed_Run.Report)
      is
      begin
         if not Item.Ran then
            IO.Put
              (IO.Standard_Error,
               "expert-cache: " & Label & " failed");
            if Item.Detail_Up > 0 then
               IO.Put
                 (IO.Standard_Error,
                  ": " & Item.Detail (1 .. Item.Detail_Up));
            end if;
            IO.New_Line (IO.Standard_Error);
         end if;
      end Explain_Failure;

      procedure Put_Report
        (File : IO.File_Type;
         Item : Speed_Run.Report)
      is
      begin
         IO.Put
           (File,
            "{""ran"":" & Bool (Item.Ran)
            & ",""digest"":" & T.JSON_Quoted (Item.Digest)
            & ",""load_seconds"":" & Seconds (Item.Load)
            & ",""cold"":{""ran"":" & Bool (Item.Cold_Ran)
            & ",""wall_seconds"":" & Seconds (Item.Cold_Wall)
            & ",""prompt_seconds"":" & Seconds (Item.Cold_Evaluate)
            & ",""generation_seconds"":" & Seconds (Item.Cold_Generate)
            & "},""warm"":{""wall_seconds"":" & Seconds (Item.Wall)
            & ",""prompt_seconds"":" & Seconds (Item.Evaluate)
            & ",""generation_seconds"":" & Seconds (Item.Generate)
            & "},""environment"":{""load_average_before"":"
            & Number (Item.Load_Before)
            & ",""load_average_after"":" & Number (Item.Load_After)
            & ",""background_peak"":" & Number (Item.Background_Max)
            & ",""background_before_peak"":"
            & Number (Item.Background_Before_Max)
            & ",""background_after_peak"":"
            & Number (Item.Background_After_Max)
            & ",""background_unit"":"
            & T.JSON_Quoted
                (if Item.Background_Uses_Processors
                 then "busy_processors" else "load_average")
            & ",""load_qualified"":" & Bool (Item.Load_Qualified)
            & ",""device_idle_seen"":"
            & Bool (Item.Device_Background_Seen)
            & ",""device_busy_before_peak_percent"":"
            & Natural'Image (Item.Device_Background_Before_Max)
            & ",""device_busy_after_peak_percent"":"
            & Natural'Image (Item.Device_Background_After_Max)
            & ",""device_load_qualified"":"
            & Bool (Item.Device_Load_Qualified)
            & ",""device_run_busy_percent"":"
            & Natural'Image (Item.Clock.Busy)
            & ",""device_run_busy_seen"":" & Bool (Item.Clock.Busy_Seen)
            & ",""temperature_before_c"":" & Number (Item.Warm_Before)
            & ",""temperature_after_c"":" & Number (Item.Warm_After)
            & "},""probability_positions"":"
            & Natural'Image (Item.Probabilities.Positions)
            & ",""experts"":{""observations"":"
            & Interfaces.Unsigned_64'Image (Item.Experts.Observations)
            & ",""admissions"":"
            & Interfaces.Unsigned_64'Image (Item.Experts.Admissions)
            & ",""device_runs"":"
            & Interfaces.Unsigned_64'Image (Item.Experts.Device_Runs)
            & ",""resident_bytes"":"
            & Interfaces.Unsigned_64'Image (Item.Experts.Resident_Bytes)
            & ",""reserve_bytes"":"
            & Interfaces.Unsigned_64'Image (Item.Experts.Reserve_Bytes)
            & "}}");
      end Put_Report;

      procedure Write_JSON
        (File : IO.File_Type; Hash : String; Stored : Boolean) is
         function Divergence (Item : Comparison) return String is
         begin
            if not Item.Prompt_Output_Match then
               return "prompt_output";
            elsif not Item.Turn_Output_Match then
               return "multi_turn_output";
            elsif not Item.Logits_Comparable then
               return "missing_logit_evidence";
            elsif not Item.Top_Tokens_Match then
               return "top_logit_set";
            elsif Item.Max_Logprob_Delta > Long_Float (Logit_Tolerance) then
               return "logprob_tolerance";
            elsif not Item.Timing_Stable then
               return "timing_drift";
            else
               return "none";
            end if;
         end Divergence;
      begin
         IO.Put_Line (File, "{");
         IO.Put_Line (File, "  ""schema"":""expert-cache-bench/1"",");
         IO.Put_Line (File, "  ""runtime"":" & T.JSON_Quoted (Model_Runner.Version) & ",");
         IO.Put_Line
           (File, "  ""engine_id"":"
                  & T.JSON_Quoted
                      (Model_Runner.Expert_Cache_Recommendations.Engine_Identity)
                  & ",");
         IO.Put_Line (File, "  ""model"":" & T.JSON_Quoted (Model) & ",");
         IO.Put_Line (File, "  ""model_sha256"":" & T.JSON_Quoted (Hash) & ",");
         IO.Put_Line
           (File, "  ""device"":" & T.JSON_Quoted (Device_Of (Reports (1))) & ",");
         IO.Put_Line (File, "  ""hardware_qualified"":" & Bool (Hardware) & ",");
         IO.Put_Line (File, "  ""tokens_per_run"":" & Positive'Image (Tokens) & ",");
         IO.Put_Line (File, "  ""repeats"":" & Positive'Image (Repeats) & ",");
         IO.Put_Line (File, "  ""measurement_order"":""A1,B1,B2,A2"",");
         IO.Put_Line (File, "  ""minimum_gain_percent"":" & Number (Minimum_Gain) & ",");
         IO.Put_Line
           (File, "  ""logit_tolerance"":"
                  & Number (Long_Float (Logit_Tolerance)) & ",");
         IO.Put_Line
           (File, "  ""max_leg_drift_percent"":"
                  & Number (Leg_Drift_Limit) & ",");
         IO.Put_Line
           (File, "  ""recommended_cache_bytes"":"
                  & Interfaces.Unsigned_64'Image (Recommended) & ",");
         IO.Put_Line
           (File, "  ""recommendation_stored"":" & Bool (Stored) & ",");
         IO.Put_Line (File, "  ""candidates"":[");
         for Index in 1 .. Count loop
            IO.Put
              (File, "    {""cache_bytes"":"
                     & Interfaces.Unsigned_64'Image (Caches (Index))
                     & ",""prompt"":");
            Put_Report (File, Reports (Index));
            if Has_Turns then
               IO.Put (File, ",""turns"":");
               Put_Report (File, Turn_Reports (Index));
            end if;
            if Index > 1 then
               IO.Put (File, ",""abba"":{""prompt"":[");
               for Leg in ABBA_Leg loop
                  Put_Report (File, Prompt_Trials (Index, Leg));
                  IO.Put (File, (if Leg = ABBA_Leg'Last then "" else ","));
               end loop;
               IO.Put (File, "]");
               if Has_Turns then
                  IO.Put (File, ",""turns"":[");
                  for Leg in ABBA_Leg loop
                     Put_Report (File, Turn_Trials (Index, Leg));
                     IO.Put (File, (if Leg = ABBA_Leg'Last then "" else ","));
                  end loop;
                  IO.Put (File, "]");
               end if;
               IO.Put (File, "}");
            end if;
            IO.Put
              (File, ",""comparison"":{""output_match"":"
                     & Bool (Judgements (Index).Output_Match)
                     & ",""prompt_output_match"":"
                     & Bool (Judgements (Index).Prompt_Output_Match)
                     & ",""turn_output_match"":"
                     & Bool (Judgements (Index).Turn_Output_Match)
                     & ",""divergence"":"
                     & T.JSON_Quoted (Divergence (Judgements (Index)))
                     & ",""logits_comparable"":"
                     & Bool (Judgements (Index).Logits_Comparable)
                     & ",""top_tokens_match"":"
                     & Bool (Judgements (Index).Top_Tokens_Match)
                     & ",""max_logprob_delta"":"
                     & Number (Judgements (Index).Max_Logprob_Delta)
                     & ",""improvement_percent"":"
                     & Number (Judgements (Index).Improvement)
                     & ",""observed_leg_drift_percent"":"
                     & Number (Judgements (Index).Max_Leg_Drift)
                     & ",""timing_stable"":"
                     & Bool (Judgements (Index).Timing_Stable)
                     & ",""physical_work"":"
                     & Bool (Judgements (Index).Physical_Work)
                     & ",""load_qualified"":"
                     & Bool (Judgements (Index).Load_Qualified)
                     & ",""passes"":" & Bool (Judgements (Index).Passes)
                     & "}}" & (if Index = Count then "" else ","));
            IO.New_Line (File);
         end loop;
         IO.Put_Line (File, "  ]");
         IO.Put_Line (File, "}");
      end Write_JSON;

   begin
      Success := False;
      if not Ada.Directories.Exists (Model)
        or else not Ada.Directories.Exists (Prompt)
      then
         return;
      end if;

      for Index in Cache_Sizes'Range loop
         if Cache_Sizes (Index) = ',' then
            Add (Cache_Sizes (First .. Index - 1));
            First := Index + 1;
         end if;
      end loop;
      Add (Cache_Sizes (First .. Cache_Sizes'Last));

      if Count = 1 then
         Measure (0, "", Reports (1));
         Baselines (1) := Reports (1);
         if Has_Turns then
            Measure (0, Turns, Turn_Reports (1));
            Baseline_Turns (1) := Turn_Reports (1);
         end if;
      else
         for Index in 2 .. Count loop
            --  A B B A: temporal and thermal drift affects both sides in
            --  both directions instead of always flattering the one that
            --  ran first or the one that ran last.
            Measure (0, "", Prompt_Trials (Index, 1));
            Measure (Caches (Index), "", Prompt_Trials (Index, 2));
            Measure (Caches (Index), "", Prompt_Trials (Index, 3));
            Measure (0, "", Prompt_Trials (Index, 4));
            Baselines (Index) :=
              Combined
                (Prompt_Trials (Index, 1), Prompt_Trials (Index, 4));
            Reports (Index) :=
              Combined
                (Prompt_Trials (Index, 2), Prompt_Trials (Index, 3));

            if Has_Turns then
               Measure (0, Turns, Turn_Trials (Index, 1));
               Measure (Caches (Index), Turns, Turn_Trials (Index, 2));
               Measure (Caches (Index), Turns, Turn_Trials (Index, 3));
               Measure (0, Turns, Turn_Trials (Index, 4));
               Baseline_Turns (Index) :=
                 Combined
                   (Turn_Trials (Index, 1), Turn_Trials (Index, 4));
               Turn_Reports (Index) :=
                 Combined
                   (Turn_Trials (Index, 2), Turn_Trials (Index, 3));
            end if;

            if not Baselines (Index).Ran or else not Reports (Index).Ran
              or else
                (Has_Turns
                 and then
                   (not Baseline_Turns (Index).Ran
                    or else not Turn_Reports (Index).Ran))
            then
               for Leg in ABBA_Leg loop
                  Explain_Failure
                    ("prompt leg" & Positive'Image (Leg),
                     Prompt_Trials (Index, Leg));
               end loop;
               if Has_Turns then
                  for Leg in ABBA_Leg loop
                     Explain_Failure
                       ("turn leg" & Positive'Image (Leg),
                        Turn_Trials (Index, Leg));
                  end loop;
               end if;
               return;
            end if;
         end loop;
         Baselines (1) := Baselines (2);
         Reports (1) := Baselines (2);
         Baseline_Turns (1) := Baseline_Turns (2);
         Turn_Reports (1) := Baseline_Turns (2);
      end if;

      Hardware :=
        Device_Of (Reports (1)) /= ""
        and then not Is_Software (Device_Of (Reports (1)));

      Judgements (1) :=
        (Prompt_Output_Match => True,
         Turn_Output_Match   => True,
         Output_Match       => True,
         Logits_Comparable  => Reports (1).Probabilities.Positions > 0,
         Top_Tokens_Match   => True,
         Max_Logprob_Delta  => 0.0,
         Improvement        => 0.0,
         Max_Leg_Drift      => 0.0,
         Timing_Stable      => True,
         Physical_Work      => True,
         Hardware_Qualified => Hardware,
         Load_Qualified     =>
           Reports (1).Load_Qualified
           and then (not Has_Turns or else Turn_Reports (1).Load_Qualified),
         Passes             => False);
      for Index in 2 .. Count loop
         Judgements (Index) :=
           Compare
             (Baselines (Index), Reports (Index), Baseline_Turns (Index),
              Turn_Reports (Index), Has_Turns, Minimum_Gain,
              Logit_Tolerance, Hardware);
         Constrain
           (Judgements (Index),
            Compare
              (Prompt_Trials (Index, 1), Prompt_Trials (Index, 2),
               Turn_Trials (Index, 1), Turn_Trials (Index, 2), Has_Turns,
               Minimum_Gain, Logit_Tolerance, Hardware),
            Require_Physical => True);
         Constrain
           (Judgements (Index),
            Compare
              (Prompt_Trials (Index, 4), Prompt_Trials (Index, 3),
               Turn_Trials (Index, 4), Turn_Trials (Index, 3), Has_Turns,
               Minimum_Gain, Logit_Tolerance, Hardware),
            Require_Physical => True);
         Constrain
           (Judgements (Index),
            Compare
              (Prompt_Trials (Index, 1), Prompt_Trials (Index, 4),
               Turn_Trials (Index, 1), Turn_Trials (Index, 4), Has_Turns,
               Minimum_Gain, Logit_Tolerance, Hardware));
         Constrain
           (Judgements (Index),
            Compare
              (Prompt_Trials (Index, 2), Prompt_Trials (Index, 3),
               Turn_Trials (Index, 2), Turn_Trials (Index, 3), Has_Turns,
               Minimum_Gain, Logit_Tolerance, Hardware),
            Require_Physical => True);
         Judgements (Index).Max_Leg_Drift :=
           Maximum_Leg_Drift
             (Total (Prompt_Trials (Index, 1), Turn_Trials (Index, 1)),
              Total (Prompt_Trials (Index, 2), Turn_Trials (Index, 2)),
              Total (Prompt_Trials (Index, 3), Turn_Trials (Index, 3)),
              Total (Prompt_Trials (Index, 4), Turn_Trials (Index, 4)));
         Judgements (Index).Timing_Stable :=
           Judgements (Index).Max_Leg_Drift <= Leg_Drift_Limit;
         Judgements (Index).Passes :=
           Judgements (Index).Output_Match
           and then Judgements (Index).Logits_Comparable
           and then Judgements (Index).Top_Tokens_Match
           and then Judgements (Index).Max_Logprob_Delta
                    <= Long_Float (Logit_Tolerance)
           and then Judgements (Index).Improvement >= Minimum_Gain
           and then Judgements (Index).Timing_Stable
           and then Judgements (Index).Physical_Work
           and then Hardware
           and then Judgements (Index).Load_Qualified;
         if Judgements (Index).Passes
           and then Judgements (Index).Improvement > Best_Gain
         then
            Best_Gain := Judgements (Index).Improvement;
            Recommended := Caches (Index);
         end if;
      end loop;

      declare
         Hash : constant String :=
           Model_Runner.Expert_Cache_Recommendations.Artifact_Digest (Model);
         File : IO.File_Type;
         Stored : Boolean;
      begin
         Model_Runner.Expert_Cache_Recommendations.Save
           (Model_SHA256 => Hash,
            Device => Device_Of (Reports (1)),
            Device_Memory => Device_Memory,
            Bytes => Recommended,
            Protocol => "expert-cache-abba-long-turns/1",
            Report => Report_Path,
            Registry_Path => Recommendation_Path,
            Stored => Stored);
         if Report_Path = "" then
            Write_JSON (IO.Standard_Output, Hash, Stored);
         else
            IO.Create (File, IO.Out_File, Report_Path);
            Write_JSON (File, Hash, Stored);
            IO.Close (File);
         end if;
         if not Stored then
            IO.Put_Line
              (IO.Standard_Error,
               "expert-cache: recommendation registry was not updated");
         end if;
      exception
         when others =>
            if IO.Is_Open (File) then
               IO.Close (File);
            end if;
            return;
      end;
      Success := True;
   exception
      when others =>
         Success := False;
   end Run;

end Expert_Cache_Bench;
