--  The shared decoders compiled for x86-64-v3.
--
--  Reached only for formats selected by the existing dispatch and only when
--  the host reports the required instructions. The shared scalar operations
--  retain contraction-off compilation. Q4_K and Q5_K select native nibble
--  kernels with exact fused subtraction for finite half scales and six-bit
--  factors. Q6_K retains both binary32 multiplications; all three share
--  their existing bounds and scale extraction.
with Model_Runner.Quantization.Decoders;
private package Model_Runner.Quantization.Wide is
   new Model_Runner.Quantization.Decoders (Vector_Q4_K => True, Vector_Q5_K => True, Vector_Q6_K => True);
