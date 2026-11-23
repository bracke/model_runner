with Ada.Command_Line;
with Ada.Directories;
with Ada.Text_IO;
with Interfaces;
with Jsonlib.Documents;
with Jsonlib.Serializers;
with Model_Runner.Backend;
with Model_Runner.Llama;
with Model_Runner.Platform;
with Speed_Run;

--  Identical instrumentation compiled against before/after engine sources.
--  Usage: no_adapter_probe MODEL PROMPT TOKENS THREADS BATCH CONTEXT
procedure No_Adapter_Probe is
   package J renames Jsonlib.Documents;
   use type Ada.Directories.File_Size;
   use type Interfaces.Unsigned_64;
   Doc : J.Document;
   Root : constant J.Node := J.New_Object (Doc);
   Result : Speed_Run.Report;

   procedure Number (Name : String; Value : Long_Float) is
   begin
      J.Insert (Doc, Root, Name, J.New_Float (Doc, Value));
   end Number;

   procedure Text (Name, Value : String) is
   begin
      J.Insert (Doc, Root, Name, J.New_String (Doc, Value));
   end Text;
begin
   Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   if Ada.Command_Line.Argument_Count /= 6 then
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error,
                           "usage: no_adapter_probe MODEL PROMPT TOKENS THREADS BATCH CONTEXT");
      return;
   end if;
   declare
      Model : constant String := Ada.Command_Line.Argument (1);
      Prompt : constant String := Ada.Command_Line.Argument (2);
      Tokens : constant Positive := Positive'Value (Ada.Command_Line.Argument (3));
      Threads : constant Positive := Positive'Value (Ada.Command_Line.Argument (4));
      Batch : constant Positive := Positive'Value (Ada.Command_Line.Argument (5));
      Context : constant Positive := Positive'Value (Ada.Command_Line.Argument (6));
      Available : constant Interfaces.Unsigned_64 := Model_Runner.Platform.Available_Memory;
   begin
      if Tokens > 256 or else Threads > 64 or else Batch > 256 or else Context not in 16 .. 32_768
        or else not Ada.Directories.Exists (Model) or else not Ada.Directories.Exists (Prompt)
        or else Ada.Directories.Size (Prompt) > 65_536 or else Available = 0
        or else Interfaces.Unsigned_64 (Ada.Directories.Size (Model)) > Available / 2
      then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "no-adapter probe: bounds or memory admission refused");
         return;
      end if;
      Speed_Run.Run
        (Path => Model, Prompt_Path => Prompt, Tokens => Tokens, Threads => Threads, Batch => Batch,
         Repack => Model_Runner.Llama.No_Repack, Cache => Model_Runner.Llama.Exact,
         Backend => Model_Runner.Backend.Backend_CPU, Penalty => 1.0,
         Draft_Tokens => 0, Draft_Tokens_Set => True, Repeats => 1, Context => Context,
         Ignore_End => True, Arithmetic => "f32", No_Cache => True, Result => Result);
      if not Result.Ran or else Result.Runs /= 1 or else Result.Prompt = 0 or else Result.Produced /= Tokens
        or else Result.Evaluate <= 0.0 or else Result.Generate <= 0.0
        or else Result.Drafted /= 0 or else Result.Accepted /= 0 or else Result.Prompt_Reused /= 0
      then
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "no-adapter probe: fixed-work generation failed");
         return;
      end if;
      J.Set_Root (Doc, Root);
      Text ("schema", "model_runner.no_adapter_probe.v1");
      Text ("digest", Result.Digest);
      Text ("backend", "cpu");
      Text ("arithmetic", "f32");
      Text ("repack", "none");
      Text ("cache", "exact");
      Text ("panel_file_cache", "off");
      Number ("seed", 1.0);
      Number ("temperature", 0.0);
      Number ("repeat_penalty", 1.0);
      Number ("draft_tokens", 0.0);
      Number ("adapter_count", 0.0);
      Number ("warmup_passes", 1.0);
      J.Insert (Doc, Root, "ignore_eos", J.New_Boolean (Doc, True));
      Number ("threads", Long_Float (Threads));
      Number ("batch", Long_Float (Batch));
      Number ("context", Long_Float (Context));
      Number ("available_memory_before_bytes", Long_Float (Available));
      Number ("prompt_tokens", Long_Float (Result.Prompt));
      Number ("generated_tokens", Long_Float (Result.Produced));
      Number ("drafted_tokens", Long_Float (Result.Drafted));
      Number ("accepted_draft_tokens", Long_Float (Result.Accepted));
      Number ("prompt_reused_tokens", Long_Float (Result.Prompt_Reused));
      Number ("prompt_seconds", Long_Float (Result.Evaluate));
      Number ("decode_seconds", Long_Float (Result.Generate));
      Number ("wall_seconds", Long_Float (Result.Wall));
      Number ("processor_seconds", Long_Float (Result.Processor));
      Number ("load_seconds", Long_Float (Result.Load));
      Number ("load_before", Result.Load_Before);
      Number ("load_after", Result.Load_After);
      Number ("temperature_before_c", Result.Warm_Before);
      Number ("temperature_after_c", Result.Warm_After);
      J.Insert (Doc, Root, "peak_rss_bytes", J.New_Null (Doc));
      Ada.Text_IO.Put_Line (Jsonlib.Serializers.To_String (Doc));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Success);
   end;
exception
   when others =>
      Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "no-adapter probe: invalid arguments or execution failure");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end No_Adapter_Probe;
