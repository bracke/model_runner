with AUnit.Assertions;

with Interfaces;

with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.CLI.Driver;
with Model_Runner.CLI.Options;
with Model_Runner.Cancellation;
with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Presentation;
with Model_Runner.Progress;
with Model_Runner.Limits;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Output;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with Expectations;
with External_Model;
with Tiny_Model;

package body Tests.CLI_Cases is

   use AUnit.Assertions;
   use type Model_Runner.CLI.Options.Color_Mode;
   use type Model_Runner.CLI.Options.Command_Kind;
   use type Model_Runner.CLI.Options.Prompt_Source;
   use type Model_Runner.CLI.Options.Verbosity;
   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Generation.Completion_Reason;
   use type Model_Runner.Numerics.Real;
   use type External_Model.Outcome;
   use type Model_Runner.CLI.Options.Text_Access;
   use type Interfaces.Unsigned_64;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package Opt renames Model_Runner.CLI.Options;
   package Containers renames Model_Runner.GGUF.Containers;
   package T renames Model_Runner.Text;

   --  Report whether Needle occurs in Haystack.
   function Contains (Haystack, Needle : String) return Boolean is
   begin
      if Needle'Length > Haystack'Length then
         return False;
      end if;
      for Start in Haystack'First .. Haystack'Last - Needle'Length + 1 loop
         if Haystack (Start .. Start + Needle'Length - 1) = Needle then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   ---------------------------------------------------------------------------
   --  Test doubles
   ---------------------------------------------------------------------------

   Max_Arguments : constant := 32;

   --  An argument vector supplied by the test rather than by a process.
   type Fixed_Arguments is limited new Opt.Arguments with record
      Values : Model_Runner.Text.Bounded_List (1 .. Max_Arguments) :=
        [others => Model_Runner.Text.Empty];
      Used   : Natural := 0;
   end record;

   overriding function Count (Self : Fixed_Arguments) return Natural
   is (Self.Used);

   overriding function Value
     (Self : Fixed_Arguments; Index : Positive) return String
   is (T.To_String (Self.Values (Index)));

   procedure Add (Item : in out Fixed_Arguments; Value : String) is
   begin
      Item.Used := Item.Used + 1;
      Item.Values (Item.Used) := T.To_Bounded (Value);
   end Add;

   Max_Captured : constant := 65_536;

   --  A sink that accumulates what generation writes, and can be told to
   --  report closure after a number of bytes so that broken-pipe handling can
   --  be exercised without a pipe.
   type Capture_Sink is limited new Model_Runner.Output.Sink with record
      Data      : String (1 .. Max_Captured) := [others => ' '];
      Used      : Natural := 0;
      Limit     : Natural := Max_Captured;
      Closed    : Boolean := False;
      Fragments : Natural := 0;
   end record;

   overriding procedure Write
     (Self   : in out Capture_Sink;
      Item   : String;
      Closed : out Boolean);

   overriding procedure Flush
     (Self : in out Capture_Sink; Closed : out Boolean);

   overriding function Is_Closed (Self : Capture_Sink) return Boolean;

   overriding procedure Write
     (Self   : in out Capture_Sink;
      Item   : String;
      Closed : out Boolean) is
   begin
      if Self.Closed or else Self.Used + Item'Length > Self.Limit then
         Self.Closed := True;
         Closed := True;
         return;
      end if;

      Self.Fragments := Self.Fragments + 1;
      Self.Data (Self.Used + 1 .. Self.Used + Item'Length) := Item;
      Self.Used := Self.Used + Item'Length;
      Closed := False;
   end Write;

   overriding procedure Flush
     (Self : in out Capture_Sink; Closed : out Boolean) is
   begin
      Closed := Self.Closed;
   end Flush;

   overriding function Is_Closed (Self : Capture_Sink) return Boolean
   is (Self.Closed);

   function Captured (Self : Capture_Sink) return String
   is (Self.Data (1 .. Self.Used));

   ---------------------------------------------------------------------------
   --  Parser
   ---------------------------------------------------------------------------

   --  A well-formed run command parses into the values it named.
   procedure Run_Command_Parses (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      Source : Fixed_Arguments;
      Item   : Opt.Command;
      Status : E.Error_Info;
   begin
      Add (Source, "run");
      Add (Source, "model.gguf");
      Add (Source, "--prompt");
      Add (Source, "hello");
      Add (Source, "--max-tokens=64");
      Add (Source, "--temperature");
      Add (Source, "0");
      Add (Source, "--seed");
      Add (Source, "42");
      Add (Source, "--stop");
      Add (Source, "END");
      Add (Source, "--color=never");
      Add (Source, "--verbose");

      Opt.Parse (Source, Item, Status);
      Assert (E.Is_Ok (Status),
              "valid command rejected: " & E.Error_Code'Image (Status.Code));
      Assert (Item.Kind = Opt.Command_Run, "wrong command");
      Assert (T.To_String (Item.Model_Path) = "model.gguf", "wrong model path");
      Assert (Item.Prompt_Kind = Opt.Prompt_Inline, "wrong prompt source");
      Assert (Item.Prompt_Text /= null and then Item.Prompt_Text.all = "hello",
              "prompt text not captured");
      Assert (Item.Max_Tokens = 64, "--max-tokens=N form not accepted");
      Assert (Item.Sampling.Temperature = 0.0, "temperature not captured");
      Assert (Item.Has_Seed and then Item.Seed = 42, "seed not captured");
      Assert (Item.Stop_Count = 1
              and then T.To_String (Item.Stop_Strings (1)) = "END",
              "stop string not captured");
      Assert (Item.Color = Opt.Color_Never, "color mode not captured");
      Assert (Item.Level = Opt.Verbose, "verbosity not captured");

      Opt.Release (Item);
   end Run_Command_Parses;

   --  Malformed command lines are rejected with the code that names the
   --  problem.
   procedure Usage_Errors_Reported (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      procedure Expect (Code : E.Error_Code; Words : String) is
         Source : Fixed_Arguments;
         Item   : Opt.Command;
         Status : E.Error_Info;
         First  : Positive := Words'First;
      begin
         for Index in Words'Range loop
            if Words (Index) = ' ' then
               if Index > First then
                  Add (Source, Words (First .. Index - 1));
               end if;
               First := Index + 1;
            end if;
         end loop;
         if First <= Words'Last then
            Add (Source, Words (First .. Words'Last));
         end if;

         Opt.Parse (Source, Item, Status);
         Assert (Status.Code = Code,
                 """" & Words & """ gave "
                 & E.Error_Code'Image (Status.Code)
                 & " instead of " & E.Error_Code'Image (Code));
         Opt.Release (Item);
      end Expect;

   begin
      Expect (E.CLI_Missing_Command, "");
      Expect (E.CLI_Unknown_Command, "frobnicate");
      Expect (E.CLI_Missing_Model_Path, "run");
      Expect (E.CLI_Unknown_Option, "run m.gguf --nope");
      Expect (E.CLI_Missing_Option_Value, "run m.gguf --prompt");
      Expect (E.CLI_Invalid_Option_Value, "run m.gguf --max-tokens abc");
      Expect (E.CLI_Option_Out_Of_Range, "run m.gguf --max-tokens 0");
      Expect (E.CLI_Repeated_Option, "run m.gguf --seed 1 --seed 2");

      --  A value on an option that does not take one. Dropping it silently
      --  left the reader believing it had been applied, and the diagnostic
      --  for it existed from the start without anything producing it.
      Expect (E.CLI_Unexpected_Option_Value, "run m.gguf --verbose=5");
      Expect (E.CLI_Unexpected_Option_Value, "run m.gguf --raw=yes");
      Expect (E.CLI_Unexpected_Option_Value, "run m.gguf --interactive=1");
      Expect (E.CLI_Unexpected_Option_Value, "inspect m.gguf --metadata=all");
      Expect (E.CLI_Unexpected_Option_Value, "run m.gguf --mmap=");

      --  The bare forms stay accepted, so the check cannot be satisfied by
      --  refusing the flags outright.
      Expect (E.No_Error, "run m.gguf --prompt hi --verbose --raw");
      Expect (E.No_Error, "inspect m.gguf --metadata --tensors");
      Expect (E.No_Error, "run m.gguf --prompt hi --quiet --mmap");
      Expect (E.No_Error, "run m.gguf --prompt hi --no-mmap --show-stats");
      Expect (E.No_Error, "run m.gguf --prompt hi --no-stats");
      Expect (E.No_Error, "inspect m.gguf --validate");

      --  And every option that does take a value still accepts it joined by
      --  an equals sign. Deciding which options take one is what the refusal
      --  above rests on, and getting a single option on the wrong side of
      --  that would refuse something that has always worked.
      Expect (E.No_Error, "run m.gguf --prompt=hi --max-tokens=2");
      Expect (E.No_Error, "run m.gguf --prompt hi --context-size=16");
      Expect (E.No_Error, "run m.gguf --prompt hi --batch-size=4");
      Expect (E.No_Error, "run m.gguf --prompt hi --threads=1");
      Expect (E.No_Error, "run m.gguf --prompt hi --temperature=0");
      Expect (E.No_Error, "run m.gguf --prompt hi --top-k=1");
      Expect (E.No_Error, "run m.gguf --prompt hi --top-p=1.0");
      Expect (E.No_Error, "run m.gguf --prompt hi --min-p=0.0");
      Expect (E.No_Error, "run m.gguf --prompt hi --repeat-penalty=1.0");
      Expect (E.No_Error, "run m.gguf --prompt hi --repeat-window=8");
      Expect (E.No_Error, "run m.gguf --prompt hi --seed=3");
      Expect (E.No_Error, "run m.gguf --prompt hi --color=never");
      Expect (E.No_Error, "run m.gguf --prompt hi --locale=en");
      Expect (E.No_Error, "run m.gguf --prompt hi --stop=zz");
      Expect (E.No_Error, "run m.gguf --prompt hi --stop-token=5");
      Expect (E.No_Error, "run m.gguf --prompt hi --memory-limit=1073741824");
      Expect (E.No_Error, "run m.gguf --prompt-file p.txt --system=hi");
      --  A size that is negative. It is read into an unsigned quantity, so
      --  without the check the conversion raises rather than reporting a bad
      --  value, and a suffix does not change that.
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --memory-limit=-1");
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --memory-limit=-1G");
      Expect (E.No_Error, "run m.gguf --prompt hi --memory-limit=1G");

      --  A number that is punctuation and no digits. Without the check for
      --  a digit these parse as zero and succeed, and zero is a temperature
      --  the program accepts: it means greedy. So the run would go ahead
      --  under a setting the caller never asked for and nothing would say
      --  so. The other three take a range that excludes zero and would be
      --  refused a step later, for the wrong reason.
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --temperature=.");
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --temperature=-");
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --temperature=+");
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --top-p=-.");

      --  And a whole part too large to hold. The parser refuses it while
      --  reading rather than overflowing, which is what it would otherwise
      --  do: the digits are accumulated in a signed integer.
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --temperature=99999999999999999999");
      Expect (E.CLI_Invalid_Option_Value,
              "run m.gguf --prompt hi --repeat-penalty=1"
              & "0000000000000000000.5");

      --  Ordinary numbers in the same shapes still parse, so none of the
      --  refusals above is the parser giving up on decimals.
      Expect (E.No_Error, "run m.gguf --prompt hi --temperature=.5");
      Expect (E.No_Error, "run m.gguf --prompt hi --temperature=1.");
      Expect (E.No_Error, "run m.gguf --prompt hi --temperature=+0.7");

      Expect (E.CLI_Conflicting_Prompt_Sources,
              "run m.gguf --prompt a --prompt-file b");
      Expect (E.CLI_Conflicting_System_Sources,
              "run m.gguf --system a --system-file b");
      Expect (E.CLI_Raw_Mode_Conflict, "run m.gguf --raw --system a");
      Expect (E.CLI_Invalid_Color_Mode, "run m.gguf --color=mauve");
      Expect (E.CLI_Unexpected_Operand, "run m.gguf extra");
      Expect (E.Sampling_Invalid_Configuration, "run m.gguf --top-p 2");
      Expect (E.Sampling_Invalid_Configuration, "run m.gguf --min-p -1");
   end Usage_Errors_Reported;

   --  Everything after the end-of-options marker is an operand, even when it
   --  begins with a dash.
   procedure End_Of_Options_Honoured
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Source : Fixed_Arguments;
      Item   : Opt.Command;
      Status : E.Error_Info;
   begin
      Add (Source, "inspect");
      Add (Source, "--");
      Add (Source, "--strange-name.gguf");

      Opt.Parse (Source, Item, Status);
      Assert (E.Is_Ok (Status),
              "end-of-options not honoured: " & E.Error_Code'Image (Status.Code));
      Assert (T.To_String (Item.Model_Path) = "--strange-name.gguf",
              "operand after -- was treated as an option");
      Opt.Release (Item);
   end End_Of_Options_Honoured;

   --  The narrow pre-parse scans find the locale and colour without parsing
   --  the rest, which is what lets a usage error be reported in the right
   --  locale.
   procedure Preliminary_Scans (T2 : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T2);
      Source : Fixed_Arguments;
      Found  : Boolean;
   begin
      Add (Source, "run");
      Add (Source, "--locale");
      Add (Source, "da");
      Add (Source, "--color=always");
      Add (Source, "--nonsense");

      Assert (Opt.Preliminary_Locale (Source) = "da",
              "locale not found by the preliminary scan");
      declare
         Mode : constant Opt.Color_Mode := Opt.Preliminary_Color (Source, Found);
      begin
         Assert (Mode = Opt.Color_Always and then Found,
                 "colour not found by the preliminary scan");
      end;

      declare
         Bare : Fixed_Arguments;
      begin
         Add (Bare, "version");
         Assert (Opt.Preliminary_Locale (Bare) = "",
                 "a locale was invented");
         --  Bound before the assertion: short-circuiting past Found would
         --  leave the out parameter written but never read.
         declare
            Mode : constant Opt.Color_Mode := Opt.Preliminary_Color (Bare, Found);
         begin
            Assert (not Mode'Valid or else not Found,
                    "a colour mode was invented");
         end;
      end;
   end Preliminary_Scans;

   ---------------------------------------------------------------------------
   --  Generation
   ---------------------------------------------------------------------------

   type Harness (Image : access constant B.Byte_Array) is limited record
      Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
      Parsed : Containers.Container;
      Ready  : L.Model;
   end record;

   procedure Start (Item : in out Harness) is
      Status : E.Error_Info;
   begin
      Containers.Reader.Parse (Item.Parsed, Item.Source, Status => Status);
      Assert (E.Is_Ok (Status), "tiny model did not parse");
      L.Prepare (Item.Ready, Item.Parsed, Item.Source, Status => Status);
      Assert (E.Is_Ok (Status), "tiny model did not prepare");
   end Start;

   --  A greedy run with a fixed seed produces the same text and the same
   --  completion reason every time.
   procedure Generation_Is_Reproducible
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
      First : String (1 .. Max_Captured) := [others => ' '];
      First_Used : Natural := 0;
   begin
      Tiny_Model.Build (Image);

      for Attempt in 1 .. 2 loop
         declare
            Held    : aliased constant B.Byte_Array := Image.all;
            Under   : Harness (Held'Access);
            Session : L.Session;
            Stop    : Model_Runner.Stops.Set;
            Sink    : aliased Capture_Sink;
            Request : Gen.Request;
            Outcome : Gen.Result;
            Status  : E.Error_Info;
         begin
            Start (Under);
            L.Open (Session, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "session did not open");
            Model_Runner.Stops.Open (Stop);

            Request.Max_Tokens := 5;
            Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
            Request.Seed := 42;
            Request.Has_Seed := True;
            Request.Add_Beginning := True;

            Gen.Generate
              (Under.Ready, Session, "ab", Request, Stop,
               Sink'Unchecked_Access, null, null, null, null,
               Outcome => Outcome);

            Assert (Outcome.Reason = Gen.Maximum_Tokens,
                    "wrong completion reason: "
                    & Gen.Completion_Reason'Image (Outcome.Reason));
            Assert (Outcome.Generated_Tokens = 5, "wrong token count");
            Assert (Outcome.Seed = 42, "the seed was not reported");
            Assert (Sink.Fragments > 0, "nothing was streamed");

            if Attempt = 1 then
               First_Used := Sink.Used;
               First (1 .. First_Used) := Captured (Sink);
            else
               Assert (Captured (Sink) = First (1 .. First_Used),
                       "a fixed seed produced different text");
            end if;

            Model_Runner.Stops.Close (Stop);
            L.Close (Session);
            Gen.Release (Outcome);
         end;
      end loop;

      B.Free (Image);
   end Generation_Is_Reproducible;

   --  A stop string ends the run and no byte of it reaches the sink, even
   --  though it was produced across more than one token.
   procedure Stop_String_Truncates
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Plain   : aliased Capture_Sink;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);

         Request.Max_Tokens := 6;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Has_Seed := True;
         Request.Add_Beginning := True;

         --  First without a stop string, to learn what the model produces.
         Gen.Generate
           (Under.Ready, Session, "ab", Request, Stop,
            Plain'Unchecked_Access, null, null, null, null, Outcome => Outcome);
         Assert (Outcome.Reason = Gen.Maximum_Tokens, "baseline run failed");
         Gen.Release (Outcome);

         --  An empty prompt is not empty by the time it is tokenized: a
         --  SentencePiece vocabulary prepends its space marker, so "" comes
         --  back as one token and the run proceeds. The refusal for a prompt
         --  of no tokens sits behind that and no vocabulary this program
         --  accepts can reach it, since any other tokenizer kind is refused
         --  when the model loads. Recorded rather than tested.

         declare
            Whole : constant String := Captured (Plain);
         begin
            Assert (Whole'Length >= 3, "baseline produced too little text");

            --  Stop on a two-character run that starts after the first
            --  character, so the match spans a token boundary.
            Model_Runner.Stops.Add_String
              (Stop, Whole (Whole'First + 1 .. Whole'First + 2), Status);
            Assert (E.Is_Ok (Status), "stop string rejected");

            L.Reset (Session);
            Gen.Generate
              (Under.Ready, Session, "ab", Request, Stop,
               Sink'Unchecked_Access, null, null, null, null,
               Outcome => Outcome);

            Assert (Outcome.Reason = Gen.Stop_String,
                    "the stop string did not end the run: "
                    & Gen.Completion_Reason'Image (Outcome.Reason));
            Assert (Captured (Sink) = Whole (Whole'First .. Whole'First),
                    "text around the stop string leaked: """
                    & Captured (Sink) & """");
         end;

         Gen.Release (Outcome);
         L.Close (Session);

         --  And generating from a session that has been closed. The model is
         --  still there and still ready; what is gone is the cache the run
         --  would extend, and continuing into it would be generating from
         --  whatever the released memory now holds.
         Gen.Generate
           (Under.Ready, Session, "ab", Request, Stop,
            Sink'Unchecked_Access, null, null, null, null, Outcome => Outcome);
         Assert (Outcome.Reason = Gen.Runtime_Error,
                 "a closed session generated text: "
                 & Gen.Completion_Reason'Image (Outcome.Reason));
         Assert (Outcome.Error.Code = E.Lifecycle_Invalid_State,
                 "a closed session was not reported as such: "
                 & E.Error_Code'Image (Outcome.Error.Code));
         Assert (Outcome.Generated_Tokens = 0,
                 "a refused run produced tokens");

         Model_Runner.Stops.Close (Stop);
         Gen.Release (Outcome);
      end;

      B.Free (Image);
   end Stop_String_Truncates;

   --  A stop token ends the run before any of its text is produced.
   procedure Stop_Token_Ends_Run (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);

         --  Every token the tiny model can produce is a stop token, so the
         --  very first sample ends the run with nothing streamed.
         for Token in 0 .. Tiny_Model.Vocabulary - 1 loop
            Model_Runner.Stops.Add_Token
              (Stop, Model_Runner.Tokenizer.Token_Id (Token), Status);
         end loop;

         Request.Max_Tokens := 4;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Add_Beginning := True;

         Gen.Generate
           (Under.Ready, Session, "ab", Request, Stop,
            Sink'Unchecked_Access, null, null, null, null, Outcome => Outcome);

         Assert (Outcome.Reason = Gen.Stop_Token,
                 "a stop token did not end the run: "
                 & Gen.Completion_Reason'Image (Outcome.Reason));
         Assert (Outcome.Generated_Tokens = 0, "a stopped token was counted");
         Assert (Captured (Sink) = "", "a stop token produced text");

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
         Gen.Release (Outcome);
      end;

      B.Free (Image);
   end Stop_Token_Ends_Run;

   --  A destination that closes ends the run as Output_Closed rather than as a
   --  failure.
   procedure Closed_Output_Is_Normal
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);

         --  Accept one byte, then behave like a broken pipe.
         Sink.Limit := 1;

         Request.Max_Tokens := 6;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Add_Beginning := True;

         Gen.Generate
           (Under.Ready, Session, "ab", Request, Stop,
            Sink'Unchecked_Access, null, null, null, null, Outcome => Outcome);

         Assert (Outcome.Reason = Gen.Output_Closed,
                 "a closed destination was not reported as such: "
                 & Gen.Completion_Reason'Image (Outcome.Reason));
         Assert (Gen.Is_Normal (Outcome.Reason),
                 "a closed destination was treated as a failure");

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
         Gen.Release (Outcome);
      end;

      B.Free (Image);
   end Closed_Output_Is_Normal;

   --  A prompt that cannot fit beside the requested output is rejected before
   --  any evaluation happens.
   procedure Context_Budget_Checked
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);

         Request.Max_Tokens := Tiny_Model.Context;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Add_Beginning := True;

         Gen.Generate
           (Under.Ready, Session, "abc", Request, Stop,
            Sink'Unchecked_Access, null, null, null, null, Outcome => Outcome);

         Assert (Outcome.Reason = Gen.Runtime_Error,
                 "an impossible request was accepted");
         Assert (Outcome.Error.Code = E.Generation_Context_Exhausted,
                 "wrong diagnostic: "
                 & E.Error_Code'Image (Outcome.Error.Code));
         Assert (L.Position (Session) = 0,
                 "a rejected request evaluated tokens anyway");

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
         Gen.Release (Outcome);
      end;

      B.Free (Image);
   end Context_Budget_Checked;

   --  Retained text matches what was streamed, byte for byte.
   procedure Retained_Text_Matches
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);

         Request.Max_Tokens := 5;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Request.Add_Beginning := True;
         Request.Retain_Text := True;

         Gen.Generate
           (Under.Ready, Session, "ab", Request, Stop,
            Sink'Unchecked_Access, null, null, null, null, Outcome => Outcome);

         Assert (Gen.Generated_Text (Outcome) = Captured (Sink),
                 "retained text differs from what was streamed");

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
         Gen.Release (Outcome);
      end;

      B.Free (Image);
   end Retained_Text_Matches;

   --  The reference-comparison machinery must actually compare: it has to
   --  accept a matching recording, reject a mismatching one, and refuse a
   --  recording whose origin is not stated.
   --
   --  The matching recording here is produced from this engine, so it is a
   --  test of the mechanism and not evidence about the engine. Cross-runtime
   --  evidence needs a recording from a different implementation, which is
   --  The model file is never written to.
   --
   --  This is stated in the README and was held by nothing. It is not a
   --  property of one code path either: the file is opened, memory-mapped
   --  where the host allows it, read through for metadata and tensors, and
   --  kept open for the length of a run. Any of that could write, and a
   --  mapping that was not read-only would write without anything failing.
   --
   --  So this reads the bytes before and after a whole run and compares
   --  them, and checks the modification time as well -- a file rewritten
   --  with identical contents is still a file this program wrote to.
   procedure Model_File_Is_Never_Modified
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Path : constant String := "obj/readonly-model.gguf";

      --  Read a whole file into fresh storage.
      function Whole (Name : String) return B.Byte_Array_Access is
         use Ada.Streams.Stream_IO;
         use type B.Byte_Array_Access;
         Handle : File_Type;
         Result : B.Byte_Array_Access;
      begin
         Open (Handle, In_File, Name);
         B.Allocate (B.Byte_Count (Size (Handle)), Result);
         if Result /= null then
            for Index in Result.all'Range loop
               B.Byte'Read (Stream (Handle), Result.all (Index));
            end loop;
         end if;
         Close (Handle);
         return Result;
      end Whole;

      use type Ada.Calendar.Time;
      use type B.Byte_Array;
      use type B.Byte_Array_Access;

      Before  : B.Byte_Array_Access;
      After   : B.Byte_Array_Access;
      Stamped : Ada.Calendar.Time;
      Status  : Natural;
      Errors  : constant String := "obj/readonly-model.err";
      Handle  : Ada.Text_IO.File_Type;
   begin
      Tiny_Model.Write (Path);
      Before := Whole (Path);
      Assert (Before /= null, "the model file could not be read");
      Stamped := Ada.Directories.Modification_Time (Path);

      --  A whole run: the model is opened, mapped where it can be, read for
      --  metadata and tensors, and generated from.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Path);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "3");
         Add (Source, "--threads");
         Add (Source, "1");

         Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Errors);
         Ada.Text_IO.Set_Output (Handle);
         Ada.Text_IO.Set_Error (Handle);
         Model_Runner.CLI.Driver.Run (Source, Status);
         Ada.Text_IO.Set_Output (Ada.Text_IO.Standard_Output);
         Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
         Ada.Text_IO.Close (Handle);

         Assert (Status = 0,
                 "the run failed with status" & Natural'Image (Status));
      end;

      --  And an inspection, which walks every descriptor rather than the
      --  tensors one architecture happens to need.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "inspect");
         Add (Source, Path);
         Add (Source, "--metadata");
         Add (Source, "--tensors");

         Ada.Text_IO.Open (Handle, Ada.Text_IO.Out_File, Errors);
         Ada.Text_IO.Set_Output (Handle);
         Ada.Text_IO.Set_Error (Handle);
         Model_Runner.CLI.Driver.Run (Source, Status);
         Ada.Text_IO.Set_Output (Ada.Text_IO.Standard_Output);
         Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
         Ada.Text_IO.Close (Handle);

         Assert (Status = 0,
                 "the inspection failed with status" & Natural'Image (Status));
      end;

      After := Whole (Path);
      Assert (After /= null, "the model file could not be read afterwards");
      Assert (After.all'Length = Before.all'Length,
              "the model file changed size");
      Assert (After.all = Before.all, "the model file changed");
      Assert (Ada.Directories.Modification_Time (Path) = Stamped,
              "the model file was rewritten with the same contents");

      B.Free (Before);
      B.Free (After);
      Ada.Directories.Delete_File (Path);
      Ada.Directories.Delete_File (Errors);
   end Model_File_Is_Never_Modified;

   --  what docs/reference-runtime.md describes.
   procedure Reference_Comparison_Works
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Root  : constant String := "obj";
      Model : constant String := Root & "/expect-model.gguf";
      Good  : constant String := Root & "/expect-good.txt";
      Bad   : constant String := Root & "/expect-bad.txt";
      Blank : constant String := Root & "/expect-blank.txt";

      --  Tokenize with this engine, to build a recording that must match.
      procedure Write_Expectation (Path : String; Corrupt : Boolean) is
         Image  : B.Byte_Array_Access;
         Handle : Ada.Text_IO.File_Type;
      begin
         Tiny_Model.Build (Image);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Under  : Harness (Held'Access);
            Tokens : Model_Runner.Tokenizer.Token_Array (1 .. 64);
            Last   : Natural;
            Status : E.Error_Info;
         begin
            Start (Under);

            Model_Runner.Tokenizer.Encode
              (L.Vocabulary (Under.Ready).all, "ab", True, False,
               Tokens, Last, Status);
            Assert (E.Is_Ok (Status) and then Last > 0, "encode failed");

            Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Path);
            Ada.Text_IO.Put_Line
              (Handle, "runtime self (mechanism test, not reference evidence)");
            Ada.Text_IO.Put_Line (Handle, "model tiny-model.gguf");
            Ada.Text_IO.Put_Line (Handle, "prompt ab");
            Ada.Text_IO.Put (Handle, "tokens");
            for Index in 1 .. Last loop
               declare
                  Value : constant Integer :=
                    Integer (Tokens (Index))
                    + (if Corrupt and then Index = Last then 1 else 0);
               begin
                  Ada.Text_IO.Put (Handle, " " & T.Image (Long_Long_Integer (Value)));
               end;
            end loop;
            Ada.Text_IO.New_Line (Handle);
            Ada.Text_IO.Close (Handle);
         end;

         B.Free (Image);
      end Write_Expectation;

      Result : External_Model.Report;
      Record_Value : Expectations.Recording;
   begin
      if not Ada.Directories.Exists (Root) then
         Ada.Directories.Create_Directory (Root);
      end if;

      Tiny_Model.Write (Model);
      Write_Expectation (Good, Corrupt => False);
      Write_Expectation (Bad, Corrupt => True);

      --  A recording that matches is accepted, and the comparison is reported
      --  as having happened.
      External_Model.Run
        (Path => Model, Prompt => "ab", Tokens => 3, Threads => 2,
         Expect => Good, Result => Result);
      Assert (Result.Result = External_Model.Ran,
              "a matching recording was not accepted: "
              & External_Model.Detail_Text (Result));
      Assert (Result.Reference_Run, "the comparison was not reported as run");
      Assert (Result.Tokens_Match, "matching tokens were not recognized");

      --  A recording that disagrees is a failure, not a pass.
      External_Model.Run
        (Path => Model, Prompt => "ab", Tokens => 3, Threads => 2,
         Expect => Bad, Result => Result);
      Assert (Result.Result = External_Model.Failed,
              "a mismatching recording was accepted");

      --  A recording with no stated origin is not evidence and is refused.
      declare
         Handle : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Blank);
         Ada.Text_IO.Put_Line (Handle, "tokens 1 2 3");
         Ada.Text_IO.Close (Handle);
      end;

      Expectations.Load (Blank, Record_Value);
      Assert (not Record_Value.Valid,
              "a recording with no stated origin was accepted");

      External_Model.Run
        (Path => Model, Prompt => "ab", Tokens => 3, Threads => 1,
         Expect => Blank, Result => Result);
      Assert (Result.Result = External_Model.Failed,
              "a recording with no stated origin did not fail the run");

      --  A missing model is a skip even when a recording is supplied.
      External_Model.Run
        (Path => Root & "/absent.gguf", Prompt => "ab", Tokens => 3,
         Threads => 1, Expect => Good, Result => Result);
      Assert (Result.Result = External_Model.Skipped,
              "a missing model was not skipped");

      Ada.Directories.Delete_File (Model);
      Ada.Directories.Delete_File (Good);
      Ada.Directories.Delete_File (Bad);
      Ada.Directories.Delete_File (Blank);
   end Reference_Comparison_Works;

   ----------
   -- Name --
   ----------

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("command line and generation");
   end Name;

   --  An observer that asks for cancellation when a chosen stage is reported.
   type Cancel_On_Stage is limited new Model_Runner.Progress.Observer with record
      Flag  : Model_Runner.Cancellation.Token_Reference := null;
      Stage : Model_Runner.Progress.Generation_Stage :=
        Model_Runner.Progress.Token_Produced;
   end record;

   overriding procedure Notify
     (Self : in out Cancel_On_Stage;
      Item : Model_Runner.Progress.Event);

   overriding procedure Notify
     (Self : in out Cancel_On_Stage;
      Item : Model_Runner.Progress.Event)
   is
      use type Model_Runner.Progress.Event_Kind;
      use type Model_Runner.Progress.Generation_Stage;
      use type Model_Runner.Cancellation.Token_Reference;
   begin
      if Self.Flag /= null
        and then Item.Kind = Model_Runner.Progress.Generation_Event
        and then Item.Generation = Self.Stage
      then
         Self.Flag.all.Request;
      end if;
   end Notify;

   --  Any command line at all is answered, never raised on.
   --
   --  The parser is the first thing an untrusted command line meets, and it
   --  is tested by cases someone thought of. This throws vectors nobody
   --  thought of at it -- options in impossible orders, values where flags
   --  go, empty arguments, text that is not UTF-8, numbers too long to be
   --  numbers -- and asks only for the property the parser owes every caller:
   --  it returns, with a definite outcome, and does not raise.
   --
   --  Every vector comes from the case number alone, so a failure is replayed
   --  by running the same case.
   procedure Any_Command_Line_Is_Answered
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      --  A small deterministic generator. The parser is what is being
      --  examined, so the source of the vectors is kept obvious.
      State : Interfaces.Unsigned_64 := 88_172_645_463_325_252;

      function Draw (Bound : Positive) return Natural is
      begin
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         return Natural (State mod Interfaces.Unsigned_64 (Bound));
      end Draw;

      --  Pieces a command line is made of, sound and otherwise.
      function Piece (Which : Natural) return String is
      begin
         case Which is
            when 0 => return "run";
            when 1 => return "inspect";
            when 2 => return "help";
            when 3 => return "version";
            when 4 => return "model.gguf";
            when 5 => return "--prompt";
            when 6 => return "--max-tokens";
            when 7 => return "--seed";
            when 8 => return "--verbose";
            when 9 => return "--raw";
            when 10 => return "--color";
            when 11 => return "--threads";
            when 12 => return "--stop";
            when 13 => return "--";
            when 14 => return "-";
            when 15 => return "";
            when 16 => return "=";
            when 17 => return "--=";
            when 18 => return "--prompt=";
            when 19 => return "--max-tokens=-1";
            when 20 => return "--max-tokens=99999999999999999999";
            when 21 => return "0";
            when 22 => return "-1";
            when 23 => return "never";
            when 24 => return [1 .. 200 => 'x'];
            when 25 => return Character'Val (16#FF#) & "bad";
            when 26 => return "--" & Character'Val (16#01#) & "ctl";
            when 27 => return "--unknown-option";
            when 28 => return "--PROMPT";
            when 29 => return "--prompt=--seed";
            when others => return "--interactive";
         end case;
      end Piece;

      Answered : Natural := 0;
   begin
      for Case_Number in 1 .. 4_000 loop
         declare
            Source : Fixed_Arguments;
            Item   : Opt.Command;
            Status : E.Error_Info;
            Count  : constant Natural := Draw (8);
         begin
            for Index in 1 .. Count loop
               Add (Source, Piece (Draw (31)));
            end loop;

            --  The property: it comes back, with an outcome, whatever it was
            --  handed. Which outcome is not the question here -- the cases
            --  above check that -- only that there is one and it arrived.
            Opt.Parse (Source, Item, Status);
            Answered := Answered + 1;

            Opt.Release (Item);
         end;
      end loop;

      Assert (Answered = 4_000,
              "only" & Natural'Image (Answered)
              & " of four thousand command lines were answered");
   end Any_Command_Line_Is_Answered;

   --  The conversation keeps its shape under the edits interactive mode makes.
   --
   --  Interactive mode needs a terminal, so its loop is driven by no test.
   --  What the loop does to the history, though, is ordinary calls: it sets a
   --  system message that must land first and replace rather than accumulate,
   --  and it drops a cancelled turn so that the history never holds a reply
   --  the model did not finish. Both are what keeps the displayed
   --  conversation and the model's context the same conversation.
   procedure Conversation_Survives_Interactive_Edits
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package C renames Model_Runner.Conversation;
      use type C.Role;

      Messages : C.History;
      Status   : E.Error_Info;
   begin
      C.Open (Messages, Status => Status);
      Assert (E.Is_Ok (Status), "the conversation did not open");
      Assert (not C.Has_System (Messages),
              "a fresh conversation claims a system message");

      C.Append (Messages, C.User_Role, "first", Status);
      C.Append (Messages, C.Assistant_Role, "second", Status);
      Assert (C.Length (Messages) = 2, "two messages did not append");

      --  A system message set after the fact goes first, not last, so the
      --  template renders it where a model expects it.
      C.Set_System (Messages, "be brief", Status);
      Assert (E.Is_Ok (Status), "a system message was refused");
      Assert (C.Has_System (Messages), "the system message was not recorded");
      Assert (C.Length (Messages) = 3, "the system message did not add one");
      Assert (C.Sender_At (Messages, 1) = C.System_Role,
              "the system message is not first");
      Assert (C.Content_At (Messages, 1) = "be brief",
              "the system message holds the wrong text: "
              & C.Content_At (Messages, 1));
      Assert (C.Content_At (Messages, 2) = "first",
              "the conversation was reordered around the system message");

      --  Setting it again replaces it rather than adding another.
      C.Set_System (Messages, "be briefer", Status);
      Assert (E.Is_Ok (Status), "replacing the system message was refused");
      Assert (C.Length (Messages) = 3,
              "replacing the system message added one:"
              & Natural'Image (C.Length (Messages)));
      Assert (C.Content_At (Messages, 1) = "be briefer",
              "the system message was not replaced");

      --  Setting it empty removes it and leaves the rest in order.
      C.Set_System (Messages, "", Status);
      Assert (E.Is_Ok (Status), "removing the system message was refused");
      Assert (not C.Has_System (Messages),
              "the system message survived being cleared");
      Assert (C.Length (Messages) = 2, "clearing removed more than itself");
      Assert (C.Content_At (Messages, 1) = "first",
              "clearing disturbed the conversation");

      --  A cancelled turn is dropped. The history must not hold a reply the
      --  model did not finish, because the next turn is rendered from it.
      C.Append (Messages, C.User_Role, "third", Status);
      C.Append (Messages, C.Assistant_Role, "unfinished", Status);
      Assert (C.Length (Messages) = 4, "the turn did not append");

      C.Drop_Last (Messages, 1);
      Assert (C.Length (Messages) = 3, "dropping one removed a different number");
      Assert (C.Content_At (Messages, 3) = "third",
              "dropping removed the wrong end of the conversation");

      --  Dropping more than there is empties it rather than going negative.
      C.Drop_Last (Messages, 99);
      Assert (C.Length (Messages) = 0,
              "dropping past the beginning left"
              & Natural'Image (C.Length (Messages)) & " messages");

      --  And it is usable afterwards rather than left in a broken state.
      C.Append (Messages, C.User_Role, "again", Status);
      Assert (E.Is_Ok (Status) and then C.Length (Messages) = 1,
              "the conversation was unusable after being emptied");

      C.Close (Messages);
   end Conversation_Survives_Interactive_Edits;

   --  What the engine refuses about a request, a conversation and a model,
   --  each by name.
   --
   --  These are refusals a caller meets rather than a file: a request asking
   --  for no tokens, an empty prompt, a prompt longer than the context, a
   --  message with no content, a conversation past its bound, and a model that
   --  is not ready. They are the library's contract with whatever drives it,
   --  and none of their codes appeared in a test.
   procedure Caller_Refusals_Report_Themselves
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;

         --  Generate with the current request and report the diagnostic.
         function Refusal (Prompt : String) return E.Error_Code is
         begin
            Gen.Generate
              (Under.Ready, Session, Prompt, Request, Stop,
               Sink'Unchecked_Access, null, null, null, null,
               Outcome => Outcome);
            declare
               Code : constant E.Error_Code := Outcome.Error.Code;
            begin
               Gen.Release (Outcome);
               return Code;
            end;
         end Refusal;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;

         --  A request for no tokens at all. Nothing to do is a mistake in the
         --  asking, not a run that produces nothing.
         Request.Max_Tokens := 0;
         Assert (Refusal ("ab") = E.Generation_Invalid_Request,
                 "a request for no tokens was accepted");

         --  A batch of no tokens, the same mistake in the other field.
         Request.Max_Tokens := 4;
         Request.Batch_Size := 0;
         Assert (Refusal ("ab") = E.Generation_Invalid_Request,
                 "a batch size of zero was accepted");

         --  An empty prompt is not reached from here and the case is left
         --  out rather than bent to fit: this vocabulary adds a beginning
         --  token, so empty text still tokenizes to one token and the engine
         --  has something to continue from. Reaching that refusal needs a
         --  vocabulary that adds nothing, which is a fixture this suite does
         --  not have.
         Request.Batch_Size := 8;

         --  A prompt longer than the context can hold. The tiny model's
         --  context is sixteen tokens, so this is not a large prompt, only a
         --  larger one than the model was built for.
         Assert (Refusal ([1 .. 200 => 'a']) = E.Generation_Prompt_Too_Long,
                 "a prompt past the context was accepted");

         --  And a request the engine accepts, so none of the above can come
         --  from an engine that refuses whatever it is given.
         Assert (Refusal ("ab") = E.No_Error,
                 "a sound request was refused");

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
      end;

      --  A model still holding an open session is not a model to release.
      --  Closing it would leave the session pointing at freed tensors.
      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         L.Close (Under.Ready, Status);
         Assert (Status.Code = E.Lifecycle_Session_Active,
                 "a model with a live session was released: "
                 & E.Error_Code'Image (Status.Code));

         L.Close (Session);
         L.Close (Under.Ready, Status);
         Assert (E.Is_Ok (Status),
                 "a model was refused after its session closed: "
                 & E.Error_Code'Image (Status.Code));
      end;

      B.Free (Image);

      --  A conversation refuses the same way.
      declare
         Messages : Model_Runner.Conversation.History;
         Status   : E.Error_Info;
      begin
         Model_Runner.Conversation.Open (Messages, Status => Status);
         Assert (E.Is_Ok (Status), "the conversation did not open");

         Model_Runner.Conversation.Append
           (Messages, Model_Runner.Conversation.User_Role, "", Status);
         Assert (Status.Code = E.Conversation_Empty,
                 "a message with no content was accepted: "
                 & E.Error_Code'Image (Status.Code));

         Model_Runner.Conversation.Append
           (Messages, Model_Runner.Conversation.User_Role, "hi", Status);
         Assert (E.Is_Ok (Status), "a sound message was refused");

         Model_Runner.Conversation.Close (Messages);
      end;

      --  A conversation refuses a message past its bound. Tightened for the
      --  test rather than filled to the built-in four thousand: what is being
      --  checked is that the bound is applied and reported, not what it is.
      declare
         Bounds   : Model_Runner.Limits.Session_Limits :=
           Model_Runner.Limits.Default_Session_Limits;
         Messages : Model_Runner.Conversation.History;
         Status   : E.Error_Info;
      begin
         Bounds.Max_Messages := 3;
         Model_Runner.Conversation.Open (Messages, Bounds, Status);
         Assert (E.Is_Ok (Status), "the bounded conversation did not open");

         for Index in 1 .. 3 loop
            Model_Runner.Conversation.Append
              (Messages, Model_Runner.Conversation.User_Role, "hi", Status);
            Assert (E.Is_Ok (Status),
                    "a message inside the bound was refused at"
                    & Integer'Image (Index));
         end loop;

         Model_Runner.Conversation.Append
           (Messages, Model_Runner.Conversation.User_Role, "hi", Status);
         Assert (Status.Code = E.Conversation_Too_Long,
                 "a message past the bound was accepted: "
                 & E.Error_Code'Image (Status.Code));

         Model_Runner.Conversation.Close (Messages);
      end;

      --  And the other bound, which is on the bytes rather than the count.
      --  A conversation can reach its storage limit with room left for more
      --  messages, and that is the limit an interactive session actually
      --  meets: it grows by what was said, not by how often.
      declare
         Bounds   : Model_Runner.Limits.Session_Limits :=
           Model_Runner.Limits.Default_Session_Limits;
         Messages : Model_Runner.Conversation.History;
         Status   : E.Error_Info;
         Filled   : Natural := 0;
      begin
         Bounds.Max_Rendered_Bytes := 64;
         Model_Runner.Conversation.Open (Messages, Bounds, Status);
         Assert (E.Is_Ok (Status), "the byte-bounded conversation did not open");

         --  Well inside the message count, and past the storage.
         for Index in 1 .. 8 loop
            Model_Runner.Conversation.Append
              (Messages, Model_Runner.Conversation.User_Role,
               "0123456789abcdef", Status);
            exit when E.Is_Error (Status);
            Filled := Filled + 1;
         end loop;

         Assert (Status.Code = E.Conversation_Too_Long,
                 "a conversation past its storage was accepted: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Filled > 0,
                 "the storage bound refused the first message as well");
         Assert (Filled < 8,
                 "the storage bound was never reached");

         Model_Runner.Conversation.Close (Messages);
      end;

      --  A model that was never prepared is not a model to generate from.
      declare
         Unprepared : L.Model;
         Session    : L.Session;
         Stop       : Model_Runner.Stops.Set;
         Request    : Gen.Request;
         Outcome    : Gen.Result;
         Status     : E.Error_Info;
      begin
         Model_Runner.Stops.Open (Stop);
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;

         Gen.Generate
           (Unprepared, Session, "ab", Request, Stop,
            null, null, null, null, null, Outcome => Outcome);

         Assert (Outcome.Error.Code = E.Lifecycle_Model_Not_Ready,
                 "generating from an unprepared model was accepted: "
                 & E.Error_Code'Image (Outcome.Error.Code));

         Gen.Release (Outcome);
         Model_Runner.Stops.Close (Stop);
         L.Close (Unprepared, Status);
      end;
   end Caller_Refusals_Report_Themselves;

   --  What a prompt file can be wrong about, each reported by name.
   --
   --  A prompt file is named by the reader and read by the program, so the
   --  ways it can fail are ordinary and the diagnostics have to tell them
   --  apart: a path that is not there, a path that is not a file, a file too
   --  large to accept, and one that is not text. Asserting merely that the
   --  run failed would let any of them stand in for the others.
   procedure Prompt_File_Failures_Report_Themselves
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model  : constant String := "obj/promptfile-model.gguf";
      Errors : constant String := "obj/promptfile-errors.txt";

      --  Run with a prompt file and return what reached standard error.
      function Diagnostics (Prompt_Path : String) return String is
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
         Room   : String (1 .. 2_048);
         Used   : Natural := 0;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--prompt-file");
         Add (Source, Prompt_Path);
         Add (Source, "--max-tokens");
         Add (Source, "1");

         Create (Handle, Out_File, Errors);
         Set_Error (Handle);
         begin
            Model_Runner.CLI.Driver.Run (Source, Status);
         exception
            when others =>
               null;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         Open (Handle, In_File, Errors);
         while not End_Of_File (Handle) and then Used < Room'Length - 300 loop
            declare
               Line : String (1 .. 300);
               Last : Natural;
            begin
               Get_Line (Handle, Line, Last);
               Room (Used + 1 .. Used + Last) := Line (1 .. Last);
               Used := Used + Last + 1;
               Room (Used) := ' ';
            end;
         end loop;
         Close (Handle);
         return Room (1 .. Used);
      end Diagnostics;

      --  Write a file of Size bytes without holding it in memory.
      procedure Write_Sized (Path : String; Size : Natural) is
         use Ada.Streams;
         Output : Ada.Streams.Stream_IO.File_Type;
         Chunk  : constant Stream_Element_Array (1 .. 65_536) :=
           [others => Stream_Element (Character'Pos ('x'))];
         Left   : Natural := Size;
      begin
         Ada.Streams.Stream_IO.Create (Output, Ada.Streams.Stream_IO.Out_File, Path);
         while Left > 0 loop
            declare
               Take : constant Natural := Natural'Min (Left, Chunk'Length);
            begin
               Ada.Streams.Stream_IO.Write
                 (Output, Chunk (1 .. Stream_Element_Offset (Take)));
               Left := Left - Take;
            end;
         end loop;
         Ada.Streams.Stream_IO.Close (Output);
      end Write_Sized;
   begin
      Tiny_Model.Write (Model);

      --  Not there.
      declare
         Text : constant String := Diagnostics ("obj/no-such-prompt-xyzzy");
      begin
         Assert (Contains (Text, "MR-IO-0001"),
                 "a missing prompt file was not reported as unopenable: "
                 & Text);
      end;

      --  There, and not a file.
      declare
         Text : constant String := Diagnostics ("obj");
      begin
         Assert (Contains (Text, "MR-IO-0005"),
                 "a directory was not reported as not a regular file: "
                 & Text);
      end;

      --  A file, and not text. The prompt reaches the tokenizer, so what is
      --  not UTF-8 has to stop before it.
      declare
         Path : constant String := "obj/promptfile-binary.txt";
         Handle : Ada.Streams.Stream_IO.File_Type;
      begin
         Ada.Streams.Stream_IO.Create (Handle, Ada.Streams.Stream_IO.Out_File, Path);
         for Value of Ada.Streams.Stream_Element_Array'[16#68#, 16#69#,
                                                        16#FF#, 16#FE#]
         loop
            Ada.Streams.Stream_Element'Write
              (Ada.Streams.Stream_IO.Stream (Handle), Value);
         end loop;
         Ada.Streams.Stream_IO.Close (Handle);

         declare
            Text : constant String := Diagnostics (Path);
         begin
            Assert (Contains (Text, "MR-IO-0006"),
                    "a prompt file that is not UTF-8 was accepted: " & Text);
         end;
         Ada.Directories.Delete_File (Path);
      end;

      --  A file past the limit. Refused on its size before it is read, so
      --  the bytes are never held.
      declare
         Path  : constant String := "obj/promptfile-large.txt";
         Limit : constant Natural :=
           Model_Runner.Limits.Default_Session_Limits.Max_Prompt_Bytes;
      begin
         Write_Sized (Path, Limit + 1);
         declare
            Text : constant String := Diagnostics (Path);
         begin
            Assert (Contains (Text, "MR-IO-0004"),
                    "a prompt file past the limit was accepted: " & Text);
         end;
         Ada.Directories.Delete_File (Path);
      end;

      --  And a prompt file that is none of those things is read.
      declare
         Path   : constant String := "obj/promptfile-good.txt";
         Handle : File_Type;
      begin
         Create (Handle, Out_File, Path);
         Put (Handle, "ab");
         Close (Handle);

         declare
            Text : constant String := Diagnostics (Path);
         begin
            Assert (not Contains (Text, "MR-IO-"),
                    "a sound prompt file was refused: " & Text);
         end;
         Ada.Directories.Delete_File (Path);
      end;

      Ada.Directories.Delete_File (Model);
      Ada.Directories.Delete_File (Errors);
   end Prompt_File_Failures_Report_Themselves;

   --  Interactive mode needs a terminal at both ends.
   --
   --  Chosen implicitly, when no prompt source is given, it was already
   --  conditional on both being terminals. Asked for by name it was not
   --  checked at all, so a redirected session drew prompts nobody saw and
   --  read a file as though someone were typing it. The diagnostic for that
   --  existed from the start with nothing producing it.
   --
   --  The decision is tested here rather than through the driver on purpose.
   --  Running the driver with --interactive would consult the real descriptors
   --  of whatever ran the suite: on a terminal it would enter the session and
   --  wait for input, and a test that hangs on a developer's machine while
   --  passing everywhere else is worse than no test.
   procedure Interaction_Needs_Both_Terminals
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Pres renames Model_Runner.Presentation;

      --  Report what the decision is for one combination.
      function Possible (Input, Output : Boolean) return Boolean is
      begin
         return Pres.Supports_Interaction
           ((Input_Is_Terminal  => Input,
             Output_Is_Terminal => Output,
             Error_Is_Terminal  => True,
             Colour_Suppressed  => False));
      end Possible;
   begin
      Assert (Possible (Input => True, Output => True),
              "a session with terminals at both ends was refused");
      Assert (not Possible (Input => False, Output => True),
              "a session reading a file was allowed");
      Assert (not Possible (Input => True, Output => False),
              "a session writing into a redirection was allowed");
      Assert (not Possible (Input => False, Output => False),
              "a session with neither end on a terminal was allowed");
   end Interaction_Needs_Both_Terminals;

   --  A cancelled generation stops, in prefill and in the decode loop alike.
   --
   --  Generation checks for cancellation twice, between prefill batches and
   --  between produced tokens, and this test does not hold either of them:
   --  measured by disabling each in turn, nothing fails, because the forward
   --  pass below observes the same request and returns the same code. They
   --  stop the work a batch or a token earlier, which no test of the outcome
   --  can see.
   --
   --  What it does hold is the behaviour a reader depends on: a run asked to
   --  stop reports that it stopped, one asked before it began produces
   --  nothing and leaves the cache at zero, and one asked while decoding
   --  stops short of its allowance.
   procedure Cancelled_Generation_Stops
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image);

      --  Standing before the run starts: nothing is produced at all.
      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Flag    : aliased Model_Runner.Cancellation.Token;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);

         Request.Max_Tokens := 4;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
         Flag.Request;

         Gen.Generate
           (Under.Ready, Session, "ab", Request, Stop,
            Sink'Unchecked_Access, null, null, null,
            Flag'Unchecked_Access, Outcome => Outcome);

         Assert (Outcome.Reason = Gen.Cancelled,
                 "a standing request did not cancel the run: "
                 & Gen.Completion_Reason'Image (Outcome.Reason));
         Assert (Outcome.Generated_Tokens = 0,
                 "a run cancelled before it began produced"
                 & Natural'Image (Outcome.Generated_Tokens) & " tokens");
         Assert (Captured (Sink) = "",
                 "a run cancelled before it began wrote: " & Captured (Sink));
         Assert (L.Position (Session) = 0,
                 "a run cancelled before it began moved the cache to"
                 & Natural'Image (L.Position (Session)));

         Gen.Release (Outcome);
         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
      end;

      --  Asked for once the first token has been produced, which is inside
      --  the decode loop rather than before it.
      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Flag    : aliased Model_Runner.Cancellation.Token;
         Asking  : aliased Cancel_On_Stage :=
           (Flag  => Flag'Unchecked_Access,
            Stage => Model_Runner.Progress.Token_Produced);
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Model_Runner.Stops.Open (Stop);

         Request.Max_Tokens := 8;
         Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;

         Gen.Generate
           (Under.Ready, Session, "ab", Request, Stop,
            Sink'Unchecked_Access, Asking'Unchecked_Access, null, null,
            Flag'Unchecked_Access, Outcome => Outcome);

         Assert (Outcome.Reason = Gen.Cancelled,
                 "a request made during decoding did not cancel the run: "
                 & Gen.Completion_Reason'Image (Outcome.Reason));
         Assert (Outcome.Generated_Tokens < Request.Max_Tokens,
                 "a cancelled run produced its whole allowance");

         Gen.Release (Outcome);
         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
      end;

      B.Free (Image);
   end Cancelled_Generation_Stops;

   --  The end token ends the run, and nothing of it reaches the output.
   --
   --  This is how a real model finishes a reply, and it was the one completion
   --  reason with no test: the other seven are reached by a stop token, a stop
   --  string, the token limit, a full context, cancellation, a closed output
   --  and an internal failure, and every one of those has a case.
   --
   --  Which token these weights produce first is not something to hard-code,
   --  so the vocabulary's end token is varied instead. Exactly one value can
   --  stop the run before it has produced anything -- the token the model
   --  reaches for first -- and that is the case worth checking, because it is
   --  the one where a mistake would show as text that should never have been
   --  emitted.
   procedure End_Of_Sequence_Ends_Run
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Ended     : Natural := 0;
      Immediate : Natural := 0;
   begin
      for Token in 0 .. Tiny_Model.Vocabulary - 1 loop
         declare
            Image : B.Byte_Array_Access;
         begin
            Tiny_Model.Build (Image, End_Token => Token);

            declare
               Held    : aliased constant B.Byte_Array := Image.all;
               Under   : Harness (Held'Access);
               Session : L.Session;
               Stop    : Model_Runner.Stops.Set;
               Sink    : aliased Capture_Sink;
               Request : Gen.Request;
               Outcome : Gen.Result;
               Status  : E.Error_Info;
            begin
               Start (Under);
               L.Open (Session, Under.Ready, Status => Status);
               Model_Runner.Stops.Open (Stop);

               Request.Max_Tokens := 4;
               Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;

               Gen.Generate
                 (Under.Ready, Session, "ab", Request, Stop,
                  Sink'Unchecked_Access, null, null, null, null,
                  Outcome => Outcome);

               if Outcome.Reason = Gen.End_Of_Sequence then
                  Ended := Ended + 1;

                  if Outcome.Generated_Tokens = 0 then
                     Immediate := Immediate + 1;
                     Assert (Captured (Sink) = "",
                             "the end token reached the output: "
                             & Captured (Sink));
                  end if;
               end if;

               Gen.Release (Outcome);
               Model_Runner.Stops.Close (Stop);
               L.Close (Session);
            end;

            B.Free (Image);
         end;
      end loop;

      Assert (Ended > 0,
              "no end token ended a run, so the path was never taken");
      Assert (Immediate = 1,
              "expected exactly one token to stop the run before it produced"
              & " anything, found" & Natural'Image (Immediate));
   end End_Of_Sequence_Ends_Run;

   --  A seed is unsigned, everywhere it is parsed, stored and shown.
   --
   --  The program generates a seed across the whole 64-bit range and then
   --  converted it to a signed type to print it, which raises for every value
   --  above Long_Long_Integer'Last -- about half of all runs. With one worker
   --  that ended the run as an internal failure; with more, the exception left
   --  the block holding the worker pool before the workers were told to stop,
   --  and leaving that block waits for them, so the program hung instead of
   --  reporting anything. Thirteen of twenty verbose runs hung.
   --
   --  The same conversion rejected any --seed above that bound, so a run whose
   --  seed came from the upper half could not be reproduced, which is what the
   --  option exists for.
   procedure Seeds_Cover_The_Unsigned_Range
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Largest : constant String := "18446744073709551615";
      Model   : constant String := "obj/seed-test-model.gguf";
      Errors  : constant String := "obj/seed-test-errors.txt";

      --  A seed the option cannot represent is refused, not wrapped.
      procedure Refuse (Value : String) is
         Source : Fixed_Arguments;
         Item   : Opt.Command;
         Status : E.Error_Info;
      begin
         Add (Source, "run");
         Add (Source, "model.gguf");
         Add (Source, "--seed");
         Add (Source, Value);
         Opt.Parse (Source, Item, Status);
         Assert (E.Is_Error (Status),
                 "a seed outside the range was accepted: " & Value);
         Opt.Release (Item);
      end Refuse;
   begin
      --  Formatting does not go through a signed type.
      Assert (T.Image (Interfaces.Unsigned_64'Last) = Largest,
              "the largest seed did not format: "
              & T.Image (Interfaces.Unsigned_64'Last));
      Assert (T.Image (Interfaces.Unsigned_64'(0)) = "0",
              "zero did not format");

      --  Parsing accepts the whole range and refuses what is outside it.
      declare
         Source : Fixed_Arguments;
         Item   : Opt.Command;
         Status : E.Error_Info;
      begin
         Add (Source, "run");
         Add (Source, "model.gguf");
         Add (Source, "--seed");
         Add (Source, Largest);
         Opt.Parse (Source, Item, Status);
         Assert (E.Is_Ok (Status),
                 "the largest seed was rejected: "
                 & E.Error_Code'Image (Status.Code));
         Assert (Item.Has_Seed and then Item.Seed = Interfaces.Unsigned_64'Last,
                 "the largest seed did not survive parsing");
         Opt.Release (Item);
      end;

      Refuse ("18446744073709551616");
      Refuse ("-1");
      Refuse ("99999999999999999999999");
      Refuse ("twelve");

      --  And a whole run with such a seed reports it rather than failing on
      --  it. One worker on purpose: if this regresses with several, the run
      --  does not fail, it stops responding, and a test that hangs tells
      --  nobody anything.
      declare
         use Ada.Text_IO;
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
         Found  : Boolean := False;
      begin
         Tiny_Model.Write (Model);

         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "2");
         Add (Source, "--threads");
         Add (Source, "1");
         Add (Source, "--seed");
         Add (Source, Largest);
         Add (Source, "--verbose");

         Create (Handle, Out_File, Errors);
         Set_Error (Handle);
         Model_Runner.CLI.Driver.Run (Source, Status);
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status = 0,
                 "a run with the largest seed failed with status"
                 & Natural'Image (Status));

         Open (Handle, In_File, Errors);
         while not End_Of_File (Handle) loop
            declare
               Line : String (1 .. 300);
               Last : Natural;
            begin
               Get_Line (Handle, Line, Last);
               if Contains (Line (1 .. Last), Largest) then
                  Found := True;
               end if;
            end;
         end loop;
         Close (Handle);

         Assert (Found, "the statistics did not report the seed");

         Ada.Directories.Delete_File (Model);
         Ada.Directories.Delete_File (Errors);
      end;
   end Seeds_Cover_The_Unsigned_Range;

   --  What the reader typed does not appear in the diagnostics.
   --
   --  The program states that it does not log prompts, system messages,
   --  generated text or conversation history, and does not persist a
   --  conversation. That is a privacy guarantee rather than a preference, and
   --  nothing checked it. The obvious way to break it is a diagnostic that
   --  quotes the input it is complaining about, which is exactly what a
   --  helpful error message wants to do.
   procedure Prompts_Are_Not_Logged
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model  : constant String := "obj/privacy-test-model.gguf";
      Errors : constant String := "obj/privacy-test-errors.txt";

      --  Nothing that could occur in a message, a template or a token.
      Prompt : constant String := "zqxjvwk";
      System : constant String := "hgfdplm";

      --  Every simple name in a directory, in one string, so that two of
      --  them can be compared. Naming the files a run must not leave behind
      --  only rules out the names somebody thought of.
      function Listing (Directory : String) return String is
         package Dirs renames Ada.Directories;
         Search : Dirs.Search_Type;
         Item   : Dirs.Directory_Entry_Type;
         Room   : String (1 .. 8_192);
         Used   : Natural := 0;

         procedure Note (Text : String) is
         begin
            if Used + Text'Length + 1 <= Room'Length then
               Room (Used + 1 .. Used + Text'Length) := Text;
               Used := Used + Text'Length + 1;
               Room (Used) := '|';
            end if;
         end Note;
      begin
         if not Dirs.Exists (Directory) then
            return "";
         end if;

         Dirs.Start_Search (Search, Directory, "");
         while Dirs.More_Entries (Search) loop
            Dirs.Get_Next_Entry (Search, Item);
            Note (Dirs.Simple_Name (Item));
         end loop;
         Dirs.End_Search (Search);
         return Room (1 .. Used);
      end Listing;

      --  What was there before the runs.
      Before_Obj  : String (1 .. 8_192);
      Obj_Used    : Natural := 0;
      Before_Here : String (1 .. 8_192);
      Here_Used   : Natural := 0;

      --  Run the program and return everything it wrote to standard error.
      function Diagnostics (Source : in out Fixed_Arguments) return String is
         Handle : File_Type;
         Status : Natural;
         Room   : String (1 .. 16_384);
         Used   : Natural := 0;
      begin
         Create (Handle, Out_File, Errors);
         Set_Error (Handle);

         begin
            Model_Runner.CLI.Driver.Run (Source, Status);
         exception
            when others =>
               null;
         end;

         Set_Error (Standard_Error);
         Close (Handle);

         Open (Handle, In_File, Errors);
         while not End_Of_File (Handle) and then Used < Room'Length - 200 loop
            declare
               Line : String (1 .. 200);
               Last : Natural;
            begin
               Get_Line (Handle, Line, Last);
               Room (Used + 1 .. Used + Last) := Line (1 .. Last);
               Used := Used + Last + 1;
               Room (Used) := ' ';
            end;
         end loop;
         Close (Handle);

         return Room (1 .. Used);
      end Diagnostics;
   begin
      Tiny_Model.Write (Model);

      --  The capture file is this test's own, so it belongs to the state
      --  the runs start from rather than to what they leave behind.
      declare
         Handle : File_Type;
      begin
         Create (Handle, Out_File, Errors);
         Close (Handle);
      end;

      declare
         Obj_Now  : constant String := Listing ("obj");
         Here_Now : constant String := Listing (".");
      begin
         Before_Obj (1 .. Obj_Now'Length) := Obj_Now;
         Obj_Used := Obj_Now'Length;
         Before_Here (1 .. Here_Now'Length) := Here_Now;
         Here_Used := Here_Now'Length;
      end;

      --  A run that succeeds, at the loudest setting the program offers.
      --  Verbose is where a prompt would leak if anywhere.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, Prompt);
         Add (Source, "--max-tokens");
         Add (Source, "3");
         Add (Source, "--verbose");

         declare
            Text : constant String := Diagnostics (Source);
         begin
            --  The capture works and the run said something, so an empty
            --  string cannot be what passes this test.
            Assert (Contains (Text, "generating") or else Contains (Text, "model"),
                    "no diagnostics were captured, so the check is vacuous: "
                    & Text);
            Assert (not Contains (Text, Prompt),
                    "the prompt appeared in the diagnostics: " & Text);
         end;
      end;

      --  A run that fails. The failure is about the prompt's size, which is
      --  the diagnostic most likely to quote it.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--prompt");
         Add (Source, Prompt);
         Add (Source, "--system");
         Add (Source, System);
         Add (Source, "--verbose");

         declare
            Text : constant String := Diagnostics (Source);
         begin
            Assert (Text'Length > 0, "the failing run said nothing at all");
            Assert (not Contains (Text, Prompt),
                    "the prompt appeared in a failure diagnostic: " & Text);
            Assert (not Contains (Text, System),
                    "the system message appeared in a failure diagnostic: "
                    & Text);
         end;
      end;

      --  Nothing was written anywhere either: a conversation is not
      --  persisted, and a run leaves behind no file the reader did not ask
      --  for. Compared as whole directory listings rather than by name,
      --  because a name has to be guessed and the one that matters is the
      --  one nobody thought of.
      Assert (Listing ("obj") = Before_Obj (1 .. Obj_Used),
              "a run left something behind in obj");
      Assert (Listing (".") = Before_Here (1 .. Here_Used),
              "a run left something behind in the working directory");

      Ada.Directories.Delete_File (Model);
      Ada.Directories.Delete_File (Errors);
   end Prompts_Are_Not_Logged;

   --  A prompt taken from standard input is bounded, and what it refuses it
   --  says plainly.
   --
   --  This is the only prompt source with no size known in advance, and it was
   --  the one that read without a bound: input of one very long line was put on
   --  the stack and the Storage_Error that followed was reported as a failure
   --  to read, while input of many short lines produced an internal error.
   --  Neither told the reader that the prompt was simply too big.
   procedure Standard_Input_Prompt_Is_Bounded
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model  : constant String := "obj/stdin-test-model.gguf";
      Input  : constant String := "obj/stdin-test-input.txt";
      Errors : constant String := "obj/stdin-test-errors.txt";

      Limit : constant Natural :=
        Model_Runner.Limits.Default_Session_Limits.Max_Prompt_Bytes;

      --  Run the program over Content on standard input and return what it
      --  wrote to standard error. The exit status comes back in Status.
      function Diagnostics_For
        (Content : String;
         Repeat  : Natural;
         Status  : out Natural) return String
      is
         Handle : File_Type;
         Result : Model_Runner.Text.Bounded;
      begin
         Create (Handle, Out_File, Input);
         for Index in 1 .. Repeat loop
            Put (Handle, Content);
         end loop;
         Close (Handle);

         declare
            Source     : Fixed_Arguments;
            In_File_Id : File_Type;
            Err_File   : File_Type;
         begin
            Add (Source, "run");
            Add (Source, Model);
            Add (Source, "--max-tokens");
            Add (Source, "1");

            Open (In_File_Id, In_File, Input);
            Create (Err_File, Out_File, Errors);

            --  Both are restored below. The program reads the current input
            --  and writes the current error, so a test can supply them.
            Set_Input (In_File_Id);
            Set_Error (Err_File);

            begin
               Model_Runner.CLI.Driver.Run (Source, Status);
            exception
               when others =>
                  Status := 8;
            end;

            Set_Input (Standard_Input);
            Set_Error (Standard_Error);
            Close (In_File_Id);
            Close (Err_File);
         end;

         --  Only the first line is wanted, and only its beginning.
         declare
            Handle_In : File_Type;
         begin
            Open (Handle_In, In_File, Errors);
            if not End_Of_File (Handle_In) then
               declare
                  Room : String (1 .. 400);
                  Last : Natural;
               begin
                  Get_Line (Handle_In, Room, Last);
                  Result := Model_Runner.Text.To_Bounded (Room (1 .. Last));
               end;
            end if;
            Close (Handle_In);
         end;

         return Model_Runner.Text.To_String (Result);
      end Diagnostics_For;

      Status : Natural;
   begin
      Tiny_Model.Write (Model);

      --  One line longer than the limit. This is the shape that used to be
      --  put on the stack in one piece.
      declare
         Line : constant String (1 .. 1024) := [others => 'a'];
         Text : constant String :=
           Diagnostics_For (Line, Limit / Line'Length + 1, Status);
      begin
         Assert (Status = 6,
                 "one over-long line gave exit status" & Natural'Image (Status)
                 & " rather than an input failure");
         Assert (Contains (Text, "MR-IO-0009"),
                 "an over-long line was not reported as too large: " & Text);
         Assert (not Contains (Text, "<error."),
                 "the diagnostic rendered as a bare message key: " & Text);
      end;

      --  The same amount of text as many short lines, which used to end as an
      --  internal error.
      declare
         Line : constant String := "abcdefghijklmno" & ASCII.LF;
         Text : constant String :=
           Diagnostics_For (Line, Limit / Line'Length + 1, Status);
      begin
         Assert (Status = 6,
                 "many short lines gave exit status" & Natural'Image (Status)
                 & " rather than an input failure");
         Assert (Contains (Text, "MR-IO-0009"),
                 "short lines over the limit were not reported as too large: "
                 & Text);
      end;

      --  Input that is not UTF-8 is refused, and the message says so rather
      --  than naming a key: standard input has no path, and the message for
      --  this condition asks for one.
      declare
         Text : constant String :=
           Diagnostics_For
             ("hello " & Character'Val (16#FF#) & Character'Val (16#FE#),
              1, Status);
      begin
         Assert (Status = 6,
                 "invalid UTF-8 gave exit status" & Natural'Image (Status));
         Assert (Contains (Text, "MR-IO-0006"),
                 "invalid UTF-8 was not reported as such: " & Text);
         Assert (not Contains (Text, "<error."),
                 "the diagnostic rendered as a bare message key: " & Text);
      end;

      --  And a prompt within the limit is read rather than refused. The tiny
      --  model's context is far too small to answer it, which is a different
      --  complaint and proves the prompt got through.
      declare
         Text : constant String := Diagnostics_For ("hello", 1, Status);
      begin
         Assert (Status /= 6,
                 "an acceptable prompt was refused as input failure: " & Text);
      end;

      Ada.Directories.Delete_File (Model);
      Ada.Directories.Delete_File (Input);
      Ada.Directories.Delete_File (Errors);
   end Standard_Input_Prompt_Is_Bounded;

   --------------------
   -- Register_Tests --
   --------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Run_Command_Parses'Access,
         "a well-formed run command parses into the values it named");
      Register_Routine
        (T, Usage_Errors_Reported'Access,
         "each malformed command line reports the code that names it");
      Register_Routine
        (T, End_Of_Options_Honoured'Access,
         "arguments after the end-of-options marker are operands");
      Register_Routine
        (T, Preliminary_Scans'Access,
         "the locale and colour pre-parse scans find only what is there");
      Register_Routine
        (T, Generation_Is_Reproducible'Access,
         "a fixed seed reproduces the same generated text");
      Register_Routine
        (T, Stop_String_Truncates'Access,
         "a stop string ends the run and none of it is streamed");
      Register_Routine
        (T, Stop_Token_Ends_Run'Access,
         "a stop token ends the run before any text is produced");
      Register_Routine
        (T, Closed_Output_Is_Normal'Access,
         "a closed destination ends the run without a failure");
      Register_Routine
        (T, Context_Budget_Checked'Access,
         "an impossible context request is rejected before evaluation");
      Register_Routine
        (T, Retained_Text_Matches'Access,
         "retained text matches what was streamed");
      Register_Routine
        (T, Any_Command_Line_Is_Answered'Access,
         "any command line is answered rather than raised on");
      Register_Routine
        (T, Conversation_Survives_Interactive_Edits'Access,
         "the conversation keeps its shape under the edits interactive makes");
      Register_Routine
        (T, Caller_Refusals_Report_Themselves'Access,
         "requests, conversations and models refuse by name");
      Register_Routine
        (T, Prompt_File_Failures_Report_Themselves'Access,
         "each way a prompt file can be wrong reports the code that names it");
      Register_Routine
        (T, Interaction_Needs_Both_Terminals'Access,
         "interactive mode needs a terminal at both ends");
      Register_Routine
        (T, Cancelled_Generation_Stops'Access,
         "a cancelled generation stops in prefill and in the decode loop");
      Register_Routine
        (T, End_Of_Sequence_Ends_Run'Access,
         "the end token ends the run and reaches no output");
      Register_Routine
        (T, Seeds_Cover_The_Unsigned_Range'Access,
         "a seed covers the unsigned range in parsing, storage and display");
      Register_Routine
        (T, Prompts_Are_Not_Logged'Access,
         "what the reader typed does not appear in the diagnostics");
      Register_Routine
        (T, Standard_Input_Prompt_Is_Bounded'Access,
         "a prompt from standard input is bounded and refused plainly");
      Register_Routine
        (T, Model_File_Is_Never_Modified'Access,
         "the model file is never written to");
      Register_Routine
        (T, Reference_Comparison_Works'Access,
         "the reference comparison accepts a match and rejects a mismatch");
   end Register_Tests;

end Tests.CLI_Cases;
