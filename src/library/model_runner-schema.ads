with Model_Runner.Errors;

--  A JSON schema, as a grammar the sampler can enforce.
--
--  A grammar says what the model may produce; a schema says what shape an
--  answer has to be. They are the same statement in two notations, and this
--  turns the one people write into the one the sampler reads. A caller with
--  a schema should not have to hand-write GBNF for it and then keep the two
--  in step.
--
--  What is read. The keywords a schema needs to describe an answer:
--
--    type          object, array, string, number, integer, boolean, null,
--                  or a list of those, which becomes alternatives
--    properties    with required; a property the schema does not require
--                  may be absent, and a schema naming no required list
--                  requires everything -- which is not what JSON Schema
--                  says, where absent means optional, and is the narrow
--                  direction this errs in throughout
--    items         the shape of every element of an array
--    enum          a choice between literal values
--    const         a single literal value
--
--  Everything else is refused where it is met rather than approximated. A
--  schema this cannot express exactly would otherwise become a grammar that
--  allows more than the schema does, and a caller would have a constraint
--  that quietly is not one -- which is worse than being told to write the
--  grammar by hand.
--
--  Objects are closed: exactly the properties named, in the order named.
--  The first property named must be one the schema requires, because a
--  first property that may be absent makes the comma before the second
--  conditional on it, and expressing that needs an alternative for every
--  place the object might start.
--  JSON says an object's members are unordered and a schema does not fix
--  their order, so a grammar that allowed every order would be a grammar
--  whose size grows as the factorial of the property count. What this
--  produces is therefore narrower than the schema: everything it accepts the
--  schema accepts, and not the reverse. That is the honest direction for a
--  constraint to err in, and it is written down here because a reader has to
--  know which way it goes.
--
--  Task safety: pure text in, pure text out; no state.
package Model_Runner.Schema is

   --  Largest grammar this will produce, in characters.
   Max_Grammar_Bytes : constant := 64 * 1024;

   --  Largest schema this will read, in characters.
   Max_Schema_Bytes : constant := 64 * 1024;

   --  How deeply a schema may nest.
   Max_Depth : constant := 16;

   --  Turn a JSON schema into a grammar.
   --
   --  @param Text The schema, as JSON.
   --  @param Grammar Receives the grammar; empty on failure. The caller
   --    passes it to the grammar compiler, which is what checks it: this
   --    writes a grammar and does not compile one.
   --  @param Last Length of the grammar written.
   --  @param Status Success, Grammar_Syntax_Error when the schema is not
   --    JSON this can read, Grammar_Schema_Unsupported when it names a
   --    keyword this does not express exactly, Grammar_Nesting_Too_Deep, or
   --    Grammar_Too_Large.
   procedure To_Grammar
     (Text    : String;
      Grammar : out String;
      Last    : out Natural;
      Status  : out Model_Runner.Errors.Error_Info);

   --  The same schema as the parameters of a call written in tags, the
   --  way the Qwen3-Coder and MiniCPM families write one: each property
   --  as Before, its name, After, its value, Close -- "<parameter=", ">"
   --  and "</parameter>" for the one, "<param name=\"", "\">" and
   --  "</param>" for the other -- in the order the schema names them,
   --  a property the schema does not require allowed to be absent, and
   --  nothing between them but whitespace.
   --
   --  A value in a tag is text, not JSON: a string is any run of
   --  characters without a '<', an enum's choices are the words
   --  themselves without quotes, a number or a boolean is written as it
   --  would be anywhere, and an object or an array is JSON, since that is
   --  what those families write for one. The schema must be an object
   --  with properties; anything else is refused.
   --
   --  @param Text The schema, as JSON.
   --  @param Before What opens a parameter's tag, before its name.
   --  @param After What follows the name and closes the opening tag.
   --  @param Close What closes the parameter.
   --  @param Grammar Receives the grammar; empty on failure.
   --  @param Last Length of the grammar written.
   --  @param Status As To_Grammar.
   procedure To_Tag_Grammar
     (Text    : String;
      Before  : String;
      After   : String;
      Close   : String;
      Grammar : out String;
      Last    : out Natural;
      Status  : out Model_Runner.Errors.Error_Info);

end Model_Runner.Schema;
