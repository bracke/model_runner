with Interfaces;

with Model_Runner.Numerics;

with Speed_Run;

--  Reproducible qualification of adaptive MoE expert residency.
--
--  One campaign binds its recommendation to a model SHA-256, runtime
--  version and device name. It compares a zero-reserve control with each
--  named reserve over a long prompt and, when supplied, a conversation of
--  turn files. Results are JSON so a later run can be compared rather than
--  transcribed.
package Expert_Cache_Bench is

   type Comparison is record
      Prompt_Output_Match : Boolean := False;
      Turn_Output_Match   : Boolean := False;
      Output_Match       : Boolean := False;
      Logits_Comparable  : Boolean := False;
      Top_Tokens_Match   : Boolean := False;
      Max_Logprob_Delta  : Long_Float := Long_Float'Last;
      Improvement        : Long_Float := 0.0;
      Max_Leg_Drift      : Long_Float := 0.0;
      Timing_Stable      : Boolean := True;
      Physical_Work      : Boolean := False;
      Hardware_Qualified : Boolean := False;
      Load_Qualified     : Boolean := False;
      Passes             : Boolean := False;
   end record;

   --  Judge one candidate against the zero-reserve control.
   --  @param Baseline Zero-reserve long-prompt report.
   --  @param Candidate Nonzero-reserve long-prompt report.
   --  @param Baseline_Turns Zero-reserve cumulative-turn report.
   --  @param Candidate_Turns Nonzero-reserve cumulative-turn report.
   --  @param Has_Turns Whether the turn reports participate.
   --  @param Minimum_Gain Smallest acceptable wall-time improvement percent.
   --  @param Logit_Tolerance Largest acceptable log-probability difference.
   --  @param Hardware Whether the selected device is hardware-backed.
   --  @return The complete qualification verdict and supporting differences.
   function Compare
     (Baseline        : Speed_Run.Report;
      Candidate       : Speed_Run.Report;
      Baseline_Turns  : Speed_Run.Report;
      Candidate_Turns : Speed_Run.Report;
      Has_Turns       : Boolean;
      Minimum_Gain    : Long_Float;
      Logit_Tolerance : Model_Runner.Numerics.Real;
      Hardware        : Boolean) return Comparison;

   --  Largest relative timing drift within the two control legs or the two
   --  candidate legs of an A1,B1,B2,A2 measurement.
   --  @param A1 First control duration.
   --  @param B1 First candidate duration.
   --  @param B2 Second candidate duration.
   --  @param A2 Second control duration.
   --  @return Maximum drift as a percentage; Long_Float'Last for a zero leg.
   function Maximum_Leg_Drift
     (A1, B1, B2, A2 : Duration) return Long_Float;

   --  Run and write a complete cache-size campaign.
   --
   --  Cache_Sizes is a comma-separated list of byte counts. A zero control
   --  is inserted when absent. Report_Path empty writes JSON to stdout.
   --  @param Model GGUF artifact to qualify.
   --  @param Prompt Long-prompt fixture path.
   --  @param Turns Directory of cumulative instruction-turn fixtures.
   --  @param Cache_Sizes Comma-separated nonzero reserve sizes in bytes.
   --  @param Report_Path JSON destination, or empty for standard output.
   --  @param Recommendation_Path Qualified-decision registry, or empty for
   --    the platform default.
   --  @param Tokens Generated tokens per workload.
   --  @param Threads CPU worker count.
   --  @param Context Session context capacity.
   --  @param Repeats Warm long-prompt repetitions.
   --  @param Device_Memory Device-memory budget in bytes.
   --  @param Minimum_Gain Smallest acceptable wall-time improvement percent.
   --  @param Logit_Tolerance Largest acceptable log-probability difference.
   --  @param Leg_Drift_Limit Largest acceptable A/A or B/B timing drift.
   --  @param Success True only when the complete report was written.
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
      Success         : out Boolean);

end Expert_Cache_Bench;
