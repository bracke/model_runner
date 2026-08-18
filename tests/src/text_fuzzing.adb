with Ada.Calendar;

with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Tokenizer;

with BPE_Vocabulary;
with Tiny_Model;

package body Text_Fuzzing is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package Containers renames Model_Runner.GGUF.Containers;
   package Vocab renames Model_Runner.Tokenizer;

   use type E.Error_Code;

   --  The codes Encode says it can report. Anything else is a defect in the
   --  interface or in this list, and either way is worth stopping for.
   function Documented (Code : E.Error_Code) return Boolean
   is (Code in E.Tokenizer_Invalid_Vocabulary
             | E.Tokenizer_Invalid_UTF8
             | E.Tokenizer_Input_Too_Long
             | E.Tokenizer_Buffer_Too_Small
             | E.Tokenizer_Missing_Byte_Fallback);

   --  How long text of a given length may take. Encoding is meant to be
   --  roughly linear in the text, so the limit is too, with a floor that a
   --  loaded machine cannot trip on its own. The old scan was six hundred
   --  times over this on text of brackets.
   function Limit (Length : Natural) return Duration
   is (0.050 + Duration (Length) * 0.000_02);

   --  A small deterministic generator. The same seed and case number produce
   --  the same text on every machine, so a failure replays.
   type Generator is record
      State : Interfaces.Unsigned_64 := 0;
   end record;

   procedure Start
     (Item : out Generator; Seed : Interfaces.Unsigned_64; Number : Positive)
   is
      use type Interfaces.Unsigned_64;
   begin
      Item.State :=
        Seed * 6_364_136_223_846_793_005
        + Interfaces.Unsigned_64 (Number) * 1_442_695_040_888_963_407 + 1;
   end Start;

   function Next (Item : in out Generator; Bound : Positive) return Natural is
      use type Interfaces.Unsigned_64;
   begin
      Item.State :=
        Item.State * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407;
      return Natural ((Item.State / 65_536) mod Interfaces.Unsigned_64 (Bound));
   end Next;

   --  What a case is made of.
   --
   --  The alphabet is chosen against the code rather than at random: brackets
   --  and bars because that is where the marker scan runs, the pieces the
   --  fixtures carry because text made of nothing they know never reaches a
   --  merge, whitespace and digits because the cutting rules turn on them,
   --  and lead bytes with no continuation because that is what an invalid
   --  UTF-8 refusal is for.
   Alphabet : constant String :=
     "<|>abcx12 " & Character'Val (9) & Character'Val (10) & "/s_time'";

   --  The same alphabet with the bracket made common. A cost paid per
   --  bracket is invisible in text where one character in twenty is one, so
   --  the longest cases are drawn from this instead: it is the shape an
   --  attacker would send, and drawing it by chance would need a campaign
   --  far longer than the gate can afford.
   Dense_Alphabet : constant String := "<<<<<<|>abcs_";

   --  Long enough that a cost growing faster than the text shows up as time
   --  rather than as a rounding difference. The scan this campaign was
   --  written for cost about four tenths of a millisecond per bracket, which
   --  is nothing on a hundred characters and seventeen seconds on forty
   --  thousand.
   Max_Text : constant := 40_000;

   --  One case: build text, encode it, and judge what came back.
   function Run_Case
     (Words  : Vocab.Vocabulary;
      Seed   : Interfaces.Unsigned_64;
      Number : Positive;
      Took   : out Duration) return Outcome
   is
      use type Ada.Calendar.Time;

      Random : Generator;
      Room   : String (1 .. Max_Text);
      Length : Natural;
      Dense  : Boolean := False;
   begin
      Start (Random, Seed, Number);

      --  Lengths are drawn so that most cases are short and a few are long:
      --  the long ones are where a cost that grows faster than the text
      --  shows itself, and the short ones are where the cutting rules and
      --  the merges have room to differ.
      case Next (Random, 8) is
         when 0 => Length := Next (Random, 8) + 1;
         when 1 => Length := Next (Random, 64) + 1;
         when 2 => Length := Next (Random, 512) + 1;
         when 7 =>
            Length := Next (Random, Max_Text) + 1;
            Dense := True;
         when others => Length := Next (Random, 4_000) + 1;
      end case;

      --  Mostly the alphabet above, sometimes a whole two-byte character --
      --  the stand-in alphabet and the word marker are made of those -- and
      --  now and then a lead byte with nothing after it, which is what the
      --  refusal for text that is not UTF-8 exists to catch. Rarely, because
      --  a campaign in which almost every case is refused before the merge
      --  loop tests the refusal and nothing else.
      declare
         Filled : Natural := 0;

         --  Whether this case is meant to be refused, decided once. Deciding
         --  it per character made every long case invalid, so the long ones
         --  -- the only ones that can show a cost growing faster than the
         --  text -- never reached the merges at all.
         Broken : constant Boolean := Next (Random, 8) = 0;
      begin
         while Filled < Length loop
            case Next (Random, 64) is
               when 0 =>
                  --  A lead byte with nothing after it, in a case meant to
                  --  be refused. Skipped rather than exited in one that is
                  --  not: exiting here cut every case to about sixty
                  --  characters, which is how a campaign can report four
                  --  hundred clean cases and have tested nothing long.
                  Filled := Filled + 1;
                  Room (Filled) :=
                    (if Broken then Character'Val (16#C4#)
                     else Alphabet (Alphabet'First));

               when 1 .. 4 =>
                  exit when Filled + 2 > Length;
                  Room (Filled + 1) := Character'Val (16#C4#);
                  Room (Filled + 2) :=
                    Character'Val (16#80# + Next (Random, 64));
                  Filled := Filled + 2;

               when others =>
                  Filled := Filled + 1;
                  Room (Filled) :=
                    (if Dense
                     then Dense_Alphabet
                            (Dense_Alphabet'First
                             + Next (Random, Dense_Alphabet'Length))
                     else Alphabet
                            (Alphabet'First
                             + Next (Random, Alphabet'Length)));
            end case;
         end loop;

         Length := Filled;
      end;

      declare
         Text   : constant String := Room (1 .. Length);
         Tokens : Vocab.Token_Array (1 .. Length * 2 + 2);
         Last   : Natural;
         Status : E.Error_Info;
         Begun  : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      begin
         Vocab.Encode
           (Words, Text,
            Add_Beginning => Number mod 2 = 0,
            Add_End       => Number mod 3 = 0,
            Target        => Tokens,
            Last          => Last,
            Status        => Status);
         Took := Ada.Calendar.Clock - Begun;

         if Took > Limit (Length) then
            return Slow;
         end if;

         if E.Is_Error (Status) then
            return (if Documented (Status.Code) then Refused
                    else Undocumented);
         end if;

         for Index in 1 .. Last loop
            if not Vocab.Is_Valid (Words, Tokens (Index)) then
               return Out_Of_Range;
            end if;
         end loop;

         --  Whatever came back has to be readable as text without raising.
         --  It need not be the text that went in: a vocabulary this small
         --  spells almost nothing, so most of a case comes back as unknown.
         declare
            Back : constant String := Vocab.Decode (Words, Tokens (1 .. Last));
         begin
            --  The call is the check -- it must not raise -- and what it
            --  returns is deliberately unconstrained. Naming the result is
            --  what keeps the call from being discarded.
            pragma Warnings (Off, "if statement has no effect");
            if Back'Length > 0 or else Last = 0 then
               null;
            end if;
            pragma Warnings (On, "if statement has no effect");
         end;

         return Encoded;
      end;
   exception
      when others =>
         Took := 0.0;
         return Escaped;
   end Run_Case;

   ---------
   -- Run --
   ---------

   procedure Run
     (Seed   : Interfaces.Unsigned_64;
      Cases  : Positive;
      Result : out Report)
   is
      --  Both roads, from the fixtures this repository owns.
      procedure Campaign (Image : B.Byte_Array_Access; Offset : Natural) is
         Held   : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
           (Held'Access);
         Parsed : Containers.Container;
         Words  : Vocab.Vocabulary;
         Status : E.Error_Info;
      begin
         Containers.Reader.Parse (Parsed, Source, Status => Status);
         if E.Is_Error (Status) then
            Result.Escaped := Result.Escaped + 1;
            return;
         end if;

         Vocab.Load (Words, Parsed, Status => Status);
         if E.Is_Error (Status) then
            Result.Escaped := Result.Escaped + 1;
            Containers.Close (Parsed);
            return;
         end if;

         for Number in 1 .. Cases loop
            declare
               Took : Duration;
               What : constant Outcome :=
                 Run_Case (Words, Seed, Number, Took);
               Spent : constant Natural :=
                 Natural (Duration'Max (0.0, Took) * 1000.0);
            begin
               Result.Cases := Result.Cases + 1;

               if Spent > Result.Worst then
                  Result.Worst := Spent;
                  Result.Worst_Case := Offset + Number;
               end if;

               case What is
                  when Encoded => Result.Encoded := Result.Encoded + 1;
                  when Refused => Result.Refused := Result.Refused + 1;
                  when Escaped => Result.Escaped := Result.Escaped + 1;
                  when Undocumented =>
                     Result.Undocumented := Result.Undocumented + 1;
                  when Out_Of_Range =>
                     Result.Out_Of_Range := Result.Out_Of_Range + 1;
                  when Not_Reversible =>
                     Result.Not_Reversible := Result.Not_Reversible + 1;
                  when Slow => Result.Slow := Result.Slow + 1;
               end case;

               if What not in Encoded | Refused and then Result.First_Bad = 0
               then
                  Result.First_Bad := Offset + Number;
               end if;
            end;
         end loop;

         Vocab.Close (Words);
         Containers.Close (Parsed);
      end Campaign;

      Marked : B.Byte_Array_Access;
      Ranked : B.Byte_Array_Access;
   begin
      Result := (others => <>);

      Tiny_Model.Build (Marked);
      Campaign (Marked, 0);
      B.Free (Marked);

      BPE_Vocabulary.Build ("gpt-2", Ranked);
      Campaign (Ranked, Cases);
      B.Free (Ranked);
   end Run;

end Text_Fuzzing;
