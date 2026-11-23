with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.SHA256;
with Hostkit;
with Hostkit.Fs;
with Hostkit.Locks;
with Hostkit.Durability;
with Hostkit.Process;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Model_Runner.Durable_Syncs;
with Model_Runner.CLI.Options;
with Model_Runner.Errors;
with Project_Tools.Files;
with Project_Tools.Text;
with Campaign_Statistics;

package body Agent_Campaign is

   package J renames Jsonlib.Documents;
   use Ada.Strings.Unbounded;
   use type Ada.Directories.File_Size;
   use type Hostkit.Locks.Lock_Outcome;
   use type Hostkit.Durability.Outcome;
   use type J.Value_Kind;
   use type Jsonlib.Errors.Error_Code;
   use type Model_Runner.Numerics.Real;

   function Scale_Image (Value : Model_Runner.Numerics.Real) return String is
      package Scale_IO is new Ada.Text_IO.Float_IO (Model_Runner.Numerics.Real);
      Buffer : String (1 .. 96);
   begin
      --  The native decimal parser retains up to eighteen fractional digits.
      --  Native_Scale checks that this representation preserves the actual binary32 value.
      Scale_IO.Put (Buffer, Value, Aft => 18, Exp => 0);
      return Ada.Strings.Fixed.Trim (Buffer, Ada.Strings.Both);
   end Scale_Image;

   function Native_Scale (Scale : Model_Runner.Numerics.Real) return Boolean is
      package O renames Model_Runner.CLI.Options;
      type Scale_Arguments is limited new O.Arguments with null record;
      overriding function Count (Self : Scale_Arguments) return Natural is (8);
      overriding function Value (Self : Scale_Arguments; Index : Positive) return String
      is (case Index is
            when 1 => "run", when 2 | 4 => "unused.gguf", when 3 => "--lora",
            when 5 => "--lora-mode", when 6 => "runtime", when 7 => "--lora-scale",
            when others => Scale_Image (Scale));
      Arguments : Scale_Arguments;
      Command : O.Command;
      Status : Model_Runner.Errors.Error_Info;
      Good : Boolean;
   begin
      O.Parse (Arguments, Command, Status);
      Good := Model_Runner.Errors.Is_Ok (Status) and then Command.Scale_Count = 1
        and then Command.Adapter_Scales (1) = Scale;
      O.Release (Command);
      return Good;
   end Native_Scale;

   function Image (N : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (N), Ada.Strings.Both));

   function File_Digest (Path : String) return String is
      use Ada.Streams;
      File : Stream_IO.File_Type;
      Buffer : Stream_Element_Array (1 .. 65_536);
      Last : Stream_Element_Offset;
      Context : GNAT.SHA256.Context;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Path);
      while not Stream_IO.End_Of_File (File) loop
         Stream_IO.Read (File, Buffer, Last);
         declare
            Text : String (1 .. Natural (Last)) with Import, Address => Buffer'Address;
         begin
            GNAT.SHA256.Update (Context, Text);
         end;
      end loop;
      Stream_IO.Close (File);
      return GNAT.SHA256.Digest (Context);
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         return "";
   end File_Digest;

   function Attempt_JSON
     (Id, Arm : String; Seed : Natural; Item : Agent_Trial.Attempt;
      Manifest_SHA256 : String := "") return String
   is
      Doc : J.Document;
      Root : constant J.Node := J.New_Object (Doc);
      procedure Text (Name, Value : String) is
      begin
         J.Insert (Doc, Root, Name, J.New_String (Doc, Value));
      end Text;
      procedure Metric (Name : String; Value : Long_Long_Integer) is
      begin
         J.Insert (Doc, Root, Name,
                   (if Value < 0 then J.New_Null (Doc) else J.New_Integer (Doc, Value)));
      end Metric;
      procedure Seconds (Name : String; Value : Duration) is
      begin
         J.Insert (Doc, Root, Name,
                   (if Value < 0.0 then J.New_Null (Doc) else J.New_Float (Doc, Long_Float (Value))));
      end Seconds;
   begin
      J.Set_Root (Doc, Root);
      J.Insert (Doc, Root, "schema_version", J.New_Integer (Doc, 1));
      Text ("state", "finished");
      Text ("attempt_id", Id);
      Text ("manifest_sha256", Manifest_SHA256);
      Text ("arm", Arm);
      Text ("task", To_String (Item.Task_Name));
      Text ("grade", Ada.Characters.Handling.To_Lower (Agent_Trial.Verdict'Image (Item.Grade)));
      Text ("ending", To_String (Item.Ending));
      Text ("directory", To_String (Item.Directory));
      Text ("figures", To_String (Item.Figures));
      Metric ("seed", Long_Long_Integer (Seed));
      Metric ("calls", Item.Executed_Calls);
      Metric ("tool_requests", Long_Long_Integer (Item.Calls));
      Metric ("generated_tokens", Item.Generated_Tokens);
      Metric ("root_generated_tokens", Item.Root_Tokens);
      Metric ("delegated_tokens", Item.Delegated_Tokens);
      Metric ("compactions", Item.Compactions);
      Metric ("prompt_read_tokens", Item.Prompt_Read);
      Metric ("prompt_reused_tokens", Item.Prompt_Reused);
      Seconds ("elapsed_seconds", Item.Seconds);
      Seconds ("load_seconds", Item.Load_Seconds);
      Seconds ("work_seconds", Item.Work_Seconds);
      for Name of Hostkit.String_Vectors.Vector'
        ([To_Unbounded_String ("peak_host_bytes"), To_Unbounded_String ("device_resident_bytes")])
      loop
         J.Insert (Doc, Root, To_String (Name), J.New_Null (Doc));
      end loop;
      return Jsonlib.Serializers.To_String (Doc);
   end Attempt_JSON;

   procedure Atomic_Write (Path, Text : String) is
   begin
      Project_Tools.Files.Write_Raw_File (Path & ".tmp", Text);
      if Model_Runner.Durable_Syncs.Sync_File (Path & ".tmp") /= Hostkit.Durability.Synced
        or else not Hostkit.Fs.Replace_File (Path & ".tmp", Path)
        or else Model_Runner.Durable_Syncs.Sync_Directory (Ada.Directories.Containing_Directory (Path))
          /= Hostkit.Durability.Synced
      then
         raise Ada.Text_IO.Use_Error with "cannot publish " & Path;
      end if;
   end Atomic_Write;

   function Read_Record (Path : String; Into : in out J.Document) return Boolean is
      Error : Jsonlib.Errors.Error_Info;
   begin
      if not Ada.Directories.Exists (Path) or else Ada.Directories.Size (Path) > 1_048_576 then
         return False;
      end if;
      Jsonlib.Parsers.Parse
        (Project_Tools.Files.Read_Raw_File (Path), Into, Error,
         (Max_Depth => 16, Max_Length => 1_048_576, Duplicates => Jsonlib.Parsers.Refuse_Duplicates));
      return Error.Code = Jsonlib.Errors.No_Error and then J.Kind (Into, J.Root (Into)) = J.Object_Value;
   end Read_Record;

   procedure Run
     (Base, Adapted, Program, Output_Directory : String;
      Clean : out Boolean;
      Only : String := "edit,find,delegate";
      Options : String := "--backend cpu --threads 8 --kv-cache q4t";
      Repeats : Positive := 3;
      Max_Seconds : Positive := 300;
      Context_Size : Positive := 8_192;
      Seed : Natural := 42;
      Check_Only : Boolean := False;
      Base_Adapter : String := "";
      Adapted_Adapter : String := "";
      Base_Scale : Model_Runner.Numerics.Real := 1.0;
      Adapted_Scale : Model_Runner.Numerics.Real := 1.0)
   is
      --  Inspect nonfinite scales explicitly before any formatting or arithmetic.
      pragma Suppress (Validity_Check);
      Directory : constant String := Ada.Directories.Full_Name (Output_Directory);
      Names : Hostkit.String_Vectors.Vector;
      Guard : Hostkit.Locks.Lock;
      Manifest : J.Document;
      Root : constant J.Node := J.New_Object (Manifest);
      Complete : Natural := 0;
      Failures : Natural := 0;
      Unknown : Natural := 0;
      Started_Count : Natural := 0;
      Infrastructure : Natural := 0;
      Blocked : Boolean := False;
      Summary : J.Document;
      Summary_Root : constant J.Node := J.New_Object (Summary);
      Results : constant J.Node := J.New_Array (Summary);
      Base_Hash, Adapted_Hash, Program_Hash, Harness_Hash : Unbounded_String;
      Base_Adapter_Hash, Adapted_Adapter_Hash, Manifest_Hash : Unbounded_String;

      function Adapter_Path (Arm : Positive) return String
      is (if Arm in 1 | 3 then Base_Adapter else Adapted_Adapter);

      function Adapter_Scale (Arm : Positive) return Model_Runner.Numerics.Real
      is (if Arm in 1 | 3 then Base_Scale else Adapted_Scale);

      function Adapter_Arguments (Arm : Positive) return Hostkit.String_Vectors.Vector is
      begin
         if Adapter_Path (Arm) = "" then
            return Hostkit.String_Vectors.Empty_Vector;
         end if;
         return [To_Unbounded_String ("--lora"),
                 To_Unbounded_String (Ada.Directories.Full_Name (Adapter_Path (Arm))),
                 To_Unbounded_String ("--lora-mode"), To_Unbounded_String ("runtime"),
                 To_Unbounded_String ("--lora-scale"), To_Unbounded_String (Scale_Image (Adapter_Scale (Arm)))];
      end Adapter_Arguments;

      function Explicit_CPU return Boolean is
         Start : Positive := Options'First;
         Expect_Backend : Boolean := False;
         Found : Boolean := False;
      begin
         for I in Options'First .. Options'Last + 1 loop
            if I > Options'Last or else Options (I) = ' ' then
               if I > Start then
                  declare
                     Word : constant String := Options (Start .. I - 1);
                  begin
                     if Expect_Backend then
                        if Word /= "cpu" then
                           return False;
                        end if;
                        Found := True;
                        Expect_Backend := False;
                     elsif Word = "--backend" then
                        Expect_Backend := True;
                     elsif Word'Length >= 10 and then Word (Word'First .. Word'First + 9) = "--backend=" then
                        if Word /= "--backend=cpu" then
                           return False;
                        end if;
                        Found := True;
                     end if;
                  end;
               end if;
               Start := I + 1;
            end if;
         end loop;
         return Found and then not Expect_Backend;
      end Explicit_CPU;

      procedure Say (Text : String) is
      begin
         Ada.Text_IO.Put_Line ("agent-campaign: " & Text);
      end Say;

      procedure Put (Name, Value : String) is
      begin
         J.Insert (Manifest, Root, Name, J.New_String (Manifest, Value));
      end Put;

      procedure Save_Summary is
         Statistics : J.Document;
         Error : Jsonlib.Errors.Error_Info;
      begin
         Jsonlib.Parsers.Parse (Campaign_Statistics.Describe (Summary, Results), Statistics, Error);
         if Error.Code /= Jsonlib.Errors.No_Error then
            raise Program_Error with "invalid campaign statistics";
         end if;
         J.Set_Member (Summary, Summary_Root, "statistics", J.Copy (Summary, Statistics, J.Root (Statistics)));
         J.Set_Member (Summary, Summary_Root, "planned_attempts",
                       J.New_Integer (Summary, Long_Long_Integer (Natural (Names.Length) * Repeats * 4)));
         J.Set_Member (Summary, Summary_Root, "pending_attempts", J.New_Integer
                       (Summary, Long_Long_Integer (Natural (Names.Length) * Repeats * 4
                         - Complete - Failures - Unknown - Infrastructure)));
         J.Set_Member (Summary, Summary_Root, "passed", J.New_Integer (Summary, Long_Long_Integer (Complete)));
         J.Set_Member (Summary, Summary_Root, "failed", J.New_Integer (Summary, Long_Long_Integer (Failures)));
         J.Set_Member (Summary, Summary_Root, "ungraded", J.New_Integer (Summary, Long_Long_Integer (Unknown)));
         J.Set_Member (Summary, Summary_Root, "infrastructure_errors",
                       J.New_Integer (Summary, Long_Long_Integer (Infrastructure)));
         J.Set_Member (Summary, Summary_Root, "blocked", J.New_Boolean (Summary, Blocked));
         J.Set_Member (Summary, Summary_Root, "recommendation", J.New_String (Summary, "inconclusive"));
         Atomic_Write (Directory & "/summary.json", Jsonlib.Serializers.To_String (Summary));
      end Save_Summary;

      procedure Keep (Doc : J.Document) is
         Grade : constant String := J.As_String (Doc, J.Member (Doc, J.Root (Doc), "grade"));
      begin
         J.Append (Summary, Results, J.Copy (Summary, Doc, J.Root (Doc)));
         if Grade = "passed" then
            Complete := Complete + 1;
         elsif Grade = "failed" then
            Failures := Failures + 1;
         elsif Grade = "ungraded" then
            Unknown := Unknown + 1;
         else
            Infrastructure := Infrastructure + 1;
         end if;
         Save_Summary;
      end Keep;

      procedure One (Task_Name : String; Round, Arm : Positive) is
         Arm_Name : constant String :=
           (case Arm is when 1 => "base-off", when 2 => "adapted-off",
                        when 3 => "base-on", when others => "adapted-on");
         Id : constant String := Task_Name & "-" & Image (Round) & "-" & Arm_Name;
         Path : constant String := Directory & "/" & Id & ".json";
         Local_Seed : constant Natural := Seed + Round - 1;
         Seen : Boolean := False;
         Passed : Boolean;
         Item : Agent_Trial.Attempt;
         Doc : J.Document;

         procedure Record_Attempt (Result : Agent_Trial.Attempt) is
            Data : J.Document;
            Error : Jsonlib.Errors.Error_Info;
         begin
            Jsonlib.Parsers.Parse
              (Attempt_JSON (Id, Arm_Name, Local_Seed, Result, To_String (Manifest_Hash)), Data, Error);
            if Error.Code /= Jsonlib.Errors.No_Error then
               raise Program_Error with "invalid campaign serialization";
            end if;
            Atomic_Write (Path, Jsonlib.Serializers.To_String (Data));
            Keep (Data);
            Seen := True;
         end Record_Attempt;
      begin
         if Ada.Directories.Exists (Path) then
            if Read_Record (Path, Doc)
              and then J.As_String (Doc, J.Member (Doc, J.Root (Doc), "state")) = "finished"
              and then J.As_String (Doc, J.Member (Doc, J.Root (Doc), "attempt_id")) = Id
              and then J.As_String (Doc, J.Member (Doc, J.Root (Doc), "arm")) = Arm_Name
              and then J.As_String (Doc, J.Member (Doc, J.Root (Doc), "task")) = Task_Name
              and then J.As_String (Doc, J.Member (Doc, J.Root (Doc), "manifest_sha256"))
                = To_String (Manifest_Hash)
              and then J.As_Integer (Doc, J.Member (Doc, J.Root (Doc), "seed")) = Long_Long_Integer (Local_Seed)
            then
               Keep (Doc);
               return;
            end if;
            Say (Id & " has an unfinished or invalid record; reconcile it before resuming");
            Blocked := True;
            Save_Summary;
            return;
         elsif Check_Only then
            return;
         end if;
         if File_Digest (Program) /= To_String (Program_Hash) then
            Say ("program changed during the campaign; use the pinned binary");
            Blocked := True;
            Save_Summary;
            return;
         end if;
         if Adapter_Path (Arm) /= ""
           and then File_Digest (Adapter_Path (Arm))
             /= To_String (if Arm in 1 | 3 then Base_Adapter_Hash else Adapted_Adapter_Hash)
         then
            Say ("adapter changed during the campaign; use the pinned file");
            Blocked := True;
            Save_Summary;
            return;
         end if;
         Atomic_Write (Path, "{""schema_version"":1,""state"":""invoking""}");
         Say ("running " & Id);
         Started_Count := Started_Count + 1;
         Agent_Trial.Run
           (Model => Ada.Directories.Full_Name (if Arm in 1 | 3 then Base else Adapted),
            Program => Ada.Directories.Full_Name (Program),
            Options => Options & " --seed " & Image (Local_Seed) & " --draft-tokens 0"
              & (if Arm <= 2 then " --no-think" else " --think"),
            Only => Task_Name, Clean => Passed, Repeats => 1, Knowledge => False, Carry => False,
            Max_Seconds => Max_Seconds, Context_Size => Context_Size, Inference => "fixed",
            Output_Directory => Directory & "/" & Id, On_Attempt => Record_Attempt'Access,
            Extra_Arguments => Adapter_Arguments (Arm));
         if not Seen then
            Item.Task_Name := To_Unbounded_String (Task_Name);
            Item.Ending := To_Unbounded_String ("trial returned before producing an attempt");
            Item.Directory := To_Unbounded_String (Directory & "/" & Id);
            Record_Attempt (Item);
         end if;
      end One;
   begin
      Clean := False;
      if Output_Directory = "" or else Only = "" or else Only'Length > 1_024
        or else Repeats > 999 or else Context_Size < 512 or else Context_Size > 131_072
        or else Max_Seconds > 86_400 or else Seed > Natural'Last - Repeats
      then
         Say ("invalid output, tasks, repeat count, context, time budget or seed");
         return;
      end if;
      if not Model_Runner.Numerics.Is_Finite (Base_Scale)
        or else not Model_Runner.Numerics.Is_Finite (Adapted_Scale)
        or else (Base_Adapter = "" and then Base_Scale /= 1.0)
        or else (Adapted_Adapter = "" and then Adapted_Scale /= 1.0)
      then
         Say ("adapter scales must be finite and require an adapter");
         return;
      end if;
      if (Base_Adapter /= "" or else Adapted_Adapter /= "") and then not Explicit_CPU then
         Say ("runtime adapter campaigns require an explicit --backend cpu for both arms");
         return;
      end if;
      if (Base_Adapter /= "" and then not Native_Scale (Base_Scale))
        or else (Adapted_Adapter /= "" and then not Native_Scale (Adapted_Scale))
      then
         Say ("adapter scale cannot be represented exactly by the native CLI decimal syntax");
         return;
      end if;
      declare
         Start : Positive := Only'First;
      begin
         for I in Only'First .. Only'Last + 1 loop
            if I > Only'Last or else Only (I) = ',' then
               declare
                  Name : constant String := Only (Start .. I - 1);
               begin
                  if not Agent_Trial.Known_Task (Name) or else Names.Contains (To_Unbounded_String (Name)) then
                     Say ("unknown or repeated task: " & Name);
                     return;
                  end if;
                  Names.Append (To_Unbounded_String (Name));
               end;
               Start := I + 1;
            end if;
         end loop;
      end;
      --  These controls belong to the paired design, not to a caller's shared options.
      for Forbidden of Hostkit.String_Vectors.Vector'
        ([To_Unbounded_String ("--seed"), To_Unbounded_String ("--draft"),
          To_Unbounded_String ("--think"), To_Unbounded_String ("--no-think"),
          To_Unbounded_String ("--context-size"), To_Unbounded_String ("--config"),
          To_Unbounded_String ("--lora")])
      loop
         if Ada.Strings.Fixed.Index (Options, To_String (Forbidden)) > 0 then
            Say ("shared options override a campaign control: " & To_String (Forbidden));
            return;
         end if;
      end loop;
      Ada.Directories.Create_Path (Directory);
      if Hostkit.Locks.Acquire (Directory & "/campaign.lock", Hostkit.Locks.Lock_Exclusive, False, Guard)
        /= Hostkit.Locks.Lock_Ok
      then
         Say ("campaign is already locked or cannot be locked");
         return;
      end if;
      Base_Hash := To_Unbounded_String (File_Digest (Base));
      Adapted_Hash := To_Unbounded_String (File_Digest (Adapted));
      Program_Hash := To_Unbounded_String (File_Digest (Program));
      Harness_Hash := To_Unbounded_String (File_Digest (Hostkit.Fs.Own_Executable));
      if Base_Adapter /= "" then
         Base_Adapter_Hash := To_Unbounded_String (File_Digest (Base_Adapter));
      end if;
      if Adapted_Adapter /= "" then
         Adapted_Adapter_Hash := To_Unbounded_String (File_Digest (Adapted_Adapter));
      end if;
      if Length (Base_Hash) = 0 or else Length (Adapted_Hash) = 0
        or else Length (Program_Hash) = 0 or else Length (Harness_Hash) = 0
        or else (Base_Adapter /= "" and then Length (Base_Adapter_Hash) = 0)
        or else (Adapted_Adapter /= "" and then Length (Adapted_Adapter_Hash) = 0)
      then
         Say ("a model, adapter, program or campaign harness could not be hashed");
         Hostkit.Locks.Release (Guard);
         return;
      end if;
      J.Set_Root (Manifest, Root);
      J.Insert (Manifest, Root, "schema_version", J.New_Integer (Manifest, 1));
      Put ("base", Ada.Directories.Full_Name (Base));
      Put ("adapted", Ada.Directories.Full_Name (Adapted));
      Put ("program", Ada.Directories.Full_Name (Program));
      Put ("base_sha256", To_String (Base_Hash));
      Put ("adapted_sha256", To_String (Adapted_Hash));
      Put ("program_sha256", To_String (Program_Hash));
      Put ("harness_sha256", To_String (Harness_Hash));
      Put ("base_adapter", (if Base_Adapter = "" then "" else Ada.Directories.Full_Name (Base_Adapter)));
      Put ("adapted_adapter", (if Adapted_Adapter = "" then "" else Ada.Directories.Full_Name (Adapted_Adapter)));
      Put ("base_adapter_sha256", To_String (Base_Adapter_Hash));
      Put ("adapted_adapter_sha256", To_String (Adapted_Adapter_Hash));
      Put ("base_adapter_mode", (if Base_Adapter = "" then "none" else "runtime"));
      Put ("adapted_adapter_mode", (if Adapted_Adapter = "" then "none" else "runtime"));
      Put ("base_adapter_scale", Scale_Image (Base_Scale));
      Put ("adapted_adapter_scale", Scale_Image (Adapted_Scale));
      Put ("options", Options);
      Put ("tasks", Only);
      Put ("repeats", Image (Repeats));
      Put ("seed", Image (Seed));
      Put ("max_seconds", Image (Max_Seconds));
      Put ("context_size", Image (Context_Size));
      Put ("inference", "fixed");
      Put ("knowledge", "off");
      Put ("carry", "off");
      Put ("draft_tokens", "0");
      declare
         Ran : Hostkit.Process.Process_Outcome;
      begin
         Ran := Hostkit.Process.Run_Captured
           ("git", [To_Unbounded_String ("rev-parse"), To_Unbounded_String ("HEAD")],
            Stdout_Path => Directory & "/source-revision.txt", Stderr_Path => Hostkit.Fs.Null_Device);
         Put ("source_revision",
              (if Ran.Started and then Ran.Exit_Status = 0
               then Ada.Strings.Fixed.Trim
                 (To_String (Project_Tools.Text.Read_Text_File (Directory & "/source-revision.txt")),
                  Ada.Strings.Maps.To_Set (" " & ASCII.CR & ASCII.LF),
                  Ada.Strings.Maps.To_Set (" " & ASCII.CR & ASCII.LF))
               else "unavailable"));
      end;
      declare
         Text : constant String := Jsonlib.Serializers.To_String (Manifest);
         Path : constant String := Directory & "/manifest.json";
      begin
         Manifest_Hash := To_Unbounded_String (GNAT.SHA256.Digest (Text));
         if Ada.Directories.Exists (Path) then
            if Ada.Directories.Size (Path) > 65_536 or else Project_Tools.Files.Read_Raw_File (Path) /= Text then
               Say ("manifest differs; use another output directory for a different campaign");
               Hostkit.Locks.Release (Guard);
               return;
            end if;
         else
            Atomic_Write (Path, Text);
         end if;
      end;
      J.Set_Root (Summary, Summary_Root);
      J.Insert (Summary, Summary_Root, "schema_version", J.New_Integer (Summary, 1));
      J.Insert (Summary, Summary_Root, "attempts", Results);
      Save_Summary;
      --  Check-only mode never changes the process's inference environment.
      if not Check_Only then
         declare
            Variables : Hostkit.String_Vectors.Vector;
            procedure Collect (Name, Value : String) is
               pragma Unreferenced (Value);
            begin
               if Name'Length >= 13 and then Name (Name'First .. Name'First + 12) = "MODEL_RUNNER_" then
                  Variables.Append (To_Unbounded_String (Name));
               end if;
            end Collect;
         begin
            Ada.Environment_Variables.Iterate (Collect'Access);
            for Name of Variables loop
               Ada.Environment_Variables.Clear (To_String (Name));
            end loop;
         end;
         Atomic_Write (Directory & "/config", "# fixed campaign configuration" & ASCII.LF);
         Ada.Environment_Variables.Set ("MODEL_RUNNER_CONFIG", Directory & "/config");
         Ada.Environment_Variables.Set ("MODEL_RUNNER_INSTRUCTIONS", "off");
         Ada.Environment_Variables.Set ("MODEL_RUNNER_CONVERSATIONS", Directory & "/conversations");
      end if;
      for Round in 1 .. Repeats loop
         for Task_Index in Names.First_Index .. Names.Last_Index loop
            for Position in 1 .. 4 loop
               One (To_String (Names (Task_Index)), Round,
                    (if (Round + Task_Index) mod 2 = 0 then Position else 5 - Position));
               exit when Blocked;
            end loop;
            exit when Blocked;
         end loop;
         exit when Blocked;
      end loop;
      Save_Summary;
      Say (Image (Complete) & " passed, " & Image (Failures) & " failed, " & Image (Unknown)
           & " ungraded, " & Image (Infrastructure) & " infrastructure errors; "
           & Image (Started_Count) & " new attempts");
      Clean := not Blocked and then Complete = Natural (Names.Length) * Repeats * 4;
      Hostkit.Locks.Release (Guard);
   exception
      when others =>
         Hostkit.Locks.Release (Guard);
         Say ("campaign failed; existing invoking records must be reconciled before retrying");
         Clean := False;
   end Run;

end Agent_Campaign;
