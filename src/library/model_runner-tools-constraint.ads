with Model_Runner.Errors;
with Model_Runner.Grammar;

--  A grammar that shapes what a tool-calling reply may be.
--
--  A model offered tools may answer in words or ask for a tool, and when it
--  asks it writes the call in the envelope its template taught it -- for the
--  templates here, a JSON object between <tool_call> and </tool_call>. Left
--  to itself it writes that envelope almost always and now and then not: a
--  brace it forgets to close, a name it spells with a space, a call the
--  reader cannot read. A grammar is how "almost always" becomes always. The
--  tokens that would write a malformed call are not in the distribution to
--  be sampled, so the reply is either prose or a call this engine can read,
--  and never the third thing.
--
--  What the grammar allows: some prose, then any number of tool-call blocks.
--  Each block is the envelope around a JSON object whose name is one of the
--  tools offered and whose arguments are a well-formed JSON value. So a call
--  always parses and always names a tool the caller has -- which is the
--  guarantee the loop is built on.
--
--  The narrow edge: prose may not contain a '<'. A grammar governs the whole
--  generation, not the calls alone, and telling prose from the start of a
--  call without a '<' to look at cannot be done by a grammar that reads left
--  to right with no lookahead. So the '<' is reserved. For the short factual
--  answers a tool task ends in this costs nothing; it is written down
--  because it is a real bound and not a bug.
--
--  Task safety: pure text in, a compiled grammar out; no state of its own.
package Model_Runner.Tools.Constraint is

   --  Compile a grammar that constrains a reply to the tools offered.
   --
   --  @param Offered The tools the caller is offering. Its names become the
   --    calls the grammar allows; a name it does not carry cannot be
   --    written. Offering nothing yields a grammar of prose alone.
   --  @param Into Receives the compiled grammar; released first.
   --  @param Status Success, Tools_Too_Large when the names would not fit
   --    the grammar buffer, or a grammar diagnostic when the assembled
   --    source will not compile.
   procedure Compile_Call_Grammar
     (Offered : Model_Runner.Tools.Definitions;
      Into    : in out Model_Runner.Grammar.Compiled;
      Status  : out Model_Runner.Errors.Error_Info);

end Model_Runner.Tools.Constraint;
