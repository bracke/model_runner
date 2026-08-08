with AUnit.Assertions;

with Interfaces;

with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Templates;
with Model_Runner.Text;

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
      --  The table holds messages plus what the template names, so one short
      --  of the bound compiles and renders.
      Assert (Render_Status (Many_Names (Tmpl.Max_Variables - 1)) = E.No_Error,
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
      Assert (Render_Status ("{% for item in tools %}x{% endfor %}")
              = E.Template_Unsupported_Construct,
              "iteration over something other than messages was accepted");
      Assert (Render_Status ("{{ raise_exception('no') }}")
              = E.Template_Unsupported_Construct,
              "raise_exception rendered");
      Assert (Render_Status ("{{ tool_call.arguments | tojson }}")
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

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
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
   end Register_Tests;

end Tests.Template_Cases;
