with Interfaces;

with Model_Runner.Numerics;

--  Multi-model driver for the adaptive expert-cache qualification protocol.
--  One tab-separated manifest line names MODEL_PATH and optionally its exact
--  DEVICE_MEMORY_BYTES.  Blank lines and lines beginning with # are ignored.
package Expert_Cache_Matrix is

   --  Run every manifest model and atomically install one aggregate JSON
   --  report.  Individual qualification records are embedded as JSON values.
   --  @param Manifest Tab-separated model paths and device budgets.
   --  @param Prompt Long-prompt fixture path.
   --  @param Turns Directory of cumulative instruction-turn fixtures.
   --  @param Cache_Sizes Comma-separated nonzero reserve sizes.
   --  @param Report_Path Aggregate JSON destination; must be nonempty.
   --  @param Recommendation_Path Qualified-decision registry.
   --  @param Tokens Generated tokens per workload.
   --  @param Threads CPU worker count.
   --  @param Context Session context capacity.
   --  @param Repeats Warm repetitions in each ABBA leg.
   --  @param Default_Device_Memory Budget for manifest lines that omit one.
   --  @param Minimum_Gain Smallest acceptable improvement percentage.
   --  @param Logit_Tolerance Largest acceptable log-probability difference.
   --  @param Leg_Drift_Limit Largest acceptable A/A or B/B timing drift.
   --  @param Success True only when every campaign and the aggregate finish.
   procedure Run
     (Manifest        : String;
      Prompt          : String;
      Turns           : String;
      Cache_Sizes     : String;
      Report_Path     : String;
      Recommendation_Path : String;
      Tokens          : Positive;
      Threads         : Positive;
      Context         : Natural;
      Repeats         : Positive;
      Default_Device_Memory : Interfaces.Unsigned_64;
      Minimum_Gain    : Long_Float;
      Logit_Tolerance : Model_Runner.Numerics.Real;
      Leg_Drift_Limit : Long_Float;
      Success         : out Boolean);

end Expert_Cache_Matrix;
