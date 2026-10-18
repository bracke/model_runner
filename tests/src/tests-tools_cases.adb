with AUnit.Test_Cases;
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
with Hostkit.Fs;
with Hostkit.Metadata;
with Model_Runner.Tools;
with Model_Runner.Conversation;
with Model_Runner.Templates;
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
with Model_Runner.Sampling;
with Model_Runner.Tokenizer.Folding;
with Model_Runner.Tools.RTF;
with Model_Runner.Framework;
with Model_Runner.CLI.Options;
with Model_Runner.Drafts;
with Model_Runner.Video;
with Model_Runner.Text;
with Model_Runner.Tools.Text_Util;

package body Tests.Tools_Cases is

   use type Model_Runner.Numerics.Element_Count;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.Grammar;
   package Tools renames Model_Runner.Tools;
   package Builtin renames Model_Runner.Tools.Builtin;
   package Constraint renames Model_Runner.Tools.Constraint;

   --  A file's bytes, whole.
   function Whole_File (Path : String) return String is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path);
      declare
         Text : String (1 .. Natural (Ada.Streams.Stream_IO.Size (File)));
      begin
         String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
         Ada.Streams.Stream_IO.Close (File);
         return Text;
      end;
   end Whole_File;

   --  A file of exactly these bytes.
   procedure Put_Bytes (Path, Text : String) is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Path);
      String'Write (Ada.Streams.Stream_IO.Stream (File), Text);
      Ada.Streams.Stream_IO.Close (File);
   end Put_Bytes;

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
      --  A search for a file's name that no file holds says the file is
      --  there: "no file holds that" was read as no such file.
      Assert (Has (Ed.Search_Code (Dir, "calc.adb"), "there is a file of that name")
              and then Has (Ed.Search_Code (Dir, "calc.adb"), "calc.adb")
              and then not Has (Ed.Search_Code (Dir, "nowhere.md"), "of that name"),
              "a search for a file's name did not say the file is there: "
              & Ada.Strings.Unbounded.To_String (Ed.Search_Code (Dir, "calc.adb").Text));

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
         --  Matched loosely, and what it would put there is what is there:
         --  said unchanged, not edited.
         declare
            Same : constant Ed.Said := Ed.Edit (Loose_Path, "    X := 3;", "    X := 3;", "");
         begin
            Assert (not Same.Failed and then not Same.Changed and then Has (Same, "unchanged"),
                    "a loose edit that changed nothing was said to have edited: "
                    & Ada.Strings.Unbounded.To_String (Same.Text));
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
      --  Not there: said with the file's lines where a line of it stands.
      declare
         Gone_Path : constant String := Dir & "/gone.adb";
      begin
         Put (Gone_Path, "begin" & ASCII.LF & "   X := 1;" & ASCII.LF & "   Y := 2;" & ASCII.LF & "end P;" & ASCII.LF);
         declare
            Missed : constant Ed.Said := Ed.Edit (Gone_Path, "   W := 0;" & ASCII.LF & "   X := 1;" & ASCII.LF
                                                  & "   Z := 9;", "x", "");
         begin
            Assert (Missed.Failed and then Has (Missed, "where its line 2 is, the file reads:")
                    and then Has (Missed, ASCII.LF & "1: begin" & ASCII.LF & "2:    X := 1;")
                    and then Has (Missed, "4: end P;"),
                    "a passage not there was not said with the lines where it would be: "
                    & Ada.Strings.Unbounded.To_String (Missed.Text));
         end;
         Assert (not Has (Ed.Edit (Gone_Path, "Q := 7;", "x", ""), "the file reads"),
                 "a passage none of whose lines is there was said with lines");
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
      --  A failure that said a lot on both streams is told cut, within
      --  what an answer may hold -- not refused as too large to tell.
      declare
         Loud : constant Pr.Result :=
           (Started => True, Stopped => False, Overflowed => False, Exit_Status => 2,
            Output => Ada.Strings.Unbounded.To_Unbounded_String ([1 .. 30_000 => 'o']),
            Errors => Ada.Strings.Unbounded.To_Unbounded_String ([1 .. 20_000 => 'e']),
            Truncated => False);
         Said : constant String := Pr.Told (Loud, "'make'");
      begin
         Assert (Said'Length <= Model_Runner.Tools.Max_Call_Bytes and then Has (Said, "bytes left out")
                 and then Has (Said, "exit status 2"),
                 "a long failure was told past what an answer may hold:" & Said'Length'Image);
      end;
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
         --  Read in the tree the helper writes in -- a workspace's -- not
         --  the process's directory: written there, an output is written.
         declare
            Tree : constant String := Ada.Directories.Full_Name ("obj/rt-tree");
         begin
            if Ada.Directories.Exists (Tree) then
               Ada.Directories.Delete_Tree (Tree);
            end if;
            Ada.Directories.Create_Path (Tree & "/obj");
            Before := Rt.Prints (Outputs, Tree);
            Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Tree & "/obj/rt_a.txt");
            Ada.Text_IO.Put_Line (F, "written in the tree");
            Ada.Text_IO.Close (F);
            Assert (Rt.Unwritten (Outputs, Before, Tree) = "obj/rt_b.txt"
                    and then Rt.Unwritten (Outputs, Rt.Prints (Outputs), "") = "obj/rt_a.txt, obj/rt_b.txt",
                    "an output written in the helper's tree was read in another: "
                    & Rt.Unwritten (Outputs, Before, Tree));
            Ada.Directories.Delete_Tree (Tree);
         end;
         --  What a task's words name that is not there: the note a parent
         --  that named no outputs is given. A path or a name.ext, its
         --  quotes and closing stop off, each once; one there, an address,
         --  a version number and plain words are not named.
         declare
            Said : constant String :=
              Rt.Named_But_Absent
                ("Write `docs/never.md` (from src/never.adb) and NOTES.txt, docs/never.md again;"
                 & " see https://example.org/x.md and version 2.5, and alire.toml.");
         begin
            Assert (Said = "docs/never.md, src/never.adb, NOTES.txt",
                    "the paths a task names that are not there were not read as they are: " & Said);
         end;
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
              "delegate must not be parallel-safe (a helper may read, write and run anything)");
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
      --  One string however it is escaped is one call -- \/ and /, \u0041 and
      --  A -- as the tools read it; a quote escaped inside a string is not
      --  taken for the string's end.
      Assert (Rc.Identity ("read_file", "{""path"": ""src\/a.adb"", ""line"": 1}")
              = Rc.Identity ("read_file", "{""path"": ""src/a.adb"", ""line"": 1}")
              and then Rc.Identity ("read_file", "{""path"": ""\u0041.adb""}")
                       = Rc.Identity ("read_file", "{""path"": ""A.adb""}")
              and then Rc.Identity ("read_file", "{""a"": ""x\"",\""b\"":\""y""}")
                       /= Rc.Identity ("read_file", "{""a"": ""x"", ""b"": ""y""}"),
              "one string spelled two ways was taken for two calls, or an escaped quote ended a string");
      declare
         Have : Boolean;
         Read : constant String :=
           Builtin.Text_Argument ("{""path"": ""\u0041\/b.adb""}", "path", Have);
      begin
         Assert (Read = "A/b.adb" and then Have,
                 "a \u escape in an argument was not read as its character");
      end;
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

      --  A thought is open where the reply opened it, or the prompt did,
      --  and it is not closed; a prompt that closed an empty one leaves none.
      Assert (Model_Runner.Agent.Thought_Open ("<think>\nmulling", "<|im_start|>assistant\n")
              and then Model_Runner.Agent.Thought_Open ("mulling", "<|im_start|>assistant\n<think>\n")
              and then not Model_Runner.Agent.Thought_Open ("<think>\nmulled</think>\ncall", "assistant\n")
              and then not Model_Runner.Agent.Thought_Open
                             ("answer", "<|im_start|>assistant\n<think>\n\n</think>\n\n")
              and then not Model_Runner.Agent.Thought_Open ("plain answer", ""),
              "a thought was taken as open where it was closed or never opened, or the other way");

      --  The harness's notes on a call: a file put back at a revision seen
      --  earlier, by an edit; a read answering as before the last change,
      --  its evidence names aside; quiet calls counted -- and carried into
      --  a second run on the same conversation, as /work's rounds are.
      declare
         Kept : Model_Runner.Agent.Recall.Carried;

         function Note (Path, Said : String; Reads, Changed : Boolean; After : String;
                        Quiet : Natural := 0) return String
         is (Rc.Note_For (Kept, Rc.Identity ((if Reads then "run_checks" else "edit_file"), Path), Path, Said,
                          Ran => True, Reads => Reads, Answered => True, Changed => Changed,
                          After => After, Quiet => Quiet));
      begin
         Assert (Note ("calc.adb", "edited", False, True, "aaaaaaaaaaaaaaaa") = "",
                 "a first edit was noted");
         Kept.Made_Change := True;
         Assert (Note ("", "checks failed, VER-000001", True, False, "") = ""
                 and then Note ("calc.adb", "edited", False, True, "bbbbbbbbbbbbbbbb") = "",
                 "a first check, or an edit to a new revision, was noted");
         declare
            --  A second run, carrying what the first saw.
            Again : constant String := Note ("calc.adb", "edited", False, True, "aaaaaaaaaaaaaaaa");
            Same  : constant String := Note ("", "checks failed, VER-000002", True, False, "");
         begin
            Assert (Ada.Strings.Fixed.Index (Again, "back to a version it had earlier") > 0
                    and then Ada.Strings.Fixed.Index (Again, "aaaaaaaaaaaaaaaa") > 0,
                    "a file put back at a revision seen earlier was not noted: " & Again);
            Assert (Ada.Strings.Fixed.Index (Same, "answers exactly as it did before") > 0,
                    "a check failing as before, under a new evidence name, was not noted: " & Same);
         end;
         Assert (Ada.Strings.Fixed.Index (Note ("", "x", True, False, "", Quiet => Rc.Quiet_Note),
                                          "calls in a row have changed nothing") > 0,
                 "calls in a row changing nothing were not noted");
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
      --  here, or for a project's checks, graph questions and observations
      --  by its work.
      declare
         package Rg renames Model_Runner.Tools.Registry;
      begin
         for Index in 1 .. Rg.Count loop
            Assert (Builtin.Handles (Rg.Name_At (Index))
                    or else Rg.Needs (Rg.Name_At (Index))
                              in Rg.Project_Graph | Rg.Project_Checks | Rg.Project_Knowledge,
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

         --  Shown before any call, at the revision it was read at: written
         --  over as it stands, and refused where it changed since.
         declare
            Outside : Ada.Text_IO.File_Type;
         begin
            Ada.Text_IO.Create (Outside, Ada.Text_IO.Out_File, Tree & "/shown.txt");
            Ada.Text_IO.Put (Outside, "as shown");
            Ada.Text_IO.Close (Outside);
            Placed.Note_Seen ("shown.txt", Model_Runner.Tools.Editing.Revision_Of (Tree & "/shown.txt"));
            --  An excerpt shown is not the whole: written over whole, it
            --  is read whole first.
            Placed.Run ("write_file", "{""path"": ""shown.txt"", ""content"": ""mine""}", Room, Last, Ended, Status);
            Assert (not Ended.Changed
                    and then Ada.Strings.Fixed.Index (Room (Room'First .. Last), "not read the whole") > 0,
                    "a file seen only as shown was written over whole: " & Room (Room'First .. Last));
            Placed.Run ("read_file", "{""path"": ""./shown.txt""}", Room, Last, Ended, Status);
            Placed.Run ("write_file", "{""path"": ""shown.txt"", ""content"": ""mine""}", Room, Last, Ended, Status);
            Assert (Ended.Changed, "a file read whole as it stands was refused: " & Room (Room'First .. Last));
            Placed.Note_Seen ("shown.txt", Model_Runner.Tools.Editing.Revision ("an older excerpt"));
            Placed.Run ("write_file", "{""path"": ""shown.txt"", ""content"": ""again""}", Room, Last, Ended, Status);
            Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "has changed since you last read") > 0,
                    "a file changed since it was shown was written over: " & Room (Room'First .. Last));
         end;

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

         --  Its own edit moves the lines it read: the range is no guide
         --  after, and a passage there twice is asked about again.
         Placed.Run ("edit_file", "{""path"": ""twice.txt"", ""old_text"": ""y"", ""new_text"": ""z\nx""}",
                     Room, Last, Ended, Status);
         Placed.Run ("edit_file", "{""path"": ""twice.txt"", ""old_text"": ""x"", ""new_text"": ""w""}",
                     Room, Last, Ended, Status);
         Assert (not Ended.Changed,
                 "an edit took a place by lines read before its own edit moved them: "
                 & Room (Room'First .. Last));

         --  A passage overlapping itself is there more than once.
         Placed.Run ("write_file", "{""path"": ""ends.txt"", ""content"": ""end;\nend;\nend;\n""}",
                     Room, Last, Ended, Status);
         Placed.Run ("edit_file", "{""path"": ""ends.txt"", ""old_text"": ""end;\nend;"", ""new_text"": ""x""}",
                     Room, Last, Ended, Status);
         Assert (not Ended.Changed,
                 "a passage there twice, overlapping, was taken as there once: " & Room (Room'First .. Last));

         --  Lines ended as the file ends them, exactly matched or not.
         declare
            Read : Ada.Strings.Unbounded.Unbounded_String;
            use Ada.Strings.Unbounded;
         begin
            Put_Bytes (Tree & "/crlf.txt", "a();" & ASCII.CR & ASCII.LF & "b();" & ASCII.CR & ASCII.LF);
            Placed.Run ("read_file", "{""path"": ""crlf.txt""}", Room, Last, Ended, Status);
            Placed.Run ("edit_file", "{""path"": ""crlf.txt"", ""old_text"": ""a();"", ""new_text"": ""a();\nc();""}",
                        Room, Last, Ended, Status);
            Read := To_Unbounded_String (Whole_File (Tree & "/crlf.txt"));
            Assert (To_String (Read) = "a();" & ASCII.CR & ASCII.LF & "c();" & ASCII.CR & ASCII.LF
                                       & "b();" & ASCII.CR & ASCII.LF,
                    "an edit to a file of CRLF lines left a bare line break");
         end;

         --  Matched with the spaces at line ends left out, what is put has
         --  no blank line the given text did not hold.
         Placed.Run ("write_file", "{""path"": ""loose.txt"", ""content"": ""foo  \nbaz\n""}",
                     Room, Last, Ended, Status);
         Placed.Run ("edit_file", "{""path"": ""loose.txt"", ""old_text"": ""foo\n"", ""new_text"": ""bar\n""}",
                     Room, Last, Ended, Status);
         Assert (Whole_File (Tree & "/loose.txt") = "bar" & ASCII.LF & "baz" & ASCII.LF,
                 "a loose edit put a blank line in: " & Whole_File (Tree & "/loose.txt"));

         --  Seen, and gone since: not made again over what was seen.
         Placed.Run ("read_file", "{""path"": ""loose.txt""}", Room, Last, Ended, Status);
         Ada.Directories.Delete_File (Tree & "/loose.txt");
         Placed.Run ("write_file", "{""path"": ""loose.txt"", ""content"": ""back""}", Room, Last, Ended, Status);
         Assert (not Ended.Changed and then not Ada.Directories.Exists (Tree & "/loose.txt"),
                 "a file seen and gone since was made again unseen: " & Room (Room'First .. Last));

         --  A search held to what may be read shows nothing of a place
         --  denied; let go, it shows it again.
         declare
            package Pm renames Model_Runner.Framework.Permissions;
            Held : Pm.Permission_Set := Pm.Unrestricted;
         begin
            Ada.Directories.Create_Path (Tree & "/secret");
            Put_Bytes (Tree & "/secret/key.txt", "hidden value" & ASCII.LF);
            Held (Pm.Read_Source).Deny.Append ("secret");
            Held (Pm.Read_Specs).Deny.Append ("secret");
            Builtin.Hold_Reads (Tree, Held);
            Placed.Run ("search_code", "{""path"": ""."", ""pattern"": ""hidden value""}", Room, Last, Ended, Status);
            Builtin.Let_Reads_Go;
            Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "secret/key.txt") = 0,
                    "a search showed a file the agent may not read: " & Room (Room'First .. Last));
            Placed.Run ("search_code", "{""path"": ""."", ""pattern"": ""hidden value""}", Room, Last, Ended, Status);
            Assert (Ada.Strings.Fixed.Index (Room (Room'First .. Last), "key.txt") > 0,
                    "a search let go still held what it shows: " & Room (Room'First .. Last));
         end;

         --  Completion offers every command the table runs.
         Assert (Ada.Strings.Fixed.Index (Model_Runner.CLI.Project_Commands.Command_Names, " /why ") > 0
                 and then Ada.Strings.Fixed.Index (Model_Runner.CLI.Project_Commands.Command_Names, " /brief ") > 0,
                 "a project command was left out of the names offered");

         --  One argument given anew, by its name, not where its text first
         --  appears.
         Assert (Model_Runner.Tools.Builtin.With_Text_Argument
                   ("{""content"": ""/a"", ""path"": ""/a""}", "path", "a")
                 = "{""content"":""/a"",""path"":""a""}",
                 "an argument given anew changed another that spelt the same: "
                 & Model_Runner.Tools.Builtin.With_Text_Argument
                     ("{""content"": ""/a"", ""path"": ""/a""}", "path", "a"));

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
            --  A file change is stamped too, by the file it would change: one
            --  that failed may run again once that has moved.
            Assert (Runner.Stamp ("calculator", "{}") = ""
                    and then Runner.Stamp ("write_file", Args) = Runner.Stamp ("read_file", Args)
                    and then Runner.Stamp ("edit_file", Args) = Runner.Stamp ("read_file", Args),
                    "a call that touches no files was given a stamp, or a file change none");
         end;
         Ada.Directories.Delete_File (Path);
      end;

      --  A file of megabytes is read on a stack of one: read a slice at a
      --  time, not copied onto the stack whole, twice.
      declare
         Path : constant String := "tools-big.txt";
         File : Ada.Text_IO.File_Type;
         Read : Boolean := False;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
         for Line in 1 .. 32 * 1024 loop
            Ada.Text_IO.Put_Line (File, [1 .. 63 => 'x']);
         end loop;
         Ada.Text_IO.Close (File);
         declare
            task Reader with Storage_Size => 1024 * 1024;
            task body Reader is
               Text   : Ada.Strings.Unbounded.Unbounded_String;
               Status : Model_Runner.Errors.Error_Info;
            begin
               Model_Runner.Tools.Editing.Read_Text (Path, Text, Status);
               Read := Model_Runner.Errors.Is_Ok (Status)
                 and then Ada.Strings.Unbounded.Length (Text) = 2 * 1024 * 1024;
            exception
               when others =>
                  Read := False;
            end Reader;
         begin
            null;
         end;
         Ada.Directories.Delete_File (Path);
         Assert (Read, "a file of two megabytes was not read on a stack of one");
      end;

      --  A tree with a link back up in it is stamped without following
      --  the link -- which walked the tree again at every level -- and the
      --  same twice.
      declare
         Folder : constant String := "tools-stamp-loop";
         Args   : constant String := "{""path"": """ & Folder & """}";
         Made   : Boolean;
         Gone   : Boolean;
      begin
         Ada.Directories.Create_Path (Folder);
         Made := Hostkit.Fs.Create_Link ("..", Folder & "/up");
         if Made then
            declare
               First  : constant String := Runner.Stamp ("list_directory", Args);
               Second : constant String := Runner.Stamp ("list_directory", Args);
            begin
               --  Taken down before anything is asserted: a link back up
               --  left in the tree is one every walk of it follows.
               Gone := Hostkit.Fs.Delete_Link (Folder & "/up");
               Ada.Directories.Delete_Directory (Folder);
               Assert (Gone and then First /= "" and then Second = First,
                       "a tree with a link back up was not stamped the same twice: " & First);
            end;
         else
            Ada.Directories.Delete_Directory (Folder);
         end if;
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

   --  gpt-oss's harmony form: its template recognised, a call read out of
   --  a message addressed to "functions.NAME" in either place the header
   --  names it, the reasoning before a call taken as the turn's words, and
   --  an answer read off the final channel -- the reply's own markers kept
   --  out of the turn, which the template refuses.
   procedure Harmony_Calls_Are_Read
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Offer : constant String :=
        "[{""type"": ""function"", ""function"": {""name"": ""list_directory"", "
        & """parameters"": {""type"": ""object"", ""properties"": {"
        & """path"": {""type"": ""string""}}}}}]";

      Defs   : aliased Tools.Definitions;
      Status : E.Error_Info;

      Call_Reply : constant String :=
        "<|channel|>analysis<|message|>Look at src first; A < B.<|end|>"
        & "<|start|>assistant<|channel|>commentary to=functions.list_directory"
        & " <|constrain|>json<|message|>{""path"": ""src""}";
      Header_Reply : constant String :=
        "<|start|>assistant to=functions.list_directory<|channel|>commentary"
        & " json<|message|>{""path"": "".""}";
      Answer_Reply : constant String :=
        "<|channel|>analysis<|message|>Done.<|end|><|start|>assistant"
        & "<|channel|>final<|message|>status: done" & ASCII.LF
        & "summary: listed<|return|>";

      function Read (Reply : String) return String is
         Asked : Tools.Calls;
         Said  : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Tools.Read_Calls (Asked, Reply, Status, Syntax => Tools.Harmony_Call,
                           Offered => Defs'Unchecked_Access);
         if E.Is_Error (Status) then
            Tools.Close (Asked);
            return "error " & E.Error_Code'Image (Status.Code);
         end if;
         for Index in 1 .. Tools.Count (Asked) loop
            Ada.Strings.Unbounded.Append
              (Said, Tools.Called (Asked, Index) & "("
                     & Tools.Arguments (Asked, Index) & ")");
         end loop;
         Tools.Close (Asked);
         return Ada.Strings.Unbounded.To_String (Said);
      end Read;

      procedure Same (Got, Wanted, What : String) is
      begin
         Assert (Got = Wanted, What & ": [" & Got & "] where [" & Wanted
                 & "] was meant");
      end Same;
   begin
      Tools.Read (Defs, Offer, Status);
      Assert (E.Is_Ok (Status), "the offer did not parse");

      declare
         use Ada.Streams.Stream_IO;
         File : File_Type;
      begin
         Open (File, In_File, "fixtures/gpt-oss-own.jinja");
         declare
            Text : String (1 .. Natural (Size (File)));
            Last : Ada.Streams.Stream_Element_Offset;
            Raw  : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Text'Length));
         begin
            Read (File, Raw, Last);
            for Index in Text'Range loop
               Text (Index) := Character'Val
                 (Raw (Ada.Streams.Stream_Element_Offset (Index)));
            end loop;
            Same (Model_Runner.Templates.Recognise (Text),
                  Model_Runner.Templates.Harmony_Shape,
                  "gpt-oss's own template was not recognised");
         end;
         Close (File);
      end;
      Assert (Tools."=" (Model_Runner.Templates.Reading_Syntax
                           (Model_Runner.Templates.Harmony_Shape),
                         Tools.Harmony_Call),
              "a harmony template's calls were not read in its syntax");

      Same (Read (Call_Reply), "list_directory({""path"": ""src""})",
            "a call named on the channel was not read");
      Same (Read (Header_Reply), "list_directory({""path"": "".""})",
            "a call named in the header was not read");
      Same (Read (Answer_Reply), "", "an answer was read as a call");
      Same (Read ("<|channel|>commentary to=functions.list_directory json"),
            "error TOOLS_CALL_MALFORMED",
            "a call cut off before its body was not refused");

      declare
         First, Last : Natural;
      begin
         Tools.Spoken_Span (Call_Reply, Tools.Harmony_Call, First, Last);
         Same (Call_Reply (First .. Last), "Look at src first; A < B.",
               "the reasoning before a call was not the turn's words");
      end;

      Same (Tools.Harmony_Answer (Answer_Reply),
            "status: done" & ASCII.LF & "summary: listed",
            "the final channel's message was not the answer");
      Same (Tools.Harmony_Answer (Call_Reply), "",
            "a reply that only called answered something");
      Same (Model_Runner.Agent.Answer_Of (Answer_Reply),
            "status: done" & ASCII.LF & "summary: listed",
            "the agent did not take the final channel as the answer");

      --  And a chat's turn, as the interactive mode keeps it: the final
      --  message for harmony, the reply with its reasoning closed else.
      Same (Model_Runner.Conversation.Reply_Turn
              (Answer_Reply, Tools.Harmony_Call),
            "status: done" & ASCII.LF & "summary: listed",
            "a harmony chat turn kept more than its final message");
      Same (Model_Runner.Conversation.Reply_Turn
              ("<think>" & ASCII.LF & "hm", Tools.Tool_Call_JSON),
            Model_Runner.Conversation.Closed_Reasoning
              ("<think>" & ASCII.LF & "hm"),
            "another chat turn was not its reply with the reasoning closed");

      --  And a turn appended as the template will read it back: the
      --  answer alone, the call's reasoning beside its call.
      declare
         Talk    : Model_Runner.Conversation.History;
         Reading : E.Error_Info;
      begin
         Model_Runner.Conversation.Open (Talk, Status => Status);
         Model_Runner.Conversation.Append
           (Talk, Model_Runner.Conversation.User_Role, "go", Status);
         Model_Runner.Conversation.Append_Reply
           (Talk, Call_Reply, Status, Reading, Syntax => Tools.Harmony_Call,
            Offered => Defs'Unchecked_Access);
         Same (Model_Runner.Conversation.Content_At (Talk, 2),
               "Look at src first; A < B.",
               "a calling turn kept more than its reasoning");
         Assert (Model_Runner.Conversation.Call_Count (Talk, 2) = 1,
                 "a calling turn did not carry its call");
         Model_Runner.Conversation.Append_Reply
           (Talk, Answer_Reply, Status, Reading, Syntax => Tools.Harmony_Call,
            Offered => Defs'Unchecked_Access);
         Same (Model_Runner.Conversation.Content_At (Talk, 3),
               "status: done" & ASCII.LF & "summary: listed",
               "an answering turn kept the channels' markers");
         Model_Runner.Conversation.Close (Talk);
      end;

      Tools.Close (Defs);
   end Harmony_Calls_Are_Read;

   --  Calls read as each family writes them, round 13 of the review:
   --  a Qwen3-Coder value keeps its indent and is typed by its schema;
   --  Llama 3's "parameters" is read; Mistral's [TOOL_CALLS] and
   --  DeepSeek's two forms are read, recognised in a template and held
   --  by the grammar; a MiniCPM reply's words end where its first call
   --  begins; prose, reasoning and a tag's value may hold any tag but
   --  the call's own; a call is read past the reasoning, never in it; an
   --  answer is what follows the first close of the reasoning; a
   --  Functionary recipient is a tool on offer; an object standing open
   --  is a call only where it names one.
   procedure Calls_Are_Read_As_Families_Write_Them
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := ASCII.LF;

      Offer : constant String :=
        "[{""type"": ""function"", ""function"": {""name"": ""edit"", "
        & """parameters"": {""type"": ""object"", ""properties"": {"
        & """old_string"": {""type"": ""string""}, "
        & """version"": {""type"": ""string""}, "
        & """count"": {""type"": ""integer""}, "
        & """flag"": {""type"": ""boolean""}, "
        & """tags"": {""type"": ""array""}}}}}]";

      Defs : aliased Tools.Definitions;

      --  The calls a reply carries in a syntax, as name(arguments) one
      --  after another; or the error it was refused with.
      function Read
        (Reply   : String;
         Syntax  : Tools.Call_Syntax;
         Offered : Boolean := True) return String
      is
         Asked  : Tools.Calls;
         Status : E.Error_Info;
         Said   : Ada.Strings.Unbounded.Unbounded_String;
      begin
         Tools.Read_Calls
           (Asked, Reply, Status, Syntax => Syntax,
            Offered => (if Offered then Defs'Unchecked_Access else null));
         if E.Is_Error (Status) then
            Tools.Close (Asked);
            return "error " & E.Error_Code'Image (Status.Code);
         end if;
         for Index in 1 .. Tools.Count (Asked) loop
            Ada.Strings.Unbounded.Append
              (Said, Tools.Called (Asked, Index) & "("
                     & Tools.Arguments (Asked, Index) & ")");
         end loop;
         Tools.Close (Asked);
         return Ada.Strings.Unbounded.To_String (Said);
      end Read;

      function Span
        (Reply : String; Syntax : Tools.Call_Syntax) return String
      is
         First, Last : Natural;
      begin
         Tools.Spoken_Span (Reply, Syntax, First, Last);
         return Reply (First .. Last);
      end Span;

      procedure Same (Got, Wanted, What : String) is
      begin
         Assert (Got = Wanted, What & ": [" & Got & "] where [" & Wanted
                 & "] was meant");
      end Same;

      Status : E.Error_Info;

      Ds_Fenced : constant String :=
        Tools.DeepSeek_Calls_Begin & Tools.DeepSeek_Call_Begin & "function"
        & Tools.DeepSeek_Sep & "edit" & LF & "```json" & LF
        & "{""count"": 2}" & LF & "```" & Tools.DeepSeek_Call_End
        & Tools.DeepSeek_Calls_End;
      Ds_Plain  : constant String :=
        Tools.DeepSeek_Calls_Begin & Tools.DeepSeek_Call_Begin & "edit"
        & Tools.DeepSeek_Sep & "{""count"": 3}" & Tools.DeepSeek_Call_End
        & Tools.DeepSeek_Calls_End;
   begin
      Tools.Read (Defs, Offer, Status);
      Assert (E.Is_Ok (Status), "the offer would not read");

      --  Qwen3-Coder: one line break either side of a value is the form's;
      --  the rest, and the schema's type, are the value's.
      Same (Read ("<tool_call>" & LF & "<function=edit>" & LF
                  & "<parameter=old_string>" & LF & "    return x" & LF
                  & "</parameter>" & LF
                  & "<parameter=version>" & LF & "3.10" & LF & "</parameter>"
                  & LF & "<parameter=count>" & LF & "42" & LF & "</parameter>"
                  & LF & "<parameter=flag>" & LF & "true" & LF & "</parameter>"
                  & LF & "</function>" & LF & "</tool_call>", Tools.Qwen_XML),
            "edit({""old_string"": ""    return x"", ""version"": ""3.10"", "
            & """count"": 42, ""flag"": true})",
            "a Qwen3-Coder call's values were trimmed or typed by their look");
      Same (Read ("<function=other>" & LF & "<parameter=n>" & LF & "0123" & LF
                  & "</parameter>" & LF & "</function>", Tools.Qwen_XML,
                  Offered => False),
            "other({""n"": ""0123""})",
            "a leading nought was written as a bare number");

      --  Llama 3's own spelling.
      Same (Read ("{""name"": ""edit"", ""parameters"": {""count"": 1}}",
                  Tools.Open_JSON),
            "edit({""count"": 1})",
            "a call under ""parameters"" was not read");

      --  An object naming a tool not offered is the answer's text.
      Same (Read ("{""answer"": {""name"": ""other"", ""arguments"": {}}}",
                  Tools.Open_JSON),
            "", "an object naming no tool on offer was read as a call");

      --  Mistral's, both forms.
      Same (Read ("Sure.[TOOL_CALLS]edit[ARGS]{""count"": 1}"
                  & "[TOOL_CALLS]edit[ARGS]{""count"": 2}", Tools.Mistral_Call),
            "edit({""count"": 1})edit({""count"": 2})",
            "Mistral's [TOOL_CALLS]name[ARGS] calls were not read");
      Same (Read ("[TOOL_CALLS][{""name"": ""edit"", ""arguments"": "
                  & "{""count"": 3}}]", Tools.Mistral_Call),
            "edit({""count"": 3})",
            "Mistral's older list of calls was not read");
      Same (Read ("[TOOL_CALLS]edit{""count"": 1}", Tools.Mistral_Call),
            "error TOOLS_CALL_MALFORMED",
            "a Mistral call with no [ARGS] was not refused");

      --  DeepSeek's, both forms, in either syntax.
      Same (Read ("Let me." & Ds_Fenced, Tools.DeepSeek_Fenced),
            "edit({""count"": 2})", "DeepSeek R1's fenced call was not read");
      Same (Read (Ds_Plain, Tools.DeepSeek_Plain),
            "edit({""count"": 3})", "DeepSeek V3.1's call was not read");
      Same (Read (Ds_Plain, Tools.DeepSeek_Fenced),
            "edit({""count"": 3})",
            "DeepSeek's two forms were not read by one reader");

      --  And the templates that write them recognised.
      Same (Model_Runner.Templates.Recognise
              ("{{ '[TOOL_CALLS]' + name + '[ARGS]' + args }}"),
            Model_Runner.Templates.Mistral_Shape,
            "a Mistral template was not recognised");
      Same (Model_Runner.Templates.Recognise
              ("{{ '" & Tools.DeepSeek_Call_Begin & "' + tool['type'] + '"
               & Tools.DeepSeek_Sep & "' }}"),
            Model_Runner.Templates.DeepSeek_Shape,
            "a DeepSeek R1 template was not recognised");
      Same (Model_Runner.Templates.Recognise
              ("{{ '" & Tools.DeepSeek_Call_Begin & "' + name + '"
               & Tools.DeepSeek_Sep & "' }}"),
            Model_Runner.Templates.DeepSeek_Plain_Shape,
            "a DeepSeek V3.1 template was not recognised");
      Assert (Tools."=" (Model_Runner.Templates.Syntax_Of
                           (Model_Runner.Templates.Mistral_Shape),
                         Tools.Mistral_Call)
              and then Tools."=" (Model_Runner.Templates.Syntax_Of
                                    (Model_Runner.Templates.DeepSeek_Shape),
                                  Tools.DeepSeek_Fenced)
              and then Tools."=" (Model_Runner.Templates.Syntax_Of
                                    (Model_Runner.Templates.DeepSeek_Plain_Shape),
                                  Tools.DeepSeek_Plain),
              "a recognised shape was not read in its own syntax");
      Assert (Model_Runner.Templates.Built_In
                (Model_Runner.Templates.Mistral_Shape) = "",
              "a shape no carried format writes had a template to stand in");

      --  A run reads in the format's syntax, the envelope opened up.
      Assert (Tools."=" (Model_Runner.Templates.Reading_Syntax
                           (Model_Runner.Templates.Format_Name
                              (Model_Runner.Templates.Format_Qwen3_Coder)),
                         Tools.Qwen_XML)
              and then Tools."=" (Model_Runner.Templates.Reading_Syntax (""),
                                  Tools.Open_JSON),
              "a run read calls in a syntax other than its format's");

      --  The grammar holds the new forms as it holds the others.
      Assert (Full_Set_Takes_In
                (Tools.Mistral_Call,
                 "Sure.[TOOL_CALLS]calculator[ARGS]{""a"":47,""op"":""+"","
                 & """b"":89}"),
              "a Mistral call was refused by its grammar");
      Assert (not Full_Set_Takes_In
                (Tools.Mistral_Call,
                 "[TOOL_CALLS]calculator[ARGS]{""a"":47}"),
              "a Mistral call missing arguments was taken");
      Assert (Full_Set_Takes_In
                (Tools.DeepSeek_Fenced,
                 Tools.DeepSeek_Calls_Begin & Tools.DeepSeek_Call_Begin
                 & "function" & Tools.DeepSeek_Sep & "calculator" & LF
                 & "```json" & LF & "{""a"":47,""op"":""+"",""b"":89}" & LF
                 & "```" & Tools.DeepSeek_Call_End & Tools.DeepSeek_Calls_End),
              "a DeepSeek R1 call was refused by its grammar");
      Assert (Full_Set_Takes_In
                (Tools.DeepSeek_Plain,
                 Tools.DeepSeek_Calls_Begin & Tools.DeepSeek_Call_Begin
                 & "calculator" & Tools.DeepSeek_Sep
                 & "{""a"":47,""op"":""+"",""b"":89}" & Tools.DeepSeek_Call_End
                 & Tools.DeepSeek_Calls_End),
              "a DeepSeek V3.1 call was refused by its grammar");

      --  Any tag in prose, reasoning or a value but the call's own.
      Assert (Full_Set_Takes_In
                (Tools.Tool_Call_JSON,
                 "<table><tr><td>a</td></tr></table> List<typename> <"),
              "prose holding <table>, </td> or List<typename> was refused");
      Assert (Full_Set_Takes_In
                (Tools.Qwen_XML,
                 "<think>the old one closed with </div> here</think>" & LF
                 & "<tool_call>" & LF & "<function=write_file>" & LF
                 & "<parameter=path>" & LF & "a.html" & LF & "</parameter>"
                 & LF & "<parameter=content>" & LF & "<div>x</div>" & LF
                 & "</parameter>" & LF & "</function>" & LF & "</tool_call>"),
              "a </div> in reasoning or in a value was refused");
      Assert (Full_Set_Takes_In
                (Tools.Tool_Call_JSON,
                 "std::cout << x << 1; cat <<EOF" & LF & "<<</div>"),
              "prose holding << was refused");
      Assert (Full_Set_Takes_In
                (Tools.Mistral_Call,
                 "[[1, 2], [3, 4]] [[x]][TOOL_CALLS]calculator[ARGS]"
                 & "{""a"":47,""op"":""+"",""b"":89}"),
              "prose holding [[ was refused ahead of a Mistral call");
      Assert (not Full_Set_Takes_In
                (Tools.Tool_Call_JSON, "<tool_call>not a call"),
              "the call's own opener was taken as prose");
      Assert (not Full_Set_Takes_In
                (Tools.Tool_Call_JSON, "a <<tool_call>not a call"),
              "the call's opener after a '<' was taken as prose");
      --  Where an answer schema leaves no prose, reasoning holding a tag.
      Assert (Grammar_Takes_Answer
                ("<think>a </div> b</think>{""answer"":4183}",
                 "{""type"":""object"",""properties"":{""answer"":"
                 & "{""type"":""integer""}},""required"":[""answer""]}"),
              "reasoning holding </div> was refused ahead of a shaped answer");
      --  The rule itself, over two literals: any text that holds neither.
      declare
         Rules : G.Compiled;
         State : G.Matcher;

         function Takes (Text : String) return Boolean is
         begin
            G.Start (Rules, State, Status);
            G.Advance (Rules, State, Text, Status);
            return E.Is_Ok (Status) and then G.Is_Complete (Rules, State);
         end Takes;
      begin
         G.Compile
           (Rules, Model_Runner.Grammar.Excluding ("root", "<ab>" & LF & "<cd>"),
            Status);
         Assert (E.Is_Ok (Status), "the excluding rule would not compile");
         Assert (Takes ("x <a <c <abc <ce > <") and then not Takes ("x <ab> y")
                 and then not Takes ("<<cd>") and then Takes (""),
                 "the excluding rule took a literal or refused other text");
         G.Close (Rules);
      end;

      --  And with nothing offered, any reply at all.
      declare
         None_Offered : Tools.Definitions;
         Rules  : G.Compiled;
         State  : G.Matcher;
      begin
         Tools.Read (None_Offered, "[]", Status);
         Constraint.Compile_Call_Grammar (None_Offered, Rules, Status);
         G.Start (Rules, State, Status);
         G.Advance (Rules, State, "<div>x</div> </tool_call>", Status);
         Assert (E.Is_Ok (Status) and then G.Is_Complete (Rules, State),
                 "a reply with nothing offered was held from a closing tag");
         G.Close (Rules);
         Tools.Close (None_Offered);
      end;

      --  A MiniCPM or Mistral reply's words end at its first call.
      Same (Span ("Let me add." & LF & "<function name=""calculator"">"
                  & "<param name=""a"">1</param></function>",
                  Tools.Function_XML),
            "Let me add.", "a MiniCPM reply's words held its calls");
      Same (Span ("Sure.[TOOL_CALLS]edit[ARGS]{}", Tools.Mistral_Call),
            "Sure.", "a Mistral reply's words held its calls");
      Same (Span ("#include <functional>" & LF & "<function=edit>" & LF
                  & "</function>", Tools.Qwen_XML),
            "#include <functional>",
            "a Qwen reply's words were cut at text that is no call");

      --  A call is read past the reasoning, not in it.
      declare
         Talk    : Model_Runner.Conversation.History;
         Reading : E.Error_Info;
      begin
         Model_Runner.Conversation.Open (Talk, Status => Status);
         Model_Runner.Conversation.Append
           (Talk, Model_Runner.Conversation.User_Role, "go", Status);
         Model_Runner.Conversation.Append_Reply
           (Talk, "<think>I will write a <tool_call> block.</think>" & LF
                  & "<tool_call>{""name"": ""edit"", ""arguments"": "
                  & "{""count"": 1}}</tool_call>",
            Status, Reading, Syntax => Tools.Tool_Call_JSON,
            Offered => Defs'Unchecked_Access);
         Assert (E.Is_Ok (Reading)
                 and then Model_Runner.Conversation.Call_Count
                            (Talk, Model_Runner.Conversation.Length (Talk)) = 1,
                 "a <tool_call> named in the reasoning lost the real call: "
                 & E.Error_Code'Image (Reading.Code));
         Model_Runner.Conversation.Append_Reply
           (Talk, "<think>{""name"": ""edit"", ""arguments"": {}}</think>"
                  & " It is three.",
            Status, Reading, Syntax => Tools.Open_JSON,
            Offered => Defs'Unchecked_Access);
         Assert (Model_Runner.Conversation.Call_Count
                   (Talk, Model_Runner.Conversation.Length (Talk)) = 0,
                 "a call drafted in the reasoning was taken");
         Model_Runner.Conversation.Close (Talk);
      end;

      --  The answer follows the first close; reasoning cut short is none.
      Same (Model_Runner.Agent.Answer_Of ("a</think>b</think>c"), "b</think>c",
            "the answer followed the last close of the reasoning");
      Same (Model_Runner.Agent.Answer_Of ("<think>still thinking"), "",
            "reasoning cut short was taken for the answer");

      --  A recipient is a name, and one on offer.
      Same (Read (">>> import os" & LF & "print (1)", Tools.Recipient_JSON),
            "", "prose after >>> was read as a call");
      Same (Read (">>> import os" & LF & "print (1)", Tools.Recipient_JSON,
                  Offered => False),
            "", "prose after >>> was read as a call where nothing was offered");

      --  Python's other escapes in a Gemma call, as the characters.
      Same (Read ("```tool_code" & LF & "edit(old_string=""a\bb"")" & LF
                  & "```", Tools.Python_Code),
            "edit({""old_string"": ""a\bb""})",
            "a \b in a Python call reached the tool as a backslash and a b");
      Same (Span ("all" & ASCII.CR & LF & "Hello", Tools.Recipient_JSON),
            "Hello", "a recipient of all written with CRLF was not all");
      Tools.Close (Defs);
   end Calls_Are_Read_As_Families_Write_Them;

   --  Reasoning is what opens a reply, as llama.cpp reads it: an answer
   --  that mentions <think> further on, with no close, is an answer -- it
   --  was emptied, and the calls it made dropped -- while a reply that
   --  opens on <think>, after any spaces, and never closes it is none.
   procedure A_Reply_Mentioning_Think_Keeps_Its_Answer
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      LF      : constant String := [1 => ASCII.LF];
      Mention : constant String :=
        "Models write <think> before their reasoning.";
      Status  : E.Error_Info;
      Defs    : aliased Tools.Definitions;
   begin
      Assert (Model_Runner.Agent.Answer_Of (Mention) = Mention,
              "an answer that mentions <think> was taken for reasoning");
      Assert (Model_Runner.Agent.Answer_Of (LF & "  <think>still thinking")
              = "",
              "reasoning opened after spaces and cut short was an answer");

      Tools.Read
        (Defs,
         "[{""type"":""function"",""function"":{""name"":""edit"","
         & """parameters"":{""type"":""object"",""properties"":"
         & "{""count"":{""type"":""integer""}}}}}]",
         Status);
      Assert (E.Is_Ok (Status), "the tool would not read");
      declare
         Talk    : Model_Runner.Conversation.History;
         Reading : E.Error_Info;
      begin
         Model_Runner.Conversation.Open (Talk, Status => Status);
         Model_Runner.Conversation.Append
           (Talk, Model_Runner.Conversation.User_Role, "go", Status);
         Model_Runner.Conversation.Append_Reply
           (Talk, Mention & LF
                  & "<tool_call>{""name"": ""edit"", ""arguments"": "
                  & "{""count"": 1}}</tool_call>",
            Status, Reading, Syntax => Tools.Tool_Call_JSON,
            Offered => Defs'Unchecked_Access);
         Assert (E.Is_Ok (Reading)
                 and then Model_Runner.Conversation.Call_Count
                            (Talk, Model_Runner.Conversation.Length (Talk)) = 1,
                 "a call after an answer mentioning <think> was dropped");
         Model_Runner.Conversation.Append_Reply
           (Talk, "  <think>I will call edit"
                  & "<tool_call>{""name"": ""edit"", ""arguments"": "
                  & "{""count"": 1}}</tool_call>",
            Status, Reading, Syntax => Tools.Tool_Call_JSON,
            Offered => Defs'Unchecked_Access);
         Assert (Model_Runner.Conversation.Call_Count
                   (Talk, Model_Runner.Conversation.Length (Talk)) = 0,
                 "a call inside reasoning that never closed was taken");
         Model_Runner.Conversation.Close (Talk);
      end;
      Tools.Close (Defs);
   end A_Reply_Mentioning_Think_Keeps_Its_Answer;

   --  A Qwen3-Coder value its schema types as other than a string is read
   --  as JSON reads one, the spaces around it none of it: a number written
   --  on a line of its own between more than the one line break either
   --  side stayed the string " 42 ", where the tool asked a number. A
   --  string keeps every space but those two line breaks.
   procedure A_Typed_Qwen_Value_Is_Read_Without_Its_Spaces
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      LF     : constant String := [1 => ASCII.LF];
      Status : E.Error_Info;
      Defs   : aliased Tools.Definitions;
      Asked  : Tools.Calls;
   begin
      Tools.Read
        (Defs,
         "[{""type"":""function"",""function"":{""name"":""edit"","
         & """parameters"":{""type"":""object"",""properties"":"
         & "{""count"":{""type"":""integer""},"
         & """flag"":{""type"":""boolean""},"
         & """list"":{""type"":""array""},"
         & """text"":{""type"":""string""}}}}}]",
         Status);
      Assert (E.Is_Ok (Status), "the tool would not read");
      Tools.Read_Calls
        (Asked,
         "<tool_call>" & LF & "<function=edit>" & LF
         & "<parameter=count>" & LF & "  42 " & LF & "</parameter>" & LF
         & "<parameter=flag>" & LF & " true" & LF & LF & "</parameter>" & LF
         & "<parameter=list>" & LF & "  [1, 2]" & LF & "</parameter>" & LF
         & "<parameter=text>" & LF & "  7 " & LF & "</parameter>" & LF
         & "</function>" & LF & "</tool_call>",
         Status, Syntax => Tools.Qwen_XML,
         Offered => Defs'Unchecked_Access);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1,
              "the call was not read");
      Assert (Tools.Arguments (Asked, 1)
              = "{""count"": 42, ""flag"": true, ""list"": [1, 2], "
                & """text"": ""  7 ""}",
              "the typed values were read with their spaces: "
              & Tools.Arguments (Asked, 1));
      Tools.Close (Asked);
      Tools.Close (Defs);
   end A_Typed_Qwen_Value_Is_Read_Without_Its_Spaces;

   --  The excluding rule takes every text that holds none of its literals
   --  -- and, held not to end on a beginning of one, ends on none -- and
   --  no other, over every text of up to six characters drawn from the
   --  literals' own characters and one more. "<<" and "[[" are among
   --  them: a beginning before a fresh first character was refused, so a
   --  call grammar's prose could hold no C++ shift and no nested list. A
   --  set whose literals hold a first character past their front is
   --  written narrower, and held only to take nothing that holds one.
   procedure Excluding_Takes_What_Holds_No_Literal
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      LF : constant String := [1 => ASCII.LF];

      --  Whether Text holds Literal anywhere.
      function Holds (Text, Literal : String) return Boolean
      is (Ada.Strings.Fixed.Index (Text, Literal) /= 0);

      --  Whether Text ends on a proper, non-empty beginning of Literal.
      function Ends_Begun (Text, Literal : String) return Boolean is
      begin
         for Count in 1 .. Literal'Length - 1 loop
            if Text'Length >= Count
              and then Text (Text'Last - Count + 1 .. Text'Last)
                       = Literal (Literal'First .. Literal'First + Count - 1)
            then
               return True;
            end if;
         end loop;
         return False;
      end Ends_Begun;

      type Text_Access is access constant String;
      type Text_List is array (Positive range <>) of Text_Access;

      procedure Check
        (Literals : Text_List;
         Alphabet : String;
         Exact    : Boolean)
      is
         Joined : Ada.Strings.Unbounded.Unbounded_String;
      begin
         for L of Literals loop
            if Ada.Strings.Unbounded.Length (Joined) > 0 then
               Ada.Strings.Unbounded.Append (Joined, LF);
            end if;
            Ada.Strings.Unbounded.Append (Joined, L.all);
         end loop;

         for Ending in Boolean loop
            declare
               Rules  : G.Compiled;
               State  : G.Matcher;
               Status : E.Error_Info;
               Text   : String (1 .. 6);
               Tried  : Natural := 0;

               function Takes (Item : String) return Boolean is
               begin
                  G.Start (Rules, State, Status);
                  Assert (E.Is_Ok (Status), "the excluding rule would not start");
                  G.Advance (Rules, State, Item, Status);
                  return E.Is_Ok (Status) and then G.Is_Complete (Rules, State);
               end Takes;

               function Wanted (Item : String) return Boolean is
               begin
                  for L of Literals loop
                     if Holds (Item, L.all)
                       or else (not Ending and then Ends_Begun (Item, L.all))
                     then
                        return False;
                     end if;
                  end loop;
                  return True;
               end Wanted;

               procedure Try (Length : Natural) is
                  Item : constant String := Text (1 .. Length);
                  Took : constant Boolean := Takes (Item);
               begin
                  Tried := Tried + 1;
                  if Exact then
                     Assert (Took = Wanted (Item),
                             "the excluding rule over "
                             & Ada.Strings.Unbounded.To_String (Joined)
                             & (if Ending then "" else " (no ending)")
                             & (if Took then " took """ else " refused """)
                             & Item & """");
                  else
                     Assert (not Took or else Wanted (Item),
                             "the narrower excluding rule took """ & Item
                             & """, which holds a literal");
                  end if;
               end Try;

               procedure Walk (Length : Natural) is
               begin
                  Try (Length);
                  if Length < Text'Last then
                     for C of Alphabet loop
                        Text (Length + 1) := C;
                        Walk (Length + 1);
                     end loop;
                  end if;
               end Walk;
            begin
               G.Compile
                 (Rules,
                  G.Excluding
                    ("root", Ada.Strings.Unbounded.To_String (Joined), Ending),
                  Status);
               Assert (E.Is_Ok (Status),
                       "the excluding rule over "
                       & Ada.Strings.Unbounded.To_String (Joined)
                       & " would not compile");
               Walk (0);
               Assert (Tried > 1000, "too few texts were tried");
               G.Close (Rules);
            end;
         end loop;
      end Check;

      Tag   : aliased constant String := "<ab>";
      Other : aliased constant String := "<cd>";
      Close : aliased constant String := "</t>";
      Open  : aliased constant String := "<f=";
      List  : aliased constant String := "[TC]";
      Sign  : aliased constant String := "$";
      Inner : aliased constant String := "a<b";
   begin
      Check ([Tag'Access, Other'Access], "<abcd>", Exact => True);
      Check ([Close'Access, Open'Access], "</tf=", Exact => True);
      Check ([List'Access], "[TC]", Exact => True);
      Check ([Sign'Access, Tag'Access], "$<ab>", Exact => True);
      Check ([Inner'Access, Other'Access], "a<bcd>", Exact => False);
   end Excluding_Takes_What_Holds_No_Literal;

   --  Small helpers that answer as their documentation says: what the
   --  surface check found named by no test once it saw functions.
   procedure Small_Helpers_Answer_As_Said (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Util renames Model_Runner.Tools.Text_Util;
      package Opt renames Model_Runner.CLI.Options;
      LF   : constant Character := ASCII.LF;
      Defs : Tools.Definitions;
      Status : E.Error_Info;

      function Has (Text, Part : String) return Boolean is (Ada.Strings.Fixed.Index (Text, Part) > 0);
   begin
      Assert (Util.Collapse_Blanks ("  a " & ASCII.HT & " b" & LF & " ") = "a b",
              "blanks were not collapsed: [" & Util.Collapse_Blanks ("  a " & ASCII.HT & " b" & LF & " ") & "]");
      Assert (Has (Util.Strip_Tags ("<p>fish &amp; chips</p><p>peas</p>"), "fish & chips")
              and then Has (Util.Strip_Tags ("<p>fish &amp; chips</p><p>peas</p>"), "chips peas"),
              "tags were not taken out, or entities not resolved: "
              & Util.Strip_Tags ("<p>fish &amp; chips</p><p>peas</p>"));
      Assert (Util.To_Valid_Utf8 ("ok" & Character'Val (16#FF#)) = "ok ", "an ill-formed byte was kept");
      Assert (Model_Runner.Text.JSON_Quoted ("a""b\" & LF) = """a\""b\\\n""",
              "a string was not quoted as JSON: " & Model_Runner.Text.JSON_Quoted ("a""b\" & LF));
      Assert (Model_Runner.UTF8.Code_Point_Columns (65) = 1
              and then Model_Runner.UTF8.Code_Point_Columns (16#0301#) = 0
              and then Model_Runner.UTF8.Code_Point_Columns (16#4E00#) = 2,
              "a code point was given the wrong width");
      Assert (Has (Model_Runner.Tools.Schemas.Definition
                     ("count", "count", [Model_Runner.Tools.Schemas.Whole_Number ("n")]), """integer"""),
              "a whole-number parameter was not an integer");
      Tools.Read (Defs, Builtin.Definitions_Text, Status);
      Assert (E.Is_Ok (Status) and then Tools.Tool_Name (Defs, 1) /= ""
              and then Tools.Tool_Name (Defs, Tools.Count (Defs) + 1) = "",
              "a tool's name was not given, or one past the last was");
      Assert (Tools.Spoken_Length ("just words") = 10, "a reply with no call was not spoken whole");
      Assert (Tools.Controls_Escaped ("{""a"": ""x" & LF & "y""}") = "{""a"": ""x\ny""}",
              "a raw line end in a string was not escaped: " & Tools.Controls_Escaped ("{""a"": ""x" & LF & "y""}"));
      Assert (Model_Runner.Video.Half_Even (2.5) = 2 and then Model_Runner.Video.Half_Even (3.5) = 4
              and then Model_Runner.Video.Half_Even (2.4) = 2,
              "a half was not rounded to the even");
      Assert (Model_Runner.Drafts.Alike_Enough (0, 100) and then not Model_Runner.Drafts.Alike_Enough (100, 100),
              "a draft's likeness was misjudged");
      for Kind in Opt.Pooling_Kind loop
         Assert (Has (Opt.Pooling_Names, Opt.Pooling_Word (Kind)), "a pooling was not named");
      end loop;
      Assert (Opt.Cache_Names /= "" and then Opt.Value_Names /= "" and then Has (Opt.Arithmetic_Names, "f32"),
              "the names a caller may give were not said");
      Assert (Model_Runner.Framework.Timestamp_After (60) > Model_Runner.Framework.Timestamp,
              "a moment ahead was not later than now");
   end Small_Helpers_Answer_As_Said;

   --  More helpers, as their documentation says.
   procedure More_Helpers_Answer_As_Said (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Rg renames Model_Runner.Tools.Registry;
      package Ed renames Model_Runner.Tools.Editing;
      package Tr renames Model_Runner.Tools.Runner;
      use type Rg.Path_Use;
      use type Tr.Tool_Context;
      LF : constant Character := ASCII.LF;
      function Has (Text, Part : String) return Boolean is (Ada.Strings.Fixed.Index (Text, Part) > 0);
   begin
      --  The registry: the tools offered by name, a tool's path, whether it
      --  asks the graph, and which findings do.
      Assert (Has (Rg.Offered_Names ([others => True]), "read_file"), "the tools offered were not named");
      Assert (Rg.Path_Of ("read_file") /= Rg.No_Path and then Rg.Path_Of ("no_such_tool") = Rg.No_Path,
              "a tool's path use was not given");
      Assert (not Rg.Asks_Graph ("read_file") and then Rg.Graph_Finding ("symbol")
              and then not Rg.Graph_Finding ("text"),
              "whether a tool or a finding asks the graph was misjudged");

      --  Editing: a path on disk, a durable change's note, declarations.
      Assert (Ed.On_Disk ("/b", "x/y") = "/b/x/y" and then Ed.On_Disk ("", "x") = "x",
              "a path was not placed on disk as said");
      Assert (Ed.Kept_Note ((others => <>)) = "", "a durable change was given a note");
      Assert (Ed.Declarations_In ("procedure A;" & LF & "function B return X;" & LF & "C := 1;" & LF, 1, 3)
                = "A, B",
              "declarations were not named: " & Ed.Declarations_In ("procedure A;" & LF & "function B return X;"
                                                                     & LF & "C := 1;" & LF, 1, 3));

      --  The runner: a task that entered no context has none, and no stop.
      Assert (Tr.Entered_Context = Tr.No_Context and then not Tr.Stop_Now,
              "a task that entered no context had one, or was told to stop");

      --  Documents' text, a letter's first decomposition.
      Assert (Has (Model_Runner.Tools.RTF.Extract_Text ("{\rtf1\ansi hello world}"), "hello world"),
              "an RTF document's text was not read: " & Model_Runner.Tools.RTF.Extract_Text
                                                          ("{\rtf1\ansi hello world}"));
      Assert (Model_Runner.Tokenizer.Folding.First_Of_Decomposition (16#E9#) = 16#65#
              and then Model_Runner.Tokenizer.Folding.First_Of_Decomposition (65) = 65,
              "a letter's decomposition was not begun as Unicode begins it");

      --  The sampler's chain ranks first by top-k, unless greedy.
      Assert (Model_Runner.Sampling.Ranks_First ((others => <>))
              and then not Model_Runner.Sampling.Ranks_First (Model_Runner.Sampling.Greedy_Configuration),
              "whether top-k comes first was misjudged");
   end More_Helpers_Answer_As_Said;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Typed_Qwen_Value_Is_Read_Without_Its_Spaces'Access,
         "a Qwen value typed other than a string is read without the spaces "
         & "around it");
      Register_Routine
        (T, A_Reply_Mentioning_Think_Keeps_Its_Answer'Access,
         "a reply that mentions <think> past its start keeps its answer and "
         & "its calls");
      Register_Routine
        (T, Excluding_Takes_What_Holds_No_Literal'Access,
         "the excluding rule takes every text that holds none of its "
         & "literals and no other, << and [[ among them");
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
        (T, Calls_Are_Read_As_Families_Write_Them'Access,
         "calls are read as Qwen3-Coder, Llama 3, Mistral, DeepSeek, MiniCPM "
         & "and Functionary write them, past the reasoning and not in it");
      Register_Routine
        (T, Harmony_Calls_Are_Read'Access,
         "calls are read as gpt-oss's harmony form writes them, and its "
         & "answer off the final channel");
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
      Register_Routine
        (T, Small_Helpers_Answer_As_Said'Access,
         "small helpers answer as their documentation says");
      Register_Routine
        (T, More_Helpers_Answer_As_Said'Access,
         "more helpers answer as their documentation says");
   end Register_Tests;

end Tests.Tools_Cases;
