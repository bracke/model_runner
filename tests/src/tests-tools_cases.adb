with AUnit.Assertions; use AUnit.Assertions;

with Model_Runner.Errors;
with Model_Runner.Grammar;
with Model_Runner.Tools;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Constraint;

package body Tests.Tools_Cases is

   package E renames Model_Runner.Errors;
   package G renames Model_Runner.Grammar;
   package Tools renames Model_Runner.Tools;
   package Builtin renames Model_Runner.Tools.Builtin;
   package Constraint renames Model_Runner.Tools.Constraint;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("built-in tools and the call grammar");
   end Name;

   --  Run one built-in call and return its answer.
   function Answer (Named, Arguments : String) return String is
      Runner : Builtin.Instance;
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      Runner.Run (Named, Arguments, Room, Last, Status);
      Assert (E.Is_Ok (Status),
              "a built-in tool would not answer: "
              & E.Error_Code'Image (Status.Code));
      return Room (1 .. Last);
   end Answer;

   --  Whether the call grammar, compiled from the built-in tools, accepts a
   --  text whole and calls it complete.
   function Grammar_Takes (Text : String) return Boolean is
      Defs   : Tools.Definitions;
      Rules  : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Held   : Boolean;
   begin
      Tools.Read (Defs, Builtin.Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the built-in definitions would not read");

      Constraint.Compile_Call_Grammar (Defs, Rules, Status);
      Assert (E.Is_Ok (Status),
              "the call grammar would not compile: "
              & E.Error_Code'Image (Status.Code));
      Assert (G.Is_Ready (Rules), "the call grammar is not ready");

      G.Start (Rules, State, Status);
      Assert (E.Is_Ok (Status), "the call grammar would not start");

      G.Advance (Rules, State, Text, Status);
      if E.Is_Error (Status) then
         G.Close (Rules);
         Tools.Close (Defs);
         return False;
      end if;

      Held := G.Is_Complete (Rules, State);
      G.Close (Rules);
      Tools.Close (Defs);
      return Held;
   end Grammar_Takes;

   --  Whether the call grammar, compiled with an answer schema, accepts a
   --  text whole and calls it complete.
   function Grammar_Takes_Answer (Text, Schema : String) return Boolean is
      Defs   : Tools.Definitions;
      Rules  : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Held   : Boolean;
   begin
      Tools.Read (Defs, Builtin.Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the built-in definitions would not read");

      Constraint.Compile_Call_Grammar
        (Defs, Rules, Status, Answer_Schema => Schema);
      Assert (E.Is_Ok (Status),
              "the call grammar would not compile with an answer schema: "
              & E.Error_Code'Image (Status.Code));
      Assert (G.Is_Ready (Rules), "the answer-schema grammar is not ready");

      G.Start (Rules, State, Status);
      Assert (E.Is_Ok (Status), "the answer-schema grammar would not start");

      G.Advance (Rules, State, Text, Status);
      if E.Is_Error (Status) then
         G.Close (Rules);
         Tools.Close (Defs);
         return False;
      end if;

      Held := G.Is_Complete (Rules, State);
      G.Close (Rules);
      Tools.Close (Defs);
      return Held;
   end Grammar_Takes_Answer;

   --  With an answer schema, a reply is a tool call or an answer in that
   --  shape -- never free prose and never an answer of the wrong shape.
   procedure Answer_Schema_Shapes_The_Answer
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Schema : constant String :=
        "{""type"":""object"",""properties"":"
        & "{""answer"":{""type"":""integer""}},""required"":[""answer""]}";
   begin
      --  A well-formed call is still taken: the loop must still be able to
      --  reach a tool on the way to the answer.
      Assert
        (Grammar_Takes_Answer
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47,""op"":""*"",""b"":89}}</tool_call>", Schema),
         "a call was refused once an answer schema was set");
      --  An answer object in the schema's shape is taken whole.
      Assert
        (Grammar_Takes_Answer ("{""answer"":4183}", Schema),
         "a schema-valid answer was refused");
      --  Prose is no longer an answer.
      Assert
        (not Grammar_Takes_Answer ("The answer is 4183.", Schema),
         "prose was taken where a shaped answer was required");
      --  An answer of the wrong type is refused.
      Assert
        (not Grammar_Takes_Answer ("{""answer"":""x""}", Schema),
         "an answer whose type did not match the schema was taken");
      --  An answer missing the required field is refused.
      Assert
        (not Grammar_Takes_Answer ("{}", Schema),
         "an answer missing a required field was taken");
   end Answer_Schema_Shapes_The_Answer;

   --  Every built-in tool answers the same way every time.
   procedure Answers_Are_Fixed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Answer ("calculator", "{""a"": 47, ""op"": ""*"", ""b"": 89}")
         = "4183",
         "the calculator did not multiply");
      Assert
        (Answer ("calculator", "{""a"": 10, ""op"": ""-"", ""b"": 4}")
         = "6",
         "the calculator did not subtract");
      Assert
        (Answer ("calculator", "{""a"": 5, ""op"": ""/"", ""b"": 0}")
         = "error: division by zero",
         "the calculator divided by zero");
      Assert
        (Answer ("string_length", "{""text"": ""hello""}") = "5",
         "string_length miscounted");
      Assert
        (Answer ("reverse_text", "{""text"": ""abc""}") = "cba",
         "reverse_text did not reverse");
      Assert
        (Answer ("lookup", "{""key"": ""capital_of_france""}") = "Paris",
         "lookup did not find the fact");
      Assert
        (Answer ("nonesuch", "{}")
           (1 .. 5) = "error",
         "an unknown tool was not reported as one");
   end Answers_Are_Fixed;

   --  The definitions read as the four tools they describe.
   procedure Definitions_Read
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Defs   : Tools.Definitions;
      Status : E.Error_Info;
   begin
      Tools.Read (Defs, Builtin.Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the built-in definitions would not read");
      Assert (Tools.Count (Defs) = 4, "the definitions are not four tools");
      Assert (Tools.Offers (Defs, "calculator"), "calculator is not offered");
      Assert (Tools.Offers (Defs, "lookup"), "lookup is not offered");
      Assert (not Tools.Offers (Defs, "danger"),
              "a tool nobody defined is offered");
      Tools.Close (Defs);

      --  The full set reads too, and offers the tools that reach the world.
      declare
         All_Defs : Tools.Definitions;
         Rules    : G.Compiled;
         G_Status : E.Error_Info;
      begin
         Tools.Read (All_Defs, Builtin.All_Definitions_Text, Status);
         Assert (E.Is_Ok (Status), "the full definitions would not read");
         Assert (Tools.Count (All_Defs) = 17,
                 "the full set is not seventeen tools");
         Assert (Tools.Offers (All_Defs, "shell"), "shell is not offered");
         Assert (Tools.Offers (All_Defs, "http_get"),
                 "http_get is not offered");
         Assert (Tools.Offers (All_Defs, "memory_put"),
                 "memory_put is not offered");

         --  The grammar still compiles over the full set (a no-argument tool
         --  makes it fall back to the looser form, which must still build).
         Constraint.Compile_Call_Grammar (All_Defs, Rules, G_Status);
         Assert (E.Is_Ok (G_Status) and then G.Is_Ready (Rules),
                 "the call grammar would not compile over the full set");
         G.Close (Rules);
         Tools.Close (All_Defs);
      end;
   end Definitions_Read;

   --  The stateless new pure tools answer the same way every time.
   procedure Pure_Additions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Answer ("base64_encode", "{""text"":""hi""}") = "aGk=",
              "base64_encode is wrong");
      Assert (Answer ("base64_decode", "{""text"":""aGk=""}") = "hi",
              "base64_decode did not round-trip");
   end Pure_Additions;

   --  Memory keeps what one call wrote for a later call to read.
   procedure Memory_Round_Trips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Runner : Builtin.Instance;
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      Runner.Run ("memory_put", "{""key"":""x"",""value"":""42""}",
                  Room, Last, Status);
      Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "ok",
              "memory_put did not accept the note");
      Runner.Run ("memory_get", "{""key"":""x""}", Room, Last, Status);
      Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "42",
              "memory_get did not recall what was put");
      Runner.Run ("memory_get", "{""key"":""nope""}", Room, Last, Status);
      Assert (Room (1 .. Last) (1 .. 5) = "error",
              "memory_get invented a value for an unknown key");
   end Memory_Round_Trips;

   --  The grammar takes a well-formed call to an offered tool, takes prose,
   --  and refuses a call to a tool nobody offered.
   procedure Grammar_Constrains
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  A well-formed call whose arguments match the calculator's schema.
      --  The arguments are compact, which is what the schema grammar allows;
      --  whitespace is still fine in the envelope around them.
      Assert
        (Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47,""op"":""*"",""b"":89}}</tool_call>"),
         "the grammar refused a well-formed call to an offered tool");
      Assert
        (Grammar_Takes
           ("<tool_call>{""name"": ""lookup"", ""arguments"": "
            & "{""key"":""capital_of_france""}}</tool_call>"),
         "the grammar refused a well-formed lookup call");
      --  The same call spaced the way a model naturally writes it -- a space
      --  after each colon and comma -- is taken too: the schema grammar
      --  tolerates whitespace rather than forcing compact JSON.
      Assert
        (Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"": 47, ""op"": ""*"", ""b"": 89}}</tool_call>"),
         "the grammar refused a schema-valid call with natural spacing");
      Assert
        (Grammar_Takes ("The answer is 4183."),
         "the grammar refused plain prose");
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""danger"", ""arguments"": {}}"
            & "</tool_call>"),
         "the grammar took a call to a tool nobody offered");
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47</tool_call>"),
         "the grammar took a call whose arguments never closed");

      --  Arguments that do not match the named tool's schema are refused:
      --  the calculator requires a, op and b, so a call missing op and b is
      --  not a call the grammar allows.
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47}}</tool_call>"),
         "the grammar took a calculator call missing required arguments");
      --  A string where the schema asks for an integer is refused too.
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":""x"",""op"":""*"",""b"":89}}</tool_call>"),
         "the grammar took a calculator call with a non-integer argument");
      --  And the lookup's key is one of a fixed set: another string is not
      --  a call the grammar allows.
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""lookup"", ""arguments"": "
            & "{""key"":""nonesuch""}}</tool_call>"),
         "the grammar took a lookup call with a key outside its enum");
   end Grammar_Constrains;

   -------------------
   -- Register_Tests --
   -------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Answers_Are_Fixed'Access,
         "every built-in tool answers the same way every time");
      Register_Routine
        (T, Definitions_Read'Access,
         "the built-in definitions read as the tools they describe");
      Register_Routine
        (T, Pure_Additions'Access,
         "the added pure tools answer the same way every time");
      Register_Routine
        (T, Memory_Round_Trips'Access,
         "memory keeps what one call wrote for a later call to read");
      Register_Routine
        (T, Grammar_Constrains'Access,
         "the call grammar takes a readable call and prose and refuses the "
         & "rest");
      Register_Routine
        (T, Answer_Schema_Shapes_The_Answer'Access,
         "an answer schema makes the reply a call or an answer in that "
         & "shape, not prose");
   end Register_Tests;

end Tests.Tools_Cases;
