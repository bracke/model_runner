--  What the processor offers, on a host nothing here has asked.
--
--  The wider instruction set this asks about is an x86-64 one, and the four
--  formats that want it run correctly without it -- slower, by between a
--  third and four fifths, and correctly. So the answer here is the one the
--  spec says an implementation that is unsure must give, and it costs those
--  four formats their gain on this host and nothing else.
package body Model_Runner.Platform.Instructions is

   function Wide_Vectors return Boolean is (False);

end Model_Runner.Platform.Instructions;
