with AUnit.Assertions; use AUnit.Assertions;

with Model_Runner.Errors;
with Model_Runner.Grammar;

package body Tests.Grammar_Cases is

   package E renames Model_Runner.Errors;
   package G renames Model_Runner.Grammar;

   use type E.Error_Code;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("output grammar");
   end Name;

   --  Compile a grammar and report whether a text is one it allows.
   --
   --  Accepts is asked about the whole text at once, which is what a token
   --  filter does with one token's text; a text of several tokens is fed a
   --  piece at a time by Advance, and both are exercised below.
   function Allows (Source, Text : String) return Boolean is
      Item   : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Result : Boolean;
   begin
      G.Compile (Item, Source, Status);
      Assert (E.Is_Ok (Status),
              "the grammar did not compile: "
              & E.Error_Code'Image (Status.Code) & " for " & Source);

      G.Start (Item, State, Status);
      Assert (E.Is_Ok (Status), "the grammar would not start");

      Result := G.Accepts (Item, State, Text);
      G.Close (Item);
      return Result;
   end Allows;

   --  And whether it is a complete text rather than a prefix of one.
   function Completes (Source, Text : String) return Boolean is
      Item   : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Result : Boolean;
   begin
      G.Compile (Item, Source, Status);
      Assert (E.Is_Ok (Status),
              "the grammar did not compile: "
              & E.Error_Code'Image (Status.Code) & " for " & Source);

      G.Start (Item, State, Status);
      Assert (E.Is_Ok (Status), "the grammar would not start");

      G.Advance (Item, State, Text, Status);
      if E.Is_Error (Status) then
         G.Close (Item);
         return False;
      end if;

      Result := G.Is_Complete (Item, State);
      G.Close (Item);
      return Result;
   end Completes;

   --  The code a grammar is refused with.
   function Refusal (Source : String) return E.Error_Code is
      Item   : G.Compiled;
      Status : E.Error_Info;
   begin
      G.Compile (Item, Source, Status);
      G.Close (Item);
      return Status.Code;
   end Refusal;

   --  Each construct of the notation means what it says.
   procedure Notation_Means_What_It_Says
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  Literals and sequences.
      Assert (Allows ("root ::= ""ab""", "ab"), "a literal was refused");
      Assert (not Allows ("root ::= ""ab""", "ac"),
              "a literal accepted text it does not spell");
      Assert (Allows ("root ::= ""ab""", "a"),
              "a prefix of a literal was refused; a token filter has to "
              & "allow the first half of a word before the second arrives");
      Assert (not Completes ("root ::= ""ab""", "a"),
              "half a literal was reported as a complete text");

      --  Alternatives.
      Assert (Allows ("root ::= ""a"" | ""b""", "b"),
              "the second alternative was refused");
      Assert (not Allows ("root ::= ""a"" | ""b""", "c"),
              "an alternative nobody wrote was allowed");

      --  Sets, ranges and their complement.
      Assert (Allows ("root ::= [a-c]", "b"), "a range was refused");
      Assert (not Allows ("root ::= [a-c]", "d"),
              "a range accepted what is outside it");
      Assert (Allows ("root ::= [^a-c]", "d"),
              "a complement refused what is outside the range");
      Assert (not Allows ("root ::= [^a-c]", "b"),
              "a complement accepted what is inside the range");

      --  Repetition.
      Assert (Allows ("root ::= [a-c]+", "abc"), "one-or-more was refused");
      Assert (not Completes ("root ::= [a-c]+", ""),
              "one-or-more was complete with none");
      Assert (Completes ("root ::= [a-c]*", ""),
              "none-or-more was not complete with none");
      Assert (Completes ("root ::= ""a""? ""b""", "b"),
              "an optional was required");
      Assert (Completes ("root ::= ""a""? ""b""", "ab"),
              "an optional was refused when present");

      --  Counted repetition, which is where a bound has to be a bound.
      Assert (Completes ("root ::= ""a""{2}", "aa"),
              "exactly two was refused");
      Assert (not Completes ("root ::= ""a""{2}", "a"),
              "exactly two accepted one");
      Assert (not Allows ("root ::= ""a""{2}", "aaa"),
              "exactly two accepted three");
      Assert (Completes ("root ::= ""a""{2,3}", "aaa"),
              "two-to-three refused three");
      Assert (not Allows ("root ::= ""a""{2,3}", "aaaa"),
              "two-to-three accepted four");
      Assert (Allows ("root ::= ""a""{2,}", "aaaaa"),
              "two-or-more refused five");

      --  Grouping and references, including one written after its use.
      Assert (Completes ("root ::= (""a"" | ""b"") ""c""", "bc"),
              "a group was not read as one item");
      Assert (Completes
                ("root ::= greeting" & ASCII.LF & "greeting ::= ""hi""", "hi"),
              "a rule written after its use was refused");

      --  Escapes, and code points rather than bytes.
      Assert (Completes ("root ::= ""a\nb""", "a" & ASCII.LF & "b"),
              "an escape was not decoded");
      --  Written as a code point rather than as the two bytes it encodes
      --  to, and matched against those bytes: what a set holds is code
      --  points, whatever the tokenizer hands over.
      Assert (Completes ("root ::= [\u00E6]",
                         String'(1 => Character'Val (16#C3#),
                                 2 => Character'Val (16#A6#))),
              "a code point escape did not match its UTF-8");
      Assert (not Allows ("root ::= [\u00E6]",
                          String'(1 => Character'Val (16#C3#))),
              "half of a code point's bytes was matched");
      Assert (not Allows ("root ::= [a-z]",
                          String'(1 => Character'Val (16#FF#))),
              "a byte that is not UTF-8 was matched against a set");

      --  Comments and whitespace between the tokens of the notation.
      Assert (Completes ("# what this is" & ASCII.LF & "root ::= ""a""", "a"),
              "a comment was not skipped");
   end Notation_Means_What_It_Says;

   --  A grammar this build cannot read is refused by name.
   procedure Refusals_Name_What_Was_Wrong
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Refusal ("thing ::= ""a""") = E.Grammar_Missing_Root,
              "a grammar with no root was accepted");
      Assert (Refusal ("root ::= other") = E.Grammar_Unknown_Rule,
              "a reference to a rule nobody wrote was accepted");
      Assert (Refusal ("root ::= ""unterminated") = E.Grammar_Syntax_Error,
              "an unterminated literal was accepted");
      Assert (Refusal ("root ::= [a-") = E.Grammar_Syntax_Error,
              "an unterminated set was accepted");
      Assert (Refusal ("root ::= (""a""") = E.Grammar_Syntax_Error,
              "an unclosed group was accepted");
      Assert (Refusal ("root ""a""") = E.Grammar_Syntax_Error,
              "a rule with no ::= was accepted");
      Assert (Refusal ("root ::= ""a"" root ::= ""b""")
                = E.Grammar_Syntax_Error,
              "a rule defined twice was accepted");
      Assert (Refusal ("root ::= ""a\q""") = E.Grammar_Syntax_Error,
              "an escape nobody defines was accepted");

      --  The bounds. Each is a refusal rather than an allocation.
      declare
         Deep : String (1 .. 2 * G.Max_Rules) := [others => ' '];
      begin
         for Index in 1 .. G.Max_Rules loop
            Deep (2 * Index - 1) := '(';
            Deep (2 * Index) := ' ';
         end loop;
         Assert (Refusal ("root ::= " & Deep) in E.Grammar_Nesting_Too_Deep
                                              | E.Grammar_Syntax_Error
                                              | E.Grammar_Too_Large,
                 "unbounded nesting was accepted");
      end;
   end Refusals_Name_What_Was_Wrong;

   --  A grammar that compiles and still cannot be matched is refused when
   --  it is asked for, not when it is read.
   --
   --  Depth at the point of matching is not depth in the text: a chain of
   --  rules, each with something after the reference, has to remember a
   --  return address for every link, and past a point there is nowhere to
   --  remember it. That is a bound the compiler cannot see, because the
   --  grammar itself is small.
   procedure Matching_Bounds_Are_Reached
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      Links : constant Natural := G.Max_Depth + 8;

      Source : String (1 .. 64 * (Links + 2)) := [others => ' '];
      Used   : Natural := 0;

      procedure Put (Text : String) is
      begin
         Source (Used + 1 .. Used + Text'Length) := Text;
         Used := Used + Text'Length;
      end Put;

      --  A number without the space Ada puts in front of it.
      function Digits_Of (Value : Natural) return String is
         Text : constant String := Natural'Image (Value);
      begin
         return Text (Text'First + 1 .. Text'Last);
      end Digits_Of;

      Item   : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
   begin
      Put ("root ::= r1" & ASCII.LF);
      for Index in 1 .. Links loop
         Put ("r" & Digits_Of (Index) & " ::= r" & Digits_Of (Index + 1)
              & " ""x""" & ASCII.LF);
      end loop;
      Put ("r" & Digits_Of (Links + 1) & " ::= ""y""");

      G.Compile (Item, Source (1 .. Used), Status);
      Assert (E.Is_Ok (Status),
              "a grammar within every compile-time bound was refused: "
              & E.Error_Code'Image (Status.Code));

      G.Start (Item, State, Status);
      Assert (Status.Code = E.Grammar_Too_Ambiguous,
              "a grammar deeper than the matcher tracks was started: "
              & E.Error_Code'Image (Status.Code));

      G.Close (Item);
   end Matching_Bounds_Are_Reached;

   --  A grammar constrains what may come next, one token's text at a time.
   procedure Matching_Follows_The_Text
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  A small JSON-ish grammar, which is what these are usually for.
      Source : constant String :=
        "root ::= object" & ASCII.LF
        & "object ::= ""{"" ws pair (ws "","" ws pair)* ws ""}""" & ASCII.LF
        & "pair ::= string ws "":"" ws value" & ASCII.LF
        & "value ::= string | number | object" & ASCII.LF
        & "string ::= ""\"""" [a-z]* ""\""""" & ASCII.LF
        & "number ::= [0-9]+" & ASCII.LF
        & "ws ::= [ ]*";

      Item   : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
   begin
      G.Compile (Item, Source, Status);
      Assert (E.Is_Ok (Status),
              "the object grammar did not compile: "
              & E.Error_Code'Image (Status.Code));

      G.Start (Item, State, Status);
      Assert (E.Is_Ok (Status), "the object grammar would not start");

      --  Only one character can begin it, which is the whole point: every
      --  other token of the vocabulary is out of the distribution.
      Assert (G.Accepts (Item, State, "{"), "the opening brace was refused");
      Assert (not G.Accepts (Item, State, "["),
              "a bracket the grammar does not allow was accepted");
      Assert (not G.Accepts (Item, State, "x"),
              "a letter was allowed where a brace was required");
      Assert (not G.Is_Complete (Item, State),
              "an empty text was reported as a complete object");

      --  Fed a piece at a time, as generation feeds it.
      declare
         type Piece_Text is access constant String;

         Pieces : constant array (1 .. 6) of Piece_Text :=
           [new String'("{"), new String'("""ab"""), new String'(":"),
            new String'("12"), new String'(""), new String'("}")];
      begin
         for Piece of Pieces loop
            Assert (G.Accepts (Item, State, Piece.all),
                    "a piece the grammar allows was refused: " & Piece.all);
            G.Advance (Item, State, Piece.all, Status);
            Assert (E.Is_Ok (Status),
                    "advancing over an allowed piece failed: "
                    & E.Error_Code'Image (Status.Code));
         end loop;
      end;

      Assert (G.Is_Complete (Item, State),
              "a complete object was not reported as complete");

      --  And nothing may follow it.
      Assert (not G.Accepts (Item, State, "{"),
              "the grammar allowed a second object after the first");

      G.Close (Item);
   end Matching_Follows_The_Text;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Notation_Means_What_It_Says'Access,
         "each construct of the notation means what it says");
      Register_Routine
        (T, Refusals_Name_What_Was_Wrong'Access,
         "a grammar this build cannot read is refused by name");
      Register_Routine
        (T, Matching_Bounds_Are_Reached'Access,
         "a grammar that compiles and cannot be matched is refused when it "
         & "is asked for");
      Register_Routine
        (T, Matching_Follows_The_Text'Access,
         "a grammar constrains what may come next, one text at a time");
   end Register_Tests;

end Tests.Grammar_Cases;
