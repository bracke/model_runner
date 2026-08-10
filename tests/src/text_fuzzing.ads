with Interfaces;

--  Fuzzing over the text a caller supplies, rather than over a model file.
--
--  Everything fuzzed until now was a container: `Fuzzing` mutates the bytes
--  of a GGUF file and asks whether the parser still refuses what it should.
--  That leaves out the other untrusted input, and the larger one by volume:
--  a prompt file, or standard input, or a command line, all of which reach
--  Model_Runner.Tokenizer.Encode with whatever was in them.
--
--  What that gap cost was a denial of service that stood for as long as the
--  marker rule did. Encode looks for a control token wherever the text opens
--  a bracket, and the scan reached the longest token the format allows --
--  1024 bytes -- at every one of them. Sixty thousand brackets, well inside
--  the documented input limit, took twenty-five seconds where the same
--  length of ordinary text took four hundredths. No test noticed, because
--  every test tokenizes text somebody wrote on purpose.
--
--  So this campaign watches the clock as well as the outcome. A case fails
--  when the call raises, when it reports a code the interface does not
--  document, when it says it succeeded and hands back a token outside the
--  vocabulary, or when it takes longer than the limit for text of its size.
--
--  Both roads are fuzzed, because they share the marker rule and nothing
--  else, and both vocabularies come from the fixture writer, so no campaign
--  here needs a model that cannot be committed.
--
--  Task safety: one campaign at a time.
package Text_Fuzzing is

   --  What one case did.
   type Outcome is
     (Encoded,        --  Text encoded and every token was in range.
      Refused,        --  Text refused with a documented code.
      Escaped,        --  An exception left Encode.
      Undocumented,   --  A code the interface does not name.
      Out_Of_Range,   --  Success, and a token the vocabulary does not hold.
      Not_Reversible, --  Success, and decoding raised.
      Slow);          --  Past the time limit for text of that size.

   --  Totals for a campaign.
   type Report is record
      Cases        : Natural := 0;
      Encoded      : Natural := 0;
      Refused      : Natural := 0;
      Escaped      : Natural := 0;
      Undocumented : Natural := 0;
      Out_Of_Range : Natural := 0;
      Not_Reversible : Natural := 0;
      Slow         : Natural := 0;

      --  The longest any single case took, in milliseconds, and the case
      --  that took it. Reported whether or not anything failed, because a
      --  campaign that is merely getting slower is worth seeing before it
      --  crosses the limit.
      Worst        : Natural := 0;
      Worst_Case   : Natural := 0;
      First_Bad    : Natural := 0;
   end record;

   --  Report whether a campaign found only acceptable outcomes.
   --
   --  @param Item Report to classify.
   --  @return True when nothing escaped, nothing undocumented was reported,
   --    no accepted text produced a token out of range and nothing was slow.
   function Is_Clean (Item : Report) return Boolean
   is (Item.Escaped = 0 and then Item.Undocumented = 0
       and then Item.Out_Of_Range = 0 and then Item.Not_Reversible = 0
       and then Item.Slow = 0);

   --  Report whether a campaign encoded anything at all.
   --
   --  Clean totals mean nothing if every case was refused before the merge
   --  loop: the checks past that point would be untested rather than
   --  satisfied.
   --
   --  @param Item Report to classify.
   --  @return True when at least one case encoded.
   function Reached_The_Merges (Item : Report) return Boolean
   is (Item.Encoded > 0);

   --  Run a whole campaign.
   --
   --  @param Seed Run seed; a case is derived from it and the case number, so
   --    a failure replays exactly.
   --  @param Cases Number of cases to run.
   --  @param Result Totals, including the first offending case number.
   procedure Run
     (Seed   : Interfaces.Unsigned_64;
      Cases  : Positive;
      Result : out Report);

end Text_Fuzzing;
