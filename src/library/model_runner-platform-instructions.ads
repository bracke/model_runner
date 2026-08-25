--  What the host's processor can be asked to do beyond the baseline.
--
--  Two questions, each asked once: does this processor have the per-lane
--  shifts and the gathers that four of the fifteen quantized formats decode
--  faster with, and does it have the byte dot product the integer product
--  multiplies through.
--  Only the answer differs between hosts and only the way of asking is
--  host-specific, so this is one spec with one body per host, beside the
--  topology body it is modelled on.
--
--  False means the host said no, could not be asked, or answered something
--  this did not understand. It is not an error: the baseline compilation
--  runs every format, as it did before any of this was here, and an
--  implementation that is unsure says False rather than risk an instruction
--  the processor has not got.
--
--  Task safety: a call reads the host and holds no state.
private package Model_Runner.Platform.Instructions is

   --  Whether this processor offers the x86-64-v3 vector instructions --
   --  in particular the per-lane variable shift and the gather.
   --
   --  @return True only where the host says so plainly.
   function Wide_Vectors return Boolean;

   --  Whether this processor offers a byte dot product -- the instruction
   --  that multiplies four eight-bit pairs into one thirty-two bit lane,
   --  where the wider set above multiplies two sixteen-bit pairs.
   --
   --  Asked separately from Wide_Vectors because it is a separate answer: a
   --  processor may have the wide lanes and not this, and every processor
   --  that has this has those. False costs the integer product the byte
   --  instruction and nothing else -- the sixteen-bit path computes the same
   --  values to the bound the sweep states.
   --
   --  @return True only where the host says so plainly.
   function Byte_Products return Boolean;

end Model_Runner.Platform.Instructions;
