with AUnit.Assertions;

with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Templates;

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

      --  Nesting. At the limit it compiles; one deeper it does not.
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
      Assert (Compile_Status ("{% for item in tools %}{% endfor %}")
              = E.Template_Unsupported_Construct,
              "iteration over something other than messages was accepted");
      Assert (Compile_Status ("{% set x = 1 %}")
              = E.Template_Unsupported_Construct,
              "an unsupported statement was accepted");

      --  A template cannot name a file. Nothing embedded in a model may cause
      --  another read, so the construct that would do it has to be refused
      --  rather than attempted.
      Assert (Compile_Status ("{% include 'other.jinja' %}")
              = E.Template_Unsupported_Construct,
              "an include was accepted");
      Assert (Compile_Status ("{% import 'other.jinja' as other %}")
              = E.Template_Unsupported_Construct,
              "an import was accepted");

      --  Names the engine does not know are refused, not rendered empty.
      Assert (Compile_Status ("{{ nonsense }}") = E.Template_Unknown_Variable,
              "an unknown variable was accepted");
      Assert (Compile_Status ("{{ message.nonsense }}")
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

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Ordinary_Template_Renders'Access,
         "a template the program would meet compiles and renders");
      Register_Routine
        (T, Malformed_Templates_Are_Refused'Access,
         "every documented compile-time refusal happens");
      Register_Routine
        (T, Rendering_Is_Bounded'Access,
         "rendering is bounded in output and in iterations");
   end Register_Tests;

end Tests.Template_Cases;
