with Ada.Strings.Fixed;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with AUnit.Assertions; use AUnit.Assertions;

with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with Zlib;

with Ada.Environment_Variables;

with Model_Runner.Agent;
with Model_Runner.Cancellation;
with Model_Runner.Agent.Recall;
with Model_Runner.Errors;
with Model_Runner.Framework.Permissions;
with Model_Runner.Numerics;
with Model_Runner.Grammar;
with Hostkit.Metadata;
with Model_Runner.Tools;
with Model_Runner.UTF8;
with Model_Runner.Tools.Builtin;
with Model_Runner.CLI.Command_Lines;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.Processes;
with Model_Runner.Agent_Runtime;
with Model_Runner.Tools.Python_Calls;
with Model_Runner.Tools.Registry;
with Model_Runner.Tools.Schemas;
with Model_Runner.Tools.Editing;
with Model_Runner.Tools.Constraint;
with Model_Runner.Tools.Runner;

package body Tests.Tools_Cases is

   use type Model_Runner.Numerics.Element_Count;
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

   --  Whether the grammar compiled from the whole built-in set accepts a
   --  text whole. The full set must build the tight grammar -- one that
   --  pins each tool's arguments -- and not fall back to the loose one.
   function Full_Set_Takes (Text : String) return Boolean is
      Defs   : Tools.Definitions;
      Rules  : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Held   : Boolean;
   begin
      Tools.Read (Defs, Builtin.All_Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the full definitions would not read");
      Constraint.Compile_Call_Grammar (Defs, Rules, Status);
      Assert (E.Is_Ok (Status) and then G.Is_Ready (Rules),
              "the full-set call grammar would not compile");
      G.Start (Rules, State, Status);
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
   end Full_Set_Takes;

   --  The whole built-in set -- all eighteen tools -- builds the tight
   --  grammar: a call names a tool and its arguments match that tool's
   --  schema. It must not outgrow the grammar and fall back to the loose
   --  form, which would leave arguments (and an answer schema) unconstrained.
   procedure Full_Set_Is_Tight
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  A well-formed calculator call is taken.
      Assert
        (Full_Set_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47,""op"":""*"",""b"":89}}</tool_call>"),
         "the full set refused a well-formed calculator call");
      --  A call missing required arguments is refused -- which only the
      --  tight grammar does; the loose one would take it.
      Assert
        (not Full_Set_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47}}</tool_call>"),
         "the full set took a calculator call missing arguments "
         & "(it fell back to the loose grammar)");
   end Full_Set_Is_Tight;

   --  Whether the grammar compiled from the whole built-in set in a tag
   --  syntax accepts a text whole.
   function Full_Set_Takes_In
     (Syntax : Tools.Call_Syntax; Text : String) return Boolean
   is
      Defs   : Tools.Definitions;
      Rules  : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Held   : Boolean;
   begin
      Tools.Read (Defs, Builtin.All_Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the full definitions would not read");
      Constraint.Compile_Call_Grammar (Defs, Rules, Status, Syntax => Syntax);
      Assert (E.Is_Ok (Status) and then G.Is_Ready (Rules),
              "the full-set call grammar would not compile in the tag "
              & "syntax: " & E.Error_Code'Image (Status.Code));
      G.Start (Rules, State, Status);
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
   end Full_Set_Takes_In;

   --  The two tag syntaxes are shaped by the grammar as the envelope is:
   --  a call in the Qwen3-Coder form or the MiniCPM form names a tool on
   --  offer and gives each parameter in its own tag, with the tool's
   --  schema saying what goes in it. A reasoning block ahead of the reply
   --  is admitted, since those families write one. What the grammar
   --  refuses is what a 0.8B model wrote unconstrained -- <parameter/op>
   --  -- and a call missing a required parameter; and the JSON envelope is
   --  not a call in either tag syntax.
   procedure Tag_Syntaxes_Are_Shaped
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := ASCII.LF;
      Qwen_Call : constant String :=
        "<think>" & LF & LF & "</think>" & LF & LF
        & "<tool_call>" & LF & "<function=calculator>" & LF
        & "<parameter=a>" & LF & "47" & LF & "</parameter>" & LF
        & "<parameter=op>" & LF & "+" & LF & "</parameter>" & LF
        & "<parameter=b>" & LF & "89" & LF & "</parameter>" & LF
        & "</function>" & LF & "</tool_call>";
      Qwen_Typo : constant String :=
        "<tool_call>" & LF & "<function=calculator>" & LF
        & "<parameter=a>" & LF & "47" & LF & "</parameter>" & LF
        & "<parameter=b>" & LF & "89" & LF & "</parameter>" & LF
        & "<parameter/op>" & LF & "+" & LF & "</parameter>" & LF
        & "</function>" & LF & "</tool_call>";
      Qwen_Short : constant String :=
        "<tool_call>" & LF & "<function=calculator>" & LF
        & "<parameter=a>" & LF & "47" & LF & "</parameter>" & LF
        & "</function>" & LF & "</tool_call>";
      Func_Call : constant String :=
        "Let me add those." & LF
        & "<function name=""calculator""><param name=""a"">47</param>"
        & "<param name=""op"">+</param><param name=""b"">89</param>"
        & "</function>";
      Func_Bad_Op : constant String :=
        "<function name=""calculator""><param name=""a"">47</param>"
        & "<param name=""op"">plus</param><param name=""b"">89</param>"
        & "</function>";
      Envelope : constant String :=
        "<tool_call>{""name"": ""calculator"", ""arguments"": "
        & "{""a"":47,""op"":""+"",""b"":89}}</tool_call>";
   begin
      Assert (Full_Set_Takes_In (Tools.Qwen_XML, Qwen_Call),
              "a well-formed Qwen call behind a think block was refused");
      Assert (not Full_Set_Takes_In (Tools.Qwen_XML, Qwen_Typo),
              "<parameter/op> was taken as a parameter");
      Assert (not Full_Set_Takes_In (Tools.Qwen_XML, Qwen_Short),
              "a Qwen call missing required parameters was taken");
      --  Code compares with '<': in a value, and in the prose before a
      --  call, it is text -- where it used to end the value, and an edit
      --  with it was cut short mid-line.
      Assert (Full_Set_Takes_In
                (Tools.Qwen_XML,
                 "When A + B < Integer'First it saturates." & LF
                 & "<tool_call>" & LF & "<function=write_file>" & LF
                 & "<parameter=path>" & LF & "calc.adb" & LF & "</parameter>" & LF
                 & "<parameter=content>" & LF & "if A < B then" & LF & "   null;" & LF & "end if;" & LF
                 & "</parameter>" & LF & "</function>" & LF & "</tool_call>"),
              "a '<' in prose or in a value was not taken as text");
      --  A reply begun inside a think block the prompt opened -- Qwen3.5's
      --  generation prompt ends "<think>" -- closes it before its call.
      Assert (Full_Set_Takes_In
                (Tools.Qwen_XML,
                 "I should read the file first, since A < B matters." & LF & "</think>" & LF & LF
                 & "<tool_call>" & LF & "<function=read_file>" & LF
                 & "<parameter=path>" & LF & "calc.adb" & LF & "</parameter>" & LF
                 & "</function>" & LF & "</tool_call>"),
              "a reply closing the think block its prompt opened was refused");
      Assert (Model_Runner.Agent.Answer_Of ("reasoning" & LF & "</think>" & LF & LF & "The sum.") = "The sum."
              and then Model_Runner.Agent.Answer_Of ("The sum.") = "The sum.",
              "an answer was not what follows its reasoning");
      Assert (not Full_Set_Takes_In (Tools.Qwen_XML, Envelope),
              "the JSON envelope was taken as a Qwen call");
      Assert (Full_Set_Takes_In (Tools.Qwen_XML, "Just an answer."),
              "prose was refused in the Qwen syntax");

      Assert (Full_Set_Takes_In (Tools.Function_XML, Func_Call),
              "a well-formed MiniCPM call after prose was refused");
      Assert (not Full_Set_Takes_In (Tools.Function_XML, Func_Bad_Op),
              "an op outside the calculator's enum was taken");
      Assert (not Full_Set_Takes_In (Tools.Function_XML, Envelope),
              "the JSON envelope was taken as a MiniCPM call");
   end Tag_Syntaxes_Are_Shaped;

   --  Functionary's recipient form is shaped as the tag syntaxes are. A reply
   --  is a run of ">>>"-parted blocks: "all" and free text is what the model
   --  said, a tool name and its arguments object is a call, and the two may
   --  stand in one reply -- spoken text, then a call. A call missing a
   --  required argument is refused, and the JSON envelope is not a call here.
   procedure Recipient_Is_Shaped
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF     : constant Character := ASCII.LF;
      Spoken : constant String := "all" & LF & "Just an answer.";
      Call   : constant String :=
        "calculator" & LF & "{""a"":47,""op"":""+"",""b"":89}";
      Spoken_Then_Call : constant String :=
        "all" & LF & "Let me compute that." & ">>>"
        & "calculator" & LF & "{""a"":47,""op"":""+"",""b"":89}";
      Short    : constant String := "calculator" & LF & "{""a"":47}";
      Envelope : constant String :=
        "<tool_call>{""name"": ""calculator"", ""arguments"": "
        & "{""a"":47,""op"":""+"",""b"":89}}</tool_call>";
   begin
      Assert (Full_Set_Takes_In (Tools.Recipient_JSON, Spoken),
              "the recipient form refused a spoken 'all' reply");
      Assert (Full_Set_Takes_In (Tools.Recipient_JSON, Call),
              "the recipient form refused a well-formed call");
      Assert (Full_Set_Takes_In (Tools.Recipient_JSON, Spoken_Then_Call),
              "the recipient form refused spoken text followed by a call");
      Assert (not Full_Set_Takes_In (Tools.Recipient_JSON, Short),
              "a recipient call missing required arguments was taken");
      Assert (not Full_Set_Takes_In (Tools.Recipient_JSON, Envelope),
              "the JSON envelope was taken as a recipient call");
   end Recipient_Is_Shaped;

   --  A Functionary recipient reply keeps its spoken words apart from its
   --  calls. Spoken_Span answers the ">>>all" block's body -- not the raw
   --  blocks -- so a mixed reply round-trips as words beside its calls, a
   --  pure call carries none, and the tag and JSON forms keep their prefix.
   procedure Recipient_Spoken_Splits
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := ASCII.LF;

      function Span
        (Reply : String; Syntax : Tools.Call_Syntax) return String
      is
         First, Last : Natural;
      begin
         Tools.Spoken_Span (Reply, Syntax, First, Last);
         return Reply (First .. Last);
      end Span;
   begin
      --  Spoken text and then a call: the words alone.
      Assert
        (Span ("all" & LF & "Let me check." & LF & ">>>get_weather" & LF
               & "{""city"":""Paris""}", Tools.Recipient_JSON)
         = "Let me check.",
         "the recipient spoken span did not isolate the words before a call");

      --  A pure call: no words.
      Assert
        (Span ("get_weather" & LF & "{""city"":""Paris""}",
               Tools.Recipient_JSON) = "",
         "a recipient pure call carried words it did not say");

      --  Spoken only: all of it.
      Assert
        (Span ("all" & LF & "Just an answer.", Tools.Recipient_JSON)
         = "Just an answer.",
         "a spoken-only recipient reply lost its words");

      --  The JSON form is unchanged: the prose before the envelope.
      Assert
        (Span ("Here you go.<tool_call>{""name"":""x"",""arguments"":{}}"
               & "</tool_call>", Tools.Tool_Call_JSON) = "Here you go.",
         "the JSON form's spoken prefix changed");
   end Recipient_Spoken_Splits;

   --  A delegator wired in runs the delegate tool's subtask; an inquirer
   --  wired in answers ask_user; an embedder wired in is what retrieve
   --  ranks with. Each is given as a stub that records what it was handed
   --  and answers something the tool's reply must carry, so the test sees
   --  the wiring reach the tool and the tool reach back through it -- and
   --  each unwired again declines as it did before, so a runner handed a
   --  null is the runner it started as.
   type Counting_Delegator is limited new Builtin.Delegator with record
      Calls : Natural := 0;

      --  How its sub-agent ends, and what it was handed to run within.
      Ending  : Builtin.Sub_State := Builtin.Completed;
      Handed  : Model_Runner.Tools.Runner.Tool_Context;
   end record;

   overriding procedure Run_Sub
     (Self        : in out Counting_Delegator;
      Instruction : String;
      Context     : Model_Runner.Tools.Runner.Tool_Context;
      Result      : out String;
      Last        : out Natural;
      Ended       : out Builtin.Sub_Outcome;
      Status      : out E.Error_Info);

   overriding function Parallel_Delegates
     (Self : Counting_Delegator) return Boolean is (False);

   overriding procedure Run_Sub
     (Self        : in out Counting_Delegator;
      Instruction : String;
      Context     : Model_Runner.Tools.Runner.Tool_Context;
      Result      : out String;
      Last        : out Natural;
      Ended       : out Builtin.Sub_Outcome;
      Status      : out E.Error_Info)
   is
      Reply : constant String := "sub-agent did: " & Instruction;
   begin
      Self.Calls := Self.Calls + 1;
      Self.Handed := Context;
      Ended := (State  => Self.Ending,
                Reason => Ada.Strings.Unbounded.To_Unbounded_String
                            (if Builtin."=" (Self.Ending, Builtin.Exhausted) then "step limit" else "answered"),
                Steps  => 3, Calls => 2, Tokens => 40, others => <>);
      Last := Result'First + Natural'Min (Reply'Length, Result'Length) - 1;
      Result (Result'First .. Last) :=
        Reply (Reply'First .. Reply'First + Last - Result'First);
      Status := E.Success;
   end Run_Sub;

   type Fixed_Inquirer is limited new Builtin.Inquirer with record
      Asked : Natural := 0;
   end record;

   overriding procedure Ask
     (Self     : in out Fixed_Inquirer;
      Question : String;
      Answer   : out String;
      Last     : out Natural;
      Status   : out E.Error_Info);

   overriding procedure Ask
     (Self     : in out Fixed_Inquirer;
      Question : String;
      Answer   : out String;
      Last     : out Natural;
      Status   : out E.Error_Info)
   is
      Reply : constant String := "the second one, to " & Question;
   begin
      Self.Asked := Self.Asked + 1;
      Last := Natural'Min (Reply'Length, Answer'Length);
      Answer (Answer'First .. Answer'First + Last - 1) :=
        Reply (Reply'First .. Reply'First + Last - 1);
      Status := E.Success;
   end Ask;

   --  An embedder that puts a text on one of two axes by a word in it, so
   --  that a passage about the moon and a query about the moon lie
   --  together and everything else lies apart.
   type Axis_Embedder is limited new Builtin.Embedder with record
      Embedded : Natural := 0;
   end record;

   overriding procedure Embed
     (Self   : in out Axis_Embedder;
      Text   : String;
      Vector : out Model_Runner.Numerics.Real_Array;
      Last   : out Natural;
      Status : out E.Error_Info);

   overriding procedure Embed
     (Self   : in out Axis_Embedder;
      Text   : String;
      Vector : out Model_Runner.Numerics.Real_Array;
      Last   : out Natural;
      Status : out E.Error_Info)
   is
      Lunar : Boolean := False;
   begin
      Self.Embedded := Self.Embedded + 1;
      for I in Text'First .. Text'Last - 3 loop
         if Text (I .. I + 3) = "moon" then
            Lunar := True;
         end if;
      end loop;
      Vector := [others => 0.0];
      if Lunar then
         Vector (Vector'First) := 1.0;
      else
         Vector (Vector'First + 1) := 1.0;
      end if;
      Last := 1;
      Status := E.Success;
   end Embed;

   procedure Wired_Helpers_Reach_Their_Tools
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Runner    : Builtin.Instance;
      Delegator : aliased Counting_Delegator;
      Inquirer  : aliased Fixed_Inquirer;
      Embedder  : aliased Axis_Embedder;
      Room      : String (1 .. Tools.Max_Call_Bytes);
      Last      : Natural;
      Status    : E.Error_Info;
      Dir       : constant String := "obj/wired_case";

      function Has (Whole, Part : String) return Boolean is
      begin
         if Part'Length = 0 or else Whole'Length < Part'Length then
            return False;
         end if;
         for P in Whole'First .. Whole'Last - Part'Length + 1 loop
            if Whole (P .. P + Part'Length - 1) = Part then
               return True;
            end if;
         end loop;
         return False;
      end Has;

      procedure Write_File (Name, Text : String) is
         F : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Dir & "/" & Name);
         Ada.Text_IO.Put_Line (F, Text);
         Ada.Text_IO.Close (F);
      end Write_File;
   begin
      Runner.Use_Delegator (Delegator'Unchecked_Access);
      Runner.Run ("delegate", "{""task"":""count the stars""}", Room, Last,
                  Status);
      Assert (E.Is_Ok (Status), "delegate through a delegator failed");
      Assert (Has (Room (1 .. Last), "sub-agent did: count the stars"),
              "the delegator's answer did not come back: " & Room (1 .. Last));
      Assert (Delegator.Calls = 1, "the delegator was not run once");

      Runner.Use_Inquirer (Inquirer'Unchecked_Access);
      Runner.Run ("ask_user", "{""question"":""which one?""}", Room, Last,
                  Status);
      Assert (E.Is_Ok (Status), "ask_user through an inquirer failed");
      Assert (Has (Room (1 .. Last), "the second one, to which one?"),
              "the inquirer's answer did not come back: " & Room (1 .. Last));
      Assert (Inquirer.Asked = 1, "the inquirer was not asked once");

      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      Write_File ("a.txt", "the tides follow the moon across the bay");
      Write_File ("b.txt", "a ledger of grain sold at the autumn market");

      Runner.Use_Embedder (Embedder'Unchecked_Access);
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""where is the moon""}",
         Room, Last, Status);
      Assert (E.Is_Ok (Status), "retrieve through an embedder failed");
      Assert (Embedder.Embedded >= 3,
              "the embedder was not asked for the query and each passage:"
              & Natural'Image (Embedder.Embedded));
      Assert (Has (Room (1 .. Last), "tides follow the moon"),
              "retrieve did not rank the passage the embedder put beside "
              & "the query first: " & Room (1 .. Last));

      --  Unwired again, each declines as a runner given nothing does.
      Runner.Use_Delegator (null);
      Runner.Use_Inquirer (null);
      Runner.Use_Embedder (null);
      Runner.Run ("delegate", "{""task"":""again""}", Room, Last, Status);
      Assert (Room (1 .. 5) = "error", "delegate did not decline unwired");
      Runner.Run ("ask_user", "{""question"":""again?""}", Room, Last,
                  Status);
      Assert (Room (1 .. 5) = "error", "ask_user did not decline unwired");
      Assert (Delegator.Calls = 1 and then Inquirer.Asked = 1,
              "an unwired helper was still reached");

      Ada.Directories.Delete_Tree (Dir);
   end Wired_Helpers_Reach_Their_Tools;

   --  A child's run is held to how it ended: only an answer is a result,
   --  and what it spent is its parent's. A tool is offered only where the
   --  runner can carry it out, and a call runs within the run's limits --
   --  a process stopped at the run's cancellation and its deadline, not
   --  waited out. And each stop says what it asks of whoever acts on it.
   procedure Calls_Run_Within_The_Run
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Tr renames Model_Runner.Tools.Runner;
      package Ag renames Model_Runner.Agent;
      use type Tr.Answer_Kind;
      use type Ada.Real_Time.Time;
      use type Ada.Real_Time.Time_Span;
      Runner    : Builtin.Instance;
      Delegator : aliased Counting_Delegator;
      Inquirer  : aliased Fixed_Inquirer;
      Room      : String (1 .. Tools.Max_Call_Bytes);
      Last      : Natural;
      Ended     : Tr.Call_Outcome;
      Status    : E.Error_Info;

      function Offers (Text, Named : String) return Boolean is
        (Ada.Strings.Fixed.Index (Text, """" & Named & """") > 0);
   begin
      --  Offered what it can run, and nothing it would decline.
      Assert (not Offers (Runner.Offered_Text, "delegate")
              and then not Offers (Runner.Offered_Text, "ask_user")
              and then Offers (Runner.Offered_Text, "read_file"),
              "an unwired runner offered a tool it declines, or not one it runs");
      Runner.Use_Delegator (Delegator'Unchecked_Access);
      Runner.Use_Inquirer (Inquirer'Unchecked_Access);
      Assert (Offers (Runner.Offered_Text, "delegate") and then Offers (Runner.Offered_Text, "ask_user"),
              "a wired runner did not offer what it was wired for");

      --  A child that ran out of steps did not do the task, whatever it
      --  said on the way; what it generated is the caller's spent.
      Delegator.Ending := Builtin.Exhausted;
      Runner.Set_Context ((Cancel => null, Deadline => Ada.Real_Time.Time_Last, Tokens_Left => 100, Depth => 0));
      Runner.Run ("delegate", "{""task"":""count the stars""}", Room, Last, Ended, Status);
      Assert (Ended.Answer = Tr.Failed and then Ended.Tokens = 40
              and then Ada.Strings.Fixed.Index (Room (1 .. Last), "stopped before answering: step limit") > 0,
              "a child that ran out of steps was taken for an answer: " & Room (1 .. Last));
      Assert (Delegator.Handed.Tokens_Left = 100,
              "the child was not handed what its parent had left");
      Delegator.Ending := Builtin.Completed;
      Runner.Run ("delegate", "{""task"":""count the stars""}", Room, Last, Ended, Status);
      Assert (Ended.Answer = Tr.Answered and then Ended.Tokens = 40
              and then Ada.Strings.Fixed.Index (Room (1 .. Last), "sub-agent did: count the stars") > 0,
              "a child that answered was not its answer");

      --  A process stops at the run's cancellation, and at its deadline.
      declare
         Stop  : aliased Model_Runner.Cancellation.Token;
         Began : Ada.Real_Time.Time;
      begin
         Stop.Request;
         Runner.Set_Context ((Cancel => Stop'Unchecked_Access, others => <>));
         Runner.Run ("shell", "{""command"":""sleep 5""}", Room, Last, Ended, Status);
         Assert (Ended.Answer = Tr.Cancelled,
                 "a program run for a cancelled run was not stopped as cancelled: " & Room (1 .. Last));

         Began := Ada.Real_Time.Clock;
         Runner.Set_Context
           ((Cancel => null, Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Milliseconds (500), others => <>));
         Runner.Run ("shell", "{""command"":""sleep 5""}", Room, Last, Ended, Status);
         Assert (Ended.Answer = Tr.Timed_Out
                 and then Ada.Real_Time.Clock - Began < Ada.Real_Time.Seconds (4),
                 "a program outlasting the run's deadline was waited out: " & Room (1 .. Last));
      end;
      Runner.Set_Context (Tr.No_Context);

      --  What each stop asks.
      Assert (Ag.Traits_Of (Ag.Answered).Finished
              and then Ag.Traits_Of (Ag.Step_Limit).Exhausted
              and then Ag.Traits_Of (Ag.Timed_Out).Exhausted
              and then Ag.Traits_Of (Ag.Generation_Failed).Retryable
              and then Ag.Traits_Of (Ag.Repeating).Needs_Change
              and then Ag.Traits_Of (Ag.Cancelled).Needs_User
              and then not Ag.Traits_Of (Ag.Repeating).Exhausted,
              "a stop did not say what it asks");
      Assert (Ag.Reason_Words (Ag.Step_Limit) = "step limit", "a stop was not said in words");
   end Calls_Run_Within_The_Run;

   --  A file is changed in part, and only as it was read: an exact passage
   --  in one place, refused where it is not there, there twice, or where
   --  the file changed since the revision the edit names; and said with
   --  where and in what. Part of a file is read by its lines, a file and a
   --  tree are searched, and a file too large to read whole is said to be.
   procedure Files_Are_Edited_In_Part
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Ed renames Model_Runner.Tools.Editing;
      Dir  : constant String := "obj/editing_case";
      Path : constant String := Dir & "/calc.adb";
      Body_Text : constant String :=
        "package body Calc is" & ASCII.LF
        & "   function Add (A, B : Integer) return Integer is" & ASCII.LF
        & "   begin" & ASCII.LF
        & "      return A + B;" & ASCII.LF
        & "   end Add;" & ASCII.LF
        & "   function Twice (A : Integer) return Integer is (A + A);" & ASCII.LF
        & "end Calc;" & ASCII.LF;

      function Has (Item : Ed.Said; Part : String) return Boolean is
        (Ada.Strings.Fixed.Index (Ada.Strings.Unbounded.To_String (Item.Text), Part) > 0);

      procedure Put (Name, Text : String) is
         F : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Name);
         Ada.Text_IO.Put (F, Text);
         Ada.Text_IO.Close (F);
      end Put;
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      Put (Path, Body_Text);

      declare
         Read  : constant String := Ed.Revision_Of (Path);
         Done  : constant Ed.Said := Ed.Edit (Path, "return A + B;", "return B + A;", Read);
      begin
         Assert (Read'Length = 16 and then not Done.Failed and then Done.Changed
                 and then Has (Done, "line 4") and then Has (Done, "in Add"),
                 "an edit of one passage was not made, or not said where: "
                 & Ada.Strings.Unbounded.To_String (Done.Text));
         --  The file has moved on from what was read: refused, untouched.
         declare
            Late : constant Ed.Said := Ed.Edit (Path, "return B + A;", "return 0;", Read);
         begin
            Assert (Late.Failed and then Has (Late, "changed since you read it")
                    and then Ed.Revision_Of (Path) /= Read,
                    "an edit of a file changed since it was read was made");
         end;
      end;
      Assert (Ed.Edit (Path, "return A - B;", "x", "").Failed
              and then Has (Ed.Edit (Path, "return A - B;", "x", ""), "is not in"),
              "an edit of a passage not there was made");
      Assert (Ed.Edit (Path, "Integer", "Natural", "").Failed
              and then Has (Ed.Edit (Path, "Integer", "Natural", ""), "times"),
              "an edit of a passage there more than once was made");

      --  Lines by number, and searches.
      Assert (Has (Ed.Read_Range (Path, 2, 3), "2:    function Add")
              and then Has (Ed.Read_Range (Path, 2, 3), "3:    begin")
              and then not Has (Ed.Read_Range (Path, 2, 3), "A + B"),
              "a range of lines was not those lines");
      Assert (Has (Ed.Search_File (Path, "Twice"), "6: ")
              and then Has (Ed.Search_File (Path, "nowhere"), "no line"),
              "a search of a file did not give the lines that hold it");
      Assert (Has (Ed.Search_Code (Dir, "Twice"), "calc.adb:6:"),
              "a search of a tree did not give path and line");

      --  Too large to read whole, and not text: said, not read.
      declare
         Huge : constant String := Dir & "/huge.log";
         F    : Ada.Text_IO.File_Type;
         Line : constant String (1 .. 1023) := [others => 'x'];
         Text : Ada.Strings.Unbounded.Unbounded_String;
         Got  : E.Error_Info;
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Huge);
         for Index in 1 .. Ed.Text_Most / 1024 + 1 loop
            Ada.Text_IO.Put_Line (F, Line);
         end loop;
         Ada.Text_IO.Close (F);
         Ed.Read_Text (Huge, Text, Got);
         Assert (E."=" (Got.Code, E.IO_File_Too_Large),
                 "a file past the bound was read whole");
         Put (Dir & "/blob.bin", "ab" & ASCII.NUL & "cd");
         Ed.Read_Text (Dir & "/blob.bin", Text, Got);
         Assert (E."=" (Got.Code, E.IO_Read_Failed), "a binary file was read as text");
      end;

      --  Not there as given, but there line for line with the spaces at the
      --  lines' ends left out, and in one place: edited there, the new text
      --  moved to the file's indentation and said so. In two places, not.
      declare
         Loose_Path : constant String := Dir & "/loose.adb";
      begin
         Put (Loose_Path,
              "procedure P is" & ASCII.LF & "begin" & ASCII.LF & "   X := 1;" & ASCII.LF
              & "   Y := 2;" & ASCII.LF & "end P;" & ASCII.LF);
         declare
            Before : Ada.Strings.Unbounded.Unbounded_String;
            Text   : Ada.Strings.Unbounded.Unbounded_String;
            Got    : E.Error_Info;
         begin
            Ed.Read_Text (Loose_Path, Before, Got);
            declare
               --  The file's own line ending -- CRLF where the host writes
               --  text so -- on the lines put in.
               Was  : constant String := Ada.Strings.Unbounded.To_String (Before);
               At_X : constant Natural := Ada.Strings.Fixed.Index (Was, "   X := 1;");
               At_Y : constant Natural := Ada.Strings.Fixed.Index (Was, "   Y := 2;");
               Ends : constant String :=
                 (if Was (At_X + 10) = ASCII.CR then ASCII.CR & ASCII.LF else [1 => ASCII.LF]);
               Want : constant String :=
                 Was (Was'First .. At_X - 1) & "   X := 3;" & Ends & "   Y := 4;"
                 & Was (At_Y + 10 .. Was'Last);
               Done : constant Ed.Said :=
                 Ed.Edit (Loose_Path, "    X := 1;" & ASCII.LF & "    Y := 2;",
                          "    X := 3;" & ASCII.LF & "    Y := 4;", "");
            begin
               Ed.Read_Text (Loose_Path, Text, Got);
               Assert (not Done.Failed and then Has (Done, "matched with the spaces")
                       and then Ada.Strings.Unbounded.To_String (Text) = Want,
                       "a passage there but for its lines' indentation was not edited in the file's: "
                       & Ada.Strings.Unbounded.To_String (Done.Text) & " -> "
                       & Ada.Strings.Unbounded.To_String (Text));
            end;
         end;
         Put (Loose_Path, "   A := 1;" & ASCII.LF & "   A := 1;" & ASCII.LF);
         declare
            Twice : constant Ed.Said := Ed.Edit (Loose_Path, "    A := 1;", "    A := 2;", "");
         begin
            --  Said to be there twice, and where -- not "not there".
            Assert (Twice.Failed and then Has (Twice, "2 times, at lines 1, 2"),
                    "a passage there loosely in two places was edited in one, or not said to be in two: "
                    & Ada.Strings.Unbounded.To_String (Twice.Text));
         end;
      end;
      --  New lines for a passage that starts after a line's indentation:
      --  set at that indentation, each kept where it stood from the first,
      --  whether the first was given with no indentation or its own; lines
      --  given already standing there are put in as given.
      declare
         Laid_Path : constant String := Dir & "/laid.adb";

         --  The file, its line ends read as LF: a host may write CRLF.
         function Now return String is
            Text : Ada.Strings.Unbounded.Unbounded_String;
            Got  : E.Error_Info;
            Kept : Ada.Strings.Unbounded.Unbounded_String;
         begin
            Ed.Read_Text (Laid_Path, Text, Got);
            for C of Ada.Strings.Unbounded.To_String (Text) loop
               if C /= ASCII.CR then
                  Ada.Strings.Unbounded.Append (Kept, C);
               end if;
            end loop;
            return Ada.Strings.Unbounded.To_String (Kept);
         end Now;

         procedure Try (New_Text, Want, Why : String) is
            Done : Ed.Said;
         begin
            Put (Laid_Path, "begin" & ASCII.LF & "   return A + B;" & ASCII.LF & "end P;" & ASCII.LF);
            Done := Ed.Edit (Laid_Path, "return A + B;", New_Text, "");
            Assert (not Done.Failed
                    --  Put ends the file with a line break of its own.
                    and then Ada.Strings.Fixed.Index
                               (Now, "begin" & ASCII.LF & Want & ASCII.LF & "end P;" & ASCII.LF) = 1,
                    Why & ": " & Ada.Strings.Unbounded.To_String (Done.Text) & " -> " & Now);
         end Try;

         Laid : constant String :=
           "   if X then" & ASCII.LF & "      return 1;" & ASCII.LF & "   end if;";
      begin
         Try ("if X then" & ASCII.LF & "   return 1;" & ASCII.LF & "end if;", Laid,
              "new lines given from the margin were not set at the line's indentation");
         Try ("   if X then" & ASCII.LF & "      return 1;" & ASCII.LF & "   end if;", Laid,
              "new lines given with an indentation of their own went in at twice it");
         Try ("return A + B;" & ASCII.LF & "   null;", "   return A + B;" & ASCII.LF & "   null;",
              "new lines given already standing at the line's indentation were moved");
      end;
      --  There twice, exactly or loosely: edited where it starts within
      --  the lines last read, where only one place does; refused without.
      declare
         Twice_Path : constant String := Dir & "/twice.adb";
         Text       : Ada.Strings.Unbounded.Unbounded_String;
         Got        : E.Error_Info;
      begin
         Put (Twice_Path, "   A := 1;" & ASCII.LF & "   B := 2;" & ASCII.LF & "   A := 1;" & ASCII.LF);
         declare
            Exact : constant Ed.Said := Ed.Edit (Twice_Path, "A := 1;", "A := 3;", "", "", 2, 3);
         begin
            Ed.Read_Text (Twice_Path, Text, Got);
            Assert (not Exact.Failed and then Has (Exact, "within the lines you last read")
                    and then Ada.Strings.Fixed.Index (Ada.Strings.Unbounded.To_String (Text), "A := 1;") > 0
                    and then Ada.Strings.Fixed.Index (Ada.Strings.Unbounded.To_String (Text), "A := 3;")
                             > Ada.Strings.Fixed.Index (Ada.Strings.Unbounded.To_String (Text), "B := 2;"),
                    "a passage there twice was not edited where the lines last read hold it: "
                    & Ada.Strings.Unbounded.To_String (Exact.Text));
         end;
         Put (Twice_Path, "   A := 1;" & ASCII.LF & "   B := 2;" & ASCII.LF & "   A := 1;" & ASCII.LF);
         declare
            Loose : constant Ed.Said := Ed.Edit (Twice_Path, "    A := 1;", "    A := 3;", "", "", 1, 2);
         begin
            Ed.Read_Text (Twice_Path, Text, Got);
            Assert (not Loose.Failed and then Has (Loose, "within the lines you last read")
                    and then Ada.Strings.Fixed.Index (Ada.Strings.Unbounded.To_String (Text), "A := 3;")
                             < Ada.Strings.Fixed.Index (Ada.Strings.Unbounded.To_String (Text), "B := 2;"),
                    "a passage there twice loosely was not edited where the lines last read hold it: "
                    & Ada.Strings.Unbounded.To_String (Loose.Text));
         end;
         Put (Twice_Path, "   A := 1;" & ASCII.LF & "   B := 2;" & ASCII.LF & "   A := 1;" & ASCII.LF);
         Assert (Ed.Edit (Twice_Path, "A := 1;", "A := 4;", "").Failed
                 and then Ed.Edit (Twice_Path, "A := 1;", "A := 4;", "", "", 1, 3).Failed,
                 "a passage there twice was edited with no lines read, or lines holding both, to tell which");
      end;
      Ada.Directories.Delete_Tree (Dir);
   end Files_Are_Edited_In_Part;

   --  One runtime, configured two ways: what a run's agent and a project's
   --  are offered comes from one registry by their capabilities, and a call
   --  is let through by the same; a helper is asked by one contract and its
   --  outputs checked by one check; a program's failure is said with its
   --  exit status and what it wrote to its standard error.
   procedure One_Runtime_For_Every_Agent
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Rg renames Model_Runner.Tools.Registry;
      package Rt renames Model_Runner.Agent_Runtime;
      package Pr renames Model_Runner.Processes;
      use type Model_Runner.Tools.Runner.Call_Kind;

      function Has (Text, Part : String) return Boolean is (Ada.Strings.Fixed.Index (Text, Part) > 0);

      Reading : constant Rg.Capabilities := [Rg.Read_Files => True, others => False];
      Working : constant Rg.Capabilities :=
        [Rg.Read_Files | Rg.Write_Files | Rg.Project_Graph | Rg.Project_Checks => True, others => False];
   begin
      --  Offered by capability: reading alone is offered read_file,
      --  list_directory and find -- find by text only, with no graph -- and
      --  nothing that writes; a project's agent is offered the graph's
      --  kinds, the checks, and the writes.
      Assert (Has (Rg.Offered (Reading), """read_file""") and then Has (Rg.Offered (Reading), """find""")
              and then not Has (Rg.Offered (Reading), """edit_file""")
              and then not Has (Rg.Offered (Reading), """references""")
              and then not Has (Rg.Offered (Reading), """read_range"""),
              "a reading agent was offered what it cannot do, or a tool find took over");
      Assert (Has (Rg.Offered (Working), """references""") and then Has (Rg.Offered (Working), """run_checks""")
              and then Has (Rg.Offered (Working), """edit_file""")
              and then not Has (Rg.Offered (Working), """delegate"""),
              "a project's agent was not offered the graph, the checks and the writes, or was offered a helper");
      --  Let through by the same: a known tool whose capability it has,
      --  and a tool find took over still runs by name.
      Assert (Rg.Allows (Reading, "read_file") and then Rg.Allows (Reading, "search_code")
              and then not Rg.Allows (Reading, "write_file") and then not Rg.Allows (Working, "shell")
              and then not Rg.Allows (Working, "no_such_tool"),
              "a call was let through against the capabilities that chose the offer");
      Assert (Rg.Kind_Of ("find") = Model_Runner.Tools.Runner.Reads
              and then Rg.Kind_Of ("edit_file") = Model_Runner.Tools.Runner.Changes
              and then Rg.Kind_Of ("now") = Model_Runner.Tools.Runner.Varies,
              "a tool's kind was not the registry's");

      --  One contract: the brief says each part as what it is, and the
      --  outputs are checked by what they hold.
      declare
         Found   : Boolean;
         Asked   : constant Rt.Contract :=
           Rt.Contract_Of ("{""task"": ""write the notes"", ""outputs"": [""obj/rt_a.txt"", ""obj/rt_b.txt""],"
                           & " ""inputs"": [""docs/my notes.md""], ""acceptance"": ""both exist""}", Found);
         Outputs : constant Rt.Paths.Vector := Asked.Outputs;
         Before  : Rt.Paths.Vector;
         F       : Ada.Text_IO.File_Type;
      begin
         Assert (Found and then Has (Rt.Brief (Asked), "write the notes")
                 and then Has (Rt.Brief (Asked), "Write: obj/rt_a.txt")
                 and then Has (Rt.Brief (Asked), "Done when: both exist")
                 and then Natural (Outputs.Length) = 2
                 and then Has (Rt.Brief (Asked), "Start from: docs/my notes.md")
                 and then Ada.Strings.Unbounded.Length (Asked.Refusal) = 0,
                 "a helper's contract was not briefed as what it is: " & Rt.Brief (Asked));
         if Ada.Directories.Exists ("obj/rt_a.txt") then
            Ada.Directories.Delete_File ("obj/rt_a.txt");
         end if;
         if Ada.Directories.Exists ("obj/rt_b.txt") then
            Ada.Directories.Delete_File ("obj/rt_b.txt");
         end if;
         Before := Rt.Prints (Outputs);
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, "obj/rt_a.txt");
         Ada.Text_IO.Put_Line (F, "written");
         Ada.Text_IO.Close (F);
         Assert (Rt.Unwritten (Outputs, Before) = "obj/rt_b.txt",
                 "an output not written was not named, or a written one was: " & Rt.Unwritten (Outputs, Before));
         Ada.Directories.Delete_File ("obj/rt_a.txt");
         --  A list argument is read as the list it is, and one written as
         --  a string is not taken for one.
         declare
            Items       : Model_Runner.Tools.Schemas.Choice_Lists.Vector;
            Given       : Boolean;
            Well_Formed : Boolean;
         begin
            Builtin.Text_List_Argument
              ("{""outputs"": [""a b.txt"", ""src/c.adb""]}", "outputs", Items, Given, Well_Formed);
            Assert (Given and then Well_Formed and then Natural (Items.Length) = 2
                    and then Items (1) = "a b.txt" and then Items (2) = "src/c.adb",
                    "a list of strings was not read as it is");
            Builtin.Text_List_Argument ("{""outputs"": ""a.txt""}", "outputs", Items, Given, Well_Formed);
            Assert (Given and then not Well_Formed and then Items.Is_Empty,
                    "a string was taken for a list");
            Builtin.Text_List_Argument ("{""task"": ""t""}", "outputs", Items, Given, Well_Formed);
            Assert (not Given and then Well_Formed, "a list not given was said to be there");
         end;

         --  Outputs written as words are no list of paths: refused, not
         --  read for what might be one.
         declare
            Worded : constant Rt.Contract :=
              Rt.Contract_Of ("{""task"": ""t"", ""outputs"": ""write src/foo.adb; then docs/a.md""}", Found);
         begin
            Assert (Worded.Outputs.Is_Empty
                    and then Has (Ada.Strings.Unbounded.To_String (Worded.Refusal), "outputs is a list of file paths"),
                    "outputs written as words were read for paths, or not refused");
         end;
         Assert (Has (Rt.Helper_Rules, "status: done") and then Has (Rt.Helper_Opening ("reviewer"), "as its reviewer"),
                 "a helper was not told how to work and report");
      end;

      --  A program's failure, said with what the model needs to put it
      --  right; its success as it printed it; a long run stopped.
      declare
         Asked : Pr.Request;
         Ran   : Pr.Result;
      begin
         Asked.Program := Ada.Strings.Unbounded.To_Unbounded_String ("sh");
         Asked.Arguments.Append (Ada.Strings.Unbounded.To_Unbounded_String ("-c"));
         Asked.Arguments.Append
           (Ada.Strings.Unbounded.To_Unbounded_String ("echo out; echo 'calc.adb:4: bad' >&2; exit 3"));
         Ran := Pr.Run (Asked);
         Assert (Ran.Started and then Ran.Exit_Status = 3 and then not Pr.Succeeded (Ran)
                 and then Has (Pr.Told (Ran, "the tool command"), "exit status 3")
                 and then Has (Pr.Told (Ran, "the tool command"), "stderr:")
                 and then Has (Pr.Told (Ran, "the tool command"), "calc.adb:4: bad"),
                 "a failing program's exit status and standard error were not said: " & Pr.Told (Ran, "it"));
         Asked.Arguments.Replace_Element (2, Ada.Strings.Unbounded.To_Unbounded_String ("echo fine"));
         Ran := Pr.Run (Asked);
         Assert (Pr.Succeeded (Ran) and then Has (Pr.Told (Ran, "it"), "fine")
                 and then not Has (Pr.Told (Ran, "it"), "error"),
                 "a program that succeeded was not said as its output");
         Asked.Arguments.Replace_Element (2, Ada.Strings.Unbounded.To_Unbounded_String ("sleep 5"));
         Asked.Limit := 0.3;
         Ran := Pr.Run (Asked);
         Assert (Ran.Started and then Ran.Stopped, "a program past its limit was not stopped");
         Asked.Program := Ada.Strings.Unbounded.To_Unbounded_String ("no-such-program-anywhere");
         Ran := Pr.Run (Asked);
         Assert (not Ran.Started and then Has (Pr.Told (Ran, "it"), "could not be run"),
                 "a program not there was not said to be");
      end;

      --  find, here with no project: text in a file and in a tree; what
      --  asks a graph is said to need one.
      declare
         Runner : Builtin.Instance;
         Room   : String (1 .. Tools.Max_Call_Bytes);
         Last   : Natural;
         Status : E.Error_Info;
      begin
         Runner.Run ("find", "{""kind"": ""text"", ""query"": ""package Model_Runner.Tools.Registry"","
                     & " ""path"": ""../src/library""}", Room, Last, Status);
         Assert (Has (Room (1 .. Last), "model_runner-tools-registry.ads:"),
                 "find text did not find a line in a tree: " & Room (1 .. Natural'Min (Last, 300)));
         Runner.Run ("find", "{""kind"": ""symbol"", ""query"": ""Run""}", Room, Last, Status);
         Assert (Has (Room (1 .. Last), "error:") and then Has (Room (1 .. Last), "graph"),
                 "find symbol with no project did not say it needs one");
      end;
   end One_Runtime_For_Every_Agent;

   --  Every project command's line is read into a request by one reader,
   --  and the request written back reads as the same request.
   procedure Command_Lines_Read_Back
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Pc renames Model_Runner.CLI.Project_Commands;
      package Cl renames Model_Runner.CLI.Command_Lines;
      use type Cl.Request;
      type Line_Ref is access constant String;
      Lines : constant array (1 .. 9) of Line_Ref :=
        [new String'("/work TASK-017 profile=review"),
         new String'("/task new Count the stars kind=analysis notes=for the night sky"),
         new String'("/accept TASK-008,TASK-009"),
         new String'("/task note TASK-003 remember the ""quoted"" bit and a=b"),
         new String'("/reconfigure scalar.agents.max_steps=12 confirm=yes"),
         new String'("/req new ""Stars counted"" text=the stars are counted"),
         new String'("/config diff 3 5"),
         new String'("/why 7"),
         new String'("/history")];
   begin
      for Line of Lines loop
         declare
            Asked : constant Cl.Request := Pc.Request_Of (Line.all);
            Again : constant Cl.Request := Pc.Request_Of (Cl.Canonical (Asked));
         begin
            Assert (Again = Asked and then Cl.Canonical (Again) = Cl.Canonical (Asked),
                    "a command's line did not read back as the same request: " & Line.all
                    & " -> " & Cl.Canonical (Asked));
         end;
      end loop;
      --  And what the reader makes of a list and of a value that runs on.
      Assert (Natural (Pc.Request_Of ("/accept TASK-008,TASK-009").Positional.Length) = 2
              and then Pc.Request_Of ("/task new X notes=for the sky").Settings.First_Element
                       = "notes=for the sky",
              "a list was not split at its commas, or a value did not run on");
      --  A quoted value ends at its quote: a word after it is a word.
      declare
         Asked : constant Cl.Request := Pc.Request_Of ("/task new X notes=""for the sky"" extra");
      begin
         Assert (Asked.Settings.First_Element = "notes=for the sky"
                 and then Asked.Positional.Contains ("extra"),
                 "a quoted value took the word after its quote: " & Cl.Canonical (Asked));
      end;
   end Command_Lines_Read_Back;

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
         Assert (Tools.Count (All_Defs) = 22,
                 "the full set is not twenty-two tools");
         Assert (Tools.Offers (All_Defs, "shell"), "shell is not offered");
         Assert (Tools.Offers (All_Defs, "http_get"),
                 "http_get is not offered");
         Assert (Tools.Offers (All_Defs, "memory_put"),
                 "memory_put is not offered");
         Assert (Tools.Offers (All_Defs, "retrieve"),
                 "retrieve is not offered");
         Assert (Tools.Offers (All_Defs, "delegate"),
                 "delegate is not offered");
         Assert (Tools.Offers (All_Defs, "ask_user"),
                 "ask_user is not offered");

         --  The grammar compiles over the full set (the tight form, which
         --  the rule bound is now wide enough to hold -- see Full_Set_Is_Tight).
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

   --  With no delegator wired -- the state of a runner given none, and of a
   --  sub-agent's own runner -- delegate declines in words the model reads,
   --  rather than crashing or recursing, so the loop goes on.
   procedure Delegate_Declines_Undelegated
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Reply : constant String := Answer ("delegate", "{""task"":""do it""}");
   begin
      Assert (Reply'Length >= 5 and then Reply (Reply'First .. Reply'First + 4)
              = "error",
              "delegate with no delegator did not decline as an error");
   end Delegate_Declines_Undelegated;

   --  With no inquirer wired -- the state of a runner given none, as an eval
   --  or a sub-agent is -- ask_user declines rather than blocking on input no
   --  one will give, so the loop goes on.
   procedure Ask_User_Declines_Unwired
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Reply : constant String :=
        Answer ("ask_user", "{""question"":""which one?""}");
   begin
      Assert (Reply'Length >= 5 and then Reply (Reply'First .. Reply'First + 4)
              = "error",
              "ask_user with no inquirer did not decline as an error");
   end Ask_User_Declines_Unwired;

   --  A note written with a memory file behind it is there for a later run:
   --  a fresh runner pointed at the same file reads it back, value and all,
   --  a space in the value included (the store is length-prefixed, so no byte
   --  of a value is a delimiter).
   procedure Memory_Persists_To_A_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Dir    : constant String := "obj/memory_case";
      Store  : constant String := Dir & "/notes.mem";
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);

      --  One runner writes a note; the file now holds it.
      declare
         Writer : Builtin.Instance;
      begin
         Writer.Use_Memory_File (Store, Status);
         Assert (E.Is_Ok (Status), "a memory file not there yet was refused");
         Writer.Run
           ("memory_put", "{""key"":""greeting"",""value"":""hello world""}",
            Room, Last, Status);
         Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "ok",
                 "memory_put did not accept the note");
      end;

      --  A fresh runner, as a later run would be, reads it back.
      declare
         Reader : Builtin.Instance;
      begin
         Reader.Use_Memory_File (Store, Status);
         Reader.Run ("memory_get", "{""key"":""greeting""}",
                     Room, Last, Status);
         Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "hello world",
                 "memory_get did not read the persisted note back whole");
      end;

      Ada.Directories.Delete_Tree (Dir);
   end Memory_Persists_To_A_File;

   --  A store file that will not parse is said, leaves the runner with no
   --  notes and raises nothing: a sound record followed by a damaged one keeps
   --  neither, a length longer than any number is refused, and one that
   --  reaches the largest number is refused rather than added to a position
   --  past it.
   procedure Damaged_Memory_File_Leaves_No_Notes
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Dir    : constant String := "obj/memory_damaged";
      Store  : constant String := Dir & "/notes.mem";
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;

      procedure Write (Content : String) is
         use Ada.Streams;
         F     : Stream_IO.File_Type;
         Block : Stream_Element_Array
           (1 .. Stream_Element_Offset (Content'Length));
      begin
         for I in Content'Range loop
            Block (Stream_Element_Offset (I - Content'First + 1)) :=
              Stream_Element (Character'Pos (Content (I)));
         end loop;
         Stream_IO.Create (F, Stream_IO.Out_File, Store);
         Stream_IO.Write (F, Block);
         Stream_IO.Close (F);
      end Write;

      --  What a fresh runner reading the store says for the key -- and, where
      --  the store would not read, that it said so: "refused".
      function Recalled (Key : String) return String is
         Reader : Builtin.Instance;
         Opened : E.Error_Info;
      begin
         Reader.Use_Memory_File (Store, Opened);
         Reader.Run ("memory_get", "{""key"":""" & Key & """}",
                     Room, Last, Status);
         return (if E.Is_Error (Opened)
                   and then Room (1 .. Last) = "error: nothing remembered under that key"
                 then "refused"
                 elsif E.Is_Error (Opened) then "refused, yet held notes"
                 else Room (1 .. Last));
      end Recalled;

   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);

      Write ("1 a1 b");
      Assert (Recalled ("a") = "b", "a sound store was not read");

      --  Damaged: said, and nothing of it taken -- not an empty store.
      Write ("1 a1 b" & "3 cd");
      Assert (Recalled ("a") = "refused",
              "a store damaged after its first record kept that record, or was not said damaged");

      Write ("99999999999999999999999 a1 b");
      Assert (Recalled ("a") = "refused",
              "a length past any number was read as one, or not said");

      Write ("1 a" & Natural'Image (Natural'Last) (2 .. 11) & " b");
      Assert (Recalled ("a") = "refused",
              "a value length reaching the largest number was read, or not said");

      --  A note the file cannot take is said, not answered ok.
      declare
         Blocked : Builtin.Instance;
         Opened  : E.Error_Info;
      begin
         Write ("1 a1 b");
         Blocked.Use_Memory_File (Store & "/inner.mem", Opened);
         Blocked.Run ("memory_put", "{""key"":""k"",""value"":""v""}", Room, Last, Status);
         Assert (Ada.Strings.Fixed.Index (Room (1 .. Last), "was not kept for a later one") > 0,
                 "a note the memory file could not take was answered ok: " & Room (1 .. Last));
      end;

      Ada.Directories.Delete_Tree (Dir);
   end Damaged_Memory_File_Leaves_No_Notes;

   --  A result too big for the call buffer keeps its head and its tail, with
   --  the middle dropped and its size noted, rather than losing everything
   --  past the head. read_file over an oversized file shows it: the file's
   --  first bytes and last bytes both come back, inside the buffer.
   procedure Large_Result_Keeps_Head_And_Tail
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Dir    : constant String := "obj/cap_case";
      Path   : constant String := Dir & "/big.txt";
      Filler : constant String (1 .. 50_000) := [others => 'x'];
      Big    : constant String := "HEAD-MARKER-START" & Filler & "TAIL-MARKER-END";
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      --  Write the bytes exactly, so no trailing newline creeps onto the
      --  tail and the test can check the file's true last bytes.
      declare
         use Ada.Streams;
         F     : Stream_IO.File_Type;
         Block : Stream_Element_Array (1 .. Stream_Element_Offset (Big'Length));
      begin
         for I in Big'Range loop
            Block (Stream_Element_Offset (I - Big'First + 1)) :=
              Stream_Element (Character'Pos (Big (I)));
         end loop;
         Stream_IO.Create (F, Stream_IO.Out_File, Path);
         Stream_IO.Write (F, Block);
         Stream_IO.Close (F);
      end;

      declare
         Runner : Builtin.Instance;
      begin
         Runner.Run ("read_file", "{""path"":""" & Path & """}",
                     Room, Last, Status);
      end;
      Assert (E.Is_Ok (Status), "read_file would not answer");

      declare
         --  The file as read, and its revision on the line after it.
         Whole  : constant String := Room (1 .. Last);
         Break  : constant Natural := Ada.Strings.Fixed.Index (Whole, [1 => ASCII.LF], Ada.Strings.Backward);
         Result : constant String := (if Break = 0 then Whole else Whole (Whole'First .. Break - 1));
      begin
         Assert (Break > 0 and then Ada.Strings.Fixed.Index (Whole (Break .. Whole'Last), "(revision ") > 0,
                 "a whole read did not end with the file's revision");
         Assert (Result'Length <= Tools.Max_Call_Bytes,
                 "the kept result does not fit the call buffer");
         Assert (Result'Length < Big'Length,
                 "an oversized result was not cut down at all");
         Assert (Result'Length >= 17
                 and then Result (Result'First .. Result'First + 16)
                   = "HEAD-MARKER-START",
                 "the head of the oversized result was lost");
         Assert (Result'Length >= 15
                 and then Result (Result'Last - 14 .. Result'Last)
                   = "TAIL-MARKER-END",
                 "the tail of the oversized result was lost");
      end;

      Ada.Directories.Delete_Tree (Dir);
   end Large_Result_Keeps_Head_And_Tail;

   --  The runner marks the tools that may overlap and the tools that may not:
   --  reads and network fetches and lexical retrieve overlap; a shared
   --  scratchpad, a waited-on process, a single session or the console do not.
   procedure Parallel_Safety_Is_Marked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Runner : Builtin.Instance;
   begin
      Assert (Runner.Parallel_Safe ("http_get"),
              "http_get should be parallel-safe");
      Assert (Runner.Parallel_Safe ("web_search"),
              "web_search should be parallel-safe");
      Assert (Runner.Parallel_Safe ("read_file"),
              "read_file should be parallel-safe");
      Assert (Runner.Parallel_Safe ("calculator"),
              "calculator should be parallel-safe");
      Assert (Runner.Parallel_Safe ("retrieve"),
              "lexical retrieve (no embedder) should be parallel-safe");
      Assert (not Runner.Parallel_Safe ("shell"),
              "shell must not be parallel-safe (it waits on a process)");
      Assert (not Runner.Parallel_Safe ("run_python"),
              "run_python must not be parallel-safe");
      Assert (not Runner.Parallel_Safe ("sql"),
              "sql must not be parallel-safe");
      Assert (not Runner.Parallel_Safe ("memory_put"),
              "memory_put must not be parallel-safe (shared scratchpad)");
      Assert (not Runner.Parallel_Safe ("write_file"),
              "write_file must not be parallel-safe");
      Assert (not Runner.Parallel_Safe ("delegate"),
              "delegate must not be parallel-safe (one sub-session)");
      Assert (not Runner.Parallel_Safe ("ask_user"),
              "ask_user must not be parallel-safe (one console)");
   end Parallel_Safety_Is_Marked;

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

   --  retrieve ranks a folder's passages against a query: the file that
   --  carries the query's words comes back first, and a query whose words
   --  are nowhere finds nothing. Deterministic, so it is scored here rather
   --  than left to a model.
   procedure Retrieve_Ranks_The_Folder
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Dir    : constant String := "obj/retrieve_case";
      Runner : Builtin.Instance;
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
      LF     : constant Character := ASCII.LF;

      --  A minimal PDF: a header, one uncompressed content stream showing a
      --  line of text, and a trailer. Enough for the extractor to find the
      --  stream, see the text block, and read the shown string.
      PDF    : constant String :=
        "%PDF-1.4" & LF
        & "1 0 obj" & LF
        & "<< /Length 51 >>" & LF
        & "stream" & LF
        & "BT /F1 12 Tf (neptune tides fill the document) Tj ET" & LF
        & "endstream" & LF
        & "endobj" & LF
        & "%%EOF" & LF;

      procedure Write_File (Name, Text : String) is
         F : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Dir & "/" & Name);
         Ada.Text_IO.Put_Line (F, Text);
         Ada.Text_IO.Close (F);
      end Write_File;

      --  Write exact bytes, for a file that carries binary (a compressed
      --  PDF stream) a line writer would mangle.
      procedure Write_Bytes (Name, Content : String) is
         use Ada.Streams;
         F   : Stream_IO.File_Type;
         Buf : Stream_Element_Array (1 .. Content'Length);
      begin
         for I in Content'Range loop
            Buf (Stream_Element_Offset (I - Content'First + 1)) :=
              Stream_Element (Character'Pos (Content (I)));
         end loop;
         Stream_IO.Create (F, Stream_IO.Out_File, Dir & "/" & Name);
         Stream_IO.Write (F, Buf);
         Stream_IO.Close (F);
      end Write_Bytes;

      --  A PDF whose content stream is FlateDecode-compressed, built by
      --  deflating the stream here so the extractor's inflate path is tried.
      function Compressed_PDF return String is
         use Zlib;
         Content : constant String :=
           "BT /F1 12 Tf (kraken lurks in the compressed deep) Tj ET";
         Raw     : Byte_Array (0 .. Content'Length - 1);
         Status  : Status_Code;
      begin
         for I in Raw'Range loop
            Raw (I) := Byte (Character'Pos (Content (Content'First + I)));
         end loop;
         declare
            Comp : constant Byte_Array := Deflate_Stored (Raw, Status);
            Bytes : String (1 .. Comp'Length);
         begin
            for I in Comp'Range loop
               Bytes (Bytes'First + (I - Comp'First)) :=
                 Character'Val (Integer (Comp (I)));
            end loop;
            return "%PDF-1.4" & LF
              & "1 0 obj" & LF
              & "<< /Filter /FlateDecode >>" & LF
              & "stream" & LF
              & Bytes & LF
              & "endstream" & LF
              & "endobj" & LF
              & "%%EOF" & LF;
         end;
      end Compressed_PDF;

      --  Little-endian fields for a hand-built ZIP.
      function LE16 (V : Natural) return String
      is (Character'Val (V mod 256) & Character'Val (V / 256 mod 256));
      function LE32 (V : Natural) return String
      is (LE16 (V mod 65536) & LE16 (V / 65536));

      --  A one-entry ZIP holding Entry_Name with Xml, deflate-compressed --
      --  the shape a .docx or .pptx has. CRC is left zero; the extractor
      --  reads the sizes and the data, not the checksum.
      function Zip_One (Entry_Name, Xml : String) return String is
         use Zlib;
         In_B   : Byte_Array (0 .. Xml'Length - 1);
         Status : Status_Code;
      begin
         for I in In_B'Range loop
            In_B (I) := Byte (Character'Pos (Xml (Xml'First + I)));
         end loop;
         declare
            Comp_B : constant Byte_Array :=
              Deflate_Raw (In_B, Status => Status);
            Comp   : String (1 .. Comp_B'Length);
            Nm     : constant Natural := Entry_Name'Length;
         begin
            for I in Comp_B'Range loop
               Comp (Comp'First + (I - Comp_B'First)) :=
                 Character'Val (Integer (Comp_B (I)));
            end loop;
            declare
               Local : constant String :=
                 "PK" & Character'Val (3) & Character'Val (4)
                 & LE16 (20) & LE16 (0) & LE16 (8) & LE16 (0) & LE16 (0)
                 & LE32 (0) & LE32 (Comp'Length) & LE32 (Xml'Length)
                 & LE16 (Nm) & LE16 (0) & Entry_Name & Comp;
               Central : constant String :=
                 "PK" & Character'Val (1) & Character'Val (2)
                 & LE16 (20) & LE16 (20) & LE16 (0) & LE16 (8) & LE16 (0)
                 & LE16 (0) & LE32 (0) & LE32 (Comp'Length) & LE32 (Xml'Length)
                 & LE16 (Nm) & LE16 (0) & LE16 (0) & LE16 (0) & LE16 (0)
                 & LE32 (0) & LE32 (0) & Entry_Name;
            begin
               return Local & Central
                 & "PK" & Character'Val (5) & Character'Val (6)
                 & LE16 (0) & LE16 (0) & LE16 (1) & LE16 (1)
                 & LE32 (Central'Length) & LE32 (Local'Length) & LE16 (0);
            end;
         end;
      end Zip_One;

      function Begins (Hay, Head : String) return Boolean
      is (Hay'Length >= Head'Length
          and then Hay (Hay'First .. Hay'First + Head'Length - 1) = Head);

      --  Each character followed by a zero byte -- UTF-16LE, as a .doc keeps
      --  Unicode text.
      function Utf16 (S : String) return String is
         R : String (1 .. S'Length * 2);
      begin
         for I in S'Range loop
            R (2 * (I - S'First) + 1) := S (I);
            R (2 * (I - S'First) + 2) := ASCII.NUL;
         end loop;
         return R;
      end Utf16;

      --  A legacy .doc: the OLE2 magic, then a single-byte run and a
      --  UTF-16LE run, the way real ones carry their text.
      Ole    : constant String :=
        Character'Val (16#D0#) & Character'Val (16#CF#)
        & Character'Val (16#11#) & Character'Val (16#E0#)
        & Character'Val (16#A1#) & Character'Val (16#B1#)
        & Character'Val (16#1A#) & Character'Val (16#E1#);
      Doc    : constant String :=
        Ole & ASCII.NUL & ASCII.NUL
        & "walrus legacy manuscript"
        & ASCII.NUL & ASCII.NUL
        & Utf16 ("moonlight equinox verse")
        & ASCII.NUL & ASCII.NUL;

      --  A legacy .xls: OLE2, like the .doc, with a run of cell text.
      Xls    : constant String :=
        Ole & ASCII.NUL & ASCII.NUL
        & "xlsledger quarterly figures"
        & ASCII.NUL & ASCII.NUL;

      --  An RTF document: a font table to skip, then the body text.
      Rtf    : constant String :=
        "{\rtf1\ansi {\fonttbl{\f0\froman Times;}} "
        & "\b0 salmontrout lighthouse manuscript\par }";

      --  An HTML page: tags around the text.
      Html   : constant String :=
        "<html><head><title>t</title></head><body>"
        & "<h1>peregrine beacon heading</h1>"
        & "<p>and some more prose</p></body></html>";
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      Write_File ("cats.txt", "Cats are small carnivorous mammals that purr.");
      Write_File
        ("dogs.txt",
         "Dogs are loyal domestic animals that bark and guard the home.");
      Write_File ("space.txt", "A planet orbits a star within a galaxy.");
      --  A file in a subdirectory, to prove the walk descends into it.
      Ada.Directories.Create_Path (Dir & "/notes");
      Write_File
        ("notes/ocean.txt",
         "The ocean is a vast body of saltwater covering most of the earth.");
      --  A binary file: a NUL byte among words found nowhere else. It must
      --  be skipped, so a query for those words finds nothing.
      Write_File
        ("blob.bin", "xyzzy" & Character'Val (0) & "hidden treasure trove");
      --  A PDF, whose text lives in a content stream, not in the source.
      Write_File ("paper.pdf", PDF);
      --  A PDF whose stream is compressed, to exercise the inflate path.
      Write_Bytes ("deep.pdf", Compressed_PDF);
      --  A .docx: a ZIP whose word/document.xml holds the text.
      Write_Bytes
        ("report.docx",
         Zip_One
           ("word/document.xml",
            "<w:document><w:body><w:p><w:r><w:t>kingfisher docx "
            & "paragraph</w:t></w:r></w:p></w:body></w:document>"));
      --  A legacy .doc, OLE2 with single-byte and UTF-16LE text runs.
      Write_Bytes ("old.doc", Doc);
      --  A legacy .xls (OLE2), an .rtf, and an .html.
      Write_Bytes ("book.xls", Xls);
      Write_File ("note.rtf", Rtf);
      Write_File ("page.html", Html);
      --  A file with a byte that is not valid UTF-8 (Latin-1 e-acute) among
      --  ASCII words -- what a PDF or a cut window can produce.
      Write_Bytes
        ("latin.txt",
         "kestrel" & Character'Val (16#E9#) & " headland manuscript");

      --  A query whose words are in the dogs file: it ranks first.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""loyal domestic guard "
         & "dogs""}",
         Room, Last, Status);
      Assert (E.Is_Ok (Status), "retrieve did not answer");
      Assert (Begins (Room (1 .. Last), "[dogs.txt]"),
              "retrieve did not rank the dogs passage first: "
              & Room (1 .. Last));

      --  A query whose words are in the nested file: retrieve descended into
      --  the subdirectory and labelled the passage with its path.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""vast saltwater ocean""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[notes/ocean.txt]"),
              "retrieve did not find the passage in the subdirectory: "
              & Room (1 .. Last));

      --  A query for words that live only inside the PDF's content stream:
      --  the extractor pulled them out of the compressed-format file, so the
      --  passage comes back labelled with the .pdf.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""neptune tides document""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[paper.pdf]"),
              "retrieve did not extract text from the PDF: "
              & Room (1 .. Last));

      --  Words that live only inside the compressed PDF's stream: the
      --  extractor inflated it and read them out.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""kraken compressed deep""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[deep.pdf]"),
              "retrieve did not inflate and extract the compressed PDF: "
              & Room (1 .. Last));

      --  Words that live only inside the .docx's XML part: the ZIP was read,
      --  the part inflated, and the tags stripped to the text.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""kingfisher docx""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[report.docx]"),
              "retrieve did not extract text from the .docx: "
              & Room (1 .. Last));

      --  The legacy .doc's single-byte run.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""walrus legacy manuscript""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[old.doc]"),
              "retrieve did not read the legacy .doc's text: "
              & Room (1 .. Last));

      --  And its UTF-16LE run.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""moonlight equinox verse""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[old.doc]"),
              "retrieve did not read the .doc's UTF-16 text: "
              & Room (1 .. Last));

      --  The legacy .xls (OLE2), read the same way as the .doc.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""xlsledger quarterly""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[book.xls]"),
              "retrieve did not read the legacy .xls: " & Room (1 .. Last));

      --  The RTF's body text, its font table skipped.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""salmontrout lighthouse""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[note.rtf]"),
              "retrieve did not read the .rtf's text: " & Room (1 .. Last));

      --  The HTML page's text, its tags stripped.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""peregrine beacon""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[page.html]"),
              "retrieve did not strip the .html tags: " & Room (1 .. Last));

      --  A passage with an invalid byte is found by its ASCII words, and
      --  what comes back is valid UTF-8 -- the byte scrubbed to a space, so
      --  the embedder and the model it is handed to both accept it.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""kestrel headland""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[latin.txt]"),
              "retrieve did not find the Latin-1 file: " & Room (1 .. Last));
      Assert (Model_Runner.UTF8.Is_Valid (Room (1 .. Last)),
              "retrieve returned bytes that are not valid UTF-8");

      --  The binary file's words are searched for: it was skipped, so
      --  nothing matches even though the bytes are there.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""xyzzy hidden treasure""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "no passage"),
              "retrieve searched a binary file it should have skipped: "
              & Room (1 .. Last));

      --  A query whose words are in no file: nothing matches.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""xylophone zebra""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "no passage"),
              "retrieve found a match for words in no file: "
              & Room (1 .. Last));

      Ada.Directories.Delete_Tree (Dir);
   end Retrieve_Ranks_The_Folder;

   --  MiniCPM writes a call as a <function> element with a <param> per
   --  argument, not a <tool_call> JSON object. Read in that syntax, a call
   --  comes out the same shape as any other: a name and its arguments as one
   --  JSON object, each param value a JSON string, a CDATA wrapper removed.
   procedure Function_XML_Calls_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Asked  : Tools.Calls;
      Status : E.Error_Info;
   begin
      --  One call, three params; the values become JSON strings.
      Tools.Read_Calls
        (Asked,
         "<function name=""calculator"">"
         & "<param name=""a"">47</param>"
         & "<param name=""op"">*</param>"
         & "<param name=""b"">89</param></function>",
         Status, Syntax => Tools.Function_XML);
      Assert (E.Is_Ok (Status), "the function-form call would not read");
      Assert (Tools.Count (Asked) = 1, "not one call");
      Assert (Tools.Called (Asked, 1) = "calculator",
              "wrong name: " & Tools.Called (Asked, 1));
      --  A numeric param value becomes a JSON number, so a typed tool gets a
      --  number; a non-numeric one (the op) stays a string.
      Assert (Tools.Arguments (Asked, 1)
              = "{""a"": 47, ""op"": ""*"", ""b"": 89}",
              "wrong arguments: " & Tools.Arguments (Asked, 1));
      Tools.Close (Asked);

      --  Two calls, and a CDATA value with a newline becomes an escaped
      --  JSON string.
      Tools.Read_Calls
        (Asked,
         "<function name=""first""><param name=""x"">1</param></function>"
         & "<function name=""note""><param name=""body"">"
         & "<![CDATA[a" & ASCII.LF & "b]]></param></function>",
         Status, Syntax => Tools.Function_XML);
      Assert (E.Is_Ok (Status), "the two function-form calls would not read");
      Assert (Tools.Count (Asked) = 2, "not two calls");
      Assert (Tools.Called (Asked, 2) = "note", "wrong second name");
      Assert (Tools.Arguments (Asked, 2) = "{""body"": ""a\nb""}",
              "CDATA value not read as an escaped JSON string: "
              & Tools.Arguments (Asked, 2));
      Tools.Close (Asked);

      --  The function form read as the JSON form finds nothing, and that is
      --  not an error: the syntaxes do not collide.
      Tools.Read_Calls
        (Asked, "<function name=""x""></function>", Status,
         Syntax => Tools.Tool_Call_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 0,
              "the function form was mistaken for a tool_call");
      Tools.Close (Asked);
   end Function_XML_Calls_Parse;

   --  Recipient_JSON reads Functionary's form: blocks parted by ">>>", each a
   --  recipient and a body across a line break. "all" is what the model said;
   --  any other name is a call whose body is its arguments object.
   procedure Recipient_JSON_Calls_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Asked  : Tools.Calls;
      Status : E.Error_Info;
   begin
      --  The model spoke, then called two functions. The reply begins at the
      --  first recipient -- the generation prompt's own ">>>" primed it -- and
      --  the rest carry their own.
      Tools.Read_Calls
        (Asked,
         "all" & ASCII.LF & "Let me check both." & ASCII.LF
         & ">>>get_weather" & ASCII.LF & "{""city"": ""Hanoi""}"
         & ">>>get_time" & ASCII.LF & "{""tz"": ""Asia/Bangkok""}",
         Status, Syntax => Tools.Recipient_JSON);
      Assert (E.Is_Ok (Status), "the recipient-form calls would not read");
      Assert (Tools.Count (Asked) = 2,
              "not two calls:" & Tools.Count (Asked)'Image);
      Assert (Tools.Called (Asked, 1) = "get_weather",
              "wrong first name: " & Tools.Called (Asked, 1));
      Assert (Tools.Arguments (Asked, 1) = "{""city"": ""Hanoi""}",
              "wrong first args: " & Tools.Arguments (Asked, 1));
      Assert (Tools.Called (Asked, 2) = "get_time", "wrong second name");
      Tools.Close (Asked);

      --  A reply that only spoke calls nothing, and is not an error.
      Tools.Read_Calls
        (Asked, "all" & ASCII.LF & "The weather is fine.",
         Status, Syntax => Tools.Recipient_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 0,
              "a spoken-only reply named a call");
      Tools.Close (Asked);

      --  A lone call, the reply beginning at the function name, no arguments.
      Tools.Read_Calls
        (Asked, "now" & ASCII.LF & "{}",
         Status, Syntax => Tools.Recipient_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1
              and then Tools.Called (Asked, 1) = "now",
              "a lone call did not read");
      Tools.Close (Asked);
   end Recipient_JSON_Calls_Parse;

   --  Python_Code reads Gemma's form: calls written as Python in a
   --  ```tool_code block, keyword arguments read as a JSON object -- a
   --  string in any of Python's quotes, True, None, a list -- with a
   --  print(..) around a call and a module before its name taken off. A
   --  "```" inside a string is the string's, not the end of the block. A
   --  positional argument names nothing and is refused; a reply with no
   --  block is read as open JSON.
   procedure Python_Code_Calls_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF     : constant Character := ASCII.LF;
      Asked  : Tools.Calls;
      Status : E.Error_Info;
   begin
      Tools.Read_Calls
        (Asked,
         "I will add them." & LF & "```tool_code" & LF
         & "calculator(a=47, op='+', b=89.)" & LF
         & "print(api.lookup(words=[""x"", 'y\'s'], exact=True, "
         & "near=None,))" & LF & "```",
         Status, Syntax => Tools.Python_Code);
      Assert (E.Is_Ok (Status), "the Python calls would not read");
      Assert (Tools.Count (Asked) = 2,
              "not two calls:" & Tools.Count (Asked)'Image);
      Assert (Tools.Called (Asked, 1) = "calculator",
              "wrong first name: " & Tools.Called (Asked, 1));
      Assert (Tools.Arguments (Asked, 1)
              = "{""a"": 47, ""op"": ""+"", ""b"": 89.0}",
              "wrong first args: " & Tools.Arguments (Asked, 1));
      Assert (Tools.Called (Asked, 2) = "lookup",
              "wrong second name: " & Tools.Called (Asked, 2));
      Assert (Tools.Arguments (Asked, 2)
              = "{""words"": [""x"", ""y's""], ""exact"": true, "
                & """near"": null}",
              "wrong second args: " & Tools.Arguments (Asked, 2));
      Tools.Close (Asked);

      --  Text across lines in triple quotes, a fence inside it.
      Tools.Read_Calls
        (Asked,
         "```tool_code" & LF & "write_file(path=""a.md"", content="""""""
         & "one" & LF & "```ada" & LF & "two" & LF & "```"""""")" & LF
         & "```",
         Status, Syntax => Tools.Python_Code);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1,
              "a triple-quoted string holding a fence did not read");
      Assert (Tools.Arguments (Asked, 1)
              = "{""path"": ""a.md"", ""content"": "
                & """one\n```ada\ntwo\n```""}",
              "wrong triple-quoted args: " & Tools.Arguments (Asked, 1));
      Tools.Close (Asked);

      Tools.Read_Calls
        (Asked, "```tool_code" & LF & "calculator(47, op=""+"")" & LF & "```",
         Status, Syntax => Tools.Python_Code);
      Assert (E.Is_Error (Status)
              and then E."=" (Status.Code, E.Tools_Call_Malformed),
              "a positional argument was read as a call");
      Tools.Close (Asked);

      --  A raw tab or line break inside a string of a model's call is the
      --  escape it stands for, not a call dropped as no JSON.
      Tools.Read_Calls
        (Asked, "<tool_call>{""name"": ""edit_file"", ""arguments"": {""old_text"": """ & ASCII.HT
                & "X := 1;" & LF & "Y"", ""new_text"": ""Z""}}</tool_call>", Status);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1
              and then Ada.Strings.Fixed.Index (Tools.Arguments (Asked, 1), "\tX := 1;\nY") > 0,
              "a call with a raw tab in a string was not read: "
              & (if Tools.Count (Asked) = 1 then Tools.Arguments (Asked, 1) else E.Error_Code'Image (Status.Code)));
      Tools.Close (Asked);

      --  Given the tools offered, an argument in its place is the
      --  parameter the definition names there; one after a keyword is not.
      declare
         Defs : aliased Tools.Definitions;
      begin
         Tools.Read (Defs, Builtin.All_Definitions_Text, Status);
         Tools.Read_Calls
           (Asked, "```tool_code" & LF & "calculator(47, ""+"", b=89)" & LF & "```",
            Status, Syntax => Tools.Python_Code, Offered => Defs'Access);
         Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1
                 and then Tools.Arguments (Asked, 1) = "{""a"": 47, ""op"": ""+"", ""b"": 89}",
                 "arguments in their places were not named by the definition: "
                 & (if Tools.Count (Asked) = 1 then Tools.Arguments (Asked, 1) else "none"));
         Tools.Close (Asked);
         Tools.Read_Calls
           (Asked, "```tool_code" & LF & "calculator(a=47, ""+"")" & LF & "```",
            Status, Syntax => Tools.Python_Code, Offered => Defs'Access);
         Assert (E.Is_Error (Status), "an argument in its place after a keyword was read");
         Tools.Close (Asked);
         --  A list a Qwen writes in a tag is the list its schema says it
         --  is, where the tools offered are known; text that looks like
         --  JSON where the schema says text stays text.
         declare
            Offered_Defs : aliased Tools.Definitions;
         begin
            Tools.Read
              (Offered_Defs,
               "[{""type"": ""function"", ""function"": {""name"": ""delegate"", ""description"": ""d"","
               & " ""parameters"": {""type"": ""object"", ""properties"": {""task"": {""type"": ""string""},"
               & " ""outputs"": {""type"": ""array"", ""items"": {""type"": ""string""}}}}}}]",
               Status);
            Tools.Read_Calls
              (Asked, "<tool_call>" & LF & "<function=delegate>" & LF & "<parameter=task>" & LF
               & "[not a list]" & LF & "</parameter>" & LF & "<parameter=outputs>" & LF
               & "[""docs/calc.md""]" & LF & "</parameter>" & LF & "</function>" & LF & "</tool_call>",
               Status, Syntax => Tools.Qwen_XML, Offered => Offered_Defs'Access);
            Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1
                    and then Tools.Arguments (Asked, 1)
                             = "{""task"": ""[not a list]"", ""outputs"": [""docs/calc.md""]}",
                    "a list in a tag was not read as its schema says: "
                    & (if Tools.Count (Asked) = 1 then Tools.Arguments (Asked, 1) else "none"));
            Tools.Close (Asked);
            Assert (Model_Runner.Tools.Python_Calls.Parameter_Type (Tools.Definition (Offered_Defs, 1), "outputs")
                    = "array"
                    and then Model_Runner.Tools.Python_Calls.Parameter_Type
                               (Tools.Definition (Offered_Defs, 1), "task") = "string"
                    and then Model_Runner.Tools.Python_Calls.Parameter_Type
                               (Tools.Definition (Offered_Defs, 1), "none") = "",
                    "a parameter's type was not the one its definition gives");
            Tools.Close (Offered_Defs);
         end;
         Assert (Model_Runner.Tools.Python_Calls.Parameter_At
                   ("{""function"": {""name"": ""f"", ""parameters"": {""type"": ""object"", ""properties"": "
                    & "{""x"": {""type"": ""object"", ""properties"": {""in"": {}}}, ""y"": {}}}}}", 2) = "y",
                 "a definition's second parameter was not the one it names second");
         Tools.Close (Defs);
      end;

      Tools.Read_Calls
        (Asked, "{""name"": ""now"", ""arguments"": {}}",
         Status, Syntax => Tools.Python_Code);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1
              and then Tools.Called (Asked, 1) = "now",
              "the open JSON was not read where no block was written");
      Tools.Close (Asked);

      Tools.Read_Calls
        (Asked, "Here is code:" & LF & "```ada" & LF & "X := 1;" & LF & "```",
         Status, Syntax => Tools.Python_Code);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 0,
              "a fence of code in an answer was read as a call");
      Tools.Close (Asked);
   end Python_Code_Calls_Parse;

   --  Gemma's form is shaped by the grammar: prose that may show code in
   --  fences of its own, then calls in ```tool_code blocks naming a tool on
   --  offer, each argument as its schema says. A call missing a required
   --  argument, a choice off the schema's list, or a name not offered is
   --  refused; so is the JSON envelope.
   procedure Python_Calls_Are_Shaped
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := ASCII.LF;
      Call : constant String :=
        "Adding." & LF & "```tool_code" & LF
        & "calculator(a=47, op=""+"", b=89)" & LF & "```";
   begin
      Assert (Full_Set_Takes_In (Tools.Python_Code, Call),
              "a well-formed Python call was refused");
      Assert (Full_Set_Takes_In
                (Tools.Python_Code,
                 "Like this:" & LF & "```ada" & LF & "X := 1;" & LF & "```"
                 & LF & "and `Y`." & LF & LF & Call),
              "code fenced in prose was refused ahead of a call");
      Assert (Full_Set_Takes_In (Tools.Python_Code, "Just an answer, `X`."),
              "an answer ending on a backtick was refused");
      Assert (not Full_Set_Takes_In
                (Tools.Python_Code,
                 "```tool_code" & LF & "calculator(a=47, b=89)" & LF & "```"),
              "a call missing a required argument was taken");
      Assert (not Full_Set_Takes_In
                (Tools.Python_Code,
                 "```tool_code" & LF & "calculator(a=47, op=""plus"", b=89)"
                 & LF & "```"),
              "a choice off the schema's list was taken");
      Assert (not Full_Set_Takes_In
                (Tools.Python_Code,
                 "```tool_code" & LF & "nonesuch(a=1)" & LF & "```"),
              "a tool not offered was taken");
   end Python_Calls_Are_Shaped;

   --  Open_JSON reads the envelope, and the object a model trained on no
   --  envelope writes instead: bare on a line, or in a ```json fence, with
   --  prose around it. It is read only where it names a function and
   --  carries arguments; an object with a name and nothing else is text,
   --  as is a brace in prose, and neither is an error. A reply that wrote
   --  the envelope is read once, not once as an envelope and again as an
   --  open object. A call written back in the shape the offer took -- a
   --  <name> and its <arguments> -- is read too. And read as Tool_Call_JSON,
   --  the open shapes are text, so no other format's reading changes.
   procedure Open_JSON_Calls_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF     : constant Character := ASCII.LF;
      Asked  : Tools.Calls;
      Status : E.Error_Info;

      Bare : constant String :=
        "{""name"": ""lookup"", ""arguments"": {""key"": ""capital_of_france""}}"
        & LF & "The capital of France is Paris.";
      Fenced : constant String :=
        "```json" & LF
        & "{""name"": ""reverse_text"", ""arguments"": {""text"": ""stressed""}}"
        & LF & "```" & LF & "stressedstressed";
      Wrapped : constant String :=
        "Sure." & LF & "<tool_call>{""name"": ""calc"", ""arguments"": "
        & "{""a"": 1}}</tool_call>";
      Text_Only : constant String :=
        "The set {1, 2} and {""name"": ""Paris""} and {""arguments"": {}} "
        & "and {not json} are all text.";
      Tagged_Call : constant String :=
        "<tools>" & LF & "  <tool>" & LF & "    <name>write_file</name>" & LF
        & "    <arguments>{""path"": ""a.txt"", ""content"": ""x""}</arguments>" & LF
        & "  </tool>" & LF & "  <tool>" & LF & "    <name>run_checks</name>" & LF
        & "    <arguments>{}</arguments>" & LF & "  </tool>" & LF & "</tools>";
   begin
      --  The call dressed as the offer was: each <name> with its
      --  <arguments> object.
      Tools.Read_Calls (Asked, Tagged_Call, Status, Syntax => Tools.Open_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 2
              and then Tools.Called (Asked, 1) = "write_file"
              and then Tools.Arguments (Asked, 1) = "{""path"": ""a.txt"", ""content"": ""x""}"
              and then Tools.Called (Asked, 2) = "run_checks",
              "the tagged calls were not read:" & Natural'Image (Tools.Count (Asked)));
      Tools.Close (Asked);

      Tools.Read_Calls (Asked, Bare, Status, Syntax => Tools.Open_JSON);
      Assert (E.Is_Ok (Status), "the bare object would not read");
      Assert (Tools.Count (Asked) = 1, "the bare object was not one call");
      Assert (Tools.Called (Asked, 1) = "lookup",
              "wrong name: " & Tools.Called (Asked, 1));
      Assert (Tools.Arguments (Asked, 1) = "{""key"": ""capital_of_france""}",
              "wrong arguments: " & Tools.Arguments (Asked, 1));
      Tools.Close (Asked);

      Tools.Read_Calls (Asked, Fenced, Status, Syntax => Tools.Open_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1,
              "the fenced object was not read as one call");
      Assert (Tools.Called (Asked, 1) = "reverse_text",
              "wrong fenced name: " & Tools.Called (Asked, 1));
      Tools.Close (Asked);

      Tools.Read_Calls (Asked, Wrapped, Status, Syntax => Tools.Open_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1,
              "the envelope was not read exactly once:"
              & Natural'Image (Tools.Count (Asked)));
      Tools.Close (Asked);

      Tools.Read_Calls (Asked, Text_Only, Status, Syntax => Tools.Open_JSON);
      Assert (E.Is_Ok (Status),
              "a brace in prose was an error: "
              & E.Error_Code'Image (Status.Code));
      Assert (Tools.Count (Asked) = 0,
              "prose with braces was read as calls:"
              & Natural'Image (Tools.Count (Asked)));
      Tools.Close (Asked);

      Tools.Read_Calls (Asked, Bare, Status, Syntax => Tools.Tool_Call_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 0,
              "the bare object was read in the envelope syntax");
      Tools.Close (Asked);
   end Open_JSON_Calls_Parse;

   -------------------
   -- Register_Tests --
   -------------------

   --  The loop's memory of calls: a read made again is answered from the
   --  first, until a call that changes state runs; then every call before
   --  it is forgotten and runs again -- a file read after it was written
   --  is read, not answered with what it held. The change itself is kept:
   --  made twice with nothing between, the second is answered.
   procedure A_Change_Makes_Earlier_Calls_Run_Again
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Tr renames Model_Runner.Tools.Runner;
      use type Tr.Answer_Kind;

      package Rc renames Model_Runner.Agent.Recall;
      Read  : constant String := Rc.Identity ("read_file", "{""path"": ""a.adb"", ""line"": 1}");
      Write : constant String := Rc.Identity ("write_file", "{""path"": ""a.adb"", ""content"": ""x""}");
      Made  : Rc.Memory;
   begin
      --  A call is its name and its arguments as an object, whatever order
      --  its members were written in and however spaced; another value,
      --  another tool or text that is not JSON is another call.
      Assert (Rc.Identity ("read_file", "{""line"":1,""path"":""a.adb""}") = Read
              and then Rc.Identity ("read_file", " { ""path"" : ""a.adb"" , ""line"" : 1 } ") = Read,
              "the same arguments in another order or spacing were taken for another call");
      Assert (Rc.Identity ("read_file", "{""path"": ""a.adb"", ""line"": 2}") /= Read
              and then Rc.Identity ("list_directory", "{""path"": ""a.adb"", ""line"": 1}") /= Read
              and then Rc.Identity ("read_file", "{""path"": ""a b""}")
                       /= Rc.Identity ("read_file", "{""path"": ""ab""}"),
              "different calls were taken for the same, or space inside a string was dropped");
      Assert (Rc.Canonical ("{""b"": [ {""d"":1, ""c"":2} ], ""a"": null}") = "{""a"":null,""b"":[{""c"":2,""d"":1}]}"
              and then Rc.Canonical ("not json  at all") = "notjsonatall",
              "arguments were not put in canonical order, or text that is not JSON was not squeezed: "
              & Rc.Canonical ("{""b"": [ {""d"":1, ""c"":2} ], ""a"": null}"));

      --  However many calls are made, each is remembered: the protection
      --  does not lapse past a count.
      declare
         Many : Rc.Memory;
      begin
         for Index in 1 .. 1_000 loop
            Many.Remember (Rc.Identity ("read_file", "{""path"": ""f" & Integer'Image (Index) & """}"));
         end loop;
         Assert (Many.Holds (Rc.Identity ("read_file", "{""path"": ""f 1000""}"))
                 and then Many.Holds (Rc.Identity ("read_file", "{""path"": ""f 1""}")),
                 "a call past the first few hundred was not remembered");
      end;

      --  What was seen once is seen again; a new pair is not.
      declare
         Sighted : Model_Runner.Agent.Recall.Sightings;
      begin
         Assert (not Sighted.Seen_Again ("a", "ten") and then not Sighted.Seen_Again ("a", "eleven")
                 and then Sighted.Seen_Again ("a", "ten") and then not Sighted.Seen_Again ("b", "ten")
                 and then not Sighted.Seen_Again ("a" & ASCII.NUL & "t", "en"),
                 "a pair seen before was not noticed, or a new one was taken for it");
      end;

      Made.Remember (Read);
      Assert (Made.Holds (Read) and then not Made.Answered (Read),
              "a call made was not held, or held answered before it was");
      Made.Keep (Read, "old text", Tr.Done);
      Made.Keep (Read, "a second answer", Tr.Done);
      Assert (Made.Answer (Read) = "old text",
              "a held call's answer was not its first: " & Made.Answer (Read));

      Made.Changed (Write);
      Assert (not Made.Holds (Read),
              "a read was still held after a change, and would be answered stale");
      Assert (Made.Holds (Write), "the change itself was not held");
      Made.Keep (Write, "wrote 8 bytes", Tr.Done);

      Made.Remember (Read);
      Made.Keep (Read, "new text", (Answer => Tr.Failed, others => <>));
      Assert (Made.Answer (Read) = "new text"
              and then Made.Ended (Read).Answer = Tr.Failed,
              "the read after the change did not keep its own answer and ending");
      Assert (Made.Answer (Write) = "wrote 8 bytes",
              "a change with nothing after it lost its answer");

      --  A change makes stale only what read what it changes: a note put
      --  in the scratchpad leaves a file read standing, a sum stands
      --  through anything, and a program, which may change anything,
      --  leaves nothing but the sum.
      declare
         use type Tr.Resource;
         Sum  : constant String := Rc.Identity ("calculator", "{""a"":1,""b"":1,""op"":""+""}");
         Note : constant String := Rc.Identity ("memory_get", "{""key"":""k""}");
         Put  : constant String := Rc.Identity ("memory_put", "{""key"":""k"",""value"":""v""}");
         Run  : constant String := Rc.Identity ("shell", "{""command"":""true""}");
         Kept : Rc.Memory;
      begin
         Kept.Remember (Read, Tr.Files);
         Kept.Remember (Sum, Tr.Pure);
         Kept.Remember (Note, Tr.Agent_Memory);
         Kept.Changed (Put, Tr.Agent_Memory);
         Assert (Kept.Holds (Read) and then Kept.Holds (Sum) and then not Kept.Holds (Note),
                 "a scratchpad note made a file read stale, or left the note's read standing");
         Kept.Changed (Write, Tr.Files);
         Assert (not Kept.Holds (Read) and then Kept.Holds (Sum) and then Kept.Holds (Put),
                 "a write left a file read standing, or took the sum or the note's change with it");
         Kept.Remember (Read, Tr.Files);
         Kept.Changed (Run, Tr.Anything);
         Assert (Kept.Holds (Sum) and then not Kept.Holds (Read) and then not Kept.Holds (Put)
                 and then not Kept.Holds (Write),
                 "a program, which may change anything, left a read or a change standing");

         --  An answer is kept with the stamp of what it read.
         Kept.Remember (Read, Tr.Files);
         Kept.Keep (Read, "text", Tr.Done, Stamp => "file 1234");
         Assert (Kept.Stamp_Of (Read) = "file 1234", "an answer's stamp was not kept");
         Kept.Forget (Read);
         Assert (not Kept.Holds (Read), "a call forgotten was still held");
      end;
   end A_Change_Makes_Earlier_Calls_Run_Again;

   --  Each built-in tool says what it does to the state later calls read,
   --  and each call how it ended -- answered, failed, or refused and by
   --  what -- beside its words, which nothing need read for that.
   procedure Built_In_Calls_Say_How_They_Ended
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Tr renames Model_Runner.Tools.Runner;
      package Pm renames Model_Runner.Framework.Permissions;
      package Env renames Ada.Environment_Variables;
      use type Tr.Call_Kind;
      use type Tr.Call_Outcome;
      use type Tr.Answer_Kind;

      Runner : Builtin.Instance;
      Root   : constant String := "tools-outcome-root";

      function Ended (Named, Arguments : String) return Tr.Call_Outcome is
         Room   : String (1 .. Tools.Max_Call_Bytes);
         Last   : Natural;
         Status : E.Error_Info;
         Result : Tr.Call_Outcome;
      begin
         Runner.Run (Named, Arguments, Room, Last, Result, Status);
         Assert (E.Is_Ok (Status), "a built-in tool would not answer " & Named);
         return Result;
      end Ended;
   begin
      Assert (Runner.Kind ("read_file") = Tr.Reads
              and then Runner.Kind ("list_directory") = Tr.Reads
              and then Runner.Kind ("calculator") = Tr.Reads
              and then Runner.Kind ("write_file") = Tr.Changes
              and then Runner.Kind ("shell") = Tr.Changes
              and then Runner.Kind ("delegate") = Tr.Changes
              and then Runner.Kind ("now") = Tr.Varies
              and then Runner.Kind ("no such tool") = Tr.Changes,
              "a built-in tool's kind is not what it does");
      --  Every grammatical call has an answer: a number past the range, a
      --  result past it, and the one division past it are said, not raised.
      declare
         Room   : String (1 .. Tools.Max_Call_Bytes);
         Last   : Natural;
         Status : E.Error_Info;
         function Calc (A, Op, B : String) return String is
         begin
            Runner.Run ("calculator", "{""a"": " & A & ", ""op"": """ & Op & """, ""b"": " & B & "}",
                        Room, Last, Status);
            return Room (1 .. Last);
         end Calc;
      begin
         Assert (Ada.Strings.Fixed.Index (Calc ("99999999999999999999999", "+", "1"), "outside the supported") > 0
                 and then Ada.Strings.Fixed.Index (Calc ("9223372036854775807", "+", "1"), "outside the supported") > 0
                 and then Ada.Strings.Fixed.Index (Calc ("-9223372036854775808", "/", "-1"), "outside the supported")
                          > 0
                 and then Calc ("6", "*", "7") = "42",
                 "a number or a result past the range was not said: " & Calc ("9223372036854775807", "+", "1"));
      end;

      --  Every tool the registry describes is carried out by one row --
      --  here, or for a project's checks and graph questions by its work.
      declare
         package Rg renames Model_Runner.Tools.Registry;
      begin
         for Index in 1 .. Rg.Count loop
            Assert (Builtin.Handles (Rg.Name_At (Index))
                    or else Rg.Needs (Rg.Name_At (Index)) in Rg.Project_Graph | Rg.Project_Checks,
                    "a tool the registry describes is carried out nowhere: " & Rg.Name_At (Index));
         end loop;
      end;
      Assert (not Builtin.Handles ("no_such_tool"), "a tool the registry does not name was handled");

      --  What answers anew though nothing here changed is never answered
      --  from before: somebody may answer a question differently, and the
      --  web is not the harness's.
      Assert (Runner.Kind ("ask_user") = Tr.Varies
              and then Runner.Kind ("http_get") = Tr.Varies
              and then Runner.Kind ("web_search") = Tr.Varies,
              "a question to the user or a fetch from the web was taken as a read that stands");
      declare
         use type Tr.Resource;
      begin
         Assert (Runner.Touches ("read_file") = Tr.Files
                 and then Runner.Touches ("memory_get") = Tr.Agent_Memory
                 and then Runner.Touches ("calculator") = Tr.Pure
                 and then Runner.Touches ("shell") = Tr.Anything
                 and then Runner.Touches ("no such tool") = Tr.Anything,
                 "a built-in tool's resource is not what it reads or changes");
      end;

      --  Given a tree, the file tools work in it, whatever directory the
      --  process is in, and say a path as the model gave it.
      declare
         Tree   : constant String := Ada.Directories.Full_Name ("obj") & "/tools-base";
         Placed : Builtin.Instance;
         Room   : String (1 .. Tools.Max_Call_Bytes);
         Last   : Natural;
         Ended  : Tr.Call_Outcome;
         Status : E.Error_Info;
      begin
         --  Afresh: a run stopped part way leaves its files.
         if Ada.Directories.Exists (Tree) then
            Ada.Directories.Delete_Tree (Tree);
         end if;
         Ada.Directories.Create_Path (Tree);
         Placed.Set_Base (Tree);
         Placed.Run ("write_file", "{""path"": ""note.txt"", ""content"": ""placed""}", Room, Last, Ended, Status);
         Assert (E.Is_Ok (Status) and then Ada.Directories.Exists (Tree & "/note.txt")
                 and then not Ada.Directories.Exists ("note.txt")
                 and then Room (Room'First .. Last) = "wrote 6 bytes to note.txt",
                 "a write went to the process's directory, not the tree named: " & Room (Room'First .. Last));
         Placed.Run ("read_file", "{""path"": ""note.txt""}", Room, Last, Ended, Status);
         Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "placed") > 0,
                 "a read was not of the tree named: " & Room (Room'First .. Last));
         Assert (Ended.After_Revision = Tr.Mark (Model_Runner.Tools.Editing.Revision ("placed")),
                 "a read did not say, as a value, the revision it read");

         --  A passage there twice is edited where the lines it last read
         --  hold it.
         Placed.Run ("write_file", "{""path"": ""twice.txt"", ""content"": ""x\ny\nx\n""}",
                     Room, Last, Ended, Status);
         Placed.Run ("read_file", "{""path"": ""twice.txt"", ""first_line"": 3, ""last_line"": 3}",
                     Room, Last, Ended, Status);
         Placed.Run ("edit_file", "{""path"": ""twice.txt"", ""old_text"": ""x"", ""new_text"": ""z""}",
                     Room, Last, Ended, Status);
         Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "within the lines you last read") > 0,
                 "an edit there twice was not taken where the lines last read hold it: "
                 & Room (Room'First .. Last));

         --  Changed under it since it read it: refused, not made over what
         --  it did not see; read again, it may.
         declare
            Outside : Ada.Text_IO.File_Type;
         begin
            Ada.Text_IO.Open (Outside, Ada.Text_IO.Out_File, Tree & "/note.txt");
            Ada.Text_IO.Put (Outside, "theirs");
            Ada.Text_IO.Close (Outside);
         end;
         Placed.Run ("write_file", "{""path"": ""note.txt"", ""content"": ""mine""}", Room, Last, Ended, Status);
         Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "has changed since you last read") > 0,
                 "a write over a change made since the agent read the file was made: " & Room (Room'First .. Last));
         Placed.Run ("read_file", "{""path"": ""note.txt""}", Room, Last, Ended, Status);
         Placed.Run ("write_file", "{""path"": ""note.txt"", ""content"": ""mine""}", Room, Last, Ended, Status);
         Assert (Ended.Changed and then not Ended.Created
                 and then Ended.Before_Revision /= Tr.No_Revision
                 and then Ended.After_Revision = Tr.Mark (Model_Runner.Tools.Editing.Revision ("mine")),
                 "a write after reading again was not made, or did not say its revisions");

         --  Nothing written over something: refused, the file kept; an
         --  empty new file is a file.
         Placed.Run ("write_file", "{""path"": ""note.txt"", ""content"": """"}", Room, Last, Ended, Status);
         Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "would empty note.txt") > 0
                 and then Ada.Directories.">" (Ada.Directories.Size (Tree & "/note.txt"), 0),
                 "an empty write emptied a file that held text: " & Room (Room'First .. Last));
         if Ada.Directories.Exists (Tree & "/empty.txt") then
            Ada.Directories.Delete_File (Tree & "/empty.txt");
         end if;
         Placed.Run ("write_file", "{""path"": ""empty.txt"", ""content"": """"}", Room, Last, Ended, Status);
         Assert (Ended.Created, "an empty new file was refused");
         Ada.Directories.Delete_File (Tree & "/empty.txt");

         --  A file made: said as made; a folder that cannot be made: said
         --  why, not only that the write failed.
         if Ada.Directories.Exists (Tree & "/fresh.txt") then
            Ada.Directories.Delete_File (Tree & "/fresh.txt");
         end if;
         Placed.Run ("write_file", "{""path"": ""fresh.txt"", ""content"": ""new""}", Room, Last, Ended, Status);
         Assert (Ended.Created and then Ended.Before_Revision = Tr.No_Revision,
                 "a file made was not said to be made");
         --  Made durable, and no partial file of its making left beside it.
         declare
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
            Left   : Boolean := False;
         begin
            Ada.Directories.Start_Search (Search, Tree, "*model_runner-partial*");
            while Ada.Directories.More_Entries (Search) loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               Left := True;
            end loop;
            Ada.Directories.End_Search (Search);
            Assert (not Left and then Ada.Strings.Fixed.Index (Room (Room'First .. Last), "durable") = 0,
                    "a write left its partial file behind, or was said not durable: " & Room (Room'First .. Last));
         end;
         Placed.Run ("write_file", "{""path"": ""note.txt/inner.txt"", ""content"": ""x""}", Room, Last, Ended, Status);
         Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "could not make the folder") > 0,
                 "a folder that could not be made was not said: " & Room (Room'First .. Last));
         Ada.Directories.Delete_File (Tree & "/fresh.txt");
         Ada.Directories.Delete_File (Tree & "/note.txt");

         --  A search that could not look everywhere does not say what is
         --  absent.
         declare
            Locked : constant String := Tree & "/locked.txt";
            Outside : Ada.Text_IO.File_Type;
            Ignored : Boolean;
            Found  : Model_Runner.Tools.Editing.Said;
         begin
            --  One left by a run that stopped before giving it back its
            --  permissions, given them back and gone first.
            if Ada.Directories.Exists (Locked) then
               Ignored := Hostkit.Metadata.Set_Permissions (Locked, 8#644#);
               Ada.Directories.Delete_File (Locked);
            end if;
            Ada.Text_IO.Create (Outside, Ada.Text_IO.Out_File, Locked);
            Ada.Text_IO.Put (Outside, "needle");
            Ada.Text_IO.Close (Outside);
            if Hostkit.Metadata.Set_Permissions (Locked, 0) then
               Found := Model_Runner.Tools.Editing.Search_Code (Tree, "needle");
               --  And retrieve says so too, beside what it ranked.
               Placed.Run ("retrieve", "{""folder"": ""."", ""query"": ""needle""}", Room, Last, Ended, Status);
               Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "(incomplete:") > 0
                       or else Ada.Strings.Fixed.Index (Room (Room'First .. Last), "needle") > 0,
                       "retrieve over a file it could not read said nothing of it: " & Room (Room'First .. Last));
               Ignored := Hostkit.Metadata.Set_Permissions (Locked, 8#644#);
               --  Root reads it anyway: then it is found, and nothing is said.
               Assert (Found.Incomplete
                       or else Ada.Strings.Fixed.Index (Ada.Strings.Unbounded.To_String (Found.Text), "needle") > 0,
                       "a search that could not read a file said nothing holds the text: "
                       & Ada.Strings.Unbounded.To_String (Found.Text));
            end if;
            Ada.Directories.Delete_File (Locked);
         end;
      end;

      --  A file read is stamped by what the file holds, so one changed
      --  under it -- by an editor, a build -- is read again; a tree read
      --  by the files under it; a call that reads no files by nothing.
      declare
         Path  : constant String := "tools-stamp.txt";
         Args  : constant String := "{""path"": """ & Path & """}";
         File  : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
         Ada.Text_IO.Put (File, "one");
         Ada.Text_IO.Close (File);
         declare
            Before : constant String := Runner.Stamp ("read_file", Args);
            Tree   : constant String := Runner.Stamp ("find", "{""kind"": ""text"", ""query"": ""x""}");
         begin
            --  The same size where the host stamps a file to the nanosecond;
            --  where it gives only size and time, an edit the same size within
            --  its time's grain is one the tree's stamp cannot see -- so there
            --  the size moves.
            declare
               Fine : Boolean;
               Held : constant String := Hostkit.Metadata.Change_Stamp (Path, Fine);
               pragma Unreferenced (Held);
            begin
               Ada.Text_IO.Open (File, Ada.Text_IO.Out_File, Path);
               Ada.Text_IO.Put (File, (if Fine then "two" else "three"));
               Ada.Text_IO.Close (File);
            end;
            Assert (Before /= "" and then Runner.Stamp ("read_file", Args) /= Before,
                    "a file changed under a read kept its stamp: " & Before);
            Assert (Tree /= "" and then Runner.Stamp ("find", "{""kind"": ""text"", ""query"": ""x""}") /= Tree,
                    "a tree with a file changed in it kept its stamp");
            Assert (Runner.Stamp ("calculator", "{}") = "" and then Runner.Stamp ("write_file", Args) = "",
                    "a call that reads no files was given a stamp");
         end;
         Ada.Directories.Delete_File (Path);
      end;

      Assert (Ended ("calculator", "{""a"": 2, ""b"": 2, ""op"": ""+""}") = Tr.Done,
              "an answered call did not end answered");
      --  A write changes the file; the same write again changes nothing,
      --  and says so.
      declare
         First  : constant Tr.Call_Outcome :=
           Ended ("write_file", "{""path"": ""tools-outcome-write.txt"", ""content"": ""same""}");
         Second : constant Tr.Call_Outcome :=
           Ended ("write_file", "{""path"": ""tools-outcome-write.txt"", ""content"": ""same""}");
         Third  : constant Tr.Call_Outcome :=
           Ended ("write_file", "{""path"": ""tools-outcome-write.txt"", ""content"": ""other""}");
      begin
         Ada.Directories.Delete_File ("tools-outcome-write.txt");
         Assert (First.Changed and then not Second.Changed and then Third.Changed
                 and then Second.Answer = Tr.Answered,
                 "a write of what a file already held was not told from one that changed it");
      end;
      Assert (Ended ("read_file", "{""path"": ""no-such-file-anywhere.txt""}")
              = Tr.Call_Outcome'(Answer => Tr.Failed, Refusal => Tr.Not_Refused, Changed => False, others => <>),
              "a read of a file not there did not end failed");

      --  Held where the harness said: refused, and by what.
      if not Ada.Directories.Exists (Root) then
         Ada.Directories.Create_Path (Root & "/.model_runner");
      end if;
      Env.Set (Pm.Agent_Root_Variable, Root);
      Env.Set (Pm.Agent_Permissions_Variable, Pm.Image (Pm.Unrestricted));
      declare
         Outside : constant Tr.Call_Outcome :=
           Ended ("read_file", "{""path"": ""../elsewhere.txt""}");
         State   : constant Tr.Call_Outcome :=
           Ended ("write_file", "{""path"": "".model_runner/evil"", ""content"": ""x""}");
         Program : constant Tr.Call_Outcome :=
           Ended ("shell", "{""command"": ""echo ran-it""}");
      begin
         Env.Clear (Pm.Agent_Root_Variable);
         Env.Clear (Pm.Agent_Permissions_Variable);
         Ada.Directories.Delete_Tree (Root);
         Assert (Outside =
                   Tr.Call_Outcome'(Answer => Tr.Refused, Refusal => Tr.Outside_Project,
                                   Changed => False, others => <>),
                 "a path out of the tree was not refused as outside the project");
         Assert (State =
                   Tr.Call_Outcome'(Answer => Tr.Refused, Refusal => Tr.Harness_Owned, Changed => False, others => <>),
                 "a write into the state was not refused as the harness's");
         Assert (Program =
                   Tr.Call_Outcome'(Answer => Tr.Refused, Refusal => Tr.Not_Permitted, Changed => False, others => <>),
                 "a program an agent may not run was not refused as not permitted");
      end;
   end Built_In_Calls_Say_How_They_Ended;

   --  What the loop does about a failure is the harness's decision, by
   --  the failure's class: room made for one that ran out of it, a backend
   --  error tried again while retries last, an unreadable call given back
   --  while chances last, and the rest an end.
   procedure Failures_Are_Recovered_By_Their_Class
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package A renames Model_Runner.Agent;
      use type A.Recovery_Action;
      use type A.Failure_Class;
   begin
      Assert (A.Class_Of (E.Make (E.Template_Output_Too_Large)) = A.Too_Large_To_Render
              and then A.Class_Of (E.Make (E.Generation_Context_Exhausted)) = A.Context_Exhausted
              and then A.Class_Of (E.Make (E.Generation_Cancelled)) = A.Interrupted
              and then A.Class_Of (E.Make (E.Tools_Call_Malformed)) = A.Unreadable_Call
              and then A.Class_Of (E.Make (E.IO_Read_Failed)) = A.Backend_Error,
              "a failure was put in the wrong class");
      Assert (A.Recovery_For (A.Context_Exhausted, True, 0, 0) = A.Compact_And_Retry
              and then A.Recovery_For (A.Context_Exhausted, False, 3, 3) = A.Stop
              and then A.Recovery_For (A.Backend_Error, True, 1, 0) = A.Retry_Same
              and then A.Recovery_For (A.Backend_Error, True, 0, 2) = A.Stop
              and then A.Recovery_For (A.Unreadable_Call, False, 0, 1) = A.Return_To_Model
              and then A.Recovery_For (A.Unreadable_Call, False, 5, 0) = A.Stop
              and then A.Recovery_For (A.Interrupted, True, 5, 5) = A.Stop,
              "a failure was not answered as its class is");
   end Failures_Are_Recovered_By_Their_Class;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Failures_Are_Recovered_By_Their_Class'Access,
         "a failure in the agent loop is recovered from as its class says");
      Register_Routine
        (T, A_Change_Makes_Earlier_Calls_Run_Again'Access,
         "a call that changes state makes every call before it run again, "
         & "and is itself answered from the first when made again");
      Register_Routine
        (T, Built_In_Calls_Say_How_They_Ended'Access,
         "each built-in tool says what it does to state, and each call how "
         & "it ended and what refused it");
      Register_Routine
        (T, Open_JSON_Calls_Parse'Access,
         "an Open_JSON reply reads a bare or fenced object naming a function "
         & "with arguments as a call, the envelope once, and prose as prose");
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
        (T, Recipient_JSON_Calls_Parse'Access,
         "the recipient form parses Functionary's calls");
      Register_Routine
        (T, Python_Code_Calls_Parse'Access,
         "Gemma's Python calls in a tool_code block read as JSON arguments");
      Register_Routine
        (T, Python_Calls_Are_Shaped'Access,
         "Gemma's Python calls are shaped by the call grammar, code fences "
         & "in prose kept");
      Register_Routine
        (T, Function_XML_Calls_Parse'Access,
         "a MiniCPM function/param reply reads as calls with JSON arguments");
      Register_Routine
        (T, Wired_Helpers_Reach_Their_Tools'Access,
         "a delegator, an inquirer and an embedder wired into the runner "
         & "are what delegate, ask_user and retrieve reach, and unwired "
         & "each declines again");
      Register_Routine
        (T, Calls_Run_Within_The_Run'Access,
         "a call runs within its run: a child is held to how it ended, a tool offered only where it runs,"
         & " a process stopped at the run's cancellation and deadline");
      Register_Routine
        (T, Files_Are_Edited_In_Part'Access,
         "a file is edited in part and only as it was read, read by lines, searched, and refused whole"
         & " past the bound");
      Register_Routine
        (T, One_Runtime_For_Every_Agent'Access,
         "every agent is offered and fenced from one registry, helpers have one contract, and a"
         & " program's failure is said with its exit status and standard error");
      Register_Routine
        (T, Command_Lines_Read_Back'Access,
         "every project command's line is read into a request by one reader, and reads back the same");
      Register_Routine
        (T, Delegate_Declines_Undelegated'Access,
         "delegate with no delegator declines rather than crashing or "
         & "recursing");
      Register_Routine
        (T, Ask_User_Declines_Unwired'Access,
         "ask_user with no inquirer declines rather than blocking on input");
      Register_Routine
        (T, Parallel_Safety_Is_Marked'Access,
         "the runner marks which tools may overlap and which may not");
      Register_Routine
        (T, Damaged_Memory_File_Leaves_No_Notes'Access,
         "a damaged memory file is said, leaves no notes and raises nothing; a note the file"
         & " cannot take is said");
      Register_Routine
        (T, Memory_Persists_To_A_File'Access,
         "a note written with a memory file behind it is read back by a "
         & "later runner");
      Register_Routine
        (T, Large_Result_Keeps_Head_And_Tail'Access,
         "a result too big for the buffer keeps its head and its tail, "
         & "not only its head");
      Register_Routine
        (T, Grammar_Constrains'Access,
         "the call grammar takes a readable call and prose and refuses the "
         & "rest");
      Register_Routine
        (T, Answer_Schema_Shapes_The_Answer'Access,
         "an answer schema makes the reply a call or an answer in that "
         & "shape, not prose");
      Register_Routine
        (T, Tag_Syntaxes_Are_Shaped'Access,
         "the Qwen3-Coder and MiniCPM tag syntaxes are shaped by the call "
         & "grammar: a parameter per tag, the schema in it, a think block "
         & "ahead, and a malformed tag refused");
      Register_Routine
        (T, Recipient_Is_Shaped'Access,
         "Functionary's recipient form is shaped by the call grammar: a "
         & "recipient on offer, its arguments object per the tool's schema, "
         & "spoken text and calls in one reply, and a short call refused");
      Register_Routine
        (T, Recipient_Spoken_Splits'Access,
         "a Functionary recipient reply's spoken words are kept apart from "
         & "its calls, a pure call carries none, and the JSON prefix holds");
      Register_Routine
        (T, Full_Set_Is_Tight'Access,
         "the whole built-in set builds the tight grammar, not the loose "
         & "fallback");
      Register_Routine
        (T, Retrieve_Ranks_The_Folder'Access,
         "retrieve ranks a folder tree's passages against a query, descends "
         & "into subfolders, and finds nothing for words in no file");
   end Register_Tests;

end Tests.Tools_Cases;
