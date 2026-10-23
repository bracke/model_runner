with Ada.Calendar.Formatting;
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
with Http_Client.Proxies;
with Http_Client.Responses;
with Http_Client.Transports.TCP;
with Http_Client.URI;

with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;

with Hostkit.Durability;
with Hostkit.Fs;
with Hostkit.Locks;

with Model_Runner.Config;
with Model_Runner.GGUF.Shards;
with Model_Runner.Platform;
with Model_Runner.Heap_Buffers;

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

   --  Whether a name reads as a hub repository, owner/name: one slash, not
   --  at either end, and nothing a path on this machine begins with. A
   --  missing /data/m.bin or ~/models/x is a file not found, not a
   --  question to put to the hub -- which was asked, the path in the
   --  request, before anything said the file was missing.
   function Looks_Like_Repository (Repo : String) return Boolean is
      Slashes : Natural := 0;
   begin
      if Repo'Length < 3
        or else Repo (Repo'First) in '/' | '.' | '~' | '\'
        or else Repo (Repo'Last) = '/'
      then
         return False;
      end if;
      for C of Repo loop
         if C = '/' then
            Slashes := Slashes + 1;
         elsif C = '\' then
            return False;
         end if;
      end loop;
      return Slashes = 1;
   end Looks_Like_Repository;

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

      return Looks_Like_Repository (Named (Named'First .. Colon - 1));
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
      return Slash and then not Ends_With (Named, ".gguf")
        and then Looks_Like_Repository (Named);
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

   ---------------
   -- Proxy_For --
   ---------------

   function Proxy_For (Setting, Bypass, Host_Name : String) return String is
      Host  : constant String := Ada.Characters.Handling.To_Lower (Host_Name);
      Start : Positive := Bypass'First;

      --  Whether one entry of the list names the host.
      function Names (Entry_Text : String) return Boolean is
         Raw   : constant String := T.Trim (Entry_Text);
         Bare  : constant String :=
           Ada.Characters.Handling.To_Lower
             (if Raw'Length > 0 and then Raw (Raw'First) = '.'
              then Raw (Raw'First + 1 .. Raw'Last) else Raw);
      begin
         if Bare = "" then
            return False;
         elsif Bare = "*" then
            return True;
         end if;
         return Host = Bare
           or else (Host'Length > Bare'Length
                    and then Host (Host'Last - Bare'Length + 1 .. Host'Last) = Bare
                    and then Host (Host'Last - Bare'Length) = '.');
      end Names;
   begin
      if Setting = "" then
         return "";
      end if;
      for I in Bypass'First .. Bypass'Last + 1 loop
         if I > Bypass'Last or else Bypass (I) = ',' then
            if Names (Bypass (Start .. I - 1)) then
               return "";
            end if;
            Start := I + 1;
         end if;
      end loop;
      return Setting;
   end Proxy_For;

   --  The client's configuration: a connection made in half a minute and
   --  every read answered in a minute, or the request fails and the next
   --  run resumes it -- with none, a link gone under a sleeping laptop held
   --  the download, and every worker of a ranged one waiting on it, for
   --  ever. The proxy the environment names, where it names one for the
   --  hub. The hub token is not in it: it goes on each request
   --  (Request_For), so a gated repository is reached.
   procedure Client_For
     (Config : out HC.Client_Configuration;
      Status : out HE.Result_Status)
   is
      Timeouts : constant Http_Client.Transports.TCP.Timeout_Config :=
        (Connect => Connect_Timeout_Ms,
         Read    => Read_Timeout_Ms,
         Write   => Read_Timeout_Ms);
      Through : constant String :=
        Proxy_For (Model_Runner.Platform.Hub_Proxy,
                   Model_Runner.Platform.Proxy_Bypass, "huggingface.co");
   begin
      Config := HC.Default_Client_Configuration;
      Config.Execution.Timeouts := Timeouts;
      Config.Execution.TLS.Timeouts := Timeouts;
      Status := HE.Ok;
      if Through /= "" then
         Status := Http_Client.Proxies.Parse (Through, Config.Execution.Proxy);
      end if;
   end Client_For;

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
      Config  : HC.Client_Configuration;
      Status  : HE.Result_Status;
   begin
      Client_For (Config, Status);
      if HE.Is_Success (Status) then
         Status := HC.Initialize (Item, Config);
      end if;
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
      Config  : HC.Client_Configuration;
      Status  : HE.Result_Status;
   begin
      Client_For (Config, Status);
      if HE.Is_Success (Status) then
         Status := HC.Initialize (Item, Config);
      end if;
      if HE.Is_Success (Status) then
         Status := Request_For (URL, Extra, Request);
      end if;
      if HE.Is_Success (Status) then
         Status := HC.Execute_To_File (Item, Request, Path, Result, Options);
      end if;
      return Status;
   end Download;

   --------------
   -- File_URL --
   --------------

   function File_URL (Repo, Revision, Name : String) return String is
      Hex : constant String := "0123456789ABCDEF";

      --  A name's bytes, the unreserved and the separators as they are and
      --  every other one as %XX.
      function Encoded (Item : String) return String is
         Result : String (1 .. 3 * Item'Length);
         Used   : Natural := 0;
      begin
         for C of Item loop
            if C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9'
                   | '-' | '_' | '.' | '~' | '/'
            then
               Used := Used + 1;
               Result (Used) := C;
            else
               Result (Used + 1) := '%';
               Result (Used + 2) := Hex (Character'Pos (C) / 16 + 1);
               Result (Used + 3) := Hex (Character'Pos (C) mod 16 + 1);
               Used := Used + 3;
            end if;
         end loop;
         return Result (1 .. Used);
      end Encoded;
   begin
      return Host & "/" & Encoded (Repo) & "/resolve/"
        & (if Revision = "" then "main" else Encoded (Revision))
        & "/" & Encoded (Name);
   end File_URL;

   ------------------
   -- Read_Listing --
   ------------------

   --  An empty listing and file set, held once: cleared from an aggregate,
   --  each was built whole in the frame that cleared it -- a listing is
   --  280 KB -- and a listing held as a local was one too.
   No_Listing : constant Listing := [others => <>];
   No_Files   : constant File_Set := [others => <>];
   package Listing_Rooms is new Model_Runner.Heap_Buffers.Holders (Listing);

   procedure Read_Listing
     (Text   : String;
      Files  : out Listing;
      Count  : out Natural;
      Ok     : out Boolean;
      Reason : out Model_Runner.Text.Bounded)
   is
      package J renames Jsonlib.Documents;
      use type J.Value_Kind;
      use type J.Node;

      Document : J.Document;
      Error    : Jsonlib.Errors.Error_Info;
   begin
      Files := No_Listing;
      Count := 0;
      Ok := False;
      Reason := T.Empty;

      Jsonlib.Parsers.Parse
        (Text, Document, Error,
         (Jsonlib.Parsers.Default_Options with delta
            Duplicates => Jsonlib.Parsers.Last_Wins));
      if Jsonlib.Errors.Failed (Error) then
         Reason := T.To_Bounded ("the hub's answer is not the listing it gives");
         return;
      end if;

      declare
         Root     : constant J.Node := J.Root (Document);
         Revision : T.Bounded;

         --  A member's text, or "" where it is absent or not text.
         function Text_Of (Item : J.Node; Named : String) return String is
         begin
            if J.Kind (Document, Item) /= J.Object_Value
              or else not J.Has_Member (Document, Item, Named)
              or else J.Kind (Document, J.Member (Document, Item, Named))
                      /= J.String_Value
            then
               return "";
            end if;
            return J.As_String (Document, J.Member (Document, Item, Named));
         end Text_Of;

         --  A member's whole number, or zero.
         function Number_Of (Item : J.Node; Named : String) return Interfaces.Unsigned_64 is
         begin
            if J.Kind (Document, Item) /= J.Object_Value
              or else not J.Has_Member (Document, Item, Named)
              or else J.Kind (Document, J.Member (Document, Item, Named))
                      /= J.Integer_Value
            then
               return 0;
            end if;
            return Interfaces.Unsigned_64'Value
              (J.Literal (Document, J.Member (Document, Item, Named)));
         exception
            when Constraint_Error =>
               return 0;
         end Number_Of;
      begin
         if J.Kind (Document, Root) /= J.Object_Value
           or else not J.Has_Member (Document, Root, "siblings")
           or else J.Kind (Document, J.Member (Document, Root, "siblings"))
                   /= J.Array_Value
         then
            Reason := T.To_Bounded ("the hub's answer lists no files");
            return;
         end if;

         declare
            Sha : constant String := Text_Of (Root, "sha");
         begin
            --  A commit is hexadecimal; anything else is not put in a URL.
            if Sha'Length in 7 .. 64
              and then (for all C of Sha => C in '0' .. '9' | 'a' .. 'f')
            then
               Revision := T.To_Bounded (Sha);
            end if;
         end;

         declare
            Siblings : constant J.Node := J.Member (Document, Root, "siblings");
         begin
            for I in 1 .. J.Length (Document, Siblings) loop
               declare
                  Entry_Node : constant J.Node := J.Element (Document, Siblings, I);
                  Name       : constant String := Text_Of (Entry_Node, "rfilename");
                  LFS        : constant J.Node :=
                    (if J.Kind (Document, Entry_Node) = J.Object_Value
                       and then J.Has_Member (Document, Entry_Node, "lfs")
                     then J.Member (Document, Entry_Node, "lfs")
                     else Entry_Node);
                  Has_LFS    : constant Boolean := LFS /= Entry_Node;
                  Digest     : constant String :=
                    (if Has_LFS then Text_Of (LFS, "sha256") else "");
                  Size       : constant Interfaces.Unsigned_64 :=
                    (if Number_Of (Entry_Node, "size") > 0
                     then Number_Of (Entry_Node, "size")
                     elsif Has_LFS then Number_Of (LFS, "size") else 0);
               begin
                  if Ends_With (Name, ".gguf")
                    and then not Contains (Name, "mmproj")
                    and then Name'Length <= Max_Name
                    and then Is_Safe_File_Name (Name)
                    and then Count < Max_Listed
                  then
                     Count := Count + 1;
                     Files (Count) :=
                       (Name     => T.To_Bounded (Name),
                        Size     => Size,
                        SHA256   =>
                          (if Digest'Length = 64 then Digest else [1 .. 64 => '0']),
                        Has_Hash => Digest'Length = 64
                                    and then (for all C of Digest =>
                                                C in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F'),
                        Revision => Revision);
                  end if;
               end;
            end loop;
         end;
      end;
      Ok := True;
   end Read_Listing;

   --  The repository's listing, read over the API: Ok false with a reason
   --  that names what went wrong -- the hub not reached, a repository it
   --  will not show without a token, one that is not there.
   procedure Fetch_Listing
     (Repo   : String;
      Files  : out Listing;
      Count  : out Natural;
      Ok     : out Boolean;
      Reason : out Model_Runner.Text.Bounded)
   is
      Result : HC.Client_Result;
      Status : constant HE.Result_Status :=
        Get (URL => Host & "/api/models/" & Repo & "?blobs=true", Result => Result);
      Code   : Natural := 0;
   begin
      Files := No_Listing;
      Count := 0;
      Ok := False;
      if not HE.Is_Success (Status) then
         Reason := T.To_Bounded
           ("could not reach huggingface.co (" & HE.Result_Status'Image (Status) & ")");
         return;
      end if;
      Code := Natural (Http_Client.Responses.Status_Code (Result.Response));
      if Code in 401 | 403 then
         Reason := T.To_Bounded
           ("the hub will not show " & Repo & " (HTTP" & Natural'Image (Code)
            & "); it may be private or gated -- set HF_TOKEN");
         return;
      elsif Code = 404 then
         Reason := T.To_Bounded ("the hub has no repository " & Repo);
         return;
      elsif Code not in 200 .. 299 then
         Reason := T.To_Bounded
           ("the hub answered HTTP" & Natural'Image (Code) & " for " & Repo);
         return;
      end if;
      Read_Listing (HC.Response_Text (Result), Files, Count, Ok, Reason);
   end Fetch_Listing;

   ------------------
   -- Choose_Quant --
   ------------------

   procedure Choose_Quant
     (Listed       : Listing;
      Listed_Count : Natural;
      Quant        : String;
      Repo         : String;
      Files        : out File_Set;
      Count        : out Natural;
      Ok           : out Boolean;
      Reason       : out Model_Runner.Text.Bounded)
   is
      Matches : Natural := 0;

      function Listed_Names return String is
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
      end Listed_Names;

      --  Shards in order: -00001- sorts before -00002-, so a name sort puts
      --  the first shard first, which is the one the loader opens.
      procedure Sort_By_Name is
      begin
         for I in 1 .. Matches loop
            for J in I + 1 .. Matches loop
               if T.To_String (Files (J).Name) < T.To_String (Files (I).Name) then
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
      Files := No_Files;
      Ok := False;
      Count := 0;
      Reason := T.Empty;

      for I in 1 .. Listed_Count loop
         if Contains (T.To_String (Listed (I).Name), Quant) and then Matches < Max_Files then
            Matches := Matches + 1;
            Files (Matches) := Listed (I);
         end if;
      end loop;

      if Matches = 0 then
         Reason := T.To_Bounded
           ("no .gguf file for that quant in " & Repo
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
                     & "quant more exactly: " & Listed_Names);
               end if;
            end;

         else
            Reason := T.To_Bounded
              ("more than one file matched; name the quant more exactly: "
               & Listed_Names);
         end if;
      end;
   end Choose_Quant;

   ----------------
   -- Choose_Fit --
   ----------------

   procedure Choose_Fit
     (Listed       : Listing;
      Listed_Count : Natural;
      Budget       : Interfaces.Unsigned_64;
      Repo         : String;
      Files        : out File_Set;
      Count        : out Natural;
      Ok           : out Boolean;
      Reason       : out Model_Runner.Text.Bounded)
   is
      --  The index in Listed of a file of this name, or zero.
      function Find (Name : String) return Natural is
      begin
         for I in 1 .. Listed_Count loop
            if T.To_String (Listed (I).Name) = Name then
               return I;
            end if;
         end loop;
         return 0;
      end Find;

      --  The whole size of the model a representative names -- a single
      --  file's size, or the sum of a shard set's -- and zero where a shard
      --  of the set is not listed: a set short of a shard is no model to
      --  weigh, and fetched it would be reported saved and fail at load.
      function Group_Total (Rep : String) return Interfaces.Unsigned_64 is
         Total : Interfaces.Unsigned_64 := 0;
         Shards_Count : constant Natural := Shard_Total (Rep);
      begin
         if Shards_Count <= 1 then
            declare
               At_Rep : constant Natural := Find (Rep);
            begin
               return (if At_Rep = 0 then 0 else Listed (At_Rep).Size);
            end;
         end if;
         if Shards_Count > Max_Files then
            return 0;
         end if;
         for K in 1 .. Shards_Count loop
            declare
               At_K : constant Natural := Find (GS.Shard_Path (Rep, K, Shards_Count));
            begin
               if At_K = 0 then
                  return 0;
               end if;
               Total := Total + Listed (At_K).Size;
            end;
         end loop;
         return Total;
      end Group_Total;

      --  Whether a file is the one that stands for its model -- a single
      --  file, or the first shard of a set.
      function Is_Representative (Name : String) return Boolean
      is (not GS.Is_Shard_Name (Name)
          or else Name (Name'Last - 18 .. Name'Last - 14) = "00001");

      Best_Fit    : Natural := 0;
      Best_Total  : Interfaces.Unsigned_64 := 0;
      Smallest    : Natural := 0;
      Small_Total : Interfaces.Unsigned_64 := 0;
      Chosen      : Natural := 0;
      None_Fit    : Boolean := False;
   begin
      Files := No_Files;
      Ok := False;
      Count := 0;
      Reason := T.Empty;

      if Listed_Count = 0 then
         Reason := T.To_Bounded ("no .gguf file in " & Repo & " -- the repository may be wrong");
         return;
      end if;

      --  Weigh each model: the largest that fits the budget, and the
      --  smallest of all as a fallback where none does.
      for I in 1 .. Listed_Count loop
         if Is_Representative (T.To_String (Listed (I).Name)) then
            declare
               Total : constant Interfaces.Unsigned_64 :=
                 Group_Total (T.To_String (Listed (I).Name));
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
         Reason := T.To_Bounded ("no quant to choose from in " & Repo);
         return;
      end if;

      --  The chosen model's files: itself, or its shards in order.
      declare
         Rep   : constant String := T.To_String (Listed (Chosen).Name);
         Total : constant Natural := Shard_Total (Rep);
      begin
         if Total <= 1 then
            Files (1) := Listed (Chosen);
            Count := 1;
         else
            for K in 1 .. Total loop
               Count := Count + 1;
               Files (Count) := Listed (Find (GS.Shard_Path (Rep, K, Total)));
            end loop;
         end if;
      end;

      if None_Fit then
         Reason := T.To_Bounded
           ("none of the quants fit this machine; the smallest was taken and "
            & "may be slow or fail");
      end if;
      Ok := True;
   end Choose_Fit;

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
      Quant        : T.Bounded;
      Listed_Room  : Listing_Rooms.Holder;
      Listed       : Listing renames Listed_Room.Data.all;
      Listed_Count : Natural;
   begin
      Files := No_Files;
      Count := 0;
      Split (Reference, Repo, Quant);
      Fetch_Listing (T.To_String (Repo), Listed, Listed_Count, Ok, Reason);
      if not Ok then
         return;
      end if;
      Choose_Quant
        (Listed, Listed_Count, T.To_String (Quant), T.To_String (Repo),
         Files, Count, Ok, Reason);
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
      Listed_Room  : Listing_Rooms.Holder;
      Listed       : Listing renames Listed_Room.Data.all;
      Listed_Count : Natural;
   begin
      Files := No_Files;
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

      Fetch_Listing (Reference, Listed, Listed_Count, Ok, Reason);
      if not Ok then
         return;
      end if;
      Choose_Fit (Listed, Listed_Count, Budget, Reference, Files, Count, Ok, Reason);
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

   -----------------
   -- File_Digest --
   -----------------

   function File_Digest (Path : String) return String is
      package Stream_IO renames Ada.Streams.Stream_IO;
      use Ada.Streams;
      Context : CryptoLib.Hashes.SHA256_Context;
      In_File : Stream_IO.File_Type;
      Room    : Model_Runner.Heap_Buffers.Bytes (4 * 1024 * 1024);
      Buffer  : Stream_Element_Array renames Room.Data.all;
      Last    : Stream_Element_Offset;
      Digest  : CryptoLib.Hashes.SHA256_Digest;
      Hex     : constant String := "0123456789abcdef";
      Seen    : String (1 .. 64);
   begin
      CryptoLib.Hashes.Initialize_SHA256 (Context);
      Stream_IO.Open (In_File, Stream_IO.In_File, Path);
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
      return Seen;
   exception
      when others =>
         if Stream_IO.Is_Open (In_File) then
            Stream_IO.Close (In_File);
         end if;
         return "";
   end File_Digest;

   -------------------
   -- Record_Digest --
   -------------------

   procedure Record_Digest (Path : String; SHA256 : String) is
      package Stream_IO renames Ada.Streams.Stream_IO;
      Note : Stream_IO.File_Type;
   begin
      Stream_IO.Create (Note, Stream_IO.Out_File, Path & ".sha256");
      String'Write (Stream_IO.Stream (Note),
                    Ada.Characters.Handling.To_Lower (SHA256) & ASCII.LF);
      Stream_IO.Close (Note);
   exception
      when others =>
         if Stream_IO.Is_Open (Note) then
            Stream_IO.Close (Note);
         end if;
   end Record_Digest;

   --------------
   -- Is_Whole --
   --------------

   --  Files read whole in this process and found the hub's, by path and
   --  digest: where the digest cannot be kept beside the file -- a store on
   --  a read-only or full disk -- it is not read again for every question.
   package Verified_Files is new Ada.Containers.Indefinite_Vectors (Positive, String);
   Verified : Verified_Files.Vector;

   --  And files read whole and found not to be, by digest, path, size and
   --  when last written: a multi-gigabyte file of the wrong bytes was read
   --  whole three times over for one download offer. Changed since, it is
   --  read again.
   Mismatched : Verified_Files.Vector;

   function As_Last_Seen (Path : String) return String is
   begin
      return Path & "|" & Ada.Directories.File_Size'Image (Ada.Directories.Size (Path))
        & "|" & Ada.Calendar.Formatting.Image
                  (Ada.Directories.Modification_Time (Path), Include_Time_Fraction => True);
   exception
      when others =>
         return Path;
   end As_Last_Seen;

   function Is_Whole (File : Download_File; Path : String) return Boolean is
      package Stream_IO renames Ada.Streams.Stream_IO;
      Wanted : constant String := Ada.Characters.Handling.To_Lower (File.SHA256);
      Key    : constant String := Wanted & Path;

      --  The digest kept beside the file, or "" where none can be read.
      function Kept return String is
         Note : Stream_IO.File_Type;
         Held : String (1 .. 64);
      begin
         if not Ada.Directories.Exists (Path & ".sha256")
           or else Ada.Directories."<" (Ada.Directories.Size (Path & ".sha256"), 64)
         then
            return "";
         end if;
         Stream_IO.Open (Note, Stream_IO.In_File, Path & ".sha256");
         String'Read (Stream_IO.Stream (Note), Held);
         Stream_IO.Close (Note);
         return Held;
      exception
         when others =>
            if Stream_IO.Is_Open (Note) then
               Stream_IO.Close (Note);
            end if;
            return "";
      end Kept;
   begin
      if not File.Has_Hash then
         return True;
      end if;
      if Kept = Wanted then
         return True;
      elsif Verified.Contains (Key) then
         --  Read whole already in this run; the note is put right where it
         --  can be, and the bytes are not read again.
         Record_Digest (Path, Wanted);
         return True;
      end if;
      --  No digest kept, or another's -- a file from before digests were
      --  kept, put there by hand, or a stale note beside the right bytes:
      --  the bytes are read, and kept as known where they are the hub's.
      if Mismatched.Contains (Wanted & As_Last_Seen (Path)) then
         return False;
      end if;
      if File_Digest (Path) = Wanted then
         Record_Digest (Path, Wanted);
         Verified.Append (Key);
         return True;
      end if;
      Mismatched.Append (Wanted & As_Last_Seen (Path));
      return False;
   end Is_Whole;

   --  Where a join of a part's chunks began, kept beside the part while it
   --  runs: Path & ".joining", the length the part had.
   procedure Note_Join_Start (Path : String; Length : Interfaces.Unsigned_64) is
      package Stream_IO renames Ada.Streams.Stream_IO;
      Note : Stream_IO.File_Type;
   begin
      Stream_IO.Create (Note, Stream_IO.Out_File, Path & ".joining");
      String'Write (Stream_IO.Stream (Note), T.Trim (Interfaces.Unsigned_64'Image (Length)));
      Stream_IO.Close (Note);
   end Note_Join_Start;

   procedure Forget_Join_Start (Path : String) is
   begin
      if Ada.Directories.Exists (Path & ".joining") then
         Ada.Directories.Delete_File (Path & ".joining");
      end if;
   end Forget_Join_Start;

   --  A part a join stopped in, cut back to where the join began: its
   --  first bytes copied to a file of their own and that put in its place,
   --  the chunks it was joining still beside it. A part with no such note
   --  is left as it is.
   procedure Cut_Back (Path : String) is
      package Stream_IO renames Ada.Streams.Stream_IO;
      use Ada.Streams;
      Note    : Stream_IO.File_Type;
      Keep    : Interfaces.Unsigned_64 := 0;
   begin
      if not Ada.Directories.Exists (Path & ".joining") then
         return;
      end if;
      declare
         Text : String (1 .. Natural (Ada.Directories.Size (Path & ".joining")));
      begin
         Stream_IO.Open (Note, Stream_IO.In_File, Path & ".joining");
         String'Read (Stream_IO.Stream (Note), Text);
         Stream_IO.Close (Note);
         Keep := Interfaces.Unsigned_64'Value (Text);
      end;
      if Ada.Directories.Exists (Path)
        and then Interfaces.Unsigned_64 (Ada.Directories.Size (Path)) > Keep
      then
         declare
            In_File, Out_File : Stream_IO.File_Type;
            Room   : Model_Runner.Heap_Buffers.Bytes (1024 * 1024);
            Buffer : Stream_Element_Array renames Room.Data.all;
            Last   : Stream_Element_Offset;
            Left   : Interfaces.Unsigned_64 := Keep;
         begin
            Stream_IO.Open (In_File, Stream_IO.In_File, Path);
            Stream_IO.Create (Out_File, Stream_IO.Out_File, Path & ".cut");
            while Left > 0 loop
               declare
                  Take : constant Stream_Element_Offset :=
                    Stream_Element_Offset
                      (Interfaces.Unsigned_64'Min (Left, Buffer'Length));
               begin
                  Stream_IO.Read (In_File, Buffer (1 .. Take), Last);
                  exit when Last < 1;
                  Stream_IO.Write (Out_File, Buffer (1 .. Last));
                  Left := Left - Interfaces.Unsigned_64 (Last);
               end;
            end loop;
            Stream_IO.Close (In_File);
            Stream_IO.Close (Out_File);
            if not Hostkit.Fs.Replace_File (Path & ".cut", Path) then
               Ada.Directories.Delete_File (Path & ".cut");
            end if;
         end;
      end if;
      Ada.Directories.Delete_File (Path & ".joining");
   exception
      when others =>
         --  Not cut: the part is dropped and the chunks with it, which is
         --  what a fetch did before the note was kept.
         if Ada.Directories.Exists (Path) then
            Ada.Directories.Delete_File (Path);
         end if;
         if Ada.Directories.Exists (Path & ".joining") then
            Ada.Directories.Delete_File (Path & ".joining");
         end if;
   end Cut_Back;

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
      URL    : constant String :=
        File_URL (Repo, T.To_String (File.Revision), T.To_String (File.Name));

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
                        Why        =>
                          (if HE.Is_Success (Status)
                           then "a range of the file came back with status"
                                & Natural'Image (Outcome.HTTP_Status_Code)
                           else "a range of the file could not be fetched ("
                                & HE.Result_Status'Image (Status)
                                & "); run it again to resume"));
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

      --  In order onto what the file held, each chunk gone once all are
      --  added. Where the join began is kept beside the part first: a join
      --  stopped part way -- a full disk -- leaves the part past a chunk's
      --  edge, and the next fetch cuts it back there (Cut_Back) rather than
      --  taking the length it has for where the chunks begin and deleting
      --  every chunk still waiting as a stray.
      Note_Join_Start (Dest_Path, Have);
      declare
         use Ada.Streams;
         Out_File : Stream_IO.File_Type;
         Room     : Model_Runner.Heap_Buffers.Bytes (1024 * 1024);
         Buffer   : Stream_Element_Array renames Room.Data.all;
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
            exception
               when others =>
                  if Stream_IO.Is_Open (In_File) then
                     Stream_IO.Close (In_File);
                  end if;
                  raise;
            end;
         end loop;
         Stream_IO.Close (Out_File);
      exception
         --  Joined part way -- a full disk, a chunk gone -- the files are
         --  closed, not left open for the life of the process, and the
         --  chunks kept for the next fetch, which cuts the part back.
         when others =>
            if Stream_IO.Is_Open (Out_File) then
               Stream_IO.Close (Out_File);
            end if;
            Reason := T.To_Bounded
              ("the file's ranges could not be put together -- the disk may be full");
            Served := True;
            Ok := False;
            return;
      end;
      for K in 1 .. Chunks loop
         Ada.Directories.Delete_File (Chunk_Path (K));
      end loop;
      Forget_Join_Start (Dest_Path);

      --  The whole against the hub's digest: a file of the right length
      --  made of the wrong bytes is removed, not opened. Its note is the
      --  whole file's, written once it takes the file's name (Settle); the
      --  part has none.
      if File.Has_Hash then
         if Ada.Characters.Handling.To_Lower (File.SHA256) /= File_Digest (Dest_Path) then
            Ada.Directories.Delete_File (Dest_Path);
            Reason := T.To_Bounded ("the file's digest is not the one the hub records; it was removed");
            return;
         end if;
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

   --  The revision a part was begun at, kept beside it as Part &
   --  ".revision"; "" where none is kept (a part from before revisions
   --  were, or a fetch of the branch's head).
   function Part_Revision (Part : String) return String is
      package Stream_IO renames Ada.Streams.Stream_IO;
      Note : Stream_IO.File_Type;
   begin
      if not Ada.Directories.Exists (Part & ".revision") then
         return "";
      end if;
      declare
         Text : String (1 .. Natural (Ada.Directories.Size (Part & ".revision")));
      begin
         Stream_IO.Open (Note, Stream_IO.In_File, Part & ".revision");
         String'Read (Stream_IO.Stream (Note), Text);
         Stream_IO.Close (Note);
         return Text;
      end;
   exception
      when others =>
         if Stream_IO.Is_Open (Note) then
            Stream_IO.Close (Note);
         end if;
         return "";
   end Part_Revision;

   procedure Note_Part_Revision (Part : String; Revision : String) is
      package Stream_IO renames Ada.Streams.Stream_IO;
      Note : Stream_IO.File_Type;
   begin
      if Revision = "" then
         if Ada.Directories.Exists (Part & ".revision") then
            Ada.Directories.Delete_File (Part & ".revision");
         end if;
         return;
      end if;
      Stream_IO.Create (Note, Stream_IO.Out_File, Part & ".revision");
      String'Write (Stream_IO.Stream (Note), Revision);
      Stream_IO.Close (Note);
   exception
      when others =>
         if Stream_IO.Is_Open (Note) then
            Stream_IO.Close (Note);
         end if;
   end Note_Part_Revision;

   procedure Fetch_Unlocked
     (Repo      : String;
      File      : Download_File;
      Dest_Path : String;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded;
      Report    : Progress_Reporter)
   is
      Part    : constant String := Dest_Path & ".part";
      Outcome : HC.Download_Result;
      Options : HC.Download_Options := HC.Default_Download_Options;
      Status  : HE.Result_Status;

      --  The checked part takes the file's name: only now is there a file
      --  at Dest_Path to open or take for done.
      --  Its bytes are put on the disk first and the name changes in one
      --  step, the old file replaced: a delete and then a rename left no
      --  file at the name between the two, and a rename over nothing let a
      --  power cut bring the name back on an empty file beside its note.
      procedure Settle is
         Synced : constant Hostkit.Durability.Outcome :=
           Hostkit.Durability.Sync_File (Part);
         pragma Unreferenced (Synced);
      begin
         if not Hostkit.Fs.Replace_File (Part, Dest_Path) then
            raise Ada.Directories.Use_Error;
         end if;
         declare
            Folder : constant Hostkit.Durability.Outcome :=
              Hostkit.Durability.Sync_Directory
                (Ada.Directories.Containing_Directory (Dest_Path));
            pragma Unreferenced (Folder);
         begin
            null;
         end;
         if Ada.Directories.Exists (Part & ".revision") then
            Ada.Directories.Delete_File (Part & ".revision");
         end if;
         --  The client checked the bytes against the digest; what it was is
         --  kept beside them, so the next run knows the file for this one.
         if File.Has_Hash then
            Record_Digest (Dest_Path, File.SHA256);
         end if;
      exception
         when others =>
            Ok := False;
            Reason := T.To_Bounded ("the checked download could not be moved to " & Dest_Path);
      end Settle;
   begin
      Ok := False;
      Reason := T.Empty;

      --  The directory the file goes in, for the ranges as for one stream;
      --  a part a join stopped in is cut back to where it began; a part of
      --  another revision of the file -- the repository changed since it
      --  was begun -- or longer than the file is no part of it -- what it
      --  holds past the end would never be checked away -- and is begun
      --  again; chunks a fetch before parts left beside the file itself
      --  are dropped.
      begin
         Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Dest_Path));
         Cut_Back (Part);
         if Ada.Directories.Exists (Part)
           and then Part_Revision (Part) /= T.To_String (File.Revision)
         then
            Ada.Directories.Delete_File (Part);
            Remove_Stray_Chunks (Part, 0, 0);
         end if;
         if File.Size > 0 and then Ada.Directories.Exists (Part)
           and then Interfaces.Unsigned_64 (Ada.Directories.Size (Part)) > File.Size
         then
            Ada.Directories.Delete_File (Part);
         end if;
         Note_Part_Revision (Part, T.To_String (File.Revision));
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
        (URL     => File_URL (Repo, T.To_String (File.Revision), T.To_String (File.Name)),
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
         --  Discarded only where it was whole: a short one is a part, kept
         --  above for the next run to resume.
         Reason := T.To_Bounded
           (if Ada.Directories.Exists (Part)
            then "the download stopped short of the file's size; run it "
                 & "again to resume from where it left off"
            else "the download did not match the hub's checksum and was "
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
   end Fetch_Unlocked;

   -----------
   -- Fetch --
   -----------

   procedure Fetch
     (Repo      : String;
      File      : Download_File;
      Dest_Path : String;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded;
      Report    : Progress_Reporter := null)
   is
      Held : Hostkit.Locks.Lock;

      procedure Release is
      begin
         if Hostkit.Locks.Is_Held (Held) then
            Hostkit.Locks.Release (Held);
         end if;
      end Release;
   begin
      Ok := False;
      Reason := T.Empty;

      --  One fetch of a file at a time: a second run pulling the same model
      --  wrote the same part and the same chunks, and removed the first's
      --  chunks as strays. The lock is the system's, so a run killed part
      --  way holds it no longer; a file system with no locks fetches as it
      --  did.
      begin
         Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Dest_Path));
         if Hostkit.Locks.Acquire
              (Dest_Path & ".lock", Hostkit.Locks.Lock_Exclusive,
               Wait => False, Item => Held) in Hostkit.Locks.Lock_Busy
         then
            Reason := T.To_Bounded
              ("another run is fetching " & T.To_String (File.Name)
               & " now; let it finish first");
            return;
         end if;
      exception
         when others =>
            null;
      end;
      Fetch_Unlocked (Repo, File, Dest_Path, Ok, Reason, Report);
      Release;
   exception
      when others =>
         Release;
         raise;
   end Fetch;

end Model_Runner.Hub;
