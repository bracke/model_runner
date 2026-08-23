--  The decoders as every x86-64 runs them.
--
--  The instance the program uses for eleven of the fifteen formats, and for
--  all fifteen on a host that does not offer the wider instruction set. Its
--  switches are the project's own, which is what makes it the baseline this
--  build was measured against for years.
with Model_Runner.Quantization.Decoders;
private package Model_Runner.Quantization.Plain is
   new Model_Runner.Quantization.Decoders;
