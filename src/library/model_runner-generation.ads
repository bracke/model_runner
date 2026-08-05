with Interfaces;

with Model_Runner.Bytes;
with Model_Runner.Cancellation;
with Model_Runner.Clocks;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Llama;
with Model_Runner.Output;
with Model_Runner.Progress;
with Model_Runner.Sampling;
with Model_Runner.Stops;

--  Generation coordination.
--
--  This package runs the loop that turns a rendered prompt into streamed text:
--  tokenize, validate the context budget, prefill, then repeatedly sample,
--  check stop conditions, evaluate, decode and emit.
--
--  Output discipline. Nothing here writes to standard output or standard
--  error. Generated text goes to an Output.Sink and progress goes to a
--  Progress.Observer; the caller decides what either of those does. Text
--  written to the sink is passed through exactly as the tokenizer decoded it:
--  no styling, no localization, no trimming, no wrapping, nothing appended.
--
--  Immutability. A Request is a value. It is read at the start of Generate and
--  never consulted again in a way that would let a change mid-run alter
--  behaviour.
--
--  Task safety: Generate runs on the calling task and takes exclusive use of
--  the session for its duration.
package Model_Runner.Generation is

   subtype Token_Id is Model_Runner.Llama.Token_Id;
   subtype Seed_Value is Model_Runner.Entropy.Seed_Value;

   --  Why generation stopped. Every run ends with exactly one of these.
   type Completion_Reason is
     (End_Of_Sequence,
      Stop_Token,
      Stop_String,
      Maximum_Tokens,
      Context_Full,
      Cancelled,
      Output_Closed,
      Runtime_Error);

   --  What to generate and how.
   type Request is record
      --  Largest number of tokens to produce. Must be greater than zero.
      Max_Tokens : Natural := 256;

      --  Validated sampling configuration.
      Sampling : Model_Runner.Sampling.Configuration;

      --  Explicit seed. When Has_Seed is False the seed comes from the entropy
      --  source, and the value actually used is reported in the result.
      Seed     : Seed_Value := 0;
      Has_Seed : Boolean := False;

      --  Prepend the tokenizer's beginning-of-sequence token to the prompt.
      Add_Beginning : Boolean := True;

      --  Keep a copy of the generated text in the result. Bounded by
      --  Max_Retained_Bytes; text beyond that is streamed but not retained.
      Retain_Text : Boolean := False;

      --  Number of prompt tokens evaluated between cancellation checks and
      --  progress reports during prefill.
      --  Prompt tokens evaluated in one pass over the weights. Larger
      --  batches make prefill faster and hold more activations at once; the
      --  engine caps it at Llama.Max_Batch whatever is asked for. It also
      --  sets how often cancellation is observed and progress reported.
      Batch_Size : Natural := 32;

      --  Reuse the session's committed context when the tokenized prompt is
      --  an exact prefix extension of it, and re-evaluate only the new
      --  suffix. When the sequences diverge the session is reset and the whole
      --  prompt is re-evaluated, so the cache never describes a conversation
      --  that differs from the one being rendered.
      Reuse_Committed_Prefix : Boolean := False;
   end record;

   --  What a run produced.
   --
   --  Release the result with Release when Retain_Text was requested.
   type Result is record
      Reason           : Completion_Reason := Runtime_Error;
      Prompt_Tokens    : Natural := 0;
      Generated_Tokens : Natural := 0;
      Final_Position   : Natural := 0;
      Seed             : Seed_Value := 0;
      Prefill_Ns       : Model_Runner.Clocks.Nanoseconds := 0;
      Decode_Ns        : Model_Runner.Clocks.Nanoseconds := 0;
      Prefill_Rate     : Long_Float := 0.0;
      Decode_Rate      : Long_Float := 0.0;
      Peak_Bytes       : Interfaces.Unsigned_64 := 0;
      Text             : Model_Runner.Bytes.Byte_Array_Access := null;
      Text_Length      : Natural := 0;
      Error            : Model_Runner.Errors.Error_Info;
   end record;

   --  Release the retained text of a result. Idempotent.
   --
   --  @param Item Result to release.
   procedure Release (Item : in out Result);

   --  Retained generated text.
   --
   --  @param Item Result to read.
   --  @return Retained text, or an empty string when retention was not
   --    requested.
   function Generated_Text (Item : Result) return String;

   --  Report whether a completion reason describes an ordinary end.
   --
   --  Cancellation and output closure are ordinary: the caller asked for them,
   --  or the destination went away. A runtime error is not.
   --
   --  @param Item Reason to classify.
   --  @return True when the run ended without a failure.
   function Is_Normal (Item : Completion_Reason) return Boolean
   is (Item /= Runtime_Error);

   --  Stable machine-readable name of a completion reason, such as
   --  "stop_string". Never localized; the presentation layer looks up a
   --  message by this name.
   --
   --  @param Item Reason to name.
   --  @return Lower-case identifier.
   function Reason_Name (Item : Completion_Reason) return String;

   --  Check a request without running it.
   --
   --  @param Item Request to check.
   --  @param Status Success, Generation_Invalid_Request or a sampling
   --    diagnostic.
   procedure Validate
     (Item   : Request;
      Status : out Model_Runner.Errors.Error_Info);

   --  Run one generation request to completion.
   --
   --  The prompt is text that has already been rendered: raw mode passes the
   --  user's text unchanged, and conversation mode passes the template's
   --  output. Tokenization happens here so that the token count that the
   --  context check uses is exactly the one that is evaluated.
   --
   --  @param Source Prepared model.
   --  @param Session Open session on that model; advanced by this call.
   --  @param Prompt Rendered prompt, UTF-8.
   --  @param Item Request to run.
   --  @param Stop_Set Stop tokens and stop strings.
   --  @param Sink Destination for generated text, or null to discard it.
   --  @param Observer Progress observer, or null.
   --  @param Time Monotonic clock used for the reported durations, or null.
   --  @param Seeds Entropy source used when the request has no explicit seed.
   --  @param Cancel Cancellation token, or null.
   --  @param Bounds Session limits applied to retention and batching.
   --  @param Outcome Completion reason, counts, timings and any diagnostic.
   procedure Generate
     (Source   : Model_Runner.Llama.Model'Class;
      Session  : in out Model_Runner.Llama.Session;
      Prompt   : String;
      Item     : Request;
      Stop_Set : Model_Runner.Stops.Set;
      Sink     : Model_Runner.Output.Sink_Reference;
      Observer : Model_Runner.Progress.Observer_Reference;
      Time     : Model_Runner.Clocks.Clock_Reference;
      Seeds    : Model_Runner.Entropy.Source_Reference;
      Cancel   : Model_Runner.Cancellation.Token_Reference;
      Bounds   : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Outcome  : out Result);

end Model_Runner.Generation;
