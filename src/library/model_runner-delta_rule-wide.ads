with Model_Runner.Delta_Rule.Kernel;

--  The rule built for x86-64-v3.
--
--  One of the two compilations of one source; the other is
--  Model_Runner.Delta_Rule.Plain. Which of them a run enters is decided
--  once, by asking the host, and told to this package's parent.
private package Model_Runner.Delta_Rule.Wide is
  new Model_Runner.Delta_Rule.Kernel (Wider => True);
