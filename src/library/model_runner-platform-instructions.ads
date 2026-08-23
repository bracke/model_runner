--  What the host's processor can be asked to do beyond the baseline.
--
--  One question, asked once: does this processor have the per-lane shifts and
--  the gathers that four of the fifteen quantized formats decode faster with.
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

end Model_Runner.Platform.Instructions;
