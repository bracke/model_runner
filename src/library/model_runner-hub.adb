with Ada.Characters.Handling;

with Http_Client.Clients;
with Http_Client.Errors;
with Http_Client.Headers;

with Model_Runner.GGUF.Shards;
with Model_Runner.Platform;

package body Model_Runner.Hub is

   package T renames Model_Runner.Text;
   package HC renames Http_Client.Clients;
   package HE renames Http_Client.Errors;
   package GS renames Model_Runner.GGUF.Shards;

   Host : constant String := "https://huggingface.co";

   --  How many shards a shard-named file says its model is: the count in
   --  its -of-000NN suffix, the five digits before ".gguf". Zero for a
   --  name that is not a shard's or whose count will not read.
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

   function Upper (Item : String) return String
     renames Ada.Characters.Handling.To_Upper;

   --  Whether Whole ends with Suffix, ignoring case.
   function Ends_With (Whole : String; Suffix : String) return Boolean is
   begin
      return Whole'Length >= Suffix'Length
        and then Upper (Whole (Whole'Last - Suffix'Length + 1 .. Whole'Last))
                 = Upper (Suffix);
   end Ends_With;

   --  Whether Needle appears in Haystack, ignoring case.
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

   -------------------
   -- Is_Reference --
   -------------------

   function Is_Reference (Named : String) return Boolean is
      Colon : Natural := 0;
   begin
      --  The last colon, so a repository with none and a quant with none
      --  are told apart. A slash before it, so owner/repo:quant is a
      --  reference and a bare path with a colon in it is not.
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

   --------------
   -- Split --
   --------------

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

   ------------------------
   -- Client_For --
   ------------------------

   --  A client configured to carry the hub token where the environment has
   --  one, so a gated repository is reached. A token that is not a valid
   --  header value is left off rather than raised on.
   function Client_For return HC.Client_Configuration is
      Config : HC.Client_Configuration := HC.Default_Client_Configuration;
      Token  : constant String :=
        Model_Runner.Platform.Environment_Value ("HF_TOKEN");
      Value  : constant String := "Bearer " & Token;
   begin
      if Token /= ""
        and then Http_Client.Headers.Is_Valid_Value (Value)
      then
         Http_Client.Headers.Append
           (Config.Default_Headers, "Authorization", Value);
      end if;
      return Config;
   end Client_For;

   -------------
   -- Resolve --
   -------------

   procedure Resolve
     (Reference : String;
      Repo      : out Model_Runner.Text.Bounded;
      File_Name : out Model_Runner.Text.Bounded;
      Shards    : out Natural;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded)
   is
      Quant  : T.Bounded;
      Result : HC.Client_Result;
      Status : HE.Result_Status;

      Max_Candidates : constant := 64;
      Candidate : array (1 .. Max_Candidates) of T.Bounded;
      Matches   : Natural := 0;

      procedure Note_Candidate (Name : String) is
      begin
         if Matches < Max_Candidates then
            Matches := Matches + 1;
            Candidate (Matches) := T.To_Bounded (Name);
         end if;
      end Note_Candidate;

      --  The candidates, comma-joined, for a message that names what
      --  matched when the caller has to choose.
      function Listed return String is
         Room : String (1 .. 400) := [others => ' '];
         Used : Natural := 0;
      begin
         for I in 1 .. Matches loop
            declare
               Name : constant String := T.To_String (Candidate (I));
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

   begin
      Ok := False;
      File_Name := T.Empty;
      Shards := 0;
      Reason := T.Empty;

      Split (Reference, Repo, Quant);

      Status := HC.Get
        (URL           => Host & "/api/models/" & T.To_String (Repo),
         Result        => Result,
         Configuration => Client_For);

      if not HE.Is_Success (Status) then
         Reason := T.To_Bounded
           ("could not reach huggingface.co (" & HE.Result_Status'Image (Status)
            & ")");
         return;
      end if;

      --  The file list is the "rfilename" values of the response. Each is a
      --  JSON string; the GGUF files whose name carries the quant are the
      --  candidates. The body is scanned rather than parsed, which one key
      --  read out of a known shape does not need a parser for.
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
                  --  Past the colon and the opening quote.
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
                             and then Contains (Name, T.To_String (Quant))
                           then
                              Note_Candidate (Name);
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
            if not GS.Is_Shard_Name (T.To_String (Candidate (I))) then
               All_Shards := False;
            end if;
         end loop;

         if Matches = 1 and then not All_Shards then
            File_Name := Candidate (1);
            Shards    := 1;
            Ok        := True;

         elsif All_Shards then
            --  A shard set: every shard carries the quant, so all matched.
            --  The -of-000NN count is authoritative; the loader opens the
            --  first shard and finds the rest beside it, so the first shard
            --  is what to name and the count is how many to fetch.
            declare
               Total : constant Natural :=
                 Shard_Total (T.To_String (Candidate (1)));
               First : constant String :=
                 (if Total >= 1
                  then GS.Shard_Path (T.To_String (Candidate (1)), 1, Total)
                  else "");
               Same  : Boolean := Total >= 1 and then First /= "";
            begin
               --  One set only: every candidate the same count and the same
               --  first shard, or the match is ambiguous.
               for I in 1 .. Matches loop
                  if Shard_Total (T.To_String (Candidate (I))) /= Total
                    or else GS.Shard_Path
                              (T.To_String (Candidate (I)), 1, Total) /= First
                  then
                     Same := False;
                  end if;
               end loop;

               if Same then
                  File_Name := T.To_Bounded (First);
                  Shards    := Total;
                  Ok        := True;
               else
                  Reason := T.To_Bounded
                    ("more than one shard set matched; name the quant more "
                     & "exactly: " & Listed);
               end if;
            end;

         else
            Reason := T.To_Bounded
              ("more than one file matched; name the quant more exactly: "
               & Listed);
         end if;
      end;
   end Resolve;

   -----------
   -- Fetch --
   -----------

   procedure Fetch
     (Repo      : String;
      File_Name : String;
      Dest_Path : String;
      Ok        : out Boolean;
      Reason    : out Model_Runner.Text.Bounded)
   is
      Outcome : HC.Download_Result;
      Options : HC.Download_Options := HC.Default_Download_Options;
      Status  : HE.Result_Status;
   begin
      Ok := False;
      Reason := T.Empty;

      --  No size cap, since a model is larger than the in-memory default;
      --  the parents are made; a non-success status is a failure rather
      --  than a saved error page.
      Options.Max_Download_Size := 0;
      Options.Create_Parent_Dirs := True;
      Options.Require_Success_Status := True;

      Status := HC.Download_To_File
        (URL           => Host & "/" & Repo & "/resolve/main/" & File_Name,
         Path          => Dest_Path,
         Result        => Outcome,
         Options       => Options,
         Configuration => Client_For);

      if HE.Is_Success (Status) then
         Ok := True;
      else
         Reason := T.To_Bounded
           ("the download failed (" & HE.Result_Status'Image (Status)
            & ", HTTP" & Natural'Image (Outcome.HTTP_Status_Code) & ")");
      end if;
   end Fetch;

end Model_Runner.Hub;
