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
--  tools offered and whose arguments match that tool's own parameter schema
--  -- the same schema the model was shown, turned into a grammar by
--  Model_Runner.Schema and paired with the tool's name, so a call for the
--  calculator cannot carry the lookup's arguments. When a tool names no
--  schema this can read, that tool's arguments fall back to a general JSON
--  value; when no tool's schema can be read, the whole grammar does. Either
--  way a call always parses and always names a tool the caller has -- which
--  is the guarantee the loop is built on.
--
--  The schema grammar is compact: it allows no whitespace inside the
--  arguments object, so a model constrained by it writes {"a":1} and not
--  {"a": 1}. The envelope around the arguments still allows whitespace, and
--  either spelling is JSON the reader accepts.
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
   --    written. Offering nothing yields a grammar of prose alone -- or, with
   --    an answer schema, of that answer alone.
   --  @param Into Receives the compiled grammar; released first.
   --  @param Status Success, Tools_Too_Large when the names would not fit
   --    the grammar buffer, or a grammar diagnostic when the assembled
   --    source will not compile.
   --  @param Answer_Schema A JSON schema the final answer must match, or the
   --    empty string for a free-text answer. When given, the reply is no
   --    longer prose or a call but a call or an object matching this schema:
   --    a model that is not calling a tool must answer in the shape asked
   --    for. It is honoured when the per-tool schema grammar can be built
   --    (or when no tools are offered); when the tools force the looser
   --    fallback, or when the answer schema itself will not compile, the
   --    answer falls back to free text.
   procedure Compile_Call_Grammar
     (Offered       : Model_Runner.Tools.Definitions;
      Into          : in out Model_Runner.Grammar.Compiled;
      Status        : out Model_Runner.Errors.Error_Info;
      Answer_Schema : String := "");

end Model_Runner.Tools.Constraint;
