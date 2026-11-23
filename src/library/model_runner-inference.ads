with Ada.Finalization;
with Ada.Real_Time;
with Ada.Strings.Unbounded;
with Interfaces;

with Model_Runner.Backend;
with Model_Runner.Backend.CPU;
with Model_Runner.Cancellation;
with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.GGUF.Containers;
with Model_Runner.GGUF.Shards;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Numerics;
with Model_Runner.Progress;
with Model_Runner.Sampling;
with Model_Runner.Text;

private with Model_Runner.Grammar.Rooms;
private with Model_Runner.Backend.Device;

--  Bounded, schema-constrained inference over one local GGUF model.
--
--  This package is the reusable embedded boundary for the inference engine.
--  It owns model and session resources, performs no CLI presentation, opens
--  no network connection, and reports expected failures as typed outcomes.
package Model_Runner.Inference is

   Max_Auxiliary_Shards : constant := 8;
   --  Most separately distributed PLE/engram sets contain one file.  The
   --  fixed upper bound keeps an Open request allocation-free.

   type Auxiliary_List is
     array (Positive range 1 .. Max_Auxiliary_Shards) of
       Model_Runner.Text.Bounded;

   Max_Runtime_Adapters : constant := 8;

   type Adapter_Option is record
      Path  : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Scale : Model_Runner.Numerics.Real := 1.0;
   end record;
   --  One CPU runtime attachment, loaded in list order without merging base weights.
   --  @field Path Exact local adapter GGUF path.
   --  @field Scale Finite multiplier, including zero and negative values.

   type Adapter_List is array (Positive range 1 .. Max_Runtime_Adapters) of Adapter_Option;

   subtype UString is Ada.Strings.Unbounded.Unbounded_String;
   --  Owned completion text.

   type Open_Options is record
      Backend        : Model_Runner.Backend.Backend_Kind :=
        Model_Runner.Backend.Backend_CPU;
      Repack         : Model_Runner.Llama.Repack_Mode :=
        Model_Runner.Llama.No_Repack;
      Context_Tokens : Natural := 0;
      Load_Threads   : Positive := 1;
      Workers        : Model_Runner.Backend.CPU.Worker_Count := 1;
      Cache          : Model_Runner.Llama.Cache_Precision :=
        Model_Runner.Llama.Exact;
      Values         : Model_Runner.Llama.Value_Precision :=
        Model_Runner.Llama.Same_As_Keys;
      Paged          : Boolean := False;
      Auxiliary      : Auxiliary_List :=
        [others => Model_Runner.Text.Empty];
      Auxiliary_Count : Natural range 0 .. Max_Auxiliary_Shards := 0;
      Runtime_Adapters : Adapter_List := [others => (others => <>)];
      Runtime_Adapter_Count : Natural range 0 .. Max_Runtime_Adapters := 0;
      Adapter_Bounds : Model_Runner.Llama.Adapter_Limits := Model_Runner.Llama.Default_Adapter_Limits;
      Panel_Cache    : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Fit_Required   : Boolean := True;
      Device_Memory  : Interfaces.Unsigned_64 := 0;
      Device_Share_Host : Boolean := False;
      Device_Index   : Positive := 1;
      Device_Patience : Duration := 60.0;
      Device_Tuning  : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Cancel         : Model_Runner.Cancellation.Token_Reference := null;
      Observer       : Model_Runner.Progress.Observer_Reference := null;
      Model_Bounds   : Model_Runner.Limits.Model_Limits :=
        Model_Runner.Limits.Default_Model_Limits;
      Session_Bounds : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
   end record;
   --  Model preparation and session limits.
   --  @field Backend Execution backend.
   --  @field Repack Optional weight representation prepared at load time.
   --  @field Context_Tokens Session capacity; zero uses the model default.
   --  @field Load_Threads Tasks available while repacking weights.
   --  @field Workers Reusable CPU workers available during inference.
   --  @field Cache Key-cache precision.
   --  @field Values Value-cache precision.
   --  @field Paged Whether a device session uses the shared paged cache.
   --  @field Auxiliary Exact auxiliary GGUF paths, including PLE/engram files.
   --  @field Auxiliary_Count Number of leading Auxiliary entries to use.
   --  @field Runtime_Adapters CPU runtime attachments and positional scales, in application order.
   --  @field Runtime_Adapter_Count Number of leading Runtime_Adapters entries to load; zero disables attachment.
   --  @field Adapter_Bounds Tightenable limits on total adapter files, pairs, rank and owned matrix/descriptor bytes.
   --  @field Panel_Cache Reusable repacked-panel file, or empty for none.
   --  @field Fit_Required Whether device preparation must keep all weights.
   --  @field Device_Memory Device matrix budget, or zero for the default.
   --  @field Device_Share_Host Read weights from host memory on the device.
   --  @field Device_Index One-based device selected for a device backend.
   --  @field Device_Patience Maximum duration to wait for the device.
   --  @field Device_Tuning Empty loads an exact cached profile, "none"
   --    disables tuning, and another value requires that exact profile path.
   --  @field Cancel Cooperative cancellation for loading and preparation.
   --  @field Observer Semantic model-loading progress receiver, or null.
   --  @field Model_Bounds Limits applied while reading and preparing GGUF.
   --  @field Session_Bounds Limits applied while opening and generating.

   type Completion_Options is record
      Maximum_Tokens       : Natural := 4_096;
      Maximum_Output_Bytes : Positive := 131_072;
      Fill_Context         : Boolean := False;
      Deadline             : Ada.Real_Time.Time := Ada.Real_Time.Time_Last;
      Sampling             : Model_Runner.Sampling.Configuration :=
        Model_Runner.Sampling.Greedy_Configuration;
      Add_Beginning        : Boolean := True;
      Cancel               : Model_Runner.Cancellation.Token_Reference := null;
      Observer             : Model_Runner.Progress.Observer_Reference := null;
   end record;
   --  Bounded controls for one completion.
   --  @field Maximum_Tokens Largest number of generated tokens.
   --  @field Maximum_Output_Bytes Largest generated byte string returned.
   --  @field Fill_Context Whether generation may use all context remaining after the prompt.
   --  @field Deadline Absolute cooperative deadline, or Time_Last.
   --  @field Sampling Validated token-sampling policy.
   --  @field Add_Beginning Whether to prepend the tokenizer's beginning token.
   --  @field Cancel Cooperative cancellation for this completion.
   --  @field Observer Semantic generation progress receiver, or null.

   type Completion_State is
     (Completion_Ready, Completion_Incomplete, Completion_Cancelled,
      Completion_Timed_Out, Completion_Output_Limit, Completion_Failed);
   --  Disposition of one completion.
   --  @enum Completion_Ready Generation reached an ordinary engine stop.
   --  @enum Completion_Incomplete A token or context bound stopped the JSON value.
   --  @enum Completion_Cancelled The caller requested cooperative cancellation.
   --  @enum Completion_Timed_Out The cooperative deadline expired.
   --  @enum Completion_Output_Limit The bounded sink refused another fragment.
   --  @enum Completion_Failed Schema compilation or generation failed.

   type Completion is record
      State  : Completion_State := Completion_Failed;
      Reason : Model_Runner.Generation.Completion_Reason :=
        Model_Runner.Generation.Runtime_Error;
      Text   : UString;
      Error  : Model_Runner.Errors.Error_Info := Model_Runner.Errors.Success;
   end record;
   --  Generated text and its typed disposition.
   --  @field State High-level completion disposition.
   --  @field Reason Exact generation stop reason.
   --  @field Text Bounded bytes emitted before the stop.
   --  @field Error Typed diagnostic for Completion_Failed.

   type Session is limited new Ada.Finalization.Limited_Controlled with private;
   --  One owned model and reusable generation session.

   type Prepared_Schema is limited private;
   --  One compiled JSON Schema reusable across sequential completions.

   --  Compile a JSON Schema once for subsequent Complete calls.
   --  @param Item Prepared schema to replace.
   --  @param Text JSON Schema in the supported exact subset.
   --  @param Status Success or a typed schema/grammar diagnostic.
   procedure Prepare
     (Item   : in out Prepared_Schema;
      Text   : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Release a prepared schema. Idempotent.
   --  @param Item Prepared schema to close.
   procedure Close (Item : in out Prepared_Schema);

   --  Return whether a schema compiled successfully.
   --  @param Item Prepared schema to inspect.
   --  @return True only after a successful Prepare.
   function Is_Ready (Item : Prepared_Schema) return Boolean;

   --  Load a local GGUF model and open a reusable inference session.
   --  @param Item Session to replace; its existing resources are closed.
   --  @param Path Local model path or first shard path.
   --  @param Options Preparation and session controls.
   --  @param Status Success or the typed loading/session failure.
   procedure Open
     (Item    : in out Session;
      Path    : String;
      Options : Open_Options := (others => <>);
      Status  : out Model_Runner.Errors.Error_Info);

   --  Reset the session and produce one schema-constrained completion.
   --  @param Item Open session used exclusively for this call.
   --  @param Prompt Complete rendered prompt supplied to the tokenizer.
   --  @param Answer_Schema JSON Schema converted to a generation grammar.
   --  @param Options Deadline and output bounds.
   --  @param Outcome Generated bytes and typed disposition.
   procedure Complete
     (Item          : in out Session;
      Prompt        : String;
      Answer_Schema : String;
      Options       : Completion_Options;
      Outcome       : out Completion);

   --  Reset the session and complete against an already compiled schema.
   --  @param Item Open session used exclusively for this call.
   --  @param Prompt Complete rendered prompt supplied to the tokenizer.
   --  @param Schema Prepared schema that outlives this call.
   --  @param Options Deadline and output bounds.
   --  @param Outcome Generated bytes and typed disposition.
   procedure Complete
     (Item    : in out Session;
      Prompt  : String;
      Schema  : Prepared_Schema;
      Options : Completion_Options;
      Outcome : out Completion);

   --  Release every owned resource. Idempotent.
   --  @param Item Session to close.
   procedure Close (Item : in out Session);

   --  Release every owned resource and report the first cleanup failure.
   --  Cleanup continues after a failure so one faulty component does not
   --  strand unrelated resources.  The status-bearing form is preferred at
   --  operational boundaries; the parameterless form raises Program_Error
   --  when this form reports an error.
   --  @param Item Session to close.
   --  @param Status Success or the first cleanup failure.
   procedure Close
     (Item   : in out Session;
      Status : out Model_Runner.Errors.Error_Info);

   --  Return whether a model and generation session are ready.
   --  @param Item Session to inspect.
   --  @return True after successful Open and before Close.
   function Is_Open (Item : Session) return Boolean;

   --  Return the path supplied to Open, or an empty string when closed.
   --  @param Item Session to inspect.
   --  @return Original local path, or an empty string.
   function Model_Path (Item : Session) return String;

   type Model_Provenance is record
      Canonical_Path : UString;
      Name           : UString;
      Architecture   : UString;
      Fingerprint    : Interfaces.Unsigned_64 := 0;
      Bytes          : Interfaces.Unsigned_64 := 0;
      Parts          : Natural := 0;
      Runtime_Adapter_Count : Natural := 0;
      Runtime_Adapter_Bytes : Interfaces.Unsigned_64 := 0;
   end record;
   --  Stable identity material for the open model.
   --  @field Canonical_Path Absolute path of the named backbone shard.
   --  @field Name Model title from general.name, or empty.
   --  @field Architecture Stable architecture identifier.
   --  @field Fingerprint Engine cache-compatibility fingerprint.
   --  @field Bytes Total bytes across backbone and auxiliary shards.
   --  @field Parts Number of opened files.
   --  @field Runtime_Adapter_Count Number of owned runtime attachments, separate from backbone/auxiliary parts.
   --  @field Runtime_Adapter_Bytes Owned decoded adapter matrices and descriptors, excluding session scratch.

   --  Return provenance for an open session, or an empty record when closed.
   --  @param Item Session to inspect.
   --  @return Model identity and size metadata.
   function Provenance (Item : Session) return Model_Provenance;

   subtype SHA256_Hex is String (1 .. 64);
   --  Lower-case SHA-256 hexadecimal text.

   --  Hash the exact joined model bytes explicitly.
   --  This reads the complete model and can therefore be expensive; Open does
   --  not perform it implicitly.
   --  @param Item Open session whose model bytes are hashed.
   --  @param Digest Receives the lower-case SHA-256 digest, or all zeroes on failure.
   --  @param Status Success or a typed lifecycle/read diagnostic.
   --  @param Cancel Optional cooperative cancellation token.
   --  @param Observer Optional byte-progress observer for the Hashing_Model stage.
   procedure SHA256
     (Item   : in out Session;
      Digest : out SHA256_Hex;
      Status : out Model_Runner.Errors.Error_Info;
      Cancel : Model_Runner.Cancellation.Token_Reference := null;
      Observer : Model_Runner.Progress.Observer_Reference := null);

private
   type Pool_Access is access Model_Runner.Backend.CPU.Pool;

   type Prepared_Schema is limited record
      Rules : Model_Runner.Grammar.Rooms.Holder;
      Ready : Boolean := False;
   end record;

   type Session is limited new Ada.Finalization.Limited_Controlled with record
      Source         : Model_Runner.GGUF.Shards.Shard_Set;
      Container      : Model_Runner.GGUF.Containers.Container;
      Engine         : Model_Runner.Llama.Model;
      Context        : Model_Runner.Llama.Session;
      Pool           : Pool_Access := null;
      Bounds         : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Path           : UString;
      Canonical_Path : UString;
      Opened         : Boolean := False;
      Device_Owned   : Boolean := False;
      Device_Lease   : Model_Runner.Backend.Device.Exclusive_Lease;
   end record;

   overriding procedure Finalize (Item : in out Session);
end Model_Runner.Inference;
