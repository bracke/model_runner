with AUnit.Assertions;

with Interfaces;

with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Output;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

with Ada.Directories;
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

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
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
        (T, Reference_Comparison_Works'Access,
         "the reference comparison accepts a match and rejects a mismatch");
   end Register_Tests;

end Tests.CLI_Cases;
