private with Ada.Finalization;

with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Limits;

--  Bounded chat-template rendering.
--
--  An embedded chat template is untrusted data. This engine implements a small
--  allowlisted subset and rejects everything else at compile time, before any
--  generation happens. It is not a Jinja implementation and does not try to
--  become one: a template that needs a construct outside the subset is
--  reported as unsupported rather than approximated.
--
--  Supported constructs
--
--    literal text
--    {{ terms }}             terms joined by '+', see below
--    {% for message in messages %} ... {% endfor %}
--    {% if cond %} ... {% elif cond %} ... {% else %} ... {% endif %}
--    {%- ... -%} and {{- ... -}}   whitespace control on either side
--
--  Terms usable in output and in comparisons
--
--    'literal'  "literal"      with \n, \t, \r, \\ and \' escapes
--    bos_token  eos_token
--    message['role']    message.role
--    message['content'] message.content
--    add_generation_prompt
--    loop.first  loop.last  loop.index0  loop.index
--
--  Conditions are an or-list of and-lists of clauses, each clause optionally
--  negated by 'not' and optionally comparing two terms with '==' or '!='.
--
--  Explicitly not supported, and rejected with Template_Unsupported_Construct:
--  set, macro, include, import, raise_exception, filters, slicing, indexing
--  into messages, arithmetic, and any function call. The engine cannot open a
--  file, read the environment, start a process, reach the network or load a
--  library, because it contains no operation that does any of those things.
--
--  Bounds. Template size, instruction count, nesting depth, loop iterations
--  and output size are all bounded. Rendering cannot recurse: the compiled
--  form is a flat instruction list with jumps.
--
--  Task safety: a Compiled template is immutable after Compile and may be
--  rendered concurrently.
package Model_Runner.Templates is

   --  Largest number of instructions a template may compile to.
   Max_Instructions : constant := 4096;

   --  Largest nesting depth of for and if blocks.
   Max_Depth : constant := 16;

   --  Largest number of terms in one output expression or comparison side.
   Max_Terms : constant := 32;

   --  Largest number of instruction steps one render may perform, across all
   --  loops. Bounds rendering time independently of the message count.
   --
   --  This is a termination condition, not a margin. The message loop nested
   --  inside itself does not finish on its own: raising this bound to two
   --  thousand million during testing produced two thousand million steps and
   --  a render still in progress. A template arriving in a model file is not
   --  trusted to terminate, so rendering stops counting rather than waiting.
   --  The default step bound. A caller changes it through Model_Limits, and
   --  a compiled template carries whatever it was compiled with.
   Max_Iterations : constant := 100_000;

   --  A compiled template. Release with Close, which is idempotent.
   type Compiled is tagged limited private;

   --  Compile and validate a template.
   --
   --  @param Item Template to fill in; released first.
   --  @param Source Template text from model metadata.
   --  @param Bounds Model limits that bound the template size.
   --  @param Status Success, Template_Too_Large, Template_Syntax_Error,
   --    Template_Unsupported_Construct, Template_Unknown_Variable,
   --    Template_Nesting_Too_Deep or Template_Unbalanced_Block.
   procedure Compile
     (Item   : in out Compiled;
      Source : String;
      Bounds : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a compiled template.
   --
   --  @param Item Template to release.
   procedure Close (Item : in out Compiled);

   --  Report whether a template compiled successfully.
   --
   --  @param Item Template to inspect.
   --  @return True when Compile succeeded.
   function Is_Compiled (Item : Compiled) return Boolean;

   --  Render a conversation.
   --
   --  @param Item Compiled template.
   --  @param Messages Conversation to render.
   --  @param Beginning_Token Text substituted for bos_token.
   --  @param End_Token Text substituted for eos_token.
   --  @param Add_Generation_Prompt Value of add_generation_prompt.
   --  @param Target Buffer receiving the rendered prompt.
   --  @param Last Number of bytes written; 0 on failure.
   --  @param Status Success, Template_Output_Too_Large,
   --    Template_Iteration_Limit or Template_Missing.
   procedure Render
     (Item                  : Compiled;
      Messages              : Model_Runner.Conversation.History;
      Beginning_Token       : String;
      End_Token             : String;
      Add_Generation_Prompt : Boolean;
      Target                : out String;
      Last                  : out Natural;
      Status                : out Model_Runner.Errors.Error_Info);

private

   --  Where the value of a term comes from.
   type Term_Kind is
     (Term_Literal,
      Term_Beginning_Token,
      Term_End_Token,
      Term_Message_Role,
      Term_Message_Content,
      Term_Generation_Prompt,
      Term_Loop_First,
      Term_Loop_Last,
      Term_Loop_Index_Zero,
      Term_Loop_Index_One,

      --  A named message rather than the one being looped over:
      --  messages[0]['role'] and its like. Offset carries the index, counted
      --  from zero as the template writes it.
      Term_Indexed_Role,
      Term_Indexed_Content);

   type Term is record
      Kind   : Term_Kind := Term_Literal;
      Offset : Natural := 0;
      Length : Natural := 0;
   end record;

   type Term_Array is array (1 .. Max_Terms) of Term;

   --  One side of a comparison, or the whole clause when there is no operator.
   type Operand is record
      Terms : Term_Array := [others => <>];
      Count : Natural := 0;
   end record;

   type Comparison_Kind is (Compare_None, Compare_Equal, Compare_Not_Equal);

   type Clause is record
      Negated : Boolean := False;
      Left    : Operand;
      Operator : Comparison_Kind := Compare_None;
      Right   : Operand;
   end record;

   Max_Clauses : constant := 8;

   type Clause_Array is array (1 .. Max_Clauses) of Clause;

   --  Conjunctions joined by 'or'. Each conjunction is a run of clauses joined
   --  by 'and', which is the tighter operator.
   type Conjunction is record
      First : Natural := 0;
      Count : Natural := 0;
   end record;

   Max_Conjunctions : constant := 4;

   type Conjunction_Array is array (1 .. Max_Conjunctions) of Conjunction;

   type Condition is record
      Clauses     : Clause_Array := [others => <>];
      Clause_Used : Natural := 0;
      Groups      : Conjunction_Array := [others => <>];
      Group_Used  : Natural := 0;
   end record;

   type Opcode is
     (Op_Text,          --  emit a literal slice
      Op_Output,        --  emit an evaluated operand
      Op_For_Begin,     --  start iterating messages
      Op_For_Next,      --  advance, jumping back while more remain
      Op_Jump_If_False, --  skip a branch
      Op_Jump);         --  unconditional jump

   --  An instruction names its operand and its condition rather than
   --  carrying them.
   --
   --  A condition is six kilobytes -- eight clauses of two thirty-two term
   --  operands -- and an operand is four hundred bytes, while an instruction
   --  needs neither unless it is a jump or an output. Carried inline, the
   --  fixed program of four thousand instructions came to twenty-six
   --  megabytes, allocated and initialised on every compile. Held to one
   --  side and pointed at, the program is a hundred kilobytes and the side
   --  tables are as long as the template actually needs.
   type Instruction is record
      Op      : Opcode := Op_Text;
      Offset  : Natural := 0;
      Length  : Natural := 0;
      Target  : Natural := 0;

      --  Positions in the compiled template's operand and condition tables,
      --  or zero when this instruction has none.
      Value_At : Natural := 0;
      Test_At  : Natural := 0;
   end record;

   type Instruction_Array is array (1 .. Max_Instructions) of Instruction;

   type Operand_Array is array (Positive range <>) of Operand;
   type Operand_Array_Access is access Operand_Array;

   type Condition_Array is array (Positive range <>) of Condition;
   type Condition_Array_Access is access Condition_Array;
   type Instruction_Access is access Instruction_Array;

   type Text_Access is access String;

   type Compiled is limited new Ada.Finalization.Limited_Controlled with record
      Ready        : Boolean := False;
      Program      : Instruction_Access := null;
      Program_Used : Natural := 0;
      Source       : Text_Access := null;
      Source_Used  : Natural := 0;

      --  Grown as the template needs them, rather than sized for the largest
      --  program the engine will accept.
      Operands      : Operand_Array_Access := null;
      Operand_Used  : Natural := 0;
      Conditions    : Condition_Array_Access := null;
      Condition_Used : Natural := 0;

      --  Taken from the bounds this was compiled with, so that rendering
      --  needs no bounds of its own.
      Step_Limit   : Positive := Max_Iterations;
   end record;

   overriding procedure Finalize (Item : in out Compiled);

end Model_Runner.Templates;
