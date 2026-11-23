with Jsonlib.Documents;
with Jsonlib.Serializers;
with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Numerics;
with Model_Runner.Text;

package body Model_Runner.CLI.Run_Settings is

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
