with Model_Runner.Platform;
with Model_Runner.Drafts;
with Model_Runner.Draft_Policy;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Directories;

with Host_Load;
with Ada.Real_Time;

with Model_Runner.Backend.CPU;
with Model_Runner.CLI.Execute;
with Model_Runner.Backend.Device;
with Model_Runner.Clocks;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.GGUF.Shards;
with Model_Runner.Limits;
with Model_Runner.Output;
with Model_Runner.Stops;
with Model_Runner.Text;

with Project_Tools.Files;

package body Speed_Run is

   package Draft_Policy renames Model_Runner.Draft_Policy;

   package CPU renames Model_Runner.Backend.CPU;
   package IO renames Ada.Text_IO;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package Shards renames Model_Runner.GGUF.Shards;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package T renames Model_Runner.Text;

   use type Ada.Real_Time.Time;
   use type Interfaces.Unsigned_64;

   --  Generated text is not kept, but it is digested: the batch-size table
   --  publishes a column showing that --batch-size changes no output, and a
   --  claim like that belongs to whatever takes the measurement.
   --
   --  FNV-1a, which is not a checksum anybody should trust for anything
   --  else. It is here to notice a difference, not to resist one.
   type Discard is limited new Model_Runner.Output.Sink with record
      Hash : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   end record;

   overriding procedure Write
     (Self : in out Discard; Item : String; Closed : out Boolean);
   overriding procedure Flush (Self : in out Discard; Closed : out Boolean);
   overriding function Is_Closed (Self : Discard) return Boolean;

   --  The hash itself, so that the sink and the public digest below cannot
   --  drift apart.
   procedure Absorb (Into : in out Interfaces.Unsigned_64; Item : String) is
   begin
      for Index in Item'Range loop
         Into :=
           (Into xor Interfaces.Unsigned_64
                       (Character'Pos (Item (Index))))
           * 16#0000_0100_0000_01B3#;
      end loop;
   end Absorb;

   --  Sixteen hexadecimal digits, most significant first.
   function Shown (Value : Interfaces.Unsigned_64) return String is
      Figures : constant String := "0123456789abcdef";
      Room    : String (1 .. 16) := [others => '0'];
      Left    : Interfaces.Unsigned_64 := Value;
   begin
      for Place in reverse Room'Range loop
         Room (Place) := Figures (Figures'First + Natural (Left mod 16));
         Left := Left / 16;
      end loop;
      return Room;
   end Shown;

   function Digest_Of (Text : String) return String is
      Held : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      Absorb (Held, Text);
      return Shown (Held);
   end Digest_Of;

   overriding procedure Write
     (Self : in out Discard; Item : String; Closed : out Boolean) is
   begin
      Absorb (Self.Hash, Item);
      Closed := False;
   end Write;

   overriding procedure Flush (Self : in out Discard; Closed : out Boolean) is
      pragma Unreferenced (Self);
   begin
      Closed := False;
   end Flush;

   overriding function Is_Closed (Self : Discard) return Boolean is
      pragma Unreferenced (Self);
   begin
      return False;
   end Is_Closed;

   type Duration_Array is array (Positive range <>) of Duration;

   --  The middle value of a set of runs. A median rather than a mean because
   --  one run in a set occasionally meets something else on the machine, and
   --  a mean carries that into the published figure.
   function Middle (Values : Duration_Array) return Duration is
      Sorted : Duration_Array := Values;
   begin
      for Outer in Sorted'First .. Sorted'Last - 1 loop
         for Inner in Sorted'First .. Sorted'Last - 1 loop
            if Sorted (Inner) > Sorted (Inner + 1) then
               declare
                  Held : constant Duration := Sorted (Inner);
               begin
                  Sorted (Inner) := Sorted (Inner + 1);
                  Sorted (Inner + 1) := Held;
               end;
            end if;
         end loop;
      end loop;
      --  Of an even count, the two middle values' mean: the upper one alone
      --  published the slower of two runs -- the first, cold on a device.
      if Sorted'Length mod 2 = 0 then
         return (Sorted (Sorted'First + Sorted'Length / 2 - 1)
                 + Sorted (Sorted'First + Sorted'Length / 2)) / 2;
      end if;
      return Sorted (Sorted'First + Sorted'Length / 2);
   end Middle;

   ---------
   -- Run --
   ---------

   procedure Run
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Natural;
      Threads     : Positive;
      Batch       : Positive;
      Repack      : L.Repack_Mode;
      Cache       : L.Cache_Precision := L.Exact;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Penalty     : Model_Runner.Numerics.Real := 1.1;
      Draft       : String := "";
      Draft_Tokens : Natural := 4;
      Draft_Tokens_Set : Boolean := False;
      Draft_Lookup : Boolean := False;
      Draft_Next   : Boolean := False;
      Repeats     : Positive;
      Budget      : Boolean := False;
      Timeline    : Boolean := False;
      Context     : Natural := 0;
      Device_Bytes : Interfaces.Unsigned_64 := 0;
      Paged       : Boolean := False;
      Ignore_End  : Boolean := False;
      Draft_Floor : Model_Runner.Numerics.Real := 0.0;
      Draft_Adapts : Boolean := False;
      Result      : out Report;
      Turns       : String := "";
      Arithmetic  : String := "";
      Memory_Limit : Interfaces.Unsigned_64 := 0;
      No_Cache    : Boolean := False)
   is
      use type Model_Runner.Backend.Backend_Kind;

      --  A phase name in a fixed width, so the seconds line up.
      function Pad (Text : String) return String
      is (if Text'Length >= 14 then Text (Text'First .. Text'First + 13)
          else Text & [1 .. 14 - Text'Length => ' ']);

      procedure Say (Text : String) is
         Room : constant Natural :=
           Natural'Min (Text'Length, Result.Detail'Length);
      begin
         Result.Detail (1 .. Room) :=
           Text (Text'First .. Text'First + Room - 1);
         Result.Detail_Up := Room;
      end Say;

      Source    : Shards.Shard_Set;
      Container : Containers.Container;
      Engine    : L.Model;
      Status    : E.Error_Info;

      --  The draft, when one was named. Loaded exactly as the model is.
      Draft_Source    : Shards.Shard_Set;
      Draft_Container : Containers.Container;
      Draft_Engine    : aliased L.Model;
      Drafting        : Boolean := False;

      --  What was asked of drafting, read as the command reads it.
      Asked : constant Draft_Policy.Asked :=
        (Tokens      => Draft_Tokens,
         Tokens_Set  => Draft_Tokens_Set or else Draft_Next,
         Lookup      => Draft_Lookup,
         Model_Named => Draft /= "");
      Found_Draft : Ada.Strings.Unbounded.Unbounded_String;
      Lightened   : Boolean := False;

      function Draft_Path return String
      is (if Draft /= "" then Draft else Ada.Strings.Unbounded.To_String (Found_Draft));

      Walls     : Duration_Array (1 .. Repeats) := [others => 0.0];
      Spents    : Duration_Array (1 .. Repeats) := [others => 0.0];
      Evaluates : Duration_Array (1 .. Repeats) := [others => 0.0];
      Generates : Duration_Array (1 .. Repeats) := [others => 0.0];
   begin
      Result := (others => <>);
      Result.Load_Before := Host_Load.Now;
      Result.Warm_Before := Host_Load.Warmth;

      if Path = "" or else not Ada.Directories.Exists (Path) then
         Result.Missing := True;
         Say ("no model at that path; nothing measured");
         return;
      end if;

      if not Ada.Directories.Exists (Prompt_Path) then
         Result.Missing := True;
         Say ("no prompt file at that path; nothing measured");
         return;
      end if;

      declare
         --  As the command reads it, which means without the file's final
         --  line separator.
         --
         --  The command reads a prompt file line by line and puts the
         --  separators back between the lines, so a file written by an
         --  editor -- which ends in a newline nobody typed as part of the
         --  prompt -- reaches the model without it. Reading the same file
         --  raw here made this tool measure a prompt one token longer than
         --  the command's, which is how the README came to publish "the
         --  seven-token prompt" for a file the command tokenizes into six.
         --  A tool that exists so the figures are a command has to read
         --  what the command reads.
         --  Its lines, too, as the command reads them: a line ended the
         --  Windows way is a line without its carriage return.
         function As_Commanded (File : String := Prompt_Path) return String is
            Whole : constant String :=
              Project_Tools.Files.Read_Raw_File (File);
            Kept  : String (1 .. Whole'Length);
            Last  : Natural := 0;
         begin
            for Index in Whole'Range loop
               if Whole (Index) = ASCII.CR
                 and then (Index = Whole'Last
                           or else Whole (Index + 1) = ASCII.LF)
               then
                  null;
               else
                  Last := Last + 1;
                  Kept (Last) := Whole (Index);
               end if;
            end loop;

            if Last > 0 and then Kept (Last) = ASCII.LF then
               Last := Last - 1;
            end if;
            return Kept (1 .. Last);
         end As_Commanded;

         Prompt : constant String := As_Commanded;

         --  In turns, each pass one turn of a conversation held in one
         --  session: the prompt every turn file so far, in their names'
         --  order, so the session holds the turns before and reads only
         --  the new one -- what a conversation's warm turn costs, which a
         --  pass in a fresh session cannot say.
         Turning : constant Boolean := Turns /= "";

         function Turn_File (Index : Positive) return String is
            Names  : Ada.Strings.Unbounded.Unbounded_String;
            Search : Ada.Directories.Search_Type;
            Item   : Ada.Directories.Directory_Entry_Type;
            type Name_List is array (1 .. 256) of Ada.Strings.Unbounded.Unbounded_String;
            List  : Name_List;
            Count : Natural := 0;
         begin
            Ada.Directories.Start_Search
              (Search, Turns, "", [Ada.Directories.Ordinary_File => True, others => False]);
            while Ada.Directories.More_Entries (Search) and then Count < List'Last loop
               Ada.Directories.Get_Next_Entry (Search, Item);
               Count := Count + 1;
               List (Count) := Ada.Strings.Unbounded.To_Unbounded_String
                 (Ada.Directories.Full_Name (Item));
            end loop;
            Ada.Directories.End_Search (Search);
            for I in 2 .. Count loop
               for J in reverse 2 .. I loop
                  exit when Ada.Strings.Unbounded."<=" (List (J - 1), List (J));
                  Names := List (J);
                  List (J) := List (J - 1);
                  List (J - 1) := Names;
               end loop;
            end loop;
            --  As the command reads a prompt file: without its final line
            --  separator and its lines' carriage returns. Read raw, every
            --  turn carried a newline the command never sends.
            return (if Index <= Count
                    then As_Commanded
                           (Ada.Strings.Unbounded.To_String (List (Index)))
                    else "");
         end Turn_File;

         function Turn_Prompt (Pass : Positive) return String is
         begin
            if not Turning then
               return Prompt;
            elsif Pass = 1 then
               return Turn_File (1);
            else
               return Turn_Prompt (Pass - 1) & ASCII.LF & Turn_File (Pass);
            end if;
         end Turn_Prompt;

         --  The session limits run opens with: half the machine unless a
         --  limit is named, so a context left to the model's own is halved
         --  until it fits, as run's is.
         Bounds : constant Model_Runner.Limits.Session_Limits :=
           Model_Runner.CLI.Execute.Unasked_Session_Bounds (Memory_Limit);

         Shared_Session : aliased L.Session;
         Shared_Draft   : aliased L.Session;

         Started : Ada.Real_Time.Time;
         Spent_At : Long_Float := 0.0;
      begin
         --  Loading is timed and reported separately, which is what the
         --  README says of it: one figure is the model and the other is the
         --  disk.
         Started := Ada.Real_Time.Clock;
         Shards.Open_Model
           (Source, Container, Path, Status => Status);
         if E.Is_Error (Status) then
            Shards.Close (Source);
            Say ("the model would not open: "
                 & E.Error_Code'Image (Status.Code));
            return;
         end if;

         --  A device is opened before the model is prepared, because the
         --  preparation asks the backend what it can read and a device that
         --  is not there answers for nothing.
         if Backend = Model_Runner.Backend.Backend_Device then
            declare
               Ready : Boolean;
            begin
               Model_Runner.Backend.Device.Open (Ready, Device_Bytes);
               if not Ready then
                  Containers.Close (Container);
                  Shards.Close (Source);
                  Say ("no device answered");
                  return;
               end if;

               --  From here, so that the sequences a load runs -- a held
               --  stack is uploaded and not run, but a warm-up would be --
               --  are in the sums with the rest.
               Model_Runner.Backend.Device.Keep_Timeline (Timeline);
            end;
         end if;

         --  As run prepares it: its paging and panel cache, and refused
         --  for a budget it does not fit unless a budget was named.
         L.Prepare
           (Engine, Container, Source, Repack => Repack, Backend => Backend,
            Threads => Threads, Status => Status, Context => Context,
            Cache => Cache, Paged => Paged,
            Fit_Required => Device_Bytes = 0,
            Panel_Cache =>
              Model_Runner.CLI.Execute.Unasked_Panel_Cache (Path, No_Cache));
         if E.Is_Error (Status) then
            Containers.Close (Container);
            Shards.Close (Source);
            Say ("the model would not prepare: "
                 & E.Error_Code'Image (Status.Code));
            return;
         end if;
         Result.Load :=
           Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);

         --  The arithmetic, as run tells the backends once the model is
         --  prepared: the one named, or the one run takes for this model --
         --  Gemma 2's mixed one, where this tool measured every model in
         --  integers and Gemma 2's figures were of a run nobody starts.
         Model_Runner.CLI.Execute.Use_Arithmetic
           (Model_Runner.CLI.Execute.Unasked_Arithmetic (Arithmetic, Engine));

         --  A draft the run would take unasked: one the model names beside
         --  itself, else one found in the store or beside the model, as
         --  Draft_Policy has run look -- found, it is loaded as a named one
         --  is.
         if Draft = "" and then Draft_Policy.Seeks_Paired_Draft (Engine, Asked) then
            Found_Draft := Ada.Strings.Unbounded.To_Unbounded_String
              (Model_Runner.Drafts.Paired (Path, Model_Runner.Platform.Models_Directory));
         end if;
         if Draft = "" and then Ada.Strings.Unbounded.Length (Found_Draft) = 0 then
            declare
               Probe : L.Session;
               Local : E.Error_Info;
            begin
               L.Open (Probe, Engine, Context => Context, Status => Local, Paged => Paged,
                       Session_Bounds => Bounds);
               if E.Is_Ok (Local)
                 and then Draft_Policy.Seeks_Store_Draft (Engine, Probe, Asked)
               then
                  declare
                     Beside   : constant String :=
                       Ada.Directories.Containing_Directory (Ada.Directories.Full_Name (Path));
                     In_Store : constant String :=
                       Model_Runner.Drafts.Find
                         (Model_Runner.Platform.Models_Directory, Path, Container,
                          L.Vocabulary (Engine).all);
                     Near     : constant String :=
                       Model_Runner.Drafts.Find
                         (Beside, Path, Container, L.Vocabulary (Engine).all);
                     function Bytes (Name : String) return Long_Long_Integer
                     is (if Name = "" then 0 else Long_Long_Integer (Ada.Directories.Size (Name)));
                  begin
                     Found_Draft := Ada.Strings.Unbounded.To_Unbounded_String
                       (if Bytes (Near) > Bytes (In_Store) then Near else In_Store);
                  end;
               end if;
               if E.Is_Ok (Local) then
                  L.Close (Probe);
               end if;
            end;
         end if;

         --  And a draft, when one was named. The figures it produces are a
         --  comparison, so both halves belong to one command: this is the
         --  same run with --draft-model and without it.
         if Draft_Path /= "" then
            if not Ada.Directories.Exists (Draft_Path) then
               Say ("no draft model at that path; nothing measured");
               L.Close (Engine, Status);
               Containers.Close (Container);
               Shards.Close (Source);
               return;
            end if;

            Shards.Open (Draft_Source, Draft_Path, Status => Status);
            if E.Is_Error (Status) then
               Say ("the draft would not open: "
                    & E.Error_Code'Image (Status.Code));
               L.Close (Engine, Status);
               Containers.Close (Container);
               Shards.Close (Source);
               return;
            end if;

            Containers.Reader.Parse
              (Draft_Container, Draft_Source, Status => Status);
            if E.Is_Error (Status) then
               Say ("the draft would not parse: "
                    & E.Error_Code'Image (Status.Code));
               return;
            end if;

            --  As run prepares a draft: exactly as the model, with the
            --  context, cache and paging its session will hold.
            L.Prepare
              (Draft_Engine, Draft_Container, Draft_Source,
               Repack => Repack, Backend => Backend,
               Threads => Threads, Status => Status,
               Context => Context, Cache => Cache, Paged => Paged,
               Fit_Required => Device_Bytes = 0,
               Panel_Cache =>
                 Model_Runner.CLI.Execute.Unasked_Panel_Cache
                   (Draft_Path, No_Cache));
            if E.Is_Error (Status) then
               Say ("the draft would not prepare: "
                    & E.Error_Code'Image (Status.Code));
               return;
            end if;

            --  Its head at four bits, as the command takes it: a proposal
            --  is checked token by token, so this changes how many are kept
            --  and never what is written. A head that will not go stays as
            --  the file has it.
            declare
               Lighter : E.Error_Info;
            begin
               L.Lighten_Head (Draft_Engine, Threads, Lighter);
            end;

            Drafting := True;
         end if;

         declare
            --  The engine reports its own split between evaluating the
            --  prompt and generating, but only when it is given a clock to
            --  read; without one both figures come back zero, which is how
            --  the first run of this reported a wall of 1.3 s made of
            --  nothing.
            Timer : aliased Model_Runner.Clocks.System_Clock;
            Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));

            --  A pool wherever there is more than one worker to put in it,
            --  whichever backend answers. It used to be withheld from every
            --  backend but the processor, on the ground that the others do
            --  not partition a product -- which was true of the products
            --  and not of the run: normalizing a batch and joining its
            --  residuals are host loops over positions on any backend, and
            --  a device run left them on one core while the pool it was not
            --  given would have shared them out.
            Where : constant CPU.Pool_Reference :=
              (if Threads = 1 then null else Team'Unchecked_Access);

            --  What the device held while this was measured, around the
            --  same region the wall time is taken around. Only where the
            --  run is on a device: a processor figure has no such number
            --  and a watcher that read one anyway would be reporting a
            --  part that did nothing.
            Watching : constant Boolean :=
              Backend = Model_Runner.Backend.Backend_Device
              and then Device_Clock.Offered;

            Watch : Device_Clock.Watcher;
         begin
            Watch.Start (Watching);

            --  Held until a pass is actually running, so that what the
            --  reading answers about is the region the wall is taken
            --  around rather than the loading and the gaps between passes.
            Device_Clock.Sample (False);

            --  One pass before the timed ones, unless the passes are a
            --  conversation's turns, as llama-bench runs one: the first
            --  uploads the weights and builds the pipelines, and the
            --  second still ran warming. With three repeats the median was
            --  that second pass -- Mellum's prompt read 0.28 s there and
            --  0.25 s from the third on, 0.36 s with the machine busy --
            --  so the figure moved with how warm the part was, not with
            --  the engine. Round zero is that pass; it is written over.
            for Round in (if Turning then 1 else 0) .. Repeats loop
               declare
                  Pass        : constant Positive := Positive'Max (Round, 1);
                  Own_Session : aliased L.Session;
                  Own_Draft   : aliased L.Session;
                  Session_At  : constant access L.Session :=
                    (if Turning then Shared_Session'Access
                     else Own_Session'Access);
                  Draft_At    : constant access L.Session :=
                    (if Turning then Shared_Draft'Access
                     else Own_Draft'Access);
                  Session : L.Session renames Session_At.all;
                  Draft_Session : L.Session renames Draft_At.all;
                  --  A turn after the first goes on in the session the
                  --  first opened, and only the last turn closes it.
                  Opening : constant Boolean := not Turning or else Pass = 1;
                  Closing : constant Boolean :=
                    not Turning or else Pass = Repeats;
                  Stop    : Model_Runner.Stops.Set;
                  Sink    : aliased Discard;
                  Request : Gen.Request;
                  Outcome : Gen.Result;
                  Local   : E.Error_Info;
               begin
                  if Opening then
                     L.Open (Session, Engine, Context => Context,
                             Workers => Where, Cache => Cache, Status => Local,
                             Paged => Paged, Session_Bounds => Bounds);
                  end if;
                  if E.Is_Error (Local) then
                     Say ("the session would not open: "
                          & E.Error_Code'Image (Local.Code));
                     exit;
                  end if;

                  --  After Open, so that what a budget reports is this run
                  --  and not the buffers being made ready for it.
                  L.Account (Session, Budget);

                  if Drafting and then Opening then
                     --  As the command opens it: the same context, cache and
                     --  paging as the session it drafts for. Opened with the
                     --  model's own context, unpaged and in binary32, a
                     --  Qwen2.5 draft's 32,768 positions did not fit on the
                     --  device and its every layer attended on the host --
                     --  three submissions a layer where the command makes
                     --  one, and the tool measured drafting short.
                     L.Open (Draft_Session, Draft_Engine, Context => Context,
                             Workers => Where, Cache => Cache,
                             Status => Local, Paged => Paged,
                             Session_Bounds => Bounds);
                     exit when E.Is_Error (Local);
                  end if;

                  Model_Runner.Stops.Open (Stop);
                  Request.Max_Tokens := Tokens;
                  Request.Ignore_End := Ignore_End;
                  Request.Draft_Floor := Draft_Floor;
                  Request.Reuse_Committed_Prefix := Turning;

                  --  As the command sets it: a backend that does not batch
                  --  gets one, whatever was asked for. Passing the asked-for
                  --  size to a backend that refuses batches makes every
                  --  prefill fail, which is what happened here -- and the
                  --  report said "0 generated" and called itself a
                  --  measurement.
                  Request.Batch_Size :=
                    (if L.Capability (Engine).Supports_Batched
                     then Batch else 1);
                  --  What the published command asks for, which is the
                  --  defaults with the temperature set to zero -- not the
                  --  greedy configuration, which also turns off the
                  --  repetition penalty and the filters.
                  --
                  --  It was the greedy configuration, and that measured a
                  --  different sampler from the command this tool exists to
                  --  reproduce. Harmless while penalties did nothing at
                  --  temperature zero; not harmless since they started
                  --  working, because the command's default penalty of 1.1
                  --  over sixty-four tokens now changes which tokens come
                  --  out.
                  Request.Sampling.Temperature := 0.0;
                  Request.Sampling.Repeat_Penalty := Penalty;
                  Request.Seed := 1;
                  Request.Has_Seed := True;
                  Request.Add_Beginning := True;
                  --  Drafting as the command drafts, asked or not.
                  declare
                     Plan : constant Draft_Policy.Plan :=
                       Draft_Policy.Decide
                         (Engine, Session, Asked,
                          Draft_Ready  => Drafting,
                          Auto_Drafted => Drafting and then Draft = "");
                  begin
                     Request.Draft_Tokens := Plan.Tokens;
                     Request.Draft_From_Context := Plan.From_Context;
                     Request.Draft_From_Next := Plan.From_Next;
                     Request.Draft_Adapts := Draft_Adapts or else Plan.Adapts;
                     --  Readied for it as the command readies it.
                     if not Lightened then
                        Draft_Policy.Prepare
                          (Engine, Plan,
                           On_Device => Backend
                                        = Model_Runner.Backend.Backend_Device,
                           Threads   => Threads);
                        Lightened := True;
                     end if;
                  end;

                  --  Before the clock is read, because turning it on is
                  --  the only thing here that could cost the region it is
                  --  about.
                  --
                  --  And on the last pass only. What dilutes this
                  --  reading is inside the generation rather than around
                  --  it: the first pass uploads the weights and builds the
                  --  pipelines, and the part stands idle for most of that.
                  --  Counting every pass made the share depend on how many
                  --  repeats were asked for -- 31 per cent at one, 72 at
                  --  three, 86 at nine and 87 at fifteen, on a run whose
                  --  wall did not move -- so two figures taken with
                  --  different repeat counts could not be compared, and
                  --  comparing is the whole of what this number is for.
                  --
                  --  The last pass is warm whatever the count is, which
                  --  makes it the same measurement at three repeats and at
                  --  fifteen: 85, 88 and 89 across those, against 31 for a
                  --  single cold pass -- which, with the untimed pass
                  --  ahead of them, none of them now is.
                  Device_Clock.Sample (Round = Repeats);

                  Started := Ada.Real_Time.Clock;
                  Spent_At := Host_Load.Processor_Seconds;
                  Gen.Generate
                    (Engine, Session, Turn_Prompt (Pass), Request, Stop, null,
                     Sink'Unchecked_Access, null, Timer'Unchecked_Access,
                     null, null,
                     Draft =>
                       (if Drafting then Draft_Engine'Unchecked_Access
                        else null),
                     Draft_Session =>
                       (if Drafting then Draft_Session'Unchecked_Access
                        else null),
                     Outcome => Outcome);
                  Walls (Pass) :=
                    Ada.Real_Time.To_Duration
                      (Ada.Real_Time.Clock - Started);

                  Device_Clock.Sample (False);

                  --  Around the same region the wall is taken around, so
                  --  the two answer about the same work. Taken across the
                  --  whole run it would have counted loading the model and
                  --  the other repeats, which is what a caller reading "the
                  --  processor time of a twelve-token run" would not
                  --  expect.
                  Spents (Pass) :=
                    Duration (Host_Load.Processor_Seconds - Spent_At);

                  Evaluates (Pass) :=
                    Duration
                      (Long_Float (Outcome.Prefill_Ns)
                       / Long_Float
                           (Model_Runner.Clocks.Nanoseconds_Per_Second));
                  Generates (Pass) :=
                    Duration
                      (Long_Float (Outcome.Decode_Ns)
                       / Long_Float
                           (Model_Runner.Clocks.Nanoseconds_Per_Second));

                  Result.Digest := Shown (Sink.Hash);

                  --  A run that did not finish is not a figure. This
                  --  reported the wall time of a failure as though it were
                  --  the wall time of a run, and a reader comparing a
                  --  backend that failed against one that worked would have
                  --  read it as the fastest thing here.
                  if Gen."/=" (Outcome.Reason, Gen.Maximum_Tokens)
                    and then Gen."/=" (Outcome.Reason, Gen.End_Of_Sequence)
                    and then Gen."/=" (Outcome.Reason, Gen.Stop_Token)
                    and then Gen."/=" (Outcome.Reason, Gen.Stop_String)
                  then
                     Say ("the run did not finish: "
                          & E.Error_Code'Image (Outcome.Error.Code));
                     Model_Runner.Stops.Close (Stop);
                     if Drafting then
                        L.Close (Draft_Session);
                     end if;
                     L.Close (Session);
                     Gen.Release (Outcome);
                     exit;
                  end if;

                  if Turning then
                     IO.Put_Line
                       (IO.Standard_Error,
                        "  turn" & Natural'Image (Pass) & ":"
                        & Natural'Image (Outcome.Prompt_Tokens - Outcome.Reused_Tokens)
                        & " new prompt tokens of" & Natural'Image (Outcome.Prompt_Tokens)
                        & ", " & T.Image (Long_Float (Evaluates (Pass)), 3) & " s reading them, "
                        & Natural'Image (Outcome.Generated_Tokens) & " generated in "
                        & T.Image (Long_Float (Generates (Pass)), 3) & " s");
                  end if;

                  --  In turns, the tokens every turn read and wrote, summed,
                  --  over the time summed below: a median of turns of other
                  --  lengths divided into the last turn's tokens was a rate
                  --  of no turn. Each turn's own is the line above.
                  Result.Prompt :=
                    (if Turning
                     then (if Pass = 1 then 0 else Result.Prompt)
                          + Outcome.Prompt_Tokens - Outcome.Reused_Tokens
                     else Outcome.Prompt_Tokens);
                  Result.Produced :=
                    (if Turning
                     then (if Pass = 1 then 0 else Result.Produced)
                          + Outcome.Generated_Tokens
                     else Outcome.Generated_Tokens);
                  Result.Drafted := Outcome.Drafted;
                  Result.Accepted := Outcome.Accepted;
                  Result.Offered_At := Outcome.Offered_At;
                  Result.Kept_At := Outcome.Kept_At;
                  Result.Runs := Pass;

                  --  Where the time went, for the caller who asked. Written
                  --  as the run ends rather than kept, because a median of
                  --  three runs is what this tool publishes and a budget is
                  --  a description of one of them.
                  if Budget and then Round > 0 then
                     declare
                        Times : constant L.Phase_Times :=
                          L.Time_Spent (Session);
                        Total : Duration := 0.0;
                     begin
                        for Phase in L.Phase loop
                           Total := Total + Times (Phase);
                        end loop;

                        IO.Put_Line
                          (IO.Standard_Error,
                           "  where a prompt's time goes, run"
                           & Natural'Image (Pass));

                        for Phase in L.Phase loop
                           IO.Put_Line
                             (IO.Standard_Error,
                              "    " & Pad (L.Phase'Image (Phase))
                              & T.Image (Long_Float (Times (Phase)), 3)
                              & " s   "
                              & (if Total > 0.0
                                 then T.Image
                                        (Long_Float (Times (Phase))
                                         / Long_Float (Total) * 100.0, 1)
                                 else "-")
                              & " per cent of what is accounted for");
                        end loop;

                        IO.Put_Line
                          (IO.Standard_Error,
                           "    " & Pad ("ACCOUNTED FOR")
                           & T.Image (Long_Float (Total), 3) & " s");
                     end;
                  end if;

                  Model_Runner.Stops.Close (Stop);
                  if Closing then
                     if Drafting then
                        L.Close (Draft_Session);
                     end if;
                     L.Close (Session);
                  end if;
                  Gen.Release (Outcome);
               end;
            end loop;

            Watch.Stop (Result.Clock);

            CPU.Close (Team);
         exception
            --  Closed on the way out as well: a pool left open by an
            --  exception kept its workers waiting, and leaving the block
            --  waited on them for ever instead of saying what went wrong.
            when others =>
               CPU.Close (Team);
               raise;
         end;

         if Timeline and then Backend = Model_Runner.Backend.Backend_Device
         then
            IO.Put (IO.Standard_Error,
                    Model_Runner.Backend.Device.Timeline_Report);
            Model_Runner.Backend.Device.Keep_Timeline (False);
         end if;

         L.Close (Engine, Status);
         Containers.Close (Container);
         Shards.Close (Source);

         if Drafting then
            L.Close (Draft_Engine, Status);
            Containers.Close (Draft_Container);
            Shards.Close (Draft_Source);
         end if;
      end;

      Result.Load_After := Host_Load.Now;
      Result.Warm_After := Host_Load.Warmth;

      if Result.Runs = Repeats and then Turns /= "" then
         --  Turns are one conversation, not repeats of one run: their sums.
         Result.Ran := True;
         Result.Wall := 0.0;
         Result.Processor := 0.0;
         Result.Evaluate := 0.0;
         Result.Generate := 0.0;
         for Pass in Walls'Range loop
            Result.Wall := Result.Wall + Walls (Pass);
            Result.Processor := Result.Processor + Spents (Pass);
            Result.Evaluate := Result.Evaluate + Evaluates (Pass);
            Result.Generate := Result.Generate + Generates (Pass);
         end loop;
         Say ("measured");
      elsif Result.Runs = Repeats then
         Result.Ran := True;
         Result.Wall := Middle (Walls);
         Result.Processor := Middle (Spents);
         Result.Evaluate := Middle (Evaluates);
         Result.Generate := Middle (Generates);
         Say ("measured");
      elsif Result.Detail_Up > 0 then
         --  What stopped it, said where it stopped, rather than written
         --  over: this said only that a run had not completed, whatever
         --  the session or the generation had said why.
         Say ("a run did not complete, nothing published: "
              & Result.Detail (1 .. Result.Detail_Up));
      else
         Say ("a run did not complete; nothing published");
      end if;
   end Run;

   -------------
   -- Summary --
   -------------

   --  Each position's kept and offered counts, while any round offered
   --  one: " 40/50 30/48 ...".
   function Kept_By_Position (Item : Report) return String is
      Line : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Position in Item.Offered_At'Range loop
         exit when Item.Offered_At (Position) = 0;
         Ada.Strings.Unbounded.Append
           (Line, Natural'Image (Item.Kept_At (Position)) & "/"
                  & Ada.Strings.Fixed.Trim
                      (Natural'Image (Item.Offered_At (Position)),
                       Ada.Strings.Left));
      end loop;
      return Ada.Strings.Unbounded.To_String (Line);
   end Kept_By_Position;

   procedure Pool (Into : in out Report; Item : Report) is
   begin
      if not Item.Ran then
         return;
      end if;

      Into.Ran := True;
      Into.Runs := Into.Runs + 1;
      Into.Prompt := Into.Prompt + Item.Prompt;
      Into.Produced := Into.Produced + Item.Produced;
      Into.Generate := Into.Generate + Item.Generate;
      Into.Evaluate := Into.Evaluate + Item.Evaluate;
      Into.Drafted := Into.Drafted + Item.Drafted;
      Into.Accepted := Into.Accepted + Item.Accepted;
      for Position in Into.Offered_At'Range loop
         Into.Offered_At (Position) :=
           Into.Offered_At (Position) + Item.Offered_At (Position);
         Into.Kept_At (Position) :=
           Into.Kept_At (Position) + Item.Kept_At (Position);
      end loop;
   end Pool;

   function Pooled_Summary (Item : Report) return String is
      Shares : Ada.Strings.Unbounded.Unbounded_String;

      function Percent (Part, Whole : Natural) return String
      is (if Whole = 0 then "-"
          else T.Image (100.0 * Long_Float (Part) / Long_Float (Whole), 1)
               & "%");
   begin
      if not Item.Ran then
         return "pooled: nothing measured";
      end if;

      for Position in Item.Offered_At'Range loop
         exit when Item.Offered_At (Position) = 0;
         Ada.Strings.Unbounded.Append
           (Shares, " " & Percent (Item.Kept_At (Position),
                                   Item.Offered_At (Position)));
      end loop;

      return "pooled over" & Natural'Image (Item.Runs) & " prompts:"
        & Natural'Image (Item.Produced) & " generated in "
        & T.Image (Long_Float (Item.Generate), 3) & " s, "
        & (if Item.Generate > 0.0
           then T.Image (Long_Float (Item.Produced)
                         / Long_Float (Item.Generate), 2)
           else "-")
        & " tokens a second"
        & (if Item.Drafted = 0 then ""
           else "; proposed" & Natural'Image (Item.Drafted)
                & " accepted" & Natural'Image (Item.Accepted)
                & " (" & Percent (Item.Accepted, Item.Drafted) & ")"
                & "; kept/offered by position:" & Kept_By_Position (Item)
                & "; kept share by position:"
                & Ada.Strings.Unbounded.To_String (Shares));
   end Pooled_Summary;

   function Summary (Item : Report) return String is
      function Seconds (Value : Duration) return String
      is (T.Image (Long_Float (Value), 3) & " s");

      --  Tokens a second, as llama-bench says them, so a comparison is read
      --  rather than worked out: " (N t/s)", or nothing where no time was
      --  spent.
      function Rate (Tokens : Natural; Spent : Duration) return String
      is (if Tokens = 0 or else Spent <= 0.0 then ""
          else " (" & T.Image (Long_Float (Tokens) / Long_Float (Spent), 2) & " t/s)");
   begin
      if Item.Missing or else not Item.Ran then
         return Item.Detail (1 .. Item.Detail_Up);
      end if;

      return "median of" & Natural'Image (Item.Runs) & " runs: "
        & Natural'Image (Item.Prompt) & " prompt tokens,"
        & Natural'Image (Item.Produced) & " generated; "
        & Seconds (Item.Wall) & " wall -- "
        & Seconds (Item.Evaluate) & " evaluating the prompt"
        & Rate (Item.Prompt, Item.Evaluate) & " and "
        & Seconds (Item.Generate) & " generating"
        & Rate (Item.Produced, Item.Generate) & "; loading took "
        & Seconds (Item.Load) & "; output " & Item.Digest
        & (if Item.Drafted = 0 then ""
           else ", proposed" & Natural'Image (Item.Drafted)
                & " accepted" & Natural'Image (Item.Accepted)
                & " (kept/offered by position:" & Kept_By_Position (Item)
                & ")")
        & "; "
        & T.Image (Long_Float (Item.Processor), 2)
        & " s of processor time"
        & "; load " & T.Image (Item.Load_Before, 2)
        & " to " & T.Image (Item.Load_After, 2)
        & (if Item.Warm_Before < 0.0 then ""
           else "; " & T.Image (Item.Warm_Before, 1)
                & " to " & T.Image (Item.Warm_After, 1) & " degrees")
        & Device_Clock.Shown (Item.Clock);
   end Summary;
end Speed_Run;
