with Ada.Text_IO;
with Ada.Directories;

with Host_Load;
with Interfaces;
with Ada.Real_Time;

with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Clocks;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Output;
with Model_Runner.Serving;
with Model_Runner.Stops;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

with Project_Tools.Files;

package body Speed_Run is

   package CPU renames Model_Runner.Backend.CPU;
   package IO renames Ada.Text_IO;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package Files renames Model_Runner.Byte_Sources.Files;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package Serving renames Model_Runner.Serving;
   package T renames Model_Runner.Text;
   package N renames Model_Runner.Numerics;
   package Vocab renames Model_Runner.Tokenizer;
   package Room_Of renames Model_Runner.Tensors;

   use type N.Element_Count;
   use type CPU.Pool_Reference;
   use type N.Real;
   use type Vocab.Token_Id;

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
      return Sorted (Sorted'First + Sorted'Length / 2);
   end Middle;

   ---------
   -- Run --
   ---------

   procedure Run
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Batch       : Positive;
      Repack      : L.Repack_Mode;
      Cache       : L.Cache_Precision := L.Exact;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Penalty     : Model_Runner.Numerics.Real := 1.1;
      Draft       : String := "";
      Draft_Tokens : Positive := 4;
      Repeats     : Positive;
      Budget      : Boolean := False;
      Result      : out Report)
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

      Source    : Files.File_Source;
      Container : Containers.Container;
      Engine    : L.Model;
      Status    : E.Error_Info;

      --  The draft, when one was named. Loaded exactly as the model is.
      Draft_Source    : Files.File_Source;
      Draft_Container : Containers.Container;
      Draft_Engine    : aliased L.Model;
      Drafting        : Boolean := False;

      Walls     : Duration_Array (1 .. Repeats) := [others => 0.0];
      Spents    : Duration_Array (1 .. Repeats) := [others => 0.0];
      Evaluates : Duration_Array (1 .. Repeats) := [others => 0.0];
      Generates : Duration_Array (1 .. Repeats) := [others => 0.0];
   begin
      Result := (others => <>);
      Result.Load_Before := Host_Load.Now;

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
         function As_Commanded return String is
            Whole : constant String :=
              Project_Tools.Files.Read_Raw_File (Prompt_Path);
         begin
            if Whole'Length > 0
              and then Whole (Whole'Last) = ASCII.LF
            then
               return Whole (Whole'First .. Whole'Last - 1);
            end if;
            return Whole;
         end As_Commanded;

         Prompt : constant String := As_Commanded;

         Started : Ada.Real_Time.Time;
         Spent_At : Long_Float := 0.0;
      begin
         --  Loading is timed and reported separately, which is what the
         --  README says of it: one figure is the model and the other is the
         --  disk.
         Started := Ada.Real_Time.Clock;
         Files.Open (Source, Path, Status => Status);
         if E.Is_Error (Status) then
            Say ("the model would not open: "
                 & E.Error_Code'Image (Status.Code));
            return;
         end if;

         Containers.Reader.Parse (Container, Source, Status => Status);
         if E.Is_Error (Status) then
            Files.Close (Source);
            Say ("the model would not parse: "
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
               Model_Runner.Backend.Device.Open (Ready);
               if not Ready then
                  Containers.Close (Container);
                  Files.Close (Source);
                  Say ("no device answered");
                  return;
               end if;
            end;
         end if;

         L.Prepare
           (Engine, Container, Source, Repack => Repack, Backend => Backend,
            Threads => Threads, Status => Status);
         if E.Is_Error (Status) then
            Containers.Close (Container);
            Files.Close (Source);
            Say ("the model would not prepare: "
                 & E.Error_Code'Image (Status.Code));
            return;
         end if;
         Result.Load :=
           Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);

         --  And a draft, when one was named. The figures it produces are a
         --  comparison, so both halves belong to one command: this is the
         --  same run with --draft-model and without it.
         if Draft /= "" then
            if not Ada.Directories.Exists (Draft) then
               Say ("no draft model at that path; nothing measured");
               L.Close (Engine, Status);
               Containers.Close (Container);
               Files.Close (Source);
               return;
            end if;

            Files.Open (Draft_Source, Draft, Status => Status);
            if E.Is_Error (Status) then
               Say ("the draft would not open: "
                    & E.Error_Code'Image (Status.Code));
               L.Close (Engine, Status);
               Containers.Close (Container);
               Files.Close (Source);
               return;
            end if;

            Containers.Reader.Parse
              (Draft_Container, Draft_Source, Status => Status);
            if E.Is_Error (Status) then
               Say ("the draft would not parse: "
                    & E.Error_Code'Image (Status.Code));
               return;
            end if;

            L.Prepare
              (Draft_Engine, Draft_Container, Draft_Source,
               Repack => Repack, Backend => Backend,
               Threads => Threads, Status => Status);
            if E.Is_Error (Status) then
               Say ("the draft would not prepare: "
                    & E.Error_Code'Image (Status.Code));
               return;
            end if;

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

            for Pass in 1 .. Repeats loop
               declare
                  Session : L.Session;
                  Draft_Session : aliased L.Session;
                  Stop    : Model_Runner.Stops.Set;
                  Sink    : aliased Discard;
                  Request : Gen.Request;
                  Outcome : Gen.Result;
                  Local   : E.Error_Info;
               begin
                  L.Open (Session, Engine, Workers => Where,
                          Cache => Cache, Status => Local);
                  exit when E.Is_Error (Local);

                  --  After Open, so that what a budget reports is this run
                  --  and not the buffers being made ready for it.
                  L.Account (Session, Budget);

                  if Drafting then
                     L.Open (Draft_Session, Draft_Engine, Workers => Where,
                             Status => Local);
                     exit when E.Is_Error (Local);
                  end if;

                  Model_Runner.Stops.Open (Stop);
                  Request.Max_Tokens := Tokens;

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
                  Request.Draft_Tokens :=
                    (if Drafting then Draft_Tokens else 0);

                  Started := Ada.Real_Time.Clock;
                  Spent_At := Host_Load.Processor_Seconds;
                  Gen.Generate
                    (Engine, Session, Prompt, Request, Stop, null,
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

                  Result.Prompt := Outcome.Prompt_Tokens;
                  Result.Produced := Outcome.Generated_Tokens;
                  Result.Drafted := Outcome.Drafted;
                  Result.Accepted := Outcome.Accepted;
                  Result.Runs := Pass;

                  --  Where the time went, for the caller who asked. Written
                  --  as the run ends rather than kept, because a median of
                  --  three runs is what this tool publishes and a budget is
                  --  a description of one of them.
                  if Budget then
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
                  if Drafting then
                     L.Close (Draft_Session);
                  end if;
                  L.Close (Session);
                  Gen.Release (Outcome);
               end;
            end loop;

            Watch.Stop (Result.Clock);

            CPU.Close (Team);
         end;

         L.Close (Engine, Status);
         Containers.Close (Container);
         Files.Close (Source);

         if Drafting then
            L.Close (Draft_Engine, Status);
            Containers.Close (Draft_Container);
            Files.Close (Draft_Source);
         end if;
      end;

      Result.Load_After := Host_Load.Now;

      if Result.Runs = Repeats then
         Result.Ran := True;
         Result.Wall := Middle (Walls);
         Result.Processor := Middle (Spents);
         Result.Evaluate := Middle (Evaluates);
         Result.Generate := Middle (Generates);
         Say ("measured");
      else
         Say ("a run did not complete; nothing published");
      end if;
   end Run;

   -------------
   -- Summary --
   -------------

   function Summary (Item : Report) return String is
      function Seconds (Value : Duration) return String
      is (T.Image (Long_Float (Value), 3) & " s");
   begin
      if Item.Missing or else not Item.Ran then
         return Item.Detail (1 .. Item.Detail_Up);
      end if;

      return "median of" & Natural'Image (Item.Runs) & " runs: "
        & Natural'Image (Item.Prompt) & " prompt tokens,"
        & Natural'Image (Item.Produced) & " generated; "
        & Seconds (Item.Wall) & " wall -- "
        & Seconds (Item.Evaluate) & " evaluating the prompt and "
        & Seconds (Item.Generate) & " generating; loading took "
        & Seconds (Item.Load) & "; output " & Item.Digest
        & (if Item.Drafted = 0 then ""
           else ", proposed" & Natural'Image (Item.Drafted)
                & " accepted" & Natural'Image (Item.Accepted))
        & "; "
        & T.Image (Long_Float (Item.Processor), 2)
        & " s of processor time"
        & "; load " & T.Image (Item.Load_Before, 2)
        & " to " & T.Image (Item.Load_After, 2)
        & Device_Clock.Shown (Item.Clock);
   end Summary;

   -----------
   -- Round --
   -----------

   procedure Serve
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Members     : Positive;
      Arrivals    : Positive;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU)
   is
      use type Model_Runner.Backend.Backend_Kind;
      use type Serving.Member_Id;

      Source    : aliased Files.File_Source;
      Container : Containers.Container;
      Engine    : aliased L.Model;
      Status    : E.Error_Info;

      function Said (Value : Duration) return String
      is (T.Image (Long_Float (Value), 3) & " s");

      procedure Say (Text : String);

      procedure Say (Text : String) is
      begin
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Text);
      end Say;
   begin
      if not Ada.Directories.Exists (Path) then
         Say ("no model at that path; nothing measured");
         return;
      end if;

      Files.Open (Source, Path, Status => Status);
      if E.Is_Error (Status) then
         Say ("the model would not open");
         return;
      end if;

      Containers.Reader.Parse (Container, Source, Status => Status);
      if E.Is_Error (Status) then
         Files.Close (Source);
         Say ("the model would not parse");
         return;
      end if;

      if Backend = Model_Runner.Backend.Backend_Device then
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Ready);
            if not Ready then
               Containers.Close (Container);
               Files.Close (Source);
               Say ("no device answered");
               return;
            end if;
         end;
      end if;

      L.Prepare
        (Engine, Container, Source, Backend => Backend,
         Threads => Threads, Status => Status);
      if E.Is_Error (Status) then
         Containers.Close (Container);
         Files.Close (Source);
         Say ("the model would not prepare");
         return;
      end if;

      declare
         Text : constant String :=
           (if Prompt_Path = "" then "The capital of France is"
            else Project_Tools.Files.Read_Raw_File (Prompt_Path));

         Held : Vocab.Token_Array (1 .. 4096);
         Last : Natural;

         Serve : Serving.Server (Capacity => Members);

         --  Every caller that will arrive, and which of them are in.
         Who   : array (1 .. Arrivals) of Serving.Member_Id :=
           [others => Serving.No_Member];
         Sent  : Natural := 0;

         Terms : Serving.Terms;

         Started  : Ada.Real_Time.Time;
         Spent    : Duration := 0.0;
         Produced : Natural := 0;
         Rounds   : Natural := 0;
         Smallest : Natural := Natural'Last;

         --  What the arriving costs, kept apart from what the rounds cost.
         --  A caller's prompt is read on its own, so a server whose members
         --  turn over spends part of its time on a pass no round divides,
         --  and the whole argument for reading several prompts together is
         --  the size of this number.
         Joining  : Duration := 0.0;
         Joined   : Natural := 0;

         --  A digest of every token every member was handed, in the order
         --  they were handed out, so that two backends can be held against
         --  each other as the round driver holds them.
         Mark : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;

         Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));
         Where : constant CPU.Pool_Reference :=
           (if Threads = 1 then null else Team'Unchecked_Access);

         --  And what the part was clocked at while it served, for the same
         --  reason the other two measurements carry it.
         Watching : constant Boolean :=
           Backend = Model_Runner.Backend.Backend_Device
           and then Device_Clock.Offered;

         Watch : Device_Clock.Watcher;
         Clock : Device_Clock.Reading;

         --  Take what a member has said, digest it, and let it go when it
         --  has finished. A seat given back is a seat the next caller in
         --  the queue takes, which is the whole of the policy being
         --  measured.
         procedure Collect (Slot : Positive);

         procedure Collect (Slot : Positive) is
            Got  : Vocab.Token_Array (1 .. 64);
            Made : Natural;
            Done : Boolean;
         begin
            Serving.Take (Serve, Who (Slot), Got, Made, Done);

            for Index in 1 .. Made loop
               Mark := Mark xor Interfaces.Unsigned_64 (Got (Index));
               Mark := Mark * 16#0000_0100_0000_01B3#;
            end loop;

            Produced := Produced + Made;

            if Done then
               Serving.Retire (Serve, Who (Slot));
               Who (Slot) := Serving.No_Member;
            end if;
         end Collect;
      begin
         Vocab.Encode
           (L.Vocabulary (Engine).all, Text,
            Add_Beginning => True, Add_End => False,
            Target => Held, Last => Last, Status => Status);

         if E.Is_Error (Status) or else Last = 0 then
            Say ("the prompt would not encode");
            L.Close (Engine, Status);
            Containers.Close (Container);
            Files.Close (Source);
            return;
         end if;

         --  Greedy, so that what a member says is a text and two backends
         --  can be compared by it.
         Terms.Sampling.Temperature := 0.0;
         Terms.Sampling.Repeat_Penalty := 1.0;

         Serving.Open
           (Serve, Engine, Workers => Where, Gather => Members,
            Status => Status);

         if E.Is_Error (Status) then
            Say ("the server would not open: "
                 & E.Error_Code'Image (Status.Code));
            L.Close (Engine, Status);
            Containers.Close (Container);
            Files.Close (Source);
            return;
         end if;

         Watch.Start (Watching);
         Started := Ada.Real_Time.Clock;

         --  Everything that fits, admitted; then one more for every one
         --  that leaves. Limits below the asked-for count as well, so the
         --  members end at different rounds and the server has to re-form.
         loop
            while Sent < Arrivals
              and then Serving.Serving (Serve) < Members
            loop
               Sent := Sent + 1;
               Terms.Limit :=
                 Natural'Max (1, Tokens - (Sent - 1) mod Members);

               declare
                  At_Join : constant Ada.Real_Time.Time :=
                    Ada.Real_Time.Clock;
               begin
                  Serving.Admit
                    (Serve, Held (1 .. Last), Terms, Who (Sent),
                     Status => Status);

                  Joining :=
                    Joining
                    + Ada.Real_Time.To_Duration
                        (Ada.Real_Time.Clock - At_Join);
                  Joined := Joined + 1;
               end;

               exit when E.Is_Error (Status);
            end loop;

            exit when E.Is_Error (Status);
            exit when Serving.Serving (Serve) = 0;

            Serving.Step (Serve, Status => Status);
            exit when E.Is_Error (Status);

            Rounds := Rounds + 1;
            Smallest := Natural'Min (Smallest, Serving.Gathered (Serve));

            for Slot in 1 .. Sent loop
               if Who (Slot) /= Serving.No_Member then
                  Collect (Slot);
               end if;
            end loop;
         end loop;

         Spent :=
           Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
         Watch.Stop (Clock);

         if E.Is_Error (Status) then
            Say ("serving failed: " & E.Error_Code'Image (Status.Code));
            for Frame in 1 .. Status.Frame_Total loop
               Say ("  " & Model_Runner.Text.To_String (Status.Frames (Frame)));
            end loop;
         else
            Say ("members" & Natural'Image (Members)
                 & ", callers" & Natural'Image (Arrivals)
                 & ", prompt" & Natural'Image (Last) & " tokens,"
                 & Natural'Image (Rounds) & " rounds in " & Said (Spent)
                 & " --" & Natural'Image (Produced) & " tokens, "
                 & Said (Spent / Duration (Natural'Max (Produced, 1)))
                 & " a token, smallest round"
                 & Natural'Image (Smallest)
                 & "; joining " & Said (Joining) & " over"
                 & Natural'Image (Joined) & " callers, "
                 & T.Image
                     (Long_Float (Joining)
                      / Long_Float (Natural'Max (Joined, 1)) * 1000.0, 1)
                 & " ms each; mark " & Shown (Mark)
                 & Device_Clock.Shown (Clock));
         end if;

         Serving.Close (Serve);

         if Where /= null then
            CPU.Close (Team);
         end if;
      end;

      L.Close (Engine, Status);
      Containers.Close (Container);
      Files.Close (Source);
   end Serve;

   procedure Round
     (Path        : String;
      Prompt_Path : String;
      Tokens      : Positive;
      Threads     : Positive;
      Members     : Positive;
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Budget      : Boolean := False)
   is
      use type Model_Runner.Backend.Backend_Kind;
      Source    : aliased Files.File_Source;
      Container : Containers.Container;
      Engine    : aliased L.Model;
      Status    : E.Error_Info;

      function Said (Value : Duration) return String
      is (T.Image (Long_Float (Value), 3) & " s");

      --  A phase's name in a fixed width, so the columns line up.
      function Pad (Text : String) return String
      is (if Text'Length >= 14 then Text (Text'First .. Text'First + 13)
          else Text & [1 .. 14 - Text'Length => ' ']);

      procedure Say (Text : String);

      procedure Say (Text : String) is
      begin
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, Text);
      end Say;
   begin
      if not Ada.Directories.Exists (Path) then
         Say ("no model at that path; nothing measured");
         return;
      end if;

      Files.Open (Source, Path, Status => Status);
      if E.Is_Error (Status) then
         Say ("the model would not open");
         return;
      end if;

      Containers.Reader.Parse (Container, Source, Status => Status);
      if E.Is_Error (Status) then
         Files.Close (Source);
         Say ("the model would not parse");
         return;
      end if;

      if Backend = Model_Runner.Backend.Backend_Device then
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open (Ready);
            if not Ready then
               Containers.Close (Container);
               Files.Close (Source);
               Say ("no device answered");
               return;
            end if;
         end;
      end if;

      L.Prepare
        (Engine, Container, Source, Backend => Backend,
         Threads => Threads, Status => Status);
      if E.Is_Error (Status) then
         Containers.Close (Container);
         Files.Close (Source);
         Say ("the model would not prepare");
         return;
      end if;

      declare
         Settings : constant L.Configuration := L.Config (Engine);
         Width    : constant N.Element_Count :=
           N.Element_Count (Settings.Vocabulary);

         Text : constant String :=
           (if Prompt_Path = "" then "The capital of France is"
            else Project_Tools.Files.Read_Raw_File (Prompt_Path));

         Held  : Vocab.Token_Array (1 .. 4096);
         Last  : Natural;

         type Session_Room is
           array (1 .. Members) of aliased L.Session;

         Live  : Session_Room;
         Group : L.Session_Group (1 .. Members);

         Step_Tokens : Vocab.Token_Array (1 .. Members);
         Rows        : Room_Of.Real_Array_Access := null;
         Aside       : Room_Of.Real_Array_Access := null;

         Started  : Ada.Real_Time.Time;
         Spent    : Duration := 0.0;
         Produced : Natural := 0;
         Stopped  : Boolean := False;

         --  A digest of every token every member chose, in order, so that
         --  two backends can be held against each other: greedy from the
         --  same prompt is the same text, and a round that ran on a device
         --  saying something else is the device path wrong rather than the
         --  device being faster.
         Mark : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;

         --  The pool the members share, as the single-sequence measurement
         --  makes one: a session opened without it does its products on the
         --  calling task, and a round measured that way is measuring the
         --  serial path rather than the round.
         Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));
         Where : constant CPU.Pool_Reference :=
           (if Threads = 1 then null else Team'Unchecked_Access);

         --  What the part was clocked at while the rounds ran, for the same
         --  reason the single-sequence measurement carries it: a device
         --  figure without one is a figure about an afternoon.
         Watching : constant Boolean :=
           Backend = Model_Runner.Backend.Backend_Device
           and then Device_Clock.Offered;

         Watch : Device_Clock.Watcher;
         Clock : Device_Clock.Reading;
      begin
         Vocab.Encode
           (L.Vocabulary (Engine).all, Text,
            Add_Beginning => True, Add_End => False,
            Target => Held, Last => Last, Status => Status);

         if E.Is_Error (Status) or else Last = 0 then
            Say ("the prompt would not encode");
            L.Close (Engine, Status);
            Containers.Close (Container);
            Files.Close (Source);
            return;
         end if;

         Room_Of.Allocate
           (N.Element_Count (Members) * Width, Rows);
         Room_Of.Allocate (Width, Aside);

         --  Each member opened and given the whole prompt on its own, which
         --  is prefill as it stands: a member's prompt is its own rows.
         for Index in Live'Range loop
            L.Open (Live (Index), Engine, Workers => Where,
                    Status => Status);
            exit when E.Is_Error (Status);

            --  The phase clock, on the member the round is made on: a round
            --  charges its phases to the session the call names, so that is
            --  the one to ask afterwards.
            if Budget and then Index = Live'First then
               L.Account (Live (Index), True);
            end if;

            Group (Index) := Live (Index)'Unchecked_Access;

            --  In batches, as generation reads a prompt: one call takes at
            --  most what the engine will evaluate at once, and handing it a
            --  whole long prompt is asking for a shape it never promised.
            declare
               At_Token : Natural := 1;
            begin
               while At_Token <= Last loop
                  declare
                     Upto : constant Natural :=
                       Natural'Min (At_Token + 127, Last);
                  begin
                     L.Evaluate_Batch
                       (Live (Index), Engine, Held (At_Token .. Upto),
                        Aside.all, Status => Status);
                     exit when E.Is_Error (Status);
                     At_Token := Upto + 1;
                  end;
               end loop;
            end;

            exit when E.Is_Error (Status);
         end loop;

         --  Watching from here, whichever way the prefill went: a task
         --  that is never started is a rendezvous nobody arrives at, and
         --  the block below waits on Stop.
         Watch.Start (Watching);

         if E.Is_Error (Status) then
            Say ("a member would not read the prompt: "
                 & E.Error_Code'Image (Status.Code));
         else
            --  The first token every member will say, taken from the
            --  prompt's own last distribution: greedy, so they agree.
            declare
               Best : N.Element_Count := 0;
            begin
               for Index in 1 .. Width - 1 loop
                  if Aside.all (Index) > Aside.all (Best) then
                     Best := Index;
                  end if;
               end loop;

               Step_Tokens := [others => Vocab.Token_Id (Best)];
            end;

            --  The phase clock, on the member the round is made on: a
            --  round charges its phases to the session the call names, so
            --  that is the one to ask afterwards. Started here rather than
            --  at Open, because what it is asked about is the rounds and
            --  the prompt each member read on its own would be nine tenths
            --  of the answer.
            if Budget then
               L.Account (Live (Live'First), True);
            end if;

            Started := Ada.Real_Time.Clock;

            for Step in 1 .. Tokens loop
               L.Evaluate_Round
                 (Members => Group, Source => Engine,
                  Tokens => Step_Tokens, Logits => Rows, Status => Status);

               exit when E.Is_Error (Status);
               Produced := Produced + 1;

               --  Greedy for each member, and a check on the way: with the
               --  same prompt and the same rule every member must choose
               --  the same token, so one that does not has read another's
               --  attention.
               for Which in 1 .. Members loop
                  declare
                     Base : constant N.Element_Count :=
                       N.Element_Count (Which - 1) * Width;
                     Best : N.Element_Count := 0;
                  begin
                     for Index in 1 .. Width - 1 loop
                        if Rows.all (Base + Index) > Rows.all (Base + Best)
                        then
                           Best := Index;
                        end if;
                     end loop;

                     if Which > 1
                       and then Vocab.Token_Id (Best) /= Step_Tokens (1)
                     then
                        Stopped := True;
                     end if;

                     Step_Tokens (Which) := Vocab.Token_Id (Best);

                     Mark :=
                       (Mark xor Interfaces.Unsigned_64 (Best))
                       * 16#0000_0100_0000_01B3#;
                  end;
               end loop;
            end loop;

            Spent :=
              Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
         end if;

         Watch.Stop (Clock);

         if E.Is_Error (Status) then
            Say ("a round failed: " & E.Error_Code'Image (Status.Code));
            for Frame in 1 .. Status.Frame_Total loop
               Say ("  " & Model_Runner.Text.To_String (Status.Frames (Frame)));
            end loop;
         else
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "members" & Integer'Image (Members)
               & ", prompt" & Integer'Image (Last)
               & " tokens, " & Integer'Image (Produced)
               & " rounds in " & Said (Spent) & " --"
               & Integer'Image (Produced * Members) & " tokens, "
               & Said (Spent / Duration (Produced * Members))
               & " a token, mark "
               & Shown (Mark)
               & (if Stopped
                  then "; MEMBERS DISAGREED, which is a collision"
                  else "")
                 & Device_Clock.Shown (Clock));

            --  And where the round's time went. Charged to the first
            --  member's session, which is the one every round was made on
            --  and so the one the whole round's phases are counted against;
            --  the prompt each member read on its own is in there too, and
            --  is the same for every backend.
            if Budget then
               declare
                  Times : constant L.Phase_Times :=
                    L.Time_Spent (Live (Live'First));
                  Total : Duration := 0.0;
               begin
                  for Phase in L.Phase loop
                     Total := Total + Times (Phase);
                  end loop;

                  Ada.Text_IO.Put_Line
                    (Ada.Text_IO.Standard_Error,
                     "  where the round's time goes");

                  for Phase in L.Phase loop
                     Ada.Text_IO.Put_Line
                       (Ada.Text_IO.Standard_Error,
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
               end;
            end if;
         end if;

         for Index in Live'Range loop
            L.Close (Live (Index));
         end loop;

         --  And the workers told to stop, which nothing else will do: a
         --  pool whose members have gone still has its tasks waiting for a
         --  job that is not coming, and the block cannot finish while they
         --  wait.
         if Where /= null then
            CPU.Close (Team);
         end if;

         Room_Of.Free (Rows);
         Room_Of.Free (Aside);
      end;

      L.Close (Engine, Status);
      Containers.Close (Container);
      Files.Close (Source);
   end Round;

end Speed_Run;
