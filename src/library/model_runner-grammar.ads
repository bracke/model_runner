private with Ada.Finalization;

with Model_Runner.Errors;

--  Bounded output grammars, in the GBNF notation.
--
--  A grammar says what the model is allowed to produce. At each step every
--  token the vocabulary holds is offered to the matcher, and the ones whose
--  text cannot continue the grammar are removed from the distribution before
--  anything is sampled. What comes out is text the grammar accepts, whatever
--  the model would have preferred.
--
--  This is a constraint and not a prompt. A model asked in words for JSON
--  answers with JSON most of the time; a model constrained by a grammar
--  cannot answer with anything else, because the tokens that would say
--  otherwise are not in the distribution to be sampled from.
--
--  Supported notation
--
--    root ::= alternatives            a rule; one of them must be named root
--    a | b                            alternatives
--    a b                              a sequence
--    "text"                           a literal, with \n \r \t \\ \" \'
--                                     and \xNN \uNNNN escapes
--    [abc] [a-z] [^abc]               a set of code points, or its complement
--    ( ... )                          grouping
--    x? x* x+                         none-or-one, none-or-more, one-or-more
--    x{2} x{2,} x{2,5}                a counted repetition
--    # comment                        to the end of the line
--
--  Everything else is refused where it is met rather than approximated. A
--  grammar that reaches for a construct this does not read is malformed as
--  far as this parser is concerned and says where: there is no construct it
--  recognizes and then declines, so there is no separate refusal for one.
--  In particular there are no lookaheads, no back-references and no
--  character classes named by escape.
--
--  Code points, not bytes. A literal and a set are matched against the code
--  points a token decodes to, so `[a-ø]` means what it says whatever the
--  model's tokenizer does with the bytes.
--
--  Bounded everywhere. The rules, the elements they compile to, the depth of
--  a stack and the number of stacks tracked at once all have limits, and a
--  grammar that exceeds one is refused rather than allocating to fit it. A
--  grammar is untrusted input: it comes from a command line or a file.
--
--  Ambiguity. A grammar that can continue several ways at once is tracked as
--  several stacks, and there is a bound on how many. It is generous enough
--  for the grammars people write and it is a refusal rather than a slowdown
--  when it is reached, because the alternative is a matcher whose cost the
--  caller cannot predict.
--
--  Task safety: a Compiled grammar is immutable once compiled and may be
--  read concurrently. A Matcher holds the state of one generation.
package Model_Runner.Grammar is

   --  Largest number of rules a grammar may define.
   Max_Rules : constant := 256;

   --  Largest number of compiled elements, across every rule.
   Max_Elements : constant := 8192;

   --  Largest number of code-point ranges, across every set.
   Max_Ranges : constant := 2048;

   --  Largest number of characters in every rule name together.
   Max_Names : constant := 4096;

   --  How deep one stack may be, which bounds how deeply rules may nest at
   --  the point of matching rather than in the text.
   Max_Depth : constant := 64;

   --  How many ways the grammar may be in the middle of at once.
   Max_Stacks : constant := 256;

   --  A compiled grammar.
   type Compiled is tagged limited private;

   --  Compile a grammar from its source.
   --
   --  @param Item Grammar to fill; released first.
   --  @param Source Grammar text.
   --  @param Status Success, or the first diagnostic that stopped it.
   procedure Compile
     (Item   : in out Compiled;
      Source : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a compiled grammar. Idempotent.
   --
   --  @param Item Grammar to release.
   procedure Close (Item : in out Compiled);

   --  Report whether a grammar compiled.
   --
   --  @param Item Grammar to inspect.
   --  @return True when it is usable.
   function Is_Ready (Item : Compiled) return Boolean;

   --  Where a generation has got to in a grammar.
   type Matcher is private;

   --  The state at the beginning of a generation.
   --
   --  @param Item Compiled grammar.
   --  @param State Receives the starting state.
   --  @param Status Success, or Grammar_Too_Ambiguous.
   procedure Start
     (Item   : Compiled;
      State  : out Matcher;
      Status : out Model_Runner.Errors.Error_Info);

   --  Report whether a text may follow, from a given state.
   --
   --  The text is what a token contributes. A token whose text cannot be
   --  matched is one the grammar does not allow next, and it is removed from
   --  the distribution rather than sampled and regretted.
   --
   --  Invalid UTF-8 is not accepted: a byte sequence that is not a code
   --  point cannot match a rule written in code points.
   --
   --  @param Item Compiled grammar.
   --  @param State State to test from.
   --  @param Text Text the token contributes.
   --  @return True when the text may follow.
   function Accepts
     (Item  : Compiled;
      State : Matcher;
      Text  : String) return Boolean;

   --  Advance the state over a text that Accepts allowed.
   --
   --  @param Item Compiled grammar.
   --  @param State State to advance.
   --  @param Text Text the token contributed.
   --  @param Status Success, Grammar_Syntax_Error when the text does not
   --    match after all, or Grammar_Too_Ambiguous.
   procedure Advance
     (Item   : Compiled;
      State  : in out Matcher;
      Text   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Report whether the grammar may end here.
   --
   --  A generation that stops where this is False stops in the middle of
   --  something the grammar was still expecting.
   --
   --  @param Item Compiled grammar.
   --  @param State State to inspect.
   --  @return True when every element has been matched on some path.
   function Is_Complete
     (Item  : Compiled;
      State : Matcher) return Boolean;

private

   --  A code point, as a grammar matches them.
   type Code_Point is range 0 .. 16#10FFFF#;

   --  One range of code points. A set is a run of these plus a flag saying
   --  whether membership is inverted.
   type Range_Entry is record
      Low  : Code_Point := 0;
      High : Code_Point := 0;
   end record;

   type Range_Array is array (1 .. Max_Ranges) of Range_Entry;

   --  What one element of a rule is.
   --
   --  Characters and references are what a text is matched against; the two
   --  markers are what tell one alternative from the next and one rule from
   --  the next. Keeping them in the element array rather than in a table of
   --  their own is what lets a position in a rule be one index.
   type Element_Kind is (Element_Char, Element_Reference, Element_Alt,
                         Element_End);

   type Element is record
      Kind : Element_Kind := Element_End;

      --  For a character set: where its ranges start and how many, and
      --  whether the set is the complement of them.
      First    : Natural := 0;
      Count    : Natural := 0;
      Inverted : Boolean := False;

      --  For a reference: which rule.
      Rule : Natural := 0;
   end record;

   type Element_Array is array (1 .. Max_Elements) of Element;

   --  Where a rule's elements begin, and what it is called.
   type Rule_Entry is record
      Start : Natural := 0;
      Name_First : Natural := 0;
      Name_Last  : Natural := 0;
   end record;

   type Rule_Array is array (1 .. Max_Rules) of Rule_Entry;

   type Compiled is new Ada.Finalization.Limited_Controlled with record
      Ready    : Boolean := False;
      Rules    : Rule_Array;
      Rule_Used : Natural := 0;
      Elements : Element_Array;
      Element_Used : Natural := 0;
      Ranges   : Range_Array;
      Range_Used : Natural := 0;
      Names    : String (1 .. Max_Names) := [others => ' '];
      Name_Used : Natural := 0;
      Root     : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Compiled);

   --  One way the grammar may be in the middle of: a stack of element
   --  positions, innermost last. The top is the element to match next; the
   --  rest are where to return to when the rule it belongs to ends.
   type Position_Stack is array (1 .. Max_Depth) of Natural;

   type Stack_Entry is record
      Depth : Natural := 0;
      Slots : Position_Stack := [others => 0];
   end record;

   type Stack_Array is array (1 .. Max_Stacks) of Stack_Entry;

   type Matcher is record
      Count  : Natural := 0;
      Stacks : Stack_Array;
   end record;

end Model_Runner.Grammar;
