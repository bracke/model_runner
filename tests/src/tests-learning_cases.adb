with Ada.Directories;
with Ada.Numerics.Long_Elementary_Functions;
with AUnit.Assertions;
with Learning_Lora;
with Learning_Lora_Files;
with Learning_Curriculum;
with Model_Runner.Errors;
with Model_Runner.Numerics;
with Tiny_Model;
with Fixtures;
with Learning_Sources;
with Model_Runner.Byte_Sources.Files;
with Model_Runner.Bytes;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Tensors;
with Learning_Fit;
with Learning_Data;
with Ada.Streams.Stream_IO;
with Interfaces;
with Project_Tools.Files;
with Jsonlib.Documents;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Jsonlib.Errors;
with Model_Runner.Llama;
with Model_Runner.Backend;
with Campaign_Statistics;
with Learning_Isolation;
with Trial_Confinement;
with Hostkit.Process;
with Hostkit.Fs;
with Ada.Strings.Unbounded;

package body Tests.Learning_Cases is
   use AUnit.Assertions;
   package N renames Model_Runner.Numerics;
   package E renames Model_Runner.Errors;
   package L renames Learning_Lora;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte;
   use type Interfaces.Unsigned_32;
   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("local supervised adapter learning");
   end Name;
   function Fresh (Name : String) return String is
      Path : constant String := "obj/learning-tests/" & Name;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_Tree (Path);
      end if;
      Ada.Directories.Create_Path (Path);
      return Path;
   end Fresh;
   procedure Independent_Gradient (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Item : L.Adapter;
      Status : E.Error_Info;
      A, GA : N.Real_Array (0 .. 5) := [0.03, -0.1, 0.2, 0.12, 0.02, -0.04];
      B, GB : N.Real_Array (0 .. 7) := [0.1, -0.2, 0.3, -0.1, 0.02, 0.04, -0.03, 0.05];
      H : constant N.Real_Array := [0.5, -0.75, 1.2];
      Base : constant N.Real_Array := [0.2, -0.1, 0.7, -0.3];
      Loss : N.Wide_Real;
      function Oracle return Long_Float is
         use Ada.Numerics.Long_Elementary_Functions;
         Z : array (0 .. 1) of Long_Float := [others => 0.0];
         Scores : array (0 .. 3) of Long_Float;
         Sum : Long_Float := 0.0;
      begin
         for R in 0 .. 1 loop
            for C in 0 .. 2 loop
               Z (R) := Z (R) + Long_Float (A (N.Element_Count (R * 3 + C)))
                 * Long_Float (H (H'First + N.Element_Count (C)));
            end loop;
         end loop;
         for V in 0 .. 3 loop
            Scores (V) := Long_Float (Base (Base'First + N.Element_Count (V)));
            for R in 0 .. 1 loop
               Scores (V) := Scores (V) + Long_Float (B (N.Element_Count (V * 2 + R))) * Z (R);
            end loop;
            Sum := Sum + Exp (Scores (V));
         end loop;
         return Log (Sum) - Scores (2);
      end Oracle;
      procedure Check (Values : in out N.Real_Array; Gradient : N.Real_Array) is
         Plus, Minus : Long_Float;
         Original : N.Real;
      begin
         for I in Values'Range loop
            Original := Values (I);
            Values (I) := Original + 0.001;
            Plus := Oracle;
            Values (I) := Original - 0.001;
            Minus := Oracle;
            Values (I) := Original;
            Assert (abs ((Plus - Minus) / 0.002 - Long_Float (Gradient (I))) < 0.0005,
                    "LoRA gradient differs from independent binary64 finite difference");
         end loop;
      end Check;
   begin
      L.Initialize (Item, (3, 4, 2), 42, Status);
      Assert (E.Is_Ok (Status), "optimizer initialization failed");
      L.Set_Factors (Item, A, B, Status);
      L.Observe (Item, H, Base, 2, True, Loss, Status);
      Assert (E.Is_Ok (Status) and then abs (Long_Float (Loss) - Oracle) < 1.0E-6,
              "cross entropy differs from independent binary64 oracle");
      L.Gradients (Item, GA, GB, Status);
      Assert (E.Is_Ok (Status), "gradient extraction failed");
      Check (A, GA);
      Check (B, GB);
      L.Clear (Item);
   end Independent_Gradient;
   procedure Parameters_Actually_Learn (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Item : L.Adapter;
      Status : E.Error_Info;
      Before, After : N.Wide_Real;
      H : constant N.Real_Array := [1.0, -0.5, 0.75];
      Base : constant N.Real_Array := [0.0, 0.0, 0.0, 0.0];
      A : N.Real_Array (0 .. 5);
      B : N.Real_Array (0 .. 7);
   begin
      L.Initialize (Item, (3, 4, 2), 42, Status);
      L.Observe (Item, H, Base, 2, False, Before, Status);
      for Step in 1 .. 100 loop
         L.Observe (Item, H, Base, 2, True, After, Status);
         L.Step (Item, 0.01, 1.0, Status);
         Assert (E.Is_Ok (Status), "bounded Adam update failed");
      end loop;
      L.Observe (Item, H, Base, 2, False, After, Status);
      L.Get_Factors (Item, A, B, Status);
      Assert (After < Before - 0.1 and then (for some V of B => V /= 0.0),
              "training did not reduce held example loss or change adapter parameters");
      Fixtures.Put_Infinity (A, 0);
      L.Set_Factors (Item, A, B, Status);
      Assert (E.Is_Error (Status), "nonfinite factors were accepted");
      L.Observe (Item, H, Base, 2, False, After, Status);
      Assert (E.Is_Ok (Status) and then After < Before - 0.1, "rejected factors damaged learned weights");
      L.Step (Item, 0.001, 1.0, Status);
      Assert (E.Is_Error (Status), "empty gradient batch was updated");
      L.Clear (Item);
   end Parameters_Actually_Learn;
   procedure Zero_Merge_Preserves_Model (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Root : constant String := Fresh ("artifacts");
      Item, Loaded : L.Adapter;
      Status : E.Error_Info;
   begin
      Tiny_Model.Write (Root & "/base.gguf");
      L.Initialize (Item, (Tiny_Model.Embedding, Tiny_Model.Vocabulary, 2), 42, Status);
      Learning_Lora_Files.Save
        (Item, Root & "/zero.gguf", Learning_Lora_Files.Digest (Root & "/base.gguf"), "llama", Status);
      Assert (E.Is_Ok (Status), "zero factor artifact did not save");
      Learning_Lora_Files.Load (Loaded, Root & "/zero.gguf", [1 .. 64 => '0'], Status);
      Assert (E.Is_Error (Status), "adapter lineage mismatch was accepted");
      Learning_Lora_Files.Load
        (Loaded, Root & "/zero.gguf", Learning_Lora_Files.Digest (Root & "/base.gguf"), Status);
      Assert (E.Is_Ok (Status), "saved factors did not reload: " & Status'Image);
      Learning_Lora_Files.Merge (Root & "/base.gguf", Root & "/zero.gguf", Root & "/merged.gguf", Status);
      Assert (E.Is_Ok (Status), "zero adapter merge failed: " & Status'Image);
      Assert (Learning_Lora_Files.Digest (Root & "/base.gguf") =
                Learning_Lora_Files.Digest (Root & "/merged.gguf"),
              "zero adapter changed the model's bytes");
      Learning_Lora_Files.Merge (Root & "/base.gguf", Root & "/zero.gguf", Root & "/merged.gguf", Status);
      Assert (E.Is_Error (Status), "existing model destination was overwritten");
      L.Clear (Item);
      L.Clear (Loaded);
   end Zero_Merge_Preserves_Model;
   procedure Nonzero_Merge_Oracle (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package C renames Model_Runner.GGUF.Containers;
      package F renames Model_Runner.Byte_Sources.Files;
      package Ten renames Model_Runner.Tensors;
      package Bytes renames Model_Runner.Bytes;
      Root : constant String := Fresh ("nonzero");
      Status : E.Error_Info;
   begin
      for Quantized in Boolean loop
         declare
            Path : constant String := Root & "/" & Boolean'Image (Quantized);
            Width : constant N.Element_Count := (if Quantized then Tiny_Model.Deep_Embedding else Tiny_Model.Embedding);
            Item : L.Adapter;
            Down : N.Real_Array (0 .. Width * 2 - 1) := [others => 0.0];
            Up : N.Real_Array (0 .. Tiny_Model.Vocabulary * 2 - 1) := [others => 0.0];
            Old_Owner, New_Owner : Learning_Sources.Guard;
            Old_Source : F.File_Source renames Old_Owner.Bytes;
            New_Source : F.File_Source renames New_Owner.Bytes;
            Parsed : C.Container;
            Old_View, New_View : Ten.View;
            Old_Row, New_Row : N.Real_Array (0 .. Width - 1);
         begin
            Ada.Directories.Create_Path (Path);
            Tiny_Model.Write (Path & "/base.gguf", Kind => Tiny_Model.Mellum,
                              Format => (if Quantized then Tiny_Model.Q6_K else Tiny_Model.F32));
            L.Initialize (Item, (Natural (Width), Tiny_Model.Vocabulary, 2), 42, Status);
            for I in 0 .. Width - 1 loop
               Down (I) := N.Real (Integer (I mod 17) - 8) / 100.0;
            end loop;
            Up (6) := 0.1;
            L.Set_Factors (Item, Down, Up, Status);
            Learning_Lora_Files.Save
              (Item, Path & "/adapter.gguf", Learning_Lora_Files.Digest (Path & "/base.gguf"), "mellum", Status);
            Assert (E.Is_Ok (Status), "nonzero factor artifact failed");
            Learning_Lora_Files.Merge (Path & "/base.gguf", Path & "/adapter.gguf", Path & "/changed.gguf", Status);
            Assert (E.Is_Ok (Status), "nonzero output merge failed: " & Status'Image);
            F.Open (Old_Source, Path & "/base.gguf", Policy => F.Mapping_Required, Status => Status);
            F.Open (New_Source, Path & "/changed.gguf", Policy => F.Mapping_Required, Status => Status);
            C.Reader.Parse (Parsed, Old_Source, Status => Status);
            declare
               Index : constant Natural := C.Find_Tensor (Parsed, "output.weight");
               Offset : constant Bytes.Byte_Count := Bytes.Byte_Count (C.Tensor_Offset (Parsed, Index));
               Length : constant Bytes.Byte_Count := Bytes.Byte_Count (C.Tensor_Bytes (Parsed, Index));
               Old_Bytes : Bytes.Byte_Array (1 .. Old_Source.Size) with Import, Address => Old_Source.Base;
               New_Bytes : Bytes.Byte_Array (1 .. New_Source.Size) with Import, Address => New_Source.Base;
            begin
               Assert (Old_Source.Size = New_Source.Size and then
                 (for all I in Old_Bytes'Range =>
                   (if I - 1 < Offset or else I - 1 >= Offset + Length then Old_Bytes (I) = New_Bytes (I))),
                 "merging changed bytes outside the output projection");
               Ten.Make (C.Tensor_Format (Parsed, Index), Tiny_Model.Vocabulary, Width,
                         Old_Source.Base, Old_Source.Size, Offset, Old_View, Status);
               Ten.Make (C.Tensor_Format (Parsed, Index), Tiny_Model.Vocabulary, Width,
                         New_Source.Base, New_Source.Size, Offset, New_View, Status);
               Ten.Dequantize_Row (Old_View, 3, Old_Row, Status);
               Ten.Dequantize_Row (New_View, 3, New_Row, Status);
               for I in Old_Row'Range loop
                  Assert (abs (N.Wide_Real (New_Row (I)) - N.Wide_Real (Old_Row (I))
                          - N.Wide_Real (Up (6)) * N.Wide_Real (Down (I))) <
                            (if Quantized then 0.01 else 1.0E-6),
                          "merged weights differ from the independent low-rank product");
               end loop;
            end;
            L.Clear (Item);
         end;
      end loop;
   end Nonzero_Merge_Oracle;
   procedure Complete_Fit_And_Tamper (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package J renames Jsonlib.Documents;
      package IO renames Ada.Streams.Stream_IO;
      Root : constant String := Fresh ("fit");
      Status : E.Error_Info;
      Parsed : J.Document;
      Parse_Error : Jsonlib.Errors.Error_Info;
      procedure Features (Name : String; Rows : Positive) is
         File : IO.File_Type;
         procedure Put (Value : Interfaces.Unsigned_32) is
            Rest : Interfaces.Unsigned_32 := Value;
            Raw : Ada.Streams.Stream_Element_Array (1 .. 4);
         begin
            for Byte of Raw loop
               Byte := Ada.Streams.Stream_Element (Rest and 255);
               Rest := Interfaces.Shift_Right (Rest, 8);
            end loop;
            IO.Write (File, Raw);
         end Put;
      begin
         IO.Create (File, IO.Out_File, Root & "/features/" & Name & ".features");
         IO.Write (File, [77, 82, 72, 76, 79, 82, 65, 49]);
         Put (8);
         Put (16);
         Put (Interfaces.Unsigned_32 (Rows));
         for Row in 1 .. Rows loop
            Put (3);
            for Column in 0 .. 7 loop
               Put (N.Bits (0.1 + N.Real (Column) / 100.0));
            end loop;
            for Column in 0 .. 15 loop
               Put (N.Bits (0.0));
            end loop;
         end loop;
         IO.Close (File);
      end Features;
      procedure Manifest (Wrong_Base : Boolean := False) is
         Doc : J.Document;
         Root_Node : constant J.Node := J.New_Object (Doc);
         procedure Put (Key, Value : String) is
         begin
            J.Insert (Doc, Root_Node, Key, J.New_String (Doc, Value));
         end Put;
      begin
         J.Set_Root (Doc, Root_Node);
         Put ("model_sha256", (if Wrong_Base then [1 .. 64 => '0']
                               else Learning_Lora_Files.Digest (Root & "/base.gguf")));
         Put ("train_features_sha256", Learning_Lora_Files.Digest (Root & "/features/train.features"));
         Put ("validation_features_sha256", Learning_Lora_Files.Digest (Root & "/features/validation.features"));
         Project_Tools.Files.Write_Raw_File
           (Root & "/features/manifest.json", Jsonlib.Serializers.To_String (Doc));
      end Manifest;
   begin
      Ada.Directories.Create_Path (Root & "/features");
      Tiny_Model.Write (Root & "/base.gguf");
      Features ("train", 256);
      Features ("validation", 32);
      Manifest (True);
      Learning_Fit.Run (Root & "/base.gguf", Root & "/features", Root & "/wrong-base", Status);
      Assert (E.Is_Error (Status), "features trained against the wrong base identity");
      Manifest;
      Learning_Fit.Run (Root & "/base.gguf", Root & "/features", Root & "/fitted", Status);
      Assert (E.Is_Ok (Status), "complete native fitting failed: " & Status'Image);
      Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Root & "/fitted/fit.json"), Parsed, Parse_Error);
      Assert (not Jsonlib.Errors.Failed (Parse_Error), "fitting result is not valid JSON");
      Assert (J.As_Float (Parsed, J.Member (Parsed, J.Root (Parsed), "final_train_cross_entropy")) <
                J.As_Float (Parsed, J.Member (Parsed, J.Root (Parsed), "zero_train_cross_entropy")),
              "complete fit did not learn from the numerical data");
      Assert (J.As_Integer (Parsed, J.Member (Parsed, J.Root (Parsed), "selected_epoch")) in 1 .. 8
              and then Ada.Directories.Exists (Root & "/fitted/selected.gguf")
              and then Ada.Directories.Exists (Root & "/fitted/final.gguf"),
              "checkpoint selection did not retain trained and final artifacts");
      Project_Tools.Files.Write_Raw_File (Root & "/features/train.features", "broken");
      Learning_Fit.Run (Root & "/base.gguf", Root & "/features", Root & "/tampered", Status);
      Assert (E.Is_Error (Status), "changed feature data bypassed its recorded digest");
      Learning_Data.Curate (Root & "/missing-collection", Root & "/missing-data", Status);
      Assert (E.Is_Error (Status), "missing independent outcomes produced a supervised dataset");
   end Complete_Fit_And_Tamper;
   procedure Feature_Target_Alignment (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package Engine renames Model_Runner.Llama;
      package C renames Model_Runner.GGUF.Containers;
      package F renames Model_Runner.Byte_Sources.Files;
      package Bytes renames Model_Runner.Bytes;
      Root : constant String := Fresh ("features");
      Owner, Feature_Owner : Learning_Sources.Guard;
      Source : F.File_Source renames Owner.Bytes;
      Feature_Source : F.File_Source renames Feature_Owner.Bytes;
      Parsed : C.Container;
      Model : Engine.Model;
      Live : Engine.Session;
      Status, Closed : E.Error_Info;
      Hidden : N.Real_Array (0 .. Tiny_Model.Deep_Embedding - 1);
      Logits : N.Real_Array (0 .. Tiny_Model.Vocabulary - 1);
      Raw : Bytes.Byte_Array (1 .. 20 + 4 * (1 + Tiny_Model.Deep_Embedding + Tiny_Model.Vocabulary));
      function Word (At_Byte : Bytes.Byte_Count) return Interfaces.Unsigned_32 is
        (Interfaces.Unsigned_32 (Raw (At_Byte))
         or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Raw (At_Byte + 1)), 8)
         or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Raw (At_Byte + 2)), 16)
         or Interfaces.Shift_Left (Interfaces.Unsigned_32 (Raw (At_Byte + 3)), 24));
   begin
      Ada.Directories.Create_Path (Root & "/dataset");
      Tiny_Model.Write (Root & "/base.gguf", Room => 16_384, Kind => Tiny_Model.Mellum, Format => Tiny_Model.Q6_K);
      Project_Tools.Files.Write_Raw_File
        (Root & "/dataset/train.jsonl",
         "{""input_tokens"":[1,3,4],""response_tokens"":[5,2],""loss_positions"":[1]}" & ASCII.LF);
      Ada.Directories.Copy_File (Root & "/dataset/train.jsonl", Root & "/dataset/validation.jsonl");
      Learning_Data.Extract
        (Root & "/base.gguf", Root & "/dataset", Root & "/extracted", Status,
         Backend => Model_Runner.Backend.Backend_CPU,
         Expected_Base => Learning_Lora_Files.Digest (Root & "/base.gguf"));
      Assert (E.Is_Ok (Status), "numerical feature extraction failed: " & Status'Image);
      F.Open (Source, Root & "/base.gguf", Status => Status);
      C.Reader.Parse (Parsed, Source, Status => Status);
      Engine.Prepare (Model, Parsed, Source, Threads => 7, Context => 16_384,
                      Cache => Engine.Transformed_Fourth, Status => Status);
      Assert (E.Is_Ok (Status), "independent feature model did not prepare");
      Engine.Open (Live, Model, Context => 5, Cache => Engine.Transformed_Fourth,
                   Values => Engine.Value_Fourth, Status => Status);
      Engine.Evaluate_Batch (Live, Model, [1, 3, 4], Logits, Status => Status);
      Engine.Hidden_State (Live, Hidden, Status);
      Assert (E.Is_Ok (Status), "independent prefix evaluation failed");
      F.Open (Feature_Source, Root & "/extracted/train.features", Status => Status);
      Feature_Source.Read (0, Raw, Status);
      Assert (E.Is_Ok (Status) and then Word (17) = 1 and then Word (21) = 5,
              "feature target does not name the next assistant token");
      for I in Hidden'Range loop
         Assert (abs (Hidden (I) - N.From_Bits (Word (Bytes.Byte_Count (25 + I * 4)))) < 1.0E-4,
                 "feature state does not precede the selected target token");
      end loop;
      for I in Logits'Range loop
         Assert (abs (Logits (I) - N.From_Bits
           (Word (Bytes.Byte_Count (25 + Tiny_Model.Deep_Embedding * 4) + Bytes.Byte_Count (I * 4)))) < 1.0E-4,
           "feature base logits do not precede the selected target token");
      end loop;
      Engine.Close (Live);
      Engine.Close (Model, Closed);
   end Feature_Target_Alignment;
   procedure Default_Arm_Statistics (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      package J renames Jsonlib.Documents;
      From, Result : J.Document;
      Rows : constant J.Node := J.New_Array (From);
      Error : Jsonlib.Errors.Error_Info;
      procedure Add (Task_Name, Arm, Grade : String; Seconds : Long_Float) is
         Row : constant J.Node := J.New_Object (From);
      begin
         J.Insert (From, Row, "task", J.New_String (From, Task_Name));
         J.Insert (From, Row, "arm", J.New_String (From, Arm));
         J.Insert (From, Row, "grade", J.New_String (From, Grade));
         J.Insert (From, Row, "seed", J.New_Integer (From, 51));
         J.Insert (From, Row, "work_seconds", J.New_Float (From, Seconds));
         J.Append (From, Rows, Row);
      end Add;
   begin
      J.Set_Root (From, Rows);
      Add ("shared", "base", "passed", 10.0);
      Add ("shared", "adapted", "passed", 8.0);
      Add ("loss", "base", "passed", 20.0);
      Add ("loss", "adapted", "failed", 300.0);
      Add ("win", "base", "failed", 0.001);
      Add ("win", "adapted", "passed", 30.0);
      Add ("neither", "base", "failed", 300.0);
      Add ("neither", "adapted", "failed", 300.0);
      Jsonlib.Parsers.Parse (Campaign_Statistics.Describe (From, Rows, Default_Only => True), Result, Error);
      Assert (not Jsonlib.Errors.Failed (Error), "default-arm statistics are not valid JSON");
      declare
         Comparisons : constant J.Node := J.Member (Result, J.Root (Result), "comparisons");
         Comparison : constant J.Node := J.Element (Result, Comparisons, 1);
      begin
         Assert (J.Length (Result, J.Member (Result, J.Root (Result), "arms")) = 2
                 and then J.Length (Result, Comparisons) = 1,
                 "unchanged-default comparison invented explicit thinking arms");
         Assert (J.As_Integer (Result, J.Member (Result, Comparison, "adapted_wins")) = 1
                 and then J.As_Integer (Result, J.Member (Result, Comparison, "adapted_losses")) = 1,
                 "default comparison lost a passing win or regression");
         Assert (J.As_Float (Result, J.Member (Result, Comparison, "base_median_work_seconds_both_solved")) = 10.0
                 and then J.As_Float
                   (Result, J.Member (Result, Comparison, "adapted_median_work_seconds_both_solved")) = 8.0,
                 "fast failures contaminated paired success costs");
      end;
   end Default_Arm_Statistics;
   procedure Sibling_Attempts_Are_Hidden (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      use Ada.Strings.Unbounded;
      Root : constant String := Ada.Directories.Full_Name (Fresh ("attempt-isolation"));
      Campaign : constant String := Root & "/campaign";
      Attempt : constant String := Campaign & "/edit-51-adapted";
      Project : constant String := Attempt & "/attempts/trial-edit";
      Sibling : constant String := Campaign & "/edit-51-base/result.json";
      Outside : constant String := Root & "/outside.txt";
      Ran : Hostkit.Process.Process_Outcome;
   begin
      Ada.Directories.Create_Path (Project);
      Ada.Directories.Create_Path (Campaign & "/edit-51-base");
      Project_Tools.Files.Write_Raw_File (Sibling, "sibling solution");
      Project_Tools.Files.Write_Raw_File (Outside, "outside marker");
      if not Trial_Confinement.Ready (Campaign) then
         return;
      end if;
      Ran := Hostkit.Process.Run_Captured
        (Trial_Confinement.Executable,
         Trial_Confinement.Wrap
           (Hostkit.Fs.Own_Executable,
            [To_Unbounded_String ("probe"), To_Unbounded_String ("campaign-boundary"),
             To_Unbounded_String (Project), To_Unbounded_String (Sibling), To_Unbounded_String (Outside)],
            Project, Learning_Isolation.Hidden_Root (Attempt)),
         Stdout_Path => Root & "/probe.txt", Stderr_Path => Root & "/probe-errors.txt", Timeout_Ms => 20_000);
      Assert (Ran.Started and then not Ran.Timed_Out and then Ran.Exit_Status = 0,
              "a learning attempt saw a sibling result or lost its writable project");
      Assert (Project_Tools.Files.Read_Raw_File (Sibling) = "sibling solution"
                and then Project_Tools.Files.Read_Raw_File (Outside) = "outside marker"
                and then Ada.Directories.Exists (Project & "/allowed.txt"),
              "learning isolation changed a protected result or refused the active project");
   end Sibling_Attempts_Are_Hidden;
   procedure Teaching_Graders (T : in out AUnit.Test_Cases.Test_Case'Class) is
      pragma Unreferenced (T);
      Root : constant String := Fresh ("graders");
      Clean : Boolean;
   begin
      Learning_Curriculum.Validate (Root, Clean);
      Assert (Clean, "teaching grader rejected a reference or accepted unchanged code");
   end Teaching_Graders;
   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, Independent_Gradient'Access, "cross entropy gradients match independent finite differences");
      Register_Routine (T, Parameters_Actually_Learn'Access, "Adam learns and malformed factors preserve weights");
      Register_Routine
        (T, Zero_Merge_Preserves_Model'Access, "zero merge preserves every byte and binds exact lineage");
      Register_Routine (T, Teaching_Graders'Access, "teaching reference and unchanged controls are qualified");
      Register_Routine
        (T, Nonzero_Merge_Oracle'Access, "nonzero and quantized merges match an independent head oracle");
      Register_Routine
        (T, Complete_Fit_And_Tamper'Access, "complete fitting selects trained checkpoints and refuses tampering");
      Register_Routine
        (T, Feature_Target_Alignment'Access, "features align frozen states with the next assistant token");
      Register_Routine (T, Default_Arm_Statistics'Access, "default-arm reports preserve regressions and honest costs");
      Register_Routine (T, Sibling_Attempts_Are_Hidden'Access, "learning attempts cannot see sibling solutions");
   end Register_Tests;
end Tests.Learning_Cases;
