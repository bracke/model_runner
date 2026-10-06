with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces;
with Model_Runner.Platform;
with Model_Runner.Config;

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
   procedure Choose_Model
     (Screen : in out Pres.Console;
      Path   : out Model_Runner.Text.Bounded;
      Picked : out Boolean)
   is
      use Ada.Directories;

      Dir : constant String := Model_Runner.Platform.Models_Directory;
      Max : constant := 500;
      Shown : array (1 .. Max) of Model_Runner.Text.Bounded;
      Full  : array (1 .. Max) of Model_Runner.Text.Bounded;
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

      procedure Add (Full_Path : String; Label : String) is
      begin
         --  Not a shard past the first: the set is one model, shown once.
         if Shards.Is_Shard_Name (Label)
           and then Label (Label'Last - 18 .. Label'Last - 14) /= "00001"
         then
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

      procedure Scan (Base : String; Prefix : String) is
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

      Scan (Dir, "");

      --  One level of subdirectories, where a downloaded shard set is laid
      --  out under a folder of its own.
      declare
         Search : Search_Type;
         Found  : Directory_Entry_Type;
      begin
         Start_Search
           (Search, Dir, "",
            Filter => [Directory => True, others => False]);
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Found);
            declare
               Name : constant String := Simple_Name (Found);
            begin
               if Name /= "." and then Name /= ".." then
                  Scan (Full_Name (Found), Name & "/");
               end if;
            end;
         end loop;
         End_Search (Search);
      exception
         when others =>
            null;
      end;

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

      Pres.Put_Note (Screen, "cli.choose.header");
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

      --  Every file of a model whose first is First (a single file, or a
      --  shard set derived from the first shard's name), and their total
      --  size. Missing pieces are skipped, so a broken set still lists.
      procedure For_Model
        (First_Path : String; Name : String;
         Bytes : out Long_Long_Integer; Delete : Boolean)
      is
         Count : constant Natural := Shard_Count (Name);
         Base  : constant String :=
           Containing_Directory (First_Path);
      begin
         Bytes := 0;
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
                  end if;
               end if;
            exception
               when others =>
                  null;
            end;
         end loop;
      end For_Model;

   begin
      Status := E.Exit_Success;

      if Dir = "" or else not Exists (Dir) then
         Pres.Put_Note
           (Screen, "cli.models.empty",
            [Loc.Named ("detail", (if Dir = "" then "-" else Dir))]);
         return;
      end if;

      --  Remove a named model.
      if Item.Models_Remove then
         declare
            Name  : constant String := T.To_String (Item.Model_Path);
            Path  : constant String := Model_Runner.Platform.Models_File (Name);
            Bytes : Long_Long_Integer := 0;
         begin
            if Path = "" or else not Exists (Path) then
               Pres.Put_Note
                 (Screen, "cli.models.not_found",
                  [Loc.Named ("name", Name), Loc.Named ("detail", Dir)]);
               Status := E.Exit_Usage;
               return;
            end if;
            For_Model (Path, Name, Bytes, Delete => True);
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
            For_Model (Full_Path, Label, Bytes, Delete => False);
            Total := Total + Bytes;
            Shown := Shown + 1;
            Pres.Put_Note
              (Screen, "cli.models.item",
               [Loc.Named ("name", Label),
                Loc.Named ("detail", Giga_Bytes (Bytes))]);
         end Consider;

         procedure Scan (Base : String; Prefix : String) is
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
                  end if;
               end;
            end loop;
            End_Search (Search);
         exception
            when others =>
               null;
         end Scan;
      begin
         Scan (Dir, "");
         declare
            Search : Search_Type;
            Found  : Directory_Entry_Type;
         begin
            Start_Search
              (Search, Dir, "",
               Filter => [Directory => True, others => False]);
            while More_Entries (Search) loop
               Get_Next_Entry (Search, Found);
               declare
                  Name : constant String := Simple_Name (Found);
               begin
                  if Name /= "." and then Name /= ".." then
                     Scan (Full_Name (Found), Name & "/");
                  end if;
               end;
            end loop;
            End_Search (Search);
         exception
            when others =>
               null;
         end;

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
