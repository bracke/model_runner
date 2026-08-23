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

   --  How large a normalization table this will read. A published one is
   --  about a quarter of a megabyte; four is room for one much larger and
   --  a refusal for a file that states a hundred, which costs the reader
   --  nothing to state and would cost this the memory to hold.
   Max_Charsmap : constant := 4 * 1024 * 1024;

   --  How long a normalized text this will find a best path through. The
   --  path costs one record a byte of it, and the table the file carries
   --  may make a byte into several, so the bound is on what comes out of
   --  the normalization rather than on what went into it.
   Max_Normalized : constant := 1024 * 1024;

   --  Largest number of code points a single Encode call will process. The
   --  merge loop is quadratic in the symbol count, so this bound is what keeps
   --  a hostile prompt from costing unbounded time.
   Max_Symbols : constant := 65_536;

   --  How many pieces one word may be spelled from on the WordPiece road.
   --  A word longer than this is one unknown token rather than a spelling
   --  that grows with the input: the bound refuses rather than allocates,
   --  as every bound here does. The longest word in a published vocabulary
   --  is spelled from a handful.
   Max_Pieces  : constant := 128;

   Hex : constant String := "0123456789ABCDEF";

   procedure Deallocate is
     new Ada.Unchecked_Deallocation (String, Text_Pool);

   procedure Free_Nodes is
     new Ada.Unchecked_Deallocation (Trie_Nodes, Trie_Access);

   procedure Free_Charsmap is
     new Ada.Unchecked_Deallocation (Charsmap_Table, Charsmap_Access);

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
      Item.Longest_Marker := 0;
      Item.Marker_Starts := [others => False];
      Item.Space_Prefix := True;
      Item.Merge_Spaces := False;
      Item.Longest_Piece := 0;
      Item.Unknown_Cost := 0.0;

      if Item.Charsmap /= null then
         if Item.Charsmap.Nodes /= null then
            Free_Nodes (Item.Charsmap.Nodes);
         end if;
         if Item.Charsmap.Replacements /= null then
            Deallocate (Item.Charsmap.Replacements);
         end if;
         Free_Charsmap (Item.Charsmap);
      end if;
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
         elsif Name = "bert" then
            --  No cutting rule to name and no merge table to read. What a
            --  WordPiece vocabulary states beyond its pieces is how the text
            --  is to be changed before they are looked up, and this build
            --  implements the one answer every published bert file gives:
            --  lower-cased, with the accents taken off.
            --
            --  A file that says otherwise is refused rather than folded
            --  anyway. A vocabulary cut without folding carries pieces with
            --  capitals in them, and folding the text before looking those
            --  up finds none of them -- every word would come back unknown,
            --  which is an answer and not an error.
            Item.Model := Kind_WordPiece;

            declare
               Folds : Boolean;
               Local : E.Error_Info;
            begin
               Containers.Get_Boolean
                 (Source, "tokenizer.ggml.do_lower_case", Folds, Local);
               if E.Is_Ok (Local) and then not Folds then
                  Item.Model := Kind_Unsupported;
                  Status := E.Make (E.Tokenizer_Unsupported_Model);
                  E.Add_Text
                    (Status, "model", "bert without folding",
                     E.Param_Identifier);
                  return;
               end if;
            end;
         elsif Name = "t5" then
            Item.Model := Kind_Unigram;
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
               if Cutting = "" or else Cutting = "default" then
                  --  What a vocabulary that names no rule is cut by,
                  --  and what the name "default" asks for outright. It is
                  --  not the original rule: it cuts every run of
                  --  punctuation out of the text first, which loses the
                  --  contractions and the space before a full stop, and it
                  --  takes digits in threes with nothing before them. The
                  --  other runtime says as much when it reads such a file,
                  --  in four lines of capitals about degraded quality.
                  Item.Cutting := Rule_Default;
               elsif Cutting = "gpt-2" or else Cutting = "mpt"
                 or else Cutting = "olmo" or else Cutting = "jais"
                 or else Cutting = "trillion"
                 or else Cutting = "granite-docling" or else Cutting = "phi-2"
                 or else Cutting = "gigachat" or else Cutting = "a.x-4.0"
                 or else Cutting = "mellum" or else Cutting = "modern-bert"
                 or else Cutting = "roberta-bpe" or else Cutting = "exaone4"
                 or else Cutting = "jina-es" or else Cutting = "jina-de"
                 or else Cutting = "jina-v1-en" or else Cutting = "jina-v2-es"
                 or else Cutting = "jina-v2-de"
                 or else Cutting = "jina-v2-code"
               then
                  Item.Cutting := Rule_GPT2;
               elsif Cutting = "falcon" then
                  --  Leads a run as the original does, but cuts
                  --  punctuation out first and groups digits in threes,
                  --  which only shows on a run of three or more.
                  Item.Cutting := Rule_Falcon;
               elsif Cutting = "llama3" or else Cutting = "llama-v3"
                 or else Cutting = "llama-bpe" or else Cutting = "falcon3"
                 or else Cutting = "falcon-h1" or else Cutting = "pixtral"
                 or else Cutting = "midm-2.0" or else Cutting = "lfm2"
                 or else Cutting = "jina-v5-nano" or else Cutting = "dbrx"
                 or else Cutting = "smaug-bpe" or else Cutting = "glm4"
                 or else Cutting = "chatglm-bpe"
               then
                  Item.Cutting := Rule_Llama3;
               elsif Cutting = "qwen2" or else Cutting = "stablelm2"
                 or else Cutting = "deepseek-r1-qwen"
                 or else Cutting = "kormo" or else Cutting = "f2llmv2"
                 or else Cutting = "megrez" or else Cutting = "hunyuan"
                 or else Cutting = "grok-2" or else Cutting = "solar-open"
               then
                  Item.Cutting := Rule_Qwen2;
               elsif Cutting = "smollm" or else Cutting = "starcoder"
                 or else Cutting = "refact" or else Cutting = "command-r"
                 or else Cutting = "codeshell" or else Cutting = "exaone"
                 or else Cutting = "minerva-7b" or else Cutting = "mellum2"
               then
                  --  Leads a run as the original does -- a space may, a
                  --  tab may not -- and takes digits one at a time with
                  --  nothing before them, as qwen2 does. Starcoder is on
                  --  this rule and not the original one: the two are one
                  --  block in the other runtime, and the vocabulary
                  --  starcoder ships cannot tell them apart because no
                  --  piece of it spans a digit and anything else.
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

         --  On the unigram road the scores are not an aid to the answer,
         --  they are the answer: what is chosen is the cut whose scores sum
         --  highest. A vocabulary without them merges left to right on
         --  every other road and means nothing at all on this one, so it is
         --  refused rather than read as a vocabulary of equals.
         if Item.Model = Kind_Unigram and then not Has_Scores then
            Status := E.Make (E.Tokenizer_Invalid_Scores);
            return;
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

      --  The running lowest score, which becomes what an unseen character
      --  costs once every piece has been read.
      Item.Unknown_Cost := Float'Last;

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

            if Entry_Value.Class in Class_Control | Class_User_Defined
              and then Last > 0
            then
               Item.Longest_Marker := Natural'Max (Item.Longest_Marker, Last);
               Item.Marker_Starts (Buffer (1)) := True;
            end if;

            --  What the best-path road needs about the vocabulary as a
            --  whole: how far ahead a piece can reach, and the lowest score
            --  an ordinary piece carries. The lowest is taken over the
            --  ordinary pieces alone, because the special ones are written
            --  with a score of zero or with a filler and neither says
            --  anything about what a rare piece costs.
            if Last > 0 then
               Item.Longest_Piece := Natural'Max (Item.Longest_Piece, Last);
            end if;

            if Entry_Value.Class = Class_Normal
              and then Entry_Value.Score < Item.Unknown_Cost
            then
               Item.Unknown_Cost := Entry_Value.Score;
            end if;

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
         --  The WordPiece road carries its own identifiers before any key is
         --  read, because the road is what decides them and not the file.
         --  The other runtime sets 101, 102 and 100 for a `bert` vocabulary
         --  and lets the file override; a published jina-bert-v2 states
         --  `cls_token_id` and `seperator_token_id` and neither
         --  `bos_token_id` nor `eos_token_id`, so read the two keys alone it
         --  wraps its text in nothing at all -- six tokens where the model
         --  was trained on eight, which is the same fault the all-MiniLM
         --  flags were and in a different key.
         --
         --  Guarded by the vocabulary's own size, because a fixture may be
         --  smaller than the identifiers a real one uses and an identifier
         --  outside the vocabulary is worse than none.
         if Item.Model = Kind_WordPiece then
            if Count > 103 then
               Item.Beginning := 101;
               Item.Ending := 102;
               Item.Unknown := 100;
            end if;
         end if;

         Special ("tokenizer.ggml.bos_token_id", Item.Beginning, Refused);
         if Refused then
            return;
         end if;

         Special ("tokenizer.ggml.eos_token_id", Item.Ending, Refused);
         if Refused then
            return;
         end if;

         --  And the name this road's own files use for the piece that ends
         --  a text, which the other runtime reads with the format's own
         --  spelling of "separator".
         if Item.Model = Kind_WordPiece then
            Special ("tokenizer.ggml.seperator_token_id", Item.Ending,
                     Refused);
            if Refused then
               return;
            end if;
         end if;

         Special ("tokenizer.ggml.unknown_token_id", Item.Unknown, Refused);
         if Refused then
            return;
         end if;

         --  The best-path road needs a piece to stand for what it cannot
         --  spell: the edge across an unseen character is the only thing
         --  keeping the lattice connected, so a vocabulary naming no
         --  unknown identifier has no answer at all for one character it
         --  has never seen. Refused here rather than at the first
         --  surprising prompt.
         if Item.Model = Kind_Unigram and then Item.Unknown = No_Token then
            Status := E.Make (E.Tokenizer_Missing_Byte_Fallback);
            return;
         end if;
      end;

      --  The same rule for the flags: absent means the model does not say,
      --  present but not a boolean means the file is wrong about itself.
      --
      --  Except on the WordPiece road, where absent does not mean the model
      --  does not say. A word-piece text is wrapped in its two markers by
      --  construction -- that is what the road is, not a policy a file
      --  chooses -- and a published all-MiniLM states the two identifiers
      --  and neither flag. Read as "does not say", it embedded six tokens
      --  where the model was trained on eight, and the vector that came
      --  back was a plausible 0.994 away from the right one: close enough
      --  to look correct beside anything but a second runtime.
      declare
         Flag : Boolean;
      begin
         if Item.Model = Kind_WordPiece then
            Item.Add_Beginning := True;
            Item.Add_End := True;
         end if;

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

         --  And whether the SentencePiece road writes a marker before the
         --  first character. Absent means it does, which is what every such
         --  vocabulary meant until gemma2 and gemma3 said otherwise; this
         --  had not been read at all, so both were given every prompt with
         --  a marker they were not trained to see and answered a question
         --  spelled differently from the one asked.
         Containers.Get_Boolean
           (Source, "tokenizer.ggml.add_space_prefix", Flag, Scratch);
         if E.Is_Ok (Scratch) then
            Item.Space_Prefix := Flag;
         elsif Scratch.Code /= E.GGUF_Missing_Metadata_Key then
            Status := Scratch;
            return;
         end if;

         --  And whether a run of whitespace becomes one marker or as many
         --  markers as there were spaces, which a unigram file states and
         --  the other roads do not ask.
         Containers.Get_Boolean
           (Source, "tokenizer.ggml.remove_extra_whitespaces", Flag, Scratch);
         if E.Is_Ok (Scratch) then
            Item.Merge_Spaces := Flag;
         elsif Scratch.Code /= E.GGUF_Missing_Metadata_Key then
            Status := Scratch;
            return;
         end if;
      end;

      --  What an unseen character costs on the best-path road: the lowest
      --  score any ordinary piece carries, less ten. The ten is what the
      --  architecture's own implementations use; what matters about it is
      --  that it is worse than any piece and by enough that a path through
      --  an unknown is never taken where a path through pieces exists.
      --  Zero where nothing set a lowest, which is a vocabulary of no
      --  ordinary pieces and no road at all.
      Item.Unknown_Cost :=
        (if Item.Unknown_Cost = Float'Last then 0.0
         else Item.Unknown_Cost - 10.0);

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

      --  The normalization table, for the road that carries one.
      --
      --  A unigram file states the text it was trained on already changed:
      --  a table from an input prefix to what replaces it, compiled into a
      --  double array and carried in the file itself. It is the model's own
      --  table and no two files need agree about it, which is why it is
      --  read rather than worked out here -- and why a file that states one
      --  and is tokenized as though it had not is a file answered in the
      --  wrong pieces.
      --
      --  The layout, as the format writes it: four bytes of length, that
      --  many bytes of trie, and the rest a pool of replacement strings the
      --  trie points into, each ended by a zero byte.
      if E.Is_Ok (Status) and then Item.Model = Kind_Unigram then
         declare
            Bytes : Natural := 0;
            Value : Long_Long_Integer;
            Span  : Natural;
         begin
            Containers.Get_Array_Length
              (Source, "tokenizer.ggml.precompiled_charsmap",
               Model_Runner.GGUF.Value_UInt8, Bytes, Scratch);

            if E.Is_Error (Scratch)
              and then Scratch.Code /= E.GGUF_Missing_Metadata_Key
            then
               Status := E.Make (E.Tokenizer_Invalid_Vocabulary);
               return;
            end if;

            if E.Is_Ok (Scratch) and then Bytes > 0 then
               if Bytes < 8 or else Bytes > Max_Charsmap then
                  Status := E.Make (E.Tokenizer_Invalid_Vocabulary);
                  E.Add_Integer (Status, "size", Long_Long_Integer (Bytes));
                  E.Add_Integer
                    (Status, "limit", Long_Long_Integer (Max_Charsmap));
                  return;
               end if;

               declare
                  Whole : String (1 .. Bytes);
               begin
                  for Index in 1 .. Bytes loop
                     Containers.Get_Integer_Element
                       (Source, "tokenizer.ggml.precompiled_charsmap",
                        Index, Value, Scratch);
                     if E.Is_Error (Scratch) then
                        Status := E.Make (E.Tokenizer_Invalid_Vocabulary);
                        return;
                     end if;
                     Whole (Index) :=
                       Character'Val (Natural (Value) mod 256);
                  end loop;

                  --  The trie's length, little-endian as the format writes
                  --  every number, and a whole number of four-byte nodes
                  --  that leaves room for a replacement pool after it.
                  Span :=
                    Character'Pos (Whole (1))
                    + Character'Pos (Whole (2)) * 256
                    + Character'Pos (Whole (3)) * 65_536
                    + Character'Pos (Whole (4)) * 16_777_216;

                  if Span mod 4 /= 0 or else Span + 4 >= Bytes then
                     Status := E.Make (E.Tokenizer_Invalid_Vocabulary);
                     E.Add_Integer (Status, "size", Long_Long_Integer (Span));
                     return;
                  end if;

                  Item.Charsmap := new Charsmap_Table;
                  Item.Charsmap.Nodes := new Trie_Nodes (0 .. Span / 4 - 1);
                  for Node in Item.Charsmap.Nodes'Range loop
                     declare
                        At_Byte : constant Natural := 5 + Node * 4;
                        use type Interfaces.Unsigned_32;
                     begin
                        Item.Charsmap.Nodes (Node) :=
                          Interfaces.Unsigned_32
                            (Character'Pos (Whole (At_Byte)))
                          + Interfaces.Shift_Left
                              (Interfaces.Unsigned_32
                                 (Character'Pos (Whole (At_Byte + 1))), 8)
                          + Interfaces.Shift_Left
                              (Interfaces.Unsigned_32
                                 (Character'Pos (Whole (At_Byte + 2))), 16)
                          + Interfaces.Shift_Left
                              (Interfaces.Unsigned_32
                                 (Character'Pos (Whole (At_Byte + 3))), 24);
                     end;
                  end loop;

                  Item.Charsmap.Replacements :=
                    new String'(Whole (Span + 5 .. Bytes));
               end;
            end if;
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
   --  The first step is the one the vocabularies disagree about. They name a
   --  pre-tokenizer -- gpt-2, llama3, qwen2 and others -- and Cut_At carries
   --  the five this build accepts, refusing any other by name at load. What
   --  a letter is, and what a digit, is asked of Ada.Wide_Wide_Characters,
   --  which knows the Unicode categories, so a CJK ideograph is a letter and
   --  a CJK comma is not, in any script and not only in ASCII.
   --
   --  What Cut_At carries is a rule per vocabulary and not a general engine
   --  for the expressions those pre-tokenizers are written as. Two things
   --  follow, and both are in Cut_At below rather than hidden:
   --
   --  The contractions are the seven the original names, matched exactly as
   --  written and so in lower case only.
   --
   --  A run of line endings is a run of whitespace and not a run of its own,
   --  so it gives its last character to the word that follows as any run of
   --  spaces does.
   --
   --  Whether either is the boundary a given model was trained on is a
   --  question about that model. The tests here settle that the engine cuts
   --  as this says and that an independent reader written from this
   --  description agrees; what they cannot settle is the description itself,
   --  which needs a second runtime and a real vocabulary -- see
   --  docs/reference-runtime.md.

   --  Unicode's punctuation categories -- Pc, Pd, Pe, Pf, Pi, Po and Ps --
   --  as ranges. Both roads need them, and both need punctuation and not
   --  "everything that is neither letter nor digit": a currency sign, a
   --  degree sign and a multiplication sign are symbols, and the difference
   --  shows in the answer twice. Two of the byte-pair rules cut every run of
   --  punctuation out of the text before anything else looks at it, so
   --  " €5" keeps the space with the sign there and " —b" does not; and
   --  WordPiece cuts a word at punctuation, so "±5" is one word and "a€b"
   --  is two.
   --
   --  Ada.Wide_Wide_Characters.Handling answers for letters, digits and
   --  spaces and has no general-category test, so the set is written out.
   --  It is 191 ranges over 842 code points, and it was taken from a
   --  Unicode database rather than from the other runtime: the two agree on
   --  every one of those code points and on no code point outside them,
   --  which is what makes the table evidence rather than a copy.
   type Span is record
      First : Natural;
      Last  : Natural;
   end record;

   Punctuation : constant array (1 .. 191) of Span :=
     [(33, 35), (37, 42), (44, 47), (58, 59), (63, 64), (91, 93),
      (95, 95), (123, 123), (125, 125), (161, 161), (167, 167),
      (171, 171), (182, 183), (187, 187), (191, 191), (894, 894),
      (903, 903), (1370, 1375), (1417, 1418), (1470, 1470),
      (1472, 1472), (1475, 1475), (1478, 1478), (1523, 1524),
      (1545, 1546), (1548, 1549), (1563, 1563), (1565, 1567),
      (1642, 1645), (1748, 1748), (1792, 1805), (2039, 2041),
      (2096, 2110), (2142, 2142), (2404, 2405), (2416, 2416),
      (2557, 2557), (2678, 2678), (2800, 2800), (3191, 3191),
      (3204, 3204), (3572, 3572), (3663, 3663), (3674, 3675),
      (3844, 3858), (3860, 3860), (3898, 3901), (3973, 3973),
      (4048, 4052), (4057, 4058), (4170, 4175), (4347, 4347),
      (4960, 4968), (5120, 5120), (5742, 5742), (5787, 5788),
      (5867, 5869), (5941, 5942), (6100, 6102), (6104, 6106),
      (6144, 6154), (6468, 6469), (6686, 6687), (6816, 6822),
      (6824, 6829), (7002, 7008), (7037, 7038), (7164, 7167),
      (7227, 7231), (7294, 7295), (7360, 7367), (7379, 7379),
      (8208, 8231), (8240, 8259), (8261, 8273), (8275, 8286),
      (8317, 8318), (8333, 8334), (8968, 8971), (9001, 9002),
      (10088, 10101), (10181, 10182), (10214, 10223), (10627, 10648),
      (10712, 10715), (10748, 10749), (11513, 11516), (11518, 11519),
      (11632, 11632), (11776, 11822), (11824, 11855), (11858, 11869),
      (12289, 12291), (12296, 12305), (12308, 12319), (12336, 12336),
      (12349, 12349), (12448, 12448), (12539, 12539), (42238, 42239),
      (42509, 42511), (42611, 42611), (42622, 42622), (42738, 42743),
      (43124, 43127), (43214, 43215), (43256, 43258), (43260, 43260),
      (43310, 43311), (43359, 43359), (43457, 43469), (43486, 43487),
      (43612, 43615), (43742, 43743), (43760, 43761), (44011, 44011),
      (64830, 64831), (65040, 65049), (65072, 65106), (65108, 65121),
      (65123, 65123), (65128, 65128), (65130, 65131), (65281, 65283),
      (65285, 65290), (65292, 65295), (65306, 65307), (65311, 65312),
      (65339, 65341), (65343, 65343), (65371, 65371), (65373, 65373),
      (65375, 65381), (65792, 65794), (66463, 66463), (66512, 66512),
      (66927, 66927), (67671, 67671), (67871, 67871), (67903, 67903),
      (68176, 68184), (68223, 68223), (68336, 68342), (68409, 68415),
      (68505, 68508), (69293, 69293), (69461, 69465), (69510, 69513),
      (69703, 69709), (69819, 69820), (69822, 69825), (69952, 69955),
      (70004, 70005), (70085, 70088), (70093, 70093), (70107, 70107),
      (70109, 70111), (70200, 70205), (70313, 70313), (70731, 70735),
      (70746, 70747), (70749, 70749), (70854, 70854), (71105, 71127),
      (71233, 71235), (71264, 71276), (71353, 71353), (71484, 71486),
      (71739, 71739), (72004, 72006), (72162, 72162), (72255, 72262),
      (72346, 72348), (72350, 72354), (72448, 72457), (72769, 72773),
      (72816, 72817), (73463, 73464), (73539, 73551), (73727, 73727),
      (74864, 74868), (77809, 77810), (92782, 92783), (92917, 92917),
      (92983, 92987), (92996, 92996), (93847, 93850), (94178, 94178),
      (113823, 113823), (121479, 121483), (125278, 125279)];

   function Is_Punctuation (Code_Point : Natural) return Boolean is
      Low  : Natural := Punctuation'First;
      High : Natural := Punctuation'Last;
   begin
      while Low <= High loop
         declare
            Middle : constant Natural := Low + (High - Low) / 2;
         begin
            if Code_Point < Punctuation (Middle).First then
               High := Middle - 1;
            elsif Code_Point > Punctuation (Middle).Last then
               Low := Middle + 1;
            else
               return True;
            end if;
         end;
      end loop;
      return False;
   end Is_Punctuation;

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
      --  allowed one leading character; a run of whitespace on its own; and
      --  the handful of English contractions the original tokenizer named.
      --  Which character may lead a run, and how far a run of digits
      --  reaches, is what the five rules disagree about, and every one of
      --  those disagreements is a case in the body below.
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

      --  What the two rules that pre-split cut whole: Unicode punctuation,
      --  the eight symbols they name outright -- $ + < = > ^ ~ | -- and the
      --  grave accent, which falcon names and the default does not. That one
      --  character is the whole difference between their classes, and it
      --  shows on " `b": the default leaves the space on the accent and
      --  falcon does not.
      function Cuts_Whole
        (Code_Point : Natural; Rule : Cut_Rule) return Boolean
      is (Code_Point in 36 | 43 | 60 | 61 | 62 | 94 | 124 | 126
          or else (Rule = Rule_Falcon and then Code_Point = 96)
          or else Is_Punctuation (Code_Point));

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

         --  Two rules cut every run of punctuation out of the text before
         --  the rest of the rule looks at it. That one step decides three
         --  things at once, and each of them is a different answer: a
         --  contraction is cut at its apostrophe rather than kept whole, a
         --  space before punctuation is left standing alone rather than
         --  leading it, and a run of punctuation is told apart from the
         --  symbols beside it.
         Splits : constant Boolean := Rule in Rule_Falcon | Rule_Default;

         --  The contractions, cut off whole and before anything else looks.
         type Contraction is access constant String;
         Ones : constant array (1 .. 7) of Contraction :=
           [new String'("'s"), new String'("'t"), new String'("'re"),
            new String'("'ve"), new String'("'m"), new String'("'ll"),
            new String'("'d")];

         --  True while the code point after Index is of the kind wanted:
         --  1 a letter, 2 a digit, 3 a space, 5 a character the rule cuts
         --  whole, 6 one it does not and which is none of the first three,
         --  and anything else none of the first three.
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
               when 5 => return Cuts_Whole (Value, Rule);
               when 6 =>
                  return not Is_Letter (Value) and then not Is_Digit (Value)
                    and then not Is_Space (Value)
                    and then not Cuts_Whole (Value, Rule);
               when others =>
                  return not Is_Letter (Value) and then not Is_Digit (Value)
                    and then not Is_Space (Value);
            end case;
         end Runs_On;

         --  How many digits run on from the code point after Index, up to
         --  three, which is as far as any rule asks.
         function Digits_Ahead return Natural is
            At_Byte : Natural := Index + Wide_Here;
            Value, Width : Natural;
            Seen : Natural := 0;
         begin
            while Seen < 3 and then At_Byte <= Text'Last loop
               Look (At_Byte, Value, Width);
               exit when Width = 0 or else not Is_Digit (Value);
               Seen := Seen + 1;
               At_Byte := At_Byte + Width;
            end loop;
            return Seen;
         end Digits_Ahead;

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

         --  The contractions, but only where nothing has cut the apostrophe
         --  out from under them first. An apostrophe is punctuation, so a
         --  rule that pre-splits punctuation never sees "'s" as a piece at
         --  all: it sees "'" and then "s". The seven names are still in the
         --  expression the rule is written as, and they never match.
         if not Splits then
            for One of Ones loop
               if Index + One'Length - 1 <= Text'Last
                 and then Text (Index .. Index + One'Length - 1) = One.all
               then
                  return Index + One'Length - 1;
               end if;
            end loop;
         end if;

         Look (Index, Here, Wide_Here);
         Look (Index + Wide_Here, Next, Wide_Next);

         --  What may lead a run depends on the rule and on what follows.
         --
         --  Under the original rule a space may lead anything: letters,
         --  digits, or symbols. Under llama3 and qwen2 any single character
         --  that is neither letter, digit nor line ending may lead letters --
         --  which is why a tab joins the word after it there -- a space may
         --  still lead symbols, and nothing at all may lead digits, which is
         --  what keeps their groups of three from starting with one.
         --
         --  The two that pre-split are the ones that need what follows.
         --  Falcon lets a space lead a short run of digits and not a long
         --  one, because the step that cuts digits into threes cuts them out
         --  of the text and leaves the space behind, and it only reaches a
         --  run of three or more: " 12" is one piece and " 123" is two. The
         --  default cuts every run of digits out however short, so a space
         --  never leads digits there at all. Both leave a space standing
         --  when what follows is punctuation, and neither does when it is a
         --  symbol they do not cut, which is why " €5" and " —b" answer
         --  differently under the same rule.
         if Wide_Next > 0 and then not Is_Space (Next) then
            if Is_Letter (Next) then
               if (if Rule in Rule_Default | Rule_GPT2 | Rule_Falcon
                            | Rule_SmolLM
                   then Here = 32
                   else not Is_Letter (Here) and then not Is_Digit (Here)
                        and then Here /= 13 and then Here /= 10)
               then
                  Step;
               end if;

            elsif Is_Digit (Next) then
               if Here = 32
                 and then (Rule = Rule_GPT2
                           or else (Rule = Rule_Falcon
                                    and then Digits_Ahead < 3))
               then
                  Step;
               end if;

            elsif Here = 32
              and then not (Splits and then Cuts_Whole (Next, Rule))
            then
               Step;
            end if;
         end if;

         if Is_Letter (Here) then
            while Runs_On (1) loop
               Step;
            end loop;

         elsif Is_Digit (Here) then
            --  Digits run to the end under the original rule, in threes
            --  under falcon, llama3 and the default, and one at a time under
            --  smollm and qwen2.
            declare
               Room : Natural :=
                 (case Rule is
                     when Rule_GPT2 => Natural'Last,
                     when Rule_Default => 3,
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

         elsif Splits and then Cuts_Whole (Here, Rule) then
            --  A run of what the rule cuts whole, and nothing else: the
            --  symbols it leaves alone end the run rather than joining it,
            --  which is what tells "`+" under falcon from "`" and "+" under
            --  the default.
            while Runs_On (5) loop
               Step;
            end loop;

         elsif Splits then
            while Runs_On (6) loop
               Step;
            end loop;

         else
            while Runs_On (4) loop
               Step;
            end loop;
         end if;

         return Index + Wide_Here - 1;
      end Cut_At;

   end BPE;

   --  The WordPiece road, which is Bert's.
   --
   --  Three steps, and the first is the one that surprises: the text is
   --  changed before anything is looked up. It is lower-cased, its accents
   --  are taken off, and its punctuation and its ideographs are cut away
   --  from the words around them -- so "Cafe", "cafe" and "cafe" with an
   --  acute are one word by the time the vocabulary sees them, and a model
   --  trained that way is a model that never saw the other two.
   --
   --  Then each word is spelled from the vocabulary, longest piece first,
   --  with every piece after the first written with two leading hashes: a
   --  vocabulary carries "play" and "##ing" and spells "playing" from the
   --  pair. A word no run of pieces spells is one unknown token, not a word
   --  partly spelled -- the pieces already matched are given back.
   --
   --  There is no merge table and no rank. Where byte-pair encoding builds a
   --  word up from characters by the order the pairs were learned, this cuts
   --  a word down from the front by what the vocabulary happens to carry,
   --  and the two arrive at different pieces for the same word.
   package Word_Piece is

      --  The mark a piece that *starts* a word is written with, which is
      --  the same U+2581 SentencePiece writes a space as.
      --
      --  This is the opposite of the convention the architecture's own
      --  papers describe, where a word starts bare and a continuation
      --  carries two leading hashes. A GGUF vocabulary is written the other
      --  way round: of the thirty thousand pieces in a published
      --  all-MiniLM, not one begins with the hashes and twenty-four
      --  thousand begin with this. The conversion rewrites them, and what
      --  this road reads is the file rather than the paper.
      --
      --  Written the paper's way first, and every word came back as a
      --  continuation piece: "a" found the bare "a" that continues a word
      --  rather than the marked one that starts it, so a real model
      --  embedded text nobody wrote. The fixture had invented the hashes
      --  and agreed with itself, which is what a fixture written from a
      --  description does when the description is of something else.
      Starts_Word : constant String := Space_Marker;

      --  Whether a code point ends the word before it and stands alone.
      --
      --  Punctuation does, and so does every ideograph: a run of Chinese is
      --  not spaced, and a vocabulary trained on it carries one piece a
      --  character rather than one a phrase. The rule reaches every script
      --  the standard library knows a category for rather than a range of
      --  code points written out here.
      function Stands_Alone (Code_Point : Natural) return Boolean;

      --  Whether a code point is thrown away rather than read: a control, a
      --  combining mark left after the accents come off, or the replacement
      --  character a decoder leaves where it could not read.
      function Discarded (Code_Point : Natural) return Boolean;

      --  Whether a code point separates words without being one.
      function Breaks (Code_Point : Natural) return Boolean;

      --  The code point with its accent taken off and lower-cased.
      function Folded (Code_Point : Natural) return Natural;

   end Word_Piece;

   package body Word_Piece is

      package Handling renames Ada.Wide_Wide_Characters.Handling;

      function Wide (Code_Point : Natural) return Wide_Wide_Character
      is (Wide_Wide_Character'Val (Code_Point));

      --  An ideograph is a letter that is not written with an alphabet, and
      --  what tells one is that it has no case: neither its lower nor its
      --  upper form differs from itself, and it is outside the scripts that
      --  space their words. Rather than test that indirectly, the blocks the
      --  architecture's own preprocessing names are used, which is what a
      --  vocabulary trained by that preprocessing was cut with.
      function Ideograph (Code_Point : Natural) return Boolean
      is (Code_Point in 16#4E00# .. 16#9FFF#
          or else Code_Point in 16#3400# .. 16#4DBF#
          or else Code_Point in 16#20000# .. 16#2A6DF#
          or else Code_Point in 16#2A700# .. 16#2B73F#
          or else Code_Point in 16#2B740# .. 16#2B81F#
          or else Code_Point in 16#2B820# .. 16#2CEAF#
          or else Code_Point in 16#F900# .. 16#FAFF#
          or else Code_Point in 16#2F800# .. 16#2FA1F#);

      --  Punctuation as this preprocessing counts it, which is wider than
      --  the category of that name in ASCII and exactly it outside: every
      --  ASCII character that is neither letter nor digit counts, so "$"
      --  and "+" and "`" cut a word even though Unicode files them under
      --  symbol -- and no character above ASCII does unless the category
      --  says so. Reading "graphic and not alphanumeric" for those instead
      --  cut a word at every currency, degree and trademark sign, which the
      --  published bge vocabulary settles: it spells "±5" as one word.
      function Punctuation (Code_Point : Natural) return Boolean
      is (Code_Point in 33 .. 47
          or else Code_Point in 58 .. 64
          or else Code_Point in 91 .. 96
          or else Code_Point in 123 .. 126
          or else (Code_Point > 127 and then Is_Punctuation (Code_Point)));

      function Stands_Alone (Code_Point : Natural) return Boolean
      is (Ideograph (Code_Point) or else Punctuation (Code_Point));

      function Discarded (Code_Point : Natural) return Boolean
      is (Code_Point = 0
          or else Code_Point = 16#FFFD#
          or else Handling.Is_Mark (Wide (Code_Point))
          or else (Handling.Is_Control (Wide (Code_Point))
                   and then Code_Point not in 9 | 10 | 13));

      function Breaks (Code_Point : Natural) return Boolean
      is (Code_Point in 32 | 9 | 10 | 11 | 12 | 13
          or else Handling.Is_Space (Wide (Code_Point))
          or else Handling.Is_Line_Terminator (Wide (Code_Point)));

      --  The accent first and the case after. To_Basic takes the diacritic
      --  off a character that carries one; a text whose accents are already
      --  written as separate combining marks loses them to Discarded
      --  instead, so both spellings of an accented word arrive at the same
      --  letters.
      --
      --  This is not a full canonical decomposition, and the difference is
      --  worth stating: a syllable that decomposes into pieces which are not
      --  marks -- Hangul is the case -- stays whole here where a decomposing
      --  implementation would take it apart. Latin text, which is what these
      --  vocabularies are overwhelmingly cut from, is the same either way.
      function Folded (Code_Point : Natural) return Natural
      is (Wide_Wide_Character'Pos
            (Handling.To_Lower (Handling.To_Basic (Wide (Code_Point)))));

   end Word_Piece;

   --  The longest piece starting at From that the vocabulary calls a control
   --  token or one of its author's own, with how many characters it spans.
   --
   --  A marker such as <|im_start|> or </s> is one token, not the dozen its
   --  spelling would merge into. A chat template writes them into the text it
   --  renders -- bos_token and eos_token are substituted as their spelling
   --  before anything is tokenized -- so a model reading that text has to see
   --  the token the template meant rather than its letters, and a model that
   --  sees the letters answers in letters, ending its turn by spelling the
   --  marker out instead of stopping.
   --
   --  Only positions whose byte some piece begins with are tried, so
   --  ordinary text costs one array read a position, and the longest match
   --  wins, so a marker that is a prefix of another cannot take its place.
   procedure Marker_At
     (Item   : Vocabulary;
      Text   : String;
      From   : Positive;
      Token  : out Token_Id;
      Length : out Natural) is
   begin
      Token := No_Token;
      Length := 0;

      if Item.Longest_Marker = 0
        or else not Item.Marker_Starts (Text (From))
      then
         return;
      end if;

      --  As far as the longest marker this vocabulary holds and no further.
      --  The bound used to be Max_Token_Bytes, which is thirty times longer
      --  than any real marker, and the cost of that fell on whoever wrote
      --  the text rather than on whoever wrote the file.
      for Reach in reverse 1 .. Natural'Min
        (Item.Longest_Marker, Text'Last - From + 1)
      loop
         declare
            Candidate : constant Token_Id :=
              Find (Item, Text (From .. From + Reach - 1));
         begin
            if Candidate /= No_Token
              and then Class_Of (Item, Candidate) in
                         Class_Control | Class_User_Defined
            then
               Token := Candidate;
               Length := Reach;
               return;
            end if;
         end;
      end loop;
   end Marker_At;

   --  What the unigram road tokenizes: the caller's text with the file's own
   --  normalization table applied to it and its spaces written as the marker.
   --
   --  Three things happen here and each of them is the file's decision
   --  rather than this program's. A prefix the table names is replaced by
   --  what the table says; a piece the file's author wrote in by hand is
   --  passed through untouched, so a marker survives a table that would
   --  otherwise rewrite it; and a byte sequence that is no character at all
   --  becomes the replacement character, one byte at a time, rather than
   --  failing the encode.
   --
   --  Then the spaces. A run of them becomes one marker where the file says
   --  to merge them and one marker each where it does not, and a marker goes
   --  in front of the first run of non-spaces either way -- which is the
   --  dummy prefix, and is written for every stretch between two markers
   --  rather than only for the first, because that is where the other
   --  runtime puts it.
   procedure Normalize_For_Unigram
     (Item  : Vocabulary;
      Text  : String;
      Store : out Text_Pool)
   is
      --  How far the table's replacement pool may be walked for one entry.
      --  A replacement is a short string; the bound is what keeps a file
      --  whose pool is missing its final zero from being walked off the end.
      Max_Replacement : constant := 256;

      --  Where the trie says the prefix starting at From is replaced, and
      --  by how much of the input. Zero length means the table says nothing.
      procedure Table_Match
        (From : Positive; At_Pool : out Natural; Span : out Natural)
      is
         use type Interfaces.Unsigned_32;

         function Node (Index : Interfaces.Unsigned_32)
            return Interfaces.Unsigned_32
         is (if Item.Charsmap = null
               or else Item.Charsmap.Nodes = null
               or else Natural (Index) > Item.Charsmap.Nodes'Last
             then 0
             else Item.Charsmap.Nodes (Natural (Index)));

         --  The three fields packed into one word: where this node's
         --  children begin, which byte reached it, and whether it ends a
         --  prefix the table names.
         function Base (Index : Interfaces.Unsigned_32)
            return Interfaces.Unsigned_32
         is (Interfaces.Shift_Left
               (Interfaces.Shift_Right (Node (Index), 10),
                Natural (Interfaces.Shift_Right
                           (Node (Index) and 2 ** 9, 6))));

         function Check (Index : Interfaces.Unsigned_32)
            return Interfaces.Unsigned_32
         is (Node (Index) and (2 ** 31 or 16#FF#));

         function Leaf (Index : Interfaces.Unsigned_32) return Boolean
         is ((Interfaces.Shift_Right (Node (Index), 8) and 1) = 1);

         function Value (Index : Interfaces.Unsigned_32)
            return Interfaces.Unsigned_32
         is (Node (Index) and (2 ** 31 - 1));

         Walk : Interfaces.Unsigned_32;
      begin
         At_Pool := 0;
         Span := 0;

         if Item.Charsmap = null
           or else Item.Charsmap.Nodes = null
           or else Item.Charsmap.Nodes'Length = 0
         then
            return;
         end if;

         Walk := Base (0);
         for Index in From .. Text'Last loop
            declare
               Byte : constant Interfaces.Unsigned_32 :=
                 Interfaces.Unsigned_32 (Character'Pos (Text (Index)));
               Ends : Boolean;
            begin
               exit when Byte = 0;
               Walk := Walk xor Byte;
               exit when Check (Walk) /= Byte;
               Ends := Leaf (Walk);
               Walk := Walk xor Base (Walk);
               if Ends then
                  Span := Index - From + 1;
                  At_Pool := Natural (Value (Walk));
               end if;
            end;
         end loop;
      end Table_Match;

      --  The longest piece the file's author wrote in by hand that starts
      --  here, which the table is not allowed to rewrite.
      function Hand_Written (From : Positive) return Natural is
         Reach : constant Natural :=
           Natural'Min (Item.Longest_Marker, Text'Last - From + 1);
      begin
         if Item.Longest_Marker = 0
           or else not Item.Marker_Starts (Text (From))
         then
            return 0;
         end if;

         for Span in reverse 1 .. Reach loop
            declare
               Piece : constant Token_Id :=
                 Find (Item, Text (From .. From + Span - 1));
            begin
               if Piece /= No_Token
                 and then Class_Of (Item, Piece) = Class_User_Defined
               then
                  return Span;
               end if;
            end;
         end loop;

         return 0;
      end Hand_Written;

      Needed : Natural := 0;
      Filled : Natural := 0;

      --  Both passes are this walk: the first counts what it would write
      --  and the second writes it. One walk written twice would be one walk
      --  that can disagree with itself about the size of its own answer.
      procedure Walk_Text (Counting : Boolean) is
         Prepended : Boolean := False;
         In_Word   : Boolean := False;

         procedure Put (Piece : String) is
         begin
            if Counting then
               Needed := Needed + Piece'Length;
            else
               Store (Filled + 1 .. Filled + Piece'Length) := Piece;
               Filled := Filled + Piece'Length;
            end if;
         end Put;

         procedure Put_Byte (Item_Byte : Character) is
         begin
            if Item_Byte /= ' ' then
               if not In_Word then
                  In_Word := True;
                  if (Item.Space_Prefix and then not Prepended)
                    or else Item.Merge_Spaces
                  then
                     Put (Space_Marker);
                     Prepended := True;
                  end if;
               end if;
               Put ([1 => Item_Byte]);
            else
               In_Word := False;
               if not Item.Merge_Spaces then
                  Put (Space_Marker);
               end if;
            end if;
         end Put_Byte;

         At_Byte : Positive := Text'First;
      begin
         while At_Byte <= Text'Last loop
            declare
               Kept    : constant Natural := Hand_Written (At_Byte);
               At_Pool : Natural;
               Span    : Natural;
               Eaten   : Natural;
            begin
               if Kept > 0 then
                  --  Passed through as written, and past the space rules
                  --  as well: a hand-written piece is the text the author
                  --  meant and not a run of words and spaces.
                  if Counting then
                     Needed := Needed + Kept;
                  else
                     Store (Filled + 1 .. Filled + Kept) :=
                       Text (At_Byte .. At_Byte + Kept - 1);
                     Filled := Filled + Kept;
                  end if;
                  In_Word := True;
                  Eaten := Kept;
               else
                  Table_Match (At_Byte, At_Pool, Span);

                  if Span > 0 then
                     declare
                        Pool : String renames Item.Charsmap.Replacements.all;
                        Stop : constant Natural := Pool'First + At_Pool;
                        Room : constant Natural :=
                          Natural'Min (Max_Replacement, Pool'Last - Stop + 1);
                        Seen : Natural := 0;
                     begin
                        while Seen < Room
                          and then Pool (Stop + Seen) /= Character'Val (0)
                        loop
                           Seen := Seen + 1;
                        end loop;

                        for Offset in 0 .. Seen - 1 loop
                           Put_Byte (Pool (Stop + Offset));
                        end loop;
                        Eaten := Span;
                     end;
                  else
                     declare
                        Value, Width : Natural;
                     begin
                        Model_Runner.UTF8.Decode_First
                          (Text (At_Byte .. Text'Last), Value, Width);
                        if Width = 0 then
                           Put_Byte (Character'Val (16#EF#));
                           Put_Byte (Character'Val (16#BF#));
                           Put_Byte (Character'Val (16#BD#));
                           Eaten := 1;
                        else
                           for Offset in 0 .. Width - 1 loop
                              Put_Byte (Text (At_Byte + Offset));
                           end loop;
                           Eaten := Width;
                        end if;
                     end;
                  end if;
               end if;

               At_Byte := At_Byte + Natural'Max (Eaten, 1);
            end;
         end loop;
      end Walk_Text;
   begin
      Store := null;
      Walk_Text (Counting => True);

      if Needed = 0 then
         return;
      end if;

      Store := new String (1 .. Needed);
      Walk_Text (Counting => False);
   end Normalize_For_Unigram;

   --  Encode text that holds no marker, on whichever road the vocabulary
   --  names. Lead says whether this text begins the caller's text, which is
   --  the only place SentencePiece puts its dummy word marker.
   procedure Encode_Plain
     (Item   : Vocabulary;
      Text   : String;
      Lead   : Boolean;
      Target : out Token_Array;
      Last   : out Natural;
      Status : out E.Error_Info)
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

      --  SentencePiece works on text in which every space is the marker and,
      --  where the file asks for it, a dummy marker precedes the first
      --  character. Substituting up front keeps every symbol a slice of one
      --  string, which is what makes a merge a constant-time splice of two
      --  adjacent slices.
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
         Needed :=
           (if Lead and then Item.Space_Prefix then Space_Marker'Length
            else 0);
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
            if Lead and then Item.Space_Prefix then
               Put (Space_Marker);
            end if;

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

      --  A WordPiece vocabulary takes a third road: the text is changed,
      --  then cut into words, then each word spelled from the front.
      if Item.Model = Kind_WordPiece then
         declare
            Produced : Natural := 0;
            Refused  : Boolean := False;

            --  The folded text, and where each word in it begins and ends.
            --  Folding can only shorten a code point's encoding or leave it
            --  as it was -- a letter with its accent off is never wider than
            --  the letter with it -- so the input's own length is room
            --  enough, and the count of words cannot exceed the count of
            --  code points.
            Room  : String (1 .. Text'Length * 4);
            Held  : Natural := 0;

            Starts : array (1 .. Max_Symbols) of Natural;
            Ends   : array (1 .. Max_Symbols) of Natural;
            Words  : Natural := 0;

            --  Whether the word being built has anything in it yet, which is
            --  what says a break has a word to close.
            Open   : Boolean := False;

            --  Add one token, or say why not. As on the byte-pair road: a
            --  buffer with no room is a refusal and not a short answer.
            procedure Put (Token : Token_Id) is
            begin
               if Refused then
                  return;
               end if;

               if Produced >= Target'Length then
                  Status := E.Make (E.Tokenizer_Buffer_Too_Small);
                  E.Add_Integer
                    (Status, "size", Long_Long_Integer (Target'Length));
                  Refused := True;
                  return;
               end if;

               Produced := Produced + 1;
               Target (Target'First + Produced - 1) := Token;
            end Put;

            --  Close the word being built, if one is open.
            procedure Close_Word is
            begin
               if Open then
                  Ends (Words) := Held;
                  Open := False;
               end if;
            end Close_Word;

            --  Put one folded code point into the word being built,
            --  starting a word where none is open.
            procedure Extend (Code_Point : Natural) is
               One : constant String := Model_Runner.UTF8.Encode (Code_Point);
            begin
               if not Open then
                  if Words >= Max_Symbols then
                     Refused := True;
                     Status := E.Make (E.Tokenizer_Input_Too_Long);
                     E.Add_Integer
                       (Status, "limit", Long_Long_Integer (Max_Symbols));
                     return;
                  end if;

                  Words := Words + 1;
                  Starts (Words) := Held + 1;
                  Open := True;
               end if;

               Room (Held + 1 .. Held + One'Length) := One;
               Held := Held + One'Length;
            end Extend;

            --  Spell one word from the vocabulary, longest piece first.
            --
            --  Every piece after the first is looked up with the two hashes
            --  in front of it. A word that runs out of pieces part way is
            --  one unknown token and not the pieces it managed: half a word
            --  spelled is a different word.
            procedure Spell (Word : String) is
               Held_Pieces : array (1 .. Max_Pieces) of Token_Id;
               Count : Natural := 0;
               From  : Positive := Word'First;
            begin
               while From <= Word'Last loop
                  declare
                     Stop  : Natural := Word'Last;
                     Found : Token_Id := No_Token;
                  begin
                     --  Longest first, shrinking by a code point at a time
                     --  so that a piece never ends inside a character.
                     while Stop >= From loop
                        declare
                           Piece : constant String :=
                             (if From = Word'First
                              then Word_Piece.Starts_Word
                                   & Word (From .. Stop)
                              else Word (From .. Stop));
                        begin
                           Found := Find (Item, Piece);
                           exit when Found /= No_Token;
                        end;

                        --  Back up to the previous character boundary.
                        Stop := Stop - 1;
                        while Stop >= From
                          and then Stop < Word'Last
                          and then Character'Pos (Word (Stop + 1)) in 128 .. 191
                        loop
                           Stop := Stop - 1;
                        end loop;
                     end loop;

                     if Found = No_Token or else Count >= Max_Pieces then
                        Count := 0;
                        exit;
                     end if;

                     Count := Count + 1;
                     Held_Pieces (Count) := Found;
                     From := Stop + 1;
                  end;
               end loop;

               if Count = 0 then
                  --  Nothing the vocabulary can spell. A WordPiece file
                  --  always carries an unknown token; one that does not is
                  --  refused rather than quietly dropping the word, which is
                  --  the defect the byte-pair road already had once.
                  if Item.Unknown /= No_Token then
                     Put (Item.Unknown);
                  elsif not Refused then
                     Status := E.Make (E.Tokenizer_Missing_Byte_Fallback);
                     E.Add_Text (Status, "value", Word, E.Param_Identifier);
                     Refused := True;
                  end if;
                  return;
               end if;

               for Index in 1 .. Count loop
                  Put (Held_Pieces (Index));
                  exit when Refused;
               end loop;
            end Spell;

            Index : Natural := Text'First;
         begin
            --  Fold and cut in one pass over the text.
            while Index <= Text'Last loop
               declare
                  Code, Width : Natural;
               begin
                  Model_Runner.UTF8.Decode_First
                    (Text (Index .. Text'Last), Code, Width);
                  exit when Width = 0;
                  Index := Index + Width;

                  if Word_Piece.Breaks (Code) then
                     Close_Word;
                  else
                     declare
                        Folded : constant Natural := Word_Piece.Folded (Code);
                     begin
                        if Word_Piece.Discarded (Folded) then
                           null;
                        elsif Word_Piece.Stands_Alone (Folded) then
                           Close_Word;
                           Extend (Folded);
                           Close_Word;
                        else
                           Extend (Folded);
                        end if;
                     end;
                  end if;
               end;

               exit when Refused;
            end loop;

            Close_Word;

            for Which in 1 .. Words loop
               exit when Refused;
               if Ends (Which) >= Starts (Which) then
                  Spell (Room (Starts (Which) .. Ends (Which)));
               end if;
            end loop;

            Last := Produced;

            if Refused then
               Last := 0;
            end if;
            return;
         end;
      end if;

      --  Byte-pair vocabularies take a different road entirely: the text is
      --  cut first, and each piece merged on its own.
      if Item.Model = Kind_BPE then
         declare
            Produced : Natural := 0;
            From     : Positive := Text'First;
            Refused  : Boolean := False;

            --  Add one token, or say why not.
            --
            --  This road used to write straight into Target under a test for
            --  room and do nothing when there was none, so a caller whose
            --  buffer was too small got a short answer and a success -- the
            --  other road reports MR-TOK-0013 for exactly that, and an
            --  independent reader written from the description is what
            --  showed the two apart.
            procedure Put (Token : Token_Id) is
            begin
               if Refused then
                  return;
               end if;

               if Produced >= Target'Length then
                  Status := E.Make (E.Tokenizer_Buffer_Too_Small);
                  E.Add_Integer
                    (Status, "size", Long_Long_Integer (Target'Length));
                  Refused := True;
                  return;
               end if;

               Produced := Produced + 1;
               Target (Target'First + Produced - 1) := Token;
            end Put;

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
                     --  A symbol the vocabulary does not carry. A byte-level
                     --  vocabulary carries a piece for every one of the 256
                     --  stand-in characters, so this cannot happen to a file
                     --  that was written properly -- and a file that was not
                     --  is the case this program exists to survive. It used
                     --  to be dropped, which deleted a piece of the caller's
                     --  own prompt without saying so.
                     if Token /= No_Token then
                        Put (Token);
                     elsif Item.Unknown /= No_Token then
                        Put (Item.Unknown);
                     elsif not Refused then
                        Status := E.Make (E.Tokenizer_Missing_Byte_Fallback);
                        E.Add_Text
                          (Status, "value",
                           Mapped (Starts (Index) .. Ends (Index)),
                           E.Param_Identifier);
                        Refused := True;
                     end if;
                  end;

                  exit when Refused;
               end loop;
            end Emit;
         begin
            while From <= Text'Last loop
               declare
                  Stop : constant Natural :=
                    BPE.Cut_At (Text, From, Item.Cutting);
               begin
                  exit when Stop < From;
                  Emit (Text (From .. Stop));
                  From := Stop + 1;
               end;

               exit when Refused;
            end loop;

            Last := (if Refused then 0 else Produced);
            return;
         end;
      end if;

      --  The unigram road.
      --
      --  Two steps and neither is a merge. The text is normalized first --
      --  through the table the file carries, then with its spaces written as
      --  the marker -- and then cut into the pieces whose scores sum highest
      --  over the whole of it.
      --
      --  That second step is why this is a road and not a setting on the
      --  SentencePiece one. Merging the best-scoring adjacent pair is a
      --  greedy walk: it never reconsiders, so a merge taken early can
      --  foreclose a split that would have scored higher whole, and a piece
      --  that lies on the best path but never appears as the join of two
      --  survivors is unreachable by merging at all. The scores are log
      --  probabilities, which is what makes summing them the right thing to
      --  do with them and comparing them the wrong one.
      if Item.Model = Kind_Unigram then
         declare
            --  What the text becomes once the file's table has been applied
            --  to it and its spaces written as the marker. On the heap for
            --  the reason the other working text is: a prompt of a few
            --  megabytes would exhaust the stack in a declarative part.
            Normal : Text_Pool := null;

            --  The best sum reaching each byte boundary of that text, and
            --  the edge that reached it: where the piece began and which
            --  piece it was.
            type Edge is record
               From  : Natural := 0;
               Token : Token_Id := No_Token;
               Sum   : Float := Float'First;
            end record;

            type Edge_Array is array (Natural range <>) of Edge;
            type Edge_Access is access Edge_Array;

            procedure Free_Edges is
              new Ada.Unchecked_Deallocation (Edge_Array, Edge_Access);

            Best : Edge_Access := null;

            --  Report a full target buffer and leave nothing behind.
            procedure Put (Code : E.Error_Code) is
            begin
               Status := E.Make (Code);
               Last := 0;
            end Put;

            procedure Release is
            begin
               if Normal /= null then
                  Deallocate (Normal);
               end if;
               if Best /= null then
                  Free_Edges (Best);
               end if;
            end Release;
         begin
            --  Lead is not asked for here. The other runtime writes
            --  the dummy prefix once a stretch rather than once a text, so
            --  a marker in the middle of a prompt begins a new one; asking
            --  Lead would put it in front of the first stretch alone.
            Normalize_For_Unigram (Item, Text, Normal);

            if Normal = null or else Normal'Length = 0 then
               Release;
               return;
            end if;

            if Normal'Length > Max_Normalized then
               Put (E.Tokenizer_Input_Too_Long);
               E.Add_Integer
                 (Status, "limit", Long_Long_Integer (Max_Normalized));
               Release;
               return;
            end if;

            Best := new Edge_Array (0 .. Normal'Length);
            Best (0) := (From => 0, Token => Item.Unknown, Sum => 0.0);

            --  One code point at a time, and from each boundary every piece
            --  the vocabulary holds that starts there. A boundary the walk
            --  never reached carries Float'First and cannot win anything,
            --  which is what keeps a partial character from being an edge.
            declare
               At_Byte : Natural := 1;
            begin
               while At_Byte <= Normal'Length loop
                  declare
                     Value, Width : Natural;
                     Covered : Boolean := False;
                     Reach   : constant Natural :=
                       Natural'Min (Item.Longest_Piece,
                                    Normal'Length - At_Byte + 1);
                  begin
                     Model_Runner.UTF8.Decode_First
                       (Normal (At_Byte .. Normal'Length), Value, Width);
                     if Width = 0 then
                        Width := 1;
                     end if;

                     if Best (At_Byte - 1).Sum > Float'First then
                        for Span in 1 .. Reach loop
                           declare
                              Piece : constant Token_Id :=
                                Find (Item,
                                      Normal (At_Byte .. At_Byte + Span - 1));
                           begin
                              if Piece /= No_Token
                                and then Class_Of (Item, Piece)
                                         /= Class_Control
                              then
                                 if Span = Width then
                                    Covered := True;
                                 end if;

                                 declare
                                    --  A piece the file's author wrote in
                                    --  by hand is scored zero rather than
                                    --  by its own score, which is what
                                    --  makes it beat the pieces it spells
                                    --  out to.
                                    Worth : constant Float :=
                                      (if Class_Of (Item, Piece)
                                          = Class_User_Defined
                                       then 0.0
                                       else Score_Of (Item, Piece));
                                    Reached : constant Float :=
                                      Best (At_Byte - 1).Sum + Worth;
                                 begin
                                    if Reached
                                       > Best (At_Byte + Span - 1).Sum
                                    then
                                       Best (At_Byte + Span - 1) :=
                                         (From  => At_Byte - 1,
                                          Token => Piece,
                                          Sum   => Reached);
                                    end if;
                                 end;
                              end if;
                           end;
                        end loop;
                     end if;

                     --  Where no piece covers this code point on its own,
                     --  an edge across it at the unknown's cost. Without it
                     --  one unseen character would leave the lattice
                     --  unconnected and fail the whole encode.
                     if not Covered
                       and then Best (At_Byte - 1).Sum > Float'First
                     then
                        declare
                           Reached : constant Float :=
                             Best (At_Byte - 1).Sum + Item.Unknown_Cost;
                        begin
                           if Reached > Best (At_Byte + Width - 1).Sum then
                              Best (At_Byte + Width - 1) :=
                                (From  => At_Byte - 1,
                                 Token => Item.Unknown,
                                 Sum   => Reached);
                           end if;
                        end;
                     end if;

                     At_Byte := At_Byte + Width;
                  end;
               end loop;
            end;

            --  Walk the edges back from the end, then reverse. A run of
            --  unknowns becomes one unknown: the model was never trained to
            --  see the same piece twice for one unreadable stretch.
            declare
               Room  : Token_Array (1 .. Target'Length);
               Held  : Natural := 0;
               Where : Natural := Normal'Length;
               Prior_Unknown : Boolean := False;
            begin
               loop
                  declare
                     This : constant Edge := Best (Where);
                     Is_Unknown : constant Boolean :=
                       This.Token = Item.Unknown;
                  begin
                     if not (Prior_Unknown and then Is_Unknown) then
                        if Held >= Room'Length then
                           Put (E.Tokenizer_Buffer_Too_Small);
                           Release;
                           return;
                        end if;
                        Held := Held + 1;
                        Room (Held) := This.Token;
                     end if;

                     exit when This.From = 0;
                     Prior_Unknown := Is_Unknown;
                     Where := This.From;
                  end;
               end loop;

               for Index in 1 .. Held loop
                  Target (Target'First + Index - 1) := Room (Held - Index + 1);
               end loop;
               Last := Held;
            end;

            Release;
            return;
         exception
            when others =>
               Last := 0;
               Status := E.Make (E.Internal_Invariant_Violated);
               raise;
         end;
      end if;

      Build_Working (Working);

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
   exception
      when Occurrence : others =>
         Release;
         Status := E.Make (E.Internal_Invariant_Violated);
         E.Add_Frame (Status, "tokenizer.encode");
         E.Add_Frame
           (Status, Ada.Exceptions.Exception_Name (Occurrence));
   end Encode_Plain;

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
      Produced : Natural := 0;

      --  Append a token, reporting a full target buffer.
      procedure Put (Token : Token_Id; Ok : out Boolean) is
      begin
         if Produced >= Target'Length then
            Status := E.Make (E.Tokenizer_Buffer_Too_Small);
            E.Add_Integer (Status, "size", Long_Long_Integer (Target'Length));
            Ok := False;
         else
            Produced := Produced + 1;
            Target (Target'First + Produced - 1) := Token;
            Ok := True;
         end if;
      end Put;

      --  Encode one stretch of ordinary text into what is left of Target.
      procedure Part (Text : String; Lead : Boolean; Ok : out Boolean) is
         Made : Natural;
      begin
         Encode_Plain
           (Item, Text, Lead,
            Target (Target'First + Produced .. Target'Last), Made, Status);
         Ok := E.Is_Ok (Status);
         if Ok then
            Produced := Produced + Made;
         end if;
      end Part;

      From : Positive := Text'First;
      Lead : Boolean := True;
      Ok   : Boolean;
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

      if Add_Beginning and then Item.Beginning /= No_Token then
         Put (Item.Beginning, Ok);
         if not Ok then
            return;
         end if;
      end if;

      --  Cut the text at every marker and encode what lies between. Both
      --  roads come through here, so the rule is one rule: it used to live
      --  inside the byte-pair road alone, which left a SentencePiece model
      --  reading its own template's end marker as a run of bytes.
      --
      --  The dummy word marker SentencePiece puts in front goes on the first
      --  stretch only. A stretch that follows a marker is a continuation of
      --  the text rather than the start of it, and this way a text holding
      --  no marker is tokenized exactly as it was before the rule arrived.
      --  Empty text is a stretch of its own and not no stretch at all: on the
      --  SentencePiece road the dummy word marker is a token, and a caller
      --  asking for the beginning token and nothing else gets both.
      if Text'Length = 0 then
         Part (Text, True, Ok);
         if not Ok then
            Last := 0;
            return;
         end if;
      end if;

      while From <= Text'Last loop
         declare
            Token : Token_Id;
            Span  : Natural;
            Found : Natural := 0;
            Reach : Natural := 0;
            Scan  : Positive := From;
         begin
            loop
               Marker_At (Item, Text, Scan, Token, Span);
               if Token /= No_Token then
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
                  Part (Text (From .. Stop), Lead, Ok);
                  if not Ok then
                     Last := 0;
                     return;
                  end if;
                  Lead := False;
               end if;
            end;

            exit when Found = 0;

            Put (Token, Ok);
            if not Ok then
               Last := 0;
               return;
            end if;

            Lead := False;
            From := Found + Reach;
         end;
      end loop;

      if Add_End and then Item.Ending /= No_Token then
         Put (Item.Ending, Ok);
         if not Ok then
            Last := 0;
            return;
         end if;
      end if;

      Last := Produced;
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

      --  WordPiece writes a piece that continues a word with two leading
      --  hashes and a piece that starts one with nothing, so the spaces are
      --  in neither: they are what the hashes are absent for. Decoding puts
      --  them back -- a hashed piece joins what came before, an unhashed one
      --  begins a word and takes a space in front of it unless it is the
      --  first thing said.
      --
      --  What this cannot put back is the text as it was written. The road
      --  folded the case and took the accents off before anything was looked
      --  up, so what comes out of a round trip is the folded text and not
      --  the caller's. That is a property of the vocabulary rather than of
      --  this decoder, and it is why nothing here claims a round trip for
      --  this road.
      if Item.Model = Kind_WordPiece then
         if Raw'Length >= Word_Piece.Starts_Word'Length
           and then Raw (Raw'First .. Raw'First
                         + Word_Piece.Starts_Word'Length - 1)
                    = Word_Piece.Starts_Word
         then
            declare
               Body_Of : constant String :=
                 Raw (Raw'First + Word_Piece.Starts_Word'Length .. Raw'Last);
            begin
               return (if First then Body_Of else " " & Body_Of);
            end;
         else
            --  A bare piece continues the word before it, so it joins what
            --  came before with nothing between.
            return Raw;
         end if;
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
