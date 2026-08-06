with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Model_Runner.Numerics;
with Model_Runner.UTF8;

package body Model_Runner.Tokenizer is

   use type Model_Runner.Errors.Error_Code;

   package E renames Model_Runner.Errors;
   package Containers renames Model_Runner.GGUF.Containers;

   --  SentencePiece writes a space as U+2581 LOWER ONE EIGHTH BLOCK.
   Space_Marker : constant String :=
     [1 => Character'Val (16#E2#),
      2 => Character'Val (16#96#),
      3 => Character'Val (16#81#)];

   --  Largest token text accepted from a vocabulary entry.
   Max_Token_Bytes : constant := 1024;

   --  Largest number of code points a single Encode call will process. The
   --  merge loop is quadratic in the symbol count, so this bound is what keeps
   --  a hostile prompt from costing unbounded time.
   Max_Symbols : constant := 65_536;

   Hex : constant String := "0123456789ABCDEF";

   procedure Deallocate is
     new Ada.Unchecked_Deallocation (String, Text_Pool);

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Vocabulary) is
   begin
      if Item.Pool /= null then
         Deallocate (Item.Pool);
      end if;
      Item.Pool_Used := 0;
      Item.Entries.Clear;
      Item.Lookup.Clear;
      Item.Loaded := False;
      Item.Model := Kind_Unsupported;
      Item.Beginning := No_Token;
      Item.Ending := No_Token;
      Item.Unknown := No_Token;
      Item.Byte_Tokens := [others => No_Token];
      Item.Byte_Fallback := False;
   exception
      when others =>
         Item.Loaded := False;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Vocabulary) is
   begin
      Close (Item);
   end Finalize;

   ----------------
   -- Is_Loaded --
   ----------------

   function Is_Loaded (Item : Vocabulary) return Boolean is (Item.Loaded);

   ----------
   -- Size --
   ----------

   function Size (Item : Vocabulary) return Natural
   is (Natural (Item.Entries.Length));

   ----------
   -- Kind --
   ----------

   function Kind (Item : Vocabulary) return Model_Kind is (Item.Model);

   -----------------
   -- Model_Name --
   -----------------

   function Model_Name (Item : Vocabulary) return String
   is (Model_Runner.Text.To_String (Item.Model_Text));

   ----------------------
   -- Beginning_Token --
   ----------------------

   function Beginning_Token (Item : Vocabulary) return Token_Id
   is (Item.Beginning);

   ----------------
   -- End_Token --
   ----------------

   function End_Token (Item : Vocabulary) return Token_Id is (Item.Ending);

   --------------------
   -- Unknown_Token --
   --------------------

   function Unknown_Token (Item : Vocabulary) return Token_Id is (Item.Unknown);

   ---------------------
   -- Adds_Beginning --
   ---------------------

   function Adds_Beginning (Item : Vocabulary) return Boolean
   is (Item.Add_Beginning and then Item.Beginning /= No_Token);

   ---------------
   -- Adds_End --
   ---------------

   function Adds_End (Item : Vocabulary) return Boolean
   is (Item.Add_End and then Item.Ending /= No_Token);

   -------------------------
   -- Has_Byte_Fallback --
   -------------------------

   function Has_Byte_Fallback (Item : Vocabulary) return Boolean
   is (Item.Byte_Fallback);

   ---------------
   -- Is_Valid --
   ---------------

   function Is_Valid (Item : Vocabulary; Token : Token_Id) return Boolean
   is (Token >= 0 and then Natural (Token) < Size (Item));

   -----------------
   -- Token_Text --
   -----------------

   function Token_Text (Item : Vocabulary; Token : Token_Id) return String is
   begin
      if not Is_Valid (Item, Token) or else Item.Pool = null then
         return "";
      end if;

      declare
         Found : Token_Entry renames Item.Entries (Natural (Token) + 1);
      begin
         if Found.Last < Found.First then
            return "";
         end if;
         return Item.Pool.all (Found.First .. Found.Last);
      end;
   end Token_Text;

   ---------------
   -- Class_Of --
   ---------------

   function Class_Of (Item : Vocabulary; Token : Token_Id) return Token_Class is
   begin
      if not Is_Valid (Item, Token) then
         return Class_Unused;
      else
         return Item.Entries (Natural (Token) + 1).Class;
      end if;
   end Class_Of;

   ----------
   -- Find --
   ----------

   function Find (Item : Vocabulary; Text : String) return Token_Id is
      Position : constant Token_Maps.Cursor := Item.Lookup.Find (Text);
   begin
      if Token_Maps.Has_Element (Position) then
         return Token_Maps.Element (Position);
      else
         return No_Token;
      end if;
   end Find;

   --  Score of a token, used to order candidate merges.
   function Score_Of (Item : Vocabulary; Token : Token_Id) return Float is
   begin
      if not Is_Valid (Item, Token) then
         return Float'First;
      else
         return Item.Entries (Natural (Token) + 1).Score;
      end if;
   end Score_Of;

   ----------
   -- Load --
   ----------

   procedure Load
     (Item   : in out Vocabulary;
      Source : Containers.Container;
      Bounds : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Status : out E.Error_Info)
   is
      Count      : Natural;
      Has_Scores : Boolean := False;
      Has_Types  : Boolean := False;
      Scratch    : E.Error_Info;
      Number     : Long_Long_Integer;
   begin
      Close (Item);

      declare
         Name : constant String :=
           Containers.String_Value (Source, "tokenizer.ggml.model");
      begin
         if Name = "" then
            Status := E.Make (E.Tokenizer_Missing_Model);
            return;
         end if;

         Item.Model_Text := Model_Runner.Text.To_Bounded (Name);

         if Name = "llama" then
            Item.Model := Kind_SentencePiece;
         else
            Item.Model := Kind_Unsupported;
            Status := E.Make (E.Tokenizer_Unsupported_Model);
            E.Add_Text (Status, "model", Name, E.Param_Identifier);
            return;
         end if;
      end;

      Containers.Get_Array_Length
        (Source, "tokenizer.ggml.tokens",
         Model_Runner.GGUF.Value_String, Count, Status);
      if E.Is_Error (Status) then
         Status := E.Make (E.Tokenizer_Missing_Tokens);
         return;
      end if;

      if Count = 0 or else Count > Bounds.Max_Vocabulary then
         Status := E.Make (E.Tokenizer_Vocabulary_Too_Large);
         E.Add_Integer (Status, "size", Long_Long_Integer (Count));
         E.Add_Integer (Status, "limit", Long_Long_Integer (Bounds.Max_Vocabulary));
         return;
      end if;

      declare
         Probe : Natural;
      begin
         Containers.Get_Array_Length
           (Source, "tokenizer.ggml.scores",
            Model_Runner.GGUF.Value_Float32, Probe, Scratch);
         Has_Scores := E.Is_Ok (Scratch) and then Probe = Count;

         Containers.Get_Array_Length
           (Source, "tokenizer.ggml.token_type",
            Model_Runner.GGUF.Value_Int32, Probe, Scratch);
         Has_Types := E.Is_Ok (Scratch) and then Probe = Count;
      end;

      --  Two passes: size the pool exactly, then fill it. This avoids a
      --  growth policy in a path a hostile file controls the length of.
      declare
         Total : Natural := 0;
      begin
         for Index in 1 .. Count loop
            declare
               Length : Natural;
            begin
               Containers.Get_String_Element_Length
                 (Source, "tokenizer.ggml.tokens", Index, Length, Scratch);
               if E.Is_Error (Scratch) or else Length > Max_Token_Bytes then
                  Status := E.Make (E.Tokenizer_Invalid_Token_Text);
                  E.Add_Integer (Status, "index", Long_Long_Integer (Index));
                  return;
               end if;
               Total := Total + Length;
            end;
         end loop;

         Item.Pool := new String (1 .. Natural'Max (Total, 1));
      end;

      for Index in 1 .. Count loop
         declare
            Buffer : String (1 .. Max_Token_Bytes);
            Last   : Natural;
            Entry_Value : Token_Entry;
         begin
            Containers.Get_String_Element
              (Source, "tokenizer.ggml.tokens", Index, Buffer, Last, Scratch);
            if E.Is_Error (Scratch) then
               Status := E.Make (E.Tokenizer_Invalid_Token_Text);
               E.Add_Integer (Status, "index", Long_Long_Integer (Index));
               return;
            end if;

            Entry_Value.First := Item.Pool_Used + 1;
            Entry_Value.Last := Item.Pool_Used + Last;
            if Last > 0 then
               Item.Pool.all (Entry_Value.First .. Entry_Value.Last) :=
                 Buffer (1 .. Last);
            end if;
            Item.Pool_Used := Item.Pool_Used + Last;

            if Has_Scores then
               declare
                  Value : Model_Runner.Numerics.Wide_Real;
               begin
                  Containers.Get_Float_Element
                    (Source, "tokenizer.ggml.scores", Index, Value, Scratch);
                  if E.Is_Ok (Scratch) then
                     Entry_Value.Score := Float (Value);
                  end if;
               end;
            end if;

            if Has_Types then
               Containers.Get_Integer_Element
                 (Source, "tokenizer.ggml.token_type", Index, Number, Scratch);
               if E.Is_Ok (Scratch) then
                  --  GGUF token types: 1 normal, 2 unknown, 3 control,
                  --  4 user defined, 5 unused, 6 byte.
                  case Number is
                     when 2      => Entry_Value.Class := Class_Unknown;
                     when 3      => Entry_Value.Class := Class_Control;
                     when 4      => Entry_Value.Class := Class_User_Defined;
                     when 5      => Entry_Value.Class := Class_Unused;
                     when 6      => Entry_Value.Class := Class_Byte;
                     when others => Entry_Value.Class := Class_Normal;
                  end case;
               end if;
            end if;

            Item.Entries.Append (Entry_Value);

            declare
               Text : constant String :=
                 (if Last = 0 then "" else Buffer (1 .. Last));
            begin
               if Text /= "" and then not Item.Lookup.Contains (Text) then
                  Item.Lookup.Insert (Text, Token_Id (Index - 1));
               end if;
            end;
         end;
      end loop;

      --  Special tokens.
      --
      --  A missing key leaves the identifier unset: not every model declares
      --  every special token. A key that is present but names no token is a
      --  different thing and is refused. Treating the two alike meant a file
      --  declaring token 999999 tokenized as though it had declared nothing,
      --  which changes the prompt the model sees without saying so.
      --
      --  Minus one is accepted and means the model has no such token. Files
      --  that carry the key without having the token write it that way, and
      --  it is already this vocabulary's No_Token.
      declare
         --  Read one identifier. Failed is set when the load cannot continue.
         procedure Special
           (Key    : String;
            Target : in out Token_Id;
            Failed : out Boolean)
         is
            Local : E.Error_Info;
            Value : Long_Long_Integer;
         begin
            Failed := False;

            Containers.Get_Integer
              (Source, Key, Long_Long_Integer (No_Token),
               Long_Long_Integer (Count - 1), Value, Local);

            if E.Is_Ok (Local) then
               Target := Token_Id (Value);
            elsif Local.Code /= E.GGUF_Missing_Metadata_Key then
               --  Reported as the container saw it: the diagnostic already
               --  names the key and whether it was the type or the value.
               Status := Local;
               Failed := True;
            end if;
         end Special;

         Refused : Boolean;
      begin
         Special ("tokenizer.ggml.bos_token_id", Item.Beginning, Refused);
         if Refused then
            return;
         end if;

         Special ("tokenizer.ggml.eos_token_id", Item.Ending, Refused);
         if Refused then
            return;
         end if;

         Special ("tokenizer.ggml.unknown_token_id", Item.Unknown, Refused);
         if Refused then
            return;
         end if;
      end;

      --  The same rule for the flags: absent means the model does not say,
      --  present but not a boolean means the file is wrong about itself.
      declare
         Flag : Boolean;
      begin
         Containers.Get_Boolean
           (Source, "tokenizer.ggml.add_bos_token", Flag, Scratch);
         if E.Is_Ok (Scratch) then
            Item.Add_Beginning := Flag;
         elsif Scratch.Code /= E.GGUF_Missing_Metadata_Key then
            Status := Scratch;
            return;
         end if;

         Containers.Get_Boolean
           (Source, "tokenizer.ggml.add_eos_token", Flag, Scratch);
         if E.Is_Ok (Scratch) then
            Item.Add_End := Flag;
         elsif Scratch.Code /= E.GGUF_Missing_Metadata_Key then
            Status := Scratch;
            return;
         end if;
      end;

      --  Byte fallback is a property of the vocabulary, not a claim in the
      --  metadata: it holds only when every byte value has a token.
      Item.Byte_Fallback := True;
      for Value in Item.Byte_Tokens'Range loop
         declare
            Name : constant String :=
              "<0x" & Hex (Value / 16 + 1) & Hex (Value mod 16 + 1) & ">";
            Token : constant Token_Id := Find (Item, Name);
         begin
            Item.Byte_Tokens (Value) := Token;
            if Token = No_Token then
               Item.Byte_Fallback := False;
            end if;
         end;
      end loop;

      Item.Loaded := True;
      Status := E.Success;
   exception
      when Occurrence : others =>
         Close (Item);
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "tokenizer.load");
         E.Add_Frame
           (Status, Ada.Exceptions.Exception_Name (Occurrence));
   end Load;

   ------------
   -- Encode --
   ------------

   procedure Encode
     (Item          : Vocabulary;
      Text          : String;
      Add_Beginning : Boolean;
      Add_End       : Boolean;
      Target        : out Token_Array;
      Last          : out Natural;
      Status        : out E.Error_Info)
   is
      --  A symbol is a slice of the working text. Symbols form a doubly
      --  linked list so that a merge is a constant-time splice.
      type Symbol is record
         First    : Natural := 0;
         Length   : Natural := 0;
         Previous : Integer := -1;
         Next     : Integer := -1;
         Alive    : Boolean := True;
      end record;

      type Symbol_Array is array (Positive range <>) of Symbol;
      type Symbol_Access is access Symbol_Array;
      procedure Free is
        new Ada.Unchecked_Deallocation (Symbol_Array, Symbol_Access);

      --  SentencePiece works on text in which every space is the marker and a
      --  dummy marker precedes the first character. Substituting up front
      --  keeps every symbol a slice of one string, which is what makes a merge
      --  a constant-time splice of two adjacent slices.
      --  The working text is built on the heap and in the statement part.
      --  It is up to three times the length of the input, and a prompt of a
      --  few megabytes -- well inside the documented limit -- would exhaust
      --  the stack here in the declarative part, where this body's own
      --  handler could not contain the failure.
      procedure Build_Working (Store : out Text_Pool) is
         Needed : Natural := 0;
      begin
         if Item.Model /= Kind_SentencePiece then
            Store := new String'(Text);
            return;
         end if;

         --  Measure first so the buffer is exact rather than a worst case.
         Needed := Space_Marker'Length;
         for Character_Value of Text loop
            Needed := Needed
              + (if Character_Value = ' ' then Space_Marker'Length else 1);
         end loop;

         Store := new String (1 .. Needed);

         declare
            Length : Natural := 0;

            procedure Put (Piece : String) is
            begin
               Store (Length + 1 .. Length + Piece'Length) := Piece;
               Length := Length + Piece'Length;
            end Put;
         begin
            Put (Space_Marker);
            for Character_Value of Text loop
               if Character_Value = ' ' then
                  Put (Space_Marker);
               else
                  Put ([1 => Character_Value]);
               end if;
            end loop;
         end;
      end Build_Working;

      Working : Text_Pool := null;

      Symbols : Symbol_Access := null;
      Count   : Natural := 0;

      --  Release everything this call allocated. Every exit path goes through
      --  it, including the handler, which previously leaked the symbol array.
      procedure Release is
      begin
         Free (Symbols);
         Deallocate (Working);
      end Release;

      --  Append a token, reporting a full target buffer.
      procedure Emit (Token : Token_Id; Ok : out Boolean) is
      begin
         if Last >= Target'Length then
            Ok := False;
         else
            Last := Last + 1;
            Target (Target'First + Last - 1) := Token;
            Ok := True;
         end if;
      end Emit;

      --  Emit one symbol, falling back to byte tokens when its text is not in
      --  the vocabulary.
      procedure Emit_Symbol (Index : Positive; Ok : out Boolean) is
         Piece : constant String :=
           Working (Symbols (Index).First
                    .. Symbols (Index).First + Symbols (Index).Length - 1);
         Token : constant Token_Id := Find (Item, Piece);
      begin
         Ok := True;

         if Token /= No_Token then
            Emit (Token, Ok);
            return;
         end if;

         for Position in Piece'Range loop
            declare
               Value : constant Natural := Character'Pos (Piece (Position));
               Byte_Token : constant Token_Id := Item.Byte_Tokens (Value);
            begin
               if Byte_Token /= No_Token then
                  Emit (Byte_Token, Ok);
               elsif Item.Unknown /= No_Token then
                  Emit (Item.Unknown, Ok);
               end if;
               exit when not Ok;
            end;
         end loop;
      end Emit_Symbol;

      Ok : Boolean;
   begin
      Last := 0;
      Status := E.Success;

      if not Item.Loaded then
         Status := E.Make (E.Tokenizer_Invalid_Vocabulary);
         return;
      end if;

      if not Model_Runner.UTF8.Is_Valid (Text) then
         Status := E.Make (E.Tokenizer_Invalid_UTF8);
         return;
      end if;

      --  Reject an oversized input before allocating anything for it: the
      --  symbol limit is a code point count, and counting needs no copy.
      if Model_Runner.UTF8.Code_Point_Count (Text) > Max_Symbols then
         Status := E.Make (E.Tokenizer_Input_Too_Long);
         E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Symbols));
         return;
      end if;

      Build_Working (Working);

      if Add_Beginning and then Item.Beginning /= No_Token then
         Emit (Item.Beginning, Ok);
         if not Ok then
            Status := E.Make (E.Tokenizer_Buffer_Too_Small);
            return;
         end if;
      end if;

      --  Split into code points, substituting the space marker.
      declare
         Position : Natural := Working'First;
      begin
         Symbols := new Symbol_Array (1 .. Max_Symbols);

         while Position <= Working'Last loop
            declare
               Length : constant Natural :=
                 Model_Runner.UTF8.Sequence_Length (Working (Position));
               Span   : constant Natural :=
                 (if Length = 0 or else Position + Length - 1 > Working'Last
                  then 1
                  else Length);
            begin
               if Count = Max_Symbols then
                  Release;
                  Status := E.Make (E.Tokenizer_Input_Too_Long);
                  E.Add_Integer (Status, "limit", Long_Long_Integer (Max_Symbols));
                  return;
               end if;

               Count := Count + 1;

               Symbols (Count) :=
                 (First    => Position,
                  Length   => Span,
                  Previous => (if Count = 1 then -1 else Count - 1),
                  Next     => Count + 1,
                  Alive    => True);

               Position := Position + Span;
            end;
         end loop;
      end;

      if Count > 0 then
         Symbols (Count).Next := -1;
      end if;

      --  Merge the best-scoring adjacent pair until no adjacent pair names a
      --  vocabulary entry. Each pass is linear in the surviving symbols and
      --  every pass removes one, so the loop terminates in at most Count
      --  passes.
      loop
         declare
            Best_Left  : Integer := -1;
            Best_Score : Float := Float'First;
            Index      : Integer := (if Count = 0 then -1 else 1);
         begin
            while Index >= 1 loop
               declare
                  Next : constant Integer := Symbols (Index).Next;
               begin
                  exit when Next < 1;

                  declare
                     Merged : constant String :=
                       Working (Symbols (Index).First
                                .. Symbols (Index).First
                                   + Symbols (Index).Length - 1)
                       & Working (Symbols (Next).First
                                  .. Symbols (Next).First
                                     + Symbols (Next).Length - 1);
                     Token  : constant Token_Id := Find (Item, Merged);
                  begin
                     if Token /= No_Token
                       and then Class_Of (Item, Token) /= Class_Unused
                       and then Score_Of (Item, Token) > Best_Score
                     then
                        Best_Score := Score_Of (Item, Token);
                        Best_Left := Index;
                     end if;
                  end;

                  Index := Next;
               end;
            end loop;

            exit when Best_Left < 1;

            declare
               Right : constant Integer := Symbols (Best_Left).Next;
            begin
               --  Splice the right symbol out and extend the left one. This is
               --  only correct because the two slices are adjacent in Working,
               --  which the split above guarantees.
               Symbols (Best_Left).Length :=
                 Symbols (Best_Left).Length + Symbols (Right).Length;
               Symbols (Best_Left).Next := Symbols (Right).Next;
               if Symbols (Right).Next >= 1 then
                  Symbols (Symbols (Right).Next).Previous := Best_Left;
               end if;
               Symbols (Right).Alive := False;
            end;
         end;
      end loop;

      declare
         Index : Integer := (if Count = 0 then -1 else 1);
      begin
         while Index >= 1 loop
            if Symbols (Index).Alive and then Symbols (Index).Length > 0 then
               Emit_Symbol (Index, Ok);
               if not Ok then
                  Release;
                  Status := E.Make (E.Tokenizer_Buffer_Too_Small);
                  return;
               end if;
            end if;
            Index := Symbols (Index).Next;
         end loop;
      end;

      Release;

      if Add_End and then Item.Ending /= No_Token then
         Emit (Item.Ending, Ok);
         if not Ok then
            Status := E.Make (E.Tokenizer_Buffer_Too_Small);
            return;
         end if;
      end if;
   exception
      when Occurrence : others =>
         Release;
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "tokenizer.encode");
         E.Add_Frame
           (Status, Ada.Exceptions.Exception_Name (Occurrence));
   end Encode;

   --------------------
   -- Decode_Token --
   --------------------

   function Decode_Token
     (Item  : Vocabulary;
      Token : Token_Id;
      First : Boolean := False) return String
   is
      Raw : constant String := Token_Text (Item, Token);
   begin
      if Raw = "" then
         return "";
      end if;

      --  A byte-fallback token contributes exactly one raw byte.
      if Class_Of (Item, Token) = Class_Byte
        and then Raw'Length = 6
        and then Raw (Raw'First .. Raw'First + 2) = "<0x"
        and then Raw (Raw'Last) = '>'
      then
         declare
            function Digit (Item : Character) return Natural is
              (if Item in '0' .. '9' then Character'Pos (Item) - Character'Pos ('0')
               elsif Item in 'A' .. 'F'
               then Character'Pos (Item) - Character'Pos ('A') + 10
               elsif Item in 'a' .. 'f'
               then Character'Pos (Item) - Character'Pos ('a') + 10
               else 16);
            High : constant Natural := Digit (Raw (Raw'First + 3));
            Low  : constant Natural := Digit (Raw (Raw'First + 4));
         begin
            if High < 16 and then Low < 16 then
               return [1 => Character'Val (High * 16 + Low)];
            end if;
         end;
      end if;

      --  Control tokens contribute no text.
      if Class_Of (Item, Token) = Class_Control then
         return "";
      end if;

      --  Replace every space marker with a space. The first token of a
      --  sequence loses the leading marker that SentencePiece added.
      declare
         Result : String (1 .. Raw'Length);
         Length : Natural := 0;
         Index  : Natural := Raw'First;
         Leading : Boolean := True;
      begin
         while Index <= Raw'Last loop
            if Index + Space_Marker'Length - 1 <= Raw'Last
              and then Raw (Index .. Index + Space_Marker'Length - 1)
                       = Space_Marker
            then
               if not (Leading and then First) then
                  Length := Length + 1;
                  Result (Length) := ' ';
               end if;
               Index := Index + Space_Marker'Length;
            else
               Length := Length + 1;
               Result (Length) := Raw (Index);
               Index := Index + 1;
               Leading := False;
            end if;
         end loop;

         return Result (1 .. Length);
      end;
   end Decode_Token;

   ------------
   -- Decode --
   ------------

   function Decode (Item : Vocabulary; Tokens : Token_Array) return String is
      use Ada.Strings.Unbounded;
      State  : Decoder;
      Result : Unbounded_String;
   begin
      Reset (State);

      for Index in Tokens'Range loop
         Append (Result, Push (State, Item, Tokens (Index)));
      end loop;

      Append (Result, Flush (State));
      return To_String (Result);
   end Decode;

   -------------
   -- Reset --
   -------------

   procedure Reset (Item : out Decoder; Continuing : Boolean := False) is
   begin
      Item :=
        (Started => Continuing, Pending => [others => ' '], Length => 0);
   end Reset;

   ----------
   -- Push --
   ----------

   function Push
     (Item   : in out Decoder;
      Source : Vocabulary;
      Token  : Token_Id) return String
   is
      Fragment : constant String :=
        Decode_Token (Source, Token, not Item.Started);
      Combined : constant String :=
        Item.Pending (1 .. Item.Length) & Fragment;
      Safe     : constant Natural :=
        Model_Runner.UTF8.Safe_Prefix_Length (Combined);
      Held     : constant Natural := Combined'Length - Safe;
   begin
      --  The dummy prefix belongs to the first piece that actually carries
      --  text. A leading control token such as the beginning-of-sequence
      --  marker contributes nothing, so it must not consume the suppression.
      if Fragment /= "" then
         Item.Started := True;
      end if;

      --  A held remainder longer than the buffer can only happen if a token
      --  contributed a very long incomplete sequence, which no well-formed
      --  vocabulary produces. Release everything rather than lose bytes.
      if Held > Max_Pending then
         Item.Length := 0;
         return Combined;
      end if;

      Item.Length := Held;
      if Held > 0 then
         Item.Pending (1 .. Held) :=
           Combined (Combined'Last - Held + 1 .. Combined'Last);
      end if;

      return Combined (Combined'First .. Combined'First + Safe - 1);
   end Push;

   -----------
   -- Flush --
   -----------

   function Flush (Item : in out Decoder) return String is
      Remaining : constant String := Item.Pending (1 .. Item.Length);
   begin
      Item.Length := 0;
      return Remaining;
   end Flush;

end Model_Runner.Tokenizer;
