with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Text_IO;

with Http_Client.Clients;
with Http_Client.Errors;
with Http_Client.Headers;

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

   -------------------
   -- Is_Reference --
   -------------------

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

   --  A client configured to carry the hub token where the environment has
   --  one, so a gated repository is reached. A token that is not a valid
   --  header value is left off rather than raised on.
   function Client_For return HC.Client_Configuration is
      Config : HC.Client_Configuration := HC.Default_Client_Configuration;
      Env_Token : constant String :=
        Model_Runner.Platform.Environment_Value ("HF_TOKEN");
      Token  : constant String :=
        (if Env_Token /= "" then Env_Token
         else Model_Runner.Config.Value ("hf-token"));
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

      Status := HC.Get
        (URL           => Host & "/api/models/" & T.To_String (Repo)
                          & "?blobs=true",
         Result        => Result,
         Configuration => Client_For);

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

      Status := HC.Get
        (URL           => Host & "/api/models/" & Reference & "?blobs=true",
         Result        => Result,
         Configuration => Client_For);

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

   --  The download's progress, kept at package level because the client's
   --  callback is a plain access-to-function with nowhere to carry state.
   --  One download runs at a time, from one task, as the package says.
   Progress_Started : Ada.Calendar.Time := Ada.Calendar.Clock;
   Progress_Base    : Interfaces.Unsigned_64 := 0;
   Progress_Based   : Boolean := False;

   --  An unsigned number without the space Image leads with.
   function Image (Value : Interfaces.Unsigned_64) return String is
      Raw : constant String := Interfaces.Unsigned_64'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   --  A byte count as gigabytes to two decimals, in integers so no float is
   --  formatted: 1_070_000_000 reads "1.07".
   function Giga (Bytes : Interfaces.Unsigned_64) return String is
      Cents : constant Interfaces.Unsigned_64 := Bytes / 10_000_000;
      Whole : constant Interfaces.Unsigned_64 := Cents / 100;
      Frac  : constant Interfaces.Unsigned_64 := Cents mod 100;
   begin
      return Image (Whole) & "."
        & Character'Val (Character'Pos ('0') + Natural (Frac / 10))
        & Character'Val (Character'Pos ('0') + Natural (Frac mod 10));
   end Giga;

   --  A rate as megabytes a second to one decimal, from the bytes since the
   --  download's start and the milliseconds since. Integers throughout.
   function Speed_MBps
     (Bytes : Interfaces.Unsigned_64; Elapsed_Ms : Long_Long_Integer)
      return String
   is
      Ms     : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Long_Long_Integer'Max (1, Elapsed_Ms));
      Tenths : constant Interfaces.Unsigned_64 := Bytes / (100 * Ms);
   begin
      return Image (Tenths / 10) & "."
        & Character'Val (Character'Pos ('0') + Natural (Tenths mod 10))
        & " MB/s";
   end Speed_MBps;

   --  Repaint the download's progress on one line of standard error: the
   --  percentage where a total is known, the gigabytes so far of the whole,
   --  and the rate. A carriage return and no newline, so it overwrites in
   --  place at the terminal a download is offered at.
   function Show_Progress
     (Bytes_Written : Interfaces.Unsigned_64;
      Total_Bytes   : Interfaces.Unsigned_64)
      return Http_Client.Errors.Result_Status
   is
      use type Ada.Calendar.Time;
      Elapsed_Ms : constant Long_Long_Integer :=
        Long_Long_Integer ((Ada.Calendar.Clock - Progress_Started) * 1000);
      Since      : Interfaces.Unsigned_64;
      Percent    : constant String :=
        (if Total_Bytes > 0
         then Image (Bytes_Written * 100 / Total_Bytes) & "%"
         else "--");
      Total_Text : constant String :=
        (if Total_Bytes > 0 then Giga (Total_Bytes) else "?");
   begin
      if not Progress_Based then
         Progress_Base  := Bytes_Written;
         Progress_Based := True;
      end if;
      Since :=
        (if Bytes_Written >= Progress_Base
         then Bytes_Written - Progress_Base else 0);

      Ada.Text_IO.Put
        (Ada.Text_IO.Standard_Error,
         ASCII.CR & "downloading  " & Percent & "   "
         & Giga (Bytes_Written) & " / " & Total_Text & " GB   "
         & (if Elapsed_Ms > 0 then Speed_MBps (Since, Elapsed_Ms) else "")
         & "          ");
      Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
      return Http_Client.Errors.Ok;
   exception
      when others =>
         return Http_Client.Errors.Ok;
   end Show_Progress;

   -----------
   -- Fetch --
   -----------

   procedure Fetch
     (Repo      : String;
      File      : Download_File;
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

      --  A progress line as it runs: the client calls back every few
      --  megabytes, and the callback repaints one line of standard error.
      Progress_Started := Ada.Calendar.Clock;
      Progress_Based   := False;
      Options.Progress_Callback := Show_Progress'Access;
      Options.Progress_Interval_Bytes := 4 * 1024 * 1024;

      Status := HC.Download_To_File
        (URL           => Host & "/" & Repo & "/resolve/main/"
                          & T.To_String (File.Name),
         Path          => Dest_Path,
         Result        => Outcome,
         Options       => Options,
         Configuration => Client_For);

      --  End the progress line the callback left without a newline.
      if Progress_Based then
         Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
      end if;

      if HE.Is_Success (Status) then
         Ok := True;
         return;
      end if;

      --  A file left at or past its whole size on a failure is not a part
      --  to resume but a whole one the digest or the size check turned
      --  down; it is removed, so a run does not open it or a later fetch
      --  take it for done. A shorter part is left where it is to resume.
      if File.Size > 0
        and then Ada.Directories.Exists (Dest_Path)
        and then Interfaces.Unsigned_64 (Ada.Directories.Size (Dest_Path))
                 >= File.Size
      then
         begin
            Ada.Directories.Delete_File (Dest_Path);
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
         if Model_Runner.Platform.Environment_Value ("HF_TOKEN") /= ""
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
