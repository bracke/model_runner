with Jsonlib.Documents;

package Campaign_Statistics is

   --  Descriptive comparisons only: repeated attempts are not independent new tasks.
   --  @param From Document owning the attempts array.
   --  @param Attempts Finished attempt records with explicit grades and nullable metrics.
   --  @return JSON with per-arm medians and paired comparisons, without a significance claim.
   --  @param Default_Only Compare base/adapted with unchanged thinking defaults instead of four explicit arms.
   function Describe
     (From : Jsonlib.Documents.Document; Attempts : Jsonlib.Documents.Node;
      Default_Only : Boolean := False) return String;

end Campaign_Statistics;
