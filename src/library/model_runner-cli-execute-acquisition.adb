with Ada.Calendar;
with Ada.Directories;
with Ada.Text_IO;
with Interfaces;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Limits;
with Model_Runner.Platform;
with Model_Runner.Config;
with Model_Runner.Hub;
with Model_Runner.Hub.Store;
with Model_Runner.Templates;
with Model_Runner.Text;

package body Model_Runner.CLI.Execute.Acquisition is

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Byte_Sources.Files.Mapping_Policy;
   use type Model_Runner.CLI.Options.Text_Access;
   use type Model_Runner.CLI.Options.Verbosity;
   use type L.Repack_Mode;

   --  Load and validate a container, and prepare a model when asked.
   --  Whether a downloaded file is whole: it is there, and its size is the
   --  one the hub gave. The hub writes a download to a part beside it and
   --  gives it the file's name only once its digest is checked, so a file
   --  at the name arrived whole; the size still turns away one put there
   --  some other way at the wrong length. An unknown size (zero) falls back
   --  to its being there at all.
   function Model_Complete
     (File : Model_Runner.Hub.Download_File; Path : String) return Boolean
   is
      use type Ada.Directories.File_Size;
   begin
      return Ada.Directories.Exists (Path)
        and then
          (File.Size = 0
           or else Ada.Directories.Size (Path)
                   = Ada.Directories.File_Size (File.Size))
        and then Model_Runner.Hub.Is_Whole (File, Path);
   exception
      when others =>
         return False;
   end Model_Complete;

   --  A download's progress, painted on one line of standard error at the
   --  terminal a download is offered at. The hub reaches no terminal and
   --  hands the numbers here, where this layer paints them; the state sits
   --  at package level because a progress callback carries none, and one
   --  download runs at a time.
   Download_Start   : Ada.Calendar.Time := Ada.Calendar.Clock;
   Download_Base    : Interfaces.Unsigned_64 := 0;
   Download_Based   : Boolean := False;
   Download_Painted : Boolean := False;

   --  An unsigned number without the space Image leads with.
   function Image_U64 (Value : Interfaces.Unsigned_64) return String is
      Raw : constant String := Interfaces.Unsigned_64'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image_U64;

   --  A byte count as gigabytes to two decimals, in integers so no float is
   --  formatted: 1_070_000_000 reads "1.07".
   function Giga_U64 (Bytes : Interfaces.Unsigned_64) return String is
      Cents : constant Interfaces.Unsigned_64 := Bytes / 10_000_000;
   begin
      return Image_U64 (Cents / 100) & "."
        & Character'Val (Character'Pos ('0') + Natural (Cents mod 100 / 10))
        & Character'Val (Character'Pos ('0') + Natural (Cents mod 100 mod 10));
   end Giga_U64;

   --  Repaint the download's progress on one line of standard error: the
   --  percentage where a total is known, the gigabytes so far of the whole,
   --  and the rate. A carriage return and no newline, so it overwrites in
   --  place. Handed to the hub as its reporter.
   procedure Report_Download
     (Written : Interfaces.Unsigned_64;
      Total   : Interfaces.Unsigned_64)
   is
      use type Ada.Calendar.Time;
      Elapsed_Ms : constant Long_Long_Integer :=
        Long_Long_Integer ((Ada.Calendar.Clock - Download_Start) * 1000);
      Percent : constant String :=
        (if Total > 0 then Image_U64 (Written * 100 / Total) & "%" else "--");
      Total_Text : constant String :=
        (if Total > 0 then Giga_U64 (Total) else "?");
      Since : Interfaces.Unsigned_64;
   begin
      if not Download_Based then
         Download_Base  := Written;
         Download_Based := True;
      end if;
      Since :=
        (if Written >= Download_Base then Written - Download_Base else 0);

      declare
         Ms : constant Interfaces.Unsigned_64 :=
           Interfaces.Unsigned_64 (Long_Long_Integer'Max (1, Elapsed_Ms));
         Tenths : constant Interfaces.Unsigned_64 := Since / (100 * Ms);
         Rate   : constant String :=
           (if Elapsed_Ms > 0
            then Image_U64 (Tenths / 10) & "."
                 & Character'Val
                     (Character'Pos ('0') + Natural (Tenths mod 10))
                 & " MB/s"
            else "");
      begin
         Ada.Text_IO.Put
           (Ada.Text_IO.Standard_Error,
            ASCII.CR & "downloading  " & Percent & "   "
            & Giga_U64 (Written) & " / " & Total_Text & " GB   "
            & Rate & "          ");
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Error);
         Download_Painted := True;
      end;
   exception
      when others =>
         null;
   end Report_Download;

   --  The bytes the chunks of a ranged fetch beside a part already hold:
   --  had, as the part is, by the next fetch, which keeps the whole ones.
   function Chunks_Beside (Part : String) return Interfaces.Unsigned_64 is
      use Ada.Directories;
      Search : Search_Type;
      Item   : Directory_Entry_Type;
      Total  : Interfaces.Unsigned_64 := 0;
   begin
      if not Exists (Containing_Directory (Part)) then
         return 0;
      end if;
      Start_Search
        (Search, Containing_Directory (Part), Simple_Name (Part) & ".range-*",
         [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         Total := Total + Interfaces.Unsigned_64 (Size (Item));
      end loop;
      End_Search (Search);
      return Total;
   exception
      when others =>
         return Total;
   end Chunks_Beside;

   --  Offer to download a model named as a Hugging Face reference the local
   --  search did not find, and, where the user takes the offer, fetch it
   --  into the models directory. A model split into shards is fetched
   --  whole, and a fetch that stops part way -- a dropped link, a Ctrl-C --
   --  leaves what came on disk, so a run of the same reference resumes: the
   --  files already whole are skipped and the part is continued. Fetched is
   --  true with Where the first file's local path only when the whole model
   --  is on disk; every other outcome -- no one match, no models directory,
   --  no terminal to ask at, a declined offer, a stopped fetch -- leaves it
   --  false and says on the console what it did.
   procedure Offer_Download
     (Screen  : in out Pres.Console;
      Named   : String;
      Fetched : out Boolean;
      Where   : out Model_Runner.Text.Bounded)
   is
      Repo, Reason : Model_Runner.Text.Bounded;
      Files : Model_Runner.Hub.File_Set;
      Count : Natural := 0;
      Ok : Boolean;
      Dir : constant String := Model_Runner.Platform.Models_Directory;

      --  The names the files are kept under within the models directory:
      --  each its own, or owner/repo/ and it where another repository's
      --  file has the name (Hub.Store.Place).
      Locals : Model_Runner.Hub.Store.Local_Names := [others => T.Empty];

      function Local (Index : Positive) return String
      is (Model_Runner.Platform.Models_File (T.To_String (Locals (Index))));

      function Destination return String is (Local (1));

      --  Every file there and whole.
      function All_Whole return Boolean is
      begin
         for I in 1 .. Count loop
            if not Model_Complete (Files (I), Local (I)) then
               return False;
            end if;
         end loop;
         return Count > 0;
      end All_Whole;
   begin
      Fetched := False;
      Where   := Model_Runner.Text.Empty;

      --  A reference fetched before and whole on disk is opened as it is,
      --  from what the manifest says it was fetched as -- without asking
      --  the hub, so a model downloaded once runs offline.
      if Dir /= "" then
         declare
            Found : Boolean;
         begin
            Model_Runner.Hub.Store.Find (Dir, Named, Repo, Files, Locals, Count, Found);
            if Found and then All_Whole then
               Where   := Model_Runner.Text.To_Bounded (Destination);
               Fetched := True;
               return;
            end if;
            Count := 0;
         end;
      end if;

      --  A reference names its quant; a bare repository lets the machine's
      --  memory choose one -- two thirds of it, the room a model may take.
      if Model_Runner.Hub.Is_Reference (Named) then
         Model_Runner.Hub.Resolve (Named, Repo, Files, Count, Ok, Reason);
      else
         Model_Runner.Hub.Pick
           (Named, Model_Runner.Platform.Physical_Memory * 2 / 3,
            Repo, Files, Count, Ok, Reason);
      end if;
      if not Ok then
         Pres.Put_Note
           (Screen, "cli.download.unresolved",
            [Loc.Named ("detail", T.To_String (Reason))]);
         return;
      end if;

      if Dir = "" then
         Pres.Put_Note (Screen, "cli.download.no_directory");
         return;
      end if;
      for I in 1 .. Count loop
         Locals (I) := T.To_Bounded
           (Model_Runner.Hub.Store.Place
              (Dir, T.To_String (Repo), T.To_String (Files (I).Name)));
      end loop;

      --  Already here whole from an earlier run: every file present and the
      --  right size, so the set is opened by its first without asking or
      --  downloading again -- and noted, for the next run to find offline.
      if All_Whole then
         Model_Runner.Hub.Store.Note (Dir, Named, T.To_String (Repo), Files, Locals, Count);
         Where   := Model_Runner.Text.To_Bounded (Destination);
         Fetched := True;
         return;
      end if;

      --  Room for what is not yet here, checked before a byte is fetched
      --  rather than found halfway through a write that then stops. What a
      --  file still needs is its size less the part already on disk; the
      --  volume the models directory sits on is asked how much it has free.
      --  Zero free is the host declining to say, and the check is skipped
      --  then -- a stalled write still reports itself.
      declare
         Needed : Interfaces.Unsigned_64 := 0;
         Free   : constant Interfaces.Unsigned_64 :=
           Model_Runner.Platform.Free_Disk_Space (Destination);

         --  A byte count as gigabytes to two decimals, in integers so no
         --  float is formatted.
         function Giga (Bytes : Interfaces.Unsigned_64) return String is
            Cents : constant Interfaces.Unsigned_64 := Bytes / 10_000_000;
            Whole : constant Interfaces.Unsigned_64 := Cents / 100;
            Frac  : constant Interfaces.Unsigned_64 := Cents mod 100;
            Shown : constant String :=
              Interfaces.Unsigned_64'Image (Whole);
         begin
            return Shown (Shown'First + 1 .. Shown'Last) & "."
              & Character'Val (Character'Pos ('0') + Natural (Frac / 10))
              & Character'Val (Character'Pos ('0') + Natural (Frac mod 10))
              & " GB";
         end Giga;
      begin
         for I in 1 .. Count loop
            declare
               On_Disk : Interfaces.Unsigned_64 := 0;
            begin
               --  What is had: the whole file where it is there whole, else
               --  the part a stopped fetch left beside it, which is what the
               --  next one resumes. A file of the wrong size at the name is
               --  had by nothing: the fetch puts the checked one over it.
               if Model_Complete (Files (I), Local (I)) then
                  On_Disk := Files (I).Size;
               elsif Ada.Directories.Exists (Local (I) & ".part") then
                  On_Disk := Interfaces.Unsigned_64'Min
                    (Files (I).Size,
                     Interfaces.Unsigned_64 (Ada.Directories.Size (Local (I) & ".part"))
                     + Chunks_Beside (Local (I) & ".part"));
               end if;
               if Files (I).Size > On_Disk then
                  Needed := Needed + (Files (I).Size - On_Disk);
               end if;
            end;
         end loop;

         --  Headroom over the bytes themselves: a ranged fetch joins its
         --  chunks onto the part, so the disk holds the whole file and the
         --  chunk being added at once, and a little more for the file
         --  system and anything else the machine is writing meanwhile.
         if Free > 0 and then Needed > 0
           and then Free < Needed + Model_Runner.Hub.Join_Headroom
         then
            Pres.Put_Note
              (Screen, "cli.download.no_space",
               [Loc.Named
                  ("detail",
                   Giga (Needed) & " needed, " & Giga (Free) & " free in "
                   & Model_Runner.Platform.Models_Directory)]);
            return;
         end if;
      end;

      --  Asked only at a terminal: a piped run has no one to answer and its
      --  input is the prompt, not a yes.
      if not Model_Runner.Platform.Is_Terminal (0) then
         Pres.Put_Note (Screen, "cli.download.declined");
         return;
      end if;

      Pres.Put_Note
        (Screen, "cli.download.offer",
         [Loc.Named ("name", Named),
          Loc.Named
            ("detail",
             (if Count <= 1 then T.To_String (Files (1).Name)
              else T.To_String (Files (1).Name) & " and"
                   & Natural'Image (Count - 1) & " more shards")
             & " from huggingface.co/" & T.To_String (Repo)
             & " into " & Model_Runner.Platform.Models_Directory)]);

      declare
         Line : String (1 .. 256);
         Last : Natural := 0;
      begin
         begin
            Ada.Text_IO.Get_Line (Line, Last);
         exception
            when Ada.Text_IO.End_Error =>
               Last := 0;
         end;
         if Last < 1
           or else not (Line (1) = 'y' or else Line (1) = 'Y')
         then
            Pres.Put_Note (Screen, "cli.download.declined");
            return;
         end if;
      end;

      for I in 1 .. Count loop
         if not Model_Complete (Files (I), Local (I)) then
            Pres.Put_Note
              (Screen, "cli.download.fetching",
               [Loc.Named ("name", T.To_String (Files (I).Name))]);

            Download_Start   := Ada.Calendar.Clock;
            Download_Based   := False;
            Download_Painted := False;
            Model_Runner.Hub.Fetch
              (T.To_String (Repo), Files (I), Local (I), Ok, Reason,
               Report => Report_Download'Access);

            --  End the progress line the reporter left without a newline.
            if Download_Painted then
               Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Error);
            end if;

            if not Ok then
               --  In the colour of something gone wrong.
               Pres.Put_Aside_Marked
                 (Screen, "diagnostic.note",
                  [Loc.Named ("detail", Pres.Next_Step_Value (Screen, "cli.download.failed",
                                                            [Loc.Named ("detail", T.To_String (Reason))]))],
                  Pres.Next_Step_Value (Screen, "cli.download.failed",
                                      [Loc.Named ("detail", T.To_String (Reason))]),
                  Pres.Bad);
               return;
            end if;
         end if;
      end loop;

      Model_Runner.Hub.Store.Note (Dir, Named, T.To_String (Repo), Files, Locals, Count);
      Pres.Put_Aside_Marked
        (Screen, "diagnostic.note",
         [Loc.Named ("detail", Pres.Next_Step_Value (Screen, "cli.download.saved",
                                                   [Loc.Named ("detail", Destination)]))],
         Pres.Next_Step_Value (Screen, "cli.download.saved", [Loc.Named ("detail", Destination)]),
         Pres.Good);
      Where   := Model_Runner.Text.To_Bounded (Destination);
      Fetched := True;
   end Offer_Download;

   --  A model named by an alias in the settings file becomes what the
   --  alias stands for -- a reference or a path -- so a run of `tiny` runs
   --  whatever alias.tiny names. A name with no such alias is itself.
   function Resolve_Alias (Named : String) return String
   is (if Model_Runner.Config.Has ("alias." & Named)
       then Model_Runner.Config.Value ("alias." & Named)
       else Named);

   procedure Load
     (Item      : Opt.Command;
      Screen    : in out Pres.Console;
      Source    : in out Shards.Shard_Set;
      Container : in out Containers.Container;
      Prepared  : in out L.Model;
      Full      : Boolean;
      Observer  : Model_Runner.Progress.Observer_Reference;
      Cancel    : Model_Runner.Cancellation.Token_Reference;
      Status    : out E.Error_Info;

      --  Which file to load, for the caller that wants a second model: the
      --  draft is loaded exactly as the model is, with the same limits and
      --  the same refusals, and differs only in which path it reads.
      Instead   : String := "")
   is
      Bounds : constant Model_Runner.Limits.Model_Limits := Model_Bounds (Item);
      Named  : constant String :=
        Resolve_Alias
          (if Instead = "" then T.To_String (Item.Model_Path) else Instead);
      Path   : constant String :=
        Model_Runner.Platform.Resolve_Model_Path (Named);

      --  Where the weights written in panels are kept between loads, keyed
      --  by the file and what says it is unchanged -- its size and when it
      --  was last written -- unless the caller opted out of caches.
      function Panel_Path return String
      is (Panel_Cache_For (Path, Item.No_Cache));
   begin
      --  A model named for the Hugging Face hub and not on disk: the user
      --  is offered its download, and where they take it the fetched file
      --  is opened in its place. Only the model a run is for, not a draft
      --  or an embedder loaded beside it (Instead names those), so a hub
      --  reference reaches the network once and by the user's leave.
      if Instead = ""
        and then not Ada.Directories.Exists (Path)
        and then (Model_Runner.Hub.Is_Reference (Named)
                  or else Model_Runner.Hub.Is_Repo (Named))
      then
         declare
            Fetched : Boolean := False;
            Where   : Model_Runner.Text.Bounded;
         begin
            Offer_Download (Screen, Named, Fetched, Where);
            if Fetched then
               Load (Item, Screen, Source, Container, Prepared, Full,
                     Observer, Cancel, Status,
                     Instead => T.To_String (Where));
               return;
            end if;
         end;
      end if;
      Model_Runner.Progress.Publish
        (Observer,
         Model_Runner.Progress.Load_Progress
           (Model_Runner.Progress.Opening_Model));

      Shards.Open_Model
        (Source, Container, Path, Item.Mapping, Bounds, Cancel, Observer,
         Status);
      if E.Is_Error (Status) then
         return;
      end if;

      if Item.Mapping = Files.Mapping_Automatic
        and then not Shards.Is_Mapped (Source)
        and then Item.Level = Opt.Verbose
      then
         Pres.Warn (Screen, "warning.mapping_unavailable");
      end if;

      --  A model in several files, said once where a caller asked to be
      --  told things. Nothing after this point knows the difference.
      if Shards.Parts (Source) > 1 and then Item.Level = Opt.Verbose then
         Pres.Put_Note
           (Screen, "cli.note.model_in_shards",
            [Loc.Named
               ("count",
                T.Image (Long_Long_Integer (Shards.Parts (Source))))]);
      end if;

      if Full then
         --  An adapter is merged into the weights, and only binary32 ones
         --  can be added to, so naming one selects that repacking where the
         --  caller named none. The help says so where the option is
         --  documented: it costs four bytes a weight, which is the same
         --  bargain --repack f32 already publishes.
         L.Prepare
           (Prepared, Container, Source, Bounds, Cancel, Observer,
            Item.Backend,
            (if Item.Repack = L.No_Repack
               and then not T.Is_Empty (Item.Adapter_Path)
             then L.To_F32
             else Item.Repack),

            --  A caller who named --device-memory has been told what the
            --  device has and said what to use anyway, so a model larger
            --  than that is run rather than refused. What it costs is
            --  reported: the statistics say how many matrices were given
            --  back, which is how many were uploaded again.
            Fit_Required => not Item.Device_Memory_Set,
            Threads      => Selected_Workers (Item),
            Status       => Status,
            Stretch      => Asked_Rotation (Item),
            Panel_Cache  => Panel_Path,
            Context      => Item.Context_Size,
            Cache        => Item.Cache,
            Paged        => Session_Paging (Item));

         --  A chat format named on the command line replaces the model's
         --  own, and whatever Prepare chose. Nothing here guesses a format
         --  from the model's name, because a chat format applied to the
         --  wrong model produces output that looks entirely reasonable and
         --  is not what the model was trained on. What Prepare may do is
         --  narrower: when the model's own template will not compile but
         --  its text is written in a carried format, that format stands
         --  in -- and a caller who asked to be told things is told.
         if E.Is_Ok (Status)
           and then not Model_Runner.Text.Is_Empty (Item.Chat_Template_Path)
         then
            --  A template read from a file, for one this build carries no
            --  name for. Its source is compiled and validated exactly as a
            --  named format's is, so an unusable file is refused rather than
            --  stored. Where both this and a named format were given, the
            --  file is the one used.
            declare
               Path : constant String :=
                 Model_Runner.Text.To_String (Item.Chat_Template_Path);
               Source  : Opt.Text_Access;
               Reading : E.Error_Info;
            begin
               Read_File
                 (Path,
                  Model_Runner.Limits.Default_Session_Limits.Max_Prompt_Bytes,
                  Source, Reading);
               if E.Is_Error (Reading) then
                  Status := Reading;
               else
                  L.Use_Template (Prepared, Source.all, Bounds, Status);
               end if;
               if Source /= null then
                  Free_Text (Source);
               end if;
            end;
         elsif E.Is_Ok (Status)
           and then not Model_Runner.Text.Is_Empty (Item.Chat_Template)
         then
            L.Use_Template
              (Prepared,
               Model_Runner.Templates.Built_In
                 (Model_Runner.Text.To_String (Item.Chat_Template)),
               Bounds, Status,
               Name => Model_Runner.Text.To_String (Item.Chat_Template));
         elsif E.Is_Ok (Status)
           and then L.Template_Stood_In (Prepared)
           and then Item.Level = Opt.Verbose
           and then not Item.Raw
         then
            Pres.Put_Note
              (Screen, "cli.note.template_stood_in",
               [Loc.Named ("name", L.Template_Format (Prepared))]);
         end if;
      end if;
   end Load;

end Model_Runner.CLI.Execute.Acquisition;
