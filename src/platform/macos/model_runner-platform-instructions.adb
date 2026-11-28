with Model_Runner.Platform.X86_Features;

--  What the processor and macOS together allow this process to execute.
--
--  The wider instruction set this asks about is an x86-64 one, and the four
--  formats that want it run correctly without it -- slower, by between a
--  third and four fifths, and correctly. So the answer here is the one the
--  spec says an implementation that is unsure must give, and it costs those
--  four formats their gain on this host and nothing else.
package body Model_Runner.Platform.Instructions is

   function Wide_Vectors return Boolean is
     (Model_Runner.Platform.X86_Features.Wide_Vectors);

   function Byte_Products return Boolean is
     (Model_Runner.Platform.X86_Features.Byte_Products);

   function Brain_Products return Boolean is
     (Model_Runner.Platform.X86_Features.Brain_Products);

   --  Not asked here: the pause spin, which every x86-64 has.
   function Low_Power_Waits return Boolean is (False);

end Model_Runner.Platform.Instructions;
