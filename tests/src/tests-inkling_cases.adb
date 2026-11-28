with System;
with Ada.Real_Time;
with Model_Runner.Platform.Device;
with Model_Runner.Shares;
with Model_Runner.Platform;
with Model_Runner.Memory;
with Model_Runner.Cache_Codecs.Transformed_Four_Bit;
with Transformed_Four_Bit_Reference;
with AUnit.Assertions;
with AUnit.Test_Cases;
with Model_Runner.Bytes;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Tiny_Model;
with Fixtures;
with Model_Runner.Kernels;
with Model_Runner.Backend;
with Model_Runner.Numerics;
with Model_Runner.Tokenizer;
with Ada.Text_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Interfaces;
with Jsonlib.Documents;
with Jsonlib.Parsers;
with Jsonlib.Errors;
with Project_Tools.Files;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Backend.CPU;
with Ada.Directories;
with Model_Runner.Backend.Device;
with Model_Runner.Platform.Device.Products;
with Device_Notes;
with Model_Runner.Cancellation;
with Model_Runner.Quantization.Integers;
with Model_Runner.Generation;
with Model_Runner.Grammar;
with Model_Runner.Stops;
with Model_Runner.Tensors;
with Model_Runner.Llama.Adapter_Testing;
with Model_Runner.Quantization.Interleave;

package body Tests.Inkling_Cases is
   use AUnit.Assertions;
   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package C renames Model_Runner.GGUF.Containers;
   package L renames Model_Runner.Llama;
   use type E.Error_Code;
   use type Model_Runner.Tokenizer.Token_Id;
   use type L.Architecture;
   use type L.Feature_Layers;
   use type Model_Runner.Tokenizer.Token_Array;
   use type Model_Runner.GGUF.Tensor_Type;
   use type L.Real;
   use type B.Byte_Count;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Tiny_Model.Inkling_Fault;
   use type Model_Runner.Numerics.Real_Array;
   use type Model_Runner.Numerics.Element_Count;
   use type Model_Runner.Numerics.Wide_Real;
   use type Interfaces.Unsigned_16;
   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_64;
   use type Jsonlib.Errors.Error_Code;
   use type Ada.Streams.Stream_Element_Offset;
   package J renames Jsonlib.Documents;
   package U renames Ada.Strings.Unbounded;

   procedure Reference_Packing (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      use type QI.Byte_Signed;
      use type Interfaces.Integer_32;
      Input_Text : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Expected_Text : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-reference.bin");
      Block_Text : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8-reference.bin");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input_Text'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Expected_Text'Length));
      Block_Expected : B.Byte_Array (1 .. B.Byte_Count (Block_Text'Length));
      Vectors : L.Real_Array (0 .. 1023);
      Values, Native : QI.Signed_Array (0 .. 1023);
      Scales : L.Real_Array (0 .. 31);
      Totals : QI.Sum_Array (0 .. 31);
      Halves : QI.Sum_Array (0 .. 63);
      Ok : Boolean;
   begin
      for Index in Input_Text'Range loop
         Input_Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Input_Text (Index)));
      end loop;
      for Index in Expected_Text'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Expected_Text (Index)));
      end loop;
      for Index in Block_Text'Range loop
         Block_Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Block_Text (Index)));
      end loop;
      for Index in Vectors'Range loop
         Vectors (Index) := B.Get_F32 (Input_Bytes, B.Byte_Count (Index) * 4, Ok);
         Assert (Ok, "Q8_K input is truncated");
      end loop;
      QI.Quantize_Vectors (Vectors, 4, 256, Native, Scales, Totals, Halves, Ok, Super => True);
      Assert (Ok, "default activation packing failed");
      QI.Quantize_Vectors
        (Vectors, 4, 256, Values, Scales, Totals, Halves, Ok, Super => True, Reference_Rounding => True);
      Assert (Ok, "reference activation packing failed");
      for Group in L.Element_Count range 0 .. 3 loop
         declare
            Base : constant B.Byte_Count := B.Byte_Count (Group) * 292;
            Scale : constant L.Real := B.Get_F32 (Expected, Base, Ok);
         begin
            Assert (Ok, "reference Q8_K scale is truncated");
            for Part in L.Element_Count range 0 .. 7 loop
               Assert (Model_Runner.Numerics.Bits (Scales (Group * 8 + Part))
                       = Model_Runner.Numerics.Bits (Scale), "reference scale bits differ");
            end loop;
            for Index in L.Element_Count range 0 .. 255 loop
               declare
                  Raw : constant Integer := Integer (Expected (Base + 5 + B.Byte_Count (Index)));
                  Byte : constant Integer := (if Raw > 127 then Raw - 256 else Raw);
               begin
                  Assert (Integer (Values (Group * 256 + Index)) = Byte,
                          "reference activation byte differs: " & Group'Image & ":" & Index'Image);
               end;
            end loop;
            for Part in L.Element_Count range 0 .. 15 loop
               declare
                  Sum : constant Interfaces.Integer_32 := Interfaces.Integer_32
                    (B.Get_I16 (Expected, Base + 260 + B.Byte_Count (Part) * 2, Ok));
               begin
                  Assert (Ok and then Halves (Group * 16 + Part) = Sum, "reference half-block sum differs");
               end;
            end loop;
         end;
      end loop;
      Assert (Native (257) /= Values (257), "reference rounding changed the default packing contract");
      QI.Quantize_Vectors
        (Vectors, 4, 256, Values, Scales, Totals, Halves, Ok, Reference_Rounding => True);
      Assert (Ok, "reference Q8_0 packing failed");
      for Block in L.Element_Count range 0 .. 31 loop
         declare
            Base : constant B.Byte_Count := B.Byte_Count (Block) * 34;
            Expected_Scale : constant Interfaces.Unsigned_32 := Interfaces.Unsigned_32
              (B.Get_U16 (Block_Expected, Base, Ok));
         begin
            Assert (Ok and then Interfaces.Unsigned_32 (Model_Runner.Numerics.To_Half (Scales (Block)))
                    = Expected_Scale, "reference Q8_0 scale differs");
            for Index in L.Element_Count range 0 .. 31 loop
               declare
                  Raw : constant Integer := Integer (Block_Expected (Base + 3 + B.Byte_Count (Index)));
                  Byte : constant Integer := (if Raw > 127 then Raw - 256 else Raw);
               begin
                  Assert (Integer (Values (Block * 32 + Index)) = Byte,
                          "reference Q8_0 byte differs: " & Block'Image & ":" & Index'Image);
               end;
            end loop;
         end;
      end loop;
      declare
         package Tensors renames Model_Runner.Tensors;
         --  A Q5_0 row of ones: d=1, every unsigned code 17, hence 17-16.
         --  Its dot with independently packed block nine is exactly the
         --  reference half scale times the sum of its signed bytes.
         Encoded : B.Byte_Array (0 .. 175) := [others => 16#11#];
         Panels : aliased B.Byte_Array (0 .. 175);
         Input, Output : Tensors.Real_Array_Access := null;
         Team : aliased Model_Runner.Backend.CPU.Pool (2);
         Status : E.Error_Info;
         Weight : Tensors.View;
      begin
         for Row in B.Byte_Count range 0 .. 7 loop
            Encoded (Row * 22 .. Row * 22 + 5) := [0, 16#3C#, 16#FF#, 16#FF#, 16#FF#, 16#FF#];
         end loop;
         Model_Runner.Quantization.Interleave.Build
           (Format => Model_Runner.GGUF.Type_Q5_0, Source => Encoded, From => 0,
            Target => Panels, Into => 0, Rows => 8, Blocks => 1, Ok => Ok);
         Assert (Ok, "Q5_0 primitive panel could not be built");
         Weight := (Format => Model_Runner.GGUF.Type_Q5_0, Rows => 8, Columns => 32,
                    Role => Tensors.Role_Feed_Forward, Reference_Activations => True, Scales => null,
                    Base => Panels'Address, Span => Panels'Length, Offset => 0,
                    Length => Panels'Length, Interleaved => True);
         Tensors.Allocate (32, Input);
         Tensors.Allocate (8, Output);
         Input.all := Vectors (288 .. 319);
         for Pooled in Boolean loop
            Model_Runner.Backend.CPU.Dispatch
              ((if Pooled then Team'Unchecked_Access else null), Weight, Input, Output, Status,
               Roles => [others => True]);
            Assert (E.Is_Ok (Status) and then Output (0) = -11.298828125,
                    "Q5_0 did not use its independently verified Q8_0 half activation scale: "
                    & Pooled'Image & " " & Status.Code'Image & " " & Output (0)'Image);
         end loop;
         Tensors.Free (Input);
         Tensors.Free (Output);
         Model_Runner.Backend.CPU.Close (Team);
      exception
         when others =>
            Tensors.Free (Input);
            Tensors.Free (Output);
            Model_Runner.Backend.CPU.Close (Team);
            raise;
      end;
   end Reference_Packing;

   procedure Reference_Q8_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      Encoded : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8-reference.bin");
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8-dot-reference.bin");
      Bytes : B.Byte_Array (1 .. B.Byte_Count (Encoded'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Values : QI.Signed_Array (7 .. 1030);
      Scales : L.Real_Array (3 .. 34);
      Totals : constant QI.Sum_Array (0 .. 31) := [others => 0];
      Halves : constant QI.Sum_Array (0 .. 63) := [others => 0];
      Sums : N.Wide_Real_Array (11 .. 14) := [others => 0.0];
      Ok : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Wide_Vectors then return; end if;
      QI.Use_Wide_Rows (True);
      Assert (Encoded'Length = 1088 and then Golden'Length = 16, "independent Q8 dot fixture shape");
      for Index in Encoded'Range loop
         Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Encoded (Index)));
      end loop;
      for Index in Golden'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Golden (Index)));
      end loop;
      for Block in L.Element_Count range 0 .. 31 loop
         Scales (Scales'First + Block) := N.To_Real (N.Half (B.Get_U16 (Bytes, B.Byte_Count (Block) * 34, Ok)));
         Assert (Ok, "independent Q8 scale truncated");
         for Index in L.Element_Count range 0 .. 31 loop
            declare
               Raw : constant Integer := Integer (Bytes (Bytes'First + B.Byte_Count (Block) * 34
                                                         + 2 + B.Byte_Count (Index)));
            begin
               Values (Values'First + Block * 32 + Index) := QI.Byte_Signed (if Raw > 127 then Raw - 256 else Raw);
            end;
         end loop;
      end loop;
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q8_0, Bytes, 0, 544, 2, 16, Values, Scales, Totals, Halves,
         0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (Ok, "reference Q8 two-vector kernel declined");
      for Index in L.Element_Count range 0 .. 3 loop
         Assert (N.Bits (L.Real (Sums (Sums'First + Index)))
                 = N.Bits (B.Get_F32 (Expected, B.Byte_Count (Index) * 4, Ok)),
                 "Q8 binary32 lane product differs from independent reference at" & Index'Image);
         Assert (Ok, "independent Q8 dot result truncated");
      end loop;
      Sums := [others => 0.0];
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q8_0, Bytes, 0, 544, 2, 16, Values, Scales, Totals, Halves,
         512, 0, 1, Sums, Ok, Reference_Arithmetic => True);
      Assert (Ok and then L.Real (Sums (11)) = B.Get_F32 (Expected, 4, Ok)
              and then L.Real (Sums (12)) = B.Get_F32 (Expected, 12, Ok),
              "reference Q8 offset vector differs");
      Sums := [others => -123.0];
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q8_0, Bytes (1 .. Bytes'Last - 1), 0, 544, 2, 16,
         Values, Scales, Totals, Halves, 0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (not Ok and then (for all Value of Sums => Value = -123.0),
              "truncated Q8 weights changed the destination");
   end Reference_Q8_Products;

   procedure Selected_Output (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package CPU renames Model_Runner.Backend.CPU;
      package G renames Model_Runner.Generation;
      Image, Saved : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build_Inkling (Image, Quantized => True);
      CPU.Use_Integer_Activations (True);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live, Full : L.Session;
         Team : aliased CPU.Pool (2);
         Row : aliased L.Real_Array (0 .. 15);
         Expected, Alternative : L.Real_Array (0 .. 15);
         Stop : aliased Model_Runner.Cancellation.Token;
         Rules : aliased Model_Runner.Grammar.Compiled;
         Request : G.Request;
         Winner, Want : Model_Runner.Tokenizer.Token_Id;
         Endings : Model_Runner.Stops.Set;
         A, Z : G.Result;
         procedure Good (Where : String) is
         begin
            Assert (E.Is_Ok (Status), Where & ": " & Status.Code'Image);
         end Good;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status); Good ("selected parse");
         L.Prepare (Engine, Descriptor, Source, Status => Status); Good ("selected prepare");
         L.Open (Live, Engine, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Good ("selected open");
         L.Open (Full, Engine, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Good ("full open");
         Assert (L.Selected_Head_Available (Live, Engine), "selected head unavailable for CPU integer fixture");
         L.Evaluate (Full, Engine, 3, Expected, Status => Status); Good ("full projection");
         L.Evaluate_Selected (Live, Engine, 3, [1, 4, 9, 15], Row'Unrestricted_Access, Status => Status);
         Good ("selected projection");
         for I in Row'Range loop
            Assert (Row (I) = (if I in 1 | 4 | 9 | 15 then Expected (I) else L.Real'First),
                    "selected projection changed a qualified output or exposed a missing row");
         end loop;
         Assert (L.Position (Live) = 1, "selected token was not committed exactly once");
         L.Evaluate_Selected (Live, Engine, 4, [4, 4], Row'Unrestricted_Access, Status => Status);
         Assert (Status.Code = E.Tensor_Invalid_Shape and then L.Position (Live) = 1,
                 "duplicate selection advanced the context");
         L.Evaluate_Selected (Live, Engine, 4, [16], Row'Unrestricted_Access, Status => Status);
         Assert (Status.Code = E.Tensor_Invalid_Shape and then L.Position (Live) = 1,
                 "out-of-range selection advanced the context");
         Stop.Request;
         L.Evaluate_Selected (Live, Engine, 4, [1], Row'Unrestricted_Access,
                              Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then L.Position (Live) = 1,
                 "cancelled selected projection committed a token");
         Stop.Reset;
         L.Complete_Logits (Live, Engine, Row'Unrestricted_Access, Status); Good ("complete selected logits");
         Assert (Row = Expected and then L.Position (Live) = 1, "full materialization changed logits or position");
         L.Evaluate_Selected (Live, Engine, 4, [3, 5], Row'Unrestricted_Access, Status => Status);
         Good ("selected continuation");
         L.Snapshot (Live, Engine, Saved, Status); Good ("selected snapshot");
         L.Evaluate (Full, Engine, 4, Expected, Status => Status); Good ("full continuation");
         L.Evaluate (Full, Engine, 5, Alternative, Status => Status); Good ("full snapshot continuation");
         L.Adopt (Live, Engine, Saved.all, Status); Good ("selected snapshot adopt");
         L.Evaluate (Live, Engine, 5, Row, Status => Status); Good ("selected adopted continuation");
         Assert (Row = Alternative, "sparse snapshot changed full continuation");
         L.Reset (Live); L.Reset (Full);
         L.Evaluate_Selected (Live, Engine, 3, [1, 4], Row'Unrestricted_Access, Status => Status);
         Good ("selected rewind prefix");
         L.Evaluate_Selected (Live, Engine, 4, [2, 5], Row'Unrestricted_Access, Status => Status);
         Good ("selected rewind branch");
         L.Rewind (Live, 1, Status); Good ("selected rewind");
         L.Evaluate (Live, Engine, 5, Row, Status => Status); Good ("selected alternative branch");
         L.Evaluate (Full, Engine, 3, Expected, Status => Status); Good ("full rewind prefix");
         L.Evaluate (Full, Engine, 5, Expected, Status => Status); Good ("full alternative branch");
         Assert (Row = Expected, "rewind reused incomplete sparse logits or stale cache");
         L.Reset (Live); L.Reset (Full);
         L.Evaluate (Full, Engine, 3, Expected, Status => Status); Good ("greedy control");
         Want := 0;
         for I in Expected'Range loop
            if Expected (I) > Expected (L.Element_Count (Want)) then
               Want := Model_Runner.Tokenizer.Token_Id (I);
            end if;
         end loop;
         L.Evaluate_Greedy (Live, Engine, 3, Row'Unrestricted_Access, Winner, Status => Status);
         Good ("greedy fused head");
         Assert (Row = Expected and then Winner = Want and then L.Position (Live) = 1,
                 "greedy head changed full logits, winner or position");
         L.Reset (Live);
         L.Evaluate_Greedy (Live, Engine, 3, Row'Unrestricted_Access, Winner,
                            Forbidden => Want, Status => Status);
         Good ("greedy forbidden winner");
         Assert (Row = Expected and then Winner /= Want, "greedy head ignored forbidden winner");
         L.Evaluate_Greedy (Live, Engine, 4, Row'Unrestricted_Access, Winner,
                            Forbidden => 16, Status => Status);
         Assert (not E.Is_Ok (Status) and then L.Position (Live) = 1,
                 "invalid greedy exclusion advanced the context");
         Stop.Request;
         L.Evaluate_Greedy (Live, Engine, 4, Row'Unrestricted_Access, Winner,
                            Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then L.Position (Live) = 1,
                 "cancelled greedy evaluation committed a token");
         Stop.Reset;
         declare
            Tokens : constant Model_Runner.Tokenizer.Token_Array := [3, 4, 5];
            Winners : Model_Runner.Tokenizer.Token_Array (3 .. 5);
            All_Rows, Control_Rows : aliased L.Real_Array (0 .. 3 * 16 - 1);
         begin
            L.Reset (Live); L.Reset (Full);
            L.Evaluate_Batch (Full, Engine, Tokens, Expected, Every => Control_Rows'Unrestricted_Access,
                              Status => Status); Good ("batched greedy control");
            L.Evaluate_Greedy_Batch (Live, Engine, Tokens, Row, All_Rows'Unrestricted_Access, Winners,
                                     Forbidden => 1, Status => Status); Good ("batched greedy head");
            Assert (All_Rows = Control_Rows and then Row = Expected, "batched greedy changed complete logits");
            for Token in Winners'Range loop
               declare
                  Want : L.Element_Count := 0;
                  Base : constant L.Element_Count := L.Element_Count (Token - Winners'First) * 16;
               begin
                  for I in L.Element_Count range 0 .. 15 loop
                     if I /= 1 and then All_Rows (Base + I) > All_Rows (Base + Want) then Want := I; end if;
                  end loop;
                  Assert (Winners (Token) = Model_Runner.Tokenizer.Token_Id (Want),
                          "batched greedy maximum or lowest-ID tie changed");
               end;
            end loop;
            L.Evaluate_Greedy_Batch (Live, Engine, Tokens, Row, All_Rows'Unrestricted_Access, Winners (3 .. 4),
                                     Status => Status);
            Assert (not E.Is_Ok (Status) and then L.Position (Live) = 3,
                    "malformed winner shape committed a batch");
            Stop.Request;
            L.Evaluate_Greedy_Batch (Live, Engine, Tokens, Row, All_Rows'Unrestricted_Access, Winners,
                                     Cancel => Stop'Unchecked_Access, Status => Status);
            Assert (Status.Code = E.Generation_Cancelled and then L.Position (Live) = 3
                    and then (for all W of Winners => W = Model_Runner.Tokenizer.No_Token),
                    "cancelled greedy batch exposed winners or committed tokens");
            Stop.Reset;
            L.Reset (Live); L.Evaluate (Live, Engine, 3, Row, Status => Status); Good ("work-plan seed");
            declare
               Before : constant Interfaces.Unsigned_64 := L.Expert_Cache_Stats (Live).Work_Plan_Hits;
            begin
               L.Reset (Live); L.Evaluate (Live, Engine, 3, Alternative, Status => Status);
               Good ("work-plan reuse");
               Assert (Row = Alternative and then L.Expert_Cache_Stats (Live).Work_Plan_Hits > Before,
                       "repeated route descriptors were not reused or changed activations");
               Assert (L.Expert_Cache_Stats (Live).Work_Plan_Misses > 0, "work-plan miss counter did not advance");
            end;
         end;
         Model_Runner.Grammar.Compile (Rules, "root ::= [abc]+", Status); Good ("constrained grammar");
         Request.Max_Tokens := 8; Request.Sampling.Temperature := 0.0;
         Request.Retain_Text := True; Request.Has_Seed := True; Request.Seed := 1;
         L.Reset (Live); L.Reset (Full);
         G.Generate (Engine, Live, "a", Request, Endings, Rules => Rules'Unchecked_Access,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => A);
         Request.Constrained_Projection := False;
         G.Generate (Engine, Full, "a", Request, Endings, Rules => Rules'Unchecked_Access,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Z);
         Assert (E.Is_Ok (A.Error) and then E.Is_Ok (Z.Error)
                 and then A.Generated_Tokens = Z.Generated_Tokens and then A.Generated_Tokens > 1
                 and then G.Generated_Text (A) = G.Generated_Text (Z),
                 "selected constrained generation differs from complete projection");
         L.Evaluate (Live, Engine, 5, Row, Status => Status); Good ("post-generation selected continuation");
         L.Evaluate (Full, Engine, 5, Expected, Status => Status); Good ("post-generation full continuation");
         Assert (Row = Expected, "selected generation left an incomplete session boundary");
         G.Release (A); G.Release (Z);
         L.Close (Live); L.Close (Full); L.Close (Engine, Status); C.Close (Descriptor); CPU.Close (Team);
      exception
         when others =>
            G.Release (A); G.Release (Z);
            L.Close (Live); L.Close (Full); L.Close (Engine, Status); C.Close (Descriptor); CPU.Close (Team); raise;
      end;
      B.Free (Image);
      Tiny_Model.Build_Inkling (Image, Fault => Tiny_Model.Inkling_Aligned_Heads);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live, Full : L.Session;
         Expected : L.Real_Array (0 .. 15);
         Actual : aliased L.Real_Array (Expected'Range);
         Winner : Model_Runner.Tokenizer.Token_Id;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "unpacked-head fixture parse");
         L.Prepare (Engine, Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "unpacked-head fixture preparation");
         L.Open (Full, Engine, Context => 32, Status => Status);
         Assert (E.Is_Ok (Status), "unpacked-head control open");
         L.Open (Live, Engine, Context => 32, Status => Status);
         Assert (E.Is_Ok (Status), "unpacked-head greedy open");
         L.Evaluate (Full, Engine, 3, Expected, Status => Status);
         Assert (E.Is_Ok (Status), "unsupported packed output format did not use ordinary projection");
         L.Evaluate_Greedy (Live, Engine, 3, Actual'Unrestricted_Access, Winner, Status => Status);
         Assert (E.Is_Ok (Status) and then Actual = Expected
                 and then Winner /= Model_Runner.Tokenizer.No_Token,
                 "greedy fallback changed complete logits for an unpacked output head");
         for Value of Actual loop
            Assert (Actual (L.Element_Count (Winner)) >= Value, "greedy fallback chose a nonmaximum token");
         end loop;
         L.Close (Live); L.Close (Full); L.Close (Engine, Status); C.Close (Descriptor);
      exception
         when others => L.Close (Live); L.Close (Full); L.Close (Engine, Status); C.Close (Descriptor); raise;
      end;
      CPU.Use_Integer_Activations (False); B.Free (Image); B.Free (Saved);
   exception
      when others => CPU.Use_Integer_Activations (False); B.Free (Image); B.Free (Saved); raise;
   end Selected_Output;

   procedure Device_Relative_Packed (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package V renames Model_Runner.Backend.Device;
      package N renames Model_Runner.Numerics;
      Ready, Done : Boolean;
      Keys : constant B.Byte_Array (0 .. 31) := [others => 16#88#];
      Values : constant B.Byte_Array (0 .. 31) := [others => 16#99#];
      Query : constant L.Real_Array (0 .. 31) := [others => 0.0];
      Actual : L.Real_Array (0 .. 31) := [others => -123.0];
      Meta : L.Real_Array (0 .. 5) := [N.From_Bits (1), N.From_Bits (2), 0.0, N.From_Bits (96), 0.5, 0.25];
      P : constant L.Real := L.Real (N.Exp (-0.5));
      Sink : constant L.Real := L.Real (N.Exp (-0.75));
      Inv : constant L.Real := L.Real (1.0 / (N.Wide_Real (P) + N.Wide_Real (Sink) + 1.0));
      Expected : constant L.Real := L.Real (N.Wide_Real (P * Inv) + N.Wide_Real (Inv));
      procedure Run (At_Meta : Natural) is
      begin
         V.Attend_Packed
           (4, 4, Query, 1, 32, 32, 1, 0, 1, 0, 32, 32, 32, 40, 42, 1, 1,
            1.0, 0.0, Actual, Done, K_Codec => V.Transformed_Four_Bit_Cache,
            V_Codec => V.Scaled_Integer_Cache, Relative_At => At_Meta);
      end Run;
   begin
      if not Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_REFERENCE_GPU") then return; end if;
      V.Close; V.Open (Ready, Budget => 4_294_967_296, Tuning_Profile => "none");
      Assert (Ready, "native Q4T relative device open");
      V.Reserve_Cache (128, 0, Done); Assert (Done, "native Q4T cache reserve");
      V.Put_Cache_Bytes (0, Keys, Done); Assert (Done, "native Q4T keys upload");
      V.Put_Cache_Bytes (32, Values, Done); Assert (Done, "native Q4T values upload");
      V.Put_Cache (40, [1.0, 1.0, 1.0, 1.0], Done); Assert (Done, "native Q4T scales upload");
      V.Put_Cache (64, Meta, Done); Assert (Done, "native Q4T relative metadata upload");
      V.Put_Cache (96, [2.0, 1.0], Done); Assert (Done, "native Q4T bias table upload");
      Run (64); Assert (Done, "native Q4T relative dispatch did not execute");
      for Value of Actual loop
         Assert (abs (Value - Expected) <= 1.0E-6, "native Q4T relative bias or sink differs from scalar equation");
      end loop;
      declare
         package P renames Model_Runner.Platform.Device.Products;
         package TT renames Model_Runner.Tensors;
         Matrix : B.Byte_Array (0 .. 32 * 34 - 1) := [others => 0];
         W : TT.View;
         Input, Values, Raw, Output, Control : TT.Real_Array_Access := null;
         Status : E.Error_Info;
         procedure Append (Steps : in out V.Product_Sequence; Query_At : Natural; Added : out Boolean) is
         begin
            V.Add_Packed_Attention
              (Steps, 1, 32, 32, 1, 0, 1, 32, 32, 1.0, 0.0, Added,
               At_Vector => Query_At, Relative_At => 64,
               Packed => (K_Codec => P.Transformed_Four_Bit_Cache, V_Codec => P.Scaled_Integer_Cache,
                 K_Bits => 4, V_Bits => 4, K_Bytes => 0, V_Bytes => 32,
                 KS_At => 40, VS_At => 42, K_Blocks => 1, V_Blocks => 1));
         end Append;
         Recorder : constant V.Attention_Recorder := Append'Unrestricted_Access;
      begin
         for Row in B.Byte_Count range 0 .. 31 loop
            Matrix (Row * 34 + 1) := 16#3C#; Matrix (Row * 34 + 2 + Row) := 1;
         end loop;
         W := (Format => Model_Runner.GGUF.Type_Q8_0, Rows => 32, Columns => 32,
               Base => Matrix (0)'Address, Span => Matrix'Length, Offset => 0, Length => Matrix'Length,
               Interleaved => False, Role => TT.Role_Attention, Reference_Activations => True, Scales => null);
         TT.Allocate (32, Input); TT.Allocate (32, Values); TT.Allocate (32, Raw);
         TT.Allocate (32, Output); TT.Allocate (32, Control);
         Input.all := Query; Values.all := Actual;
         V.Gate_And_Project (W, W, Input, Values, Raw, Control, null, Done, Status,
                             Reference_Arithmetic => True);
         Assert (Done and then E.Is_Ok (Status), "standalone relative attention epilogue failed");
         Values.all := Query;
         V.Gate_And_Project (W, W, Input, Values, Raw, Output, null, Done, Status,
                             Reference_Arithmetic => True, Attention => Recorder);
         Assert (Done and then E.Is_Ok (Status) and then Output.all = Control.all,
                 "chained relative Q4T attention changed native epilogue output");
         TT.Free (Input); TT.Free (Values); TT.Free (Raw); TT.Free (Output); TT.Free (Control);
      exception
         when others => TT.Free (Input); TT.Free (Values); TT.Free (Raw);
            TT.Free (Output); TT.Free (Control); raise;
      end;
      Meta (2) := N.From_Bits (10); V.Put_Cache (64, Meta, Done);
      V.Attend_Packed
        (4, 4, Query, 1, 32, 32, 1, 10, 11, 0, 32, 32, 32, 40, 42, 1, 1,
         1.0, 0.0, Actual, Done, K_Codec => V.Transformed_Four_Bit_Cache,
         V_Codec => V.Scaled_Integer_Cache, Relative_At => 64);
      Assert (Done, "native relative attention rejected valid shifted cache origin");
      for Value of Actual loop
         Assert (abs (Value - Expected) <= 1.0E-6, "native shifted cache origin changed relative attention");
      end loop;
      Meta (2) := 0.0; V.Put_Cache (64, Meta, Done);
      Actual := [others => -123.0];
      Run (Natural'Last);
      Assert (not Done and then (for all X of Actual => X = -123.0), "relative metadata outside cache executed");
      Meta (0) := 0.0; V.Put_Cache (64, Meta, Done); Run (64);
      Assert (not Done, "zero relative width executed");
      Meta (0) := N.From_Bits (1); Meta (2) := N.From_Bits (1);
      V.Put_Cache (64, Meta, Done); Run (64);
      Assert (not Done, "relative cache origin beyond first visible token executed");
      Meta (2) := 0.0; Meta (3) := N.From_Bits (16#FFFF_FFFF#);
      V.Put_Cache (64, Meta, Done); Run (64);
      Assert (not Done, "relative table outside cache executed");
      V.Release_Cache; V.Close;
   exception
      when others => V.Release_Cache; V.Close; raise;
   end Device_Relative_Packed;

   procedure Relative_Bias_Lanes (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package K renames Model_Runner.Kernels;
      Done : Boolean;
      type Counts is array (Positive range <>) of L.Element_Count;
   begin
      K.Use_Wide_Lanes (Model_Runner.Backend.CPU.Wide_Vectors);
      for Width of Counts'[1, 4, 8, 32] loop
         declare
            Relative : constant L.Real_Array (5 .. 4 + Width) := Fixtures.Sequence (Width, 93, 0.3);
            Table : constant L.Real_Array (11 .. 10 + 128 * Width) := Fixtures.Sequence (128 * Width, 42, 0.7);
            Scores, Expected : L.Real_Array (3 .. 10);
            Bias : L.Real;
         begin
            for Extent of Counts'[0, 1, 7, 8, 9, 128] loop
               for Distance of Counts'[7, 8, 15, 127, 128, 135, 100_000] loop
                  Scores := Fixtures.Sequence (8, 74, 2.0); Expected := Scores;
                  for Lane in L.Element_Count range 0 .. 7 loop
                     Bias := 0.0;
                     if Distance - Lane < Extent then
                        for Channel in L.Element_Count range 0 .. Width - 1 loop
                           Bias := Bias + Relative (5 + Channel) * Table (11 + (Distance - Lane) * Width + Channel);
                        end loop;
                     end if;
                     Expected (3 + Lane) := Scores (3 + Lane) * 0.125 + (Bias - 0.03125);
                  end loop;
                  K.Relative_Scores_Eight (Scores, Relative, Table, Distance, Extent, 0.125, 0.03125, Done);
                  Assert (Done = Model_Runner.Backend.CPU.Wide_Vectors, "relative bias host gate");
                  if Done then
                     for I in Scores'Range loop
                        Assert (N.Bits (Scores (I)) = N.Bits (Expected (I)), "relative bias scalar order changed");
                     end loop;
                  end if;
               end loop;
            end loop;
            Scores := [others => 123.0];
            K.Relative_Scores_Eight (Scores, Relative, Table, 6, 128, 1.0, 0.0, Done);
            Assert (not Done and then (for all V of Scores => V = 123.0),
                    "relative bias invalid distance wrote output");
            K.Relative_Scores_Eight (Scores, Relative, Table, 8, 129, 1.0, 0.0, Done);
            Assert (not Done and then (for all V of Scores => V = 123.0),
                    "relative bias truncated table wrote output");
            K.Relative_Scores_Eight (Scores (3 .. 9), Relative, Table, 8, 128, 1.0, 0.0, Done);
            Assert (not Done and then (for all V of Scores => V = 123.0),
                    "relative bias invalid score width wrote output");
         end;
      end loop;
   end Relative_Bias_Lanes;

   procedure Reference_Pack_Reordering (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      use type QI.Signed_Array;
      use type QI.Sum_Array;
      Vectors : N.Real_Array (5 .. 516);
      A, B : QI.Signed_Array (11 .. 522);
      SA, SB : N.Real_Array (7 .. 22);
      TA, TB : QI.Sum_Array (3 .. 18);
      HA, HB : QI.Sum_Array (1 .. 32);
      Ok : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Byte_Products then return; end if;
      for Super in Boolean loop
         for Half in Boolean loop
            for Position in N.Element_Count range 0 .. 31 loop
               for I in Vectors'Range loop
                  Vectors (I) := N.Real (Integer (I mod 127) - 63) + 0.5;
               end loop;
               for Group in N.Element_Count range 0 .. 1 loop
                  Vectors (5 + Group * 256 + Position) := (if Group = 0 then 127.0 else -127.0);
                  Vectors (5 + Group * 256 + 255) := (if Group = 0 then -127.0 else 127.0);
               end loop;
               QI.Use_Deep_Rows (False);
               QI.Quantize_Vectors (Vectors, 1, 512, A, SA, TA, HA, Ok,
                                    Super => Super, Reference_Rounding => True, Half_Scales => Half);
               Assert (Ok, "scalar tie reference declined");
               QI.Use_Deep_Rows (True);
               QI.Quantize_Vectors (Vectors, 1, 512, B, SB, TB, HB, Ok,
                                    Super => Super, Reference_Rounding => True, Half_Scales => Half);
               Assert (Ok and then A = B and then TA = TB and then HA = HB,
                       "SIMD nearest-even bytes, signed maximum or sums changed");
               for I in SA'Range loop
                  Assert (N.Bits (SA (I)) = N.Bits (SB (I)), "SIMD stored scale changed");
               end loop;
            end loop;
         end loop;
      end loop;
      Vectors (5) := N.From_Bits (16#7FC0_0001#);
      QI.Quantize_Vectors (Vectors, 1, 512, B, SB, TB, HB, Ok, Reference_Rounding => True);
      Assert (not Ok, "SIMD reference packer accepted a NaN");
   exception
      when others => QI.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products); raise;
   end Reference_Pack_Reordering;

   procedure Fused_Expert_Accumulation (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      pragma Suppress (Validity_Check);
      package N renames Model_Runner.Numerics;
      package K renames Model_Runner.Kernels;
      use type Ada.Real_Time.Time;
      Edges : constant L.Real_Array :=
        [0.0, N.From_Bits (16#8000_0000#), 1.0, -1.0, N.From_Bits (16#3F80_0001#),
         N.From_Bits (16#3F7F_FFFF#), N.From_Bits (1), N.From_Bits (16#8000_0001#),
         N.From_Bits (16#7F7F_FFFF#), N.From_Bits (16#FF7F_FFFF#),
         N.From_Bits (16#7F80_0000#), N.From_Bits (16#FF80_0000#), N.From_Bits (16#7FC1_2345#)];
   begin
      for Size in L.Element_Count range 0 .. 35 loop
         for Used of L.Real_Array'[0.0,1.0,2.0,3.0,8.0,16.0] loop
            for Factor of Edges loop
               declare
                  Count : constant L.Element_Count := L.Element_Count (Used);
                  Target : L.Real_Array (7 .. 8 + Size) := [others => -777.0];
                  Values : L.Real_Array (17 .. 17 + Size * Count - 1);
                  Scaled : L.Real_Array (Values'Range);
                  Want : L.Real_Array (Target'Range) := Target;
                  Weights : L.Real_Array (23 .. 23 + Count - 1) := [others => Factor];
               begin
                  for I in Values'Range loop
                     Values (I) := Edges (Edges'First + (I - Values'First) mod Edges'Length);
                  end loop;
                  Scaled := Values; Want (8 .. 7 + Size) := [others => 0.0];
                  for Slot in L.Element_Count range 0 .. Count - 1 loop
                     K.Scale (Scaled (17 + Slot * Size .. 16 + (Slot + 1) * Size), Weights (Weights'First + Slot));
                     K.Add (Want (8 .. 7 + Size), Scaled (17 + Slot * Size .. 16 + (Slot + 1) * Size));
                  end loop;
                  K.Weighted_Sum (Target (8 .. 7 + Size), Values, Weights);
                  for I in Target'Range loop
                     Assert (N.Bits (Target (I)) = N.Bits (Want (I)),
                             "weighted expert sum differs at size" & Size'Image & " experts" & Count'Image);
                  end loop;
               end;
            end loop;
         end loop;
      end loop;
      declare
         Target : L.Real_Array (7 .. 38) := [others => -777.0];
         Values : constant L.Real_Array (17 .. 47) := [others => -888.0];
      begin
         K.Weighted_Sum (Target, Values, L.Real_Array'[0.5]);
         Assert ((for all V of Target => V = -777.0), "mismatched weighted expert lengths wrote output");
      end;
      declare
         Width : constant L.Element_Count := 2304;
         Original : L.Real_Array (0 .. 8 * Width - 1);
         Experts : L.Real_Array (Original'Range);
         Actual : L.Real_Array (5 .. 5 + Width - 1);
         Want : L.Real_Array (7 .. 7 + Width - 1) := [others => 0.0];
         Weights : constant L.Real_Array := [0.31,0.27,0.16,0.09,0.07,0.05,0.03,0.02];
         State : Interfaces.Unsigned_32 := 16#2915_CD37#;
         procedure Sum (Fused : Boolean) is
         begin
            Actual := [others => 0.0]; Experts := Original;
            if Fused then K.Weighted_Sum (Actual, Experts, Weights);
            else
               for Slot in L.Element_Count range 0 .. 7 loop
                  K.Scale (Experts (Slot * Width .. (Slot + 1) * Width - 1), Weights (Slot));
                  K.Add (Actual, Experts (Slot * Width .. (Slot + 1) * Width - 1));
               end loop;
            end if;
         end Sum;
      begin
         for I in Original'Range loop
            State := State xor Interfaces.Shift_Left (State, 13);
            State := State xor Interfaces.Shift_Right (State, 17);
            State := State xor Interfaces.Shift_Left (State, 5);
            Original (I) := L.Real (Integer (State mod 100001) - 50000) / 997.0;
         end loop;
         Sum (False); Want := Actual;
         Sum (True);
         for I in L.Element_Count range 0 .. Width - 1 loop
            Assert (N.Bits (Actual (Actual'First + I)) = N.Bits (Want (Want'First + I)),
                    "fused eight-expert reduction changed rank order or rounding");
         end loop;
         for I in Experts'Range loop
            Assert (N.Bits (Experts (I)) = N.Bits (Original (I)), "weighted sum changed read-only expert scratch");
         end loop;
         if Ada.Environment_Variables.Value ("INKLING_SMALL_MOE_BENCH", "") = "1" then
            for Fused in Boolean loop
               Sum (Fused);
               declare
                  Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
               begin
                  for Pass in 1 .. 65536 loop Sum (Fused); end loop;
                  Ada.Text_IO.Put_Line ("expert sum fused=" & Fused'Image & " seconds="
                    & Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started)'Image);
               end;
               for I in L.Element_Count range 0 .. Width - 1 loop
                  Assert (N.Bits (Actual (Actual'First + I)) = N.Bits (Want (Want'First + I)),
                          "timed fused expert result differs");
               end loop;
            end loop;
         end if;
      end;
   end Fused_Expert_Accumulation;

   procedure CPU_Reference_SiTU (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package K renames Model_Runner.Kernels;
      use type Ada.Real_Time.Time;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/reference-situ-input.f32");
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/reference-situ-output.f32");
      Encoded : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Count : constant L.Element_Count := 65536;
      Original : L.Real_Array (7 .. 7 + Count - 1);
      Up : L.Real_Array (11 .. 11 + Count - 1);
      Actual : L.Real_Array (5 .. 5 + Count - 1);
      Good : Boolean;
      function Exp_F (V : L.Real) return L.Real with Import, Convention => C, External_Name => "expf";
      function Tanh_F (V : L.Real) return L.Real with Import, Convention => C, External_Name => "tanhf";
      procedure Scalar is
         GR : constant L.Real := 1.0 / 4.0;
         UR : constant L.Real := 1.0 / 25.0;
      begin
         for I in L.Element_Count range 0 .. Count - 1 loop
            declare
               Raw : constant L.Real := Actual (Actual'First + I);
               Gated : constant L.Real := (4.0 * Tanh_F (Raw * GR))
                 * (if Raw <= -88.72283935546875 then 0.0 else 1.0 / (1.0 + Exp_F (-Raw)));
               Linear : constant L.Real := 25.0 * Tanh_F (Up (Up'First + I) * UR);
            begin Actual (Actual'First + I) := Gated * Linear; end;
         end loop;
      end Scalar;
   begin
      Assert (Input'Length = 2 * Count * 4 and then Golden'Length = Count * 4, "SiTU fixture shape");
      for I in Input'Range loop Encoded (B.Byte_Count (I)) := B.Byte (Character'Pos (Input (I))); end loop;
      for I in Golden'Range loop Expected (B.Byte_Count (I)) := B.Byte (Character'Pos (Golden (I))); end loop;
      for I in L.Element_Count range 0 .. Count - 1 loop
         Original (Original'First + I) := B.Get_F32 (Encoded, B.Byte_Count (I) * 4, Good);
         Assert (Good, "SiTU gate fixture truncated");
         Up (Up'First + I) := B.Get_F32 (Encoded, B.Byte_Count (Count + I) * 4, Good);
         Assert (Good, "SiTU up fixture truncated");
      end loop;
      Actual := Original;
      K.Reference_SiTU (Actual, Up, 4.0, 25.0);
      for I in L.Element_Count range 0 .. Count - 1 loop
         declare
            Want : constant L.Real := B.Get_F32 (Expected, B.Byte_Count (I) * 4, Good);
         begin
            Assert (Good and then N.Bits (Actual (Actual'First + I)) = N.Bits (Want),
                    "CPU SiTU differs from independent fixture at" & I'Image
                    & " actual" & N.Bits (Actual (Actual'First + I))'Image & " expected" & N.Bits (Want)'Image);
         end;
      end loop;
      for Size in L.Element_Count range 0 .. 35 loop
         declare
            Tail : L.Real_Array (17 .. 17 + Size + 1) := [others => -777.0];
            Arm : L.Real_Array (23 .. 23 + Size - 1);
         begin
            for I in L.Element_Count range 0 .. Size - 1 loop
               Tail (18 + I) := Original (Original'First + I); Arm (23 + I) := Up (Up'First + I);
            end loop;
            K.Reference_SiTU (Tail (18 .. 18 + Size - 1), Arm, 4.0, 25.0);
            Assert (Tail (17) = -777.0 and then Tail (Tail'Last) = -777.0, "CPU SiTU tail wrote guard");
            for I in L.Element_Count range 0 .. Size - 1 loop
               Assert (N.Bits (Tail (18 + I)) = N.Bits (Actual (Actual'First + I)), "CPU SiTU tail differs");
            end loop;
         end;
      end loop;
      declare
         Guard : L.Real_Array (0 .. 31) := [others => -777.0];
         Raised : Boolean := False;
      begin
         begin K.Reference_SiTU (Guard, Up (Up'First .. Up'First + 30), 4.0, 25.0);
         exception when Constraint_Error => Raised := True; end;
         Assert (Raised and then (for all V of Guard => V = -777.0), "CPU SiTU short arm wrote output");
         Raised := False;
         begin K.Reference_SiTU (Guard, Up, 0.0, 25.0);
         exception when Constraint_Error => Raised := True; end;
         Assert (Raised and then (for all V of Guard => V = -777.0), "CPU SiTU invalid cap wrote output");
      end;
      declare
         pragma Suppress (Validity_Check);
         Edge : L.Real_Array (0 .. 31) :=
           [0.0, N.From_Bits (16#8000_0000#), N.From_Bits (16#006C_E3EE#),
            N.From_Bits (16#806C_E3EE#), 1.0E-20, -1.0E-20,
            4.0, -4.0, 25.0, -25.0, 1.0E10, -1.0E10, N.From_Bits (16#7F7F_FFFF#),
            N.From_Bits (16#FF7F_FFFF#), 87.3, -87.3,
            N.From_Bits (16#7FC1_2345#), N.From_Bits (16#7F80_0000#),
            N.From_Bits (16#FF80_0000#), others => 0.5];
         Arm : L.Real_Array (7 .. 38) := [others => -0.7];
         Want : L.Real_Array (Edge'Range);
      begin
         Arm (31) := N.From_Bits (16#7FC1_2345#);
         Arm (32) := N.From_Bits (16#7F80_0000#);
         Arm (33) := N.From_Bits (16#FF80_0000#);
         for I in Edge'Range loop
            declare
               Raw : constant L.Real := Edge (I);
               Gated : constant L.Real := (4.0 * Tanh_F (Raw * (1.0 / 4.0)))
                 * (if Raw <= -88.72283935546875 then 0.0 else 1.0 / (1.0 + Exp_F (-Raw)));
               Linear : constant L.Real := 25.0 * Tanh_F (Arm (Arm'First + I) * (1.0 / 25.0));
            begin Want (I) := Gated * Linear; end;
         end loop;
         K.Reference_SiTU (Edge, Arm, 4.0, 25.0);
         for I in Edge'Range loop
            Assert (N.Bits (Edge (I)) = N.Bits (Want (I)), "CPU SiTU special value differs" & I'Image);
         end loop;
      end;
      --  Differential coverage beyond the stored fixture: arbitrary finite
      --  binary32 magnitudes, using independent platform libm for the oracle.
      declare
         State : Interfaces.Unsigned_32 := 16#CD72_91A3#;
         function Next_Value return L.Real is
            Bits : Interfaces.Unsigned_32;
         begin
            State := State xor Interfaces.Shift_Left (State, 13);
            State := State xor Interfaces.Shift_Right (State, 17);
            State := State xor Interfaces.Shift_Left (State, 5);
            Bits := State;
            if (Bits and 16#7F80_0000#) = 16#7F80_0000# then Bits := Bits and 16#FF7F_FFFF#; end if;
            return N.From_Bits (Bits);
         end Next_Value;
      begin
         for I in L.Element_Count range 0 .. Count - 1 loop
            Actual (Actual'First + I) := Next_Value;
            Up (Up'First + I) := Next_Value;
            declare
               Raw : constant L.Real := Actual (Actual'First + I);
               Gated : constant L.Real := (4.0 * Tanh_F (Raw * (1.0 / 4.0)))
                 * (if Raw <= -88.72283935546875 then 0.0 else 1.0 / (1.0 + Exp_F (-Raw)));
               Linear : constant L.Real := 25.0 * Tanh_F (Up (Up'First + I) * (1.0 / 25.0));
            begin Original (Original'First + I) := Gated * Linear; end;
         end loop;
         K.Reference_SiTU (Actual, Up, 4.0, 25.0);
         for I in L.Element_Count range 0 .. Count - 1 loop
            Assert (N.Bits (Actual (Actual'First + I)) = N.Bits (Original (Original'First + I)),
                    "CPU SiTU random finite magnitude differs at" & I'Image);
         end loop;
      end;
      if Ada.Environment_Variables.Value ("INKLING_SITU_BENCH", "") = "1" then
         for I in L.Element_Count range 0 .. Count - 1 loop
            Original (Original'First + I) := B.Get_F32 (Encoded, B.Byte_Count (I) * 4, Good);
            Up (Up'First + I) := B.Get_F32 (Encoded, B.Byte_Count (Count + I) * 4, Good);
         end loop;
         declare
            Started : Ada.Real_Time.Time;
            Elapsed : Duration;
         begin
            for Vector in Boolean loop
               Actual := Original;
               if Vector then K.Reference_SiTU (Actual, Up, 4.0, 25.0); else Scalar; end if;
               Started := Ada.Real_Time.Clock;
               for Pass in 1 .. 128 loop
                  Actual := Original;
                  if Vector then K.Reference_SiTU (Actual, Up, 4.0, 25.0); else Scalar; end if;
               end loop;
               Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
               Ada.Text_IO.Put_Line ("SiTU component vector=" & Vector'Image & " seconds=" & Elapsed'Image);
               for I in L.Element_Count range 0 .. Count - 1 loop
                  Assert (N.Bits (Actual (Actual'First + I)) =
                          N.Bits (B.Get_F32 (Expected, B.Byte_Count (I) * 4, Good)),
                          "timed SiTU component differs from independent output");
               end loop;
            end loop;
         end;
      end if;
   end CPU_Reference_SiTU;

   procedure Vulkan_Reference_SiTU (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package PD renames Model_Runner.Platform.Device;
      package P renames Model_Runner.Platform.Device.Products;
      Count : constant := 2048;
      Width : constant := 32;
      Elements : constant N.Element_Count := Count * Width;
      Inventory : PD.Inventory;
      Context : PD.Context;
      Engine : P.Engine;
      Steps : P.Sequence;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/reference-situ-input.f32");
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/reference-situ-output.f32");
      Encoded : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (0 .. 2 * Elements - 1);
      Output : L.Real_Array (0 .. 2 * Elements - 1) := [others => 999.0];
      Identity : L.Real_Array (0 .. Width * Width - 1) := [others => 0.0];
      Ready, Good, Halted : Boolean;
      Different : Natural := 0;
      First : N.Element_Count := 0;
   begin
      if not Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_REFERENCE_GPU") then return; end if;
      for I in Input'Range loop Encoded (B.Byte_Count (I)) := B.Byte (Character'Pos (Input (I))); end loop;
      for I in Golden'Range loop Expected (B.Byte_Count (I)) := B.Byte (Character'Pos (Golden (I))); end loop;
      for I in Vectors'Range loop
         Vectors (I) := B.Get_F32 (Encoded, B.Byte_Count (I) * 4, Good);
         Assert (Good, "SiTU independent input truncated");
      end loop;
      for I in N.Element_Count range 0 .. Width - 1 loop Identity (I * Width + I) := 1.0; end loop;
      PD.Open (Inventory, Ready); Assert (Ready and then PD.Count (Inventory) > 0, "SiTU device unavailable");
      PD.Open (Context, Inventory, 1, Ready); Assert (Ready, "SiTU context unavailable");
      P.Open (Engine, Context, Ready, Budget => 268_435_456);
      Assert (Ready and then P.Takes_Reference_SiTU (Engine), "reference SiTU pipeline unavailable");
      declare
         Matrix : constant B.Byte_Array := Fixtures.Encode_F32 (Identity);
      begin
         P.Open_Sequence (Steps);
         P.Add_Product (Steps, Matrix (Matrix'First)'Address, Matrix'Length, 0,
                        P.Values_F32, Width, Width, Good, At_Vector => Natural (Elements),
                        Exact => True, Kept => False);
         Assert (Good, "SiTU identity projection rejected");
         P.Add_Join (Steps, Good, Unit => 14, Alpha => 4.0, Limit => 25.0);
         Assert (Good, "SiTU reference join rejected");
         P.Run (Engine, Steps, Vectors, Count, Output, Good, Halted);
         Assert (Good and then not Halted, "SiTU device execution failed");
      end;
      for I in N.Element_Count range 0 .. Elements - 1 loop
         declare
            Want : constant L.Real := B.Get_F32 (Expected, B.Byte_Count (I) * 4, Good);
         begin
            Assert (Good, "SiTU independent output truncated");
            if N.Bits (Output (Elements + I)) /= N.Bits (Want) then
               if Different = 0 then First := I; end if;
               Different := Different + 1;
            end if;
         end;
      end loop;
      Ada.Text_IO.Put_Line ("Reference SiTU: compared 65536 values, mismatches" & Different'Image);
      declare
         Want : constant L.Real := B.Get_F32 (Expected, B.Byte_Count (First) * 4, Good);
      begin
         Assert (Good, "SiTU first independent output truncated");
         Assert (Different = 0, "reference SiTU differs at" & First'Image
                 & " actual bits" & N.Bits (Output (Elements + First))'Image
                 & " expected bits" & N.Bits (Want)'Image);
      end;
      P.Close (Engine); PD.Close (Context); PD.Close (Inventory);
   exception
      when others => P.Close (Engine); PD.Close (Context); PD.Close (Inventory); raise;
   end Vulkan_Reference_SiTU;

   procedure Vulkan_GSQ_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package G renames Model_Runner.GGUF;
      package PD renames Model_Runner.Platform.Device;
      package P renames Model_Runner.Platform.Device.Products;
      Inventory : PD.Inventory;
      Context : PD.Context;
      Engine : P.Engine;
      Steps : P.Sequence;
      Ready, Good, Halted : Boolean;
      Input : L.Real_Array (0 .. 9 * 2304 - 1);
      function Bytes (Name : String) return B.Byte_Array is
         Raw : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/" & Name);
         Data : B.Byte_Array (0 .. B.Byte_Count (Raw'Length) - 1);
      begin
         for I in Data'Range loop Data (I) := Character'Pos (Raw (Raw'First + Natural (I))); end loop;
         return Data;
      end Bytes;
      Formats : constant array (1 .. 4) of G.Tensor_Type :=
        [G.Type_IQ4_NL, G.Type_Q2_0, G.Type_IQ3_S, G.Type_IQ3_XXS];
   begin
      Assert (not P.Takes_Reference_GSQ (Engine), "closed engine advertises GSQ products");
      if not Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_REFERENCE_GPU") then return; end if;
      declare
         Data : constant B.Byte_Array := Bytes ("gsq-small-blocks/input-2304.f32");
      begin
         for I in Input'Range loop
            Input (I) := B.Get_F32 (Data, B.Byte_Count (I) * 4, Good);
            Assert (Good, "GSQ Vulkan independent input truncated");
         end loop;
      end;
      PD.Open (Inventory, Ready); Assert (Ready and then PD.Count (Inventory) > 0, "GSQ inventory unavailable");
      PD.Open (Context, Inventory, 1, Ready); Assert (Ready, "GSQ device unavailable");
      P.Open (Engine, Context, Ready, Budget => 268_435_456);
      Assert (Ready and then P.Takes_Reference_GSQ (Engine), "native GSQ reference pipeline unavailable");
      for Format of Formats loop
         declare
            Small : constant Boolean := Format in G.Type_IQ4_NL | G.Type_Q2_0;
            Name : constant String := (case Format is when G.Type_IQ4_NL => "nl-2304",
              when G.Type_Q2_0 => "q2-2304", when G.Type_IQ3_S => "iq3s", when others => "iq3xxs");
            Prefix : constant String := (if Small then "gsq-small-blocks/" else "gsq-grid-blocks/");
            Weight : constant B.Byte_Array := Bytes (Prefix & Name & ".bin");
            Golden : constant B.Byte_Array := Bytes (Prefix & Name & ".f32");
            Rows : constant L.Element_Count := (if Small then 5 else 4);
            Packing : constant P.Weight_Packing := (case Format is
              when G.Type_IQ4_NL => P.Packed_IQ4_NL, when G.Type_Q2_0 => P.Packed_Q2_0,
              when G.Type_IQ3_S => P.Packed_IQ3_S, when others => P.Packed_IQ3_XXS);
            Worst : L.Real := 0.0;
         begin
            P.Open_Sequence (Steps);
            P.Add_Product (Steps, Weight (Weight'First)'Address, Weight'Length, 0, Packing,
                           Natural (Rows), 2304, Good, Kept => True, Reference_Integer => True);
            Assert (Good, "native GSQ reference product rejected");
            for Count in Positive range 1 .. 9 loop
               declare
                  Output : L.Real_Array (11 .. 11 + Rows * L.Element_Count (Count)) := [others => -123.0];
               begin
                  P.Run (Engine, Steps, Input, Count, Output, Good, Halted);
                  Assert (Good and then not Halted, "native GSQ reference execution failed " & Format'Image);
                  for R in L.Element_Count range 0 .. Rows - 1 loop
                     for V in L.Element_Count range 0 .. L.Element_Count (Count) - 1 loop
                        declare
                           Want : constant L.Real := B.Get_F32 (Golden, B.Byte_Count (R * 9 + V) * 4, Good);
                           Got : constant L.Real := Output (11 + V * Rows + R);
                        begin
                           Assert (Good, "independent GSQ golden truncated");
                           Worst := L.Real'Max (Worst, abs (Got - Want));
                           if Small then
                              Assert (N.Bits (Got) = N.Bits (Want), "GSQ small-block reference differs "
                                & Format'Image & Count'Image & R'Image & V'Image & Got'Image & Want'Image);
                           else
                              --  Existing FP32 decoder/reference comparison envelope.
                              Assert (abs (Got - Want) <= 1.0E-5 + 2.0E-5 * abs Want,
                                      "GSQ grid reference outside FP32 envelope " & Format'Image
                                      & Count'Image & R'Image & V'Image & Got'Image & Want'Image);
                           end if;
                        end;
                     end loop;
                  end loop;
                  Assert (Output (Output'Last) = -123.0, "native GSQ reference overwrote output guard");
               end;
            end loop;
            Ada.Text_IO.Put_Line ("GSQ Vulkan " & Format'Image & " independent maximum error" & Worst'Image);
         end;
      end loop;
      P.Close (Engine); Assert (not P.Takes_Reference_GSQ (Engine), "closed engine retained GSQ pipeline");
      PD.Close (Context); PD.Close (Inventory);
   exception
      when others => P.Close (Engine); PD.Close (Context); PD.Close (Inventory); raise;
   end Vulkan_GSQ_Products;

   procedure Vulkan_GSQ_Experts (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package G renames Model_Runner.GGUF;
      package QI renames Model_Runner.Quantization.Integers;
      package TT renames Model_Runner.Tensors;
      package V renames Model_Runner.Backend.Device;
      Gate, Up : B.Byte_Array (0 .. 64 * 34 - 1) := [others => 0];
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/reference-situ-native.f32");
      Encoded : B.Byte_Array (0 .. B.Byte_Count (Golden'Length) - 1);
      Activated : L.Real_Array (0 .. 63);
      Values : QI.Signed_Array (0 .. 63);
      Scales : L.Real_Array (0 .. 1);
      Totals : QI.Sum_Array (0 .. 1);
      Halves : QI.Sum_Array (0 .. 3);
      Input, Output : TT.Real_Array_Access := null;
      Ready, Good : Boolean;
      Status : E.Error_Info;
   begin
      if not Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_REFERENCE_GPU") then return; end if;
      for I in Encoded'Range loop Encoded (I) := Character'Pos (Golden (Golden'First + Natural (I))); end loop;
      for I in Activated'Range loop
         Activated (I) := B.Get_F32 (Encoded, B.Byte_Count (I mod 32) * 4, Good);
         Assert (Good, "independent expert activation truncated");
      end loop;
      for R in B.Byte_Count range 0 .. 63 loop
         Gate (R * 34 + 1) := 16#3C#; Up (R * 34 + 1) := 16#3C#;
         Gate (R * 34 + 2 + R mod 32) := 1; Up (R * 34 + 2 + 31 - R mod 32) := 1;
      end loop;
      QI.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
      QI.Quantize_Vectors (Activated, 1, 64, Values, Scales, Totals, Halves, Good,
                           Reference_Rounding => True, Half_Scales => True);
      Assert (Good, "independent expert activation packing declined");
      V.Open (Ready, Budget => 268_435_456, Tuning_Profile => "none"); Assert (Ready, "GSQ expert device unavailable");
      TT.Allocate (8 * 32, Input); TT.Allocate (8 * 32, Output);
      for I in Input.all'Range loop
         Input (I) := (if I mod 32 = 0 then 127.0 elsif I mod 32 = 31 then -127.0
                      else L.Real (Integer (I mod 32) - 16));
      end loop;
      for Kind in 1 .. 2 loop
         declare
            Raw : constant L.Real_Array := Fixtures.Sequence (32 * 64, 19, 0.7);
            Down : constant B.Byte_Array :=
              (if Kind = 1 then Fixtures.Encode_IQ4_NL (Raw) else Fixtures.Encode_Q2_0 (Raw));
            Format : constant G.Tensor_Type := (if Kind = 1 then G.Type_IQ4_NL else G.Type_Q2_0);
            Gate_View : constant TT.View := (Format => G.Type_Q8_0, Rows => 64, Columns => 32,
              Base => Gate (0)'Address, Span => Gate'Length, Offset => 0, Length => Gate'Length,
              Interleaved => False, Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
            Up_View : TT.View := Gate_View;
            Down_View : constant TT.View := (Format => Format, Rows => 32, Columns => 64,
              Base => Down (Down'First)'Address, Span => Down'Length, Offset => 0, Length => Down'Length,
              Interleaved => False, Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
            Expected : N.Wide_Real_Array (0 .. 31) := [others => 0.0];
         begin
            Up_View.Base := Up (0)'Address;
            QI.Accumulate_Rows (Format, Down, 0, Down'Length / 32, 32,
                                (if Kind = 1 then 2 else 1), Values, Scales, Totals, Halves,
                                0, 64, 1, Expected, Good, Reference_Arithmetic => True);
            Assert (Good, "GSQ expert expected down product declined");
            for Count in Positive range 1 .. 8 loop
               V.Dispatch_Reference_Expert (Gate_View, Up_View, Down_View, Input,
                                            L.Element_Count (Count), Output, 4.0, 25.0, Status);
               Assert (E.Is_Ok (Status), "native GSQ fused expert failed " & Status.Code'Image);
               for I in L.Element_Count range 0 .. L.Element_Count (Count) * 32 - 1 loop
                  Assert (N.Bits (Output (I)) = N.Bits (L.Real (Expected (I mod 32))),
                          "native GSQ fused expert differs " & Kind'Image & Count'Image & I'Image);
               end loop;
            end loop;
         end;
      end loop;
      --  Valid mixed-format experts lacking a reference pipeline stay on
      --  the CPU, including after an F32 session left their matrices held.
      declare
         G_Data : constant B.Byte_Array (0 .. 64 * 50 - 1) := [others => 0];
         D_Data : constant B.Byte_Array (0 .. 256 * 18 - 1) := [others => 0];
         Gate_View : constant TT.View := (Format => G.Type_IQ1_S, Rows => 64, Columns => 256,
           Base => G_Data (0)'Address, Span => G_Data'Length, Offset => 0, Length => G_Data'Length,
           Interleaved => False, Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
         Down_View : constant TT.View := (Format => G.Type_Q2_0, Rows => 256, Columns => 64,
           Base => D_Data (0)'Address, Span => D_Data'Length, Offset => 0, Length => D_Data'Length,
           Interleaved => False, Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
         Held : Boolean;
      begin
         V.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_Every);
         V.Hold_Expert (Gate_View, Gate_View, Down_View, Held);
         Assert (not Held and then not V.Expert_Held (Gate_View, Gate_View, Down_View),
                 "unsupported reference expert was admitted to fused device execution");
         V.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_None);
         V.Hold_Expert (Gate_View, Gate_View, Down_View, Held);
         Assert (Held and then V.Expert_Held (Gate_View, Gate_View, Down_View),
                 "reference eligibility changed ordinary F32 residency");
         V.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_Every);
         Assert (not V.Expert_Held (Gate_View, Gate_View, Down_View),
                 "cached F32 matrices bypassed reference-format eligibility");
         V.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_None);
      end;
      TT.Free (Input); TT.Free (Output); V.Close;
   exception
      when others => TT.Free (Input); TT.Free (Output); V.Close; raise;
   end Vulkan_GSQ_Experts;

   procedure Vulkan_Reference_Mixture (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package QI renames Model_Runner.Quantization.Integers;
      package TT renames Model_Runner.Tensors;
      package V renames Model_Runner.Backend.Device;
      Gate, Up, Down : B.Byte_Array (0 .. 32 * 34 - 1) := [others => 0];
      Gates, Ups, Downs : TT.View_Group (1 .. 8);
      Input, Output : TT.Real_Array_Access := null;
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/reference-situ-native.f32");
      Expected_Bytes : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Activated, Expected : L.Real_Array (0 .. 31);
      Values : QI.Signed_Array (0 .. 31);
      Scales : L.Real_Array (0 .. 0);
      Totals : QI.Sum_Array (0 .. 0);
      Halves : QI.Sum_Array (0 .. 1);
      Shares : L.Real_Array (0 .. 7);
      Ready, Good : Boolean;
      Status : E.Error_Info;
   begin
      if not Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_REFERENCE_GPU") then return; end if;
      for I in Golden'Range loop Expected_Bytes (B.Byte_Count (I)) := B.Byte (Character'Pos (Golden (I))); end loop;
      for I in Activated'Range loop
         Activated (I) := B.Get_F32 (Expected_Bytes, B.Byte_Count (I) * 4, Good);
         Assert (Good, "native mixture activation fixture truncated");
      end loop;
      for Row in B.Byte_Count range 0 .. 31 loop
         Gate (Row * 34) := 0; Gate (Row * 34 + 1) := 16#3C#;
         Up (Row * 34) := 0; Up (Row * 34 + 1) := 16#3C#;
         Down (Row * 34) := 0; Down (Row * 34 + 1) := 16#3C#;
         Gate (Row * 34 + 2 + Row) := 1;
         Up (Row * 34 + 2 + 31 - Row) := 1;
         Down (Row * 34 + 2 + Row) := 1;
      end loop;
      for I in Gates'Range loop
         Gates (I) := (Format => Model_Runner.GGUF.Type_Q8_0, Rows => 32, Columns => 32,
           Base => Gate (0)'Address, Span => Gate'Length, Offset => 0, Length => Gate'Length,
           Interleaved => False, Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
         Ups (I) := Gates (I); Ups (I).Base := Up (0)'Address;
         Downs (I) := Gates (I); Downs (I).Base := Down (0)'Address;
      end loop;
      V.Open (Ready, Budget => 268_435_456, Tuning_Profile => "none");
      Assert (Ready and then V.Takes_Reference_Mixture, "native reference mixture pipeline unavailable");
      TT.Allocate (32, Input); TT.Allocate (32, Output);
      for I in L.Element_Count range 0 .. 31 loop Input (I) := L.Real (Integer (I) - 16); end loop;
      Input (0) := 127.0; Input (31) := -127.0;
      QI.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
      QI.Quantize_Vectors (Activated, 1, 32, Values, Scales, Totals, Halves, Good,
                           Reference_Rounding => True, Half_Scales => True);
      Assert (Good, "reference down-input packing declined");
      for Number in 1 .. 8 loop
         Expected := [others => 0.0];
         for Slot in 0 .. Number - 1 loop
            Shares (L.Element_Count (Slot)) := L.Real (Slot + 1) / 36.0;
            for I in Expected'Range loop
               declare
                  Dot : constant L.Real := L.Real (Values (I)) * Scales (0);
                  Weighted : constant L.Real := Dot * Shares (L.Element_Count (Slot));
               begin Expected (I) := Expected (I) + Weighted; end;
            end loop;
         end loop;
         V.Dispatch_Reference_Mixture
           (Gates (1 .. Number), Ups (1 .. Number), Downs (1 .. Number),
            Shares (0 .. L.Element_Count (Number) - 1), Input, Output, 4.0, 25.0, Status);
         Assert (E.Is_Ok (Status), "native reference mixture dispatch failed" & Status.Code'Image);
         for I in Expected'Range loop
            Assert (N.Bits (Output (I)) = N.Bits (Expected (I)),
                    "native reference mixture changes ordered aggregation" & Number'Image & I'Image);
         end loop;
      end loop;
      Output.all := [others => 123.0]; Shares (0) := N.From_Bits (16#7FC0_0000#);
      V.Dispatch_Reference_Mixture (Gates, Ups, Downs, Shares, Input, Output, 4.0, 25.0, Status);
      Assert (not E.Is_Ok (Status) and then (for all X of Output.all => X = 123.0),
              "nonfinite route share committed native mixture output");
      Shares (0) := 0.125; Input (0) := N.From_Bits (16#7FC0_0000#);
      V.Dispatch_Reference_Mixture (Gates, Ups, Downs, Shares, Input, Output, 4.0, 25.0, Status);
      Assert (not E.Is_Ok (Status) and then (for all X of Output.all => X = 123.0),
              "nonfinite source committed native mixture output");
      declare
         type Counts is array (Positive range <>) of L.Element_Count;
         Raw, Weighted, History, Raw_Output, Residual : TT.Real_Array_Access := null;
         Text : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/reference-sigmoid-native.f32");
         Bytes : B.Byte_Array (1 .. B.Byte_Count (Text'Length));
         Sigmoid : L.Real_Array (0 .. 31);
      begin
         for I in Text'Range loop Bytes (B.Byte_Count (I)) := B.Byte (Character'Pos (Text (I))); end loop;
         for I in Sigmoid'Range loop
            Sigmoid (I) := B.Get_F32 (Bytes, B.Byte_Count (I) * 4, Good);
            Assert (Good, "independent native sigmoid fixture truncated");
         end loop;
         Output.all := [others => 123.0];
         for Count of Counts'[0, 129, L.Element_Count'Last] loop
            V.Dispatch_Reference_Expert (Gates (1), Ups (1), Downs (1), Input, Count, Output, 4.0, 25.0, Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch and then (for all X of Output.all => X = 123.0),
                    "malformed resident batch count changed output or bypassed validation");
         end loop;
         for Count of Counts'[1, 2, 4, 17, 128] loop
            TT.Free (Input); TT.Free (Output); TT.Allocate (Count * 32, Input); TT.Allocate (Count * 32, Output);
            declare
               Activations : L.Real_Array (0 .. Count * 32 - 1);
               Packed : QI.Signed_Array (Activations'Range);
               Scale : L.Real_Array (0 .. Count - 1);
               Sums : QI.Sum_Array (Scale'Range);
               Half_Sums : QI.Sum_Array (0 .. Count * 2 - 1);
            begin
               for Token in L.Element_Count range 0 .. Count - 1 loop
                  for I in L.Element_Count range 0 .. 31 loop
                     declare
                        Index : constant L.Element_Count := (if Token mod 2 = 0 then I else 31 - I);
                     begin
                        Input (Token * 32 + I) := (if Index = 0 then 127.0 elsif Index = 31 then -127.0
                                                  else L.Real (Integer (Index) - 16));
                        Activations (Token * 32 + I) := Activated (Index);
                     end;
                  end loop;
               end loop;
               QI.Quantize_Vectors (Activations, Count, 32, Packed, Scale, Sums, Half_Sums, Good,
                                    Reference_Rounding => True, Half_Scales => True);
               Assert (Good, "independent batched SiTU packing declined");
               V.Dispatch_Reference_Expert (Gates (1), Ups (1), Downs (1), Input, Count, Output, 4.0, 25.0, Status);
               Assert (E.Is_Ok (Status), "batched resident reference expert failed");
               for I in Output.all'Range loop
                  Assert (N.Bits (Output (I)) = N.Bits (L.Real (Packed (I)) * Scale (I / 32)),
                          "batched resident expert changes reference output" & Count'Image & I'Image);
               end loop;
               declare
                  Inputs : TT.Target_Group (1 .. 8) := [others => Input];
                  Outputs : TT.Target_Group (1 .. 8) := [others => null];
                  Stop : aliased Model_Runner.Cancellation.Token;
               begin
                  for Slot in Outputs'Range loop TT.Allocate (Count * 32, Outputs (Slot)); end loop;
                  for Number in 2 .. 8 loop
                     V.Dispatch_Reference_Experts
                       (Gates (1 .. Number), Ups (1 .. Number), Downs (1 .. Number),
                        Inputs (1 .. Number), Count, Outputs (1 .. Number), 4.0, 25.0, Status);
                     Assert (E.Is_Ok (Status), "grouped resident experts failed");
                     for Slot in 1 .. Number loop
                        Assert (Outputs (Slot).all = Output.all,
                                "grouped resident expert changed reference output");
                     end loop;
                  end loop;
                  for O of Outputs loop O.all := [others => 123.0]; end loop;
                  Inputs (8) := null;
                  V.Dispatch_Reference_Experts (Gates, Ups, Downs, Inputs, Count, Outputs, 4.0, 25.0, Status);
                  Assert (not E.Is_Ok (Status)
                          and then (for all O of Outputs => (for all X of O.all => X = 123.0)),
                          "invalid grouped source committed another expert's output");
                  Inputs (8) := Input; Stop.Request;
                  V.Dispatch_Reference_Experts (Gates, Ups, Downs, Inputs, Count, Outputs, 4.0, 25.0, Status,
                                                Cancel => Stop'Unchecked_Access);
                  Assert (Status.Code = E.Generation_Cancelled
                          and then (for all O of Outputs => (for all X of O.all => X = 123.0)),
                          "cancelled grouped experts committed output");
                  for O of Outputs loop TT.Free (O); end loop;
               exception
                  when others => for O of Outputs loop TT.Free (O); end loop; raise;
               end;
               declare
                  Weighted : TT.Real_Array_Access := null;
                  Route_Shares : L.Real_Array (0 .. Count * 8 - 1);
                  Want : L.Real_Array (0 .. Count * 32 - 1) := [others => 0.0];
                  Before : constant Natural := V.Reference_Packing_Reuses;
               begin
                  TT.Allocate (Count * 32, Weighted);
                  for Slot in L.Element_Count range 0 .. 7 loop
                     for Token in L.Element_Count range 0 .. Count - 1 loop
                        Route_Shares (Slot * Count + Token) :=
                          L.Real (Slot + 1) / (if Token mod 2 = 0 then 16.0 else 32.0);
                        for Channel in L.Element_Count range 0 .. 31 loop
                           declare
                              I : constant L.Element_Count := Token * 32 + Channel;
                              Down : constant L.Real := L.Real (N.Wide_Real (L.Real (Packed (I)))
                                * N.Wide_Real (Scale (Token)));
                              Scaled : constant L.Real := L.Real (N.Wide_Real (Down)
                                * N.Wide_Real (Route_Shares (Slot * Count + Token)));
                           begin Want (I) := L.Real (N.Wide_Real (Want (I)) + N.Wide_Real (Scaled)); end;
                        end loop;
                     end loop;
                  end loop;
                  V.Dispatch_Reference_Mixture (Gates, Ups, Downs, Route_Shares, Input, Weighted,
                                                4.0, 25.0, Status, Count => Positive (Count));
                  Assert (E.Is_Ok (Status), "batched ordered reference mixture failed");
                  for I in Want'Range loop
                     Assert (N.Bits (Weighted (I)) = N.Bits (Want (I)),
                             "batched native mixture changed route-order accumulation");
                  end loop;
                  Assert (V.Reference_Packing_Reuses > Before, "compatible gate/up inputs were repacked");
                  Weighted.all := [others => 123.0];
                  Route_Shares (Route_Shares'Last) := N.From_Bits (16#7FC0_0000#);
                  V.Dispatch_Reference_Mixture (Gates, Ups, Downs, Route_Shares, Input, Weighted,
                                                4.0, 25.0, Status, Count => Positive (Count));
                  Assert (not E.Is_Ok (Status) and then (for all X of Weighted.all => X = 123.0),
                          "nonfinite batched route committed another token's output");
                  TT.Free (Weighted);
               exception
                  when others => TT.Free (Weighted); raise;
               end;
               if Count <= 17 then
                  TT.Allocate (Count * 32, Raw); TT.Allocate (Count * 32, Weighted);
                  TT.Allocate (Count * 32, Raw_Output); TT.Allocate (Count * 32, Residual);
                  for I in Weighted.all'Range loop
                     declare
                        Token : constant L.Element_Count := I / 32;
                        Index : constant L.Element_Count := (if Token mod 2 = 0 then I mod 32 else 31 - I mod 32);
                     begin
                        Weighted (I) := L.Real (Integer (I mod 7) - 3) / 4.0;
                        Activations (I) := Weighted (I) * Sigmoid (Index);
                        Residual (I) := L.Real (Integer (I mod 5) - 2) / 8.0;
                     end;
                  end loop;
                  QI.Quantize_Vectors (Activations, Count, 32, Packed, Scale, Sums, Half_Sums, Good,
                                       Reference_Rounding => True, Half_Scales => True);
                  Assert (Good, "reference gated attention packing declined");
                  for Taps in L.Element_Count range 3 .. 4 loop
                     TT.Allocate (32 * (Taps - 1), History);
                     declare
                        Coefficients : L.Real_Array (0 .. 32 * Taps - 1);
                        Past : L.Real_Array (0 .. 32 * (Taps - 1) - 1);
                        Want : L.Real_Array (Activations'Range);
                        Factor : constant L.Real := 1.0 / L.Real (N.Sqrt (N.Wide_Real (Taps + 1)));
                        Done : Boolean;
                     begin
                        for I in Coefficients'Range loop Coefficients (I) := L.Real (Integer (I mod 7) - 3) / 32.0;
                        end loop;
                        for I in Past'Range loop Past (I) := L.Real (Integer (I mod 7) - 3) / 16.0; end loop;
                        History.all := Past;
                        for Token in L.Element_Count range 0 .. Count - 1 loop
                           for Channel in L.Element_Count range 0 .. 31 loop
                              declare
                                 At_Value : constant L.Element_Count := Token * 32 + Channel;
                                 Raw_Value : constant L.Real := L.Real (Packed (At_Value)) * Scale (Token);
                                 Total : L.Real := 0.0;
                              begin
                                 --  Coefficients are small dyadic integers; these test products
                                 --  and sums are exact in binary64 before each binary32 rounding.
                                 for Tap in L.Element_Count range 0 .. Taps - 1 loop
                                    Total := L.Real (N.Wide_Real (Coefficients (Channel * Taps + Tap))
                                      * N.Wide_Real (if Tap = Taps - 1 then Raw_Value
                                                    else Past (Channel * (Taps - 1) + Tap)) + N.Wide_Real (Total));
                                 end loop;
                                 Want (At_Value) := (Raw_Value + Total) * Factor;
                                 Want (At_Value) := Want (At_Value) + Residual (At_Value);
                                 for Lag in L.Element_Count range 1 .. Taps - 2 loop
                                    Past (Channel * (Taps - 1) + Lag - 1) := Past (Channel * (Taps - 1) + Lag);
                                 end loop;
                                 Past (Channel * (Taps - 1) + Taps - 2) := Raw_Value;
                              end;
                           end loop;
                        end loop;
                        V.Gate_And_Project
                          (Gates (1), Downs (1), Input, Weighted, Raw, Output, null, Done, Status,
                           Count => Positive (Count), Conv_Taps => Coefficients, Conv_History => History,
                           Raw_Output => Raw_Output, Reference_Arithmetic => True, Residual => Residual);
                        Assert (Done and then E.Is_Ok (Status), "reference attention epilogue did not execute");
                        for I in Want'Range loop
                           Assert (N.Bits (Output (I)) = N.Bits (Want (I)),
                                   "reference attention epilogue changed output" & Count'Image & I'Image);
                        end loop;
                        for I in Past'Range loop
                           Assert (N.Bits (History (I)) = N.Bits (Past (I)),
                                   "reference attention epilogue changed convolution history");
                        end loop;
                     end;
                     TT.Free (History);
                  end loop;
                  TT.Free (Raw); TT.Free (Weighted); TT.Free (Raw_Output); TT.Free (Residual);
               end if;
            end;
         end loop;
      exception
         when others => TT.Free (Raw); TT.Free (Weighted); TT.Free (History);
            TT.Free (Raw_Output); TT.Free (Residual); raise;
      end;
      --  Eight wide experts at128rows exceeded the former summed4MiB
      --  packing layout, though only one product's packing is live.
      declare
         Width : constant L.Element_Count := 2048;
         Count : constant L.Element_Count := 128;
         Row_Bytes : constant B.Byte_Count := B.Byte_Count (Width / 32) * 34;
         G, U : B.Byte_Array (0 .. 32 * Row_Bytes - 1) := [others => 0];
         D : B.Byte_Array (0 .. B.Byte_Count (Width) * 34 - 1) := [others => 0];
         Big_Input : TT.Real_Array_Access := null;
         Outputs : TT.Target_Group (1 .. 8) := [others => null];
         Big_Gates, Big_Ups, Big_Downs : TT.View_Group (1 .. 8);
      begin
         for Row in B.Byte_Count range 0 .. 31 loop
            for Block in B.Byte_Count range 0 .. B.Byte_Count (Width / 32) - 1 loop
               G (Row * Row_Bytes + Block * 34 + 1) := 16#3C#;
               U (Row * Row_Bytes + Block * 34 + 1) := 16#3C#;
            end loop;
            G (Row * Row_Bytes + 2 + Row) := 1;
            U (Row * Row_Bytes + 2 + 31 - Row) := 1;
         end loop;
         for Row in B.Byte_Count range 0 .. B.Byte_Count (Width) - 1 loop
            D (Row * 34 + 1) := 16#3C#;
            if Row < 32 then D (Row * 34 + 2 + Row) := 1; end if;
         end loop;
         TT.Allocate (Count * Width, Big_Input); Big_Input.all := [others => 0.0];
         for Token in L.Element_Count range 0 .. Count - 1 loop
            Big_Input.all (Token * Width .. Token * Width + 31) := Input.all (Token * 32 .. Token * 32 + 31);
         end loop;
         for Slot in Outputs'Range loop
            Big_Gates (Slot) := Gates (1); Big_Gates (Slot).Columns := Width;
            Big_Gates (Slot).Base := G (0)'Address; Big_Gates (Slot).Span := G'Length;
            Big_Gates (Slot).Length := G'Length;
            Big_Ups (Slot) := Big_Gates (Slot); Big_Ups (Slot).Base := U (0)'Address;
            Big_Downs (Slot) := Downs (1); Big_Downs (Slot).Rows := Width;
            Big_Downs (Slot).Base := D (0)'Address; Big_Downs (Slot).Span := D'Length;
            Big_Downs (Slot).Length := D'Length;
            TT.Allocate (Count * Width, Outputs (Slot));
         end loop;
         V.Dispatch_Reference_Experts
           (Big_Gates, Big_Ups, Big_Downs, [1 .. 8 => Big_Input], Count, Outputs, 4.0, 25.0, Status);
         Assert (E.Is_Ok (Status), "wide grouped experts exceeded bounded packing workspace");
         for O of Outputs loop
            for I in O.all'Range loop
               Assert (N.Bits (O (I)) = N.Bits
                         (if I mod Width < 32 then Output (I / Width * 32 + I mod Width) else 0.0),
                       "reused resident packing changed independent expert output");
            end loop;
         end loop;
         TT.Free (Big_Input); for O of Outputs loop TT.Free (O); end loop;
      exception
         when others => TT.Free (Big_Input); for O of Outputs loop TT.Free (O); end loop; raise;
      end;
      V.Close; TT.Free (Input); TT.Free (Output);
      declare
         Image : B.Byte_Array_Access := null;
      begin
         Tiny_Model.Build_Inkling (Image, Fault => Tiny_Model.Inkling_Aligned_Heads,
                                   Quantized => True, Uniform_Router => True);
         Model_Runner.Backend.CPU.Use_Integer_Activations (True);
         declare
            Held : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
            Descriptor : C.Container;
            Host, Device : aliased L.Model;
            CPU_Run, GPU_Run : L.Session;
            Team : aliased Model_Runner.Backend.CPU.Pool (2);
            Tokens : constant Model_Runner.Tokenizer.Token_Array (1 .. 17) := [others => 3];
            Control, Actual : L.Real_Array (0 .. 15);
            Expert_Bytes : Interfaces.Unsigned_64 := 0;
         begin
            Assert (C.Metadata_Bytes (Descriptor) = 0, "fresh uniform metadata accounting");
            C.Reader.Parse (Descriptor, Source, Status => Status);
            Assert (E.Is_Ok (Status), "uniform router parse");
            Assert (C.Metadata_Bytes (Descriptor) > 0, "parsed uniform metadata accounting");
            L.Prepare (Host, Descriptor, Source, Context => 32, Status => Status);
            Assert (E.Is_Ok (Status), "uniform router CPU prepare");
            L.Open (CPU_Run, Host, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
            Assert (E.Is_Ok (Status), "uniform router CPU open");
            L.Evaluate_Batch (CPU_Run, Host, Tokens, Control, Status => Status);
            Assert (E.Is_Ok (Status), "uniform router CPU batch");
            --  Leave all selected experts room while forcing ordinary split
            --  placement. The session reserve remains fully accounted for.
            for Index in 1 .. C.Tensor_Count (Descriptor) loop
               declare
                  Name : constant String := C.Tensor_Name (Descriptor, Index);
               begin
                  if Ada.Strings.Fixed.Index (Name, "exps.weight") > 0 then
                     Expert_Bytes := Expert_Bytes + C.Tensor_Bytes (Descriptor, Index);
                  end if;
               end;
            end loop;
            V.Open (Ready, Budget => L.Device_Kept_Back (L.Config (Host), 32)
                      + C.Tensor_Data_Bytes (Descriptor) - Expert_Bytes / 4, Tuning_Profile => "none");
            Assert (Ready, "uniform router GPU open");
            V.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_Every);
            L.Prepare (Device, Descriptor, Source, Context => 32,
                       Backend => Model_Runner.Backend.Backend_Device, Expert_Cache => 8 * 1024 * 1024,
                       Status => Status);
            Assert (E.Is_Ok (Status), "uniform router GPU prepare");
            L.Open (GPU_Run, Device, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
            Assert (E.Is_Ok (Status), "uniform router GPU session");
            L.Evaluate (GPU_Run, Device, 3, Actual, Status => Status);
            Assert (E.Is_Ok (Status), "uniform router residency seed: " & Status.Code'Image);
            L.Reset (GPU_Run);
            L.Evaluate_Batch (GPU_Run, Device, Tokens, Actual, Status => Status);
            Assert (E.Is_Ok (Status), "uniform router GPU batch: " & Status.Code'Image);
            Assert (L.Expert_Cache_Stats (GPU_Run).Batched_Device_Aggregations > 0,
                    "uniform resident batch did not exercise ordered GPU aggregation");
            Assert (Actual = Control, "uniform batched GPU aggregation changed complete model logits");
            Ada.Text_IO.Put_Line ("Uniform full-model batched GPU reductions: "
              & L.Expert_Cache_Stats (GPU_Run).Batched_Device_Aggregations'Image);
            L.Close (CPU_Run); L.Close (GPU_Run); L.Close (Host, Status); L.Close (Device, Status);
            C.Close (Descriptor);
            Assert (C.Metadata_Bytes (Descriptor) = 0, "closed uniform metadata accounting");
            Model_Runner.Backend.CPU.Close (Team); V.Close;
         exception
            when others => L.Close (CPU_Run); L.Close (GPU_Run); L.Close (Host, Status); L.Close (Device, Status);
               C.Close (Descriptor); Model_Runner.Backend.CPU.Close (Team); V.Close; raise;
         end;
         Model_Runner.Backend.CPU.Use_Integer_Activations (False); B.Free (Image);
      exception
         when others => Model_Runner.Backend.CPU.Use_Integer_Activations (False); B.Free (Image); raise;
      end;
   exception
      when others => V.Close; TT.Free (Input); TT.Free (Output); raise;
   end Vulkan_Reference_Mixture;

   procedure Vulkan_Integer_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package QI renames Model_Runner.Quantization.Integers;
      package TT renames Model_Runner.Tensors;
      package G renames Model_Runner.GGUF;
      package Device renames Model_Runner.Backend.Device;
      package PD renames Model_Runner.Platform.Device;
      package Products renames Model_Runner.Platform.Device.Products;
      Inventory : PD.Inventory;
      Opened : PD.Context;
      Probe : Products.Engine;
      type Kinds is array (Positive range <>) of G.Tensor_Type;
      Formats : constant Kinds := [G.Type_Q4_K, G.Type_Q5_K, G.Type_Q6_K, G.Type_Q5_0, G.Type_Q8_0];
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Width : constant N.Element_Count := 2304;
      Vectors, Target, Second_Target : TT.Real_Array_Access := null;
      Bulk : B.Byte_Array (1 .. 5 * 4896);
      Mixed : TT.View_Group (1 .. 5);
      Mixed_Targets : TT.Target_Group (1 .. 5) := [others => null];
      Mixed_Expected : N.Real_Array (0 .. 5 * 34 - 1);
      Format_Index : Positive := 1;
      Values : QI.Signed_Array (0 .. 17 * Width - 1);
      Scales : N.Real_Array (0 .. 17 * Width / 32 - 1);
      Totals : QI.Sum_Array (Scales'Range);
      Halves : QI.Sum_Array (0 .. Scales'Length * 2 - 1);
      Status : E.Error_Info;
      Good, Ready : Boolean;
   begin
      Assert (not Products.Takes_Reference_Integers (Probe), "closed engine advertises reference integer pipeline");
      if not Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_REFERENCE_GPU") then
         Ada.Text_IO.Put_Line ("note: native Vulkan integer operators need MODEL_RUNNER_INKLING_REFERENCE_GPU");
         return;
      end if;
      PD.Open (Inventory, Ready);
      Assert (Ready and then PD.Count (Inventory) > 0, "reference integer inventory unavailable");
      PD.Open (Opened, Inventory, 1, Ready);
      Assert (Ready, "reference integer context unavailable");
      Products.Open (Probe, Opened, Ready, Budget => 268_435_456);
      Assert (Ready and then Products.Takes_Reference_Integers (Probe), "reference integer pipeline unavailable");
      Assert (Products.Reference_Packing_Reuses (Probe) = 0, "fresh engine retained packing reuse counters");
      Assert (Products.Takes_Reference_Integers (Probe, Device_Packing => True),
              "reference activation packing did not obtain a real device pipeline");
      Products.Close (Probe);
      Assert (not Products.Takes_Reference_Integers (Probe), "closed engine retained reference integer pipeline");
      PD.Close (Opened); PD.Close (Inventory);
      Device.Open (Ready, Budget => 268_435_456, Tuning_Profile => "none");
      Assert (Ready, "native Vulkan operator device unavailable");
      Device.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_Every);
      TT.Allocate (17 * Width, Vectors); TT.Allocate (34, Target); TT.Allocate (34, Second_Target);
      for Into of Mixed_Targets loop TT.Allocate (34, Into); end loop;
      for I in Input'Range loop Input_Bytes (B.Byte_Count (I)) := B.Byte (Character'Pos (Input (I))); end loop;
      for V in N.Element_Count range 0 .. 16 loop
         for C in N.Element_Count range 0 .. Width - 1 loop
            Vectors.all (V * Width + C) := B.Get_F32 (Input_Bytes, B.Byte_Count ((V mod 2) * 512 + C mod 512) * 4,
                        Good);
            Assert (Good, "native Vulkan input fixture truncated");
            case V is
               when 8 => Vectors.all (V * Width + C) := 0.0;
               when 9 => Vectors.all (V * Width + C) := (if C mod 2 = 0 then 127.0 else -127.0);
               when 10 => Vectors.all (V * Width + C) := (if C mod 2 = 0 then -127.0 else 127.0);
               when 11 => Vectors.all (V * Width + C) := N.Real (Integer (C mod 255) - 127) + 0.5;
               when 12 => Vectors.all (V * Width + C) := N.From_Bits (16#8000_0000#);
               when 13 => Vectors.all (V * Width + C) := N.Real (Integer (C mod 255) - 127) * 0.000001;
               when 14 => Vectors.all (V * Width + C) := N.Real (Integer (C mod 255) - 127) * 0.00000001;
               when 15 => Vectors.all (V * Width + C) := N.Real (Integer (C mod 255) - 127) * 32752.0;
               when others => null;
            end case;
         end loop;
      end loop;
      for Format of Formats loop
         declare
            Prefix : constant String := (case Format is
              when G.Type_Q4_K => "q4k", when G.Type_Q5_K => "q5k", when G.Type_Q6_K => "q6k",
              when G.Type_Q5_0 => "q50", when others => "q8");
            Encoded : constant String := Project_Tools.Files.Read_Raw_File
              ("fixtures/inkling2/" & (if Format = G.Type_Q8_0 then "q8-reference.bin"
                                       else Prefix & "-dot-reference-weights.bin"));
            Native : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
            Elements : constant N.Element_Count := N.Element_Count (G.Block_Elements (Format));
            Original : constant N.Element_Count := 512 / Elements;
            Blocks : constant N.Element_Count := Width / Elements;
            RB : constant B.Byte_Count := B.Byte_Count (Blocks) * Native;
            Matrix, Partner : B.Byte_Array (1 .. RB * 2);
            Weight, Other : TT.View;
         begin
            for Row in N.Element_Count range 0 .. 1 loop
               for Block in 0 .. Blocks - 1 loop
                  for Byte in B.Byte_Count range 0 .. Native - 1 loop
                     Matrix (1 + B.Byte_Count (Row) * RB + B.Byte_Count (Block) * Native + Byte) :=
                       B.Byte (Character'Pos (Encoded (Encoded'First
                         + Natural (B.Byte_Count (Row * Original + Block mod Original) * Native + Byte))));
                  end loop;
               end loop;
            end loop;
            Weight := (Format => Format, Rows => 2, Columns => Width, Base => Matrix (1)'Address,
                       Span => Matrix'Length, Offset => 0, Length => Matrix'Length, Interleaved => False,
                       Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
            Partner (1 .. RB) := Matrix (1 + RB .. RB * 2);
            Partner (1 + RB .. RB * 2) := Matrix (1 .. RB);
            Other := Weight; Other.Base := Partner (1)'Address;
            declare
               At_Byte : constant B.Byte_Count := B.Byte_Count (Format_Index - 1) * 4896;
            begin
               Bulk (At_Byte + 1 .. At_Byte + RB * 2) := Matrix;
               Mixed (Format_Index) := Weight;
               Mixed (Format_Index).Base := Bulk (At_Byte + 1)'Address;
            end;
            QI.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
            QI.Quantize_Vectors (Vectors.all, 17, Width, Values, Scales, Totals, Halves, Good,
              Super => QI.Supers_Vectors (Format), Reference_Rounding => True,
              Half_Scales => Format in G.Type_Q8_0 | G.Type_Q5_0);
            Assert (Good, "native Vulkan reference packing declined");
            for Count in N.Element_Count range 1 .. 17 loop
               declare
                  Expected : N.Wide_Real_Array (0 .. 2 * Count - 1) := [others => 0.0];
               begin
                  QI.Use_Wide_Rows (True); QI.Use_Deep_Rows (False);
                  QI.Accumulate_Rows (Format, Matrix, 0, RB, 2,
                    Width / N.Element_Count (G.Block_Elements (Format)), Values, Scales, Totals, Halves,
                    0, Width, Count, Expected, Good, Reference_Arithmetic => True);
                  QI.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
                  Assert (Good, "native Vulkan scalar oracle declined");
                  if Count = 17 then
                     for V in N.Element_Count range 0 .. 16 loop
                        for Row in N.Element_Count range 0 .. 1 loop
                           Mixed_Expected (N.Element_Count (Format_Index - 1) * 34 + V * 2 + Row) :=
                             N.Real (Expected (Row * 17 + V));
                        end loop;
                     end loop;
                  end if;
                  Device.Dispatch_Batch (Weight, Vectors, Count, Target, Status);
                  Assert (E.Is_Ok (Status), "native Vulkan integer dispatch failed: " & Prefix & Status.Code'Image);
                  for V in 0 .. Count - 1 loop
                     for Row in N.Element_Count range 0 .. 1 loop
                        Assert (N.Bits (Target.all (V * 2 + Row)) = N.Bits (N.Real (Expected (Row * Count + V))),
                                "Vulkan integer lanes differ: " & Prefix & Count'Image & V'Image & Row'Image
                                & " actual bits" & N.Bits (Target.all (V * 2 + Row))'Image
                                & " expected bits" & N.Bits (N.Real (Expected (Row * Count + V)))'Image);
                     end loop;
                  end loop;
                  Device.Dispatch_Batch_Group ([3 => Weight, 4 => Other], Vectors, Count,
                                                [7 => Target, 8 => Second_Target], Status);
                  Assert (E.Is_Ok (Status), "native Vulkan reference group failed: " & Prefix & Status.Code'Image);
                  for V in 0 .. Count - 1 loop
                     for Row in N.Element_Count range 0 .. 1 loop
                        Assert (N.Bits (Target.all (V * 2 + Row)) = N.Bits (N.Real (Expected (Row * Count + V)))
                          and then N.Bits (Second_Target.all (V * 2 + Row))
                            = N.Bits (N.Real (Expected ((1 - Row) * Count + V))),
                          "grouped native Vulkan products changed lanes: " & Prefix & Count'Image);
                     end loop;
                  end loop;
                  if Count = 2 then
                     Device.Dispatch_Group ([Weight, Other], Vectors, [Target, Second_Target], Status, Apart => Width);
                     Assert (E.Is_Ok (Status), "apart native Vulkan group failed: " & Prefix & Status.Code'Image);
                     for Row in N.Element_Count range 0 .. 1 loop
                        Assert (N.Bits (Target.all (Row)) = N.Bits (N.Real (Expected (Row * Count)))
                          and then N.Bits (Second_Target.all (Row))
                            = N.Bits (N.Real (Expected ((1 - Row) * Count + 1))),
                          "apart native Vulkan products changed input identity: " & Prefix);
                     end loop;
                  end if;
               end;
            end loop;
            if Format = G.Type_Q6_K then
               Weight.Rows := 1; Weight.Span := RB; Weight.Length := RB;
               Target.all := [others => 333.0];
               Device.Dispatch_Batch (Weight, Vectors, 1, Target, Status);
               Assert (not E.Is_Ok (Status) and then (for all V of Target.all => V = 333.0),
                       "native Vulkan accepted an unpadded final weight word or wrote on rejection");
            end if;
         end;
         if Format_Index < 5 then Format_Index := Format_Index + 1; end if;
      end loop;
      Device.Dispatch_Batch_Group (Mixed, Vectors, 17, Mixed_Targets, Status);
      Assert (E.Is_Ok (Status), "mixed reference packing classes refused: " & Status.Code'Image);
      for F in Mixed_Targets'Range loop
         for I in N.Element_Count range 0 .. 33 loop
            Assert (N.Bits (Mixed_Targets (F).all (I)) = N.Bits (Mixed_Expected (N.Element_Count (F - 1) * 34 + I)),
                    "mixed native reference group used another product's packing");
         end loop;
         Mixed_Targets (F).all := [others => 123.0];
      end loop;
      Mixed (1).Reference_Activations := False;
      Device.Dispatch_Batch_Group (Mixed, Vectors, 17, Mixed_Targets, Status);
      Assert (not E.Is_Ok (Status), "mixed reference and non-reference group was silently approximated");
      for Into of Mixed_Targets loop
         Assert ((for all X of Into.all => X = 123.0), "rejected mixed reference group wrote outputs");
      end loop;
      Vectors.all (0) := N.From_Bits (16#7FC0_0000#);
      Target.all := [others => 456.0];
      Device.Dispatch_Batch (Mixed (2), Vectors, 1, Target, Status);
      Assert (not E.Is_Ok (Status) and then (for all X of Target.all => X = 456.0),
              "nonfinite reference activation reached device packing or changed output");
      Device.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_None);
      Device.Close;
      TT.Free (Vectors); TT.Free (Target); TT.Free (Second_Target);
      for Into of Mixed_Targets loop TT.Free (Into); end loop;
   exception
      when others =>
         Products.Close (Probe); PD.Close (Opened); PD.Close (Inventory);
         QI.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
         Device.Round_Walks (Model_Runner.Platform.Device.Products.Rounds_None);
         Device.Close; TT.Free (Vectors); TT.Free (Target); TT.Free (Second_Target);
      for Into of Mixed_Targets loop TT.Free (Into); end loop; raise;
   end Vulkan_Integer_Products;

   procedure Batched_Q4T_Rotations (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package Codec renames Model_Runner.Cache_Codecs.Transformed_Four_Bit;
      type Widths is array (Positive range <>) of N.Element_Count;
      Sizes : constant Widths := [32, 64, 128];
      Good : Boolean;
   begin
      for Width of Sizes loop
         for Count in N.Element_Count range 1 .. 17 loop
            declare
               Actual : N.Real_Array (3 .. 6 + Count * Width) := [others => 123.0];
               Expected : N.Real_Array (0 .. Count * Width - 1);
               One : N.Real_Array (0 .. Width - 1);
            begin
               for I in Expected'Range loop
                  Actual (I + 5) :=
                    (if I mod 11 = 0 then N.From_Bits (16#8000_0000#)
                     else N.Real (Integer ((I * 7919) mod 4093) - 2046) / 127.0);
               end loop;
               for Row in 0 .. Count - 1 loop
                  Codec.Rotate_Key (Actual (5 + Row * Width .. 5 + (Row + 1) * Width - 1), One, Good);
                  Assert (Good, "scalar Q4T rotation refused finite input");
                  Expected (Row * Width .. (Row + 1) * Width - 1) := One;
               end loop;
               Codec.Rotate_Rows (Actual (5 .. 4 + Count * Width), Width, Count, Good);
               Assert (Good, "batched Q4T rotation refused finite rows");
               for I in Expected'Range loop
                  Assert (N.Bits (Actual (I + 5)) = N.Bits (Expected (I)), "batched Q4T butterfly order changed");
               end loop;
               Assert (Actual (3) = 123.0 and then Actual (4) = 123.0
                 and then Actual (5 + Count * Width) = 123.0 and then Actual (6 + Count * Width) = 123.0,
                 "batched Q4T rotation wrote beyond rows");
               Codec.Rotate_Rows (Actual, Width + 1, Count, Good);
               Assert (not Good, "malformed Q4T width accepted");
               Actual (5) := N.From_Bits (16#7FC0_0000#);
               Codec.Rotate_Rows (Actual (5 .. 4 + Count * Width), Width, Count, Good);
               Assert (not Good, "nonfinite Q4T rotation input accepted");
            end;
         end loop;
      end loop;
   end Batched_Q4T_Rotations;

   procedure Reference_Long_Rows (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      package G renames Model_Runner.GGUF;
      package TT renames Model_Runner.Tensors;
      use type Interfaces.Unsigned_8;
      Width : constant N.Element_Count := 2304;
      Vectors : N.Real_Array (0 .. 33 * Width - 1);
      Values : QI.Signed_Array (Vectors'Range);
      Scales : N.Real_Array (0 .. Vectors'Length / 32 - 1);
      Totals : QI.Sum_Array (Scales'Range);
      Halves : QI.Sum_Array (0 .. Scales'Length * 2 - 1);
      type Kinds is array (Positive range <>) of G.Tensor_Type;
      Formats : constant Kinds := [G.Type_Q4_K, G.Type_Q5_K, G.Type_Q6_K, G.Type_Q5_0, G.Type_Q8_0];
      Good : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Byte_Products then return; end if;
      QI.Use_Wide_Rows (True);
      for V in N.Element_Count range 0 .. 32 loop
         for C in 0 .. Width - 1 loop
            Vectors (V * Width + C) := N.Real (Integer ((C * 97 + V * 233) mod 2047) - 1023)
              / N.Real (3 + (C / 64) mod 11);
         end loop;
      end loop;
      for Format of Formats loop
         declare
            Prefix : constant String := (case Format is
              when G.Type_Q4_K => "q4k", when G.Type_Q5_K => "q5k", when G.Type_Q6_K => "q6k",
              when G.Type_Q5_0 => "q50", when others => "q8");
            Encoded : constant String := Project_Tools.Files.Read_Raw_File
              ("fixtures/inkling2/" & (if Format = G.Type_Q8_0 then "q8-reference.bin"
                                       else Prefix & "-dot-reference-weights.bin"));
            Block_Size : constant B.Byte_Count := B.Byte_Count (G.Block_Bytes (Format));
            Blocks : constant N.Element_Count := Width / N.Element_Count (G.Block_Elements (Format));
            Old_Blocks : constant N.Element_Count := 512 / N.Element_Count (G.Block_Elements (Format));
            Row_Size : constant B.Byte_Count := B.Byte_Count (Blocks) * Block_Size;
            Matrix, Partner : B.Byte_Array (1 .. Row_Size * 5);
            Meta_A, Meta_B : TT.Real_Array_Access := null;
            Weight : TT.View;
            Status : E.Error_Info;
            procedure Check_Parallel_Preparation is
               package CPU renames Model_Runner.Backend.CPU;
               Team : aliased CPU.Pool (4);
               Packed : CPU.Packed_Rows;
               Actual : N.Real_Array (0 .. 5 * 33 - 1);
               Expected : N.Wide_Real_Array (Actual'Range) := [others => 0.0];
               Copy : TT.View := Weight;
               Done : Boolean;
               Bad : Boolean := False;
               procedure Produce (First : N.Element_Count; Into : out N.Real_Array) is
               begin
                  Into := Vectors (First .. First + Into'Length - 1);
                  if Bad and then First = 16 * Width then Into (Into'First) := N.From_Bits (16#7FC0_0001#); end if;
               end Produce;
            begin
               Copy.Base := Matrix (Matrix'First)'Address;
               QI.Use_Deep_Rows (False);
               QI.Accumulate_Rows (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                                   0, Width, 33, Expected, Done, Reference_Arithmetic => True);
               Assert (Done, "parallel packing independent lane oracle declined");
               QI.Use_Deep_Rows (True);
               CPU.Pack (Packed, Vectors'Unrestricted_Access, 33, Width, QI.Supers_Vectors (Format), Done,
                         Roles => [others => True], Reference_Arithmetic => True,
                         Half_Scales => Format in G.Type_Q8_0 | G.Type_Q5_0,
                         Transform => Produce'Unrestricted_Access, Team => Team'Unchecked_Access);
               Assert (Done, "parallel transformed input preparation declined");
               CPU.Multiply_Packed_Whole (Copy, Packed, Actual, Done);
               Assert (Done, "parallel transformed product declined");
               for Row in N.Element_Count range 0 .. 4 loop
                  for Token in N.Element_Count range 0 .. 32 loop
                     Assert (N.Bits (Actual (Token * 5 + Row)) = N.Bits (N.Real (Expected (Row * 33 + Token))),
                             "parallel packing changed independent reference products");
                  end loop;
               end loop;
               Bad := True;
               CPU.Pack (Packed, Vectors'Unrestricted_Access, 33, Width, QI.Supers_Vectors (Format), Done,
                         Roles => [others => True], Reference_Arithmetic => True,
                         Half_Scales => Format in G.Type_Q8_0 | G.Type_Q5_0,
                         Transform => Produce'Unrestricted_Access, Team => Team'Unchecked_Access);
               Assert (not Done, "parallel transformed input accepted non-finite data");
               Actual := [others => 123.0];
               CPU.Multiply_Packed_Whole (Copy, Packed, Actual, Done);
               Assert (not Done and then (for all X of Actual => X = 123.0),
                       "failed parallel preparation exposed partially packed rows");
               CPU.Unpack (Packed); CPU.Close (Team);
            exception
               when others => CPU.Unpack (Packed); CPU.Close (Team); raise;
            end Check_Parallel_Preparation;
         begin
            for Row in N.Element_Count range 0 .. 4 loop
               for Block in 0 .. Blocks - 1 loop
                  for Byte in B.Byte_Count range 0 .. Block_Size - 1 loop
                     Matrix (1 + B.Byte_Count (Row * Blocks + Block) * Block_Size + Byte) :=
                       B.Byte (Character'Pos (Encoded (Encoded'First + Natural
                         (B.Byte_Count ((Row rem 2) * Old_Blocks + Block rem Old_Blocks) * Block_Size + Byte))));
                  end loop;
               end loop;
            end loop;
            for Row in B.Byte_Count range 0 .. 4 loop
               Partner (1 + Row * Row_Size .. (Row + 1) * Row_Size) :=
                 Matrix (1 + (4 - Row) * Row_Size .. (5 - Row) * Row_Size);
            end loop;
            Weight := (Format => Format, Rows => 5, Columns => Width, Base => Matrix (1)'Address,
                       Span => Matrix'Length, Offset => 0, Length => Matrix'Length, Interleaved => False,
                       Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
            if TT.Reference_Scale_Count (Weight) > 0 then
               TT.Allocate (TT.Reference_Scale_Count (Weight), Meta_A);
               TT.Allocate (TT.Reference_Scale_Count (Weight), Meta_B);
               TT.Decode_Reference_Scales (Weight, Meta_A.all, Status);
               Assert (E.Is_Ok (Status), "native coefficients unavailable");
               Weight.Base := Partner (1)'Address;
               TT.Decode_Reference_Scales (Weight, Meta_B.all, Status);
               Assert (E.Is_Ok (Status), "partner coefficients unavailable");
            end if;
            QI.Use_Deep_Rows (True);
            QI.Quantize_Vectors (Vectors, 33, Width, Values, Scales, Totals, Halves, Good,
                                 Super => QI.Supers_Vectors (Format), Reference_Rounding => True,
                                 Half_Scales => Format in G.Type_Q8_0 | G.Type_Q5_0);
            Assert (Good, "long-row activations declined");
            Check_Parallel_Preparation;
            for Count in N.Element_Count range 1 .. 33 loop
               declare
                  Expected, Actual : N.Wide_Real_Array (0 .. 5 * Count - 1) := [others => 0.0];
                  Direct : aliased N.Real_Array := [5 .. 4 + Count * 7 => 123.0];
                  Other : aliased N.Real_Array := [11 .. 10 + Count * 7 => 123.0];
                  Destinations : Model_Runner.Shares.Member_Rows (3 .. 2 + Natural (Count));
                  Sources : Model_Runner.Shares.Member_Rows (9 .. 8 + Natural (Count));
               begin
                  QI.Use_Deep_Rows (False);
                  QI.Accumulate_Rows (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                                      0, Width, Count, Expected, Good, Reference_Arithmetic => True);
                  Assert (Good, "qualified scalar long-row reference declined");
                  QI.Use_Deep_Rows (True);
                  QI.Accumulate_Rows (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                                      0, Width, Count, Actual, Good, Reference_Arithmetic => True);
                  Assert (Good, "streamed long-row product declined");
                  for I in Expected'Range loop
                     Assert (N.Bits (N.Real (Actual (I))) = N.Bits (N.Real (Expected (I))),
                             "long-row reference lanes changed: " & Prefix & Count'Image & I'Image);
                  end loop;
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good);
                  Assert (Good, "direct paired-row product declined");
                  for V in 0 .. Count - 1 loop
                     for Row in N.Element_Count range 0 .. 4 loop
                        Assert (N.Bits (Direct (6 + V * 7 + Row)) = N.Bits (N.Real (Expected (Row * Count + V))),
                                "direct row mismatch: " & Prefix & Count'Image & Row'Image & V'Image);
                     end loop;
                     Assert (Direct (5 + V * 7) = 123.0 and then Direct (11 + V * 7) = 123.0,
                             "direct product crossed output range");
                  end loop;
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good,
                     Partner => Partner, Partner_Target => Other'Unchecked_Access);
                  Assert (Good, "joint gate/up product declined");
                  for V in 0 .. Count - 1 loop
                     for Row in N.Element_Count range 0 .. 4 loop
                        Assert (N.Bits (Direct (6 + V * 7 + Row)) = N.Bits (N.Real (Expected (Row * Count + V)))
                          and then N.Bits (Other (12 + V * 7 + Row))
                            = N.Bits (N.Real (Expected ((4 - Row) * Count + V))),
                          "joint row mismatch: " & Prefix & Count'Image & Row'Image & V'Image);
                     end loop;
                     Assert (Other (11 + V * 7) = 123.0 and then Other (17 + V * 7) = 123.0,
                             "joint product crossed output range");
                  end loop;
                  for I in Destinations'Range loop
                     Destinations (I) := Natural (Count) - 1 - (I - Destinations'First);
                  end loop;
                  Direct := [others => 123.0]; Other := [others => 123.0];
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good,
                     Metadata => (if Meta_A /= null then Meta_A.all else []), Partner => Partner,
                     Partner_Metadata => (if Meta_B /= null then Meta_B.all else []),
                     Partner_Target => Other'Unchecked_Access, Result_Members => Destinations);
                  Assert (Good, "cached and scattered joint products declined");
                  for V in 0 .. Count - 1 loop
                     for Row in N.Element_Count range 0 .. 4 loop
                        Assert (N.Bits (Direct (6 + (Count - V - 1) * 7 + Row))
                            = N.Bits (N.Real (Expected (Row * Count + V)))
                          and then N.Bits (Other (12 + (Count - V - 1) * 7 + Row))
                            = N.Bits (N.Real (Expected ((4 - Row) * Count + V))),
                            "cached scattered result differs: " & Prefix & Count'Image & Row'Image & V'Image);
                     end loop;
                     Assert (Direct (5 + V * 7) = 123.0 and then Direct (11 + V * 7) = 123.0,
                             "scattered product crossed output range");
                  end loop;
                  for I in Sources'Range loop
                     Sources (I) := (Natural (Count) - 1 - (I - Sources'First)) / 2;
                  end loop;
                  Direct := [others => 123.0]; Other := [others => 123.0];
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good,
                     Metadata => (if Meta_A /= null then Meta_A.all else []), Partner => Partner,
                     Partner_Metadata => (if Meta_B /= null then Meta_B.all else []),
                     Partner_Target => Other'Unchecked_Access, Input_Members => Sources);
                  Assert (Good, "indexed packed inputs declined");
                  for V in 0 .. Count - 1 loop
                     for Row in N.Element_Count range 0 .. 4 loop
                        declare
                           From : constant N.Element_Count := N.Element_Count (Sources (Sources'First + Natural (V)));
                        begin
                           Assert (N.Bits (Direct (6 + V * 7 + Row)) = N.Bits (N.Real (Expected (Row * Count + From)))
                             and then N.Bits (Other (12 + V * 7 + Row))
                               = N.Bits (N.Real (Expected ((4 - Row) * Count + From))),
                             "indexed input differs from independent scalar result: " & Prefix & Count'Image);
                        end;
                     end loop;
                     Assert (Direct (5 + V * 7) = 123.0 and then Direct (11 + V * 7) = 123.0,
                             "indexed input product crossed output guards");
                  end loop;
                  if Count = 33 then
                     declare
                        Bytes : constant QI.Signed_Array (5 .. 4 + Values'Length) := Values;
                        Scale_Rows : constant N.Real_Array (7 .. 6 + Scales'Length) := Scales;
                        Sums : constant QI.Sum_Array (9 .. 8 + Totals'Length) := Totals;
                        Half_Sums : constant QI.Sum_Array (11 .. 10 + Halves'Length) := Halves;
                     begin
                        QI.Reference_Products
                          (Format, Matrix, 0, Row_Size, 5, Blocks, Bytes, Scale_Rows, Sums, Half_Sums,
                           0, Width, Count, Direct'Unchecked_Access, 1, 7, Good, Input_Members => Sources);
                        Assert (Good, "indexed input arrays with shifted origins declined");
                        for V in 0 .. Count - 1 loop
                           for Row in N.Element_Count range 0 .. 4 loop
                              Assert (N.Bits (Direct (6 + V * 7 + Row)) = N.Bits (N.Real
                                (Expected (Row * Count + N.Element_Count (Sources (Sources'First + Natural (V)))))),
                                "indexed input origin changed numerical output");
                           end loop;
                        end loop;
                     end;
                  end if;
                  Sources := [others => 0];
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values (0 .. Width - 1),
                     Scales (0 .. Width / 32 - 1), Totals (0 .. Width / 32 - 1), Halves (0 .. Width / 16 - 1),
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good, Input_Members => Sources);
                  Assert (Good, "many output vectors from one packed source declined");
                  for V in 0 .. Count - 1 loop
                     for Row in N.Element_Count range 0 .. 4 loop
                        Assert (N.Bits (Direct (6 + V * 7 + Row)) = N.Bits (N.Real (Expected (Row * Count))),
                                "repeated packed source changed output");
                     end loop;
                  end loop;
                  Sources (Sources'First) := 33; Direct := [others => 123.0];
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good, Input_Members => Sources);
                  Assert (not Good and then (for all X of Direct => X = 123.0), "invalid source wrote output");
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good,
                     Input_Members => Sources (Sources'First .. Sources'Last - 1));
                  if Count > 1 then
                     Assert (not Good and then (for all X of Direct => X = 123.0), "short source map wrote output");
                  end if;
                  if Count = 1 then
                     Sources (Sources'First) := 1; Direct := [others => 123.0];
                     QI.Reference_Products
                       (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                        0, 1, Count, Direct'Unchecked_Access, 1, 7, Good, Input_Members => Sources);
                     Assert (not Good and then (for all X of Direct => X = 123.0),
                             "a single indexed packed input accepted an unaligned source stride");
                     QI.Reference_Products
                       (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                        0, 1, Count, Direct'Unchecked_Access, 1, 7, Good);
                     Assert (Good, "an ordinary single vector incorrectly consumed its unused stride");
                     for Row in N.Element_Count range 0 .. 4 loop
                        Assert (N.Bits (Direct (6 + Row)) = N.Bits (N.Real (Expected (Row))),
                                "single-vector stride rejection changed ordinary products");
                     end loop;
                  end if;
                  Direct := [others => 123.0]; Destinations (Destinations'First) := Natural (Count);
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good, Result_Members => Destinations);
                  Assert (not Good and then (for all X of Direct => X = 123.0), "bad destination wrote output");
                  if Count > 1 then
                     Destinations := [others => 0];
                     QI.Reference_Products
                       (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                        0, Width, Count, Direct'Unchecked_Access, 1, 7, Good, Result_Members => Destinations);
                     Assert (not Good and then (for all X of Direct => X = 123.0),
                        "duplicate destination wrote output");
                  end if;
                  Direct := [others => 123.0]; Other := [others => 123.0];
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good,
                     Partner => Partner (1 .. Partner'Last - 1), Partner_Target => Other'Unchecked_Access);
                  Assert (not Good and then (for all X of Direct => X = 123.0)
                    and then (for all X of Other => X = 123.0), "truncated partner changed output");
                  QI.Reference_Products
                    (Format, Matrix, 0, Row_Size, 5, Blocks, Values, Scales, Totals, Halves,
                     0, Width, Count, Direct'Unchecked_Access, 1, 7, Good,
                     Partner => Partner, Partner_Target => Direct'Unchecked_Access);
                  Assert (not Good and then (for all X of Direct => X = 123.0), "aliased pair changed output");
                  if Format in G.Type_Q8_0 | G.Type_Q5_0 then
                     declare
                        Edge : QI.Signed_Array (Values'Range) := [others => 0];
                        Lane : N.Real_Array (0 .. 7);
                        Dot : Integer;
                        Scale, Wanted : N.Real;
                        Code : Integer;
                        Raw : Interfaces.Unsigned_8;
                        Readable : Boolean;
                        At_Byte : B.Byte_Count;
                     begin
                        for V in 0 .. Count - 1 loop
                           Edge (V * Width .. V * Width + 31) := [others => QI.Byte_Signed'First];
                        end loop;
                        QI.Reference_Products
                          (Format, Matrix, 8 * Block_Size, Row_Size, 5, 1, Edge, Scales, Totals, Halves,
                           0, Width, Count, Direct'Unchecked_Access, 1, 7, Good);
                        Assert (Good, "signed-byte fallback declined");
                        for V in 0 .. Count - 1 loop
                           for Row in N.Element_Count range 0 .. 4 loop
                              At_Byte := B.Byte_Count (Row) * Row_Size + 8 * Block_Size;
                              Scale := N.To_Real (N.Half (B.Get_U16 (Matrix, At_Byte, Readable)))
                                * Scales (V * Width / 32);
                              for Group in N.Element_Count range 0 .. 7 loop
                                 Dot := 0;
                                 for C in Group * 4 .. Group * 4 + 3 loop
                                    if Format = G.Type_Q8_0 then
                                       Code := Integer (Matrix (1 + At_Byte + 2 + B.Byte_Count
                        (C)));
                                       if Code > 127 then Code := Code - 256; end if;
                                    else
                                       Raw := Matrix (1 + At_Byte + 6 + B.Byte_Count (C mod 16));
                                       Code := Integer (Interfaces.Shift_Right (Raw, (if C < 16 then 0 else 4)) and 15);
                                       Raw := Matrix (1 + At_Byte + 2 + B.Byte_Count (C / 8));
                                       if (Interfaces.Shift_Right (Raw, Natural (C mod 8)) and 1) = 0 then
                                          Code := Code - 16;
                                       end if;
                                    end if;
                                    Dot := Dot - 128 * Code;
                                 end loop;
                                 Lane (Group) := 0.0 + N.Real (Dot) * Scale;
                              end loop;
                              Wanted := ((Lane (0) + Lane (4)) + (Lane (2) + Lane (6)))
                                + ((Lane (1) + Lane (5)) + (Lane (3) + Lane (7)));
                              Assert (N.Bits (Direct (6 + V * 7 + Row)) = N.Bits (Wanted),
                                      "minus-128 dot: " & Prefix & Count'Image & Row'Image & V'Image
                                        & " actual " & Direct (6 + V * 7 + Row)'Image & " wanted " & Wanted'Image);
                           end loop;
                        end loop;
                     end;
                  end if;
               end;
            end loop;
            TT.Free (Meta_A); TT.Free (Meta_B);
         exception
            when others => TT.Free (Meta_A); TT.Free (Meta_B); raise;
         end;
      end loop;
   exception
      when others => QI.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products); raise;
   end Reference_Long_Rows;

   procedure Reference_Integer_Tiles (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package N renames Model_Runner.Numerics;
      package QI renames Model_Runner.Quantization.Integers;
      package IL renames Model_Runner.Quantization.Interleave;
      package TT renames Model_Runner.Tensors;
      package G renames Model_Runner.GGUF;
      type Kinds is array (Positive range <>) of G.Tensor_Type;
      Formats : constant Kinds := [G.Type_Q4_K, G.Type_Q5_K, G.Type_Q6_K, G.Type_Q5_0, G.Type_Q8_0];
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Vectors : N.Real_Array (0 .. 5119) := [others => 0.0];
      Values : QI.Signed_Array (11 .. 5130);
      Scales : N.Real_Array (7 .. 166);
      Totals : QI.Sum_Array (5 .. 164);
      Halves : QI.Sum_Array (3 .. 322);
      Ok : Boolean;
      function Selected (Vector : N.Element_Count) return N.Element_Count is
        (if Vector = 0 or else Vector = 2 or else Vector = 3 then 1 else 0);
   begin
      if not Model_Runner.Backend.CPU.Byte_Products then return; end if;
      for I in Input'Range loop Input_Bytes (B.Byte_Count (I)) := B.Byte (Character'Pos (Input (I))); end loop;
      for V in N.Element_Count range 0 .. 8 loop
         for C in N.Element_Count range 0 .. 511 loop
            Vectors ((V + 1) * 512 + C) := B.Get_F32
              (Input_Bytes, B.Byte_Count (Selected (V) * 512 + C) * 4, Ok);
            Assert (Ok, "tile input fixture truncated");
         end loop;
      end loop;
      for Format of Formats loop
         declare
            Prefix : constant String := (case Format is
              when G.Type_Q4_K => "q4k", when G.Type_Q5_K => "q5k", when G.Type_Q6_K => "q6k",
              when G.Type_Q5_0 => "q50", when others => "q8");
            Encoded : constant String := Project_Tools.Files.Read_Raw_File
              ("fixtures/inkling2/" & (if Format = G.Type_Q8_0 then "q8-reference.bin"
                                       else Prefix & "-dot-reference-weights.bin"));
            Golden : constant String := Project_Tools.Files.Read_Raw_File
              ("fixtures/inkling2/" & Prefix & "-dot-reference"
               & (if Format = G.Type_Q8_0 then ".bin" else "-output.bin"));
            RB : constant B.Byte_Count := B.Byte_Count (Encoded'Length / 2);
            Blocks : constant N.Element_Count := 512 / N.Element_Count (G.Block_Elements (Format));
            Matrix : aliased B.Byte_Array (1 .. 16 + 8 * RB) := [others => 0];
            Panel : aliased B.Byte_Array (1 .. 8 * RB);
            Expected : B.Byte_Array (1 .. 16);
            Sums : N.Wide_Real_Array (19 .. 33) := [others => 0.125];
            Full : N.Real_Array (0 .. 39);
            Weight : TT.View;
            Metadata : TT.Real_Array_Access := null;
            Status : E.Error_Info;
         begin
            for Row in N.Element_Count range 0 .. 7 loop
               for C in B.Byte_Count range 0 .. RB - 1 loop
                  Matrix (Matrix'First + 16 + B.Byte_Count (Row) * RB + C) :=
                    B.Byte (Character'Pos (Encoded (Encoded'First + Natural (Row rem 2) * Natural (RB) + Natural (C))));
               end loop;
            end loop;
            for I in Golden'Range loop Expected (B.Byte_Count (I)) := B.Byte (Character'Pos (Golden (I))); end loop;
            QI.Quantize_Vectors (Vectors, 10, 512, Values, Scales, Totals, Halves, Ok,
                                 Super => QI.Supers_Vectors (Format), Reference_Rounding => True);
            Assert (Ok, "tile activation packing failed");
            if not QI.Supers_Vectors (Format) then
               for Scale of Scales loop Scale := N.To_Real (N.To_Half (Scale)); end loop;
            end if;
            QI.Accumulate_Rows (Format, Matrix, 16, RB, 3, Blocks, Values, Scales, Totals, Halves,
                                512, 512, 5, Sums, Ok, Reference_Arithmetic => True);
            Assert (Ok, "odd-row five-vector tile declined for " & Prefix);
            for Row in N.Element_Count range 0 .. 2 loop
               for V in N.Element_Count range 0 .. 4 loop
                  Assert (Sums (19 + Row * 5 + V) = 0.125 + N.Wide_Real
                    (B.Get_F32 (Expected, B.Byte_Count ((Row rem 2) * 2 + Selected (V)) * 4, Ok)),
                    "integer tile differs from independent golden: " & Prefix & Row'Image & V'Image);
               end loop;
            end loop;
            IL.Build (Format, Matrix, 16, Panel, 0, 8, Blocks, Ok);
            Assert (Ok, "independent integer panel build failed");
            Weight := (Format => Format, Rows => 8, Columns => 512, Base => Panel (1)'Address,
                       Span => Panel'Length, Offset => 0, Length => Panel'Length, Interleaved => True,
                       Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
            if TT.Reference_Scale_Count (Weight) > 0 then
               TT.Allocate (TT.Reference_Scale_Count (Weight), Metadata);
               TT.Decode_Reference_Scales (Weight, Metadata.all, Status);
               Assert (E.Is_Ok (Status), "panel header cache failed");
               Weight.Scales := Metadata;
            end if;
            TT.Mat_Mul_Range_Packed
              (Weight, Values (Values'First + 512 .. Values'Last), Scales (Scales'First + 16 .. Scales'Last),
               Totals (Totals'First + 16 .. Totals'Last), Halves (Halves'First + 32 .. Halves'Last),
               5, Full, 0, 7, Ok);
            Assert (Ok, "reference integer panel declined");
            for Row in N.Element_Count range 0 .. 7 loop
               for V in N.Element_Count range 0 .. 4 loop
                  Assert (N.Bits (Full (V * 8 + Row)) = N.Bits (B.Get_F32
                    (Expected, B.Byte_Count ((Row rem 2) * 2 + Selected (V)) * 4, Ok)),
                    "cached panel integer tile differs: " & Prefix & Row'Image & V'Image);
               end loop;
            end loop;
            for Count in N.Element_Count range 1 .. 9 loop
               declare
                  Native_Sums : N.Wide_Real_Array (0 .. 3 * Count - 1) := [others => 0.0];
                  Panel_Sums : N.Real_Array (0 .. 8 * Count - 1);
               begin
                  QI.Accumulate_Rows
                    (Format, Matrix, 16, RB, 3, Blocks, Values, Scales, Totals, Halves,
                     512, 512, Count, Native_Sums, Ok, Reference_Arithmetic => True);
                  Assert (Ok, "stream/tile remainder declined");
                  for Row in N.Element_Count range 0 .. 2 loop
                     for V in 0 .. Count - 1 loop
                        Assert (N.Bits (N.Real (Native_Sums (Row * Count + V))) = N.Bits
                          (B.Get_F32 (Expected, B.Byte_Count ((Row rem 2) * 2 + Selected (V)) * 4, Ok)),
                          "stream/tile remainder differs: " & Prefix & Count'Image & Row'Image & V'Image);
                     end loop;
                  end loop;
                  for Cached in Boolean loop
                     Weight.Scales := (if Cached then Metadata else null);
                     TT.Mat_Mul_Range_Packed
                       (Weight, Values (Values'First + 512 .. Values'Last),
                        Scales (Scales'First + 16 .. Scales'Last), Totals (Totals'First + 16 .. Totals'Last),
                        Halves (Halves'First + 32 .. Halves'Last), Count, Panel_Sums, 0, 7, Ok);
                     Assert (Ok, "direct panel remainder declined");
                     for Row in N.Element_Count range 0 .. 7 loop
                        for V in 0 .. Count - 1 loop
                           Assert (N.Bits (Panel_Sums (V * 8 + Row)) = N.Bits
                             (B.Get_F32 (Expected, B.Byte_Count ((Row rem 2) * 2 + Selected (V)) * 4, Ok)),
                             "direct panel remainder differs: " & Prefix & Count'Image & Row'Image & V'Image);
                        end loop;
                     end loop;
                  end loop;
               end;
            end loop;
            TT.Free (Metadata);
            Sums := [others => -7.0];
            QI.Accumulate_Rows (Format, Matrix (1 .. 16 + 3 * RB - 1), 16, RB, 3, Blocks,
                                Values, Scales, Totals, Halves, 512, 512, 5, Sums, Ok,
                                Reference_Arithmetic => True);
            Assert (not Ok and then (for all V of Sums => V = -7.0), "tile rejection modified sums");
         exception
            when others => TT.Free (Metadata); raise;
         end;
      end loop;
   end Reference_Integer_Tiles;

   procedure Reference_F32_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      package N renames Model_Runner.Numerics;
      Encoded : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/f32-dot-reference.bin");
      Bytes : aliased B.Byte_Array (1 .. B.Byte_Count (Encoded'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (5 .. 1028);
      Target : L.Real_Array (13 .. 16) := [others => 0.0];
      Weight : TT.View;
      Ok : Boolean;
   begin
      Assert (Model_Runner.Backend.CPU.Byte_Products = Model_Runner.Platform.Byte_Products,
              "CPU backend vector capability differs from the host");
      if not Model_Runner.Platform.Byte_Products then return; end if;
      TT.Use_Deep_Products (True);
      TT.Use_Wide_Halves (True);
      Assert (Encoded'Length = 4096 and then Golden'Length = 16, "independent F32 dot fixture shape");
      for Index in Encoded'Range loop
         Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Encoded (Index)));
      end loop;
      for Index in Golden'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Golden (Index)));
      end loop;
      for Index in L.Element_Count range 0 .. 1023 loop
         Vectors (Vectors'First + Index) := B.Get_F32 (Bytes, B.Byte_Count (Index) * 4, Ok);
         Assert (Ok, "independent F32 dot input truncated");
      end loop;
      Weight := (Format => Model_Runner.GGUF.Type_F32, Rows => 2, Columns => 512,
                 Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null,
                 Base => Bytes'Address, Span => Bytes'Length, Offset => 0,
                 Length => Bytes'Length, Interleaved => False);
      TT.Mat_Mul_Range_Float (Weight, Vectors, 2, Target, 0, 1, Ok);
      Assert (Ok, "reference F32 product declined");
      for Vector in L.Element_Count range 0 .. 1 loop
         for Row in L.Element_Count range 0 .. 1 loop
            Assert (N.Bits (Target (Target'First + Vector * 2 + Row))
                    = N.Bits (B.Get_F32 (Expected, B.Byte_Count (Row * 2 + Vector) * 4, Ok)),
                    "F32 lane product differs from independent reference");
            Assert (Ok, "independent F32 dot result truncated");
         end loop;
      end loop;
   end Reference_F32_Products;

   procedure Reference_Q4_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Encoded : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q4k-dot-reference-weights.bin");
      Golden : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q4k-dot-reference-output.bin");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Bytes : B.Byte_Array (1 .. B.Byte_Count (Encoded'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (0 .. 1023);
      Values : QI.Signed_Array (0 .. 1023);
      Scales : L.Real_Array (0 .. 31);
      Totals : QI.Sum_Array (0 .. 31);
      Halves : QI.Sum_Array (0 .. 63);
      Sums : N.Wide_Real_Array (5 .. 8) := [others => 0.0];
      Ok : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Wide_Vectors then return; end if;
      QI.Use_Wide_Rows (True);
      Assert (Input'Length = 4096 and then Encoded'Length = 576 and then Golden'Length = 16,
              "independent Q4_K dot fixture shape");
      for Index in Input'Range loop
         Input_Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Input (Index)));
      end loop;
      for Index in Encoded'Range loop
         Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Encoded (Index)));
      end loop;
      for Index in Golden'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Golden (Index)));
      end loop;
      for Index in Vectors'Range loop
         Vectors (Index) := B.Get_F32 (Input_Bytes, B.Byte_Count (Index) * 4, Ok);
         Assert (Ok, "independent Q4_K input truncated");
      end loop;
      QI.Quantize_Vectors
        (Vectors, 2, 512, Values, Scales, Totals, Halves, Ok, Super => True, Reference_Rounding => True);
      Assert (Ok, "Q4_K independent activation packing declined");
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q4_K, Bytes, 0, 288, 2, 2, Values, Scales, Totals, Halves,
         0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (Ok, "reference Q4_K product declined");
      for Index in L.Element_Count range 0 .. 3 loop
         Assert (N.Bits (L.Real (Sums (Sums'First + Index)))
                 = N.Bits (B.Get_F32 (Expected, B.Byte_Count (Index) * 4, Ok)),
                 "Q4_K product differs from independent reference at" & Index'Image);
         Assert (Ok, "independent Q4_K result truncated");
      end loop;
      Sums := [others => -123.0];
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q4_K, Bytes (1 .. Bytes'Last - 1), 0, 288, 2, 2,
         Values, Scales, Totals, Halves, 0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (not Ok and then (for all Value of Sums => Value = -123.0),
              "truncated Q4_K weights changed the destination");
   end Reference_Q4_Products;

   procedure Reference_Q50_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Encoded : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q50-dot-reference-weights.bin");
      Golden : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q50-dot-reference-output.bin");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Bytes : B.Byte_Array (1 .. B.Byte_Count (Encoded'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (0 .. 1023);
      Values : QI.Signed_Array (0 .. 1023);
      Scales : L.Real_Array (0 .. 31);
      Totals : QI.Sum_Array (0 .. 31);
      Halves : QI.Sum_Array (0 .. 63);
      Sums : N.Wide_Real_Array (5 .. 8) := [others => 0.0];
      Ok : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Wide_Vectors then return; end if;
      QI.Use_Wide_Rows (True);
      Assert (Input'Length = 4096 and then Encoded'Length = 704 and then Golden'Length = 16,
              "independent Q5_0 dot fixture shape");
      for Index in Input'Range loop
         Input_Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Input (Index)));
      end loop;
      for Index in Encoded'Range loop
         Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Encoded (Index)));
      end loop;
      for Index in Golden'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Golden (Index)));
      end loop;
      for Index in Vectors'Range loop
         Vectors (Index) := B.Get_F32 (Input_Bytes, B.Byte_Count (Index) * 4, Ok);
         Assert (Ok, "independent Q5_0 input truncated");
      end loop;
      QI.Quantize_Vectors
        (Vectors, 2, 512, Values, Scales, Totals, Halves, Ok, Super => False, Reference_Rounding => True);
      Assert (QI.Packs_Vectors
                (Model_Runner.GGUF.Type_Q5_0, 2, Reference_Arithmetic => True),
              "reference Q5_0 product is unreachable from backend dispatch");
      Assert (not QI.Packs_Vectors (Model_Runner.GGUF.Type_Q5_0, 2),
              "Q5_0 reference support changed the default arithmetic contract");
      Assert (Ok, "Q5_0 independent activation packing declined");
      for Scale of Scales loop Scale := N.To_Real (N.To_Half (Scale)); end loop;
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q5_0, Bytes, 0, 352, 2, 16, Values, Scales, Totals, Halves,
         0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (Ok, "reference Q5_0 product declined");
      for Index in L.Element_Count range 0 .. 3 loop
         Assert (N.Bits (L.Real (Sums (Sums'First + Index)))
                 = N.Bits (B.Get_F32 (Expected, B.Byte_Count (Index) * 4, Ok)),
                 "Q5_0 product differs from independent reference at" & Index'Image);
         Assert (Ok, "independent Q5_0 result truncated");
      end loop;
      declare
         package CPU renames Model_Runner.Backend.CPU;
         package TT renames Model_Runner.Tensors;
         Weight : TT.View :=
           (Format => Model_Runner.GGUF.Type_Q5_0, Rows => 2, Columns => 512,
            Base => Bytes (Bytes'First)'Address, Span => Bytes'Length,
            Offset => 0, Length => Bytes'Length, Interleaved => False,
            Role => TT.Role_Feed_Forward, Reference_Activations => True, Scales => null);
         Packed, Scratch : CPU.Packed_Rows;
         Raw : aliased L.Real_Array (Vectors'Range);
         Up : aliased L.Real_Array (Vectors'Range) := [others => -1.0];
         Calls : Natural := 0;
         procedure Produce_Input (First : L.Element_Count; Into : out L.Real_Array) is
         begin
            Into := Vectors (Vectors'First + First .. Vectors'First + First + Into'Length - 1);
         end Produce_Input;
         procedure Activate (Gate : in out L.Real_Array; Other : L.Real_Array) is
         begin
            Assert (Gate'Length = 32 and then Other'Length = 32, "activation did not receive one native block");
            Calls := Calls + 1;
            for I in Gate'Range loop Gate (I) := Gate (I) * Other (Other'First + I - Gate'First); end loop;
         end Activate;
         procedure Measured (Gate : in out L.Real_Array; Other : L.Real_Array; Peak : out L.Real) is
         begin
            Activate (Gate, Other);
            Peak := 0.0;
            for Value of Gate loop Peak := L.Real'Max (Peak, abs (Value)); end loop;
         end Measured;
         procedure Produce (Gate : in out L.Real_Array; Other : L.Real_Array; Peaks : out L.Real_Array) is
         begin
            Calls := Calls + 1;
            Assert (Gate'Length = 1024 and then Other'Length = 1024 and then Peaks'Length = 32,
                    "whole-run producer shape");
            Peaks := [others => 0.0];
            for I in Gate'Range loop
               Gate (I) := Gate (I) * Other (Other'First + I - Gate'First);
               declare
                  P : L.Real renames Peaks (Peaks'First + (I - Gate'First) / 32);
               begin
                  P := L.Real'Max (P, abs (Gate (I)));
               end;
            end loop;
         end Produce;
         procedure Reject (Gate : in out L.Real_Array; Other : L.Real_Array; Peaks : out L.Real_Array) is
            pragma Unreferenced (Gate, Other);
         begin
            Peaks := [others => 0.0]; Peaks (Peaks'Last) := -1.0;
         end Reject;
         Actual : L.Real_Array (0 .. 3);
         Gathered : TT.Real_Array_Access;
      begin
         CPU.Pack
           (Packed, Vectors'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => True);
         Assert (Ok, "independent Q5_0 batch packing declined");
         CPU.Multiply_Packed_Whole (Weight, Packed, Actual, Ok);
         Assert (Ok, "independent Q5_0 whole packed product declined");
         for Row in L.Element_Count range 0 .. 1 loop
            for Vector in L.Element_Count range 0 .. 1 loop
               Assert (N.Bits (Actual (Vector * 2 + Row))
                       = N.Bits (B.Get_F32 (Expected, B.Byte_Count (Row * 2 + Vector) * 4, Ok)),
                       "whole packed Q5_0 product differs from independent reference");
            end loop;
         end loop;
         declare
            Split : L.Real_Array (7 .. 10) := [others => -777.0];
         begin
            CPU.Multiply_Packed_Whole (Weight, Packed, Split, Ok, First_Row => 1, Last_Row => 1);
            Assert (Ok and then Split (7) = -777.0 and then Split (9) = -777.0
                    and then N.Bits (Split (8)) = N.Bits (Actual (1))
                    and then N.Bits (Split (10)) = N.Bits (Actual (3)),
                    "packed projection range changed another output row");
            CPU.Multiply_Packed_Whole (Weight, Packed, Split, Ok, First_Row => 0, Last_Row => 0);
            Assert (Ok and then Split = Actual, "disjoint packed projection ranges differ from whole product");
            CPU.Multiply_Packed_Whole (Weight, Packed, Split, Ok, First_Row => 2);
            Assert (not Ok and then Split = Actual, "out-of-range packed projection changed output");
            CPU.Multiply_Packed_Whole (Weight, Packed, Split, Ok, First_Row => 1, Last_Row => 0);
            Assert (not Ok and then Split = Actual, "reversed packed projection changed output");
         end;
         CPU.Pack
           (Packed, Vectors'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => True,
            Transform => Produce_Input'Unrestricted_Access);
         Assert (Ok, "transformed reference input packing declined");
         declare
            Transformed : L.Real_Array (Actual'Range);
         begin
            CPU.Multiply_Packed_Whole (Weight, Packed, Transformed, Ok);
            Assert (Ok and then Transformed = Actual, "block-transform packing changed independent products");
         end;
         TT.Allocate (4, Gathered);
         CPU.Multiply_Packed (Weight, Packed, [1, 0], Gathered, Ok);
         Assert (Ok and then Gathered.all = Actual (2 .. 3) & Actual (0 .. 1),
                 "gathered Q5_0 rows changed independent reference products");
         CPU.Multiply_Packed_Pair (Weight, Weight, Packed, [1, 0], Gathered, Gathered, Scratch, Ok);
         Assert (Ok and then Gathered.all = Actual (2 .. 3) & Actual (0 .. 1),
                 "paired integer products changed independent reference rows");
         CPU.Unpack (Scratch);
         for I in Raw'Range loop Raw (I) := -Vectors (I); end loop;
         CPU.Pack
           (Packed, Raw'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => True,
            Activate => Activate'Unrestricted_Access, Up => Up'Unrestricted_Access);
         Assert (Ok and then Calls = 32 and then Raw = Vectors, "fused activation or packing block lifecycle");
         CPU.Multiply_Packed_Whole (Weight, Packed, Gathered.all, Ok);
         Assert (Ok and then Gathered.all = Actual, "fused packing changed independent Q5_0 products");
         for I in Raw'Range loop Raw (I) := -Vectors (I); end loop;
         Calls := 0;
         CPU.Pack
           (Packed, Raw'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => True,
            Measure => Measured'Unrestricted_Access, Up => Up'Unrestricted_Access);
         Assert (Ok and then Calls = 32 and then Raw = Vectors, "measured activation lifecycle");
         CPU.Multiply_Packed_Whole (Weight, Packed, Gathered.all, Ok);
         Assert (Ok and then Gathered.all = Actual, "measured packing changed independent Q5_0 products");
         for I in Raw'Range loop Raw (I) := -Vectors (I); end loop;
         Calls := 0;
         CPU.Pack
           (Packed, Raw'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => True,
            Produce => Produce'Unrestricted_Access, Up => Up'Unrestricted_Access);
         Assert (Ok and then Calls = 1 and then Raw = Vectors, "whole-run activation lifecycle");
         CPU.Multiply_Packed_Whole (Weight, Packed, Gathered.all, Ok);
         Assert (Ok and then Gathered.all = Actual, "whole-run packing changed independent Q5_0 products");
         CPU.Pack
           (Packed, Raw'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True,
            Produce => Reject'Unrestricted_Access, Up => Up'Unrestricted_Access);
         Assert (not Ok, "whole-run producer accepted invalid peak");
         CPU.Pack
           (Packed, Raw'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => False,
            Produce => Produce'Unrestricted_Access, Up => Up'Unrestricted_Access);
         Assert (not Ok and then Calls = 1, "whole-run producer accepted unsupported arithmetic");
         CPU.Pack
           (Packed, Raw'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True,
            Produce => Produce'Unrestricted_Access, Activate => Activate'Unrestricted_Access,
            Up => Up'Unrestricted_Access);
         Assert (not Ok and then Calls = 1, "whole-run producer accepted competing callback");

         CPU.Pack
           (Packed, Raw'Unrestricted_Access, 1, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => True);
         Gathered.all := [others => -777.0];
         CPU.Multiply_Packed_Whole (Weight, Packed, Gathered.all, Ok);
         Assert (Ok and then Gathered (0) = B.Get_F32 (Expected, 0, Ok)
                 and then Gathered (1) = B.Get_F32 (Expected, 8, Ok)
                 and then Gathered (2) = -777.0 and then Gathered (3) = -777.0,
                 "reused packed capacity exposed stale vectors");
         CPU.Pack
           (Packed, Vectors'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => True);
         TT.Free (Gathered);
         Weight.Reference_Activations := False;
         CPU.Multiply_Packed_Whole (Weight, Packed, Actual, Ok);
         Assert (not Ok, "packed Q5_0 rows accepted another activation contract");
         Weight.Reference_Activations := True;
         CPU.Pack
           (Packed, Vectors'Unrestricted_Access, 2, 512, False, Ok,
            Roles => [others => True], Reference_Arithmetic => True, Half_Scales => False);
         CPU.Multiply_Packed_Whole (Weight, Packed, Actual, Ok);
         Assert (not Ok, "packed Q5_0 rows accepted unrounded scales");
         CPU.Unpack (Packed);
      exception
         when others =>
            TT.Free (Gathered);
            CPU.Unpack (Packed); CPU.Unpack (Scratch);
            raise;
      end;
      Sums := [others => -123.0];
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q5_0, Bytes (1 .. Bytes'Last - 1), 0, 352, 2, 16,
         Values, Scales, Totals, Halves, 0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (not Ok and then (for all Value of Sums => Value = -123.0),
              "truncated Q5_0 weights changed the destination");
   end Reference_Q50_Products;

   procedure Reference_Q5_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Encoded : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q5k-dot-reference-weights.bin");
      Golden : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q5k-dot-reference-output.bin");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Bytes : B.Byte_Array (1 .. B.Byte_Count (Encoded'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (0 .. 1023);
      Values : QI.Signed_Array (0 .. 1023);
      Scales : L.Real_Array (0 .. 31);
      Totals : QI.Sum_Array (0 .. 31);
      Halves : QI.Sum_Array (0 .. 63);
      Sums : N.Wide_Real_Array (5 .. 8) := [others => 0.0];
      Ok : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Wide_Vectors then return; end if;
      QI.Use_Wide_Rows (True);
      Assert (Input'Length = 4096 and then Encoded'Length = 704 and then Golden'Length = 16,
              "independent Q5_K dot fixture shape");
      for Index in Input'Range loop
         Input_Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Input (Index)));
      end loop;
      for Index in Encoded'Range loop
         Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Encoded (Index)));
      end loop;
      for Index in Golden'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Golden (Index)));
      end loop;
      for Index in Vectors'Range loop
         Vectors (Index) := B.Get_F32 (Input_Bytes, B.Byte_Count (Index) * 4, Ok);
         Assert (Ok, "independent Q5_K input truncated");
      end loop;
      QI.Quantize_Vectors
        (Vectors, 2, 512, Values, Scales, Totals, Halves, Ok, Super => True, Reference_Rounding => True);
      Assert (Ok, "Q5_K independent activation packing declined");
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q5_K, Bytes, 0, 352, 2, 2, Values, Scales, Totals, Halves,
         0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (Ok, "reference Q5_K product declined");
      for Index in L.Element_Count range 0 .. 3 loop
         Assert (N.Bits (L.Real (Sums (Sums'First + Index)))
                 = N.Bits (B.Get_F32 (Expected, B.Byte_Count (Index) * 4, Ok)),
                 "Q5_K product differs from independent reference at" & Index'Image);
         Assert (Ok, "independent Q5_K result truncated");
      end loop;
      Sums := [others => -123.0];
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q5_K, Bytes (1 .. Bytes'Last - 1), 0, 352, 2, 2,
         Values, Scales, Totals, Halves, 0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (not Ok and then (for all Value of Sums => Value = -123.0),
              "truncated Q5_K weights changed the destination");
   end Reference_Q5_Products;

   procedure Small_IQ4_Benchmark (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      package CPU renames Model_Runner.Backend.CPU;
      use type Ada.Real_Time.Time;
      Width : constant L.Element_Count := 1152;
      Rows : constant L.Element_Count := 2304;
      RB : constant B.Byte_Count := 648;
      Source : constant String := Project_Tools.Files.Read_Raw_File
        ("fixtures/inkling2/gsq-small-blocks/nl-1152.bin");
      Input : constant String := Project_Tools.Files.Read_Raw_File
        ("fixtures/inkling2/gsq-small-blocks/input-1152.f32");
      Golden_Text : constant String := Project_Tools.Files.Read_Raw_File
        ("fixtures/inkling2/gsq-small-blocks/nl-1152.f32");
      Golden : B.Byte_Array (0 .. B.Byte_Count (Golden_Text'Length) - 1);
      Native : B.Byte_Array_Access := null;
      Expert_Bytes : constant B.Byte_Count := B.Byte_Count (Rows) * RB;
      Expert_Count : constant := 32;
      Encoded : B.Byte_Array (0 .. B.Byte_Count (Input'Length) - 1);
      Vectors : L.Real_Array (0 .. 8 * Width - 1);
      Values : QI.Signed_Array (Vectors'Range);
      Scales : L.Real_Array (0 .. 8 * Width / 32 - 1);
      Totals : QI.Sum_Array (Scales'Range);
      Halves : QI.Sum_Array (0 .. 8 * Width / 16 - 1);
      Output : aliased L.Real_Array (0 .. 8 * Rows - 1) := [others => -777.0];
      Expected : L.Real_Array (Output'Range);
      Team : aliased CPU.Pool (8);
      Status : E.Error_Info;
      Good : Boolean;
      type Row_Work is limited new CPU.Task_Item with record
         Fast : Boolean := False;
         Weight_First : B.Byte_Count := 0;
         Queries : L.Element_Count := 1;
         Valid : Boolean := True with Atomic;
      end record;
      overriding procedure Run (Work : in out Row_Work; From, To : L.Element_Count);
      overriding procedure Run (Work : in out Row_Work; From, To : L.Element_Count) is
         Count : constant L.Element_Count := Work.Queries;
         Sums : N.Wide_Real_Array (0 .. QI.Row_Tile * Count - 1);
         First : L.Element_Count := From;
         Handled : Boolean;
      begin
         if From > To then return; end if;
         if Work.Fast then
            QI.Reference_Products (Model_Runner.GGUF.Type_IQ4_NL, Native.all,
              Work.Weight_First + B.Byte_Count (From) * RB, RB, To - From + 1, 36,
              Values, Scales, Totals, Halves, 0, Width, Count,
              Output'Unrestricted_Access, From, Rows, Handled);
            if not Handled then Work.Valid := False; end if;
         else
            --  The unchanged tensor fallback: original row-tile selection,
            --  integer kernel and row-major wide sums, then binary32 output.
            while First <= To loop
               declare
                  Here : constant L.Element_Count := L.Element_Count'Min (QI.Wanted_Tile (Count), To - First + 1);
               begin
                  Sums := [others => 0.0];
                  QI.Accumulate_Rows (Model_Runner.GGUF.Type_IQ4_NL, Native.all,
                    Work.Weight_First + B.Byte_Count (First) * RB,
                    RB, Here, 36, Values, Scales, Totals, Halves, 0, Width, Count, Sums, Handled,
                    Reference_Arithmetic => True);
                  if not Handled then Work.Valid := False; return; end if;
                  for Q in L.Element_Count range 0 .. Count - 1 loop
                     for Row in L.Element_Count range 0 .. Here - 1 loop
                        Output (Q * Rows + First + Row) := L.Real (Sums (Row * Count + Q));
                     end loop;
                  end loop;
                  First := First + Here;
               end;
            end loop;
         end if;
      end Run;
      Work : aliased Row_Work;
      procedure Dispatch is
      begin
         CPU.Dispatch_Shares (Team'Unchecked_Access, Rows, Work'Unchecked_Access, Status,
                              Cost => Rows * Width * Work.Queries, Team_Size => 8);
         Assert (E.Is_Ok (Status) and then Work.Valid, "IQ4 row-pair component dispatch failed");
      end Dispatch;
   begin
      if Ada.Environment_Variables.Value ("INKLING_IQ4_PAIR_BENCH", "") /= "1" then
         CPU.Close (Team); return;
      end if;
      Assert (Model_Runner.Platform.Byte_Products, "IQ4 row-pair benchmark requires byte-dot ISA");
      Native := new B.Byte_Array (0 .. Expert_Count * Expert_Bytes - 1);
      for I in Native'Range loop
         Native (I) := Character'Pos (Source (Source'First + Natural ((I mod Expert_Bytes) mod Source'Length)));
      end loop;
      for I in Golden'Range loop Golden (I) := Character'Pos (Golden_Text (Golden_Text'First + Natural (I))); end loop;
      for I in Encoded'Range loop Encoded (I) := Character'Pos (Input (Input'First + Natural (I))); end loop;
      for I in Vectors'Range loop
         Vectors (I) := B.Get_F32 (Encoded, B.Byte_Count (I mod (8 * Width)) * 4, Good);
         Assert (Good, "IQ4 row-pair component input truncated");
      end loop;
      QI.Use_Wide_Rows (True); QI.Use_Deep_Rows (True);
      QI.Quantize_Vectors (Vectors, 8, Width, Values, Scales, Totals, Halves, Good,
                          Reference_Rounding => True, Half_Scales => True);
      Assert (Good, "IQ4 row-pair component packing failed");
      for Count of L.Real_Array'([4.0,8.0]) loop
         Work.Queries := L.Element_Count (Count);
         for Cold in Boolean loop
            for Fast in Boolean range True .. True loop
               Work.Weight_First := 0;
               Work.Fast := Fast; Work.Valid := True; Output := [others => -777.0]; Dispatch;
               for Q in L.Element_Count range 0 .. Work.Queries - 1 loop
                  for Row in L.Element_Count range 0 .. Rows - 1 loop
                     declare
                        Want : constant L.Real := B.Get_F32
                          (Golden, B.Byte_Count ((Row mod 5) * 9 + Q) * 4, Good);
                     begin
                        Assert (Good and then N.Bits (Output (Q * Rows + Row)) = N.Bits (Want),
                                "IQ4 paired component changed independent GGML bits");
                     end;
                  end loop;
               end loop;
               if Fast then Expected := Output;
               else
                  for I in Output'Range loop
                     Assert (N.Bits (Output (I)) = N.Bits (Expected (I)), "IQ4 row-pair component changed bits");
                  end loop;
               end if;
               declare
                  Passes : constant Positive := (if Cold then 1024 else 2048);
                  Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
                  Elapsed : Duration;
               begin
                  for Pass in 1 .. Passes loop
                     Work.Weight_First := (if Cold then B.Byte_Count (Pass mod Expert_Count) * Expert_Bytes else 0);
                     Dispatch;
                  end loop;
                  Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
                  Ada.Text_IO.Put_Line ("IQ4 row-pair count=" & Count'Image & " fast=" & Fast'Image
                    & " cold=" & Cold'Image & " projection_tok_s=" & Long_Float'Image (Long_Float (Count) * Long_Float (Passes)
                      / Long_Float (Elapsed)) & " seconds=" & Elapsed'Image);
               end;
               for I in Output'Range loop
                  Assert (N.Bits (Output (I)) = N.Bits (Expected (I)), "timed IQ4 row-pair differs");
               end loop;
            end loop;
         end loop;
      end loop;
      CPU.Close (Team); B.Free (Native);
   exception when others => CPU.Close (Team); B.Free (Native); raise;
   end Small_IQ4_Benchmark;

   procedure Small_IQ3_Benchmark (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      package CPU renames Model_Runner.Backend.CPU;
      use type Ada.Real_Time.Time;
      Width : constant L.Element_Count := 2304;
      Rows : constant L.Element_Count := 1152;
      RB : constant B.Byte_Count := 990;
      Source : constant String := Project_Tools.Files.Read_Raw_File
        ("fixtures/inkling2/gsq-grid-direct/iq3_s.bin");
      Input : constant String := Project_Tools.Files.Read_Raw_File
        ("fixtures/inkling2/gsq-grid-direct/input.f32");
      Native : B.Byte_Array_Access := null;
      Expert_Bytes : constant B.Byte_Count := B.Byte_Count (Rows) * RB;
      Expert_Count : constant := 32;
      Encoded : B.Byte_Array (0 .. B.Byte_Count (Input'Length) - 1);
      Vectors : L.Real_Array (0 .. 16 * Width - 1);
      Values : QI.Signed_Array (Vectors'Range);
      Scales : L.Real_Array (0 .. 16 * Width / 32 - 1);
      Totals : QI.Sum_Array (Scales'Range);
      Halves : QI.Sum_Array (0 .. 16 * Width / 16 - 1);
      Output : aliased L.Real_Array (0 .. 16 * Rows - 1) := [others => -777.0];
      Expected : L.Real_Array (Output'Range);
      Team : aliased CPU.Pool (8);
      Status : E.Error_Info;
      Good : Boolean;
      type Row_Work is limited new CPU.Task_Item with record
         Fast : Boolean := False;
         Weight_First : B.Byte_Count := 0;
         Queries : L.Element_Count := 1;
         Valid : Boolean := True with Atomic;
      end record;
      overriding procedure Run (Work : in out Row_Work; From, To : L.Element_Count);
      overriding procedure Run (Work : in out Row_Work; From, To : L.Element_Count) is
         Count : constant L.Element_Count := Work.Queries;
         Sums : N.Wide_Real_Array (0 .. QI.Row_Tile * Count - 1);
         First : L.Element_Count := From;
         Handled : Boolean;
      begin
         if From > To then return; end if;
         if Work.Fast then
            QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native.all,
              Work.Weight_First + B.Byte_Count (From) * RB, RB, To - From + 1, 9,
              Values, Scales, Totals, Halves, 0, Width, Count,
              Output'Unrestricted_Access, From, Rows, Handled);
            if not Handled then Work.Valid := False; end if;
         else
            --  The unchanged tensor fallback: original row-tile selection,
            --  integer kernel and row-major wide sums, then binary32 output.
            while First <= To loop
               declare
                  Here : constant L.Element_Count := L.Element_Count'Min (QI.Wanted_Tile (Count), To - First + 1);
               begin
                  Sums := [others => 0.0];
                  QI.Accumulate_Rows (Model_Runner.GGUF.Type_IQ3_S, Native.all,
                    Work.Weight_First + B.Byte_Count (First) * RB,
                    RB, Here, 9, Values, Scales, Totals, Halves, 0, Width, Count, Sums, Handled,
                    Reference_Arithmetic => True);
                  if not Handled then Work.Valid := False; return; end if;
                  for Q in L.Element_Count range 0 .. Count - 1 loop
                     for Row in L.Element_Count range 0 .. Here - 1 loop
                        Output (Q * Rows + First + Row) := L.Real (Sums (Row * Count + Q));
                     end loop;
                  end loop;
                  First := First + Here;
               end;
            end loop;
         end if;
      end Run;
      Work : aliased Row_Work;
      procedure Dispatch is
      begin
         CPU.Dispatch_Shares (Team'Unchecked_Access, Rows, Work'Unchecked_Access, Status,
                              Cost => Rows * Width * Work.Queries, Team_Size => 8);
         Assert (E.Is_Ok (Status) and then Work.Valid, "small IQ3 component dispatch failed");
      end Dispatch;
   begin
      if Ada.Environment_Variables.Value ("INKLING_SMALL_MOE_BENCH", "") /= "1" then
         CPU.Close (Team); return;
      end if;
      Assert (Model_Runner.Platform.Byte_Products, "small IQ3 benchmark requires byte-dot ISA");
      Native := new B.Byte_Array (0 .. Expert_Count * Expert_Bytes - 1);
      for I in Native'Range loop
         Native (I) := Character'Pos (Source (Source'First + Natural (I mod Source'Length)));
      end loop;
      for I in Encoded'Range loop Encoded (I) := Character'Pos (Input (Input'First + Natural (I))); end loop;
      for I in Vectors'Range loop
         Vectors (I) := B.Get_F32 (Encoded, B.Byte_Count (I mod (9 * Width)) * 4, Good);
         Assert (Good, "small IQ3 component input truncated");
      end loop;
      QI.Use_Wide_Rows (True); QI.Use_Deep_Rows (True);
      QI.Quantize_Vectors (Vectors, 16, Width, Values, Scales, Totals, Halves, Good,
                          Super => True, Reference_Rounding => True);
      Assert (Good, "small IQ3 component packing failed");
      for Count of L.Real_Array'([8.0,9.0,12.0,16.0]) loop
         Work.Queries := L.Element_Count (Count);
         for Cold in Boolean loop
            for Fast in Boolean loop
               Work.Weight_First := 0;
               Work.Fast := Fast; Work.Valid := True; Output := [others => -777.0]; Dispatch;
               if not Fast then Expected := Output;
               else
                  for I in Output'Range loop
                     Assert (N.Bits (Output (I)) = N.Bits (Expected (I)), "small IQ3 component changed bits");
                  end loop;
               end if;
               declare
                  Passes : constant Positive := (if Cold then 1024 else 2048);
                  Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
                  Elapsed : Duration;
               begin
                  for Pass in 1 .. Passes loop
                     Work.Weight_First := (if Cold then B.Byte_Count (Pass mod Expert_Count) * Expert_Bytes else 0);
                     Dispatch;
                  end loop;
                  Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
                  Ada.Text_IO.Put_Line ("small IQ3 count=" & Count'Image & " fast=" & Fast'Image
                    & " cold=" & Cold'Image & " projection_tok_s=" & Long_Float'Image (Long_Float (Count) * Long_Float (Passes)
                      / Long_Float (Elapsed)) & " seconds=" & Elapsed'Image);
               end;
               for I in Output'Range loop
                  Assert (N.Bits (Output (I)) = N.Bits (Expected (I)), "timed small IQ3 differs");
               end loop;
            end loop;
         end loop;
      end loop;
      CPU.Close (Team); B.Free (Native);
   exception when others => CPU.Close (Team); B.Free (Native); raise;
   end Small_IQ3_Benchmark;

   procedure IQ3_Reference_Arithmetic (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      use type QI.Byte_Signed;
      function Read_Bytes (Name : String) return B.Byte_Array is
         Text : constant String := Project_Tools.Files.Read_Raw_File
           ("fixtures/inkling2/gsq-grid-direct/" & Name);
         Result : B.Byte_Array (0 .. B.Byte_Count (Text'Length) - 1);
      begin
         for I in Result'Range loop Result (I) := Character'Pos (Text (Text'First + Natural (I))); end loop;
         return Result;
      end Read_Bytes;
      Source : constant B.Byte_Array := Read_Bytes ("iq3_s.bin");
      Golden : constant B.Byte_Array := Read_Bytes ("iq3_s.f32");
      Input : constant B.Byte_Array := Read_Bytes ("input.f32");
      Width : constant L.Element_Count := 2304;
      Rows : constant L.Element_Count := 16;
      RB : constant B.Byte_Count := 990;
      Native : B.Byte_Array (19 .. 19 + B.Byte_Count (Rows) * RB - 1);
      Vectors : L.Real_Array (5 .. 5 + 129 * Width - 1);
      Values : QI.Signed_Array (9 .. 9 + 129 * Width - 1);
      Scales : L.Real_Array (11 .. 11 + 129 * Width / 32 - 1);
      Totals : QI.Sum_Array (Scales'Range);
      Halves : QI.Sum_Array (13 .. 13 + 129 * Width / 16 - 1);
      Actual : aliased L.Real_Array (11 .. 11 + 129 * 19 + 7) := [others => -777.0];
      Good : Boolean;
      Counts : constant array (1 .. 16) of L.Element_Count := [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16];
   begin
      if not Model_Runner.Platform.Byte_Products then return; end if;
      QI.Use_Wide_Rows (True); QI.Use_Deep_Rows (True);
      for I in Native'Range loop Native (I) := Source ((I - Native'First) mod Source'Length); end loop;
      for I in Vectors'Range loop
         Vectors (I) := B.Get_F32 (Input, B.Byte_Count ((I - Vectors'First) mod (9 * Width)) * 4, Good);
         Assert (Good, "IQ3 input fixture truncated");
      end loop;
      QI.Quantize_Vectors (Vectors, 129, Width, Values, Scales, Totals, Halves, Good,
                           Super => True, Reference_Rounding => True);
      Assert (Good, "IQ3 native small/eight-query activation packing failed");
      for Count of Counts loop
         Actual := [others => -777.0];
         QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
           Values, Scales, Totals, Halves, 0, Width, Count,
           Actual'Unrestricted_Access, 2, 19, Good, Interleaved => False);
         Assert (Good, "IQ3 native small/eight-query products refused count" & Count'Image);
         for Row in L.Element_Count range 0 .. Rows - 1 loop
            declare
               Native_Sums : N.Wide_Real_Array (0 .. Count - 1) := [others => 0.0];
            begin
               QI.Accumulate_Rows (Model_Runner.GGUF.Type_IQ3_S, Native, B.Byte_Count (Row) * RB, RB, 1, 9,
                 Values, Scales, Totals, Halves, 0, Width, Count, Native_Sums, Good,
                 Reference_Arithmetic => True);
               Assert (Good, "native IQ3 oracle refused");
               for V in L.Element_Count range 0 .. Count - 1 loop
                  declare
                     Got : constant L.Real := Actual (Actual'First + 2 + Row + V * 19);
                     Want : constant L.Real := B.Get_F32 (Golden, B.Byte_Count ((Row mod 4) * 9 + V mod 9) * 4,
                                                        Good);
                  begin
                     Assert (N.Bits (Got) = N.Bits (L.Real (Native_Sums (V))),
                             "IQ3 native small/eight-query changed native bits at count" & Count'Image
                             & " row" & Row'Image
                             & " vector" & V'Image);
                     Assert (Good and then abs (Got - Want) <= 1.0E-5 + 2.0E-5 * abs Want,
                             "IQ3 native small/eight-query differs from independent GGML fixture");
                  end;
               end loop;
            end;
         end loop;
         for V in L.Element_Count range 0 .. Count - 1 loop
            Assert (Actual (Actual'First + V * 19) = -777.0
                    and then Actual (Actual'First + V * 19 + 1) = -777.0
                    and then Actual (Actual'First + V * 19 + 18) = -777.0, "IQ3 output padding overwritten");
         end loop;
         for I in Actual'First + Count * 19 .. Actual'Last loop
            Assert (Actual (I) = -777.0, "IQ3 padded query wrote output");
         end loop;
      end loop;
      --  Exercise both ends of the admitted block range, not just the
      --  checkpoint's nine-block expert rows. The old native kernel is
      --  the exact oracle; the independent goldens above remain unchanged.
      for Blocks of L.Real_Array'([1.0,64.0]) loop
         declare
            Number : constant L.Element_Count := L.Element_Count (Blocks);
            Bytes_Per_Row : constant B.Byte_Count := B.Byte_Count (Number) * 110;
            Data : B.Byte_Array (7 .. 6 + Bytes_Per_Row);
            Stride : constant L.Element_Count := Number * 256;
         begin
            for I in Data'Range loop Data (I) := Source ((I - Data'First) mod Source'Length); end loop;
            for Count of L.Real_Array'([9.0,16.0]) loop
               declare
                  Many : constant L.Element_Count := L.Element_Count (Count);
                  Sums : N.Wide_Real_Array (0 .. Many - 1) := [others => 0.0];
               begin
                  Actual := [others => -777.0];
                  QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Data, 0, Bytes_Per_Row, 1, Number,
                    Values, Scales, Totals, Halves, 0, Stride, Many, Actual'Unrestricted_Access, 2, 19, Good);
                  Assert (Good, "IQ3 boundary block count declined");
                  QI.Accumulate_Rows (Model_Runner.GGUF.Type_IQ3_S, Data, 0, Bytes_Per_Row, 1, Number,
                    Values, Scales, Totals, Halves, 0, Stride, Many, Sums, Good, Reference_Arithmetic => True);
                  Assert (Good, "IQ3 boundary block oracle declined");
                  for Q in L.Element_Count range 0 .. Many - 1 loop
                     Assert (N.Bits (Actual (Actual'First + 2 + Q * 19)) = N.Bits (L.Real (Sums (Q))),
                             "IQ3 boundary block product changed bits");
                  end loop;
               end;
            end loop;
         end;
      end loop;
      for Unchanged of L.Real_Array'([0.0,17.0,32.0,128.0]) loop
         Actual := [others => -777.0];
         QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
           Values, Scales, Totals, Halves, 0, Width, L.Element_Count (Unchanged),
           Actual'Unrestricted_Access, 2, 19, Good);
         Assert (not Good and then (for all V of Actual => V = -777.0),
                 "IQ3 small/eight-query path captured an unsupported query count");
      end loop;
      declare
         Sources : Model_Runner.Shares.Member_Rows := [3,0,8,2,4,0,1,7];
         Destinations : Model_Runner.Shares.Member_Rows := [7,0,5,1,6,2,4,3];
      begin
         Actual := [others => -777.0];
         QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
           Values, Scales, Totals, Halves, 0, Width, 8,
           Actual'Unrestricted_Access, 2, 19, Good, Interleaved => False,
           Result_Members => Destinations, Input_Members => Sources);
         Assert (Good, "IQ3 indexed products declined");
         for Row in L.Element_Count range 0 .. Rows - 1 loop
            declare
               Native_Sums : N.Wide_Real_Array (0 .. 8) := [others => 0.0];
            begin
               QI.Accumulate_Rows (Model_Runner.GGUF.Type_IQ3_S, Native, B.Byte_Count (Row) * RB, RB, 1, 9,
                 Values, Scales, Totals, Halves, 0, Width, 9, Native_Sums, Good,
                 Reference_Arithmetic => True);
               for V in Natural range 0 .. 7 loop
                  Assert (N.Bits (Actual (Actual'First + 2 + Row + L.Element_Count (Destinations (V)) * 19)) =
                          N.Bits (L.Real (Native_Sums (L.Element_Count (Sources (V))))), "IQ3 mapping differs");
               end loop;
            end;
         end loop;
         Sources (Sources'First) := 999; Actual := [others => -777.0];
         QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
           Values, Scales, Totals, Halves, 0, Width, 8,
           Actual'Unrestricted_Access, 2, 19, Good, Interleaved => False, Input_Members => Sources);
         Assert (not Good and then (for all V of Actual => V = -777.0), "IQ3 invalid source wrote output");
         Destinations (1) := Destinations (0);
         QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
           Values, Scales, Totals, Halves, 0, Width, 8,
           Actual'Unrestricted_Access, 2, 19, Good, Interleaved => False, Result_Members => Destinations);
         Assert (not Good and then (for all V of Actual => V = -777.0), "IQ3 duplicate destination wrote output");
      end;
      for Count in L.Element_Count range 1 .. 16 loop
         declare
            Sources : Model_Runner.Shares.Member_Rows (0 .. Natural (Count) - 1);
            Destinations : Model_Runner.Shares.Member_Rows (Sources'Range);
         begin
            for I in Sources'Range loop Sources (I) := (15 - I) mod 9; Destinations (I) := 15 - I; end loop;
            Actual := [others => -777.0];
            QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
              Values, Scales, Totals, Halves, 0, Width, Count,
              Actual'Unrestricted_Access, 2, 19, Good, Input_Members => Sources, Result_Members => Destinations);
            Assert (Good, "small IQ3 mapped inputs declined");
            for Row in L.Element_Count range 0 .. Rows - 1 loop
               declare
                  Sums : N.Wide_Real_Array (0 .. 8) := [others => 0.0];
               begin
                  QI.Accumulate_Rows (Model_Runner.GGUF.Type_IQ3_S, Native, B.Byte_Count (Row) * RB, RB, 1, 9,
                    Values, Scales, Totals, Halves, 0, Width, 9, Sums, Good, Reference_Arithmetic => True);
                  Assert (Good, "small mapped native oracle declined");
                  for I in Sources'Range loop
                     Assert (N.Bits (Actual (Actual'First + 2 + Row + L.Element_Count (Destinations (I)) * 19))
                       = N.Bits (L.Real (Sums (L.Element_Count (Sources (I))))), "small IQ3 mapping differs");
                  end loop;
               end;
            end loop;
            Actual := [others => -777.0]; Sources (Sources'First) := 999;
            QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
              Values, Scales, Totals, Halves, 0, Width, Count,
              Actual'Unrestricted_Access, 2, 19, Good, Input_Members => Sources);
            Assert (not Good and then (for all V of Actual => V = -777.0), "small invalid map wrote output");
            Values (Values'First + (Count - 1) * Width) := -128;
            QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
              Values, Scales, Totals, Halves, 0, Width, Count, Actual'Unrestricted_Access, 2, 19, Good);
            Assert (not Good and then (for all V of Actual => V = -777.0), "small invalid byte wrote output");
            Values (Values'First + (Count - 1) * Width) := 0;
         end;
      end loop;
      QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S,
        Native (Native'First .. Native'Last - 1), 0, RB, Rows, 9,
        Values, Scales, Totals, Halves, 0, Width, 8,
        Actual'Unrestricted_Access, 2, 19, Good, Interleaved => False);
      Assert (not Good and then (for all V of Actual => V = -777.0), "IQ3 truncated native weights wrote output");
      Values (Values'First + 7 * Width) := -128;
      QI.Reference_Products (Model_Runner.GGUF.Type_IQ3_S, Native, 0, RB, Rows, 9,
        Values, Scales, Totals, Halves, 0, Width, 8,
        Actual'Unrestricted_Access, 2, 19, Good, Interleaved => False);
      Assert (not Good and then (for all V of Actual => V = -777.0), "IQ3 invalid signed input wrote output");
   end IQ3_Reference_Arithmetic;

   procedure Seven_Q5_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Encoded : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q5k-dot-reference-weights.bin");
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q5k-dot-reference-output.bin");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Bytes : B.Byte_Array (1 .. B.Byte_Count (Encoded'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (5 .. 5 + 7 * 512 - 1);
      Values : QI.Signed_Array (7 .. 7 + 7 * 512 - 1);
      Scales : L.Real_Array (9 .. 9 + 7 * 16 - 1);
      Totals : QI.Sum_Array (11 .. 11 + 7 * 16 - 1);
      Halves : QI.Sum_Array (13 .. 13 + 7 * 32 - 1);
      Target : aliased L.Real_Array (5 .. 5 + 7 * 3 + 3) := [others => -123.0];
      Source_Map : constant Model_Runner.Shares.Member_Rows := [1, 0, 1, 0, 0, 1, 0];
      Result_Map : constant Model_Runner.Shares.Member_Rows := [6, 1, 5, 2, 4, 0, 3];
      Good : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Byte_Products then return; end if;
      QI.Use_Wide_Rows (True); QI.Use_Deep_Rows (True);
      for I in Input'Range loop Input_Bytes (B.Byte_Count (I)) := B.Byte (Character'Pos (Input (I))); end loop;
      for I in Encoded'Range loop Bytes (B.Byte_Count (I)) := B.Byte (Character'Pos (Encoded (I))); end loop;
      for I in Golden'Range loop Expected (B.Byte_Count (I)) := B.Byte (Character'Pos (Golden (I))); end loop;
      for V in L.Element_Count range 0 .. 6 loop
         for I in L.Element_Count range 0 .. 511 loop
            Vectors (5 + V * 512 + I) := B.Get_F32 (Input_Bytes, B.Byte_Count ((V mod 2) * 512 + I) * 4, Good);
            Assert (Good, "seven Q5 input fixture truncated");
         end loop;
      end loop;
      QI.Quantize_Vectors
        (Vectors, 7, 512, Values, Scales, Totals, Halves, Good, Super => True, Reference_Rounding => True);
      Assert (Good, "seven Q5 reference packing refused");
      for Mapped in Boolean loop
         Target := [others => -123.0];
         QI.Reference_Products
           (Model_Runner.GGUF.Type_Q5_K, Bytes, 0, 352, 2, 2, Values, Scales, Totals, Halves,
            0, 512, 7, Target'Unrestricted_Access, 0, 3, Good,
            Result_Members => (if Mapped then Result_Map else []),
            Input_Members => (if Mapped then Source_Map else []));
         Assert (Good, "seven Q5 reference kernel declined");
         for V in L.Element_Count range 0 .. 6 loop
            declare
               Source : constant L.Element_Count := (if Mapped then L.Element_Count (Source_Map (Natural (V))) else V);
               Destination : constant L.Element_Count :=
                 (if Mapped then L.Element_Count (Result_Map (Natural (V))) else V);
            begin
               for Row in L.Element_Count range 0 .. 1 loop
                  Assert (N.Bits (Target (5 + Destination * 3 + Row)) =
                          N.Bits (B.Get_F32 (Expected, B.Byte_Count (Row * 2 + Source mod 2) * 4, Good)),
                          "seven Q5 output differs from independent GGML fixture");
                  Assert (Good, "seven Q5 golden truncated");
               end loop;
               Assert (Target (5 + Destination * 3 + 2) = -123.0, "seven Q5 wrote output padding");
            end;
         end loop;
         Assert (Target (Target'Last) = -123.0, "seven Q5 wrote a padded eighth result");
      end loop;
      Target := [others => -123.0];
      QI.Reference_Products
        (Model_Runner.GGUF.Type_Q5_K, Bytes (Bytes'First .. Bytes'Last - 1), 0, 352, 2, 2,
         Values, Scales, Totals, Halves, 0, 512, 7, Target'Unrestricted_Access, 0, 3, Good);
      Assert (not Good and then (for all V of Target => V = -123.0), "seven Q5 truncation wrote output");
   end Seven_Q5_Products;

   procedure Reference_Q6_Products (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8k-input.f32");
      Encoded : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q6k-dot-reference-weights.bin");
      Golden : constant String :=
        Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q6k-dot-reference-output.bin");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Bytes : B.Byte_Array (1 .. B.Byte_Count (Encoded'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (0 .. 1023);
      Values : QI.Signed_Array (0 .. 1023);
      Scales : L.Real_Array (0 .. 31);
      Totals : QI.Sum_Array (0 .. 31);
      Halves : QI.Sum_Array (0 .. 63);
      Sums : N.Wide_Real_Array (5 .. 8) := [others => 0.0];
      Ok : Boolean;
   begin
      if not Model_Runner.Backend.CPU.Wide_Vectors then return; end if;
      QI.Use_Wide_Rows (True);
      Assert (Input'Length = 4096 and then Encoded'Length = 840 and then Golden'Length = 16,
              "independent Q6_K dot fixture shape");
      for Index in Input'Range loop
         Input_Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Input (Index)));
      end loop;
      for Index in Encoded'Range loop
         Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Encoded (Index)));
      end loop;
      for Index in Golden'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Golden (Index)));
      end loop;
      for Index in Vectors'Range loop
         Vectors (Index) := B.Get_F32 (Input_Bytes, B.Byte_Count (Index) * 4, Ok);
         Assert (Ok, "independent Q6_K input truncated");
      end loop;
      QI.Quantize_Vectors
        (Vectors, 2, 512, Values, Scales, Totals, Halves, Ok, Super => True, Reference_Rounding => True);
      Assert (Ok, "Q6_K independent activation packing declined");
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q6_K, Bytes, 0, 420, 2, 2, Values, Scales, Totals, Halves,
         0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (Ok, "reference Q6_K product declined");
      for Index in L.Element_Count range 0 .. 3 loop
         Assert (N.Bits (L.Real (Sums (Sums'First + Index)))
                 = N.Bits (B.Get_F32 (Expected, B.Byte_Count (Index) * 4, Ok)),
                 "Q6_K product differs from independent reference at" & Index'Image);
         Assert (Ok, "independent Q6_K result truncated");
      end loop;
      Sums := [others => -123.0];
      QI.Accumulate_Rows
        (Model_Runner.GGUF.Type_Q6_K, Bytes (1 .. Bytes'Last - 1), 0, 420, 2, 2,
         Values, Scales, Totals, Halves, 0, 512, 2, Sums, Ok, Reference_Arithmetic => True);
      Assert (not Ok and then (for all Value of Sums => Value = -123.0),
              "truncated Q6_K weights changed the destination");
   end Reference_Q6_Products;

   procedure Reference_Attention_Packing (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package QI renames Model_Runner.Quantization.Integers;
      package N renames Model_Runner.Numerics;
      Input : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8-attention-input.f32");
      Golden : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/q8-attention-reference.bin");
      Input_Bytes : B.Byte_Array (1 .. B.Byte_Count (Input'Length));
      Expected : B.Byte_Array (1 .. B.Byte_Count (Golden'Length));
      Vectors : L.Real_Array (0 .. 3071);
      Values : QI.Signed_Array (0 .. 3071);
      Scales : L.Real_Array (0 .. 95);
      Totals : QI.Sum_Array (0 .. 95);
      Halves : QI.Sum_Array (0 .. 191);
      Ok : Boolean;
   begin
      Assert (Input'Length = 12288 and then Golden'Length = 3264, "independent attention packing fixture shape");
      for Index in Input'Range loop
         Input_Bytes (B.Byte_Count (Index)) := B.Byte (Character'Pos (Input (Index)));
      end loop;
      for Index in Golden'Range loop
         Expected (B.Byte_Count (Index)) := B.Byte (Character'Pos (Golden (Index)));
      end loop;
      for Index in Vectors'Range loop
         Vectors (Index) := B.Get_F32 (Input_Bytes, B.Byte_Count (Index) * 4, Ok);
         Assert (Ok, "attention packing input truncated");
      end loop;
      QI.Quantize_Vectors
        (Vectors, 1, 3072, Values, Scales, Totals, Halves, Ok, Reference_Rounding => True);
      Assert (Ok, "attention packing refused");
      for Block in L.Element_Count range 0 .. 95 loop
         Assert (Interfaces.Unsigned_16 (N.To_Half (Scales (Block)))
                 = B.Get_U16 (Expected, B.Byte_Count (Block) * 34, Ok),
                 "attention Q8 scale differs at block" & Block'Image);
         Assert (Ok, "attention packing expected scale truncated");
         for Index in L.Element_Count range 0 .. 31 loop
            declare
               Raw : constant Integer := Integer (Expected (Expected'First + B.Byte_Count (Block) * 34
                                                            + 2 + B.Byte_Count (Index)));
               Signed : constant Integer := (if Raw > 127 then Raw - 256 else Raw);
            begin
               Assert (Integer (Values (Block * 32 + Index)) = Signed,
                       "attention Q8 byte differs at" & L.Element_Count'Image (Block * 32 + Index));
            end;
         end loop;
      end loop;
   end Reference_Attention_Packing;

   procedure Dump_Activation (Directory, Name : String; Values : L.Real_Array; Integers : Boolean := False) is
      File : Ada.Streams.Stream_IO.File_Type;
      Bytes : Ada.Streams.Stream_Element_Array (1 .. Ada.Streams.Stream_Element_Offset (Values'Length) * 4);
      Bits : Interfaces.Unsigned_32;
      At_Byte : Ada.Streams.Stream_Element_Offset := 1;
   begin
      for Value of Values loop
         Bits := (if Integers then Interfaces.Unsigned_32 (Value) else Model_Runner.Numerics.Bits (Value));
         for Byte in 0 .. 3 loop
            Bytes (At_Byte) := Ada.Streams.Stream_Element (Interfaces.Shift_Right (Bits, Byte * 8) and 255);
            At_Byte := At_Byte + 1;
         end loop;
      end loop;
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Directory & "/" & Name & (if Integers then ".i32" else ".f32"));
      Ada.Streams.Stream_IO.Write (File, Bytes);
      Ada.Streams.Stream_IO.Close (File);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         raise;
   end Dump_Activation;

   type Reference_Observer is limited new L.Watcher with record
      Compared : Natural := 0;
      Maximum : L.Real := 0.0;
      Elements : Natural := 0;
      Squared : Model_Runner.Numerics.Wide_Real := 0.0;
      Different : Natural := 0;
      First_Failure : U.Unbounded_String;
      First_Route_Failure : U.Unbounded_String;
      Worst : U.Unbounded_String;
      Manifest : access J.Document;
      Expected_Position : Natural := 0;
      Recording_File : U.Unbounded_String := U.To_Unbounded_String ("fixtures/inkling2/tiny-f32.tsv");
      Dump_Directory : U.Unbounded_String;
      Bundle_Directory : U.Unbounded_String := U.To_Unbounded_String ("fixtures/inkling2/q4_k_m-cpu-hello");
      Last_State : Natural := 0;
   end record;

   overriding procedure Note
     (Item : in out Reference_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count);
   overriding procedure Note_State
     (Item : in out Reference_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array);

   overriding procedure Note
     (Item : in out Reference_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count)
   is
      pragma Unreferenced (Rows);
   begin
      if U.Length (Item.Dump_Directory) > 0 and then Ada.Strings.Fixed.Index (Which, "ffn_gate_inp.weight") > 0 then
         Dump_Activation
           (U.To_String (Item.Dump_Directory),
            "ffn_normed-" & Ada.Strings.Fixed.Trim (Item.Last_State'Image, Ada.Strings.Both), Values);
      elsif U.Length (Item.Dump_Directory) > 0
        and then Ada.Strings.Fixed.Index (Which, "attn_gate.weight") > 0
      then
         Dump_Activation
           (U.To_String (Item.Dump_Directory),
            "attention_gate_input-" & Ada.Strings.Fixed.Trim (Item.Last_State'Image, Ada.Strings.Both), Values);
      end if;
   end Note;

   overriding procedure Note_State
     (Item : in out Reference_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array)
   is
      pragma Unreferenced (Logical);
      File : Ada.Text_IO.File_Type;
      State : constant Natural := (if Visit = 1 then Physical else 24 + (Visit - 2) * 12 + Physical - 6);
      Operation : constant String :=
        (if Which = "loop_control_q" then "loop_input_0"
         elsif Which = "loop_control_k" then "loop_input_1"
         elsif Which = "loop_control_v" then "loop_input_2"
         elsif Which = "loop_control_ffn" then "loop_ffn_input" else Which);
      Key : constant String := Operation
        & (if Which in "result_norm" | "result_output" then ""
           else "-" & Ada.Strings.Fixed.Trim (State'Image, Ada.Strings.Both)) & ASCII.HT;

      Absolute_Tolerance : L.Real := 1.0E-5;
      Tensor_Squared : Model_Runner.Numerics.Wide_Real := 0.0;
      Expected_Squared : Model_Runner.Numerics.Wide_Real := 0.0;

      procedure Compare (Index : L.Element_Count; Expected : L.Real) is
         Difference : constant L.Real := abs (Values (Index) - Expected);
      begin
         Item.Elements := Item.Elements + 1;
         Item.Squared := Item.Squared + Model_Runner.Numerics.Wide_Real (Difference) ** 2;
         Tensor_Squared := Tensor_Squared + Model_Runner.Numerics.Wide_Real (Difference) ** 2;
         Expected_Squared := Expected_Squared + Model_Runner.Numerics.Wide_Real (Expected) ** 2;
         if Difference > Item.Maximum then
            Item.Maximum := Difference;
            Item.Worst := U.To_Unbounded_String (Key & " element " & Index'Image);
         end if;
         if (if Which = "ffn_moe_topk" then Difference /= 0.0
             else Difference > Absolute_Tolerance + abs (Expected) * 2.0E-5)
         then
            Item.Different := Item.Different + 1;
            if U.Length (Item.First_Failure) = 0 then
               Item.First_Failure := U.To_Unbounded_String (Key & " element " & Index'Image
                 & ": native " & Values (Index)'Image & ", reference " & Expected'Image);
            end if;
            if Which = "ffn_moe_topk" and then U.Length (Item.First_Route_Failure) = 0 then
               Item.First_Route_Failure := U.To_Unbounded_String (Key & " element " & Index'Image
                 & ": native " & Values (Index)'Image & ", reference " & Expected'Image);
            end if;
         end if;
      end Compare;
   begin
      Assert (Position = Item.Expected_Position, "golden compared to another position");
      Item.Last_State := State;
      if U.Length (Item.Dump_Directory) > 0 then
         Dump_Activation (U.To_String (Item.Dump_Directory), Key (1 .. Key'Last - 1), Values,
                          Which = "ffn_moe_topk");
      end if;
      if Ada.Strings.Fixed.Index (Which, "expert_") = 1
        or else Ada.Strings.Fixed.Index (Which, "attention_") = 1
      then
         return;
      end if;
      if Item.Manifest /= null then
         declare
            Doc : J.Document renames Item.Manifest.all;
            Tensors : constant J.Node := J.Member (Doc, J.Root (Doc), "tensors");
            Raw : Ada.Streams.Stream_IO.File_Type;
            Bytes : Ada.Streams.Stream_Element_Array (1 .. 4);
            Last : Ada.Streams.Stream_Element_Offset;
            Bits : Interfaces.Unsigned_32;
         begin
            for Number in 1 .. J.Length (Doc, Tensors) loop
               declare
                  Tensor : constant J.Node := J.Element (Doc, Tensors, Number);
               begin
                  if J.As_String (Doc, J.Member (Doc, Tensor, "name")) = Key (1 .. Key'Last - 1) then
                     Assert (J.As_Integer (Doc, J.Member (Doc, Tensor, "length_bytes"))
                             = Long_Long_Integer (Values'Length) * 4, "recorded activation length differs");
                     declare
                        Budget : constant J.Node := J.Member (Doc, Tensor, "f16_precision_budget");
                     begin
                        if J.Is_Present (Budget) then
                           Assert (J.As_String (Doc, J.Member (Doc, J.Root (Doc), "comparison_policy"))
                                   = "f16_reference_error_envelope", "unrecognized precision comparison policy");
                           Absolute_Tolerance := L.Real
                             (J.As_Float (Doc, J.Member (Doc, Budget, "absolute_tolerance")));
                        end if;
                     end;
                     Ada.Streams.Stream_IO.Open
                       (Raw, Ada.Streams.Stream_IO.In_File, U.To_String (Item.Bundle_Directory) & "/"
                        & J.As_String (Doc, J.Member (Doc, Tensor, "file")));
                     Ada.Streams.Stream_IO.Set_Index
                       (Raw, Ada.Streams.Stream_IO.Positive_Count
                        (J.As_Integer (Doc, J.Member (Doc, Tensor, "offset_bytes")) + 1));
                     for Index in Values'Range loop
                        Ada.Streams.Stream_IO.Read (Raw, Bytes, Last);
                        Assert (Last = Bytes'Last, "truncated reference bundle");
                        Bits := Interfaces.Unsigned_32 (Bytes (1))
                          or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Bytes (2)), 8)
                          or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Bytes (3)), 16)
                          or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Bytes (4)), 24);
                        Compare (Index,
                          (if J.As_String (Doc, J.Member (Doc, Tensor, "type")) = "i32-le" then L.Real (Bits)
                           else Model_Runner.Numerics.From_Bits (Bits)));
                     end loop;
                     Ada.Streams.Stream_IO.Close (Raw);
                     declare
                        Budget : constant J.Node := J.Member (Doc, Tensor, "f16_precision_budget");
                        RMS : constant Model_Runner.Numerics.Wide_Real := Model_Runner.Numerics.Sqrt
                          (Tensor_Squared / Model_Runner.Numerics.Wide_Real (Values'Length));
                     begin
                        if J.Is_Present (Budget) then
                           Assert (RMS <= Model_Runner.Numerics.Wide_Real
                                     (J.As_Float (Doc, J.Member (Doc, Budget, "rms_tolerance")))
                                   + 2.0E-5 * Model_Runner.Numerics.Sqrt
                                     (Expected_Squared / Model_Runner.Numerics.Wide_Real (Values'Length)),
                                   "F16 tensor RMS exceeds independent reference precision envelope: " & Key);
                        end if;
                     end;
                     Item.Compared := Item.Compared + 1;
                     return;
                  end if;
               end;
            end loop;
         exception
            when others =>
               if Ada.Streams.Stream_IO.Is_Open (Raw) then
                  Ada.Streams.Stream_IO.Close (Raw);
               end if;
               raise;
         end;
         Assert (Which = "attn_out" and then Physical mod 6 = 0, "missing checkpoint golden: " & Key);
         return;
      end if;
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, U.To_String (Item.Recording_File));
      while not Ada.Text_IO.End_Of_File (File) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (File);
            Start : Positive := Key'Length + 1;
            Finish : Natural;
         begin
            if Line'Length >= Key'Length and then Line (1 .. Key'Length) = Key then
               for Index in Values'Range loop
                  Finish := Ada.Strings.Fixed.Index (Line, " ", From => Start);
                  if Finish = 0 then
                     Finish := Line'Last + 1;
                  end if;
                  Compare (Index, L.Real'Value (Line (Start .. Finish - 1)));
                  Start := Finish + 1;
               end loop;
               Assert (Finish = Line'Last + 1, Key & " has additional reference values");
               Item.Compared := Item.Compared + 1;
               Ada.Text_IO.Close (File);
               return;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (File);
      --  At a block boundary the same tensor is named ffn_inp next;
      --  all other attention outputs retain their own callback name.
      Assert (Which = "attn_out" and then Physical mod 6 = 0, "missing independent golden: " & Key);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Note_State;

   procedure Read
     (Fault : Tiny_Model.Inkling_Fault; Config : out L.Configuration; Status : out E.Error_Info;
      Bounds : Model_Runner.Limits.Model_Limits := Model_Runner.Limits.Default_Model_Limits)
   is
      Image : B.Byte_Array_Access;
   begin
      Tiny_Model.Build_Inkling (Image, Fault);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "independent tiny fixture is malformed GGUF");
         Assert (C.Tensor_Count (Descriptor) in 703 .. 705, "tiny tensor inventory changed");
         L.Read_Config (Descriptor, Bounds, Config, Status);
         C.Close (Descriptor);
      exception
         when others =>
            C.Close (Descriptor);
            B.Free (Image);
            raise;
      end;
      B.Free (Image);
   end Read;

   procedure Metadata (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Config : L.Configuration;
      Status : E.Error_Info;
   begin
      Read (Tiny_Model.Inkling_Valid, Config, Status);
      Assert (E.Is_Ok (Status), "valid metadata: " & Status.Code'Image & " " & E.Text_Of (Status, "tensor"));
      Assert (Config.Kind = L.Inkling2_Loop and then Config.Layers = 24
              and then Config.Inkling.Runtime_Layers = 48, "physical and runtime counts were conflated");
      Assert (Config.Embedding = 8 and then Config.Head_Size = 4 and then Config.Heads = 2
              and then Config.KV_Heads = 1 and then Config.Group_Size = 2, "head arrays were misread");
      Assert (Config.Rotary = 0 and then Config.Vocabulary = 16 and then Config.Inkling.Padded_Vocabulary = 20,
              "position or vocabulary contract changed");
      Assert (Config.Window_Layers (0) and then not Config.Window_Layers (5)
              and then Config.Window_Layers (22) and then not Config.Window_Layers (23), "hybrid pattern changed");
      Assert (Config.Experts = 4 and then Config.Experts_Used = 2 and then Config.Sigmoid_Gate
              and then Config.Expert_Scale = 2.0, "routing metadata changed");
      Read (Tiny_Model.Inkling_Omitted_Optionals, Config, Status);
      Assert (E.Is_Ok (Status) and then Config.Expert_Scale = 1.0 and then Config.Logit_Cap = 0.0,
              "reference-defined optional defaults changed");
   end Metadata;

   procedure Malformed (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Config : L.Configuration;
      Status : E.Error_Info;
      Expected : E.Error_Code;
   begin
      for Fault in Tiny_Model.Inkling_Missing_Parameter .. Tiny_Model.Inkling_Extra_Tensor loop
         Expected :=
           (case Fault is
               when Tiny_Model.Inkling_Missing_Parameter => E.GGUF_Missing_Metadata_Key,
               when Tiny_Model.Inkling_Wrong_Parameter_Type => E.GGUF_Metadata_Type_Mismatch,
               when Tiny_Model.Inkling_Nonfinite_Parameter => E.GGUF_Metadata_Out_Of_Range,
               when Tiny_Model.Inkling_Variable_Loops | Tiny_Model.Inkling_Extra_Tensor => E.Arch_Unsupported_Feature,
               when Tiny_Model.Inkling_Missing_Tensor => E.Arch_Missing_Tensor,
               when Tiny_Model.Inkling_Wrong_Expert_Shape => E.Arch_Invalid_Tensor_Shape,
               when others => E.Arch_Invalid_Metadata);
         Read (Fault, Config, Status);
         Assert (Status.Code = Expected, Fault'Image & " returned " & Status.Code'Image
                 & " instead of " & Expected'Image);
         if Fault = Tiny_Model.Inkling_Missing_Tensor then
            Assert (E.Text_Of (Status, "tensor") = "blk.6.loop_q_ctrl_forget.weight",
                    "missing controller diagnostic lost its identity");
         end if;
      end loop;
   end Malformed;

   procedure Integer_Workspace_Plan (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Config : L.Configuration;
      Status : E.Error_Info;
      Smaller, Larger : Model_Runner.Memory.Session_Plan;
      --  Each worker can retain two F32 feed arms and the packed down
      --  input: one byte/value, three 32-bit fields per 32 values and
      --  a second half-block sum. These coexist for a 32-member chunk.
      Minimum_Growth : constant Interfaces.Unsigned_64 :=
        Interfaces.Unsigned_64 (Model_Runner.Backend.CPU.Max_Workers + 1)
        * 32 * 128 * 19 / 2;
   begin
      Read (Tiny_Model.Inkling_Valid, Config, Status);
      Assert (E.Is_Ok (Status), "workspace metadata failed");
      Config.Expert_Feed := 128;
      L.Plan_For (Config, 32, Smaller, Status);
      Assert (E.Is_Ok (Status), "smaller workspace plan failed");
      Config.Expert_Feed := 256;
      L.Plan_For (Config, 32, Larger, Status);
      Assert (E.Is_Ok (Status), "larger workspace plan failed");
      Assert (Larger.Activation_Bytes >= Smaller.Activation_Bytes + Minimum_Growth,
              "session plan understates coexisting integer expert workspaces");
   end Integer_Workspace_Plan;

   procedure Limits (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Config : L.Configuration;
      Status : E.Error_Info;
      Bounds : Model_Runner.Limits.Model_Limits := Model_Runner.Limits.Default_Model_Limits;
   begin
      Bounds.Max_Layers := 47;
      Read (Tiny_Model.Inkling_Valid, Config, Status, Bounds);
      Assert (Status.Code = E.Arch_Invalid_Metadata
              and then E.Text_Of (Status, "key") = "inkling2_loop.loop.state_count",
              "runtime layers escaped caller limits");
      Bounds := Model_Runner.Limits.Default_Model_Limits;
      Bounds.Max_Vocabulary := 19;
      Read (Tiny_Model.Inkling_Valid, Config, Status, Bounds);
      Assert (Status.Code = E.GGUF_Metadata_Out_Of_Range, "padded vocabulary escaped caller limits");
      Bounds := Model_Runner.Limits.Default_Model_Limits;
      Bounds.Max_Embedding := 4;
      Read (Tiny_Model.Inkling_Valid, Config, Status, Bounds);
      Assert (Status.Code = E.GGUF_Metadata_Out_Of_Range, "embedding escaped caller limits");
   end Limits;

   type Cancelling_Observer is limited new L.Watcher with record
      Stop : Model_Runner.Cancellation.Token_Reference;
      Reached : Boolean := False;
      Minimum_Position : Natural := 0;
   end record;

   overriding procedure Note
     (Item : in out Cancelling_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count);
   overriding procedure Note_State
     (Item : in out Cancelling_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array);

   overriding procedure Note
     (Item : in out Cancelling_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count)
   is
      pragma Unreferenced (Item, Which, Values, Rows);
   begin
      null;
   end Note;

   overriding procedure Note_State
     (Item : in out Cancelling_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array)
   is
      pragma Unreferenced (Physical, Visit, Values);
   begin
      if Logical = 20 and then Which = "l_out" and then Position >= Item.Minimum_Position then
         Item.Reached := True;
         Item.Stop.Request;
      end if;
   end Note_State;

   type Replay_Counter is limited new L.Watcher with record
      Tokens : Natural := 0;
   end record;
   overriding procedure Note
     (Item : in out Replay_Counter; Which : String; Values : L.Real_Array; Rows : L.Element_Count);
   overriding procedure Note_State
     (Item : in out Replay_Counter; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array);
   overriding procedure Note
     (Item : in out Replay_Counter; Which : String; Values : L.Real_Array; Rows : L.Element_Count) is
      pragma Unreferenced (Item, Which, Values, Rows);
   begin
      null;
   end Note;
   overriding procedure Note_State
     (Item : in out Replay_Counter; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array) is
      pragma Unreferenced (Physical, Logical, Visit, Position, Values);
   begin
      if Which = "result_norm" then
         Item.Tokens := Item.Tokens + 1;
      end if;
   end Note_State;

   --  Independent cache arithmetic: direct Hadamard coefficients and a
   --  scalar attention equation, operating on observed model-basis Q/K/V.
   type Q4T_Observer is limited new L.Watcher with record
      Config : L.Configuration;
      Capacity : L.Element_Count := 0;
      Queries, Keys, Values, Relative, Sinks, Bias : Model_Runner.Tensors.Real_Array_Access := null;
      Compared, Elements, Different : Natural := 0;
      First_Failure : U.Unbounded_String;
      Maximum : L.Real := 0.0;
   end record;

   overriding procedure Note
     (Item : in out Q4T_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count);
   overriding procedure Note_State
     (Item : in out Q4T_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array);

   overriding procedure Note
     (Item : in out Q4T_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count) is
      pragma Unreferenced (Item, Which, Values, Rows);
   begin
      null;
   end Note;

   procedure Release (Item : in out Q4T_Observer) is
   begin
      Model_Runner.Tensors.Free (Item.Queries);
      Model_Runner.Tensors.Free (Item.Keys);
      Model_Runner.Tensors.Free (Item.Values);
      Model_Runner.Tensors.Free (Item.Relative);
      Model_Runner.Tensors.Free (Item.Sinks);
      Model_Runner.Tensors.Free (Item.Bias);
   end Release;

   procedure Initialize
     (Item : in out Q4T_Observer; Config : L.Configuration; Capacity : Positive;
      Descriptor : C.Container; Source : in out Model_Runner.Byte_Sources.Source'Class)
   is
      package T renames Model_Runner.Tensors;
      D : constant L.Element_Count := L.Element_Count (Config.Head_Size);
      Q : constant L.Element_Count := L.Element_Count (Config.Heads);
      KV : constant L.Element_Count := L.Element_Count (Config.KV_Heads);
      R : constant L.Element_Count := L.Element_Count (Config.Inkling.Relative_Width);
      Extent : constant L.Element_Count := L.Element_Count'Max
        (L.Element_Count (Config.Window), L.Element_Count (Config.Inkling.Relative_Extent));
      Rows : constant L.Element_Count := 48 * L.Element_Count (Capacity);
      Status : E.Error_Info;
      Ok : Boolean;
   begin
      Item.Config := Config;
      Item.Capacity := L.Element_Count (Capacity);
      T.Allocate (Rows * Q * D, Item.Queries);
      T.Allocate (Rows * KV * D, Item.Keys);
      T.Allocate (Rows * KV * D, Item.Values);
      T.Allocate (Rows * Q * R, Item.Relative);
      T.Allocate (Rows * Q, Item.Sinks);
      T.Allocate (24 * Extent * R, Item.Bias);
      Assert (Item.Queries /= null and then Item.Keys /= null and then Item.Values /= null
              and then Item.Relative /= null and then Item.Sinks /= null and then Item.Bias /= null,
              "independent Q4T observer allocation failed");
      for Physical in 0 .. 23 loop
         declare
            Name : constant String := "blk." & Ada.Strings.Fixed.Trim (Physical'Image, Ada.Strings.Both)
              & ".attn_rel_bias.weight";
            Index : constant Natural := C.Find_Tensor (Descriptor, Name);
            Data : B.Byte_Array (0 .. B.Byte_Count (C.Tensor_Bytes (Descriptor, Index)) - 1);
            Count : constant L.Element_Count := L.Element_Count (C.Tensor_Elements (Descriptor, Index));
            At_Bias : constant L.Element_Count := L.Element_Count (Physical) * Extent * R;
         begin
            Assert (C.Tensor_Format (Descriptor, Index) = Model_Runner.GGUF.Type_F32,
                    "Q4T oracle expects the model's F32 relative table");
            Source.Read (B.Byte_Count (C.Tensor_Offset (Descriptor, Index)), Data, Status);
            Assert (E.Is_Ok (Status), "Q4T relative table read failed");
            for Offset in 0 .. Count - 1 loop
               Item.Bias (At_Bias + Offset) := B.Get_F32 (Data, B.Byte_Count (Offset) * 4, Ok);
               Assert (Ok, "Q4T relative table is truncated");
            end loop;
         end;
      end loop;
   end Initialize;

   overriding procedure Note_State
     (Item : in out Q4T_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array)
   is
      pragma Unreferenced (Logical);
      package N renames Model_Runner.Numerics;
      package Codec renames Model_Runner.Cache_Codecs.Transformed_Four_Bit;
      package Reference renames Transformed_Four_Bit_Reference;
      D : constant L.Element_Count := L.Element_Count (Item.Config.Head_Size);
      Q : constant L.Element_Count := L.Element_Count (Item.Config.Heads);
      KV : constant L.Element_Count := L.Element_Count (Item.Config.KV_Heads);
      R : constant L.Element_Count := L.Element_Count (Item.Config.Inkling.Relative_Width);
      State : constant L.Element_Count := L.Element_Count
        (if Visit = 1 then Physical else 24 + (Visit - 2) * 12 + Physical - 6);
      Row : constant L.Element_Count := State * Item.Capacity + L.Element_Count (Position);
      Extent : constant L.Element_Count := L.Element_Count'Max
        (L.Element_Count (Item.Config.Window), L.Element_Count (Item.Config.Inkling.Relative_Extent));
      Valid : Boolean;
   begin
      if Which not in "Qcur" | "Kcur" | "Vcur" | "Rcur" | "attn_q4t_sinks" | "attn_q4t_output" then return; end if;
      Assert (L.Element_Count (Position) < Item.Capacity, "Q4T observer prefix exceeded its capacity");
      if Which = "Qcur" then
         Item.Queries.all (Row * Q * D .. (Row + 1) * Q * D - 1) := Values;
      elsif Which in "Kcur" | "Vcur" then
         for Head in 0 .. KV - 1 loop
            declare
               Codes : Codec.Byte_Array (0 .. Codec.Code_Bytes (D) - 1);
               Scales : L.Real_Array (0 .. Codec.Scale_Count (D) - 1);
               Decoded : L.Real_Array (0 .. D - 1);
               At_Row : constant L.Element_Count := Row * KV * D + Head * D;
               Input : L.Real_Array renames Values (Values'First + Head * D .. Values'First + (Head + 1) * D - 1);
            begin
               if Which = "Kcur" then
                  Reference.Encode_Key (Input, Codes, Scales, Valid);
                  Assert (Valid, "independent Q4T key encoding failed");
                  Reference.Decode_Key (Codes, Scales, Decoded, Valid);
                  Item.Keys.all (At_Row .. At_Row + D - 1) := Decoded;
               else
                  Reference.Encode_Value (Input, Codes, Scales, Valid);
                  Assert (Valid, "independent Q4T value encoding failed");
                  Reference.Decode_Value (Codes, Scales, Decoded, Valid);
                  Item.Values.all (At_Row .. At_Row + D - 1) := Decoded;
               end if;
               Assert (Valid, "independent Q4T decoding failed");
            end;
         end loop;
      elsif Which = "Rcur" then
         Item.Relative.all (Row * Q * R .. (Row + 1) * Q * R - 1) := Values;
      elsif Which = "attn_q4t_sinks" then
         Item.Sinks.all (Row * Q .. (Row + 1) * Q - 1) := Values;
      else
         declare
            Local : constant Boolean := Item.Config.Window_Layers (Physical);
            First : constant Natural :=
              (if Local and then Position >= Item.Config.Window then Position - Item.Config.Window + 1 else 0);
            Table_Length : constant Natural :=
              (if Local then Item.Config.Window else Item.Config.Inkling.Relative_Extent);
            Scale : constant L.Real := 1.0 / L.Real (N.Sqrt (N.Wide_Real (D)));
         begin
            for Head in 0 .. Q - 1 loop
               declare
                  Scores : L.Real_Array (L.Element_Count (First) .. L.Element_Count (Position));
                  Maximum : L.Real := 0.0;
                  Total : N.Wide_Real;
                  Inverse : L.Real;
                  Sum : N.Wide_Real_Array (0 .. D - 1) := [others => 0.0];
                  KV_Head : constant L.Element_Count := Head / L.Element_Count (Item.Config.Group_Size);
               begin
                  for Past in First .. Position loop
                     declare
                        Dot : N.Wide_Real := 0.0;
                        Bias : L.Real := 0.0;
                        Key_At : constant L.Element_Count :=
                          (State * Item.Capacity + L.Element_Count (Past)) * KV * D + KV_Head * D;
                     begin
                        for Channel in 0 .. D - 1 loop
                           Dot := Dot + N.Wide_Real (Item.Queries (Row * Q * D + Head * D + Channel))
                             * N.Wide_Real (Item.Keys (Key_At + Channel));
                        end loop;
                        if Position - Past < Table_Length then
                           for Channel in 0 .. R - 1 loop
                              Bias := Bias + Item.Relative (Row * Q * R + Head * R + Channel)
                                * Item.Bias (L.Element_Count (Physical) * Extent * R
                                             + L.Element_Count (Position - Past) * R + Channel);
                           end loop;
                        end if;
                        Scores (L.Element_Count (Past)) := L.Real (Dot) * Scale
                          + (Bias - Item.Sinks (Row * Q + Head));
                        Maximum := L.Real'Max (Maximum, Scores (L.Element_Count (Past)));
                     end;
                  end loop;
                  Total := N.Wide_Real (L.Real (N.Exp (N.Wide_Real (-Maximum))));
                  for Score of Scores loop
                     Score := L.Real (N.Exp (N.Wide_Real (Score - Maximum)));
                     Total := Total + N.Wide_Real (Score);
                  end loop;
                  Inverse := L.Real (1.0 / Total);
                  for Past in First .. Position loop
                     declare
                        P : constant N.Wide_Real := N.Wide_Real (Scores (L.Element_Count (Past)) * Inverse);
                        At_Value : constant L.Element_Count :=
                          (State * Item.Capacity + L.Element_Count (Past)) * KV * D + KV_Head * D;
                     begin
                        for Channel in 0 .. D - 1 loop
                           Sum (Channel) := Sum (Channel) + P * N.Wide_Real (Item.Values (At_Value + Channel));
                        end loop;
                     end;
                  end loop;
                  for Channel in Sum'Range loop
                     declare
                        Expected : constant L.Real := L.Real (Sum (Channel));
                        Difference : constant L.Real := abs (Values (Values'First + Head * D + Channel) - Expected);
                     begin
                        Item.Maximum := L.Real'Max (Item.Maximum, Difference);
                        Item.Elements := Item.Elements + 1;
                        if Difference > 1.0E-5 + 2.0E-5 * abs Expected then
                           Item.Different := Item.Different + 1;
                           if U.Length (Item.First_Failure) = 0 then
                              Item.First_Failure := U.To_Unbounded_String
                                ("Q4T attention differs from independent reference, state" & State'Image
                                 & " position" & Position'Image & " head" & Head'Image
                                 & " channel" & Channel'Image & " error" & Difference'Image);
                           end if;
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end;
         Item.Compared := Item.Compared + 1;
      end if;
   end Note_State;

   procedure Q4T_Cache (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image, Saved : B.Byte_Array_Access := null;
      Status : E.Error_Info;
      Config : L.Configuration;
   begin
      Model_Runner.Backend.CPU.Use_Integer_Activations (False);
      Read (Tiny_Model.Inkling_Valid, Config, Status);
      Assert (E.Is_Ok (Status) and then not L.Cache_Compatible (Config, L.Transformed_Fourth),
              "Q4T accepted a transform crossing a tiny head boundary");
      Tiny_Model.Build_Inkling (Image, Fault => Tiny_Model.Inkling_Aligned_Heads, Room => 512);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live, Fresh : L.Session;
         Team : aliased Model_Runner.Backend.CPU.Pool (1);
         Other_Team : aliased Model_Runner.Backend.CPU.Pool (2);
         Observer : aliased Q4T_Observer;
         Stop : aliased Model_Runner.Cancellation.Token;
         Interrupt : aliased Cancelling_Observer;
         Tokens : Model_Runner.Tokenizer.Token_Array (1 .. 24);
         Long_Prefix : Model_Runner.Tokenizer.Token_Array (1 .. 512);
         Actual, Expected, Continued : L.Real_Array (0 .. 15);
         Every : Model_Runner.Tensors.Real_Array_Access := new L.Real_Array (0 .. 24 * 16 - 1);
         Baseline : L.Real_Array (Every.all'Range);
         Exact_Plan, Packed_Plan : Model_Runner.Memory.Session_Plan;

         procedure Good (Where : String) is
         begin
            Assert (E.Is_Ok (Status), Where & ": " & Status.Code'Image
                    & " " & E.Text_Of (Status, "tensor") & " " & E.Text_Of (Status, "exception"));
         end Good;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Good ("Q4T parse");
         L.Prepare (Engine, Descriptor, Source, Backend => Model_Runner.Backend.Backend_CPU, Status => Status);
         Good ("Q4T prepare");
         Assert (L.Cache_Compatible (L.Config (Engine), L.Transformed_Fourth), "aligned Q4T heads refused");
         L.Plan_Session (Engine, 512, Exact_Plan, Status, Cache => L.Exact);
         Good ("Q4T exact plan");
         L.Plan_Session (Engine, 512, Packed_Plan, Status, Cache => L.Transformed_Fourth);
         Good ("Q4T packed plan");
         Assert (Packed_Plan.KV_Cache_Bytes * 32 = Exact_Plan.KV_Cache_Bytes * 5,
                 "Q4T plan did not use five bits per key/value element including scales");
         L.Plan_Session (Engine, 512, Packed_Plan, Status, Cache => L.Transformed_Fourth, Values => L.Value_Eighth);
         Assert (Status.Code = E.Arch_Unsupported_Feature, "unsupported Inkling Q4T/value pairing was accepted");
         L.Open (Live, Engine, Context => 512, Cache => L.Transformed_Fourth,
                 Workers => Team'Unchecked_Access, Status => Status);
         Good ("Q4T grouped open");
         L.Open (Fresh, Engine, Context => 512, Cache => L.Transformed_Fourth,
                 Workers => Other_Team'Unchecked_Access, Status => Status);
         Good ("Q4T independent-head open");
         for Index in Tokens'Range loop Tokens (Index) := Model_Runner.Tokenizer.Token_Id (3 + Index mod 12); end loop;
         for Index in Long_Prefix'Range loop
            Long_Prefix (Index) := Model_Runner.Tokenizer.Token_Id (3 + Index mod 12);
         end loop;
         for Index in Tokens'Range loop
            L.Evaluate (Fresh, Engine, Tokens (Index), Expected, Status => Status);
            Good ("Q4T scalar reference");
            Baseline (L.Element_Count ((Index - 1) * 16) .. L.Element_Count (Index * 16 - 1)) := Expected;
         end loop;
         Initialize (Observer, L.Config (Engine), 32, Descriptor, Source);
         L.Watch (Live, Observer'Unchecked_Access);
         L.Evaluate_Batch (Live, Engine, Tokens, Actual, Every => Every, Status => Status);
         L.Watch (Live, null);
         Good ("Q4T batched independent attention");
         Assert (Every.all = Baseline, "Q4T prefill/grouped heads differ from incremental independent heads");
         Assert (Observer.Compared = 48 * Tokens'Length, "Q4T oracle missed a logical visit or prompt position");
         Assert (Observer.Different = 0, U.To_String (Observer.First_Failure));
         Ada.Text_IO.Put_Line ("Inkling Q4T independent attention: " & Observer.Compared'Image
                              & " rows, " & Observer.Elements'Image & " elements, max " & Observer.Maximum'Image);
         Release (Observer);
         L.Evaluate (Live, Engine, 5, Actual, Status => Status);
         Good ("Q4T batched continuation");
         L.Evaluate (Fresh, Engine, 5, Expected, Status => Status);
         Good ("Q4T scalar continuation");
         Assert (Actual = Expected, "Q4T prefill left different logical cache state");
         L.Snapshot (Live, Engine, Saved, Status);
         Good ("Q4T snapshot");
         L.Evaluate (Live, Engine, 6, Continued, Status => Status);
         Good ("Q4T snapshot continuation");
         L.Adopt (Live, Engine, Saved.all, Status);
         Good ("Q4T adoption");
         L.Evaluate (Live, Engine, 6, Actual, Status => Status);
         Good ("Q4T adopted continuation");
         Assert (Actual = Continued, "Q4T snapshot changed a continuation");
         B.Free (Saved);
         L.Rewind (Live, 8, Status);
         Good ("Q4T rewind");
         L.Reset (Fresh);
         L.Evaluate_Batch (Fresh, Engine, Tokens (1 .. 8), Expected, Status => Status);
         Good ("Q4T fresh rewind prefix");
         L.Evaluate (Fresh, Engine, 14, Expected, Status => Status);
         Good ("Q4T fresh alternative");
         L.Evaluate (Live, Engine, 14, Actual, Status => Status);
         Good ("Q4T alternative");
         Assert (Actual = Expected, "Q4T rewind retained another branch's cache");
         Interrupt.Stop := Stop'Unchecked_Access;
         Interrupt.Reached := False;
         L.Watch (Live, Interrupt'Unchecked_Access);
         L.Evaluate (Live, Engine, 5, Actual, Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then Interrupt.Reached and then L.Position (Live) = 9,
                 "cancelled Q4T evaluation committed a partial token");
         Stop.Reset;
         L.Watch (Live, null);
         L.Evaluate (Live, Engine, 13, Actual, Status => Status);
         Good ("Q4T continuation after cancellation");
         L.Evaluate (Fresh, Engine, 13, Expected, Status => Status);
         Good ("Q4T cancellation control");
         Assert (Actual = Expected, "cancelled Q4T visit corrupted a continuation");
         L.Reset (Live);
         for Chunk in 0 .. 7 loop
            L.Evaluate_Batch (Live, Engine, Long_Prefix (Chunk * 64 + 1 .. (Chunk + 1) * 64),
                              Actual, Status => Status);
            Good ("Q4T context eviction");
         end loop;
         L.Rewind (Live, 17, Status);
         Good ("Q4T rewind past local eviction");
         L.Reset (Fresh);
         L.Evaluate_Batch (Fresh, Engine, Long_Prefix (1 .. 17), Expected, Status => Status);
         Good ("Q4T fresh evicted prefix");
         L.Evaluate (Fresh, Engine, 15, Expected, Status => Status);
         Good ("Q4T fresh evicted continuation");
         L.Evaluate (Live, Engine, 15, Actual, Status => Status);
         Good ("Q4T evicted continuation");
         Assert (Actual = Expected, "Q4T local eviction and replay changed a branch");
         Model_Runner.Tensors.Free (Every);
         L.Close (Live); L.Close (Fresh);
         L.Close (Engine, Status); C.Close (Descriptor);
         Model_Runner.Backend.CPU.Close (Team); Model_Runner.Backend.CPU.Close (Other_Team);
      exception
         when others =>
            Release (Observer);
            Model_Runner.Tensors.Free (Every);
            L.Close (Live); L.Close (Fresh);
            L.Close (Engine, Status); C.Close (Descriptor);
            Model_Runner.Backend.CPU.Close (Team); Model_Runner.Backend.CPU.Close (Other_Team);
            raise;
      end;
      B.Free (Image);
   exception
      when others => B.Free (Image); B.Free (Saved); raise;
   end Q4T_Cache;

   procedure Q4T_Checkpoint (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Variable : constant String := "MODEL_RUNNER_INKLING_Q4T_MODEL";
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Descriptor : C.Container;
      Engine : aliased L.Model;
      Live, Fresh : L.Session;
      Team : aliased Model_Runner.Backend.CPU.Pool (7);
      Observer : aliased Q4T_Observer;
      Status : E.Error_Info;
      Stop : aliased Model_Runner.Cancellation.Token;
      Interrupt : aliased Cancelling_Observer;
      --  Seventeen positions exercise eight-key tiles, four-query, paired
      --  and single-query paths, and multiple scale blocks at D=128.
      Tokens : constant Model_Runner.Tokenizer.Token_Array :=
        [1, 3, 4, 5, 6, 1, 3, 4, 5, 6, 1, 3, 4, 5, 6, 1, 3];
      Actual, Expected : L.Real_Array (0 .. 200057);
      Backend : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_BACKEND", "cpu");
      On_Device : constant Boolean := Backend in "device" | "hybrid";
      Sharing : constant Boolean := Backend = "device";
      Bounds : Model_Runner.Limits.Model_Limits := Model_Runner.Limits.Default_Model_Limits;
      Arithmetic : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_ARITH", "f32");

      procedure Compare (Where : String) is
         Outside : Natural := 0;
         Maximum : L.Real := 0.0;
      begin
         if not On_Device or else Arithmetic = "int8" then
            Assert (Actual = Expected, Where);
            return;
         end if;
         --  Existing independent F32 checkpoint envelope; device matrix
         --  batch shapes do not promise bit-identical floating reductions.
         for Index in Actual'Range loop
            declare
               Difference : constant L.Real := abs (Actual (Index) - Expected (Index));
            begin
               Maximum := L.Real'Max (Maximum, Difference);
               if Difference > 1.0E-5 + 2.0E-5 * abs Expected (Index) then Outside := Outside + 1; end if;
            end;
         end loop;
         Ada.Text_IO.Put_Line ("Q4T hybrid " & Where & ": max " & Maximum'Image
                              & ", outside original F32 envelope " & Outside'Image);
         Assert (Outside = 0, Where & ": differences outside the original F32 reference envelope");
      end Compare;
   begin
      if not Ada.Environment_Variables.Exists (Variable) then return; end if;
      Assert (Backend in "cpu" | "device" | "hybrid", "Q4T checkpoint backend must be cpu, device or hybrid");
      if On_Device then
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open
              (Ready, Budget => 4_294_967_296, Share_Host => Sharing, Tuning_Profile => "none");
            Assert (Ready, "Q4T checkpoint device open failed");
            Model_Runner.Backend.Device.Round_Walks
              (if Arithmetic = "int8" then Model_Runner.Platform.Device.Products.Rounds_Every
               else Model_Runner.Platform.Device.Products.Rounds_None);
         end;
      end if;
      Assert (Arithmetic in "f32" | "int8", "Q4T checkpoint arithmetic must be f32 or int8");
      Model_Runner.Backend.CPU.Use_Integer_Activations (Arithmetic = "int8");
      if Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_INTEGER_WIDTH", "512") = "256" then
         Assert (not On_Device and then Arithmetic = "int8", "width comparison requires CPU integer execution");
         Model_Runner.Quantization.Integers.Use_Deep_Rows (False);
      end if;
      Model_Runner.Byte_Sources.Files.Open (Source, Ada.Environment_Variables.Value (Variable), Status => Status);
      Assert (E.Is_Ok (Status), "Q4T checkpoint file open failed");
      C.Reader.Parse (Descriptor, Source, Status => Status);
      Assert (E.Is_Ok (Status), "Q4T checkpoint parse failed");
      if Sharing then
         Bounds.Max_Allocation_Bytes := 24 * 1024 * 1024 * 1024;
         Bounds.Max_Model_Bytes := 24 * 1024 * 1024 * 1024;
      end if;
      L.Prepare (Engine, Descriptor, Source, Bounds => Bounds,
                 Backend => (if On_Device then Model_Runner.Backend.Backend_Device
                             else Model_Runner.Backend.Backend_CPU),
                 Context => 32,
                 Expert_Cache => (if Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_CHAIN_GPU")
                                  then 256 * 1024 * 1024 else 0), Status => Status);
      Assert (E.Is_Ok (Status), "Q4T checkpoint preparation failed");
      L.Open (Live, Engine, Context => 32, Cache => L.Transformed_Fourth,
              Workers => Team'Unchecked_Access, Status => Status);
      Assert (E.Is_Ok (Status), "Q4T checkpoint session open failed");
      Initialize (Observer, L.Config (Engine), 32, Descriptor, Source);
      L.Watch (Live, Observer'Unchecked_Access);
      L.Evaluate_Batch (Live, Engine, Tokens, Actual, Status => Status);
      L.Watch (Live, null);
      Assert (E.Is_Ok (Status), "Q4T checkpoint prefill failed: " & Status.Code'Image
              & " " & E.Text_Of (Status, "exception"));
      Assert (Observer.Compared = 48 * Tokens'Length, "full-checkpoint Q4T attention coverage incomplete");
      Assert (Observer.Different = 0, U.To_String (Observer.First_Failure));
      L.Open (Fresh, Engine, Context => 32, Cache => L.Transformed_Fourth,
              Workers => Team'Unchecked_Access, Status => Status);
      Assert (E.Is_Ok (Status), "Q4T checkpoint incremental open failed");
      L.Evaluate_Batch (Fresh, Engine, Tokens, Expected, Status => Status);
      Assert (E.Is_Ok (Status), "Q4T unwatched grouped projection prefill failed");
      if Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_CHAIN_GPU") then
         Assert (L.Expert_Cache_Stats (Fresh).Device_Runs > 0,
                 "batched prefill did not execute resident integer experts");
         Ada.Text_IO.Put_Line ("Resident expert sequences during prefill:"
                               & L.Expert_Cache_Stats (Fresh).Device_Runs'Image);
      end if;
      Compare ("watched versus grouped projection prefill");
      L.Reset (Fresh);
      for Token of Tokens loop
         L.Evaluate (Fresh, Engine, Token, Expected, Status => Status);
         Assert (E.Is_Ok (Status), "Q4T checkpoint incremental evaluation failed");
      end loop;
      Compare ("prefill and incremental");
      L.Evaluate (Live, Engine, 7, Actual, Status => Status);
      Assert (E.Is_Ok (Status), "Q4T checkpoint continuation failed");
      L.Evaluate (Fresh, Engine, 7, Expected, Status => Status);
      Assert (E.Is_Ok (Status), "Q4T checkpoint control continuation failed");
      Compare ("cache continuation");
      if Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_CHAIN_GPU") then
         Assert (L.Expert_Cache_Stats (Fresh).Device_Runs > 0,
                 "resident integer MoE test did not execute its native sequence");
      end if;
      declare
         Before, After : L.Real_Array (0 .. L.Element_Count (L.Config (Engine).Embedding) - 1);
         Position : constant Natural := L.Position (Live);
      begin
         L.Hidden_State (Live, Before, Status);
         Assert (E.Is_Ok (Status), "Q4T hidden state before batch cancellation");
         Interrupt.Stop := Stop'Unchecked_Access;
         Interrupt.Minimum_Position := Position + 2;
         L.Watch (Live, Interrupt'Unchecked_Access);
         L.Evaluate_Batch (Live, Engine, Tokens (1 .. 5), Actual,
                           Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then Interrupt.Reached
                 and then L.Position (Live) = Position, "Q4T cancellation committed part of a batch");
         L.Watch (Live, null);
         Stop.Reset;
         L.Hidden_State (Live, After, Status);
         Assert (E.Is_Ok (Status) and then Before = After, "Q4T cancellation changed the committed hidden state");
         L.Evaluate (Live, Engine, 8, Actual, Status => Status);
         Assert (E.Is_Ok (Status), "Q4T continuation after batch cancellation");
         L.Evaluate (Fresh, Engine, 8, Expected, Status => Status);
         Assert (E.Is_Ok (Status), "Q4T control after batch cancellation");
         Compare ("batch cancellation recovery");
         L.Rewind (Live, Tokens'Length, Status);
         Assert (E.Is_Ok (Status), "Q4T checkpoint before continuation lost");
         L.Rewind (Fresh, Tokens'Length, Status);
         Assert (E.Is_Ok (Status), "Q4T control checkpoint before continuation lost");
         L.Evaluate (Live, Engine, 9, Actual, Status => Status);
         Assert (E.Is_Ok (Status), "Q4T branch after batch rewind");
         L.Evaluate (Fresh, Engine, 9, Expected, Status => Status);
         Assert (E.Is_Ok (Status), "Q4T control branch after batch rewind");
         Compare ("batch checkpoint rewind");
      end;
      if Backend = "cpu" and then Arithmetic = "int8" then
         declare
            Position : constant Natural := L.Position (Live);
            Selected : constant Model_Runner.Shares.Member_Rows := [0, 1, 47, L.Config (Engine).Vocabulary - 1];
         begin
            Assert (L.Selected_Head_Available (Live, Engine), "checkpoint selected head unavailable");
            L.Evaluate (Live, Engine, 10, Actual, Status => Status);
            Assert (E.Is_Ok (Status), "checkpoint full output qualification");
            Expected := Actual;
            L.Rewind (Live, Position, Status);
            Assert (E.Is_Ok (Status), "checkpoint selected output rewind");
            L.Evaluate_Selected (Live, Engine, 10, Selected, Actual'Unrestricted_Access, Status => Status);
            Assert (E.Is_Ok (Status), "checkpoint selected output evaluation");
            for I of Selected loop
               Assert (Model_Runner.Numerics.Bits (Actual (L.Element_Count (I)))
                       = Model_Runner.Numerics.Bits (Expected (L.Element_Count (I))),
                       "checkpoint selected output changed qualified integer bits");
            end loop;
            L.Complete_Logits (Live, Engine, Actual'Unrestricted_Access, Status);
            Assert (E.Is_Ok (Status) and then Actual = Expected and then L.Position (Live) = Position + 1,
                    "checkpoint full materialization changed logits or position");
            L.Rewind (Live, Position, Status);
            Assert (E.Is_Ok (Status), "checkpoint greedy output rewind");
            declare
               Winner : Model_Runner.Tokenizer.Token_Id;
               Want : L.Element_Count := Expected'First;
            begin
               for I in Expected'Range loop
                  if Expected (I) > Expected (Want) then Want := I; end if;
               end loop;
               L.Evaluate_Greedy (Live, Engine, 10, Actual'Unrestricted_Access, Winner, Status => Status);
               Assert (E.Is_Ok (Status) and then Actual = Expected
                       and then Winner = Model_Runner.Tokenizer.Token_Id (Want),
                       "checkpoint fused greedy head changed full logits or winner");
            end;
         end;
      end if;
      if On_Device then
         Assert (L.Loop_Device_Attention_Runs (Live) > 0, "Q4T device lifecycle silently used CPU attention");
      end if;
      Ada.Text_IO.Put_Line ("Inkling Q4_K_M Q4T attention reference: " & Observer.Compared'Image
                           & " rows, " & Observer.Elements'Image & " elements, max " & Observer.Maximum'Image);
      Model_Runner.Quantization.Integers.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
      declare
         Stats : constant L.Expert_Cache_Statistics := L.Expert_Cache_Stats (Fresh);
      begin
         Assert (Stats.Metadata_Bytes <= 128 * 1024 * 1024
                 and then Stats.Largest_Metadata_Layer <= 2 * (128 * 1024 * 1024 / 12),
                 "elastic coefficient cache exceeded its total or layer cap");
         Ada.Text_IO.Put_Line ("Inkling metadata bytes " & Stats.Metadata_Bytes'Image
           & ", largest layer " & Stats.Largest_Metadata_Layer'Image
           & ", work-plan hits " & Stats.Work_Plan_Hits'Image
           & ", batched GPU reductions " & Stats.Batched_Device_Aggregations'Image);
      end;
      Release (Observer);
      L.Close (Live); L.Close (Fresh); L.Close (Engine, Status); C.Close (Descriptor);
      Model_Runner.Byte_Sources.Files.Close (Source); Model_Runner.Backend.CPU.Close (Team);
      if On_Device then
         Assert (Model_Runner.Backend.Device.Cache_Claimed = 0, "native Q4T device cache survived session close");
         Model_Runner.Backend.Device.Close;
      end if;
   exception
      when others =>
         Model_Runner.Quantization.Integers.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
      Release (Observer);
         L.Close (Live); L.Close (Fresh); L.Close (Engine, Status); C.Close (Descriptor);
         Model_Runner.Byte_Sources.Files.Close (Source); Model_Runner.Backend.CPU.Close (Team);
         if On_Device then Model_Runner.Backend.Device.Close; end if;
         raise;
   end Q4T_Checkpoint;

   procedure Lifecycle (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access := null;
      Saved : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Write_Inkling ("obj/tiny-inkling.gguf");
      Tiny_Model.Write_Inkling ("obj/tiny-inkling-q8.gguf", Quantized => True);
      Tiny_Model.Write_Inkling ("obj/tiny-inkling-long.gguf", Room => 2304);
      Tiny_Model.Write_Inkling ("obj/tiny-inkling-zero-controls.gguf", Fault => Tiny_Model.Inkling_Zero_Controls);
      Tiny_Model.Build_Inkling (Image);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live, Again : L.Session;
         First, Second, Alternative, Actual : L.Real_Array (0 .. 15);
         Tokens : constant Model_Runner.Tokenizer.Token_Array := [3, 4];
         Stop : aliased Model_Runner.Cancellation.Token;
         Interrupt : aliased Cancelling_Observer;
         Hidden_Before, Hidden_After : L.Real_Array (0 .. 7);
         Budget : Model_Runner.Limits.Session_Limits := Model_Runner.Limits.Default_Session_Limits;
         use type L.Session_State;

         procedure Good (Operation : String) is
         begin
            Assert (E.Is_Ok (Status), Operation & ": " & Status.Code'Image
                    & " " & E.Text_Of (Status, "tensor") & " " & E.Text_Of (Status, "key"));
         end Good;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Good ("parse");
         L.Prepare (Engine, Descriptor, Source, Backend => Model_Runner.Backend.Backend_CPU, Status => Status);
         Good ("prepare");
         Budget.Max_Session_Bytes := 1;
         L.Open (Live, Engine, Context => 32, Session_Bounds => Budget, Status => Status);
         Assert (E.Is_Error (Status) and then L.State (Live) = L.Closed,
                 "impossible memory budget did not refuse a closed session");
         L.Open (Live, Engine, Context => 32, Status => Status);
         Good ("open");
         L.Evaluate (Live, Engine, 3, First, Status => Status);
         Good ("first");
         L.Snapshot (Live, Engine, Saved, Status);
         Good ("snapshot");
         L.Evaluate (Live, Engine, 4, Second, Status => Status);
         Good ("second");
         L.Rewind (Live, 1, Status);
         Good ("rewind");
         L.Evaluate (Live, Engine, 5, Alternative, Status => Status);
         Good ("alternative");
         L.Reset (Live);
         L.Evaluate (Live, Engine, 3, Actual, Status => Status);
         Good ("reset");
         Assert (Actual = First, "reset retained invalid state");
         L.Evaluate (Live, Engine, 5, Actual, Status => Status);
         Good ("fresh continuation");
         Assert (Actual = Alternative, "rewind retained another continuation's convolution state");
         L.Reset (Live);
         L.Evaluate_Batch (Live, Engine, Tokens, Actual, Status => Status);
         Good ("prefill");
         Assert (Actual = Second, "prefill differs from token-at-a-time decoding");
         L.Open (Again, Engine, Context => 32, Status => Status);
         Good ("second session");
         L.Adopt (Again, Engine, Saved.all, Status);
         Good ("adopt");
         L.Evaluate (Again, Engine, 4, Actual, Status => Status);
         Good ("saved continuation");
         Assert (Actual = Second, "snapshot lost logical KV or convolution state");
         --  Cancel after the second visit has mutated KV and convolution history.
         L.Rewind (Live, 1, Status);
         Good ("rewind before interruption");
         L.Hidden_State (Live, Hidden_Before, Status);
         Good ("hidden state before cancellation");
         Interrupt.Stop := Stop'Unchecked_Access;
         L.Watch (Live, Interrupt'Unchecked_Access);
         L.Evaluate (Live, Engine, 4, Actual, Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then Interrupt.Reached,
                 "cancellation was not observed during a repeated logical visit");
         Assert (L.Position (Live) = 1, "cancelled token was committed");
         L.Hidden_State (Live, Hidden_After, Status);
         Good ("hidden state after cancellation");
         Assert (Hidden_Before = Hidden_After, "cancelled token exposed an uncommitted hidden state");
         Stop.Reset;
         L.Watch (Live, null);
         L.Evaluate (Live, Engine, 5, Actual, Status => Status);
         Good ("continuation after interruption");
         Assert (Actual = Alternative, "cancelled visit contaminated the next continuation");
         L.Close (Again);
         L.Open (Again, Engine, Context => 32, Cache => L.Halved, Status => Status);
         Good ("half cache open");
         L.Evaluate (Again, Engine, 3, First, Status => Status);
         Good ("half cache first");
         B.Free (Saved);
         L.Snapshot (Again, Engine, Saved, Status);
         Good ("half cache snapshot");
         L.Evaluate (Again, Engine, 4, Second, Status => Status);
         Good ("half cache second");
         L.Adopt (Again, Engine, Saved.all, Status);
         Good ("half cache adopt");
         L.Evaluate (Again, Engine, 4, Actual, Status => Status);
         Good ("half cache continuation");
         Assert (Actual = Second, "half cache adoption lost per-visit state");
         L.Close (Again);
         Model_Runner.Backend.CPU.Use_Integer_Activations (True);
         L.Open (Again, Engine, Context => 32, Cache => L.Halved, Status => Status);
         Good ("different arithmetic open");
         L.Adopt (Again, Engine, Saved.all, Status);
         Assert (Status.Code = E.Lifecycle_Cache_Mismatched and then L.Position (Again) = 0,
                 "snapshot reused another activation arithmetic's context");
         Model_Runner.Backend.CPU.Use_Integer_Activations (False);
         L.Close (Again);
         L.Close (Live);
         L.Close (Engine, Status);
         C.Close (Descriptor);
      exception
         when others =>
            L.Close (Again);
            L.Close (Live);
            L.Close (Engine, Status);
            C.Close (Descriptor);
            raise;
      end;
      B.Free (Saved);
      B.Free (Image);
   exception
      when others =>
         B.Free (Saved);
         B.Free (Image);
         raise;
   end Lifecycle;

   procedure Cross_Reference
     (Quantized : Boolean; On_Device : Boolean := False;
      Fault : Tiny_Model.Inkling_Fault := Tiny_Model.Inkling_Valid;
      Layout : L.Repack_Mode := L.No_Repack;
      Panel_Path : String := ""; Expect_Mapped : Boolean := False)
   is
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      if On_Device then
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Close;
            Model_Runner.Backend.Device.Open (Ready, Tuning_Profile => "none");
            if not Ready then
               Device_Notes.Skip ("for native Inkling differential inference");
               return;
            end if;
            Model_Runner.Backend.Device.Round_Walks
              (Model_Runner.Platform.Device.Products.Rounds_None);
         end;
      end if;
      Tiny_Model.Build_Inkling (Image, Fault => Fault, Quantized => Quantized);
      Model_Runner.Backend.CPU.Use_Integer_Activations (Quantized);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live : L.Session;
         Observer : aliased Reference_Observer;
         Actual, Watched : L.Real_Array (0 .. 15);
         Team : aliased Model_Runner.Backend.CPU.Pool (2);
      begin
         if Quantized then
            Observer.Recording_File := U.To_Unbounded_String ("fixtures/inkling2/tiny-q8.tsv");
         elsif Fault = Tiny_Model.Inkling_Zero_Controls then
            Observer.Recording_File := U.To_Unbounded_String ("fixtures/inkling2/tiny-zero-controls.tsv");
         end if;
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "reference fixture parse failed");
         L.Prepare
           (Engine, Descriptor, Source,
            Backend => (if On_Device then Model_Runner.Backend.Backend_Device
                        else Model_Runner.Backend.Backend_CPU), Repack => Layout,
            Panel_Cache => Panel_Path, Status => Status);
         Assert (E.Is_Ok (Status), "reference fixture prepare failed: " & Status.Code'Image);
         if Expect_Mapped then
            Assert (L.Panels_Cached (Engine) > 0, "reference run did not read the mapped panel cache");
         elsif L."=" (Layout, L.To_Rows) then
            Assert (L.Repacked_Bytes (Engine) > 0, "reference run did not build row panels");
         end if;
         L.Open (Live, Engine, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "reference fixture open failed");
         L.Watch (Live, Observer'Unchecked_Access);
         L.Evaluate (Live, Engine, 1, Actual, Status => Status);
         Assert (E.Is_Ok (Status), "reference evaluation failed: " & Status.Code'Image);
         Assert (Observer.Compared = 834, "reference coverage changed: " & Observer.Compared'Image);
         Ada.Text_IO.Put_Line ("Inkling " & (if Quantized then "Q8" else "F32") & " reference: "
                               & Observer.Elements'Image & " elements, max "
                               & Observer.Maximum'Image);
         Assert (Observer.Different = 0, U.To_String (Observer.First_Failure));
         Watched := Actual;
         L.Watch (Live, null);
         L.Reset (Live);
         L.Evaluate (Live, Engine, 1, Actual, Status => Status);
         Assert (E.Is_Ok (Status) and then Actual = Watched, "grouped inference differs from observed execution");
         if not Quantized and then Fault = Tiny_Model.Inkling_Valid then
            L.Watch (Live, null);
            L.Reset (Live);
            L.Evaluate_Batch (Live, Engine, [1, 1, 1, 1, 1, 1, 1, 1, 1], Actual, Status => Status);
            Assert (E.Is_Ok (Status), "independent batched prefix prefill failed");
            Observer.Compared := 0;
            Observer.Elements := 0;
            Observer.Maximum := 0.0;
            Observer.Squared := 0.0;
            Observer.Different := 0;
            Observer.First_Failure := U.Null_Unbounded_String;
            Observer.First_Route_Failure := U.Null_Unbounded_String;
            Observer.Expected_Position := 9;
            Observer.Recording_File := U.To_Unbounded_String ("fixtures/inkling2/tiny-prefix-f32.tsv");
            L.Watch (Live, Observer'Unchecked_Access);
            L.Evaluate (Live, Engine, 1, Actual, Status => Status);
            Assert (E.Is_Ok (Status), "independent prefix decode failed");
            Assert (Observer.Compared = 834, "prefix activation coverage is incomplete");
            Ada.Text_IO.Put_Line ("Inkling F32 prefix reference: " & Observer.Elements'Image & " elements, max "
                                  & Observer.Maximum'Image);
            Assert (Observer.Different = 0, U.To_String (Observer.First_Failure));
         end if;
         L.Close (Live);
         L.Close (Engine, Status);
         C.Close (Descriptor);
         Model_Runner.Backend.CPU.Close (Team);
      exception
         when others =>
            L.Close (Live);
            L.Close (Engine, Status);
            C.Close (Descriptor);
         Model_Runner.Backend.CPU.Close (Team);
            raise;
      end;
      B.Free (Image);
      if On_Device then
         Model_Runner.Backend.Device.Close;
      end if;
   exception
      when others =>
         B.Free (Image);
         if On_Device then
            Model_Runner.Backend.Device.Close;
         end if;
         raise;
   end Cross_Reference;

   procedure Zero_Controls (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Cross_Reference (False, Fault => Tiny_Model.Inkling_Zero_Controls);
   end Zero_Controls;

   procedure Nonfinite_Weights (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build_Inkling (Image, Fault => Tiny_Model.Inkling_Nonfinite_Weight);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live : L.Session;
         Actual : L.Real_Array (0 .. 15);
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "nonfinite weight fixture framing is invalid");
         L.Prepare (Engine, Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "nonfinite weight fixture did not reach lazy weight evaluation");
         L.Open (Live, Engine, Context => 32, Status => Status);
         Assert (E.Is_Ok (Status), "nonfinite weight fixture did not open");
         L.Evaluate (Live, Engine, 1, Actual, Status => Status);
         Assert (Status.Code = E.Tensor_Non_Finite_Value and then L.Position (Live) = 0,
                 "nonfinite weight was committed or returned the wrong diagnostic: " & Status.Code'Image);
         L.Reset (Live);
         L.Close (Live);
         L.Close (Engine, Status);
         C.Close (Descriptor);
      exception
         when others =>
            L.Close (Live);
            L.Close (Engine, Status);
            C.Close (Descriptor);
            raise;
      end;
      B.Free (Image);
   exception
      when others =>
         B.Free (Image);
         raise;
   end Nonfinite_Weights;

   procedure Cache_Metadata_Identity (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access := null;
      Saved : B.Byte_Array_Access := null;
      First_Mark : Interfaces.Unsigned_64 := 0;
      Status : E.Error_Info;
   begin
      for Changed in Boolean loop
         Tiny_Model.Build_Inkling
           (Image, Fault => (if Changed then Tiny_Model.Inkling_Alternate_Softcap else Tiny_Model.Inkling_Valid));
         declare
            Held : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
            Descriptor : C.Container;
            Engine : aliased L.Model;
            Live : L.Session;
            Actual : L.Real_Array (0 .. 15);
         begin
            C.Reader.Parse (Descriptor, Source, Status => Status);
            Assert (E.Is_Ok (Status), "cache metadata fixture parse failed");
            L.Prepare (Engine, Descriptor, Source, Status => Status);
            Assert (E.Is_Ok (Status), "cache metadata fixture prepare failed");
            L.Open (Live, Engine, Context => 32, Status => Status);
            Assert (E.Is_Ok (Status), "cache metadata fixture open failed");
            if Changed then
               Assert (L.Fingerprint (Engine) /= First_Mark,
                       "same weights under another residual/activation contract shared a model fingerprint");
               L.Adopt (Live, Engine, Saved.all, Status);
               Assert (Status.Code = E.Lifecycle_Cache_Mismatched and then L.Position (Live) = 0,
                       "saved context was adopted under a different activation contract");
            else
               First_Mark := L.Fingerprint (Engine);
               L.Evaluate (Live, Engine, 1, Actual, Status => Status);
               Assert (E.Is_Ok (Status), "cache identity evaluation failed");
               L.Snapshot (Live, Engine, Saved, Status);
               Assert (E.Is_Ok (Status), "cache identity snapshot failed");
            end if;
            L.Close (Live);
            L.Close (Engine, Status);
            C.Close (Descriptor);
         exception
            when others =>
               L.Close (Live);
               L.Close (Engine, Status);
               C.Close (Descriptor);
               raise;
         end;
         B.Free (Image);
      end loop;
      B.Free (Saved);
   exception
      when others =>
         B.Free (Saved);
         B.Free (Image);
         raise;
   end Cache_Metadata_Identity;

   procedure Stable_Router_Picks (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Scores : L.Real_Array (13 .. 140);
      Actual, Expected : L.Real_Array (3 .. 10);
      type Flags is array (Natural range 0 .. 127) of Boolean;
      Taken : Flags;
      Best : Integer;
   begin
      for Pattern in 0 .. 127 loop
         for I in Scores'Range loop
            Scores (I) := (case Pattern is when 0 => 1.0, when 1 => L.Real (I),
              when 2 => -L.Real (I), when 3 => (if I mod 2 = 0 then -0.0 else 0.0),
              when others => L.Real ((Natural (I) * (Pattern + 17) + Pattern * 13) mod 23) - 11.0);
         end loop;
         Taken := [others => False];
         for Slot in Expected'Range loop
            Best := -1;
            for I in Taken'Range loop
               if not Taken (I) and then (Best < 0 or else Scores (Scores'First + L.Element_Count (I)) >
                 Scores (Scores'First + L.Element_Count (Best))) then Best := I; end if;
            end loop;
            Taken (Best) := True; Expected (Slot) := L.Real (Best);
         end loop;
         Model_Runner.Llama.Adapter_Testing.Pick_Experts (Scores, Actual);
         Assert (Actual = Expected, "8-of-128 router changed ordering or tie selection");
      end loop;
   end Stable_Router_Picks;

   procedure Parallel_Convolution_State (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
      Tokens : Model_Runner.Tokenizer.Token_Array (5 .. 68);
      type Caches is array (Positive range <>) of L.Cache_Precision;
      --  Aligned heads make every convolution wide enough for the pool's
      --  normal cost threshold, including dynamic key/value convolution.
      procedure Good (Where : String) is
      begin
         Assert (E.Is_Ok (Status), Where & ": " & Status.Code'Image);
      end Good;
   begin
      for I in Tokens'Range loop Tokens (I) := Model_Runner.Tokenizer.Token_Id ((I - Tokens'First) mod 7 + 1); end loop;
      Tiny_Model.Build_Inkling (Image, Quantized => True, Fault => Tiny_Model.Inkling_Aligned_Heads, Room => 128);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Serial, Pooled : L.Session;
         Team : aliased Model_Runner.Backend.CPU.Pool (3);
         A, Z : L.Real_Array (0 .. 15);
         SA : TT.Real_Array_Access := new L.Real_Array (0 .. 64 * 32 - 1);
         SZ : TT.Real_Array_Access := new L.Real_Array (SA'Range);
         LA : TT.Real_Array_Access := new L.Real_Array (0 .. 64 * 16 - 1);
         LZ : TT.Real_Array_Access := new L.Real_Array (LA'Range);
      begin
         Model_Runner.Backend.CPU.Use_Integer_Activations (True);
         C.Reader.Parse (Descriptor, Source, Status => Status); Good ("parallel convolution parse");
         L.Prepare (Engine, Descriptor, Source, Status => Status); Good ("parallel convolution prepare");
         for Cache of Caches'[L.Exact, L.Transformed_Fourth] loop
            L.Open (Serial, Engine, Context => 96, Cache => Cache, Status => Status); Good ("serial convolution open");
            L.Open (Pooled, Engine, Context => 96, Cache => Cache, Workers => Team'Unchecked_Access,
                    Status => Status); Good ("parallel convolution open");
            L.Keep_States (Serial, 80, Status); Good ("serial convolution checkpoints");
            L.Keep_States (Pooled, 80, Status); Good ("parallel convolution checkpoints");
            L.Evaluate_Batch (Serial, Engine, Tokens, A, States => SA, Every => LA, Status => Status);
            Good ("serial convolution batch");
            L.Evaluate_Batch (Pooled, Engine, Tokens, Z, States => SZ, Every => LZ, Status => Status);
            Good ("parallel convolution batch");
            Assert (A = Z and then SA.all = SZ.all and then LA.all = LZ.all,
                    "channel parallelism changed logits or logical-visit hidden states");
            L.Evaluate (Serial, Engine, 3, A, Status => Status); Good ("serial convolution continuation");
            L.Evaluate (Pooled, Engine, 3, Z, Status => Status); Good ("parallel convolution continuation");
            Assert (A = Z, "channel parallelism changed causal convolution history");
            L.Rewind (Serial, 32, Status); Good ("serial convolution rewind");
            L.Rewind (Pooled, 32, Status); Good ("parallel convolution rewind");
            L.Evaluate_Batch (Serial, Engine, Tokens (5 .. 20), A, Status => Status);
            Good ("serial convolution alternate batch");
            L.Evaluate_Batch (Pooled, Engine, Tokens (5 .. 20), Z, Status => Status);
            Good ("parallel convolution alternate batch");
            Assert (A = Z, "parallel convolution rewind retained another continuation");
            L.Reset (Serial); L.Reset (Pooled);
            L.Evaluate_Batch (Serial, Engine, Tokens, A, Status => Status); Good ("serial convolution reset");
            L.Evaluate_Batch (Pooled, Engine, Tokens, Z, Status => Status); Good ("parallel convolution reset");
            Assert (A = Z, "parallel convolution reset retained stale history");
            L.Close (Serial); L.Close (Pooled);
         end loop;
         L.Close (Engine, Status); Good ("parallel convolution close");
         TT.Free (SA); TT.Free (SZ); TT.Free (LA); TT.Free (LZ); Model_Runner.Backend.CPU.Close (Team);
      exception
         when others =>
            L.Close (Serial); L.Close (Pooled); L.Close (Engine, Status);
            TT.Free (SA); TT.Free (SZ); TT.Free (LA); TT.Free (LZ); Model_Runner.Backend.CPU.Close (Team);
            raise;
      end;
      B.Free (Image);
   exception when others => B.Free (Image); raise;
   end Parallel_Convolution_State;

   procedure Batched_Prefill (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
      Tokens : constant Model_Runner.Tokenizer.Token_Array (7 .. 15) := [3, 4, 1, 5, 2, 7, 3, 6, 1];
   begin
      for Variant in 0 .. 5 loop
         declare
            Quantized : constant Boolean := Variant /= 0;
            Down_Format : constant Model_Runner.GGUF.Tensor_Type :=
              (case Variant is when 2 => Model_Runner.GGUF.Type_IQ4_NL,
               when 3 => Model_Runner.GGUF.Type_Q2_0,
               when 4 => Model_Runner.GGUF.Type_IQ3_S, when 5 => Model_Runner.GGUF.Type_IQ3_XXS,
               when others => Model_Runner.GGUF.Type_Q8_0);
         begin
         Tiny_Model.Build_Inkling (Image, Quantized => Quantized, Down_Format => Down_Format);
         declare
            Held : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
            Descriptor : C.Container;
            Engine : aliased L.Model;
            Live : L.Session;
            Team : aliased Model_Runner.Backend.CPU.Pool (2);
            Actual, Expected, Next : L.Real_Array (0 .. 15);
            H : constant L.Element_Count := (if Quantized then 32 else 8);
            Hidden : L.Real_Array (0 .. H - 1);
            All_Logits : Model_Runner.Tensors.Real_Array_Access := new L.Real_Array'(11 .. 11 + 9 * 16 => -123.0);
            All_States : Model_Runner.Tensors.Real_Array_Access := new L.Real_Array'(13 .. 13 + 9 * H => -123.0);
            Expected_Logits : L.Real_Array (All_Logits.all'Range) := [others => -123.0];
            Expected_States : L.Real_Array (All_States.all'Range) := [others => -123.0];
            Stop : aliased Model_Runner.Cancellation.Token;
            Interrupt : aliased Cancelling_Observer;
            Counter : aliased Replay_Counter;

            procedure Good (Where : String) is
            begin
               Assert (E.Is_Ok (Status), Where & ": " & Status.Code'Image & " " & E.Text_Of (Status, "exception"));
            end Good;
         begin
            Model_Runner.Backend.CPU.Use_Integer_Activations (Quantized);
            C.Reader.Parse (Descriptor, Source, Status => Status);
            Good ("batch parse");
            L.Prepare (Engine, Descriptor, Source, Backend => Model_Runner.Backend.Backend_CPU, Status => Status);
            Good ("batch prepare");
            Assert (Model_Runner.Llama.Adapter_Testing.Device_Expert_Contracts_Match (Engine),
                    "device expert slices lost the prepared activation contract");
            for Cache in L.Exact .. L.Halved loop
               L.Open (Live, Engine, Context => 32, Cache => Cache, Workers => Team'Unchecked_Access, Status => Status);
               Good ("batch open");
               for Token in Tokens'Range loop
                  L.Evaluate (Live, Engine, Tokens (Token), Expected, Status => Status);
                  Good ("scalar baseline");
                  L.Hidden_State (Live, Hidden, Status);
                  Good ("scalar hidden");
                  declare
                     Index : constant Model_Runner.Numerics.Element_Count :=
                       Model_Runner.Numerics.Element_Count (Token - Tokens'First);
                  begin
                     Expected_Logits (11 + Index * 16 .. 11 + (Index + 1) * 16 - 1) := Expected;
                     Expected_States (13 + Index * H .. 13 + (Index + 1) * H - 1) := Hidden;
                  end;
               end loop;
               L.Evaluate (Live, Engine, 5, Next, Status => Status);
               Good ("scalar continuation");
               L.Reset (Live);
               L.Evaluate_Batch (Live, Engine, Tokens, Actual,
                                 States => All_States, Every => All_Logits, Status => Status);
               Good ("batched logits and states");
               Assert (Actual = Expected and then All_Logits.all = Expected_Logits
                       and then All_States.all = Expected_States,
                       "batched prefill changed per-token outputs: " & Quantized'Image & " " & Cache'Image
                       & " logits=" & Boolean'Image (All_Logits.all = Expected_Logits)
                       & " states=" & Boolean'Image (All_States.all = Expected_States));
               L.Evaluate (Live, Engine, 5, Actual, Status => Status);
               Good ("batch continuation");
               Assert (Actual = Next, "batched prefill left different KV or convolution state");
               Model_Runner.Llama.Adapter_Testing.Poison_Scratch
                 (Live, Model_Runner.Numerics.From_Bits (16#7FC0_0001#));
               L.Reset (Live);
               L.Evaluate_Batch (Live, Engine, Tokens (7 .. 10), Actual, Status => Status);
               Good ("first partition");
               L.Evaluate_Batch (Live, Engine, Tokens (11 .. 15), Actual, Status => Status);
               Good ("second partition");
               Assert (Actual = Expected, "partitioning prefill changed the result");
               L.Reset (Live);
               declare
                  Short : Model_Runner.Tensors.Real_Array_Access := new L.Real_Array'(5 .. 5 => -123.0);
               begin
                  L.Evaluate_Batch (Live, Engine, Tokens, Actual, States => Short, Status => Status);
                  Assert (Status.Code = E.Tensor_Shape_Mismatch and then L.Position (Live) = 0
                          and then Short (5) = -123.0, "undersized states committed or wrote output");
                  L.Evaluate_Batch (Live, Engine, Tokens, Actual, Every => Short, Status => Status);
                  Assert (Status.Code = E.Tensor_Shape_Mismatch and then L.Position (Live) = 0
                          and then Short (5) = -123.0, "undersized logits committed or wrote output");
                  Model_Runner.Tensors.Free (Short);
               exception
                  when others =>
                     Model_Runner.Tensors.Free (Short);
                     raise;
               end;
               --  A saved state at the start of the last partition is
               --  enough for a short rewind: only the retained suffix runs.
               L.Reset (Live);
               L.Evaluate_Batch (Live, Engine, Tokens (7 .. 10), Actual, Status => Status);
               Good ("checkpoint first partition");
               L.Evaluate_Batch (Live, Engine, Tokens (11 .. 15), Actual, Status => Status);
               Good ("checkpoint second partition");
               Counter.Tokens := 0;
               L.Watch (Live, Counter'Unchecked_Access);
               L.Rewind (Live, 5, Status);
               L.Watch (Live, null);
               Good ("bounded suffix rewind");
               Assert (Counter.Tokens = 1, "rewind replayed the prefix instead of the retained suffix");
               L.Hidden_State (Live, Hidden, Status);
               Good ("checkpoint hidden state");
               Assert (Hidden = Expected_States (13 + 4 * H .. 13 + 5 * H - 1),
                       "checkpoint rewind restored the wrong normalized state");
               L.Evaluate (Live, Engine, Tokens (12), Actual, Status => Status);
               Good ("checkpoint continuation");
               Assert (Actual = Expected_Logits (11 + 5 * 16 .. 11 + 6 * 16 - 1),
                       "checkpoint continuation differs from full recomputation");
               L.Evaluate (Live, Engine, Tokens (13), Actual, Status => Status);
               Good ("ring checkpoint continuation");
               Counter.Tokens := 0;
               L.Watch (Live, Counter'Unchecked_Access);
               L.Rewind (Live, 5, Status);
               L.Watch (Live, null);
               Good ("older ring checkpoint rewind");
               Assert (Counter.Tokens = 0, "older reachable boundary was replayed instead of restored");
               L.Hidden_State (Live, Hidden, Status);
               Good ("ring checkpoint hidden state");
               Assert (Hidden = Expected_States (13 + 4 * H .. 13 + 5 * H - 1),
                       "ring checkpoint restored the wrong normalized state");
               L.Evaluate (Live, Engine, Tokens (12), Actual, Status => Status);
               Good ("ring checkpoint alternative continuation");
               Assert (Actual = Expected_Logits (11 + 5 * 16 .. 11 + 6 * 16 - 1),
                       "ring checkpoint continuation differs from recomputation");
               --  An explicit conversation boundary survives more decode
               --  calls than the recent-state ring can hold. Restoring it
               --  must do no inference and permit a different continuation.
               L.Reset (Live);
               L.Evaluate_Batch (Live, Engine, Tokens (7 .. 10), Actual, Status => Status);
               Good ("persistent prefix prefill");
               L.Mark_Checkpoint (Live);
               for Index in 11 .. 15 loop
                  L.Evaluate (Live, Engine, Tokens (Index), Actual, Status => Status);
                  Good ("persistent prefix decode");
               end loop;
               Counter.Tokens := 0;
               L.Watch (Live, Counter'Unchecked_Access);
               L.Rewind (Live, 4, Status);
               L.Watch (Live, null);
               Good ("persistent prefix rewind");
               Assert (Counter.Tokens = 0, "marked prefix was evicted by decode calls");
               L.Evaluate (Live, Engine, Tokens (11), Actual, Status => Status);
               Good ("persistent prefix alternative continuation");
               Assert (Actual = Expected_Logits (11 + 4 * 16 .. 11 + 5 * 16 - 1),
                       "marked prefix continuation differs from recomputation");
               --  A cancellation in a repeated layer must commit none of
               --  the batch, and must restore its convolution history.
               L.Reset (Live);
               L.Evaluate (Live, Engine, 3, Actual, Status => Status);
               Good ("before batch cancellation");
               L.Hidden_State (Live, Hidden, Status);
               Good ("hidden before batch cancellation");
               Interrupt.Stop := Stop'Unchecked_Access;
               Interrupt.Reached := False;
               L.Watch (Live, Interrupt'Unchecked_Access);
               L.Evaluate_Batch (Live, Engine, Tokens, Actual, Cancel => Stop'Unchecked_Access, Status => Status);
               Assert (Status.Code = E.Generation_Cancelled and then Interrupt.Reached and then L.Position (Live) = 1,
                       "cancelled batch committed positions");
               Stop.Reset;
               L.Watch (Live, null);
               L.Hidden_State (Live, All_States (13 .. 13 + H - 1), Status);
               Good ("hidden after batch cancellation");
               Assert (All_States (13 .. 13 + H - 1) = Hidden, "cancelled batch changed the committed hidden state");
               L.Evaluate (Live, Engine, 4, Actual, Status => Status);
               Good ("after batch cancellation");
               Assert (Actual = Expected_Logits (27 .. 42), "cancelled batch contaminated continuation");
               L.Close (Live);
            end loop;
            Model_Runner.Tensors.Free (All_Logits);
            Model_Runner.Tensors.Free (All_States);
            L.Close (Engine, Status);
            C.Close (Descriptor);
            Model_Runner.Backend.CPU.Close (Team);
         exception
            when others =>
               L.Close (Live);
               Model_Runner.Tensors.Free (All_Logits);
               Model_Runner.Tensors.Free (All_States);
               L.Close (Engine, Status);
               C.Close (Descriptor);
               Model_Runner.Backend.CPU.Close (Team);
               raise;
         end;
         B.Free (Image);
         end;
      end loop;
      Model_Runner.Backend.CPU.Use_Integer_Activations (False);
   exception
      when others =>
         B.Free (Image);
         Model_Runner.Backend.CPU.Use_Integer_Activations (False);
         raise;
   end Batched_Prefill;

   procedure Reference (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Cross_Reference (False);
   end Reference;

   procedure Quantized_Reference (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Cross_Reference (True);
   end Quantized_Reference;

   procedure Quantized_Panels (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Cache_Path : constant String := "obj/tiny-inkling-reference.panels";
   begin
      Ada.Directories.Create_Path ("obj");
      if Ada.Directories.Exists (Cache_Path) then
         Ada.Directories.Delete_File (Cache_Path);
      end if;
      Cross_Reference (True, Layout => L.To_Rows);
      Cross_Reference (True, Layout => L.To_Rows, Panel_Path => Cache_Path);
      Assert (Ada.Directories.Exists (Cache_Path), "reference panel cache was not persisted");
      Cross_Reference (True, Layout => L.To_Rows, Panel_Path => Cache_Path, Expect_Mapped => True);
   end Quantized_Panels;

   procedure Device_Reference (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
   begin
      Cross_Reference (False, On_Device => True);
   end Device_Reference;

   procedure Long_Context_Reference (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build_Inkling (Image, Room => 2304);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live, Fresh : L.Session;
         Team : aliased Model_Runner.Backend.CPU.Pool (2);
         Observer : aliased Reference_Observer;
         Actual, Expected : L.Real_Array (0 .. 15);
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "long fixture parse failed");
         L.Prepare (Engine, Descriptor, Source, Backend => Model_Runner.Backend.Backend_CPU, Status => Status);
         Assert (E.Is_Ok (Status), "long fixture prepare failed");
         L.Open (Live, Engine, Context => 2304, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "long fixture open failed");
         declare
            Tokens : constant Model_Runner.Tokenizer.Token_Array (1 .. 2199) := [others => 1];
            First : Positive := Tokens'First;
         begin
            while First <= Tokens'Last loop
               declare
                  Last : constant Positive := Positive'Min (First + 127, Tokens'Last);
               begin
                  L.Evaluate_Batch (Live, Engine, Tokens (First .. Last), Actual, Status => Status);
                  Assert (E.Is_Ok (Status), "long batch failed at " & First'Image & ": " & Status.Code'Image);
                  First := Last + 1;
               end;
            end loop;
         end;
         Observer.Expected_Position := 2199;
         Observer.Recording_File := U.To_Unbounded_String ("fixtures/inkling2/tiny-long-prefix-f32.tsv");
         L.Watch (Live, Observer'Unchecked_Access);
         L.Evaluate (Live, Engine, 1, Actual, Status => Status);
         Assert (E.Is_Ok (Status), "long decode failed");
         Assert (Observer.Compared = 834 and then Observer.Different = 0,
                 "long context differs from independent recomputation: " & U.To_String (Observer.First_Failure));
         Ada.Text_IO.Put_Line ("Inkling long prefix reference: " & Observer.Elements'Image
                               & " elements, max " & Observer.Maximum'Image);
         L.Watch (Live, null);
         L.Rewind (Live, 2199, Status);
         Assert (E.Is_Ok (Status), "rewind across local eviction failed");
         L.Evaluate (Live, Engine, 5, Actual, Status => Status);
         Assert (E.Is_Ok (Status), "alternative after eviction failed");
         L.Open (Fresh, Engine, Context => 2304, Status => Status);
         Assert (E.Is_Ok (Status), "fresh long context open failed");
         for Position in 0 .. 2198 loop
            L.Evaluate (Fresh, Engine, 1, Expected, Status => Status);
            Assert (E.Is_Ok (Status), "fresh long prefix failed");
         end loop;
         L.Evaluate (Fresh, Engine, 5, Expected, Status => Status);
         Assert (E.Is_Ok (Status) and then Actual = Expected,
                 "rewind after local eviction differs from a fresh alternative continuation");
         L.Close (Fresh);
         L.Close (Live);
         L.Close (Engine, Status);
         C.Close (Descriptor);
         Model_Runner.Backend.CPU.Close (Team);
      exception
         when others =>
            L.Close (Fresh);
            L.Close (Live);
            L.Close (Engine, Status);
            C.Close (Descriptor);
            Model_Runner.Backend.CPU.Close (Team);
            raise;
      end;
      B.Free (Image);
   exception
      when others =>
         B.Free (Image);
         raise;
   end Long_Context_Reference;

   procedure Checkpoint (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Variable : constant String := "MODEL_RUNNER_INKLING_MODEL";
      Reference_Path : constant String := Ada.Environment_Variables.Value
        ("MODEL_RUNNER_INKLING_REFERENCE", "fixtures/inkling2/q4_k_m-f32-hello");
      Arithmetic : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_ARITH", "f32");
      Backend : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_BACKEND", "cpu");
      On_Device : constant Boolean := Backend in "device" | "hybrid";
      Sharing : constant Boolean := Backend = "device";
      Cache : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_CACHE", "f32");
      Repacking : constant String := Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_REPACK", "none");
      Bounds : Model_Runner.Limits.Model_Limits := Model_Runner.Limits.Default_Model_Limits;
      Status : E.Error_Info;
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Descriptor : C.Container;
      Engine : aliased L.Model;
      Live : L.Session;
      Team : aliased Model_Runner.Backend.CPU.Pool (7);
      Observer : aliased Reference_Observer;
      Doc : aliased J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Actual, Watched : L.Real_Array (0 .. 200057);
   begin
      if not Ada.Environment_Variables.Exists (Variable) then
         Ada.Text_IO.Put_Line ("note: optional Inkling checkpoint comparison needs " & Variable);
         Model_Runner.Backend.CPU.Close (Team);
         return;
      end if;
      Jsonlib.Parsers.Parse
        (Project_Tools.Files.Read_Raw_File (Reference_Path & "/manifest.json"), Doc, Error);
      Assert (Error.Code = Jsonlib.Errors.No_Error, "checkpoint manifest could not be read");
      Observer.Manifest := Doc'Unchecked_Access;
      Assert
        (J.Is_Present (J.Member (Doc, J.Root (Doc), "tensors"))
         and then J.Is_Present (J.Member (Doc, J.Root (Doc), "bundles")),
         "checkpoint comparison requires a tensor-capture manifest, not a comparison-summary manifest");
      Observer.Bundle_Directory := U.To_Unbounded_String (Reference_Path);
      if Ada.Environment_Variables.Exists ("MODEL_RUNNER_INKLING_DUMP") then
         Observer.Dump_Directory := U.To_Unbounded_String
           (Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_DUMP"));
         Ada.Directories.Create_Path (U.To_String (Observer.Dump_Directory));
      end if;
      Assert (Arithmetic in "f32" | "int8", "checkpoint arithmetic must be f32 or int8");
      Assert (Backend in "cpu" | "device" | "hybrid", "checkpoint backend must be cpu, device or hybrid");
      if On_Device then
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open
              (Ready, Budget => 4_294_967_296, Share_Host => Sharing, Tuning_Profile => "none");
            Assert (Ready, "checkpoint Vulkan device is unavailable");
            Model_Runner.Backend.Device.Round_Walks
              (if Arithmetic = "f32" then Model_Runner.Platform.Device.Products.Rounds_None
               else Model_Runner.Platform.Device.Products.Rounds_Every);
         end;
      end if;
      Model_Runner.Backend.CPU.Use_Integer_Activations (Arithmetic = "int8");
      if Ada.Environment_Variables.Value ("MODEL_RUNNER_INKLING_INTEGER_WIDTH", "512") = "256" then
         Assert (not On_Device and then Arithmetic = "int8", "width comparison requires CPU integer execution");
         Model_Runner.Quantization.Integers.Use_Deep_Rows (False);
      end if;
      Model_Runner.Byte_Sources.Files.Open
        (Source, Ada.Environment_Variables.Value (Variable), Status => Status);
      Assert (E.Is_Ok (Status), "checkpoint could not be opened");
      C.Reader.Parse (Descriptor, Source, Status => Status);
      Assert (E.Is_Ok (Status), "checkpoint header could not be read");
      Assert (Repacking in "none" | "rows", "checkpoint repacking must be none or rows");
      if Sharing or else Repacking = "rows" then
         --  Host sharing pins a single arena, within an explicit 24-GiB host budget.
         Bounds.Max_Allocation_Bytes := 24 * 1024 * 1024 * 1024;
         Bounds.Max_Model_Bytes := 24 * 1024 * 1024 * 1024;
      end if;
      L.Prepare
        (Engine, Descriptor, Source, Bounds => Bounds,
         Backend => (if On_Device then Model_Runner.Backend.Backend_Device else Model_Runner.Backend.Backend_CPU),
         Repack => (if Repacking = "rows" then L.To_Rows else L.No_Repack),
         Context => 32, Status => Status);
      Assert (E.Is_Ok (Status), "checkpoint prepare failed: " & Status.Code'Image
              & " " & E.Text_Of (Status, "category") & " requested=" & E.Text_Of (Status, "requested")
              & " limit=" & E.Text_Of (Status, "limit"));
      Assert (Cache in "f32" | "f16", "checkpoint cache must be f32 or f16");
      L.Open (Live, Engine, Context => 32, Workers => Team'Unchecked_Access,
              Cache => (if Cache = "f16" then L.Halved else L.Exact), Status => Status);
      Assert (E.Is_Ok (Status), "checkpoint open failed: " & Status.Code'Image);
      declare
         Tokens : constant J.Node := J.Member (Doc, J.Member (Doc, J.Root (Doc), "input"), "tokens");
         Count : constant Natural := J.Length (Doc, Tokens);
      begin
         Assert (Count > 0, "checkpoint reference contains no input tokens");
         Observer.Expected_Position := Count - 1;
         if Count > 1 then
            declare
               Prefix : Model_Runner.Tokenizer.Token_Array (1 .. Count - 1);
            begin
               for Index in Prefix'Range loop
                  Prefix (Index) := Model_Runner.Tokenizer.Token_Id
                    (J.As_Integer (Doc, J.Element (Doc, Tokens, Index)));
               end loop;
               L.Evaluate_Batch (Live, Engine, Prefix, Actual, Status => Status);
               Assert (E.Is_Ok (Status), "checkpoint batched prefix failed: " & Status.Code'Image);
            end;
         end if;
         L.Watch (Live, Observer'Unchecked_Access);
         L.Evaluate
           (Live, Engine, Model_Runner.Tokenizer.Token_Id (J.As_Integer (Doc, J.Element (Doc, Tokens, Count))),
            Actual, Status => Status);
         Assert (E.Is_Ok (Status), "checkpoint prefix evaluation failed: " & Status.Code'Image
                 & " capability=" & E.Text_Of (Status, "capability") & " category=" & E.Text_Of (Status, "category")
                 & " compared=" & Observer.Compared'Image);
      end;
      Assert (E.Is_Ok (Status), "checkpoint evaluation failed: " & Status.Code'Image);
      declare
         Best : L.Element_Count := Actual'First;
         Observations : constant J.Node := J.Member (Doc, J.Root (Doc), "observations");
      begin
         for Index in Actual'Range loop
            if Actual (Index) > Actual (Best) then
               Best := Index;
            end if;
         end loop;
         Assert (Long_Long_Integer (Best) = J.As_Integer (Doc, J.Member (Doc, Observations, "greedy_next_token")),
                 "checkpoint greedy token differs from the independent reference");
      end;
      if Backend = "cpu" then
         Watched := Actual;
         L.Watch (Live, null);
         L.Reset (Live);
         declare
            Tokens : constant J.Node := J.Member (Doc, J.Member (Doc, J.Root (Doc), "input"), "tokens");
         begin
            for Index in 1 .. J.Length (Doc, Tokens) loop
               L.Evaluate
                 (Live, Engine, Model_Runner.Tokenizer.Token_Id (J.As_Integer (Doc, J.Element (Doc, Tokens, Index))),
                  Actual, Status => Status);
               Assert (E.Is_Ok (Status), "grouped expert evaluation failed: " & Status.Code'Image);
            end loop;
         end;
         Assert (Actual = Watched, "grouped expert execution changed full-checkpoint logits");
         if Cache = "f32" and then Arithmetic = "f32" then
            declare
               package G renames Model_Runner.Generation;
               Golden : J.Document;
               Parse_Status : Jsonlib.Errors.Error_Info;
               Request : G.Request;
               Endings : Model_Runner.Stops.Set;
               Generated : G.Result;
            begin
               Jsonlib.Parsers.Parse
                 (Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/greedy-f32-16.json"),
                  Golden, Parse_Status);
               Assert (Parse_Status.Code = Jsonlib.Errors.No_Error, "independent greedy fixture is invalid");
               Request.Max_Tokens := 16;
               Request.Batch_Size := 16;
               Request.Sampling.Temperature := 0.0;
               Request.Has_Seed := True;
               Request.Seed := 1;
               Request.Retain_Text := True;
               L.Reset (Live);
               G.Generate
                 (Engine, Live, "The capital of France is", Request, Endings,
                  Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null,
                  Outcome => Generated);
               Assert (E.Is_Ok (Generated.Error) and then Generated.Generated_Tokens = 16,
                       "normal native generation did not complete the fixed independent workload");
               Assert (G.Generated_Text (Generated) = J.As_String (Golden, J.Member
                         (Golden, J.Root (Golden), "expected_text")),
                       "sixteen greedy tokens differ from the independent text fixture");
               G.Release (Generated);
            exception
               when others =>
                  G.Release (Generated);
                  raise;
            end;
         end if;
      end if;
      Ada.Text_IO.Put_Line ("Inkling Q4_K_M " & Arithmetic & " reference: " & Observer.Compared'Image & " tensors, "
        & Observer.Elements'Image & " elements, max " & Observer.Maximum'Image & ", RMS "
        & Model_Runner.Numerics.Sqrt (Observer.Squared
          / Model_Runner.Numerics.Wide_Real (Observer.Elements))'Image
        & ", outside tolerance " & Observer.Different'Image
        & ", worst " & U.To_String (Observer.Worst)
        & ", first routing mismatch " & U.To_String (Observer.First_Route_Failure));
      Model_Runner.Quantization.Integers.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
      L.Close (Live);
      L.Close (Engine, Status);
      C.Close (Descriptor);
      Model_Runner.Byte_Sources.Files.Close (Source);
      Model_Runner.Backend.CPU.Close (Team);
      if On_Device then
         Model_Runner.Backend.Device.Close;
      end if;
      Assert (Observer.Compared = 834, "checkpoint activation coverage is incomplete");
      Assert (Observer.Different = 0, U.To_String (Observer.First_Failure));
   exception
      when others =>
         Model_Runner.Quantization.Integers.Use_Deep_Rows (Model_Runner.Backend.CPU.Byte_Products);
         L.Close (Live);
         L.Close (Engine, Status);
         C.Close (Descriptor);
         Model_Runner.Byte_Sources.Files.Close (Source);
         Model_Runner.Backend.CPU.Close (Team);
         if On_Device then
            Model_Runner.Backend.Device.Close;
         end if;
         raise;
   end Checkpoint;

   procedure Prefix_And_Drafting (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package G renames Model_Runner.Generation;
      Image : B.Byte_Array_Access;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build_Inkling (Image);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live, Fresh : L.Session;
         Team : aliased Model_Runner.Backend.CPU.Pool (2);
         Request : G.Request;
         Endings : Model_Runner.Stops.Set;
         First, Reused, Cold, Drafted : G.Result;
         Prompt : constant String := "abababab";
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "generation fixture parse failed");
         L.Prepare (Engine, Descriptor, Source, Backend => Model_Runner.Backend.Backend_CPU,
                    Status => Status);
         Assert (E.Is_Ok (Status), "generation fixture prepare failed");
         L.Open (Live, Engine, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "generation live session failed: " & Status.Code'Image);
         L.Open (Fresh, Engine, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "generation fresh session failed: " & Status.Code'Image);
         Model_Runner.Stops.Open (Endings);
         --  Start with prefill only: the tiny vocabulary emits unknown
         --  tokens whose display spelling does not round-trip as text.
         Request.Max_Tokens := 0;
         Request.Batch_Size := 16;
         Request.Ignore_End := True;
         Request.Add_Beginning := False;
         Request.Sampling.Temperature := 0.0;
         Request.Sampling.Repeat_Penalty := 1.0;
         Request.Has_Seed := True;
         Request.Seed := 1;
         Request.Retain_Text := True;
         G.Generate (Engine, Live, Prompt, Request, Endings,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => First);
         Assert (E.Is_Ok (First.Error), "first generation failed");
         declare
            Continued : constant String := Prompt & "ab";
         begin
            Request.Max_Tokens := 4;
            Request.Reuse_Committed_Prefix := True;
            G.Generate (Engine, Live, Continued, Request, Endings,
              Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Reused);
            Assert (E.Is_Ok (Reused.Error) and then Reused.Reused_Tokens > 0
                    and then G."=" (Reused.Cache_Event, G.Prefix_Extended),
                    "extended conversation did not reuse its committed prefix: " & Reused.Error.Code'Image
                    & " event=" & Reused.Cache_Event'Image & " kept=" & Reused.Reused_Tokens'Image
                    & " first=" & G.Generated_Text (First));
            Request.Reuse_Committed_Prefix := False;
            G.Generate (Engine, Fresh, Continued, Request, Endings,
              Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Cold);
            Assert (E.Is_Ok (Cold.Error) and then G.Generated_Text (Cold) = G.Generated_Text (Reused),
                    "prefix reuse changed the greedy continuation");
            L.Reset (Fresh);
            Request.Draft_Tokens := 4;
            Request.Draft_From_Context := True;
            G.Generate (Engine, Fresh, Continued, Request, Endings,
              Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Drafted);
            Assert (E.Is_Ok (Drafted.Error) and then Drafted.Drafted > 0 and then
                    G.Generated_Text (Cold) = G.Generated_Text (Drafted),
                    "context drafting changed the greedy continuation: " & Drafted.Error.Code'Image
                    & " cold=" & G.Generated_Text (Cold) & " draft=" & G.Generated_Text (Drafted)
                    & " proposed=" & Drafted.Drafted'Image & " kept=" & Drafted.Accepted'Image);
         end;
         G.Release (First);
         G.Release (Reused);
         G.Release (Cold);
         G.Release (Drafted);
         L.Close (Live);
         L.Close (Fresh);
         L.Close (Engine, Status);
         C.Close (Descriptor);
         Model_Runner.Backend.CPU.Close (Team);
      exception
         when others =>
            G.Release (First);
            G.Release (Reused);
            G.Release (Cold);
            G.Release (Drafted);
            L.Close (Live);
            L.Close (Fresh);
            L.Close (Engine, Status);
            C.Close (Descriptor);
            Model_Runner.Backend.CPU.Close (Team);
            raise;
      end;
      B.Free (Image);
   exception
      when others =>
         B.Free (Image);
         raise;
   end Prefix_And_Drafting;

   procedure Device_Pointwise_Reference (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package V renames Model_Runner.Backend.Device;
      package TT renames Model_Runner.Tensors;
      package K renames Model_Runner.Kernels;
      Ready, Done : Boolean;
      Gate_Bytes, Projection_Bytes, Identity_Bytes : B.Byte_Array_Access;
      Gate, Projection : TT.View;
      Input, Value, Raw, Weighted, Output : TT.Real_Array_Access;
      Message, Down_Row, History, Raw_Output : TT.Real_Array_Access;
      Expected_Raw, Expected_Weighted, Expected : L.Real_Array (0 .. 7);
      Status : E.Error_Info;
   begin
      V.Close;
      V.Open (Ready, Tuning_Profile => "none");
      if not Ready then
         Device_Notes.Skip ("for native pointwise projection chaining");
         return;
      end if;
      declare
         Bytes : constant B.Byte_Array := Fixtures.Encode_F32 (Fixtures.Sequence (64, 711, 0.25));
      begin
         B.Allocate (Bytes'Length, Gate_Bytes);
         Gate_Bytes.all := Bytes;
      end;
      declare
         Bytes : constant B.Byte_Array := Fixtures.Encode_F32 (Fixtures.Sequence (64, 891, 0.25));
      begin
         B.Allocate (Bytes'Length, Projection_Bytes);
         Projection_Bytes.all := Bytes;
      end;
      TT.Make (Model_Runner.GGUF.Type_F32, 8, 8, Gate_Bytes, 0, Gate, Status);
      Assert (E.Is_Ok (Status), "pointwise gate view failed");
      TT.Make (Model_Runner.GGUF.Type_F32, 8, 8, Projection_Bytes, 0, Projection, Status);
      Assert (E.Is_Ok (Status), "pointwise output view failed");
      for Count in 1 .. 17 loop
         TT.Allocate (L.Element_Count (Count * 8), Input);
         TT.Allocate (L.Element_Count (Count * 8), Value);
         TT.Allocate (L.Element_Count (Count * 8), Raw);
         TT.Allocate (L.Element_Count (Count * 8), Weighted);
         TT.Allocate (L.Element_Count (Count * 8), Output);
         Input.all := Fixtures.Sequence (L.Element_Count (Count * 8), 124, 0.5);
         Value.all := Fixtures.Sequence (L.Element_Count (Count * 8), 214, 0.5);
         for Observed in Boolean loop
            V.Gate_And_Project (Gate, Projection, Input, Value, Raw, Output,
                                (if Observed then Weighted else null), Done, Status, Count => Count);
            Assert (Done and then E.Is_Ok (Status), "batched pointwise sequence declined a supported shape");
            for Token in 0 .. Count - 1 loop
               declare
                  From : constant L.Element_Count := L.Element_Count (Token * 8);
               begin
                  TT.Mat_Mul_Range (Gate, Input.all (From .. From + 7), 1, Expected_Raw, 0, 7);
                  Expected_Weighted := Expected_Raw;
                  K.Sigmoid (Expected_Weighted);
                  K.Multiply (Expected_Weighted, Value.all (From .. From + 7));
                  TT.Mat_Mul_Range (Projection, Expected_Weighted, 1, Expected, 0, 7);
                  for Index in Expected'Range loop
                     Assert (abs (Raw (From + Index) - Expected_Raw (Index)) <= 1.0E-5
                             and then abs (Output (From + Index) - Expected (Index)) <= 1.0E-5,
                             "batched pointwise sequence differs from native CPU math");
                     if Observed then
                        Assert (abs (Weighted (From + Index) - Expected_Weighted (Index)) <= 1.0E-5,
                                "observer did not receive the actual weighted batch");
                     end if;
                  end loop;
               end;
            end loop;
         end loop;
         TT.Allocate (L.Element_Count (Count * 8), Message);
         TT.Allocate (L.Element_Count (Count * 8), Down_Row);
         TT.Allocate (L.Element_Count (Count * 8), Raw_Output);
         Message.all := Fixtures.Sequence (L.Element_Count (Count * 8), 347, 0.5);
         declare
            Want : L.Real_Array (0 .. L.Element_Count (Count * 8) - 1);
            Want_Gain, Want_Forget, Want_Down : L.Real_Array (0 .. 7);
         begin
            for Token in 0 .. Count - 1 loop
               declare
                  From : constant L.Element_Count := L.Element_Count (Token * 8);
               begin
                  TT.Mat_Mul_Range (Gate, Input.all (From .. From + 7), 1, Want_Down, 0, 7);
                  TT.Mat_Mul_Range (Projection, Want_Down, 1, Want_Gain, 0, 7);
                  TT.Mat_Mul_Range (Gate, Want_Down, 1, Want_Forget, 0, 7);
                  for Index in Want_Down'Range loop
                     declare
                        Gain : constant L.Real := L.Real (Model_Runner.Numerics.Tanh
                          (Model_Runner.Numerics.Wide_Real (Want_Gain (Index))));
                        Forget : constant L.Real := L.Real (Model_Runner.Numerics.Tanh
                          (Model_Runner.Numerics.Wide_Real (Want_Forget (Index))));
                     begin
                        Want (From + Index) := (Value (From + Index) - Forget * Value (From + Index))
                          + Gain * Message (From + Index);
                     end;
                  end loop;
               end;
            end loop;
            V.Control_And_Blend (Gate, Projection, Gate, Input, Value, Message,
                                 Down_Row, Raw, Weighted, Count, Done, Status);
            Assert (Done and then E.Is_Ok (Status), "native device control blend did not execute");
            for Index in Want'Range loop
               Assert (abs (Value (Index) - Want (Index)) <= 1.0E-5, "native device control blend differs");
            end loop;
         end;
         for Tap_Count in 3 .. 4 loop
         declare
            Width : constant L.Element_Count := L.Element_Count (Tap_Count - 1);
            Taps : constant L.Real_Array := Fixtures.Sequence (L.Element_Count (Tap_Count * 8), 718, 0.25);
            Want_History : L.Real_Array (0 .. 8 * Width - 1) := Fixtures.Sequence (8 * Width, 817, 0.25);
            Want : L.Real_Array (0 .. L.Element_Count (Count * 8) - 1);
            Scale : constant L.Real := 1.0 / L.Real (Model_Runner.Numerics.Sqrt
              (Model_Runner.Numerics.Wide_Real (Tap_Count + 1)));
         begin
            TT.Allocate (8 * Width, History);
            History.all := Want_History;
            for Token in 0 .. Count - 1 loop
               declare
                  From : constant L.Element_Count := L.Element_Count (Token * 8);
               begin
                  TT.Mat_Mul_Range (Gate, Input.all (From .. From + 7), 1, Expected_Raw, 0, 7);
                  Expected_Weighted := Expected_Raw; K.Sigmoid (Expected_Weighted);
                  K.Multiply (Expected_Weighted, Value.all (From .. From + 7));
                  TT.Mat_Mul_Range (Projection, Expected_Weighted, 1, Expected, 0, 7);
                  for Index in Expected'Range loop
                     declare
                        Total : L.Real := 0.0;
                     begin
                        for Tap in L.Element_Count range 0 .. Width loop
                           Total := Total + Taps (Index * (Width + 1) + Tap)
                             * (if Tap = Width then Expected (Index) else Want_History (Index * Width + Tap));
                        end loop;
                        Want (From + Index) := (Expected (Index) + Total) * Scale;
                        for Lag in 1 .. Width - 1 loop
                           Want_History (Index * Width + Lag - 1) := Want_History (Index * Width + Lag);
                        end loop;
                        Want_History (Index * Width + Width - 1) := Expected (Index);
                     end;
                  end loop;
               end;
            end loop;
            V.Gate_And_Project (Gate, Projection, Input, Value, Raw, Output, Weighted, Done, Status,
                                Count => Count, Conv_Taps => Taps, Conv_History => History, Raw_Output => Raw_Output);
            Assert (Done and then E.Is_Ok (Status), "native output convolution sequence did not execute");
            for Index in Want'Range loop
               Assert (abs (Output (Index) - Want (Index)) <= 1.0E-5, "native device output convolution differs");
            end loop;
            for Index in Want_History'Range loop
               Assert (abs (History (Index) - Want_History (Index)) <= 1.0E-5,
                       "native device convolution committed incorrect history");
            end loop;
            TT.Free (History);
         end;
         end loop;
         TT.Free (Message); TT.Free (Down_Row); TT.Free (History); TT.Free (Raw_Output);
         if Count = 1 then
            declare
               Gains : constant L.Real_Array (0 .. 7) := Fixtures.Sequence (8, 44, 0.5);
            begin
               K.RMS_Norm (Input.all, Gains, 1.0E-6, Expected_Weighted, K.Binary32_Stages);
               TT.Mat_Mul_Range (Projection, Expected_Weighted, 1, Expected, 0, 7);
               V.Normalize_Output (Projection, Gains, 1.0E-6, Input, Weighted, Output, Done, Status);
               Assert (Done and then E.Is_Ok (Status), "normalization/output device sequence did not execute");
               for Index in Expected'Range loop
                  Assert (abs (Weighted (Index) - Expected_Weighted (Index)) <= 1.0E-5
                          and then abs (Output (Index) - Expected (Index)) <= 1.0E-5,
                          "device normalization/output differs from CPU math");
               end loop;
            end;
         end if;
         TT.Free (Input); TT.Free (Value); TT.Free (Raw); TT.Free (Weighted); TT.Free (Output);
      end loop;
      declare
         Weights : L.Real_Array (0 .. 63) := [others => 0.0];
         Identity : TT.View;
      begin
         for Index in L.Element_Count range 0 .. 7 loop Weights (Index * 8 + Index) := 1.0; end loop;
         declare
            Bytes : constant B.Byte_Array := Fixtures.Encode_F32 (Weights);
         begin
            B.Allocate (Bytes'Length, Identity_Bytes); Identity_Bytes.all := Bytes;
         end;
         TT.Make (Model_Runner.GGUF.Type_F32, 8, 8, Identity_Bytes, 0, Identity, Status);
         Assert (E.Is_Ok (Status), "controller identity fixture failed");
         TT.Allocate (256, Input); TT.Allocate (256, Value); TT.Allocate (256, Message);
         TT.Allocate (256, Down_Row); TT.Allocate (256, Raw); TT.Allocate (256, Weighted);
         Input.all := Fixtures.Sequence (256, 821, 12.0);
         Input (0) := 0.0; Input (1) := 1.0E-7; Input (2) := -1.0E-7;
         Input (3) := 1.0E-4; Input (4) := -1.0E-4; Input (5) := 20.0; Input (6) := -20.0;
         Value.all := [others => 0.0]; Message.all := [others => 1.0];
         V.Control_And_Blend (Identity, Identity, Identity, Input, Value, Message,
                              Down_Row, Raw, Weighted, 32, Done, Status);
         Assert (Done and then E.Is_Ok (Status), "accurate controller pipeline did not execute");
         for Index in Value.all'Range loop
            declare
               Want : constant L.Real := L.Real (Model_Runner.Numerics.Tanh
                 (Model_Runner.Numerics.Wide_Real (Raw (Index))));
            begin
               Assert ((if Want = 0.0 then Value (Index) = 0.0
                        else Model_Runner.Numerics.Bits (Value (Index)) = Model_Runner.Numerics.Bits (Want)),
                       "controller tanh differs from widened host arithmetic at" & Index'Image);
            end;
         end loop;
         TT.Free (Input); TT.Free (Value); TT.Free (Message);
         TT.Free (Down_Row); TT.Free (Raw); TT.Free (Weighted);
      end;
      V.Close;
      B.Free (Gate_Bytes);
      B.Free (Projection_Bytes);
      B.Free (Identity_Bytes);
   exception
      when others =>
         TT.Free (Message); TT.Free (Down_Row); TT.Free (History); TT.Free (Raw_Output);
         TT.Free (Input);
         TT.Free (Value);
         TT.Free (Raw);
         TT.Free (Weighted);
         TT.Free (Output);
         V.Close;
         B.Free (Gate_Bytes);
         B.Free (Projection_Bytes);
         B.Free (Identity_Bytes);
         raise;
   end Device_Pointwise_Reference;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("native Inkling");
   end Name;

   procedure Grouped_Draft_Arithmetic (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      package Inspect renames Model_Runner.Llama.Adapter_Testing;
      Widths : constant array (1 .. 3) of L.Element_Count := [64, 128, 256];
      Status : E.Error_Info;
      Good : Boolean;
      function FMA (X, Y, Z : L.Real) return L.Real
        with Import, Convention => C, External_Name => "fmaf";
   begin
      if not Model_Runner.Platform.Byte_Products then return; end if;
      for Width of Widths loop
         declare
            Queries : constant L.Real_Array := Fixtures.Sequence (4 * Width, 9107, 0.9);
            Key : constant L.Real_Array := Fixtures.Sequence (Width, 1149, 0.9);
            Actual, Expected : L.Real_Array (9 .. 12);
            Weight : TT.View;
         begin
            TT.Make (Model_Runner.GGUF.Type_F32, 4, Width, Queries (Queries'First)'Address,
                     B.Byte_Count (Queries'Length) * 4, 0, Weight, Status);
            Assert (E.Is_Ok (Status), "grouped draft view"); Weight.Reference_Activations := True;
            TT.Mat_Mul_Range_Float (Weight, Key, 1, Expected, 0, 3, Good);
            Assert (Good, "draft scalar reference unavailable");
            for Many in L.Element_Count range 1 .. 4 loop
               Inspect.Grouped_Draft_Dots (Queries, Key, Width, Many, Actual);
               for I in L.Element_Count range 0 .. Many - 1 loop
                  Assert (Model_Runner.Numerics.Bits (Actual (9 + I)) = Model_Runner.Numerics.Bits (Expected (9 + I)),
                          "grouped draft dot changed reference fold");
               end loop;
               declare
                  Gains : constant L.Real_Array := [0.0, -0.5, 0.25, 1.0];
                  Into : L.Real_Array (13 .. 13 + 4 * (Width + 16) - 1) := [others => 0.125];
                  Want : L.Real_Array (Into'Range) := Into;
               begin
                  for Member in L.Element_Count range 0 .. Many - 1 loop
                     for Channel in L.Element_Count range 0 .. Width - 1 loop
                        Want (13 + Member * (Width + 16) + Channel) :=
                          FMA (Key (Key'First + Channel), Gains (Gains'First + Member), 0.125);
                     end loop;
                  end loop;
                  Inspect.Grouped_Draft_Values (Key, Gains, Into, Width + 16, Many);
                  Assert (Into = Want, "grouped draft value FMA changed results or touched guards");
               end;
            end loop;
         end;
      end loop;
   end Grouped_Draft_Arithmetic;

   procedure Draft_Vector_Arithmetic (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Inspect renames Model_Runner.Llama.Adapter_Testing;
   begin
      for Length in L.Element_Count range 0 .. 65 loop
         for Shift in 0 .. 2 loop
            declare
               Values : L.Real_Array (7 .. 7 + Length + 3) := [others => 999.0];
               Expected : L.Real_Array (Values'Range) := Values;
               Up : L.Real_Array (13 .. 13 + Length + 3) := [others => 0.25];
               Subtract : constant L.Real := L.Real (Shift) * 0.125;
            begin
               for I in L.Element_Count range 0 .. Length - 1 loop
                  Values (7 + I) := L.Real (Integer (I * 997 mod 1024) - 512) * 0.25;
                  Expected (7 + I) := Inspect.Scalar_Exp (Values (7 + I) - Subtract);
               end loop;
               Inspect.Vector_Exp (Values (7 .. 7 + Length - 1), Subtract);
               for I in Values'Range loop
                  Assert (Model_Runner.Numerics.Bits (Values (I)) = Model_Runner.Numerics.Bits (Expected (I)),
                          "vector exponential changed reference rounding or guards");
               end loop;
               for I in L.Element_Count range 0 .. Length - 1 loop
                  Values (7 + I) := L.Real (Integer (I * 997 mod 1024) - 512) * 0.25;
                  Up (13 + I) := L.Real (Integer (I mod 9) - 4) * 0.125;
                  Expected (7 + I) :=
                    (Values (7 + I) / (1.0 + Inspect.Scalar_Exp (-Values (7 + I)))) * Up (13 + I);
               end loop;
               Inspect.Vector_Activate (Values (7 .. 7 + Length - 1), Up (13 .. 13 + Length - 1));
               for I in Values'Range loop
                  Assert (Model_Runner.Numerics.Bits (Values (I)) = Model_Runner.Numerics.Bits (Expected (I)),
                          "vector activation changed reference rounding or guards");
               end loop;
            end;
         end loop;
      end loop;
      declare
         Edge : constant L.Real_Array :=
           [-0.0, 0.0, -104.0, -104.00000762939453, -103.99999237060547, -88.72283935546875,
            -87.0, 88.72283935546875, 104.0, 104.125, -0.125, 0.125, -1.0, 1.0, -1000.0, 1000.0];
         Values : L.Real_Array (Edge'Range) := Edge;
         Up : constant L.Real_Array (Edge'Range) := [others => -0.25];
      begin
         Inspect.Vector_Exp (Values, 0.0);
         for I in Edge'Range loop
            Assert (Model_Runner.Numerics.Bits (Values (I)) =
                    Model_Runner.Numerics.Bits (Inspect.Scalar_Exp (Edge (I) - 0.0)),
                    "exponential saturation or signed zero changed");
         end loop;
         Values := Edge; Inspect.Vector_Activate (Values, Up);
         for I in Edge'Range loop
            Assert (Model_Runner.Numerics.Bits (Values (I)) =
                    Model_Runner.Numerics.Bits ((Edge (I) / (1.0 + Inspect.Scalar_Exp (-Edge (I)))) * Up (I)),
                    "activation saturation or signed zero changed");
         end loop;
      end;
      for Width in L.Element_Count range 1 .. 4 loop
         for Position in 0 .. 5 loop
            declare
               D : constant L.Element_Count := Width * 32;
               Values : L.Real_Array (11 .. 11 + 3 * D - 1);
               Expected : L.Real_Array (Values'Range);
            begin
               for I in Values'Range loop Values (I) := L.Real (I mod 37) / 64.0; end loop;
               Expected := Values;
               Inspect.Rotation (Expected, 3, D, Position * 1023, 10000.0, False);
               Inspect.Rotation (Values, 3, D, Position * 1023, 10000.0, True);
               for I in Values'Range loop
                  Assert (Model_Runner.Numerics.Bits (Values (I)) = Model_Runner.Numerics.Bits (Expected (I)),
                          "reused rotary table changed angle/FMA order");
               end loop;
            end;
         end loop;
      end loop;
   end Draft_Vector_Arithmetic;

   procedure Compact_Features_And_Packing (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      package Inspect renames Model_Runner.Llama.Adapter_Testing;
      package CPU renames Model_Runner.Backend.CPU;
      use type System.Address;
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build_Inkling (Image, Quantized => True); CPU.Use_Integer_Activations (True);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         A, Control : L.Session;
         Team : aliased CPU.Pool (2);
         Tokens : constant Model_Runner.Tokenizer.Token_Array (3 .. 10) := [1, 3, 4, 2, 7, 3, 6, 1];
         Layers : constant L.Feature_Layers := [5, 23, 41, 48];
         Features, Expected_Features : TT.Real_Array_Access := new L.Real_Array (7 .. 7 + 8 * 4 * 32 - 1);
         Every : TT.Real_Array_Access := new L.Real_Array (11 .. 11 + 8 * 16 - 1);
         Read_Row : TT.Real_Array_Access := new L.Real_Array (9 .. 24);
         Row, Expected : L.Real_Array (0 .. 15);
         Winners : Model_Runner.Tokenizer.Token_Array (5 .. 12);
         Address : System.Address;
         Stop : aliased Model_Runner.Cancellation.Token;
         procedure Good (Where : String) is
         begin Assert (E.Is_Ok (Status), Where & ": " & Status.Code'Image); end Good;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status); Good ("compact parse");
         L.Prepare (Engine, Descriptor, Source, Status => Status); Good ("compact prepare");
         L.Open (A, Engine, 32, Workers => Team'Unchecked_Access, Status => Status); Good ("compact open");
         L.Open (Control, Engine, 32, Workers => Team'Unchecked_Access, Status => Status); Good ("compact control");
         L.Evaluate_Features (Control, Engine, Tokens, Layers, Expected_Features, Expected, Every, Status => Status);
         Good ("complete feature reference");
         Assert (Inspect.Plan_Slots (A) = L.Config (Engine).Inkling.Runtime_Layers,
                 "CPU route plans still share physical-layer slots across visits");
         L.Evaluate_Feature_Winners (A, Engine, Tokens, Layers, Features, Row, Winners, 0, Status => Status);
         Good ("compact winners");
         Assert (Row = Expected and then Features.all = Expected_Features.all, "compact features/final logits differ");
         Assert (not Inspect.Has_Head_Rows (A), "compact verification allocated complete batch logits");
         for I in Winners'Range loop
            declare
               Base : constant L.Element_Count := Every.all'First + L.Element_Count (I - Winners'First) * 16;
               Best : L.Element_Count := 1;
            begin
               for J in L.Element_Count range 2 .. 15 loop
                  if Every (Base + J) > Every (Base + Best) then Best := J; end if;
               end loop;
               Assert (Winners (I) = Model_Runner.Tokenizer.Token_Id (Best), "compact greedy winner differs");
               L.Verification_Logits (A, Engine, I - Winners'First, Read_Row, Status); Good ("accepted row");
               Assert (Read_Row.all = Every.all (Base .. Base + 15), "rejected-proposal continuation row differs");
            end;
         end loop;
         Address := Inspect.Mixture_Storage (A);
         Assert (Address /= System.Null_Address, "shared packing was not retained");
         L.Reset (A);
         Assert (Inspect.Mixture_Storage (A) = Address, "reset released reusable shared packing");
         L.Evaluate_Feature_Winners (A, Engine, Tokens, Layers, Features, Row, Winners, Status => Status);
         Good ("reused compact batch");
         Assert (Inspect.Mixture_Storage (A) = Address, "same-sized evaluation reallocated shared packing");
         L.Reset (A); L.Reset (Control); Stop.Request;
         L.Evaluate_Feature_Winners
           (A, Engine, Tokens, Layers, Features, Row, Winners, Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then L.Position (A) = 0
           and then (for all V of Features.all => V = 0.0)
           and then (for all V of Winners => V = Model_Runner.Tokenizer.No_Token),
           "compact cancellation leaked state");
         Stop.Reset;
         L.Verification_Logits (A, Engine, 0, Read_Row, Status);
         Assert (E.Is_Error (Status), "cancelled compact batch exposed a usable row");
         L.Close (A);
         Assert (Inspect.Mixture_Storage (A) = System.Null_Address, "close leaked shared packing");
         Assert (Inspect.Plan_Slots (A) = 0, "close retained logical scheduling slots");
         L.Close (Control); L.Close (Engine, Status); C.Close (Descriptor); CPU.Close (Team);
         TT.Free (Features); TT.Free (Expected_Features); TT.Free (Every); TT.Free (Read_Row);
      exception
         when others =>
            L.Close (A); L.Close (Control); L.Close (Engine, Status); C.Close (Descriptor); CPU.Close (Team);
            TT.Free (Features); TT.Free (Expected_Features); TT.Free (Every); TT.Free (Read_Row); raise;
      end;
      CPU.Use_Integer_Activations (False); B.Free (Image);
   exception
      when others => CPU.Use_Integer_Activations (False); B.Free (Image); raise;
   end Compact_Features_And_Packing;

   procedure Logical_Feature_Capture (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
      function Golden (Key : String; Width : L.Element_Count) return L.Real_Array is
         File : Ada.Text_IO.File_Type;
         Result : L.Real_Array (0 .. Width - 1);
      begin
         Ada.Text_IO.Open (File, Ada.Text_IO.In_File, "fixtures/inkling2/tiny-f32.tsv");
         while not Ada.Text_IO.End_Of_File (File) loop
            declare
               Line : constant String := Ada.Text_IO.Get_Line (File);
               Prefix : constant String := Key & ASCII.HT;
               From : Positive := Prefix'Length + 1;
               Last : Natural;
            begin
               if Line'Length >= Prefix'Length and then Line (1 .. Prefix'Length) = Prefix then
                  for I in Result'Range loop
                     Last := Ada.Strings.Fixed.Index (Line, " ", From => From);
                     if Last = 0 then Last := Line'Last + 1; end if;
                     Result (I) := L.Real'Value (Line (From .. Last - 1)); From := Last + 1;
                  end loop;
                  Ada.Text_IO.Close (File); return Result;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (File); Assert (False, "missing independent feature golden " & Key); return Result;
      exception
         when others => if Ada.Text_IO.Is_Open (File) then Ada.Text_IO.Close (File); end if; raise;
      end Golden;
   begin
      Tiny_Model.Build_Inkling (Image);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Live, Fresh : L.Session;
         Team : aliased Model_Runner.Backend.CPU.Pool (2);
         Stop : aliased Model_Runner.Cancellation.Token;
         Interrupt : aliased Cancelling_Observer;
         Layers : constant L.Feature_Layers (3 .. 6) := [5, 23, 41, 48];
         Tokens : constant Model_Runner.Tokenizer.Token_Array (4 .. 6) := [1, 2, 3];
         H : constant L.Element_Count := 8;
         Span : constant L.Element_Count := 4 * H;
         Features : TT.Real_Array_Access := new L.Real_Array (13 .. 14 + 3 * Span);
         Scalar : TT.Real_Array_Access := new L.Real_Array (7 .. 6 + Span);
         Row, Expected : L.Real_Array (0 .. 15);
         Hidden : L.Real_Array (0 .. H - 1);
         procedure Good (Where : String) is
         begin
            Assert (E.Is_Ok (Status), Where & ": " & Status.Code'Image);
         end Good;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status); Good ("capture parse");
         L.Prepare (Engine, Descriptor, Source, Status => Status); Good ("capture prepare");
         L.Open (Live, Engine, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Good ("capture open");
         L.Open (Fresh, Engine, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Good ("capture control");
         Features.all := [others => 123.0];
         L.Evaluate_Features (Live, Engine, [1], Layers, Scalar, Row, Status => Status); Good ("capture goldens");
         for Slot in L.Element_Count range 0 .. 3 loop
            declare
               Key : constant String :=
                 (case Slot is when 0 => "l_out-4", when 1 => "l_out-28",
                  when 2 => "l_out-46", when others => "result_norm");
               Values : constant L.Real_Array := Golden (Key, H);
            begin
               for I in Values'Range loop
                  Assert (abs (Scalar (Scalar.all'First + Slot * H + I) - Values (I))
                            <= 1.0E-5 + abs (Values (I)) * 2.0E-5,
                          "captured another logical visit/stage: " & Key);
               end loop;
            end;
         end loop;
         L.Reset (Live);
         L.Evaluate_Features (Live, Engine, Tokens, Layers,
                              Features.all (14 .. 13 + 3 * Span)'Unrestricted_Access, Row, Status => Status);
         Good ("capture batch");
         for Token in Tokens'Range loop
            L.Evaluate_Features (Fresh, Engine, [Tokens (Token)], Layers, Scalar, Expected, Status => Status);
            Good ("capture scalar");
            Assert (Features.all (14 + L.Element_Count (Token - Tokens'First) * Span
              .. 13 + L.Element_Count (Token - Tokens'First + 1) * Span) = Scalar.all,
                    "batched capture differs from scalar prefixes");
         end loop;
         Assert (Row = Expected and then L.Position (Live) = 3, "capture changed logits or commit count");
         L.Hidden_State (Live, Hidden, Status); Good ("capture final norm");
         Assert (Features.all (14 + 2 * Span + 3 * H .. 13 + 3 * Span) = Hidden,
                 "tap48 is not the normalized output input");
         Assert (Features (Features.all'First) = 123.0 and then Features (Features.all'Last) = 123.0,
                 "capture overwrote caller guards");
         L.Reset (Live); Features.all := [others => 123.0];
         L.Evaluate_Features (Live, Engine, [1], [5, 5], Features, Row, Status => Status);
         Assert (Status.Code = E.Tensor_Shape_Mismatch and then L.Position (Live) = 0
                   and then (for all V of Features.all => V = 123.0), "duplicate feature taps were not atomic");
         L.Evaluate_Features (Live, Engine, [1], [49], Features, Row, Status => Status);
         Assert (Status.Code = E.Tensor_Shape_Mismatch and then L.Position (Live) = 0,
                 "invalid feature tap advanced target");
         L.Evaluate_Features (Live, Engine, [1], Layers,
                              Scalar.all (7 .. Scalar.all'Last - 1)'Unrestricted_Access, Row, Status => Status);
         Assert (Status.Code = E.Tensor_Shape_Mismatch and then L.Position (Live) = 0,
                 "short feature rows advanced target");
         Interrupt.Stop := Stop'Unchecked_Access; Interrupt.Reached := False;
         L.Watch (Live, Interrupt'Unchecked_Access);
         L.Evaluate_Features (Live, Engine, Tokens, Layers,
                              Features.all (14 .. 13 + 3 * Span)'Unrestricted_Access, Row,
                              Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then Interrupt.Reached and then L.Position (Live) = 0,
                 "cancelled feature batch committed");
         Assert ((for all V of Features.all (14 .. 13 + 3 * Span) => V = 0.0)
                   and then Features (Features.all'First) = 123.0 and then Features (Features.all'Last) = 123.0,
                 "cancelled feature batch exposed partial rows");
         Stop.Reset; L.Watch (Live, null);
         L.Evaluate (Live, Engine, 1, Row, Status => Status); Good ("ordinary evaluation after capture cancellation");
         L.Reset (Fresh); L.Evaluate (Fresh, Engine, 1, Expected, Status => Status); Good ("fresh capture control");
         Assert (Row = Expected, "feature cancellation contaminated target state");
         TT.Free (Features); TT.Free (Scalar); L.Close (Live); L.Close (Fresh); L.Close (Engine, Status);
         C.Close (Descriptor); Model_Runner.Backend.CPU.Close (Team);
      exception
         when others => TT.Free (Features); TT.Free (Scalar); L.Close (Live); L.Close (Fresh); L.Close (Engine, Status);
            C.Close (Descriptor); Model_Runner.Backend.CPU.Close (Team); raise;
      end;
      B.Free (Image);
   exception
      when others => B.Free (Image); raise;
   end Logical_Feature_Capture;

   function Read_Draft_Data (Path : String) return L.Real_Array is
      Raw : constant String := Project_Tools.Files.Read_Raw_File (Path);
      Bytes : B.Byte_Array (1 .. B.Byte_Count (Raw'Length));
      Result : L.Real_Array (0 .. L.Element_Count (Raw'Length / 4) - 1);
      Good : Boolean;
   begin
      for I in Raw'Range loop Bytes (B.Byte_Count (I - Raw'First + 1)) := B.Byte (Character'Pos (Raw (I))); end loop;
      for I in Result'Range loop
         Result (I) := B.Get_F32 (Bytes, B.Byte_Count (I) * 4, Good);
         Assert (Good, "short DSpark golden " & Path);
      end loop;
      return Result;
   end Read_Draft_Data;

   function Draft_Golden (Name : String) return L.Real_Array is
     (Read_Draft_Data ("fixtures/inkling2/dspark-tiny/" & Name));

   procedure Compare_Draft
     (Name : String; Values : L.Real_Array; Directory : String := "fixtures/inkling2/dspark-tiny") is
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Bytes : B.Byte_Array (1 .. 4096);
      Status : E.Error_Info;
      Done : L.Element_Count := 0;
      Worst : L.Real := 0.0;
   begin
      Model_Runner.Byte_Sources.Files.Open (Source, Directory & "/" & Name & ".f32", Status => Status);
      Assert (E.Is_Ok (Status), "DSpark golden open " & Name);
      Assert (Source.Size = B.Byte_Count (Values'Length) * 4, "DSpark golden shape " & Name);
      while Done < Values'Length loop
         declare
            Count : constant L.Element_Count := L.Element_Count'Min (1024, Values'Length - Done);
            Good : Boolean;
            Expected : L.Real;
         begin
            Source.Read (B.Byte_Count (Done) * 4, Bytes (1 .. B.Byte_Count (Count) * 4), Status);
            Assert (E.Is_Ok (Status), "DSpark golden read " & Name);
            for I in 0 .. Count - 1 loop
               Expected := B.Get_F32 (Bytes, B.Byte_Count (I) * 4, Good);
               Assert (Good, "DSpark golden short float " & Name);
               Worst := L.Real'Max (Worst, abs (Values (Values'First + Done + I) - Expected));
               if abs (Values (Values'First + Done + I) - Expected) > 1.0E-5 + 2.0E-5 * abs (Expected) then
                  Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                    "DSpark first mismatch " & Name & L.Element_Count'Image (Done + I)
                    & " got" & Values (Values'First + Done + I)'Image & " expected" & Expected'Image);
               end if;
               Assert (abs (Values (Values'First + Done + I) - Expected) <= 1.0E-5 + 2.0E-5 * abs (Expected),
                       "DSpark golden " & Name & L.Element_Count'Image (Done + I)
                       & ": " & Values (Values'First + Done + I)'Image
                       & " expected" & Expected'Image & " worst" & Worst'Image);
            end loop;
            Done := Done + Count;
         end;
      end loop;
      Model_Runner.Byte_Sources.Files.Close (Source);
   exception
      when others => Model_Runner.Byte_Sources.Files.Close (Source); raise;
   end Compare_Draft;

   type Draft_Observer is new L.Watcher with record
      Dump_Directory : U.Unbounded_String;
      Directory : U.Unbounded_String := U.To_Unbounded_String ("fixtures/inkling2/dspark-tiny");
      Checked : Natural := 0;
   end record;
   overriding procedure Note
     (Item : in out Draft_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count);
   overriding procedure Note_State
     (Item : in out Draft_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array);
   overriding procedure Note
     (Item : in out Draft_Observer; Which : String; Values : L.Real_Array; Rows : L.Element_Count) is
      pragma Unreferenced (Rows);
   begin
      if U.Length (Item.Dump_Directory) > 0 and then Which /= "" then
         Dump_Activation (U.To_String (Item.Dump_Directory), Which & "-input", Values);
      end if;
   end Note;
   overriding procedure Note_State
     (Item : in out Draft_Observer; Which : String; Physical, Logical : Natural;
      Visit : Positive; Position : Natural; Values : L.Real_Array)
   is
      pragma Unreferenced (Logical, Visit, Position);
      Name : constant String := Which
        & (if Which in "kcur_injected" | "vcur_injected"
           then "-" & Ada.Strings.Fixed.Trim (Physical'Image, Ada.Strings.Both) else "");
   begin
      if U.Length (Item.Dump_Directory) > 0 then
         Dump_Activation (U.To_String (Item.Dump_Directory), Name, Values);
      else
         Compare_Draft (Name, Values, U.To_String (Item.Directory));
      end if;
      Item.Checked := Item.Checked + 1;
   end Note_State;

   procedure DSpark_Metadata (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Original : constant String := Project_Tools.Files.Read_Raw_File
        (Tiny_Model.DSpark_Fixture);
      procedure Refuse (Key : String; Offset : Natural; Byte : B.Byte; Expected : E.Error_Code) is
         Held : aliased B.Byte_Array := [1 .. B.Byte_Count (Original'Length) => 0];
         At_Key : constant Natural := Ada.Strings.Fixed.Index (Original, Key);
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Settings : L.Configuration;
         Status : E.Error_Info;
      begin
         Assert (At_Key > 0, "missing fault key " & Key);
         for I in Original'Range loop Held (B.Byte_Count (I)) := B.Byte (Character'Pos (Original (I))); end loop;
         Held (B.Byte_Count (At_Key + Offset)) := Byte;
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "malformed metadata fixture lost GGUF structure " & Key);
         L.Read_Config (Descriptor, Settings => Settings, Status => Status);
         Assert (Status.Code = Expected, "DSpark fault " & Key & " got " & Status.Code'Image);
      end Refuse;
   begin
      Refuse ("dflash.block_size", String'("dflash.block_size")'Length + 4, 7, E.Arch_Invalid_Metadata);
      Refuse ("dflash.block_count", String'("dflash.block_count")'Length + 4, 2, E.Arch_Invalid_Metadata);
      Refuse ("dflash.target_layers", String'("dflash.target_layers")'Length + 16, 6, E.Arch_Invalid_Metadata);
      Refuse ("dflash.has_markov_context", String'("dflash.has_markov_context")'Length + 4, 0,
              E.Arch_Unsupported_Feature);
      Refuse ("dflash.sample_from_anchor", String'("dflash.sample_from_anchor")'Length + 4, 1,
              E.Arch_Unsupported_Feature);
      Refuse ("dflash.has_confidence_head", String'("dflash.has_confidence_head")'Length + 4, 1,
              E.Arch_Unsupported_Feature);
      Refuse ("markov_w2.weight", 0, Character'Pos ('n'), E.Arch_Missing_Tensor);
      Refuse ("joint_proj.weight", String'("joint_proj.weight")'Length + 20, 1, E.Arch_Invalid_Tensor_Format);
   end DSpark_Metadata;

   procedure Native_BF16_Dots (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      package N renames Model_Runner.Numerics;
      Raw : constant String := Project_Tools.Files.Read_Raw_File ("fixtures/inkling2/dspark-bf16/weights.bf16");
      Payload : B.Byte_Array (1 .. B.Byte_Count (Raw'Length) + 7) := [others => 99];
      Input : constant L.Real_Array := Read_Draft_Data ("fixtures/inkling2/dspark-bf16/input.f32");
      Expected : constant L.Real_Array := Read_Draft_Data ("fixtures/inkling2/dspark-bf16/expected.f32");
      Output : L.Real_Array (7 .. 23) := [others => 123.0];
      Weight : TT.View;
      Handled : Boolean;
   begin
      if not Model_Runner.Platform.Brain_Products or else not Model_Runner.Platform.Byte_Products then
         return;
      end if;
      for I in Raw'Range loop Payload (3 + B.Byte_Count (I)) := B.Byte (Character'Pos (Raw (I))); end loop;
      Weight :=
        (Format => Model_Runner.GGUF.Type_BF16, Rows => 5, Columns => 256,
         Role => TT.Role_Other, Reference_Activations => True, Scales => null,
         Base => Payload (1)'Address, Span => Payload'Length, Offset => 3,
         Length => B.Byte_Count (Raw'Length), Interleaved => False);
      TT.Use_Deep_Products (True, Brain => True);
      TT.Mat_Mul_Range_Float (Weight, Input, 3, Output, 0, 4, Handled);
      Assert (Handled, "native BF16 dot declined");
      for I in Expected'Range loop
         Assert (N.Bits (Output (Output'First + I)) = N.Bits (Expected (I)),
                 "native BF16 dot differs from pinned kernel" & I'Image);
      end loop;
      Assert (Output (22) = 123.0 and then Output (23) = 123.0, "BF16 output guard overwritten");
      Output := [others => 123.0];
      TT.Mat_Mul_Range_Float (Weight, Input, 3, Output, 1, 3, Handled);
      Assert (Handled, "BF16 partial rows declined");
      for Vector in L.Element_Count range 0 .. 2 loop
         for Row in L.Element_Count range 0 .. 4 loop
            Assert (Output (7 + Vector * 5 + Row) =
                      (if Row in 1 .. 3 then Expected (Vector * 5 + Row) else 123.0),
                    "BF16 partial row or vector stride");
         end loop;
      end loop;
      TT.Use_Deep_Products (False);
      declare
         Rounded : L.Real_Array := Input;
      begin
         for Value of Rounded loop
            declare
               Bits : constant Interfaces.Unsigned_32 := N.Bits (Value);
            begin
               Value := N.From_Bits
                 ((Bits + 16#7FFF# + (Interfaces.Shift_Right (Bits, 16) and 1)) and 16#FFFF_0000#);
            end;
         end loop;
         TT.Mat_Mul_Range_Float (Weight, Rounded, 3, Output, 0, 4, Handled);
         Assert (Handled, "BF16 fallback declined");
         for I in Expected'Range loop
            Assert (abs (Output (7 + I) - Expected (I)) <= 1.0E-5 + 2.0E-5 * abs (Expected (I)),
                    "BF16 fallback exceeds primitive bound");
         end loop;
      end;
      TT.Use_Deep_Products (Model_Runner.Platform.Byte_Products, Brain => Model_Runner.Platform.Brain_Products);
   exception
      when others =>
         TT.Use_Deep_Products (Model_Runner.Platform.Byte_Products, Brain => Model_Runner.Platform.Brain_Products);
         raise;
   end Native_BF16_Dots;

   procedure Native_DSpark (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      package CPU renames Model_Runner.Backend.CPU;
      Image : B.Byte_Array_Access := null;
      Draft_Bytes : Model_Runner.Byte_Sources.Files.File_Source;
      Draft_Info : C.Container;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build_Inkling (Image, Quantized => True);
      CPU.Use_Integer_Activations (True);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Descriptor : C.Container;
         Engine : aliased L.Model;
         Draft : aliased L.Model;
         Live, Scalar : L.Session;
         Team : aliased CPU.Pool (2);
         Observer : aliased Draft_Observer;
         Features : TT.Real_Array_Access := new L.Real_Array'(Draft_Golden ("features.f32"));
         All_Logits, Again : TT.Real_Array_Access := new L.Real_Array (7 .. 118);
         Proposals, Repeated : Model_Runner.Tokenizer.Token_Array (3 .. 9);
         Expected : constant Model_Runner.Tokenizer.Token_Array (3 .. 9) := [7, 7, 7, 7, 7, 6, 6];
         Row : L.Real_Array (0 .. 15);
         Stop : aliased Model_Runner.Cancellation.Token;
      begin
         C.Reader.Parse (Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark target parse");
         L.Prepare (Engine, Descriptor, Source, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark target prepare " & Status.Code'Image);
         Model_Runner.Byte_Sources.Files.Open
           (Draft_Bytes, Tiny_Model.DSpark_Fixture, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark fixture open");
         C.Reader.Parse (Draft_Info, Draft_Bytes, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark fixture parse");
         declare
            Config : L.Configuration;
         begin
            L.Read_Config (Draft_Info, Settings => Config, Status => Status);
            Assert (E.Is_Ok (Status) and then Config.Kind = L.DFlash
                    and then Config.DSpark.Markov_Rank = 4, "DSpark metadata " & Status.Code'Image);
         end;
         L.Prepare (Draft, Draft_Info, Draft_Bytes, Status => Status);
         Assert (Status.Code = E.Arch_Unsupported_Feature and then not L.Is_Ready (Draft),
                 "DSpark accepted no target");
         L.Prepare (Draft, Draft_Info, Draft_Bytes, Target => Engine'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark prepare " & Status.Code'Image);
         Assert (L.Draft_Feature_Layers (Draft) = L.Feature_Layers'[5, 23, 41, 48], "DSpark tap mapping");
         L.Close (Engine, Status);
         Assert (Status.Code = E.Lifecycle_Session_Active and then L.Is_Ready (Engine), "borrowed target freed");
         L.Open (Live, Draft, Context => 32, Workers => Team'Unchecked_Access, Cache => L.Transformed_Fourth,
                 Status => Status);
         Assert (Status.Code = E.Arch_Unsupported_Feature, "unqualified draft cache accepted");
         L.Open (Live, Draft, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark open " & Status.Code'Image);
         declare
            package Inspect renames Model_Runner.Llama.Adapter_Testing;
            Bytes : aliased B.Byte_Array (0 .. 139 * 34 - 1) := [others => 0];
            Weight : TT.View;
         begin
            for Row in B.Byte_Count range 0 .. 138 loop
               Bytes (Row * 34 + 1) := 16#3C#;
               for I in B.Byte_Count range 0 .. 31 loop
                  Bytes (Row * 34 + 2 + I) := B.Byte ((Row * 7 + I * 13) mod 256);
               end loop;
            end loop;
            Weight := (Format => Model_Runner.GGUF.Type_Q8_0, Rows => 139, Columns => 32, Role => TT.Role_Feed_Forward,
                       Reference_Activations => True, Scales => null, Base => Bytes'Address,
                       Span => Bytes'Length, Offset => 0, Length => Bytes'Length, Interleaved => False);
            for Count in 1 .. 8 loop
               declare
                  Input : L.Real_Array (5 .. 5 + L.Element_Count (Count) * 32 - 1);
                  Product : L.Real_Array (11 .. 11 + L.Element_Count (Count) * 139 - 1);
                  Output : L.Real_Array (13 .. 13 + L.Element_Count (Count) * 139 + 3) := [others => 0.125];
                  Runs : constant Interfaces.Unsigned_64 := Inspect.Residual_Runs (Live);
               begin
                  for I in Input'Range loop Input (I) := L.Real (Integer (I mod 29) - 14) / 32.0; end loop;
                  Inspect.Project (Live, Weight, Input, Count, Product, Status);
                  Assert (E.Is_Ok (Status), "residual reference product");
                  Inspect.Residual_Project (Live, Weight, Input, Count, Output, Status);
                  Assert (E.Is_Ok (Status) and then Inspect.Residual_Runs (Live) = Runs + 1,
                          "packed residual path was not executed");
                  for I in L.Element_Count range 0 .. L.Element_Count (Count) * 139 - 1 loop
                     Assert (Model_Runner.Numerics.Bits (Output (13 + I)) =
                             Model_Runner.Numerics.Bits (0.125 + Product (11 + I)),
                             "residual epilogue changed product/add rounding or row stride");
                  end loop;
                  Assert (Output (Output'Last) = 0.125, "residual epilogue overwrote guard");
                  if Count >= 2 then
                     Output := [others => -999.0];
                     Inspect.Proposal_Project (Live, Weight, Input, Count, Output, Status);
                     Assert (E.Is_Ok (Status), "proposal-only projection failed");
                     Assert ((for all I in L.Element_Count range 13 .. 13 + 138 => Output (I) = -999.0),
                             "proposal projection touched unused anchor row");
                     for I in L.Element_Count range 139 .. L.Element_Count (Count) * 139 - 1 loop
                        Assert (Model_Runner.Numerics.Bits (Output (13 + I)) =
                                Model_Runner.Numerics.Bits (Product (11 + I)),
                                "skipping anchor changed projection rows or stride");
                     end loop;
                     Assert (Output (Output'Last) = -999.0, "proposal projection overwrote guard");
                  end if;
                  Stop.Request; Output := [others => 0.125];
                  Inspect.Residual_Project (Live, Weight, Input, Count, Output, Status, Stop'Unchecked_Access);
                  Assert (Status.Code = E.Generation_Cancelled and then (for all V of Output => V = 0.125),
                          "cancelled residual product published rows");
                  Stop.Reset;
               end;
            end loop;
         end;
         L.Open (Scalar, Draft, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark scalar open");
         Assert (L.Draft_Feature_Room (Live) /= null and then L.Draft_Feature_Room (Live)'Length = 2048 * 32,
                 "DSpark feature room not owned by session");
         L.Propose_Draft_Block (Live, Draft, 3, Proposals, Status => Status);
         Assert (Status.Code = E.Lifecycle_Invalid_State, "drafted without target context");
         L.Evaluate (Live, Draft, 3, Row, Status => Status);
         Assert (Status.Code = E.Arch_Unsupported_Feature and then L.Position (Live) = 0,
                 "feature-conditioned drafter ran ordinary decoder");
         L.Watch (Live, Observer'Unchecked_Access);
         L.Inject_Draft_Context (Live, Draft, [1, 2, 3], Features, Status => Status);
         Assert (E.Is_Ok (Status) and then L.Position (Live) = 3, "DSpark injection " & Status.Code'Image);
         L.Propose_Draft_Block (Live, Draft, 3, Proposals, Every => All_Logits, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark proposal " & Status.Code'Image);
         Assert (Observer.Checked = 9, "DSpark intermediate coverage");
         L.Watch (Live, null);
         Compare_Draft ("corrected", All_Logits.all);
         Assert (Proposals = Expected and then L.Position (Live) = 3, "DSpark Markov tokens or noise committed");
         L.Propose_Draft_Block (Live, Draft, 3, Repeated, Every => Again, Status => Status);
         Assert (E.Is_Ok (Status) and then Repeated = Proposals and then Again.all = All_Logits.all,
                 "DSpark repeated proposal changed cache");
         for Length in 1 .. 7 loop
            declare
               Complete, Greedy : Model_Runner.Tokenizer.Token_Array (5 .. 4 + Length);
               Rows : TT.Real_Array_Access := new L.Real_Array (9 .. 9 + L.Element_Count (Length) * 16 - 1);
            begin
               L.Propose_Draft_Block (Live, Draft, 3, Complete, Every => Rows, Status => Status);
               Assert (E.Is_Ok (Status), "complete variable-width proposal");
               L.Propose_Draft_Block (Live, Draft, 3, Greedy, Status => Status);
               Assert (E.Is_Ok (Status) and then Complete = Greedy and then L.Position (Live) = 3,
                       "local greedy correction changed IDs, ties or committed context");
               TT.Free (Rows);
            exception
               when others => TT.Free (Rows); raise;
            end;
         end loop;
         for Token in 0 .. 2 loop
            declare
               Feature : constant TT.Real_Array_Access := Features.all
                 (L.Element_Count (Token) * 128 .. L.Element_Count (Token + 1) * 128 - 1)'Unrestricted_Access;
            begin
               L.Inject_Draft_Context (Scalar, Draft, [Model_Runner.Tokenizer.Token_Id (Token + 1)], Feature,
                                       Status => Status);
               Assert (E.Is_Ok (Status), "DSpark scalar injection");
            end;
         end loop;
         L.Propose_Draft_Block (Scalar, Draft, 3, Repeated, Every => Again, Status => Status);
         Assert (E.Is_Ok (Status) and then Repeated = Proposals and then Again.all = All_Logits.all,
                 "DSpark batched/scalar injection differs");
         Stop.Request;
         L.Inject_Draft_Context (Live, Draft, [4], Features, Cancel => Stop'Unchecked_Access, Status => Status);
         Assert (Status.Code = E.Generation_Cancelled and then L.Position (Live) = 3,
                 "DSpark cancellation committed partial context");
         L.Rewind (Live, 2, Status);
         Assert (E.Is_Ok (Status), "DSpark rewind");
         declare
            Feature : constant TT.Real_Array_Access := Features.all (256 .. 383)'Unrestricted_Access;
         begin
            L.Inject_Draft_Context (Live, Draft, [3], Feature, Status => Status);
         end;
         L.Propose_Draft_Block (Live, Draft, 3, Repeated, Every => Again, Status => Status);
         Assert (E.Is_Ok (Status) and then Repeated = Proposals and then Again.all = All_Logits.all,
                 "DSpark rewind/reinject differs from fresh");
         declare
            Long : L.Session;
            Input : TT.Real_Array_Access := new L.Real_Array'
              (Read_Draft_Data ("fixtures/inkling2/dspark-long/features.f32"));
            At_Token : Natural := 0;
            Bounds : Model_Runner.Limits.Session_Limits;
            Plan : Model_Runner.Memory.Session_Plan;
         begin
            L.Plan_Session (Draft, 1040, Plan, Status);
            Assert (E.Is_Ok (Status), "DSpark long-context plan");
            Bounds.Max_Session_Bytes := Plan.Total_Resident - 1;
            L.Open (Long, Draft, 1040, Session_Bounds => Bounds, Workers => Team'Unchecked_Access, Status => Status);
            Assert (E.Is_Error (Status) and then L.Draft_Feature_Room (Long) = null,
                    "DSpark allocation bypassed session memory limit");
            L.Open (Long, Draft, 1040, Workers => Team'Unchecked_Access, Status => Status);
            Assert (E.Is_Ok (Status), "DSpark long context open");
            L.Close (Scalar);
            L.Open (Scalar, Draft, 1040, Status => Status);
            Assert (E.Is_Ok (Status), "DSpark serial long context open");
            while At_Token < 1030 loop
               declare
                  Span : constant Natural := Natural'Min (512, 1030 - At_Token);
                  Rows : constant TT.Real_Array_Access := Input.all
                    (L.Element_Count (At_Token) * 128 .. L.Element_Count (At_Token + Span) * 128 - 1)
                    'Unrestricted_Access;
               begin
                  L.Inject_Draft_Context (Long, Draft, [1 .. Span => 3], Rows, Status => Status);
                  Assert (E.Is_Ok (Status), "DSpark long-context injection");
                  L.Inject_Draft_Context (Scalar, Draft, [1 .. Span => 3], Rows, Status => Status);
                  Assert (E.Is_Ok (Status), "DSpark serial long-context injection");
                  At_Token := At_Token + Span;
               end;
            end loop;
            L.Propose_Draft_Block (Long, Draft, 3, Repeated, Every => Again, Status => Status);
            Assert (E.Is_Ok (Status), "DSpark long-context proposal " & Status.Code'Image);
            Compare_Draft ("corrected", Again.all, "fixtures/inkling2/dspark-long");
            Assert (Repeated = Model_Runner.Tokenizer.Token_Array'[15, 7, 7, 7, 1, 6, 6],
                    "DSpark local/global long-context proposal IDs");
            L.Propose_Draft_Block (Scalar, Draft, 3, Repeated, Every => All_Logits, Status => Status);
            Assert (E.Is_Ok (Status) and then All_Logits.all = Again.all,
                    "DSpark parallel attention changed serial reductions");
            L.Rewind (Long, 1020, Status);
            Assert (E.Is_Ok (Status), "DSpark rewind across local-window boundary");
            declare
               Rows : constant TT.Real_Array_Access := Input.all (1020 * 128 .. 1030 * 128 - 1)
                 'Unrestricted_Access;
            begin
               L.Inject_Draft_Context (Long, Draft, [1 .. 10 => 3], Rows, Status => Status);
            end;
            L.Propose_Draft_Block (Long, Draft, 3, Repeated, Every => Again, Status => Status);
            Assert (E.Is_Ok (Status), "DSpark long-context rewind proposal");
            Compare_Draft ("corrected", Again.all, "fixtures/inkling2/dspark-long");
            L.Close (Long); TT.Free (Input);
         exception
            when others => L.Close (Long); TT.Free (Input); raise;
         end;
         L.Reset (Live);
         Assert (L.Position (Live) = 0, "DSpark reset");
         L.Close (Scalar); L.Close (Live);
         Assert (L.Draft_Feature_Room (Live) = null, "DSpark room retained after close");
         L.Close (Draft, Status);
         Assert (E.Is_Ok (Status), "DSpark close");
         L.Close (Engine, Status);
         Assert (E.Is_Ok (Status), "DSpark target borrow retained");
         TT.Free (Features); TT.Free (All_Logits); TT.Free (Again);
         CPU.Close (Team);
      exception
         when others => CPU.Close (Team); TT.Free (Features); TT.Free (All_Logits); TT.Free (Again); raise;
      end;
      Model_Runner.Byte_Sources.Files.Close (Draft_Bytes);
      CPU.Use_Integer_Activations (False);
      B.Free (Image);
   exception
      when others => CPU.Use_Integer_Activations (False); B.Free (Image); raise;
   end Native_DSpark;

   procedure Seven_Head_Benchmark (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      package CPU renames Model_Runner.Backend.CPU;
      use type Ada.Real_Time.Time;
      Path : constant String := Ada.Environment_Variables.Value ("INKLING_HEAD7_MODEL", "");
      Directory : constant String := Ada.Environment_Variables.Value ("INKLING_HEAD7_DUMP", "");
      Passes : constant Positive := 12;
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Descriptor : C.Container;
      Status : E.Error_Info;
      Input, Output : TT.Real_Array_Access := null;
      Team : aliased CPU.Pool (8);
      Weight : TT.View;
      Index : Natural;
      Started : Ada.Real_Time.Time;
      Elapsed : Duration;
   begin
      if Path = "" then return; end if;
      Model_Runner.Byte_Sources.Files.Open
        (Source, Path, Policy => Model_Runner.Byte_Sources.Files.Mapping_Required, Status => Status);
      Assert (E.Is_Ok (Status), "head component mapping failed");
      C.Reader.Parse (Descriptor, Source, Status => Status);
      Assert (E.Is_Ok (Status), "head component metadata failed");
      Index := C.Find_Tensor (Descriptor, "output.weight");
      Assert (Index > 0 and then C.Tensor_Format (Descriptor, Index) = Model_Runner.GGUF.Type_Q5_K,
              "head component requires the selected Q5_K tensor");
      Weight := (Format => Model_Runner.GGUF.Type_Q5_K,
                 Rows => L.Element_Count (C.Tensor_Dimension (Descriptor, Index, 2)),
                 Columns => L.Element_Count (C.Tensor_Dimension (Descriptor, Index, 1)),
                 Role => TT.Role_Output, Reference_Activations => True, Scales => null,
                 Base => Model_Runner.Byte_Sources.Files.Base (Source),
                 Span => Model_Runner.Byte_Sources.Files.Size (Source),
                 Offset => B.Byte_Count (C.Tensor_Offset (Descriptor, Index)),
                 Length => B.Byte_Count (C.Tensor_Bytes (Descriptor, Index)), Interleaved => False);
      Assert (Weight.Columns = 2304 and then Weight.Rows = 201024, "selected head shape changed");
      Input := new L.Real_Array (5 .. 5 + 7 * Weight.Columns - 1);
      Output := new L.Real_Array (7 .. 7 + 7 * Weight.Rows - 1);
      for I in Input'Range loop Input (I) := L.Real (Integer (I mod 257) - 128) / 256.0; end loop;
      CPU.Use_Integer_Activations (True);
      Model_Runner.Quantization.Integers.Use_Wide_Rows (True);
      Model_Runner.Quantization.Integers.Use_Deep_Rows (True);
      TT.Use_Deep_Products (True, Brain => Model_Runner.Platform.Brain_Products);
      CPU.Dispatch_Batch (Team'Unchecked_Access, Weight, Input, 7, Output, Status, Roles => [others => True]);
      Assert (E.Is_Ok (Status), "head warmup failed");
      Started := Ada.Real_Time.Clock;
      for Run in 1 .. Passes loop
         CPU.Dispatch_Batch (Team'Unchecked_Access, Weight, Input, 7, Output, Status, Roles => [others => True]);
         Assert (E.Is_Ok (Status), "head component product failed");
      end loop;
      Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
      Ada.Text_IO.Put_Line ("Q5 head component: seven rows, eight workers, projection_tok_s="
                           & Long_Float'Image (Long_Float (7 * Passes) / Long_Float (Elapsed))
                           & " seconds=" & Duration'Image (Elapsed));
      if Directory /= "" then
         declare
            File : Ada.Streams.Stream_IO.File_Type;
            Bytes : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Output'Length) * 4)
              with Import, Address => Output (Output'First)'Address;
         begin
            Ada.Streams.Stream_IO.Create (File, Ada.Streams.Stream_IO.Out_File, Directory & "/head-seven.f32");
            Ada.Streams.Stream_IO.Write (File, Bytes); Ada.Streams.Stream_IO.Close (File);
         exception
            when others =>
               if Ada.Streams.Stream_IO.Is_Open (File) then Ada.Streams.Stream_IO.Close (File); end if;
               raise;
         end;
      end if;
      CPU.Close (Team); TT.Free (Input); TT.Free (Output); C.Close (Descriptor);
      Model_Runner.Byte_Sources.Files.Close (Source); CPU.Use_Integer_Activations (False);
   exception
      when others =>
         CPU.Close (Team); TT.Free (Input); TT.Free (Output); C.Close (Descriptor);
         Model_Runner.Byte_Sources.Files.Close (Source); CPU.Use_Integer_Activations (False); raise;
   end Seven_Head_Benchmark;

   function Draft_Anchor (Directory : String) return Model_Runner.Tokenizer.Token_Id is
      File : Ada.Text_IO.File_Type;
      Result : Model_Runner.Tokenizer.Token_Id;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Directory & "/anchor.txt");
      Result := Model_Runner.Tokenizer.Token_Id'Value (Ada.Text_IO.Get_Line (File));
      Ada.Text_IO.Close (File);
      return Result;
   exception
      when others => if Ada.Text_IO.Is_Open (File) then Ada.Text_IO.Close (File); end if; raise;
   end Draft_Anchor;

   procedure Full_DSpark_Reference (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package TT renames Model_Runner.Tensors;
      package CPU renames Model_Runner.Backend.CPU;
      Directory : constant String := Ada.Environment_Variables.Value ("INKLING_DSPARK_REFERENCE", "");
      Status : E.Error_Info;
   begin
      if Directory = "" then return; end if;
      CPU.Use_Integer_Activations (True);
      declare
         Target_Bytes, Draft_Bytes : Model_Runner.Byte_Sources.Files.File_Source;
         Target_Info, Draft_Info : C.Container;
         Target, Draft : aliased L.Model;
         Live, Hot, Target_Live : L.Session;
         Team : aliased CPU.Pool (8);
         Features : TT.Real_Array_Access := new L.Real_Array'(Read_Draft_Data (Directory & "/features.f32"));
         Logits : TT.Real_Array_Access := new L.Real_Array (0 .. 7 * 200_058 - 1);
         Proposed : Model_Runner.Tokenizer.Token_Array (1 .. 7);
         Observer : aliased Draft_Observer;
         Anchor : constant Model_Runner.Tokenizer.Token_Id := Draft_Anchor (Directory);
      begin
         Observer.Directory := U.To_Unbounded_String (Directory);
         Observer.Dump_Directory := U.To_Unbounded_String
           (Ada.Environment_Variables.Value ("INKLING_DSPARK_DUMP", ""));
         if U.Length (Observer.Dump_Directory) > 0 then
            Ada.Text_IO.Put_Line ("DSpark diagnostic only: comparisons disabled, native activations saved");
         end if;
         Model_Runner.Byte_Sources.Files.Open
           (Target_Bytes, Ada.Environment_Variables.Value ("INKLING_TARGET_MODEL"), Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark target open " & Status.Code'Image);
         C.Reader.Parse (Target_Info, Target_Bytes, Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark target parse " & Status.Code'Image);
         L.Prepare (Target, Target_Info, Target_Bytes, Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark target prepare " & Status.Code'Image);
         Model_Runner.Byte_Sources.Files.Open
           (Draft_Bytes, Ada.Environment_Variables.Value ("INKLING_DRAFT_MODEL"), Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark draft open " & Status.Code'Image);
         C.Reader.Parse (Draft_Info, Draft_Bytes, Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark draft parse " & Status.Code'Image);
         L.Prepare (Draft, Draft_Info, Draft_Bytes, Target => Target'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark draft prepare " & Status.Code'Image);
         L.Open (Live, Draft, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark draft session " & Status.Code'Image);
         L.Watch (Live, Observer'Unchecked_Access);
         L.Inject_Draft_Context (Live, Draft, [32269, 11, 152717], Features, Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark context injection " & Status.Code'Image);
         L.Propose_Draft_Block (Live, Draft, Anchor, Proposed, Every => Logits, Status => Status);
         Assert (E.Is_Ok (Status), "full DSpark proposal " & Status.Code'Image);
         if U.Length (Observer.Dump_Directory) > 0 then
            Dump_Activation (U.To_String (Observer.Dump_Directory), "corrected", Logits.all);
         else
         Compare_Draft ("corrected", Logits.all, Directory);
         Assert (Proposed = Model_Runner.Tokenizer.Token_Array'[68014, 371, 150409, 6, 82, 220, 68111],
                 "full DSpark independent proposals differ");
         end if;
         Assert (Observer.Checked = 9, "full DSpark intermediate coverage");
         L.Watch (Live, null);
         if U.Length (Observer.Dump_Directory) = 0 then
            L.Open (Hot, Draft, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
            Assert (E.Is_Ok (Status), "full DSpark grouped session");
            L.Inject_Draft_Context (Hot, Draft, [32269, 11, 152717], Features, Status => Status);
            Assert (E.Is_Ok (Status), "full DSpark grouped context injection");
            L.Propose_Draft_Block (Hot, Draft, Anchor, Proposed, Every => Logits, Status => Status);
            Assert (E.Is_Ok (Status), "full DSpark fused readout " & Status.Code'Image);
            Compare_Draft ("corrected", Logits.all, Directory);
            Assert (Proposed = Model_Runner.Tokenizer.Token_Array'[68014, 371, 150409, 6, 82, 220, 68111],
                    "full DSpark fused readout changed independent proposals");
         end if;
         L.Open (Target_Live, Target, Context => 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "full target feature session");
         declare
            Width : constant L.Element_Count := 2304 * 4;
            Captured : constant TT.Real_Array_Access := L.Draft_Feature_Room (Live);
            Row : L.Real_Array (0 .. 200_057);
         begin
            L.Evaluate_Features (Target_Live, Target, [371, 151451, 149879, 151194, 149884],
                                 L.Draft_Feature_Layers (Draft),
                                 Captured, Row, Status => Status);
            Assert (E.Is_Ok (Status), "full native target feature capture " & Status.Code'Image);
            Compare_Draft ("target-baseline-taps",
                           Captured.all (Captured'First + 4 * Width .. Captured'First + 5 * Width - 1), Directory);
         end;
         L.Close (Target_Live); L.Close (Hot);
         L.Close (Live); L.Close (Draft, Status); L.Close (Target, Status);
         TT.Free (Features); TT.Free (Logits);
         Model_Runner.Byte_Sources.Files.Close (Draft_Bytes);
         Model_Runner.Byte_Sources.Files.Close (Target_Bytes);
         CPU.Close (Team);
      exception
         when others => CPU.Close (Team); TT.Free (Features); TT.Free (Logits); raise;
      end;
      CPU.Use_Integer_Activations (False);
   exception
      when others => CPU.Use_Integer_Activations (False); raise;
   end Full_DSpark_Reference;

   procedure DSpark_Generation (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package G renames Model_Runner.Generation;
      package CPU renames Model_Runner.Backend.CPU;
      Image : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build_Inkling (Image, Fault => Tiny_Model.Inkling_Aligned_Heads, Quantized => True);
      CPU.Use_Integer_Activations (True);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Target_Bytes : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Draft_Bytes : Model_Runner.Byte_Sources.Files.File_Source;
         Target_Info, Draft_Info : C.Container;
         Target, Draft : aliased L.Model;
         Live, Fresh : aliased L.Session;
         Draft_Live : aliased L.Session;
         Team : aliased CPU.Pool (2);
         Request : G.Request;
         Endings : Model_Runner.Stops.Set;
         Plain, Drafted, Reused, Cold, Refused : G.Result;
      begin
         C.Reader.Parse (Target_Info, Target_Bytes, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark generation target parse");
         L.Prepare (Target, Target_Info, Target_Bytes, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark generation target prepare");
         Model_Runner.Byte_Sources.Files.Open
           (Draft_Bytes, Tiny_Model.DSpark_Fixture, Status => Status);
         C.Reader.Parse (Draft_Info, Draft_Bytes, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark generation draft parse");
         L.Prepare (Draft, Draft_Info, Draft_Bytes, Target => Target'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark generation draft prepare");
         L.Open (Live, Target, 32, Workers => Team'Unchecked_Access,
                 Cache => L.Transformed_Fourth, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark generation target open");
         L.Open (Fresh, Target, 32, Workers => Team'Unchecked_Access,
                 Cache => L.Transformed_Fourth, Status => Status);
         L.Open (Draft_Live, Draft, 32, Workers => Team'Unchecked_Access, Status => Status);
         Assert (E.Is_Ok (Status), "DSpark generation draft open");
         Model_Runner.Stops.Open (Endings);
         Request.Max_Tokens := 8;
         Request.Batch_Size := 3;
         Request.Ignore_End := True;
         Request.Add_Beginning := False;
         Request.Sampling.Temperature := 0.0;
         Request.Sampling.Repeat_Penalty := 1.0;
         Request.Has_Seed := True;
         Request.Seed := 1;
         Request.Retain_Text := True;
         G.Generate (Target, Fresh, "abababab", Request, Endings,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Plain);
         Assert (E.Is_Ok (Plain.Error), "DSpark undrafted baseline");
         Request.Draft_Tokens := 7;
         G.Generate (Target, Live, "abababab", Request, Endings,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Drafted,
           Draft => Draft'Unchecked_Access, Draft_Session => Draft_Live'Unchecked_Access);
         Assert (E.Is_Ok (Drafted.Error), "DSpark generation " & Drafted.Error.Code'Image);
         Assert (G.Generated_Text (Plain) = G.Generated_Text (Drafted)
                 and then Plain.Generated_Tokens = Drafted.Generated_Tokens,
                 "DSpark verifier changed target output");
         Assert (Drafted.Drafted > 0, "DSpark generation never proposed");
         Assert (L.Position (Draft_Live) = L.Position (Live), "DSpark paired positions diverged");
         for At_Token in 0 .. L.Position (Live) - 1 loop
            Assert (L.Committed_Token (Draft_Live, At_Token) = L.Committed_Token (Live, At_Token),
                    "DSpark injected rejected token");
         end loop;
         Request.Reuse_Committed_Prefix := True;
         G.Generate (Target, Live, "ababababab", Request, Endings,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Reused,
           Draft => Draft'Unchecked_Access, Draft_Session => Draft_Live'Unchecked_Access);
         Assert (E.Is_Ok (Reused.Error), "DSpark reused generation " & Reused.Error.Code'Image);
         L.Reset (Fresh); Request.Draft_Tokens := 0;
         G.Generate (Target, Fresh, "ababababab", Request, Endings,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Cold);
         Assert (E.Is_Ok (Cold.Error) and then G.Generated_Text (Reused) = G.Generated_Text (Cold),
                 "DSpark prefix reuse changed target output");
         Request.Draft_Tokens := 7;
         Request.Sampling.Temperature := 0.5;
         G.Generate (Target, Live, "abab", Request, Endings,
           Sink => null, Observer => null, Time => null, Seeds => null, Cancel => null, Outcome => Refused,
           Draft => Draft'Unchecked_Access, Draft_Session => Draft_Live'Unchecked_Access);
         Assert (Refused.Error.Code = E.Arch_Unsupported_Feature, "sampled DSpark silently approximated");
         G.Release (Plain); G.Release (Drafted); G.Release (Reused); G.Release (Cold); G.Release (Refused);
         Model_Runner.Stops.Close (Endings);
         L.Close (Draft_Live); L.Close (Fresh); L.Close (Live);
         L.Close (Draft, Status); L.Close (Target, Status);
         Model_Runner.Byte_Sources.Files.Close (Draft_Bytes);
         CPU.Close (Team);
      exception
         when others => CPU.Close (Team); raise;
      end;
      CPU.Use_Integer_Activations (False); B.Free (Image);
   exception
      when others => CPU.Use_Integer_Activations (False); B.Free (Image); raise;
   end DSpark_Generation;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Parallel_Convolution_State'Access,
                        "parallel convolution preserves batched logical states, rewind and reset");
      Register_Routine (T, Small_IQ4_Benchmark'Access,
                        "optional profiled IQ4 row-pair component benchmark");
      Register_Routine (T, Small_IQ3_Benchmark'Access,
                        "optional small IQ3 native expert component comparison");
      Register_Routine (T, IQ3_Reference_Arithmetic'Access,
                        "native IQ3 one-to-sixteen-query products preserve independent goldens, maps and guards");
      Register_Routine (T, Seven_Q5_Products'Access,
                        "seven Q5 vectors preserve independent products, mappings and bounds");
      Register_Routine (T, Seven_Head_Benchmark'Access,
                        "optional selected Q5 seven-row head component benchmark");
      Register_Routine (T, Draft_Vector_Arithmetic'Access,
                        "vector drafter exponentials, activation and reused rotary tables are exact");
      Register_Routine (T, Grouped_Draft_Arithmetic'Access,
                        "grouped DSpark dots and value FMAs preserve reference bits");
      Register_Routine (T, Compact_Features_And_Packing'Access,
                        "compact features, winner rows and retained shared packing preserve lifecycle");
      AUnit.Test_Cases.Registration.Register_Routine
        (T, Stable_Router_Picks'Access, "stable 8-of-128 router matches scan ordering and ties");
      Register_Routine (T, Prefix_And_Drafting'Access,
                        "prefix reuse and context drafting preserve greedy generation");
      Register_Routine (T, Zero_Controls'Access, "independent zero-gate three-pass residual reference");
      Register_Routine (T, Nonfinite_Weights'Access, "nonfinite execution fails without committing a token");
      Register_Routine
        (T, Q4T_Cache'Access, "Q4T independent attention, batching, snapshots, rewind and eviction");
      Register_Routine
        (T, Q4T_Checkpoint'Access, "optional Q4T full checkpoint attention and continuation");
      Register_Routine
        (T, Cache_Metadata_Identity'Access, "saved context binds loop, normalization and activation metadata");
      Register_Routine (T, Metadata'Access, "metadata, padded vocabulary and all tensor roles");
      Register_Routine
        (T, Malformed'Access, "malformed metadata, tensors and unsupported variants fail before weights");
      Register_Routine (T, Limits'Access, "caller limits include logical visits and padded rows");
      Register_Routine (T, Integer_Workspace_Plan'Access, "memory plan covers integer worker scratch");
      Register_Routine
        (T, Batched_Prefill'Access, "batched prefill states, logits, partitions and atomic cancellation");
      Register_Routine (T, Lifecycle'Access, "native execution, prefill, reset, rewind and saved continuation");
      Register_Routine (T, Reference'Access, "independent F32 layer, message, controller and logit reference");
      Register_Routine (T, Quantized_Reference'Access, "independent Q8 activation-scale and decoder reference");
      Register_Routine
        (T, Quantized_Panels'Access, "independent Q8 arithmetic survives rebuilt and mapped row panels");
      Register_Routine (T, Device_Pointwise_Reference'Access,
                        "Vulkan pointwise projection sequence executes and returns observer inputs");
      Register_Routine (T, Device_Reference'Access, "Vulkan independent F32 decoder and prefix reference");
      Register_Routine
        (T, Long_Context_Reference'Access, "long-context eviction, independent recomputation and rewind");
      Register_Routine
        (T, Reference_Integer_Tiles'Access, "integer tiles, vector tails and cached panels match independent goldens");
      Register_Routine (T, Reference_Q6_Products'Access, "independent Q6_K binary32 products and bounds");
      Register_Routine (T, Reference_Q5_Products'Access, "independent Q5_K binary32 products and bounds");
      Register_Routine (T, Reference_Q50_Products'Access, "independent Q5_0 binary32 products and bounds");
      Register_Routine (T, Reference_Attention_Packing'Access, "independent attention Q8 packing at model width");
      Register_Routine (T, Reference_Q4_Products'Access, "independent Q4_K binary32 products and bounds");
      Register_Routine (T, Reference_F32_Products'Access, "independent F32 integer-profile lane products");
      Register_Routine (T, Reference_Q8_Products'Access, "independent Q8 binary32 products and bounds");
      Register_Routine (T, Vulkan_Integer_Products'Access, "optional native Vulkan reference integer products");
      Register_Routine (T, Fused_Expert_Accumulation'Access,
                        "fused expert weighting preserves separate rounding, values, bounds and rank order");
      Register_Routine (T, CPU_Reference_SiTU'Access, "CPU reference SiTU exact independent arithmetic and tails");
      Register_Routine (T, Vulkan_Reference_SiTU'Access, "optional native Vulkan reference SiTU arithmetic");
      Register_Routine (T, Vulkan_GSQ_Products'Access, "native Vulkan GSQ products match independent reference");
      Register_Routine (T, Vulkan_GSQ_Experts'Access, "native Vulkan GSQ fused experts preserve reference activation");
      Register_Routine (T, Vulkan_Reference_Mixture'Access, "optional native Vulkan resident integer mixture");
      Register_Routine (T, Batched_Q4T_Rotations'Access, "batched Q4T rotations preserve scalar butterfly order");
      Register_Routine (T, Reference_Long_Rows'Access, "long streamed rows retain qualified reference lanes");
      Register_Routine
        (T, Selected_Output'Access, "selected output and constrained generation preserve full lifecycle");
      Register_Routine
        (T, Device_Relative_Packed'Access, "optional native Vulkan Q4T relative attention and metadata bounds");
      Register_Routine (T, Relative_Bias_Lanes'Access, "SIMD relative bias preserves scalar channel order and bounds");
      Register_Routine (T, Reference_Pack_Reordering'Access, "SIMD reference packing preserves ties and signed maxima");
      Register_Routine (T, Reference_Packing'Access, "independent Q8_K signed scales, ties and block sums");
      Register_Routine
        (T, Full_DSpark_Reference'Access, "optional full DSpark checkpoint reference");
      Register_Routine
        (T, DSpark_Generation'Access, "DSpark generation verifies proposals and reuses paired prefixes");
      Register_Routine
        (T, DSpark_Metadata'Access, "DSpark metadata rejects unsupported variants and malformed tensors");
      Register_Routine
        (T, Native_BF16_Dots'Access, "native BF16 pair dots preserve reference packing, folds and bounds");
      Register_Routine
        (T, Native_DSpark'Access, "native DSpark reference blocks, Markov proposals and lifecycle");
      Register_Routine
        (T, Logical_Feature_Capture'Access, "logical target features preserve visits, batching and transactionality");
      Register_Routine (T, Checkpoint'Access, "optional independent Q4_K_M checkpoint reference");
   end Register_Tests;
end Tests.Inkling_Cases;
