--  A call written as Python, read as the JSON every other call shape is
--  read as.
--
--  Gemma was trained to call a function by writing the call itself, in
--  Python, in a ```tool_code block: get_weather(city="Paris", days=3). The
--  rest of the program knows a call as a name and its arguments as one JSON
--  object, so this reads the Python into that: each keyword argument a
--  member, each literal its JSON -- a string in any of Python's quotes,
--  escapes and all, and adjacent strings joined as Python joins them; True,
--  False and None as true, false and null; a list or a tuple as an array; a
--  dict as an object. A call wrapped in print(..), as the model writes one
--  now and then, is the call inside it, and a name with a module before it
--  -- api.get_weather -- is its last part.
--
--  An argument with no keyword is the tool's parameter in that place, in
--  the order its definition names them, where the tools offered are given:
--  calculator(47, op="+") is a=47. What is not a literal -- an expression,
--  a variable -- and an argument with no keyword where no definition says
--  what it is, is no call this can read: the model is told, as for any call
--  that does not read, rather than given a guess.
--
--  Task safety: no state.
package Model_Runner.Tools.Python_Calls is

   --  Read the next call in Text at or after From.
   --
   --  @param Text A tool_code block's text and what follows it: the block
   --    is read call by call, so a "```" inside a string is the string's.
   --  @param From Where to start; on return, past the call read, at the
   --    fence that closes the block, or past Text when neither was left.
   --  @param Name The function's name.
   --  @param Name_Last Length of the name in Name.
   --  @param Args The arguments, a JSON object.
   --  @param Args_Last Length of the object in Args.
   --  @param Found Whether there was a call left; False with Ok True when
   --    only whitespace, or the closing fence, was.
   --  @param Ok False when what stands there is not a call this reads.
   --  @param Offered The tools offered, whose definitions name a positional
   --    argument; null where none are known, and then one is refused.
   procedure Read_Call
     (Text      : String;
      From      : in out Positive;
      Name      : out String;
      Name_Last : out Natural;
      Args      : out String;
      Args_Last : out Natural;
      Found     : out Boolean;
      Ok        : out Boolean;
      Offered   : access constant Definitions'Class := null);

   --  The name of a tool's parameter in a place, in the order its
   --  definition's properties name them.
   --
   --  @param Definition The tool's definition, as JSON.
   --  @param Place Which, from 1.
   --  @return The name; "" where there is no such parameter.
   function Parameter_At (Definition : String; Place : Positive) return String;

end Model_Runner.Tools.Python_Calls;
