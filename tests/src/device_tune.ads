--  Explicit, correctness-gated device launch tuning.
package Device_Tune is

   --  Compare the currently compiled launch candidates across product,
   --  exact-attention, and packed-cache decode, verify, and prefill shapes.
   --  A winning combined policy is correctness-replayed before it is stored.
   --
   --  @param Rounds Alternating measured pairs per candidate and shape.
   --  @param Write_Profile Store a winning combined policy at its exact-key
   --    cache path after replaying it.
   --  @param Check_Profile Existing profile to load and replay, or empty for
   --    a tuning campaign.
   --  @param Passed True when a device ran every candidate correctly.
   procedure Report
     (Rounds        : Positive := 7;
      Write_Profile : Boolean := False;
      Check_Profile : String := "";
      Passed        : out Boolean);

end Device_Tune;
