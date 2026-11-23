with Ada.Unchecked_Conversion;
with AUnit.Assertions; use AUnit.Assertions;
with AUnit.Test_Cases;
with Adapter_Oracle;
with Fixtures;
with Interfaces;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Cancellation;
with Model_Runner.Memory;
with Model_Runner.Limits;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama.Adapter_Testing;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Tokenizer;
with Tiny_Model;
with System;
with Model_Runner.Byte_Sources;
with Ada.Directories;
with Adapter_Benchmark;
with Adapter_Fixture;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Model_Runner.Byte_Sources.Files;
with Project_Tools.Files;
with Model_Runner.Inference;
with Model_Runner.Progress;
with Model_Runner.Text;
with Ada.Strings.Unbounded;

package body Tests.Adapter_Cases is

   package O renames Adapter_Oracle;
   package B renames Model_Runner.Bytes;
   package C renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package G renames Model_Runner.GGUF;
   package L renames Model_Runner.Llama;
   package P renames Model_Runner.Llama.Adapter_Testing;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   use type O.Number;
   use type N.Real;
   use type N.Element_Count;
   use type B.Byte_Count;
   use type B.Byte_Array;
   use type B.Byte;
   use type E.Error_Code;
   use type G.Tensor_Type;
   use type Interfaces.Unsigned_64;
   use type Interfaces.Unsigned_32;
   use type P.Projection;
   use type Tiny_Model.Fixture_Architecture;
   use type Model_Runner.Memory.Account;
   use type Model_Runner.Backend.Backend_Kind;
   use type System.Bit_Order;

   type Read_Fault is (Cancel_Read, Fail_Read, Short_Source, Changed_Source);
   type Fault_Source is limited new Model_Runner.Byte_Sources.Source with record
      Data : B.Byte_Array_Access;
      Stop : Model_Runner.Cancellation.Token_Reference;
      Fault : Read_Fault;
      Reads : Natural := 0;
   end record;
   overriding function Size (Self : Fault_Source) return B.Byte_Count;
   overriding procedure Read
     (Self : in out Fault_Source; Offset : B.Byte_Count; Target : out B.Byte_Array; Status : out E.Error_Info);
   overriding function Is_Mapped (Self : Fault_Source) return Boolean is (False);
   overriding function Base (Self : Fault_Source) return System.Address is (System.Null_Address);
   overriding function Name (Self : Fault_Source) return String is ("adapter fault fixture");
   overriding function Changed (Self : Fault_Source) return Boolean is (Self.Fault = Changed_Source);
   overriding function Size (Self : Fault_Source) return B.Byte_Count
   is (Self.Data'Length - (if Self.Fault = Short_Source then 1 else 0));
   overriding procedure Read
     (Self : in out Fault_Source; Offset : B.Byte_Count; Target : out B.Byte_Array; Status : out E.Error_Info)
   is
   begin
      Self.Reads := Self.Reads + 1;
      if Self.Fault = Fail_Read then
         Status := E.Make (E.IO_Read_Failed);
      elsif Offset > Self.Size or else Target'Length > Self.Size - Offset then
         Status := E.Make (E.GGUF_Truncated);
      else
         Target := Self.Data (Self.Data'First + Offset .. Self.Data'First + Offset + Target'Length - 1);
         Status := E.Success;
         if Self.Fault = Cancel_Read then
            Self.Stop.Request;
         end if;
      end if;
   end Read;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("adapter numerical contract");
   end Name;

   procedure Check (Status : E.Error_Info; Where : String) is
   begin
      Assert (E.Is_Ok (Status), Where & ": " & E.Error_Code'Image (Status.Code)
                & " " & E.Text_Of (Status, "feature") & " " & E.Text_Of (Status, "capability"));
   end Check;

   function A_Value (K, Column : Natural) return O.Number
   is (O.Number (Integer ((K * 7 + Column * 3) mod 17) - 8) / 128.0);

   function B_Value (Row, K : Natural) return O.Number
   is (O.Number (Integer ((Row * 5 + K * 11) mod 19) - 9) / 64.0);

   type Alpha_Kind is (Absent, Zero, Positive_Alpha);
   type Fault is (None, Half_Pair, Wrong_Input, Wrong_Output, Wrong_Rank, Foreign_Target, Foreign_Type, Activated,
                  Late_Shape, Late_Non_Finite, Invalid_Alpha, Non_Finite_Down, Overflowing_Delta,
                  Rank_Three, Quantized_Down, Extra_Target, Wide_Scaled_Result);

   procedure Build_Adapter
     (Columns, Rows, Rank : Positive; Stem, Architecture : String; Format : G.Tensor_Type;
      Alpha : Alpha_Kind; Broken : Fault; Image : out B.Byte_Array_Access;
      Tweak : Boolean := False; Swap : Boolean := False)
   is
      Builder : Fixtures.Builder;
      Width : constant Positive := Columns - (if Broken = Wrong_Input then 1 else 0);
      Height : constant Positive := Rows + (if Broken = Wrong_Output then 1 else 0);
      Up_Rank : constant Positive := Rank + (if Broken = Wrong_Rank then 1 else 0);
      Down : N.Real_Array (0 .. N.Element_Count (Width * Rank) - 1);
      Up : N.Real_Array (0 .. N.Element_Count (Height * Up_Rank) - 1);
      Name : constant String := (if Broken = Foreign_Target then "blk.0.attn_norm.weight" else Stem);
   begin
      Fixtures.Add_String (Builder, "general.architecture", Architecture);
      Fixtures.Add_String (Builder, "general.type", (if Broken = Foreign_Type then "model" else "adapter"));
      Fixtures.Add_String (Builder, "adapter.type", "lora");
      if Alpha /= Absent then
         Fixtures.Add_F32 (Builder, "adapter.lora.alpha",
                          (if Broken = Invalid_Alpha then -1.0 elsif Alpha = Zero then 0.0 else N.Real (Rank) * 0.5));
      end if;
      if Broken = Activated then
         Fixtures.Add_U32 (Builder, "adapter.alora.invocation_tokens", 4);
      end if;
      for K in 0 .. Rank - 1 loop
         for Column in 0 .. Width - 1 loop
            Down (N.Element_Count (K * Width + Column)) := N.Real (A_Value (K, Column));
         end loop;
      end loop;
      for Row in 0 .. Height - 1 loop
         for K in 0 .. Up_Rank - 1 loop
            Up (N.Element_Count (Row * Up_Rank + K)) := N.Real (B_Value (Row, K));
         end loop;
      end loop;
      if Tweak then
         Assert (Up (Up'Last) /= 0.0, "identity fixture needs a nonzero final coefficient");
         Up (Up'Last) := -Up (Up'Last);
      end if;
      if Broken = Overflowing_Delta then
         Down := [others => N.Real'Last];
         Up := [others => N.Real'Last];
      end if;
      if Broken = Wide_Scaled_Result then
         Down := [others => 0.0];
         for K in 0 .. Rank - 1 loop
            Down (N.Element_Count (K * Width)) := 1.0;
         end loop;
         Up := [others => 1.0E30];
      end if;
      declare
         Data : B.Byte_Array :=
           (if Format = G.Type_F16 then Fixtures.Encode_F16 (Down) else Fixtures.Encode_F32 (Down));
      begin
         if Broken = Non_Finite_Down then
            if Format = G.Type_F16 then
               Data (Data'Last - 1 .. Data'Last) := [0, 16#7E#];
            else
               Data (Data'Last - 3 .. Data'Last) := [0, 0, 16#C0#, 16#7F#];
            end if;
         end if;
         Fixtures.Add_Tensor
           (Builder, Name & ".lora_a",
            (if Broken = Rank_Three then Fixtures.Dimension_List'([G.U64 (Width), G.U64 (Rank), 1])
             else Fixtures.Dimension_List'([G.U64 (Width), G.U64 (Rank)])),
            (if Broken = Quantized_Down then G.Type_Q8_0 else Format),
            (if Broken = Quantized_Down then Fixtures.Encode_Q8_0 (Down) else Data));
      end;
      if Broken /= Half_Pair then
         Fixtures.Add_Tensor
           (Builder, Name & ".lora_b", [G.U64 (Up_Rank), G.U64 (Height)], Format,
            (if Format = G.Type_F16 then Fixtures.Encode_F16 (Up) else Fixtures.Encode_F32 (Up)));
      end if;
      if Broken = Extra_Target then
         Fixtures.Add_Tensor (Builder, "output.weight.lora_a", [G.U64 (Width), G.U64 (Rank)],
                              Format, Fixtures.Encode_F32 (Down));
         Fixtures.Add_Tensor (Builder, "output.weight.lora_b", [G.U64 (Up_Rank), G.U64 (Height)],
                              Format, Fixtures.Encode_F32 (Up));
      end if;
      if Broken in Late_Shape | Late_Non_Finite then
         declare
            Bad_Width : constant Positive := Columns - (if Broken = Late_Shape then 1 else 0);
            Bad_Down : constant N.Real_Array (0 .. N.Element_Count (Bad_Width * Rank) - 1) := [others => 0.125];
            --  Tiny llama's key projection has half the query's output width.
            Bad_Up : constant N.Real_Array (0 .. N.Element_Count (Rows / 2 * Rank) - 1) := [others => 0.25];
            Encoded : B.Byte_Array := Fixtures.Encode_F32 (Bad_Up);
         begin
            if Broken = Late_Non_Finite then
               Encoded (Encoded'Last - 3 .. Encoded'Last) := [0, 0, 16#C0#, 16#7F#];
            end if;
            Fixtures.Add_Tensor (Builder, "blk.0.attn_k.weight.lora_a", [G.U64 (Bad_Width), G.U64 (Rank)],
                                 G.Type_F32, Fixtures.Encode_F32 (Bad_Down));
            Fixtures.Add_Tensor (Builder, "blk.0.attn_k.weight.lora_b", [G.U64 (Rank), G.U64 (Rows / 2)],
                                 G.Type_F32, Encoded);
         end;
      end if;
      Fixtures.Build (Builder, Image);
      if Swap then
         Assert (Format = G.Type_F32 and then Columns = Rows, "offset control requires equally sized F32 pairs");
         Fixtures.Poke_U64 (Image.all, Fixtures.Field_Position (Builder, Fixtures.Tensor_Offset, 1),
                            G.U64 (Columns * Rank * 4));
         Fixtures.Poke_U64 (Image.all, Fixtures.Field_Position (Builder, Fixtures.Tensor_Offset, 2), 0);
      end if;
   end Build_Adapter;

   procedure Apply
     (Ready : in out L.Model; Image : B.Byte_Array; Scale : N.Real; Status : out E.Error_Info;
      Runtime : Boolean := False; Bounds : L.Adapter_Limits := L.Default_Adapter_Limits;
      Cancel : Model_Runner.Cancellation.Token_Reference := null)
   is
      --  Deliberate raw non-finite scales must reach Merge_Adapter's structured validation.
      pragma Suppress (Validity_Check);
      Held : aliased constant B.Byte_Array := Image;
      Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
      Parsed : C.Container;
   begin
      C.Reader.Parse (Parsed, Source, Status => Status);
      Check (Status, "adapter parse");
      if Runtime then
         L.Attach_Adapter (Ready, Parsed, Source, Scale, Status, Bounds, Cancel);
      else
         L.Merge_Adapter (Ready, Parsed, Source, Scale, Status);
      end if;
      C.Close (Parsed);
   end Apply;

   procedure Known_Answers_And_Stacking (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      --  Different nonzero origins catch accidental use of GGUF axis numbers as array indices.
      Weight : constant O.Matrix (4 .. 5, 7 .. 9) := [[1.0, 2.0, -1.0], [-2.0, 0.0, 3.0]];
      Down : constant O.Matrix (8 .. 9, 2 .. 4) := [[1.0, 0.0, 2.0], [-1.0, 3.0, 1.0]];
      Up : constant O.Matrix (3 .. 4, 6 .. 7) := [[2.0, -1.0], [0.5, 4.0]];
      Input : constant O.Vector (5 .. 7) := [2.0, -1.0, 0.5];
      Answer : O.Vector (9 .. 10) := [others => 123.0];
      Status : E.Error_Info;
      function Bits is new Ada.Unchecked_Conversion (O.Number, Interfaces.Unsigned_64);
   begin
      O.Project (Weight, Input, Answer, Status);
      Check (Status, "analytic base");
      Assert (Answer (9) = -0.5 and then Answer (10) = -2.5, "wrong base answer");
      O.Accumulate (Down, Up, Input, 0.25, 4.0, True, Answer, Status);
      Check (Status, "analytic adapter");
      Assert (Answer (9) = 4.75 and then Answer (10) = -10.75, "rank/orientation/alpha mismatch");
      O.Accumulate (Down, Up, Input, -0.25, 4.0, True, Answer, Status);
      Check (Status, "negative stack");
      Assert (Answer (9) = -0.5 and then Answer (10) = -2.5, "negative stack did not cancel");
      O.Accumulate (Down, Up, Input, 1.0, 0.0, True, Answer, Status);
      Check (Status, "zero alpha");
      Assert (Answer (9) = 10.0 and then Answer (10) = -19.0, "zero alpha did not use scale alone");
      Answer := [-0.5, -2.5];
      O.Accumulate (Down, Up, Input, 1.0, 99.0, False, Answer, Status);
      Check (Status, "absent alpha");
      Assert (Answer (9) = 10.0 and then Answer (10) = -19.0, "absent alpha did not use scale alone");
      Answer := [-0.0, 2.0];
      O.Accumulate (Down, Up, Input, 0.0, 4.0, True, Answer, Status);
      Check (Status, "zero scale");
      Assert (Bits (Answer (9)) = 16#8000_0000_0000_0000# and then Answer (10) = 2.0,
              "zero scale changed a bit of the result");
   end Known_Answers_And_Stacking;

   procedure Invalid_Reference_Inputs_Preserve_Output (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      --  Deliberately inject IEEE values the reference is required to refuse structurally.
      pragma Suppress (Validity_Check);
      function From_Bits is new Ada.Unchecked_Conversion (Interfaces.Unsigned_64, O.Number);
      Down : O.Matrix (0 .. 1, 0 .. 2) := [others => [others => 1.0]];
      Up : O.Matrix (0 .. 1, 0 .. 1) := [others => [others => 1.0]];
      Bad_Up : constant O.Matrix (0 .. 1, 0 .. 0) := [others => [others => 1.0]];
      type Bit_Patterns is array (Positive range <>) of Interfaces.Unsigned_64;
      Input : O.Vector (0 .. 2) := [others => 1.0];
      Answer : O.Vector (0 .. 1) := [17.0, -19.0];
      Status : E.Error_Info;
      procedure Refused (Code : E.Error_Code; Why : String) is
      begin
         Assert (Status.Code = Code, Why & ": " & E.Error_Code'Image (Status.Code));
         Assert (Answer (0) = 17.0 and then Answer (1) = -19.0, Why & " changed output");
      end Refused;
   begin
      O.Accumulate (Down, Up, Input (0 .. 1), 1.0, 1.0, True, Answer, Status);
      Refused (E.Tensor_Shape_Mismatch, "bad input width");
      O.Accumulate (Down, Bad_Up, Input, 1.0, 1.0, True, Answer, Status);
      Refused (E.Tensor_Shape_Mismatch, "bad rank");
      declare
         Empty : constant O.Matrix (1 .. 0, 0 .. 2) := [others => [others => 0.0]];
         Tall : constant O.Matrix (0 .. 64, 0 .. 2) := [others => [others => 1.0]];
         Wide : constant O.Matrix (0 .. 1, 0 .. 64) := [others => [others => 1.0]];
         Oversized : constant O.Matrix (0 .. 1, 0 .. O.Max_Width) := [others => [others => 0.0]];
         Long_Input : constant O.Vector (0 .. O.Max_Width) := [others => 0.0];
      begin
         O.Accumulate (Empty, Up, Input, 1.0, 1.0, True, Answer, Status);
         Refused (E.Tensor_Shape_Mismatch, "empty pair");
         O.Accumulate (Tall, Wide, Input, 1.0, 1.0, True, Answer, Status);
         Refused (E.Tensor_Rank_Too_High, "rank limit");
         O.Project (Oversized, Long_Input, Answer, Status);
         Refused (E.Tensor_Out_Of_Bounds, "width limit");
      end;
      for Bits of Bit_Patterns'([16#7FF8_0000_0000_0001#, 16#7FF0_0000_0000_0000#, 16#FFF0_0000_0000_0000#])
      loop
         Down (1, 2) := From_Bits (Bits);
         O.Accumulate (Down, Up, Input, 0.0, 1.0, True, Answer, Status);
         Refused (E.Tensor_Non_Finite_Value, "invalid last matrix value at zero scale");
         O.Project (Down, Input, Answer, Status);
         Refused (E.Tensor_Non_Finite_Value, "non-finite base value");
         Down (1, 2) := 1.0;
         Up (1, 1) := From_Bits (Bits);
         O.Accumulate (Down, Up, Input, 0.0, 1.0, True, Answer, Status);
         Refused (E.Tensor_Non_Finite_Value, "non-finite B value at zero scale");
         Up (1, 1) := 1.0;
         O.Accumulate (Down, Up, Input, From_Bits (Bits), 1.0, True, Answer, Status);
         Refused (E.Tensor_Non_Finite_Value, "non-finite scale");
         O.Accumulate (Down, Up, Input, 1.0, From_Bits (Bits), True, Answer, Status);
         Refused (E.Tensor_Non_Finite_Value, "non-finite alpha");
         Input (2) := From_Bits (Bits);
         O.Project (Down, Input, Answer, Status);
         Refused (E.Tensor_Non_Finite_Value, "non-finite input");
         Input (2) := 1.0;
      end loop;
      O.Accumulate (Down, Up, Input, 1.0, -1.0, True, Answer, Status);
      Refused (E.GGUF_Metadata_Out_Of_Range, "negative alpha");
      O.Accumulate (Down, Up, Input, 1.0, 1.0E6 + 1.0, True, Answer, Status);
      Refused (E.GGUF_Metadata_Out_Of_Range, "oversized alpha");
   end Invalid_Reference_Inputs_Preserve_Output;

   procedure Quantized_Base_Has_Independent_Values (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      Bytes : aliased B.Byte_Array (1 .. 3 * 34) := [others => 0];
      Weight : T.View;
      Expected : O.Matrix (0 .. 2, 0 .. 31);
      Input : O.Vector (0 .. 31);
      Native_Input : N.Real_Array (0 .. 31);
      Answer : O.Vector (0 .. 2) := [others => 0.0];
      Status : E.Error_Info;
   begin
      --  Q8_0, one block per row, scale 0.25 = binary16 0x3400. No quantizer or tensor decoder
      --  produces Expected: the signed codes and exact dyadic scale define it independently.
      for Row in 0 .. 2 loop
         Bytes (B.Byte_Count (Row * 34 + 2)) := 16#34#;
         for Column in 0 .. 31 loop
            declare
               Code : constant Integer := (Row * 11 + Column * 5) mod 31 - 15;
            begin
               Bytes (B.Byte_Count (Row * 34 + Column + 3)) := B.Byte (Code mod 256);
               Expected (Row, Column) := O.Number (Code) / 4.0;
            end;
         end loop;
      end loop;
      for Column in 0 .. 31 loop
         Input (Column) := O.Number (Integer (Column mod 9) - 4) / 8.0;
         Native_Input (N.Element_Count (Column)) := N.Real (Input (Column));
      end loop;
      T.Make (G.Type_Q8_0, 3, 32, Bytes'Address, Bytes'Length, 0, Weight, Status);
      Check (Status, "manual Q8_0 view");
      O.Project (Expected, Input, Answer, Status);
      Check (Status, "manual Q8_0 projection");
      for Row in 0 .. 2 loop
         Assert (O.Number (T.Row_Dot (Weight, N.Element_Count (Row), Native_Input)) = Answer (Row),
                 "native base projection differs from independently decoded Q8_0");
      end loop;
   end Quantized_Base_Has_Independent_Values;

   procedure Seven_Targets_Match_Expanded_Oracle (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      type Formats is array (Positive range <>) of G.Tensor_Type;
      type Architectures is array (Positive range <>) of Tiny_Model.Fixture_Architecture;

      procedure One (Which : P.Projection; Format : G.Tensor_Type; Alpha : Alpha_Kind;
                     Rank : Positive; Kind : Tiny_Model.Fixture_Architecture; Runtime : Boolean) is
         Image, Adapter : B.Byte_Array_Access := null;
         Layer_Index : constant Natural := (if Kind = Tiny_Model.Qwen35 and then Which <= P.Attention_Output
                                           then 1 else 0);
         Stem : constant String := "blk." & (if Layer_Index = 0 then "0." else "1.") & P.Stem (Which) & ".weight";
         Arch : constant String :=
           (case Kind is when Tiny_Model.Qwen35 => "qwen35", when Tiny_Model.Granite => "granite",
                         when others => "llama");
         Status : E.Error_Info;
      begin
         Tiny_Model.Build (Image, Format => (if Kind = Tiny_Model.Qwen35 then Tiny_Model.F32 else Tiny_Model.Q8_0),
                           Kind => Kind);
         declare
            Held : aliased constant B.Byte_Array := Image.all;
            Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
            Parsed : C.Container;
            Ready : L.Model;
            Live : L.Session;
            View : T.View;
         begin
            C.Reader.Parse (Parsed, Source, Status => Status);
            Check (Status, "quantized base parse");
            L.Prepare (Ready, Parsed, Source, Repack => (if Runtime then L.No_Repack else L.To_F32),
                       Backend => Model_Runner.Backend.Backend_Reference, Threads => 1, Status => Status);
            Check (Status, "same decoded base preparation");
            P.Read_Projection (Ready, Layer_Index, Which, View, Status);
            Check (Status, "promised projection");
            declare
               Columns : constant Positive := Positive (View.Columns);
               Rows : constant Positive := Positive (View.Rows);
               Base : O.Matrix (0 .. Rows - 1, 0 .. Columns - 1);
               Down : O.Matrix (0 .. Rank - 1, 0 .. Columns - 1);
               Up : O.Matrix (0 .. Rows - 1, 0 .. Rank - 1);
               Input : O.Vector (0 .. Columns - 1);
               Expected : O.Vector (0 .. Rows - 1) := [others => 0.0];
               Native_Input : N.Real_Array (0 .. View.Columns - 1);
               Row_Buffer : N.Real_Array (0 .. View.Columns - 1);
               Actual_Output : N.Real_Array (0 .. View.Rows - 1);
               Previous_Output : N.Real_Array (0 .. View.Rows - 1) := [others => 0.0];
               Scales : constant O.Vector := [0.75, -0.5, 0.0];
            begin
               for Row in 0 .. Rows - 1 loop
                  T.Dequantize_Row (View, N.Element_Count (Row), Row_Buffer, Status);
                  Check (Status, "decoded base row");
                  for Column in 0 .. Columns - 1 loop
                     Base (Row, Column) := O.Number (Row_Buffer (N.Element_Count (Column)));
                  end loop;
                  for K in 0 .. Rank - 1 loop
                     Up (Row, K) := B_Value (Row, K);
                  end loop;
               end loop;
               for Column in 0 .. Columns - 1 loop
                  Input (Column) := O.Number (Integer (Column mod 13) - 6) / 16.0;
                  Native_Input (N.Element_Count (Column)) := N.Real (Input (Column));
                  for K in 0 .. Rank - 1 loop
                     Down (K, Column) := A_Value (K, Column);
                  end loop;
               end loop;
               O.Project (Base, Input, Expected, Status);
               Check (Status, "oracle base");
               for Scale of Scales loop
                  Build_Adapter (Columns, Rows, Rank, Stem, Arch, Format, Alpha, None, Adapter);
                  Apply (Ready, Adapter.all, N.Real (Scale), Status, Runtime);
                  Check (Status, "F32 merge for " & Stem);
                  B.Free (Adapter);
                  --  Read only after the adapter's source and storage have gone away.
                  O.Accumulate (Down, Up, Input, Scale,
                                (if Alpha = Positive_Alpha then O.Number (Rank) * 0.5 else 0.0),
                                Alpha /= Absent, Expected, Status);
                  Check (Status, "expanded B*A*x reference");
                  if Runtime then
                     Assert (View.Format = (if Kind = Tiny_Model.Qwen35 then G.Type_F32 else G.Type_Q8_0),
                             "runtime attachment expanded the base weight");
                     L.Open (Live, Ready, Status => Status);
                     Check (Status, "runtime projection session");
                     P.Project (Live, View, Native_Input, 1, Actual_Output, Status);
                     Check (Status, "native runtime token projection");
                     if Scale = 0.0 then
                        for Row in Actual_Output'Range loop
                           Assert (N.Bits (Actual_Output (Row)) = N.Bits (Previous_Output (Row)),
                                   "zero-scale attachment changed projection bits");
                        end loop;
                     end if;
                     Previous_Output := Actual_Output;
                  end if;
                  for Row in 0 .. Rows - 1 loop
                     declare
                        Actual : constant O.Number :=
                          (if Runtime then O.Number (Actual_Output (N.Element_Count (Row)))
                           else O.Number (T.Row_Dot (View, N.Element_Count (Row), Native_Input)));
                     begin
                        Assert (abs (Actual - Expected (Row)) <= O.Absolute_Tolerance
                                  + O.Relative_Tolerance * abs Expected (Row),
                                Stem & " differs from the binary64 expanded oracle");
                     end;
                  end loop;
                  if Runtime then
                     declare
                        Inputs : N.Real_Array (0 .. 3 * View.Columns - 1);
                        Outputs : N.Real_Array (0 .. 3 * View.Rows - 1);
                        Ratios : constant O.Vector := [1.0, -0.5, 0.0];
                     begin
                        for Position in 0 .. 2 loop
                           for Column in 0 .. Columns - 1 loop
                              Inputs (N.Element_Count (Position * Columns + Column)) :=
                                Native_Input (N.Element_Count (Column)) * N.Real (Ratios (Position));
                           end loop;
                        end loop;
                        P.Project (Live, View, Inputs, 3, Outputs, Status);
                        Check (Status, "native runtime partial batch projection");
                        for Position in 0 .. 2 loop
                           for Row in 0 .. Rows - 1 loop
                              declare
                                 Want : constant O.Number := Expected (Row) * Ratios (Position);
                                 Got : constant O.Number :=
                                   O.Number (Outputs (N.Element_Count (Position * Rows + Row)));
                              begin
                                 Assert (abs (Want - Got) <= O.Absolute_Tolerance + O.Relative_Tolerance * abs Want,
                                         Stem & " batch row differs from oracle");
                              end;
                           end loop;
                        end loop;
                     end;
                     L.Close (Live);
                  end if;
               end loop;
            end;
            L.Close (Ready, Status);
            Check (Status, "model close");
            C.Close (Parsed);
         end;
         B.Free (Image);
      exception
         when others => B.Free (Image); B.Free (Adapter); raise;
      end One;
   begin
      for Runtime in Boolean loop
         for Kind of Architectures'([Tiny_Model.Llama, Tiny_Model.Qwen35, Tiny_Model.Granite]) loop
            for Which in P.Projection loop
               for Format of Formats'([G.Type_F32, G.Type_F16]) loop
                  for Alpha in Alpha_Kind loop
                     One (Which, Format, Alpha, (if Alpha = Zero then 3 else 2), Kind, Runtime);
                  end loop;
               end loop;
            end loop;
         end loop;
      end loop;
   end Seven_Targets_Match_Expanded_Oracle;

   procedure Malformed_Pairs_Are_Refused (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      Image, Adapter : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build (Image);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : C.Container;
         Ready : L.Model;
         View : T.View;
         Input : constant N.Real_Array (0 .. Tiny_Model.Embedding - 1) := [others => 0.25];
         Before : N.Real;
      begin
         C.Reader.Parse (Parsed, Source, Status => Status);
         Check (Status, "malformed controls base parse");
         L.Prepare (Ready, Parsed, Source, Repack => L.To_F32, Status => Status);
         Check (Status, "malformed controls base prepare");
         P.Read_Projection (Ready, 0, P.Attention_Query, View, Status);
         Check (Status, "malformed controls view");
         Before := T.Row_Dot (View, 0, Input);
         for Broken in Half_Pair .. Activated loop
            Build_Adapter (Tiny_Model.Embedding, Tiny_Model.Embedding, 2, "blk.0.attn_q.weight", "llama",
                           G.Type_F32, Positive_Alpha, Broken, Adapter);
            Apply (Ready, Adapter.all, 1.0, Status);
            Assert (Status.Code = (case Broken is
                                      when Wrong_Input | Wrong_Output | Wrong_Rank => E.Arch_Invalid_Tensor_Shape,
                                      when Foreign_Type | Activated => E.Arch_Unsupported_Feature,
                                      when others => E.Arch_Missing_Tensor),
                    "bad pair " & Fault'Image (Broken) & " was accepted or misclassified");
            B.Free (Adapter);
            Assert (T.Row_Dot (View, 0, Input) = Before, "a refused first pair changed the base");
         end loop;
         L.Close (Ready, Status);
         Check (Status, "malformed controls model close");
         C.Close (Parsed);
      end;
      B.Free (Image);
   exception
      when others => B.Free (Image); B.Free (Adapter); raise;
   end Malformed_Pairs_Are_Refused;

   procedure Late_Invalid_Pairs_Preserve_Model (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      pragma Suppress (Validity_Check);
      Image, Adapter : B.Byte_Array_Access := null;
      Status : E.Error_Info;
   begin
      Tiny_Model.Build (Image);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : C.Container;
         Ready : L.Model;
         Query, Key : T.View;
         Input : constant N.Real_Array (0 .. Tiny_Model.Embedding - 1) := [others => 0.25];
         Before_Query, Before_Key : N.Real;
         Identity : Interfaces.Unsigned_64;
      begin
         C.Reader.Parse (Parsed, Source, Status => Status);
         Check (Status, "late controls base parse");
         L.Prepare (Ready, Parsed, Source, Repack => L.To_F32, Status => Status);
         Check (Status, "late controls base prepare");
         P.Read_Projection (Ready, 0, P.Attention_Query, Query, Status);
         Check (Status, "late controls query view");
         P.Read_Projection (Ready, 0, P.Attention_Key, Key, Status);
         Check (Status, "late controls key view");
         Build_Adapter (Tiny_Model.Embedding, Tiny_Model.Embedding, 2, "blk.0.attn_q.weight", "llama",
                        G.Type_F32, Positive_Alpha, None, Adapter);
         Apply (Ready, Adapter.all, 1.0, Status);
         Check (Status, "existing attachment before rejected stack");
         B.Free (Adapter);
         Before_Query := T.Row_Dot (Query, 0, Input);
         Before_Key := T.Row_Dot (Key, 0, Input);
         Identity := L.Fingerprint (Ready);
         for Broken in Late_Shape .. Overflowing_Delta loop
            Build_Adapter (Tiny_Model.Embedding, Tiny_Model.Embedding, 2, "blk.0.attn_q.weight", "llama",
                           G.Type_F32, Positive_Alpha, Broken, Adapter);
            Apply (Ready, Adapter.all, 1.0, Status);
            Assert (Status.Code = (case Broken is
                                      when Late_Shape => E.Arch_Invalid_Tensor_Shape,
                                      when Late_Non_Finite | Non_Finite_Down | Overflowing_Delta =>
                                         E.Tensor_Non_Finite_Value,
                                      when others => E.GGUF_Metadata_Out_Of_Range),
                    "late pair or invalid alpha was accepted or misclassified");
            B.Free (Adapter);
            Assert (T.Row_Dot (Query, 0, Input) = Before_Query and then T.Row_Dot (Key, 0, Input) = Before_Key,
                    "a rejected adapter changed earlier projections");
            Assert (L.Fingerprint (Ready) = Identity, "a rejected adapter changed model identity");
         end loop;
         --  Even a zero scale validates the complete payload; valid zero scale must not change a projection.
         Build_Adapter (Tiny_Model.Embedding, Tiny_Model.Embedding, 2, "blk.0.attn_q.weight", "llama",
                        G.Type_F32, Positive_Alpha, Non_Finite_Down, Adapter);
         Apply (Ready, Adapter.all, 0.0, Status);
         Assert (Status.Code = E.Tensor_Non_Finite_Value, "zero scale bypassed payload validation");
         B.Free (Adapter);
         Build_Adapter (Tiny_Model.Embedding, Tiny_Model.Embedding, 2, "blk.0.attn_q.weight", "llama",
                        G.Type_F32, Positive_Alpha, None, Adapter);
         declare
            type Bad_Scales is array (Positive range <>) of Interfaces.Unsigned_32;
         begin
            for Bits of Bad_Scales'([16#7FC0_0001#, 16#7F80_0000#, 16#FF80_0000#]) loop
               Apply (Ready, Adapter.all, N.From_Bits (Bits), Status);
               Assert (Status.Code = E.Tensor_Non_Finite_Value, "non-finite API scale was not refused");
               Assert (L.Fingerprint (Ready) = Identity, "non-finite scale changed identity");
            end loop;
         end;
         Apply (Ready, Adapter.all, 0.0, Status);
         Check (Status, "valid zero scale");
         Assert (T.Row_Dot (Query, 0, Input) = Before_Query and then T.Row_Dot (Key, 0, Input) = Before_Key,
                 "zero scale changed model projections");
         B.Free (Adapter);
         L.Close (Ready, Status);
         Check (Status, "late controls model close");
         C.Close (Parsed);
      end;
      B.Free (Image);
   exception
      when others => B.Free (Image); B.Free (Adapter); raise;
   end Late_Invalid_Pairs_Preserve_Model;

   procedure Adapter_Content_Binds_Saved_Context (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      Width : constant Positive := Tiny_Model.Deep_Embedding;
      Rank : constant Positive := 64;
      Payload_Length : constant B.Byte_Count := B.Byte_Count (2 * Width * Rank * 4);
      pragma Compile_Time_Error (Payload_Length <= 65_536, "identity fixture must span multiple hash chunks");
      Image, Adapter, Kept, Original_Adapter : B.Byte_Array_Access := null;
      Status : E.Error_Info;
      Saved_Size : B.Byte_Count := 0;
      Runtime_Mode : Boolean := False;

      procedure With_Model (Tweak, Take : Boolean; Result : out E.Error_Info; Swap : Boolean := False) is
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : C.Container;
         Ready : L.Model;
         Live : L.Session;
         Logits : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
         Local : E.Error_Info;
      begin
         C.Reader.Parse (Parsed, Source, Status => Local);
         Check (Local, "context content base parse");
         L.Prepare (Ready, Parsed, Source,
                    Repack => (if Runtime_Mode then L.No_Repack else L.To_F32), Status => Local);
         Check (Local, "context content base prepare");
         --  Establish the base's cached sample before either merge: the adapter's complete identity
         --  must distinguish the effective models without relying on resampling mutated weights.
         Assert (L.Fingerprint (Ready) /= 0, "base fingerprint unavailable");
         Build_Adapter (Width, Width, Rank, "blk.0.attn_q.weight", "llama",
                        G.Type_F32, Positive_Alpha, None, Adapter, Tweak, Swap);
         if Saved_Size = 0 then
            Saved_Size := Adapter'Length;
            Original_Adapter := new B.Byte_Array'(Adapter.all);
         else
            Assert (Adapter'Length = Saved_Size, "identity control changed the adapter's size");
         end if;
         if Tweak then
            Assert (Adapter (Adapter'First .. Adapter'Last - 1)
                      = Original_Adapter (Original_Adapter'First .. Original_Adapter'Last - 1)
                      and then Adapter (Adapter'Last) /= Original_Adapter (Original_Adapter'Last),
                    "identity control must change only the last byte, beyond the first hash chunk");
         end if;
         if Swap then
            --  Only descriptor offsets changed. Full payload hashing alone must not accept this adapter.
            Assert (Adapter (Adapter'Last - Payload_Length + 1 .. Adapter'Last)
                      = Original_Adapter (Original_Adapter'Last - Payload_Length + 1 .. Original_Adapter'Last),
                    "offset control changed tensor payload bytes");
         end if;
         Apply (Ready, Adapter.all, 1.0, Local, Runtime => Runtime_Mode);
         Check (Local, "context content merge");
         B.Free (Adapter);
         L.Open (Live, Ready, Status => Local);
         Check (Local, "context content session");
         if Take then
            L.Evaluate (Live, Ready, 4, Logits, Status => Local);
            Check (Local, "context content token");
            L.Snapshot (Live, Ready, Kept, Result);
         else
            L.Adopt (Live, Ready, Kept.all, Result);
         end if;
         L.Close (Live);
         L.Close (Ready, Local);
         Check (Local, "context content model close");
         C.Close (Parsed);
      end With_Model;
   begin
      Tiny_Model.Build (Image, Tiny_Model.Q4_K);
      With_Model (Tweak => False, Take => True, Result => Status);
      Check (Status, "content snapshot");
      With_Model (Tweak => False, Take => False, Result => Status);
      Check (Status, "same content round trip");
      With_Model (Tweak => True, Take => False, Result => Status);
      Assert (Status.Code = E.Lifecycle_Cache_Mismatched,
              "a saved context accepted another same-sized adapter's weights");
      With_Model (Tweak => False, Take => False, Result => Status, Swap => True);
      Assert (Status.Code = E.Lifecycle_Cache_Mismatched,
              "a saved context accepted changed tensor offsets with identical payload bytes");
      B.Free (Kept);
      B.Free (Original_Adapter);
      Runtime_Mode := True;
      Saved_Size := 0;
      With_Model (Tweak => False, Take => True, Result => Status);
      Check (Status, "runtime content snapshot");
      With_Model (Tweak => False, Take => False, Result => Status);
      Check (Status, "runtime same content round trip");
      With_Model (Tweak => True, Take => False, Result => Status);
      Assert (Status.Code = E.Lifecycle_Cache_Mismatched, "runtime snapshot accepted changed matrix content");
      With_Model (Tweak => False, Take => False, Result => Status, Swap => True);
      Assert (Status.Code = E.Lifecycle_Cache_Mismatched, "runtime snapshot accepted relocated matrix values");
      Runtime_Mode := False;
      With_Model (Tweak => False, Take => False, Result => Status);
      Assert (Status.Code = E.Lifecycle_Cache_Mismatched, "snapshot accepted a different adapter execution mode");
      B.Free (Kept);
      B.Free (Original_Adapter);
      B.Free (Image);
   exception
      when others => B.Free (Image); B.Free (Adapter); B.Free (Kept); B.Free (Original_Adapter); raise;
   end Adapter_Content_Binds_Saved_Context;

   procedure Runtime_Tokens_And_Batches_Match_Merge (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      package CPU renames Model_Runner.Backend.CPU;
      Old_Roles : constant CPU.Role_Set := CPU.Integer_Activation_Roles;
      type Kinds is array (Positive range <>) of Tiny_Model.Fixture_Architecture;
      type Backends is array (Positive range <>) of Model_Runner.Backend.Backend_Kind;
      type Ranks is array (Positive range <>) of Positive;
      Image, Adapter : B.Byte_Array_Access := null;

      procedure One
        (Kind : Tiny_Model.Fixture_Architecture; Backend : Model_Runner.Backend.Backend_Kind;
         Rank : Positive; Packed : Boolean := False) is
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : C.Container;
         Runtime, Merged : L.Model;
         Token_Live, Batch_Live, Reference_Live : L.Session;
         Status : E.Error_Info;
         Tokens : constant Model_Runner.Tokenizer.Token_Array := [1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
         Token_Result, Batch_Result, Reference_Result : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
         View : T.View;
         procedure Agree (Left, Right : N.Real_Array; Why : String) is
         begin
            for Index in Left'Range loop
               Assert (abs (Left (Index) - Right (Index)) <= 1.0E-4 + 1.0E-4 * abs Right (Index), Why);
            end loop;
         end Agree;
      begin
         C.Reader.Parse (Parsed, Source, Status => Status);
         Check (Status, "runtime end-to-end parse");
         L.Prepare (Runtime, Parsed, Source, Backend => Backend,
                    Repack => (if Packed then L.To_Rows else L.No_Repack), Status => Status);
         Check (Status, "quantized runtime prepare");
         L.Prepare (Merged, Parsed, Source, Backend => Model_Runner.Backend.Backend_Reference,
                    Repack => L.To_F32, Status => Status);
         Check (Status, "same-base F32 reference prepare");
         for Which in P.Projection loop
            declare
               Layer_Index : constant Natural := (if Kind = Tiny_Model.Qwen35 and then Which <= P.Attention_Output
                                                 then 1 else 0);
               Stem : constant String := "blk." & (if Layer_Index = 0 then "0." else "1.") & P.Stem (Which) & ".weight";
            begin
               P.Read_Projection (Runtime, Layer_Index, Which, View, Status);
               Check (Status, "end-to-end target");
               Assert (not Packed or else View.Interleaved, "packed test did not interleave its projection");
               Build_Adapter (Positive (View.Columns), Positive (View.Rows), Rank, Stem,
                              C.String_Value (Parsed, "general.architecture"),
                              (if P.Projection'Pos (Which) mod 2 = 0 then G.Type_F16 else G.Type_F32),
                              Positive_Alpha, None, Adapter);
               Apply (Runtime, Adapter.all, 0.25, Status, Runtime => True);
               Check (Status, "end-to-end attachment");
               Apply (Merged, Adapter.all, 0.25, Status);
               Check (Status, "end-to-end reference merge");
               B.Free (Adapter);
            end;
         end loop;
         Assert (L.Runtime_Adapter_Count (Runtime) = 7 and then L.Runtime_Adapter_Bytes (Runtime) > 0,
                 "runtime attachment accounting is missing");
         L.Open (Token_Live, Runtime, Status => Status);
         Check (Status, "runtime token session");
         Assert (not L.Drafts_Next (Token_Live), "runtime session advertised unsupported next-layer drafting");
         declare
            State : constant N.Real_Array (1 .. 0) := [];
            Next_State : N.Real_Array (1 .. 0);
         begin
            L.Draft_Next (Token_Live, Runtime, 1, State, 0, Token_Result, Next_State, Status);
            Assert (Status.Code = E.Arch_Unsupported_Feature, "runtime session executed unsupported drafting");
         end;
         L.Open (Batch_Live, Runtime, Status => Status);
         Check (Status, "independent runtime batch session");
         L.Open (Reference_Live, Merged, Status => Status);
         Check (Status, "reference session");
         for Token of Tokens loop
            L.Evaluate (Token_Live, Runtime, Token, Token_Result, Status => Status);
            Check (Status, "runtime token");
            L.Evaluate (Reference_Live, Merged, Token, Reference_Result, Status => Status);
            Check (Status, "reference token");
            Agree (Token_Result, Reference_Result, "runtime token logits differ from same-base merge");
         end loop;
         L.Evaluate_Batch (Batch_Live, Runtime, Tokens (1 .. 8), Batch_Result, Status => Status);
         if Backend = Model_Runner.Backend.Backend_Reference then
            Assert (Status.Code = E.Backend_Capability_Missing, "reference batch capability changed silently");
         else
            Check (Status, "runtime prompt batch " & Tiny_Model.Fixture_Architecture'Image (Kind));
            L.Evaluate_Batch (Batch_Live, Runtime, Tokens (9 .. 11), Batch_Result, Status => Status);
            Check (Status, "runtime prompt tail");
            Agree (Token_Result, Batch_Result, "runtime batch/tail logits differ from token route");
         end if;
         L.Close (Token_Live);
         L.Close (Batch_Live);
         L.Close (Reference_Live);
         L.Close (Runtime, Status);
         Check (Status, "runtime model cleanup");
         Assert (L.Runtime_Adapter_Count (Runtime) = 0 and then L.Runtime_Adapter_Bytes (Runtime) = 0,
                 "runtime ownership survived close");
         L.Close (Merged, Status);
         Check (Status, "reference model cleanup");
         C.Close (Parsed);
      end One;
   begin
      CPU.Use_Integer_Activations (CPU.No_Role);
      for Kind of Kinds'([Tiny_Model.Llama, Tiny_Model.Qwen2, Tiny_Model.Qwen3, Tiny_Model.Qwen35,
                          Tiny_Model.Granite]) loop
         Tiny_Model.Build (Image, Tiny_Model.Q8_0, Kind => Kind);
         for Backend of Backends'([Model_Runner.Backend.Backend_CPU, Model_Runner.Backend.Backend_Reference]) loop
            for Rank of Ranks'([2, 32, 64]) loop
               One (Kind, Backend, Rank);
            end loop;
         end loop;
         if Kind = Tiny_Model.Granite then
            One (Kind, Model_Runner.Backend.Backend_CPU, 32, Packed => True);
         end if;
         B.Free (Image);
      end loop;
      CPU.Use_Integer_Activations (Old_Roles);
   exception
      when others =>
         CPU.Use_Integer_Activations (Old_Roles);
         B.Free (Image);
         B.Free (Adapter);
         raise;
   end Runtime_Tokens_And_Batches_Match_Merge;

   procedure Runtime_Load_Is_Transactional (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      Image, Adapter : B.Byte_Array_Access := null;
      Status : E.Error_Info;
      Stop : aliased Model_Runner.Cancellation.Token;
   begin
      Tiny_Model.Build (Image, Tiny_Model.Q8_0);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : C.Container;
         Ready : L.Model;
         Live : L.Session;
         View : T.View;
         Before : Model_Runner.Memory.Account;
         Identity : Interfaces.Unsigned_64;
         Budget : L.Adapter_Limits := L.Default_Adapter_Limits;
         Base_Plan, Runtime_Plan : Model_Runner.Memory.Session_Plan;
         Session_Bounds : Model_Runner.Limits.Session_Limits := Model_Runner.Limits.Default_Session_Limits;
      begin
         C.Reader.Parse (Parsed, Source, Status => Status);
         Check (Status, "transaction base parse");
         L.Prepare (Ready, Parsed, Source, Backend => Model_Runner.Backend.Backend_Reference, Status => Status);
         Check (Status, "transaction base prepare");
         Before := L.Account (Ready);
         Identity := L.Fingerprint (Ready);
         for Broken in Half_Pair .. Non_Finite_Down loop
            Build_Adapter (Tiny_Model.Wide_Embedding, Tiny_Model.Wide_Embedding, 2, "blk.0.attn_q.weight", "llama",
                           G.Type_F32, Positive_Alpha, Broken, Adapter);
            Apply (Ready, Adapter.all, 1.0, Status, Runtime => True);
            Assert (E.Is_Error (Status), "runtime loader accepted " & Fault'Image (Broken));
            Assert (L.Runtime_Adapter_Count (Ready) = 0 and then L.Runtime_Adapter_Bytes (Ready) = 0,
                    "failed attachment published ownership");
            Assert (L.Fingerprint (Ready) = Identity and then L.Account (Ready) = Before,
                    "failed attachment changed identity or accounting");
            B.Free (Adapter);
         end loop;
         for Broken in Rank_Three .. Extra_Target loop
            Build_Adapter (Tiny_Model.Wide_Embedding, Tiny_Model.Wide_Embedding, 32, "blk.0.attn_q.weight", "llama",
                           G.Type_F32, Positive_Alpha, Broken, Adapter);
            Apply (Ready, Adapter.all, 1.0, Status, Runtime => True);
            Assert (E.Is_Error (Status) and then L.Account (Ready) = Before
                      and then L.Fingerprint (Ready) = Identity, "runtime accepted an unsupported descriptor");
            B.Free (Adapter);
         end loop;
         Build_Adapter (Tiny_Model.Wide_Embedding, Tiny_Model.Wide_Embedding, 2, "blk.0.attn_q.weight", "llama",
                        G.Type_F16, Positive_Alpha, Non_Finite_Down, Adapter);
         Apply (Ready, Adapter.all, 0.0, Status, Runtime => True);
         Assert (Status.Code = E.Tensor_Non_Finite_Value and then L.Account (Ready) = Before,
                 "zero scale skipped F16 payload validation");
         B.Free (Adapter);
         Build_Adapter (Tiny_Model.Wide_Embedding, Tiny_Model.Wide_Embedding, 2, "blk.0.attn_q.weight", "llama",
                        G.Type_F16, Positive_Alpha, None, Adapter);
         Budget.Max_Bytes := 1;
         Apply (Ready, Adapter.all, 1.0, Status, True, Budget);
         Assert (Status.Code = E.Memory_Limit_Exceeded, "storage limit was ignored");
         Assert (L.Account (Ready) = Before, "storage refusal changed account");
         Budget := L.Default_Adapter_Limits;
         Budget.Max_Rank := 1;
         Apply (Ready, Adapter.all, 1.0, Status, True, Budget);
         Assert (Status.Code = E.Arch_Invalid_Tensor_Shape and then L.Account (Ready) = Before,
                 "rank limit changed the model");
         Budget := L.Default_Adapter_Limits;
         declare
            Held_Adapter : aliased constant B.Byte_Array := Adapter.all;
            Reader : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held_Adapter'Access);
            Descriptor : C.Container;
         begin
            C.Reader.Parse (Descriptor, Reader, Status => Status);
            Check (Status, "fault descriptor parse");
            for Fault in Read_Fault loop
               declare
                  Faulty : Fault_Source;
               begin
                  Stop.Reset;
                  Faulty.Data := Adapter;
                  Faulty.Stop := Stop'Unchecked_Access;
                  Faulty.Fault := Fault;
                  L.Attach_Adapter (Ready, Descriptor, Faulty, Status => Status, Cancel => Stop'Unchecked_Access);
                  Assert (E.Is_Error (Status), "runtime accepted " & Read_Fault'Image (Fault));
                  Assert (L.Account (Ready) = Before and then L.Fingerprint (Ready) = Identity
                            and then L.Runtime_Adapter_Count (Ready) = 0, "failed read changed model state");
                  if Fault = Cancel_Read then
                     Assert (Faulty.Reads > 0 and then Status.Code = E.Generation_Cancelled,
                             "cancellation did not occur after a successful payload read");
                  end if;
               end;
            end loop;
            C.Close (Descriptor);
         end;
         Stop.Request;
         Apply (Ready, Adapter.all, 1.0, Status, True, Budget, Stop'Unchecked_Access);
         Assert (Status.Code = E.Generation_Cancelled and then L.Fingerprint (Ready) = Identity,
                 "cancelled attachment changed the model");
         Stop.Reset;
         L.Plan_Session (Ready, Tiny_Model.Context, Base_Plan, Status);
         Check (Status, "unadapted plan");
         Budget.Max_Adapters := 1;
         Apply (Ready, Adapter.all, 1.0, Status, True, Budget);
         Check (Status, "valid runtime load");
         Assert (L.Account (Ready).Current - Before.Current = L.Runtime_Adapter_Bytes (Ready),
                 "owned adapter storage was not charged");
         Identity := L.Fingerprint (Ready);
         Before := L.Account (Ready);
         Apply (Ready, Adapter.all, 1.0, Status, True, Budget);
         Assert (Status.Code = E.Memory_Limit_Exceeded and then L.Account (Ready) = Before
                   and then L.Fingerprint (Ready) = Identity, "file limit damaged an existing attachment");
         L.Plan_Session (Ready, Tiny_Model.Context, Runtime_Plan, Status);
         Check (Status, "runtime plan");
         Assert (Runtime_Plan.Activation_Bytes - Base_Plan.Activation_Bytes
                   = 4 * 8 * (Tiny_Model.Wide_Embedding + 2), "session plan omitted bounded adapter scratch");
         Session_Bounds.Max_Session_Bytes := Base_Plan.Total_Resident;
         L.Open (Live, Ready, Context => Tiny_Model.Context, Session_Bounds => Session_Bounds, Status => Status);
         Assert (Status.Code = E.Memory_Limit_Exceeded, "session admission ignored adapter scratch");
         L.Open (Live, Ready, Status => Status);
         Check (Status, "runtime lifecycle session");
         Apply (Ready, Adapter.all, 1.0, Status, Runtime => True);
         Assert (Status.Code = E.Lifecycle_Session_Active, "attachment changed an active session's weights");
         L.Close (Ready, Status);
         Assert (Status.Code = E.Lifecycle_Session_Active, "model closed beneath an adapter session");
         L.Close (Live);
         Apply (Ready, Adapter.all, 1.0, Status);
         Assert (Status.Code = E.Arch_Unsupported_Feature, "runtime and merge modes were mixed");
         P.Read_Projection (Ready, 0, P.Attention_Query, View, Status);
         Check (Status, "retained quantized target");
         Assert (View.Format = G.Type_Q8_0, "runtime load expanded quantized weights");
         B.Free (Adapter);
         L.Close (Ready, Status);
         Check (Status, "transaction cleanup");
         C.Close (Parsed);
      end;
      B.Free (Image);
   exception
      when others => B.Free (Image); B.Free (Adapter); raise;
   end Runtime_Load_Is_Transactional;

   procedure Wide_Fixture_And_Paired_Timing (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      package J renames Jsonlib.Documents;
      use type J.Value_Kind;
      use type Jsonlib.Errors.Error_Code;
      Root : constant String := "obj/adapter-benchmark-contract";
      Clean : Boolean;
      Doc : J.Document;
      Parsed_JSON : Jsonlib.Errors.Error_Info;
      Status : E.Error_Info;
      File : Model_Runner.Byte_Sources.Files.File_Source;
      Descriptor : C.Container;
   begin
      if Ada.Directories.Exists (Root) then
         Ada.Directories.Delete_Tree (Root);
      end if;
      Ada.Directories.Create_Path (Root);
      Tiny_Model.Write (Root & "/base.gguf", Format => Tiny_Model.Q8_0, Kind => Tiny_Model.Qwen35);
      Project_Tools.Files.Write_Raw_File (Root & "/prompt.txt", "hello");
      Adapter_Fixture.Run (Root & "/base.gguf", Root & "/bad.gguf", "", Clean, Rank => 65, All_Targets => True);
      Assert (not Clean and then not Ada.Directories.Exists (Root & "/bad.gguf"), "unbounded rank wrote a fixture");
      Adapter_Fixture.Run (Root & "/base.gguf", Root & "/adapter.gguf", "", Clean, Rank => 32, All_Targets => True);
      Assert (Clean, "wide hybrid fixture did not build");
      Model_Runner.Byte_Sources.Files.Open (File, Root & "/adapter.gguf", Status => Status);
      Check (Status, "wide fixture open");
      C.Reader.Parse (Descriptor, File, Status => Status);
      Check (Status, "wide fixture parse");
      Assert (C.Tensor_Count (Descriptor) = 20, "wide hybrid fixture omitted a main target or included draft weights");
      Assert (C.Find_Tensor (Descriptor, "blk.2.ffn_gate.weight.lora_a") = 0, "fixture included next-layer weights");
      Assert (C.Tensor_Dimension (Descriptor, 1, 2) = 32, "fixture did not use the requested rank");
      C.Close (Descriptor);
      Model_Runner.Byte_Sources.Files.Close (File);
      Adapter_Fixture.Run (Root & "/base.gguf", Root & "/adapter.gguf", "", Clean, All_Targets => True);
      Assert (not Clean, "fixture overwrote an existing file");
      Adapter_Benchmark.Run
        (Root & "/base.gguf", Root & "/adapter.gguf", Root & "/prompt.txt", Root & "/bad.json", Clean,
         Repeats => 22);
      Assert (not Clean and then not Ada.Directories.Exists (Root & "/bad.json"), "unbounded benchmark wrote a report");
      Adapter_Benchmark.Run
        (Root & "/base.gguf", Root & "/adapter.gguf", Root & "/prompt.txt", Root & "/timing.json", Clean,
         Repeats => 2, Tokens => 2, Threads => 1, Batch => 3, Context => Tiny_Model.Context, Include_Merge => True);
      Assert (Clean, "paired native timing failed its fixed-work or zero-scale control");
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Root & "/timing.json"), Doc, Parsed_JSON);
      Assert (Parsed_JSON.Code = Jsonlib.Errors.No_Error, "benchmark report is not JSON");
      declare
         Base : constant J.Node := J.Root (Doc);
         Samples : constant J.Node := J.Member (Doc, Base, "samples");
         Summary : constant J.Node := J.Member (Doc, Base, "summary");
      begin
         Assert (J.Length (Doc, Samples) = 8 and then J.Length (Doc, Summary) = 4,
                 "benchmark lost a paired arm or summary");
         Assert (J.As_String (Doc, J.Member (Doc, J.Element (Doc, Samples, 1), "arm")) = "base"
                   and then J.As_String (Doc, J.Member (Doc, J.Element (Doc, Samples, 5), "arm")) = "merge",
                 "benchmark did not reverse arm order");
         Assert (J.Kind (Doc, J.Member (Doc, Base, "peak_rss_bytes")) = J.Null_Value,
                 "benchmark fabricated unavailable memory residency");
      end;
      Tiny_Model.Write_Adapter (Root & "/half.gguf", Half => True, For_Arch => "qwen35");
      Adapter_Benchmark.Run
        (Root & "/base.gguf", Root & "/half.gguf", Root & "/prompt.txt", Root & "/failure.json", Clean,
         Repeats => 1, Tokens => 2, Threads => 1, Batch => 3, Context => Tiny_Model.Context);
      Assert (not Clean, "invalid attachment was counted as a successful performance comparison");
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Root & "/failure.json"), Doc, Parsed_JSON);
      Assert (Parsed_JSON.Code = Jsonlib.Errors.No_Error, "failed performance report is not JSON");
      Assert (J.Length (Doc, J.Member (Doc, J.Root (Doc), "summary")) = 0,
              "failed attachment was published as a fast timing summary");
   end Wide_Fixture_And_Paired_Timing;

   procedure Tiled_Adapters_Preserve_Oracle_And_Failures (Test : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (Test);
      pragma Suppress (Validity_Check);
      package CPU renames Model_Runner.Backend.CPU;
      Width : constant Positive := Tiny_Model.Deep_Embedding;
      Rank : constant Positive := 64;
      Positions : constant N.Element_Count := 33;
      W : constant N.Element_Count := N.Element_Count (Width);
      Image, Adapter : B.Byte_Array_Access := null;
      Team : aliased CPU.Pool (3);
      Ready : L.Model;
      Live : L.Session;
      Status : E.Error_Info;
      Stop : aliased Model_Runner.Cancellation.Token;
      View : T.View;
      Inputs : N.Real_Array (7 .. 7 + (Positions + 1) * W - 1);
      Outputs : N.Real_Array (13 .. 13 + (Positions + 1) * W - 1);
      type Counts is array (Positive range <>) of N.Element_Count;
      Expected : O.Matrix (0 .. 16, 0 .. Width - 1);
   begin
      Tiny_Model.Build (Image, Tiny_Model.Q4_K);
      declare
         Held : aliased constant B.Byte_Array := Image.all;
         Source : Model_Runner.Byte_Sources.Memory.Buffer_Source (Held'Access);
         Parsed : C.Container;
      begin
         C.Reader.Parse (Parsed, Source, Status => Status);
         Check (Status, "tiled base parse");
         L.Prepare (Ready, Parsed, Source, Backend => Model_Runner.Backend.Backend_CPU, Status => Status);
         Check (Status, "tiled base prepare");
         P.Read_Projection (Ready, 0, P.Attention_Query, View, Status);
         Check (Status, "tiled target");
         for Pass in 1 .. 3 loop
            Build_Adapter (Width, Width, (if Pass = 2 then 3 else Rank), "blk.0.attn_q.weight", "llama",
                           G.Type_F32, Positive_Alpha, None, Adapter);
            Apply (Ready, Adapter.all, (if Pass = 1 then 0.75 elsif Pass = 2 then -0.5 else 0.0),
                   Status, Runtime => True);
            Check (Status, "tiled stacked attachment");
            B.Free (Adapter);
         end loop;
         for Position in 0 .. 16 loop
            declare
               Down : O.Matrix (0 .. Rank - 1, 0 .. Width - 1);
               Up : O.Matrix (0 .. Width - 1, 0 .. Rank - 1);
               Small_Down : O.Matrix (0 .. 2, 0 .. Width - 1);
               Small_Up : O.Matrix (0 .. Width - 1, 0 .. 2);
               X : O.Vector (0 .. Width - 1);
               Y : O.Vector (0 .. Width - 1) := [others => 3.25];
            begin
               for Column in 0 .. Width - 1 loop
                  X (Column) := O.Number (Integer ((Position * 7 + Column * 3) mod 17) - 8) / 32.0;
                  for K in 0 .. Rank - 1 loop
                     Down (K, Column) := A_Value (K, Column);
                     Up (Column, K) := B_Value (Column, K);
                     if K < 3 then
                        Small_Down (K, Column) := Down (K, Column);
                        Small_Up (Column, K) := Up (Column, K);
                     end if;
                  end loop;
               end loop;
               O.Accumulate (Down, Up, X, 0.75, O.Number (Rank) * 0.5, True, Y, Status);
               Check (Status, "tiled rank64 oracle");
               O.Accumulate (Small_Down, Small_Up, X, -0.5, 1.5, True, Y, Status);
               Check (Status, "tiled rank3 oracle");
               for Row in 0 .. Width - 1 loop
                  Expected (Position, Row) := Y (Row);
               end loop;
            end;
         end loop;
         for Position in 0 .. Positions - 1 loop
            for Column in 0 .. Width - 1 loop
               Inputs (Inputs'First + Position * W + N.Element_Count (Column)) :=
                 N.Real (Integer ((Natural (Position mod 17) * 7 + Column * 3) mod 17) - 8) / 32.0;
            end loop;
         end loop;
         --  A poisoned unused row detects reads beyond Count, including on partial tiles.
         Inputs (Inputs'First + Positions * W .. Inputs'Last) := [others => N.From_Bits (16#7FC0_0000#)];
         for Parallel in Boolean loop
            if Parallel then
               CPU.Open (Team);
            end if;
            L.Open (Live, Ready, Workers => (if Parallel then Team'Unchecked_Access else null), Status => Status);
            Check (Status, "tiled session");
            for Count of Counts'([1, 3, 7, 8, 9, 15, 16, 17, 33]) loop
               Outputs := [others => 3.25];
               P.Accumulate (Live, View, Inputs, Count, Outputs, Status);
               Check (Status, "native tiled delta");
               for Position in 0 .. Count - 1 loop
                  for Row in 0 .. Width - 1 loop
                     declare
                        Want : constant O.Number := Expected (Natural (Position mod 17), Row);
                        Got : constant O.Number := O.Number (Outputs
                          (Outputs'First + Position * W + N.Element_Count (Row)));
                     begin
                        Assert (abs (Got - Want) <= O.Absolute_Tolerance + O.Relative_Tolerance * abs Want,
                                "tiled delta differs from independent expanded oracle");
                     end;
                  end loop;
               end loop;
               for Index in Outputs'First + Count * W .. Outputs'Last loop
                  Assert (Outputs (Index) = 3.25, "tile wrote an unused output row");
               end loop;
            end loop;
            declare
               Edge_In : N.Real_Array (N.Element_Count'Last - 2 * W + 1 .. N.Element_Count'Last);
               Edge_Out : N.Real_Array (Edge_In'Range) := [others => 3.25];
            begin
               Edge_In := Inputs (Inputs'First .. Inputs'First + 2 * W - 1);
               P.Accumulate (Live, View, Edge_In, 2, Edge_Out, Status);
               Check (Status, "tile at the maximum array origin");
               for Cell in 0 .. 2 * W - 1 loop
                  declare
                     Want : constant O.Number := Expected (Natural (Cell / W), Natural (Cell mod W));
                     Got : constant O.Number := O.Number (Edge_Out (Edge_Out'First + Cell));
                  begin
                     Assert (abs (Got - Want) <= O.Absolute_Tolerance + O.Relative_Tolerance * abs Want,
                             "tile lost a maximum-origin array bound");
                  end;
               end loop;
            end;
            Outputs := [others => 3.25];
            P.Accumulate (Live, View, Inputs, Positions + 2, Outputs, Status);
            Assert (Status.Code = E.Tensor_Shape_Mismatch and then (for all Value of Outputs => Value = 3.25),
                    "an oversized tile count wrote outside active storage");
            Stop.Request;
            P.Accumulate (Live, View, Inputs, Positions, Outputs, Status, Stop'Unchecked_Access);
            Assert (Status.Code = E.Generation_Cancelled and then (for all Value of Outputs => Value = 3.25),
                    "cancelled tile published partial output");
            Stop.Reset;
            P.Accumulate (Live, View, Inputs, Positions + 1, Outputs, Status);
            Assert (Status.Code = E.Tensor_Non_Finite_Value
                      and then (System.Default_Bit_Order /= System.Low_Order_First
                                or else (for all Value of Outputs => Value = 3.25)),
                    "late invalid input published earlier tiles");
            P.Accumulate (Live, View, Inputs, Positions, Outputs, Status);
            Check (Status, "tile scratch recovers after refusal");
            L.Close (Live);
         end loop;
         Build_Adapter (Width, Width, Rank, "blk.0.attn_q.weight", "llama", G.Type_F32, Absent,
                        Wide_Scaled_Result, Adapter);
         Apply (Ready, Adapter.all, 1.0E-20, Status, Runtime => True);
         Check (Status, "wide scaled attachment");
         B.Free (Adapter);
         Inputs := [others => 1.0E20];
         for Parallel in Boolean loop
            L.Open (Live, Ready, Workers => (if Parallel then Team'Unchecked_Access else null), Status => Status);
            Check (Status, "wide scaled session");
            Outputs := [others => 3.25];
            P.Accumulate (Live, View, Inputs, 9, Outputs, Status);
            Check (Status, "wide unscaled delta remains finite after scaling");
            for Index in Outputs'First .. Outputs'First + 9 * W - 1 loop
               declare
                  Want : constant O.Number := O.Number (N.Real'(1.0E-20)) * O.Number (Rank)
                    * O.Number (N.Real'(1.0E30)) * O.Number (N.Real'(1.0E20));
               begin
                  Assert (abs (O.Number (Outputs (Index)) - Want) <= 1.0E-5 * abs Want,
                          "a premature F32 B*x overflow changed a finite scaled result");
               end;
            end loop;
            L.Close (Live);
         end loop;
         Build_Adapter (Width, Width, Rank, "blk.0.attn_q.weight", "llama", G.Type_F32, Absent,
                        Overflowing_Delta, Adapter);
         Apply (Ready, Adapter.all, 1.0, Status, Runtime => True);
         Check (Status, "finite overflowing payload attaches");
         B.Free (Adapter);
         Inputs := [others => 1.0];
         for Parallel in Boolean loop
            L.Open (Live, Ready, Workers => (if Parallel then Team'Unchecked_Access else null), Status => Status);
            Check (Status, "overflow session");
            Outputs := [others => 3.25];
            P.Accumulate (Live, View, Inputs, 9, Outputs, Status);
            Assert (Status.Code = E.Tensor_Non_Finite_Value and then (for all Value of Outputs => Value = 3.25),
                    "overflow was not a structured refusal before tile publication");
            L.Close (Live);
         end loop;
         CPU.Close (Team);
         L.Close (Ready, Status);
         Check (Status, "tiled model close");
         C.Close (Parsed);
      end;
      B.Free (Image);
   exception
      when others =>
         CPU.Close (Team);
         L.Close (Live);
         L.Close (Ready, Status);
         B.Free (Adapter);
         B.Free (Image);
         raise;
   end Tiled_Adapters_Preserve_Oracle_And_Failures;

   procedure Embedded_Adapters_Are_Owned_And_Identified (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package I renames Model_Runner.Inference;
      use type I.Completion_State;
      use type Ada.Strings.Unbounded.Unbounded_String;
      Base : constant String := "obj/embedded-adapter-base.gguf";
      Adapter : constant String := "obj/embedded adapter.gguf";
      Item : I.Session;
      Options : I.Open_Options := (Workers => 4, others => <>);
      Running : constant I.Completion_Options :=
        (Maximum_Tokens => 4, Maximum_Output_Bytes => 16, others => <>);
      Status : E.Error_Info;
      Baseline, Zero, Active, Repeated : I.Completion;
      Bare, Attached, Stacked : I.Model_Provenance;
      Zero_Fingerprint : Interfaces.Unsigned_64;
      Bare_SHA, Active_SHA : I.SHA256_Hex;
   begin
      Tiny_Model.Write (Base, Byte_Pair => True);
      Tiny_Model.Write_Adapter (Adapter);
      I.Open (Item, Base, Options, Status);
      Check (Status, "bare embedded model");
      Bare := I.Provenance (Item);
      Assert (Bare.Runtime_Adapter_Count = 0 and then Bare.Runtime_Adapter_Bytes = 0,
              "an ordinary embedded model acquired adapters");
      I.SHA256 (Item, Bare_SHA, Status);
      Check (Status, "bare model SHA");
      I.Complete (Item, "ab", "{""const"":12}", Running, Baseline);
      Assert (Baseline.State = I.Completion_Ready, "bare embedded fixture did not generate");

      Options.Runtime_Adapter_Count := 1;
      Options.Runtime_Adapters (1) := (Model_Runner.Text.To_Bounded (Adapter), 0.0);
      I.Open (Item, Base, Options, Status);
      Check (Status, "zero-scale embedded adapter");
      Zero_Fingerprint := I.Provenance (Item).Fingerprint;
      I.Complete (Item, "ab", "{""const"":12}", Running, Zero);
      Assert (Zero.State = Baseline.State and then Zero.Text = Baseline.Text,
              "zero-scale embedded attachment changed generation");
      Assert (Zero_Fingerprint /= Bare.Fingerprint, "zero-scale attachment lost its context identity");

      Options.Runtime_Adapters (1).Scale := 1.0;
      I.Open (Item, Base, Options, Status);
      Check (Status, "active embedded adapter");
      Attached := I.Provenance (Item);
      Assert (Attached.Runtime_Adapter_Count = 1 and then Attached.Runtime_Adapter_Bytes > 0
                and then Attached.Fingerprint /= Zero_Fingerprint,
              "embedded provenance omitted adapter storage, count or scale identity");
      Assert (Attached.Bytes = Bare.Bytes and then Attached.Parts = Bare.Parts,
              "adapter ownership changed backbone provenance semantics");
      I.SHA256 (Item, Active_SHA, Status);
      Check (Status, "attached backbone SHA");
      Assert (Active_SHA = Bare_SHA, "backbone SHA silently became an adapter composite digest");
      I.Complete (Item, "ab", "{""const"":12}", Running, Active);
      Ada.Directories.Delete_File (Adapter);
      I.Complete (Item, "ab", "{""const"":12}", Running, Repeated);
      Assert (Active.State = I.Completion_Ready and then Repeated.State = Active.State
                and then Repeated.Text = Active.Text,
              "embedded completion retained a dependency on the adapter file");
      Tiny_Model.Write_Adapter (Adapter, Rank => 2);
      I.Complete (Item, "ab", "{""const"":12}", Running, Repeated);
      Assert (Repeated.State = Active.State and then Repeated.Text = Active.Text
                and then I.Provenance (Item).Fingerprint = Attached.Fingerprint,
              "rewriting a closed adapter source changed an active embedded model");

      Options.Runtime_Adapter_Count := 2;
      Options.Runtime_Adapters (2) := (Model_Runner.Text.To_Bounded (Adapter), -0.5);
      I.Open (Item, Base, Options, Status);
      Check (Status, "stacked embedded adapters");
      Stacked := I.Provenance (Item);
      Assert (Stacked.Runtime_Adapter_Count = 2 and then Stacked.Runtime_Adapter_Bytes > Attached.Runtime_Adapter_Bytes
                and then Stacked.Fingerprint /= Attached.Fingerprint,
              "the embedded adapter list or positional scales did not reach the engine");
      I.Open (Item, Base, Options, Status);
      Check (Status, "repeat stacked open");
      Assert (I.Provenance (Item).Fingerprint = Stacked.Fingerprint, "identical attachments changed identity");
      Options.Runtime_Adapters (1).Scale := -0.5;
      Options.Runtime_Adapters (2).Scale := 1.0;
      I.Open (Item, Base, Options, Status);
      Check (Status, "reordered positional scales");
      Assert (I.Provenance (Item).Fingerprint /= Stacked.Fingerprint, "positional scales were ignored");
      I.Close (Item, Status);
      Check (Status, "embedded adapter close");
      I.Close (Item, Status);
      Check (Status, "repeated embedded adapter close");
      Assert (I.Provenance (Item).Runtime_Adapter_Count = 0, "closed provenance retained adapter ownership");
   end Embedded_Adapters_Are_Owned_And_Identified;

   procedure Embedded_Adapter_Failures_Close_The_Session (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package I renames Model_Runner.Inference;
      Base : constant String := "obj/embedded-adapter-fail-base.gguf";
      Adapter : constant String := "obj/embedded-adapter-good.gguf";
      Broken : constant String := "obj/embedded-adapter-broken.gguf";
      Item : I.Session;
      Status : E.Error_Info;
      Options : I.Open_Options;
   begin
      Tiny_Model.Write (Base, Format => Tiny_Model.Q2_K);
      Tiny_Model.Write_Adapter (Adapter, Deep => True);
      Tiny_Model.Write_Adapter (Broken, Half => True, Deep => True);
      Options.Runtime_Adapter_Count := 2;
      Options.Runtime_Adapters (1).Path := Model_Runner.Text.To_Bounded (Adapter);
      Options.Runtime_Adapters (2).Path := Model_Runner.Text.To_Bounded (Broken);
      I.Open (Item, Base, Options, Status);
      Assert (Status.Code = E.Arch_Missing_Tensor and then not I.Is_Open (Item)
                and then I.Model_Path (Item) = "" and then I.Provenance (Item).Runtime_Adapter_Bytes = 0,
              "a bad later adapter exposed a partially attached public session");
      Options.Runtime_Adapter_Count := 1;
      I.Open (Item, Base, Options, Status);
      Check (Status, "recovery after a later bad adapter");
      Options.Runtime_Adapters (1).Path := Model_Runner.Text.To_Bounded ("obj/absent-embedded-adapter.gguf");
      I.Open (Item, Base, Options, Status);
      Assert (Status.Code = E.IO_Open_Failed and then not I.Is_Open (Item),
              "a missing adapter preserved an old public session or lost its IO diagnostic");
      Options.Runtime_Adapters (1).Path := Model_Runner.Text.To_Bounded (Broken);
      Project_Tools.Files.Write_Raw_File (Broken, "not GGUF");
      I.Open (Item, Base, Options, Status);
      Assert (E.Is_Error (Status) and then not I.Is_Open (Item), "malformed adapter bytes were ignored");
      Options.Runtime_Adapters (1).Path := Model_Runner.Text.To_Bounded (Adapter);
      Options.Adapter_Bounds.Max_Bytes := 1;
      I.Open (Item, Base, Options, Status);
      Assert (Status.Code = E.Memory_Limit_Exceeded and then not I.Is_Open (Item),
              "embedded loading ignored its decoded adapter byte bound");
      Options.Adapter_Bounds := L.Default_Adapter_Limits;
      Tiny_Model.Write_Adapter (Adapter, Rank => 2, Deep => True);
      Options.Adapter_Bounds.Max_Rank := 1;
      I.Open (Item, Base, Options, Status);
      Assert (E.Is_Error (Status) and then not I.Is_Open (Item), "embedded loading ignored its adapter rank bound");
      Options.Adapter_Bounds := L.Default_Adapter_Limits;
      I.Open (Item, Base, Options, Status);
      Check (Status, "healthy reopen after adapter bound refusals");
      I.Close (Item, Status);
      Check (Status, "cleanup after refusal recovery");
   end Embedded_Adapter_Failures_Close_The_Session;

   procedure Embedded_Adapter_Controls_Validate_Before_IO (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      pragma Suppress (Validity_Check);
      package I renames Model_Runner.Inference;
      Item : I.Session;
      Status : E.Error_Info;
      Options : I.Open_Options;
   begin
      Options.Runtime_Adapter_Count := 1;
      Options.Runtime_Adapters (1).Path := Model_Runner.Text.To_Bounded ("obj/absent-adapter.gguf");
      Options.Backend := Model_Runner.Backend.Backend_Device;
      I.Open (Item, "obj/absent-base.gguf", Options, Status);
      Assert (Status.Code = E.Arch_Unsupported_Feature and then not I.Is_Open (Item),
              "embedded runtime adapters attempted device acquisition or model IO before refusing the backend");
      Options.Backend := Model_Runner.Backend.Backend_CPU;
      Options.Runtime_Adapters (1).Scale := N.From_Bits (16#7FC0_0000#);
      I.Open (Item, "obj/absent-base.gguf", Options, Status);
      Assert (Status.Code = E.Tensor_Non_Finite_Value, "nonfinite embedded scale reached model IO");
      Options.Runtime_Adapters (1).Scale := 1.0;
      Options.Adapter_Bounds.Max_Bytes := 0;
      I.Open (Item, "obj/absent-base.gguf", Options, Status);
      Assert (Status.Code = E.Arch_Unsupported_Feature, "invalid embedded adapter bounds reached model IO");
      Options.Adapter_Bounds := L.Default_Adapter_Limits;
      Options.Adapter_Bounds.Max_Adapters := 1;
      Options.Runtime_Adapter_Count := 2;
      I.Open (Item, "obj/absent-base.gguf", Options, Status);
      Assert (Status.Code = E.Memory_Limit_Exceeded, "too many embedded adapters reached model IO");
      Options.Runtime_Adapter_Count := 1;
      Options.Runtime_Adapters (1).Path := Model_Runner.Text.Empty;
      I.Open (Item, "obj/absent-base.gguf", Options, Status);
      Assert (Status.Code = E.IO_Open_Failed and then E.Text_Of (Status, "path") = "",
              "empty adapter path reached backbone IO");
   end Embedded_Adapter_Controls_Validate_Before_IO;

   procedure Embedded_Adapter_Parse_Observes_Cancellation (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package I renames Model_Runner.Inference;
      package Progress renames Model_Runner.Progress;
      use type Progress.Load_Stage;
      use type Progress.Event_Kind;
      type Watcher is limited new Progress.Observer with record
         Stop : Model_Runner.Cancellation.Token_Reference;
         Prepared : Boolean := False;
         Adapter_Headers : Natural := 0;
      end record;
      overriding procedure Notify (Self : in out Watcher; Item : Progress.Event);
      overriding procedure Notify (Self : in out Watcher; Item : Progress.Event) is
      begin
         if Item.Kind = Progress.Load_Event then
            if Item.Load = Progress.Model_Ready then
               Self.Prepared := True;
            elsif Self.Prepared and then Item.Load = Progress.Reading_Header then
               Self.Adapter_Headers := Self.Adapter_Headers + 1;
               Self.Stop.Request;
            end if;
         end if;
      end Notify;
      Base : constant String := "obj/embedded-adapter-cancel-base.gguf";
      Adapter : constant String := "obj/embedded-adapter-cancel.gguf";
      Item : I.Session;
      Status : E.Error_Info;
      Token : aliased Model_Runner.Cancellation.Token;
      Seen : aliased Watcher;
      Options : I.Open_Options;
   begin
      Tiny_Model.Write (Base);
      Tiny_Model.Write_Adapter (Adapter);
      Seen.Stop := Token'Unchecked_Access;
      Options.Cancel := Token'Unchecked_Access;
      Options.Observer := Seen'Unchecked_Access;
      Options.Runtime_Adapter_Count := 1;
      Options.Runtime_Adapters (1).Path := Model_Runner.Text.To_Bounded (Adapter);
      I.Open (Item, Base, Options, Status);
      Assert (Seen.Prepared and then Seen.Adapter_Headers = 1 and then Status.Code = E.Generation_Cancelled
                and then not I.Is_Open (Item),
              "the embedded adapter parser ignored the load observer or cancellation token");
      Options.Cancel := null;
      Options.Observer := null;
      I.Open (Item, Base, Options, Status);
      Check (Status, "embedded reopen after adapter parser cancellation");
      I.Close (Item, Status);
      Check (Status, "embedded close after cancellation recovery");
   end Embedded_Adapter_Parse_Observes_Cancellation;

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Known_Answers_And_Stacking'Access, "binary64 oracle has analytic answers and stacking");
      Register_Routine (T, Invalid_Reference_Inputs_Preserve_Output'Access, "invalid reference inputs preserve output");
      Register_Routine
        (T, Quantized_Base_Has_Independent_Values'Access, "base Q8_0 values are independently specified");
      Register_Routine
        (T, Seven_Targets_Match_Expanded_Oracle'Access, "seven native projections match expanded oracle");
      Register_Routine
        (T, Malformed_Pairs_Are_Refused'Access, "malformed first pairs are refused without mutation");
      Register_Routine
        (T, Late_Invalid_Pairs_Preserve_Model'Access, "late invalid pairs preserve weights and identity");
      Register_Routine
        (T, Adapter_Content_Binds_Saved_Context'Access, "saved contexts bind full adapter content");
      Register_Routine
        (T, Runtime_Tokens_And_Batches_Match_Merge'Access, "quantized runtime token and batch logits match merge");
      Register_Routine
        (T, Runtime_Load_Is_Transactional'Access, "runtime refusal preserves ownership identity and accounting");
      Register_Routine
        (T, Wide_Fixture_And_Paired_Timing'Access, "wide hybrid fixtures and paired timing preserve controls");
      Register_Routine
        (T, Tiled_Adapters_Preserve_Oracle_And_Failures'Access, "bounded CPU tiles match oracle and preserve failures");
      Register_Routine
        (T, Embedded_Adapters_Are_Owned_And_Identified'Access, "embedded adapters own sources and bind provenance");
      Register_Routine
        (T, Embedded_Adapter_Failures_Close_The_Session'Access, "embedded adapter failures close and recover");
      Register_Routine
        (T, Embedded_Adapter_Controls_Validate_Before_IO'Access, "embedded adapter controls validate before IO");
      Register_Routine
        (T, Embedded_Adapter_Parse_Observes_Cancellation'Access, "embedded adapter parsing observes cancellation");
   end Register_Tests;

end Tests.Adapter_Cases;
