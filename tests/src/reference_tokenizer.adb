with Ada.Unchecked_Deallocation;

with Model_Runner.Errors;
with Model_Runner.Numerics;

package body Reference_Tokenizer is

   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;

   procedure Free is new Ada.Unchecked_Deallocation
     (Piece_Array, Piece_Array_Access);

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
         begin
            Containers.Get_Float_Element
              (Source, "tokenizer.ggml.scores", Index, Score, Status);
            Item.Pieces (Index).Score :=
              (if E.Is_Error (Status) then 0.0 else Float (Score));
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

      Loaded := True;
   end Load;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Vocabulary) is
   begin
      if Item.Pieces /= null then
         Free (Item.Pieces);
      end if;
      Item.Count := 0;
      Item.Beginning := -1;
      Item.Unknown := -1;
   end Close;

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
   end Encode;

end Reference_Tokenizer;
