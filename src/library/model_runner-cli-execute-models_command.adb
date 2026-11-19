with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Model_Runner.CLI.Choosers;
with Ada.Containers.Indefinite_Vectors;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces;
with Model_Runner.Hub;
with Model_Runner.Hub.Store;
with Model_Runner.Platform;
with Model_Runner.Config;
with Model_Runner.Heap_Buffers;

package body Model_Runner.CLI.Execute.Models_Command is

   use type Ada.Directories.File_Kind;
   use type Interfaces.Unsigned_64;

   --------------
   -- Dispatch --
   --------------

   --  Offer a choice of the models on hand when a run names none. The
   --  models directory is listed, a shard set shown once by its first
   --  shard, and the user's number selects one; Path is its file and
   --  Picked is true only then. No directory, no model in it, no terminal
   --  to ask at and a blank or out-of-range answer all leave Picked false
   --  so the caller reports a model as missing as before.
   --  What a download leaves beside a model: its part and the part's
   --  notes, the note of where a join of its chunks began, its lock.
   type Suffix_Access is access constant String;
   Leftover_Suffixes : constant array (Positive range <>) of Suffix_Access :=
     [new String'(".part"), new String'(".part.sha256"),
      new String'(".part.revision"), new String'(".part.joining"),
      new String'(".part.cut"), new String'(".lock")];

   --  The models found, by the name shown and the whole path: five hundred
   --  of each, a quarter of a megabyte apiece, held on the heap rather
   --  than in the frame that lists them.
   --  The other folder of models as its files are labelled: its path, the
   --  home shown as ~, ahead of each name.
   function Other_Label return String is
      Other : constant String := Model_Runner.Platform.Other_Models_Directory;
      Home_Models : constant String :=
        Model_Runner.Platform.Home_Models_Directory;
   begin
      return
        (if Home_Models /= "" and then Other /= ""
           and then Ada.Directories.Full_Name (Other)
                    = Ada.Directories.Full_Name (Home_Models)
         then "~/models/"
         else Other & "/");
   exception
      when others =>
         return Other & "/";
   end Other_Label;

   type Name_Array is array (1 .. 500) of Model_Runner.Text.Bounded;
   package Name_Rooms is new Model_Runner.Heap_Buffers.Holders (Name_Array);

   procedure Choose_Model
     (Screen : in out Pres.Console;
      Path   : out Model_Runner.Text.Bounded;
      Picked : out Boolean;
      Title  : String := "cli.choose.header";
      Offer_Downloads : Boolean := True)
   is
      --  The list a conversation's /model shows: only what is on the
      --  machine, and only what can hold the conversation.
      Conversing : constant Boolean := not Offer_Downloads;
      use Ada.Directories;

      Dir : constant String := Model_Runner.Platform.Models_Directory;
      Max : constant Positive := Name_Array'Last;
      Shown_Room : Name_Rooms.Holder;
      Full_Room  : Name_Rooms.Holder;
      Shown : Name_Array renames Shown_Room.Data.all;
      Full  : Name_Array renames Full_Room.Data.all;
      Sizes : array (1 .. Max) of Long_Long_Integer := [others => 0];
      Count : Natural := 0;

      --  What the machine has to hold a model in, or zero where it will not
      --  say. A model much past two thirds of it will not leave room for
      --  the cache and the rest, and is marked too big to run here.
      Budget : constant Long_Long_Integer :=
        Long_Long_Integer (Model_Runner.Platform.Physical_Memory);

      function Too_Big (Bytes : Long_Long_Integer) return Boolean
      is (Budget > 0 and then Bytes > Budget * 2 / 3);

      --  A byte count as gigabytes to two decimals, in integers so no float
      --  is formatted -- the shown size for a settings-file suggestion that
      --  gave its bytes.
      function Giga (Bytes : Long_Long_Integer) return String is
         Cents : constant Long_Long_Integer := Bytes / 10_000_000;
         Whole : constant Long_Long_Integer := Cents / 100;
         Frac  : constant Long_Long_Integer := Cents mod 100;
         Shown : constant String := Long_Long_Integer'Image (Whole);
      begin
         return Shown (Shown'First + 1 .. Shown'Last) & "."
           & Character'Val (Character'Pos ('0') + Natural (Frac / 10))
           & Character'Val (Character'Pos ('0') + Natural (Frac mod 10))
           & " GB";
      end Giga;

      --  The architecture a model file says it is, from the first keys of
      --  its header: general.architecture comes first in every file the
      --  converters write. Empty where it cannot be read there.
      function Architecture_Of (Full_Path : String) return String is
         use Ada.Streams;
         File  : Ada.Streams.Stream_IO.File_Type;
         Bytes : Stream_Element_Array (1 .. 4096);
         Last  : Stream_Element_Offset;
         At_Byte : Stream_Element_Offset := 1;

         function Read_U64 return Interfaces.Unsigned_64 is
            Value : Interfaces.Unsigned_64 := 0;
         begin
            if At_Byte + 7 > Last then
               raise Constraint_Error;
            end if;
            for Shift in reverse 0 .. 7 loop
               Value := Value * 256 + Interfaces.Unsigned_64 (Bytes (At_Byte + Stream_Element_Offset (Shift)));
            end loop;
            At_Byte := At_Byte + 8;
            return Value;
         end Read_U64;

         function Read_U32 return Natural is
            Value : Natural := 0;
         begin
            if At_Byte + 3 > Last then
               raise Constraint_Error;
            end if;
            for Shift in reverse 0 .. 3 loop
               Value := Value * 256 + Natural (Bytes (At_Byte + Stream_Element_Offset (Shift)));
            end loop;
            At_Byte := At_Byte + 4;
            return Value;
         end Read_U32;

         function Read_Text return String is
            Length : constant Interfaces.Unsigned_64 := Read_U64;
         begin
            if Length > Interfaces.Unsigned_64 (Last - At_Byte + 1) then
               raise Constraint_Error;
            end if;
            declare
               Text : String (1 .. Natural (Length));
            begin
               for Index in Text'Range loop
                  Text (Index) := Character'Val (Bytes (At_Byte + Stream_Element_Offset (Index - 1)));
               end loop;
               At_Byte := At_Byte + Stream_Element_Offset (Length);
               return Text;
            end;
         end Read_Text;
      begin
         Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Full_Path, Form => "shared=yes");
         Ada.Streams.Stream_IO.Read (File, Bytes, Last);
         Ada.Streams.Stream_IO.Close (File);
         if Last < 24 or else Bytes (1 .. 4) /= [71, 71, 85, 70] then   --  "GGUF"
            return "";
         end if;
         --  No keys at all: no tokenizer, no architecture -- tensors alone,
         --  as a picture model's weights may come.
         At_Byte := 17;
         if Read_U64 = 0 then
            return "(none)";
         end if;
         At_Byte := 9;
         declare
            Tensors : constant Interfaces.Unsigned_64 := Read_U64;
            Keys    : constant Interfaces.Unsigned_64 := Read_U64;
            Said    : Ada.Strings.Unbounded.Unbounded_String;
         begin
            At_Byte := 25;   --  past the magic, the version and the two counts
            --  The first keys, each skipped as its type says: the
            --  architecture, and how many blocks it says it has.
            for Key_Index in 1 .. Natural (Interfaces.Unsigned_64'Min (Keys, 24)) loop
               declare
                  Key  : constant String := Read_Text;
                  Kind : constant Natural := Read_U32;
                  Arch : constant String := Ada.Strings.Unbounded.To_String (Said);
               begin
                  case Kind is
                     when 8 =>
                        declare
                           Value : constant String := Read_Text;
                        begin
                           if Key = "general.architecture" then
                              Said := Ada.Strings.Unbounded.To_Unbounded_String (Value);
                           end if;
                        end;
                     when 4 | 5 =>
                        declare
                           Count : constant Natural := Read_U32;
                        begin
                           --  Fewer tensors than the blocks it says it has:
                           --  part of a model -- a next-token head, a
                           --  drafting block -- not a model.
                           if Arch /= "" and then Key = Arch & ".block_count"
                             and then Interfaces.Unsigned_64 (Count) > Tensors
                           then
                              return "(part)";
                           end if;
                        end;
                     when 0 | 1 | 7 => At_Byte := At_Byte + 1;
                     when 2 | 3 => At_Byte := At_Byte + 2;
                     when 6 => At_Byte := At_Byte + 4;
                     when 10 | 11 | 12 => At_Byte := At_Byte + 8;
                     when others => exit;
                  end case;
               end;
            end loop;
            return Ada.Strings.Unbounded.To_String (Said);
         end;
      exception
         when others =>
            if Ada.Streams.Stream_IO.Is_Open (File) then
               Ada.Streams.Stream_IO.Close (File);
            end if;
            return "";
      end Architecture_Of;

      --  Whether a model can hold a conversation: not speech, a vision
      --  projector, an embedding or reranking encoder, or a picture model,
      --  each of which has a command of its own. One whose header does not
      --  say is offered rather than guessed away.
      function Converses (Full_Path : String) return Boolean is
         Said : constant String := Architecture_Of (Full_Path);
      begin
         return Said not in "whisper" | "clip" | "bert" | "nomic-bert" | "nomic-bert-moe"
                           | "jina-bert-v2" | "qwen_image" | "(none)" | "(part)";
      end Converses;

      --  Whether the settings file hides a model from the lists: its
      --  models-hide names patterns, a space between them, * standing for
      --  any run of characters, matched to the file's name in any case.
      function Hidden (Simple : String) return Boolean is
         use Ada.Characters.Handling;
         Patterns : constant String := To_Lower (Model_Runner.Config.Value ("models-hide"));
         Name     : constant String := To_Lower (Simple);

         --  Whether Name from At_Name matches Pattern from At_Pattern.
         function Matches (Pattern : String; At_Pattern, At_Name : Positive) return Boolean is
         begin
            if At_Pattern > Pattern'Last then
               return At_Name > Name'Last;
            elsif Pattern (At_Pattern) = '*' then
               for Rest in At_Name .. Name'Last + 1 loop
                  if Matches (Pattern, At_Pattern + 1, Rest) then
                     return True;
                  end if;
               end loop;
               return False;
            else
               return At_Name <= Name'Last
                 and then Name (At_Name) = Pattern (At_Pattern)
                 and then Matches (Pattern, At_Pattern + 1, At_Name + 1);
            end if;
         end Matches;

         From : Positive := Patterns'First;
      begin
         while From <= Patterns'Last loop
            declare
               Stop : Natural := From;
            begin
               while Stop <= Patterns'Last and then Patterns (Stop) not in ' ' | ',' | ASCII.HT loop
                  Stop := Stop + 1;
               end loop;
               if Stop > From and then Name'Length > 0
                 and then Matches (Patterns (From .. Stop - 1), From, Name'First)
               then
                  return True;
               end if;
               From := Stop + 1;
            end;
         end loop;
         return False;
      end Hidden;

      procedure Add (Full_Path : String; Label : String) is
         Simple : constant String := Ada.Directories.Simple_Name (Full_Path);
      begin
         --  Not one the settings file hides.
         if Hidden (Simple) then
            return;
         end if;
         --  Not a shard past the first: the set is one model, shown once.
         if Shards.Is_Shard_Name (Label)
           and then Label (Label'Last - 18 .. Label'Last - 14) /= "00001"
         then
            return;
         end if;
         --  Nor a vision projector, which is half of a model and runs as
         --  none: --mmproj names it beside the model it serves.
         if Simple'Length >= 6
           and then Ada.Characters.Handling.To_Lower (Simple (Simple'First .. Simple'First + 5)) = "mmproj"
         then
            return;
         end if;
         --  For a conversation, only a model that holds one.
         if Conversing and then not Converses (Full_Path) then
            return;
         end if;
         if Count < Max then
            Count := Count + 1;
            Shown (Count) := Model_Runner.Text.To_Bounded (Label);
            Full  (Count) := Model_Runner.Text.To_Bounded (Full_Path);
            begin
               Sizes (Count) := Long_Long_Integer (Ada.Directories.Size
                                                      (Full_Path));
            exception
               when others =>
                  Sizes (Count) := 0;
            end;
         end if;
      end Add;

      procedure Scan (Base : String; Prefix : String; Depth : Natural) is
         Search : Search_Type;
         Found  : Directory_Entry_Type;
      begin
         Start_Search
           (Search, Base, "",
            Filter => [Ordinary_File => True, others => False]);
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Found);
            declare
               Name : constant String := Simple_Name (Found);
            begin
               if Name'Length >= 5
                 and then Name (Name'Last - 4 .. Name'Last) = ".gguf"
               then
                  Add (Full_Name (Found), Prefix & Name);
               end if;
            end;
         end loop;
         End_Search (Search);
         if Depth > 0 then
            Start_Search
              (Search, Base, "",
               Filter => [Directory => True, others => False]);
            while More_Entries (Search) loop
               Get_Next_Entry (Search, Found);
               declare
                  Name : constant String := Simple_Name (Found);
               begin
                  if Name /= "." and then Name /= ".." then
                     Scan (Full_Name (Found), Prefix & Name & "/", Depth - 1);
                  end if;
               end;
            end loop;
            End_Search (Search);
         end if;
      exception
         when others =>
            null;
      end Scan;

      --  A model this engine runs well, offered for download: its label
      --  carries the size, and the reference stands in for a model file so
      --  that choosing it hands the run a name not on disk, whose download
      --  offer fetches it into the models directory.
      procedure Add_Suggestion
        (Name, Size, Reference : String; Bytes : Long_Long_Integer) is
      begin
         --  Only what is on the machine, where that is asked.
         if not Offer_Downloads then
            return;
         end if;
         if Count < Max then
            Count := Count + 1;
            Shown (Count) :=
              Model_Runner.Text.To_Bounded
                ("download " & Name & " (" & Size & ")");
            Full (Count) := Model_Runner.Text.To_Bounded (Reference);
            Sizes (Count) := Bytes;
         end if;
      end Add_Suggestion;
   begin
      Path   := Model_Runner.Text.Empty;
      Picked := False;

      --  A terminal to ask at, and a models directory to work in -- even
      --  one not made yet, since a suggestion downloads into it. Dir empty
      --  is no home and nowhere to keep a model, so nothing is offered.
      if Dir = "" or else not Model_Runner.Platform.Is_Terminal (0) then
         return;
      end if;

      --  Three levels of subdirectories: a downloaded shard set is laid out
      --  under a folder of its own, and a file another repository's name
      --  took is kept under owner/repo/.
      Scan (Dir, "", 3);
      --  And the other folder's, by where they are.
      if Model_Runner.Platform.Other_Models_Directory /= "" then
         Scan (Model_Runner.Platform.Other_Models_Directory, Other_Label, 3);
      end if;

      --  Suggestions the settings file adds, before the built-in starters
      --  so a machine's own list leads. Each is `suggest.NAME = reference`,
      --  with an optional byte count after the reference that the shown
      --  size and the too-big mark are read from; without it the size shows
      --  as unknown and the model is never marked too big, since nothing
      --  here knows how large it is until it is fetched.
      for I in 1 .. Model_Runner.Config.Count loop
         declare
            Key : constant String := Model_Runner.Config.Key_At (I);
            Tag : constant String := "suggest.";
         begin
            if Key'Length > Tag'Length
              and then Key (Key'First .. Key'First + Tag'Length - 1) = Tag
            then
               declare
                  Label : constant String :=
                    Key (Key'First + Tag'Length .. Key'Last);
                  Spec  : constant String := Model_Runner.Config.Value_At (I);
                  Cut   : Natural := 0;
                  Bytes : Long_Long_Integer := 0;
               begin
                  for J in Spec'Range loop
                     if Spec (J) = ' ' or else Spec (J) = ASCII.HT then
                        Cut := J;
                        exit;
                     end if;
                  end loop;

                  declare
                     Reference : constant String :=
                       (if Cut = 0 then Spec else Spec (Spec'First .. Cut - 1));
                     Tail : constant String :=
                       (if Cut = 0 then "" else Spec (Cut + 1 .. Spec'Last));
                  begin
                     --  'Value ignores the blanks around the count and reads
                     --  an underscore-grouped literal; a tail that is not a
                     --  number leaves the size unknown rather than refusing
                     --  the suggestion.
                     if Tail /= "" then
                        begin
                           Bytes := Long_Long_Integer'Value (Tail);
                        exception
                           when others =>
                              Bytes := 0;
                        end;
                     end if;

                     if Label /= "" and then Reference /= "" then
                        Add_Suggestion
                          (Label,
                           (if Bytes > 0 then Giga (Bytes) else "size unknown"),
                           Reference, Bytes);
                     end if;
                  end;
               end;
            end if;
         end;
      end loop;

      --  And a few models this engine runs well, smallest first, so a
      --  first run with nothing on hand still has somewhere to start.
      Add_Suggestion ("SmolLM2-360M-Instruct", "0.3 GB",
                      "bartowski/SmolLM2-360M-Instruct-GGUF:Q4_K_M", 270_000_000);
      Add_Suggestion ("Qwen2.5-0.5B-Instruct", "0.5 GB",
                      "bartowski/Qwen2.5-0.5B-Instruct-GGUF:Q4_K_M", 500_000_000);
      --  A small agentic tool-use model that reasons in a think block. It
      --  is a MiniCPM exported as llama with its scaling folded in, so it
      --  runs on the llama path; two Q4_K_M files carry the quant, so the
      --  reference names the Nemotron-DPO one exactly.
      Add_Suggestion
        ("MiniCPM5-1B-Tooluse", "0.7 GB",
         "ewin-reg/MiniCPM5-1B-Agentic-Tooluse-GGUF:Nemotron-DPO.Q4_K_M",
         688_066_560);
      Add_Suggestion ("Llama-3.2-1B-Instruct", "0.8 GB",
                      "bartowski/Llama-3.2-1B-Instruct-GGUF:Q4_K_M", 807_694_464);
      Add_Suggestion ("Qwen2.5-1.5B-Instruct", "1.1 GB",
                      "bartowski/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M", 1_100_000_000);
      Add_Suggestion ("gemma-2-2b-it", "1.7 GB",
                      "bartowski/gemma-2-2b-it-GGUF:Q4_K_M", 1_708_582_752);
      Add_Suggestion ("Qwen2.5-3B-Instruct", "2.0 GB",
                      "bartowski/Qwen2.5-3B-Instruct-GGUF:Q4_K_M", 1_930_000_000);
      Add_Suggestion ("Phi-3.5-mini-instruct", "2.4 GB",
                      "bartowski/Phi-3.5-mini-instruct-GGUF:Q4_K_M",
                      2_393_232_672);
      --  An Ada and SPARK coder, a Qwen2.5-Coder-14B fine-tune, which this
      --  crate's own language makes the one specialist worth the size here.
      --  Two Q4_K_M revisions carry the quant, so the reference names r6 --
      --  the newer -- exactly, since the bare quant would match both.
      Add_Suggestion ("Steelman-14B-Ada", "9.0 GB",
                      "the-clanker-lover/steelman-14b-ada-GGUF:r6-Q4_K_M",
                      9_020_550_464);

      if Count = 0 then
         return;
      end if;

      --  At a terminal the shared selector: arrows move, a typed filter
      --  narrows, Tab says where a model is, Esc gives up. The files of
      --  one model in several quantizations are one entry; chosen, its
      --  files are offered in a list of their own, Esc there back to the
      --  models.
      if Model_Runner.CLI.Choosers.Is_Available (Screen) then
         declare
            use Ada.Characters.Handling;

            --  The model a file is, its quantization taken off: the name
            --  without .gguf, cut before its first part that names a
            --  format -- Q4_K_M, IQ3_XXS, q8_0, f16, bf16, MXFP4 -- in any
            --  case, the parts that only mark a variant (UD, MTP) left out
            --  of what groups. A download offered is a group of its own.
            function Base_Of (Label : String) return String is
               Name  : constant String :=
                 (if Label'Length > 5 and then To_Lower (Label (Label'Last - 4 .. Label'Last)) = ".gguf"
                  then Label (Label'First .. Label'Last - 5) else Label);
               Start : Positive := Name'First;
               Kept  : Ada.Strings.Unbounded.Unbounded_String;

               function Is_Format (Part : String) return Boolean is
                  Low : constant String := To_Lower (Part);
               begin
                  return Low'Length >= 2
                    and then ((Low (Low'First) = 'q' and then Is_Digit (Low (Low'First + 1)))
                              or else (Low'Length >= 3 and then Low (Low'First .. Low'First + 1) = "iq"
                                       and then Is_Digit (Low (Low'First + 2)))
                              or else (Low'Length >= 3 and then Low (Low'First .. Low'First + 1) = "tq"
                                       and then Is_Digit (Low (Low'First + 2)))
                              or else Low in "f16" | "f32" | "bf16" | "fp16" | "fp32" | "mxfp4" | "nvfp4");
               end Is_Format;
            begin
               if Ada.Strings.Fixed.Index (Label, "download ") = Label'First then
                  return Label;
               end if;
               for At_Char in Name'First .. Name'Last + 1 loop
                  if At_Char > Name'Last or else Name (At_Char) = '-' then
                     declare
                        Part : constant String := Name (Start .. At_Char - 1);
                     begin
                        exit when Start > Name'First and then Is_Format (Part);
                        if To_Lower (Part) not in "ud" | "mtp" then
                           if Ada.Strings.Unbounded.Length (Kept) > 0 then
                              Ada.Strings.Unbounded.Append (Kept, "-");
                           end if;
                           Ada.Strings.Unbounded.Append (Kept, Part);
                        end if;
                     end;
                     Start := At_Char + 1;
                  end if;
               end loop;
               return Ada.Strings.Unbounded.To_String (Kept);
            end Base_Of;

            Group_Of : array (1 .. Count) of Natural := [others => 0];
            First_Of : array (1 .. Count) of Natural := [others => 0];
            Members  : array (1 .. Count) of Natural := [others => 0];
            Groups   : Natural := 0;

            --  A file as a list shows it: its name and its size.
            function Labelled (I : Positive) return String is
               Label : constant String := Model_Runner.Text.To_String (Shown (I));
               Offer : constant Boolean := Ada.Strings.Fixed.Index (Label, "download ") = Label'First;
            begin
               return (if Sizes (I) > 0 and then not Offer then Label & " (" & Giga (Sizes (I)) & ")" else Label);
            end Labelled;

            function Too_Big_Tag (I : Positive) return Ada.Strings.Unbounded.Unbounded_String
            is (Ada.Strings.Unbounded.To_Unbounded_String
                  (if Too_Big (Sizes (I)) then Pres.Message_Value (Screen, "cli.choose.too_big") else ""));
         begin
            --  The groups, in the order their first file came.
            for I in 1 .. Count loop
               declare
                  Key : constant String := To_Lower (Base_Of (Model_Runner.Text.To_String (Shown (I))));
               begin
                  for G in 1 .. Groups loop
                     if To_Lower (Base_Of (Model_Runner.Text.To_String (Shown (First_Of (G))))) = Key then
                        Group_Of (I) := G;
                        exit;
                     end if;
                  end loop;
                  if Group_Of (I) = 0 then
                     Groups := Groups + 1;
                     First_Of (Groups) := I;
                     Group_Of (I) := Groups;
                  end if;
                  Members (Group_Of (I)) := Members (Group_Of (I)) + 1;
               end;
            end loop;

            --  The groups by name, in any case, as a person looks one up.
            declare
               Order : array (1 .. Groups) of Positive;
               function Name_Of (G : Positive) return String
               is (To_Lower (Base_Of (Model_Runner.Text.To_String (Shown (First_Of (G))))));
            begin
               for G in 1 .. Groups loop
                  Order (G) := G;
               end loop;
               for Next in 2 .. Groups loop
                  declare
                     Held : constant Positive := Order (Next);
                     At_Slot : Natural := Next - 1;
                  begin
                     while At_Slot >= 1 and then Name_Of (Order (At_Slot)) > Name_Of (Held) loop
                        Order (At_Slot + 1) := Order (At_Slot);
                        At_Slot := At_Slot - 1;
                     end loop;
                     Order (At_Slot + 1) := Held;
                  end;
               end loop;
               loop
                  declare
                     Items : Model_Runner.CLI.Choosers.Choice_List;
                     Taken : Natural;
                  begin
                     for Slot in 1 .. Groups loop
                        declare
                           G : constant Positive := Order (Slot);
                        begin
                           if Members (G) = 1 then
                              Model_Runner.CLI.Choosers.Append
                                (Items,
                                 (Label      => Ada.Strings.Unbounded.To_Unbounded_String (Labelled (First_Of (G))),
                                  Tag        => Too_Big_Tag (First_Of (G)),
                                  Details    => Ada.Strings.Unbounded.To_Unbounded_String
                                                  (Model_Runner.Text.To_String (Full (First_Of (G)))),
                                  Selectable => True));
                           else
                              --  The model, how many files it has, and each named
                              --  where Tab shows more.
                              declare
                                 Files : Ada.Strings.Unbounded.Unbounded_String;
                              begin
                                 for I in 1 .. Count loop
                                    if Group_Of (I) = G then
                                       Ada.Strings.Unbounded.Append (Files, Labelled (I) & ASCII.LF);
                                    end if;
                                 end loop;
                                 Model_Runner.CLI.Choosers.Append
                                   (Items,
                                    (Label      => Ada.Strings.Unbounded.To_Unbounded_String
                                                     (Base_Of (Model_Runner.Text.To_String (Shown (First_Of (G))))
                                                      & " (" & T.Image (Long_Long_Integer (Members (G))) & " "
                                                      & Pres.Message_Value (Screen, "cli.choose.files") & ")"),
                                     Tag        => Ada.Strings.Unbounded.Null_Unbounded_String,
                                     Details    => Files,
                                     Selectable => True));
                              end;
                           end if;
                        end;
                     end loop;
                     Taken := Model_Runner.CLI.Choosers.Choose (Screen, Title, Items);
                     exit when Taken not in 1 .. Groups;
                     --  The slot chosen, as the group it shows.
                     Taken := Order (Taken);
                     if Members (Taken) = 1 then
                        Path   := Full (First_Of (Taken));
                        Picked := True;
                        exit;
                     end if;

                     --  A group: which of its files.
                     declare
                        Files : Model_Runner.CLI.Choosers.Choice_List;
                        Index : array (1 .. Count) of Natural := [others => 0];
                        Used  : Natural := 0;
                        Which : Natural;
                     begin
                        for I in 1 .. Count loop
                           if Group_Of (I) = Taken then
                              Used := Used + 1;
                              Index (Used) := I;
                              Model_Runner.CLI.Choosers.Append
                                (Files,
                                 (Label      => Ada.Strings.Unbounded.To_Unbounded_String (Labelled (I)),
                                  Tag        => Too_Big_Tag (I),
                                  Details    => Ada.Strings.Unbounded.To_Unbounded_String
                                                  (Model_Runner.Text.To_String (Full (I))),
                                  Selectable => True));
                           end if;
                        end loop;
                        Which := Model_Runner.CLI.Choosers.Choose
                          (Screen, "cli.choose.variant", Files,
                           Heading => Base_Of (Model_Runner.Text.To_String (Shown (First_Of (Taken))))
                                      & ": " & Pres.Message_Value (Screen, "cli.choose.variant"));
                        if Which in 1 .. Used then
                           Path   := Full (Index (Which));
                           Picked := True;
                           exit;
                        end if;
                        --  Esc: back to the models.
                     end;
                  end;
               end loop;
            end;
            return;
         end;
      end if;

      Pres.Put_Note (Screen, Title);
      for I in 1 .. Count loop
         declare
            Label : constant String := Model_Runner.Text.To_String (Shown (I));
            --  A model on disk with its size, as an offered one has it.
            Name : constant String :=
              (if Sizes (I) > 0 and then Ada.Strings.Fixed.Index (Label, "download ") /= Label'First
               then Label & " (" & Giga (Sizes (I)) & ")" else Label);
            Note : constant String :=
              (if Too_Big (Sizes (I))
               then " -- " & Pres.Message_Value (Screen, "cli.choose.too_big")
               else "");
         begin
            --  Its size beside it, and one too big for here in the colour
            --  of something that will not do.
            Pres.Put_Aside_Marked
              (Screen, "cli.choose.item",
               [Loc.Named ("index", T.Image (Long_Long_Integer (I))),
                Loc.Named ("name", Name & Note)],
               (if Note = "" then "" else Pres.Message_Value (Screen, "cli.choose.too_big")),
               Pres.Bad);
         end;
      end loop;
      Pres.Put_Note
        (Screen, "cli.choose.prompt",
         [Loc.Named ("count", T.Image (Long_Long_Integer (Count)))]);

      declare
         Line : String (1 .. 64);
         Last : Natural := 0;
         N    : Integer := 0;
      begin
         begin
            Ada.Text_IO.Get_Line (Line, Last);
         exception
            when Ada.Text_IO.End_Error =>
               Last := 0;
         end;
         if Last >= 1 then
            begin
               N := Integer'Value (Line (1 .. Last));
            exception
               when others =>
                  N := 0;
            end;
         end if;
         if N in 1 .. Count then
            Path   := Full (N);
            Picked := True;
         end if;
      end;
   end Choose_Model;

   procedure Choose_Next_Model
     (Screen : in out Pres.Console;
      Path   : out Model_Runner.Text.Bounded;
      Picked : out Boolean) is
   begin
      Choose_Model (Screen, Path, Picked, Title => "cli.choose.header_next", Offer_Downloads => False);
   end Choose_Next_Model;

   --  How many files a shard-named model is, from its -of-000NN suffix;
   --  one for a name that is not a shard's.
   function Shard_Count (Name : String) return Natural is
   begin
      if not Shards.Is_Shard_Name (Name) then
         return 1;
      end if;
      return Natural'Value (Name (Name'Last - 9 .. Name'Last - 5));
   exception
      when others =>
         return 1;
   end Shard_Count;

   --  A byte count as gigabytes to two decimals, in integers.
   function Giga_Bytes (Bytes : Long_Long_Integer) return String is
      Cents : constant Long_Long_Integer := Bytes / 10_000_000;
   begin
      return T.Image (Cents / 100) & "."
        & Character'Val (Character'Pos ('0') + Natural ((Cents / 10) mod 10))
        & Character'Val (Character'Pos ('0') + Natural (Cents mod 10))
        & " GB";
   end Giga_Bytes;

   --------------
   -- Do_Models --
   --------------

   --  The models command: list the models on hand with their sizes, or,
   --  with remove, delete a named one and all its shards.
   procedure Do_Models
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural)
   is
      use Ada.Directories;
      Dir : constant String := Model_Runner.Platform.Models_Directory;

      --  A kept file's name within the models directory.
      function Relative_Of (Path : String) return String is
        (if Path'Length > Dir'Length + 1
           and then Path (Path'First .. Path'First + Dir'Length - 1) = Dir
         then Path (Path'First + Dir'Length + 1 .. Path'Last)
         else Simple_Name (Path));

      --  The files a download of Path leaves beside it.
      procedure Remove_Leftovers (Path : String) is
         Folder : constant String := Containing_Directory (Path);
         Search : Search_Type;
         Found  : Directory_Entry_Type;
         package Names is new Ada.Containers.Indefinite_Vectors (Positive, String);
         Gone   : Names.Vector;
      begin
         for Suffix of Leftover_Suffixes loop
            if Exists (Path & Suffix.all) then
               Gone.Append (Path & Suffix.all);
            end if;
         end loop;
         Start_Search
           (Search, Folder, Simple_Name (Path) & ".part.range-*",
            [Ordinary_File => True, others => False]);
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Found);
            Gone.Append (Full_Name (Found));
         end loop;
         End_Search (Search);
         for Name of Gone loop
            Delete_File (Name);
         end loop;
      end Remove_Leftovers;

      --  Every file of a model whose first is First (a single file, or a
      --  shard set derived from the first shard's name), and their total
      --  size. Missing pieces are skipped, so a broken set still lists.
      procedure For_Model
        (First_Path : String; Name : String;
         Bytes : out Long_Long_Integer; Delete : Boolean;
         Failed : out Model_Runner.Errors.Error_Info)
      is
         Count : constant Natural := Shard_Count (Name);
         Base  : constant String :=
           Containing_Directory (First_Path);
      begin
         Bytes := 0;
         Failed := Model_Runner.Errors.Success;
         for Index in 1 .. Count loop
            declare
               File_Name : constant String :=
                 (if Count = 1 then Simple_Name (First_Path)
                  else Shards.Shard_Path (Simple_Name (First_Path), Index, Count));
               Path : constant String :=
                 (if Count = 1 then First_Path
                  else (if Base = "" then File_Name
                        else Base & "/" & File_Name));
            begin
               if Exists (Path) then
                  Bytes := Bytes + Long_Long_Integer (Size (Path));
                  if Delete then
                     Delete_File (Path);
                     --  And the digest the download kept beside it.
                     if Exists (Path & ".sha256") then
                        Delete_File (Path & ".sha256");
                     end if;
                  end if;
               end if;
               --  And what a stopped download of it left -- its part, the
               --  part's chunks and notes, its lock -- many gigabytes that
               --  nothing listed and nothing else would ever remove; and
               --  the manifest's record of it.
               if Delete then
                  Remove_Leftovers (Path);
                  Model_Runner.Hub.Store.Forget (Dir, Relative_Of (Path));
               end if;
            exception
               --  A file that would not go -- no permission, a directory by
               --  the name -- is said, not counted as removed.
               when Failure : others =>
                  if Delete and then E.Is_Ok (Failed) then
                     Failed := E.Make (E.IO_Write_Failed);
                     E.Add_Text (Failed, "path", Path, E.Param_Path);
                     E.Add_Text (Failed, "detail", Ada.Exceptions.Exception_Name (Failure));
                  end if;
            end;
         end loop;
      end For_Model;

   begin
      Status := E.Exit_Success;

      if (Dir = "" or else not Exists (Dir)) and then Model_Runner.Platform.Other_Models_Directory = "" then
         Pres.Put_Note
           (Screen, "cli.models.empty",
            [Loc.Named ("detail", (if Dir = "" then "-" else Dir))]);
         return;
      end if;

      --  Remove a named model: the store's only, never one kept by hand.
      if Item.Models_Remove then
         declare
            Name  : constant String := T.To_String (Item.Model_Path);
            Path  : constant String := Model_Runner.Platform.Models_File (Name);
            Bytes : Long_Long_Integer := 0;
            Failed : E.Error_Info;

            --  A model of the store by its own name: one file name, a
            --  GGUF's, nothing that climbs out -- `models remove
            --  ../../.bashrc` deleted that file.
            --  A folder within the store is the store's -- a hub's quants
            --  are often in one, and models list shows them as folder/name
            --  -- so a name passes as the hub's own file names do: no
            --  climb, no root, no drive, no empty or dot segment.
            function Is_Store_Name return Boolean is
              (Name'Length > 5
               and then Ada.Characters.Handling.To_Lower
                          (Name (Name'Last - 4 .. Name'Last)) = ".gguf"
               and then Model_Runner.Hub.Is_Safe_File_Name (Name));
         begin
            if not Is_Store_Name or else Path = ""
              or else (not Exists (Path) and then not Exists (Path & ".part"))
              or else (Exists (Path) and then Kind (Path) /= Ordinary_File)
            then
               Pres.Put_Note
                 (Screen, "cli.models.not_found",
                  [Loc.Named ("name", Name), Loc.Named ("detail", Dir)]);
               Status := E.Exit_Usage;
               return;
            end if;
            For_Model (Path, Name, Bytes, Delete => True, Failed => Failed);
            if E.Is_Error (Failed) then
               Pres.Report (Screen, Failed);
               Status := E.Exit_Status (Failed);
               return;
            end if;
            Pres.Put_Note
              (Screen, "cli.models.removed",
               [Loc.Named ("name", Name),
                Loc.Named ("detail", Giga_Bytes (Bytes))]);
         end;
         return;
      end if;

      --  List the models on hand.
      declare
         Total   : Long_Long_Integer := 0;
         Shown   : Natural := 0;

         procedure Consider (Full_Path : String; Label : String) is
            Bytes : Long_Long_Integer;
         begin
            --  A shard set is one model, listed by its first shard.
            if Shards.Is_Shard_Name (Label)
              and then Label (Label'Last - 18 .. Label'Last - 14) /= "00001"
            then
               return;
            end if;
            declare
               Ignored : E.Error_Info;
            begin
               For_Model (Full_Path, Label, Bytes, Delete => False, Failed => Ignored);
            end;
            Total := Total + Bytes;
            Shown := Shown + 1;
            Pres.Put_Note
              (Screen, "cli.models.item",
               [Loc.Named ("name", Label),
                Loc.Named ("detail", Giga_Bytes (Bytes))]);
         end Consider;

         procedure Scan_Folders (Base : String; Prefix : String; Depth : Natural);

         procedure Scan (Base : String; Prefix : String; Depth : Natural) is
            Search : Search_Type;
            Found  : Directory_Entry_Type;
         begin
            Start_Search
              (Search, Base, "",
               Filter => [Ordinary_File => True, others => False]);
            while More_Entries (Search) loop
               Get_Next_Entry (Search, Found);
               declare
                  Name : constant String := Simple_Name (Found);
               begin
                  if Name'Length >= 5
                    and then Name (Name'Last - 4 .. Name'Last) = ".gguf"
                  then
                     Consider (Full_Name (Found), Prefix & Name);
                  elsif Name'Length > 10
                    and then Name (Name'Last - 9 .. Name'Last) = ".gguf.part"
                    and then not Exists (Full_Name (Found) (Full_Name (Found)'First .. Full_Name (Found)'Last - 5))
                    and then not (Prefix'Length >= Other_Label'Length
                                  and then Prefix (Prefix'First .. Prefix'First + Other_Label'Length - 1)
                                           = Other_Label)
                  then
                     --  A download stopped part way, which models remove
                     --  takes by the model's name -- the store's alone: one
                     --  in the other folder is neither resumed nor removed,
                     --  so not offered.
                     Pres.Put_Note
                       (Screen, "cli.models.item",
                        [Loc.Named ("name", Prefix & Name (Name'First .. Name'Last - 5) & " (partial download)"),
                         Loc.Named ("detail", Giga_Bytes (Long_Long_Integer (Size (Found))))]);
                  end if;
               end;
            end loop;
            End_Search (Search);
            Scan_Folders (Base, Prefix, Depth);
         exception
            when others =>
               null;
         end Scan;

         procedure Scan_Folders (Base : String; Prefix : String; Depth : Natural) is
            Search : Search_Type;
            Found  : Directory_Entry_Type;
         begin
            if Depth = 0 then
               return;
            end if;
            Start_Search
              (Search, Base, "",
               Filter => [Directory => True, others => False]);
            while More_Entries (Search) loop
               Get_Next_Entry (Search, Found);
               declare
                  Name : constant String := Simple_Name (Found);
               begin
                  if Name /= "." and then Name /= ".." then
                     Scan (Full_Name (Found), Prefix & Name & "/", Depth - 1);
                  end if;
               end;
            end loop;
            End_Search (Search);
         exception
            when others =>
               null;
         end Scan_Folders;
      begin
         --  A shard set in a folder of its own, and a file another
         --  repository's name took kept under owner/repo/: three levels.
         if Dir /= "" and then Exists (Dir) then
            Scan (Dir, "", 3);
         end if;
         --  And the other folder's, by where they are.
         if Model_Runner.Platform.Other_Models_Directory /= "" then
            Scan (Model_Runner.Platform.Other_Models_Directory, Other_Label, 3);
         end if;

         if Shown = 0 then
            Pres.Put_Note
              (Screen, "cli.models.empty", [Loc.Named ("detail", Dir)]);
         else
            Pres.Put_Note
              (Screen, "cli.models.total",
               [Loc.Named ("count", T.Image (Long_Long_Integer (Shown))),
                Loc.Named ("detail", Giga_Bytes (Total))]);
         end if;
      end;
   end Do_Models;

end Model_Runner.CLI.Execute.Models_Command;
