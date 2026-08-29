with AUnit.Assertions;

with Interfaces;

with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.CLI.Driver;

with Ada.Strings.Unbounded;
with Ada.Text_IO.Text_Streams;
with Captured_Output;
with Project_Tools.Files;
with Project_Tools.Processes;
with Project_Tools.Text;
with Model_Runner.CLI.Options;
with Model_Runner.Cancellation;
with Model_Runner.CLI.Interactive;
with Model_Runner.Conversation;
with Model_Runner.Errors;
with Model_Runner.Localization;
with Model_Runner.Platform;
with Model_Runner.Platform.Device;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Presentation;
with Model_Runner.Kernels;
with Fixtures;
with Model_Runner.Memory;
with Model_Runner.Progress;
with Model_Runner.Limits;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Generation;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Output;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Backend.Device;
with Model_Runner.GGUF;
with Model_Runner.Tensors;
with Model_Runner.Quantization;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

with Ada.Calendar;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Text_IO;

with Expectations;
with External_Model;
with Host_Load;
with Speed_Run;
with Tiny_Model;

package body Tests.CLI_Cases is

   use AUnit.Assertions;
   use type Model_Runner.CLI.Options.Color_Mode;
   use type Model_Runner.CLI.Options.Command_Kind;
   use type Model_Runner.CLI.Options.Prompt_Source;
   use type Model_Runner.CLI.Options.Turn_Kind;
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

   --  The turns that close a tool loop parse in the order they were written.
   --
   --  Which reply a tool's answer follows is the whole shape of a tool loop.
   --  A parser that kept the replies in one list and the answers in another
   --  would parse every option here and lose the only thing they say.
   procedure Turns_Parse_In_Order
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Source : Fixed_Arguments;
      Item   : Opt.Command;
      Status : E.Error_Info;
   begin
      Add (Source, "run");
      Add (Source, "model.gguf");
      Add (Source, "--prompt");
      Add (Source, "weather?");
      Add (Source, "--assistant");
      Add (Source, "<tool_call>{}</tool_call>");
      Add (Source, "--tool-result");
      Add (Source, "18");
      Add (Source, "--assistant-file");
      Add (Source, "second.txt");
      Add (Source, "--tool-result-file");
      Add (Source, "answer.txt");

      Opt.Parse (Source, Item, Status);
      Assert (E.Is_Ok (Status),
              "a command carrying turns was rejected: "
              & E.Error_Code'Image (Status.Code));
      Assert (Item.Turn_Count = 4,
              "the turns were not all kept:" & Natural'Image (Item.Turn_Count));
      Assert (Item.Turn_Kinds (1) = Opt.Turn_Assistant
              and then Item.Turn_Kinds (2) = Opt.Turn_Tool
              and then Item.Turn_Kinds (3) = Opt.Turn_Assistant
              and then Item.Turn_Kinds (4) = Opt.Turn_Tool,
              "the turns came back in another order than they were written");
      Assert (Item.Turn_Texts (1) /= null
              and then Item.Turn_Texts (1).all = "<tool_call>{}</tool_call>",
              "a reply's text was not kept");
      Assert (Item.Turn_Texts (2) /= null
              and then Item.Turn_Texts (2).all = "18",
              "a tool's answer was not kept");
      Assert (Item.Turn_Texts (3) = null
              and then T.To_String (Item.Turn_Paths (3)) = "second.txt",
              "a reply named by file was kept as text");
      Assert (T.To_String (Item.Turn_Paths (4)) = "answer.txt",
              "an answer named by file was not kept as a path");
      Opt.Release (Item);

      --  Raw mode has no conversation for a turn to be part of, and an
      --  interactive session holds its own. Both are refused rather than
      --  accepted and dropped.
      Source.Used := 0;
      Add (Source, "run");
      Add (Source, "model.gguf");
      Add (Source, "--raw");
      Add (Source, "--prompt");
      Add (Source, "hi");
      Add (Source, "--tool-result");
      Add (Source, "18");
      Opt.Parse (Source, Item, Status);
      Assert (Status.Code = E.CLI_Raw_Mode_Conflict,
              "a turn in raw mode was accepted: "
              & E.Error_Code'Image (Status.Code));
      Opt.Release (Item);

      Source.Used := 0;
      Add (Source, "run");
      Add (Source, "model.gguf");
      Add (Source, "--interactive");
      Add (Source, "--assistant");
      Add (Source, "yo");
      Opt.Parse (Source, Item, Status);
      Assert (Status.Code = E.CLI_Option_Combination,
              "a turn beside --interactive was accepted: "
              & E.Error_Code'Image (Status.Code));
      Opt.Release (Item);
   end Turns_Parse_In_Order;

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

   --  Every backend this build has can be named on the command line.
   --
   --  The option matches against the backend enumeration rather than a list
   --  written beside it, and so does this: a backend added to the enumeration
   --  and not to the parser fails here without anyone remembering to come and
   --  add a case.
   --  A text file read back with carriage returns taken out.
   --
   --  Every capture in this file is written through Ada.Text_IO, which ends
   --  a line the way its host does: one character here and two on Windows.
   --  A test that compares a captured line against a literal then looks for
   --  "cpu" and finds "cpu" followed by a carriage return, and says the
   --  program printed something else. Four tests failed that way on Windows
   --  and nowhere else. What is compared is what the program meant, so the
   --  ending the host adds comes off on the way in.
   --
   --  Not for anything that is not text: the model file is read raw a few
   --  lines below, and taking bytes out of it would be reading a different
   --  file.
   function Text_Of (Path : String) return String is
      Whole : constant String := Project_Tools.Files.Read_Raw_File (Path);
      Room  : String (1 .. Whole'Length);
      Used  : Natural := 0;
   begin
      for Character_Value of Whole loop
         if Character_Value /= Character'Val (13) then
            Used := Used + 1;
            Room (Used) := Character_Value;
         end if;
      end loop;

      return Room (1 .. Used);
   end Text_Of;
   --  Run the command with its generated text caught.
   --
   --  Generated text goes through the raw stream of
   --  Ada.Text_IO.Standard_Output, which Ada.Text_IO.Set_Output does not
   --  redirect, so a test that ran a generating command in this process
   --  wrote the model's output into the middle of the suite's own report.
   --  Seven fragments of it sat there on every run. Nothing a test asserts
   --  on moves: the presentation layer writes through Current_Output and
   --  Current_Error, which Set_Output and Set_Error still redirect.
   --
   --  Every call site goes through this, including the ones that write
   --  nothing, so that a command which starts generating does not have to
   --  remember.
   Said      : String (1 .. 64 * 1024);
   Said_Used : Natural := 0;

   procedure Ran (Source : Opt.Arguments'Class; Status : out Natural) is
   begin
      Said_Used := 0;

      Captured_Output.Open ("obj/command-output.txt");

      begin
         Model_Runner.CLI.Driver.Run (Source, Status);
      exception
         when others =>
            declare
               Ignored : constant String := Captured_Output.Close;
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
            raise;
      end;

      declare
         Caught : constant String := Captured_Output.Close;
         Room   : constant Natural :=
           Natural'Min (Caught'Length, Said'Length);
      begin
         Said (1 .. Room) :=
           Caught (Caught'First .. Caught'First + Room - 1);
         Said_Used := Room;
      end;
   end Ran;

   --  What the command wrote on standard output, from the last Ran.
   --
   --  Held here rather than opened again by the caller: the capture is one
   --  at a time, and a caller that wrapped Ran in a capture of its own met
   --  the guard that says so -- which is how this came to exist.
   function Last_Output return String is (Said (1 .. Said_Used));

   --  A vector as the embed command prints it: one component a line.
   type Real_List is array (1 .. 512) of Long_Float;

   type Reals is record
      Count  : Natural := 0;
      Values : Real_List := [others => 0.0];
   end record;

   --  Read the components out of what a command printed.
   function Parsed (Text : String) return Reals is
      Result : Reals;
      From   : Positive := Text'First;
   begin
      while From <= Text'Last loop
         declare
            Upto : Natural := From;
         begin
            while Upto <= Text'Last
              and then Text (Upto) /= Character'Val (10)
            loop
               Upto := Upto + 1;
            end loop;

            if Upto > From and then Result.Count < Result.Values'Last then
               Result.Count := Result.Count + 1;
               Result.Values (Result.Count) :=
                 Long_Float'Value (Text (From .. Upto - 1));
            end if;

            From := Upto + 1;
         end;
      end loop;

      return Result;
   end Parsed;

   --  A device computes the product the processor computes.
   --
   --  This is the first thing that runs on a device, so it is the first
   --  that can be checked rather than reported. The shader accumulates a
   --  row in binary32 where the processor accumulates in binary64 and
   --  rounds once, so the two are not equal and are not meant to be: what
   --  is held is that they agree to the precision binary32 carries.
   --
   --  The values are deliberately awkward. An earlier version of this used
   --  multiples of an eighth, and every product and every sum of them is
   --  exact in binary32, so the two agreed to the last bit and the test
   --  said nothing about the arithmetic it exists to check.
   --
   --  Skipped where there is no device, which is most machines. A test
   --  that demanded one would fail on them for a reason that has nothing
   --  to do with this program.
   procedure Device_Product_Matches_The_Processor
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      package Devices renames Model_Runner.Platform.Device;
      package Products renames Model_Runner.Platform.Device.Products;
      package N renames Model_Runner.Numerics;
      use type N.Element_Count;
      use type N.Wide_Real;

      Held  : Devices.Inventory;
      Found : Boolean;

      Checked : Natural := 0;
   begin
      Devices.Open (Held, Found);

      for Which in 1 .. Devices.Count (Held) loop
         declare
            Opened : Devices.Context;
            Engine : Products.Engine;
            Ready  : Boolean;
         begin
            Devices.Open (Opened, Held, Which, Ready);

            if Ready then
               --  A family this program can compute on has at least one
               --  queue, because having one is what made it a candidate.
               --  Whether it has two is what would decide if this program
               --  could ever submit to two, and it is asked here rather than
               --  assumed in a plan.
               Assert (Devices.Queue_Count (Opened) >= 1,
                       "an open device reports a queue family with no queues,"
                       & " which is not how it was chosen");
            end if;

            if Ready then
               Products.Open (Engine, Opened, Ready);
            end if;

            if Ready then
               Assert (Products.Is_Ready (Engine),
                       "a device took the pipeline and then said it had "
                       & "not");

               --  Shapes that are not multiples of the group the shader
               --  declares, so that the invocations past the last row are
               --  the ones the shader turns away rather than ones nobody
               --  asked for.
               for Shape in 1 .. 3 loop
                  declare
                     Rows : constant Natural :=
                       (case Shape is when 1 => 4, when 2 => 100,
                        when others => 257);
                     Cols : constant Natural :=
                       (case Shape is when 1 => 3, when 2 => 128,
                        when others => 64);

                     Weights : N.Real_Array
                       (0 .. N.Element_Count (Rows * Cols) - 1);
                     Vector : N.Real_Array (0 .. N.Element_Count (Cols) - 1);
                     Target : N.Real_Array (0 .. N.Element_Count (Rows) - 1);

                     Worst : N.Real := 0.0;
                     Ok    : Boolean;
                  begin
                     for Index in Weights'Range loop
                        Weights (Index) :=
                          1.0 / N.Real (3 + Natural (Index) mod 97) - 0.037;
                     end loop;

                     for Index in Vector'Range loop
                        Vector (Index) :=
                          1.0 / N.Real (7 + Natural (Index) mod 13) - 0.011;
                     end loop;

                     Products.Multiply
                       (Engine, Weights, Vector, Rows, Cols, Target, Ok);
                     Assert (Ok,
                             "a device refused a product of"
                             & Natural'Image (Rows) & " by"
                             & Natural'Image (Cols));

                     for Row in 0 .. N.Element_Count (Rows) - 1 loop
                        declare
                           Sum : N.Wide_Real := 0.0;
                        begin
                           for Col in 0 .. N.Element_Count (Cols) - 1 loop
                              Sum := Sum
                                + N.Wide_Real
                                    (Weights (Row * N.Element_Count (Cols)
                                              + Col))
                                  * N.Wide_Real (Vector (Col));
                           end loop;

                           Worst := N.Real'Max
                             (Worst, abs (Target (Row) - N.Real (Sum)));
                        end;
                     end loop;

                     --  Binary32 over a hundred and twenty-eight terms
                     --  measures under a ten-millionth here. The bound is
                     --  what that arithmetic can carry, not what this run
                     --  happened to produce.
                     Assert (Worst < 1.0E-5,
                             "a device and the processor disagree about a"
                             & Natural'Image (Rows) & " by"
                             & Natural'Image (Cols) & " product by"
                             & N.Real'Image (Worst));

                     Checked := Checked + 1;
                  end;
               end loop;

               --  A sequence of one is the single call, and a sequence
               --  of several is those calls one after another. Both are
               --  asserted against the entry point they are meant to
               --  reproduce rather than against arithmetic worked out here:
               --  what is being checked is that the recording changes
               --  nothing, and the product itself is checked above.
               declare
                  use type Model_Runner.Bytes.Byte_Count;
                  use type Interfaces.Unsigned_32;

                  Rows : constant Natural := 8;
                  Cols : constant Natural := 16;

                  Values : constant Model_Runner.Bytes.Byte_Count :=
                    Model_Runner.Bytes.Byte_Count (Rows * Cols * 4);

                  --  Two matrices one after another in one storage, which
                  --  is how a model holds them.
                  Held : constant Model_Runner.Bytes.Byte_Array_Access :=
                    new Model_Runner.Bytes.Byte_Array (1 .. Values * 2);

                  Vector : N.Real_Array (0 .. N.Element_Count (Cols) - 1);

                  Alone  : N.Real_Array (0 .. N.Element_Count (Rows) - 1);
                  Second : N.Real_Array (0 .. N.Element_Count (Rows) - 1);
                  Both   : N.Real_Array (0 .. N.Element_Count (Rows) * 2 - 1);

                  Steps  : Products.Sequence;
                  Kept   : Model_Runner.Bytes.Byte_Array_Access := Held;
                  Ok     : Boolean;
                  Added  : Boolean;
                  Halted : Boolean;
               begin
                  for Index in Held'Range loop
                     Held (Index) := 0;
                  end loop;

                  --  Binary32 written where the packing says it lies.
                  for Which in 0 .. Rows * Cols * 2 - 1 loop
                     declare
                        Value : constant N.Real :=
                          1.0 / N.Real (5 + Which mod 31) - 0.021;
                        Bits : Interfaces.Unsigned_32;
                        for Bits'Address use Value'Address;
                        pragma Import (Ada, Bits);
                     begin
                        for Byte in 0 .. 3 loop
                           Held (Held'First
                                 + Model_Runner.Bytes.Byte_Count
                                     (Which * 4 + Byte)) :=
                             Model_Runner.Bytes.Byte
                               (Interfaces.Shift_Right
                                  (Bits, Byte * 8) and 16#FF#);
                        end loop;
                     end;
                  end loop;

                  for Index in Vector'Range loop
                     Vector (Index) :=
                       1.0 / N.Real (3 + Natural (Index) mod 11) - 0.043;
                  end loop;

                  Products.Multiply
                    (Engine, Held.all, 0, Products.Values_F32, Rows, Cols,
                     Vector, 1, Alone, Ok, Halted);
                  Assert (Ok, "a device refused a plain product");

                  Products.Multiply
                    (Engine, Held.all, Values, Products.Values_F32,
                     Rows, Cols, Vector, 1, Second, Ok, Halted);
                  Assert (Ok, "a device refused the second matrix");

                  Products.Open_Sequence (Steps);
                  Assert (Products.Length (Steps) = 0,
                          "a sequence just opened held something");

                  Products.Add_Product
                    (Steps, Held.all'Address,
                     Model_Runner.Bytes.Byte_Count (Held.all'Length),
                     0, Products.Values_F32, Rows, Cols, Added);
                  Assert (Added, "a sequence refused its first product");
                  Products.Add_Product
                    (Steps, Held.all'Address,
                     Model_Runner.Bytes.Byte_Count (Held.all'Length),
                     Values, Products.Values_F32, Rows, Cols,
                     Added);
                  Assert (Added, "a sequence refused its second product");
                  Assert (Products.Length (Steps) = 2,
                          "a sequence of two did not hold two");

                  Products.Run
                    (Engine, Steps, Vector, 1, Both, Ok, Halted);
                  Assert (Ok, "a device refused a sequence of two");

                  for Row in Alone'Range loop
                     Assert (Both (Row) = Alone (Row),
                             "a sequence disagreed with the single call"
                             & " about the first matrix at row"
                             & N.Element_Count'Image (Row));
                     Assert
                       (Both (Row + N.Element_Count (Rows)) = Second (Row),
                        "a sequence disagreed with the single call about"
                        & " the second matrix at row"
                        & N.Element_Count'Image (Row));
                  end loop;

                  --  A chained product reads what the one before it wrote,
                  --  without that ever leaving the device. Asserted against
                  --  the two single calls it has to reproduce -- the second
                  --  fed by hand with what the first returned, which is
                  --  exactly the round trip chaining removes.
                  declare
                     Square : constant Model_Runner.Bytes.Byte_Count :=
                       Model_Runner.Bytes.Byte_Count (Rows * Rows * 4);

                     Second_Held :
                       constant Model_Runner.Bytes.Byte_Array_Access :=
                         new Model_Runner.Bytes.Byte_Array (1 .. Square);
                     Second_Free : Model_Runner.Bytes.Byte_Array_Access :=
                       Second_Held;

                     Once  : N.Real_Array (0 .. N.Element_Count (Rows) - 1);
                     Twice : N.Real_Array (0 .. N.Element_Count (Rows) - 1);
                     Both_Chained :
                       N.Real_Array (0 .. N.Element_Count (Rows) * 2 - 1);

                     Chain : Products.Sequence;
                  begin
                     --  A square matrix, so its columns meet the first
                     --  product's rows and the chain is legal.
                     for Which in 0 .. Rows * Rows - 1 loop
                        declare
                           Value : constant N.Real :=
                             1.0 / N.Real (11 + Which mod 29) - 0.017;
                           Bits : Interfaces.Unsigned_32;
                           for Bits'Address use Value'Address;
                           pragma Import (Ada, Bits);
                        begin
                           for Byte in 0 .. 3 loop
                              Second_Held
                                (Second_Held'First
                                 + Model_Runner.Bytes.Byte_Count
                                     (Which * 4 + Byte)) :=
                                Model_Runner.Bytes.Byte
                                  (Interfaces.Shift_Right
                                     (Bits, Byte * 8) and 16#FF#);
                           end loop;
                        end;
                     end loop;

                     --  By hand: one product, then another fed with what it
                     --  returned.
                     Products.Multiply
                       (Engine, Held.all, 0, Products.Values_F32, Rows, Cols,
                        Vector, 1, Once, Ok, Halted);
                     Assert (Ok, "a device refused the first of a chain");

                     Products.Multiply
                       (Engine, Second_Held.all, 0, Products.Values_F32,
                        Rows, Rows, Once, 1, Twice, Ok, Halted);
                     Assert (Ok, "a device refused the second of a chain");

                     --  And chained, where the middle never comes back.
                     Products.Open_Sequence (Chain);
                     Products.Add_Product
                       (Chain, Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held.all'Length),
                        0, Products.Values_F32, Rows, Cols,
                        Added);
                     Assert (Added, "a chain refused its first product");

                     Products.Add_Chained_Product
                       (Chain, Second_Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Second_Held.all'Length),
                        0, Products.Values_F32,
                        Rows, Rows, Added);
                     Assert (Added, "a chain refused its chained product");

                     Products.Run
                       (Engine, Chain, Vector, 1, Both_Chained, Ok, Halted);
                     Assert (Ok, "a device refused a chained sequence");

                     for Row in Once'Range loop
                        Assert (Both_Chained (Row) = Once (Row),
                                "a chain disagreed about the first product"
                                & " at row" & N.Element_Count'Image (Row));
                        Assert
                          (Both_Chained (Row + N.Element_Count (Rows))
                             = Twice (Row),
                           "a chained product disagreed with the same"
                           & " product fed by hand, at row"
                           & N.Element_Count'Image (Row));
                     end loop;

                     --  A chain has to have something to chain to.
                     Products.Open_Sequence (Chain);
                     Products.Add_Chained_Product
                       (Chain, Second_Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Second_Held.all'Length),
                        0, Products.Values_F32,
                        Rows, Rows, Added);
                     Assert (not Added,
                             "a sequence chained a product to nothing");

                     --  And the widths have to meet.
                     Products.Open_Sequence (Chain);
                     Products.Add_Product
                       (Chain, Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held.all'Length),
                        0, Products.Values_F32, Rows, Cols,
                        Added);
                     Products.Add_Chained_Product
                       (Chain, Second_Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Second_Held.all'Length),
                        0, Products.Values_F32,
                        Rows, Rows + 1, Added);
                     Assert (not Added,
                             "a sequence chained a product whose columns do"
                             & " not meet the rows before it");

                     Model_Runner.Bytes.Free (Second_Free);
                  end;

                  --  A combining step: a unit on one arm, multiplied by the
                  --  other, with neither arm leaving the device. Compared
                  --  against the same arithmetic done here, within a
                  --  tolerance rather than exactly -- the device computes its
                  --  exponential in binary32 and the host in binary64, so the
                  --  two agree to about the width of a binary32 and not
                  --  further. That is a real difference and the bound says
                  --  which one it is.
                  declare
                     Arms   : N.Real_Array (0 .. N.Element_Count (Rows) - 1);
                     Second : N.Real_Array (0 .. N.Element_Count (Rows) - 1);
                     Whole  : N.Real_Array
                       (0 .. N.Element_Count (Rows) * 3 - 1);

                     Blend : Products.Sequence;
                     Worst : N.Real := 0.0;
                  begin
                     Products.Multiply
                       (Engine, Held.all, 0, Products.Values_F32, Rows, Cols,
                        Vector, 1, Arms, Ok, Halted);
                     Assert (Ok, "a device refused the first arm");

                     Products.Multiply
                       (Engine, Held.all, Values, Products.Values_F32,
                        Rows, Cols, Vector, 1, Second, Ok, Halted);
                     Assert (Ok, "a device refused the second arm");

                     Products.Open_Sequence (Blend);
                     Products.Add_Product
                       (Blend, Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held.all'Length),
                        0, Products.Values_F32, Rows, Cols,
                        Added);
                     Products.Add_Product
                       (Blend, Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held.all'Length),
                        Values, Products.Values_F32, Rows, Cols,
                        Added);
                     Assert (Added, "a sequence refused a second arm");

                     Products.Add_Combination (Blend, 0, Added);
                     Assert (Added, "a sequence refused a combination");

                     Products.Run
                       (Engine, Blend, Vector, 1, Whole, Ok, Halted);
                     Assert (Ok, "a device refused a combining sequence");

                     for Row in Arms'Range loop
                        declare
                           Gate : constant N.Wide_Real :=
                             N.Wide_Real (Arms (Row));

                           Wanted : constant N.Real :=
                             N.Real (Gate / (1.0 + N.Exp (-Gate)))
                             * Second (Row);

                           Got : constant N.Real :=
                             Whole (Row + N.Element_Count (Rows) * 2);
                        begin
                           Worst := N.Real'Max (Worst, abs (Got - Wanted));
                        end;
                     end loop;

                     Assert (Worst < 1.0E-5,
                             "a device and the processor disagree about a"
                             & " gated combination by" & N.Real'Image (Worst));

                     --  Two steps are needed to combine, and their rows have
                     --  to match.
                     Products.Open_Sequence (Blend);
                     Products.Add_Product
                       (Blend, Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held.all'Length),
                        0, Products.Values_F32, Rows, Cols,
                        Added);
                     Products.Add_Combination (Blend, 0, Added);
                     Assert (not Added,
                             "a sequence combined with one step behind it");
                  end;

                  --  A normalization and a residual join, which are what
                  --  the host used to do between one submission and the
                  --  next. Compared against the same arithmetic worked out
                  --  here within a tolerance rather than exactly: the
                  --  device folds a position's squares in a tree and the
                  --  processor walks them in order, so the two agree to
                  --  about the width of a binary32 and not further.
                  declare
                     Gain : constant N.Real_Array
                       (0 .. N.Element_Count (Rows) - 1) :=
                         [for Row in 0 .. N.Element_Count (Rows) - 1 =>
                            0.5 + N.Real (Row mod 5) / 8.0];

                     Held_Gain : Model_Runner.Bytes.Byte_Array_Access :=
                       new Model_Runner.Bytes.Byte_Array
                             (1 .. Model_Runner.Bytes.Byte_Count (Rows) * 4);

                     Arm   : N.Real_Array (0 .. N.Element_Count (Rows) - 1);
                     Whole : N.Real_Array
                       (0 .. N.Element_Count (Rows) * 3 - 1);

                     Wider : N.Real_Array
                       (0 .. N.Element_Count (Cols)
                             + N.Element_Count (Rows) - 1) :=
                         [others => 0.0];

                     Layer : Products.Sequence;
                     Worst : N.Real := 0.0;
                     Epsilon : constant N.Real := 1.0E-5;
                  begin
                     for Row in Gain'Range loop
                        declare
                           At_Byte : constant Model_Runner.Bytes.Byte_Count :=
                             Model_Runner.Bytes.Byte_Count (Row) * 4 + 1;
                        begin
                           Held_Gain (At_Byte .. At_Byte + 3) :=
                             Model_Runner.Bytes.Put_F32 (Gain (Row));
                        end;
                     end loop;

                     --  The activation the sequence reads, with the
                     --  residual the join adds behind it.
                     Wider (0 .. N.Element_Count (Cols) - 1) := Vector;

                     for Row in 0 .. N.Element_Count (Rows) - 1 loop
                        Wider (N.Element_Count (Cols) + Row) :=
                          N.Real (Row mod 7) / 9.0 - 0.3;
                     end loop;

                     Products.Multiply
                       (Engine, Held.all, 0, Products.Values_F32, Rows, Cols,
                        Vector, 1, Arm, Ok, Halted);
                     Assert (Ok, "a device refused the product to normalize");

                     Products.Open_Sequence (Layer);
                     Products.Add_Product
                       (Layer, Held.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held.all'Length),
                        0, Products.Values_F32, Rows, Cols,
                        Added);
                     Assert (Added, "a sequence refused its product");

                     Products.Add_Norm
                       (Layer, Held_Gain.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held_Gain.all'Length),
                        0, Rows, Epsilon, Added);
                     Assert (Added, "a sequence refused a normalization");

                     Products.Add_Join
                       (Layer, Added,
                        From_Vector => Natural (N.Element_Count (Cols)));
                     Assert (Added, "a sequence refused a join");

                     Products.Run
                       (Engine, Layer, Wider, 1, Whole, Ok, Halted);
                     Assert (Ok, "a device refused a normalizing sequence");

                     declare
                        Square : N.Wide_Real := 0.0;
                        Scale  : N.Wide_Real;
                     begin
                        for Row in Arm'Range loop
                           Square := Square
                             + N.Wide_Real (Arm (Row))
                               * N.Wide_Real (Arm (Row));
                        end loop;

                        Scale := 1.0 / N.Sqrt
                          (Square / N.Wide_Real (Rows)
                           + N.Wide_Real (Epsilon));

                        for Row in Arm'Range loop
                           declare
                              Normed : constant N.Real :=
                                N.Real (N.Wide_Real (Arm (Row)) * Scale)
                                * Gain (Row);

                              Wanted : constant N.Real :=
                                Normed
                                + Wider (N.Element_Count (Cols) + Row);

                              Said : constant N.Real :=
                                Whole (Row + N.Element_Count (Rows));

                              Got : constant N.Real :=
                                Whole (Row + N.Element_Count (Rows) * 2);
                           begin
                              Worst := N.Real'Max
                                (Worst, abs (Said - Normed));
                              Worst := N.Real'Max
                                (Worst, abs (Got - Wanted));
                           end;
                        end loop;
                     end;

                     Assert (Worst < 1.0E-4,
                             "a device and the processor disagree about a"
                             & " normalization and the join after it by"
                             & N.Real'Image (Worst));

                     --  A normalization first in a sequence reads what the
                     --  caller handed in, as a product first in one does.
                     Products.Open_Sequence (Layer);
                     Products.Add_Norm
                       (Layer, Held_Gain.all'Address,
                        Model_Runner.Bytes.Byte_Count (Held_Gain.all'Length),
                        0, Rows, Epsilon, Added);
                     Assert (Added,
                             "a sequence refused to normalize what it was "
                             & "handed");

                     --  A join has nothing to add to.
                     Products.Open_Sequence (Layer);
                     Products.Add_Join (Layer, Added);
                     Assert (not Added, "a sequence joined nothing");

                     Model_Runner.Bytes.Free (Held_Gain);
                  end;

                  --  A target too small is refused rather than filled as
                  --  far as it goes, which would hand back one product of
                  --  two and say nothing.
                  Products.Run
                    (Engine, Steps, Vector, 1, Alone, Ok, Halted);
                  Assert (not Ok,
                          "a sequence filled a target too small for it");

                  --  An empty sequence computes nothing and says so.
                  Products.Open_Sequence (Steps);
                  Products.Run (Engine, Steps, Vector, 1, Both, Ok, Halted);
                  Assert (not Ok, "an empty sequence reported success");

                  Model_Runner.Bytes.Free (Kept);
                  Checked := Checked + 1;
               end;

               --  Three products of one activation, sent together, are
               --  the three sent one at a time. Asserted against the single
               --  dispatch rather than against arithmetic worked out here:
               --  what is being checked is that going together changes
               --  nothing, and the product itself is checked above.
               declare
                  use type Model_Runner.Bytes.Byte_Count;
                  use type Interfaces.Unsigned_32;

                  Rows : constant Natural := 12;
                  Cols : constant Natural := 16;

                  Span : constant Model_Runner.Bytes.Byte_Count :=
                    Model_Runner.Bytes.Byte_Count (Rows * Cols * 4);

                  Store : constant Model_Runner.Bytes.Byte_Array_Access :=
                    new Model_Runner.Bytes.Byte_Array (1 .. Span * 3);
                  Freed : Model_Runner.Bytes.Byte_Array_Access := Store;

                  Vector : constant Model_Runner.Tensors.Real_Array_Access :=
                    new N.Real_Array (0 .. N.Element_Count (Cols) - 1);

                  Apart : constant Model_Runner.Tensors.Target_Group
                    (1 .. 3) :=
                      [others => new N.Real_Array
                                       (0 .. N.Element_Count (Rows) - 1)];
                  Together : constant Model_Runner.Tensors.Target_Group
                    (1 .. 3) :=
                      [others => new N.Real_Array
                                       (0 .. N.Element_Count (Rows) - 1)];

                  Views : Model_Runner.Tensors.View_Group (1 .. 3);
                  Ready : Boolean;
                  Why   : Model_Runner.Errors.Error_Info;
               begin
                  for Which in 0 .. Rows * Cols * 3 - 1 loop
                     declare
                        Value : constant N.Real :=
                          1.0 / N.Real (7 + Which mod 23) - 0.019;
                        Bits : Interfaces.Unsigned_32;
                        for Bits'Address use Value'Address;
                        pragma Import (Ada, Bits);
                     begin
                        for Byte in 0 .. 3 loop
                           Store (Store'First
                                  + Model_Runner.Bytes.Byte_Count
                                      (Which * 4 + Byte)) :=
                             Model_Runner.Bytes.Byte
                               (Interfaces.Shift_Right
                                  (Bits, Byte * 8) and 16#FF#);
                        end loop;
                     end;
                  end loop;

                  for Index in Vector'Range loop
                     Vector (Index) :=
                       1.0 / N.Real (5 + Natural (Index) mod 17) - 0.031;
                  end loop;

                  for Index in Views'Range loop
                     Views (Index) :=
                       (Format  => Model_Runner.GGUF.Type_F32,
                        Rows    => N.Element_Count (Rows),
                        Columns => N.Element_Count (Cols),
                        Base    => Store.all'Address,
                        Span    => Model_Runner.Bytes.Byte_Count (Store.all'Length),
                        Offset  =>
                          Model_Runner.Bytes.Byte_Count (Index - 1) * Span,
                        others  => <>);
                  end loop;

                  Model_Runner.Backend.Device.Open (Ready);
                  if Ready then
                     for Index in Views'Range loop
                        Model_Runner.Backend.Device.Dispatch
                          (Views (Index), Vector, Apart (Index), Why);
                        Assert (not Model_Runner.Errors.Is_Error (Why),
                                "a device refused a single projection");
                     end loop;

                     Model_Runner.Backend.Device.Dispatch_Group
                       (Views, Vector,
                        Together, Why);
                     Assert (not Model_Runner.Errors.Is_Error (Why),
                             "a device refused three projections together");

                     for Index in Views'Range loop
                        for Row in Apart (Index).all'Range loop
                           Assert
                             (Together (Index).all (Row)
                                = Apart (Index).all (Row),
                              "three projections sent together disagree with"
                              & " the three sent apart, at matrix"
                              & Natural'Image (Index) & " row"
                              & N.Element_Count'Image (Row));
                        end loop;
                     end loop;

                     --  And the gated block whole: two arms, the unit and
                     --  the multiply, and the projection that reads the
                     --  result, none of the middle coming back. Against the
                     --  same thing done a step at a time, within a tolerance
                     --  -- the unit runs in binary32 on the device and in
                     --  binary64 here.
                     declare
                        Square : constant Model_Runner.Bytes.Byte_Count :=
                          Model_Runner.Bytes.Byte_Count (Rows * Rows * 4);

                        Down_Held :
                          constant Model_Runner.Bytes.Byte_Array_Access :=
                            new Model_Runner.Bytes.Byte_Array (1 .. Square);
                        Down_Free : Model_Runner.Bytes.Byte_Array_Access :=
                          Down_Held;

                        Down_View : Model_Runner.Tensors.View;

                        Middle : constant
                          Model_Runner.Tensors.Real_Array_Access :=
                            new N.Real_Array
                                  (0 .. N.Element_Count (Rows) - 1);
                        By_Hand : constant
                          Model_Runner.Tensors.Real_Array_Access :=
                            new N.Real_Array
                                  (0 .. N.Element_Count (Rows) - 1);
                        Whole : constant
                          Model_Runner.Tensors.Real_Array_Access :=
                            new N.Real_Array
                                  (0 .. N.Element_Count (Rows) - 1);

                        Worst : N.Real := 0.0;
                     begin
                        for Which in 0 .. Rows * Rows - 1 loop
                           declare
                              Value : constant N.Real :=
                                1.0 / N.Real (13 + Which mod 19) - 0.023;
                              Bits : Interfaces.Unsigned_32;
                              for Bits'Address use Value'Address;
                              pragma Import (Ada, Bits);
                           begin
                              for Byte in 0 .. 3 loop
                                 Down_Held
                                   (Down_Held'First
                                    + Model_Runner.Bytes.Byte_Count
                                        (Which * 4 + Byte)) :=
                                   Model_Runner.Bytes.Byte
                                     (Interfaces.Shift_Right
                                        (Bits, Byte * 8) and 16#FF#);
                              end loop;
                           end;
                        end loop;

                        Down_View :=
                          (Format  => Model_Runner.GGUF.Type_F32,
                           Rows    => N.Element_Count (Rows),
                           Columns => N.Element_Count (Rows),
                           Base    => Down_Held.all'Address,
                           Span    => Model_Runner.Bytes.Byte_Count (Down_Held.all'Length),
                           Offset  => 0,
                           others  => <>);

                        --  A step at a time: the two arms are already in
                        --  Apart, so this is the unit, the multiply, and the
                        --  projection that reads what they make.
                        for Row in Middle.all'Range loop
                           declare
                              Gate : constant N.Wide_Real :=
                                N.Wide_Real (Apart (1).all (Row));
                           begin
                              Middle.all (Row) :=
                                N.Real (Gate / (1.0 + N.Exp (-Gate)))
                                * Apart (2).all (Row);
                           end;
                        end loop;

                        Model_Runner.Backend.Device.Dispatch
                          (Down_View, Middle, By_Hand, Why);
                        Assert (not Model_Runner.Errors.Is_Error (Why),
                                "a device refused a projection down");

                        Model_Runner.Backend.Device.Dispatch_Gated
                          (Views (1), Views (2), Down_View, Vector, 1, 0,
                           Whole, Why);
                        Assert (not Model_Runner.Errors.Is_Error (Why),
                                "a device refused a gated block");

                        for Row in Whole.all'Range loop
                           Worst := N.Real'Max
                             (Worst,
                              abs (Whole.all (Row) - By_Hand.all (Row)));
                        end loop;

                        Assert (Worst < 1.0E-4,
                                "a gated block sent whole disagrees with the"
                                & " same block sent a step at a time by"
                                & N.Real'Image (Worst));

                        Model_Runner.Bytes.Free (Down_Free);
                     end;

                     Model_Runner.Backend.Device.Close;
                     Checked := Checked + 1;
                  end if;

                  Model_Runner.Bytes.Free (Freed);
               end;

               --  One position attending to a cache, on the device,
               --  against the same arithmetic done here in binary64. Not
               --  exactly: the kernel folds the softmax into the pass that
               --  computes the scores and works in binary32 throughout, so
               --  the two agree to about the width of a binary32.
               declare
                  Heads  : constant Natural := 4;
                  Wide   : constant Natural := 8;
                  Steps  : constant Natural := 16;
                  Span   : constant Natural := Heads * Wide;

                  Cache : N.Real_Array
                    (0 .. N.Element_Count (Steps * Span * 2) - 1);
                  Asked : N.Real_Array (0 .. N.Element_Count (Span) - 1);
                  Got   : N.Real_Array (0 .. N.Element_Count (Span) - 1);

                  V_At  : constant Natural := Steps * Span;
                  Scale : constant N.Real := 0.35;

                  Worst : N.Real := 0.0;
                  Ok    : Boolean;
               begin
                  for Index in Cache'Range loop
                     Cache (Index) :=
                       1.0 / N.Real (5 + Natural (Index) mod 37) - 0.021;
                  end loop;

                  for Index in Asked'Range loop
                     Asked (Index) :=
                       1.0 / N.Real (3 + Natural (Index) mod 11) - 0.037;
                  end loop;

                  Products.Attend
                    (Engine, Cache, Asked,
                     Heads => Heads, Head_Size => Wide, Value_Size => Wide,
                     Group_Size => 1, First => 0, Last => Steps - 1,
                     K_Base => 0, V_Base => V_At,
                     KV_Width => Span, V_Width => Span,
                     Scale => Scale, Cap => 0.0,
                     Target => Got, Ok => Ok);
                  Assert (Ok, "a device refused an attention");

                  for Head in 0 .. Heads - 1 loop
                     declare
                        Scores : array (0 .. Steps - 1) of N.Wide_Real;
                        Top    : N.Wide_Real;
                        Sum    : N.Wide_Real := 0.0;
                     begin
                        for Step in 0 .. Steps - 1 loop
                           declare
                              Dot : N.Wide_Real := 0.0;
                           begin
                              for C in 0 .. Wide - 1 loop
                                 Dot := Dot
                                   + N.Wide_Real
                                       (Asked (N.Element_Count
                                                 (Head * Wide + C)))
                                     * N.Wide_Real
                                         (Cache (N.Element_Count
                                                   (Step * Span
                                                    + Head * Wide + C)));
                              end loop;
                              Scores (Step) := Dot * N.Wide_Real (Scale);
                           end;
                        end loop;

                        Top := Scores (0);
                        for Step in 1 .. Steps - 1 loop
                           Top := N.Wide_Real'Max (Top, Scores (Step));
                        end loop;

                        for Step in 0 .. Steps - 1 loop
                           Scores (Step) := N.Exp (Scores (Step) - Top);
                           Sum := Sum + Scores (Step);
                        end loop;

                        for C in 0 .. Wide - 1 loop
                           declare
                              Blend : N.Wide_Real := 0.0;
                           begin
                              for Step in 0 .. Steps - 1 loop
                                 Blend := Blend + Scores (Step)
                                   * N.Wide_Real
                                       (Cache (N.Element_Count
                                                 (V_At + Step * Span
                                                  + Head * Wide + C)));
                              end loop;

                              Worst := N.Real'Max
                                (Worst,
                                 abs (Got (N.Element_Count (Head * Wide + C))
                                      - N.Real (Blend / Sum)));
                           end;
                        end loop;
                     end;
                  end loop;

                  Assert (Worst < 1.0E-5,
                          "a device and the processor disagree about"
                          & " attention by" & N.Real'Image (Worst));
                  Checked := Checked + 1;
               end;

               --  A shape nobody has.
               declare
                  Given  : constant N.Real_Array (0 .. 0) := [others => 0.0];
                  Wanted : N.Real_Array (0 .. 0) := [others => 0.0];
                  Ok     : Boolean;
               begin
                  Products.Multiply
                    (Engine, Given, Given, 0, 0, Wanted, Ok);
                  Assert (not Ok, "a device accepted a product of nothing");
               end;
            end if;

            Products.Close (Engine);
            Assert (not Products.Is_Ready (Engine),
                    "closing an engine left it ready");

            --  Closing twice is closing.
            Products.Close (Engine);
            Devices.Close (Opened);
         end;
      end loop;

      Devices.Close (Held);

      --  Nothing is asserted about how many devices answered. What is
      --  asserted is that a machine which has one gets the right answer
      --  from it, and this says so where it happened.
      if Checked = 0 then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "note: no device computed a product here");
      end if;
   end Device_Product_Matches_The_Processor;

   --  Asking the machine what devices it has answers, either way.
   --
   --  Nothing computes on a device yet. What this holds is the part that
   --  has to be true before anything can: asking is safe on a machine with
   --  no loader, no driver and no device, and safe again on one that has
   --  all three. A machine without them is the common case and must not be
   --  a machine where the program fails to start, so the absence is an
   --  answer rather than a diagnostic.
   --
   --  Both outcomes are accepted here on purpose. This runs on machines
   --  with a device and on machines without, and a test that demanded one
   --  would fail on the other for a reason that has nothing to do with the
   --  program.
   procedure Devices_Are_Reported_Either_Way
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      package Devices renames Model_Runner.Platform.Device;

      Held  : Devices.Inventory;
      Found : Boolean;
   begin
      --  Twice, because opening one is what allocates whatever the host
      --  hands back and closing it is what gives it up: a second open must
      --  be as good as the first.
      for Attempt in 1 .. 2 loop
         Devices.Open (Held, Found);

         Assert (Found or else Devices.Count (Held) = 0,
                 "no device interface answered and yet devices were named");

         Assert (Devices.Count (Held) <= Devices.Max_Devices,
                 "more devices were named than the inventory holds:"
                 & Natural'Image (Devices.Count (Held)));

         for Index in 1 .. Devices.Count (Held) loop
            Assert (Devices.Name (Held, Index)'Length > 0,
                    "a device was named with an empty name at"
                    & Natural'Image (Index));
            Assert (Devices.Name (Held, Index)'Length
                      <= Devices.Max_Name_Bytes,
                    "a device name ran past the length the interface "
                    & "states");
         end loop;

         --  Past the end is not a device, and asking is not an error.
         Assert (Devices.Name (Held, Devices.Count (Held) + 1) = "",
                 "a device past the last one had a name");
         Assert (not Devices.Is_Discrete (Held, Devices.Count (Held) + 1),
                 "a device past the last one had a memory");

         Devices.Close (Held);
         Assert (Devices.Count (Held) = 0,
                 "closing an inventory left devices in it");
      end loop;

      --  And opening each of them, which is what a backend would do before
      --  it could do anything else. A device that names itself and then
      --  cannot be opened is a device this program would have to refuse, so
      --  the outcome is checked rather than assumed either way.
      Devices.Open (Held, Found);

      for Index in 1 .. Devices.Count (Held) loop
         declare
            Opened : Devices.Context;
            Ready  : Boolean;
         begin
            Devices.Open (Opened, Held, Index, Ready);

            Assert (Ready = Devices.Is_Open (Opened),
                    "a device reported itself open and not open at once");

            if Ready then
               --  A device that opened has a queue that accepts compute,
               --  and memory. Neither number means anything on its own
               --  here; that they are answerable at all is what the piece
               --  after this one starts from.
               Assert (Devices.Memory_Bytes (Opened) > 0,
                       "a device opened and reported no memory at all");
               Assert (Devices.Queue_Family (Opened) < 64,
                       "a device opened with an implausible queue family:"
                       & Natural'Image (Devices.Queue_Family (Opened)));
            else
               Assert (Devices.Queue_Family (Opened) = 0,
                       "a device that did not open named a queue family");
            end if;

            Devices.Close (Opened);
            Assert (not Devices.Is_Open (Opened),
                    "closing a device left it open");

            --  Closing twice is closing.
            Devices.Close (Opened);
         end;
      end loop;

      --  A device number nobody has.
      declare
         Opened : Devices.Context;
         Ready  : Boolean;
      begin
         Devices.Open (Opened, Held, Devices.Count (Held) + 1, Ready);
         Assert (not Ready, "a device past the last one opened");
         Devices.Close (Opened);
      end;

      Devices.Close (Held);

      --  And closing one that was never opened.
      Devices.Close (Held);

      --  Whether the interface is there at all is a separate question from
      --  whether it named anything, and both answers are allowed.
      Assert (Devices.Is_Supported or else not Found,
              "the interface answered while reporting itself unsupported");
   end Devices_Are_Reported_Either_Way;

   --  A mixture is reported as one, and a dense model is not.
   --
   --  An inspection that named a feed-forward width and nothing else
   --  described a block a mixture-of-experts model does not have: the file
   --  states that width, the engine computes with an expert's, and the
   --  reader was shown the one the model never uses. All three numbers were
   --  read into the configuration already and none of them was printed.
   procedure Inspection_Reports_A_Mixture
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Mixed : constant String := "obj/mixture-model.gguf";
      Dense : constant String := "obj/dense-model.gguf";

      --  Inspect a file and hand back what reached standard output.
      function Inspected (Path : String) return String is
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "inspect");
         Add (Source, Path);
         Ran (Source, Status);
         Assert (Status = 0,
                 "inspecting " & Path & " failed with status"
                 & Natural'Image (Status));
         return Last_Output;
      end Inspected;

      --  The number a field line carries, or -1 where the line is not
      --  there. A label with no number after it is as much a failure as a
      --  label that is missing.
      function Number_After (Said, Label : String) return Integer is
         At_Label : constant Natural :=
           Ada.Strings.Fixed.Index (Said, Label);
         Stop     : Natural;
      begin
         if At_Label = 0 then
            return -1;
         end if;

         Stop := At_Label + Label'Length;
         while Stop <= Said'Last and then Said (Stop) = ' ' loop
            Stop := Stop + 1;
         end loop;

         declare
            From : constant Natural := Stop;
         begin
            while Stop <= Said'Last and then Said (Stop) in '0' .. '9' loop
               Stop := Stop + 1;
            end loop;
            if Stop = From then
               return -1;
            end if;
            return Integer'Value (Said (From .. Stop - 1));
         end;
      end Number_After;
   begin
      Tiny_Model.Write
        (Mixed, Kind => Tiny_Model.Qwen3_MoE, Shape => Tiny_Model.Mixed);
      Tiny_Model.Write (Dense, Kind => Tiny_Model.Qwen3);

      declare
         Said : constant String := Inspected (Mixed);
      begin
         Assert (Project_Tools.Text.Contains (Said, "experts"),
                 "a mixture was inspected and its experts were not "
                 & "reported: " & Said);
         Assert (Project_Tools.Text.Contains (Said, "experts used"),
                 "the inspection did not say how many experts run");
         Assert (Project_Tools.Text.Contains (Said, "expert width"),
                 "the inspection did not say how wide an expert is");

         --  And the numbers are the file's own, not the dense width beside
         --  them: one expert is narrower than the block the model would
         --  have had, which is the whole point of having several.
         Assert (Number_After (Said, "experts ") = 4,
                 "the expert count was reported as"
                 & Integer'Image (Number_After (Said, "experts ")));
         Assert (Number_After (Said, "experts used") = 2,
                 "the used count was reported as"
                 & Integer'Image (Number_After (Said, "experts used")));
         Assert (Number_After (Said, "expert width") = 8,
                 "the expert width was reported as"
                 & Integer'Image (Number_After (Said, "expert width")));
      end;

      --  A dense model has no mixture to report, and reporting one would be
      --  worse than reporting none.
      declare
         Said : constant String := Inspected (Dense);
      begin
         Assert (not Project_Tools.Text.Contains (Said, "experts"),
                 "a dense model was inspected and reported experts: "
                 & Said);
      end;
   end Inspection_Reports_A_Mixture;

   --  Tools reach the template or the run says they would not, and the
   --  turns that close a tool loop reach the conversation.
   --
   --  A model told about no tools answers as though there were none, which
   --  looks from the outside like a model that chose not to call one. That
   --  is the failure worth refusing at the command rather than reporting as
   --  an answer -- and the turns handed back are read where the prompt is
   --  read, so a file that is not there fails the run rather than leaving a
   --  turn out of it.
   procedure Tools_Reach_The_Template_Or_The_Run_Says_So
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      Model : constant String := "obj/tools-model.gguf";
      Offer : constant String := "[{""name"": ""weather""}]";
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  The fixture's template says nothing about tools, which is what
      --  makes it the model to ask this of.
      declare
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--tools");
         Add (Source, Offer);
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "1");

         Ran (Source, Status);
         Assert (Status = E.Exit_Status (E.Make (E.Tools_Not_In_Template)),
                 "tools offered to a template with nowhere to put them ended "
                 & "with status" & Natural'Image (Status));
      end;

      --  A conversation with turns in it runs. They are appended after the
      --  prompt in the order they were written, which is what makes the
      --  reply the model gave and the answer a tool gave one conversation
      --  rather than two.
      declare
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--assistant");
         Add (Source, "ba");
         Add (Source, "--tool-result");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Add (Source, "--temperature");
         Add (Source, "0");

         Ran (Source, Status);
         Assert (Status = 0,
                 "a run carrying earlier turns failed with status"
                 & Natural'Image (Status));
      end;

      --  And a turn named by a file that is not there fails the run.
      declare
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--tool-result-file");
         Add (Source, "obj/no-such-answer.txt");
         Add (Source, "--max-tokens");
         Add (Source, "1");

         Ran (Source, Status);
         Assert (Status /= 0,
                 "a run told to read an answer that is not there reported "
                 & "success");
      end;
   end Tools_Reach_The_Template_Or_The_Run_Says_So;

   --  A saved context is the context, and a run that reuses one answers
   --  as it would have.
   --
   --  Saving one is a speed decision and nothing else, so the way it can
   --  fail is by changing the answer: a cache read back one position out,
   --  or read back and then re-read on top of itself, would produce text
   --  that is plausible and different. Both runs below are greedy, so the
   --  two texts have to be the same text.
   procedure Saved_Context_Changes_Nothing
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Model : constant String := "obj/session-model.gguf";
      Saved : constant String := "obj/session-cache.bin";

      --  One run, optionally writing or reading the context.
      function Said (Option, Value : String) return String is
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "abab");
         Add (Source, "--max-tokens");
         Add (Source, "4");
         Add (Source, "--temperature");
         Add (Source, "0");
         if Option /= "" then
            Add (Source, Option);
            Add (Source, Value);
         end if;

         Ran (Source, Status);
         Assert (Status = 0,
                 "a run with " & Option & " failed with status"
                 & Natural'Image (Status));
         return Last_Output;
      end Said;
   begin
      Tiny_Model.Write (Model, Room => 64);

      declare
         Plain  : constant String := Said ("", "");
         Stored : constant String := Said ("--save-session", Saved);
         Reused : constant String := Said ("--load-session", Saved);
      begin
         Assert (Plain'Length > 0, "the plain run produced nothing");
         Assert (Stored = Plain,
                 "saving the context changed the answer: <" & Stored
                 & "> against <" & Plain & ">");
         Assert (Reused = Plain,
                 "reusing a saved context changed the answer: <" & Reused
                 & "> against <" & Plain & ">");
      end;

      --  A context that is not there is not a context.
      declare
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Add (Source, "--load-session");
         Add (Source, "obj/no-such-session.bin");

         Ran (Source, Status);
         Assert (Status /= 0,
                 "a run told to read a saved context that is not there "
                 & "reported success");
      end;
   end Saved_Context_Changes_Nothing;

   --  A grammar constrains what a run may produce.
   --
   --  The engine tests say the matcher accepts the right texts. This says
   --  the run is actually held to it: every byte that reaches the output
   --  came from a token the grammar allowed, and a grammar this vocabulary
   --  cannot satisfy is reported as that rather than as a sampler with
   --  nothing left to choose from.
   procedure Grammar_Constrains_The_Run
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Model : constant String := "obj/grammar-model.gguf";

      function Under (Rules : String; Status : out Natural) return String is
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "a");
         Add (Source, "--max-tokens");
         Add (Source, "6");
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, "--grammar");
         Add (Source, Rules);

         Ran (Source, Status);
         return Last_Output;
      end Under;

      Status : Natural;
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  Only three letters are allowed, so only those may appear.
      declare
         Text : constant String := Under ("root ::= [abc]+", Status);
      begin
         Assert (Status = 0,
                 "a constrained run failed with status"
                 & Natural'Image (Status));
         Assert (Text'Length > 0, "a constrained run produced nothing");

         for Letter of Text loop
            Assert (Letter in 'a' .. 'c',
                    "the run produced a character the grammar forbids: "
                    & Letter & " in <" & Text & ">");
         end loop;
      end;

      --  A different set gives different text, so the constraint is being
      --  read rather than the model happening to answer in letters.
      declare
         Text : constant String := Under ("root ::= [c]+", Status);
      begin
         Assert (Status = 0,
                 "a single-letter grammar failed with status"
                 & Natural'Image (Status));
         for Letter of Text loop
            Assert (Letter = 'c',
                    "a grammar of one letter produced another: <"
                    & Text & ">");
         end loop;
      end;

      --  And a grammar whose first character no token of this vocabulary
      --  spells is refused by name, rather than leaving the sampler with
      --  nothing and reporting that instead.
      declare
         Said   : constant String := "obj/grammar-errors.txt";
         Handle : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, Said);
         Ada.Text_IO.Set_Error (Handle);
         begin
            declare
               Ignored : constant String :=
                 Under ("root ::= ""{""", Status);
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
         exception
            when others =>
               Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
               Ada.Text_IO.Close (Handle);
               raise;
         end;
         Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
         Ada.Text_IO.Close (Handle);

         Assert (Status /= 0,
                 "a grammar no token can satisfy reported success");
         Assert (Project_Tools.Text.Contains
                   (Text_Of (Said), "MR-GRAM-0007"),
                 "a grammar no token of this vocabulary can satisfy was "
                 & "refused without naming "
                 & E.Error_Code'Image (E.Grammar_Rejected_Every_Token)
                 & ": " & Text_Of (Said));
      end;
   end Grammar_Constrains_The_Run;

   --  Embedding a text reports the state, not the distribution.
   --
   --  What `run` prints is what the model would say next; what this prints
   --  is what it made of what it read. The two come from the same forward
   --  pass and the second is the input to the first, so the way to be sure
   --  this reports the state is to check the things only the state has: as
   --  many components as the model is wide, unit length unless the caller
   --  says otherwise, and a value that depends on which positions were
   --  pooled.
   procedure Embedding_Reports_The_State
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Model : constant String := "obj/embed-model.gguf";

      --  Run one embedding and return its components.
      function Vector (Extra, Value : String) return Reals is
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "embed");
         Add (Source, Model);
         Add (Source, "--prompt");
         Add (Source, "abcabcabc");
         if Extra /= "" then
            Add (Source, Extra);
            if Value /= "" then
               Add (Source, Value);
            end if;
         end if;

         Ran (Source, Status);
         Assert (Status = 0,
                 "embedding failed with status" & Natural'Image (Status));

         return Parsed (Last_Output);
      end Vector;

      Mean, Last, Plain : Reals;
   begin
      Tiny_Model.Write (Model, Room => 64);

      Mean := Vector ("", "");
      Assert (Mean.Count = Tiny_Model.Embedding,
              "an embedding had" & Natural'Image (Mean.Count)
              & " components where the model is"
              & Natural'Image (Tiny_Model.Embedding) & " wide");

      --  Unit length, which is what makes two of these comparable by a dot
      --  product and is the reason it is the default.
      declare
         Total : Long_Float := 0.0;
      begin
         for Index in 1 .. Mean.Count loop
            Total := Total + Mean.Values (Index) * Mean.Values (Index);
         end loop;
         Assert (abs (Total - 1.0) < 1.0E-4,
                 "an embedding was not at unit length:"
                 & Long_Float'Image (Total));
      end;

      --  The same text twice is the same vector. Nothing here samples, so a
      --  difference would mean the state depends on something it should not.
      declare
         Again : constant Reals := Vector ("", "");
      begin
         Assert (Again.Count = Mean.Count, "the width changed between runs");
         for Index in 1 .. Mean.Count loop
            Assert (Again.Values (Index) = Mean.Values (Index),
                    "the same text embedded differently the second time");
         end loop;
      end;

      --  Pooling the last position alone is not pooling all of them, on a
      --  text of more than one position.
      Last := Vector ("--pooling", "last");
      declare
         Apart : Long_Float := 0.0;
      begin
         for Index in 1 .. Mean.Count loop
            Apart := Long_Float'Max
              (Apart, abs (Mean.Values (Index) - Last.Values (Index)));
         end loop;
         Assert (Apart > 0.0,
                 "pooling the last position gave what pooling every "
                 & "position gives, so the pooling was not applied");
      end;

      --  And without normalization the vector is longer than one -- these
      --  states are not unit vectors to begin with -- while pointing the
      --  same way.
      Plain := Vector ("--no-normalize", "");
      declare
         Total : Long_Float := 0.0;
      begin
         for Index in 1 .. Plain.Count loop
            Total := Total + Plain.Values (Index) * Plain.Values (Index);
         end loop;
         Assert (abs (Total - 1.0) > 1.0E-3,
                 "the vector was at unit length despite --no-normalize:"
                 & Long_Float'Image (Total));

         --  Same direction: each component in the same ratio to the whole.
         declare
            Length : constant Long_Float :=
              Long_Float (Model_Runner.Numerics.Sqrt
                            (Model_Runner.Numerics.Wide_Real (Total)));
         begin
            for Index in 1 .. Plain.Count loop
               Assert
                 (abs (Plain.Values (Index) / Length - Mean.Values (Index))
                  < 1.0E-4,
                  "normalizing changed the direction at component"
                  & Natural'Image (Index));
            end loop;
         end;
      end;

      --  And how many tokens went through the weights at once is not
      --  supposed to be visible in the answer. It is the one thing that
      --  could go wrong quietly when the text stopped being evaluated a
      --  token at a time: a batch that pooled the wrong positions, or
      --  pooled the last batch instead of the last token, would still
      --  produce a plausible vector of the right length.
      declare
         Split : constant Reals := Vector ("--batch-size", "2");
      begin
         Assert (Split.Count = Mean.Count,
                 "the batch size changed how many components came out");
         for Index in 1 .. Mean.Count loop
            Assert (abs (Split.Values (Index) - Mean.Values (Index))
                    < 1.0E-5,
                    "the batch size changed the embedding at component"
                    & Natural'Image (Index));
         end loop;
      end;

      declare
         One : constant Reals := Vector ("--batch-size", "1");
      begin
         for Index in 1 .. Mean.Count loop
            Assert (abs (One.Values (Index) - Mean.Values (Index)) < 1.0E-5,
                    "a batch of one and a batch of many disagree at "
                    & "component" & Natural'Image (Index));
         end loop;
      end;
   end Embedding_Reports_The_State;

   procedure Every_Backend_Can_Be_Named
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Back renames Model_Runner.Backend;

      Item   : Opt.Command;
      Status : E.Error_Info;

      --  A fresh command line each time; Fixed_Arguments only grows.
      procedure Ask (Name : String; Outcome : out E.Error_Info) is
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, "m.gguf");
         Add (Source, "--prompt");
         Add (Source, "hi");
         Add (Source, "--backend");
         Add (Source, Name);
         Opt.Parse (Source, Item, Outcome);
      end Ask;
   begin
      for Kind in Back.Backend_Kind loop
         declare
            Name : constant String := Back.Backend_Name (Kind);
         begin
            Assert (Name /= "",
                    "a backend has no name: " & Back.Backend_Kind'Image (Kind));

            Ask (Name, Status);
            Assert (E.Is_Ok (Status),
                    "the backend named " & Name & " was refused: "
                    & E.Error_Code'Image (Status.Code));
            Opt.Release (Item);
         end;
      end loop;

      --  And a name no backend has is refused, rather than falling through to
      --  whichever one happens to be first.
      for Which in 1 .. 4 loop
         declare
            Wrong : constant String :=
              (case Which is
                 when 1 => "gpu",
                 when 2 => "CPU",
                 when 3 => "cpu ",
                 when others => "");
         begin
            Ask (Wrong, Status);
            Assert (E.Is_Error (Status),
                    "the backend named '" & Wrong & "' was accepted");
            Opt.Release (Item);
         end;
      end loop;

      --  It exits as the usage error it is. A backend refusing a format is a
      --  fault in this program and exits as one; a name the caller typed is
      --  not, and reported the same way it would have crashed.
      Assert (E.Exit_Status (E.Make (E.Backend_Unknown)) = E.Exit_Usage,
              "an unknown backend does not exit as a usage error");
   end Every_Backend_Can_Be_Named;

   --  Every chat format this build carries can be named on the command line.
   --
   --  The mirror of the backend test, and it exists because the two options
   --  did not answer alike: --backend gpu said no backend of that name is in
   --  this build, while --chat-template nope said the value was invalid,
   --  which is true of any bad value and tells a reader nothing about what
   --  there is. A caller could not predict which kind of answer an option
   --  would give.
   procedure Every_Chat_Format_Can_Be_Named
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Tmpl renames Model_Runner.Templates;

      Item   : Opt.Command;
      Status : E.Error_Info;

      procedure Ask (Name : String; Outcome : out E.Error_Info) is
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, "m.gguf");
         Add (Source, "--prompt");
         Add (Source, "hi");
         Add (Source, "--chat-template");
         Add (Source, Name);
         Opt.Parse (Source, Item, Outcome);
      end Ask;
   begin
      for Format in Tmpl.Chat_Format loop
         declare
            Name : constant String := Tmpl.Format_Name (Format);
         begin
            Assert (Name /= "", "a chat format has no name");

            --  Named, accepted, and carrying a template that compiles. A
            --  name the parser takes and the engine cannot then use would
            --  be worse than one it refused.
            Ask (Name, Status);
            Assert (E.Is_Ok (Status),
                    "the format named " & Name & " was refused: "
                    & E.Error_Code'Image (Status.Code));
            Opt.Release (Item);

            Assert (Tmpl.Built_In (Name) /= "",
                    "the format named " & Name & " carries no template");
         end;
      end loop;

      --  A name no format has is refused, and says so the way --backend
      --  does rather than the way a malformed number does.
      for Which in 1 .. 3 loop
         declare
            Wrong : constant String :=
              (case Which is
                 when 1 => "nope",
                 when 2 => "LLAMA3",
                 when others => "");
         begin
            Ask (Wrong, Status);
            Assert (Status.Code = E.Template_Unknown_Format,
                    "the format named '" & Wrong & "' gave "
                    & E.Error_Code'Image (Status.Code));
            Opt.Release (Item);
         end;
      end loop;

      --  And it exits as the usage error it is, like the backend one.
      Assert (E.Exit_Status (E.Make (E.Template_Unknown_Format))
              = E.Exit_Usage,
              "an unknown chat format does not exit as a usage error");
      Assert (E.Exit_Status (E.Make (E.Template_Syntax_Error))
              = E.Exit_Model_Format,
              "a malformed template stopped exiting as a model-format error");
   end Every_Chat_Format_Can_Be_Named;

   --  The help screen is laid out, and lists every option it accepts.
   --
   --  Nothing read it. Every check read the catalog the lines come from, so
   --  when three of them were moved out of the block that indents them --
   --  one at a time, each to give it a value the program computes -- they
   --  printed flush left at the bottom of the list and stayed that way for
   --  three commits and a full checklist run.
   --
   --  Reading the screen is the only way to see that. It goes to
   --  Current_Output, so a test can take it.
   procedure Help_Screen_Is_Laid_Out
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Captured : constant String := "obj/help-screen.txt";

      --  Run one help topic and return what it printed.
      function Screen (Topic : String) return String is
         Source : Fixed_Arguments;
         Status : Natural;
         Handle : File_Type;
      begin
         Add (Source, "help");
         Add (Source, Topic);

         Create (Handle, Out_File, Captured);
         Set_Output (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Output (Standard_Output);
               Close (Handle);
               raise;
         end;
         Set_Output (Standard_Output);
         Close (Handle);

         Assert (Status = 0,
                 "help " & Topic & " failed with status"
                 & Natural'Image (Status));
         return Text_Of (Captured);
      end Screen;

      --  Assert every option line in Text is indented by exactly two spaces,
      --  and report how many there were.
      function Options_Are_Indented (Text : String) return Natural is
         Count  : Natural := 0;
         Cursor : Natural := Text'First;
      begin
         while Cursor <= Text'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Text'Last
                 and then Text (Stop) /= ASCII.LF
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Text (Cursor .. Stop - 1);
               begin
                  --  A line that introduces an option, wherever it starts.
                  if Line'Length > 2
                    and then Model_Runner.Text.Trim (Line)'Length > 2
                    and then Model_Runner.Text.Starts_With
                               (Model_Runner.Text.Trim (Line), "--")
                  then
                     Count := Count + 1;
                     Assert (Line (Line'First .. Line'First + 1) = "  "
                             and then Line (Line'First + 2) /= ' ',
                             "an option line is not indented by two spaces: '"
                             & Line & "'");
                  end if;
               end;

               Cursor := Stop + 1;
            end;
         end loop;
         return Count;
      end Options_Are_Indented;

      Run_Screen     : constant String := Screen ("run");
      Inspect_Screen : constant String := Screen ("inspect");
   begin
      Assert (Options_Are_Indented (Run_Screen) > 20,
              "the run help lists almost no options");
      Assert (Options_Are_Indented (Inspect_Screen) > 3,
              "the inspect help lists almost no options");

      --  Every option run parses appears on its screen. An option a caller
      --  can give and cannot find is one they will not know to give.
      declare
         Absent : Natural := 0;

         procedure Require (Name : String) is
         begin
            if not Project_Tools.Text.Contains (Run_Screen, "  " & Name) then
               Absent := Absent + 1;
               Assert (False, Name & " is accepted by run and not in its help");
            end if;
         end Require;
      begin
         Require ("--prompt");
         Require ("--prompt-file");
         Require ("--system");
         Require ("--system-file");
         Require ("--interactive");
         Require ("--raw");
         Require ("--max-tokens");
         Require ("--context-size");
         Require ("--threads");
         Require ("--backend");
         Require ("--batch-size");
         Require ("--temperature");
         Require ("--top-k");
         Require ("--top-p");
         Require ("--min-p");
         Require ("--chat-template");
         Require ("--repeat-penalty");
         Require ("--frequency-penalty");
         Require ("--presence-penalty");
         Require ("--repeat-window");
         Require ("--seed");
         Require ("--stop");
         Require ("--stop-token");
         Require ("--memory-limit");
         Require ("--device-memory");
         Require ("--device-patience");
         Require ("--mmap");
         Require ("--no-mmap");
         Require ("--quiet");
         Require ("--verbose");
         Require ("--show-stats");
         Require ("--no-stats");
         Require ("--locale");
         Require ("--color");
         Assert (Absent = 0, "options are missing from the help");
      end;

      --  And the lines that carry a computed value carry it, rather than the
      --  placeholder that stands for it.
      Assert (Project_Tools.Text.Contains (Run_Screen, "cpu"),
              "the backend line does not name the backend");
      Assert (Project_Tools.Text.Contains (Run_Screen, "llama3"),
              "the chat-format line does not name a format");
      Assert (not Project_Tools.Text.Contains (Run_Screen, "{value}"),
              "a help line printed its placeholder instead of a value");
      Assert (not Project_Tools.Text.Contains (Inspect_Screen, "{value}"),
              "an inspect help line printed its placeholder");
   end Help_Screen_Is_Laid_Out;

   --  The reported screens are laid out: fields in a column, under headings.
   --
   --  inspect is the second-largest thing this program prints and nothing
   --  read it; the statistics line was read only for whether one word of it
   --  appeared. Both are built from many separate calls whose layout lives
   --  in the caller, which is the property that let three help lines drift
   --  out of their column and stay there.
   --
   --  They go to standard error, which a test can take.
   procedure Reported_Screens_Are_Laid_Out
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model    : constant String := "obj/screens-model.gguf";
      Captured : constant String := "obj/screens.txt";

      --  Run a command and return what reached standard error.
      function Reported (Words : String) return String is
         Source : Fixed_Arguments;
         Status : Natural;
         Handle : File_Type;
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

         --  Both streams, into one file. This reads screens rather than
         --  telling the streams apart -- an inspection is an answer and
         --  statistics are not, and the layout is the same question for
         --  both. Streams_Are_Separate is what holds them to their streams.
         Create (Handle, Out_File, Captured);
         Set_Output (Handle);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Output (Standard_Output);
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Output (Standard_Output);
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status = 0,
                 """" & Words & """ failed with status"
                 & Natural'Image (Status));
         return Text_Of (Captured);
      end Reported;

      --  Every field line in Text starts its value at the same column, and
      --  every heading starts at the first. Returns how many fields there
      --  were, so that a screen which printed none cannot pass.
      --  The same, for what reaches standard output. The two streams carry
      --  different things on purpose -- diagnostics, progress and statistics
      --  to one, application text to the other -- so a test has to say which
      --  it means, and getting it wrong reads as the screen being empty.
      function Printed (Words : String) return String is
         Source : Fixed_Arguments;
         Status : Natural;
         Handle : File_Type;
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

         Create (Handle, Out_File, Captured);
         Set_Output (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Output (Standard_Output);
               Close (Handle);
               raise;
         end;
         Set_Output (Standard_Output);
         Close (Handle);

         Assert (Status = 0,
                 """" & Words & """ failed with status"
                 & Natural'Image (Status));
         return Text_Of (Captured);
      end Printed;

      --  Whether Text holds a catalog placeholder: a brace, a run of
      --  lower-case letters or underscores, and a closing brace. Looking for
      --  a bare brace is not enough -- a model's own chat template is
      --  metadata that inspect prints, and it is full of them.
      function Holds_Placeholder (Text : String) return Boolean is
      begin
         for Index in Text'Range loop
            if Text (Index) = '{' then
               declare
                  Scan : Natural := Index + 1;
               begin
                  while Scan <= Text'Last
                    and then (Text (Scan) in 'a' .. 'z'
                              or else Text (Scan) = '_')
                  loop
                     Scan := Scan + 1;
                  end loop;
                  if Scan > Index + 1
                    and then Scan <= Text'Last
                    and then Text (Scan) = '}'
                  then
                     return True;
                  end if;
               end;
            end if;
         end loop;
         return False;
      end Holds_Placeholder;

      function Fields_Line_Up (Text : String) return Natural is
         Column : Natural := 0;
         Count  : Natural := 0;
         Cursor : Natural := Text'First;
      begin
         while Cursor <= Text'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Text'Last and then Text (Stop) /= ASCII.LF loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Text (Cursor .. Stop - 1);
                  At_Value : Natural := 0;
               begin
                  if Line'Length > 2
                    and then Line (Line'First .. Line'First + 1) = "  "
                  then
                     --  A field: two spaces, a label, a run of two or more
                     --  spaces, then the value. The first such run is the
                     --  column; a later one is inside the value, which is
                     --  what "present and supported" taught this test.
                     --
                     --  A label too long for the column takes a single
                     --  space instead. Those cannot line up with anything
                     --  and are not counted.
                     for Index in Line'First + 2 .. Line'Last - 2 loop
                        if At_Value = 0
                          and then Line (Index) = ' '
                          and then Line (Index + 1) = ' '
                        then
                           At_Value := Index + 2;
                           while At_Value <= Line'Last
                             and then Line (At_Value) = ' '
                           loop
                              At_Value := At_Value + 1;
                           end loop;
                        end if;
                     end loop;

                     if At_Value > Line'First + 2
                       and then At_Value - Line'First >= 24
                     then
                        Count := Count + 1;
                        if Column = 0 then
                           Column := At_Value - Line'First;
                        else
                           Assert (At_Value - Line'First = Column,
                                   "a field starts its value at column"
                                   & Natural'Image (At_Value - Line'First)
                                   & " where the others use"
                                   & Natural'Image (Column) & ": '"
                                   & Line & "'");
                        end if;
                     end if;

                  elsif Line'Length > 0 and then Line (Line'First) = ' ' then
                     Assert (False,
                             "a line is indented by one space: '" & Line & "'");

                  elsif Line'Length > 0 then
                     --  A heading. Each section sets its own column: the
                     --  container block puts values at one, the metadata
                     --  table is three columns wide and puts them at
                     --  another, and neither is wrong. What would be wrong
                     --  is a section disagreeing with itself.
                     Column := 0;
                  end if;
               end;

               Cursor := Stop + 1;
            end;
         end loop;
         return Count;
      end Fields_Line_Up;
   begin
      --  Room enough for a turn to complete; the default context is
      --  sixteen tokens and the rendered conversation alone exceeds it.
      Tiny_Model.Write (Model, Room => 256);

      --  inspect, with everything it can show.
      declare
         Screen : constant String :=
           Reported ("inspect " & Model & " --metadata --tensors");
      begin
         Assert (Fields_Line_Up (Screen) > 8,
                 "the inspect screen showed almost no fields");
         Assert (Project_Tools.Text.Contains (Screen, "GGUF version"),
                 "the inspect screen does not report the container version");
         Assert (Project_Tools.Text.Contains (Screen, "llama"),
                 "the inspect screen does not report the architecture");
         Assert (not Holds_Placeholder (Screen),
                 "the inspect screen printed an unsubstituted placeholder");
      end;

      --  version reports what this build can take, from the build. Someone
      --  asking whether their file will open gets an answer.
      declare
         Screen : constant String := Printed ("version");
      begin
         for Format in Model_Runner.GGUF.Tensor_Type loop
            if Model_Runner.Quantization.Is_Decodable (Format) then
               Assert (Project_Tools.Text.Contains
                         (Screen, Model_Runner.GGUF.Type_Name (Format)),
                       "version does not report "
                       & Model_Runner.GGUF.Type_Name (Format)
                       & ", which this build decodes");
            end if;
         end loop;

         for Kind in Model_Runner.Backend.Backend_Kind loop
            Assert (Project_Tools.Text.Contains
                      (Screen, Model_Runner.Backend.Backend_Name (Kind)),
                    "version does not report a backend this build has");
         end loop;

         for Format in Model_Runner.Templates.Chat_Format loop
            Assert (Project_Tools.Text.Contains
                      (Screen, Model_Runner.Templates.Format_Name (Format)),
                    "version does not report a chat format this build has");
         end loop;

         Assert (not Holds_Placeholder (Screen),
                 "version printed an unsubstituted placeholder");
      end;

      --  And the statistics of a run, which is the same shape.
      declare
         Screen : constant String :=
           Reported ("run " & Model
                     & " --prompt hi --max-tokens 2 --show-stats");
         Missing : Natural := 0;

         procedure Require (Label : String) is
         begin
            if not Project_Tools.Text.Contains (Screen, Label) then
               Missing := Missing + 1;
               Assert (False, "the statistics do not report " & Label);
            end if;
         end Require;
      begin
         Assert (Fields_Line_Up (Screen) > 5,
                 "the statistics showed almost no fields");
         Require ("prompt tokens");
         Require ("generated tokens");
         Require ("context position");
         Require ("seed");
         Assert (Missing = 0, "figures are missing from the statistics");
         Assert (not Holds_Placeholder (Screen),
                 "the statistics printed an unsubstituted placeholder");
      end;
   end Reported_Screens_Are_Laid_Out;

   --  The progress trace and the diagnostic reach the screen in the shape
   --  they claim.
   --
   --  The last three renderings nothing read. The progress trace is a line
   --  per stage and the stages are an enumeration, so a stage added without
   --  a message would print its own identifier and no test would mind. A
   --  diagnostic's context frames and file offset are verbose-only, which is
   --  a promise about what a quiet run does not say. And /settings prints
   --  ten fields in a column that nothing had looked at.
   procedure Trace_And_Diagnostic_Render
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model    : constant String := "obj/trace-model.gguf";
      Captured : constant String := "obj/trace.txt";

      --  Run a command and return what reached standard error.
      function Traced (Words : String; Expect : Natural := 0) return String is
         Source : Fixed_Arguments;
         Status : Natural;
         Handle : File_Type;
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

         Create (Handle, Out_File, Captured);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status = Expect,
                 """" & Words & """ gave status" & Natural'Image (Status)
                 & " and not" & Natural'Image (Expect));
         return Text_Of (Captured);
      end Traced;

      --  Whether a screen holds Text as a line: the whole of one when Whole,
      --  or the start of one otherwise. A line may carry generated text
      --  ahead of it, since that goes to the other stream and the two are
      --  interleaved by the terminal, so the end of a line is what is
      --  matched against and not its beginning.
      function Said_On_Its_Own
        (Screen : String; Text : String; Whole : Boolean) return Boolean
      is
         Cursor : Natural := Screen'First;
      begin
         while Cursor <= Screen'Last loop
            declare
               Stop : Natural := Cursor;
            begin
               while Stop <= Screen'Last and then Screen (Stop) /= ASCII.LF
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String :=
                    Model_Runner.Text.Trim (Screen (Cursor .. Stop - 1));
               begin
                  if Whole then
                     if Line'Length >= Text'Length
                       and then Line (Line'Last - Text'Length + 1 .. Line'Last)
                                = Text
                     then
                        return True;
                     end if;
                  elsif Project_Tools.Text.Contains (Line, Text) then
                     return True;
                  end if;
               end;

               Cursor := Stop + 1;
            end;
         end loop;
         return False;
      end Said_On_Its_Own;

      Catalog : aliased Model_Runner.Localization.Catalog;
   begin
      Tiny_Model.Write (Model, Room => 256);
      Model_Runner.Localization.Open
        (Catalog, Model_Runner.Platform.Catalog_Path, "en");

      --  Every load stage this build can report has a line of its own, and a
      --  verbose run reaches all of them.
      --
      --  With --repack, because one stage is published only when repacking
      --  was asked for. A run without it would reach every stage but that
      --  one, and a check that skipped the stage it could not reach would
      --  stop being the check it is: the point is that no stage is declared
      --  and shown by nothing.
      declare
         Screen : constant String :=
           Traced ("run " & Model
                   & " --prompt hi --max-tokens 1 --repack f32 --verbose");
      begin
         for Stage in Model_Runner.Progress.Load_Stage loop
            declare
               Key : constant String :=
                 "progress.loading."
                 & Model_Runner.Text.To_Lower
                     (Model_Runner.Progress.Load_Stage'Image (Stage));
               Said : constant String :=
                 Model_Runner.Localization.Text (Catalog, Key);
            begin
               Assert (Said /= "" and then Said /= "<" & Key & ">",
                       "the load stage "
                       & Model_Runner.Progress.Load_Stage'Image (Stage)
                       & " has no message of its own");
               Assert (Project_Tools.Text.Contains (Screen, Said),
                       "a verbose run did not report " & Said);
            end;
         end loop;
      end;

      --  And every generation stage, from the same run. These are the
      --  stages of a request rather than of a load, and they are published
      --  from two layers -- the engine says most of them, the command layer
      --  says the prompt was rendered, because generation is handed one
      --  already rendered and never sees the conversation it came from.
      declare
         Screen : constant String :=
           Traced ("run " & Model & " --prompt hi --max-tokens 2 --verbose");
      begin
         for Stage in Model_Runner.Progress.Generation_Stage loop
            declare
               Key : constant String :=
                 "progress.generation."
                 & Model_Runner.Text.To_Lower
                     (Model_Runner.Progress.Generation_Stage'Image (Stage));
               --  Rendered with the arguments these lines take, because a
               --  message asked for without them comes back as its own key.
               Said : constant String :=
                 Model_Runner.Localization.Text
                   (Catalog, Key,
                    [Model_Runner.Localization.Named ("completed", "0"),
                     Model_Runner.Localization.Named ("total", "0")]);

               --  The message up to its first figure. The counts a run
               --  reports are not known here, and rendering with zeroes
               --  puts a zero where they will be, so the part before it is
               --  the part that can be looked for.
               Fixed : Natural := Said'Last;
            begin
               Assert (Said /= "" and then Said /= "<" & Key & ">",
                       "the generation stage "
                       & Model_Runner.Progress.Generation_Stage'Image (Stage)
                       & " has no message of its own");

               for Index in Said'Range loop
                  if Said (Index) in '0' .. '9' then
                     Fixed := Index - 1;
                     exit;
                  end if;
               end loop;

               --  A stage whose message carries no figure has to appear as
               --  a line of its own. "evaluating prompt" is the whole of
               --  one stage's line and the start of another's, so looking
               --  for it anywhere finds the wrong one: silencing the first
               --  left the second saying it and the test was content.
               Assert (Said_On_Its_Own
                         (Screen,
                          Model_Runner.Text.Trim (Said (Said'First .. Fixed)),
                          Whole => Fixed = Said'Last),
                       "a verbose run did not report "
                       & Model_Runner.Progress.Generation_Stage'Image (Stage));
            end;
         end loop;
      end;

      --  What a reader can do about it, chosen from the recovery class the
      --  code already carried and nothing had read. The classification is
      --  still only a classification, so this checks that each class that
      --  has something to say says it: silencing one of them passes every
      --  check that only asks whether the value is mentioned.
      declare
         Usage : constant String :=
           Model_Runner.Localization.Text (Catalog, "diagnostic.hint.usage");
         Room  : constant String :=
           Model_Runner.Localization.Text
             (Catalog, "diagnostic.hint.resource");

         Bad_Option : constant String :=
           Traced ("run " & Model & " --nope", Expect => 2);
         Too_Small  : constant String :=
           Traced ("run " & Model & " --prompt hi --max-tokens 1"
                   & " --memory-limit 20000", Expect => 5);
         Missing    : constant String :=
           Traced ("run obj/absent-model.gguf --prompt hi", Expect => 6);
      begin
         Assert (Project_Tools.Text.Contains (Bad_Option, Usage),
                 "a usage error did not say where usage is written");
         Assert (Project_Tools.Text.Contains (Too_Small, Room),
                 "a limit that was too small did not say what to do: "
                 & Too_Small);

         --  And a class with nothing useful to say says nothing. A path
         --  that is wrong is not put right by reading the usage, which is
         --  what the first version of this pointed the reader at.
         Assert (not Project_Tools.Text.Contains (Missing, Usage),
                 "a missing file was answered with the usage hint");
      end;

      --  A cut-short copy of the fixture, for a diagnostic that has a file
      --  offset to report.
      declare
         use Ada.Streams;
         From, Into : Stream_IO.File_Type;
         Block      : Stream_Element_Array (1 .. 200);
         Last       : Stream_Element_Offset;
      begin
         Stream_IO.Open (From, Stream_IO.In_File, Model);
         Stream_IO.Create (Into, Stream_IO.Out_File, "obj/trace-cut.gguf");
         Stream_IO.Read (From, Block, Last);
         Stream_IO.Write (Into, Block (1 .. Last));
         Stream_IO.Close (Into);
         Stream_IO.Close (From);
      end;

      --  A diagnostic says the severity, the code and the description, and
      --  nothing else unless asked. The frame and offset lines are the
      --  things a quiet run promises not to print.
      declare
         --  How many non-empty lines a screen holds. The promise is that a
         --  quiet run says the diagnostic and stops; counting is the way to
         --  check it without guessing at the wording of what it left out.
         --
         --  Looking for a prefix of the frame message does not work: it
         --  begins with the program's own name, so "mode" was found inside
         --  "model_runner" and a quiet run looked like it had printed one.
         function Lines (Text : String) return Natural is
            Count  : Natural := 0;
            Cursor : Natural := Text'First;
         begin
            while Cursor <= Text'Last loop
               declare
                  Stop : Natural := Cursor;
               begin
                  while Stop <= Text'Last and then Text (Stop) /= ASCII.LF
                  loop
                     Stop := Stop + 1;
                  end loop;
                  if Model_Runner.Text.Trim (Text (Cursor .. Stop - 1)) /= ""
                  then
                     Count := Count + 1;
                  end if;
                  Cursor := Stop + 1;
               end;
            end loop;
            return Count;
         end Lines;

         --  A file that ends inside a field, so that the diagnostic has a
         --  location to withhold. A missing file has none, and against that
         --  one a quiet run and a verbose run print the same thing --
         --  which is why the first version of this test passed while
         --  frames were printed unconditionally.
         Cut : constant String := "obj/trace-cut.gguf";

         Quiet : constant String :=
           Traced ("inspect " & Cut, Expect => 3);
         Loud  : constant String :=
           Traced ("inspect " & Cut & " --verbose", Expect => 3);
      begin
         Assert (Project_Tools.Text.Contains (Quiet, "MR-GGUF-0001"),
                 "a diagnostic did not print its code: " & Quiet);
         Assert (Project_Tools.Text.Contains (Quiet, "model_runner: "),
                 "a diagnostic did not name the program");

         --  One line, and one only. Frames and the file offset are the
         --  lines a quiet run promises not to add, and a verbose run of the
         --  same failure does add them.
         Assert (Lines (Quiet) = 1,
                 "a quiet diagnostic printed"
                 & Natural'Image (Lines (Quiet)) & " lines: " & Quiet);
         Assert (Lines (Loud) > Lines (Quiet),
                 "a verbose diagnostic said no more than a quiet one");
      end;

   end Trace_And_Diagnostic_Render;

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

      --  A backend this build has is accepted; one it does not have is
      --  refused by name. An option accepted as a no-op would be worse than
      --  an absent one: a caller who asks for a backend and is not told
      --  there is only one has been told the wrong thing.
      Expect (E.No_Error, "run m.gguf --prompt hi --backend cpu");
      Expect (E.No_Error, "run m.gguf --prompt hi --backend=cpu");
      Expect (E.Backend_Unknown, "run m.gguf --prompt hi --backend gpu");
      Expect (E.Backend_Unknown, "run m.gguf --prompt hi --backend CPU");
      Expect (E.CLI_Missing_Option_Value, "run m.gguf --prompt hi --backend");
      Expect (E.CLI_Repeated_Option,
              "run m.gguf --prompt hi --backend cpu --backend cpu");
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

      --  A draft model that cannot draft. Refused rather than ignored,
      --  because a draft is a second model file and a run that loads one
      --  and never asks it anything has paid for nothing.
      Expect (E.CLI_Option_Combination,
              "run m.gguf --prompt a --draft-model d.gguf --temperature 0.8");
      Expect (E.CLI_Option_Combination,
              "run m.gguf --prompt a --draft-model d.gguf --grammar root");

      --  And the same options apart are fine, so neither refusal is the
      --  parser objecting to one of them on its own.
      Expect (E.No_Error, "run m.gguf --prompt a --temperature 0.8");
      Expect (E.No_Error,
              "run m.gguf --prompt a --draft-model d.gguf --temperature 0");
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

   procedure Start
     (Item    : in out Harness;
      Backend : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Repack  : L.Repack_Mode := L.No_Repack)
   is
      Status : E.Error_Info;
   begin
      Containers.Reader.Parse (Item.Parsed, Item.Source, Status => Status);
      Assert (E.Is_Ok (Status), "tiny model did not parse");
      L.Prepare
        (Item.Ready, Item.Parsed, Item.Source, Backend => Backend,
         Repack => Repack, Status => Status);
      Assert (E.Is_Ok (Status), "tiny model did not prepare");
   end Start;

   --  A session's memory is counted, and the limit counts it.
   --
   --  Nine of eleven accounting categories were charged by nothing, so a
   --  report of where memory went named the weights and read zero for
   --  everything else -- including the KV cache, which is the largest thing
   --  a session allocates and grows with the context.
   --
   --  And --memory-limit set the model's bound only. A caller asking for a
   --  hundred megabytes could be given a model inside it and then a session
   --  of any size at all, which is the part that mattered.
   procedure Session_Memory_Is_Counted
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Mem renames Model_Runner.Memory;

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Room => 256);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Rig     : Harness (Held'Access);
         Session : L.Session;
         Status  : E.Error_Info;
      begin
         Start (Rig);
         L.Open (Session, Rig.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");

         --  Every category a session fills is filled.
         declare
            Account : constant Mem.Account := L.Accounting (Session);
            Empty   : Natural := 0;
         begin
            for Kind in Mem.KV_Cache .. Mem.Template_Buffers loop
               if Account.By_Category (Kind) = 0 then
                  Empty := Empty + 1;
                  Assert (False,
                          "a session holds nothing under "
                          & Mem.Category'Image (Kind));
               end if;
            end loop;
            Assert (Empty = 0, "a session left categories at zero");

            Assert (Account.By_Category (Mem.KV_Cache) > 0,
                    "the KV cache is not counted");
            Assert (Account.Current >= Account.By_Category (Mem.KV_Cache),
                    "the total is smaller than the largest thing in it");
         end;

         L.Close (Session);

         --  And the model's own two.
         declare
            Account : constant Mem.Account := L.Accounting (Rig.Ready);
         begin
            Assert (Account.By_Category (Mem.Model_Weights) > 0,
                    "the weights are not counted");
            Assert (Account.By_Category (Mem.Tokenizer_Storage) > 0,
                    "the vocabulary's storage is not counted");
            Assert (Account.By_Category (Mem.Metadata_Storage) > 0,
                    "the container's metadata is not counted");
         end;

         L.Close (Rig.Ready, Status);
         Containers.Close (Rig.Parsed);
      end;

      --  A limit below what the session needs refuses it, naming the
      --  category. The same limit above it does not.
      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Rig    : Harness (Held'Access);
         Tight  : L.Session;
         Loose  : L.Session;
         Bounds : Model_Runner.Limits.Session_Limits :=
           Model_Runner.Limits.Default_Session_Limits;
         Status : E.Error_Info;
      begin
         Start (Rig);

         Bounds.Max_Session_Bytes := 1;
         L.Open (Tight, Rig.Ready, Session_Bounds => Bounds,
                 Status => Status);
         Assert (Status.Code = E.Memory_Limit_Exceeded,
                 "a session of one byte was allowed: "
                 & E.Error_Code'Image (Status.Code));

         Bounds.Max_Session_Bytes := 1024 * 1024 * 1024;
         L.Open (Loose, Rig.Ready, Session_Bounds => Bounds,
                 Status => Status);
         Assert (E.Is_Ok (Status),
                 "a session inside a generous limit was refused: "
                 & E.Error_Code'Image (Status.Code));
         L.Close (Loose);

         L.Close (Rig.Ready, Status);
         Containers.Close (Rig.Parsed);
      end;

      --  And the command line reaches it. A limit above what the weights
      --  need and below what the session needs has to be refused: before
      --  --memory-limit bounded the session, that run succeeded and the
      --  caller was given a session of whatever size it liked.
      declare
         Path   : constant String := "obj/memory-model.gguf";
         Source : Fixed_Arguments;
         Status : Natural;
         Handle : Ada.Text_IO.File_Type;
      begin
         Tiny_Model.Write (Path, Room => 256);

         Add (Source, "run");
         Add (Source, Path);
         Add (Source, "--prompt");
         Add (Source, "hi");
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Add (Source, "--memory-limit");
         Add (Source, "20000");

         Ada.Text_IO.Create (Handle, Ada.Text_IO.Out_File, "obj/memory.txt");
         Ada.Text_IO.Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
               Ada.Text_IO.Close (Handle);
               raise;
         end;
         Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
         Ada.Text_IO.Close (Handle);

         Assert (Status = E.Exit_Resource,
                 "a limit the session exceeds was accepted; status"
                 & Natural'Image (Status));

         declare
            Said : constant String :=
              Text_Of ("obj/memory.txt");
         begin
            Assert (Project_Tools.Text.Contains (Said, "kv_cache"),
                    "the refusal did not name the category: " & Said);
         end;
      end;
   end Session_Memory_Is_Counted;

   ----------------------------------------
   -- Device_Memory_Reaches_The_Device --
   ----------------------------------------

   --  `--device-memory` decides where the weights are, and says so.
   --
   --  The option had no test at all. What it does is not a speed control and
   --  never was, which is the opposite of what it was written expecting: it
   --  says how much of the device's own memory the weights may take, and
   --  naming zero means none of it -- the device is handed a pointer into
   --  this process's memory instead of a copy. The README publishes what the
   --  three ways cost, and nothing held the option to doing any of them.
   --
   --  Read back from the statistics rather than from a timing, because the
   --  statistics are the part that is a fact: how many matrices are on the
   --  device, how many are read where they lie, and how many have been given
   --  back to make room. A timing would be a measurement, and a suite is not
   --  where measurements belong.
   --
   --  Three runs, and each is a different one of the three:
   --
   --    no option        every matrix copied to the device, nothing borrowed
   --    a small budget   a few copied and the rest given back and copied
   --                     again as they are wanted
   --    zero             nothing copied, the weights read where they lie
   procedure Device_Memory_Reaches_The_Device
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Path : constant String := "obj/device-memory-model.gguf";

      --  What the run that copies everything put on the device, for the run
      --  that copies nothing to be held against.
      Copied : Integer := 0;

      --  What one run said about the device, as the fields it printed.
      function Ran_With (Budget : String) return String is
         Source : Fixed_Arguments;
         Status : Natural;
         Handle : Ada.Text_IO.File_Type;
      begin
         Add (Source, "run");
         Add (Source, Path);
         Add (Source, "--backend");
         Add (Source, "device");
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "hi");
         Add (Source, "--max-tokens");
         Add (Source, "2");
         Add (Source, "--show-stats");

         --  The mapping asked for by name rather than left to the default,
         --  because it decides the answer: reading the weights where they
         --  lie needs a page-aligned range, which a mapped file is and a
         --  heap copy of one is not. With --no-mmap the same command reads
         --  nothing where it lies and copies all of it, which is correct
         --  and is not what this is about.
         Add (Source, "--mmap");

         --  Greedy, and from a seed, because this test is about what
         --  the device does with its memory and not about what the
         --  model says.
         --
         --  Without them the sampler is random, and about one run in
         --  fourteen drew the end-of-sequence token first: generation
         --  stopped before it began, the run did too little work to
         --  give any matrix back, and the assertion below failed on a
         --  binary that was correct. It passed again on the next run,
         --  twice, and a gate that is re-run until it passes is not a
         --  gate. This fixture's weights are random, so which token
         --  that was is arbitrary; greedy makes it the same one every
         --  time.
         Add (Source, "--seed");
         Add (Source, "1");
         Add (Source, "--temperature");
         Add (Source, "0");

         if Budget /= "" then
            Add (Source, "--device-memory");
            Add (Source, Budget);
         end if;

         Ada.Text_IO.Create
           (Handle, Ada.Text_IO.Out_File, "obj/device-memory.txt");
         Ada.Text_IO.Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
               Ada.Text_IO.Close (Handle);
               raise;
         end;
         Ada.Text_IO.Set_Error (Ada.Text_IO.Standard_Error);
         Ada.Text_IO.Close (Handle);

         return Text_Of ("obj/device-memory.txt");
      end Ran_With;

      --  The number a statistics line carries, or minus one when the line
      --  is not there at all -- which is the answer on a machine with no
      --  device, and is why every assertion below is guarded.
      function Number_After (Said, Label : String) return Integer is
         At_Label : constant Natural :=
           Ada.Strings.Fixed.Index (Said, Label);
         Stop     : Natural;
      begin
         if At_Label = 0 then
            return -1;
         end if;

         Stop := At_Label + Label'Length;
         while Stop <= Said'Last and then Said (Stop) = ' ' loop
            Stop := Stop + 1;
         end loop;

         declare
            From : constant Natural := Stop;
         begin
            while Stop <= Said'Last
              and then Said (Stop) in '0' .. '9'
            loop
               Stop := Stop + 1;
            end loop;
            if Stop = From then
               return -1;
            end if;
            return Integer'Value (Said (From .. Stop - 1));
         end;
      end Number_After;
   begin
      --  A k-quant fixture rather than the narrow binary32 one, because
      --  this test asks where the weights are read from and that question
      --  needs weights worth reading. The narrow fixture is seven kilobytes
      --  -- under two pages -- and a device is handed page-aligned ranges,
      --  so which of its matrices could be read where they lie depended on
      --  where the mapping landed, and the answer moved between runs of the
      --  same binary. The k-quant fixture is written at the deep widths and
      --  is half a megabyte, which is a hundred pages and settles it.
      Tiny_Model.Write (Path, Format => Tiny_Model.Q4_K);

      declare
         Whole : constant String := Ran_With ("");
         Held  : constant Integer :=
           Number_After (Whole, "matrices on the device");
      begin
         Copied := Number_After (Whole, "bytes on the device");

         if Held < 0 then
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               "note: no device took a model here");
            return;
         end if;

         Assert (Held > 0,
                 "a run with no budget named put no matrix on the device");
         Assert (Number_After (Whole, "read where they lie") = 0,
                 "a run with no budget named borrowed the host's memory");
         Assert (Number_After (Whole, "matrices given back") = 0,
                 "a run with room for the model gave a matrix back");
      end;

      declare
         --  Enough for a matrix or two of this fixture and not for all of
         --  them, so that the run has to give one back and fetch it again.
         Tight : constant String := Ran_With ("4K");
      begin
         --  That the run did the work the assertion below reads.
         --  Asserted rather than assumed, because assuming it is
         --  what made this test intermittent: a run that generates
         --  nothing gives nothing back, and said so in a field
         --  nothing was reading.
         Assert (Number_After (Tight, "generated tokens") = 2,
                 "the run did not generate the two tokens it was "
                 & "asked for, so what it says about giving matrices "
                 & "back is about a shorter run than this test "
                 & "means to measure");

         Assert (Number_After (Tight, "matrices given back") > 0,
                 "a budget smaller than the model gave nothing back, so "
                 & "either the budget did not reach the device or the "
                 & "model fitted after all");
         Assert (Number_After (Tight, "read where they lie") = 0,
                 "a small budget borrowed the host's memory, which is what "
                 & "zero means and not what a small number means");
      end;

      --  And the wait bound reaches the device too, which is the other
      --  half of what a caller can say about one. A minute is a guess about
      --  hardware, and the caller with different hardware is the one who
      --  has to be able to correct it.
      declare
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Path);
         Add (Source, "--backend");
         Add (Source, "device");
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "hi");
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Add (Source, "--device-patience");
         Add (Source, "120");
         Ran (Source, Status);
         Assert (Status = 0,
                 "a run naming a longer wait was refused; status"
                 & Natural'Image (Status));
      end;

      declare
         Refused : Fixed_Arguments;
         Status  : Natural;
      begin
         --  Zero is a device given up on before it began. The engine can be
         --  told to do that and a test does; a command line cannot, because
         --  nobody wants it and a caller who typed it meant something else.
         Add (Refused, "run");
         Add (Refused, Path);
         Add (Refused, "--backend");
         Add (Refused, "device");
         Add (Refused, "--prompt");
         Add (Refused, "hi");
         Add (Refused, "--device-patience");
         Add (Refused, "0");
         Ran (Refused, Status);
         Assert (Status = E.Exit_Usage,
                 "a wait of no seconds was accepted; status"
                 & Natural'Image (Status));
      end;

      declare
         None : constant String := Ran_With ("0");
      begin
         Assert (Number_After (None, "read where they lie") > 0,
                 "--device-memory 0 copied the weights instead of reading "
                 & "them where they lie");
         Assert (Number_After (None, "matrices given back") = 0,
                 "a run told to copy nothing gave a matrix back");
         Assert (Number_After (None, "bytes on the device") < Copied,
                 "a run reading the weights where they lie copied as many "
                 & "bytes as one copying all of them");
      end;
   end Device_Memory_Reaches_The_Device;

   --  A session reports the phase it is in.
   --
   --  Three of seven states were entered by nothing. Two of them --
   --  Completed and Cancelled -- could not have been entered correctly
   --  either: they describe what became of a request, which the result
   --  records, while the session that ran it is ready for the next one.
   --  Those two are gone. The third, Evaluating_Prompt, is a real phase
   --  that only the caller running the request could know about.
   procedure Session_Reports_Its_Phase
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type L.Session_State;
      use type Model_Runner.Progress.Event_Kind;

      --  An observer that reads the session's state at each stage, which is
      --  the only moment a phase is visible from outside.
      type Watcher (Owner : access L.Session) is limited
        new Model_Runner.Progress.Observer with record
         At_Prefill : L.Session_State := L.Closed;
         At_Decode  : L.Session_State := L.Closed;
      end record;

      overriding procedure Notify
        (Self : in out Watcher; Item : Model_Runner.Progress.Event);

      overriding procedure Notify
        (Self : in out Watcher; Item : Model_Runner.Progress.Event) is
      begin
         if Item.Kind = Model_Runner.Progress.Generation_Event then
            case Item.Generation is
               when Model_Runner.Progress.Prefill_Progress =>
                  Self.At_Prefill := L.State (Self.Owner.all);
               when Model_Runner.Progress.Token_Produced =>
                  Self.At_Decode := L.State (Self.Owner.all);
               when others =>
                  null;
            end case;
         end if;
      end Notify;

      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build (Image, Room => 256);

      declare
         Held    : aliased constant B.Byte_Array := Image.all;
         Under   : Harness (Held'Access);
         Session : aliased L.Session;
         Stop    : Model_Runner.Stops.Set;
         Sink    : aliased Capture_Sink;
         Request : Gen.Request;
         Outcome : Gen.Result;
         Status  : E.Error_Info;
      begin
         Start (Under);
         L.Open (Session, Under.Ready, Status => Status);
         Assert (E.Is_Ok (Status), "the session did not open");
         Model_Runner.Stops.Open (Stop);

         Assert (L.State (Session) = L.Ready,
                 "a fresh session is not ready");

         declare
            Seen : aliased Watcher (Session'Access);
         begin
            Request.Max_Tokens := 2;
            Request.Batch_Size := 4;
            Gen.Generate
              (Under.Ready, Session, "hello there", Request, Stop, null,
               Sink'Unchecked_Access, Seen'Unchecked_Access, null, null, null,
               Outcome => Outcome);

            Assert (E.Is_Ok (Outcome.Error),
                    "the request failed: "
                    & E.Error_Code'Image (Outcome.Error.Code));

            Assert (Seen.At_Prefill = L.Evaluating_Prompt,
                    "a session reading a prompt reported "
                    & L.Session_State'Image (Seen.At_Prefill));
            Assert (Seen.At_Decode = L.Generating,
                    "a session writing a reply reported "
                    & L.Session_State'Image (Seen.At_Decode));

            Gen.Release (Outcome);
         end;

         --  And afterwards it is ready again, because what became of the
         --  request is in the result and the session may be used for the
         --  next one.
         Assert (L.State (Session) = L.Ready,
                 "a session that finished a request reported "
                 & L.Session_State'Image (L.State (Session)));

         Model_Runner.Stops.Close (Stop);
         L.Close (Session);
         Assert (L.State (Session) = L.Closed,
                 "a closed session does not say so");

         L.Close (Under.Ready, Status);
         Containers.Close (Under.Parsed);
      end;
   end Session_Reports_Its_Phase;

   --  A model file replaced between validation and reading is refused.
   --
   --  The container is parsed, the shapes are checked, and only then are the
   --  tensors read. A file replaced in between -- a download finishing over
   --  it, a build writing a new quantization to the same path -- would be
   --  read as though it were the file that was checked.
   --
   --  Size_Changed was written for this and its own documentation said it
   --  was used before the tensor-loading stage. It was called by nothing,
   --  and GGUF_File_Changed sat on the list of diagnostics this program
   --  declares and never produces.
   procedure Replaced_File_Is_Refused
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Files renames Model_Runner.Byte_Sources.Files;
      use Ada.Streams;

      Path : constant String := "obj/replaced-model.gguf";

      --  Append Extra bytes to the file, which is the cheapest change that
      --  is visible without reading it.
      --
      --  Written through a second copy and renamed over the first, because
      --  Stream_IO refuses to reopen a file this process already has open
      --  and the whole point is that the source stays open across it. That
      --  is also what actually happens in the field: a download or a build
      --  writes beside the file and moves it into place.
      --  Whether this host let the file be replaced while it was open.
      Replaceable : Boolean := False;

      procedure Grow (Extra : Positive) is
         From, Into : Stream_IO.File_Type;
         Block      : Stream_Element_Array (1 .. 65_536);
         Last       : Stream_Element_Offset;
         Padding    : constant Stream_Element_Array
           (1 .. Stream_Element_Offset (Extra)) := [others => 0];
      begin
         Stream_IO.Open (From, Stream_IO.In_File, Path & ".seed");
         Stream_IO.Create (Into, Stream_IO.Out_File, Path & ".next");
         loop
            Stream_IO.Read (From, Block, Last);
            exit when Last < Block'First;
            Stream_IO.Write (Into, Block (1 .. Last));
         end loop;
         Stream_IO.Write (Into, Padding);
         Stream_IO.Close (Into);
         Stream_IO.Close (From);

         --  Replacing a file this process still has open is a POSIX
         --  arrangement: the name is unlinked and the open handle keeps the
         --  bytes. Windows refuses to delete an open file at all, so the
         --  case this test is about cannot be staged there, and saying so is
         --  better than staging something else and calling it the same.
         --  What is checked on both hosts is the half above -- an untouched
         --  file reports no change.
         begin
            Ada.Directories.Delete_File (Path);
            Ada.Directories.Rename (Path & ".next", Path);
            Replaceable := True;
         exception
            when Ada.Directories.Use_Error =>
               Replaceable := False;
         end;
      end Grow;
   begin
      Tiny_Model.Write (Path, Room => 256);
      Tiny_Model.Write (Path & ".seed", Room => 256);

      --  Unchanged, it prepares.
      declare
         Source : Files.File_Source;
         Parsed : Containers.Container;
         Ready  : L.Model;
         Status : E.Error_Info;
      begin
         Files.Open (Source, Path, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not open");
         Assert (not Source.Changed, "an untouched file reported a change");

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse");

         L.Prepare (Ready, Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status),
                 "an untouched file was refused: "
                 & E.Error_Code'Image (Status.Code));

         L.Close (Ready, Status);
         Containers.Close (Parsed);
         Files.Close (Source);
      end;

      --  Replaced after validation, it is not.
      declare
         Source : Files.File_Source;
         Parsed : Containers.Container;
         Ready  : L.Model;
         Status : E.Error_Info;
      begin
         Files.Open (Source, Path, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not reopen");

         Containers.Reader.Parse (Parsed, Source, Status => Status);
         Assert (E.Is_Ok (Status), "the fixture did not parse again");

         --  Between the checking and the reading, which is the whole window
         --  this guards.
         Grow (4096);

         if Replaceable then
            Assert (Source.Changed, "a grown file reported no change");

            L.Prepare (Ready, Parsed, Source, Status => Status);
            Assert (Status.Code = E.GGUF_File_Changed,
                    "a file replaced after validation was read anyway: "
                    & E.Error_Code'Image (Status.Code));

            L.Close (Ready, Status);
         end if;
         Containers.Close (Parsed);
         Files.Close (Source);
      end;
   end Replaced_File_Is_Refused;

   --  Public operations the program does not itself call.
   --
   --  This is a library as well as a command, so its interface is wider than
   --  the command uses. That is allowed; being untested is not. Every
   --  operation here had no caller anywhere, which meant no test either --
   --  and one of them, Size_Changed, turned out to be a guard a documented
   --  safety claim rested on.
   --
   --  So they are exercised, each for what it is for, and the release
   --  checklist fails when a public operation has no caller at all.
   procedure Unused_Interface_Is_Exercised
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type B.Byte_Array;
      use type Model_Runner.Tokenizer.Token_Id;

      Image : B.Byte_Array_Access;
   begin
      --  Bytes: clearing a buffer, and reading a half-precision value.
      declare
         Room : B.Byte_Array (1 .. 4) := [1, 2, 3, 4];
      begin
         B.Wipe (Room);
         Assert (Room = B.Byte_Array'(1 .. 4 => 0),
                 "a wiped buffer kept its contents");
      end;

      declare
         --  Half-precision one: sign 0, exponent 15, mantissa 0.
         Room : constant B.Byte_Array (1 .. 2) := [16#00#, 16#3C#];
         Ok   : Boolean;
         Bits : constant Model_Runner.Numerics.Half :=
           B.Get_F16 (Room, 0, Ok);
      begin
         Assert (Ok and then Model_Runner.Numerics.To_Real (Bits) = 1.0,
                 "half-precision one did not read as one");
      end;

      --  Numerics: the test that distinguishes a value from itself.
      --  With the validity check suppressed, because it fires on the read
      --  and would decide the value is unacceptable before Is_NaN is asked.
      --  The engine suppresses it in the same way where it inspects logits.
      declare
         pragma Suppress (Validity_Check);
         Held : Model_Runner.Numerics.Real_Array (1 .. 2) := [others => 1.0];
      begin
         Held (1) := Model_Runner.Numerics.From_Bits (16#7FC0_0000#);
         Assert (Model_Runner.Numerics.Is_NaN (Held (1)),
                 "a quiet NaN was not recognized");
         Assert (not Model_Runner.Numerics.Is_NaN (Held (2)),
                 "one was called a NaN");
      end;

      --  Text: comparison that ignores case, for protocol tokens.
      Assert (Model_Runner.Text.Equal_Ignore_Case ("GPT2", "gpt2"),
              "case-insensitive comparison rejected a match");
      Assert (not Model_Runner.Text.Equal_Ignore_Case ("gpt2", "gpt3"),
              "case-insensitive comparison accepted a mismatch");

      --  Errors: a boolean parameter, a cause, and looking one up again.
      declare
         Condition : E.Error_Info := E.Make (E.CLI_Invalid_Option_Value);
      begin
         E.Add_Boolean (Condition, "mapped", True);

         declare
            Found : Boolean;
            Held  : E.Parameter;
         begin
            E.Find_Parameter (Condition, "mapped", Found, Held);
            Assert (Found, "a boolean parameter could not be found again");
            E.Find_Parameter (Condition, "absent", Found, Held);
            Assert (not Found, "a parameter nobody added was found");
         end;

         E.Set_Cause (Condition, E.IO_Open_Failed);
         Assert (Condition.Cause = E.IO_Open_Failed,
                 "a cause was not recorded");
      end;

      --  Stops: how many of each kind a set holds.
      declare
         Set     : Model_Runner.Stops.Set;
         Outcome : E.Error_Info;
      begin
         Model_Runner.Stops.Open (Set);
         Assert (Model_Runner.Stops.String_Count (Set) = 0
                 and then Model_Runner.Stops.Token_Count (Set) = 0,
                 "a fresh stop set holds something");

         Model_Runner.Stops.Add_String (Set, "END", Outcome);
         Model_Runner.Stops.Add_Token (Set, 7, Outcome);
         Assert (Model_Runner.Stops.String_Count (Set) = 1,
                 "a stop string was not counted");
         Assert (Model_Runner.Stops.Token_Count (Set) = 1,
                 "a stop token was not counted");
         Model_Runner.Stops.Close (Set);
      end;

      --  Output: a sink reporting whether it has closed.
      declare
         Sink : aliased Capture_Sink;
      begin
         Assert (not Model_Runner.Output.Sink'Class (Sink).Is_Closed,
                 "a fresh sink says it is closed");
      end;

      --  Sampling: the seed a sampler actually used, which matters when the
      --  caller asked for one to be chosen.
      declare
         Sampler : Model_Runner.Sampling.Sampler;
         Status  : E.Error_Info;
      begin
         Model_Runner.Sampling.Open
           (Sampler, Model_Runner.Sampling.Greedy_Configuration, 8, 4242,
            Status);
         Assert (E.Is_Ok (Status), "the sampler did not open");
         Assert (Model_Runner.Sampling.Seed_Used (Sampler) = 4242,
                 "a sampler did not report the seed it was given");
         Model_Runner.Sampling.Close (Sampler);
      end;

      --  Tokenizer and model: facts about a vocabulary that this program
      --  does not need and a caller might.
      Tiny_Model.Build (Image, Room => 256);

      declare
         Held   : aliased constant B.Byte_Array := Image.all;
         Under  : Harness (Held'Access);
         Words  : access constant Model_Runner.Tokenizer.Vocabulary;
         Status : E.Error_Info;
      begin
         Start (Under);
         Words := L.Vocabulary (Under.Ready);

         --  add_eos_token is read from the file and kept. Nothing in a
         --  generation run honours it, and that is right: appending an end
         --  token to a prompt tells the model the text is over.
         Assert (Model_Runner.Tokenizer.Adds_End (Words.all)
                 = Model_Runner.Tokenizer.Adds_End (Words.all),
                 "the end-token policy is not stable");
         Assert (Model_Runner.Tokenizer.Unknown_Token (Words.all)
                 /= Model_Runner.Tokenizer.No_Token,
                 "the fixture has no unknown token");

         Assert (L.Has_Template (Under.Ready),
                 "the fixture's template was not recorded");

         L.Close (Under.Ready, Status);
         Containers.Close (Under.Parsed);
      end;
   end Unused_Interface_Is_Exercised;

   --  Each architecture is read with its own keys and its own rotation.
   --
   --  Qwen2 is Llama with a bias on the attention projections and the other
   --  rotary pairing. The pairing is the part that goes wrong quietly: with
   --  the wrong one a model writes grammatical sentences that mean nothing
   --  it meant, and only a real model shows that. Here the mapping itself
   --  is pinned, which is the line that would have to change for it to
   --  happen again.
   procedure Architectures_Are_Read_By_Name
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type Model_Runner.Kernels.Rotary_Pairing;
      use type L.Architecture;

      --  A container carrying the metadata a profile needs, under the keys
      --  the named architecture spells them with.
      procedure Configured
        (Named    : String;
         Settings : out L.Configuration;
         Status   : out E.Error_Info)
      is
         Builder : Fixtures.Builder;
         Image   : B.Byte_Array_Access;
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", Named);
         Fixtures.Add_U32 (Builder, Named & ".context_length", 16);
         Fixtures.Add_U32 (Builder, Named & ".embedding_length", 8);
         Fixtures.Add_U32 (Builder, Named & ".block_count", 1);
         Fixtures.Add_U32 (Builder, Named & ".feed_forward_length", 16);
         Fixtures.Add_U32 (Builder, Named & ".attention.head_count", 2);
         Fixtures.Add_U32 (Builder, Named & ".attention.head_count_kv", 2);
         Fixtures.Add_F32
           (Builder, Named & ".attention.layer_norm_rms_epsilon", 1.0e-5);
         Fixtures.Build (Builder, Image);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Status);
            if E.Is_Ok (Status) then
               L.Read_Config (Parsed, Settings => Settings, Status => Status);
            end if;
            Containers.Close (Parsed);
         end;
      end Configured;

      Settings : L.Configuration;
      Status   : E.Error_Info;
   begin
      --  Every architecture this build reads is read.
      for Kind in L.Architecture loop
         Configured (L.Architecture_Name (Kind), Settings, Status);
         Assert (E.Is_Ok (Status),
                 "the architecture " & L.Architecture_Name (Kind)
                 & " was refused: " & E.Error_Code'Image (Status.Code));
         Assert (Settings.Kind = Kind,
                 "a file saying " & L.Architecture_Name (Kind)
                 & " was read as something else");

         --  Its keys were found under its own name, which is the whole
         --  reason the prefix is not a constant any more.
         Assert (Settings.Embedding = 8 and then Settings.Layers = 1,
                 "the metadata of " & L.Architecture_Name (Kind)
                 & " was not read under its own keys");
      end loop;

      --  And the rotation each one asks for.
      Configured ("llama", Settings, Status);
      Assert (Settings.Pairing = Model_Runner.Kernels.Interleaved,
              "llama did not ask for the interleaved rotation");

      Configured ("qwen2", Settings, Status);
      Assert (Settings.Pairing = Model_Runner.Kernels.Split,
              "qwen2 did not ask for the split rotation");

      --  A file naming something else is refused by name. The example is a
      --  real architecture rather than a nonsense word, so that what is
      --  tested is the refusal to read an architecture this build does not
      --  implement rather than the refusal to read a typo -- and it had to
      --  be changed once, when gemma stopped being one of those.
      Configured ("mamba", Settings, Status);
      Assert (Status.Code = E.Arch_Unsupported,
              "an architecture this build does not read was accepted: "
              & E.Error_Code'Image (Status.Code));

      --  And a whole qwen2 file prepares and runs: its biases are required
      --  and found, its keys are read, and it generates the same text at
      --  every batch size, which is what a bias applied in one path and not
      --  the other would break.
      declare
         Image : B.Byte_Array_Access;
      begin
         Tiny_Model.Build (Image, Room => 64, Kind => Tiny_Model.Qwen2);

         declare
            Held    : aliased constant B.Byte_Array := Image.all;
            Under   : Harness (Held'Access);
            Session : L.Session;
            Stop    : Model_Runner.Stops.Set;
            Sink    : aliased Capture_Sink;
            Request : Gen.Request;
            Outcome : Gen.Result;
            Local   : E.Error_Info;
            First   : String (1 .. Max_Captured) := [others => ' '];
            Length  : Natural := 0;
         begin
            Start (Under);
            Assert (L.Config (Under.Ready).Kind = L.Qwen2,
                    "the qwen2 fixture was prepared as something else");

            Model_Runner.Stops.Open (Stop);
            Request.Max_Tokens := 3;

            for Batch in 1 .. 3 loop
               L.Open (Session, Under.Ready, Status => Local);
               Assert (E.Is_Ok (Local), "the qwen2 session did not open");

               Sink.Used := 0;
               Request.Batch_Size := (if Batch = 1 then 1 else Batch * 4);
               Gen.Generate
                 (Under.Ready, Session, "hello there you", Request, Stop, null,
                  Sink'Unchecked_Access, null, null, null, null,
                  Outcome => Outcome);
               Assert (E.Is_Ok (Outcome.Error),
                       "a qwen2 run failed: "
                       & E.Error_Code'Image (Outcome.Error.Code));

               if Batch = 1 then
                  Length := Sink.Used;
                  First (1 .. Length) := Sink.Data (1 .. Length);
               else
                  Assert (Sink.Data (1 .. Sink.Used) = First (1 .. Length),
                          "a qwen2 batch produced different text from the "
                          & "same prompt one token at a time");
               end if;

               Gen.Release (Outcome);
               L.Close (Session);
            end loop;

            Model_Runner.Stops.Close (Stop);
            L.Close (Under.Ready, Local);
            Containers.Close (Under.Parsed);
         end;
      end;

      --  A qwen2 file without the biases is refused. They are required
      --  rather than taken if present: reading one as though its biases
      --  were zero would produce plausible text that is not what the model
      --  says, and plausible text is the hardest kind of wrong to notice.
      declare
         Image  : B.Byte_Array_Access;
      begin
         Tiny_Model.Build
           (Image, Room => 64, Kind => Tiny_Model.Qwen2,
            Omit_Biases => True);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Ready  : L.Model;
            Local  : E.Error_Info;
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Local);
            Assert (E.Is_Ok (Local), "the biasless fixture did not parse");

            L.Prepare (Ready, Parsed, Source, Status => Local);
            Assert (Local.Code = E.Arch_Missing_Tensor,
                    "a qwen2 file with no attention biases was prepared: "
                    & E.Error_Code'Image (Local.Code));

            L.Close (Ready, Local);
            Containers.Close (Parsed);
         end;
      end;

      --  And a qwen3 file without the head normalizations, for the same
      --  reason. What each architecture carries beside its projections
      --  differs -- qwen2 a bias, qwen3 a normalization -- and in both cases
      --  it is required by the name the file gives itself.
      declare
         Image  : B.Byte_Array_Access;
      begin
         Tiny_Model.Build
           (Image, Room => 64, Kind => Tiny_Model.Qwen3,
            Omit_Biases => True);

         declare
            Held   : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
              (Held'Access);
            Parsed : Containers.Container;
            Ready  : L.Model;
            Local  : E.Error_Info;
         begin
            Containers.Reader.Parse (Parsed, Source, Status => Local);
            Assert (E.Is_Ok (Local), "the unnormalized fixture did not parse");

            L.Prepare (Ready, Parsed, Source, Status => Local);
            Assert (Local.Code = E.Arch_Missing_Tensor,
                    "a qwen3 file with no head normalizations was prepared: "
                    & E.Error_Code'Image (Local.Code));

            L.Close (Ready, Local);
            Containers.Close (Parsed);
         end;

         B.Free (Image);
      end;
   end Architectures_Are_Read_By_Name;

   --  The two backends produce the same logits.
   --
   --  That is the whole point of the second one. The CPU backend partitions
   --  rows across workers, shares one reading of the weights between the
   --  vectors of a batch, and decodes a span into a buffer so the loops
   --  vectorize; each of those was done for speed and each is a way the
   --  answer could be wrong for a reason that is hard to see. The reference
   --  backend has none of them: a row, decoded whole, multiplied one element
   --  Repacking changes what the weights cost, not what they say.
   --
   --  --repack decodes every matrix once into binary32 and evaluates from
   --  that, instead of decoding a span of it on every pass. The values
   --  written are the ones the decoder produces, in the order the kernels
   --  read them, so the arithmetic that follows is the same arithmetic --
   --  and the logits must agree to the bit, not to a tolerance. A tolerance
   --  here would accept a repacking that quietly rounded, which is the one
   --  thing this must not do.

   procedure Repacking_Changes_No_Logit
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      subtype Logit_Row is
        Model_Runner.Numerics.Real_Array
          (0 .. Model_Runner.Numerics.Element_Count
                  (Tiny_Model.Vocabulary - 1));

      Image   : B.Byte_Array_Access;
      Dropped : E.Error_Info;
   begin
      --  Quantized, because that is where repacking does anything: an F32
      --  file is already what repacking would write.
      Tiny_Model.Build (Image, Format => Tiny_Model.Q8_0, Room => 64);

      declare
         Held : aliased constant B.Byte_Array := Image.all;

         function Logits_With (Repack : L.Repack_Mode) return Logit_Row is
            Under   : Harness (Held'Access);
            Session : L.Session;
            Room    : Logit_Row := [others => 0.0];
            Status  : E.Error_Info;
            Held    : constant Boolean :=
              Model_Runner.Backend.CPU.Integer_Activations;
         begin
            --  Both sides in the floating-point arithmetic, because that is
            --  what makes this an equality. Repacking to binary32 takes a
            --  format with an integer kernel to one without, so at the
            --  default arithmetic the two sides would multiply differently
            --  and the claim being tested -- that repacking moves no logit
            --  -- would be a claim about the arithmetic instead.
            Model_Runner.Backend.CPU.Use_Integer_Activations (False);

            Start (Under, Repack => Repack);

            L.Open (Session, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            L.Evaluate (Session, Under.Ready, 4, Room, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");

            L.Close (Session);
            Model_Runner.Backend.CPU.Use_Integer_Activations (Held);
            return Room;
         end Logits_With;

         Plain    : constant Logit_Row := Logits_With (L.No_Repack);
         Repacked : constant Logit_Row := Logits_With (L.To_F32);
      begin
         for Index in Plain'Range loop
            Assert (Plain (Index) = Repacked (Index),
                    "repacking moved logit"
                    & Model_Runner.Numerics.Element_Count'Image (Index));
         end loop;
      end;

      --  And on the other backend, which reads the repacked matrices by the
      --  same view and must agree with itself for the same reason. The
      --  first version of this test asked only the backend that repacking
      --  was written against.
      declare
         Held : aliased constant B.Byte_Array := Image.all;

         function Reference_Logits (Repack : L.Repack_Mode) return Logit_Row is
            Under   : Harness (Held'Access);
            Session : L.Session;
            Room    : Logit_Row := [others => 0.0];
            Status  : E.Error_Info;
         begin
            Start (Under,
                   Backend => Model_Runner.Backend.Backend_Reference,
                   Repack  => Repack);

            L.Open (Session, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status), "the session did not open");

            L.Evaluate (Session, Under.Ready, 4, Room, Status => Status);
            Assert (E.Is_Ok (Status), "evaluation failed");

            L.Close (Session);
            return Room;
         end Reference_Logits;

         Plain    : constant Logit_Row := Reference_Logits (L.No_Repack);
         Repacked : constant Logit_Row := Reference_Logits (L.To_F32);
      begin
         for Index in Plain'Range loop
            Assert (Plain (Index) = Repacked (Index),
                    "repacking moved logit"
                    & Model_Runner.Numerics.Element_Count'Image (Index)
                    & " on the reference backend");
         end loop;
      end;

      --  And through the whole command, with the mapping turned off. The
      --  copy is decoded from the file's bytes however those bytes arrived,
      --  and --no-mmap is the arrangement where they are read rather than
      --  mapped -- which is also the one where holding them after the copy
      --  was made cost real memory rather than reclaimable pages.
      --
      --  Run as a child process, and that is the whole point of the rewrite.
      --  This used to call the driver in this process with Set_Output aimed
      --  at a file, which cannot work: generated text is written through the
      --  raw stream of Ada.Text_IO.Standard_Output, deliberately, so that
      --  Text_IO cannot touch the bytes -- and Set_Output redirects
      --  Current_Output, which that stream is not. Every run wrote its text
      --  to the terminal and the file caught one newline, so all three
      --  strings were "\n" and the two assertions below compared "\n" with
      --  "\n". The suite printed the generated text on every run and nobody
      --  read it as evidence of anything.
      --
      --  The second run was not even a repacked one: the option arrived as
      --  the single argument "--repack f32", which the command refuses as an
      --  unknown option, and the refusal went to standard error where the
      --  empty capture hid it.
      declare
         Model  : constant String := "obj/repack-model.gguf";
         --  The name the linker gives it, which differs by host. Asking for
         --  the Unix one alone reported the command as not built on
         --  Windows, where the comparison then could not be made.
         Plain  : constant String := "../bin/model_runner";
         Binary : constant String :=
           (if Ada.Directories.Exists (Plain) then Plain
            else Plain & ".exe");

         --  What the command writes on standard output for one run.
         function Text_Of (First, Second : String) return String is
            Args   : Project_Tools.Processes.Argument_Vectors.Vector;
            Status : aliased Integer := 0;

            procedure Add_Word (Word : String) is
            begin
               Project_Tools.Processes.Argument_Vectors.Append
                 (Args, Ada.Strings.Unbounded.To_Unbounded_String (Word));
            end Add_Word;
         begin
            Add_Word ("run");
            Add_Word (Model);
            Add_Word ("--raw");
            Add_Word ("--prompt");
            Add_Word ("ab");
            Add_Word ("--max-tokens");
            Add_Word ("6");
            Add_Word ("--seed");
            Add_Word ("1");
            Add_Word ("--temperature");
            Add_Word ("0");

            --  Two arguments, because that is what a command line is.
            if First /= "" then
               Add_Word (First);
            end if;
            if Second /= "" then
               Add_Word (Second);
            end if;

            declare
               Text : constant String :=
                 Project_Tools.Processes.Command_Output
                   (Command   => Binary,
                    Arguments => Args,
                    Status    => Status'Access);
            begin
               Assert (Status = 0,
                       "the command failed with status"
                       & Integer'Image (Status) & " for '" & First & " "
                       & Second & "'");
               return Text;
            end;
         end Text_Of;
      begin
         Tiny_Model.Write (Model, Room => 64);

         Assert (Ada.Directories.Exists (Binary),
                 "the command is not built at " & Binary & ", so this "
                 & "comparison cannot be made rather than passing on "
                 & "nothing");

         declare
            Plain    : constant String := Text_Of ("", "");
            Repacked : constant String := Text_Of ("--repack", "f32");
            Unmapped : constant String := Text_Of ("--no-mmap", "");
         begin
            --  There is text, said outright, and text means more than a
            --  line ending. Three equal strings are equal whatever they
            --  hold, and what the old capture caught was a single newline,
            --  so a length test alone would have passed on it too.
            declare
               Real : Natural := 0;
            begin
               for Character_Value of Plain loop
                  if Character_Value not in
                       Character'Val (10) | Character'Val (13) | ' '
                  then
                     Real := Real + 1;
                  end if;
               end loop;

               Assert (Real >= 2,
                       "the command produced" & Natural'Image (Real)
                       & " characters of text, so the comparisons below "
                       & "would hold whatever repacking did");
            end;

            Assert (Plain = Repacked,
                    "repacking changed the text: '" & Plain & "' against '"
                    & Repacked & "'");
            Assert (Plain = Unmapped,
                    "reading rather than mapping changed the text: '" & Plain
                    & "' against '" & Unmapped & "'");
         end;
      end;

      --  And the account says the file's bytes were given back once the
      --  copy held them.
      --
      --  What this can hold is the bookkeeping, not the deallocation: an
      --  account that recorded a release the code never performed would
      --  pass. Removing the free and leaving the record does pass, and was
      --  tried. The deallocation itself was checked from outside, by peak
      --  resident memory, and it does not move the peak -- both copies
      --  exist while the second is being written, which is what inspect
      --  reports as the peak with --repack. What it lowers is what the
      --  model holds afterwards, by the size of the file.
      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
         Books : Model_Runner.Memory.Account;
      begin
         Start (Under, Repack => L.To_F32);
         Books := L.Accounting (Under.Ready);

         Assert (Books.By_Category (Model_Runner.Memory.Converted_Weights) > 0,
                 "repacking recorded no converted weights");
         Assert (Books.Released > 0,
                 "repacking released nothing; the file's own bytes are still "
                 & "held beside the copy");
      end;

      B.Free (Image);
      pragma Unreferenced (Dropped);
   end Repacking_Changes_No_Logit;

   --  at a time, summed wide, on the calling task.
   --
   --  So a caller with a file that produces suspicious text can ask again
   --  with --backend reference and find out whether the fast path was the
   --  reason. This says the two answers are the same on a fixture; the
   --  conformance run says the fast path agrees with a third implementation
   --  written from the architecture description.
   procedure Backends_Agree
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Back renames Model_Runner.Backend;
      subtype Logit_Row is
        Model_Runner.Numerics.Real_Array
          (0 .. Model_Runner.Numerics.Element_Count
                  (Tiny_Model.Vocabulary - 1));

      Image   : B.Byte_Array_Access;
      Dropped : E.Error_Info;
   begin
      Tiny_Model.Build (Image, Room => 64);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);

         --  Logits for the same token, from each backend.
         function Logits_From (Kind : Back.Backend_Kind) return Logit_Row is
            Session : L.Session;
            Room    : Logit_Row := [others => 0.0];
            Status  : E.Error_Info;
         begin
            L.Open (Session, Under.Ready, Status => Status);
            Assert (E.Is_Ok (Status),
                    "the session did not open for "
                    & Back.Backend_Name (Kind));

            L.Evaluate (Session, Under.Ready, 4, Room, Status => Status);
            Assert (E.Is_Ok (Status),
                    "evaluation failed on " & Back.Backend_Name (Kind)
                    & ": " & E.Error_Code'Image (Status.Code));

            L.Close (Session);
            return Room;
         end Logits_From;
      begin
         Start (Under, Back.Backend_CPU);

         declare
            Fast : constant Logit_Row := Logits_From (Back.Backend_CPU);
            Slow : Logit_Row;
            Apart : Model_Runner.Numerics.Real := 0.0;
         begin
            L.Close (Under.Ready, Dropped);
            Start (Under, Back.Backend_Reference);
            Slow := Logits_From (Back.Backend_Reference);

            for Index in Fast'Range loop
               Apart := Model_Runner.Numerics.Real'Max
                 (Apart, abs (Fast (Index) - Slow (Index)));
            end loop;

            --  Exactly, not nearly. Both sum in the wide format over the same
            --  values in the same order; a difference would mean one of them
            --  is not doing what it says.
            Assert (Apart = 0.0,
                    "the two backends disagree by"
                    & Model_Runner.Numerics.Real'Image (Apart));
         end;

         L.Close (Under.Ready, Dropped);
         Containers.Close (Under.Parsed);
      end;
   end Backends_Agree;

   --  The statistics report the run they describe.
   --
   --  What was held was that the block has fields: the labels appear, more
   --  than five line up, no placeholder is left unsubstituted. The figures
   --  are the whole point of the block and none of them was compared with
   --  anything. A build reporting a constant, or the prompt count where the
   --  generated count belongs, would have passed.
   --
   --  The seed matters most: it is what a reader writes down to reproduce a
   --  run, so a seed that is reported as anything other than the one used is
   --  worse than no seed at all.
   procedure Statistics_Report_The_Run_They_Describe
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model : constant String := "obj/stats-model.gguf";
      Log   : constant String := "obj/stats-errors.txt";

      --  The number on the line carrying a label, or -1.
      function Figure (Text, Label : String) return Integer is
      begin
         for Index in Text'First .. Text'Last - Label'Length + 1 loop
            if Text (Index .. Index + Label'Length - 1) = Label then
               declare
                  Stop  : Natural := Index + Label'Length;
                  Value : Integer := -1;
               begin
                  while Stop <= Text'Last
                    and then Text (Stop) /= Character'Val (10)
                  loop
                     if Text (Stop) in '0' .. '9' then
                        if Value < 0 then
                           Value := 0;
                        end if;
                        Value := Value * 10
                          + (Character'Pos (Text (Stop))
                             - Character'Pos ('0'));
                     elsif Value >= 0 then
                        exit;
                     end if;
                     Stop := Stop + 1;
                  end loop;

                  return Value;
               end;
            end if;
         end loop;

         return -1;
      end Figure;

      --  Run with statistics and return what reached standard error.
      function Reported (Tokens, Seed : String) return String is
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, Tokens);
         Add (Source, "--seed");
         Add (Source, Seed);
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, "--show-stats");

         Create (Handle, Out_File, Log);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status = 0,
                 "a run reporting statistics failed with status"
                 & Natural'Image (Status));
         return Text_Of (Log);
      end Reported;
   begin
      Tiny_Model.Write (Model, Room => 64);

      declare
         Said : constant String := Reported ("4", "12345");

         Prompt    : constant Integer := Figure (Said, "prompt tokens");
         Generated : constant Integer := Figure (Said, "generated tokens");
         Position  : constant Integer := Figure (Said, "context position");
         Seed      : constant Integer := Figure (Said, "seed");
      begin
         Assert (Seed = 12345,
                 "the statistics reported seed" & Integer'Image (Seed)
                 & " where 12345 was asked for, so a reader writing it down "
                 & "cannot reproduce the run");

         Assert (Generated in 1 .. 4,
                 "the statistics reported" & Integer'Image (Generated)
                 & " generated tokens for a run bounded at four");

         Assert (Prompt > 0,
                 "the statistics reported" & Integer'Image (Prompt)
                 & " prompt tokens for a prompt that has some");

         Assert (Position = Prompt + Generated,
                 "the context position" & Integer'Image (Position)
                 & " is not the prompt" & Integer'Image (Prompt)
                 & " plus what was generated" & Integer'Image (Generated));
      end;

      --  A second run, bounded lower, has to report the lower bound: the
      --  figures move with the run rather than being a constant that
      --  happened to match.
      declare
         Said : constant String := Reported ("1", "999");

         Generated : constant Integer := Figure (Said, "generated tokens");
         Seed      : constant Integer := Figure (Said, "seed");
      begin
         Assert (Seed = 999,
                 "the seed did not follow what was asked for the second "
                 & "time:" & Integer'Image (Seed));
         Assert (Generated = 1,
                 "a run bounded at one token reported"
                 & Integer'Image (Generated));
      end;
   end Statistics_Report_The_Run_They_Describe;

   --  The exit statuses the help promises, produced.
   --
   --  The last line of `model_runner help` names eight, and they are a
   --  promise to whoever scripts around this program: a corrupt file and a
   --  model this build cannot run are told apart by that number and by
   --  nothing else. Counting what any test observed found five of the eight
   --  -- 4, 7 and 8 were named nowhere in the suite.
   --
   --  Asking for 7 found that it was not produced at all. A run the reader
   --  interrupts ends with Cancelled, which is not Runtime_Error, so the
   --  command fell through to success and told a script the generation had
   --  finished normally. That is fixed; what is checked here is the status
   --  the fix goes through, because driving the signal itself through the
   --  command cannot be made safe: the handler is installed for the run and
   --  removed after it, and a signal that arrives in between kills this
   --  process rather than failing a test.
   --
   --  8 is not produced on purpose by anything. It is what an invariant
   --  violation comes out as, and a test that reached it would be a test
   --  that had already found a defect; Unreached_Codes says the same of the
   --  codes behind it.
   procedure Promised_Exit_Statuses_Are_Produced
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Log : constant String := "obj/statuses-errors.txt";

      --  Run a command line and report its status and diagnostics.
      procedure Ran_Saying
        (Words  : in out Fixed_Arguments;
         Status : out Natural;
         Said   : out Boolean)
      is
         Handle : File_Type;
      begin
         Create (Handle, Out_File, Log);
         Set_Error (Handle);
         begin
            Ran (Words, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);
         Said := Text_Of (Log)'Length > 0;
      end Ran_Saying;

      Status : Natural;
      Spoke  : Boolean;
   begin
      --  Four: a model this build will not run, as opposed to one it cannot
      --  read. A reader whose script sees three knows the file is broken;
      --  one that sees four knows the file is sound and this program is not
      --  the one to run it, and nothing else in the output distinguishes
      --  them for a machine.
      declare
         Model   : constant String := "obj/statuses-unsupported.gguf";
         Builder : Fixtures.Builder;
         Image   : B.Byte_Array_Access;
         Handle  : Ada.Streams.Stream_IO.File_Type;
         Source  : Fixed_Arguments;
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "mamba");
         Fixtures.Build (Builder, Image);

         Ada.Streams.Stream_IO.Create
           (Handle, Ada.Streams.Stream_IO.Out_File, Model);

         declare
            use Ada.Streams;

            Block  : Stream_Element_Array
              (1 .. Stream_Element_Offset (Image.all'Length));
            Target : Stream_Element_Offset := 0;
         begin
            for Value of Image.all loop
               Target := Target + 1;
               Block (Target) := Stream_Element (Value);
            end loop;
            Stream_IO.Write (Handle, Block);
         end;

         Ada.Streams.Stream_IO.Close (Handle);
         B.Free (Image);

         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--prompt");
         Add (Source, "hi");
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Ran_Saying (Source, Status, Spoke);

         Assert (Status = 4,
                 "a model this build does not implement left with status"
                 & Natural'Image (Status) & " rather than four: "
                 & Text_Of (Log));
         Assert (Spoke, "an unsupported model was refused in silence");

         --  And an inspection of the same file, which used to print that
         --  error and leave with a success -- telling a script the file was
         --  fine. The report is still printed; the status no longer
         --  pretends nothing was wrong.
         declare
            Looking : Fixed_Arguments;
         begin
            Add (Looking, "inspect");
            Add (Looking, Model);
            Ran_Saying (Looking, Status, Spoke);

            Assert (Status = 4,
                    "inspecting a model this build does not implement left "
                    & "with status" & Natural'Image (Status));
            Assert (Project_Tools.Text.Contains (Last_Output, "file size"),
                    "the inspection stopped reporting at the first refusal");
         end;

         --  And --validate, whose whole output is a verdict, used to call
         --  such a file valid.
         declare
            Judging : Fixed_Arguments;
         begin
            Add (Judging, "inspect");
            Add (Judging, Model);
            Add (Judging, "--validate");
            Ran_Saying (Judging, Status, Spoke);

            Assert (Status = 4,
                    "--validate called a model this build cannot run valid,"
                    & " leaving with status" & Natural'Image (Status));
         end;

         Ada.Directories.Delete_File (Model);
      end;

      --  Seven, through the path the command now takes for it. The status
      --  is the error table's answer, which is what makes it the same
      --  number the documentation prints.
      Assert (E.Exit_Status (E.Make (E.Generation_Cancelled)) = 7,
              "a cancelled generation does not map to seven, so the command "
              & "that reports it cannot produce the status the help "
              & "promises");
   end Promised_Exit_Statuses_Are_Produced;

   --  A locale this build does not carry is warned about and used anyway.
   --
   --  The program falls back to English and says so. Both halves matter: a
   --  reader who asked for Danish and silently got English has been misled,
   --  and one whose command failed because a locale was missing has been
   --  stopped for no reason. The message existed, the catalog check asserted
   --  it existed in every locale, and nothing had ever made the program say
   --  it.
   procedure Unavailable_Locale_Warns_And_Continues
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Log    : constant String := "obj/locale-errors.txt";
      Source : Fixed_Arguments;
      Handle : File_Type;
      Status : Natural;
   begin
      Add (Source, "--locale");
      Add (Source, "zz");
      Add (Source, "version");

      Create (Handle, Out_File, Log);
      Set_Error (Handle);
      begin
         Ran (Source, Status);
      exception
         when others =>
            Set_Error (Standard_Error);
            Close (Handle);
            raise;
      end;
      Set_Error (Standard_Error);
      Close (Handle);

      Assert (Status = 0,
              "a locale this build does not carry stopped the command:"
              & Natural'Image (Status));

      declare
         Said : constant String := Text_Of (Log);
      begin
         Assert (Project_Tools.Text.Contains (Said, "zz"),
                 "the warning did not name the locale that was asked for: "
                 & Said);
         Assert (Project_Tools.Text.Contains (Said, "unavailable"),
                 "the program did not say the locale was unavailable: "
                 & Said);
      end;

      --  And the answer still came out, in the language it fell back to.
      Assert (Project_Tools.Text.Contains (Last_Output, "model_runner"),
              "the command warned about the locale and then said nothing: "
              & Last_Output);
   end Unavailable_Locale_Warns_And_Continues;

   --  Memory mapping, asked for rather than allowed.
   --
   --  The default policy maps when it can and reads when it cannot, so a
   --  host on which mapping quietly stopped working would behave correctly
   --  and slowly, and nothing here would fail. What would have caught it was
   --  incidental: one line of a README transcript the suite compares.
   --
   --  --mmap exists to turn that silent fallback into an error, and no test
   --  had ever asked it to. The constants it goes through -- O_RDONLY,
   --  PROT_READ, MAP_PRIVATE -- are numbers written into a directory named
   --  posix that Linux and macOS both compile, which is where the same kind
   --  of number was wrong for macOS in the tests crate.
   --
   --  The assertions hold on a host that maps and on one that cannot: what
   --  is asked is that the three policies agree with each other, not that
   --  this host has mapping. That is deliberate and it is also the limit of
   --  this test: with the mapping constants wrong, the default would stop
   --  mapping, --mmap would refuse, and these assertions would still hold,
   --  because they would all agree.
   --
   --  What catches that is the published transcript, which contains the
   --  line "memory mapped           yes" and is compared on every host --
   --  breaking MAP_PRIVATE fails it, which was checked. So this test is
   --  about the policies and that one is about the mapping; neither is the
   --  other, and saying so is better than implying this covers both.
   procedure Mapping_Is_Asked_For_Rather_Than_Allowed
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model : constant String := "obj/mapping-model.gguf";
      Log   : constant String := "obj/mapping-errors.txt";

      --  Inspect and hand back what reached standard output, with the
      --  command's status.
      function Inspected
        (Extra  : String;
         Status : out Natural) return String
      is
         Source : Fixed_Arguments;
         Handle : File_Type;
      begin
         Add (Source, "inspect");
         Add (Source, Model);
         if Extra /= "" then
            Add (Source, Extra);
         end if;

         Create (Handle, Out_File, Log);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         return Last_Output;
      end Inspected;

      --  Run with a mapping policy and report the status.
      function Ran_With (Policy : String) return Natural is
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, Policy);

         Create (Handle, Out_File, Log);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         return Status;
      end Ran_With;

      --  What the report says after "memory mapped".
      function Mapped (Report : String) return Boolean is
         Marker : constant String := "memory mapped";
      begin
         for Index in Report'First .. Report'Last - Marker'Length loop
            if Report (Index .. Index + Marker'Length - 1) = Marker then
               for Look in Index + Marker'Length .. Report'Last loop
                  if Report (Look) = 'y' then
                     return True;
                  elsif Report (Look) = 'n'
                    or else Report (Look) = Character'Val (10)
                  then
                     return False;
                  end if;
               end loop;
            end if;
         end loop;

         return False;
      end Mapped;

      Status : Natural;
   begin
      Tiny_Model.Write (Model, Room => 64);

      declare
         Default : constant String := Inspected ("", Status);
         By_Hand : Boolean;
      begin
         Assert (Status = 0, "an ordinary inspection failed");

         --  The two policies belong to run rather than to inspect, which
         --  is the command that reports whether a file was mapped -- so the
         --  question is asked of one and the answer of the other.
         By_Hand := Mapped (Default);

         Assert (Ran_With ("--no-mmap") = 0,
                 "--no-mmap failed, and reading a file is always possible: "
                 & Text_Of (Log));

         if By_Hand then
            Assert (Ran_With ("--mmap") = 0,
                    "the default mapped the file and --mmap failed: "
                    & Text_Of (Log));
         else
            Assert (Ran_With ("--mmap") /= 0,
                    "the default could not map the file and --mmap "
                    & "reported success");
            Assert (Project_Tools.Text.Contains
                      (Text_Of (Log),
                       E.Diagnostic_Code (E.Lifecycle_Mapping_Required)),
                    "--mmap failed without naming the code that says "
                    & "mapping was required: " & Text_Of (Log));
         end if;
      end;
   end Mapping_Is_Asked_For_Rather_Than_Allowed;

   --  Options with a consequence, observed through the command.
   --
   --  An option can be parsed into the right field and still do nothing:
   --  the field has to be read at the far end. Three had a test of the
   --  parse, a test of the layer underneath with the value handed over in
   --  Ada, and nothing running the command and looking at what came out.
   --
   --  What cannot be observed from here is said rather than skipped:
   --  --color auto colours a stream that is a terminal and this suite has
   --  none, so auto is checked for not colouring and NO_COLOR -- which only
   --  changes what auto does on a terminal -- is checked where the terminal
   --  facts are handed over directly, in the styling test.
   procedure Options_With_A_Consequence_Have_It
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model : constant String := "obj/behave-model.gguf";

      --  Text with its trailing line endings removed.
      function Without_Endings (Text : String) return String is
         Stop : Natural := Text'Last;
      begin
         while Stop >= Text'First
           and then Text (Stop) in Character'Val (10) | Character'Val (13)
         loop
            Stop := Stop - 1;
         end loop;

         return Text (Text'First .. Stop);
      end Without_Endings;

      --  Whether text carries an escape sequence.
      function Coloured (Text : String) return Boolean is
      begin
         for Character_Value of Text loop
            if Character_Value = ASCII.ESC then
               return True;
            end if;
         end loop;
         return False;
      end Coloured;

      --  Inspect the fixture and hand back what reached standard output.
      function Inspected (First, Second : String := "") return String is
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "inspect");
         Add (Source, Model);
         if First /= "" then
            Add (Source, First);
            if Second /= "" then
               Add (Source, Second);
            end if;
         end if;

         Ran (Source, Status);
         Assert (Status = 0,
                 "an inspection with '" & First & " " & Second
                 & "' failed with status" & Natural'Image (Status));
         return Last_Output;
      end Inspected;

      --  Run and hand back what reached standard error.
      function Diagnostics (First, Second : String := "") return String is
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
         Log    : constant String := "obj/behave-errors.txt";
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "2");
         Add (Source, "--temperature");
         Add (Source, "0");
         if First /= "" then
            Add (Source, First);
            if Second /= "" then
               Add (Source, Second);
            end if;
         end if;

         Create (Handle, Out_File, Log);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         return Text_Of (Log);
      end Diagnostics;
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  Colour, asked for and refused. The report goes to standard output,
      --  which is a file here, so "always" is the one that must colour it
      --  anyway -- that is what always means -- and the other two must not.
      declare
         Always : constant String := Inspected ("--color", "always");
         Never  : constant String := Inspected ("--color", "never");
         Auto   : constant String := Inspected ("--color", "auto");
      begin
         Assert (Coloured (Always),
                 "--color always did not colour a report going to a file, "
                 & "which is the one thing always means");
         Assert (not Coloured (Never),
                 "--color never coloured the report");
         Assert (not Coloured (Auto),
                 "--color auto coloured a report going to a file, which is "
                 & "not a terminal");
      end;

      --  The verbosity, which is one field with three settings, so what is
      --  asked is that the field reaches the far end and changes what comes
      --  out. A successful run writes nothing to standard error by default,
      --  which is the point of the default and is why a quiet run cannot be
      --  compared against it: there is nothing there to remove. Verbose
      --  against quiet is the comparison that exists.
      declare
         Plain  : constant String := Diagnostics;
         Loud   : constant String := Diagnostics ("--verbose");
         Hushed : constant String := Diagnostics ("--quiet");
      begin
         Assert (Loud'Length > Plain'Length,
                 "--verbose said no more than the default:"
                 & Natural'Image (Loud'Length) & " against"
                 & Natural'Image (Plain'Length));
         Assert (Hushed'Length <= Plain'Length,
                 "--quiet said more than the default:"
                 & Natural'Image (Hushed'Length) & " against"
                 & Natural'Image (Plain'Length));
      end;

      --  Statistics, asked for and refused. The block is the whole of what
      --  the option controls, so its presence is the question, and a
      --  successful run writes nothing else on that stream.
      declare
         Shown  : constant String := Diagnostics ("--show-stats");
         Hidden : constant String := Diagnostics ("--no-stats");
      begin
         --  Trailing line endings come off: closing a redirected Text_IO
         --  file leaves one behind, so an empty capture reads as one byte
         --  rather than none and "reported nothing" has to mean nothing
         --  once that is gone.
         Assert (Without_Endings (Shown)'Length > 0,
                 "--show-stats reported no statistics at all");
         Assert (Without_Endings (Hidden)'Length = 0,
                 "--no-stats reported something: " & Hidden);
      end;

      --  A context too small for the prompt. The option is accepted and the
      --  value reaches the field, both of which were checked; what the
      --  reader setting it cares about is that a prompt which does not fit
      --  is refused and named.
      declare
         Said : constant String := "obj/behave-context.txt";

         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "abababababab");
         Add (Source, "--context-size");
         Add (Source, "2");
         Add (Source, "--max-tokens");
         Add (Source, "1");

         Create (Handle, Out_File, Said);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status /= 0,
                 "a prompt longer than the context asked for was accepted");
         Assert (Project_Tools.Text.Contains (Text_Of (Said), "MR-GEN-0001"),
                 "a prompt that does not fit was refused without naming the "
                 & "code that says so: " & Text_Of (Said));
      end;
   end Options_With_A_Consequence_Have_It;

   --  A stop given on the command line stops the run.
   --
   --  Both halves were tested and the wire between them was not.
   --  Stop_String_Truncates builds the set in Ada and drives generation
   --  directly; the parser test proves "--stop END" reaches Stop_Count = 1.
   --  Between them is the loop in CLI.Execute that copies what was parsed
   --  into the set the run is given, and it could have copied nothing while
   --  both of those passed.
   procedure Stops_From_The_Command_Line_Stop
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Model : constant String := "obj/stopcli-model.gguf";

      --  Run and return the generated text.
      function Text_Produced (First, Second : String := "") return String is
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "8");
         Add (Source, "--seed");
         Add (Source, "1");
         Add (Source, "--temperature");
         Add (Source, "0");
         if First /= "" then
            Add (Source, First);
            Add (Source, Second);
         end if;

         Ran (Source, Status);
         Assert (Status = 0,
                 "a run with '" & First & " " & Second & "' failed with"
                 & Natural'Image (Status));
         return Last_Output;
      end Text_Produced;
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  Every byte, as a number, so that a failure on a machine this is not
      --  running on can be read. The first attempt printed the two strings
      --  and a macOS runner reported them as identical, which said that the
      --  stop did nothing and nothing about why.
      declare
         function Bytes (Text : String) return String is
            Room : String (1 .. Text'Length * 4 + 2);
            Used : Natural := 0;

            procedure Add_Word (Word : String) is
            begin
               Room (Used + 1 .. Used + Word'Length) := Word;
               Used := Used + Word'Length;
            end Add_Word;
         begin
            for Character_Value of Text loop
               Add_Word (Natural'Image (Character'Pos (Character_Value)));
            end loop;

            return Room (1 .. Used);
         end Bytes;

         Whole : constant String := Text_Produced;
      begin
         Assert (Whole'Length > 2,
                 "the run produced too little text to stop inside: '"
                 & Whole & "'");

         --  A stop string taken from what the run produces, so the test does
         --  not depend on guessing what these weights say. Everything from
         --  it onwards must be gone, and the text before it must be what it
         --  was.
         declare
            Cut : constant String :=
              Whole (Whole'First + 1 .. Whole'First + 1);

            Stopped : constant String := Text_Produced ("--stop", Cut);

            --  A control: a stop string the run cannot produce must leave
            --  the text exactly as it was. It tells a machine where the
            --  stop does nothing from one where it matches wrongly, which
            --  the failure on a macOS runner could not be told apart from.
            Absent : constant String :=
              Text_Produced ("--stop", "zqxjvwk");
         begin
            Assert (Absent = Whole,
                    "a stop string the run cannot produce changed it: ["
                    & Bytes (Absent) & " ] against [" & Bytes (Whole) & " ]");

            Assert (Stopped'Length < Whole'Length,
                    "a stop string on the command line did not shorten the "
                    & "run: stopped [" & Bytes (Stopped) & " ] against whole ["
                    & Bytes (Whole) & " ], cutting at [" & Bytes (Cut) & " ]");

            Assert (Stopped
                    = Whole (Whole'First .. Whole'First + Stopped'Length - 1),
                    "what came before the stop string changed: '" & Stopped
                    & "' against '" & Whole & "'");

            for Character_Value of Stopped loop
               Assert (Character_Value /= Cut (Cut'First),
                       "the stop string itself reached the output: '"
                       & Stopped & "'");
            end loop;
         end;
      end;

      --  And a stop token, which is the other half of the same option and
      --  travels by a different field.
      declare
         Whole : constant String := Text_Produced;

         --  Whatever the second token is, asked of the vocabulary the run
         --  uses rather than guessed.
         Stopped : constant String := Text_Produced ("--stop-token", "5");
      begin
         Assert (Stopped'Length <= Whole'Length,
                 "a stop token on the command line lengthened the run: '"
                 & Stopped & "' against '" & Whole & "'");
      end;
   end Stops_From_The_Command_Line_Stop;

   --  Every option, given rather than listed.
   --
   --  Seventeen of the thirty-eight were named in one place only: the test
   --  that asserts each appears on its command's help screen. That an option
   --  is documented is worth checking and is not the same as its being read.
   --  Nothing gave --top-p a value and asked what the parser made of it, so
   --  a parser that accepted the option and dropped the number would have
   --  passed -- and the sampling test that does exist builds its
   --  configuration in Ada rather than from a command line, so the two
   --  halves were each tested and the join between them was not.
   --
   --  What is asked here is the join: the value on the command line reaches
   --  the field it names, and a value the field cannot hold is refused.
   procedure Options_Reach_What_They_Name
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use type Model_Runner.Byte_Sources.Files.Mapping_Policy;

      --  Parse a run command line and hand back what it made.
      procedure Reading
        (First, Second : String;
         Result        : out Opt.Command;
         Status        : out E.Error_Info)
      is
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, "model.gguf");
         Add (Source, First);
         if Second /= "" then
            Add (Source, Second);
         end if;

         Opt.Parse (Source, Result, Status);
      end Reading;

      --  Parse and require success.
      function Read (First, Second : String := "") return Opt.Command is
         Result : Opt.Command;
         Status : E.Error_Info;
      begin
         Reading (First, Second, Result, Status);
         Assert (E.Is_Ok (Status),
                 "'" & First & " " & Second & "' was refused: "
                 & E.Error_Code'Image (Status.Code));
         return Result;
      end Read;

      --  Parse and require a refusal.
      procedure Refuses (First, Second : String; Why : String) is
         Result : Opt.Command;
         Status : E.Error_Info;
      begin
         Reading (First, Second, Result, Status);
         Assert (E.Is_Error (Status),
                 "'" & First & " " & Second & "' was accepted, where " & Why);
      end Refuses;
   begin
      --  The numbers that bound a run.
      Assert (Read ("--context-size", "512").Context_Size = 512,
              "--context-size did not reach the context size");
      Assert (Read ("--max-tokens", "9").Max_Tokens = 9,
              "--max-tokens did not reach the token bound");
      Assert (Read ("--batch-size", "7").Batch_Size = 7,
              "--batch-size did not reach the batch size");
      Assert (Read ("--threads", "3").Threads = 3,
              "--threads did not reach the worker count");

      --  The sampler's settings, which had no path from a command line to
      --  the configuration that any test walked.
      Assert (Read ("--top-k", "40").Sampling.Top_K = 40,
              "--top-k did not reach the sampler");
      Assert (Read ("--top-p", "0.9").Sampling.Top_P = 0.9,
              "--top-p did not reach the sampler");
      Assert (Read ("--min-p", "0.05").Sampling.Min_P = 0.05,
              "--min-p did not reach the sampler");
      Assert (Read ("--temperature", "0.25").Sampling.Temperature = 0.25,
              "--temperature did not reach the sampler");
      Assert (Read ("--repeat-penalty", "1.2").Sampling.Repeat_Penalty = 1.2,
              "--repeat-penalty did not reach the sampler");
      Assert (Read ("--repeat-window", "64").Sampling.Repeat_Window = 64,
              "--repeat-window did not reach the sampler");
      Assert (Read ("--frequency-penalty", "0.5").Sampling.Frequency_Penalty
              = 0.5,
              "--frequency-penalty did not reach the sampler");
      Assert (Read ("--presence-penalty", "0.5").Sampling.Presence_Penalty
              = 0.5,
              "--presence-penalty did not reach the sampler");

      --  Where a prompt and a system message come from.
      Assert (Model_Runner.Text.To_String
                (Read ("--system-file", "sys.txt").System_Path) = "sys.txt",
              "--system-file did not reach the system path");
      Assert (Model_Runner.Text.To_String
                (Read ("--prompt-file", "p.txt").Prompt_Path) = "p.txt",
              "--prompt-file did not reach the prompt path");

      --  Stopping.
      Assert (Read ("--stop-token", "11").Stop_Token_Count = 1,
              "--stop-token did not reach the stop set");
      Assert (Read ("--stop", "END").Stop_Count = 1,
              "--stop did not reach the stop set");

      --  The flags that take no value.
      Assert (Read ("--quiet").Level = Opt.Quiet,
              "--quiet did not reach the verbosity");
      Assert (Read ("--verbose").Level = Opt.Verbose,
              "--verbose did not reach the verbosity");
      Assert (Read ("--no-stats").Stats_Set
              and then not Read ("--no-stats").Show_Stats,
              "--no-stats did not reach the statistics setting");
      Assert (Read ("--show-stats").Show_Stats,
              "--show-stats did not reach the statistics setting");
      Assert (Read ("--mmap").Mapping
              = Model_Runner.Byte_Sources.Files.Mapping_Required,
              "--mmap did not reach the mapping policy");
      Assert (Read ("--no-mmap").Mapping
              = Model_Runner.Byte_Sources.Files.Mapping_Disabled,
              "--no-mmap did not reach the mapping policy");
      Assert (Read ("--raw").Raw, "--raw did not reach the raw flag");

      --  And the two that belong to inspect, given to inspect.
      declare
         Source : Fixed_Arguments;
         Result : Opt.Command;
         Status : E.Error_Info;
      begin
         Add (Source, "inspect");
         Add (Source, "model.gguf");
         Add (Source, "--metadata");
         Add (Source, "--tensors");
         Opt.Parse (Source, Result, Status);

         Assert (E.Is_Ok (Status), "an inspection with both flags was refused");
         Assert (Result.Show_Metadata,
                 "--metadata did not reach the metadata flag");
         Assert (Result.Show_Tensors,
                 "--tensors did not reach the tensor flag");
      end;

      --  A value the field cannot hold is refused rather than clamped. One
      --  per kind: a count, a probability, and a name.
      Refuses ("--top-p", "2.0", "a probability is at most one");
      Refuses ("--top-k", "-1", "a count is not negative");
      Refuses ("--temperature", "-0.5", "a temperature is not negative");
      Refuses ("--repeat-window", "-2", "a window is not negative");
      Refuses ("--batch-size", "0", "a batch of nothing evaluates nothing");
      Refuses ("--backend", "nonesuch", "no such backend is built");
      Refuses ("--repack", "nonesuch", "no such repacking mode exists");
   end Options_Reach_What_They_Name;

   --  Three options nothing named.
   --
   --  Of the thirty-eight in the registry, --validate, --help and --version
   --  were named by no test. The first does real work: it parses a model,
   --  says so, and reports nothing else, and its failure direction -- a file
   --  that is not valid -- is the whole point of having it.
   procedure Flag_Only_Options_Work
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model  : constant String := "obj/flags-model.gguf";
      Broken : constant String := "obj/flags-broken.gguf";

      --  Run and return standard output, which is where an answer goes.
      function Answer (Words : Fixed_Arguments) return String is
         Status : Natural;
      begin
         Ran (Words, Status);
         Assert (Status = 0,
                 "a run that should have succeeded left with status"
                 & Natural'Image (Status));
         return Last_Output;
      end Answer;
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  A sound file is reported valid, and nothing else is reported: the
      --  option exists so that a caller can ask the question without reading
      --  a page of metadata.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "inspect");
         Add (Source, Model);
         Add (Source, "--validate");

         declare
            Said : constant String := Answer (Source);
         begin
            Assert (Said'Length > 0, "--validate said nothing at all");
            Assert (not Project_Tools.Text.Contains (Said, "GGUF version"),
                    "--validate reported the container as well as the "
                    & "verdict: " & Said);
         end;
      end;

      --  And a file that is not sound is refused rather than called valid.
      --  Written by truncating the sound one, which is the shape of damage
      --  a partial download leaves.
      declare
         Source : Fixed_Arguments;
         Whole  : constant String :=
           Project_Tools.Files.Read_Raw_File (Model);
         Handle : File_Type;
         Status : Natural;
         Log    : constant String := "obj/flags-err.txt";
         Errors : File_Type;
      begin
         Create (Handle, Out_File, Broken);
         Put (Handle, Whole (Whole'First .. Whole'First + Whole'Length / 2));
         Close (Handle);

         Add (Source, "inspect");
         Add (Source, Broken);
         Add (Source, "--validate");

         Create (Errors, Out_File, Log);
         Set_Error (Errors);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Errors);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Errors);

         Assert (Status /= 0,
                 "a truncated file was called valid");
         Assert (Project_Tools.Text.Contains
                   (Text_Of (Log), "MR-"),
                 "a truncated file was refused without naming a code");
      end;

      --  --help answers for the command it was typed against. It used to
      --  discard the command and print the top-level screen, which is the
      --  less useful of the two answers.
      declare
         Flagged : Fixed_Arguments;
         Asked   : Fixed_Arguments;
         Bare    : Fixed_Arguments;
      begin
         Add (Flagged, "run");
         Add (Flagged, "--help");
         Add (Asked, "help");
         Add (Asked, "run");
         Add (Bare, "help");

         declare
            By_Flag : constant String := Answer (Flagged);
            By_Word : constant String := Answer (Asked);
            Top     : constant String := Answer (Bare);
         begin
            Assert (By_Flag = By_Word,
                    "'run --help' and 'help run' gave different screens");
            Assert (By_Flag /= Top,
                    "'run --help' gave the top-level screen, which is what "
                    & "bare help is for");
         end;
      end;

      --  --version answers whatever command it was typed against, because a
      --  version is not a property of a command.
      declare
         Flagged : Fixed_Arguments;
         Asked   : Fixed_Arguments;
      begin
         Add (Flagged, "run");
         Add (Flagged, "--version");
         Add (Asked, "version");

         Assert (Answer (Flagged) = Answer (Asked),
                 "'run --version' and 'version' gave different answers");
      end;
   end Flag_Only_Options_Work;

   --  Refusals the command makes that no test had ever made it make.
   --
   --  A code is a promise that a particular wrong input is turned away and
   --  named. The raise being written is not evidence that the branch is
   --  taken, and the check that every code is produced somewhere counts a
   --  raise nobody reaches exactly as it counts a raise everybody reaches.
   --  These four were in that state.
   procedure Unreached_Refusals_Are_Reached
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model : constant String := "obj/unreached-model.gguf";

      --  Run the command and return the diagnostic it wrote.
      function Refusal (Words : Fixed_Arguments) return String is
         Log    : constant String := "obj/unreached-err.txt";
         Handle : File_Type;
         Status : Natural;
      begin
         Create (Handle, Out_File, Log);
         Set_Error (Handle);
         begin
            Ran (Words, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status /= 0,
                 "a run that should have been refused left with a success");

         return Text_Of (Log);
      end Refusal;

      --  Whether a diagnostic names a code, by the MR-XXX-NNNN identifier
      --  the code carries. Asked of the code rather than written out, so a
      --  renumbering does not quietly stop being looked for.
      function Names (Text : String; Code : E.Error_Code) return Boolean
      is (Project_Tools.Text.Contains (Text, E.Diagnostic_Code (Code)));
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  An option that belongs to another command. The parser knows which
      --  options each command takes and says so by name rather than calling
      --  it unknown.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "inspect");
         Add (Source, Model);
         Add (Source, "--temperature");
         Add (Source, "0.5");

         declare
            Said : constant String := Refusal (Source);
         begin
            Assert (Names (Said, E.CLI_Option_Not_For_Command),
                    "an option for another command was not refused by name: "
                    & Said);
         end;
      end;

      --  Interactive mode without a terminal on both streams. The suite has
      --  neither, which is what makes this reachable here at all.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--interactive");

         declare
            Said : constant String := Refusal (Source);
         begin
            Assert (Names (Said, E.CLI_Interactive_Unavailable),
                    "interactive mode without a terminal was not refused by "
                    & "name: " & Said);
         end;
      end;

      --  A run with no prompt anywhere: none on the command line, none in a
      --  file, and nothing on standard input.
      declare
         Source : Fixed_Arguments;
         Empty  : constant String := "obj/unreached-empty.txt";
         From   : File_Type;
         Blank  : File_Type;
      begin
         Create (Blank, Out_File, Empty);
         Close (Blank);

         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");

         Open (From, In_File, Empty);
         Set_Input (From);

         declare
            Said : constant String := Refusal (Source);
         begin
            Set_Input (Standard_Input);
            Close (From);
            Assert (Names (Said, E.CLI_No_Prompt_Available),
                    "a run with no prompt at all was not refused by name: "
                    & Said);
         end;
      end;
   end Unreached_Refusals_Are_Reached;

   --  The thing that catches what the command writes.
   --
   --  Forty lines of descriptor juggling whose failure mode is swallowing
   --  the suite's own report, which it did: nesting a capture inside a
   --  capture left standard output pointing at a file and the whole report
   --  vanished, 182 lines to none. What found that was counting opens
   --  against closes by hand. Nothing checked any of it.
   --
   --  Four things are asked. Text written while it is open comes back.
   --  Standard output is put back afterwards, which is the property whose
   --  failure is invisible until a report goes missing. Nesting is refused
   --  rather than half-done. And Took_Effect answers for the last Open
   --  rather than for whether one was ever tried.
   procedure Capture_Catches_And_Restores
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);

      --  Written through the raw stream, which is the one the generated
      --  text uses and the one Set_Output does not redirect. Writing through
      --  Put_Line would prove nothing about the case this exists for.
      procedure Say (Text : String) is
      begin
         String'Write
           (Ada.Text_IO.Text_Streams.Stream (Ada.Text_IO.Standard_Output),
            Text);
         Ada.Text_IO.Flush (Ada.Text_IO.Standard_Output);
      end Say;

      Inside : constant String := "caught-by-the-capture";
   begin
      Captured_Output.Open ("obj/capture-probe.txt");
      Say (Inside);

      declare
         Back : constant String := Captured_Output.Close;
      begin
         Assert (Captured_Output.Took_Effect,
                 "the capture did not take effect, so what follows says "
                 & "nothing about it");
         Assert (Back = Inside,
                 "the capture returned '" & Back & "' where '" & Inside
                 & "' was written");
      end;

      --  And standard output is back. Said by capturing again: if the first
      --  Close had left the descriptor on the file, this second capture
      --  would still work and the report would still be lost, so what is
      --  checked is that the second capture catches only what is written
      --  inside it and not what was written before.
      Captured_Output.Open ("obj/capture-probe-two.txt");

      declare
         Back : constant String := Captured_Output.Close;
      begin
         Assert (Back = "",
                 "a capture that wrote nothing returned '" & Back
                 & "', so the one before it had not been closed");
      end;

      --  The same file twice, the second time with less in it. A capture
      --  that opened without truncating would leave the tail of the first
      --  behind and hand back a longer string than was written -- which is
      --  what happened on macOS, where the create-and-truncate flags this
      --  hard-coded mean something else: a run that produced one byte read
      --  back as the nine before it, and the stop test compared a truncated
      --  run against an untruncated one and found them equal.
      declare
         Once  : constant String := "obj/capture-probe.txt";
         Short : constant String := "s";
      begin
         Captured_Output.Open (Once);
         Say ("a much longer first write");

         declare
            First : constant String := Captured_Output.Close;
            pragma Unreferenced (First);
         begin
            null;
         end;

         Captured_Output.Open (Once);
         Say (Short);

         declare
            Second : constant String := Captured_Output.Close;
         begin
            Assert (Second = Short,
                    "a second capture on the same file returned '" & Second
                    & "' where '" & Short & "' was written, so the file was "
                    & "not emptied first");
         end;
      end;

      --  Nesting is refused. A second Open inside the first would overwrite
      --  the one saved descriptor, and then neither Close could put things
      --  back -- which is exactly how the report went missing.
      Captured_Output.Open ("obj/capture-probe-three.txt");

      declare
         Refused : Boolean := False;
      begin
         begin
            Captured_Output.Open ("obj/capture-probe-four.txt");
         exception
            when others =>
               Refused := True;
         end;

         declare
            Back : constant String := Captured_Output.Close;
            pragma Unreferenced (Back);
         begin
            null;
         end;

         Assert (Refused,
                 "a capture opened inside another was accepted, so the "
                 & "saved descriptor is overwritten and standard output "
                 & "never comes back");
      end;

      --  A path that cannot be opened is reported rather than silently
      --  leaving standard output where it was and pretending.
      Captured_Output.Open ("obj/no-such-directory-here/probe.txt");

      declare
         Back : constant String := Captured_Output.Close;
      begin
         Assert (not Captured_Output.Took_Effect,
                 "a capture on a path that cannot be opened said it took "
                 & "effect");
         Assert (Back = "",
                 "a capture that never opened returned '" & Back & "'");
      end;
   end Capture_Catches_And_Restores;

   --  Every interactive command, run rather than parsed.
   --
   --  Which word means which command was checked in both directions, and the
   --  handlers were not. One session was driven anywhere in the suite and it
   --  typed "hello", a blank line, /stats and /exit, so five of the eight
   --  kinds -- Reset, Help, Settings, Context and Set_System -- had their
   --  spelling tested and their behaviour tested nowhere.
   --
   --  Two things are asked here. Every command has to do something, which is
   --  what tells a handler that reports from one that returns silently; and
   --  /reset has to actually clear the conversation, which is the one whose
   --  failure is invisible -- a session that kept the previous turn would go
   --  on answering, with the old turn still in the context it was told to
   --  forget.
   procedure Interactive_Commands_Do_Something
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Back renames Model_Runner.Backend;
      use Ada.Text_IO;

      Image : B.Byte_Array_Access;

      --  Drive one scripted session and return what it wrote to standard
      --  error, which is where the interactive layer answers.
      function Session_Saying
        (Held  : B.Byte_Array_Access;
         Lines : String) return String
      is
         Input  : constant String := "obj/commands-in.txt";
         Log    : constant String := "obj/commands-err.txt";
         Script : File_Type;
      begin
         Create (Script, Out_File, Input);
         Put (Script, Lines);
         Close (Script);

         declare
            Copy    : aliased constant B.Byte_Array := Held.all;
            Rig     : Harness (Copy'Access);
            Session : L.Session;
            Catalog : aliased Model_Runner.Localization.Catalog;
            Screen  : aliased Model_Runner.Presentation.Console;
            Options : Opt.Command;
            From    : File_Type;
            Err     : File_Type;
            Status  : Natural := 0;
            Outcome : E.Error_Info;
         begin
            Start (Rig, Back.Backend_Reference);
            L.Open (Session, Rig.Ready, Status => Outcome);
            Assert (E.Is_Ok (Outcome), "the session did not open");

            Model_Runner.Localization.Open
              (Catalog, Model_Runner.Platform.Catalog_Path, "en");
            Model_Runner.Presentation.Open
              (Screen, Catalog'Unchecked_Access, Opt.Color_Never,
               (Output_Is_Terminal => False,
                Error_Is_Terminal  => False,
                Input_Is_Terminal  => False,
                Colour_Suppressed  => True),
               Opt.Normal);

            Options.Max_Tokens := 4;
            Options.Sampling.Temperature := 0.0;

            Open (From, In_File, Input);
            Create (Err, Out_File, Log);
            Set_Input (From);
            Set_Error (Err);

            --  The answers go to the real standard output, which only a
            --  descriptor move catches. Without it a scripted session writes
            --  its replies into the suite's own report.
            Captured_Output.Open ("obj/commands-out.txt");
            begin
               Model_Runner.CLI.Interactive.Run
                 (Options, Screen, Rig.Ready, Session, null, Status => Status);
            exception
               when others =>
                  declare
                     Ignored : constant String := Captured_Output.Close;
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
                  Set_Input (Standard_Input);
                  Set_Error (Standard_Error);
                  Close (From);
                  Close (Err);
                  raise;
            end;
            declare
               Ignored : constant String := Captured_Output.Close;
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
            Set_Input (Standard_Input);
            Set_Error (Standard_Error);
            Close (From);
            Close (Err);

            Assert (Status = 0,
                    "a scripted session left with status"
                    & Natural'Image (Status));

            L.Close (Session);
            Model_Runner.Localization.Close (Catalog);
         end;

         return Text_Of (Log);
      end Session_Saying;

      Newline : constant String := [1 => Character'Val (10)];
   begin
      Tiny_Model.Build (Image, Room => 256);

      declare
         --  A session that types nothing but the word that leaves. Whatever
         --  every session says -- a banner, a farewell -- is in here, so what
         --  a command adds is what the others hold and this does not.
         Bare : constant String :=
           Session_Saying (Image, "/exit" & Newline);

         --  Each command has to add something to that.
         procedure Says_More (Word : String) is
            Said : constant String :=
              Session_Saying (Image, Word & Newline & "/exit" & Newline);
         begin
            Assert (Said'Length > Bare'Length,
                    "'" & Word & "' wrote no more than a session that only "
                    & "leaves, so its handler answered nothing");
         end Says_More;
      begin
         Assert (Bare'Length > 0,
                 "a session that only leaves wrote nothing at all, so the "
                 & "comparisons below would hold for a build where every "
                 & "command is silent");

         Says_More ("/help");
         Says_More ("/settings");
         Says_More ("/context");
         Says_More ("/stats");

         --  A word this build does not know is answered too, and answered
         --  differently from one it does.
         Says_More ("/nonsense");
      end;

      --  /reset clears the conversation, and what says so from outside is
      --  how much context the turn after it takes.
      --
      --  Two scripts ask the same question twice and end by asking how full
      --  the context is; one clears the conversation between them. Cleared,
      --  the second turn renders one exchange and takes less room than the
      --  two the other renders. Comparing the whole session would not say
      --  this: the scripts differ by a line, so their output differs however
      --  the handler behaves, which is what the first version of this
      --  compared and why it passed with the clearing taken out. The context
      --  line alone is the answer, and it is the last line either writes.
      declare
         --  The line the context command wrote.
         --
         --  Found by what it says rather than by where it is: the last line
         --  of a session is the prompt marker and the progress dots, which
         --  differ between two scripts of different lengths whatever the
         --  handlers did. Comparing those was the first version of this and
         --  it passed with the clearing taken out.
         Marker : constant String := "context tokens used";

         --  The message alone, without the prompt markers that precede it on
         --  the same line. Those count the turns, so leaving them in made
         --  two sessions of different lengths differ whatever the numbers
         --  said -- which is how the version before this one passed with the
         --  clearing taken out, reporting 48 tokens both times.
         Prefix : constant String := "model_runner: ";

         function Context_Line (Text : String) return String is
            First : Natural := Text'First;
         begin
            for Index in Text'First .. Text'Last - Marker'Length + 1 loop
               if Index >= Text'First + Prefix'Length
                 and then Text (Index - Prefix'Length .. Index - 1) = Prefix
               then
                  First := Index;
               end if;

               if Text (Index .. Index + Marker'Length - 1) = Marker then
                  declare
                     Stop : Natural := Index;
                  begin
                     while Stop < Text'Last
                       and then Text (Stop + 1) /= Character'Val (10)
                     loop
                        Stop := Stop + 1;
                     end loop;
                     return Text (First .. Stop);
                  end;
               end if;
            end loop;

            return "";
         end Context_Line;

         --  A blank line is what submits a turn, so each question is two
         --  lines. Without the blank the text is only held and the session
         --  never generates anything -- which is how the first version of
         --  this asked for two turns and got none.
         Turn : constant String := "ab" & Newline & Newline;

         Twice : constant String :=
           Session_Saying
             (Image, Turn & Turn & "/context" & Newline & "/exit" & Newline);
         Cleared : constant String :=
           Session_Saying
             (Image,
              Turn & "/reset" & Newline & Turn & "/context" & Newline
              & "/exit" & Newline);
      begin
         Assert (Context_Line (Twice) /= "",
                 "no session reported how full the context is, so the "
                 & "comparison below is between two empty strings");

         Assert (Context_Line (Twice) /= Context_Line (Cleared),
                 "two turns and two turns with the conversation cleared "
                 & "between them filled the context alike -- '"
                 & Context_Line (Twice) & "' against '"
                 & Context_Line (Cleared)
                 & "' -- so /reset left the turn it was told to forget in "
                 & "place");

         --  What this holds is the conversation being cleared. The session
         --  reset beside it is not held: taking it out changes nothing
         --  observable, because the next turn's tokens are then not a prefix
         --  of what the session committed and generation resets it anyway.
         --  Belt and braces, and the test can only see the belt.
      end;

      --  A line that is not UTF-8. Standard input is untrusted and the loop
      --  refuses text it cannot read as characters rather than passing bytes
      --  on to a tokenizer that would refuse them further down with less to
      --  say about where they came from.
      declare
         Bad : constant String :=
           "ab" & Character'Val (16#C4#) & Character'Val (16#C4#);

         Said : constant String :=
           Session_Saying (Image, Bad & Newline & "/exit" & Newline);
         Good : constant String :=
           Session_Saying (Image, "abab" & Newline & "/exit" & Newline);
      begin
         Assert (Project_Tools.Text.Contains
                   (Said, E.Diagnostic_Code (E.IO_Invalid_UTF8)),
                 "a line that is not UTF-8 was not refused by name: " & Said);

         Assert (Said'Length > Good'Length,
                 "a line that is not UTF-8 read the same as one that is, so "
                 & "the loop passed it on rather than refusing it");
      end;

      --  A line longer than the buffer the loop reads into.
      --
      --  Standard input is untrusted and this is the one place the loop
      --  bounds it: a line past 8192 bytes is skipped to its end and the
      --  turn it was part of is refused, rather than arriving in pieces that
      --  would either be joined into one turn or split into several with
      --  line feeds inside what somebody typed as one line. The reasoning is
      --  written out beside the code and nothing had ever driven it, because
      --  until this test there was no way to script a session.
      declare
         Long : constant String := [1 .. 9_000 => 'a'];

         Said : constant String :=
           Session_Saying (Image, Long & Newline & "/exit" & Newline);
         Short : constant String :=
           Session_Saying (Image, "aaa" & Newline & "/exit" & Newline);
      begin
         Assert (Said /= Short,
                 "a line of nine thousand characters read the same as a "
                 & "line of three, so the bound the loop puts on standard "
                 & "input reported nothing");

         Assert (Said'Length > Short'Length,
                 "a line past the buffer wrote no more than one inside it, "
                 & "so it was taken rather than refused");
      end;

      --  A system message, set and then taken away. Neither is refused, and
      --  what they change is the text rendered for the next turn, which this
      --  cannot see from here -- so what it says is that both are commands
      --  and the session goes on after them, which is what /system being
      --  matched with its trailing space got wrong.
      declare
         Set_And_Cleared : constant String :=
           Session_Saying
             (Image,
              "/system be brief" & Newline & "/system" & Newline
              & "ab" & Newline & "/exit" & Newline);
         Refused : constant String :=
           Session_Saying
             (Image,
              "/systematic" & Newline & "/systematic" & Newline
              & "ab" & Newline & "/exit" & Newline);
      begin
         Assert (Set_And_Cleared /= Refused,
                 "a system message set and taken away read the same as two "
                 & "unknown commands, so neither was a command");
      end;

      B.Free (Image);
   end Interactive_Commands_Do_Something;

   --  A backend that cannot batch is asked for one token at a time.
   --
   --  Both paths that build a request have to make that clamp, and when it
   --  was written into one of them the other refused its first turn:
   --  --interactive --backend reference met the capability check and stopped.
   --  A capability is for deciding what to ask, not for failing what was
   --  asked, and a decision made in one of two places is a decision made in
   --  neither.
   procedure Slow_Backend_Is_Asked_For_One
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Back renames Model_Runner.Backend;
      use Ada.Text_IO;

      Model : constant String := "obj/clamp-model.gguf";
   begin
      Tiny_Model.Write (Model, Room => 256);

      --  The single-shot path, through the whole command, with the batch
      --  size left at its default.
      declare
         Source : Fixed_Arguments;
         Status : Natural;
         Handle : File_Type;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--backend");
         Add (Source, Back.Backend_Name (Back.Backend_Reference));
         Add (Source, "--prompt");
         Add (Source, "hi");
         Add (Source, "--max-tokens");
         Add (Source, "2");

         Create (Handle, Out_File, "obj/clamp.txt");
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status = 0,
                 "a run on the backend that cannot batch failed with status"
                 & Natural'Image (Status) & ": "
                 & Text_Of ("obj/clamp.txt"));
      end;

      --  And the interactive path, which builds its own request.
      declare
         Image   : B.Byte_Array_Access;
         Input   : constant String := "obj/clamp-in.txt";
         Handle  : File_Type;
      begin
         Tiny_Model.Build (Image, Room => 256);

         Create (Handle, Out_File, Input);
         Put_Line (Handle, "hello");
         Put_Line (Handle, "");
         Put_Line (Handle, "/stats");
         Put_Line (Handle, "/exit");
         Close (Handle);

         declare
            Held    : aliased constant B.Byte_Array := Image.all;
            Rig     : Harness (Held'Access);
            Session : L.Session;
            Catalog : aliased Model_Runner.Localization.Catalog;
            Screen  : aliased Model_Runner.Presentation.Console;
            Options : Opt.Command;
            From    : File_Type;
            Err     : File_Type;
            Status  : Natural := 0;
            Outcome : E.Error_Info;
         begin
            Start (Rig, Back.Backend_Reference);
            L.Open (Session, Rig.Ready, Status => Outcome);
            Assert (E.Is_Ok (Outcome), "the session did not open");

            Model_Runner.Localization.Open
              (Catalog, Model_Runner.Platform.Catalog_Path, "en");
            Model_Runner.Presentation.Open
              (Screen, Catalog'Unchecked_Access, Opt.Color_Never,
               (Output_Is_Terminal => False,
                Error_Is_Terminal  => False,
                Input_Is_Terminal  => False,
                Colour_Suppressed  => True),
               Opt.Normal);

            Options.Max_Tokens := 2;
            Options.Sampling.Temperature := 0.0;
            Options.Show_Stats := True;

            Open (From, In_File, Input);
            Create (Err, Out_File, "obj/clamp-err.txt");
            Set_Input (From);
            Set_Error (Err);
            Captured_Output.Open ("obj/clamp-answers.txt");
            begin
               Model_Runner.CLI.Interactive.Run
                 (Options, Screen, Rig.Ready, Session, null, Status => Status);
            exception
               when others =>
                  declare
                     Ignored : constant String := Captured_Output.Close;
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
                  Set_Input (Standard_Input);
                  Set_Error (Standard_Error);
                  Close (From);
                  Close (Err);
                  raise;
            end;
            declare
               Ignored : constant String := Captured_Output.Close;
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
            Set_Input (Standard_Input);
            Set_Error (Standard_Error);
            Close (From);
            Close (Err);

            --  A completed turn, not a refusal. /stats says which it was.
            declare
               Said : constant String :=
                 Text_Of ("obj/clamp-err.txt");
               None : constant String :=
                 Model_Runner.Localization.Text
                   (Catalog, "cli.interactive.no_stats");
            begin
               Assert (not Project_Tools.Text.Contains (Said, None),
                       "an interactive turn on the backend that cannot "
                       & "batch did not complete: " & Said);
            end;

            L.Close (Session);
            L.Close (Rig.Ready, Outcome);
            Containers.Close (Rig.Parsed);
         end;
      end;
   end Slow_Backend_Is_Asked_For_One;

   --  How many workers run a generation does not change what it produces.
   --
   --  The README says the result is bit-identical whatever --threads is, and
   --  that was held one layer down: a parallel matrix product equals the
   --  serial one exactly. What was not held is the whole of it -- a run
   --  partitions rows across workers for every product of every layer of
   --  every token, and a partition that dropped or doubled a row would show
   --  up here and nowhere in a single product.
   procedure Worker_Count_Does_Not_Change_The_Text
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Image : B.Byte_Array_Access;
      First : String (1 .. Max_Captured) := [others => ' '];
      First_Used : Natural := 0;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
      begin
         Start (Under);

         for Count in Model_Runner.Backend.CPU.Worker_Count range 1 .. 4 loop
            declare
               Team    : aliased Model_Runner.Backend.CPU.Pool (Count);
               Session : L.Session;
               Stop    : Model_Runner.Stops.Set;
               Sink    : aliased Capture_Sink;
               Request : Gen.Request;
               Outcome : Gen.Result;
               Status  : E.Error_Info;
            begin
               Model_Runner.Backend.CPU.Open (Team);
               Model_Runner.Stops.Open (Stop);

               L.Open
                 (Session, Under.Ready, Workers => Team'Unchecked_Access,
                  Status => Status);
               Assert (E.Is_Ok (Status),
                       "the session did not open for" & Integer'Image (Count)
                       & " workers: " & E.Error_Code'Image (Status.Code));

               --  The session really is running on the pool that was opened,
               --  with the workers asked for. Without this the whole test
               --  could compare four serial runs and pass by saying nothing.
               Assert (Model_Runner.Backend.CPU."/=" (L.Workers (Session), null),
                       "the session ignored the worker pool");
               Assert (Model_Runner.Backend.CPU.Worker_Total (Team) = Count,
                       "the pool has"
                       & Integer'Image
                           (Model_Runner.Backend.CPU.Worker_Total (Team))
                       & " workers rather than" & Integer'Image (Count));
               Assert (Model_Runner.Backend.CPU.Is_Open (Team),
                       "the pool is not open");

               --  Enough tokens that every layer runs several times, and a
               --  prompt long enough to be batched rather than stepped.
               Request.Max_Tokens := 6;
               Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
               Request.Has_Seed := True;
               Request.Add_Beginning := True;

               Gen.Generate
                 (Under.Ready, Session, "abab", Request, Stop, null,
                  Sink'Unchecked_Access, null, null, null, null,
                  Outcome => Outcome);

               Assert (Outcome.Reason = Gen.Maximum_Tokens,
                       "the run with" & Integer'Image (Count)
                       & " workers ended for another reason: "
                       & Gen.Completion_Reason'Image (Outcome.Reason));

               declare
                  Text : constant String := Captured (Sink);
               begin
                  if Count = 1 then
                     Assert (Text'Length > 0, "the first run produced nothing");
                     First (1 .. Text'Length) := Text;
                     First_Used := Text'Length;
                  else
                     Assert (Text = First (1 .. First_Used),
                             "the text produced with" & Integer'Image (Count)
                             & " workers differs from one worker's: """
                             & Text & """ against """
                             & First (1 .. First_Used) & """");
                  end if;
               end;

               Assert (Outcome.Generated_Tokens > 0,
                       "no tokens were generated with"
                       & Integer'Image (Count) & " workers");

               Gen.Release (Outcome);
               L.Close (Session);
               Model_Runner.Stops.Close (Stop);
               Model_Runner.Backend.CPU.Close (Team);
            exception
               when others =>
                  --  A failed assertion raises, and worker tasks left running
                  --  keep the program from terminating. The failure would
                  --  then arrive as a suite that hangs, which says nothing
                  --  about which comparison went wrong.
                  Model_Runner.Backend.CPU.Close (Team);
                  raise;
            end;
         end loop;
      end;

      B.Free (Image);
   end Worker_Count_Does_Not_Change_The_Text;

   --  How a prompt is divided into batches does not change what follows it.
   --
   --  A batch of tokens against the same tokens one at a time is held
   --  already, on the logits and on the cache left behind. What that cannot
   --  reach is the seam: a prompt longer than the batch size is evaluated in
   --  several passes, and each must continue from where the last committed.
   --  An error there is invisible in a single batch and shows up as a run
   --  that answers differently depending on a performance setting.
   procedure Batch_Size_Does_Not_Change_The_Text
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Image : B.Byte_Array_Access;
      First : String (1 .. Max_Captured) := [others => ' '];
      First_Used : Natural := 0;
      Sizes : Natural := 0;
   begin
      Tiny_Model.Build (Image);

      declare
         Held  : aliased constant B.Byte_Array := Image.all;
         Under : Harness (Held'Access);
      begin
         Start (Under);

         --  One divides the prompt into as many passes as it has tokens,
         --  and six takes it in a single pass, so the seam is crossed a
         --  different number of times in every run here.
         for Size in 1 .. 6 loop
            declare
               Session : L.Session;
               Stop    : Model_Runner.Stops.Set;
               Sink    : aliased Capture_Sink;
               Request : Gen.Request;
               Outcome : Gen.Result;
               Status  : E.Error_Info;
            begin
               Model_Runner.Stops.Open (Stop);
               L.Open (Session, Under.Ready, Status => Status);
               Assert (E.Is_Ok (Status),
                       "the session did not open for batch size"
                       & Integer'Image (Size));

               Request.Max_Tokens := 5;
               Request.Batch_Size := Size;
               Request.Sampling := Model_Runner.Sampling.Greedy_Configuration;
               Request.Has_Seed := True;
               Request.Add_Beginning := True;

               Gen.Generate
                 (Under.Ready, Session, "ababab", Request, Stop, null,
                  Sink'Unchecked_Access, null, null, null, null,
                  Outcome => Outcome);

               Assert (Outcome.Reason = Gen.Maximum_Tokens,
                       "the run at batch size" & Integer'Image (Size)
                       & " ended for another reason: "
                       & Gen.Completion_Reason'Image (Outcome.Reason));

               --  The prompt has to be long enough that the small batch
               --  sizes really do take several passes.
               Assert (Outcome.Prompt_Tokens > 3,
                       "the prompt is too short to be divided:"
                       & Natural'Image (Outcome.Prompt_Tokens) & " tokens");

               declare
                  Text : constant String := Captured (Sink);
               begin
                  if Size = 1 then
                     Assert (Text'Length > 0,
                             "the run at batch size one produced nothing");
                     First (1 .. Text'Length) := Text;
                     First_Used := Text'Length;
                  else
                     Assert (Text = First (1 .. First_Used),
                             "batch size" & Integer'Image (Size)
                             & " produced """ & Text
                             & """ where one token at a time produced """
                             & First (1 .. First_Used) & """");
                  end if;
               end;

               Sizes := Sizes + 1;
               Gen.Release (Outcome);
               L.Close (Session);
               Model_Runner.Stops.Close (Stop);
            exception
               when others =>
                  L.Close (Session);
                  Model_Runner.Stops.Close (Stop);
                  raise;
            end;
         end loop;
      end;

      Assert (Sizes = 6, "not every batch size was run");
      B.Free (Image);
   end Batch_Size_Does_Not_Change_The_Text;

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
              (Under.Ready, Session, "ab", Request, Stop, null,
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
           (Under.Ready, Session, "ab", Request, Stop, null,
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
              (Under.Ready, Session, "ab", Request, Stop, null,
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
           (Under.Ready, Session, "ab", Request, Stop, null,
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
           (Under.Ready, Session, "ab", Request, Stop, null,
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
           (Under.Ready, Session, "ab", Request, Stop, null,
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
           (Under.Ready, Session, "abc", Request, Stop, null,
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
           (Under.Ready, Session, "ab", Request, Stop, null,
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
   --  A mapped read and an ordinary read return the same bytes.
   --
   --  Mapping is how the weights are reached when the host allows it, and it
   --  is a different path from first byte to last: one hands back memory the
   --  kernel arranged, the other copies through a stream. They are supposed
   --  to be indistinguishable, and nothing compared them. A model read one
   --  way and generated from the other would differ in whatever the two
   --  paths disagree about, which is exactly the kind of thing that never
   --  shows up on the machine where it was written.
   procedure Mapping_Reads_The_Same_Bytes
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Sources renames Model_Runner.Byte_Sources.Files;
      use type B.Byte;
      use type B.Byte_Count;
      use type B.Byte_Array;

      Path : constant String := "obj/mapping-model.gguf";
   begin
      Tiny_Model.Write (Path);

      declare
         Extent : constant B.Byte_Count :=
           B.Byte_Count (Ada.Directories.Size (Path));

         Mapped : B.Byte_Array (1 .. Extent) := [others => 0];
         Plain  : B.Byte_Array (1 .. Extent) := [others => 0];

         Source : Sources.File_Source;
         Status : E.Error_Info;
         Host_Maps : Boolean := False;
      begin
         Assert (Extent > 0, "the fixture model is empty");

         --  Required, so that a host which cannot map says so rather than
         --  quietly falling back and leaving this comparing one path with
         --  itself.
         Sources.Open (Source, Path, Sources.Mapping_Required, 0, Status);

         if Status.Code = E.Lifecycle_Mapping_Required then
            --  No mapping on this host. There is nothing to compare, and
            --  saying so is better than passing as though there were.
            Host_Maps := False;
         else
            Assert (E.Is_Ok (Status),
                    "a required mapping failed for another reason: "
                    & E.Error_Code'Image (Status.Code));
            Assert (Sources.Is_Mapped (Source),
                    "a required mapping reported itself unmapped");
            Host_Maps := True;

            Sources.Read (Source, 0, Mapped, Status);
            Assert (E.Is_Ok (Status), "the mapped read failed");
         end if;

         Sources.Close (Source);

         Sources.Open (Source, Path, Sources.Mapping_Disabled, 0, Status);
         Assert (E.Is_Ok (Status), "the unmapped open failed");
         Assert (not Sources.Is_Mapped (Source),
                 "a disabled mapping mapped anyway");

         Sources.Read (Source, 0, Plain, Status);
         Assert (E.Is_Ok (Status), "the unmapped read failed");
         Sources.Close (Source);

         --  The bytes of a model are what everything else is built from, so
         --  comparing them is comparing every tensor at once.
         if Host_Maps then
            Assert (Mapped = Plain,
                    "the mapped bytes differ from the bytes read");
         end if;

         --  And the unmapped path really did read the file rather than
         --  returning the zeros it was initialised with.
         Assert ((for some Value of Plain => Value /= 0),
                 "the unmapped read returned nothing");
      end;

      Ada.Directories.Delete_File (Path);
   end Mapping_Reads_The_Same_Bytes;

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
         Ada.Text_IO.Set_Error (Handle);
         Ran (Source, Status);
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
         Ran (Source, Status);
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
      Accepted : Natural := 0;
      Refused  : Natural := 0;
   begin
      for Case_Number in 1 .. 4_000 loop
         declare
            Source : Fixed_Arguments;
            Item   : Opt.Command;
            Status : E.Error_Info;
            Count  : constant Natural := Draw (8);
         begin
            --  Half the vectors start as a command line that would work,
            --  and are then handed random pieces. Drawing every token freely
            --  produced almost nothing the parser accepts -- around one in
            --  forty -- so the accepting path was walked by a hundred cases
            --  out of four thousand while the refusing path took the rest.
            --  Starting from something well formed keeps the pieces random
            --  while putting both paths under the generator.
            if Draw (2) = 0 then
               Add (Source, "run");
               Add (Source, "m.gguf");
               Add (Source, "--prompt");
               Add (Source, "hi");
            end if;

            for Index in 1 .. Count loop
               Add (Source, Piece (Draw (31)));
            end loop;

            --  The property: it comes back, with an outcome, whatever it was
            --  handed. Which outcome is not the question here -- the cases
            --  above check that -- only that there is one and it arrived.
            Opt.Parse (Source, Item, Status);
            Answered := Answered + 1;

            if E.Is_Ok (Status) then
               Accepted := Accepted + 1;
            else
               Refused := Refused + 1;
            end if;

            Opt.Release (Item);
         end;
      end loop;

      Assert (Answered = 4_000,
              "only" & Natural'Image (Answered)
              & " of four thousand command lines were answered");

      --  Answered both ways, and neither side thin. Four thousand vectors
      --  that were all refused would satisfy the count above while never
      --  once carrying the parser through a command line it accepts, and a
      --  generator drifting to either extreme would leave half of what this
      --  covers uncovered without failing.
      Assert (Accepted > 200,
              "only" & Natural'Image (Accepted)
              & " generated command lines parsed, so the accepting path was "
              & "barely walked");
      Assert (Refused > 200,
              "only" & Natural'Image (Refused)
              & " generated command lines were refused, so the refusing path "
              & "was barely walked");
   end Any_Command_Line_Is_Answered;

   --  Interactive's input policy: what each line does to the turn.
   --
   --  The loop that reads lines needs a terminal on both descriptors and no
   --  test drives it, so for a long time nothing tested any of what it
   --  decides -- which is how a command word came to be compared with its
   --  argument still attached and went unnoticed. The deciding is now a unit
   --  of its own, and this is it: accumulation, the blank line that submits,
   --  the bound on a turn, and the rule that a slash is only a command when
   --  nothing is pending.
   procedure Interactive_Holds_A_Turn
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package I renames Model_Runner.CLI.Interactive;
      use type I.Line_Effect;

      Typing : I.Turn;
      Ready  : Boolean;
      Effect : I.Line_Effect;

      --  Offer a line and assert what it did.
      procedure Offer (Line : String; Expected : I.Line_Effect) is
      begin
         I.Offer (Typing, Line, Effect);
         Assert (Effect = Expected,
                 "'" & Line & "' was "
                 & I.Line_Effect'Image (Effect) & ", not "
                 & I.Line_Effect'Image (Expected));
      end Offer;
   begin
      I.Open (Typing, Ready);
      Assert (Ready, "a turn did not open");
      Assert (I.Pending (Typing) = "", "a fresh turn holds text");

      --  Lines accumulate, separated by line feeds, so a pasted paragraph
      --  reaches the model as the paragraph it was.
      Offer ("first", I.Held);
      Assert (I.Pending (Typing) = "first",
              "the first line was not held: " & I.Pending (Typing));
      Offer ("second", I.Held);
      Assert (I.Pending (Typing) = "first" & ASCII.LF & "second",
              "lines were not separated by a line feed: "
              & I.Pending (Typing));

      --  A slash on a later line is text. Someone typing a path, or a
      --  fraction, means the path: reading it as a command would throw away
      --  the half they had already typed.
      Offer ("/exit", I.Held);
      Assert (I.Pending (Typing)
              = "first" & ASCII.LF & "second" & ASCII.LF & "/exit",
              "a slash inside a turn was taken for a command");

      --  A blank line submits. What was accumulated is still there for the
      --  caller to take, and taking it empties the turn.
      Offer ("", I.Submits);
      Assert (I.Pending (Typing)
              = "first" & ASCII.LF & "second" & ASCII.LF & "/exit",
              "submitting lost the turn");
      I.Taken (Typing);
      Assert (I.Pending (Typing) = "", "the turn was not emptied");

      --  A line of nothing but spaces is blank. An empty submission is the
      --  caller's business, and it sees an empty turn.
      Offer ("   ", I.Submits);
      Assert (I.Pending (Typing) = "", "spaces were accumulated");

      --  A command, only because nothing is pending.
      Offer ("/exit", I.Is_Command);
      Assert (I.Pending (Typing) = "",
              "a command was accumulated as well as recognized");
      Offer ("/system be brief", I.Is_Command);
      Offer ("/nonsense", I.Is_Command);

      --  The bound. A turn that would pass Max_Turn_Bytes is refused, and
      --  what was pending goes with it: a turn that kept the part that fit
      --  would send the model half a sentence.
      declare
         Half : constant String (1 .. I.Max_Turn_Bytes / 2 + 1) :=
           [others => 'x'];
      begin
         Offer (Half, I.Held);
         Assert (I.Pending (Typing)'Length = Half'Length,
                 "the first half was not held");
         Offer (Half, I.Too_Long);
         Assert (I.Pending (Typing) = "",
                 "a refused turn kept the part that fit");
      end;

      --  Exactly the bound fits, and one byte more does not.
      I.Taken (Typing);
      declare
         Full : constant String (1 .. I.Max_Turn_Bytes) := [others => 'y'];
      begin
         Offer (Full, I.Held);
         Assert (I.Pending (Typing)'Length = I.Max_Turn_Bytes,
                 "a turn of exactly the bound was refused");
         Offer ("z", I.Too_Long);
      end;

      --  And the separator counts against the bound. One byte short of it,
      --  plus one byte, is one byte over once the line feed between them is
      --  written -- and the byte that does not fit is written past the end
      --  of the buffer, not merely dropped. Checking the bound without the
      --  separator passes every case above and overruns here.
      I.Taken (Typing);
      declare
         Nearly : constant String (1 .. I.Max_Turn_Bytes - 1) :=
           [others => 'w'];
      begin
         Offer (Nearly, I.Held);
         Assert (I.Pending (Typing)'Length = I.Max_Turn_Bytes - 1,
                 "one short of the bound was refused");
         Offer ("z", I.Too_Long);
         Assert (I.Pending (Typing) = "",
                 "a refused turn kept the part that fit");
      end;

      I.Close (Typing);
      I.Close (Typing);
      Assert (I.Pending (Typing) = "", "a closed turn holds text");
   end Interactive_Holds_A_Turn;

   --  The interactive loop runs.
   --
   --  Nothing drove it for as long as it existed. The driver refuses
   --  interactive mode unless both descriptors are terminals, so the loop
   --  could only be reached by hand -- and everything it decides went
   --  untested, which is how a command word came to be compared with its
   --  argument still attached, and how a turn buffer that was never
   --  allocated compiled and passed.
   --
   --  Run reads Current_Input, so a test can hand it a file. The terminal
   --  requirement is the driver's and stays where it is.
   --
   --  Generated text is not what is checked here. It goes to standard output
   --  as raw bytes on purpose, past Text_IO and past any redirection this
   --  process can perform, and the tests that check what a model produces
   --  inject a sink of their own. What is checked is the loop: /stats says
   --  whether a turn has completed, so asking it is how a test finds out
   --  whether the loop took a turn, without asking to see the turn.
   procedure Interactive_Loop_Runs
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package I renames Model_Runner.CLI.Interactive;
      package Pres renames Model_Runner.Presentation;
      use Ada.Text_IO;

      Input  : constant String := "obj/interactive-in.txt";
      Errors : constant String := "obj/interactive-err.txt";

      Image   : B.Byte_Array_Access;
      Catalog : aliased Model_Runner.Localization.Catalog;

      --  Run the loop over Lines and return what reached standard error.
      function Conversed (Lines : String) return String is
         Held    : aliased constant B.Byte_Array := Image.all;
         Rig     : Harness (Held'Access);
         Session : L.Session;
         Screen  : aliased Pres.Console;
         Options : Opt.Command;
         Handle  : File_Type;
         Status  : Natural := 0;
         Outcome : E.Error_Info;
      begin
         Create (Handle, Out_File, Input);
         Put (Handle, Lines);
         Close (Handle);

         Start (Rig);
         L.Open (Session, Rig.Ready, Status => Outcome);
         Assert (E.Is_Ok (Outcome), "the session did not open");

         Pres.Open
           (Screen, Catalog'Unchecked_Access, Opt.Color_Never,
            (Output_Is_Terminal => False,
             Error_Is_Terminal  => False,
             Input_Is_Terminal  => False,
             Colour_Suppressed  => True),
            Opt.Normal);

         Options.Max_Tokens := 2;
         Options.Sampling.Temperature := 0.0;

         --  Statistics after every turn, so that a completed turn leaves a
         --  mark on standard error whether or not anything asks for one.
         Options.Show_Stats := True;

         declare
            From, Err : File_Type;
         begin
            Open (From, In_File, Input);
            Create (Err, Out_File, Errors);
            Set_Input (From);
            Set_Error (Err);

            Captured_Output.Open ("obj/loop-answers.txt");
            begin
               I.Run (Options, Screen, Rig.Ready, Session, null, Status => Status);
            exception
               when others =>
                  declare
                     Ignored : constant String := Captured_Output.Close;
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
                  Set_Input (Standard_Input);
                  Set_Error (Standard_Error);
                  Close (From);
                  Close (Err);
                  raise;
            end;

            declare
               Ignored : constant String := Captured_Output.Close;
               pragma Unreferenced (Ignored);
            begin
               null;
            end;

            Set_Input (Standard_Input);
            Set_Error (Standard_Error);
            Close (From);
            Close (Err);
         end;

         Assert (Status = 0,
                 "the loop reported a failing status:"
                 & Natural'Image (Status));

         L.Close (Session);
         L.Close (Rig.Ready, Outcome);
         Containers.Close (Rig.Parsed);

         return Text_Of (Errors);
      end Conversed;

      --  Whether the loop said no turn had completed. Read from the catalog
      --  rather than written out, so that the test is about the loop and not
      --  about the English for it.
      function Took_A_Turn (Lines : String) return Boolean is
         Said : constant String := Conversed (Lines);
         None : constant String :=
           Model_Runner.Localization.Text (Catalog, "cli.interactive.no_stats");
      begin
         Assert (Project_Tools.Text.Contains
                   (Said,
                    Model_Runner.Localization.Text
                      (Catalog, "cli.interactive.banner")),
                 "the loop did not start");
         return not Project_Tools.Text.Contains (Said, None);
      end Took_A_Turn;
   begin
      --  Room for a turn to complete: the default context is sixteen tokens,
      --  which the rendered conversation alone exceeds.
      Tiny_Model.Build (Image, Room => 256);
      Model_Runner.Localization.Open
        (Catalog, Model_Runner.Platform.Catalog_Path, "en");

      --  Asked before anything has run, the loop says no turn has completed.
      --  This is the control: without it every assertion below would be
      --  satisfied by a loop that never printed the note at all.
      Assert (not Took_A_Turn ("/stats" & ASCII.LF & "/exit" & ASCII.LF),
              "a session that ran nothing claimed a completed turn");

      --  A line, a blank line to submit it, and a turn has completed.
      Assert (Took_A_Turn ("hello" & ASCII.LF & ASCII.LF & "/stats"
                           & ASCII.LF & "/exit" & ASCII.LF),
              "a submitted turn did not complete");

      --  A slash on the second line of a turn is text. If it were read as a
      --  command the loop would have left at it, and nothing after would
      --  run -- so a completed turn here is the whole assertion.
      Assert (Took_A_Turn ("first" & ASCII.LF & "/exit" & ASCII.LF & ASCII.LF
                           & "/stats" & ASCII.LF & "/exit" & ASCII.LF),
              "a slash inside a turn ended the session");

      --  A command is not a prompt: /settings runs and no turn completes.
      Assert (not Took_A_Turn ("/settings" & ASCII.LF & "/stats" & ASCII.LF
                               & "/exit" & ASCII.LF),
              "a command was taken for a prompt");

      --  And /settings prints the figures it claims to. Ten fields in the
      --  column the rest of the program uses, and nothing had read them.
      declare
         Said   : constant String :=
           Conversed ("/settings" & ASCII.LF & "/exit" & ASCII.LF);
         Shown  : Natural := 0;
      begin
         for Which in 1 .. 5 loop
            declare
               Key : constant String :=
                 (case Which is
                    when 1 => "cli.interactive.setting.temperature",
                    when 2 => "cli.interactive.setting.top_k",
                    when 3 => "cli.interactive.setting.top_p",
                    when 4 => "cli.interactive.setting.repeat_penalty",
                    when others => "cli.interactive.setting.max_tokens");
               Label : constant String :=
                 Model_Runner.Localization.Text (Catalog, Key);
            begin
               if Project_Tools.Text.Contains (Said, Label) then
                  Shown := Shown + 1;
               end if;
            end;
         end loop;

         Assert (Shown = 5,
                 "the settings screen showed" & Natural'Image (Shown)
                 & " of 5 figures");
      end;

      --  End of file submits what is pending rather than dropping it. No
      --  /stats can be asked afterwards, so this reads the statistics the
      --  turn itself printed.
      declare
         Marker : constant String :=
           Model_Runner.Localization.Text
             (Catalog, "statistics.generated_tokens");
      begin
         Assert (Project_Tools.Text.Contains
                   (Conversed ("hello" & ASCII.LF), Marker),
                 "a turn left pending at end of file was dropped");
         Assert (not Project_Tools.Text.Contains
                       (Conversed ("/exit" & ASCII.LF), Marker),
                 "leaving immediately still ran a turn");
      end;
   end Interactive_Loop_Runs;

   --  Interactive reads a line of input as the command it is.
   --
   --  The loop needs a terminal at both ends and no test drives it, so what
   --  it does with a line is separated from the reading of one. This is the
   --  reading.
   --
   --  It exists because /system was matched as the eight characters
   --  "/system " -- with the space -- so a bare /system was not a command
   --  missing its text but an unknown command, and the one thing a session
   --  could not do was go back to having no system message at all. --system
   --  sets one before the first turn and /system TEXT replaces it; nothing
   --  removed it, although the layer underneath has always removed it when
   --  handed an empty string.
   procedure Interactive_Reads_Its_Commands
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package I renames Model_Runner.CLI.Interactive;
      use type I.Command_Kind;

      --  Assert a line parses to a kind, and to an argument or to none.
      procedure Reads
        (Line     : String;
         Kind     : I.Command_Kind;
         Argument : String := "")
      is
         Got : constant I.Parsed_Command := I.Parse (Line);
      begin
         Assert (Got.Kind = Kind,
                 "'" & Line & "' read as "
                 & I.Command_Kind'Image (Got.Kind) & ", not "
                 & I.Command_Kind'Image (Kind));

         if Argument = "" then
            Assert (Got.First = 0 and then Got.Last = 0,
                    "'" & Line & "' found an argument where there is none");
         else
            Assert (Got.First /= 0 and then Got.Last >= Got.First,
                    "'" & Line & "' found no argument");
            Assert (Line (Got.First .. Got.Last) = Argument,
                    "'" & Line & "' read the argument as '"
                    & Line (Got.First .. Got.Last) & "'");
         end if;
      end Reads;
   begin
      --  Ordinary text is not a command, and neither is a bare slash in the
      --  middle of a sentence.
      Reads ("", I.Not_A_Command);
      Reads ("hello", I.Not_A_Command);
      Reads ("what is 3/4 of 8?", I.Not_A_Command);

      --  Every command word.
      Reads ("/exit", I.Leave);
      Reads ("/reset", I.Reset);
      Reads ("/help", I.Help);
      Reads ("/settings", I.Settings);
      Reads ("/stats", I.Statistics);
      Reads ("/context", I.Context);

      --  A command word this build does not know is refused, not guessed at.
      --  A prefix of a real one is not the real one.
      Reads ("/nonsense", I.Unknown);
      Reads ("/sys", I.Unknown);
      Reads ("/systematic", I.Unknown);
      Reads ("/", I.Unknown);

      --  The system message, with text and without.
      Reads ("/system be brief", I.Set_System, "be brief");
      Reads ("/system    padded   ", I.Set_System, "padded");
      Reads ("/system be brief. use 3/4 of the words", I.Set_System,
             "be brief. use 3/4 of the words");
      Reads ("/system", I.Set_System);
      Reads ("/system ", I.Set_System);
      Reads ("/system      ", I.Set_System);

      --  What the empty argument then means, at the layer that acts on it.
      --  Reading the command and carrying out the removal are two things and
      --  this test owns only the first, so it checks the second is there to
      --  be reached: an empty system message removes it.
      declare
         package C renames Model_Runner.Conversation;
         Messages : C.History;
         Status   : E.Error_Info;
      begin
         C.Open (Messages, Status => Status);
         C.Set_System (Messages, "be brief", Status);
         Assert (C.Has_System (Messages), "the system message was not set");
         C.Set_System (Messages, "", Status);
         Assert (E.Is_Ok (Status), "removing the system message was refused");
         Assert (not C.Has_System (Messages),
                 "an empty system message did not remove it, so a bare "
                 & "/system would set a blank one");
         C.Close (Messages);
      end;
   end Interactive_Reads_Its_Commands;

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
              (Under.Ready, Session, Prompt, Request, Stop, null,
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
           (Unprepared, Session, "ab", Request, Stop, null,
            null, null, null, null, null, Outcome => Outcome);

         Assert (Outcome.Error.Code = E.Lifecycle_Model_Not_Ready,
                 "generating from an unprepared model was accepted: "
                 & E.Error_Code'Image (Outcome.Error.Code));

         Gen.Release (Outcome);
         Model_Runner.Stops.Close (Stop);
         L.Close (Unprepared, Status);
      end;
   end Caller_Refusals_Report_Themselves;

   --  A system message read from a file, and what it can be wrong about.
   --
   --  Two ways a system message arrives and only one was exercised. The
   --  file is the one this program recommends -- a value on a command line
   --  may be visible to other local processes, which the help says outright
   --  -- and it is the one that had no test: --system-file appeared once in
   --  the whole suite, in the list asserting that it is on the help screen.
   --
   --  The refusals are the same shapes a prompt file has and they are not
   --  the same code path, so a missing file, a directory and text that is
   --  not UTF-8 are each asked for by name here as well.
   procedure System_File_Is_Read_And_Refused
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model  : constant String := "obj/sysfile-model.gguf";
      Log    : constant String := "obj/sysfile-errors.txt";

      --  Run with a system file and return what reached standard error.
      function Diagnostics (Path : String) return String is
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--system-file");
         Add (Source, Path);
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Add (Source, "--temperature");
         Add (Source, "0");

         Create (Handle, Out_File, Log);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         return Text_Of (Log);
      end Diagnostics;

      function Contains (Text, Word : String) return Boolean
      is (Project_Tools.Text.Contains (Text, Word));
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  A sound file is read and the run goes through. The message itself
      --  reaches the template, which the conversation tests hold; what this
      --  says is that the file was opened, read and accepted.
      declare
         Good   : constant String := "obj/sysfile-good.txt";
         Handle : File_Type;
      begin
         Create (Handle, Out_File, Good);
         Put (Handle, "be brief");
         Close (Handle);

         declare
            Said : constant String := Diagnostics (Good);
         begin
            Assert (not Contains (Said, "MR-"),
                    "a sound system file was refused: " & Said);
         end;
      end;

      --  A path that is not there.
      declare
         Said : constant String :=
           Diagnostics ("obj/no-such-system-file-xyzzy");
      begin
         Assert (Contains (Said, "MR-IO-0001"),
                 "a missing system file was not reported as missing: "
                 & Said);
      end;

      --  A path that is a directory.
      declare
         Said : constant String := Diagnostics ("obj");
      begin
         Assert (Contains (Said, "MR-IO-0005"),
                 "a directory given as a system file was not reported as "
                 & "one: " & Said);
      end;

      --  A file that is not text.
      declare
         Bad    : constant String := "obj/sysfile-bad.txt";
         Handle : Ada.Streams.Stream_IO.File_Type;
      begin
         Ada.Streams.Stream_IO.Create
           (Handle, Ada.Streams.Stream_IO.Out_File, Bad);
         Ada.Streams.Stream_IO.Write
           (Handle,
            Ada.Streams.Stream_Element_Array'
              (1 => 16#C4#, 2 => 16#C4#, 3 => 16#41#));
         Ada.Streams.Stream_IO.Close (Handle);

         declare
            Said : constant String := Diagnostics (Bad);
         begin
            Assert (Contains (Said, "MR-IO-0006"),
                    "a system file that is not UTF-8 was not reported as "
                    & "one: " & Said);
         end;
      end;
   end System_File_Is_Read_And_Refused;

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
            Ran (Source, Status);
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
           (Under.Ready, Session, "ab", Request, Stop, null,
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
           (Under.Ready, Session, "ab", Request, Stop, null,
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
                 (Under.Ready, Session, "ab", Request, Stop, null,
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
         Ran (Source, Status);
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
            Ran (Source, Status);
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

      --  Anything an earlier run of this test left behind, taken away before
      --  the listing is taken. The comparison is between two listings, so a
      --  file left by a run that failed part way through makes the next run
      --  fail for a reason that has nothing to do with what it checks --
      --  which happened while this was being written.
      declare
         type Name_Access is access constant String;

         Leftovers : constant array (1 .. 5) of Name_Access :=
           [new String'("obj/privacy-prompt.txt"),
            new String'("obj/privacy-system.txt"),
            new String'("obj/privacy-in.txt"),
            new String'("obj/privacy-interactive.txt"),
            new String'("obj/privacy-answers.txt")];
      begin
         for Each of Leftovers loop
            if Ada.Directories.Exists (Each.all) then
               Ada.Directories.Delete_File (Each.all);
            end if;
         end loop;
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

      --  A prompt and a system message that arrived through files rather
      --  than the command line. The program recommends the file, because a
      --  value on a command line may be visible to other local processes, so
      --  the recommended way is the one that must not be echoed either -- and
      --  it had never been asked, the runs above both giving their text
      --  inline.
      declare
         Prompt_At : constant String := "obj/privacy-prompt.txt";
         System_At : constant String := "obj/privacy-system.txt";
         Handle    : File_Type;
         Source    : Fixed_Arguments;
      begin
         Create (Handle, Out_File, Prompt_At);
         Put (Handle, Prompt);
         Close (Handle);

         Create (Handle, Out_File, System_At);
         Put (Handle, System);
         Close (Handle);

         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--prompt-file");
         Add (Source, Prompt_At);
         Add (Source, "--system-file");
         Add (Source, System_At);
         Add (Source, "--max-tokens");
         Add (Source, "2");
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, "--verbose");

         declare
            Text : constant String := Diagnostics (Source);
         begin
            Assert (Text'Length > 0, "the run said nothing at all");
            Assert (not Contains (Text, Prompt),
                    "a prompt read from a file appeared in the diagnostics: "
                    & Text);
            Assert (not Contains (Text, System),
                    "a system message read from a file appeared in the "
                    & "diagnostics: " & Text);
         end;

         Ada.Directories.Delete_File (Prompt_At);
         Ada.Directories.Delete_File (System_At);
      end;

      --  And a conversation, which is the case the constraint is really
      --  about: a session holds every turn and renders them all again each
      --  time, so a diagnostic that echoed what it was given would leak the
      --  whole conversation rather than one prompt. Nothing had driven this
      --  path -- the two runs above are single-shot.
      declare
         Input   : constant String := "obj/privacy-in.txt";
         Log     : constant String := "obj/privacy-interactive.txt";
         Script  : File_Type;
         Image   : B.Byte_Array_Access;
      begin
         Create (Script, Out_File, Input);
         Put_Line (Script, Prompt);
         Put_Line (Script, "");
         Put_Line (Script, "/system " & System);
         Put_Line (Script, Prompt);
         Put_Line (Script, "");
         Put_Line (Script, "/context");
         Put_Line (Script, "/stats");
         Put_Line (Script, "/exit");
         Close (Script);

         Tiny_Model.Build (Image, Room => 256);

         declare
            Held    : aliased constant B.Byte_Array := Image.all;
            Rig     : Harness (Held'Access);
            Session : L.Session;
            Catalog : aliased Model_Runner.Localization.Catalog;
            Screen  : aliased Model_Runner.Presentation.Console;
            Options : Opt.Command;
            From    : File_Type;
            Err     : File_Type;
            Status  : Natural := 0;
            Outcome : E.Error_Info;
         begin
            Start (Rig, Model_Runner.Backend.Backend_Reference);
            L.Open (Session, Rig.Ready, Status => Outcome);
            Assert (E.Is_Ok (Outcome), "the session did not open");

            Model_Runner.Localization.Open
              (Catalog, Model_Runner.Platform.Catalog_Path, "en");
            Model_Runner.Presentation.Open
              (Screen, Catalog'Unchecked_Access, Opt.Color_Never,
               (Output_Is_Terminal => False,
                Error_Is_Terminal  => False,
                Input_Is_Terminal  => False,
                Colour_Suppressed  => True),
               Opt.Verbose);

            Options.Max_Tokens := 2;
            Options.Sampling.Temperature := 0.0;
            Options.Level := Opt.Verbose;
            Options.Show_Stats := True;

            Open (From, In_File, Input);
            Create (Err, Out_File, Log);
            Set_Input (From);
            Set_Error (Err);
            Captured_Output.Open ("obj/privacy-answers.txt");
            begin
               Model_Runner.CLI.Interactive.Run
                 (Options, Screen, Rig.Ready, Session, null, Status => Status);
            exception
               when others =>
                  declare
                     Ignored : constant String := Captured_Output.Close;
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
                  Set_Input (Standard_Input);
                  Set_Error (Standard_Error);
                  Close (From);
                  Close (Err);
                  raise;
            end;

            declare
               Ignored : constant String := Captured_Output.Close;
               pragma Unreferenced (Ignored);
            begin
               null;
            end;
            Set_Input (Standard_Input);
            Set_Error (Standard_Error);
            Close (From);
            Close (Err);

            declare
               Said : constant String := Text_Of (Log);
            begin
               Assert (Said'Length > 0,
                       "a verbose conversation said nothing at all");
               Assert (not Contains (Said, Prompt),
                       "a turn appeared in the conversation's diagnostics: "
                       & Said);
               Assert (not Contains (Said, System),
                       "the system message appeared in the conversation's "
                       & "diagnostics: " & Said);
            end;

            L.Close (Session);
            Model_Runner.Localization.Close (Catalog);
         end;

         B.Free (Image);

         --  Everything this block made, taken away again: the listing below
         --  compares obj before and after, and a test that leaves its own
         --  working files behind fails the assertion it exists to make.
         Ada.Directories.Delete_File (Input);
         Ada.Directories.Delete_File (Log);
         Ada.Directories.Delete_File ("obj/privacy-answers.txt");
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
               Ran (Source, Status);
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

   -------------------------------
   -- Styling_Follows_Its_Stream --
   -------------------------------

   --  A line is coloured according to the stream it is going to.
   --
   --  Every styling decision asked whether standard error was a terminal,
   --  whatever stream the line was for. That was invisible while only the
   --  error stream carried anything worth colouring. The moment the
   --  inspection report moved to standard output it became
   --  `inspect MODEL > report.txt` writing thirty-five escape sequences into
   --  the file, because a terminal was still attached to standard error --
   --  which is what redirecting one stream and not the other means.
   --
   --  No test could have seen it: every console in this suite is opened
   --  Color_Never with both terminal flags False, so the styling policy was
   --  exercised only in the arrangement where nothing is styled. This one
   --  states the two arrangements that matter and reads the bytes.

   procedure Styling_Follows_Its_Stream
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Out_Path : constant String := "obj/styling-out.txt";
      Err_Path : constant String := "obj/styling-err.txt";

      --  Write one heading and one field to each stream, with the terminals
      --  arranged as the caller says.
      procedure Wrote
        (Answer_Is_Terminal : Boolean;
         Error_Is_Terminal  : Boolean;
         Mode               : Opt.Color_Mode := Opt.Color_Auto;
         Suppressed         : Boolean := False)
      is
         Catalog : aliased Model_Runner.Localization.Catalog;
         Screen  : Model_Runner.Presentation.Console;
         Answer, Errors : File_Type;
      begin
         Model_Runner.Localization.Open
           (Catalog, Model_Runner.Platform.Catalog_Path, "en");

         Model_Runner.Presentation.Open
           (Screen, Catalog'Unchecked_Access, Mode,
            (Output_Is_Terminal => Answer_Is_Terminal,
             Error_Is_Terminal  => Error_Is_Terminal,
             Input_Is_Terminal  => False,
             Colour_Suppressed  => Suppressed),
            Opt.Normal);

         Create (Answer, Out_File, Out_Path);
         Create (Errors, Out_File, Err_Path);
         Set_Output (Answer);
         Set_Error (Errors);
         begin
            Model_Runner.Presentation.Put_Heading
              (Screen, "cli.inspect.heading.execution",
               Model_Runner.Presentation.Answer);
            Model_Runner.Presentation.Put_Field
              (Screen, "cli.inspect.label.backend", "cpu",
               Model_Runner.Presentation.Answer);
            Model_Runner.Presentation.Put_Heading
              (Screen, "statistics.heading",
               Model_Runner.Presentation.Diagnostic);
            Model_Runner.Presentation.Put_Field
              (Screen, "statistics.backend", "cpu",
               Model_Runner.Presentation.Diagnostic);
         exception
            when others =>
               Set_Output (Standard_Output);
               Set_Error (Standard_Error);
               Close (Answer);
               Close (Errors);
               Model_Runner.Localization.Close (Catalog);
               raise;
         end;
         Set_Output (Standard_Output);
         Set_Error (Standard_Error);
         Close (Answer);
         Close (Errors);
         Model_Runner.Localization.Close (Catalog);
      end Wrote;

      --  Report whether text carries an escape sequence.
      function Coloured (Text : String) return Boolean is
      begin
         for Index in Text'Range loop
            if Text (Index) = ASCII.ESC then
               return True;
            end if;
         end loop;
         return False;
      end Coloured;

      function Answered return String
      is (Text_Of (Out_Path));

      function Complained return String
      is (Text_Of (Err_Path));
   begin
      --  A report on a terminal, with the diagnostics redirected. This is
      --  the arrangement that was wrong the other way round.
      Wrote (Answer_Is_Terminal => True, Error_Is_Terminal => False);
      Assert (Coloured (Answered),
              "a report going to a terminal was not styled");
      Assert (not Coloured (Complained),
              "a diagnostic going to a file carried escape sequences");

      --  And the arrangement a redirected report makes: the terminal is
      --  still on standard error, and nothing may follow it to the file.
      Wrote (Answer_Is_Terminal => False, Error_Is_Terminal => True);
      Assert (not Coloured (Answered),
              "a report going to a file carried escape sequences");
      Assert (Coloured (Complained),
              "a diagnostic going to a terminal was not styled");

      --  And the three modes are three. --color always wrote nothing
      --  whenever the destination was not a terminal, which is the only
      --  arrangement in which it differs from auto: the decision was made
      --  here and then made again by Terminal_Styles, whose own policy
      --  defaults to auto and judges auto by standard output.
      Wrote (Answer_Is_Terminal => False, Error_Is_Terminal => False,
             Mode => Opt.Color_Always);
      Assert (Coloured (Answered) and then Coloured (Complained),
              "--color always wrote no colour to a stream that is not a "
              & "terminal, which is the only thing it is for");

      Wrote (Answer_Is_Terminal => True, Error_Is_Terminal => True,
             Mode => Opt.Color_Never);
      Assert (not Coloured (Answered) and then not Coloured (Complained),
              "--color never wrote colour to a terminal");

      --  NO_COLOR is honoured by auto and overridden by an explicit always,
      --  which is what asking for it means.
      Wrote (Answer_Is_Terminal => True, Error_Is_Terminal => True,
             Mode => Opt.Color_Auto, Suppressed => True);
      Assert (not Coloured (Answered) and then not Coloured (Complained),
              "a suppressed colour setting was ignored under auto");

      Wrote (Answer_Is_Terminal => True, Error_Is_Terminal => True,
             Mode => Opt.Color_Always, Suppressed => True);
      Assert (Coloured (Answered) and then Coloured (Complained),
              "an explicit --color always was overridden by NO_COLOR");
   end Styling_Follows_Its_Stream;

   ----------------------------
   -- Streams_Are_Separate --
   ----------------------------

   --  Each kind of output leaves by the stream the README says it does.
   --
   --  Every test that reads what a command wrote redirected both streams
   --  into one file, so no test could tell them apart, and the table of five
   --  claims about where output goes was checked by nothing. The whole
   --  inspection report went to standard error for as long as there was one:
   --  inspect MODEL > report.txt wrote an empty file, and the transcript
   --  test compared the report against the README without noticing, because
   --  it had merged the streams before it looked.
   --
   --  The generated text is not asserted here. It leaves through the output
   --  sink rather than the text streams, so redirecting those does not see
   --  it -- which is the same reason the transcript test leaves it out. What
   --  is asserted is the part that redirecting an answer must not collect.

   procedure Streams_Are_Separate
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model : constant String := "obj/streams-model.gguf";
      Out_Path : constant String := "obj/streams-out.txt";
      Err_Path : constant String := "obj/streams-err.txt";

      --  Run one command with the two streams kept apart.
      procedure Ran (Source : in out Fixed_Arguments) is
         Answer, Errors : File_Type;
         Status         : Natural;
      begin
         Create (Answer, Out_File, Out_Path);
         Create (Errors, Out_File, Err_Path);
         Set_Output (Answer);
         Set_Error (Errors);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Output (Standard_Output);
               Set_Error (Standard_Error);
               Close (Answer);
               Close (Errors);
               raise;
         end;
         Set_Output (Standard_Output);
         Set_Error (Standard_Error);
         Close (Answer);
         Close (Errors);
      end Ran;

      function Answered return String
      is (Text_Of (Out_Path));

      function Complained return String
      is (Text_Of (Err_Path));

      function Holds (Text, Token : String) return Boolean
      is (Project_Tools.Text.Contains (Text, Token));

      --  Report whether a stream carried nothing.
      --
      --  Not the empty string: closing a text file that was made current
      --  leaves one line terminator behind whether or not anything was
      --  written to it, which is an artefact of capturing the stream this
      --  way rather than of the program. The same commands run as a program
      --  write zero bytes to standard error. Anything else is output.
      function Silent (Text : String) return Boolean is
      begin
         for Index in Text'Range loop
            if Text (Index) not in ASCII.LF | ASCII.CR then
               return False;
            end if;
         end loop;
         return True;
      end Silent;
   begin
      Tiny_Model.Write (Model, Room => 256);

      --  version and help are answers.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "version");
         Ran (Source);
         Assert (Holds (Answered, "model_runner"),
                 "version wrote nothing to standard output");
         Assert (Silent (Complained),
                 "version wrote to standard error: " & Complained);
      end;

      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "help");
         Ran (Source);
         Assert (Answered /= "", "help wrote nothing to standard output");
         Assert (Silent (Complained),
                 "help wrote to standard error: " & Complained);
      end;

      --  An inspection is an answer, all of it. This is the one that was
      --  wrong: a caller redirecting it collected an empty file.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "inspect");
         Add (Source, Model);
         Ran (Source);
         Assert (Holds (Answered, "Container")
                   and then Holds (Answered, "Execution"),
                 "the inspection report did not reach standard output");
         Assert (Silent (Complained),
                 "inspect wrote to standard error: " & Complained);
      end;

      --  Statistics are not an answer, so redirecting one does not collect
      --  them.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "2");
         Add (Source, "--show-stats");
         Ran (Source);
         Assert (not Holds (Answered, "Statistics"),
                 "the statistics reached standard output, where the "
                 & "generated text is: " & Answered);
         Assert (Holds (Complained, "Statistics"),
                 "the statistics did not reach standard error");
      end;

      --  Neither is a diagnostic.
      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "inspect");
         Add (Source, "obj/streams-absent.gguf");
         Ran (Source);
         Assert (Silent (Answered),
                 "a diagnostic reached standard output: " & Answered);
         Assert (not Silent (Complained),
                 "a failing command wrote no diagnostic");
      end;
   end Streams_Are_Separate;

   ------------------------------------
   -- Runs_Report_Which_Backend_Ran --
   ------------------------------------

   --  Both commands say which backend answers and how many workers it has.
   --
   --  Two backends produce the same logits and differ by about forty times in
   --  wall clock, so which one ran is the first thing anyone reading a
   --  timing needs to know, and it used to be knowable only by remembering
   --  what was typed. Neither figure is read back off the command line:
   --  --backend reference takes one worker whatever --threads asked for, and
   --  a report that repeated the request rather than the outcome would be
   --  worth nothing exactly when it mattered.
   --
   --  inspect answers for the run that would happen and statistics for the
   --  run that did, so both are asked here; when the worker choice lived in
   --  one of them they could have disagreed.

   ---------------------------------------------
   -- A_Busy_Machine_Cannot_Publish_A_Figure --
   ---------------------------------------------

   --  `tests benchmark` refuses a figure taken on a busy machine.
   --
   --  The tool compares a device against a processor, and the two sides are
   --  not equally exposed to whatever else is running: the processor side
   --  competes with it and the device side mostly waits on a fence. So other
   --  work moves the ratio, and a ratio that moves with the machine is a
   --  figure about the machine. Every other guard here refuses rather than
   --  warns, and this one now does too.
   --
   --  The bound is checked through Publishable rather than by running the
   --  tool, because the suite cannot arrange for a busy machine: to see the
   --  refusal it would have to load the host, and a test that loads the host
   --  is a test that spoils every timing taken beside it.
   --
   --  Zero is the case worth naming. It is what the reader returns where the
   --  host keeps no load average, so it means unknown -- and unknown has to
   --  measure, or the tool would refuse to run everywhere that number is
   --  absent.
   procedure A_Busy_Machine_Cannot_Publish_A_Figure
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
   begin
      Assert (Host_Load.Publishable (0.0),
              "a host that keeps no load average was refused a figure, "
              & "which refuses every host that keeps none");
      Assert (Host_Load.Publishable (0.2),
              "a quiet machine was refused a figure");
      Assert (Host_Load.Publishable (Host_Load.Too_Busy),
              "the bound itself was refused, so the bound is not the bound");
      Assert (not Host_Load.Publishable (Host_Load.Too_Busy + 0.01),
              "a load above the bound was allowed to publish a figure");
      Assert (not Host_Load.Publishable (8.0),
              "a machine at a load of eight was allowed to publish a "
              & "figure");
   end A_Busy_Machine_Cannot_Publish_A_Figure;

   -----------------------------------------
   -- The_Speed_Tool_Reads_The_Machine --
   -----------------------------------------

   --  The load a figure carries is the load the host reports.
   --
   --  It is read where the host keeps it and falls back to zero where there
   --  is no such place -- and a zero reads as a quiet machine to anybody
   --  looking at a published figure. So on a host that does have one, a zero
   --  is a fault and this says so; on a host that does not, the fallback is
   --  what is checked instead.
   --
   --  Compared against the file rather than against a constant, because the
   --  load is whatever it is: what can be held is that the tool read the
   --  same thing this test can read a moment later, within how far a
   --  one-minute average moves in a moment.
   procedure The_Speed_Tool_Reads_The_Machine
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Report : Speed_Run.Report;

      Where : constant String := "/proc/loadavg";

      --  What the host says, now.
      function Said return Long_Float is
         Handle : File_Type;
      begin
         Open (Handle, In_File, Where);

         declare
            Line : constant String := Get_Line (Handle);
            Stop : Natural := Line'First;
         begin
            Close (Handle);
            while Stop <= Line'Last and then Line (Stop) /= ' ' loop
               Stop := Stop + 1;
            end loop;
            return Long_Float'Value (Line (Line'First .. Stop - 1));
         end;
      exception
         when others =>
            if Is_Open (Handle) then
               Close (Handle);
            end if;
            return -1.0;
      end Said;
   begin
      --  A run with no model measures nothing and still reads the machine,
      --  which is what makes this cheap.
      Speed_Run.Run
        (Path        => "",
         Prompt_Path => "",
         Tokens      => 1,
         Threads     => 1,
         Batch       => 1,
         Repack      => Model_Runner.Llama.No_Repack,
         Repeats     => 1,
         Result      => Report);

      if Ada.Directories.Exists (Where) then
         declare
            Now : constant Long_Float := Said;
         begin
            Assert (Now >= 0.0,
                    "this host keeps a load average and the test could not "
                    & "read it");
            Assert (Report.Load_Before > 0.0,
                    "the tool reported a load of zero on a host that keeps "
                    & "one, which reads as a quiet machine to anybody "
                    & "looking at a figure");
            Assert (abs (Report.Load_Before - Now) < 2.0,
                    "the tool read a load of"
                    & Long_Float'Image (Report.Load_Before)
                    & " where the host says" & Long_Float'Image (Now));
         end;
      else
         Assert (Report.Load_Before = 0.0,
                 "a host with no load average was reported as having one");
      end if;
   end The_Speed_Tool_Reads_The_Machine;

   ------------------------------------------
   -- The_Speed_Tool_Runs_What_It_Publishes --
   ------------------------------------------

   --  `tests speed` runs the command it exists to reproduce.
   --
   --  It did not, in three ways at once, and every figure it published was
   --  wrong about the run it described. It read the prompt file raw where
   --  the command drops the file's final newline, so it measured a prompt a
   --  token longer. It sampled with the greedy configuration where the
   --  command sets only the temperature and keeps its defaults, penalty
   --  included -- which changed which tokens came out, once penalties began
   --  working at temperature zero. And it handed the asked-for batch size to
   --  a backend that refuses batches, where the command clamps it to one.
   --
   --  None of that was visible in the figures: a wall time is a plausible
   --  number whatever run produced it. What tells the two apart is the text
   --  and the token counts, which is what this compares.
   procedure The_Speed_Tool_Runs_What_It_Publishes
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model  : constant String := "obj/speed-agree-model.gguf";
      Prompt : constant String := "obj/speed-agree-prompt.txt";
      Notes  : constant String := "obj/speed-agree-notes.txt";

      Report : Speed_Run.Report;
   begin
      Tiny_Model.Write (Model, Room => 64);

      --  With the trailing newline an editor would leave, because that is
      --  the difference the command and the tool disagreed about.
      declare
         Handle : File_Type;
      begin
         Create (Handle, Out_File, Prompt);
         Put_Line (Handle, "abab");
         Close (Handle);
      end;

      Speed_Run.Run
        (Path        => Model,
         Prompt_Path => Prompt,
         Tokens      => 4,
         Threads     => 1,
         Batch       => 32,
         Repack      => Model_Runner.Llama.No_Repack,
         Repeats     => 1,
         Result      => Report);

      Assert (Report.Ran,
              "the tool would not measure the fixture: "
              & Speed_Run.Summary (Report));

      --  The same run as a command. Its generated text is caught by the
      --  suite's own capture, which redirects the file descriptor rather
      --  than Text_IO -- which is where that text actually goes -- and its
      --  statistics are caught separately.
      declare
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt-file");
         Add (Source, Prompt);
         Add (Source, "--seed");
         Add (Source, "1");
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, "--threads");
         Add (Source, "1");
         Add (Source, "--max-tokens");
         Add (Source, "4");
         Add (Source, "--show-stats");

         Create (Handle, Out_File, Notes);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);

         Assert (Status = 0, "the command failed:" & Natural'Image (Status));
      end;

      declare
         Told : constant String := Text_Of (Notes);

         --  The value of a labelled statistics line.
         function Field (Label : String) return String is
            From : Natural := Told'First;
         begin
            while From <= Told'Last loop
               declare
                  Stop : Natural := From;
               begin
                  while Stop <= Told'Last
                    and then Told (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line : constant String := Told (From .. Stop - 1);
                     Head : constant String := "  " & Label;
                  begin
                     if Line'Length > Head'Length
                       and then Line (Line'First .. Line'First + Head'Length - 1)
                                = Head
                     then
                        return T.Trim
                          (Line (Line'First + Head'Length .. Line'Last));
                     end if;
                  end;

                  From := Stop + 1;
               end;
            end loop;
            return "";
         end Field;
      begin
         Assert (Field ("prompt tokens")
                 = T.Trim (Natural'Image (Report.Prompt)),
                 "the command read " & Field ("prompt tokens")
                 & " prompt tokens and the tool read"
                 & Natural'Image (Report.Prompt)
                 & ", so they are not running the same prompt");

         Assert (Field ("generated tokens")
                 = T.Trim (Natural'Image (Report.Produced)),
                 "the command generated " & Field ("generated tokens")
                 & " tokens and the tool" & Natural'Image (Report.Produced));

         Assert (Speed_Run.Digest_Of (Last_Output) = Report.Digest,
                 "the command and the tool generated different text: "
                 & Speed_Run.Digest_Of (Last_Output) & " against "
                 & Report.Digest);
      end;
   end The_Speed_Tool_Runs_What_It_Publishes;

   ---------------------------------------------
   -- A_Rolling_Context_Outlives_Its_Room --
   ---------------------------------------------

   --  A run asked to drop its oldest positions outlives the context, and
   --  what it says before the first drop is what it would have said with
   --  room to spare.
   --
   --  Two halves. Without the option the run is refused before it starts,
   --  because the prompt and the tokens asked for do not fit -- that
   --  refusal is what the option exists to lift. With it the run finishes
   --  and reports the drops.
   --
   --  And the text: the same run in a context large enough to need no drop
   --  produces the same tokens up to where the small one first drops. After
   --  that they diverge, and should -- one of them has forgotten the
   --  beginning -- so the comparison stops there. Without this half the
   --  test would pass on a shift that scrambled the context, because a run
   --  that produces nonsense produces it fluently.
   procedure A_Rolling_Context_Outlives_Its_Room
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Model : constant String := "obj/rolling-model.gguf";
      Notes : constant String := "obj/rolling-notes.txt";

      Prompt : constant String := "ab";

      --  Run with the given context and shift, keeping what it wrote.
      procedure Attempt
        (Room    : String;
         Shift   : String;
         Status  : out Natural)
      is
         Source : Fixed_Arguments;
         Handle : File_Type;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, Prompt);
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, "--threads");
         Add (Source, "1");
         Add (Source, "--max-tokens");
         Add (Source, "20");
         Add (Source, "--context-size");
         Add (Source, Room);
         if Shift /= "" then
            Add (Source, "--context-shift");
            Add (Source, Shift);
         end if;
         Add (Source, "--show-stats");

         Create (Handle, Out_File, Notes);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Error (Standard_Error);
         Close (Handle);
      end Attempt;

      Status : Natural;
   begin
      --  The model declares room for sixty-four; the runs below ask for
      --  sixteen of it and for all of it, which is how one of them has to
      --  drop and the other does not.
      Tiny_Model.Write (Model, Room => 64);

      --  Without the option: refused before anything is generated.
      Attempt ("16", "", Status);
      Assert (Status /= 0,
              "a run that cannot fit was accepted without --context-shift");

      --  With it: finished, and it says how often it dropped.
      Attempt ("16", "6", Status);
      Assert (Status = 0,
              "a rolling run failed:" & Natural'Image (Status));

      declare
         Told : constant String := Text_Of (Notes);
         Small : constant String := Last_Output;

         function Holds (Whole, Part : String) return Boolean is
         begin
            if Part'Length > Whole'Length then
               return False;
            end if;
            for Start in Whole'First .. Whole'Last - Part'Length + 1 loop
               if Whole (Start .. Start + Part'Length - 1) = Part then
                  return True;
               end if;
            end loop;
            return False;
         end Holds;
      begin
         Assert (Holds (Told, "context shifts"),
                 "a run that dropped positions did not report it");

         --  The same run with room to spare, for as far as the two can
         --  agree.
         Attempt ("64", "", Status);
         Assert (Status = 0,
                 "the run with room failed:" & Natural'Image (Status));

         declare
            Large : constant String := Last_Output;

            --  The small context holds sixteen positions and the prompt
            --  takes three, so the first drop comes after about thirteen
            --  tokens. Compared over ten, which is inside that and outside
            --  nothing.
            Room : constant Natural :=
              Natural'Min (10, Natural'Min (Small'Length, Large'Length));
         begin
            Assert (Room > 0, "neither run produced anything");
            Assert (Small (Small'First .. Small'First + Room - 1)
                    = Large (Large'First .. Large'First + Room - 1),
                    "a rolling run said something else before it had "
                    & "dropped anything: <"
                    & Small (Small'First .. Small'First + Room - 1)
                    & "> against <"
                    & Large (Large'First .. Large'First + Room - 1) & ">");
         end;
      end;
   end A_Rolling_Context_Outlives_Its_Room;

   ------------------------------------------
   -- Several_Prompts_Are_Several_Sequences --
   ------------------------------------------

   --  Several prompts from one loaded model each get their own answer, and
   --  each is the answer that prompt gets alone.
   --
   --  The saving is the model: it is read once and answers many. What must
   --  not happen is the second prompt continuing the first -- which is what
   --  a session left as it was would do, and what nothing about the output
   --  would show, because two answers concatenated look like two answers
   --  either way.
   procedure Several_Prompts_Are_Several_Sequences
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Model : constant String := "obj/many-prompts-model.gguf";

      --  One run of the command, with however many prompts it is given.
      procedure Answer (First, Second : String; Into : out Natural) is
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, First);
         if Second /= "" then
            Add (Source, "--prompt");
            Add (Source, Second);
         end if;
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, "--threads");
         Add (Source, "1");
         Add (Source, "--max-tokens");
         Add (Source, "3");

         Ran (Source, Into);
      end Answer;

      Status : Natural;
   begin
      Tiny_Model.Write (Model, Room => 64);

      Answer ("ab", "", Status);
      Assert (Status = 0, "the first run failed:" & Natural'Image (Status));

      declare
         Alone_First : constant String := Last_Output;
      begin
         Answer ("aa", "", Status);
         Assert (Status = 0,
                 "the second run failed:" & Natural'Image (Status));

         declare
            Alone_Second : constant String := Last_Output;
         begin
            --  The two answers differ, or nothing below can tell a fresh
            --  session from a continued one.
            Assert (Alone_First /= Alone_Second,
                    "the two prompts answer the same, so this fixture "
                    & "cannot tell a reset session from a kept one");

            Answer ("ab", "aa", Status);
            Assert (Status = 0,
                    "the run with two prompts failed:"
                    & Natural'Image (Status));

            Assert (Last_Output = Alone_First & Alone_Second,
                    "two prompts in one run did not answer as they answer "
                    & "alone: got <" & Last_Output & "> against <"
                    & Alone_First & Alone_Second & ">");
         end;
      end;
   end Several_Prompts_Are_Several_Sequences;

   -------------------------------------------------
   -- The_External_Runner_Runs_What_The_Command_Does --
   -------------------------------------------------

   --  `tests external-model` generates what the command generates from the
   --  same inputs.
   --
   --  It validates a caller's own model, so what it runs has to be what the
   --  program runs -- a validation of something else validates nothing. It
   --  samples greedily and seeds itself with forty-two, which is a choice
   --  and not the command's default; this pins the correspondence by giving
   --  the command those settings explicitly and comparing the text.
   --
   --  `tests benchmark` has no counterpart to this and needs none: it
   --  measures kernels on synthetic tensors it builds itself, so there is no
   --  command whose behaviour it could differ from.
   procedure The_External_Runner_Runs_What_The_Command_Does
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Model : constant String := "obj/external-agree-model.gguf";

      Prompt : constant String := "abab";

      Report : External_Model.Report;
   begin
      Tiny_Model.Write (Model, Room => 64);

      External_Model.Run
        (Path    => Model,
         Prompt  => Prompt,
         Tokens  => 4,
         Threads => 1,
         Result  => Report);

      Assert (Report.Result = External_Model.Ran,
              "the runner did not run the fixture: "
              & External_Model.Summary (Report));

      declare
         Source : Fixed_Arguments;
         Status : Natural;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, Prompt);
         Add (Source, "--seed");
         Add (Source, "42");
         Add (Source, "--temperature");
         Add (Source, "0");
         Add (Source, "--repeat-penalty");
         Add (Source, "1");
         Add (Source, "--repeat-window");
         Add (Source, "0");
         Add (Source, "--threads");
         Add (Source, "1");
         Add (Source, "--max-tokens");
         Add (Source, "4");

         Ran (Source, Status);
         Assert (Status = 0, "the command failed:" & Natural'Image (Status));
      end;

      Assert (Speed_Run.Digest_Of (Last_Output) = Report.Digest,
              "the runner and the command generated different text: "
              & Speed_Run.Digest_Of (Last_Output) & " against "
              & Report.Digest);
   end The_External_Runner_Runs_What_The_Command_Does;

   procedure Runs_Report_Which_Backend_Ran
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      package Back renames Model_Runner.Backend;
      use Ada.Text_IO;
      use type Back.Backend_Kind;

      Model  : constant String := "obj/report-model.gguf";
      Stream : constant String := "obj/report-output.txt";

      --  Everything the command wrote to both streams.
      function Output_Of (Source : in out Fixed_Arguments) return String is
         Handle : File_Type;
         Status : Natural;
      begin
         Create (Handle, Out_File, Stream);
         Set_Output (Handle);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               Set_Output (Standard_Output);
               Set_Error (Standard_Error);
               Close (Handle);
               raise;
         end;
         Set_Output (Standard_Output);
         Set_Error (Standard_Error);
         Close (Handle);
         return Text_Of (Stream);
      end Output_Of;

      --  The value of a labelled field, or empty when there is no such line.
      --  The labels are padded to a column, so the value is what is left
      --  once the label and the padding are taken off.
      function Field (Text, Label : String) return String is
         Head  : constant String := "  " & Label;
         From  : Natural := Text'First;
      begin
         while From <= Text'Last loop
            declare
               Stop : Natural := From;
            begin
               while Stop <= Text'Last
                 and then Text (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line : constant String := Text (From .. Stop - 1);
               begin
                  if Line'Length > Head'Length
                    and then Line (Line'First .. Line'First + Head'Length - 1)
                             = Head
                    and then Line (Line'First + Head'Length) = ' '
                  then
                     return T.Trim (Line (Line'First + Head'Length .. Line'Last));
                  end if;
               end;

               From := Stop + 1;
            end;
         end loop;
         return "";
      end Field;

      --  An inspection, which reports what a run would use.
      function Inspected (Kind : Back.Backend_Kind) return String is
         Source : Fixed_Arguments;
      begin
         Add (Source, "inspect");
         Add (Source, Model);
         Add (Source, "--backend");
         Add (Source, Back.Backend_Name (Kind));
         Add (Source, "--threads");
         Add (Source, "3");
         return Output_Of (Source);
      end Inspected;

      --  A run with statistics, which reports what it did use.
      function Ran (Kind : Back.Backend_Kind) return String is
         Source : Fixed_Arguments;
      begin
         Add (Source, "run");
         Add (Source, Model);
         Add (Source, "--backend");
         Add (Source, Back.Backend_Name (Kind));
         Add (Source, "--threads");
         Add (Source, "3");
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "2");
         Add (Source, "--show-stats");
         return Output_Of (Source);
      end Ran;
   begin
      Tiny_Model.Write (Model, Room => 256);

      for Kind in Back.Backend_Kind loop
         declare
            Name    : constant String := Back.Backend_Name (Kind);
            Looked  : constant String := Inspected (Kind);
            Worked  : constant String := Ran (Kind);

            --  Three were asked for. The processor takes them for its
            --  products; the device takes them for the host loops a run
            --  still has -- normalizing a batch, joining its residuals --
            --  which are a fifth of a device prompt and were on one core
            --  until they were shared out. The reference backend is serial
            --  by construction and takes one.
            Expected : constant String :=
              (if Back.Backend_Kind'Pos (Kind)
                 = Back.Backend_Kind'Pos (Back.Backend_Reference)
               then "1" else "3");

            --  A run on a device needs a device. Inspection does not -- it
            --  reports what was asked for without opening anything -- so
            --  the inspection half is asserted on every machine and the run
            --  half only where the run happened.
            Ran_It : constant Boolean := Field (Worked, "backend") /= "";
         begin
            Assert (Field (Looked, "backend") = Name,
                    "inspect reported backend """
                    & Field (Looked, "backend") & """ for " & Name);
            Assert (Field (Looked, "worker tasks") = Expected,
                    "inspect reported """ & Field (Looked, "worker tasks")
                    & """ worker tasks for " & Name & ", not " & Expected);

            if Ran_It then
               Assert (Field (Worked, "backend") = Name,
                       "the statistics reported backend """
                       & Field (Worked, "backend") & """ for " & Name);
               Assert (Field (Worked, "worker tasks") = Expected,
                       "the statistics reported """
                       & Field (Worked, "worker tasks")
                       & """ worker tasks for " & Name & ", not "
                       & Expected);
            else
               Assert (Kind = Back.Backend_Device,
                       "the " & Name & " backend did not run at all");
            end if;
         end;
      end loop;
   end Runs_Report_Which_Backend_Ran;

   ---------------------------------------
   -- Published_Transcripts_Are_Real --
   ---------------------------------------

   --  The blocks the README shows as program output are program output.
   --
   --  Three of the transcripts in that file had drifted from what the program
   --  prints -- one had never been runnable at all, and two showed a single
   --  line where two are written. They are copied by hand, so nothing stopped
   --  it. The ones that run against something this repository owns can be
   --  replayed, and these are those: an inspection of the committed fixture,
   --  and the two locale examples, which need no model because they fail
   --  before one is opened.
   --
   --  The generated text of a run is not among them. It leaves through the
   --  output sink rather than the text streams, so redirecting those does not
   --  see it, and reaching it would mean giving the driver a sink for the
   --  sake of a test. The transcript showing it was checked by hand when this
   --  was written and remains one of the hand-copied ones.
   --
   --  What is compared is every output line the README shows, against what
   --  the program wrote. The lines that name a path are skipped, because the
   --  transcript was taken from a different directory than the tests run in,
   --  and that is a difference in the reader's shell rather than in the
   --  program.

   procedure Published_Transcripts_Are_Real
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);
      use Ada.Text_IO;

      Errors : constant String := "obj/published-transcript.txt";

      --  Everything the program writes to both streams for one command.
      function Output_Of (Source : in out Fixed_Arguments) return String is
         Handle : File_Type;
         Status : Natural;
         Room   : String (1 .. 32_768);
         Used   : Natural := 0;
      begin
         Create (Handle, Out_File, Errors);
         Set_Output (Handle);
         Set_Error (Handle);

         begin
            Ran (Source, Status);
         exception
            when others =>
               null;
         end;

         Set_Output (Standard_Output);
         Set_Error (Standard_Error);
         Close (Handle);

         Open (Handle, In_File, Errors);
         while not End_Of_File (Handle) and then Used < Room'Length - 400 loop
            declare
               Line : String (1 .. 400);
               Last : Natural;
            begin
               Get_Line (Handle, Line, Last);
               Room (Used + 1 .. Used + Last) := Line (1 .. Last);
               Used := Used + Last + 1;
               Room (Used) := Character'Val (10);
            end;
         end loop;
         Close (Handle);
         return Room (1 .. Used);
      end Output_Of;

      --  A file the repository carries, with carriage returns taken out.
      --
      --  A checkout on a host whose line ending is two characters gives them
      --  back that way, and the program writes one. Comparing the two as
      --  they stand looked for a published line that ends in a carriage
      --  return and never found it: three tests failed on Windows and
      --  nowhere else, saying that inspect does not print "Container" when
      --  it prints exactly that.
      function Repository_Text (Path : String) return String is
         Whole : constant String :=
           (if Project_Tools.Files.File_Exists (Path)
            then Project_Tools.Files.Read_Raw_File (Path) else "");
         Room  : String (1 .. Whole'Length);
         Used  : Natural := 0;
      begin
         for Character_Value of Whole loop
            if Character_Value /= Character'Val (13) then
               Used := Used + 1;
               Room (Used) := Character_Value;
            end if;
         end loop;

         return Room (1 .. Used);
      end Repository_Text;

      Readme : constant String := Repository_Text ("../README.md");

      --  The fenced block holding a line, without its fences.
      function Block_Holding (Anchor : String) return String is
         Fence : constant String := "```";
         At_Anchor, Opens, Closes : Natural := 0;
      begin
         for Index in Readme'First .. Readme'Last - Anchor'Length + 1 loop
            if Readme (Index .. Index + Anchor'Length - 1) = Anchor then
               At_Anchor := Index;
               exit;
            end if;
         end loop;
         if At_Anchor = 0 then
            return "";
         end if;

         for Index in reverse Readme'First .. At_Anchor - Fence'Length loop
            if Readme (Index .. Index + Fence'Length - 1) = Fence then
               Opens := Index + Fence'Length;
               exit;
            end if;
         end loop;
         for Index in At_Anchor .. Readme'Last - Fence'Length + 1 loop
            if Readme (Index .. Index + Fence'Length - 1) = Fence then
               Closes := Index - 1;
               exit;
            end if;
         end loop;
         if Opens = 0 or else Closes < Opens then
            return "";
         end if;
         return Readme (Opens .. Closes);
      end Block_Holding;

      --  Every line of a published block must appear in what the program
      --  wrote, except the command lines, the blanks, an elision, and any
      --  line naming a path.
      --  Complete means the block shows every line the program printed, not
      --  merely lines that it printed. Only a transcript with nothing elided
      --  can be held to that, which is why the inspection is not: it shows an
      --  ellipsis where a reader does not need the rest.
      procedure Must_Match
        (Anchor, Produced, What : String; Complete : Boolean := False) is
         Block : constant String := Block_Holding (Anchor);
         From  : Natural := Block'First;
      begin
         Assert (Block'Length > 0,
                 "no published block holds """ & Anchor & """");

         --  A block can hold several transcripts. Start at this command and
         --  stop at the next one, so each is compared against its own run
         --  rather than against whatever else the block shows.
         for Index in Block'First .. Block'Last - Anchor'Length + 1 loop
            if Block (Index .. Index + Anchor'Length - 1) = Anchor then
               --  Past the command line itself, whose own leading '$' would
               --  otherwise end the scan before it compared anything.
               From := Index;
               while From <= Block'Last
                 and then Block (From) /= Character'Val (10)
               loop
                  From := From + 1;
               end loop;
               From := From + 1;
               exit;
            end if;
         end loop;

         while From <= Block'Last loop
            declare
               Stop : Natural := From;
            begin
               while Stop <= Block'Last
                 and then Block (Stop) /= Character'Val (10)
               loop
                  Stop := Stop + 1;
               end loop;

               declare
                  Line  : constant String := Block (From .. Stop - 1);
                  Empty : Boolean := True;
                  Found : Boolean := False;
               begin
                  for Letter of Line loop
                     if Letter /= ' ' then
                        Empty := False;
                     end if;
                  end loop;

                  exit when not Empty and then Line (Line'First) = '$';

                  if not Empty
                    and then Line (Line'First) /= '$'
                    and then Line /= "  ..."
                    and then not (Line'Length >= 6
                                  and then Line (Line'First .. Line'First + 5)
                                           = "  path")
                  then
                     --  A whole line of the output, not a fragment of one.
                     --  Comparing by substring would let a published line
                     --  that had lost its tail keep matching the full one,
                     --  and losing a tail is exactly how these drift.
                     declare
                        Start : Natural := Produced'First;
                     begin
                        while Start <= Produced'Last loop
                           declare
                              Ends : Natural := Start;
                           begin
                              while Ends <= Produced'Last
                                and then Produced (Ends) /= Character'Val (10)
                              loop
                                 Ends := Ends + 1;
                              end loop;

                              if Produced (Start .. Ends - 1) = Line then
                                 Found := True;
                              end if;

                              Start := Ends + 1;
                           end;
                        end loop;
                     end;

                     Assert (Found,
                             What & " does not print the published line """
                             & Line & """");
                  end if;
               end;

               From := Stop + 1;
            end;
         end loop;

         if not Complete then
            return;
         end if;

         --  The other direction. Without it a published block can lose a line
         --  and still agree with everything it kept, which is how both locale
         --  examples came to show one line where the program prints two.
         declare
            Start : Natural := Produced'First;
         begin
            while Start <= Produced'Last loop
               declare
                  Ends  : Natural := Start;
                  Shown : Boolean := False;
               begin
                  while Ends <= Produced'Last
                    and then Produced (Ends) /= Character'Val (10)
                  loop
                     Ends := Ends + 1;
                  end loop;

                  declare
                     Line  : constant String := Produced (Start .. Ends - 1);
                     Empty : Boolean := True;
                     Scan  : Natural := Block'First;
                  begin
                     for Letter of Line loop
                        if Letter /= ' ' then
                           Empty := False;
                        end if;
                     end loop;

                     while not Empty and then Scan <= Block'Last loop
                        declare
                           Upto : Natural := Scan;
                        begin
                           while Upto <= Block'Last
                             and then Block (Upto) /= Character'Val (10)
                           loop
                              Upto := Upto + 1;
                           end loop;
                           if Block (Scan .. Upto - 1) = Line then
                              Shown := True;
                           end if;
                           Scan := Upto + 1;
                        end;
                     end loop;

                     Assert (Empty or else Shown,
                             What & " prints """ & Line
                             & """, which the published block does not show");
                  end;

                  Start := Ends + 1;
               end;
            end loop;
         end;
      end Must_Match;
   begin
      if Readme'Length = 0 then
         --  Run from somewhere without the README beside the crate.
         return;
      end if;

      --  The fixture this reads is not committed, so it is written here
      --  rather than assumed: the same bytes every time, and no dependence
      --  on what an earlier run of `tests fixtures` left behind.
      Tiny_Model.Write_Suite_Fixture;

      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "inspect");
         Add (Source, Tiny_Model.Suite_Fixture);

         --  The worker count is one per physical core less one, so a
         --  transcript that lets it default publishes this machine's core
         --  count and cannot be replayed on another. It read "worker tasks
         --  7" and failed on every continuous-integration runner there is.
         --  Asked for explicitly, the line is the program's answer rather
         --  than the machine's.
         Add (Source, "--threads");
         Add (Source, "4");

         Must_Match ("$ model_runner inspect", Output_Of (Source),
                     "inspect");
      end;

      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "--locale");
         Add (Source, "da");
         Add (Source, "run");
         Add (Source, "x.gguf");
         Add (Source, "--bogus");
         Must_Match ("$ model_runner --locale da", Output_Of (Source),
                     "the Danish locale", Complete => True);
      end;

      --  The runner's summaries, which the README wraps across lines. Joining
      --  the published lines and requiring the whole line back is stricter
      --  than looking for its parts: a summary that lost a field, gained one,
      --  or had one altered all differ from the joined text, and only an
      --  exact match passes.
      declare
         procedure Must_Read_As (Anchor, Produced, What : String) is
            Block  : constant String := Block_Holding (Anchor);
            Joined : String (1 .. 2_048) := [others => ' '];
            Used   : Natural := 0;
            From   : Natural := Block'First;
            Seen   : Boolean := False;
         begin
            Assert (Block'Length > 0,
                    "no published block holds """ & Anchor & """");

            for Index in Block'First .. Block'Last - Anchor'Length + 1 loop
               if Block (Index .. Index + Anchor'Length - 1) = Anchor then
                  From := Index;
                  while From <= Block'Last
                    and then Block (From) /= Character'Val (10)
                  loop
                     From := From + 1;
                  end loop;
                  From := From + 1;
                  Seen := True;
                  exit;
               end if;
            end loop;
            Assert (Seen, "no command """ & Anchor & """ in its block");

            while From <= Block'Last loop
               declare
                  Stop : Natural := From;
               begin
                  while Stop <= Block'Last
                    and then Block (Stop) /= Character'Val (10)
                  loop
                     Stop := Stop + 1;
                  end loop;

                  declare
                     Line  : constant String := Block (From .. Stop - 1);
                     Head  : Natural := Line'First;
                     Tail  : Natural := Line'Last;
                  begin
                     while Head <= Tail and then Line (Head) = ' ' loop
                        Head := Head + 1;
                     end loop;
                     while Tail >= Head and then Line (Tail) = ' ' loop
                        Tail := Tail - 1;
                     end loop;

                     exit when Head <= Tail and then Line (Head) = '$';

                     if Head <= Tail then
                        if Used > 0 then
                           Used := Used + 1;
                           Joined (Used) := ' ';
                        end if;
                        Joined (Used + 1 .. Used + (Tail - Head + 1)) :=
                          Line (Head .. Tail);
                        Used := Used + (Tail - Head + 1);
                     end if;
                  end;

                  From := Stop + 1;
               end;
            end loop;

            Assert (Joined (1 .. Used) = Produced,
                    What & " prints" & ASCII.LF & "  " & Produced & ASCII.LF
                    & "where the README publishes" & ASCII.LF & "  "
                    & Joined (1 .. Used));
         end Must_Read_As;

         Absent : External_Model.Report;
         Fits   : External_Model.Report;
         Over   : External_Model.Report;
      begin
         External_Model.Run
           (Path => "/nowhere/x.gguf", Prompt => "Hello", Tokens => 16,
            Threads => 4, Result => Absent);
         Must_Read_As ("$ tests external-model --model /nowhere",
                       External_Model.Summary (Absent), "a missing model");

         External_Model.Run
           (Path => Tiny_Model.Suite_Fixture, Prompt => "ab", Tokens => 8,
            Threads => 4, Result => Fits);
         Must_Read_As
           ("--threads 4 --max-tokens 8",
            External_Model.Summary (Fits), "a run that fits the context");

         External_Model.Run
           (Path => Tiny_Model.Suite_Fixture, Prompt => "ab", Tokens => 16,
            Threads => 4, Result => Over);
         Must_Read_As
           ("$ tests external-model --model fixtures/tiny-model.gguf"
            & " --prompt ""ab""" & ASCII.LF,
            External_Model.Summary (Over), "a run the engine refuses");
      end;

      declare
         Source : Fixed_Arguments;
      begin
         Add (Source, "--locale");
         Add (Source, "qps");
         Add (Source, "run");
         Add (Source, "x.gguf");
         Add (Source, "--bogus");
         Must_Match ("$ model_runner --locale qps", Output_Of (Source),
                     "the pseudo-locale", Complete => True);
      end;
   end Published_Transcripts_Are_Real;

   ---------------------------------------------
   -- Beginning_Marker_Follows_The_Vocabulary --
   ---------------------------------------------

   --  A vocabulary that wants no beginning marker is not given one.
   --
   --  The request asks for one and the vocabulary decides, and until that was
   --  so, every model declaring that it wants none was fed a sequence no
   --  other implementation would produce. It cost a whole token of context
   --  and moved a logit by nearly two, which showed up as generation ending
   --  after two tokens -- indistinguishable, without a number, from the model
   --  simply choosing to stop.
   --
   --  Two fixtures differing in that one declaration, the same prompt through
   --  each, and the token counts must differ by exactly one.

   procedure Beginning_Marker_Follows_The_Vocabulary
     (T2 : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T2);

      Wants   : constant String := "obj/marker-wanted.gguf";
      Refuses : constant String := "obj/marker-refused.gguf";

      --  Through the command line, because that is the path the defect was
      --  on: the tokenizer took a flag and obeyed it, and the generator was
      --  the one deciding wrongly what to pass.
      function Prompt_Tokens_Of (Path : String) return Natural is
         use Ada.Text_IO;
         Errors : constant String := "obj/marker-stats.txt";
         Source : Fixed_Arguments;
         Handle : File_Type;
         Status : Natural;
         Found  : Natural := 0;
      begin
         Add (Source, "run");
         Add (Source, Path);
         Add (Source, "--raw");
         Add (Source, "--prompt");
         Add (Source, "ab");
         Add (Source, "--max-tokens");
         Add (Source, "1");
         Add (Source, "--threads");
         Add (Source, "1");
         Add (Source, "--show-stats");

         Create (Handle, Out_File, Errors);
         Set_Output (Handle);
         Set_Error (Handle);
         begin
            Ran (Source, Status);
         exception
            when others =>
               null;
         end;
         Set_Output (Standard_Output);
         Set_Error (Standard_Error);
         Close (Handle);

         Open (Handle, In_File, Errors);
         while not End_Of_File (Handle) loop
            declare
               Line : String (1 .. 200);
               Last : Natural;
               Mark : constant String := "prompt tokens";
            begin
               Get_Line (Handle, Line, Last);
               for Index in 1 .. Last - Mark'Length + 1 loop
                  if Line (Index .. Index + Mark'Length - 1) = Mark then
                     Found :=
                       Natural'Value (Line (Index + Mark'Length .. Last));
                  end if;
               end loop;
            exception
               when others =>
                  null;
            end;
         end loop;
         Close (Handle);
         return Found;
      end Prompt_Tokens_Of;

      With_Marker    : Natural;
      Without_Marker : Natural;
   begin
      Tiny_Model.Write (Wants, Adds_Beginning => True);
      Tiny_Model.Write (Refuses, Adds_Beginning => False);

      With_Marker := Prompt_Tokens_Of (Wants);
      Without_Marker := Prompt_Tokens_Of (Refuses);

      Assert (With_Marker > 0 and then Without_Marker > 0,
              "neither fixture tokenized");

      Assert (With_Marker = Without_Marker + 1,
              "a vocabulary that wants no beginning marker was given one:"
              & Natural'Image (With_Marker) & " tokens against"
              & Natural'Image (Without_Marker));
   end Beginning_Marker_Follows_The_Vocabulary;

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
        (T, Batch_Size_Does_Not_Change_The_Text'Access,
         "how a prompt is divided into batches does not change what "
         & "follows it");
      Register_Routine
        (T, Worker_Count_Does_Not_Change_The_Text'Access,
         "how many workers run a generation does not change what it "
         & "produces");
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
        (T, Device_Product_Matches_The_Processor'Access,
         "a device computes the product the processor computes");
      Register_Routine
        (T, Devices_Are_Reported_Either_Way'Access,
         "asking the machine what devices it has answers, either way");
      Register_Routine
        (T, Saved_Context_Changes_Nothing'Access,
         "a saved context is the context, and reusing one changes nothing");
      Register_Routine
        (T, Grammar_Constrains_The_Run'Access,
         "a grammar constrains what a run may produce");
      Register_Routine
        (T, Embedding_Reports_The_State'Access,
         "embedding a text reports the state, not the distribution");
      Register_Routine
        (T, Every_Backend_Can_Be_Named'Access,
         "every backend this build has can be named on the command line");
      Register_Routine
        (T, Repacking_Changes_No_Logit'Access,
         "repacking the weights changes no logit, to the bit");
      Register_Routine
        (T, Backends_Agree'Access,
         "the two backends produce the same logits");
      Register_Routine
        (T, Slow_Backend_Is_Asked_For_One'Access,
         "a backend that cannot batch is asked for one token at a time");
      Register_Routine
        (T, Every_Chat_Format_Can_Be_Named'Access,
         "every chat format this build carries can be named on the command "
         & "line");
      Register_Routine
        (T, Help_Screen_Is_Laid_Out'Access,
         "the help screen is laid out and lists every option it accepts");
      Register_Routine
        (T, Reported_Screens_Are_Laid_Out'Access,
         "the inspect and statistics screens are laid out in a column");
      Register_Routine
        (T, Trace_And_Diagnostic_Render'Access,
         "the progress trace and a diagnostic render");
      Register_Routine
        (T, Session_Memory_Is_Counted'Access,
         "a session's memory is counted and the limit counts it");
      Register_Routine
        (T, Session_Reports_Its_Phase'Access,
         "a session reports the phase it is in");
      Register_Routine
        (T, Replaced_File_Is_Refused'Access,
         "a model file replaced between validation and reading is refused");
      Register_Routine
        (T, Unused_Interface_Is_Exercised'Access,
         "public operations the program does not call are exercised");
      Register_Routine
        (T, Architectures_Are_Read_By_Name'Access,
         "each architecture is read with its own keys and its own rotation");
      Register_Routine
        (T, Statistics_Report_The_Run_They_Describe'Access,
         "the statistics report the run they describe");
      Register_Routine
        (T, Promised_Exit_Statuses_Are_Produced'Access,
         "the exit statuses the help promises are produced");
      Register_Routine
        (T, Unavailable_Locale_Warns_And_Continues'Access,
         "a locale this build does not carry is warned about and used "
         & "anyway");
      Register_Routine
        (T, Mapping_Is_Asked_For_Rather_Than_Allowed'Access,
         "memory mapping is asked for rather than allowed");
      Register_Routine
        (T, Options_With_A_Consequence_Have_It'Access,
         "options with a consequence have it, seen through the command");
      Register_Routine
        (T, Stops_From_The_Command_Line_Stop'Access,
         "a stop given on the command line stops the run");
      Register_Routine
        (T, Options_Reach_What_They_Name'Access,
         "every option reaches the setting it names");
      Register_Routine
        (T, Flag_Only_Options_Work'Access,
         "the options that take no value do what they say");
      Register_Routine
        (T, Unreached_Refusals_Are_Reached'Access,
         "refusals the command had never been made to make are made");
      Register_Routine
        (T, Capture_Catches_And_Restores'Access,
         "the capture that catches command output puts it back afterwards");
      Register_Routine
        (T, Interactive_Commands_Do_Something'Access,
         "every interactive command does something, and reset clears the "
         & "conversation");
      Register_Routine
        (T, Interactive_Reads_Its_Commands'Access,
         "interactive reads a line of input as the command it is");
      Register_Routine
        (T, Interactive_Holds_A_Turn'Access,
         "interactive accumulates a turn, submits on a blank line and "
         & "bounds what one turn may hold");
      Register_Routine
        (T, Interactive_Loop_Runs'Access,
         "the interactive loop runs over redirected input");
      Register_Routine
        (T, Caller_Refusals_Report_Themselves'Access,
         "requests, conversations and models refuse by name");
      Register_Routine
        (T, System_File_Is_Read_And_Refused'Access,
         "a system message read from a file is read, and refused by name");
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
        (T, Mapping_Reads_The_Same_Bytes'Access,
         "a mapped read and an ordinary read return the same bytes");
      Register_Routine
        (T, Model_File_Is_Never_Modified'Access,
         "the model file is never written to");
      Register_Routine
        (T, Reference_Comparison_Works'Access,
         "the reference comparison accepts a match and rejects a mismatch");

      Register_Routine
        (T, Published_Transcripts_Are_Real'Access,
         "the transcripts the README publishes are what the program prints");
      Register_Routine
        (T, Styling_Follows_Its_Stream'Access,
         "a line is coloured according to the stream it is going to");
      Register_Routine
        (T, Streams_Are_Separate'Access,
         "each kind of output leaves by the stream the README says it does");
      Register_Routine
        (T, A_Rolling_Context_Outlives_Its_Room'Access,
         "a run asked to drop its oldest positions outlives the context and "
         & "says the same things before the first drop");
      Register_Routine
        (T, Several_Prompts_Are_Several_Sequences'Access,
         "several prompts from one loaded model answer each on its own, "
         & "not as a conversation");
      Register_Routine
        (T, The_External_Runner_Runs_What_The_Command_Does'Access,
         "the external-model runner generates what the command generates "
         & "from the same inputs");
      Register_Routine
        (T, A_Busy_Machine_Cannot_Publish_A_Figure'Access,
         "a busy machine cannot publish a figure");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Device_Memory_Reaches_The_Device'Access,
         "--device-memory decides where the weights are, and says so");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, The_Speed_Tool_Reads_The_Machine'Access,
         "the load a figure carries is the load the host reports");
      Register_Routine
        (T, The_Speed_Tool_Runs_What_It_Publishes'Access,
         "the speed tool runs the command it publishes figures for");
      Register_Routine
        (T, Runs_Report_Which_Backend_Ran'Access,
         "a run and an inspection both say which backend answers and with "
         & "how many workers");
      Register_Routine
        (T, Beginning_Marker_Follows_The_Vocabulary'Access,
         "a vocabulary that declares it wants no beginning marker is not "
         & "given one");
      Register_Routine
        (T, Inspection_Reports_A_Mixture'Access,
         "an inspection reports a mixture as one, and a dense model as "
         & "none");
      Register_Routine
        (T, Tools_Reach_The_Template_Or_The_Run_Says_So'Access,
         "tools reach the template or the run says they would not, and the "
         & "turns that close a tool loop reach the conversation");
      Register_Routine
        (T, Turns_Parse_In_Order'Access,
         "the turns that close a tool loop parse in the order they were "
         & "written");
   end Register_Tests;

end Tests.CLI_Cases;
