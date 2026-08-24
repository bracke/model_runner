with Model_Runner.Quantization.Integers.Kernels;

--  The integer product built for the instruction set every x86-64 has.
--
--  One of the two compilations of one source; the other is
--  Model_Runner.Quantization.Integers.Wide. Which of them a run enters is
--  decided once, by asking the host, and told to this package's parent.
private package Model_Runner.Quantization.Integers.Plain is
  new Model_Runner.Quantization.Integers.Kernels;
