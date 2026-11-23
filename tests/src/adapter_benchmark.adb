with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Agent_Campaign;
with Interfaces;
with Jsonlib.Documents;
with Jsonlib.Serializers;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Llama;
with Model_Runner.Platform;
with Model_Runner.Text;
with Project_Tools.Files;
with Speed_Run;

package body Adapter_Benchmark is
   procedure Run
     (Model_Path, Adapter_Path, Prompt_Path, Output_Path : String; Clean : out Boolean;
      Repeats : Positive := 5; Tokens : Positive := 16; Threads : Positive := 4;
      Batch : Positive := 16; Context : Positive := 512; Include_Merge : Boolean := False)
   is
      package J renames Jsonlib.Documents;
      package L renames Model_Runner.Llama;
      package C renames Model_Runner.GGUF.Containers;
      use type Interfaces.Unsigned_64;
      use type Ada.Directories.File_Size;
      type Arm is (Base, Zero, Runtime, Merge);
      type Times is array (Positive range <>) of Long_Float;
      type Results is array (Positive range <>, Arm range <>) of Speed_Run.Report;
      Data : Results (1 .. Positive'Min (Repeats, 21), Arm);
      Doc : J.Document;
      Root : constant J.Node := J.New_Object (Doc);
      Samples : constant J.Node := J.New_Array (Doc);
      Summary : constant J.Node := J.New_Array (Doc);
      Source : Model_Runner.Byte_Sources.Files.File_Source;
      Parsed : C.Container;
      Status : Model_Runner.Errors.Error_Info;
      Needed, Available : Interfaces.Unsigned_64 := 0;
      Adapter_Needed, Max_Rank : Interfaces.Unsigned_64 := 0;
      Ok : Boolean := True;

      function Name (Which : Arm) return String
      is (case Which is when Base => "base", when Zero => "zero", when Runtime => "runtime", when Merge => "merge");

      procedure Text (Into : J.Node; Key, Value : String) is
      begin
         J.Insert (Doc, Into, Key, J.New_String (Doc, Value));
      end Text;
      procedure Number (Into : J.Node; Key : String; Value : Long_Float) is
      begin
         J.Insert (Doc, Into, Key, (if Value < 0.0 then J.New_Null (Doc) else J.New_Float (Doc, Value)));
      end Number;
      function Median (Values : Times) return Long_Float is
         Copy : Times := Values;
         Value : Long_Float;
      begin
         for Index in Copy'First + 1 .. Copy'Last loop
            for Position in reverse Copy'First + 1 .. Index loop
               exit when Copy (Position - 1) <= Copy (Position);
               Value := Copy (Position);
               Copy (Position) := Copy (Position - 1);
               Copy (Position - 1) := Value;
            end loop;
         end loop;
         return (if Copy'Length mod 2 = 1 then Copy (Copy'Length / 2 + 1)
                 else (Copy (Copy'Length / 2) + Copy (Copy'Length / 2 + 1)) / 2.0);
      end Median;
   begin
      Clean := False;
      if Output_Path = "" or else Ada.Directories.Exists (Output_Path) or else Repeats > 21
        or else Tokens > 256 or else Threads > 64 or else Batch > 256 or else Context not in 16 .. 32_768
        or else not Ada.Directories.Exists (Prompt_Path) or else Ada.Directories.Size (Prompt_Path) > 65_536
      then
         Ada.Text_IO.Put_Line ("adapter benchmark: invalid bounds, prompt or existing output");
         return;
      end if;
      J.Set_Root (Doc, Root);
      Text (Root, "schema", "model_runner.cpu_adapter_benchmark.v1");
      Text (Root, "scope", "paired warm inference, descriptive only; no quality or significance claim");
      Text (Root, "arithmetic", "f32");
      Text (Root, "model_sha256", Agent_Campaign.File_Digest (Model_Path));
      Text (Root, "adapter_sha256", Agent_Campaign.File_Digest (Adapter_Path));
      Text (Root, "prompt_sha256", Agent_Campaign.File_Digest (Prompt_Path));
      Text (Root, "binary_sha256", Agent_Campaign.File_Digest (Ada.Command_Line.Command_Name));
      Number (Root, "threads", Long_Float (Threads));
      Number (Root, "batch", Long_Float (Batch));
      Number (Root, "context", Long_Float (Context));
      Number (Root, "repeats", Long_Float (Repeats));
      Number (Root, "tokens", Long_Float (Tokens));
      J.Insert (Doc, Root, "samples", Samples);
      J.Insert (Doc, Root, "summary", Summary);
      --  Conservative benchmark admission, distinct from the engine's detailed session accounting.
      Available := Model_Runner.Platform.Available_Memory;
      Model_Runner.Byte_Sources.Files.Open (Source, Model_Path, Status => Status);
      if Model_Runner.Errors.Is_Ok (Status) then
         C.Reader.Parse (Parsed, Source, Status => Status);
      end if;
      if Model_Runner.Errors.Is_Error (Status) then
         C.Close (Parsed);
         Model_Runner.Byte_Sources.Files.Close (Source);
         Ada.Text_IO.Put_Line ("adapter benchmark: base did not parse");
         return;
      end if;
      Needed := Interfaces.Unsigned_64 (Source.Size);
      if Include_Merge then
         Needed := 0;
         for Index in 1 .. C.Tensor_Count (Parsed) loop
            if C.Tensor_Elements (Parsed, Index) > (Interfaces.Unsigned_64'Last - Needed) / 8 then
               Ok := False;
               exit;
            end if;
            Needed := Needed + 8 * C.Tensor_Elements (Parsed, Index);
         end loop;
      end if;
      C.Close (Parsed);
      Model_Runner.Byte_Sources.Files.Close (Source);
      Model_Runner.Byte_Sources.Files.Open (Source, Adapter_Path, Status => Status);
      if Model_Runner.Errors.Is_Ok (Status) then
         C.Reader.Parse (Parsed, Source, Status => Status);
      end if;
      if Model_Runner.Errors.Is_Ok (Status) then
         for Index in 1 .. C.Tensor_Count (Parsed) loop
            if C.Tensor_Elements (Parsed, Index) > (1_073_741_824 - Adapter_Needed) / 4 then
               Ok := False;
               exit;
            end if;
            Adapter_Needed := Adapter_Needed + 4 * C.Tensor_Elements (Parsed, Index);
            declare
               Tensor : constant String := C.Tensor_Name (Parsed, Index);
            begin
               if Tensor'Length >= 7 and then Tensor (Tensor'Last - 6 .. Tensor'Last) = ".lora_a"
                 and then C.Tensor_Rank (Parsed, Index) = 2
               then
                  Max_Rank := Interfaces.Unsigned_64'Max (Max_Rank, C.Tensor_Dimension (Parsed, Index, 2));
               end if;
            end;
         end loop;
      else
         Ok := False;
      end if;
      Number (Root, "adapter_tensor_count", Long_Float (C.Tensor_Count (Parsed)));
      Number (Root, "adapter_max_rank", Long_Float (Max_Rank));
      Number (Root, "adapter_decoded_estimate_bytes", Long_Float (Adapter_Needed));
      C.Close (Parsed);
      Model_Runner.Byte_Sources.Files.Close (Source);
      if not Ok or else Needed > Available / 2 or else Adapter_Needed > Available / 4 then
         Ada.Text_IO.Put_Line ("adapter benchmark: base working set exceeds conservative half-RAM admission");
         return;
      end if;
      Number (Root, "available_memory_before_bytes", Long_Float (Available));
      Number (Root, "base_admission_estimate_bytes", Long_Float (Needed));
      for Trial in Data'Range (1) loop
         for Slot in 0 .. (if Include_Merge then 3 else 2) loop
            declare
               Which : constant Arm := Arm'Val (if Trial mod 2 = 1 then Slot
                                               else (if Include_Merge then 3 else 2) - Slot);
               Result : Speed_Run.Report renames Data (Trial, Which);
               Row : constant J.Node := J.New_Object (Doc);
            begin
               Ada.Text_IO.Put_Line ("adapter benchmark " & Model_Runner.Text.Image (Long_Long_Integer (Trial))
                                     & " " & Name (Which));
               Speed_Run.Run
                 (Path => Model_Path, Prompt_Path => Prompt_Path, Tokens => Tokens, Threads => Threads,
                  Batch => Batch, Repack => (if Which = Merge then L.To_F32 else L.No_Repack),
                  Draft_Tokens => 0, Draft_Tokens_Set => True, Repeats => 1, Context => Context,
                  Ignore_End => True, Arithmetic => "f32", No_Cache => True,
                  Adapter => (if Which = Base then "" else Adapter_Path),
                  Adapter_Scale => (if Which = Zero then 0.0 else 1.0), Adapter_Runtime => Which /= Merge,
                  Result => Result);
               Text (Row, "arm", Name (Which));
               Number (Row, "trial", Long_Float (Trial));
               Number (Row, "slot", Long_Float (Slot));
               Text (Row, "detail", Result.Detail (1 .. Result.Detail_Up));
               Text (Row, "digest", Result.Digest);
               J.Insert (Doc, Row, "ran", J.New_Boolean (Doc, Result.Ran));
               Number (Row, "prompt_tokens", Long_Float (Result.Prompt));
               Number (Row, "generated_tokens", Long_Float (Result.Produced));
               Number (Row, "load_seconds", Long_Float (Result.Load));
               Number (Row, "adapter_load_seconds", Long_Float (Result.Adapter_Load));
               Number (Row, "prompt_seconds", Long_Float (Result.Evaluate));
               Number (Row, "decode_seconds", Long_Float (Result.Generate));
               Number (Row, "wall_seconds", Long_Float (Result.Wall));
               Number (Row, "processor_seconds", Long_Float (Result.Processor));
               Number (Row, "adapter_owned_bytes", Long_Float (Result.Adapter_Bytes));
               Number (Row, "model_accounted_bytes", Long_Float (Result.Model_Bytes));
               Number (Row, "load_before", Result.Load_Before);
               Number (Row, "load_after", Result.Load_After);
               Number (Row, "temperature_before_celsius", Result.Warm_Before);
               Number (Row, "temperature_after_celsius", Result.Warm_After);
               J.Append (Doc, Samples, Row);
               if not Result.Ran or else Result.Produced /= Tokens then
                  Ok := False;
                  exit;
               end if;
            end;
         end loop;
         exit when not Ok;
         if Data (Trial, Base).Digest /= Data (Trial, Zero).Digest
           or else Data (Trial, Base).Prompt /= Data (Trial, Zero).Prompt
           or else Data (Trial, Base).Prompt /= Data (Trial, Runtime).Prompt
           or else (Include_Merge and then Data (Trial, Base).Prompt /= Data (Trial, Merge).Prompt)
         then
            Ok := False;
            exit;
         end if;
      end loop;
      if Ok then
         for Which in Base .. (if Include_Merge then Merge else Runtime) loop
            declare
               Row : constant J.Node := J.New_Object (Doc);
               Loads, Prompts, Decodes, Prompt_Ratios, Decode_Ratios : Times (1 .. Repeats);
            begin
               for Trial in Data'Range (1) loop
                  Loads (Trial) := Long_Float (Data (Trial, Which).Load);
                  Prompts (Trial) := Long_Float (Data (Trial, Which).Evaluate);
                  Decodes (Trial) := Long_Float (Data (Trial, Which).Generate);
                  Prompt_Ratios (Trial) := Prompts (Trial) / Long_Float'Max
                    (Long_Float (Data (Trial, Base).Evaluate), 1.0E-9);
                  Decode_Ratios (Trial) := Decodes (Trial) / Long_Float'Max
                    (Long_Float (Data (Trial, Base).Generate), 1.0E-9);
               end loop;
               Text (Row, "arm", Name (Which));
               Number (Row, "median_load_seconds", Median (Loads));
               Number (Row, "median_prompt_seconds", Median (Prompts));
               Number (Row, "median_decode_seconds", Median (Decodes));
               Number (Row, "median_paired_prompt_ratio", Median (Prompt_Ratios));
               Number (Row, "median_paired_decode_ratio", Median (Decode_Ratios));
               J.Append (Doc, Summary, Row);
            end;
         end loop;
      end if;
      Clean := Ok;
      J.Insert (Doc, Root, "controls_passed", J.New_Boolean (Doc, Clean));
      Text (Root, "warmup", "one untimed full inference pass before each measured sample; model reloaded per arm");
      J.Insert (Doc, Root, "peak_rss_bytes", J.New_Null (Doc));
      Project_Tools.Files.Write_Raw_File
        (Output_Path, Jsonlib.Serializers.To_String (Doc, (Jsonlib.Serializers.Default_Options with delta
                                                         Form => Jsonlib.Serializers.Pretty)));
   exception
      when others =>
         C.Close (Parsed);
         Model_Runner.Byte_Sources.Files.Close (Source);
         Clean := False;
         Ada.Text_IO.Put_Line ("adapter benchmark failed; no completed comparison claimed");
   end Run;
end Adapter_Benchmark;
