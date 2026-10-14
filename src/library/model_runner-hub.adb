with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Vectors;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Task_Attributes;

with CryptoLib.Hashes;

with Http_Client.Auth.Bearer;
with Http_Client.Clients;
with Http_Client.Errors;
with Http_Client.Headers;
with Http_Client.Requests;
with Http_Client.Types;
with Http_Client.URI;

with Model_Runner.Config;
with Model_Runner.GGUF.Shards;
with Model_Runner.Platform;

package body Model_Runner.Hub is

   use type Interfaces.Unsigned_64;
   use type Http_Client.Errors.Result_Status;

   package T renames Model_Runner.Text;
   package HC renames Http_Client.Clients;
   package HE renames Http_Client.Errors;
   package GS renames Model_Runner.GGUF.Shards;

   Host : constant String := "https://huggingface.co";

   function Upper (Item : String) return String
     renames Ada.Characters.Handling.To_Upper;

   --  How many shards a shard-named file says its model is: the count in
   --  its -of-000NN suffix. Zero for a name that is not a shard's.
   function Shard_Total (Name : String) return Natural is
   begin
      if not GS.Is_Shard_Name (Name) then
         return 0;
      end if;
      return Natural'Value (Name (Name'Last - 9 .. Name'Last - 5));
   exception
      when others =>
         return 0;
   end Shard_Total;

   function Ends_With (Whole : String; Suffix : String) return Boolean is
   begin
      return Whole'Length >= Suffix'Length
        and then Upper (Whole (Whole'Last - Suffix'Length + 1 .. Whole'Last))
                 = Upper (Suffix);
   end Ends_With;

   function Contains (Haystack : String; Needle : String) return Boolean is
      Up_Hay    : constant String := Upper (Haystack);
      Up_Needle : constant String := Upper (Needle);
   begin
      if Up_Needle'Length = 0 then
         return True;
      end if;
      for First in Up_Hay'First .. Up_Hay'Last - Up_Needle'Length + 1 loop
         if Up_Hay (First .. First + Up_Needle'Length - 1) = Up_Needle then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   --  The number that follows "size": at or soon after From in Body_Text,
   --  which the hub's blobs listing puts a few fields past each rfilename.
   --  Zero when none is close, so a file whose size the API did not give is
   --  fetched without resume rather than not at all.
   function Size_After
     (Body_Text : String; From : Natural) return Interfaces.Unsigned_64
   is
      Marker : constant String := """size""";
      Window : constant Natural :=
        Natural'Min (Body_Text'Last, From + 300);
      Cursor : Natural := From;
   begin
      while Cursor <= Window - Marker'Length + 1 loop
         if Body_Text (Cursor .. Cursor + Marker'Length - 1) = Marker then
            declare
               Scan  : Natural := Cursor + Marker'Length;
               Value : Interfaces.Unsigned_64 := 0;
               Any   : Boolean := False;
            begin
               while Scan <= Body_Text'Last
                 and then Body_Text (Scan) not in '0' .. '9'
                 and then Body_Text (Scan) /= '}'
               loop
                  Scan := Scan + 1;
               end loop;
               while Scan <= Body_Text'Last
                 and then Body_Text (Scan) in '0' .. '9'
               loop
                  Value := Value * 10
                    + Interfaces.Unsigned_64
                        (Character'Pos (Body_Text (Scan)) - Character'Pos ('0'));
                  Any := True;
                  Scan := Scan + 1;
               end loop;
               if Any then
                  return Value;
               end if;
               return 0;
            end;
         end if;
         Cursor := Cursor + 1;
      end loop;
      return 0;
   end Size_After;

   --  The 64-character SHA-256 the hub's blobs listing puts in each file's
   --  lfs record, soon after its rfilename. Found is false where none is
   --  close, and then the file is checked by its size alone.
   procedure Hash_After
     (Body_Text : String;
      From      : Natural;
      Hash      : out String;
      Found     : out Boolean)
   is
      Marker : constant String := """sha256""";
      Window : constant Natural :=
        Natural'Min (Body_Text'Last, From + 400);
      Cursor : Natural := From;
   begin
      Hash  := [others => '0'];
      Found := False;
      while Cursor <= Window - Marker'Length + 1 loop
         if Body_Text (Cursor .. Cursor + Marker'Length - 1) = Marker then
            declare
               Scan : Natural := Cursor + Marker'Length;
            begin
               while Scan <= Body_Text'Last
                 and then Body_Text (Scan) /= '"'
               loop
                  Scan := Scan + 1;
               end loop;
               Scan := Scan + 1;
               declare
                  Start : constant Natural := Scan;
               begin
                  while Scan <= Body_Text'Last
                    and then Body_Text (Scan) /= '"'
                  loop
                     Scan := Scan + 1;
                  end loop;
                  if Scan <= Body_Text'Last
                    and then Scan - Start = Hash'Length
                  then
                     Hash  := Body_Text (Start .. Scan - 1);
                     Found := True;
                  end if;
               end;
               return;
            end;
         end if;
         Cursor := Cursor + 1;
      end loop;
   end Hash_After;

   -----------------------
   -- Is_Safe_File_Name --
   -----------------------

   function Is_Safe_File_Name (Name : String) return Boolean is
      Start : Positive := Name'First;
   begin
      if Name = "" then
         return False;
      end if;
      for C of Name loop
         if C in '\' | ':' or else Character'Pos (C) < 32 or else Character'Pos (C) = 127 then
            return False;
         end if;
      end loop;
      for I in Name'First .. Name'Last + 1 loop
         if I > Name'Last or else Name (I) = '/' then
            if Name (Start .. I - 1) in "" | "." | ".." then
               return False;
            end if;
            Start := I + 1;
         end if;
      end loop;
      return True;
   end Is_Safe_File_Name;

   ------------------
   -- Is_Reference --
   ------------------

   function Is_Reference (Named : String) return Boolean is
      Colon : Natural := 0;
   begin
      for Index in reverse Named'Range loop
         if Named (Index) = ':' then
            Colon := Index;
            exit;
         end if;
      end loop;

      if Colon = 0 or else Colon = Named'Last then
         return False;
      end if;

      for Index in Named'First .. Colon - 1 loop
         if Named (Index) = '/' then
            return True;
         end if;
      end loop;
      return False;
   end Is_Reference;

   -------------
   -- Is_Repo --
   -------------

   function Is_Repo (Named : String) return Boolean is
      Slash : Boolean := False;
   begin
      for C of Named loop
         if C = ':' then
            return False;
         elsif C = '/' then
            Slash := True;
         end if;
      end loop;
      return Slash and then not Ends_With (Named, ".gguf");
   end Is_Repo;

   -----------
   -- Split --
   -----------

   procedure Split (Reference : String; Repo : out T.Bounded;
                    Quant : out T.Bounded)
   is
      Colon : Natural := 0;
   begin
      for Index in reverse Reference'Range loop
         if Reference (Index) = ':' then
            Colon := Index;
            exit;
         end if;
      end loop;
      Repo  := T.To_Bounded (Reference (Reference'First .. Colon - 1));
      Quant := T.To_Bounded (Reference (Colon + 1 .. Reference'Last));
   end Split;

   ----------------
   -- Client_For --
   ----------------

   --  The client's configuration. The hub token is not in it: it goes on
   --  each request (Request_For), so a gated repository is reached.
   function Client_For return HC.Client_Configuration is (HC.Default_Client_Configuration);

   --  The hub token, where the environment or the settings have one.
   function Token return String is
      Env_Token : constant String := Model_Runner.Platform.Hub_Token;
   begin
      return (if Env_Token /= "" then Env_Token else Model_Runner.Config.Value ("hf-token"));
   end Token;

   --  A request for a URL, carrying the hub token where there is one: on
   --  the request, where the client keeps it to the origin it is for -- a
   --  default header would follow a redirect anywhere, and the client
   --  refuses one. A token that is no valid one is left off.
   function Request_For
     (URL     : String;
      Extra   : Http_Client.Headers.Header_List;
      Made    : out Http_Client.Requests.Request) return HE.Result_Status
   is
      Where  : Http_Client.URI.URI_Reference;
      Bare   : Http_Client.Requests.Request;
      Status : HE.Result_Status := Http_Client.URI.Parse (URL, Where);
   begin
      if not HE.Is_Success (Status) then
         return Status;
      end if;
      Status := Http_Client.Requests.Create (Http_Client.Types.GET, Where, Bare, Headers => Extra);
      if not HE.Is_Success (Status) then
         return Status;
      end if;
      if Token /= "" and then Http_Client.Auth.Bearer.Is_Valid_Token (Token) then
         return Http_Client.Auth.Bearer.Set_Bearer_Authorization (Bare, Token, Made);
      end if;
      Made := Bare;
      return Status;
   end Request_For;

   --  A GET of the hub, as HC.Get makes one, with its token.
   function Get (URL : String; Result : out HC.Client_Result) return HE.Result_Status is
      Item    : HC.Client;
      Request : Http_Client.Requests.Request;
      Status  : HE.Result_Status := HC.Initialize (Item, Client_For);
   begin
      if HE.Is_Success (Status) then
         Status := Request_For (URL, Http_Client.Headers.Empty, Request);
      end if;
      if HE.Is_Success (Status) then
         Status := HC.Execute (Item, Request, Result);
      end if;
      return Status;
   end Get;

   --  A download from the hub to a file, as HC.Download_To_File makes one,
   --  with its token and the headers given -- a range.
   function Download
     (URL     : String;
      Path    : String;
      Result  : out HC.Download_Result;
      Options : HC.Download_Options;
      Extra   : Http_Client.Headers.Header_List := Http_Client.Headers.Empty) return HE.Result_Status
   is
      Item    : HC.Client;
      Request : Http_Client.Requests.Request;
      Status  : HE.Result_Status := HC.Initialize (Item, Client_For);
   begin
      if HE.Is_Success (Status) then
         Status := Request_For (URL, Extra, Request);
      end if;
      if HE.Is_Success (Status) then
         Status := HC.Execute_To_File (Item, Request, Path, Result, Options);
      end if;
      return Status;
   end Download;

   -------------
   -- Resolve --
   -------------

   procedure Resolve
     (Reference : String;
      Repo      : out Model_Runner.Text.Bounded;
      Files     : out File_Set;
      Count     : out Natural;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded)
   is
      Quant  : T.Bounded;
      Result : HC.Client_Result;
      Status : HE.Result_Status;

      Matches : Natural := 0;

      procedure Note_Candidate
        (Name     : String;
         Size     : Interfaces.Unsigned_64;
         Hash     : String;
         Has_Hash : Boolean) is
      begin
         if Matches < Max_Files then
            Matches := Matches + 1;
            Files (Matches) :=
              (Name     => T.To_Bounded (Name),
               Size     => Size,
               SHA256   => Hash,
               Has_Hash => Has_Hash);
         end if;
      end Note_Candidate;

      function Listed return String is
         Room : String (1 .. 400) := [others => ' '];
         Used : Natural := 0;
      begin
         for I in 1 .. Matches loop
            declare
               Name : constant String := T.To_String (Files (I).Name);
            begin
               exit when Used + Name'Length + 2 > Room'Last;
               if Used > 0 then
                  Room (Used + 1 .. Used + 2) := ", ";
                  Used := Used + 2;
               end if;
               Room (Used + 1 .. Used + Name'Length) := Name;
               Used := Used + Name'Length;
            end;
         end loop;
         return Room (1 .. Used);
      end Listed;

      --  Shards in order: -00001- sorts before -00002-, so a name sort puts
      --  the first shard first, which is the one the loader opens.
      procedure Sort_By_Name is
      begin
         for I in 1 .. Matches loop
            for J in I + 1 .. Matches loop
               if T.To_String (Files (J).Name)
                 < T.To_String (Files (I).Name)
               then
                  declare
                     Swap : constant Download_File := Files (I);
                  begin
                     Files (I) := Files (J);
                     Files (J) := Swap;
                  end;
               end if;
            end loop;
         end loop;
      end Sort_By_Name;

   begin
      Ok := False;
      Count := 0;
      Reason := T.Empty;

      Split (Reference, Repo, Quant);

      Status := Get
        (URL           => Host & "/api/models/" & T.To_String (Repo)
                          & "?blobs=true",
         Result        => Result);

      if not HE.Is_Success (Status) then
         Reason := T.To_Bounded
           ("could not reach huggingface.co (" & HE.Result_Status'Image (Status)
            & ")");
         return;
      end if;

      declare
         Body_Text : constant String := HC.Response_Text (Result);
         Marker    : constant String := """rfilename""";
         Cursor    : Natural := Body_Text'First;
      begin
         while Cursor <= Body_Text'Last - Marker'Length + 1 loop
            if Body_Text (Cursor .. Cursor + Marker'Length - 1) = Marker then
               declare
                  Scan : Natural := Cursor + Marker'Length;
               begin
                  while Scan <= Body_Text'Last
                    and then Body_Text (Scan) /= '"'
                  loop
                     Scan := Scan + 1;
                  end loop;
                  Scan := Scan + 1;
                  declare
                     Start : constant Natural := Scan;
                  begin
                     while Scan <= Body_Text'Last
                       and then Body_Text (Scan) /= '"'
                     loop
                        Scan := Scan + 1;
                     end loop;
                     if Scan <= Body_Text'Last then
                        declare
                           Name : constant String :=
                             Body_Text (Start .. Scan - 1);
                        begin
                           if Ends_With (Name, ".gguf")
                             and then Is_Safe_File_Name (Name)
                             and then Contains (Name, T.To_String (Quant))
                           then
                              declare
                                 Digest : String (1 .. 64);
                                 Have   : Boolean;
                              begin
                                 Hash_After (Body_Text, Scan, Digest, Have);
                                 Note_Candidate
                                   (Name, Size_After (Body_Text, Scan),
                                    Digest, Have);
                              end;
                           end if;
                        end;
                     end if;
                     Cursor := Scan + 1;
                  end;
               end;
            else
               Cursor := Cursor + 1;
            end if;
         end loop;
      end;

      if Matches = 0 then
         Reason := T.To_Bounded
           ("no .gguf file for that quant in " & T.To_String (Repo)
            & " -- the repository or the quant may be wrong");
         return;
      end if;

      declare
         All_Shards : Boolean := True;
      begin
         for I in 1 .. Matches loop
            if not GS.Is_Shard_Name (T.To_String (Files (I).Name)) then
               All_Shards := False;
            end if;
         end loop;

         if Matches = 1 and then not All_Shards then
            Count := 1;
            Ok    := True;

         elsif All_Shards then
            --  A shard set: every shard carries the quant, so all matched.
            --  One set only -- every shard the same count and, made the
            --  first, the same name -- and the whole set present.
            declare
               Total : constant Natural :=
                 Shard_Total (T.To_String (Files (1).Name));
               First : constant String :=
                 (if Total >= 1
                  then GS.Shard_Path (T.To_String (Files (1).Name), 1, Total)
                  else "");
               Same  : Boolean := Total >= 1 and then First /= "";
            begin
               for I in 1 .. Matches loop
                  if Shard_Total (T.To_String (Files (I).Name)) /= Total
                    or else GS.Shard_Path
                              (T.To_String (Files (I).Name), 1, Total) /= First
                  then
                     Same := False;
                  end if;
               end loop;

               if Same and then Matches = Total then
                  Sort_By_Name;
                  Count := Matches;
                  Ok    := True;
               else
                  Reason := T.To_Bounded
                    ("the shard set is incomplete or ambiguous; name the "
                     & "quant more exactly: " & Listed);
               end if;
            end;

         else
            Reason := T.To_Bounded
              ("more than one file matched; name the quant more exactly: "
               & Listed);
         end if;
      end;
   end Resolve;

   ----------
   -- Pick --
   ----------

   procedure Pick
     (Reference : String;
      Budget    : Interfaces.Unsigned_64;
      Repo      : out Model_Runner.Text.Bounded;
      Files     : out File_Set;
      Count     : out Natural;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded)
   is
      Result : HC.Client_Result;
      Status : HE.Result_Status;

      Max_All : constant := 256;
      All_Files : array (1 .. Max_All) of Download_File;
      All_N     : Natural := 0;

      --  The index in All_Files of a file of this name, or zero.
      function Find (Name : String) return Natural is
      begin
         for I in 1 .. All_N loop
            if T.To_String (All_Files (I).Name) = Name then
               return I;
            end if;
         end loop;
         return 0;
      end Find;

      --  The whole size of the model a representative names -- a single
      --  file's size, or the sum of a shard set's, the pieces it can find.
      function Group_Total (Rep : String) return Interfaces.Unsigned_64 is
         Total : Interfaces.Unsigned_64 := 0;
         Shards_Count : constant Natural := Shard_Total (Rep);
      begin
         if Shards_Count <= 1 then
            declare
               At_Rep : constant Natural := Find (Rep);
            begin
               return (if At_Rep = 0 then 0 else All_Files (At_Rep).Size);
            end;
         end if;
         for K in 1 .. Shards_Count loop
            declare
               At_K : constant Natural := Find (GS.Shard_Path (Rep, K, Shards_Count));
            begin
               if At_K /= 0 then
                  Total := Total + All_Files (At_K).Size;
               end if;
            end;
         end loop;
         return Total;
      end Group_Total;

      --  Whether a file is the one that stands for its model -- a single
      --  file, or the first shard of a set.
      function Is_Representative (Name : String) return Boolean
      is (not GS.Is_Shard_Name (Name)
          or else Name (Name'Last - 18 .. Name'Last - 14) = "00001");

      Best_Fit   : Natural := 0;
      Best_Total : Interfaces.Unsigned_64 := 0;
      Smallest   : Natural := 0;
      Small_Total : Interfaces.Unsigned_64 := 0;
      Chosen     : Natural := 0;
      None_Fit   : Boolean := False;
   begin
      Ok := False;
      Count := 0;
      Reason := T.Empty;
      Repo := T.To_Bounded (Reference);

      if Budget = 0 then
         Reason := T.To_Bounded
           ("could not read this machine's memory to pick a quant; name one "
            & "as " & Reference & ":QUANT");
         return;
      end if;

      Status := Get
        (URL           => Host & "/api/models/" & Reference & "?blobs=true",
         Result        => Result);

      if not HE.Is_Success (Status) then
         Reason := T.To_Bounded
           ("could not reach huggingface.co (" & HE.Result_Status'Image (Status)
            & ")");
         return;
      end if;

      declare
         Body_Text : constant String := HC.Response_Text (Result);
         Marker    : constant String := """rfilename""";
         Cursor    : Natural := Body_Text'First;
      begin
         while Cursor <= Body_Text'Last - Marker'Length + 1 loop
            if Body_Text (Cursor .. Cursor + Marker'Length - 1) = Marker then
               declare
                  Scan : Natural := Cursor + Marker'Length;
               begin
                  while Scan <= Body_Text'Last and then Body_Text (Scan) /= '"'
                  loop
                     Scan := Scan + 1;
                  end loop;
                  Scan := Scan + 1;
                  declare
                     Start : constant Natural := Scan;
                  begin
                     while Scan <= Body_Text'Last
                       and then Body_Text (Scan) /= '"'
                     loop
                        Scan := Scan + 1;
                     end loop;
                     if Scan <= Body_Text'Last then
                        declare
                           Name : constant String :=
                             Body_Text (Start .. Scan - 1);
                           Digest : String (1 .. 64);
                           Have   : Boolean;
                        begin
                           if Ends_With (Name, ".gguf")
                             and then Is_Safe_File_Name (Name)
                             and then All_N < Max_All
                           then
                              Hash_After (Body_Text, Scan, Digest, Have);
                              All_N := All_N + 1;
                              All_Files (All_N) :=
                                (Name     => T.To_Bounded (Name),
                                 Size     => Size_After (Body_Text, Scan),
                                 SHA256   => Digest,
                                 Has_Hash => Have);
                           end if;
                        end;
                     end if;
                     Cursor := Scan + 1;
                  end;
               end;
            else
               Cursor := Cursor + 1;
            end if;
         end loop;
      end;

      if All_N = 0 then
         Reason := T.To_Bounded
           ("no .gguf file in " & Reference
            & " -- the repository may be wrong");
         return;
      end if;

      --  Weigh each model: the largest that fits the budget, and the
      --  smallest of all as a fallback where none does.
      for I in 1 .. All_N loop
         if Is_Representative (T.To_String (All_Files (I).Name)) then
            declare
               Total : constant Interfaces.Unsigned_64 :=
                 Group_Total (T.To_String (All_Files (I).Name));
            begin
               if Total > 0 then
                  if Total <= Budget
                    and then (Best_Fit = 0 or else Total > Best_Total)
                  then
                     Best_Fit := I;
                     Best_Total := Total;
                  end if;
                  if Smallest = 0 or else Total < Small_Total then
                     Smallest := I;
                     Small_Total := Total;
                  end if;
               end if;
            end;
         end if;
      end loop;

      if Best_Fit /= 0 then
         Chosen := Best_Fit;
      else
         Chosen := Smallest;
         None_Fit := True;
      end if;

      if Chosen = 0 then
         Reason := T.To_Bounded ("no quant to choose from in " & Reference);
         return;
      end if;

      --  The chosen model's files: itself, or its shards in order.
      declare
         Rep   : constant String := T.To_String (All_Files (Chosen).Name);
         Total : constant Natural := Shard_Total (Rep);
      begin
         if Total <= 1 then
            Files (1) := All_Files (Chosen);
            Count := 1;
         else
            Count := 0;
            for K in 1 .. Natural'Min (Total, Max_Files) loop
               declare
                  At_K : constant Natural :=
                    Find (GS.Shard_Path (Rep, K, Total));
               begin
                  if At_K /= 0 then
                     Count := Count + 1;
                     Files (Count) := All_Files (At_K);
                  end if;
               end;
            end loop;
         end if;
      end;

      if Count = 0 then
         Reason := T.To_Bounded ("the chosen quant's files could not be listed");
         return;
      end if;

      if None_Fit then
         Reason := T.To_Bounded
           ("none of the quants fit this machine; the smallest was taken and "
            & "may be slow or fail");
      end if;
      Ok := True;
   end Pick;

   -----------
   -- Fetch --
   -----------

   ---------------------
   -- Download line --
   ---------------------

   --  Where a download's progress is sent, kept at package level because
   --  the client's callback is a plain access-to-function with nowhere to
   --  carry state. One download runs at a time, from one task, as the
   --  package says. The hub formats nothing and reaches no terminal: it
   --  hands the numbers to whoever asked, and a caller with a terminal
   --  paints them.
   Active_Report : Progress_Reporter := null;

   --  The client's callback: pass the numbers on and carry on. A reporter
   --  that raised would not stop the download, so one that does is caught.
   function Show_Progress
     (Bytes_Written : Interfaces.Unsigned_64;
      Total_Bytes   : Interfaces.Unsigned_64)
      return Http_Client.Errors.Result_Status
   is
   begin
      if Active_Report /= null then
         Active_Report (Bytes_Written, Total_Bytes);
      end if;
      return Http_Client.Errors.Ok;
   exception
      when others =>
         return Http_Client.Errors.Ok;
   end Show_Progress;

   -----------
   -- Fetch --
   -----------

   -------------------
   -- Fetch_Ranges --
   -------------------

   --  A large file fetched as ranges at once: one connection to the hub's
   --  servers gave 3.7 MB/s of a link that carries more. Chunks of 64 MB
   --  past what the file already holds, four connections taking them in
   --  turn, each chunk a file of its own beside the model -- one whole is
   --  kept, so a stopped fetch resumes a chunk at a time -- then appended
   --  in order, each removed as it goes, and the whole checked against the
   --  digest the hub records. Ranges the server will not serve as asked --
   --  no 206, another length -- leave Served false, and the caller fetches
   --  in one stream instead.
   Chunk_Bytes   : constant := 64 * 1024 * 1024;
   Range_Workers : constant := 4;
   Ranges_From   : constant := 512 * 1024 * 1024;

   --  The chunk the calling worker task is fetching, for the client's
   --  progress callback, which carries no state of its own.
   package Worker_Chunk is new Ada.Task_Attributes (Natural, 0);

   type Chunk_Bytes_Array is array (Positive range <>) of Interfaces.Unsigned_64;

   --  Chunk files beside Path that a fetch starting at Have, in Chunks
   --  chunks, would not take -- left by a fetch that began elsewhere, or
   --  by one whose part was since removed -- are removed: nothing else
   --  ever would, and each can be 64 MB.
   procedure Remove_Stray_Chunks (Path : String; Have : Interfaces.Unsigned_64; Chunks : Natural) is
      Prefix : constant String := Ada.Directories.Simple_Name (Path) & ".range-";
      Folder : constant String := Ada.Directories.Containing_Directory (Path);
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
      package Names is new Ada.Containers.Indefinite_Vectors (Positive, String);
      Stray  : Names.Vector;

      function Taken (Name : String) return Boolean is
      begin
         for K in 1 .. Chunks loop
            if Name = Prefix & Model_Runner.Text.Trim
                 (Interfaces.Unsigned_64'Image (Have + Interfaces.Unsigned_64 (K - 1) * Chunk_Bytes))
            then
               return True;
            end if;
         end loop;
         return False;
      end Taken;
   begin
      if not Ada.Directories.Exists (Folder) then
         return;
      end if;
      Ada.Directories.Start_Search
        (Search, Folder, Prefix & "*", [Ada.Directories.Ordinary_File => True, others => False]);
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         if not Taken (Ada.Directories.Simple_Name (Item)) then
            Stray.Append (Ada.Directories.Full_Name (Item));
         end if;
      end loop;
      Ada.Directories.End_Search (Search);
      for Name of Stray loop
         Ada.Directories.Delete_File (Name);
      end loop;
   end Remove_Stray_Chunks;

   procedure Fetch_Ranges
     (Repo      : String;
      File      : Download_File;
      Dest_Path : String;
      Served    : out Boolean;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded;
      Report    : Progress_Reporter)
   is
      Have   : constant Interfaces.Unsigned_64 :=
        (if Ada.Directories.Exists (Dest_Path)
         then Interfaces.Unsigned_64 (Ada.Directories.Size (Dest_Path)) else 0);
      Left   : constant Interfaces.Unsigned_64 := File.Size - Have;
      Chunks : constant Natural := Natural ((Left + Chunk_Bytes - 1) / Chunk_Bytes);
      URL    : constant String := Host & "/" & Repo & "/resolve/main/" & T.To_String (File.Name);

      function Start_Of (K : Positive) return Interfaces.Unsigned_64 is
        (Have + Interfaces.Unsigned_64 (K - 1) * Chunk_Bytes);
      function Length_Of (K : Positive) return Interfaces.Unsigned_64 is
        (Interfaces.Unsigned_64'Min (Chunk_Bytes, File.Size - Start_Of (K)));
      function Chunk_Path (K : Positive) return String is
        (Dest_Path & ".range-" & Model_Runner.Text.Trim (Interfaces.Unsigned_64'Image (Start_Of (K))));

      --  Which chunk is next, how much of each is written, and whether any
      --  went wrong -- and how: a range not served, or another failure.
      protected Board is
         procedure Take (K : out Natural);
         procedure Wrote (K : Positive; Bytes : Interfaces.Unsigned_64);
         procedure Fail (Not_Served : Boolean; Why : String);
         procedure Finish;
         function Written return Interfaces.Unsigned_64;
         function Failed return Boolean;
         function Refused return Boolean;
         function Why return String;
         function Finished return Natural;
      private
         Next      : Positive := 1;
         Bytes     : Chunk_Bytes_Array (1 .. Natural'Max (Chunks, 1)) := [others => 0];
         Bad       : Boolean := False;
         Unserved  : Boolean := False;
         Said      : Model_Runner.Text.Bounded;
         Done      : Natural := 0;
      end Board;

      protected body Board is
         procedure Take (K : out Natural) is
         begin
            if Bad or else Next > Chunks then
               K := 0;
            else
               K := Next;
               Next := Next + 1;
            end if;
         end Take;

         procedure Wrote (K : Positive; Bytes : Interfaces.Unsigned_64) is
         begin
            Board.Bytes (K) := Bytes;
         end Wrote;

         procedure Fail (Not_Served : Boolean; Why : String) is
         begin
            if not Bad then
               Said := T.To_Bounded (Why);
            end if;
            Bad := True;
            Unserved := Unserved or else Not_Served;
         end Fail;

         procedure Finish is
         begin
            Done := Done + 1;
         end Finish;

         function Written return Interfaces.Unsigned_64 is
            Sum : Interfaces.Unsigned_64 := 0;
         begin
            for B of Bytes loop
               Sum := Sum + B;
            end loop;
            return Sum;
         end Written;

         function Failed return Boolean is (Bad);
         function Refused return Boolean is (Unserved);
         function Why return String is (T.To_String (Said));
         function Finished return Natural is (Done);
      end Board;

      function Chunk_Progress
        (Bytes_Written : Interfaces.Unsigned_64;
         Total_Bytes   : Interfaces.Unsigned_64) return HE.Result_Status
      is
         pragma Unreferenced (Total_Bytes);
      begin
         if Worker_Chunk.Value > 0 then
            Board.Wrote (Worker_Chunk.Value, Bytes_Written);
         end if;
         return (if Board.Failed then HE.Internal_Error else HE.Ok);
      end Chunk_Progress;

      task type Worker;

      task body Worker is
         K : Natural;
      begin
         loop
            Board.Take (K);
            exit when K = 0;
            declare
               Path    : constant String := Chunk_Path (K);
               Length  : constant Interfaces.Unsigned_64 := Length_Of (K);
               Ranged  : Http_Client.Headers.Header_List := Http_Client.Headers.Empty;
               Options : HC.Download_Options := HC.Default_Download_Options;
               Outcome : HC.Download_Result;
               Status  : HE.Result_Status;
            begin
               --  A chunk a stopped fetch left whole is not fetched again.
               if Ada.Directories.Exists (Path)
                 and then Interfaces.Unsigned_64 (Ada.Directories.Size (Path)) = Length
               then
                  Board.Wrote (K, Length);
               else
                  Http_Client.Headers.Append
                    (Ranged, "Range",
                     "bytes=" & Model_Runner.Text.Trim (Interfaces.Unsigned_64'Image (Start_Of (K))) & "-"
                     & Model_Runner.Text.Trim (Interfaces.Unsigned_64'Image (Start_Of (K) + Length - 1)));
                  Options.Max_Download_Size := 0;
                  Options.Require_Success_Status := True;
                  Options.File_Mode := HC.Overwrite;
                  Options.Expected_Size := Length;
                  Options.Progress_Callback := Chunk_Progress'Unrestricted_Access;
                  Options.Progress_Interval_Bytes := 1024 * 1024;
                  Worker_Chunk.Set_Value (K);
                  Status := Download (URL => URL, Path => Path, Result => Outcome, Options => Options,
                                      Extra => Ranged);
                  Worker_Chunk.Set_Value (0);
                  if HE.Is_Success (Status) and then Outcome.HTTP_Status_Code = 206
                    and then Outcome.Bytes_Written = Length
                  then
                     Board.Wrote (K, Length);
                  else
                     Board.Fail
                       (Not_Served => HE.Is_Success (Status) and then Outcome.HTTP_Status_Code /= 206,
                        Why        => "a range of the file came back with status"
                                      & Natural'Image (Outcome.HTTP_Status_Code));
                  end if;
               end if;
            exception
               when others =>
                  Board.Fail (Not_Served => False, Why => "a range of the file could not be fetched");
            end;
         end loop;
         Board.Finish;
      exception
         when others =>
            Board.Finish;
      end Worker;
   begin
      Served := True;
      Ok := False;
      Reason := T.Empty;
      Remove_Stray_Chunks (Dest_Path, Have, Chunks);
      declare
         Crew : array (1 .. Range_Workers) of Worker;
         pragma Unreferenced (Crew);
      begin
         --  The progress painted from here, the one task that may: the
         --  workers only count.
         while Board.Finished < Range_Workers loop
            delay 0.5;
            if Report /= null then
               begin
                  Report (Have + Board.Written, File.Size);
               exception
                  when others =>
                     null;
               end;
            end if;
         end loop;
      end;

      if Board.Failed then
         Served := not Board.Refused;
         Reason := T.To_Bounded (Board.Why);
         --  Chunks fetched whole stay for the next run; a part is gone.
         for K in 1 .. Chunks loop
            if Ada.Directories.Exists (Chunk_Path (K))
              and then Interfaces.Unsigned_64 (Ada.Directories.Size (Chunk_Path (K))) /= Length_Of (K)
            then
               Ada.Directories.Delete_File (Chunk_Path (K));
            end if;
         end loop;
         if not Served then
            --  Ranges are not this server's way: none is kept.
            for K in 1 .. Chunks loop
               if Ada.Directories.Exists (Chunk_Path (K)) then
                  Ada.Directories.Delete_File (Chunk_Path (K));
               end if;
            end loop;
         end if;
         return;
      end if;

      --  In order onto what the file held, each chunk gone as it is added.
      declare
         use Ada.Streams;
         Out_File : Stream_IO.File_Type;
         Buffer   : Stream_Element_Array (1 .. 1024 * 1024);
         Last     : Stream_Element_Offset;
      begin
         if Ada.Directories.Exists (Dest_Path) then
            Stream_IO.Open (Out_File, Stream_IO.Append_File, Dest_Path);
         else
            Stream_IO.Create (Out_File, Stream_IO.Out_File, Dest_Path);
         end if;
         for K in 1 .. Chunks loop
            declare
               In_File : Stream_IO.File_Type;
            begin
               Stream_IO.Open (In_File, Stream_IO.In_File, Chunk_Path (K));
               while not Stream_IO.End_Of_File (In_File) loop
                  Stream_IO.Read (In_File, Buffer, Last);
                  Stream_IO.Write (Out_File, Buffer (1 .. Last));
               end loop;
               Stream_IO.Close (In_File);
               Ada.Directories.Delete_File (Chunk_Path (K));
            end;
         end loop;
         Stream_IO.Close (Out_File);
      end;

      --  The whole against the hub's digest: a file of the right length
      --  made of the wrong bytes is removed, not opened.
      if File.Has_Hash then
         declare
            use Ada.Streams;
            Context : CryptoLib.Hashes.SHA256_Context;
            In_File : Stream_IO.File_Type;
            Buffer  : Stream_Element_Array (1 .. 4 * 1024 * 1024);
            Last    : Stream_Element_Offset;
            Digest  : CryptoLib.Hashes.SHA256_Digest;
            Hex     : constant String := "0123456789abcdef";
            Seen    : String (1 .. 64);
         begin
            CryptoLib.Hashes.Initialize_SHA256 (Context);
            Stream_IO.Open (In_File, Stream_IO.In_File, Dest_Path);
            while not Stream_IO.End_Of_File (In_File) loop
               Stream_IO.Read (In_File, Buffer, Last);
               CryptoLib.Hashes.Update (Context, Buffer (1 .. Last));
            end loop;
            Stream_IO.Close (In_File);
            Digest := CryptoLib.Hashes.Finalize (Context);
            for I in Digest'Range loop
               Seen (2 * I - 1) := Hex (Natural (Digest (I)) / 16 + 1);
               Seen (2 * I) := Hex (Natural (Digest (I)) mod 16 + 1);
            end loop;
            if Ada.Characters.Handling.To_Lower (File.SHA256) /= Seen then
               Ada.Directories.Delete_File (Dest_Path);
               Reason := T.To_Bounded ("the file's digest is not the one the hub records; it was removed");
               return;
            end if;
         end;
      end if;
      if Report /= null then
         Report (File.Size, File.Size);
      end if;
      Ok := True;
   exception
      when others =>
         Served := True;
         Ok := False;
         Reason := T.To_Bounded ("the file's ranges could not be put together");
   end Fetch_Ranges;

   procedure Fetch
     (Repo      : String;
      File      : Download_File;
      Dest_Path : String;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded;
      Report    : Progress_Reporter := null)
   is
      Part    : constant String := Dest_Path & ".part";
      Outcome : HC.Download_Result;
      Options : HC.Download_Options := HC.Default_Download_Options;
      Status  : HE.Result_Status;

      --  The checked part takes the file's name: only now is there a file
      --  at Dest_Path to open or take for done.
      procedure Settle is
      begin
         if Ada.Directories.Exists (Dest_Path) then
            Ada.Directories.Delete_File (Dest_Path);
         end if;
         Ada.Directories.Rename (Part, Dest_Path);
      exception
         when others =>
            Ok := False;
            Reason := T.To_Bounded ("the checked download could not be moved to " & Dest_Path);
      end Settle;
   begin
      Ok := False;
      Reason := T.Empty;

      --  The directory the file goes in, for the ranges as for one stream;
      --  a part longer than the file is no part of it -- what it holds past
      --  the end would never be checked away -- and is begun again; chunks
      --  a fetch before parts left beside the file itself are dropped.
      begin
         Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Dest_Path));
         if File.Size > 0 and then Ada.Directories.Exists (Part)
           and then Interfaces.Unsigned_64 (Ada.Directories.Size (Part)) > File.Size
         then
            Ada.Directories.Delete_File (Part);
         end if;
         Remove_Stray_Chunks (Dest_Path, 0, 0);
      exception
         when others =>
            Reason := T.To_Bounded
              ("could not make room for " & Dest_Path
               & " -- the directory may not be writable");
            return;
      end;

      --  A large file whose digest the hub gives: in ranges at once, where
      --  the server serves them; in one stream where it does not.
      if File.Size >= Ranges_From and then File.Has_Hash then
         declare
            Served : Boolean;
         begin
            Fetch_Ranges (Repo, File, Part, Served, Ok, Reason, Report);
            if Ok then
               Settle;
               return;
            elsif Served then
               return;
            end if;
            Reason := T.Empty;
         end;
      end if;

      --  Written to the file itself, and a part left where it stops: a
      --  later fetch of the same file asks for the bytes past what is there
      --  and appends, so an interrupted download of a large model is not
      --  begun again. No size cap; the parents are made; a non-success
      --  status is a failure rather than a saved error page.
      Options.Max_Download_Size := 0;
      Options.Create_Parent_Dirs := True;
      Options.Require_Success_Status := True;
      Options.File_Mode := HC.Overwrite;
      Options.Enable_Resume := True;
      Options.Preserve_Partial_File := True;

      --  The whole size where it is known, so the client stops at it and a run
      --  that fills the file exactly is done. The download's size field is now
      --  64-bit, so a multi-gigabyte model size is carried through directly.
      if File.Size > 0 then
         Options.Expected_Size := File.Size;
      end if;

      --  And the digest the hub records, where it gave one, so the bytes on
      --  disk are the model's and not a mangling the size alone would pass.
      if File.Has_Hash then
         Options.Verify_SHA256 := True;
         Options.Expected_SHA256_Hex := File.SHA256;
      end if;

      --  Progress as it runs: the client calls back every few megabytes,
      --  and the callback hands the numbers to the caller's reporter to
      --  paint where there is a terminal to paint on.
      Active_Report := Report;
      Options.Progress_Callback := Show_Progress'Access;
      Options.Progress_Interval_Bytes := 4 * 1024 * 1024;

      Status := Download
        (URL     => Host & "/" & Repo & "/resolve/main/" & T.To_String (File.Name),
         Path    => Part,
         Result  => Outcome,
         Options => Options);

      Active_Report := null;

      if HE.Is_Success (Status) then
         Ok := True;
         Settle;
         return;
      end if;

      --  A file left at or past its whole size on a failure is not a part
      --  to resume but a whole one the digest or the size check turned
      --  down; it is removed, so a run does not open it or a later fetch
      --  take it for done. A shorter part is left where it is to resume.
      if File.Size > 0
        and then Ada.Directories.Exists (Part)
        and then Interfaces.Unsigned_64 (Ada.Directories.Size (Part))
                 >= File.Size
      then
         begin
            Ada.Directories.Delete_File (Part);
         exception
            when others =>
               null;
         end;
      end if;

      if Outcome.HTTP_Status_Code in 401 | 403 then
         --  A gated repository, which the hub answers the same way whether
         --  the token is missing or without access. Say which so the fix
         --  is the right one: accept the terms and set a token, or check
         --  the token that is set.
         if Model_Runner.Platform.Hub_Token /= ""
           or else Model_Runner.Config.Value ("hf-token") /= ""
         then
            Reason := T.To_Bounded
              ("the hub refused this repository (HTTP"
               & Natural'Image (Outcome.HTTP_Status_Code)
               & "); a token is set but may be invalid or without access -- "
               & "accept the model's terms on its hub page, or check the "
               & "token");
         else
            Reason := T.To_Bounded
              ("this repository is gated and no token is set (HTTP"
               & Natural'Image (Outcome.HTTP_Status_Code)
               & "); accept the model's terms on its hub page, then set "
               & "HF_TOKEN or hf-token in the settings file");
         end if;
      elsif Status = HE.Integrity_Check_Failed then
         Reason := T.To_Bounded
           ("the download did not match the hub's checksum and was "
            & "discarded; run it again to fetch it anew");
      elsif Status = HE.Write_Failed then
         --  The bytes arrived; writing them did not. Resuming will not
         --  help, so this says what will: room, or a writable directory.
         Reason := T.To_Bounded
           ("could not write " & Dest_Path
            & " -- the disk may be full or the directory not writable");
      else
         Reason := T.To_Bounded
           ("the download stopped (" & HE.Result_Status'Image (Status)
            & ", HTTP" & Natural'Image (Outcome.HTTP_Status_Code)
            & "); run it again to resume from where it left off");
      end if;
   end Fetch;

end Model_Runner.Hub;
