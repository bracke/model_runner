--  Native adversarial subprocesses used by the campaign boundary regressions.
package Campaign_Probe is

   --  @param Write_Only Test only whether a forbidden destination can be overwritten.
   --  @param Writable Directory where the confined parent must still be able to write.
   --  @param Guarded Hidden verifier sentinel, or the write-only destination.
   --  @param Outside Read-only host sentinel outside the campaign.
   --  @return Zero for a sound boundary, nine for a refused write-only attack, one for a regression.
   function Run (Write_Only : Boolean; Writable, Guarded, Outside : String) return Natural;

end Campaign_Probe;
