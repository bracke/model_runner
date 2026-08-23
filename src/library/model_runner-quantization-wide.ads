--  The same decoders compiled for a wider instruction set.
--
--  One source, two compilations: this unit differs from Plain only in the
--  switches the project file gives it, which are recorded there beside the
--  reason. Reached only for the four formats measured faster this way and
--  only where the host says it has the instructions, which
--  Model_Runner.Platform.Instructions answers.
--
--  Its switches turn off floating-point contraction, so the arithmetic is
--  the same operations in the same order as the baseline's and a decoded
--  block is the same bits either way. What is wanted from the wider set is
--  the per-lane shift and the gather, not a fused multiply-add.
with Model_Runner.Quantization.Decoders;
private package Model_Runner.Quantization.Wide is
   new Model_Runner.Quantization.Decoders;
