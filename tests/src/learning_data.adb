with Ada.Containers.Vectors;
with Ada.Directories;
with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Jsonlib.Documents;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Jsonlib.Errors;
with Learning_Curriculum;
with Learning_Lora_Files;
with Model_Runner.Trajectories;
with Model_Runner.Text;
with Project_Tools.Files;

package body Learning_Data is
   package J renames Jsonlib.Documents;
   package E renames Model_Runner.Errors;
   package Trace renames Model_Runner.Trajectories;
   use Ada.Strings.Unbounded;
   use type J.Value_Kind;
   use type Ada.Directories.File_Size;
   use type Ada.Containers.Count_Type;
   package Ids is new Ada.Containers.Vectors (Positive, Natural);
   function Image (Value : Natural) return String is (Model_Runner.Text.Image (Long_Long_Integer (Value)));
   function Text (Doc : J.Document; At_Node : J.Node; Key : String) return String is
     (if J.Kind (Doc, At_Node) = J.Object_Value and then J.Has_Member (Doc, At_Node, Key)
       and then J.Kind (Doc, J.Member (Doc, At_Node, Key)) = J.String_Value
      then J.As_String (Doc, J.Member (Doc, At_Node, Key)) else "");
   procedure Curate
     (Collection, Output : String; Status : out E.Error_Info; Only_Family : Natural := 0) is
      Train, Validation, Ledger : Ada.Text_IO.File_Type;
      procedure Episode (Path, Family, Result_Path : String; Is_Validation : Boolean; Budget : in out Natural) is
         Checked : Trace.Validation;
         Events : Ada.Text_IO.File_Type;
         Prompt, Reply : Ids.Vector;
         Ends : Ids.Vector;
         Prompt_Text, Reply_Text, Pending_Piece : Unbounded_String;
         Pending_Id : Natural := 0;
         Last_Mutation, Good_Check : Natural := 0;
         Terminal : Natural := 0;
         Mutation_Count : array (1 .. 256) of Natural := [others => 0];
         Generation : Natural := 0;
         Digest : constant String := Learning_Lora_Files.Digest (Path);
         function Unhex (Hex : String) return String is
            Result : String (1 .. Hex'Length / 2);
            function Digit (Ch : Character) return Natural is
              (if Ch in '0' .. '9' then Character'Pos (Ch) - Character'Pos ('0')
               elsif Ch in 'a' .. 'f' then Character'Pos (Ch) - Character'Pos ('a') + 10
               else Character'Pos (Ch) - Character'Pos ('A') + 10);
         begin
            for I in Result'Range loop
               Result (I) := Character'Val (16 * Digit (Hex (Hex'First + 2 * (I - 1)))
                                            + Digit (Hex (Hex'First + 2 * (I - 1) + 1)));
            end loop;
            return Result;
         end Unhex;
         procedure Qualify_Generations is
            Call_Generation : array (1 .. 1_024) of Natural := [others => 0];
            Mutation, Check : array (1 .. 1_024) of Boolean := [others => False];
         begin
            Ada.Text_IO.Open (Events, Ada.Text_IO.In_File, Path);
            while not Ada.Text_IO.End_Of_File (Events) loop
               declare
                  Envelope, Data : J.Document;
                  Error : Jsonlib.Errors.Error_Info;
                  Line : constant String := Ada.Text_IO.Get_Line (Events);
               begin
                  Jsonlib.Parsers.Parse (Line, Envelope, Error);
                  declare
                     Kind : constant String := Text (Envelope, J.Root (Envelope), "kind");
                  begin
                     if Kind = "generation_start" then
                        Generation := Generation + 1;
                        if Generation > Mutation_Count'Length then
                           Status := E.Make (E.IO_Read_Failed);
                           exit;
                        end if;
                     elsif Kind in "tool_call" | "tool_result" then
                        Jsonlib.Parsers.Parse (Text (Envelope, J.Root (Envelope), "payload"), Data, Error);
                        declare
                           Root : constant J.Node := J.Root (Data);
                           Id : constant Long_Long_Integer := J.As_Integer (Data, J.Member (Data, Root, "id"));
                        begin
                           if Id not in 1 .. 1_024 then
                              Status := E.Make (E.IO_Read_Failed);
                              exit;
                           elsif Kind = "tool_call" then
                              Call_Generation (Natural (Id)) := Generation;
                              Mutation (Natural (Id)) := Text (Data, Root, "name") in "edit_file" | "write_file";
                              Check (Natural (Id)) := Text (Data, Root, "name") = "run_checks";
                              if Mutation (Natural (Id)) then
                                 Mutation_Count (Generation) := Mutation_Count (Generation) + 1;
                              end if;
                           elsif Mutation (Natural (Id)) and then Ada.Strings.Fixed.Index
                             (Text (Data, Root, "ending"), "CHANGED => TRUE") /= 0
                           then
                              Last_Mutation := Call_Generation (Natural (Id));
                           elsif Check (Natural (Id)) and then Ada.Strings.Fixed.Index
                             (Text (Data, Root, "text"), "checks passed") /= 0
                           then
                              Good_Check := Call_Generation (Natural (Id));
                           end if;
                        end;
                     end if;
                  end;
               end;
            end loop;
            Ada.Text_IO.Close (Events);
            Generation := 0;
         end Qualify_Generations;
         procedure Emit is
            Doc : J.Document;
            Root : constant J.Node := J.New_Object (Doc);
            P : constant J.Node := J.New_Array (Doc);
            R : constant J.Node := J.New_Array (Doc);
            Mask : constant J.Node := J.New_Array (Doc);
            Length : constant Natural := Natural (Reply.Length);
            Visible : Ids.Vector;
            Close_At : constant Natural := Ada.Strings.Fixed.Index
              (To_String (Reply_Text), "</think>", Going => Ada.Strings.Backward);
            First_Visible : constant Natural :=
              (if Close_At /= 0 then Close_At + 8
               elsif Ada.Strings.Fixed.Index (To_String (Prompt_Text), "<think>", Going => Ada.Strings.Backward) >
                 Ada.Strings.Fixed.Index (To_String (Prompt_Text), "</think>", Going => Ada.Strings.Backward)
               then Ada.Strings.Unbounded.Length (Reply_Text) + 1 else 1);
            Take : Natural;
            procedure Put (Key, Value : String) is
            begin
               J.Insert (Doc, Root, Key, J.New_String (Doc, Value));
            end Put;
         begin
            if Generation not in Last_Mutation | Good_Check | Checked.Generations
              or else Mutation_Count (Generation) > 1
              or else Prompt.Is_Empty or else Natural (Prompt.Length + Reply.Length) > 16_384
            then
               return;
            end if;
            for Index in 1 .. Length loop
               if (if Index = 1 then 1 else Ends.Element (Index - 1) + 1) >= First_Visible then
                  Visible.Append (Index);
               end if;
            end loop;
            if Terminal /= 0 and then not Visible.Is_Empty and then Visible.Last_Element /= Terminal then
               Visible.Append (Terminal);
            end if;
            Take := Natural'Min (32, Natural'Min (Budget, Natural (Visible.Length)));
            if Take = 0 then
               return;
            end if;
            J.Set_Root (Doc, Root);
            Put ("family", Family);
            Put ("split", (if Is_Validation then "validation" else "train"));
            Put ("capture_path", Path);
            Put ("capture_sha256", Digest);
            Put ("independent_result_path", Result_Path);
            Put ("independent_result_sha256", Learning_Lora_Files.Digest (Result_Path));
            Put ("loss_role", (if Generation = Last_Mutation then "verified-final-edit"
                               elsif Generation = Good_Check then "passed-check" else "completion"));
            J.Insert (Doc, Root, "generation", J.New_Integer (Doc, Long_Long_Integer (Generation)));
            for Token of Prompt loop
               J.Append (Doc, P, J.New_Integer (Doc, Long_Long_Integer (Token)));
            end loop;
            for Token of Reply loop
               J.Append (Doc, R, J.New_Integer (Doc, Long_Long_Integer (Token)));
            end loop;
            for Index in 1 .. Natural (Visible.Length) loop
               if Index * Take / Natural (Visible.Length) > (Index - 1) * Take / Natural (Visible.Length) then
                  J.Append (Doc, Mask, J.New_Integer (Doc, Long_Long_Integer (Visible.Element (Index))));
               end if;
            end loop;
            J.Insert (Doc, Root, "input_tokens", P);
            J.Insert (Doc, Root, "response_tokens", R);
            J.Insert (Doc, Root, "loss_positions", Mask);
            if Is_Validation then
               Ada.Text_IO.Put_Line (Validation, Jsonlib.Serializers.To_String (Doc));
            else
               Ada.Text_IO.Put_Line (Train, Jsonlib.Serializers.To_String (Doc));
            end if;
            Budget := Budget - Take;
         end Emit;
      begin
         Trace.Validate (Path, Checked, Status, Max_Bytes => 16 * 1_024 * 1_024);
         if E.Is_Error (Status) or else not Checked.Complete or else not Checked.Exact_Tokens
           or else Checked.Child_Episodes /= 0 or else To_String (Checked.Children) /= "[]"
         then
            Status := E.Make (E.IO_Read_Failed);
            return;
         end if;
         Qualify_Generations;
         if E.Is_Error (Status) or else Last_Mutation = 0 then
            Status := E.Make (E.IO_Read_Failed);
            return;
         end if;
         Ada.Text_IO.Open (Events, Ada.Text_IO.In_File, Path);
         while not Ada.Text_IO.End_Of_File (Events) loop
            declare
               Envelope, Data : J.Document;
               Parse_Error : Jsonlib.Errors.Error_Info;
               Line : constant String := Ada.Text_IO.Get_Line (Events);
            begin
               Jsonlib.Parsers.Parse (Line, Envelope, Parse_Error);
               Jsonlib.Parsers.Parse (Text (Envelope, J.Root (Envelope), "payload"), Data, Parse_Error);
               if Jsonlib.Errors.Failed (Parse_Error) then
                  Status := E.Make (E.IO_Read_Failed);
                  exit;
               end if;
               declare
                  Kind : constant String := Text (Envelope, J.Root (Envelope), "kind");
                  Root : constant J.Node := J.Root (Data);
               begin
                  if Kind = "episode_start" then
                     if Text (Data, J.Member (Data, Root, "provenance"), "model_sha256") /=
                       "ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755"
                     then
                        Status := E.Make (E.IO_Read_Failed);
                     end if;
                  elsif Kind = "generation_start" then
                     Generation := Generation + 1;
                     Prompt.Clear;
                     Reply.Clear;
                     Ends.Clear;
                     Reply_Text := Null_Unbounded_String;
                     Terminal := 0;
                  elsif Kind = "model_input" then
                     Prompt_Text := To_Unbounded_String (Text (Data, Root, "prompt"));
                     declare
                        Tokens : constant J.Node := J.Member (Data, Root, "tokens");
                     begin
                        for I in 1 .. J.Length (Data, Tokens) loop
                           Prompt.Append (Natural (J.As_Integer (Data, J.Element (Data, Tokens, I))));
                        end loop;
                     end;
                  elsif Kind = "committed_token" then
                     if Natural (J.As_Integer (Data, J.Member (Data, Root, "id"))) /= Pending_Id then
                        Status := E.Make (E.IO_Read_Failed);
                        exit;
                     end if;
                     Reply.Append (Natural (J.As_Integer (Data, J.Member (Data, Root, "id"))));
                     Append (Reply_Text, To_String (Pending_Piece));
                     Ends.Append (Ada.Strings.Unbounded.Length (Reply_Text));
                  elsif Kind = "selected_token" then
                     Pending_Id := Natural (J.As_Integer (Data, J.Member (Data, Root, "id")));
                     Pending_Piece := To_Unbounded_String (Unhex (Text (Data, Root, "piece_hex")));
                     if J.As_Boolean (Data, J.Member (Data, Root, "terminal")) then
                        Reply.Append (Pending_Id);
                        Append (Reply_Text, To_String (Pending_Piece));
                        Ends.Append (Ada.Strings.Unbounded.Length (Reply_Text));
                        Terminal := Natural (Reply.Length);
                     end if;
                  elsif Kind = "generation_end" and then Text (Data, Root, "reason") = "end_of_sequence" then
                     Emit;
                  end if;
               end;
            end;
            exit when E.Is_Error (Status);
         end loop;
         Ada.Text_IO.Close (Events);
      exception
         when others =>
            if Ada.Text_IO.Is_Open (Events) then
               Ada.Text_IO.Close (Events);
            end if;
            Status := E.Make (E.IO_Read_Failed);
      end Episode;
   begin
      Status := E.Success;
      if Only_Family > Learning_Curriculum.Families then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      if Ada.Directories.Exists (Output) then
         Status := E.Make (E.IO_Open_Failed);
         return;
      end if;
      Ada.Directories.Create_Path (Output);
      Ada.Text_IO.Create (Train, Ada.Text_IO.Out_File, Output & "/train.jsonl");
      Ada.Text_IO.Create (Validation, Ada.Text_IO.Out_File, Output & "/validation.jsonl");
      Ada.Text_IO.Create (Ledger, Ada.Text_IO.Out_File, Output & "/outcomes.jsonl");
      for Which in 1 .. Learning_Curriculum.Families loop
         if Only_Family = 0 or else Which = Only_Family then
            declare
               Family : constant String := Learning_Curriculum.Family (Which);
               Budget : Natural := 256;
            begin
               for Seed in 42 .. 44 loop
                  declare
                     Path : constant String := Collection & "/" & Family & "-" & Image (Seed) & "/result.json";
                     Result : J.Document;
                     Parse_Error : Jsonlib.Errors.Error_Info;
                  begin
                     if not Ada.Directories.Exists (Path) or else Ada.Directories.Size (Path) > 1_048_576 then
                        Status := E.Make (E.IO_Read_Failed);
                        exit;
                     end if;
                     Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Path), Result, Parse_Error);
                     if Jsonlib.Errors.Failed (Parse_Error)
                       or else Text (Result, J.Root (Result), "state") /= "finished"
                       or else Text (Result, J.Root (Result), "grade") = "infrastructure_error"
                     then
                        Status := E.Make (E.IO_Read_Failed);
                        exit;
                     end if;
                     Ada.Text_IO.Put_Line (Ledger, Jsonlib.Serializers.To_String (Result));
                     if Text (Result, J.Root (Result), "grade") = "passed" then
                        Episode
                          (Text (Result, J.Root (Result), "directory")
                           & "/.trial-runtime/captures/episode-1/events.jsonl",
                           Family, Path, Which = Learning_Curriculum.Families, Budget);
                     end if;
                     exit when E.Is_Error (Status);
                  end;
               end loop;
               if Budget = 256 then
                  Status := E.Make (E.IO_Read_Failed);
               end if;
            end;
         end if;
         exit when E.Is_Error (Status);
      end loop;
      Ada.Text_IO.Close (Train);
      Ada.Text_IO.Close (Validation);
      Ada.Text_IO.Close (Ledger);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Train) then
            Ada.Text_IO.Close (Train);
         end if;
         if Ada.Text_IO.Is_Open (Validation) then
            Ada.Text_IO.Close (Validation);
         end if;
         if Ada.Text_IO.Is_Open (Ledger) then
            Ada.Text_IO.Close (Ledger);
         end if;
         Status := E.Make (E.IO_Read_Failed);
   end Curate;
   procedure Extract
     (Model, Dataset, Output : String; Status : out E.Error_Info;
      Backend : Model_Runner.Backend.Backend_Kind := Model_Runner.Backend.Backend_Device;
      Expected_Base : String := "ecc4d5b8107fc219e23c494b2d107552137637b6c6002ee713e0ba8af7fa2755") is separate;
end Learning_Data;
