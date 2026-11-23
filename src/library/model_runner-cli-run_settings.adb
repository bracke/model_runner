with Jsonlib.Documents;
with Jsonlib.Serializers;
with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Numerics;
with Model_Runner.Text;
with Ada.Strings.Unbounded;
with Model_Runner.GGUF.Shards;
with Model_Runner.Platform;
with Model_Runner.Errors;
with Model_Runner.Localization;

package body Model_Runner.CLI.Run_Settings is

   function Capture
     (Item : Options.Command; Prepared : Llama.Model'Class; Session : Llama.Session;
      Request : Generation.Request; Thinking : Templates.Thinking_Choice;
      Effort : Templates.Reasoning_Effort; Invocation : String := ""; Task_Id : String := "";
      Project_Revision : String := ""; Parent_Invocation : String := "") return Trajectories.Options
   is
      use Ada.Strings.Unbounded;
      Result : Trajectories.Options := Trajectories.Configured;
      Artifacts : Unbounded_String;
      Model_Path : constant String := Text.To_String (Item.Model_Path);
      Model_Hash : Unbounded_String;
      function Q (Value : String) return String renames Trajectories.Quote;

      procedure Artifact (Role, Path : String; Scale : String := "") is
         Hash : constant String := Platform.Program_Stamp (Path);
      begin
         if Hash'Length /= 64 then
            Result.Invalid := True;
         end if;
         if Role = "model" then
            Model_Hash := To_Unbounded_String (Hash);
         end if;
         Append (Artifacts, (if Length (Artifacts) = 0 then "" else ",")
           & "{""role"":" & Q (Role) & ",""path"":" & Q (Path)
           & ",""sha256"":" & Q (Hash) & ",""scale"":" & Q (Scale) & "}");
      end Artifact;
   begin
      if Length (Result.Directory) = 0 then
         return Result;
      end if;
      Artifact ("model", Model_Path);
      if Model_Runner.GGUF.Shards.Is_Shard_Name (Model_Path) then
         declare
            Count : constant Positive := Positive'Value (Model_Path (Model_Path'Last - 9 .. Model_Path'Last - 5));
         begin
            if Count > Model_Runner.GGUF.Shards.Max_Shards then
               Result.Invalid := True;
            else
               for Part in 2 .. Count loop
                  Artifact ("model_shard", Model_Runner.GGUF.Shards.Shard_Path (Model_Path, Part, Count));
               end loop;
            end if;
         end;
      end if;
      for Part in 1 .. Item.Auxiliary_Count loop
         Artifact ("auxiliary", Text.To_String (Item.Auxiliary_Shards (Part)));
      end loop;
      for Part in 1 .. Item.Adapter_Count loop
         Artifact ("adapter", Text.To_String (Item.Adapters (Part)), Item.Adapter_Scales (Part)'Image);
      end loop;
      Result.Provenance := To_Unbounded_String
        ("{""model_sha256"":" & Q (To_String (Model_Hash))
         & ",""artifacts"" :[" & To_String (Artifacts) & "]"
         & ",""adapter_mode"":" & Q (if Item.Adapter_Runtime then "runtime" else "merge")
         & ",""invocation"":" & Q (Invocation) & ",""task_id"":" & Q (Task_Id)
         & ",""project_revision"":" & Q (Project_Revision)
         & ",""parent_invocation"":" & Q (Parent_Invocation)
         & ",""settings"":" & Describe (Item, Prepared, Session, Request, Thinking, Effort) & "}");
      return Result;
   exception
      when others =>
         Result.Invalid := True;
         return Result;
   end Capture;

   procedure Report_Capture (Screen : in out Presentation.Console; Result : Agent.Outcome) is
   begin
      if Model_Runner.Errors.Is_Error (Result.Capture_Error) then
         Presentation.Put_Note (Screen, "cli.agent.capture_incomplete",
           [Localization.Named ("path", Ada.Strings.Unbounded.To_String (Result.Capture_Path)),
            Localization.Named ("code", Result.Capture_Error.Code'Image)]);
      end if;
   end Report_Capture;

   function Describe
     (Item : Options.Command; Prepared : Llama.Model'Class; Session : Llama.Session;
      Request : Generation.Request; Thinking : Templates.Thinking_Choice;
      Effort : Templates.Reasoning_Effort; Role : String := "session"; Round : Natural := 0;
      Policy : String := ""; Steps : Natural := 0; Tokens : Natural := 0; Seconds : Duration := 0.0)
      return String
   is
      package J renames Jsonlib.Documents;
      Doc : J.Document;
      Root : constant J.Node := J.New_Object (Doc);
      Sampling : constant J.Node := J.New_Object (Doc);
      Target : J.Node := Root;
      Team : constant Backend.CPU.Pool_Reference := Llama.Workers (Session);
      use type Backend.CPU.Pool_Reference;
      procedure Text (Name, Value : String) is
      begin
         J.Insert (Doc, Target, Name, J.New_String (Doc, Value));
      end Text;
      procedure Count (Name : String; Value : Natural) is
      begin
         J.Insert (Doc, Target, Name, J.New_Integer (Doc, Long_Long_Integer (Value)));
      end Count;
      procedure Flag (Name : String; Value : Boolean) is
      begin
         J.Insert (Doc, Target, Name, J.New_Boolean (Doc, Value));
      end Flag;
      procedure Real_Value (Name : String; Value : Model_Runner.Numerics.Real) is
      begin
         J.Insert (Doc, Target, Name, J.New_Float (Doc, Long_Float (Value)));
      end Real_Value;
   begin
      J.Set_Root (Doc, Root);
      Count ("schema_version", 1);
      Text ("role", Role);
      Count ("round", Round);
      Text ("model", Model_Runner.Text.To_String (Item.Model_Path));
      Text ("architecture", Llama.Architecture_Name (Llama.Config (Prepared).Kind));
      Text ("backend", Backend.Backend_Name (Llama.Capability (Prepared).Kind));
      Count ("context_size", Llama.Capacity (Session));
      Count ("threads", (if Team = null then 1 else Natural (Backend.CPU.Worker_Total (Team.all))));
      Text ("cache_keys", Llama.Cache_Name (Llama.Precision (Session)));
      Text ("cache_values", Llama.Cache_Name (Llama.Value_Precision_Of (Session)));
      Text ("arithmetic", Llama.Arithmetic_Name (Item.Arithmetic));
      Text ("repack", Llama.Repack_Name (Item.Repack));
      Count ("batch_size", Natural'Min (Request.Batch_Size, Llama.Batch_Limit (Prepared)));
      Count ("requested_batch_size", Request.Batch_Size);
      Count ("max_tokens", Request.Max_Tokens);
      Flag ("fill_context", Request.Fill_Context);
      Flag ("seed_given", Request.Has_Seed);
      if Request.Has_Seed then
         Text ("seed", Model_Runner.Text.Image (Request.Seed));
      else
         J.Insert (Doc, Root, "seed", J.New_Null (Doc));
      end if;
      Text ("thinking", Templates.Thinking_Choice'Image (Thinking));
      Text ("reasoning_effort", Templates.Reasoning_Effort'Image (Effort));
      Text ("template", Llama.Template_Format (Prepared));
      Text ("policy", Policy);
      Count ("draft_tokens", Request.Draft_Tokens);
      Flag ("draft_from_context", Request.Draft_From_Context);
      Flag ("draft_from_next", Request.Draft_From_Next);
      Flag ("draft_lookup", Request.Draft_Lookup_First);
      Count ("context_shift", Request.Context_Shift);
      Count ("context_keep", Request.Context_Keep);
      Flag ("reuse_committed_prefix", Request.Reuse_Committed_Prefix);
      Flag ("ignore_eos", Request.Ignore_End);
      Count ("runtime_adapters", Llama.Runtime_Adapter_Count (Prepared));
      Count ("max_steps", Steps);
      Count ("max_total_tokens", Tokens);
      Count ("cli_max_parallel", Item.Max_Parallel);
      Count ("cli_delegate_depth", Item.Delegate_Depth);
      J.Insert (Doc, Root, "max_seconds", J.New_Float (Doc, Long_Float (Seconds)));
      Target := Sampling;
      Real_Value ("temperature", Request.Sampling.Temperature);
      Real_Value ("dynatemp_range", Request.Sampling.Dynatemp_Range);
      Real_Value ("dynatemp_exponent", Request.Sampling.Dynatemp_Exponent);
      Real_Value ("top_p", Request.Sampling.Top_P);
      Real_Value ("min_p", Request.Sampling.Min_P);
      Real_Value ("top_a", Request.Sampling.Top_A);
      Real_Value ("repeat_penalty", Request.Sampling.Repeat_Penalty);
      Real_Value ("frequency_penalty", Request.Sampling.Frequency_Penalty);
      Real_Value ("presence_penalty", Request.Sampling.Presence_Penalty);
      Real_Value ("typical_p", Request.Sampling.Typical_P);
      Real_Value ("tail_free", Request.Sampling.Tail_Free);
      Real_Value ("xtc_probability", Request.Sampling.XTC_Probability);
      Real_Value ("xtc_threshold", Request.Sampling.XTC_Threshold);
      Real_Value ("dry_multiplier", Request.Sampling.DRY_Multiplier);
      Real_Value ("dry_base", Request.Sampling.DRY_Base);
      Real_Value ("mirostat_tau", Request.Sampling.Mirostat_Tau);
      Real_Value ("mirostat_eta", Request.Sampling.Mirostat_Eta);
      Count ("top_k", Request.Sampling.Top_K);
      Count ("repeat_window", Request.Sampling.Repeat_Window);
      Count ("dry_allowed_length", Request.Sampling.DRY_Allowed_Length);
      Count ("mirostat", Request.Sampling.Mirostat);
      J.Insert (Doc, Root, "sampling", Sampling);
      return Jsonlib.Serializers.To_String (Doc);
   end Describe;

end Model_Runner.CLI.Run_Settings;
