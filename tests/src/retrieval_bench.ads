--  What a task's context holds of the code it is about, measured.
--
--  A project is made fresh under obj/retrieval-bench from the frozen
--  sources in fixtures/retrieval-bench, and a task made for each case: a
--  lookup, a change with callers, an implementation, an impact, one whose
--  tests matter, and the lookup again in a small room. Each case names the
--  lines a model needs to do it -- the declaration, the body, a caller, a
--  test -- and its context is built for rooms of 4,096, 8,192 and 32,768
--  tokens. What is said of each is how many of those lines the context
--  holds (recall), what its source sections cost, and what it costs in
--  all, with the time the build took: the same figures for every build of
--  the harness, so that one retrieval can be held against another.
package Retrieval_Bench is

   --  Make the project, build every case's contexts and say what each held.
   procedure Run;

end Retrieval_Bench;
