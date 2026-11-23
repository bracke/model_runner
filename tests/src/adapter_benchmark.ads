--  Paired CPU timing through Speed_Run; adapters may be synthetic and no quality result is inferred.
package Adapter_Benchmark is
   --  @param Model_Path Complete local GGUF base, shared by all arms.
   --  @param Adapter_Path Complete local GGUF adapter; no downloads are performed.
   --  @param Prompt_Path Raw prompt file, capped at 64 KiB.
   --  @param Output_Path New JSON report path; existing files are refused.
   --  @param Clean Whether every arm finished, with fixed work and the zero-scale identity control intact.
   --  @param Repeats Paired repetitions, from one through 21, with alternating arm order.
   --  @param Tokens Generated tokens per sample, from one through 256, ignoring EOS.
   --  @param Threads CPU worker count, from one through 64.
   --  @param Batch Prompt batch size, from one through 256.
   --  @param Context Explicit session capacity, from 16 through 32768.
   --  @param Include_Merge Include the same-base F32 merge arm, with conservative host memory admission.
   procedure Run
     (Model_Path, Adapter_Path, Prompt_Path, Output_Path : String; Clean : out Boolean;
      Repeats : Positive := 5; Tokens : Positive := 16; Threads : Positive := 4;
      Batch : Positive := 16; Context : Positive := 512; Include_Merge : Boolean := False);
end Adapter_Benchmark;
