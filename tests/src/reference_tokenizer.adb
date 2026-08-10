with Ada.Unchecked_Deallocation;

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

   --  SentencePiece: substitute, split, then merge by score.
   procedure Encode_By_Score
     (Item          : Vocabulary;
      Text          : String;
      Add_Beginning : Boolean;
      Tokens        : out Token_Vector;
      Last          : out Natural)
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

      Add (Marker);
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

      if Add_Beginning and then Item.Beginning >= 0 then
         Last := Last + 1;
         Tokens (Last) := Item.Beginning;
      end if;

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

   --  Byte-pair: cut, rewrite each byte, then merge by rank.
   --
   --  The cutting is the ASCII part of the rule and no more: every byte above
   --  127 counts as a letter here, where the engine asks the standard library
   --  for the Unicode category. They agree on ASCII, which is what the
   --  comparison uses; text outside it is the engine's own business and it
   --  refuses what it cannot cut faithfully.
   type Contraction is access constant String;

   procedure Encode_By_Rank
     (Item          : Vocabulary;
      Text          : String;
      Add_Beginning : Boolean;
      Tokens        : out Token_Vector;
      Last          : out Natural)
   is
      Marker_Length : Natural := 0;

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

      --  A marker such as <|im_start|> is one token and not the dozen its
      --  spelling would merge into: the longest piece starting here that the
      --  vocabulary calls a control token or one of its author's own, or
      --  zero when there is none. Only a position opening a bracket is
      --  tried, so text that merely starts with one is left alone.
      function Marker_At (From : Positive) return Integer is
         Found : Integer := -1;
      begin
         if Text (From) /= '<' then
            return -1;
         end if;

         for Reach in 1 .. Natural'Min (Max_Piece, Text'Last - From + 1) loop
            declare
               Which : constant Integer :=
                 Find (Item, Text (From .. From + Reach - 1));
            begin
               if Which >= 0
                 and then Item.Pieces (Which + 1).Sort in 3 | 4
               then
                  Found := Which;
                  Marker_Length := Reach;
               end if;
            end;
         end loop;

         return Found;
      end Marker_At;

      At_Index : Natural;
   begin
      Last := 0;

      if Add_Beginning and then Item.Beginning >= 0 then
         Last := Last + 1;
         Tokens (Last) := Item.Beginning;
      end if;

      At_Index := Text'First;
      while At_Index <= Text'Last loop
         declare
            Marker : constant Integer := Marker_At (At_Index);
         begin
            if Marker >= 0 then
               Last := Last + 1;
               Tokens (Last) := Marker;
               At_Index := At_Index + Marker_Length;
            else
               declare
                  Ends : constant Natural := Cut_Last (At_Index);
               begin
                  Emit (At_Index, Ends);
                  At_Index := Ends + 1;
               end;
            end if;
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
      Last          : out Natural) is
   begin
      case Item.Model is
         when SentencePiece =>
            Encode_By_Score (Item, Text, Add_Beginning, Tokens, Last);
         when Byte_Pair =>
            Encode_By_Rank (Item, Text, Add_Beginning, Tokens, Last);
         when Unreadable =>
            Last := 0;
      end case;
   end Encode;

end Reference_Tokenizer;
