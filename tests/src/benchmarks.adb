with Ada.Real_Time;
with Interfaces;
with Ada.Text_IO;

with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Reference;
with Model_Runner.Grammar;
with Model_Runner.Kernels;
with Model_Runner.Sampling;
with Model_Runner.Tokenizer;
with Model_Runner.Platform;
with Model_Runner.Numerics;
with Model_Runner.Quantization;
with Model_Runner.Tensors;

with Fixtures;

package body Benchmarks is

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package N renames Model_Runner.Numerics;
   package Q renames Model_Runner.Quantization;
   package T renames Model_Runner.Tensors;

   use type Interfaces.Unsigned_64;

   use type B.Byte_Array_Access;
   use type B.Byte_Count;
   use type N.Element_Count;
   use type N.Real;
   use type T.Real_Array_Access;

   --  Fed by the reference copy so that the copy cannot be optimised away,
   --  and read once at the end where the value can never be what is tested.
   Guard : Interfaces.Unsigned_64 := 0;

   Rows    : constant N.Element_Count := 512;
   Columns : constant N.Element_Count := 2048;

   --  Fill a buffer with values that are not all the same, so that a decoder
   --  cannot be accidentally fast on uniform data.
   procedure Fill (Data : in out B.Byte_Array) is
      Value : B.Byte := 0;
   begin
      for Index in Data'Range loop
         Value := B.Byte ((Integer (Value) * 7 + 13) mod 251);
         Data (Index) := Value;
      end loop;
   end Fill;

   --  Force every half-precision scale in a span of blocks to a modest normal
   --  exponent.
   --
   --  Random bytes read as half precision are frequently denormal, infinite
   --  or not-a-number. Arithmetic on denormals is slow on this hardware, so
   --  leaving them in measures a case no real model contains and reports the
   --  kernels as slower than they are.
   procedure Tame_Scales
     (Data   : in out B.Byte_Array;
      Format : G.Tensor_Type;
      Blocks : B.Byte_Count)
   is
      Width : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
   begin
      case Format is
         when G.Type_F16 =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#30#;
            end loop;

         when G.Type_F32 =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 3) := 16#3E#;
            end loop;

         when G.Type_BF16 =>
            --  The top half of a binary32, so the byte that carries the sign
            --  and the exponent is the second of two rather than the fourth
            --  of four. Left alone, arbitrary bytes are as often infinite or
            --  not-a-number here as they are in any other float format, and
            --  the benchmark would be timing those.
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#3E#;
            end loop;

         when G.Type_Q4_0 | G.Type_Q8_0 | G.Type_Q5_0
            | G.Type_IQ4_NL | G.Type_IQ4_XS =>
            --  One half-precision scale at the head of the block. The
            --  super-block form's sub-block scales are integers, so they
            --  cannot be anything but finite whatever bytes they hold.
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#30#;
            end loop;

         when G.Type_Q4_1 | G.Type_Q5_1 =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#30#;
               Data (Data'First + Block * Width + 3) := 16#30#;
            end loop;

         when G.Type_Q4_K | G.Type_Q5_K =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 1) := 16#30#;
               Data (Data'First + Block * Width + 3) := 16#30#;
            end loop;

         when G.Type_Q6_K =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 209) := 16#30#;
            end loop;

         when G.Type_Q3_K =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 109) := 16#30#;
            end loop;

         when G.Type_Q2_K =>
            for Block in 0 .. Blocks - 1 loop
               Data (Data'First + Block * Width + 81) := 16#30#;
               Data (Data'First + Block * Width + 83) := 16#30#;
            end loop;

         when others =>
            null;
      end case;
   end Tame_Scales;

   type Rate_Array is array (Positive range <>) of Long_Float;

   --  The middle of a set of rounds.
   --
   --  Every figure this tool feeds is published as a median of three, and
   --  this tool reported one pass. The spread is not small: the same number
   --  came out 11136, 12574 and 12944 Me/s on three consecutive runs, so a
   --  single pass read against a published median is worth about ten per
   --  cent either way -- enough to look like a regression that is not there,
   --  and enough to hide one that is. Taking the median here is the
   --  difference between a tool that answers the question and one that
   --  leaves the last step to whoever remembers it.
   function Middle (Values : Rate_Array) return Long_Float is
      Sorted : Rate_Array := Values;
   begin
      for Outer in Sorted'First .. Sorted'Last - 1 loop
         for Inner in Sorted'First .. Sorted'Last - 1 loop
            if Sorted (Inner) > Sorted (Inner + 1) then
               declare
                  Held : constant Long_Float := Sorted (Inner);
               begin
                  Sorted (Inner) := Sorted (Inner + 1);
                  Sorted (Inner + 1) := Held;
               end;
            end if;
         end loop;
      end loop;
      return Sorted (Sorted'First + Sorted'Length / 2);
   end Middle;

   --  Elements per second, or zero when nothing was timed.
   function Rate_Of
     (Elements : Long_Long_Integer; Elapsed : Duration) return Long_Float
   is (if Long_Float (Elapsed) > 0.0
       then Long_Float (Elements) / Long_Float (Elapsed)
       else 0.0);

   --  Report one rate.
   procedure Report_Rate
     (Name     : String;
      Rate     : Long_Float;
      Relative : Long_Float := 0.0)
   is
      package IO renames Ada.Text_IO;

      Label   : String (1 .. 34) := [others => ' '];
      Room    : constant Natural := Natural'Min (Name'Length, Label'Length);
   begin
      Label (1 .. Room) := Name (Name'First .. Name'First + Room - 1);
      IO.Put ("  " & Label);

      --  Elements per second, and the nanoseconds each one cost.
      IO.Put (Long_Float'Image (Rate / 1.0E6) & " Me/s");
      if Rate > 0.0 then
         IO.Put ("   " & Long_Float'Image (1.0E9 / Rate) & " ns/element");
      end if;

      --  Where a reference was measured in this same run, this is the figure
      --  worth keeping. It survives a different machine, a busy one and a
      --  throttled one, and an absolute rate survives none of those. Quoted
      --  as a cost so that it rises when the code gets slower.
      if Relative > 0.0 and then Rate > 0.0 then
         IO.Put
           ("   " & Long_Float'Image (Relative / Rate) & " x a copied byte");
      end if;
      IO.New_Line;
   end Report_Rate;

   --  Report one measurement.
   procedure Report
     (Name     : String;
      Elements : Long_Long_Integer;
      Elapsed  : Duration;
      Relative : Long_Float := 0.0)
   is
   begin
      Report_Rate (Name, Rate_Of (Elements, Elapsed), Relative);
   end Report;

   ---------
   -- Run --
   ---------

   procedure Run (Seconds : Duration := 0.5; Rounds : Positive := 3) is
      package IO renames Ada.Text_IO;
      use type Ada.Real_Time.Time;

      --  Time a kernel until at least Seconds have passed, then report the
      --  cost per element over everything actually done.
      --
      --  These rates are comparable within one sitting and not across two.
      --  Repeated on an idle machine, the same binary reports each kernel to
      --  within about half a percent; hours apart, on a laptop that has
      --  changed thermal and clock state, the same binary has reported 785
      --  and 598 Me/s for the same kernel. So a change is worth believing
      --  only when the two versions were run against each other in one
      --  sitting, alternating -- old, new, old -- and it survived.
      --
      --  Two attempts to make a single run mean something on its own were
      --  measured and dropped. Dividing by a memory copy timed in the same
      --  round, which is what makes the parse figure below comparable, was
      --  worse than the plain rate for nine of the twelve kernels: a copy is
      --  bound by memory and these are bound by arithmetic, so the two do
      --  not move together and the division adds the copy's noise instead of
      --  removing the kernel's. Dividing by the f32 dot product, which is
      --  bound by the same thing, was worse still. Timing five short rounds
      --  and keeping the best was worse than one long one, because each
      --  round then measures a fifth as much work and the best of five short
      --  rounds is an optimistic one rather than an undisturbed one.
      procedure Measure
        (Name        : String;
         Format      : G.Tensor_Type;
         Use_Row_Dot : Boolean)
      is
         Bytes_Per_Row : constant B.Byte_Count :=
           B.Byte_Count (Columns)
           / B.Byte_Count (G.Block_Elements (Format))
           * B.Byte_Count (G.Block_Bytes (Format));

         Data   : B.Byte_Array_Access;
         Item   : T.View;
         Status : E.Error_Info;

         Vector : N.Real_Array (0 .. Columns - 1);
         Target : N.Real_Array (0 .. Rows - 1) := [others => 0.0];
         Scratch : N.Real_Array (0 .. Columns - 1) := [others => 0.0];

         Started  : Ada.Real_Time.Time;
         Done     : N.Element_Count := 0;
         Guard    : N.Real := 0.0;
         Rates    : Rate_Array (1 .. Rounds) := [others => 0.0];
      begin
         B.Allocate (Bytes_Per_Row * B.Byte_Count (Rows), Data);
         if Data = null then
            IO.Put_Line ("  " & Name & ": allocation failed");
            return;
         end if;

         Fill (Data.all);
         Tame_Scales
           (Data.all, Format,
            B.Byte_Count (Rows) * B.Byte_Count (Columns)
            / B.Byte_Count (G.Block_Elements (Format)));

         T.Make (Format, Rows, Columns, Data, 0, Item, Status);
         if E.Is_Error (Status) then
            IO.Put_Line ("  " & Name & ": view rejected");
            B.Free (Data);
            return;
         end if;

         for Index in Vector'Range loop
            Vector (Index) := N.Real (Index mod 17) * 0.125 - 1.0;
         end loop;

         for Pass in Rates'Range loop
            Done := 0;
            Started := Ada.Real_Time.Clock;
            loop
               if Use_Row_Dot then
                  for Row in 0 .. Rows - 1 loop
                     Target (Row) := T.Row_Dot (Item, Row, Vector);
                  end loop;
                  Guard := Guard + Target (0);
               else
                  for Row in 0 .. Rows - 1 loop
                     T.Dequantize_Row (Item, Row, Scratch, Status);
                  end loop;
                  Guard := Guard + Scratch (0);
               end if;

               Done := Done + Rows * Columns;
               exit when Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started) >= Seconds;
            end loop;

            Rates (Pass) :=
              Rate_Of (Long_Long_Integer (Done),
                       Ada.Real_Time.To_Duration
                         (Ada.Real_Time.Clock - Started));
         end loop;

         Report_Rate (Name, Middle (Rates));

         --  Keep the result live so the loop cannot be optimized away.
         if Guard = N.Real'Last then
            IO.Put_Line ("");
         end if;

         B.Free (Data);
      end Measure;

      --  What sampling costs a token.
      --
      --  It runs once per token produced and over as many candidates as
      --  the model has tokens, and every fixture here has sixteen of them.
      --  A real vocabulary is tens of thousands, which is the size at which
      --  sorting all of them starts to be worth knowing about.
      procedure Measure_Sampling (Name : String; Greedy : Boolean) is
         Words : constant := 32_000;

         Logits : N.Real_Array (0 .. Words - 1);

         Item     : Model_Runner.Sampling.Sampler;
         Settings : Model_Runner.Sampling.Configuration :=
           Model_Runner.Sampling.Greedy_Configuration;
         Token    : Model_Runner.Tokenizer.Token_Id;
         Status   : E.Error_Info;

         Started : Ada.Real_Time.Time;
         Done    : N.Element_Count := 0;
         Guard   : Natural := 0;
         Rates   : Rate_Array (1 .. Rounds) := [others => 0.0];
      begin
         --  A distribution with a shape: a few large logits and a long
         --  tail, which is what a model produces and what decides how much
         --  work the truncation steps do.
         for Index in Logits'Range loop
            Logits (Index) :=
               N.Real (Natural (Index) mod 977) * 0.01 - 5.0;
         end loop;

         if not Greedy then
            Settings.Temperature := 0.8;
            Settings.Top_K := 40;
            Settings.Top_P := 0.95;
            Settings.Min_P := 0.05;
            Settings.Repeat_Penalty := 1.1;
         end if;

         Model_Runner.Sampling.Open (Item, Settings, Words, 1, Status);
         if E.Is_Error (Status) then
            IO.Put_Line ("  " & Name & ": the sampler did not open");
            return;
         end if;

         for Pass in Rates'Range loop
            Done := 0;
            Started := Ada.Real_Time.Clock;
            loop
               Model_Runner.Sampling.Sample (Item, Logits, Token, Status);
               if E.Is_Ok (Status) then
                  Guard := Guard + 1;
               end if;

               Done := Done + 1;
               exit when Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started) >= Seconds;
            end loop;

            Rates (Pass) :=
              Rate_Of (Long_Long_Integer (Done),
                       Ada.Real_Time.To_Duration
                         (Ada.Real_Time.Clock - Started));
         end loop;

         Report_Rate (Name, Middle (Rates));

         if Guard = Natural'Last then
            IO.Put_Line ("");
         end if;

         Model_Runner.Sampling.Close (Item);
      end Measure_Sampling;

      --  What a grammar costs a step.
      --
      --  Every token of the vocabulary is offered to the matcher before
      --  anything is sampled, so the filter runs as often as a token is
      --  produced and over as many texts as the model has tokens. The
      --  fixtures this suite uses have sixteen; a real vocabulary has tens
      --  of thousands, and nothing in the tests would show the difference.
      --  This does: one step over a vocabulary of that size.
      procedure Measure_Grammar (Name : String; Inside : Boolean) is
         Words : constant := 32_000;

         --  A quote, written once: the grammar below is full of them and
         --  doubling them inside a literal makes it unreadable.
         Q : constant String := [1 => Character'Val (34)];

         Source : constant String :=
           "root ::= object" & ASCII.LF
           & "object ::= " & Q & "{" & Q & " ws pair (ws " & Q & "," & Q
           & " ws pair)* ws " & Q & "}" & Q & ASCII.LF
           & "pair ::= string ws " & Q & ":" & Q & " ws value" & ASCII.LF
           & "value ::= string | number | object" & ASCII.LF
           & "string ::= " & Q & "\" & Q & Q & " [a-z]* " & Q & "\" & Q
           & Q & ASCII.LF
           & "number ::= [0-9]+" & ASCII.LF
           & "ws ::= [ ]*";

         --  A stand-in vocabulary: short pieces over the printable range,
         --  which is what a real one is mostly made of.
         type Piece is record
            Last : Natural := 0;
            Text : String (1 .. 8) := [others => ' '];
         end record;

         type Piece_Array is array (1 .. Words) of Piece;
         type Piece_Array_Access is access Piece_Array;

         Pieces : constant Piece_Array_Access := new Piece_Array;

         Item   : Model_Runner.Grammar.Compiled;
         State  : Model_Runner.Grammar.Matcher;
         Status : E.Error_Info;

         Started : Ada.Real_Time.Time;
         Done    : N.Element_Count := 0;
         Guard   : Natural := 0;
         Rates   : Rate_Array (1 .. Rounds) := [others => 0.0];
      begin
         for Index in Pieces'Range loop
            declare
               Length : constant Natural := 1 + (Index mod 6);
            begin
               Pieces (Index).Last := Length;
               for Where in 1 .. Length loop
                  Pieces (Index).Text (Where) :=
                    Character'Val
                      (32 + ((Index * 7 + Where * 13) mod 94));
               end loop;
            end;
         end loop;

         Model_Runner.Grammar.Compile (Item, Source, Status);
         if E.Is_Error (Status) then
            IO.Put_Line ("  grammar filter: the grammar did not compile");
            return;
         end if;

         Model_Runner.Grammar.Start (Item, State, Status);

         --  Two states, because they cost differently and both are real. At
         --  the start only one character may follow, so almost every token
         --  is refused by its first byte and never simulated. Inside a
         --  string most letters may follow, so most tokens are simulated to
         --  the end -- and that is the case a grammar is slowest in.
         if Inside then
            Model_Runner.Grammar.Advance (Item, State, "{", Status);
            Model_Runner.Grammar.Advance
              (Item, State, [1 => Character'Val (34)], Status);
            Model_Runner.Grammar.Advance (Item, State, "ab", Status);
         end if;

         for Pass in Rates'Range loop
            Done := 0;
            Started := Ada.Real_Time.Clock;
            loop
               for Index in Pieces'Range loop
                  if Model_Runner.Grammar.Accepts
                       (Item, State,
                        Pieces (Index).Text (1 .. Pieces (Index).Last))
                  then
                     Guard := Guard + 1;
                  end if;
               end loop;

               Done := Done + Words;
               exit when Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started) >= Seconds;
            end loop;

            Rates (Pass) :=
              Rate_Of (Long_Long_Integer (Done),
                       Ada.Real_Time.To_Duration
                         (Ada.Real_Time.Clock - Started));
         end loop;

         Report_Rate (Name, Middle (Rates));

         if Guard = Natural'Last then
            IO.Put_Line ("");
         end if;

         Model_Runner.Grammar.Close (Item);
      end Measure_Grammar;

      --  The vector kernels each token passes through, which the measures
      --  above do not touch: normalization before every attention and feed
      --  forward block, softmax over the attention scores and again over the
      --  vocabulary, and the activation between the feed forward matrices.
      --  A row product is the larger cost, but these run just as often and
      --  nothing here was measuring them.
      procedure Measure_Vector (Name : String; Which : Character) is
         Length : constant N.Element_Count := 4096;
         Values : N.Real_Array (0 .. Length - 1);
         Weight : constant N.Real_Array (0 .. Length - 1) := [others => 1.0];
         Target : N.Real_Array (0 .. Length - 1) := [others => 0.0];
         Started : Ada.Real_Time.Time;
         Done    : N.Element_Count := 0;
         Guard   : N.Real := 0.0;
         Ok      : Boolean;
         Rates   : Rate_Array (1 .. Rounds) := [others => 0.0];
      begin
         for Index in Values'Range loop
            Values (Index) := N.Real (Index mod 23) * 0.125 - 1.0;
         end loop;

         for Pass in Rates'Range loop
            Done := 0;
            Started := Ada.Real_Time.Clock;
            loop
               case Which is
                  when 'S' =>
                     Target := Values;
                     Model_Runner.Kernels.Softmax (Target, Ok);
                     Guard := Guard + Target (0);
                  when 'N' =>
                     Model_Runner.Kernels.RMS_Norm
                       (Values, Weight, 1.0E-5, Target);
                     Guard := Guard + Target (0);
                  when 'L' =>
                     Target := Values;
                     Model_Runner.Kernels.SiLU (Target);
                     Guard := Guard + Target (0);
                  when others =>
                     Guard := Guard
                       + Model_Runner.Kernels.Dot (Values, Weight);
               end case;

               Done := Done + Length;
               exit when Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started) >= Seconds;
            end loop;

            Rates (Pass) :=
              Rate_Of (Long_Long_Integer (Done),
                       Ada.Real_Time.To_Duration
                         (Ada.Real_Time.Clock - Started));
         end loop;

         Report_Rate (Name, Middle (Rates));

         if Guard = N.Real'Last then
            IO.Put_Line ("");
         end if;
      end Measure_Vector;

      --  How the matrix product scales, with nothing else in the way.
      --
      --  Counted in shares rather than workers, because a job is cut into one
      --  more piece than the pool has workers: the task that submits it takes
      --  the last piece instead of waiting. One share is therefore the serial
      --  path and no pool at all, and eight shares is a pool of seven. Naming
      --  the rows after the workers, as this once did, made a pool of one
      --  look like the serial baseline when it was already two-way parallel,
      --  and halved every speedup below it.
      --
      --  A whole run reaches about four and a half times on eight cores, and
      --  the question this answers is whether that ceiling is in the kernel
      --  or in what surrounds it. The weight matrix here is larger than this
      --  machine's last-level cache, so every pass reads it from memory, as a
      --  real one does. Count is what separates the two cases a run spends
      --  its time in: one vector per pass is generating a token, where each
      --  weight byte is read for a single multiply, and thirty-two is
      --  How much slower the reference backend is than the CPU one.
      --
      --  The README and the support matrix publish that ratio -- "about
      --  forty times as long" -- and it was taken by hand, once, with
      --  nothing able to produce it again. A published figure that cannot be
      --  re-measured is a figure the fingerprint duty cannot be discharged
      --  for: the check says re-measure and record what you get, and there
      --  was nothing to run.
      --
      --  Both are given the same view and the same vector, on one task, so
      --  what is compared is the two ways of multiplying and nothing else.
      --  The CPU side is measured through a null pool, which is its serial
      --  path: a ratio against a pool would be a ratio against this
      --  machine's core count as well.
      procedure Measure_Reference_Ratio
        (Name   : String;
         Format : G.Tensor_Type := G.Type_Q8_0)
      is
         Rows    : constant N.Element_Count := 512;
         Columns : constant N.Element_Count := 2048;
         Width   : constant B.Byte_Count :=
           B.Byte_Count (Columns) / B.Byte_Count (G.Block_Elements (Format))
           * B.Byte_Count (G.Block_Bytes (Format));

         Data   : B.Byte_Array_Access;
         Item   : T.View;
         Status : E.Error_Info;

         Inputs  : T.Real_Array_Access;
         Outputs : T.Real_Array_Access;

         Fast, Slow : Long_Float := 0.0;

         --  Passes per second of one product, by whichever backend.
         function Passes_Of (Reference : Boolean) return Long_Float is
            Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
            Passes  : Long_Long_Integer := 0;
            Elapsed : Duration := 0.0;
         begin
            loop
               if Reference then
                  Model_Runner.Backend.Reference.Product
                    (Item, Inputs, Outputs, Status);
               else
                  Model_Runner.Backend.CPU.Dispatch
                    (null, Item, Inputs, Outputs, Status);
               end if;
               exit when E.Is_Error (Status);
               Passes := Passes + 1;
               Elapsed := Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started);
               exit when Elapsed >= Seconds;
            end loop;

            if Elapsed <= 0.0 or else Passes = 0 then
               return 0.0;
            end if;
            return Long_Float (Passes) / Long_Float (Elapsed);
         end Passes_Of;
      begin
         T.Allocate (Columns, Inputs);
         T.Allocate (Rows, Outputs);
         B.Allocate (Width * B.Byte_Count (Rows), Data);
         if Data = null or else Inputs = null or else Outputs = null then
            return;
         end if;
         Fill (Data.all);
         Tame_Scales (Data.all, Format,
                      B.Byte_Count (Rows) * B.Byte_Count (Columns)
                      / B.Byte_Count (G.Block_Elements (Format)));
         T.Make (Format, Rows, Columns, Data, 0, Item, Status);
         if E.Is_Error (Status) then
            B.Free (Data);
            return;
         end if;

         for Index in Inputs.all'Range loop
            Inputs.all (Index) := N.Real (Index mod 17) * 0.125 - 1.0;
         end loop;

         declare
            Quick : Rate_Array (1 .. Rounds) := [others => 0.0];
            Plain : Rate_Array (1 .. Rounds) := [others => 0.0];
         begin
            for Pass in Quick'Range loop
               Quick (Pass) := Passes_Of (Reference => False);
               Plain (Pass) := Passes_Of (Reference => True);
            end loop;
            Fast := Middle (Quick);
            Slow := Middle (Plain);
         end;

         if Fast > 0.0 and then Slow > 0.0 then
            IO.Put_Line
              ("  " & Name & Long_Float'Image (Fast / Slow)
               & "x slower on the reference backend");
         end if;

         B.Free (Data);
         T.Free (Inputs);
         T.Free (Outputs);
      end Measure_Reference_Ratio;

      --  evaluating a prompt, where the same byte serves thirty-two.
      procedure Measure_Scaling
        (Name             : String;
         Vectors_Per_Pass : N.Element_Count;
         Format           : G.Tensor_Type := G.Type_Q8_0)
      is
         Rows    : constant N.Element_Count := 4096;
         Columns : constant N.Element_Count := 4096;
         Width   : constant B.Byte_Count :=
           B.Byte_Count (Columns) / B.Byte_Count (G.Block_Elements (Format))
           * B.Byte_Count (G.Block_Bytes (Format));

         Data   : B.Byte_Array_Access;
         Item   : T.View;
         Status : E.Error_Info;

         Inputs  : T.Real_Array_Access;
         Outputs : T.Real_Array_Access;

         Cores : constant Positive := Model_Runner.Platform.Core_Count;
         Serial : Long_Float := 0.0;
      begin
         T.Allocate (Columns * Vectors_Per_Pass, Inputs);
         T.Allocate (Rows * Vectors_Per_Pass, Outputs);
         B.Allocate (Width * B.Byte_Count (Rows), Data);
         if Data = null or else Inputs = null or else Outputs = null then
            return;
         end if;
         Fill (Data.all);
         Tame_Scales (Data.all, Format,
                      B.Byte_Count (Rows) * B.Byte_Count (Columns)
                      / B.Byte_Count (G.Block_Elements (Format)));
         T.Make (Format, Rows, Columns, Data, 0, Item, Status);
         if E.Is_Error (Status) then
            B.Free (Data);
            return;
         end if;

         for Index in Inputs.all'Range loop
            Inputs.all (Index) := N.Real (Index mod 17) * 0.125 - 1.0;
         end loop;

         IO.Put_Line ("  " & Name);

         for Shares in 1 .. Cores loop
            declare
               Started : Ada.Real_Time.Time;
               Passes  : Long_Long_Integer := 0;
               Elapsed : Duration := 0.0;
               Rate    : Long_Float;

               --  One share is the serial path, which is a null pool
               --  reference rather than a pool of nothing.
               Team : aliased Model_Runner.Backend.CPU.Pool
                 (Model_Runner.Backend.CPU.Worker_Count
                    (Integer'Max (1, Shares - 1)));
               Rates : Rate_Array (1 .. Rounds) := [others => 0.0];
               Where : constant Model_Runner.Backend.CPU.Pool_Reference :=
                 (if Shares = 1 then null else Team'Unchecked_Access);
            begin
               for Pass in Rates'Range loop
                  Passes := 0;
                  Started := Ada.Real_Time.Clock;
                  loop
                     Model_Runner.Backend.CPU.Dispatch_Batch
                       (Where, Item, Inputs, Vectors_Per_Pass, Outputs,
                        Status);
                     exit when E.Is_Error (Status);
                     Passes := Passes + 1;
                     Elapsed := Ada.Real_Time.To_Duration
                       (Ada.Real_Time.Clock - Started);
                     exit when Elapsed >= Seconds;
                  end loop;

                  if Elapsed > 0.0 and then Passes > 0 then
                     Rates (Pass) :=
                       Long_Float (Passes)
                       * Long_Float (Long_Long_Integer (Rows)
                                     * Long_Long_Integer (Columns)
                                     * Long_Long_Integer (Vectors_Per_Pass))
                       / Long_Float (Elapsed);
                  end if;
               end loop;

               Rate := Middle (Rates);

               if Rate > 0.0 then
                  if Shares = 1 then
                     Serial := Rate;
                  end if;
                  IO.Put_Line
                    ("   " & Integer'Image (Shares)
                     & (if Shares = 1 then " share " else " shares")
                     & Long_Float'Image (Rate / 1.0E6) & " Me/s   "
                     & Long_Float'Image (Rate / Serial) & "x");
               end if;

               Model_Runner.Backend.CPU.Close (Team);
            end;
         end loop;

         B.Free (Data);
         T.Free (Inputs);
         T.Free (Outputs);
      end Measure_Scaling;

      --  Decode blocks with no arithmetic on top, to separate the cost of
      --  producing the values from the cost of using them.
      --  How many times a measurement is repeated before its best is kept.
      --
      --  A single timing on a shared machine carries a spread wider than the
      --  regressions worth catching: the same binary measured a twelfth apart
      --  run to run while this was being written. The best of several is the
      --  round that was interrupted least, which is the one that says most
      --  about the code.
      Parse_Rounds : constant := 5;

      Round_Seconds : constant Duration := Seconds / Parse_Rounds;

      --  A reference measured in this same run, under the same conditions.
      --
      --  An absolute rate says nothing on its own. It moves with the machine,
      --  its load and its clock, so a number recorded on one host cannot be
      --  compared with one produced on another -- and that comparison is
      --  exactly what catching a regression needs. Parsing is mostly copying
      --  bytes and looking at them, so a plain memory copy moves with the
      --  same things and divides them back out.
      Reference_Span : constant B.Byte_Count := 4 * 1024 * 1024;

      --  One round of the reference, run beside the round it is compared
      --  with rather than once before all of them.
      --
      --  That is what makes the ratio worth quoting. A disturbance that
      --  slows the machine for half a second slows both halves of the same
      --  round, and dividing one by the other takes most of it back out. A
      --  reference measured once, earlier, cancels nothing: it just moves
      --  the error into the answer.
      function Copy_Round
        (From : B.Byte_Array_Access;
         Into : B.Byte_Array_Access;
         Span : Duration) return Long_Float
      is
         Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
         Copies  : Long_Long_Integer := 0;
         Elapsed : Duration := 0.0;
      begin
         loop
            Into.all := From.all;

            --  Read back, so that nothing here can be discarded as work
            --  whose result is never wanted.
            Guard := Guard + Interfaces.Unsigned_64 (Into.all (Into.all'First));
            Copies := Copies + 1;
            Elapsed := Ada.Real_Time.To_Duration
              (Ada.Real_Time.Clock - Started);
            exit when Elapsed >= Span;
         end loop;

         if Elapsed <= 0.0 then
            return 0.0;
         end if;

         return Long_Float (Copies * Long_Long_Integer (Reference_Span))
           / Long_Float (Elapsed);
      end Copy_Round;

      --  Time parsing a metadata-heavy container.
      --
      --  Loading a model is not a kernel, but it is the first thing a run
      --  spends time on, and until this was here a change to the reader could
      --  cost a fifth of it without anything noticing. A vocabulary is what
      --  makes a real file's metadata large: a hundred thousand token strings
      --  and their scores, which is the shape of a small real model.
      procedure Measure_Parse is
         Tokens  : constant := 100_000;
         Builder : Fixtures.Builder;
         Image   : B.Byte_Array_Access;
         Passes       : Long_Long_Integer := 0;
         Started      : Ada.Real_Time.Time;
         Elapsed      : Duration := 0.0;
         Best_Cost    : Long_Float := 0.0;
         Copy_Rate    : Long_Float := 0.0;
         Kept_Copy    : Long_Float := 0.0;
         Kept_Passes  : Long_Long_Integer := 0;
         Kept_Elapsed : Duration := 0.0;
         From         : B.Byte_Array_Access;
         Into         : B.Byte_Array_Access;
      begin
         Fixtures.Reset (Builder);
         Fixtures.Add_String (Builder, "general.architecture", "llama");
         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.tokens", G.Value_String, Tokens);
         for Index in 1 .. Tokens loop
            Fixtures.String_Element
              (Builder, "token" & Integer'Image (Index) & "xyzzy");
         end loop;
         Fixtures.End_Array (Builder);

         Fixtures.Begin_Array
           (Builder, "tokenizer.ggml.scores", G.Value_Float32, Tokens);
         for Index in 1 .. Tokens loop
            Fixtures.Float_Element (Builder, N.Real (Index));
         end loop;
         Fixtures.End_Array (Builder);
         Fixtures.Build (Builder, Image);

         if Image = null then
            return;
         end if;

         B.Allocate (Reference_Span, From);
         B.Allocate (Reference_Span, Into);

         if From = null or else Into = null then
            B.Free (From);
            B.Free (Into);
            B.Free (Image);
            return;
         end if;

         Fill (From.all);

         for Round in 1 .. Parse_Rounds loop
            --  The reference first, then the parse, in the same round.
            Copy_Rate := Copy_Round (From, Into, Round_Seconds / 2);

            Passes := 0;
            Started := Ada.Real_Time.Clock;

            loop
               declare
                  Held   : aliased constant B.Byte_Array := Image.all;
                  Source : Model_Runner.Byte_Sources.Memory.Buffer_Source
                    (Held'Access);
                  Item   : Model_Runner.GGUF.Containers.Container;
                  Status : E.Error_Info;
               begin
                  Model_Runner.GGUF.Containers.Reader.Parse
                    (Item, Source, Model_Runner.Limits.Default_Model_Limits,
                     null, null, Status);
                  exit when E.Is_Error (Status);
                  Model_Runner.GGUF.Containers.Close (Item);
               end;

               Passes := Passes + 1;
               Elapsed := Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started);
               exit when Elapsed >= Round_Seconds / 2;
            end loop;

            --  The round with the lowest cost against its own reference,
            --  not the average of the rounds: a slow round measured the
            --  machine rather than the reader, and this is what says so.
            if Elapsed > 0.0 and then Copy_Rate > 0.0 and then Passes > 0 then
               declare
                  Rate : constant Long_Float :=
                    Long_Float (Passes * Long_Long_Integer (Image.all'Length))
                    / Long_Float (Elapsed);
                  Cost : constant Long_Float := Copy_Rate / Rate;
               begin
                  if Best_Cost = 0.0 or else Cost < Best_Cost then
                     Best_Cost := Cost;
                     Kept_Passes := Passes;
                     Kept_Elapsed := Elapsed;
                     Kept_Copy := Copy_Rate;
                  end if;
               end;
            end if;
         end loop;

         --  Reported per byte of container, which is what a reader's cost
         --  scales with and what makes it comparable across fixtures.
         Report
           ("metadata parse, per byte",
            Kept_Passes * Long_Long_Integer (Image.all'Length), Kept_Elapsed,
            Kept_Copy);
         B.Free (From);
         B.Free (Into);
         B.Free (Image);
      end Measure_Parse;

      procedure Measure_Decode (Name : String; Format : G.Tensor_Type) is
         Per_Block : constant N.Element_Count :=
           N.Element_Count (G.Block_Elements (Format));
         Width     : constant B.Byte_Count :=
           B.Byte_Count (G.Block_Bytes (Format));
         Count     : constant B.Byte_Count := 4096;

         Data    : B.Byte_Array_Access;
         Block   : Q.Block_Buffer;
         Ok      : Boolean;
         Started : Ada.Real_Time.Time;
         Done    : N.Element_Count := 0;
         Guard   : N.Real := 0.0;
         Rates   : Rate_Array (1 .. Rounds) := [others => 0.0];
      begin
         B.Allocate (Width * Count, Data);
         if Data = null then
            return;
         end if;
         Fill (Data.all);
         Tame_Scales (Data.all, Format, Count);

         for Pass in Rates'Range loop
            Done := 0;
            Started := Ada.Real_Time.Clock;
            loop
               for Index in 0 .. Count - 1 loop
                  Q.Decode_Block (Format, Data.all, Index * Width, Block, Ok);
                  Guard := Guard + Block (0);
               end loop;

               Done := Done + N.Element_Count (Count) * Per_Block;
               exit when Ada.Real_Time.To_Duration
                 (Ada.Real_Time.Clock - Started) >= Seconds;
            end loop;

            Rates (Pass) :=
              Rate_Of (Long_Long_Integer (Done),
                       Ada.Real_Time.To_Duration
                         (Ada.Real_Time.Clock - Started));
         end loop;

         Report_Rate (Name, Middle (Rates));

         if Guard = N.Real'Last then
            IO.Put_Line ("");
         end if;
         B.Free (Data);
      end Measure_Decode;

   begin
      IO.Put_Line ("kernel benchmarks, single task, "
                   & N.Element_Count'Image (Rows) & " x"
                   & N.Element_Count'Image (Columns) & " per pass");
      IO.New_Line;

      IO.Put_Line ("row dot product");
      Measure ("q8_0 Row_Dot", G.Type_Q8_0, True);
      Measure ("q4_0 Row_Dot", G.Type_Q4_0, True);
      Measure ("q2_k Row_Dot", G.Type_Q2_K, True);
      Measure ("q3_k Row_Dot", G.Type_Q3_K, True);
      Measure ("q4_1 Row_Dot", G.Type_Q4_1, True);
      Measure ("q5_0 Row_Dot", G.Type_Q5_0, True);
      Measure ("q5_1 Row_Dot", G.Type_Q5_1, True);
      Measure ("q4_k Row_Dot", G.Type_Q4_K, True);
      Measure ("q5_k Row_Dot", G.Type_Q5_K, True);
      Measure ("q6_k Row_Dot", G.Type_Q6_K, True);
      Measure ("iq4nl Row_Dot", G.Type_IQ4_NL, True);
      Measure ("iq4xs Row_Dot", G.Type_IQ4_XS, True);
      Measure ("f16  Row_Dot", G.Type_F16, True);
      Measure ("bf16 Row_Dot", G.Type_BF16, True);
      Measure ("f32  Row_Dot", G.Type_F32, True);
      IO.New_Line;

      IO.Put_Line ("row dequantization");
      Measure ("q8_0 Dequantize_Row", G.Type_Q8_0, False);
      Measure ("f16  Dequantize_Row", G.Type_F16, False);
      Measure ("q4_k Dequantize_Row", G.Type_Q4_K, False);
      Measure ("f32  Dequantize_Row", G.Type_F32, False);
      IO.New_Line;

      IO.Put_Line ("matrix product across shares");
      Measure_Scaling ("q8_0, one vector per pass, as when generating", 1);
      Measure_Scaling ("q4_k, one vector per pass", 1, G.Type_Q4_K);
      Measure_Scaling ("q8_0, thirty-two per pass, as when evaluating a prompt",
                       32);
      Measure_Scaling ("q4_k, thirty-two per pass", 32, G.Type_Q4_K);
      IO.New_Line;

      IO.Put_Line ("reference backend against the CPU one, serial");
      Measure_Reference_Ratio ("q8_0");
      Measure_Reference_Ratio ("q4_k", G.Type_Q4_K);
      Measure_Reference_Ratio ("f32 ", G.Type_F32);
      IO.New_Line;

      IO.Put_Line ("sampling, one token chosen from 32000");
      Measure_Sampling ("greedy", True);
      Measure_Sampling ("top-k, top-p, min-p, penalties", False);
      IO.New_Line;

      IO.Put_Line ("output grammar, one token filtered");
      Measure_Grammar ("at a place one character may follow", False);
      Measure_Grammar ("inside a string, where most may", True);
      IO.New_Line;

      IO.Put_Line ("vector kernels");
      Measure_Vector ("softmax", 'S');
      Measure_Vector ("rms norm", 'N');
      Measure_Vector ("silu", 'L');
      Measure_Vector ("dot", 'D');
      IO.New_Line;

      IO.Put_Line ("metadata parsing");
      Measure_Parse;
      IO.New_Line;

      IO.Put_Line ("block decode alone");
      Measure_Decode ("q8_0 Decode_Block", G.Type_Q8_0);
      Measure_Decode ("q4_k Decode_Block", G.Type_Q4_K);
      Measure_Decode ("q5_k Decode_Block", G.Type_Q5_K);
      Measure_Decode ("q6_k Decode_Block", G.Type_Q6_K);
      Measure_Decode ("f32  Decode_Block", G.Type_F32);
   end Run;

end Benchmarks;
