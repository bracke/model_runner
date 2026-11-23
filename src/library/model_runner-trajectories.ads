private with Ada.Finalization;
private with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Model_Runner.Errors;
with Model_Runner.Tokenizer;

--  Opt-in, bounded local evidence. Each episode is an ordered, SHA-256 chained
--  event stream. It is separate from the excerpt-only project journal. A missing
--  footer, failed write or exceeded limit never qualifies as a complete capture.
--  Nothing is uploaded and export never executes tools. One recorder has one owner.
package Model_Runner.Trajectories is
   subtype Byte_Limit is Positive range 1_024 .. 64 * 1_024 * 1_024;
   subtype Episode_Limit is Positive range 1 .. 1_024;

   type Options is record
      Directory : Ada.Strings.Unbounded.Unbounded_String;
      Max_Bytes : Byte_Limit := 16 * 1_024 * 1_024;
      Max_Episodes : Episode_Limit := 64;
      Provenance : Ada.Strings.Unbounded.Unbounded_String;
      Invalid : Boolean := False;
   end record;

   --  Read MODEL_RUNNER_CAPTURE_DIR and optional CAPTURE_MAX_BYTES / MAX_EPISODES
   --  with the same MODEL_RUNNER_ prefix. Empty directory disables capture.
   --  @return Options; malformed limits are reported by Open, not raised.
   function Configured return Options;

   type Lineage is record
      Parent : Ada.Strings.Unbounded.Unbounded_String;
      Parent_Call : Natural := 0;
      Provenance : Ada.Strings.Unbounded.Unbounded_String;
      Directory : Ada.Strings.Unbounded.Unbounded_String;
      Max_Bytes : Byte_Limit := 16 * 1_024 * 1_024;
      Max_Episodes : Episode_Limit := 64;
   end record;

   --  Task-local context passed around actual tool execution, including workers.
   --  @return Parent episode and call currently executing on this task.
   function Current return Lineage;

   --  @param Context Context to enter or restore on the calling task only.
   procedure Enter (Context : Lineage);

   type Event_Kind is
     (Episode_Start, Context, Generation_Start, Model_Input, Selected_Token,
      Committed_Token, Output_Text, Generation_End, Raw_Reply, Tool_Call, Tool_Result,
      Compaction, Forced_Text, Retry, Ineligible, Episode_End);

   type Recorder is tagged limited private;

   --  Reserve a fresh private episode directory without overwriting old evidence.
   --  Retention refuses new episodes at its limit; it never deletes old ones.
   --  @param Item Recorder, closed first.
   --  @param Settings Explicit opt-in, limits and JSON provenance.
   --  @param Metadata JSON object describing this run and its parent.
   --  @param Status Success, IO_Input_Too_Large, IO_Open_Failed or invalid environment.
   procedure Open
     (Item : in out Recorder; Settings : Options; Metadata : String;
      Status : out Model_Runner.Errors.Error_Info);

   --  Append one complete JSON object, in order. A storage error is latched and
   --  later writes become no-ops; the inference run can continue unchanged.
   --  @param Item Recorder; disabled recorders are no-ops.
   --  @param Kind Event type.
   --  @param Payload Complete JSON object; never shortened.
   procedure Append (Item : in out Recorder; Kind : Event_Kind; Payload : String);

   --  Record the actual input token IDs, after tokenization, with loss mask zero.
   --  @param Item Recorder.
   --  @param Prompt Actual text passed to tokenization.
   --  @param Tokens Actual complete input sequence.
   procedure Input
     (Item : in out Recorder; Prompt : String; Tokens : Model_Runner.Tokenizer.Token_Array);

   --  Record a sampled token before stop suppression; its bytes are hex encoded
   --  because one token need not contain a complete UTF-8 character.
   --  @param Item Recorder.
   --  @param Token Actual selected ID, including terminal tokens.
   --  @param Piece Exact tokenizer bytes.
   --  @param Terminal Whether this token stops generation before commitment.
   procedure Selected
     (Item : in out Recorder; Token : Model_Runner.Tokenizer.Token_Id;
      Piece : String; Terminal : Boolean);

   --  End capture and close its file. Errors leave an incomplete artifact.
   --  @param Item Recorder.
   --  @param Payload JSON object with the actual agent outcome.
   --  @param Status Latched capture error, separate from the agent outcome.
   procedure Finish
     (Item : in out Recorder; Payload : String; Status : out Model_Runner.Errors.Error_Info);

   --  @param Item Recorder.
   --  @return Its event file, empty when capture is disabled or reservation failed.
   function Path (Item : Recorder) return String;

   --  @param Item Recorder.
   --  @return Whether events can still be recorded.
   function Active (Item : Recorder) return Boolean;

   --  @param Text UTF-8 text to quote as one JSON string without truncation.
   --  @return JSON string literal.
   function Quote (Text : String) return String;

   --  @param Bytes Arbitrary bytes, including partial UTF-8 token spellings.
   --  @return Two lower-case hexadecimal characters per byte.
   function Hex_Bytes (Bytes : String) return String;

   --  @param Value Integer to spell without padding.
   --  @return Decimal JSON integer.
   function Number (Value : Long_Long_Integer) return String;

   type Validation is record
      Complete : Boolean := False;
      Exact_Tokens : Boolean := False;
      Events : Natural := 0;
      Generations : Natural := 0;
      Committed_Tokens : Natural := 0;
      Last_Digest : Ada.Strings.Unbounded.Unbounded_String;
      File_Digest : Ada.Strings.Unbounded.Unbounded_String;
      Outcome : Ada.Strings.Unbounded.Unbounded_String;
      Metadata : Ada.Strings.Unbounded.Unbounded_String;
      Children : Ada.Strings.Unbounded.Unbounded_String;
      Child_Episodes : Natural := 0;
      Selected_Tokens : Natural := 0;
      Unanswered_Calls : Natural := 0;
   end record;

   --  Validate bounds, hash chain, event ordering, token IDs and masks, paired
   --  tool results and generation counts. Excerpt-only journals are refused.
   --  @param File_Name One selected episode event file; no directory traversal.
   --  @param Result Capture completeness, counts and ending, never an inferred grade.
   --  @param Status Success or structured read/size failure.
   --  @param Max_Bytes Maximum input size accepted before reading or parsing.
   procedure Validate
     (File_Name : String; Result : out Validation; Status : out Model_Runner.Errors.Error_Info;
      Max_Bytes : Byte_Limit := Byte_Limit'Last);

   --  Validate an embedded stream without reading or replaying referenced files.
   --  The caller must separately bind and validate every child listed in Children.
   --  @param Content Exact JSON-lines bytes, including their final newline.
   --  @param Result Local stream validation and explicit child references.
   --  @param Status Structured invalid-input or size failure.
   --  @param Max_Bytes Largest accepted stream, checked before parsing.
   procedure Validate_Content
     (Content : String; Result : out Validation; Status : out Model_Runner.Errors.Error_Info;
      Max_Bytes : Byte_Limit := Byte_Limit'Last);

private
   type Recorder is new Ada.Finalization.Limited_Controlled with record
      File : Ada.Streams.Stream_IO.File_Type;
      Name : Ada.Strings.Unbounded.Unbounded_String;
      Previous : String (1 .. 64) := [others => '0'];
      Sequence : Natural := 0;
      Written : Natural := 0;
      Limit : Byte_Limit := Byte_Limit'First;
      Error : Model_Runner.Errors.Error_Info;
      Registration : Natural := 0;
   end record;

   overriding procedure Finalize (Item : in out Recorder);
end Model_Runner.Trajectories;
