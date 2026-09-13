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
   end Definitions_Read;

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
        (T, Grammar_Constrains'Access,
         "the call grammar takes a readable call and prose and refuses the "
         & "rest");
   end Register_Tests;

end Tests.Tools_Cases;
