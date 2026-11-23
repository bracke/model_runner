with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.SHA256;
with Agent_Campaign;
with Agent_Trial;
with Hostkit;
with Hostkit.Fs;
with Jsonlib.Documents;
with Jsonlib.Serializers;
with Model_Runner.Errors;
with Project_Tools.Files;
with Trial_Confinement;
with Trial_Settings;

--  A bounded, independently graded base-only edit check, without starting four campaign arms.
--  Usage: cpu_work_probe MODEL PROGRAM TEMPLATE NEW_OUTPUT THREADS BATCH CACHE REPEATS
procedure CPU_Work_Probe is
   package J renames Jsonlib.Documents;
   package E renames Model_Runner.Errors;
   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Kind;
   use type Agent_Trial.Verdict;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Number (Index : Positive) return Natural is
      Text : constant String := Ada.Command_Line.Argument (Index);
   begin
      if Text'Length not in 1 .. 4 or else (for some C of Text => C not in '0' .. '9') then
         return 0;
      end if;
      return Natural'Value (Text);
   end Number;

   procedure Refuse (Code : E.Error_Code; Detail : String) is
      Error : E.Error_Info := E.Make (Code);
   begin
      E.Add_Text (Error, "detail", Detail);
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, E.Diagnostic_Code (Error.Code) & ": " & E.Text_Of (Error, "detail"));
   end Refuse;
begin
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   if Ada.Command_Line.Argument_Count /= 8 then
      Refuse (E.CLI_Invalid_Option_Value,
              "usage: cpu_work_probe MODEL PROGRAM TEMPLATE NEW_OUTPUT THREADS BATCH CACHE REPEATS");
      return;
   end if;
   for Index in 1 .. 8 loop
      if Ada.Command_Line.Argument (Index)'Length not in 1 .. 4_096 then
         Refuse (E.CLI_Invalid_Option_Value, "empty or excessive argument");
         return;
      end if;
   end loop;
   declare
      Threads : constant Natural := Number (5);
      Batch : constant Natural := Number (6);
      Repeats : constant Natural := Number (8);
      Cache : constant String := Ada.Command_Line.Argument (7);
      Doc : J.Document;
      Root : constant J.Node := J.New_Object (Doc);
      Variables : Hostkit.String_Vectors.Vector;
      All_Passed : Boolean := True;

      procedure Collect (Name, Value : String) is
         pragma Unreferenced (Value);
      begin
         if Name'Length >= 13 and then Name (Name'First .. Name'First + 12) = "MODEL_RUNNER_" then
            Variables.Append (To_Unbounded_String (Name));
         end if;
      end Collect;

      procedure Text (Name, Value : String) is
      begin
         J.Insert (Doc, Root, Name, J.New_String (Doc, Value));
      end Text;
   begin
      if Threads not in 1 .. 16 or else Batch not in 1 .. 1_024 or else Repeats not in 1 .. 3
        or else Cache not in "q4t" | "f16" or else Ada.Directories.Exists (Ada.Command_Line.Argument (4))
      then
         Refuse (E.CLI_Invalid_Option_Value, "invalid bounds, cache, or output directory already exists");
         return;
      end if;
      for Index in 1 .. 3 loop
         if not Ada.Directories.Exists (Ada.Command_Line.Argument (Index))
           or else Ada.Directories.Kind (Ada.Command_Line.Argument (Index)) /= Ada.Directories.Ordinary_File
         then
            Refuse (E.IO_Not_A_Regular_File, Ada.Command_Line.Argument (Index));
            return;
         end if;
      end loop;
      Ada.Directories.Create_Path (Ada.Command_Line.Argument (4));
      declare
         Directory : constant String := Ada.Directories.Full_Name (Ada.Command_Line.Argument (4));
         Model : constant String := Ada.Directories.Full_Name (Ada.Command_Line.Argument (1));
         Program : constant String := Ada.Directories.Full_Name (Ada.Command_Line.Argument (2));
         Template : constant String := Ada.Directories.Full_Name (Ada.Command_Line.Argument (3));
         Options : constant String :=
           "--backend cpu --threads " & Image (Threads) & " --batch-size " & Image (Batch)
           & " --kv-cache " & Cache & " --repack rows --mmap --arith int8 --draft-tokens 0"
           & " --no-think --temperature 0.8 --top-p 1 --top-k 0 --min-p 0";
      begin
         if not Trial_Confinement.Ready (Directory) then
            Refuse (E.IO_Open_Failed, "native OS confinement unavailable");
            return;
         end if;
         Ada.Environment_Variables.Iterate (Collect'Access);
         for Name of Variables loop
            Ada.Environment_Variables.Clear (To_String (Name));
         end loop;
         Project_Tools.Files.Write_Raw_File (Directory & "/config", "# fixed base-only probe" & ASCII.LF);
         Ada.Environment_Variables.Set ("MODEL_RUNNER_CONFIG", Directory & "/config");
         Ada.Environment_Variables.Set ("MODEL_RUNNER_INSTRUCTIONS", "off");
         J.Set_Root (Doc, Root);
         Text ("model", Model);
         Text ("model_sha256", Agent_Campaign.File_Digest (Model));
         Text ("program_sha256", Agent_Campaign.File_Digest (Program));
         Text ("harness_sha256", Agent_Campaign.File_Digest (Hostkit.Fs.Own_Executable));
         Text ("template_sha256", Agent_Campaign.File_Digest (Template));
         for Name of Hostkit.String_Vectors.Vector'
           ([To_Unbounded_String ("model_sha256"), To_Unbounded_String ("program_sha256"),
             To_Unbounded_String ("harness_sha256"), To_Unbounded_String ("template_sha256")])
         loop
            if J.As_String (Doc, J.Member (Doc, Root, To_String (Name))) = "" then
               Refuse (E.IO_Read_Failed, "an input could not be hashed");
               return;
            end if;
         end loop;
         Text ("options", Options);
         Text ("scope", "base-only edit, fresh projects, seeds 42 onward, context 8192, 300 seconds work");
         J.Insert (Doc, Root, "repeats", J.New_Integer (Doc, Long_Long_Integer (Repeats)));
         declare
            Manifest : constant String := Jsonlib.Serializers.To_String (Doc);
            Digest : constant String := GNAT.SHA256.Digest (Manifest);
         begin
            Project_Tools.Files.Write_Raw_File (Directory & "/manifest.json", Manifest);
            for Round in 1 .. Repeats loop
               declare
                  Seed : constant Natural := 41 + Round;
                  Seen : Boolean := False;
                  Clean : Boolean := False;
                  procedure Record_Attempt (Item : Agent_Trial.Attempt) is
                     Result : Agent_Trial.Attempt := Item;
                  begin
                     if To_String (Item.Isolation) /= "bubblewrap-v1"
                       or else Length (Item.Configuration_Before) = 0
                       or else Item.Configuration_Before /= Item.Configuration_After
                       or else not Trial_Settings.Valid
                         (To_String (Item.Resolved_Settings), Need_Work => Item.Grade = Agent_Trial.Passed)
                       or else not Trial_Settings.Matches
                         (To_String (Item.Resolved_Settings), Seed, 8_192, False, 0)
                     then
                        Result.Grade := Agent_Trial.Infrastructure_Error;
                        Result.Ending := To_Unbounded_String ("native settings or configuration did not qualify");
                     end if;
                     Project_Tools.Files.Write_Raw_File
                       (Directory & "/attempt-" & Image (Round) & ".json",
                        Agent_Campaign.Attempt_JSON ("edit-" & Image (Round), "base-off", Seed, Result, Digest));
                     All_Passed := All_Passed and then Result.Grade = Agent_Trial.Passed;
                     Seen := True;
                  end Record_Attempt;
               begin
                  Agent_Trial.Run
                    (Model => Model, Program => Program, Options => Options & " --seed " & Image (Seed),
                     Only => "edit", Clean => Clean, Knowledge => False, Carry => False,
                     Max_Seconds => 300, Context_Size => 8_192, Inference => "fixed",
                     Output_Directory => Directory & "/run-" & Image (Round), Isolation_Root => Directory,
                     Extra_Arguments => [To_Unbounded_String ("--chat-template-file"),
                                         To_Unbounded_String (Template)], On_Attempt => Record_Attempt'Access);
                  All_Passed := All_Passed and then Seen and then Clean;
                  exit when not Seen or else not Clean or else not All_Passed;
               end;
            end loop;
         end;
         if All_Passed then
            Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
         end if;
      end;
   end;
exception
   when Failure : others =>
      declare
         Error : constant E.Error_Info := E.Unexpected (Failure, "running bounded CPU work probe");
      begin
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, E.Diagnostic_Code (Error.Code));
      end;
end CPU_Work_Probe;
