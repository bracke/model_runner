with Speed_Run;

--  The machine-readable verdict for a retained-session speed campaign.
--
--  Kept apart from the command-line presentation so every refusal --
--  including malformed bounds -- can be exercised without loading a model.
package Cache_Regression is

   type Failure_Kind is
     (Turns_Required,
      Campaign_Incomplete,
      Rewind_Failed,
      Invalid_Hit_Minimum,
      Hit_Rate_Too_Low,
      Invalid_Evaluated_Maximum,
      Too_Many_Evaluated,
      Invalid_Prompt_Maximum,
      Prompt_Too_Slow,
      Digest_Differs);

   type Failure_Set is array (Failure_Kind) of Boolean;

   --  Check one report against the bounds as the command spells them.
   --  An empty bound is absent. Numeric text must be nonnegative.
   --
   --  @param Item Completed speed campaign to judge.
   --  @param Has_Turns Whether the command named a turns directory.
   --  @param Hit_Minimum Least accepted reuse percentage, or empty.
   --  @param Evaluated_Maximum Most accepted evaluated tokens, or empty.
   --  @param Prompt_Maximum Most accepted prompt seconds, or empty.
   --  @param Expected_Digest Required output digest, or empty.
   --  @param Failures Every reason the campaign was refused.
   procedure Check
     (Item               : Speed_Run.Report;
      Has_Turns          : Boolean;
      Hit_Minimum        : String;
      Evaluated_Maximum  : String;
      Prompt_Maximum     : String;
      Expected_Digest    : String;
      Failures           : out Failure_Set);

   --  Percentage of cumulative prompt tokens retained by the session.
   --
   --  @param Item Speed campaign whose reuse is counted.
   --  @return Reused tokens as a percentage of cumulative prompt tokens.
   function Hit_Rate (Item : Speed_Run.Report) return Long_Float;

   --  Whether no refusal was recorded.
   --
   --  @param Failures Reasons returned by Check.
   --  @return True when every failure flag is false.
   function Passed (Failures : Failure_Set) return Boolean;

end Cache_Regression;
