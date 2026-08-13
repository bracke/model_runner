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
with Model_Runner.Stops;
with Model_Runner.Text;

with Project_Tools.Files;

package body Speed_Run is

   package CPU renames Model_Runner.Backend.CPU;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package Files renames Model_Runner.Byte_Sources.Files;
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
      Backend     : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Penalty     : Model_Runner.Numerics.Real := 1.1;
      Draft       : String := "";
      Draft_Tokens : Positive := 4;
      Repeats     : Positive;
      Result      : out Report)
   is
      use type Model_Runner.Backend.Backend_Kind;

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

            --  No pool for a backend that does not partition, whatever the
            --  thread count says.
            Where : constant CPU.Pool_Reference :=
              (if Threads = 1
                 or else Backend /= Model_Runner.Backend.Backend_CPU
               then null else Team'Unchecked_Access);
         begin
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
                  L.Open (Session, Engine, Workers => Where, Status => Local);
                  exit when E.Is_Error (Local);

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

                  Model_Runner.Stops.Close (Stop);
                  if Drafting then
                     L.Close (Draft_Session);
                  end if;
                  L.Close (Session);
                  Gen.Release (Outcome);
               end;
            end loop;

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
        & "; load " & T.Image (Item.Load_Before, 2)
        & " to " & T.Image (Item.Load_After, 2);
   end Summary;

end Speed_Run;
