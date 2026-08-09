with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
with Ada.Wide_Wide_Characters.Handling;

with Model_Runner.Numerics;
with Model_Runner.UTF8;

package body Model_Runner.Tokenizer is

   --  A token score comes out of the file as a float and any bit pattern is
   --  possible, so a not-a-number is ordinary input here rather than a
   --  fault. Validity checking raises when one is read, before anything can
   --  decide what to do about it, which turns a vocabulary with a strange
   --  score into the program reporting a defect in itself. The same reason
   --  the kernels give. Bounds and range checking are untouched.
   pragma Suppress (Validity_Check);

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

   -------------------
   -- Storage_Bytes --
   -------------------

   function Storage_Bytes (Item : Vocabulary) return Natural
   is (Item.Pool_Used);

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
         elsif Name = "gpt2" then
            Item.Model := Kind_BPE;

            --  Which rule cuts the text before any merging happens. The
            --  vocabularies differ here and the difference is not small:
            --  under the original rule only a space may lead a word, while
            --  the later ones let any single character that is neither
            --  letter nor digit do it, so "tab<TAB>and" is three pieces
            --  under one and two under the other, and the models are
            --  trained on one answer each.
            --
            --  Only the rule this implements is accepted. The others are
            --  refused by name rather than cut by the wrong rule, because a
            --  wrong cut yields tokens that decode back to the same text
            --  and mean something else to the model -- there is nothing
            --  downstream that would notice.
            declare
               Cutting : constant String :=
                 Containers.String_Value (Source, "tokenizer.ggml.pre");
            begin
               if Cutting = "" or else Cutting = "gpt-2"
                 or else Cutting = "starcoder"
               then
                  Item.Cutting := Rule_GPT2;
               elsif Cutting = "falcon" then
                  --  Leads a run as the original does, but groups digits in
                  --  threes as the later rules do, which only shows on a run
                  --  of four or more.
                  Item.Cutting := Rule_Falcon;
               elsif Cutting = "llama3" or else Cutting = "llama-bpe" then
                  Item.Cutting := Rule_Llama3;
               elsif Cutting = "qwen2" then
                  Item.Cutting := Rule_Qwen2;
               elsif Cutting = "smollm" then
                  --  Leads a run as the original does -- a space may, a tab
                  --  may not -- and takes digits one at a time with nothing
                  --  before them, as qwen2 does.
                  Item.Cutting := Rule_SmolLM;
               else
                  Item.Model := Kind_Unsupported;
                  Status := E.Make (E.Tokenizer_Unsupported_Model);
                  E.Add_Text (Status, "model", Cutting, E.Param_Identifier);
                  return;
               end if;
            end;
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
         --  A table that is absent is not an error: a vocabulary without
         --  scores merges left to right, and one without token types has no
         --  added tokens. A table that is there and does not match the
         --  vocabulary is another matter. Scores decide which merge wins, so
         --  quietly dropping a short table tokenizes the same text
         --  differently and says nothing.
         Containers.Get_Array_Length
           (Source, "tokenizer.ggml.scores",
            Model_Runner.GGUF.Value_Float32, Probe, Scratch);
         if E.Is_Ok (Scratch) then
            if Probe /= Count then
               Status := E.Make (E.Tokenizer_Invalid_Scores);
               E.Add_Integer (Status, "size", Long_Long_Integer (Probe));
               E.Add_Integer (Status, "expected", Long_Long_Integer (Count));
               return;
            end if;
            Has_Scores := True;
         elsif Scratch.Code /= E.GGUF_Missing_Metadata_Key then
            Status := E.Make (E.Tokenizer_Invalid_Scores);
            return;
         else
            Has_Scores := False;
         end if;

         Containers.Get_Array_Length
           (Source, "tokenizer.ggml.token_type",
            Model_Runner.GGUF.Value_Int32, Probe, Scratch);
         if E.Is_Ok (Scratch) then
            if Probe /= Count then
               Status := E.Make (E.Tokenizer_Invalid_Token_Type);
               E.Add_Integer (Status, "size", Long_Long_Integer (Probe));
               E.Add_Integer (Status, "expected", Long_Long_Integer (Count));
               return;
            end if;
            Has_Types := True;
         elsif Scratch.Code /= E.GGUF_Missing_Metadata_Key then
            Status := E.Make (E.Tokenizer_Invalid_Token_Type);
            return;
         else
            Has_Types := False;
         end if;
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

      --  The merge table, for a vocabulary that has one.
      --
      --  Each entry is the two pieces with a space between them, and its
      --  position is its rank: earlier entries are applied first. The file
      --  writes them in that order, so the rank is the index and nothing has
      --  to be sorted.
      --
      --  A byte-pair vocabulary without merges cannot tokenize anything but
      --  single characters, so an absent or empty table is refused rather
      --  than accepted into silently wrong output. For SentencePiece the
      --  table is meaningless and is not read at all.
      if Item.Model = Kind_BPE then
         declare
            Merge_Count : Natural := 0;
         begin
            Containers.Get_Array_Length
              (Source, "tokenizer.ggml.merges",
               Model_Runner.GGUF.Value_String, Merge_Count, Scratch);

            if E.Is_Error (Scratch) or else Merge_Count = 0 then
               Status := E.Make (E.Tokenizer_Invalid_Merges);
               return;
            end if;

            if Merge_Count > Bounds.Max_Vocabulary then
               Status := E.Make (E.Tokenizer_Vocabulary_Too_Large);
               E.Add_Integer (Status, "size", Long_Long_Integer (Merge_Count));
               E.Add_Integer
                 (Status, "limit",
                  Long_Long_Integer (Bounds.Max_Vocabulary));
               return;
            end if;

            for Index in 1 .. Merge_Count loop
               declare
                  Buffer : String (1 .. Max_Token_Bytes * 2 + 1);
                  Last   : Natural;
               begin
                  Containers.Get_String_Element
                    (Source, "tokenizer.ggml.merges", Index,
                     Buffer, Last, Scratch);
                  if E.Is_Error (Scratch) or else Last = 0 then
                     Status := E.Make (E.Tokenizer_Invalid_Merges);
                     E.Add_Integer (Status, "index", Long_Long_Integer (Index));
                     return;
                  end if;

                  --  Kept keyed exactly as written, so looking one up is
                  --  joining the two pieces with a space rather than parsing
                  --  anything. A repeated pair keeps its first, lower rank.
                  if not Item.Merges.Contains (Buffer (1 .. Last)) then
                     Item.Merges.Insert (Buffer (1 .. Last), Index);
                  end if;
               end;
            end loop;
         end;
      end if;

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

   --  Byte-pair encoding.
   --
   --  Three steps, in this order, and the order is the whole of it. The text
   --  is cut into pieces at boundaries the vocabulary's own rules define --
   --  a run of letters, a run of digits, a run of neither, each allowed one
   --  leading space -- so that no merge can ever join a word to the one after
   --  it. Each piece is rewritten so that every byte becomes a printable
   --  character, which is what lets a merge table written as text describe
   --  arbitrary bytes. Then the pieces are merged, lowest rank first, until
   --  no adjacent pair appears in the table.
   --
   --  What is not here is the whole of the first step. The vocabularies name
   --  a pre-tokenizer -- gpt-2, llama3, qwen2 and others -- and they differ
   --  in how they cut, chiefly around non-ASCII text, where a letter has to
   --  be told from a symbol by its Unicode category. This implements the
   --  ASCII rules exactly and treats every code point above 127 as a letter,
   --  which is right for running text in most scripts and wrong for
   --  punctuation and symbols outside ASCII. Encode says so by refusing
   --  rather than guessing: see Pre_Token_Cut.
   package BPE is

      --  Each byte as the printable character that stands for it, as the
      --  original byte-level vocabularies define. Bytes that are already
      --  printable ASCII stand for themselves; the rest are moved into a
      --  range where no byte value collides with a real character.
      type Byte_Character_Table is array (0 .. 255) of Natural;

      Byte_Character : constant Byte_Character_Table :=
        [256, 257, 258, 259, 260, 261, 262, 263,
         264, 265, 266, 267, 268, 269, 270, 271,
         272, 273, 274, 275, 276, 277, 278, 279,
         280, 281, 282, 283, 284, 285, 286, 287,
         288,  33,  34,  35,  36,  37,  38,  39,
          40,  41,  42,  43,  44,  45,  46,  47,
          48,  49,  50,  51,  52,  53,  54,  55,
          56,  57,  58,  59,  60,  61,  62,  63,
          64,  65,  66,  67,  68,  69,  70,  71,
          72,  73,  74,  75,  76,  77,  78,  79,
          80,  81,  82,  83,  84,  85,  86,  87,
          88,  89,  90,  91,  92,  93,  94,  95,
          96,  97,  98,  99, 100, 101, 102, 103,
         104, 105, 106, 107, 108, 109, 110, 111,
         112, 113, 114, 115, 116, 117, 118, 119,
         120, 121, 122, 123, 124, 125, 126, 289,
         290, 291, 292, 293, 294, 295, 296, 297,
         298, 299, 300, 301, 302, 303, 304, 305,
         306, 307, 308, 309, 310, 311, 312, 313,
         314, 315, 316, 317, 318, 319, 320, 321,
         322, 161, 162, 163, 164, 165, 166, 167,
         168, 169, 170, 171, 172, 323, 174, 175,
         176, 177, 178, 179, 180, 181, 182, 183,
         184, 185, 186, 187, 188, 189, 190, 191,
         192, 193, 194, 195, 196, 197, 198, 199,
         200, 201, 202, 203, 204, 205, 206, 207,
         208, 209, 210, 211, 212, 213, 214, 215,
         216, 217, 218, 219, 220, 221, 222, 223,
         224, 225, 226, 227, 228, 229, 230, 231,
         232, 233, 234, 235, 236, 237, 238, 239,
         240, 241, 242, 243, 244, 245, 246, 247,
         248, 249, 250, 251, 252, 253, 254, 255];

      --  Where one pre-token ends, starting at From.
      --
      --  A run of letters, a run of digits, or a run of neither, each
      --  allowed one leading space; a run of spaces on its own; and the
      --  handful of English contractions the original tokenizer named. Every
      --  vocabulary of this kind cuts roughly this way and they differ in the
      --  details, which is why Understood below refuses the text this cannot
      --  cut faithfully rather than cutting it wrongly.
      function Cut_At
        (Text : String; From : Positive; Rule : Cut_Rule) return Natural;

   end BPE;

   package body BPE is

      --  Classified by the standard library, which knows the Unicode
      --  categories: a letter is anything in L, a digit anything in Nd. That
      --  is what tells a CJK ideograph, which is a letter, from a CJK comma,
      --  which is not, and neither can be told apart by looking at bytes.
      package Handling renames Ada.Wide_Wide_Characters.Handling;

      function Wide (Code_Point : Natural) return Wide_Wide_Character
      is (Wide_Wide_Character'Val (Code_Point));

      function Is_Letter (Code_Point : Natural) return Boolean
      is (Handling.Is_Letter (Wide (Code_Point)));

      function Is_Digit (Code_Point : Natural) return Boolean
      is (Handling.Is_Digit (Wide (Code_Point)));

      function Is_Space (Code_Point : Natural) return Boolean
      is (Code_Point in 32 | 9 | 10 | 11 | 12 | 13
          or else Handling.Is_Space (Wide (Code_Point))
          or else Handling.Is_Line_Terminator (Wide (Code_Point)));

      function Cut_At
        (Text : String; From : Positive; Rule : Cut_Rule) return Natural
      is
         --  The code point at a byte position, and how many bytes it took.
         procedure Look
           (At_Byte : Positive; Value : out Natural; Width : out Natural) is
         begin
            if At_Byte > Text'Last then
               Value := 0;
               Width := 0;
            else
               Model_Runner.UTF8.Decode_First
                 (Text (At_Byte .. Text'Last), Value, Width);
               if Width = 0 then
                  Width := 1;
               end if;
            end if;
         end Look;

         Index : Natural := From;
         Here, Wide_Here : Natural;
         Next, Wide_Next : Natural;

         --  The contractions, cut off whole and before anything else looks.
         type Contraction is access constant String;
         Ones : constant array (1 .. 7) of Contraction :=
           [new String'("'s"), new String'("'t"), new String'("'re"),
            new String'("'ve"), new String'("'m"), new String'("'ll"),
            new String'("'d")];

         --  True while the code point after Index is of the kind wanted.
         function Runs_On (Kind : Natural) return Boolean is
            Value, Width : Natural;
         begin
            if Index >= Text'Last then
               return False;
            end if;
            Look (Index + Wide_Here, Value, Width);
            if Width = 0 then
               return False;
            end if;
            case Kind is
               when 1 => return Is_Letter (Value);
               when 2 => return Is_Digit (Value);
               when 3 => return Is_Space (Value);
               when others =>
                  return not Is_Letter (Value) and then not Is_Digit (Value)
                    and then not Is_Space (Value);
            end case;
         end Runs_On;

         --  Step over the code point at Index.
         procedure Step is
            Value, Width : Natural;
         begin
            Look (Index + Wide_Here, Value, Width);
            Index := Index + Wide_Here;
            Here := Value;
            Wide_Here := Width;
         end Step;
      begin
         if Index > Text'Last then
            return Text'Last;
         end if;

         for One of Ones loop
            if Index + One'Length - 1 <= Text'Last
              and then Text (Index .. Index + One'Length - 1) = One.all
            then
               return Index + One'Length - 1;
            end if;
         end loop;

         Look (Index, Here, Wide_Here);
         Look (Index + Wide_Here, Next, Wide_Next);

         --  What may lead a word. Under the original rule only a space may,
         --  and under the later ones any single character that is neither a
         --  letter, a digit, nor a line ending -- which is why a tab joins
         --  the word after it there and stands alone here.
         --  What may lead a run depends on both rules and on what follows.
         --
         --  Under the original rule a space may lead anything: letters,
         --  digits, or symbols. Under the later ones any single character
         --  that is neither letter, digit nor line ending may lead letters --
         --  which is why a tab joins the word after it there -- a space may
         --  still lead symbols, and nothing at all may lead digits, which is
         --  what keeps their groups of three from starting with one.
         if Wide_Next > 0 and then not Is_Space (Next) then
            if Is_Letter (Next) then
               if (if Rule in Rule_GPT2 | Rule_Falcon | Rule_SmolLM
                   then Here = 32
                   else not Is_Letter (Here) and then not Is_Digit (Here)
                        and then Here /= 13 and then Here /= 10)
               then
                  Step;
               end if;

            elsif Is_Digit (Next) then
               if Rule in Rule_GPT2 | Rule_Falcon and then Here = 32 then
                  Step;
               end if;

            elsif Here = 32 then
               Step;
            end if;
         end if;

         if Is_Letter (Here) then
            while Runs_On (1) loop
               Step;
            end loop;

         elsif Is_Digit (Here) then
            --  Digits run to the end under the original rule, in threes
            --  under llama3, and one at a time under qwen2.
            declare
               Room : Natural :=
                 (case Rule is
                     when Rule_GPT2 => Natural'Last,
                     when Rule_Falcon => 3,
                     when Rule_Llama3 => 3,
                     when Rule_SmolLM | Rule_Qwen2 => 1);
            begin
               Room := Room - 1;
               while Room > 0 and then Runs_On (2) loop
                  Step;
                  Room := Room - 1;
               end loop;
            end;

         elsif Is_Space (Here) then
            --  A run of spaces keeps its last one for the word that follows.
            while Runs_On (3) loop
               Step;
            end loop;
            if Index < Text'Last and then Index > From then
               Index := Index - 1;
               return Index + Wide_Here - 1 - (Wide_Here - 1);
            end if;

         else
            while Runs_On (4) loop
               Step;
            end loop;
         end if;

         return Index + Wide_Here - 1;
      end Cut_At;

   end BPE;

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

      --  Byte-pair vocabularies take a different road entirely: the text is
      --  cut first, and each piece merged on its own.
      if Item.Model = Kind_BPE then
         declare
            Produced : Natural := 0;
            From     : Positive := Text'First;

            procedure Emit (Piece : String) is
               --  Every byte as its printable stand-in, which is the form
               --  the vocabulary and the merge table are written in.
               Mapped : String (1 .. Piece'Length * 3);
               Filled : Natural := 0;

               --  One symbol per stand-in character, merged in place.
               Starts : array (1 .. Piece'Length + 1) of Natural;
               Ends   : array (1 .. Piece'Length + 1) of Natural;
               Count  : Natural := 0;
            begin
               for Letter of Piece loop
                  declare
                     One : constant String :=
                       Model_Runner.UTF8.Encode
                         (BPE.Byte_Character (Character'Pos (Letter)));
                  begin
                     Count := Count + 1;
                     Starts (Count) := Filled + 1;
                     Mapped (Filled + 1 .. Filled + One'Length) := One;
                     Filled := Filled + One'Length;
                     Ends (Count) := Filled;
                  end;
               end loop;

               --  Merge the lowest-ranked adjacent pair until none is in the
               --  table. Written plainly, a pass per merge: a vocabulary's
               --  pieces are short, and the alternative is a heap for what is
               --  usually fewer than ten symbols.
               loop
                  declare
                     Best      : Natural := 0;
                     Best_Rank : Natural := Natural'Last;
                  begin
                     for Index in 1 .. Count - 1 loop
                        declare
                           Key : constant String :=
                             Mapped (Starts (Index) .. Ends (Index)) & " "
                             & Mapped (Starts (Index + 1)
                                       .. Ends (Index + 1));
                           Found : constant Merge_Maps.Cursor :=
                             Item.Merges.Find (Key);
                        begin
                           if Merge_Maps.Has_Element (Found)
                             and then Merge_Maps.Element (Found) < Best_Rank
                           then
                              Best := Index;
                              Best_Rank := Merge_Maps.Element (Found);
                           end if;
                        end;
                     end loop;

                     exit when Best = 0;

                     --  The two become one slice, and the rest close up.
                     Ends (Best) := Ends (Best + 1);
                     for Index in Best + 1 .. Count - 1 loop
                        Starts (Index) := Starts (Index + 1);
                        Ends (Index) := Ends (Index + 1);
                     end loop;
                     Count := Count - 1;
                  end;
               end loop;

               for Index in 1 .. Count loop
                  declare
                     Token : constant Token_Id :=
                       Find (Item, Mapped (Starts (Index) .. Ends (Index)));
                  begin
                     if Token /= No_Token and then Produced < Target'Length then
                        Produced := Produced + 1;
                        Target (Target'First + Produced - 1) := Token;
                     end if;
                  end;
               end loop;
            end Emit;
         begin
            if Add_Beginning and then Item.Beginning /= No_Token then
               Produced := Produced + 1;
               Target (Target'First) := Item.Beginning;
            end if;

            --  A marker such as <|im_start|> is one token, not the dozen
            --  its spelling would merge into. A chat template writes them
            --  into the text it renders, so a model reading that text has to
            --  see the token the template meant rather than its letters --
            --  and a model that sees the letters answers in letters, ending
            --  its turn by spelling the marker out instead of stopping.
            --
            --  Only positions beginning a bracket are tried, and the longest
            --  match that the vocabulary calls a control token wins, so
            --  ordinary text that merely starts with one is untouched.
            while From <= Text'Last loop
               declare
                  Marker : Natural := 0;
                  Ending : Natural := 0;
               begin
                  if Text (From) = '<' then
                     for Reach in reverse 1 .. Natural'Min
                       (Max_Token_Bytes, Text'Last - From + 1)
                     loop
                        declare
                           Candidate : constant Token_Id :=
                             Find (Item, Text (From .. From + Reach - 1));
                        begin
                           if Candidate /= No_Token
                             and then Class_Of (Item, Candidate) in
                                        Class_Control | Class_User_Defined
                           then
                              Marker := Natural (Candidate);
                              Ending := From + Reach - 1;
                              exit;
                           end if;
                        end;
                     end loop;
                  end if;

                  if Ending > 0 then
                     if Produced < Target'Length then
                        Produced := Produced + 1;
                        Target (Target'First + Produced - 1) :=
                          Token_Id (Marker);
                     end if;
                     From := Ending + 1;
                  else
                     declare
                        Stop : constant Natural :=
                          BPE.Cut_At (Text, From, Item.Cutting);
                     begin
                        exit when Stop < From;
                        Emit (Text (From .. Stop));
                        From := Stop + 1;
                     end;
                  end if;
               end;
            end loop;

            if Add_End and then Item.Ending /= No_Token
              and then Produced < Target'Length
            then
               Produced := Produced + 1;
               Target (Target'First + Produced - 1) := Item.Ending;
            end if;

            Last := Produced;
            return;
         end;
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

      --  Byte-pair token text is written in stand-in characters, one for
      --  each byte, so that a merge table written as text can describe
      --  arbitrary bytes. Decoding has to undo that: without it a model's
      --  output arrives as the stand-ins themselves, and a space reads as
      --  the character that stands for one.
      if Item.Model = Kind_BPE then
         declare
            Result : String (1 .. Raw'Length);
            Filled : Natural := 0;
            Index  : Natural := Raw'First;
         begin
            while Index <= Raw'Last loop
               declare
                  Code, Width : Natural;
                  Found : Boolean := False;
               begin
                  Model_Runner.UTF8.Decode_First
                    (Raw (Index .. Raw'Last), Code, Width);
                  exit when Width = 0;

                  for Value in BPE.Byte_Character'Range loop
                     if BPE.Byte_Character (Value) = Code then
                        Filled := Filled + 1;
                        Result (Filled) := Character'Val (Value);
                        Found := True;
                        exit;
                     end if;
                  end loop;

                  --  A character that stands for no byte is passed through
                  --  as it was written, which is what an added token such as
                  --  a marker is made of.
                  if not Found then
                     Result (Filled + 1 .. Filled + Width) :=
                       Raw (Index .. Index + Width - 1);
                     Filled := Filled + Width;
                  end if;

                  Index := Index + Width;
               end;
            end loop;

            return Result (1 .. Filled);
         end;
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
