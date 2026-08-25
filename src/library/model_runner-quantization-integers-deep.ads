with Model_Runner.Quantization.Integers.Kernels;

--  The integer product built for x86-64-v4, through the byte dot product.
--
--  The third of three compilations of one source. Plain is the baseline and
--  Wide is x86-64-v3; this one is entered only where the host says it has
--  the byte dot product, which is asked once at elaboration as the other
--  question is.
--
--  What it is for is one instruction: where the other two multiply two
--  sixteen-bit pairs into a lane, this multiplies four eight-bit ones. That
--  also means the weights need no widening at all -- they are read as the
--  bytes the file holds -- which is the unpack the other two spend seven per
--  cent of a prompt on, and half the operand traffic besides.
private package Model_Runner.Quantization.Integers.Deep is
  new Model_Runner.Quantization.Integers.Kernels
        (Wider => True, Deep => True);
