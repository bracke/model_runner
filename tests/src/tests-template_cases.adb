with AUnit.Assertions;
with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Streams.Stream_IO;
with Ada.Calendar.Time_Zones;

with Interfaces;

with Model_Runner.CLI.Checkpoint;
with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tools;

package body Tests.Template_Cases is

   use AUnit.Assertions;
   use type Model_Runner.Errors.Error_Code;

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package Tmpl renames Model_Runner.Templates;

   --  Compile Source and report the resulting code.
   function Compile_Status (Source : String) return E.Error_Code is
      Item   : Tmpl.Compiled;
      Status : E.Error_Info;
      Result : E.Error_Code;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      Result := Status.Code;
      Tmpl.Close (Item);
      return Result;
   end Compile_Status;

   --  Compile Source, render it over Messages messages, and report the
   --  resulting code. A construct the compiler carries rather than answers
   --  shows up here and not in Compile_Status.
   function Render_Status
     (Source : String; Messages : Natural := 2) return E.Error_Code;

   --  A conversation of Count alternating messages.
   procedure Fill (Item : in out Conv.History; Count : Natural) is
      Status : E.Error_Info;
   begin
      Conv.Open (Item, Status => Status);
      for Index in 1 .. Count loop
         Conv.Append
           (Item,
            (if Index mod 2 = 1 then Conv.User_Role else Conv.Assistant_Role),
            "m", Status);
      end loop;
   end Fill;

   function Render_Status
     (Source : String; Messages : Natural := 2) return E.Error_Code
   is
      Item    : Tmpl.Compiled;
      Status  : E.Error_Info;
      Talk    : Conv.History;
      Room    : String (1 .. 8192);
      Last    : Natural;
      Result  : E.Error_Code;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      if E.Is_Error (Status) then
         Tmpl.Close (Item);
         return Status.Code;
      end if;

      Fill (Talk, Messages);
      Tmpl.Render (Item, Talk, "<s>", "</s>", True, Room, Last, Status);
      Result := Status.Code;
      Conv.Close (Talk);
      Tmpl.Close (Item);
      return Result;
   end Render_Status;

   --  Today's date as "%d %b %Y" or "%Y-%m-%d" would write it, worked out
   --  here from the calendar rather than asked of the engine, so that the
   --  engine's answer is checked against something it did not compute.
   function Today (Format : String) return String is
      package Fmt renames Ada.Calendar.Formatting;
      Now   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Zone  : constant Ada.Calendar.Time_Zones.Time_Offset :=
        Ada.Calendar.Time_Zones.UTC_Time_Offset (Now);
      Month : constant Ada.Calendar.Month_Number := Fmt.Month (Now, Zone);
      Day   : constant Ada.Calendar.Day_Number := Fmt.Day (Now, Zone);
      Year  : constant Ada.Calendar.Year_Number := Fmt.Year (Now, Zone);
      Names : constant String := "JanFebMarAprMayJunJulAugSepOctNovDec";
      function Two (N : Natural) return String
      is ((if N < 10 then "0" else "")
          & Model_Runner.Text.Trim (Natural'Image (N)));
   begin
      if Format = "%d %b %Y" then
         return Two (Day) & " " & Names (Month * 3 - 2 .. Month * 3) & " "
           & Model_Runner.Text.Trim (Natural'Image (Year));
      else
         return Model_Runner.Text.Trim (Natural'Image (Year)) & "-"
           & Two (Month) & "-" & Two (Day);
      end if;
   end Today;

   --  Nested "for message in messages" blocks, Levels deep.
   function Nested (Levels : Positive) return String is
      Opening : constant String := "{% for message in messages %}";
      Closing : constant String := "{% endfor %}";
      Result  : String (1 .. Levels * (Opening'Length + Closing'Length));
      Used    : Natural := 0;
   begin
      for Level in 1 .. Levels loop
         Result (Used + 1 .. Used + Opening'Length) := Opening;
         Used := Used + Opening'Length;
      end loop;
      for Level in 1 .. Levels loop
         Result (Used + 1 .. Used + Closing'Length) := Closing;
         Used := Used + Closing'Length;
      end loop;
      return Result (1 .. Used);
   end Nested;

   --  A template the program would actually meet compiles and renders.
   --
   --  Without this the refusals below would be satisfied by an engine that
   --  refuses everything.
   --  Each built-in chat format renders the turns its architecture expects.
   --
   --  Written out here rather than derived, because a rendering derived from
   --  the template it is checking agrees with itself. What these strings are
   --  is what a llama3, chatml, gemma or phi3 model was trained to read, and
   --  a format that renders something else produces fluent text answering a
   --  conversation the model was never shown.
   procedure Built_In_Formats_Render_Their_Turns
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := Character'Val (10);

      type Expectation is record
         Which : Tmpl.Chat_Format;
         Text  : access constant String;
      end record;

      Llama3_Text : aliased constant String :=
        "<s><|start_header_id|>user<|end_header_id|>" & LF & LF
        & "hi<|eot_id|><|start_header_id|>assistant<|end_header_id|>" & LF & LF
        & "yo<|eot_id|><|start_header_id|>assistant<|end_header_id|>" & LF & LF;

      ChatML_Text : aliased constant String :=
        "<|im_start|>user" & LF & "hi<|im_end|>" & LF
        & "<|im_start|>assistant" & LF & "yo<|im_end|>" & LF
        & "<|im_start|>assistant" & LF;

      --  The assistant is called "model", which is the whole reason this
      --  format needs a comparison the others do not.
      Gemma_Text : aliased constant String :=
        "<s><start_of_turn>user" & LF & "hi<end_of_turn>" & LF
        & "<start_of_turn>model" & LF & "yo<end_of_turn>" & LF
        & "<start_of_turn>model" & LF;

      Phi3_Text : aliased constant String :=
        "<|user|>" & LF & "hi<|end|>" & LF
        & "<|assistant|>" & LF & "yo<|end|>" & LF
        & "<|assistant|>" & LF;

      --  ChatML's turns exactly, for a conversation of plain messages.
      --  Where this format differs from ChatML is the tool answers, which
      --  this conversation has none of and the case below has.
      Coder_Text : aliased constant String :=
        "<|im_start|>user" & LF & "hi<|im_end|>" & LF
        & "<|im_start|>assistant" & LF & "yo<|im_end|>" & LF
        & "<|im_start|>assistant" & LF;

      --  MiniCPM's plain turns are ChatML's, after a leading bos_token the
      --  model needs; where it differs is the folded tool answers, which the
      --  case below covers.
      MiniCPM_Text : aliased constant String :=
        "<s>"
        & "<|im_start|>user" & LF & "hi<|im_end|>" & LF
        & "<|im_start|>assistant" & LF & "yo<|im_end|>" & LF
        & "<|im_start|>assistant" & LF;

      Wanted : constant array (1 .. 6) of Expectation :=
        [(Tmpl.Format_Llama3, Llama3_Text'Access),
         (Tmpl.Format_ChatML, ChatML_Text'Access),
         (Tmpl.Format_Gemma, Gemma_Text'Access),
         (Tmpl.Format_Phi3, Phi3_Text'Access),
         (Tmpl.Format_Qwen3_Coder, Coder_Text'Access),
         (Tmpl.Format_MiniCPM, MiniCPM_Text'Access)];

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Target   : String (1 .. 512);
      Last     : Natural;
   begin
      --  Every format the enumeration has, so one added without a rendering
      --  here fails rather than passes unexamined.
      Assert (Wanted'Length = Tmpl.Chat_Format'Pos (Tmpl.Chat_Format'Last) + 1,
              "a chat format was added and this test was not told");

      for Each of Wanted loop
         declare
            Name : constant String := Tmpl.Format_Name (Each.Which);
         begin
            Tmpl.Compile (Item, Tmpl.Built_In (Name), Status => Status);
            Assert (E.Is_Ok (Status),
                    "the " & Name & " template did not compile: "
                    & E.Error_Code'Image (Status.Code));

            Conv.Open (Messages, Status => Status);
            Conv.Append (Messages, Conv.User_Role, "hi", Status);
            Conv.Append (Messages, Conv.Assistant_Role, "yo", Status);

            Tmpl.Render
              (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
            Assert (E.Is_Ok (Status),
                    "the " & Name & " template did not render: "
                    & E.Error_Code'Image (Status.Code));
            Assert (Target (1 .. Last) = Each.Text.all,
                    "the " & Name & " format rendered [" & Target (1 .. Last)
                    & "] where [" & Each.Text.all & "] is what that "
                    & "architecture reads");

            Conv.Close (Messages);
            Tmpl.Close (Item);
         end;
      end loop;

      --  Where the Qwen3-Coder format is not ChatML: a run of tool answers
      --  is folded into one user turn, opened before the first and closed
      --  after the last, where ChatML would wrap each of them on its own.
      --  Taken from the template that model ships, which this format exists
      --  because this engine will not compile -- it opens with a macro.
      declare
         Wanted : constant String :=
           "<|im_start|>user" & LF & "P.<|im_end|>" & LF
           & "<|im_start|>user" & LF
           & "<tool_response>" & LF & "a" & LF & "</tool_response>" & LF
           & "<tool_response>" & LF & "b" & LF & "</tool_response>" & LF
           & "<|im_end|>" & LF
           & "<|im_start|>assistant" & LF;
      begin
         Tmpl.Compile
           (Item, Tmpl.Built_In (Tmpl.Format_Name (Tmpl.Format_Qwen3_Coder)),
            Status => Status);
         Assert (E.Is_Ok (Status), "the qwen3-coder format did not compile");

         Conv.Open (Messages, Status => Status);
         Conv.Append (Messages, Conv.User_Role, "P.", Status);
         Conv.Append (Messages, Conv.Tool_Role, "a", Status);
         Conv.Append (Messages, Conv.Tool_Role, "b", Status);

         Tmpl.Render
           (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
         Assert (E.Is_Ok (Status),
                 "the qwen3-coder format did not render tool answers: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Target (1 .. Last) = Wanted,
                 "a run of tool answers rendered [" & Target (1 .. Last)
                 & "] where [" & Wanted & "] is what that model reads");

         Conv.Close (Messages);
         Tmpl.Close (Item);
      end;

      --  Its calls are covered on their own in Qwen3_Coder_Renders_Tool_Calls,
      --  where the tools it offers and the <function=..> call it writes need
      --  a definitions list to render against.

      --  A template compiled into a Compiled that held another answers for
      --  itself. The name table and the slots that point into it are not
      --  storage and were not being released with the storage, so a format
      --  that never mentions tools reported that it reads them when the
      --  template before it did -- and a caller offering tools to such a
      --  format had them dropped rather than being told.
      Tmpl.Compile
        (Item,
         "{% for message in messages %}{% if tools %}x{% endif %}{% endfor %}",
         Status => Status);
      Assert (E.Is_Ok (Status), "the first template did not compile");
      Assert (Tmpl.Reads_Tools (Item),
              "a template naming tools was read as not naming them");

      Tmpl.Compile
        (Item, Tmpl.Built_In (Tmpl.Format_Name (Tmpl.Format_ChatML)),
         Status => Status);
      Assert (E.Is_Ok (Status), "the second template did not compile");
      Assert (not Tmpl.Reads_Tools (Item),
              "a template that never mentions tools reported that it reads "
              & "them, which is the answer the template before it gave");
      Tmpl.Close (Item);
   end Built_In_Formats_Render_Their_Turns;

   --  The minicpm format, unlike qwen3-coder, does write the tool half: the
   --  tools offered as a <tools> block, and a call as a <function> element
   --  whose arguments the params filter turns into <param> children -- the
   --  shape MiniCPM emits and Tools.Read_Calls reads back in Function_XML.
   --  A template's own text names the carried format it is written in.
   --
   --  Each carried format is recognised in its own source -- what Recognise
   --  reads are the markers Built_In writes -- and in the shape a model's
   --  real template takes: Qwen3-Coder's opens its turns the ChatML way and
   --  is told apart by its call form, and a Zephyr-style template shares
   --  Phi3's turn markers without being Phi3. What no carried format is
   --  written in is not recognised as one. And the syntax a format's calls
   --  are read in follows from the name, for every name the build carries.
   procedure Templates_Are_Recognised_By_Their_Markers
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Model_Runner.Tools.Call_Syntax;
   begin
      for Which in Tmpl.Chat_Format loop
         Assert
           (Tmpl.Recognise (Tmpl.Built_In (Tmpl.Format_Name (Which)))
              = Tmpl.Format_Name (Which),
            "the " & Tmpl.Format_Name (Which)
            & " format is recognised in its own source");
      end loop;

      --  The shapes real templates take, reduced to their markers: a
      --  Qwen3-Coder template is ChatML turns plus its call form, a
      --  MiniCPM one ChatML turns plus its own, and a Qwen3 one that
      --  calls in the JSON envelope is ChatML.
      Assert
        (Tmpl.Recognise
           ("<|im_start|>{{ m.role }} {% if tools %}<tool_call>"
            & "<function={{ c.name }}><parameter={{ k }}>{{ v }}"
            & "</parameter></function></tool_call>{% endif %}")
           = "qwen3-coder",
         "ChatML turns with the <function=..> call form are qwen3-coder");
      Assert
        (Tmpl.Recognise
           ("<|im_start|>{{ m.role }} <function name=""{{ c.name }}"">"
            & "<param name=""{{ k }}"">{{ v }}</param></function>")
           = "minicpm",
         "ChatML turns with the <function name=..> call form are minicpm");
      Assert
        (Tmpl.Recognise
           ("<|im_start|>{{ m.role }} <tool_call>{{ c | tojson }}</tool_call>")
           = "chatml",
         "ChatML turns calling in the JSON envelope are chatml");
      Assert
        (Tmpl.Recognise ("<|user|>{{ m.content }}</s><|assistant|>") = "",
         "a Zephyr-style template shares phi3's turn markers and is not "
         & "recognised as phi3");
      Assert
        (Tmpl.Recognise ("[INST] {{ m.content }} [/INST]") = "",
         "a template in no carried format is not recognised as one");
      Assert (Tmpl.Recognise ("") = "", "an empty template is not recognised");

      Assert (Tmpl.Syntax_Of ("qwen3-coder") = Model_Runner.Tools.Qwen_XML,
              "qwen3-coder calls are read as <function=..>");
      Assert (Tmpl.Syntax_Of ("minicpm") = Model_Runner.Tools.Function_XML,
              "minicpm calls are read as <function name=..>");
      Assert (Tmpl.Syntax_Of ("chatml") = Model_Runner.Tools.Tool_Call_JSON,
              "chatml calls are read from the JSON envelope");
      Assert (Tmpl.Syntax_Of ("") = Model_Runner.Tools.Tool_Call_JSON,
              "a model's own template is read from the JSON envelope");
   end Templates_Are_Recognised_By_Their_Markers;

   --  The gemma format offers tools in the first user turn, writes a call
   --  in the <tool_call> JSON envelope, and folds a tool's answer into a
   --  user turn -- Gemma having no system turn and no tool turn of its own.
   --
   --  The system message goes ahead of the tools and both ahead of what the
   --  user said, in the one turn, as the model's own template folds a
   --  system message. Crossed against jinja2 reading the same source on
   --  five conversation shapes, every byte agreeing; what is checked here
   --  is that each part is where the model will look for it.
   procedure Gemma_Renders_Tool_Calls
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF       : constant Character := Character'Val (10);
      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Defs     : aliased Model_Runner.Tools.Definitions;
      Asked    : Model_Runner.Tools.Calls;
      Status   : E.Error_Info;
      Target   : String (1 .. 4096);
      Last     : Natural;

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
   begin
      Model_Runner.Tools.Read
        (Defs,
         "[{""type"": ""function"", ""function"": {""name"": ""calc"", "
         & """description"": ""d"", ""parameters"": {""type"": ""object"", "
         & """properties"": {""a"": {""type"": ""number""}}}}}]",
         Status);
      Assert (E.Is_Ok (Status), "the tool definitions would not read");

      Tmpl.Compile
        (Item, Tmpl.Built_In (Tmpl.Format_Name (Tmpl.Format_Gemma)),
         Status => Status);
      Assert (E.Is_Ok (Status), "the gemma format did not compile");
      Assert (Tmpl.Reads_Tools (Item), "the gemma format does not read tools");

      Conv.Open (Messages, Status => Status);
      Conv.Set_System (Messages, "Be brief.", Status);
      Conv.Append (Messages, Conv.User_Role, "hi", Status);
      Conv.Append_Asking (Messages, "", Status);
      Model_Runner.Tools.Read_Calls
        (Asked,
         "<tool_call>{""name"": ""calc"", ""arguments"": "
         & "{""a"": 47, ""op"": ""*"", ""b"": 89}}</tool_call>",
         Status);
      Conv.Append_Call
        (Messages, Model_Runner.Tools.Called (Asked, 1),
         Model_Runner.Tools.Arguments (Asked, 1), Status);
      Model_Runner.Tools.Close (Asked);
      Conv.Append (Messages, Conv.Tool_Role, "4183", Status);

      Tmpl.Render
        (Item, Messages, "<bos>", "<eos>", True, Target, Last, Status,
         Tools => Defs'Access);
      Assert (E.Is_Ok (Status),
              "the gemma format did not render with tools: "
              & E.Error_Code'Image (Status.Code));

      declare
         R : constant String := Target (1 .. Last);
      begin
         Assert (Has (R, "<bos><start_of_turn>user" & LF & "Be brief." & LF & LF
                          & "You have access to the following functions."),
                 "the system message does not open the first user turn "
                 & "ahead of the tools: " & R);
         Assert (Has (R, "Functions:" & LF & "{""type"": ""function"""),
                 "the tools were not offered as JSON: " & R);
         Assert (Has (R, "}" & LF & LF & "hi<end_of_turn>"),
                 "the user's words do not close the first turn: " & R);
         Assert (not Has (R, "<start_of_turn>system"),
                 "a system turn was written, which Gemma has none of: " & R);
         Assert (Has (R, "<start_of_turn>model" & LF & "<tool_call>" & LF
                          & "{""name"": ""calc"", ""arguments"": "
                          & "{""a"": 47, ""op"": ""*"", ""b"": 89}}" & LF
                          & "</tool_call><end_of_turn>"),
                 "the call was not written in the JSON envelope: " & R);
         Assert (Has (R, "<start_of_turn>user" & LF & "<tool_response>" & LF
                          & "4183" & LF & "</tool_response>" & LF
                          & "<end_of_turn>"),
                 "the tool's answer was not folded into a user turn: " & R);
         Assert (R (R'Last - 20 .. R'Last) = "<start_of_turn>model" & LF,
                 "the generation prompt does not end the rendering: " & R);
      end;

      Conv.Close (Messages);
      Tmpl.Close (Item);
      Model_Runner.Tools.Close (Defs);
   end Gemma_Renders_Tool_Calls;

   procedure MiniCPM_Renders_Tool_Calls
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF       : constant Character := Character'Val (10);
      pragma Unreferenced (LF);
      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Defs     : aliased Model_Runner.Tools.Definitions;
      Asked    : Model_Runner.Tools.Calls;
      Status   : E.Error_Info;
      Target   : String (1 .. 4096);
      Last     : Natural;

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
   begin
      Model_Runner.Tools.Read
        (Defs,
         "[{""type"": ""function"", ""function"": {""name"": ""calc"", "
         & """description"": ""d"", ""parameters"": {""type"": ""object"", "
         & """properties"": {""a"": {""type"": ""number""}}}}}]",
         Status);
      Assert (E.Is_Ok (Status), "the tool definitions would not read");

      Tmpl.Compile
        (Item, Tmpl.Built_In (Tmpl.Format_Name (Tmpl.Format_MiniCPM)),
         Status => Status);
      Assert (E.Is_Ok (Status), "the minicpm format did not compile");

      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, "hi", Status);
      Conv.Append_Asking (Messages, "", Status);
      Model_Runner.Tools.Read_Calls
        (Asked,
         "<tool_call>{""name"": ""calc"", ""arguments"": "
         & "{""a"": 47, ""op"": ""*"", ""b"": 89}}</tool_call>",
         Status);
      Conv.Append_Call
        (Messages, Model_Runner.Tools.Called (Asked, 1),
         Model_Runner.Tools.Arguments (Asked, 1), Status);
      Model_Runner.Tools.Close (Asked);

      Tmpl.Render
        (Item, Messages, "<s>", "</s>", True, Target, Last, Status,
         Tools => Defs'Access);
      Assert (E.Is_Ok (Status),
              "the minicpm format did not render with tools: "
              & E.Error_Code'Image (Status.Code));

      declare
         R : constant String := Target (1 .. Last);
      begin
         Assert (Has (R, "<tools>") and then Has (R, """name"": ""calc"""),
                 "the tools were not offered: " & R);
         Assert (Has (R, "<function name=""calc"">"),
                 "the call was not written as a function element: " & R);
         Assert (Has (R, "<param name=""a"">47</param>"),
                 "a param was not written from the arguments: " & R);
         Assert (Has (R, "<param name=""op"">*</param>"),
                 "the op param was not written: " & R);
      end;

      --  The generation prompt's reasoning block, as MiniCPM's own template
      --  writes it and as the carried qwen3-coder does: opened for a caller
      --  who asked, closed and empty for one who asked it off, absent for
      --  one who said nothing. The carried format wrote none of these, so
      --  --no-think reached a MiniCPM as nothing at all.
      declare
         Nl : constant String := "" & Character'Val (10);
         function Ends (Whole, Tail : String) return Boolean
         is (Whole'Length >= Tail'Length
             and then Whole (Whole'Last - Tail'Length + 1 .. Whole'Last)
                      = Tail);
         function Rendered (Choice : Tmpl.Thinking_Choice) return String is
            Room : String (1 .. 4096);
            Used : Natural;
            St   : E.Error_Info;
         begin
            Tmpl.Render (Item, Messages, "<s>", "</s>", True, Room, Used, St,
                         Thinking => Choice);
            Assert (E.Is_Ok (St), "the format did not render");
            return Room (1 .. Used);
         end Rendered;
         Silent : constant String := Rendered (Tmpl.Thinking_Unstated);
         Asked  : constant String := Rendered (Tmpl.Thinking_On);
         Off    : constant String := Rendered (Tmpl.Thinking_Off);
      begin
         Assert (Ends (Silent, "<|im_start|>assistant" & Nl),
                 "a caller who said nothing got a reasoning block: " & Silent);
         Assert (Ends (Asked, "<|im_start|>assistant" & Nl & "<think>" & Nl),
                 "thinking on did not open the block: " & Asked);
         Assert (Ends (Off, "<|im_start|>assistant" & Nl & "<think>" & Nl & Nl
                            & "</think>" & Nl & Nl),
                 "thinking off did not write the empty block: " & Off);
      end;

      --  And an earlier exchange's reasoning is dropped while the one in
      --  progress keeps its own, which is what the model's own template
      --  does with its last_query_index.
      declare
         Nl     : constant String := "" & Character'Val (10);
         Again  : Conv.History;
         Room   : String (1 .. 4096);
         Used   : Natural;
         St     : E.Error_Info;
      begin
         Conv.Open (Again, Status => St);
         Conv.Append (Again, Conv.User_Role, "q one", St);
         Conv.Append (Again, Conv.Assistant_Role,
                      "<think>" & Nl & "first thoughts" & Nl & "</think>"
                      & Nl & Nl & "First answer.", St);
         Conv.Append (Again, Conv.User_Role, "q two", St);
         Conv.Append (Again, Conv.Assistant_Role,
                      "<think>" & Nl & "second thoughts" & Nl & "</think>"
                      & Nl & Nl & "Second answer.", St);
         Tmpl.Render (Item, Again, "", "", True, Room, Used, St);
         Assert (E.Is_Ok (St), "the two-exchange history did not render");
         Assert (Has (Room (1 .. Used),
                      "<|im_start|>assistant" & Nl & "First answer.<|im_end|>"),
                 "an earlier turn kept its reasoning: " & Room (1 .. Used));
         Assert (not Has (Room (1 .. Used), "first thoughts"),
                 "an earlier turn's reasoning was written: " & Room (1 .. Used));
         Assert (Has (Room (1 .. Used),
                      "<|im_start|>assistant" & Nl & "<think>" & Nl
                      & "second thoughts" & Nl & "</think>" & Nl & Nl
                      & "Second answer.<|im_end|>"),
                 "the current exchange lost its reasoning: " & Room (1 .. Used));
         Conv.Close (Again);
      end;

      Conv.Close (Messages);
      Tmpl.Close (Item);
      Model_Runner.Tools.Close (Defs);
   end MiniCPM_Renders_Tool_Calls;

   --  The qwen3-coder format writes the tool half in its own shape: the tools
   --  offered inside a <tools> block with the model's exact call-format
   --  instructions, and a call as <tool_call><function=name><parameter=k>v
   --  </parameter></function></tool_call> -- the shape Qwen3-Coder emits and
   --  Tools.Read_Calls reads back in Qwen_XML, the qwen_params filter standing
   --  in for that template's arguments mapping-walk.
   procedure Qwen3_Coder_Renders_Tool_Calls
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF       : constant Character := Character'Val (10);
      pragma Unreferenced (LF);
      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Defs     : aliased Model_Runner.Tools.Definitions;
      Asked    : Model_Runner.Tools.Calls;
      Status   : E.Error_Info;
      Target   : String (1 .. 4096);
      Last     : Natural;

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
   begin
      Model_Runner.Tools.Read
        (Defs,
         "[{""type"": ""function"", ""function"": {""name"": ""calc"", "
         & """description"": ""d"", ""parameters"": {""type"": ""object"", "
         & """properties"": {""a"": {""type"": ""number""}}}}}]",
         Status);
      Assert (E.Is_Ok (Status), "the tool definitions would not read");

      Tmpl.Compile
        (Item, Tmpl.Built_In (Tmpl.Format_Name (Tmpl.Format_Qwen3_Coder)),
         Status => Status);
      Assert (E.Is_Ok (Status), "the qwen3-coder format did not compile");

      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, "hi", Status);
      Conv.Append_Asking (Messages, "", Status);
      Model_Runner.Tools.Read_Calls
        (Asked,
         "<tool_call>{""name"": ""calc"", ""arguments"": "
         & "{""a"": 47, ""op"": ""*"", ""b"": 89}}</tool_call>",
         Status);
      Conv.Append_Call
        (Messages, Model_Runner.Tools.Called (Asked, 1),
         Model_Runner.Tools.Arguments (Asked, 1), Status);
      Model_Runner.Tools.Close (Asked);

      Tmpl.Render
        (Item, Messages, "<s>", "</s>", True, Target, Last, Status,
         Tools => Defs'Access);
      Assert (E.Is_Ok (Status),
              "the qwen3-coder format did not render with tools: "
              & E.Error_Code'Image (Status.Code));

      declare
         R  : constant String := Target (1 .. Last);
         Nl : constant String := "" & Character'Val (10);
      begin
         --  The tool as the model's own template writes it: a <function>
         --  element with the schema walked into <parameter> elements, not
         --  the JSON the format used to offer. Crossed against jinja2
         --  reading the model's own template with enums, defaults, nested
         --  items, required lists and a return, byte for byte.
         Assert (Has (R, "<tools>" & Nl & "<function>" & Nl
                      & "<name>calc</name>" & Nl & "<description>d</description>"
                      & Nl & "<parameters>" & Nl & "<parameter>" & Nl
                      & "<name>a</name>" & Nl & "<type>number</type>" & Nl
                      & "</parameter>" & Nl & "</parameters>" & Nl
                      & "</function>" & Nl & "</tools>"),
                 "the tools were not offered as the model writes them: " & R);
         Assert (Has (R, "<function=calc>"),
                 "the call was not written in the qwen3-coder form: " & R);
         Assert (Has (R, "<parameter=a>" & Character'Val (10)
                 & "47" & Character'Val (10) & "</parameter>"),
                 "a parameter was not written from the arguments: " & R);
         Assert (Has (R, "<parameter=op>" & Character'Val (10)
                 & "*" & Character'Val (10) & "</parameter>"),
                 "the op parameter was not written: " & R);
         Assert (Has (R, "</function>" & Character'Val (10) & "</tool_call>"),
                 "the call envelope was not closed: " & R);
      end;

      --  The generation prompt's reasoning block, as Qwen3.5's own
      --  template writes it: opened for a caller who asked, closed and
      --  empty for one who asked it off, and absent -- the prompt
      --  Qwen3-Coder was trained on -- for a caller who said nothing.
      declare
         Nl : constant String := "" & Character'Val (10);
         function Ends (Whole, Tail : String) return Boolean
         is (Whole'Length >= Tail'Length
             and then Whole (Whole'Last - Tail'Length + 1 .. Whole'Last)
                      = Tail);
         function Rendered (Choice : Tmpl.Thinking_Choice) return String is
            Room : String (1 .. 4096);
            Used : Natural;
            St   : E.Error_Info;
         begin
            Tmpl.Render (Item, Messages, "<s>", "</s>", True, Room, Used, St,
                         Thinking => Choice);
            Assert (E.Is_Ok (St), "the format did not render");
            return Room (1 .. Used);
         end Rendered;
         Silent : constant String := Rendered (Tmpl.Thinking_Unstated);
         Asked  : constant String := Rendered (Tmpl.Thinking_On);
         Off    : constant String := Rendered (Tmpl.Thinking_Off);
      begin
         Assert (Ends (Silent, "<|im_start|>assistant" & Nl),
                 "a caller who said nothing got a reasoning block: " & Silent);
         Assert (Ends (Asked, "<|im_start|>assistant" & Nl & "<think>" & Nl),
                 "thinking on did not open the block: " & Asked);
         Assert (Ends (Off, "<|im_start|>assistant" & Nl & "<think>" & Nl & Nl
                            & "</think>" & Nl & Nl),
                 "thinking off did not write the empty block: " & Off);
      end;

      --  And the reasoning an earlier turn carried is not written back,
      --  while the exchange in progress keeps its own -- as Qwen3.5's own
      --  template keeps only what follows the last thing the user said.
      --  Crossed against jinja2 on the same source, byte for byte.
      declare
         Nl     : constant String := "" & Character'Val (10);
         Again  : Conv.History;
         Room   : String (1 .. 4096);
         Used   : Natural;
         St     : E.Error_Info;
      begin
         Conv.Open (Again, Status => St);
         Conv.Append (Again, Conv.User_Role, "q one", St);
         Conv.Append (Again, Conv.Assistant_Role,
                      "<think>" & Nl & "first thoughts" & Nl & "</think>"
                      & Nl & Nl & "First answer.", St);
         Conv.Append (Again, Conv.User_Role, "q two", St);
         Conv.Append (Again, Conv.Assistant_Role,
                      "<think>" & Nl & "second thoughts" & Nl & "</think>"
                      & Nl & Nl & "Second answer.", St);
         Tmpl.Render (Item, Again, "", "", True, Room, Used, St);
         Assert (E.Is_Ok (St), "the two-exchange history did not render");
         Assert (Has (Room (1 .. Used),
                      "<|im_start|>assistant" & Nl & "First answer.<|im_end|>"),
                 "an earlier turn kept its reasoning: " & Room (1 .. Used));
         Assert (not Has (Room (1 .. Used), "first thoughts"),
                 "an earlier turn's reasoning was written: " & Room (1 .. Used));
         Assert (Has (Room (1 .. Used),
                      "<|im_start|>assistant" & Nl & "<think>" & Nl
                      & "second thoughts" & Nl & "</think>" & Nl & Nl
                      & "Second answer.<|im_end|>"),
                 "the current exchange lost its reasoning: " & Room (1 .. Used));
         Conv.Close (Again);
      end;

      Conv.Close (Messages);
      Tmpl.Close (Item);
      Model_Runner.Tools.Close (Defs);
   end Qwen3_Coder_Renders_Tool_Calls;

   --  Arithmetic, the text filters, the date and the template's own
   --  refusal: the constructs that used to be refused where they were
   --  read, each rendered against what the language would write.
   procedure Expressions_Render_As_The_Language_Would
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  What a template renders with two messages, or the code it
      --  refused with, as text.
      function Rendered (Source : String) return String is
         Item   : Tmpl.Compiled;
         Status : E.Error_Info;
         Talk   : Conv.History;
         Room   : String (1 .. 8192);
         Last   : Natural;
      begin
         Tmpl.Compile (Item, Source, Status => Status);
         if E.Is_Error (Status) then
            Tmpl.Close (Item);
            return "compile: " & E.Error_Code'Image (Status.Code);
         end if;
         Fill (Talk, 2);
         Tmpl.Render (Item, Talk, "<s>", "</s>", True, Room, Last, Status);
         Conv.Close (Talk);
         Tmpl.Close (Item);
         if E.Is_Error (Status) then
            return "render: " & E.Error_Code'Image (Status.Code)
              & (if Status.Parameter_Total > 0
                 then " " & Model_Runner.Text.To_String
                              (Status.Parameters (1).Text_Value)
                 else "");
         end if;
         return Room (1 .. Last);
      end Rendered;

      procedure Same (Source, Expected, What : String) is
         Got : constant String := Rendered (Source);
      begin
         Assert (Got = Expected,
                 What & ": " & Source & " rendered (" & Got
                 & ") where the language writes (" & Expected & ")");
      end Same;
   begin
      --  Products bind before sums, brackets bind tightest, and the
      --  language's floor division and remainder round towards minus
      --  infinity together.
      Same ("{{ 2 + 3 * 4 }}", "14", "a product inside a sum");
      Same ("{{ (2 + 3) * 4 }}", "20", "a bracketed sum in a product");
      Same ("{{ 20 - 2 * 3 - 4 }}", "10", "products and minuses mixed");
      Same ("{{ 7 // 2 }}", "3", "floor division");
      Same ("{{ -7 // 2 }}", "-4", "floor division rounds down");
      Same ("{{ -7 % 2 }}", "1", "a remainder pairs with the floor");
      Same ("{{ 8 / 2 }}", "4.0", "a division is binary64, whole or not");
      Same ("{{ 2 * (3 + 4) * 2 }}", "28", "a group in the middle");
      Same ("{{ (messages | length) * 10 + 1 }}", "21",
            "a length in a product");
      Same ("{{ 'a' ~ 1 + 2 ~ 'b' }}", "a12b",
            "a tilde binds before a plus and makes text of it all");
      Same ("{{ (1 + 2) ~ 'b' }}", "3b", "a bracketed sum beside a tilde");
      Same ("{{ 7 / 2 }}", "3.5", "a division that does not come out whole");
      Same ("{{ 0.1 + 0.2 }}|{{ 1.5 + 1 }}|{{ 2.5 * 2 }}|{{ 7.5 // 2 }}"
            & "|{{ 7.5 % 2 }}|{{ 1e16 * 1.0 }}|{{ 1.0e15 }}|{{ 0.00001 * 1 }}"
            & "|{{ 2.0 }}|{{ 1 / 3 }}|{{ -1.5 - 1 }}|{{ [2.5, 1.5, 3] | min }}"
            & "|{{ [2.5, 1.5, 3] | sort | join(',') }}"
            & "|{% if 1.5 > 1 and 0.5 < 1 %}c{% endif %}|{{ '3.7' | int }}"
            & "{{ '3' | float }}{{ 1.25 | tojson }}|{{ 100.0 * 100 }}"
            & "|{% if 1.5 is number %}n{% endif %}",
            "0.30000000000000004|2.5|5.0|3.0|1.5|1e+16|1000000000000000.0"
            & "|1e-05|2.0|0.3333333333333333|-2.5|1.5|1.5,2.5,3|c|33.01.25"
            & "|10000.0|n",
            "numbers that are not whole, written as Python writes them");
      Same ("{{ 7 // (2 - 2) }}",
            "render: TEMPLATE_UNSUPPORTED_CONSTRUCT //",
            "a division by zero");

      --  The text filters, alone and in a chain.
      Same ("{{ 'Hello World' | lower }}", "hello world", "lower");
      Same ("{{ 'Hello World' | upper }}", "HELLO WORLD", "upper");
      Same ("{{ 'hello WORLD' | capitalize }}", "Hello world", "capitalize");
      Same ("{{ 'hello big WORLD' | title }}", "Hello Big World", "title");
      Same ("{{ ' 42x' | int }}", "42", "int reads the leading number");
      Same ("{{ 'x' | string }}", "x", "string is the text as it is");
      Same ("{{ 'x' | safe }}", "x", "safe is the text as it is");
      Same ("{{ '' | default('d') }}", "d", "default stands in for nothing");
      Same ("{{ 'v' | default('d') }}", "v", "default keeps a value");
      Same ("{{ 'a-b-c' | replace('-', '+') }}", "a+b+c", "replace");
      Same ("{{ ' Ab ' | trim | lower | replace('a', 'x') }}", "xb",
            "filters in a chain");
      Same ("{% set n = 5 %}{{ n | int + 1 }}", "6",
            "int makes a number of a name");

      --  The date, checked against a calendar the engine did not read.
      Same ("{{ strftime_now('%d %b %Y') }}", Today ("%d %b %Y"),
            "strftime_now with the directives Llama 3 uses");
      Same ("{{ strftime_now('%Y-%m-%d') }}", Today ("%Y-%m-%d"),
            "strftime_now with numeric directives");
      Same ("{% if strftime_now is defined %}yes{% endif %}", "yes",
            "strftime_now is defined");

      --  The template refusing, in its author's words.
      Same ("{{ raise_exception('System role not supported') }}",
            "render: TEMPLATE_REFUSED System role not supported",
            "raise_exception");

      --  A block set gathers what is written into the name and not the
      --  prompt; a macro is a body run where it is called, its parameters
      --  bound by the call and given back after, defaults and all, and a
      --  macro may call itself.
      Same ("{% set x %}a{{ 1 + 1 }}b{% endset %}[{{ x }}]", "[a2b]",
            "a block set");
      Same ("{% set x %}{% for message in messages %}{{ message.role }}"
            & "{% endfor %}{% endset %}<{{ x | upper }}>",
            "<USERASSISTANT>", "a block set holding a loop, then filtered");
      Same ("{% macro hi(name, mark='!') %}hi {{ name }}{{ mark }}"
            & "{% endmacro %}{{ hi('a') }} {{ hi('b', '?') }}",
            "hi a! hi b?", "a macro with a default parameter");
      Same ("{% macro twice(t) %}{{ t }}{{ t }}{% endmacro %}"
            & "{{ twice('ab') | upper }}", "ABAB", "a macro's text filtered");
      Same ("{% set p = 'outer' %}{% macro m(p) %}{{ p }}{% endmacro %}"
            & "{{ m('inner') }}{{ p }}", "innerouter",
            "a parameter given back after the call");
      Same ("{% macro count(n) %}{{ n }}{% if n > 1 %},"
            & "{{ count(n - 1) }}{% endif %}{% endmacro %}{{ count(4) }}",
            "4,3,2,1", "a macro calling itself");
      Same ("{% macro m() %}x{% endmacro %}{% for message in messages %}"
            & "{{ m() }}{% endfor %}", "xx", "a macro called in a loop");
      Same ("{% macro loop_forever(n) %}{{ loop_forever(n) }}{% endmacro %}"
            & "{{ loop_forever(1) }}",
            "render: TEMPLATE_NESTING_TOO_DEEP loop_forever",
            "a macro that never returns");
   end Expressions_Render_As_The_Language_Would;

   --  The value model: what a template holds that is not text -- a list it
   --  wrote out, a mapping read out of a schema, a turn's calls and their
   --  arguments -- walked, indexed, asked about and written, the way the
   --  language does it. Everything here is a construct Qwen3-Coder's or
   --  MiniCPM's own template uses, and the two are set beside jinja2
   --  reading those templates conversation for conversation.
   procedure Values_Render_As_The_Language_Would
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Defs : aliased Model_Runner.Tools.Definitions;

      --  What a template renders with two messages and one tool whose
      --  schema has an enum, a nested list and a required list, plus a
      --  turn that called it; or the code it refused with, as text.
      function Rendered (Source : String) return String is
         Item   : Tmpl.Compiled;
         Status : E.Error_Info;
         Talk   : Conv.History;
         Asked  : Model_Runner.Tools.Calls;
         Room   : String (1 .. 8192);
         Last   : Natural;
      begin
         Tmpl.Compile (Item, Source, Status => Status);
         if E.Is_Error (Status) then
            Tmpl.Close (Item);
            return "compile: " & E.Error_Code'Image (Status.Code);
         end if;
         Conv.Open (Talk, Status => Status);
         Conv.Append (Talk, Conv.User_Role, "<tool_response>x", Status);
         Conv.Append_Asking (Talk, "Let me see.", Status);
         Model_Runner.Tools.Read_Calls
           (Asked,
            "<tool_call>{""name"": ""calc"", ""arguments"": "
            & "{""a"": 2, ""op"": ""+"", ""tags"": [""x"", ""y""]}}"
            & "</tool_call>",
            Status);
         Conv.Append_Call
           (Talk, Model_Runner.Tools.Called (Asked, 1),
            Model_Runner.Tools.Arguments (Asked, 1), Status);
         Model_Runner.Tools.Close (Asked);
         Conv.Append (Talk, Conv.Tool_Role, "5", Status);
         Tmpl.Render (Item, Talk, "<s>", "</s>", True, Room, Last, Status,
                      Tools => Defs'Access);
         Conv.Close (Talk);
         Tmpl.Close (Item);
         if E.Is_Error (Status) then
            return "render: " & E.Error_Code'Image (Status.Code)
              & (if Status.Parameter_Total > 0
                 then " " & Model_Runner.Text.To_String
                              (Status.Parameters (1).Text_Value)
                 else "");
         end if;
         return Room (1 .. Last);
      end Rendered;

      procedure Same (Source, Expected, What : String) is
         Got : constant String := Rendered (Source);
      begin
         Assert (Got = Expected,
                 What & ": " & Source & " rendered (" & Got
                 & ") where the language writes (" & Expected & ")");
      end Same;

      Status : E.Error_Info;
   begin
      Model_Runner.Tools.Read
        (Defs,
         "[{""type"": ""function"", ""function"": {""name"": ""calc"", "
         & """description"": "" d "", ""parameters"": {""type"": ""object"", "
         & """properties"": {""a"": {""type"": ""integer"", "
         & """description"": ""left""}, ""op"": {""type"": ""string"", "
         & """enum"": [""+"", ""-""]}, ""tags"": {""type"": ""array"", "
         & """items"": {""type"": ""string""}}}, "
         & """required"": [""a"", ""op""]}}}]",
         Status);
      Assert (E.Is_Ok (Status), "the tool definitions would not read");

      --  A list written out is a value: walked, measured, indexed, asked
      --  whether it holds something, and printed as Python prints one.
      Same ("{% set l = ['a', 'b'] %}{{ l }}", "['a', 'b']",
            "a list literal printed");
      Same ("{% set l = [] %}{{ l | length }}", "0", "an empty list");
      Same ("{% set l = [3, 1, 2] %}{{ l | min }}", "1", "min of a list");
      Same ("{% set l = ['a', 'b'] %}{% for x in l %}<{{ x }}>{% endfor %}",
            "<a><b>", "a list literal walked");
      Same ("{% set l = ['a', 'b'] %}{{ l[1] }}{{ l[1 - 1] }}", "ba",
            "a list indexed by a number and by a sum");
      Same ("{% set l = ['a', 'b'] %}{% if 'b' in l %}y{% endif %}"
            & "{% if 'c' not in l %}n{% endif %}", "yn",
            "in and not in on a list");
      Same ("{% set l = [1, 2] %}{% if l is iterable %}i{% endif %}"
            & "{% if l is not mapping %}m{% endif %}"
            & "{% if 'x' is iterable %}t{% endif %}", "imt",
            "is iterable and is mapping on a list and on text");

      --  A tool's schema is a mapping: members by path, walked two names
      --  at a time with items, asked whether they are there, written
      --  with tojson.
      Same ("{% for t in tools %}{{ t.function.name }}"
            & "{{ t.function.parameters.properties.a.type }}{% endfor %}",
            "calcinteger", "members along a path");
      Same ("{% for t in tools %}{% for k, v in "
            & "t.function.parameters.properties | items %}{{ k }}="
            & "{{ v.type }};{% endfor %}{% endfor %}",
            "a=integer;op=string;tags=array;", "a mapping walked with items");
      Same ("{% for t in tools %}{% for k in "
            & "t.function.parameters.properties %}{{ k }}{% endfor %}"
            & "{% endfor %}", "aoptags", "a mapping walked yields its keys");
      Same ("{% for t in tools %}{% set p = t.function.parameters %}"
            & "{% if p is mapping %}m{% endif %}"
            & "{% if p.required is defined %}r{% endif %}"
            & "{% if p.nothing is defined %}!{% endif %}"
            & "{{ p.required | length }}{% endfor %}", "mr2",
            "a mapping asked about and assigned by value");
      Same ("{% for t in tools %}{% for e in "
            & "t.function.parameters.properties.op.enum %}`{{ e }}`"
            & "{% endfor %}{{ t.function.parameters.properties.tags.items "
            & "| tojson }}{% endfor %}",
            "`+``-`{""type"": ""string""}",
            "a list inside a schema walked and a member written as JSON");
      Same ("{% for t in tools %}{{ t.function.description | trim }}"
            & "{{ t.function.parameters.properties.a.type | string }}"
            & "{% endfor %}", "dinteger", "filters on schema members");
      Same ("{% for t in tools %}{% if t.function is defined %}"
            & "{% set t = t.function %}{% endif %}{{ t.name }}{% endfor %}",
            "calc", "a loop's name rebound to its own member");

      --  A turn's calls and their arguments walked the same way, and the
      --  loop's neighbours read through loop.previtem and loop.nextitem.
      Same ("{% for message in messages %}{% if message.tool_calls is "
            & "defined and message.tool_calls is iterable %}"
            & "{% for c in message.tool_calls %}{{ c.name }}("
            & "{% for k, v in c.arguments | items %}{{ k }}={{ v }},"
            & "{% endfor %}){% endfor %}{% endif %}{% endfor %}",
            "calc(a=2,op=+,tags=['x', 'y'],)",
            "a call's arguments walked and written");
      Same ("{% for message in messages %}{% if message.role == 'tool' %}"
            & "{% if loop.previtem and loop.previtem.role != 'tool' %}"
            & "[{% endif %}{{ message.content }}"
            & "{% if loop.last or loop.nextitem.role != 'tool' %}]"
            & "{% endif %}{% endif %}{% endfor %}", "[5]",
            "the neighbours of a loop's item");
      Same ("{% for message in messages[::-1] %}{{ message.role[0] }}"
            & "{% endfor %}", "tau", "the conversation walked backwards");
      Same ("{% for m in messages %}{{ loop.index }}{% for n in messages %}"
            & "{{ loop.index }}{% endfor %}{% endfor %}",
            "112321233123", "a loop inside a loop, each with its own count");

      --  Text methods with variables, and the string methods a template
      --  takes a reply apart with.
      Same ("{% set m = '<tool_response>' %}{% if messages[0].content"
            & ".startswith(m) %}s{% endif %}{% if not messages[0].content"
            & ".endswith('x') %}!{% endif %}", "s",
            "startswith and endswith with a variable");
      Same ("{% set d = 'A' %}{{ 'a-a'.replace('a', d) }}"
            & "{{ 'b'.replace('b', 'c' ~ 'd') }}", "A-Acd",
            "replace with a variable and an expression");
      Same ("{% set parts = 'a<s>b<s>c'.split('<s>') %}{{ parts[0] }}"
            & "{{ parts | length }}{{ parts[-1] }}", "a3c",
            "a cut kept whole, indexed and measured");

      --  A name assigned inside a loop's body is the body's own and the
      --  name outside is untouched, as the language scopes it; a
      --  namespace's field is what a loop assigns for after.
      Same ("{% set x = 'o' %}{% for m in messages %}{% set x = 'i' %}"
            & "{% endfor %}{{ x }}", "o", "a set in a loop does not leak");
      Same ("{% set ns = namespace(x='o') %}{% for m in messages %}"
            & "{% set ns.x = 'i' %}{% endfor %}{{ ns.x }}", "i",
            "a namespace field set in a loop is kept");
      Same ("{% for m in messages %}{% set x %}{{ m.role }}{% endset %}"
            & "{{ x }}{% endfor %}[{% if x is defined %}!{% endif %}]",
            "userassistanttool[]",
            "a block set inside a loop");

      --  A tag closed with -%} strips what follows it, in a macro as
      --  anywhere else.
      Same ("{% if true -%}   x{% endif %}", "x", "-%} strips the text after");
      Same ("{% macro m(l) %}{% for i in l -%}  <{{ i }}>{% endfor -%}"
            & " {% endmacro %}{{ m(['a', 'b']) }}", "<a><b>",
            "a list passed to a macro and -%} inside it");

      --  A comparison or test is a value: printed as Python prints a
      --  truth, assigned, compared with another, and true and false and
      --  none print as Python prints them.
      Same ("[{{ 1 == 1 }}][{{ nothing is defined }}][{{ true }}]"
            & "[{{ false }}][{{ none }}][{{ 'ab'.startswith('a') }}]",
            "[True][False][True][False][None][True]",
            "truths printed as Python prints them");
      Same ("{% set ok = 1 == 2 %}{% if ok %}T{% else %}F{% endif %}"
            & "{{ ok }}{{ ok | tojson }}", "FFalsefalse",
            "a comparison assigned and read back");
      Same ("{% if (1 == 1) != (2 == 3) %}y{% endif %}"
            & "{% if (1 == 1) == (2 == 3) %}n{% endif %}"
            & "{% if not (1 == 2) and (3 == 3) %}z{% endif %}", "yz",
            "two bracketed conditions compared");

      --  A choice written inside an expression, which is how Gemma's
      --  template puts a system message in front of the first turn only.
      Same ("{% for m in messages %}{{ m.role + ('!' if loop.first else '') }}"
            & "{% endfor %}", "user!assistanttool",
            "a choice inside a sum");
      Same ("{% set p = 'x' %}{{ (p if false) }}[{{ (p if true) }}]", "[x]",
            "a choice without an else");

      --  Positions and members chained after a term, however it began.
      Same ("{% set l = [['b', 'c'], 'd'] %}{{ l[0][1] }}{{ l[1][0] }}"
            & "{{ messages[0].role[0] }}{{ messages[0]['content'][0] }}"
            & "{{ 'a|b'.split('|')[1].upper() }}"
            & "{% for t in tools %}{{ t.function.parameters.properties"
            & ".op.enum[1] }}{{ t['function'].name }}{% endfor %}",
            "cdu<B-calc", "an index after an index, a path or a cut");

      --  A macro's body reads the names outside it and keeps its own
      --  assignments to itself, as the language scopes it.
      Same ("{% set x = 'o' %}{% macro m() %}{{ x }}{% set x = 'i' %}"
            & "{{ x }}{% endmacro %}{{ m() }}{{ x }}", "oio",
            "a macro reads outer names and its sets stay inside");

      --  A number is a number: written, counted, measured, read out of a
      --  schema or assigned, it adds where text runs together, and it is
      --  not the text of itself.
      Same ("{% set i = 1 %}{{ i + 1 }}{% set j = i %}{{ j + i }}"
            & "{% set t = '1' %}{{ t + '1' }}{{ t ~ i }}"
            & "{% if i == '1' %}!{% endif %}{% if i == 1 %}y{% endif %}"
            & "{% if t == '1' %}z{% endif %}"
            & "{% if i is number and t is not number %}n{% endif %}"
            & "{% if i is string %}!{% endif %}{% if (i | string) is string %}s"
            & "{% endif %}{{ messages | length + 1 }}{{ '7' | int + 1 }}",
            "221111yzns48", "numbers kept apart from text");
      Same ("{% for t in tools %}{{ t.function.parameters.properties.a"
            & ".minimum + 1 }}{% endfor %}{% set l = [1, 2] %}{{ l[0] + l[1] }}"
            & "{% for i in range(2) %}{{ i + 10 }}{% endfor %}"
            & "{% for m in messages %}{{ loop.index + 100 }}{% endfor %}",
            "131011101102103", "numbers read out, counted and looped");
      Same ("{% set i = 1 %}{% set i = 'a' %}{{ i + '1' }}", "a1",
            "a name reassigned text runs together");

      --  The list filters, on lists written out and on the conversation,
      --  a mapping written out with its methods, break and continue,
      --  loop.length and loop.revindex, a filter block, and a call block
      --  with caller(). Every one of these is crossed against jinja2.
      Same ("{% set l = ['b', 'a', 'c', 'a'] %}{{ l | join(', ') }}|"
            & "{{ l | sort | join }}|{{ l | sort(reverse=True) | join }}|"
            & "{{ l | unique | join }}|{{ [3, 1, 2] | sort | join('-') }}|"
            & "{{ l | select('equalto', 'a') | list | length }}|"
            & "{{ l | reject('equalto', 'a') | join }}|"
            & "{{ 'abc' | list | join('.') }}|"
            & "{{ ['B', 'a', 'C'] | sort | join }}"
            & "{{ ['B', 'a', 'C'] | sort(case_sensitive=True) | join }}",
            "b, a, c, a|aabc|cbaa|bac|1-2-3|2|bc|a.b.c|aBCBCa",
            "the list filters on a list written out");
      Same ("{{ messages | map(attribute='role') | join(',') }}|"
            & "{{ messages | selectattr('role', 'equalto', 'user')"
            & " | map(attribute='content') | join('+') }}|"
            & "{{ messages | rejectattr('role', 'equalto', 'user') | list"
            & " | length }}|{{ (messages | first).role }}|"
            & "{{ (messages | last)['role'] }}|"
            & "{{ messages | selectattr('role', 'in', ['user', 'tool'])"
            & " | list | length }}|{{ messages | last | tojson }}",
            "user,assistant,tool|<tool_response>x|2|user|tool|2|"
            & "{""role"": ""tool"", ""content"": ""5""}",
            "the list filters on the conversation");
      Same ("{% set d = {'a': 1, 'b': 'x', 'c': [1, 2], 'd': {'e': true}} %}"
            & "{{ d }}|{{ d | tojson }}|{{ d.a + 1 }}|{{ d.keys() | join(',') }}"
            & "|{{ d.values() | length }}|{{ d.get('b') }}{{ d.get('z', 'n') }}"
            & "|{% for k, v in d | dictsort %}{{ k }};{% endfor %}"
            & "|{% for k, v in {'z': 1, 'a': 2} | dictsort(by='value',"
            & " reverse=True) %}{{ k }}{% endfor %}"
            & "|{% for a, b in [[1, 2], [3, 4]] %}{{ a + b }}{% endfor %}",
            "{'a': 1, 'b': 'x', 'c': [1, 2], 'd': {'e': True}}|"
            & "{""a"": 1, ""b"": ""x"", ""c"": [1, 2], ""d"": {""e"": true}}"
            & "|2|a,b,c,d|4|xn|a;b;c;d;|az|37",
            "a mapping written out, its methods and pairs unpacked");
      Same ("{% for i in range(5) %}{% if i == 1 %}{% continue %}{% endif %}"
            & "{% if i == 3 %}{% break %}{% endif %}{{ i }}{% endfor %}|"
            & "{% for m in messages %}{{ loop.length }}{{ loop.revindex }}"
            & "{{ loop.revindex0 }}{% endfor %}|"
            & "{% for i in range(2, 9, 3) %}{{ loop.revindex }}{% endfor %}|"
            & "{% filter upper %}ab{{ 'c' }}{% endfilter %}",
            "02|332321310|321|ABC",
            "break, continue, loop.length, loop.revindex and a filter block");
      Same ("{% macro box(t) %}<{{ t }}>{{ caller() }}</{{ t }}>{% endmacro %}"
            & "{% call box('b') %}in {{ 1 + 1 }}{% endcall %}"
            & "{% call box('x') %}{% call box('n') %}deep{% endcall %}"
            & "{% endcall %}", "<b>in 2</b><x><n>deep</n></x>",
            "a call block and caller(), nested");
      Same ("{{ 'a\nb\n\nc' | indent(2) }}|{{ 'ab' | indent(1, first=True) }}"
            & "|{{ 'a|b'.split('|')[1].upper() }}{{ 'Ab'.lower() }}"
            & "|{% set l = ['a', none, true] %}{{ l | reject('none')"
            & " | join(',') }}|{{ True }}{{ None }}",
            "a" & Character'Val (10) & "  b" & Character'Val (10)
            & Character'Val (10) & "  c| ab|Bab|a,True|TrueNone",
            "indent, the case methods, null read out, capitalised words");

      --  The text filters that shape output, with blocks, raw blocks and
      --  do statements that grow a list or a mapping in place -- each
      --  crossed against jinja2 by `tests cross --expressions`.
      Same ("{{ 'ab' | center(5) }}|{{ 'hello world foo' | truncate(9) }}|"
            & "{{ 'Hello world this is a test' | wordwrap(10) }}|"
            & "{{ '%s is %d and %.2f %%' | format('x', 3, 1.5) }}|"
            & "{{ '<b>hi</b> <i>there</i>  x' | striptags }}|{{ 'x' | pprint }}"
            & "|{{ 'abc' | reverse }}{{ [1, 2, 3] | reverse | list | tojson }}"
            & "|{{ [1, 5, 3] | max }}{{ [{'n': 2}, {'n': 5}] | max(attribute='n') }}",
            "  ab |hello...|Hello" & Character'Val (10) & "world this"
            & Character'Val (10) & "is a test|x is 3 and 1.50 %|hi there x"
            & "|'x'|cba[3, 2, 1]|5{'n': 5}",
            "the text filters that shape output");
      Same ("{% with a = 1, b = 'x' %}{{ a }}{{ b }}{% set a = 2 %}{{ a }}"
            & "{% endwith %}[{% if a is defined %}!{% endif %}]"
            & "{% set a = 9 %}{% with a = 1 %}{{ a }}{% endwith %}{{ a }}"
            & "|{% raw %}{{ not rendered }} {% if %}{% endraw %}"
            & "|{% set l = [] %}{% do l.append(1) %}{% do l.extend([2, 3]) %}"
            & "{{ l }}{% set d = {'a': 1} %}{% do d.update({'b': 2}) %}{{ d }}"
            & "{% do 1 + 1 %}|{% set ns = namespace(items=[]) %}"
            & "{% for m in messages %}{% do ns.items.append(m.role) %}"
            & "{% endfor %}{{ ns.items | join(',') }}",
            "1x2[]19|{{ not rendered }} {% if %}|[1, 2, 3]{'a': 1, 'b': 2}"
            & "|user,assistant,tool",
            "with, raw and do");

      --  A loop over a name never assigned is refused as the output
      --  refuses it, and a field a turn has not got is nothing.
      Same ("{% for x in nothing %}x{% endfor %}",
            "render: TEMPLATE_UNKNOWN_VARIABLE nothing",
            "a loop over a name never assigned");
      Same ("{{ messages[0].nothing }}[{% if messages[0].nothing is defined %}"
            & "!{% endif %}]", "[]", "a field a turn has not got");

      Model_Runner.Tools.Close (Defs);
   end Values_Render_As_The_Language_Would;

   --  The carried qwen3-coder, minicpm and gemma formats are the same
   --  bytes as the models' own templates, and the engine can say so
   --  itself now that it renders all three: each format and the model's
   --  own file, read from fixtures, rendered on the same conversations
   --  and compared byte for byte. The model's own file is what jinja2
   --  was crossed against, so this is the crossing kept in the suite.
   procedure Carried_Formats_Match_The_Models_Own_Templates
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Defs : aliased Model_Runner.Tools.Definitions;

      --  A file's bytes, every one: what a record of renderings is read
      --  as, where a line break at the end is a byte like any other.
      function Raw_File_Text (Path : String) return String is
         Held : Ada.Streams.Stream_IO.File_Type;
      begin
         Ada.Streams.Stream_IO.Open
           (Held, Ada.Streams.Stream_IO.In_File, Path);
         declare
            Size : constant Natural :=
              Natural (Ada.Streams.Stream_IO.Size (Held));
            Room : String (1 .. Size);
         begin
            String'Read (Ada.Streams.Stream_IO.Stream (Held), Room);
            Ada.Streams.Stream_IO.Close (Held);
            return Room;
         end;
      end Raw_File_Text;

      --  A template file's text, less the line break a file ends with
      --  and a template written as one line does not.
      function File_Text (Path : String) return String is
         Whole : constant String := Raw_File_Text (Path);
      begin
         if Whole'Length > 0 and then Whole (Whole'Last) = Character'Val (10)
         then
            return Whole (Whole'First .. Whole'Last - 1);
         end if;
         return Whole;
      end File_Text;

      --  The published templates with no carried format beside them.
      type File_Name is access constant String;
      Published : constant array (1 .. 2) of File_Name :=
        [new String'("fixtures/gpt-oss-own.jinja"),
         new String'("fixtures/qwen36-own.jinja")];

      --  Every template with jinja2's renderings recorded beside it.
      type Recording is record
         Template    : File_Name;
         Record_File : File_Name;
      end record;
      Recorded : constant array (1 .. 5) of Recording :=
        [(new String'("fixtures/qwen3-coder-own.jinja"),
          new String'("fixtures/qwen3-coder-own.render")),
         (new String'("fixtures/minicpm-own.jinja"),
          new String'("fixtures/minicpm-own.render")),
         (new String'("fixtures/gemma3-own.jinja"),
          new String'("fixtures/gemma3-own.render")),
         (new String'("fixtures/qwen36-own.jinja"),
          new String'("fixtures/qwen36-own.render")),
         (new String'("fixtures/gpt-oss-own.jinja"),
          new String'("fixtures/gpt-oss-own.render"))];

      --  One conversation, built the same way for both templates.
      type Shape is
        (Plain, With_System, Tools_No_System, Tools_With_System,
         Call_With_Text, Call_Without_Text, Two_Calls, Reply_No_Prompt,
         Reasoning, Nested_Arguments, Wrapped_User, Two_Systems, Developer,
         Parts_Content, Reply_Parts, Tool_Parts);

      procedure Build (Talk : in out Conv.History; Which : Shape) is
         Asked  : Model_Runner.Tools.Calls;
         Status : E.Error_Info;
      begin
         Conv.Open (Talk, Status => Status);
         case Which is
            when Plain =>
               Conv.Append (Talk, Conv.User_Role, "hi", Status);
            when With_System =>
               Conv.Set_System (Talk, "Be brief.", Status);
               Conv.Append (Talk, Conv.User_Role, "hi", Status);
            when Tools_With_System =>
               Conv.Set_System (Talk, "Be brief.", Status);
               Conv.Append (Talk, Conv.User_Role, "add", Status);
            when Tools_No_System =>
               Conv.Append (Talk, Conv.User_Role, "add 2 and 3", Status);
            when Call_With_Text | Call_Without_Text =>
               --  The two call turns `tests cross` hands jinja2, to the
               --  byte: one with text before the call and two answers
               --  and a question after it, one with neither.
               Conv.Append (Talk, Conv.User_Role, "add", Status);
               Conv.Append_Asking
                 (Talk, (if Which = Call_With_Text
                         then "  Let me compute.  " else ""), Status);
               Model_Runner.Tools.Read_Calls
                 (Asked,
                  (if Which = Call_With_Text
                   then "<tool_call>{""name"": ""calc"", ""arguments"": "
                        & "{""a"": 2, ""op"": ""+"", ""b"": 3}}</tool_call>"
                   else "<tool_call>{""name"": ""calc"", ""arguments"": "
                        & "{""a"": 2, ""op"": ""*"", ""b"": 3, ""exact"": true}}"
                        & "</tool_call>"),
                  Status);
               Conv.Append_Call
                 (Talk, Model_Runner.Tools.Called (Asked, 1),
                  Model_Runner.Tools.Arguments (Asked, 1), Status);
               Model_Runner.Tools.Close (Asked);
               if Which = Call_With_Text then
                  Conv.Append (Talk, Conv.Tool_Role, "5", Status);
                  Conv.Append (Talk, Conv.Tool_Role, "5 again", Status);
                  Conv.Append (Talk, Conv.User_Role, "thanks", Status);
               else
                  Conv.Append (Talk, Conv.Tool_Role, "6", Status);
               end if;
            when Two_Calls =>
               Conv.Append (Talk, Conv.User_Role, "add", Status);
               Conv.Append_Asking (Talk, "", Status);
               Model_Runner.Tools.Read_Calls
                 (Asked,
                  "<tool_call>{""name"": ""calc"", ""arguments"": "
                  & "{""a"": 1, ""op"": ""+"", ""b"": 1}}</tool_call>"
                  & "<tool_call>{""name"": ""weather"", ""arguments"": "
                  & "{""city"": ""Odense""}}</tool_call>",
                  Status);
               for C in 1 .. 2 loop
                  Conv.Append_Call
                    (Talk, Model_Runner.Tools.Called (Asked, C),
                     Model_Runner.Tools.Arguments (Asked, C), Status);
               end loop;
               Model_Runner.Tools.Close (Asked);
               Conv.Append (Talk, Conv.Tool_Role, "2", Status);
               Conv.Append (Talk, Conv.Tool_Role, "rain", Status);
               Conv.Append (Talk, Conv.Assistant_Role, "done", Status);
            when Reply_No_Prompt =>
               Conv.Append (Talk, Conv.User_Role, "hi", Status);
               Conv.Append (Talk, Conv.Assistant_Role, "yo", Status);
            when Reasoning =>
               Conv.Append (Talk, Conv.User_Role, "q1", Status);
               Conv.Append
                 (Talk, Conv.Assistant_Role,
                  "<think>" & Character'Val (10) & "first"
                  & Character'Val (10) & "</think>" & Character'Val (10)
                  & Character'Val (10) & "A1", Status);
               Conv.Append (Talk, Conv.User_Role, "q2", Status);
               Conv.Append
                 (Talk, Conv.Assistant_Role,
                  "<think>" & Character'Val (10) & "second"
                  & Character'Val (10) & "</think>" & Character'Val (10)
                  & Character'Val (10) & "A2", Status);
            when Nested_Arguments =>
               Conv.Append (Talk, Conv.User_Role, "go", Status);
               Conv.Append_Asking (Talk, "", Status);
               Model_Runner.Tools.Read_Calls
                 (Asked,
                  "<tool_call>{""name"": ""calc"", ""arguments"": "
                  & "{""a"": {""x"": 1, ""y"": [true, null]}, "
                  & """l"": [1, ""two""], ""s"": ""str"", ""n"": 2.5}}"
                  & "</tool_call>",
                  Status);
               Conv.Append_Call
                 (Talk, Model_Runner.Tools.Called (Asked, 1),
                  Model_Runner.Tools.Arguments (Asked, 1), Status);
               Model_Runner.Tools.Close (Asked);
               Conv.Append (Talk, Conv.Tool_Role, "{""ok"": true}", Status);
            when Wrapped_User =>
               Conv.Append
                 (Talk, Conv.User_Role,
                  "<tool_response>" & Character'Val (10) & "from before"
                  & Character'Val (10) & "</tool_response>", Status);
               Conv.Append (Talk, Conv.Assistant_Role, "noted", Status);
               Conv.Append
                 (Talk, Conv.User_Role, "<tool_response>x</tool_response>",
                  Status);
            when Two_Systems =>
               Conv.Set_System (Talk, "First.", Status);
               Conv.Append (Talk, Conv.System_Role, "Second.", Status);
               Conv.Append (Talk, Conv.User_Role, "hi", Status);
            when Developer =>
               Conv.Append
                 (Talk, Conv.Developer_Role, "Answer tersely.", Status);
               Conv.Append (Talk, Conv.User_Role, "hi", Status);
            when Parts_Content =>
               Conv.Append_Parts
                 (Talk, Conv.User_Role,
                  "[{""type"": ""image""}, {""type"": ""text"", ""text"": "
                  & """ what is this ""}, {""type"": ""video""}]", Status);
            when Reply_Parts =>
               Conv.Append (Talk, Conv.User_Role, "hi", Status);
               Conv.Append_Parts
                 (Talk, Conv.Assistant_Role,
                  "[{""type"": ""text"", ""text"": "" a cat ""}, "
                  & "{""type"": ""image""}]", Status);
               Conv.Append (Talk, Conv.User_Role, "sure?", Status);
            when Tool_Parts =>
               Conv.Append (Talk, Conv.User_Role, "weather?", Status);
               Conv.Append_Asking (Talk, "", Status);
               Model_Runner.Tools.Read_Calls
                 (Asked,
                  "<tool_call>{""name"": ""weather"", ""arguments"": "
                  & "{""city"": ""Aarhus""}}</tool_call>",
                  Status);
               Conv.Append_Call
                 (Talk, Model_Runner.Tools.Called (Asked, 1),
                  Model_Runner.Tools.Arguments (Asked, 1), Status);
               Model_Runner.Tools.Close (Asked);
               Conv.Append_Parts
                 (Talk, Conv.Tool_Role,
                  "[{""type"": ""text"", ""text"": ""12 C""}, "
                  & "{""type"": ""image""}]", Status);
         end case;
         Assert (E.Is_Ok (Status), "the conversation would not build");
      end Build;

      --  Choices says whether the caller's thinking choice is tried too,
      --  and Thoughts whether a history carrying <think> blocks is: the
      --  carried qwen3-coder format writes both as Qwen3.5's template
      --  does, which Qwen3-Coder's own says nothing about. Tooled says
      --  whether the conversations with tools are: Gemma's own template
      --  has no tool half, and the carried format's is this build's own.
      procedure Compare
        (Format    : Tmpl.Chat_Format; Own_File : String;
         Choices   : Boolean;
         Thoughts  : Boolean;
         Tooled    : Boolean := True)
      is
         use type Tmpl.Thinking_Choice;
         Carried, Own : Tmpl.Compiled;
         Status       : E.Error_Info;
      begin
         Tmpl.Compile
           (Carried, Tmpl.Built_In (Tmpl.Format_Name (Format)),
            Status => Status);
         Assert (E.Is_Ok (Status), "the carried format did not compile");
         Tmpl.Compile (Own, File_Text (Own_File), Status => Status);
         Assert (E.Is_Ok (Status),
                 "the model's own template did not compile: "
                 & E.Error_Code'Image (Status.Code));

         for Which in Shape loop
            for Choice in Tmpl.Thinking_Choice loop
               if (Choices or else Choice = Tmpl.Thinking_Unstated)
                 and then (Thoughts or else Which /= Reasoning)
                 and then (Tooled
                           or else Which not in Tools_No_System
                                     | Tools_With_System | Call_With_Text
                                     | Call_Without_Text | Two_Calls
                                     | Nested_Arguments)
               then
                  declare
                     Talk       : Conv.History;
                     Tooled     : constant Boolean :=
                       Which in Tools_No_System | Tools_With_System
                                | Call_With_Text | Call_Without_Text
                                | Two_Calls | Nested_Arguments | Tool_Parts;
                     Generation : constant Boolean :=
                       Which not in Two_Calls | Reply_No_Prompt;
                     A, B       : String (1 .. 8192);
                     A_Last, B_Last : Natural;
                     Status_A, Status_B : E.Error_Info;
                  begin
                     Build (Talk, Which);
                     Tmpl.Render
                       (Carried, Talk, "<s>", "</s>", Generation,
                        A, A_Last, Status_A, Thinking => Choice,
                        Tools => (if Tooled then Defs'Access else null));
                     Tmpl.Render
                       (Own, Talk, "<s>", "</s>", Generation,
                        B, B_Last, Status_B, Thinking => Choice,
                        Tools => (if Tooled then Defs'Access else null));
                     Conv.Close (Talk);
                     --  A conversation the model's own template refuses
                     --  in its author's words -- Gemma's insists the
                     --  roles alternate -- or by adding words to a list
                     --  of parts, as Qwen3-Coder's does, is one the
                     --  carried format refuses the same way, unless it is
                     --  a tool turn, which the carried format takes and
                     --  its model never saw.
                     if E."=" (Status_B.Code, E.Template_Refused)
                       or else E."=" (Status_B.Code,
                                      E.Template_Unsupported_Construct)
                     then
                        Assert (E."=" (Status_A.Code, Status_B.Code)
                                or else Tooled,
                                Tmpl.Format_Name (Format) & " rendered "
                                & Shape'Image (Which)
                                & " where the model's own template refuses it");
                        goto Next_Case;
                     end if;
                     Assert (E.Is_Ok (Status_A),
                             Tmpl.Format_Name (Format) & " did not render "
                             & Shape'Image (Which) & ": "
                             & E.Error_Code'Image (Status_A.Code));
                     Assert (E.Is_Ok (Status_B),
                             "the model's own " & Tmpl.Format_Name (Format)
                             & " template did not render "
                             & Shape'Image (Which) & ": "
                             & E.Error_Code'Image (Status_B.Code));
                     Assert (A (1 .. A_Last) = B (1 .. B_Last),
                             "the carried " & Tmpl.Format_Name (Format)
                             & " format and the model's own template differ on "
                             & Shape'Image (Which) & " "
                             & Tmpl.Thinking_Choice'Image (Choice)
                             & ": carried (" & A (1 .. A_Last) & ") own ("
                             & B (1 .. B_Last) & ")");
                  end;
               end if;
               <<Next_Case>>
            end loop;
         end loop;

         Tmpl.Close (Carried);
         Tmpl.Close (Own);
      end Compare;

      Status : E.Error_Info;
   begin
      Model_Runner.Tools.Read
        (Defs,
         "[{""type"": ""function"", ""function"": {""name"": ""calc"", "
         & """description"": "" Evaluate a binary arithmetic operation. "", "
         & """parameters"": {""type"": ""object"", ""properties"": {"
         & """a"": {""type"": ""integer"", ""description"": ""left operand""}, "
         & """op"": {""type"": ""string"", ""enum"": [""+"", ""-"", ""*"", ""/""], "
         & """description"": ""the operator""}, ""b"": {""type"": ""integer""}, "
         & """exact"": {""type"": ""boolean"", ""default"": false, ""minimum"": 0}, "
         & """tags"": {""type"": ""array"", ""items"": {""type"": ""string""}}}, "
         & """required"": [""a"", ""op"", ""b""]}, ""return"": {""type"": ""number""}}}, "
         & "{""type"": ""function"", ""function"": {""name"": ""weather"", "
         & """description"": ""Look up the weather."", ""parameters"": {"
         & """type"": ""object"", ""properties"": {""city"": {""type"": ""string"", "
         & """description"": ""which city"", ""enum"": [""Aarhus"", ""Odense""], "
         & """required"": [""city""]}}}}}]",
         Status);
      Assert (E.Is_Ok (Status), "the tool definitions would not read");

      Compare (Tmpl.Format_Qwen3_Coder, "fixtures/qwen3-coder-own.jinja",
               Choices => False, Thoughts => False);
      Compare (Tmpl.Format_MiniCPM, "fixtures/minicpm-own.jinja",
               Choices => True, Thoughts => True);
      Compare (Tmpl.Format_Gemma, "fixtures/gemma3-own.jinja",
               Choices => False, Thoughts => True, Tooled => False);

      --  And two published templates this build carries no format for,
      --  rendered on every shape without a refusal: what `tests cross`
      --  sets beside jinja2, kept where a checkout runs it.
      for Which in Shape loop
         for File of Published loop
            declare
               Own    : Tmpl.Compiled;
               Talk   : Conv.History;
               Room   : String (1 .. 8192);
               Last   : Natural;
               Status : E.Error_Info;
               Tooled : constant Boolean :=
                 Which in Tools_No_System | Tools_With_System
                          | Call_With_Text | Call_Without_Text | Two_Calls
                          | Nested_Arguments | Tool_Parts;
            begin
               Tmpl.Compile (Own, File_Text (File.all), Status => Status);
               Assert (E.Is_Ok (Status),
                       File.all & " did not compile: "
                       & E.Error_Code'Image (Status.Code));
               Build (Talk, Which);
               Tmpl.Render
                 (Own, Talk, "<s>", "</s>",
                  Which not in Two_Calls | Reply_No_Prompt,
                  Room, Last, Status,
                  Tools => (if Tooled then Defs'Access else null));
               Conv.Close (Talk);
               Tmpl.Close (Own);
               --  gpt-oss adds words to the content, so a list of parts
               --  is refused -- as jinja2 refuses it, with a TypeError --
               --  in a user's turn and in a reply alike.
               if Which in Parts_Content | Reply_Parts
                 and then File.all = "fixtures/gpt-oss-own.jinja"
               then
                  Assert (E."=" (Status.Code,
                                 E.Template_Unsupported_Construct),
                          File.all & " took a list of parts as words");
               else
                  Assert (E.Is_Ok (Status),
                          File.all & " refused " & Shape'Image (Which) & ": "
                          & E.Error_Code'Image (Status.Code));
               end if;
            end;
         end loop;
      end loop;

      --  The branches for content that is a list of parts -- an image, a
      --  video, a text -- with literal lists in hand, apart from the turn
      --  given as parts above: Qwen3.6's render_content macro is called
      --  from the end of its own file with such a list, and Gemma 3's
      --  branch is written out with one. Both are set beside jinja2 by
      --  `tests cross --expressions`, the same lists in hand.
      declare
         Own    : Tmpl.Compiled;
         Talk   : Conv.History;
         Room   : String (1 .. 8192);
         Last   : Natural;
         Status : E.Error_Info;
         Tail   : constant String :=
           "|{% set add_vision_id = true %}{{ render_content([{'type': "
           & "'image'}, {'text': ' t '}, {'video': 1}, {'image_url': 'u'}], "
           & "true) }}|{{ image_count.value }}{{ video_count.value }}"
           & "|{{ render_content('plain', false) }}"
           & "|{{ render_content(none, false) }}|";
         Wanted : constant String :=
           "|Picture 1: <|vision_start|><|image_pad|><|vision_end|> t "
           & "Video 1: <|vision_start|><|video_pad|><|vision_end|>"
           & "Picture 2: <|vision_start|><|image_pad|><|vision_end|>|21"
           & "|plain||";
         Gemma_Branch : constant String :=
           "{%- set content = [{'type': 'image'}, {'type': 'text', "
           & "'text': ' hello '}] -%}{%- if content is string -%}"
           & "{{ content | trim }}{%- elif content is iterable -%}"
           & "{%- for item in content -%}{%- if item['type'] == 'image' -%}"
           & "{{ '<start_of_image>' }}{%- elif item['type'] == 'text' -%}"
           & "{{ item['text'] | trim }}{%- endif -%}{%- endfor -%}"
           & "{%- else -%}{{ raise_exception(""Invalid content type"") }}"
           & "{%- endif -%}";
      begin
         Tmpl.Compile
           (Own, File_Text ("fixtures/qwen36-own.jinja") & Tail,
            Status => Status);
         Assert (E.Is_Ok (Status), "the Qwen3.6 template with a tail did "
                 & "not compile: " & E.Error_Code'Image (Status.Code));
         Build (Talk, Plain);
         Tmpl.Render (Own, Talk, "<s>", "</s>", False, Room, Last, Status);
         Conv.Close (Talk);
         Tmpl.Close (Own);
         Assert (E.Is_Ok (Status), "render_content over a list refused: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Last >= Wanted'Length
                 and then Room (Last - Wanted'Length + 1 .. Last) = Wanted,
                 "render_content over a list of parts wrote: "
                 & Room (1 .. Last));

         Tmpl.Compile (Own, Gemma_Branch, Status => Status);
         Assert (E.Is_Ok (Status), "Gemma's parts branch did not compile");
         Build (Talk, Plain);
         Tmpl.Render (Own, Talk, "<s>", "</s>", False, Room, Last, Status);
         Conv.Close (Talk);
         Tmpl.Close (Own);
         Assert (E.Is_Ok (Status) and then Room (1 .. Last)
                   = "<start_of_image>hello",
                 "Gemma's parts branch wrote: " & Room (1 .. Last));
      end;

      --  A model's own template that writes message['content'] -- adding it
      --  to text, as MiniCPM-V's does -- renders a picture's parts inline:
      --  the words and the picture's marker where it stands, when the caller
      --  hands Render the marker. Without a marker the add is refused, as it
      --  was, rather than run together as the parts' spelling.
      declare
         Talk   : Conv.History;
         Status : E.Error_Info;
         Own    : Tmpl.Compiled;
         Room   : String (1 .. 8192);
         Last   : Natural;
         Body_T : constant String :=
           "{% for message in messages %}"
           & "{{ '[' + message['content'] + ']' }}{% endfor %}";
         Parts  : constant String :=
           "[{""type"": ""image""}, {""type"": ""text"", ""text"": ""hi""}]";
      begin
         Conv.Open (Talk, Status => Status);
         Conv.Append_Parts (Talk, Conv.User_Role, Parts, Status);
         Assert (E.Is_Ok (Status), "the parts turn was refused");

         Tmpl.Compile (Own, Body_T, Status => Status);
         Assert (E.Is_Ok (Status), "the content-adding template did not compile");
         Tmpl.Render (Own, Talk, "<s>", "</s>", False, Room, Last, Status,
                      Image_Marker => "<IMG>");
         Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "[<IMG>hi]",
                 "content parts did not render inline: "
                 & (if E.Is_Ok (Status) then Room (1 .. Last)
                    else E.Error_Code'Image (Status.Code)));

         --  With no marker the add of text and a parts list is refused.
         Tmpl.Render (Own, Talk, "<s>", "</s>", False, Room, Last, Status);
         Assert (Status.Code = E.Template_Unsupported_Construct,
                 "adding text to parts without a marker was not refused");
         Tmpl.Close (Own);
         Conv.Close (Talk);
      end;

      --  A turn given as parts reads as its words wherever text is wanted,
      --  keeps its list for the template, survives a checkpoint, and is
      --  refused when the list is not one.
      declare
         Talk   : Conv.History;
         Again  : Conv.History;
         Loaded : Boolean := False;
         Status : E.Error_Info;
         Parts  : constant String :=
           "[{""type"": ""image""}, {""type"": ""text"", ""text"": ""what""},"
           & " {""type"": ""text"", ""text"": "" is\nthis""}]";
         File   : constant String := "parts-checkpoint.bin";
      begin
         Assert (Conv.Text_Of_Parts (Parts) = "what is" & ASCII.LF & "this",
                 "the words of the parts read as: "
                 & Conv.Text_Of_Parts (Parts));
         Assert (Conv.Text_Of_Parts ("[{""type"": ""image""}]") = "",
                 "a picture alone has words");
         --  Every escape the language has, and a surrogate pair as the
         --  one character it spells.
         Assert (Conv.Unescaped ("a\""b\\c\/d\be\ff\u00e9\ud83d\ude00")
                   = "a""b\c/d" & ASCII.BS & "e" & ASCII.FF & "f"
                     & Character'Val (16#C3#) & Character'Val (16#A9#)
                     & Character'Val (16#F0#) & Character'Val (16#9F#)
                     & Character'Val (16#98#) & Character'Val (16#80#),
                 "the escapes of a JSON string were undone wrongly: "
                 & Conv.Unescaped ("a\""b\\c\/d\be\ff\u00e9\ud83d\ude00"));
         Assert (Conv.Unescaped ("\ud83d x\u12") = " xu12",
                 "a lone surrogate or a short escape was not dropped: "
                 & Conv.Unescaped ("\ud83d x\u12"));
         Assert (Conv.Text_Of_Parts
                   ("[{""type"": ""text"", ""text"": ""say \""hi\"" \u2014""}]")
                   = "say ""hi"" " & Character'Val (16#E2#)
                     & Character'Val (16#80#) & Character'Val (16#94#),
                 "a part's text with escapes reads wrongly");

         Conv.Open (Talk, Status => Status);
         Conv.Append_Parts (Talk, Conv.User_Role, "what", Status);
         Assert (E."=" (Status.Code, E.Conversation_Empty),
                 "parts that are not a list were taken");
         Conv.Append_Parts (Talk, Conv.User_Role, "[]", Status);
         Assert (E."=" (Status.Code, E.Conversation_Empty),
                 "an empty list of parts was taken");
         Conv.Append_Parts (Talk, Conv.User_Role, Parts, Status);
         Assert (E.Is_Ok (Status), "a list of parts was refused");
         Assert (Conv.Length (Talk) = 1
                 and then Conv.Content_At (Talk, 1)
                   = "what is" & ASCII.LF & "this"
                 and then Conv.Parts_At (Talk, 1) = Parts,
                 "the turn given as parts does not read as both");
         Conv.Append (Talk, Conv.Assistant_Role, "a cat", Status);
         Assert (Conv.Parts_At (Talk, 2) = "",
                 "a turn given as words has parts");

         Model_Runner.CLI.Checkpoint.Save (File, Talk);
         Conv.Open (Again, Status => Status);
         Model_Runner.CLI.Checkpoint.Load (File, Again, Loaded, Status);
         Assert (Loaded and then E.Is_Ok (Status),
                 "the checkpoint with a turn of parts did not load");
         Assert (Conv.Length (Again) = 2
                 and then Conv.Parts_At (Again, 1) = Parts
                 and then Conv.Content_At (Again, 1)
                   = "what is" & ASCII.LF & "this"
                 and then Conv.Content_At (Again, 2) = "a cat",
                 "the turn of parts did not survive the checkpoint");
         Conv.Close (Again);
         Conv.Close (Talk);
         Ada.Directories.Delete_File (File);
      end;

      --  And what jinja2 rendered from each of the five, recorded by
      --  `tests cross --record` with these tokens, compared byte for byte
      --  here, where no Python is needed: a record a case, the
      --  conversation's number, the caller's thinking choice, the byte
      --  count -- minus one where jinja2 refused, and then this engine
      --  must refuse too -- and the bytes. A template writing the date
      --  is compared with the day it was recorded read as today.
      for File of Recorded loop
         declare
            Whole   : constant String := Raw_File_Text (File.Record_File.all);
            Own     : Tmpl.Compiled;
            Status  : E.Error_Info;
            Cursor  : Natural := Whole'First;
            Dated   : String (1 .. 10) := [others => ' '];
            Cases   : Natural := 0;

            function Line_End (From : Natural) return Natural is
               At_LF : Natural := From;
            begin
               while At_LF <= Whole'Last
                 and then Whole (At_LF) /= Character'Val (10)
               loop
                  At_LF := At_LF + 1;
               end loop;
               return At_LF;
            end Line_End;

            --  The recording's date replaced by today's, wherever it
            --  stands.
            function Redated (Text : String) return String is
               R : Ada.Strings.Unbounded.Unbounded_String;
               I : Natural := Text'First;
               Now : constant String := Today ("%Y-%m-%d");
            begin
               while I <= Text'Last loop
                  if I + 9 <= Text'Last and then Text (I .. I + 9) = Dated then
                     Ada.Strings.Unbounded.Append (R, Now);
                     I := I + 10;
                  else
                     Ada.Strings.Unbounded.Append (R, Text (I));
                     I := I + 1;
                  end if;
               end loop;
               return Ada.Strings.Unbounded.To_String (R);
            end Redated;
         begin
            Tmpl.Compile (Own, File_Text (File.Template.all), Status => Status);
            Assert (E.Is_Ok (Status), File.Template.all & " did not compile");

            while Cursor <= Whole'Last loop
               declare
                  Stop : constant Natural := Line_End (Cursor);
                  Line : constant String := Whole (Cursor .. Stop - 1);
               begin
                  Cursor := Stop + 1;
                  if Line'Length > 5 and then Line (Line'First .. Line'First + 4)
                                             = "date "
                  then
                     Dated := Line (Line'First + 5 .. Line'First + 14);
                  elsif Line'Length > 5
                    and then Line (Line'First .. Line'First + 4) = "case "
                  then
                     declare
                        Scan : Natural := Line'First + 5;
                        Number, Bytes : Integer;
                        Choice : Tmpl.Thinking_Choice;
                        First, Last : Natural;

                        procedure Word is
                        begin
                           First := Scan;
                           while Scan <= Line'Last and then Line (Scan) /= ' '
                           loop
                              Scan := Scan + 1;
                           end loop;
                           Last := Scan - 1;
                           Scan := Scan + 1;
                        end Word;
                     begin
                        Word;
                        Number := Integer'Value (Line (First .. Last));
                        Word;
                        Choice :=
                          (if Line (First .. Last) = "think"
                           then Tmpl.Thinking_On
                           elsif Line (First .. Last) = "no-think"
                           then Tmpl.Thinking_Off
                           else Tmpl.Thinking_Unstated);
                        Word;
                        Bytes := Integer'Value (Line (First .. Last));

                        declare
                           Which   : constant Shape := Shape'Val (Number - 1);
                           Wanted  : constant String :=
                             (if Bytes < 0 then ""
                              else Whole (Cursor .. Cursor + Bytes - 1));
                           Talk    : Conv.History;
                           Room    : String (1 .. 16384);
                           Filled  : Natural;
                           Tooled  : constant Boolean :=
                             Which in Tools_No_System | Tools_With_System
                                      | Call_With_Text | Call_Without_Text
                                      | Two_Calls | Nested_Arguments
                                      | Tool_Parts;
                        begin
                           Cursor := Cursor + Integer'Max (Bytes, 0) + 1;
                           Cases := Cases + 1;
                           Build (Talk, Which);
                           Tmpl.Render
                             (Own, Talk, "<s>", "</s>",
                              Which not in Two_Calls | Reply_No_Prompt,
                              Room, Filled, Status, Thinking => Choice,
                              Tools => (if Tooled then Defs'Access else null));
                           Conv.Close (Talk);
                           if Bytes < 0 then
                              Assert (E.Is_Error (Status),
                                      File.Template.all & " rendered "
                                      & Shape'Image (Which)
                                      & " where jinja2 refused it");
                           else
                              Assert (E.Is_Ok (Status),
                                      File.Template.all & " refused "
                                      & Shape'Image (Which) & ": "
                                      & E.Error_Code'Image (Status.Code));
                              Assert (Room (1 .. Filled) = Redated (Wanted),
                                      File.Template.all & " on "
                                      & Shape'Image (Which) & " "
                                      & Tmpl.Thinking_Choice'Image (Choice)
                                      & " rendered (" & Room (1 .. Filled)
                                      & ") where jinja2 rendered ("
                                      & Redated (Wanted) & ")");
                           end if;
                        end;
                     end;
                  end if;
               end;
            end loop;
            Tmpl.Close (Own);
            Assert (Cases >= 16, File.Record_File.all & " holds too few cases");
         end;
      end loop;

      Model_Runner.Tools.Close (Defs);
   end Carried_Formats_Match_The_Models_Own_Templates;

   procedure Ordinary_Template_Renders
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        "{% for message in messages %}<|{{ message.role }}|>"
        & "{{ message.content }}{% endfor %}"
        & "{% if add_generation_prompt %}<|assistant|>{% endif %}";

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Target   : String (1 .. 256);
      Last     : Natural;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "an ordinary template did not compile: "
              & E.Error_Code'Image (Status.Code));
      Assert (Tmpl.Is_Compiled (Item), "a compiled template says it is not");

      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, "hi", Status);
      Conv.Append (Messages, Conv.Assistant_Role, "yo", Status);

      Tmpl.Render
        (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (E.Is_Ok (Status),
              "rendering failed: " & E.Error_Code'Image (Status.Code));
      Assert (Target (1 .. Last) = "<|user|>hi<|assistant|>yo<|assistant|>",
              "rendered the wrong text: " & Target (1 .. Last));

      --  The generation prompt is a value the caller supplies, not a constant.
      Tmpl.Render
        (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
      Assert (E.Is_Ok (Status), "rendering without a generation prompt failed");
      Assert (Target (1 .. Last) = "<|user|>hi<|assistant|>yo",
              "add_generation_prompt was ignored: " & Target (1 .. Last));

      --  Close is idempotent, and a closed template renders nothing.
      Tmpl.Close (Item);
      Tmpl.Close (Item);
      Assert (not Tmpl.Is_Compiled (Item),
              "a closed template still says it is compiled");

      Tmpl.Render
        (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (Status.Code = E.Template_Missing,
              "a closed template rendered anyway: "
              & E.Error_Code'Image (Status.Code));
      Assert (Last = 0, "a failed render reported bytes written");

      Conv.Close (Messages);
   end Ordinary_Template_Renders;

   --  The shape of the template a current model actually ships.
   --
   --  A Llama-3 file opens with four blocks that ask whether names exist,
   --  give them values when they do not, lift the system message out of the
   --  conversation by slicing it off the front, and describe tool calling in
   --  branches a conversation of plain messages never enters. None of that
   --  is exotic; all of it was outside the subset, and a stock model could
   --  not be chatted with until it was not.
   --
   --  This is written here rather than copied from a model file so that the
   --  test owns what it tests. Every construct below is one that file uses.
   procedure Model_Shaped_Template_Renders
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := Character'Val (10);

      Source : constant String :=
        "{{- bos_token }}"
        & "{%- if custom_tools is defined %}"
        & "{%- set tools = custom_tools %}"
        & "{%- endif %}"
        & "{%- if not date_string is defined %}"
        & "{%- if strftime_now is defined %}"
        & "{%- set date_string = strftime_now(""%d %b %Y"") %}"
        & "{%- else %}"
        & "{%- set date_string = ""26 Jul 2024"" %}"
        & "{%- endif %}"
        & "{%- endif %}"
        & "{%- if not tools is defined %}"
        & "{%- set tools = none %}"
        & "{%- endif %}"
        & "{#- lift the system message out so it can be slotted in #}"
        & "{%- if messages[0]['role'] == 'system' %}"
        & "{%- set system_message = messages[0]['content']|trim %}"
        & "{%- set messages = messages[1:] %}"
        & "{%- else %}"
        & "{%- set system_message = """" %}"
        & "{%- endif %}"
        & "{{- ""<|system|>"" }}"
        & "{%- if tools is not none %}"
        & "{{- ""Environment: ipython"" }}"
        & "{%- endif %}"
        & "{{- ""Today: "" + date_string + "" "" }}"
        & "{%- if tools is not none and not tools_in_user_message %}"
        & "{{- raise_exception(""no tools here"") }}"
        & "{%- endif %}"
        & "{{- system_message }}"
        & "{{- ""<|end|>"" }}"
        & "{%- for message in messages %}"
        & "{%- if not (message.role == 'ipython' or message.role == 'tool'"
        & " or 'tool_calls' in message) %}"
        & "{{- '<|' + message['role'] + '|>' + message['content'] | trim"
        & " + '<|end|>' }}"
        & "{%- elif 'tool_calls' in message %}"
        & "{{- message.tool_calls[0] | tojson }}"
        & "{%- endif %}"
        & "{%- endfor %}"
        & "{%- if add_generation_prompt %}"
        & "{{- '<|assistant|>' }}"
        & "{%- endif %}";

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Target   : String (1 .. 1024);
      Last     : Natural;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "a template shaped like a model's own did not compile: "
              & E.Error_Code'Image (Status.Code));

      --  Without a system message. The name messages still means the whole
      --  conversation, date_string is today's date -- strftime_now is
      --  defined, so the template's own fallback is not taken -- and the
      --  tool branches are never entered.
      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, " Hi ", Status);
      Tmpl.Render (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (E.Is_Ok (Status),
              "rendering failed: " & E.Error_Code'Image (Status.Code));
      Assert (Target (1 .. Last)
              = "<s><|system|>Today: " & Today ("%d %b %Y") & " <|end|>"
                & "<|user|>Hi<|end|><|assistant|>",
              "rendered the wrong text: " & Target (1 .. Last));
      Conv.Close (Messages);

      --  With one. The system message is lifted out of the conversation and
      --  placed in the block the model expects it in, and the loop that
      --  follows must not render it a second time -- which is exactly what
      --  the slice is for, and exactly what breaks when it is ignored.
      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.System_Role, "  Be brief.  ", Status);
      Conv.Append (Messages, Conv.User_Role, "Hi", Status);
      Conv.Append (Messages, Conv.Assistant_Role, "Yo", Status);
      Tmpl.Render (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (E.Is_Ok (Status),
              "rendering with a system message failed: "
              & E.Error_Code'Image (Status.Code));
      Assert (Target (1 .. Last)
              = "<s><|system|>Today: " & Today ("%d %b %Y") & " Be brief.<|end|>"
                & "<|user|>Hi<|end|><|assistant|>Yo<|end|><|assistant|>",
              "rendered the wrong text: " & Target (1 .. Last));
      Conv.Close (Messages);

      Tmpl.Close (Item);
      pragma Unreferenced (LF);
   end Model_Shaped_Template_Renders;

   --  The bounds that came with variables are bounds, and they are reached.
   --
   --  A template that assigns names is a template that can be written to
   --  assign too many of them, or to hold too much text in them. Neither may
   --  end in an exception or in a prompt built from a name whose value was
   --  quietly dropped.
   procedure Variable_Bounds_Hold
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  One assignment per name, one more than the table holds.
      function Many_Names (Count : Positive) return String is
         Room : String (1 .. Count * 32);
         Used : Natural := 0;

         procedure Put (Text : String) is
         begin
            Room (Used + 1 .. Used + Text'Length) := Text;
            Used := Used + Text'Length;
         end Put;
      begin
         for Index in 1 .. Count loop
            Put ("{% set n" & Model_Runner.Text.Image
                   (Long_Long_Integer (Index)) & " = 'x' %}");
         end loop;
         return Room (1 .. Used);
      end Many_Names;
   begin
      --  The table holds two names before a template says anything --
      --  messages, which is the conversation, and message, which is whatever
      --  a loop or an assignment has bound -- so two short of the bound
      --  compiles and renders.
      Assert (Render_Status (Many_Names (Tmpl.Max_Variables - 2)) = E.No_Error,
              "a template naming as many as the table holds was refused");

      --  Past it, the assignment is refused rather than silently dropped.
      Assert (Render_Status (Many_Names (Tmpl.Max_Variables + 4))
              = E.Template_Unsupported_Construct,
              "a template naming more than the table holds was accepted");

      --  Text. A name reassigned in a loop costs one iteration's room, not
      --  every iteration's, which is what a template building a message's
      --  text before emitting it does on every turn.
      declare
         Long : constant String (1 .. 4000) := [others => 'y'];
      begin
         Assert (Render_Status
                   ("{% for message in messages %}"
                    & "{% set c = '" & Long & "' %}{% endfor %}",
                    Messages => 40) = E.No_Error,
                 "a name reassigned in a loop ran out of room");
      end;

      --  And when it genuinely does not fit, the error says so, rather than
      --  reporting the rendered prompt as too large -- which would be a true
      --  sentence about the wrong subject.
      declare
         Long : constant String (1 .. 4000) := [others => 'y'];
      begin
         Assert (Render_Status
                   ("{% for message in messages %}"
                    & "{% set a = '" & Long & "' %}"
                    & "{% set b = a + a %}{% set c = b + b %}"
                    & "{% set d = c + c %}{% set e = d + d %}{{ e }}"
                    & "{% endfor %}",
                    Messages => 8)
                 = E.Template_Variables_Too_Large,
                 "a template holding more text than the pool has was "
                 & "accepted, or refused as something else");
      end;
   end Variable_Bounds_Hold;

   --  Every documented compile-time refusal happens.
   procedure Malformed_Templates_Are_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Bound : constant Natural :=
        Model_Runner.Limits.Default_Model_Limits.Max_Template_Bytes;
   begin
      --  Size. One byte over the stated limit is over it.
      declare
         Big : constant String (1 .. Bound + 1) := [others => 'x'];
      begin
         Assert (Compile_Status (Big) = E.Template_Too_Large,
                 "a template past the size limit was accepted");
      end;

      --  Instruction count. Each output tag costs an instruction, so a
      --  template well past Max_Instructions cannot compile.
      declare
         Piece : constant String := "{{ bos_token }}";
         Many  : String (1 .. (Tmpl.Max_Instructions + 100) * Piece'Length);
         Used  : Natural := 0;
      begin
         for Index in 1 .. Tmpl.Max_Instructions + 100 loop
            Many (Used + 1 .. Used + Piece'Length) := Piece;
            Used := Used + Piece'Length;
         end loop;
         Assert (Compile_Status (Many (1 .. Used)) = E.Template_Too_Large,
                 "a template past the instruction limit was accepted");
      end;

      --  A branch that has already been closed cannot be closed again. Both
      --  of these reached the code that patches the pending jump with
      --  nothing pending, and indexed instruction zero: a template from a
      --  model file crashing the compiler into an internal invariant
      --  violation, which the property sweep counted as an ordinary refusal
      --  and nobody looked at.
      Assert (Compile_Status
                ("{% if add_generation_prompt %}a{% else %}b{% else %}c"
                 & "{% endif %}") = E.Template_Unbalanced_Block,
              "a second else was accepted");
      Assert (Compile_Status
                ("{% if add_generation_prompt %}a{% else %}b"
                 & "{% elif add_generation_prompt %}c{% endif %}")
                = E.Template_Unbalanced_Block,
              "an elif after an else was accepted");

      --  Nesting. At the limit it compiles; one deeper it does not.
      --  Nothing to compile. A model whose template metadata is present and
      --  empty has said nothing, and rendering from it would produce a
      --  prompt with no conversation in it at all.
      Assert (Compile_Status ("") = E.Template_Missing,
              "an empty template compiled: "
              & E.Error_Code'Image (Compile_Status ("")));

      Assert (Compile_Status (Nested (Tmpl.Max_Depth)) = E.No_Error,
              "nesting at the documented depth was refused");
      Assert (Compile_Status (Nested (Tmpl.Max_Depth + 1))
              = E.Template_Nesting_Too_Deep,
              "nesting past the documented depth was accepted");

      --  Blocks that do not balance.
      Assert (Compile_Status ("{% endfor %}") = E.Template_Unbalanced_Block,
              "a stray endfor was accepted");
      Assert (Compile_Status ("{% endif %}") = E.Template_Unbalanced_Block,
              "a stray endif was accepted");
      Assert (Compile_Status ("{% for message in messages %}")
              = E.Template_Unbalanced_Block,
              "an unclosed for was accepted");
      Assert (Compile_Status ("{% if add_generation_prompt %}")
              = E.Template_Unbalanced_Block,
              "an unclosed if was accepted");
      Assert (Compile_Status ("{% for message in messages %}{% endif %}")
              = E.Template_Unbalanced_Block,
              "a for closed by endif was accepted");

      --  Constructs the engine does not implement are refused rather than
      --  ignored. An ignored tag would silently change the prompt.
      --
      --  Where the refusal happens is the whole design. A statement whose
      --  shape cannot be read is refused at compile time, because nothing
      --  after it can be trusted to mean anything. A value that cannot be
      --  computed is refused when it is asked for, because a template that
      --  never asks for it has asked for nothing wrong -- and every template
      --  shipped with a current model describes tool calling in branches a
      --  conversation of plain messages never enters.
      --  A loop walks whatever its operand is worth -- the conversation,
      --  a count, the tools, one turn's calls, a list or mapping read out
      --  of a schema or written in the template. A name never assigned is
      --  worth nothing, and is refused as it is in the output rather than
      --  walked as an empty list.
      Assert (Render_Status ("{% for item in whatever %}x{% endfor %}")
              = E.Template_Unknown_Variable,
              "iteration over a name never assigned was accepted");
      Assert (Render_Status ("{% for other in message.tool_calls %}x"
                             & "{% endfor %}")
              = E.No_Error,
              "a call loop binding a name that is not tool_call was "
              & "refused");
      --  raise_exception is the template refusing in its author's words,
      --  and the words are the diagnostic.
      Assert (Render_Status ("{{ raise_exception('no') }}")
              = E.Template_Refused,
              "raise_exception did not refuse");
      Assert (Render_Status ("{{ message.content | xmlattr }}")
              = E.Template_Unknown_Filter,
              "an unknown filter rendered");
      Assert (Render_Status ("{% set d = strftime_now('%d') %}{{ d }}")
              = E.No_Error,
              "strftime_now with a directive this engine has was refused");
      Assert (Render_Status ("{% set d = strftime_now('%Q') %}{{ d }}")
              = E.Template_Unsupported_Construct,
              "a function call rendered");
      Assert (Render_Status ("{{ never_assigned }}")
              = E.Template_Unknown_Variable,
              "reading a name the template never assigned rendered");

      --  The same constructs inside a branch the conversation does not enter
      --  cost nothing, which is the point of refusing late.
      Assert (Render_Status
                ("{% if tools %}{{ raise_exception('no') }}"
                 & "{% endif %}ok") = E.No_Error,
              "a refusal in an untaken branch stopped the render");

      --  A template cannot name a file. Nothing embedded in a model may cause
      --  another read, so the construct that would do it has to be refused
      --  rather than attempted.
      Assert (Compile_Status ("{% include 'other.jinja' %}")
              = E.Template_Unsupported_Construct,
              "an include was accepted");
      Assert (Compile_Status ("{% import 'other.jinja' as other %}")
              = E.Template_Unsupported_Construct,
              "an import was accepted");

      --  A filter keeps a diagnostic of its own: a reader can act on "this
      --  template uses a filter I do not have" where "unsupported
      --  expression" leaves them looking for the expression.
      Assert (Render_Status ("{{ bos_token | xmlattr }}")
              = E.Template_Unknown_Filter,
              "a filter was not reported as one");
      Assert (Render_Status ("{{ message.content | trim }}") = E.No_Error,
              "the trim filter was refused");

      --  Names the engine does not know are refused, not rendered empty;
      --  a field a turn has not got is empty, as Jinja prints its
      --  undefined, because that is what every template's "is defined"
      --  and unguarded read of an optional field are written against.
      Assert (Render_Status ("{{ nonsense }}") = E.Template_Unknown_Variable,
              "an unknown variable was accepted");
      Assert (Render_Status ("{{ message.nonsense }}") = E.No_Error,
              "a field a turn has not got was refused");

      --  Syntax that does not close.
      Assert (Compile_Status ("{{ bos_token ") = E.Template_Syntax_Error,
              "an unterminated expression was accepted");
      Assert (Compile_Status ("{% for message in messages ")
              = E.Template_Syntax_Error,
              "an unterminated tag was accepted");
   end Malformed_Templates_Are_Refused;

   --  Rendering is bounded in output and in time.
   --
   --  These two bounds are what stop a model file from turning a prompt into
   --  an unbounded write or an unbounded run.
   procedure Rendering_Is_Bounded
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Last     : Natural;
   begin
      --  Output. The template writes more than the buffer holds.
      declare
         Target : String (1 .. 8);
      begin
         Tmpl.Compile
           (Item,
            "{% for message in messages %}0123456789{% endfor %}",
            Status => Status);
         Assert (E.Is_Ok (Status), "the output template did not compile");

         Fill (Messages, 4);
         Tmpl.Render
           (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
         Assert (Status.Code = E.Template_Output_Too_Large,
                 "output past the buffer was accepted: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Last = 0, "a refused render reported bytes written");
         Conv.Close (Messages);
         Tmpl.Close (Item);
      end;

      --  Output that fits exactly is not refused: the limit is a limit, not
      --  an off-by-one.
      declare
         Target : String (1 .. 40);
      begin
         Tmpl.Compile
           (Item,
            "{% for message in messages %}0123456789{% endfor %}",
            Status => Status);
         Fill (Messages, 4);
         Tmpl.Render
           (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
         Assert (E.Is_Ok (Status),
                 "output that fits exactly was refused: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Last = 40, "the whole output was not written");
         Conv.Close (Messages);
         Tmpl.Close (Item);
      end;

      --  Time. Nesting the message loop inside itself does not terminate on
      --  its own: with the bound raised to two thousand million, the render
      --  reached that count and was still at the seventh instruction of a
      --  twelve-instruction program. The iteration bound is not a safety
      --  margin here, it is the only thing that ends the render, and a model
      --  file carrying such a template would otherwise hang the program.
      declare
         Target : String (1 .. 1024);
      begin
         Tmpl.Compile (Item, Nested (6), Status => Status);
         Assert (E.Is_Ok (Status), "the nested template did not compile");

         Fill (Messages, 10);
         Tmpl.Render
           (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
         Assert (Status.Code = E.Template_Iteration_Limit,
                 "a template past the iteration limit ran to completion: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Last = 0, "a refused render reported bytes written");
         Conv.Close (Messages);
         Tmpl.Close (Item);
      end;
   end Rendering_Is_Bounded;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("chat template");
   end Name;

   --  A caller can tighten the step bound, and the render says which bound
   --  stopped it.
   --
   --  Every other limit this program applies is a field a caller sets; this
   --  one was a constant in the engine until now. A caller rendering
   --  templates from files it does not trust may want a tighter bound than
   --  one rendering its own.
   procedure Render_Step_Bound_Is_A_Setting
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Tight : constant Model_Runner.Limits.Model_Limits :=
        (Model_Runner.Limits.Default_Model_Limits with delta
           Max_Render_Iterations => 32);

      --  Nested loops over a conversation: the shape that runs away.
      Runaway : constant String :=
        "{% for message in messages %}{% for message in messages %}"
        & "{{ message.content }}{% endfor %}{% endfor %}";

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Target   : String (1 .. 4_096);
      Last     : Natural;
      Status   : E.Error_Info;
   begin
      Conv.Open (Messages, Status => Status);
      Assert (E.Is_Ok (Status), "the conversation did not open");
      Fill (Messages, 8);

      Tmpl.Compile (Item, Runaway, Bounds => Tight, Status => Status);
      Assert (E.Is_Ok (Status),
              "the template did not compile: "
              & E.Error_Code'Image (Status.Code));

      Tmpl.Render (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (Status.Code = E.Template_Iteration_Limit,
              "a render past the tightened bound was allowed: "
              & E.Error_Code'Image (Status.Code));
      Assert (Last = 0, "a refused render reported writing something");

      Tmpl.Close (Item);

      --  And the same template under the default bound gets further: the
      --  setting is what stopped it, not the template being impossible.
      Tmpl.Compile (Item, Runaway, Status => Status);
      Assert (E.Is_Ok (Status), "the template did not compile a second time");

      Tmpl.Render (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (E.Is_Ok (Status) or else Status.Code /= E.Template_Iteration_Limit,
              "the default bound stopped a render that fits in it");

      Tmpl.Close (Item);
      Conv.Close (Messages);
   end Render_Step_Bound_Is_A_Setting;

   --  Any template at all is answered, and a failed render writes nothing.
   --
   --  The engine's own bounds are checked by cases chosen to reach them. This
   --  assembles templates from fragments instead -- balanced and unbalanced,
   --  nested and interleaved, with tags a person writing cases would not put
   --  next to each other -- and renders whatever compiles against
   --  conversations of varying shape into buffers of varying size.
   --
   --  Two properties, both of which the rest of the engine relies on. Neither
   --  compiling nor rendering may raise: a template comes out of a model file
   --  and a fault here would be a file taking the process down. And a render
   --  that fails must report writing nothing, because the caller emits Last
   --  bytes and would otherwise emit whatever the buffer held.
   --
   --  This is most of the suite's running time, and the reason is
   --  compilation rather than anything about the templates: each one
   --  allocates a program of four thousand instructions and initialises it,
   --  which is around ten milliseconds and happens two thousand times.
   --  Rendering all of them costs well under a second, measured by removing
   --  it. Of the two thousand, about fifteen hundred compile and eight
   --  hundred and fifty render.
   --
   --  So the seconds are the price of two thousand compilations, not of the
   --  runaway renders. Cutting the case count is the only thing that would
   --  buy them back, and it would buy less coverage with them.
   procedure Any_Template_Is_Answered
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Interfaces.Unsigned_64;

      State : Interfaces.Unsigned_64 := 2_718_281_828_459_045_235;

      function Draw (Bound : Positive) return Natural is
      begin
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         return Natural (State mod Interfaces.Unsigned_64 (Bound));
      end Draw;

      --  Fragments of the supported grammar, and of what is nearly it.
      function Body_Fragment (Which : Natural) return String is
      begin
         case Which is
            when 0 => return "{{ message.role }}";
            when 1 => return "{{ message.content }}";
            when 2 => return "{{ bos_token }}";
            when 3 => return "{{ eos_token }}";
            when 4 => return "{{ loop.first }}";
            when 5 => return "{{ loop.index }}";
            when 6 => return "text";
            when 7 => return "{{- bos_token -}}";
            when others => return "{{ message['content'] }}";
         end case;
      end Body_Fragment;

      Answered : Natural := 0;
      Compiled : Natural := 0;
      Rendered : Natural := 0;
      Refused  : Natural := 0;
      Internal : Natural := 0;
   begin
      for Case_Number in 1 .. 2_000 loop
         declare
            Source : String (1 .. 512);
            Filled : Natural := 0;
            Open_Blocks : array (1 .. 8) of Natural := [others => 0];
            Depth  : Natural := 0;

            --  Append a fragment if there is room for it.
            procedure Put (Part : String) is
            begin
               if Filled + Part'Length <= Source'Length then
                  Source (Filled + 1 .. Filled + Part'Length) := Part;
                  Filled := Filled + Part'Length;
               end if;
            end Put;
         begin
            --  Built balanced, so that most of them compile and the render
            --  is what is being examined. A generator that mostly produced
            --  templates the compiler rejects would be testing the compiler
            --  and calling it a test of rendering.
            for Step in 1 .. 4 + Draw (5) loop
               case Draw (10) is
                  when 0 | 1 =>
                     if Depth < Open_Blocks'Length then
                        Depth := Depth + 1;
                        Open_Blocks (Depth) := 0;
                        Put ("{% for message in messages %}");
                     end if;

                  when 2 =>
                     if Depth < Open_Blocks'Length then
                        Depth := Depth + 1;
                        Open_Blocks (Depth) := 1;
                        Put ("{% if add_generation_prompt %}");
                     end if;

                  when 3 =>
                     if Depth > 0 and then Open_Blocks (Depth) = 1 then
                        Put ("{% else %}");
                     end if;

                  when others =>
                     Put (Body_Fragment (Draw (9)));
               end case;
            end loop;

            --  Close what was opened, innermost first.
            while Depth > 0 loop
               Put ((if Open_Blocks (Depth) = 0
                     then "{% endfor %}" else "{% endif %}"));
               Depth := Depth - 1;
            end loop;

            --  One in four is then broken on purpose, so the refusals are
            --  reached by more than accident.
            if Draw (4) = 0 and then Filled > 12 then
               Filled := Filled - Draw (12);
            end if;

            declare
               Item     : Tmpl.Compiled;
               Status   : E.Error_Info;
               Messages : Conv.History;
               Outcome  : E.Error_Info;

               --  Small buffers on purpose: a loop over messages emitting
               --  their content overruns them, which is the failing render
               --  this is here to watch.
               Room     : constant Natural :=
                 (if Draw (2) = 0 then 1 + Draw (24) else 1 + Draw (256));
               Target   : String (1 .. Room) := [others => '?'];
               Last     : Natural;
            begin
               Tmpl.Compile (Item, Source (1 .. Filled), Status => Status);
               Answered := Answered + 1;

               if Status.Code = E.Internal_Invariant_Violated then
                  Internal := Internal + 1;
               end if;

               if E.Is_Ok (Status) then
                  Compiled := Compiled + 1;
                  Fill (Messages, 1 + Draw (4));

                  Tmpl.Render
                    (Item, Messages, "<s>", "</s>",
                     Draw (2) = 0, Target, Last, Outcome);

                  if Outcome.Code = E.Internal_Invariant_Violated then
                     Internal := Internal + 1;
                  end if;

                  if E.Is_Ok (Outcome) then
                     Rendered := Rendered + 1;
                     Assert (Last <= Target'Length,
                             "case" & Natural'Image (Case_Number)
                             & " reported writing more than the buffer holds:"
                             & Natural'Image (Last));
                  else
                     Refused := Refused + 1;
                     --  The caller emits Last bytes. A failed render that
                     --  left a count behind would emit whatever was in the
                     --  buffer, which here is a row of question marks and in
                     --  the engine is the previous turn.
                     Assert (Last = 0,
                             "case" & Natural'Image (Case_Number)
                             & " failed and still reported"
                             & Natural'Image (Last) & " bytes");
                  end if;

                  Conv.Close (Messages);
               end if;

               Tmpl.Close (Item);
            end;
         end;
      end loop;

      --  Both paths must be reached, or this passes by never rendering.
      --  Measured when written: about fifteen hundred of two thousand
      --  compile, of which roughly half render and half overrun their buffer.
      --  No generated template may reach an internal invariant violation.
      --  That code means the engine found a state it believes impossible,
      --  and a file deciding when that happens is the thing this sweep is
      --  for. Twenty-three of two thousand did, counted as refusals.
      Assert (Internal = 0,
              Natural'Image (Internal)
              & " generated templates reached an internal invariant "
              & "violation");

      Assert (Compiled > 500,
              "too few templates compiled to be testing rendering:"
              & Natural'Image (Compiled));
      Assert (Rendered > 100 and then Refused > 100,
              "the render outcomes are too one-sided to hold both:"
              & Natural'Image (Rendered) & " ok," & Natural'Image (Refused)
              & " refused");
      Assert (Answered = 2_000,
              "only" & Natural'Image (Answered)
              & " of two thousand templates were answered");
   end Any_Template_Is_Answered;

   --------------------
   -- Register_Tests --
   --------------------

   --  What the template a current model ships needs beyond what the subset
   --  held, said as the answers rather than as the constructs.
   --
   --  Every string below was rendered by the implementation the template was
   --  written for and copied here, which is the only way a comparison of
   --  this kind means anything: an expected answer worked out from the
   --  engine's own reading of the template agrees with the engine by
   --  construction. What settles the whole template rather than these pieces
   --  is `tests render` against that implementation, which is what
   --  docs/reference-runtime.md is for.
   procedure Modern_Constructs_Render
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      type Expectation is record
         Source : access constant String;
         Answer : access constant String;
      end record;

      --  A holder with named fields, and a field assigned inside a loop
      --  outliving it -- which is the whole reason a template asks for one.
      Space_Source : aliased constant String :=
        "{%- set ns = namespace(seen=false, last=messages|length - 1) %}"
        & "{%- for message in messages %}"
        & "{%- if message.role == 'assistant' %}{%- set ns.seen = true %}"
        & "{%- endif %}{%- endfor %}"
        & "[{{ ns.last }}|{% if ns.seen %}yes{% else %}no{% endif %}]";
      Space_Answer : aliased constant String := "[1|yes]";

      --  Counting rather than walking a list, backwards, which no list can
      --  express and which a template uses to find the last question asked.
      Range_Source : aliased constant String :=
        "{%- for index in range(messages|length - 1, -1, -1) %}"
        & "{%- set message = messages[index] %}"
        & "[{{ message.role }}]{%- endfor %}";
      Range_Answer : aliased constant String := "[assistant][user]";

      --  A position worked out rather than written, and the field named
      --  either way round.
      Indexed_Source : aliased constant String :=
        "{%- for message in messages %}"
        & "{%- if loop.index0 > 0 and messages[loop.index0 - 1].role != 'x' %}"
        & "[{{ messages[0]['role'] }}/{{ messages[1].role }}]"
        & "{%- endif %}{%- endfor %}";
      Indexed_Answer : aliased constant String := "[user/assistant]";

      --  Text inside text, which is the same word as the test that asks
      --  whether a message carries a field and a different question.
      Inside_Source : aliased constant String :=
        "{%- for message in messages %}"
        & "[{% if 'B' in message.content %}y{% else %}n{% endif %}"
        & "{% if 'q' not in message.content %}!{% endif %}]"
        & "{%- endfor %}";
      Inside_Answer : aliased constant String := "[n!][y!]";

      --  Order, and the two words a template writes to tell a flag set to
      --  false from one never set at all. A length is a number and not
      --  text, as the language has it.
      Order_Source : aliased constant String :=
        "{%- set n = messages|length %}"
        & "[{% if n > 1 %}a{% endif %}{% if n >= 2 %}b{% endif %}"
        & "{% if n < 2 %}c{% endif %}{% if n <= 2 %}d{% endif %}"
        & "{% if missing is defined %}e{% endif %}"
        & "{% if n is string %}f{% endif %}{% if n | string is string %}g"
        & "{% endif %}]";
      Order_Answer : aliased constant String := "[abdg]";

      --  A reply that carries its reasoning in a marked block, taken apart
      --  the way the template that writes such replies takes it apart: four
      --  methods in a row, each on what the one before it answered.
      Methods_Source : aliased constant String :=
        "{%- for message in messages %}{%- if message.role == 'assistant' %}"
        & "{%- set body = message.content.split('</think>')[-1].lstrip('|') %}"
        & "{%- set why = message.content.split('</think>')[0]"
        & ".rstrip('|').split('<think>')[-1].lstrip('|') %}"
        & "[{{ why }}][{{ body }}]{%- endif %}{%- endfor %}";
      Methods_Answer : aliased constant String := "[r][Blue.]";

      --  A loop over the conversation whose variable is not called
      --  message, which is how the template a current mixture ships walks
      --  it backwards: the name it binds is unused and it says which
      --  message it means with a set of its own.
      Walk_Source : aliased constant String :=
        "{%- for forward in messages %}"
        & "{%- set message = messages[loop.index0] %}"
        & "[{{ message.role }}]{%- endfor %}";
      Walk_Answer : aliased constant String := "[user][assistant]";

      --  And what such a loop does to the name it does not bind: nothing.
      --  A message bound before it is the message bound after it, which is
      --  what the language says and what a loop binding as it went would
      --  quietly undo.
      Unbound_Source : aliased constant String :=
        "{%- set message = messages[1] %}"
        & "{%- for forward in messages %}{%- endfor %}"
        & "[{{ message.role }}]";
      Unbound_Answer : aliased constant String := "[assistant]";

      --  A sum with brackets round part of it, which is how a template
      --  counts back from the end of a conversation. Brackets after a minus
      --  turn the joins inside them round, because that is what taking a
      --  sum away comes to.
      Group_Source : aliased constant String :=
        "{%- set last = (messages|length - 1) - 0 %}"
        & "[{{ last }}][{{ 10 - (3 - 1) }}]";
      Group_Answer : aliased constant String := "[1][8]";

      --  A choice written on one line, which a template writes where a turn
      --  may not carry the field it is after.
      Choice_Source : aliased constant String :=
        "{%- for message in messages %}"
        & "{%- set who = 'asked' if message.role == 'user' else 'answered' %}"
        & "[{{ who }}]{%- endfor %}";
      Choice_Answer : aliased constant String := "[asked][answered]";

      --  Cuts at a position rather than at a marker, counted from either
      --  end, which is how a template asks whether a turn begins and ends
      --  with the markers a tool's answer is wrapped in.
      Cut_Source : aliased constant String :=
        "[{{ messages[0].content[:2] }}][{{ messages[0].content[2:] }}]"
        & "[{{ messages[0].content[1:3] }}][{{ messages[0].content[-2:] }}]";
      Cut_Answer : aliased constant String := "[he][llo][el][lo]";

      --  Which side of a cut is wanted, said by a filter rather than by a
      --  position. The same question either way round.
      Side_Source : aliased constant String :=
        "{%- for message in messages %}{%- if message.role == 'assistant' %}"
        & "[{{ message.content.split('</think>')|last }}]"
        & "[{{ message.content.split('<think>')|first }}]"
        & "{%- endif %}{%- endfor %}";
      Side_Answer : aliased constant String := "[|Blue.][]";

      Wanted : constant array (1 .. 12) of Expectation :=
        [(Space_Source'Access, Space_Answer'Access),
         (Range_Source'Access, Range_Answer'Access),
         (Indexed_Source'Access, Indexed_Answer'Access),
         (Inside_Source'Access, Inside_Answer'Access),
         (Order_Source'Access, Order_Answer'Access),
         (Methods_Source'Access, Methods_Answer'Access),
         (Walk_Source'Access, Walk_Answer'Access),
         (Unbound_Source'Access, Unbound_Answer'Access),
         (Group_Source'Access, Group_Answer'Access),
         (Choice_Source'Access, Choice_Answer'Access),
         (Cut_Source'Access, Cut_Answer'Access),
         (Side_Source'Access, Side_Answer'Access)];

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Target   : String (1 .. 2048);
      Last     : Natural;
   begin
      for Each of Wanted loop
         Tmpl.Compile (Item, Each.Source.all, Status => Status);
         Assert (E.Is_Ok (Status),
                 "a template the models ship did not compile: "
                 & E.Error_Code'Image (Status.Code) & " -- "
                 & Each.Source.all);

         Conv.Open (Messages, Status => Status);
         Conv.Append (Messages, Conv.User_Role, "hello", Status);
         Conv.Append
           (Messages, Conv.Assistant_Role,
            "<think>|r|</think>|Blue.", Status);

         Tmpl.Render
           (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
         Assert (E.Is_Ok (Status),
                 "it did not render: " & E.Error_Code'Image (Status.Code)
                 & " -- " & Each.Source.all);
         Assert (Target (1 .. Last) = Each.Answer.all,
                 "rendered [" & Target (1 .. Last) & "] where the answer is ["
                 & Each.Answer.all & "] -- " & Each.Source.all);

         Conv.Close (Messages);
         Tmpl.Close (Item);
      end loop;

      --  A name the template never assigned is nothing when a condition asks
      --  about it and an error when the output does. Both matter: a template
      --  writes "if tools" to find out whether it was given any, and a
      --  template that prints a name it never wrote would put the empty
      --  string where it meant text and say nothing about it.
      Assert (Render_Status ("{% if never %}x{% endif %}") = E.No_Error,
              "a condition asking about a name never assigned was refused");
      Assert (Render_Status ("{% if message.tool_calls %}x{% endif %}")
              = E.No_Error,
              "a condition asking about a field a message has not got was "
              & "refused");
      Assert (Render_Status ("{{ never }}") = E.Template_Unknown_Variable,
              "output reading a name never assigned was accepted");

      --  A loop over the conversation may call its variable what it likes
      --  and read a turn's fields through that name, as Jinja does.
      Assert (Render_Status
                ("{% for other in messages %}{{ other.role }}{% endfor %}")
              = E.No_Error,
              "a field read off a loop's own name was refused");

      --  A cut nothing said the side of is a list, printed as Python
      --  prints one.
      Assert (Render_Status ("{{ 'a</think>b'.split('</think>') }}")
              = E.No_Error,
              "a cut with neither end asked for was refused");
      Assert (Render_Status ("{{ 'a</think>b'.split('</think>')|last }}")
              = E.No_Error,
              "a cut whose side a filter names was refused");
   end Modern_Constructs_Render;

   --  What a turn asked for, written as the template writes it.
   --
   --  A model that calls a tool writes the call in the spelling its template
   --  told it to. Kept as text, that spelling is what reaches the model on
   --  the next turn; kept as a call, the template writes it again -- and the
   --  two are not the same bytes, which is the whole reason a template has a
   --  branch for it.
   --
   --  Everything below is what the Qwen3 file uses in that branch, written
   --  here so the test owns what it tests: the question, the loop, the two
   --  fields, the "is string" that tells a value it may print from one it
   --  must encode, and the branch for a call shape this engine does not hold
   --  -- which must not be entered rather than must not exist.
   procedure Tool_Calls_Render_As_Calls
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := Character'Val (10);

      Source : constant String :=
        "{%- for message in messages %}"
        & "{%- if message.role == 'user' %}"
        & "<|user|>{{ message.content }}"
        & "{%- elif message.role == 'assistant' %}"
        & "<|assistant|>{{ message.content }}"
        & "{%- if message.tool_calls %}"
        & "{%- for tool_call in message.tool_calls %}"
        & "{%- if (loop.first and message.content) or (not loop.first) %}"
        & "{{- '|' }}"
        & "{%- endif %}"
        & "{%- if tool_call.function %}"
        & "{%- set tool_call = tool_call.function %}"
        & "{%- endif %}"
        & "{{- '<call>{""name"": ""' }}{{- tool_call.name }}"
        & "{{- '"", ""arguments"": ' }}"
        & "{%- if tool_call.arguments is string %}"
        & "{{- tool_call.arguments }}"
        & "{%- else %}"
        & "{{- tool_call.arguments | tojson }}"
        & "{%- endif %}"
        & "{{- '}</call>' }}"
        & "{%- endfor %}"
        & "{%- endif %}"
        & "{%- elif message.role == 'tool' %}"
        & "{%- if loop.first or (messages[loop.index0 - 1].role != 'tool') %}"
        & "<|user|>"
        & "{%- endif %}"
        & "<answer>{{ message.content }}</answer>"
        & "{%- if loop.last or (messages[loop.index0 + 1].role != 'tool') %}"
        & "<|end|>"
        & "{%- endif %}"
        & "{%- endif %}"
        & "{%- endfor %}";

      --  What the model wrote, in the spelling its template asked for.
      Reply : constant String :=
        "Checking." & LF
        & "<tool_call>" & LF
        & "{""name"": ""get_weather"", ""arguments"": {""city"": ""Paris""}}"
        & LF & "</tool_call>";

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Reading  : E.Error_Info;
      Target   : String (1 .. 1024);
      Last     : Natural;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "the tool-call branch did not compile: "
              & E.Error_Code'Image (Status.Code));

      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, "w?", Status);
      Conv.Append_Reply (Messages, Reply, Status, Reading);
      Assert (E.Is_Ok (Status) and then E.Is_Ok (Reading),
              "a reply carrying a call was not taken into the conversation");

      --  The reply came apart where the model stopped speaking: the text is
      --  the turn's content, the call is beside it, and the newline between
      --  them belongs to neither.
      Assert (Conv.Content_At (Messages, 2) = "Checking.",
              "the spoken part of a reply was kept wrong: "
              & Conv.Content_At (Messages, 2));
      Assert (Conv.Call_Count (Messages, 2) = 1,
              "a reply with one call produced"
              & Natural'Image (Conv.Call_Count (Messages, 2)));
      Assert (Conv.Call_Name (Messages, 2, 1) = "get_weather",
              "the call named " & Conv.Call_Name (Messages, 2, 1));
      Assert (Conv.Call_Arguments (Messages, 2, 1) = "{""city"": ""Paris""}",
              "the call's arguments were kept as "
              & Conv.Call_Arguments (Messages, 2, 1));
      Assert (Conv.Call_Count (Messages, 1) = 0,
              "a turn nobody called from carries calls");

      --  Two answers handed back, which the template folds into one turn.
      --  That fold is written as messages[loop.index0 + 1], and a plus that
      --  ran two numbers together rather than adding them would end the
      --  first answer's turn and open none for the second.
      Conv.Append (Messages, Conv.Tool_Role, "18", Status);
      Conv.Append (Messages, Conv.Tool_Role, "22", Status);
      Assert (E.Is_Ok (Status), "a tool answer was not appended");

      Tmpl.Render (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
      Assert (E.Is_Ok (Status),
              "rendering a conversation with calls failed: "
              & E.Error_Code'Image (Status.Code));
      Assert (Target (1 .. Last)
              = "<|user|>w?<|assistant|>Checking.|"
                & "<call>{""name"": ""get_weather"", ""arguments"": "
                & "{""city"": ""Paris""}}</call>"
                & "<|user|><answer>18</answer><answer>22</answer><|end|>",
              "rendered the wrong text: " & Target (1 .. Last));

      --  A dropped turn takes its calls with it, and the turn appended after
      --  it must not inherit them.
      Conv.Drop_Last (Messages, 3);
      Conv.Append (Messages, Conv.Assistant_Role, "plain", Status);
      Assert (Conv.Call_Count (Messages, 2) = 0,
              "a turn appended after a dropped one inherited its calls");

      Tmpl.Render (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
      Assert (Target (1 .. Last) = "<|user|>w?<|assistant|>plain",
              "a dropped call still rendered: " & Target (1 .. Last));

      Conv.Close (Messages);

      --  A reply that called nothing is the turn it always was, and a reply
      --  that is nothing but a call is a turn with nothing said in it.
      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, "w?", Status);
      Conv.Append_Reply (Messages, "just talking", Status, Reading);
      Assert (E.Is_Ok (Status) and then Conv.Call_Count (Messages, 2) = 0,
              "a reply with no call in it was taken apart anyway");
      Conv.Append (Messages, Conv.User_Role, "w again?", Status);
      Conv.Append_Reply
        (Messages,
         "<tool_call>{""name"": ""get_weather"", ""arguments"": {}}"
         & "</tool_call>",
         Status, Reading);
      Assert (E.Is_Ok (Status), "a reply of nothing but a call was refused");
      Assert (Conv.Content_At (Messages, 4) = "",
              "a reply of nothing but a call said something: "
              & Conv.Content_At (Messages, 4));

      Tmpl.Render (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
      Assert (Target (1 .. Last)
              = "<|user|>w?<|assistant|>just talking"
                & "<|user|>w again?<|assistant|>"
                & "<call>{""name"": ""get_weather"", ""arguments"": {}}"
                & "</call>",
              "a reply that only called rendered wrong: " & Target (1 .. Last));

      --  And a system message set afterwards, which rebuilds the whole
      --  history: the calls have to survive being rebuilt, or a template
      --  loses them the moment a caller changes the system message.
      Conv.Set_System (Messages, "Be brief.", Status);
      Assert (E.Is_Ok (Status), "setting the system message failed");
      Assert (Conv.Call_Count (Messages, 5) = 1,
              "rebuilding the history lost a turn's calls");
      Assert (Conv.Call_Name (Messages, 5, 1) = "get_weather",
              "rebuilding the history renamed a call");

      Conv.Close (Messages);
      Tmpl.Close (Item);
   end Tool_Calls_Render_As_Calls;

   --  A name given the value of another name keeps it.
   --
   --  The template a reasoning model ships walks its conversation backwards
   --  to find the last question in it, and writes down the loop's counter
   --  when it finds one. That counter is reassigned every time round the
   --  loop; a name that held the counter's own storage rather than a copy of
   --  what it said quietly became the current position -- so the last
   --  question was found at position zero, every reply before it was resent
   --  with its reasoning still in it, and nothing anywhere reported a fault.
   procedure A_Copied_Name_Keeps_What_It_Copied
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Source : constant String :=
        "{%- set ns = namespace(found=true, at=messages|length - 1) %}"
        & "{%- for index in range(ns.at, -1, -1) %}"
        & "{%- set message = messages[index] %}"
        & "{%- if ns.found and message.role == 'user' %}"
        & "{%- set ns.found = false %}"
        & "{%- set ns.at = index %}"
        & "{%- endif %}"
        & "{%- endfor %}"
        & "at={{ ns.at }}";

      Item     : Tmpl.Compiled;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Target   : String (1 .. 256);
      Last     : Natural;
   begin
      Tmpl.Compile (Item, Source, Status => Status);
      Assert (E.Is_Ok (Status),
              "the backwards walk did not compile: "
              & E.Error_Code'Image (Status.Code));

      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, "one", Status);
      Conv.Append (Messages, Conv.Assistant_Role, "two", Status);
      Conv.Append (Messages, Conv.User_Role, "three", Status);

      Tmpl.Render (Item, Messages, "<s>", "</s>", False, Target, Last, Status);
      Assert (E.Is_Ok (Status),
              "the backwards walk failed: " & E.Error_Code'Image (Status.Code));
      Assert (Target (1 .. Last) = "at=2",
              "the last question was found at the wrong position: "
              & Target (1 .. Last));

      Conv.Close (Messages);
      Tmpl.Close (Item);
   end A_Copied_Name_Keeps_What_It_Copied;

   --  What a caller offers and what the model writes back are read, or
   --  refused by name.
   --
   --  A tool definition arrives as a caller's file and a call arrives as a
   --  model's text, which is to say neither is trusted. Every refusal here
   --  is a promise that a particular wrong input is turned away and said so;
   --  a refusal nothing reaches is a promise nobody has checked.
   procedure Tool_Definitions_Are_Read_Or_Refused
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      package Tools renames Model_Runner.Tools;

      Offered : Tools.Definitions;
      Asked   : Tools.Calls;
      Status  : E.Error_Info;

      --  A list of Count tools, each named and nothing else.
      function Many (Count : Positive) return String is
         Room : String (1 .. 64 * Count + 2);
         Used : Natural := 0;

         procedure Put (Value : String) is
         begin
            Room (Used + 1 .. Used + Value'Length) := Value;
            Used := Used + Value'Length;
         end Put;
      begin
         Put ("[");
         for Index in 1 .. Count loop
            if Index > 1 then
               Put (",");
            end if;
            Put ("{""name"": ""t""}");
         end loop;
         Put ("]");
         return Room (1 .. Used);
      end Many;
   begin
      --  What is read.
      Tools.Read
        (Offered,
         "[{""type"": ""function"", ""function"": {""name"": ""weather"","
         & " ""parameters"": {""type"": ""object""}}}]",
         Status);
      Assert (E.Is_Ok (Status),
              "a definition a caller would write was refused: "
              & E.Error_Code'Image (Status.Code));
      Assert (Tools.Count (Offered) = 1 and then Tools.Offers (Offered, "weather"),
              "the definition was read under another name");

      --  One object rather than a list of them, which is what a caller with
      --  one tool writes and what refusing would make them wrap.
      Tools.Read (Offered, "{""name"": ""weather""}", Status);
      Assert (E.Is_Ok (Status) and then Tools.Count (Offered) = 1,
              "one tool written on its own was refused");

      --  And what is not.
      Tools.Read (Offered, "", Status);
      Assert (Status.Code = E.Tools_Invalid_JSON,
              "nothing at all was read as a tool: "
              & E.Error_Code'Image (Status.Code));

      Tools.Read (Offered, "[1]", Status);
      Assert (Status.Code = E.Tools_Not_An_Object,
              "a number was read as a tool: "
              & E.Error_Code'Image (Status.Code));

      Tools.Read (Offered, "[{""description"": ""nameless""}]", Status);
      Assert (Status.Code = E.Tools_Missing_Name,
              "a tool nobody can name was offered: "
              & E.Error_Code'Image (Status.Code));

      Tools.Read (Offered, Many (Tools.Max_Definitions + 1), Status);
      Assert (Status.Code = E.Tools_Too_Many,
              "more tools than this build carries were read: "
              & E.Error_Code'Image (Status.Code));

      declare
         --  One definition larger than the room every definition has
         --  together.
         Wide : String (1 .. Tools.Max_Definition_Bytes + 64) :=
           [others => 'x'];
      begin
         Wide (1 .. 20) := "{""name"": ""a"", ""d"": """;
         Wide (Wide'Last - 1 .. Wide'Last) := """}";
         Tools.Read (Offered, Wide, Status);
         Assert (Status.Code = E.Tools_Too_Large,
                 "a definition larger than the pool was read: "
                 & E.Error_Code'Image (Status.Code));
      end;

      declare
         --  Nested deeper than this build reads. A schema nests as deeply as
         --  its author wrote it, and this is where a file that nests without
         --  end stops being read.
         Deep : String (1 .. 200) := [others => '['];
         Used : constant Natural := 40;
      begin
         Deep (Used + 1 .. Used + Used) := [others => ']'];
         Tools.Read
           (Offered,
            "[{""name"": ""a"", ""p"": " & Deep (1 .. 2 * Used) & "}]",
            Status);
         Assert (Status.Code = E.Tools_Nesting_Too_Deep,
                 "a definition nesting without end was read: "
                 & E.Error_Code'Image (Status.Code));
      end;

      Tools.Close (Offered);

      --  The calls read back out of a reply. A reply with no block in it
      --  carries no calls and is not an error: a model asked a question it
      --  can answer itself answers it.
      Tools.Read_Calls (Asked, "just talking", Status);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 0,
              "a plain reply was read as a call");

      Tools.Read_Calls
        (Asked,
         "<tool_call>{""name"": ""weather"", ""arguments"": "
         & "{""city"": ""Paris""}}</tool_call>",
         Status);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 1
              and then Tools.Called (Asked, 1) = "weather"
              and then Tools.Arguments (Asked, 1) = "{""city"": ""Paris""}",
              "a call the template asked the model to write was not read");

      --  Arguments written as a string holding JSON, which is how some
      --  models answer: read back out of the string and written the one way,
      --  so that a caller sees the arguments and not the quoting.
      Tools.Read_Calls
        (Asked,
         "<tool_call>{""name"": ""weather"", ""arguments"": "
         & """{\""city\"": \""Paris\""}""}</tool_call>",
         Status);
      Assert (E.Is_Ok (Status)
              and then Tools.Arguments (Asked, 1) = "{""city"": ""Paris""}",
              "quoted arguments were handed on with their quoting: "
              & Tools.Arguments (Asked, 1));

      Tools.Read_Calls (Asked, "<tool_call>{}</tool_call>", Status);
      Assert (Status.Code = E.Tools_Call_Malformed,
              "a call naming no function was read: "
              & E.Error_Code'Image (Status.Code));

      Tools.Read_Calls (Asked, "<tool_call>{""name"": ""a""", Status);
      Assert (Status.Code = E.Tools_Call_Malformed,
              "a reply that stopped in the middle of a call was read as "
              & "no call at all: " & E.Error_Code'Image (Status.Code));

      Tools.Close (Asked);
   end Tool_Definitions_Are_Read_Or_Refused;

   --  Compaction drops the oldest turns and keeps the shape a model reads:
   --  the system message, the task, and a coherent recent tail whose calls
   --  and results still belong together.
   procedure Compaction_Keeps_The_Shape
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      use type Conv.Role;
      Messages : Conv.History;
      Status   : E.Error_Info;
      Dropped  : Natural;
   begin
      Conv.Open (Messages, Status => Status);
      Assert (E.Is_Ok (Status), "the history would not open");

      --  A system message, the task, then five rounds of an assistant call
      --  and a tool answer.
      Conv.Append (Messages, Conv.System_Role, "Be brief.", Status);
      Conv.Append (Messages, Conv.User_Role, "the task", Status);
      for Round in 1 .. 5 loop
         Conv.Append_Asking
           (Messages, "step" & Integer'Image (Round), Status);
         Conv.Append_Call
           (Messages, "calc", "{""n"":" & Integer'Image (Round) & "}",
            Status);
         Conv.Append
           (Messages, Conv.Tool_Role, "result" & Integer'Image (Round),
            Status);
      end loop;
      Assert (Conv.Length (Messages) = 12, "the history is not twelve turns");

      --  Keep a recent tail; the boundary lands on a tool answer and is
      --  pulled back to the assistant turn that produced it, so no orphan
      --  result leads the tail.
      Conv.Compact (Messages, Keep_Recent => 3, Dropped => Dropped);
      Assert (Dropped > 0, "compaction dropped nothing from a full history");

      Assert (Conv.Sender_At (Messages, 1) = Conv.System_Role
              and then Conv.Content_At (Messages, 1) = "Be brief.",
              "compaction lost the system message");
      declare
         Task_Text : constant String := Conv.Content_At (Messages, 2);

         function Contains (Whole, Part : String) return Boolean is
         begin
            if Part'Length = 0 or else Whole'Length < Part'Length then
               return Part'Length = 0;
            end if;
            for P in Whole'First .. Whole'Last - Part'Length + 1 loop
               if Whole (P .. P + Part'Length - 1) = Part then
                  return True;
               end if;
            end loop;
            return False;
         end Contains;
      begin
         Assert (Conv.Sender_At (Messages, 2) = Conv.User_Role
                 and then Task_Text'Length >= 8
                 and then Task_Text (Task_Text'First .. Task_Text'First + 7)
                   = "the task",
                 "compaction lost the task");
         --  The dropped turns leave a digest folded into the task, so the run
         --  keeps the thread of what it did -- including the calls it made.
         Assert (Contains (Task_Text, "calc"),
                 "compaction folded no digest of the dropped calls into "
                 & "the task");
      end;

      declare
         N     : constant Positive := Conv.Length (Messages);
         Found : Boolean := False;
      begin
         Assert (Conv.Sender_At (Messages, N) = Conv.Tool_Role
                 and then Conv.Content_At (Messages, N) = "result 5",
                 "the last tool answer did not survive: "
                 & Conv.Content_At (Messages, N));
         Assert (Conv.Sender_At (Messages, 3) = Conv.Assistant_Role,
                 "the recent tail begins on an orphaned tool answer");
         for I in 1 .. N loop
            if Conv.Sender_At (Messages, I) = Conv.Assistant_Role
              and then Conv.Call_Count (Messages, I) = 1
              and then Conv.Call_Name (Messages, I, 1) = "calc"
            then
               Found := True;
            end if;
         end loop;
         Assert (Found, "no kept assistant turn kept its call");
      end;

      --  A history that already fits the keep window loses nothing.
      Conv.Compact (Messages, Keep_Recent => 100, Dropped => Dropped);
      Assert (Dropped = 0, "compaction dropped from a history that fit");

      Conv.Close (Messages);
   end Compaction_Keeps_The_Shape;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Gemma_Renders_Tool_Calls'Access,
         "the gemma format offers tools in the first user turn, writes a "
         & "call in the <tool_call> JSON envelope, and folds a tool's "
         & "answer into a user turn");
      Register_Routine
        (T, MiniCPM_Renders_Tool_Calls'Access,
         "the minicpm format offers tools and writes a call as a function "
         & "element with param children");
      Register_Routine
        (T, Qwen3_Coder_Renders_Tool_Calls'Access,
         "the qwen3-coder format offers tools and writes a call in the "
         & "<function=..><parameter=..> form");
      Register_Routine
        (T, Values_Render_As_The_Language_Would'Access,
         "lists, mappings, a schema's members, a call's arguments and the "
         & "conversation are walked, indexed, asked about and written as "
         & "the language does it, and a loop's assignments stay its own");
      Register_Routine
        (T, Carried_Formats_Match_The_Models_Own_Templates'Access,
         "the carried qwen3-coder, minicpm and gemma formats render the "
         & "same bytes as the models' own templates, conversation for "
         & "conversation, the gpt-oss and Qwen3.6 templates render every "
         & "shape, and all five render the bytes jinja2 recorded");
      Register_Routine
        (T, Templates_Are_Recognised_By_Their_Markers'Access,
         "a template's own text names the carried format it is written in, "
         & "and the call syntax follows from the name");
      Register_Routine
        (T, Built_In_Formats_Render_Their_Turns'Access,
         "each built-in chat format renders the turns its architecture reads");
      Register_Routine
        (T, Modern_Constructs_Render'Access,
         "what a current model's template needs beyond the older subset "
         & "renders what that model was trained to read");
      Register_Routine
        (T, Any_Template_Is_Answered'Access,
         "any template is answered and a failed render writes nothing");
      Register_Routine
        (T, Ordinary_Template_Renders'Access,
         "a template the program would meet compiles and renders");
      Register_Routine
        (T, Expressions_Render_As_The_Language_Would'Access,
         "arithmetic, the text filters, the date and raise_exception "
         & "render as the language writes them");
      Register_Routine
        (T, Model_Shaped_Template_Renders'Access,
         "a template shaped like the one a current model ships renders");
      Register_Routine
        (T, Variable_Bounds_Hold'Access,
         "the bounds on a template's variables are reached and reported");
      Register_Routine
        (T, Malformed_Templates_Are_Refused'Access,
         "every documented compile-time refusal happens");
      Register_Routine
        (T, Render_Step_Bound_Is_A_Setting'Access,
         "a caller can tighten the render step bound");
      Register_Routine
        (T, Rendering_Is_Bounded'Access,
         "rendering is bounded in output and in iterations");
      Register_Routine
        (T, Tool_Calls_Render_As_Calls'Access,
         "a turn's tool calls are kept beside its text and written as the "
         & "template writes them");
      Register_Routine
        (T, Tool_Definitions_Are_Read_Or_Refused'Access,
         "the tools a caller offers and the calls a model writes back are "
         & "read or refused by name");
      Register_Routine
        (T, A_Copied_Name_Keeps_What_It_Copied'Access,
         "a name given another name's value keeps it after the other "
         & "changes");
      Register_Routine
        (T, Compaction_Keeps_The_Shape'Access,
         "compacting a history drops the oldest turns and keeps the system "
         & "message, the task and a coherent recent tail");
   end Register_Tests;

end Tests.Template_Cases;
