with Ada.Unchecked_Deallocation;
with Ada.Wide_Wide_Characters.Handling;

with Model_Runner.Errors;
with Model_Runner.Numerics;

package body Reference_Tokenizer is

   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;

   procedure Free is new Ada.Unchecked_Deallocation
     (Piece_Array, Piece_Array_Access);

   procedure Free is new Ada.Unchecked_Deallocation
     (Merge_Array, Merge_Array_Access);

   --  The word marker: U+2581, which this format puts where a space was.
   Marker : constant String :=
     [Character'Val (16#E2#), Character'Val (16#96#), Character'Val (16#81#)];

   ----------
   -- Load --
   ----------

   procedure Load
     (Item   : in out Vocabulary;
      Source : Containers.Container;
      Loaded : out Boolean)
   is
      Status : E.Error_Info;
      Count  : Natural := 0;
   begin
      Close (Item);
      Loaded := False;

      for Index in 1 .. Containers.Metadata_Count (Source) loop
         if Containers.Metadata_Key (Source, Index) = "tokenizer.ggml.tokens"
         then
            Count := Containers.Metadata_Length (Source, Index);
         end if;
      end loop;

      if Count = 0 or else Count > Max_Pieces then
         return;
      end if;

      Item.Pieces := new Piece_Array;
      Item.Count := Count;

      for Index in 1 .. Count loop
         declare
            Room : String (1 .. Max_Piece);
            Last : Natural;
         begin
            Containers.Get_String_Element
              (Source, "tokenizer.ggml.tokens", Index, Room, Last, Status);
            if E.Is_Error (Status) then
               Close (Item);
               return;
            end if;

            Item.Pieces (Index).Last := Last;
            Item.Pieces (Index).Text (1 .. Last) := Room (1 .. Last);
         end;

         declare
            Score : Model_Runner.Numerics.Wide_Real;
            Sort  : Long_Long_Integer;
         begin
            Containers.Get_Float_Element
              (Source, "tokenizer.ggml.scores", Index, Score, Status);
            Item.Pieces (Index).Score :=
              (if E.Is_Error (Status) then 0.0 else Float (Score));

            Containers.Get_Integer_Element
              (Source, "tokenizer.ggml.token_type", Index, Sort, Status);
            Item.Pieces (Index).Sort :=
              (if E.Is_Error (Status) or else Sort < 0 then 0
               else Natural (Sort));
         end;
      end loop;

      --  The two identifiers this needs by name. A vocabulary without them
      --  is still usable; the caller asks for no beginning token and an
      --  unknown character then has nowhere to go, which is reported by
      --  producing nothing rather than by inventing an identifier.
      declare
         Value : Long_Long_Integer;
      begin
         Containers.Get_Integer
           (Source, "tokenizer.ggml.bos_token_id", 0, 1_000_000, Value,
            Status);
         Item.Beginning := (if E.Is_Error (Status) then -1
                            else Integer (Value));

         Containers.Get_Integer
           (Source, "tokenizer.ggml.unknown_token_id", 0, 1_000_000, Value,
            Status);
         Item.Unknown := (if E.Is_Error (Status) then -1
                          else Integer (Value));
      end;

      --  Which tokenizer this is, and for a byte-pair one which rule cuts
      --  the text and what the merge table holds.
      declare
         Name : constant String :=
           Containers.String_Value (Source, "tokenizer.ggml.model");
      begin
         if Name = "llama" then
            Item.Model := SentencePiece;
         elsif Name = "gpt2" then
            Item.Model := Byte_Pair;
         elsif Name = "bert" then
            Item.Model := Word_Piece;
         else
            Item.Model := Unreadable;
         end if;
      end;

      if Item.Model = Byte_Pair then
         declare
            Cutting : constant String :=
              Containers.String_Value (Source, "tokenizer.ggml.pre");
            Ranks   : Natural := 0;
         begin
            if Cutting = "" or else Cutting = "gpt-2"
              or else Cutting = "starcoder"
            then
               Item.Cutting := GPT2;
            elsif Cutting = "falcon" then
               Item.Cutting := Falcon;
            elsif Cutting = "smollm" then
               Item.Cutting := SmolLM;
            elsif Cutting = "llama3" or else Cutting = "llama-bpe" then
               Item.Cutting := Llama3;
            elsif Cutting = "qwen2" then
               Item.Cutting := Qwen2;
            else
               Item.Model := Unreadable;
               Close (Item);
               return;
            end if;

            for Index in 1 .. Containers.Metadata_Count (Source) loop
               if Containers.Metadata_Key (Source, Index)
                 = "tokenizer.ggml.merges"
               then
                  Ranks := Containers.Metadata_Length (Source, Index);
               end if;
            end loop;

            if Ranks = 0 or else Ranks > Max_Merges then
               Close (Item);
               return;
            end if;

            Item.Merges := new Merge_Array;
            Item.Ranks := Ranks;

            for Index in 1 .. Ranks loop
               declare
                  Room : String (1 .. Max_Merge);
                  Last : Natural;
               begin
                  Containers.Get_String_Element
                    (Source, "tokenizer.ggml.merges", Index, Room, Last,
                     Status);
                  if E.Is_Error (Status) then
                     Close (Item);
                     return;
                  end if;

                  Item.Merges (Index).Last := Last;
                  Item.Merges (Index).Text (1 .. Last) := Room (1 .. Last);
               end;
            end loop;
         end;
      end if;

      Loaded := Item.Model /= Unreadable;
   end Load;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Vocabulary) is
   begin
      if Item.Pieces /= null then
         Free (Item.Pieces);
      end if;
      if Item.Merges /= null then
         Free (Item.Merges);
      end if;
      Item.Count := 0;
      Item.Ranks := 0;
      Item.Beginning := -1;
      Item.Unknown := -1;
      Item.Model := Unreadable;
   end Close;

   ----------
   -- Kind --
   ----------

   function Kind (Item : Vocabulary) return Model_Kind is (Item.Model);

   ----------
   -- Size --
   ----------

   function Size (Item : Vocabulary) return Natural is (Item.Count);

   --  The identifier of a piece, or -1. Scanned rather than looked up: this
   --  is meant to be obviously right, not quick.
   function Find (Item : Vocabulary; Text : String) return Integer is
   begin
      if Item.Pieces = null then
         return -1;
      end if;

      for Index in 1 .. Item.Count loop
         if Item.Pieces (Index).Last = Text'Length
           and then Item.Pieces (Index).Text (1 .. Item.Pieces (Index).Last)
                    = Text
         then
            return Index - 1;
         end if;
      end loop;

      return -1;
   end Find;

   --  The score of a piece, or the worst there is.
   function Score (Item : Vocabulary; Text : String) return Float is
      Which : constant Integer := Find (Item, Text);
   begin
      return (if Which < 0 then Float'First
              else Item.Pieces (Which + 1).Score);
   end Score;

   --  The longest piece starting at From that the vocabulary calls a control
   --  token or one of its author's own, with how many characters it spans.
   --  Only a position opening a bracket is tried, and the longest match wins.
   procedure Marker_At
     (Item   : Vocabulary;
      Text   : String;
      From   : Positive;
      Token  : out Integer;
      Length : out Natural) is
   begin
      Token := -1;
      Length := 0;

      if Text (From) /= '<' then
         return;
      end if;

      for Reach in 1 .. Natural'Min (Max_Piece, Text'Last - From + 1) loop
         declare
            Which : constant Integer :=
              Find (Item, Text (From .. From + Reach - 1));
         begin
            if Which >= 0 and then Item.Pieces (Which + 1).Sort in 3 | 4 then
               Token := Which;
               Length := Reach;
            end if;
         end;
      end loop;
   end Marker_At;

   --  SentencePiece: substitute, split, then merge by score.
   procedure Encode_By_Score
     (Item   : Vocabulary;
      Text   : String;
      Lead   : Boolean;
      Tokens : out Token_Vector;
      Last   : out Natural)
   is
      --  The text with every space replaced by the marker and one in front,
      --  which is what the format's own encoder does before it starts.
      Room : String (1 .. (Text'Length + 1) * 3);
      Used : Natural := 0;

      procedure Add (Value : String) is
      begin
         Room (Used + 1 .. Used + Value'Length) := Value;
         Used := Used + Value'Length;
      end Add;

      --  One symbol: a slice of the prepared text.
      type Symbol is record
         First  : Natural := 0;
         Length : Natural := 0;
         Live   : Boolean := False;
      end record;

      Symbols : array (1 .. Max_Tokens) of Symbol;
      Count   : Natural := 0;
   begin
      Last := 0;

      if Lead then
         Add (Marker);
      end if;

      for Index in Text'Range loop
         if Text (Index) = ' ' then
            Add (Marker);
         else
            Add (Text (Index .. Index));
         end if;
      end loop;

      --  One symbol per character, where a character is a UTF-8 sequence.
      declare
         Index : Natural := 1;
      begin
         while Index <= Used loop
            declare
               Lead : constant Natural := Character'Pos (Room (Index));
               Span : constant Natural :=
                 (if Lead < 16#80# then 1
                  elsif Lead < 16#E0# then 2
                  elsif Lead < 16#F0# then 3
                  else 4);
               Take : constant Natural := Natural'Min (Span, Used - Index + 1);
            begin
               Count := Count + 1;
               Symbols (Count) := (First => Index, Length => Take,
                                   Live => True);
               Index := Index + Take;
            end;
         end loop;
      end;

      --  Merge the best-scoring adjacent pair, over and over.
      loop
         declare
            Best_At    : Natural := 0;
            Best_Next  : Natural := 0;
            Best_Score : Float := Float'First;
            Left       : Natural := 0;
         begin
            for Index in 1 .. Count loop
               if Symbols (Index).Live then
                  if Left /= 0 then
                     declare
                        Joined : constant String :=
                          Room (Symbols (Left).First
                                .. Symbols (Left).First
                                   + Symbols (Left).Length - 1)
                          & Room (Symbols (Index).First
                                  .. Symbols (Index).First
                                     + Symbols (Index).Length - 1);
                     begin
                        if Find (Item, Joined) >= 0
                          and then Score (Item, Joined) > Best_Score
                        then
                           Best_Score := Score (Item, Joined);
                           Best_At := Left;
                           Best_Next := Index;
                        end if;
                     end;
                  end if;
                  Left := Index;
               end if;
            end loop;

            exit when Best_At = 0;

            Symbols (Best_At).Length :=
              Symbols (Best_At).Length + Symbols (Best_Next).Length;
            Symbols (Best_Next).Live := False;
         end;
      end loop;

      --  What is left is either a piece or a run of bytes.
      for Index in 1 .. Count loop
         if Symbols (Index).Live then
            declare
               Text_Of : constant String :=
                 Room (Symbols (Index).First
                       .. Symbols (Index).First + Symbols (Index).Length - 1);
               Which   : constant Integer := Find (Item, Text_Of);

               Digits_Of : constant String := "0123456789ABCDEF";
            begin
               if Which >= 0 then
                  Last := Last + 1;
                  Tokens (Last) := Which;
               else
                  for Position in Text_Of'Range loop
                     declare
                        Value : constant Natural :=
                          Character'Pos (Text_Of (Position));
                        Named : constant String :=
                          "<0x"
                          & Digits_Of (Digits_Of'First + Value / 16 + 1 - 1)
                          & Digits_Of (Digits_Of'First + Value mod 16 + 1 - 1)
                          & ">";
                        Byte  : constant Integer := Find (Item, Named);
                     begin
                        Last := Last + 1;
                        Tokens (Last) :=
                          (if Byte >= 0 then Byte else Item.Unknown);
                     end;
                  end loop;
               end if;
            end;
         end if;
      end loop;
   end Encode_By_Score;

   --  WordPiece: fold the text, cut it into words, spell each from the
   --  front with the longest piece the vocabulary carries.
   --
   --  Written from the description rather than from the engine's code, and
   --  it differs in how it does everything but the answer: it folds with the
   --  same standard-library operations because there is only one way to ask
   --  for those, it cuts by testing each code point in turn where the engine
   --  builds a folded copy as it goes, and it spells by scanning the
   --  vocabulary for the longest match where the engine hashes.
   procedure Encode_By_Piece
     (Item   : Vocabulary;
      Text   : String;
      Tokens : out Token_Vector;
      Last   : out Natural)
   is
      package Handling renames Ada.Wide_Wide_Characters.Handling;

      --  What a converted vocabulary marks a word's first piece with, which
      --  is the same U+2581 SentencePiece writes a space as. Written out
      --  here rather than taken from the engine, as everything else in this
      --  file is.
      Mark : constant String :=
        [Character'Val (16#E2#), Character'Val (16#96#),
         Character'Val (16#81#)];

      function Wide (Code : Natural) return Wide_Wide_Character
      is (Wide_Wide_Character'Val (Code));

      --  The blocks the architecture's own preprocessing names.
      function Ideograph (Code : Natural) return Boolean
      is (Code in 16#4E00# .. 16#9FFF#
          or else Code in 16#3400# .. 16#4DBF#
          or else Code in 16#20000# .. 16#2A6DF#
          or else Code in 16#2A700# .. 16#2B73F#
          or else Code in 16#2B740# .. 16#2B81F#
          or else Code in 16#2B820# .. 16#2CEAF#
          or else Code in 16#F900# .. 16#FAFF#
          or else Code in 16#2F800# .. 16#2FA1F#);

      function Punctuation (Code : Natural) return Boolean
      is (Code in 33 .. 47 or else Code in 58 .. 64
          or else Code in 91 .. 96 or else Code in 123 .. 126
          or else (Code > 127
                   and then Handling.Is_Punctuation_Connector (Wide (Code)))
          or else (Code > 127
                   and then not Handling.Is_Alphanumeric (Wide (Code))
                   and then Handling.Is_Graphic (Wide (Code))
                   and then not Handling.Is_Space (Wide (Code))
                   and then not Ideograph (Code)));

      --  One word at a time, built here and spelled before the next begins,
      --  which is the other way round from the engine: it cuts the whole
      --  text and then spells every word.
      Word : String (1 .. 512);
      Held : Natural := 0;

      --  Spell what is in Word, or give back the unknown token.
      procedure Spell is
         From  : Positive := 1;
         Marks : Token_Vector (1 .. 128);
         Count : Natural := 0;
      begin
         if Held = 0 then
            return;
         end if;

         while From <= Held loop
            declare
               Best      : Integer := -1;
               Best_Stop : Natural := 0;
            begin
               --  The longest piece the vocabulary carries that starts
               --  here, found by asking about every piece rather than by
               --  shortening a candidate.
               --  The pieces are held one-based and a piece's identifier
               --  is one below where it sits, which is what Find returns
               --  too.
               for Index in 1 .. Item.Count loop
                  declare
                     Piece : constant String :=
                       Item.Pieces (Index).Text
                         (1 .. Item.Pieces (Index).Last);

                     --  A piece that starts a word carries the marker and
                     --  one that continues a word does not, so which of
                     --  the two a position may take is decided here and
                     --  the marker never reaches the comparison.
                     Marked : constant Boolean :=
                       Piece'Length > Mark'Length
                       and then Piece (Piece'First
                                       .. Piece'First + Mark'Length - 1)
                                = Mark;

                     Body_Of : constant String :=
                       (if From = 1
                        then (if Marked
                              then Piece (Piece'First + Mark'Length
                                          .. Piece'Last)
                              else "")
                        else (if Marked then "" else Piece));
                  begin
                     if Body_Of'Length > 0
                       and then From + Body_Of'Length - 1 <= Held
                       and then Word (From .. From + Body_Of'Length - 1)
                                = Body_Of
                       and then From + Body_Of'Length - 1 > Best_Stop
                     then
                        Best := Index - 1;
                        Best_Stop := From + Body_Of'Length - 1;
                     end if;
                  end;
               end loop;

               if Best < 0 or else Count >= Marks'Last then
                  Count := 0;
                  exit;
               end if;

               Count := Count + 1;
               Marks (Count) := Best;
               From := Best_Stop + 1;
            end;
         end loop;

         if Count = 0 then
            Last := Last + 1;
            Tokens (Tokens'First + Last - 1) := Item.Unknown;
         else
            for Index in 1 .. Count loop
               Last := Last + 1;
               Tokens (Tokens'First + Last - 1) := Marks (Index);
            end loop;
         end if;

         Held := 0;
      end Spell;

      --  UTF-8 read and written here rather than through the engine's
      --  reader. That is the whole point of a second implementation: a
      --  mistake in one is unlikely to be the same mistake in the other,
      --  and sharing the decoder would make the two agree about every text
      --  the decoder reads wrongly.
      function Written (Code : Natural) return String
      is (if Code < 16#80#
          then [1 => Character'Val (Code)]
          elsif Code < 16#800#
          then [Character'Val (16#C0# + Code / 16#40#),
                Character'Val (16#80# + Code mod 16#40#)]
          elsif Code < 16#1_0000#
          then [Character'Val (16#E0# + Code / 16#1000#),
                Character'Val (16#80# + (Code / 16#40#) mod 16#40#),
                Character'Val (16#80# + Code mod 16#40#)]
          else [Character'Val (16#F0# + Code / 16#4_0000#),
                Character'Val (16#80# + (Code / 16#1000#) mod 16#40#),
                Character'Val (16#80# + (Code / 16#40#) mod 16#40#),
                Character'Val (16#80# + Code mod 16#40#)]);

      --  The code point at a byte position, and how many bytes it took.
      procedure Read_One
        (At_Byte : Positive; Code : out Natural; Width : out Natural)
      is
         Lead : constant Natural := Character'Pos (Text (At_Byte));

         --  How many continuation bytes the lead announces.
         Extra : constant Natural :=
           (if Lead < 16#80# then 0
            elsif Lead >= 16#F0# then 3
            elsif Lead >= 16#E0# then 2
            elsif Lead >= 16#C0# then 1
            else 0);
      begin
         if Lead in 16#80# .. 16#BF#
           or else At_Byte + Extra > Text'Last
         then
            --  A stray continuation byte, or a sequence the text does not
            --  hold the whole of. Neither is text this can fold, and
            --  stopping is what the engine does with it too.
            Code := 0;
            Width := 0;
            return;
         end if;

         Code := (if Extra = 0 then Lead
                  elsif Extra = 1 then Lead - 16#C0#
                  elsif Extra = 2 then Lead - 16#E0#
                  else Lead - 16#F0#);

         for Step in 1 .. Extra loop
            Code := Code * 16#40#
              + (Character'Pos (Text (At_Byte + Step)) - 16#80#);
         end loop;

         Width := Extra + 1;
      end Read_One;

      --  Put one folded code point into the word being built.
      procedure Extend (Code : Natural) is
         One : constant String := Written (Code);
      begin
         if Held + One'Length <= Word'Last then
            Word (Held + 1 .. Held + One'Length) := One;
            Held := Held + One'Length;
         end if;
      end Extend;

      Index : Natural := Text'First;
   begin
      Last := 0;

      while Index <= Text'Last loop
         declare
            Code, Width : Natural;
         begin
            Read_One (Index, Code, Width);
            exit when Width = 0;
            Index := Index + Width;

            --  Whitespace separates words, which includes the separators
            --  that are not spaces: a line terminator ends a word as surely
            --  as a space does, and leaving it out would join the last word
            --  of one line to the first of the next.
            if Handling.Is_Space (Wide (Code))
              or else Handling.Is_Line_Terminator (Wide (Code))
              or else Code in 32 | 9 | 10 | 11 | 12 | 13
            then
               Spell;
            else
               declare
                  Folded : constant Natural :=
                    Wide_Wide_Character'Pos
                      (Handling.To_Lower (Handling.To_Basic (Wide (Code))));
               begin
                  if Handling.Is_Mark (Wide (Folded))
                    or else Folded = 0
                    or else Folded = 16#FFFD#
                    or else (Handling.Is_Control (Wide (Folded))
                             and then Folded not in 9 | 10 | 13)
                  then
                     null;
                  elsif Punctuation (Folded) or else Ideograph (Folded) then
                     Spell;
                     Extend (Folded);
                     Spell;
                  else
                     Extend (Folded);
                  end if;
               end;
            end if;
         end;
      end loop;

      Spell;
   end Encode_By_Piece;

   --  Byte-pair: cut, rewrite each byte, then merge by rank.
   --
   --  The cutting is the ASCII part of the rule and no more: every byte above
   --  127 counts as a letter here, where the engine asks the standard library
   --  for the Unicode category. They agree on ASCII, which is what the
   --  comparison uses; text outside it is the engine's own business and it
   --  refuses what it cannot cut faithfully.
   type Contraction is access constant String;

   procedure Encode_By_Rank
     (Item   : Vocabulary;
      Text   : String;
      Tokens : out Token_Vector;
      Last   : out Natural)
   is
      function Is_Letter (Value : Character) return Boolean
      is (Value in 'a' .. 'z' | 'A' .. 'Z'
          or else Character'Pos (Value) > 127);

      function Is_Digit (Value : Character) return Boolean
      is (Value in '0' .. '9');

      function Is_Space (Value : Character) return Boolean
      is (Value in ' ' | Character'Val (9) | Character'Val (10)
                 | Character'Val (11) | Character'Val (12)
                 | Character'Val (13));

      --  The character that stands for a byte. Bytes that print stand for
      --  themselves; the rest are moved above 255, in order, so that a merge
      --  table written as text can name every one of them.
      function Prints (Value : Natural) return Boolean
      is (Value in 33 .. 126 | 161 .. 172 | 174 .. 255);

      function Mapped (Value : Natural) return Natural is
         Moved : Natural := 0;
      begin
         if Prints (Value) then
            return Value;
         end if;

         for Earlier in 0 .. Value - 1 loop
            if not Prints (Earlier) then
               Moved := Moved + 1;
            end if;
         end loop;

         return 256 + Moved;
      end Mapped;

      --  A code point below 2048 as its UTF-8 bytes, which is as far as the
      --  mapping above ever reaches.
      function As_UTF8 (Value : Natural) return String
      is (if Value < 16#80# then [1 => Character'Val (Value)]
          else [Character'Val (16#C0# + Value / 16#40#),
                Character'Val (16#80# + Value mod 16#40#)]);

      --  Where the pre-token starting at From ends.
      function Cut_Last (From : Positive) return Natural is
         Ones : constant array (1 .. 7) of Contraction :=
           [new String'("'s"), new String'("'t"), new String'("'re"),
            new String'("'ve"), new String'("'m"), new String'("'ll"),
            new String'("'d")];

         At_Index : Natural := From;

         function Follows return Character
         is (if At_Index < Text'Last then Text (At_Index + 1)
             else Character'Val (0));

         function Has_More return Boolean is (At_Index < Text'Last);
      begin
         for One of Ones loop
            if From + One'Length - 1 <= Text'Last
              and then Text (From .. From + One'Length - 1) = One.all
            then
               return From + One'Length - 1;
            end if;
         end loop;

         --  What may lead a run, which depends on the rule and on what the
         --  run is made of.
         if Has_More and then not Is_Space (Follows) then
            if Is_Letter (Follows) then
               if (case Item.Cutting is
                      when GPT2 | Falcon | SmolLM => Text (At_Index) = ' ',
                      when Llama3 | Qwen2 =>
                        not Is_Letter (Text (At_Index))
                        and then not Is_Digit (Text (At_Index))
                        and then Text (At_Index) /= Character'Val (10)
                        and then Text (At_Index) /= Character'Val (13))
               then
                  At_Index := At_Index + 1;
               end if;

            elsif Is_Digit (Follows) then
               if Item.Cutting in GPT2 | Falcon
                 and then Text (At_Index) = ' '
               then
                  At_Index := At_Index + 1;
               end if;

            elsif Text (At_Index) = ' ' then
               At_Index := At_Index + 1;
            end if;
         end if;

         if Is_Letter (Text (At_Index)) then
            while Has_More and then Is_Letter (Follows) loop
               At_Index := At_Index + 1;
            end loop;

         elsif Is_Digit (Text (At_Index)) then
            declare
               Room : Natural :=
                 (case Item.Cutting is
                     when GPT2 => Natural'Last,
                     when Falcon | Llama3 => 3,
                     when SmolLM | Qwen2 => 1) - 1;
            begin
               while Room > 0 and then Has_More and then Is_Digit (Follows)
               loop
                  At_Index := At_Index + 1;
                  Room := Room - 1;
               end loop;
            end;

         elsif Is_Space (Text (At_Index)) then
            declare
               Began : constant Natural := At_Index;
            begin
               while Has_More and then Is_Space (Follows) loop
                  At_Index := At_Index + 1;
               end loop;

               --  A run of spaces gives its last one back to the word after
               --  it, unless the run is what the text ends with.
               if At_Index < Text'Last and then At_Index > Began then
                  At_Index := At_Index - 1;
               end if;
            end;

         else
            while Has_More and then not Is_Letter (Follows)
              and then not Is_Digit (Follows) and then not Is_Space (Follows)
            loop
               At_Index := At_Index + 1;
            end loop;
         end if;

         return At_Index;
      end Cut_Last;

      --  The rank of a pair, or zero when the table does not hold it.
      function Rank_Of (Left, Right : String) return Natural is
         Key : constant String := Left & " " & Right;
      begin
         for Index in 1 .. Item.Ranks loop
            if Item.Merges (Index).Last = Key'Length
              and then Item.Merges (Index).Text (1 .. Item.Merges (Index).Last)
                       = Key
            then
               return Index;
            end if;
         end loop;

         return 0;
      end Rank_Of;

      --  One pre-token, merged and emitted.
      procedure Emit (From, To : Positive) is
         type Symbol is record
            First  : Natural := 0;
            Length : Natural := 0;
            Live   : Boolean := False;
         end record;

         Room    : String (1 .. (To - From + 1) * 2);
         Used    : Natural := 0;
         Symbols : array (1 .. To - From + 1) of Symbol;
         Count   : Natural := 0;
      begin
         for Index in From .. To loop
            declare
               One : constant String :=
                 As_UTF8 (Mapped (Character'Pos (Text (Index))));
            begin
               Count := Count + 1;
               Symbols (Count) :=
                 (First => Used + 1, Length => One'Length, Live => True);
               Room (Used + 1 .. Used + One'Length) := One;
               Used := Used + One'Length;
            end;
         end loop;

         --  Merge the lowest-ranked adjacent pair, over and over. Ties go to
         --  the leftmost, which is the only place two equal ranks can differ.
         loop
            declare
               Best_At   : Natural := 0;
               Best_Next : Natural := 0;
               Best_Rank : Natural := 0;
               Left      : Natural := 0;
            begin
               for Index in 1 .. Count loop
                  if Symbols (Index).Live then
                     if Left /= 0 then
                        declare
                           Rank : constant Natural :=
                             Rank_Of
                               (Room (Symbols (Left).First
                                      .. Symbols (Left).First
                                         + Symbols (Left).Length - 1),
                                Room (Symbols (Index).First
                                      .. Symbols (Index).First
                                         + Symbols (Index).Length - 1));
                        begin
                           if Rank /= 0
                             and then (Best_Rank = 0 or else Rank < Best_Rank)
                           then
                              Best_Rank := Rank;
                              Best_At := Left;
                              Best_Next := Index;
                           end if;
                        end;
                     end if;
                     Left := Index;
                  end if;
               end loop;

               exit when Best_At = 0;

               Symbols (Best_At).Length :=
                 Symbols (Best_At).Length + Symbols (Best_Next).Length;
               Symbols (Best_Next).Live := False;
            end;
         end loop;

         for Index in 1 .. Count loop
            if Symbols (Index).Live then
               declare
                  Which : constant Integer :=
                    Find (Item,
                          Room (Symbols (Index).First
                                .. Symbols (Index).First
                                   + Symbols (Index).Length - 1));
               begin
                  Last := Last + 1;
                  Tokens (Last) := (if Which >= 0 then Which else Item.Unknown);
               end;
            end if;
         end loop;
      end Emit;

      At_Index : Natural;
   begin
      Last := 0;

      At_Index := Text'First;
      while At_Index <= Text'Last loop
         declare
            Ends : constant Natural := Cut_Last (At_Index);
         begin
            Emit (At_Index, Ends);
            At_Index := Ends + 1;
         end;
      end loop;
   end Encode_By_Rank;

   ------------
   -- Encode --
   ------------

   procedure Encode
     (Item          : Vocabulary;
      Text          : String;
      Add_Beginning : Boolean;
      Tokens        : out Token_Vector;
      Last          : out Natural)
   is
      From : Positive := Text'First;
      Lead : Boolean := True;

      --  Encode one stretch of ordinary text and append what it makes.
      procedure Part (Piece : String; Leading : Boolean) is
         Made : Token_Vector (1 .. Tokens'Length);
         Count : Natural;
      begin
         case Item.Model is
            when SentencePiece =>
               Encode_By_Score (Item, Piece, Leading, Made, Count);
            when Byte_Pair =>
               Encode_By_Rank (Item, Piece, Made, Count);
            when Word_Piece =>
               Encode_By_Piece (Item, Piece, Made, Count);
            when Unreadable =>
               Count := 0;
         end case;

         for Index in 1 .. Count loop
            Last := Last + 1;
            Tokens (Tokens'First + Last - 1) := Made (Index);
         end loop;
      end Part;
   begin
      Last := 0;

      if Item.Model = Unreadable then
         return;
      end if;

      if Add_Beginning and then Item.Beginning >= 0 then
         Last := Last + 1;
         Tokens (Tokens'First) := Item.Beginning;
      end if;

      --  Cut the text at every marker and encode what lies between, which is
      --  the same rule on both roads. The dummy word marker SentencePiece
      --  puts in front goes on the first stretch only.
      if Text'Length = 0 then
         Part (Text, True);
         return;
      end if;

      while From <= Text'Last loop
         declare
            Token : Integer;
            Span  : Natural;
            Found : Natural := 0;
            Reach : Natural := 0;
            Scan  : Positive := From;
         begin
            loop
               Marker_At (Item, Text, Scan, Token, Span);
               if Token >= 0 then
                  Found := Scan;
                  Reach := Span;
                  exit;
               end if;

               exit when Scan = Text'Last;
               Scan := Scan + 1;
            end loop;

            declare
               Stop : constant Natural :=
                 (if Found = 0 then Text'Last else Found - 1);
            begin
               if Stop >= From then
                  Part (Text (From .. Stop), Lead);
                  Lead := False;
               end if;
            end;

            exit when Found = 0;

            Last := Last + 1;
            Tokens (Tokens'First + Last - 1) := Token;
            Lead := False;
            From := Found + Reach;
         end;
      end loop;
   end Encode;

end Reference_Tokenizer;
