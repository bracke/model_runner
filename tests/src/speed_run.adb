with Ada.Directories;
with Interfaces;
with Ada.Real_Time;

with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Clocks;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Output;
with Model_Runner.Sampling;
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

   overriding procedure Write
     (Self : in out Discard; Item : String; Closed : out Boolean) is
   begin
      for Index in Item'Range loop
         Self.Hash :=
           (Self.Hash xor Interfaces.Unsigned_64
                            (Character'Pos (Item (Index))))
           * 16#0000_0100_0000_01B3#;
      end loop;
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
      Repeats     : Positive;
      Result      : out Report)
   is
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

      Walls     : Duration_Array (1 .. Repeats) := [others => 0.0];
      Evaluates : Duration_Array (1 .. Repeats) := [others => 0.0];
      Generates : Duration_Array (1 .. Repeats) := [others => 0.0];
   begin
      Result := (others => <>);

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
         Prompt : constant String :=
           Project_Tools.Files.Read_Raw_File (Prompt_Path);

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

         L.Prepare
           (Engine, Container, Source, Repack => Repack,
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

         declare
            --  The engine reports its own split between evaluating the
            --  prompt and generating, but only when it is given a clock to
            --  read; without one both figures come back zero, which is how
            --  the first run of this reported a wall of 1.3 s made of
            --  nothing.
            Timer : aliased Model_Runner.Clocks.System_Clock;
            Team  : aliased CPU.Pool (CPU.Worker_Count (Threads));
            Where : constant CPU.Pool_Reference :=
              (if Threads = 1 then null else Team'Unchecked_Access);
         begin
            for Pass in 1 .. Repeats loop
               declare
                  Session : L.Session;
                  Stop    : Model_Runner.Stops.Set;
                  Sink    : aliased Discard;
                  Request : Gen.Request;
                  Outcome : Gen.Result;
                  Local   : E.Error_Info;
               begin
                  L.Open (Session, Engine, Workers => Where, Status => Local);
                  exit when E.Is_Error (Local);

                  Model_Runner.Stops.Open (Stop);
                  Request.Max_Tokens := Tokens;
                  Request.Batch_Size := Batch;
                  Request.Sampling :=
                    Model_Runner.Sampling.Greedy_Configuration;
                  Request.Seed := 1;
                  Request.Has_Seed := True;
                  Request.Add_Beginning := True;

                  Started := Ada.Real_Time.Clock;
                  Gen.Generate
                    (Engine, Session, Prompt, Request, Stop,
                     Sink'Unchecked_Access, null, Timer'Unchecked_Access,
                     null, null, Outcome => Outcome);
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

                  --  Sixteen hexadecimal digits, most significant first.
                  declare
                     Figures : constant String := "0123456789abcdef";
                     Left    : Interfaces.Unsigned_64 := Sink.Hash;
                  begin
                     for Place in reverse Result.Digest'Range loop
                        Result.Digest (Place) :=
                          Figures
                            (Figures'First
                             + Natural (Left mod 16));
                        Left := Left / 16;
                     end loop;
                  end;

                  Result.Prompt := Outcome.Prompt_Tokens;
                  Result.Produced := Outcome.Generated_Tokens;
                  Result.Runs := Pass;

                  Model_Runner.Stops.Close (Stop);
                  L.Close (Session);
                  Gen.Release (Outcome);
               end;
            end loop;

            CPU.Close (Team);
         end;

         L.Close (Engine, Status);
         Containers.Close (Container);
         Files.Close (Source);
      end;

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
        & Seconds (Item.Load) & "; output " & Item.Digest;
   end Summary;

end Speed_Run;
