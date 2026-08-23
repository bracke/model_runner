with AUnit.Assertions;

with Interfaces;

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

      Wanted : constant array (1 .. 4) of Expectation :=
        [(Tmpl.Format_Llama3, Llama3_Text'Access),
         (Tmpl.Format_ChatML, ChatML_Text'Access),
         (Tmpl.Format_Gemma, Gemma_Text'Access),
         (Tmpl.Format_Phi3, Phi3_Text'Access)];

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
   end Built_In_Formats_Render_Their_Turns;

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
      --  conversation, date_string falls to the value the template itself
      --  supplies, and the tool branches are never entered.
      Conv.Open (Messages, Status => Status);
      Conv.Append (Messages, Conv.User_Role, " Hi ", Status);
      Tmpl.Render (Item, Messages, "<s>", "</s>", True, Target, Last, Status);
      Assert (E.Is_Ok (Status),
              "rendering failed: " & E.Error_Code'Image (Status.Code));
      Assert (Target (1 .. Last)
              = "<s><|system|>Today: 26 Jul 2024 <|end|>"
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
              = "<s><|system|>Today: 26 Jul 2024 Be brief.<|end|>"
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
      --  The four things there are to walk are the conversation, a count,
      --  the tools and one turn's calls. Anything else is a loop over
      --  something this engine does not hold.
      Assert (Render_Status ("{% for item in whatever %}x{% endfor %}")
              = E.Template_Unsupported_Construct,
              "iteration over something other than messages was accepted");
      Assert (Render_Status ("{% for other in message.tool_calls %}x"
                             & "{% endfor %}")
              = E.Template_Unsupported_Construct,
              "a call loop binding a name that is not tool_call was "
              & "accepted");
      Assert (Render_Status ("{{ raise_exception('no') }}")
              = E.Template_Unsupported_Construct,
              "raise_exception rendered");
      Assert (Render_Status ("{{ message.content | upper }}")
              = E.Template_Unknown_Filter,
              "an unknown filter rendered");
      Assert (Render_Status ("{% set d = strftime_now('%d') %}{{ d }}")
              = E.Template_Unsupported_Construct,
              "a function call rendered");
      Assert (Render_Status ("{{ never_assigned }}")
              = E.Template_Unknown_Variable,
              "reading a name the template never assigned rendered");

      --  The same constructs inside a branch the conversation does not enter
      --  cost nothing, which is the point of refusing late.
      Assert (Render_Status
                ("{% if tools is defined %}{{ raise_exception('no') }}"
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
      Assert (Render_Status ("{{ bos_token | upper }}")
              = E.Template_Unknown_Filter,
              "a filter was not reported as one");
      Assert (Render_Status ("{{ message.content | trim }}") = E.No_Error,
              "the trim filter was refused");

      --  Names the engine does not know are refused, not rendered empty.
      Assert (Render_Status ("{{ nonsense }}") = E.Template_Unknown_Variable,
              "an unknown variable was accepted");
      Assert (Render_Status ("{{ message.nonsense }}")
              = E.Template_Unknown_Variable,
              "an unknown message field was accepted");

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
      --  false from one never set at all.
      Order_Source : aliased constant String :=
        "{%- set n = messages|length %}"
        & "[{% if n > 1 %}a{% endif %}{% if n >= 2 %}b{% endif %}"
        & "{% if n < 2 %}c{% endif %}{% if n <= 2 %}d{% endif %}"
        & "{% if missing is defined %}e{% endif %}"
        & "{% if n is string %}f{% endif %}]";
      Order_Answer : aliased constant String := "[abdf]";

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

      --  A loop over the conversation may call its variable what it likes,
      --  and what it may not do is read a field off it: the fields this
      --  engine reads from a turn are read through the one name, and a name
      --  that is not that one is a name nothing can be read from. Refused
      --  where it is read rather than answered with the turn the loop
      --  happens to be on, which would be right by accident.
      Assert (Render_Status
                ("{% for other in messages %}{{ other.role }}{% endfor %}")
              = E.Template_Unknown_Variable,
              "a field read off a loop's own name was answered");

      --  A cut nothing said the side of answers with a list, and a list has
      --  no spelling here. Said by either the position or the filter, and
      --  refused where it is said by neither.
      Assert (Render_Status ("{{ 'a</think>b'.split('</think>') }}")
              = E.Template_Unsupported_Construct,
              "a cut with neither end asked for was printed anyway");
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

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
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
   end Register_Tests;

end Tests.Template_Cases;
