with Model_Runner.Quantization.Integers.Kernels;

--  The integer product built for x86-64-v3.
--
--  One of the two compilations of one source; the other is
--  Model_Runner.Quantization.Integers.Plain. Which of them a run enters is
--  decided once, by asking the host, and told to this package's parent.
private package Model_Runner.Quantization.Integers.Wide is
  new Model_Runner.Quantization.Integers.Kernels;
