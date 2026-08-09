with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Text;
with Model_Runner.Tokenizer;

package body Model_Runner.Generation is

   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Errors.Error_Code;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Tensors.Real_Array_Access;
   use type Model_Runner.Tokenizer.Token_Id;

   package B renames Model_Runner.Bytes;
   package C renames Model_Runner.Cancellation;
   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package P renames Model_Runner.Progress;
   package S renames Model_Runner.Sampling;
   package T renames Model_Runner.Tensors;
   package Vocab renames Model_Runner.Tokenizer;

   --  Room kept in the pending buffer beyond the longest stop string. One
   --  decoded token cannot contribute more bytes than this, so a fragment
   --  always fits after the held-back prefix.
   Fragment_Reserve : constant := 1024;

   type Token_Buffer is access Vocab.Token_Array;
   procedure Free_Tokens is
     new Ada.Unchecked_Deallocation (Vocab.Token_Array, Token_Buffer);

   -------------
   -- Release --
   -------------

   procedure Release (Item : in out Result) is
   begin
      B.Free (Item.Text);
      Item.Text_Length := 0;
   end Release;

   ---------------------
   -- Generated_Text --
   ---------------------

   function Generated_Text (Item : Result) return String is
   begin
      if Item.Text = null or else Item.Text_Length = 0 then
         return "";
      else
         return B.To_String
           (Item.Text.all (Item.Text.all'First
                           .. Item.Text.all'First
                              + B.Byte_Count (Item.Text_Length) - 1));
      end if;
   end Generated_Text;

   -----------------
   -- Reason_Name --
   -----------------

   function Reason_Name (Item : Completion_Reason) return String
   is (Model_Runner.Text.To_Lower (Completion_Reason'Image (Item)));

   --------------
   -- Validate --
   --------------

   procedure Validate
     (Item   : Request;
      Status : out E.Error_Info) is
   begin
      if Item.Max_Tokens = 0 then
         Status := E.Make (E.Generation_Invalid_Request);
         E.Add_Text (Status, "field", "max_tokens", E.Param_Identifier);
         return;
      end if;

      if Item.Batch_Size = 0 then
         Status := E.Make (E.Generation_Invalid_Request);
         E.Add_Text (Status, "field", "batch_size", E.Param_Identifier);
         return;
      end if;

      S.Validate (Item.Sampling, Status);
   end Validate;

   --------------
   -- Generate --
   --------------

   procedure Generate
     (Source   : L.Model'Class;
      Session  : in out L.Session;
      Prompt   : String;
      Item     : Request;
      Stop_Set : Model_Runner.Stops.Set;
      Sink     : Model_Runner.Output.Sink_Reference;
      Observer : P.Observer_Reference;
      Time     : Model_Runner.Clocks.Clock_Reference;
      Seeds    : Model_Runner.Entropy.Source_Reference;
      Cancel   : C.Token_Reference;
      Bounds   : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Outcome  : out Result)
   is
      Settings : constant L.Configuration := L.Config (Source);
      Words    : constant access constant Vocab.Vocabulary :=
        L.Vocabulary (Source);
      Longest  : constant Natural :=
        Model_Runner.Stops.Longest_String (Stop_Set);

      Sampler : S.Sampler;
      Decoder : Vocab.Decoder;
      Logits  : T.Real_Array_Access := null;
      Tokens  : Token_Buffer := null;

      --  Bytes decoded but not yet released, because a stop string might still
      --  complete inside them.
      Pending      : B.Byte_Array_Access := null;
      Pending_Used : Natural := 0;

      Prompt_Count : Natural := 0;
      First_Token  : Positive := 1;
      Status       : E.Error_Info := E.Success;
      Closed       : Boolean := False;
      Started      : Model_Runner.Clocks.Nanoseconds := 0;
      Finished     : Boolean := False;

      --  Release everything this call owns. Called exactly once, from the
      --  single exit path.
      procedure Cleanup is
      begin
         T.Free (Logits);
         B.Free (Pending);
         if Tokens /= null then
            Free_Tokens (Tokens);
         end if;
         S.Close (Sampler);
      end Cleanup;

      --  Record the outcome of the run. The first call wins, so a stop
      --  condition detected while unwinding cannot overwrite the real reason.
      procedure Conclude
        (Reason    : Completion_Reason;
         Condition : E.Error_Info := E.Success) is
      begin
         if not Finished then
            Finished := True;
            Outcome.Reason := Reason;
            Outcome.Error := Condition;

            --  And the session goes back to being ready. It is ready:
            --  what became of the request is in the result, and the next
            --  request may be asked of the same session. A failure is
            --  Llama's to record, because after one nothing further can be
            --  asked at all.
            if Reason /= Runtime_Error then
               L.Enter (Session, L.Ready);
            end if;
         end if;
      end Conclude;

      --  Append text to the retained buffer, stopping at the configured cap.
      --  Text beyond the cap is still streamed; only retention is bounded.
      procedure Retain (Fragment : String) is
      begin
         if Outcome.Text = null or else Fragment'Length = 0 then
            return;
         end if;

         declare
            Room : constant Natural :=
              Natural (Outcome.Text.all'Length) - Outcome.Text_Length;
            Take : constant Natural := Natural'Min (Room, Fragment'Length);
         begin
            if Take > 0 then
               Outcome.Text.all
                 (B.Byte_Count (Outcome.Text_Length) + 1
                  .. B.Byte_Count (Outcome.Text_Length + Take)) :=
                 B.To_Bytes
                   (Fragment (Fragment'First .. Fragment'First + Take - 1));
               Outcome.Text_Length := Outcome.Text_Length + Take;
            end if;
         end;
      end Retain;

      --  Write a fragment to the sink. Generated text is passed through
      --  unchanged: nothing is styled, localized, trimmed or wrapped.
      procedure Emit (Fragment : String) is
      begin
         if Fragment'Length = 0 or else Closed then
            return;
         end if;
         Retain (Fragment);
         Model_Runner.Output.Emit (Sink, Fragment, Closed);
      end Emit;

      --  Current pending text.
      function Pending_Text return String is
      begin
         if Pending_Used = 0 then
            return "";
         else
            return B.To_String (Pending.all (1 .. B.Byte_Count (Pending_Used)));
         end if;
      end Pending_Text;

      --  Drop the first Count bytes of the pending buffer.
      procedure Consume (Count : Natural) is
         Remaining : constant Natural := Pending_Used - Count;
      begin
         if Remaining > 0 then
            Pending.all (1 .. B.Byte_Count (Remaining)) :=
              Pending.all
                (B.Byte_Count (Count) + 1 .. B.Byte_Count (Pending_Used));
         end if;
         Pending_Used := Remaining;
      end Consume;

   begin
      Outcome := (others => <>);

      Validate (Item, Status);
      if E.Is_Error (Status) then
         Conclude (Runtime_Error, Status);
         Cleanup;
         return;
      end if;

      if not L.Is_Ready (Source) then
         Conclude (Runtime_Error, E.Make (E.Lifecycle_Model_Not_Ready));
         Cleanup;
         return;
      end if;

      if L.State (Session) in L.Closed | L.Failed then
         Conclude (Runtime_Error, E.Make (E.Lifecycle_Invalid_State));
         Cleanup;
         return;
      end if;

      --  Seed selection. An explicit seed wins; otherwise the entropy source
      --  chooses one and the choice is reported so the run can be repeated.
      if Item.Has_Seed then
         Outcome.Seed := Item.Seed;
      else
         Model_Runner.Entropy.Draw (Seeds, Outcome.Seed);
      end if;

      S.Open (Sampler, Item.Sampling, Settings.Vocabulary, Outcome.Seed, Status);
      if E.Is_Error (Status) then
         Conclude (Runtime_Error, Status);
         Cleanup;
         return;
      end if;

      --  A beginning-of-sequence marker belongs to the prompt, never to the
      --  generated text.
      if Vocab.Beginning_Token (Words.all) /= Vocab.No_Token then
         S.Forbid (Sampler, Vocab.Beginning_Token (Words.all));
      end if;

      T.Allocate (N.Element_Count (Settings.Vocabulary), Logits);
      B.Allocate (B.Byte_Count (Longest + Fragment_Reserve) * 2, Pending);
      --  Sized for the worst case the tokenizer can produce -- byte fallback
      --  emits at most one token per byte, plus the beginning marker -- so
      --  that an over-long prompt is reported as such rather than as a buffer
      --  that was too small to find out.
      Tokens :=
        new Vocab.Token_Array
          (1 .. Natural'Max (L.Capacity (Session), Prompt'Length + 2));

      if Logits = null or else Pending = null then
         Conclude (Runtime_Error, E.Make (E.Memory_Allocation_Failed));
         Cleanup;
         return;
      end if;

      if Item.Retain_Text then
         B.Allocate
           (B.Byte_Count (Natural'Max (Bounds.Max_Retained_Bytes, 1)),
            Outcome.Text);
         if Outcome.Text = null then
            Conclude (Runtime_Error, E.Make (E.Memory_Allocation_Failed));
            Cleanup;
            return;
         end if;
      end if;

      --  Tokenize. The count used for the context check below is exactly the
      --  sequence that will be evaluated.
      --  A request asks for a beginning marker; the vocabulary decides
      --  whether it wants one. Some models declare that they do not, and
      --  putting one in front anyway feeds a sequence no other
      --  implementation would: measured on such a model, a logit moved by
      --  nearly two, where two honest implementations of the same
      --  arithmetic differ by hundredths.
      Vocab.Encode
        (Words.all, Prompt,
         Item.Add_Beginning and then Vocab.Adds_Beginning (Words.all),
         False, Tokens.all, Prompt_Count, Status);
      if E.Is_Error (Status) then
         Conclude (Runtime_Error, Status);
         Cleanup;
         return;
      end if;

      Outcome.Prompt_Tokens := Prompt_Count;
      P.Publish
        (Observer,
         P.Generation_Progress
           (P.Prompt_Tokenized, Interfaces.Unsigned_64 (Prompt_Count)));

      if Prompt_Count = 0 then
         Conclude (Runtime_Error, E.Make (E.Generation_Empty_Prompt));
         Cleanup;
         return;
      end if;

      --  Decide how much of the committed context can be kept. Reuse happens
      --  only when the committed tokens are an exact prefix of the sequence
      --  about to be evaluated; anything else resets the session, so the cache
      --  never describes a different conversation from the rendered one.
      declare
         Committed : constant Natural := L.Position (Session);
         Matches   : Boolean := Item.Reuse_Committed_Prefix
           and then Committed > 0
           and then Committed <= Prompt_Count;
      begin
         if Matches then
            for Index in 1 .. Committed loop
               if L.Committed_Token (Session, Index - 1) /= Tokens.all (Index)
               then
                  Matches := False;
                  exit;
               end if;
            end loop;
         end if;

         if Matches then
            First_Token := Committed + 1;
         else
            if Committed > 0 then
               L.Reset (Session);
            end if;
            First_Token := 1;
         end if;
      end;

      --  Context budget, checked before any evaluation so that an impossible
      --  request costs nothing.
      declare
         Available : constant Natural :=
           L.Capacity (Session) - L.Position (Session);
         Remaining : constant Natural := Prompt_Count - First_Token + 1;
      begin
         if Remaining > Available then
            Status := E.Make (E.Generation_Prompt_Too_Long);
            E.Add_Integer
              (Status, "prompt", Long_Long_Integer (Remaining),
               E.Param_Tokens);
            E.Add_Integer
              (Status, "available", Long_Long_Integer (Available),
               E.Param_Tokens);
            Conclude (Runtime_Error, Status);
            Cleanup;
            return;
         end if;

         if Remaining + Item.Max_Tokens > Available then
            Status := E.Make (E.Generation_Context_Exhausted);
            E.Add_Integer
              (Status, "prompt", Long_Long_Integer (Remaining),
               E.Param_Tokens);
            E.Add_Integer
              (Status, "requested", Long_Long_Integer (Item.Max_Tokens),
               E.Param_Tokens);
            E.Add_Integer
              (Status, "available", Long_Long_Integer (Available),
               E.Param_Tokens);
            Conclude (Runtime_Error, Status);
            Cleanup;
            return;
         end if;
      end;

      --  The generated tokens continue the prompt rather than beginning a
      --  sequence, so the first one keeps its leading space. Treating it as a
      --  dummy prefix would silently delete the space between the prompt and
      --  the continuation.
      Vocab.Reset (Decoder, Continuing => Prompt /= "");

      --  Prefill. The prompt is consumed in batches: every token in a batch
      --  shares one pass over the weights, and reading and decoding those
      --  weights is what a forward pass spends its time on. Batch_Size also
      --  sets how often cancellation is observed and progress reported.
      P.Publish
        (Observer,
         P.Generation_Progress
           (P.Prefill_Started, 0, Interfaces.Unsigned_64 (Prompt_Count)));
      L.Enter (Session, L.Evaluating_Prompt);
      Started := Model_Runner.Clocks.Read (Time);

      --  Tokens already in the cache still shape the repetition penalty, so
      --  they are recorded without being evaluated again.
      for Index in 1 .. First_Token - 1 loop
         S.Record_Token (Sampler, Tokens.all (Index));
      end loop;

      declare
         --  A batch is bounded by what the engine will evaluate at once as
         --  well as by the requested size, so a large --batch-size cannot
         --  turn into an unbounded working set.
         Span : constant Natural :=
           Natural'Max (1, Natural'Min (Item.Batch_Size, L.Max_Batch));
         Index : Natural := First_Token;
      begin
         Prefill_Loop :
         while Index <= Prompt_Count loop
            if C.Is_Cancelled (Cancel) then
               Conclude (Cancelled);
               exit Prefill_Loop;
            end if;

            declare
               Last : constant Natural :=
                 Natural'Min (Index + Span - 1, Prompt_Count);
            begin
               L.Evaluate_Batch
                 (Session, Source, Tokens.all (Index .. Last), Logits.all,
                  Cancel, Status);

               if E.Is_Error (Status) then
                  if Status.Code = E.Generation_Cancelled then
                     Conclude (Cancelled);
                  else
                     Conclude (Runtime_Error, Status);
                  end if;
                  exit Prefill_Loop;
               end if;

               for Step in Index .. Last loop
                  S.Record_Token (Sampler, Tokens.all (Step));
               end loop;

               Index := Last + 1;
            end;

            P.Publish
              (Observer,
               P.Generation_Progress
                 (P.Prefill_Progress, Interfaces.Unsigned_64 (Index - 1),
                  Interfaces.Unsigned_64 (Prompt_Count)));
         end loop Prefill_Loop;
      end;

      Outcome.Prefill_Ns :=
        Model_Runner.Clocks.Elapsed (Started, Model_Runner.Clocks.Read (Time));
      Outcome.Prefill_Rate :=
        Model_Runner.Clocks.Rate_Per_Second
          (Interfaces.Unsigned_64 (Prompt_Count - First_Token + 1),
           Outcome.Prefill_Ns);

      --  Decode loop.
      Started := Model_Runner.Clocks.Read (Time);

      if not Finished then
         P.Publish (Observer, P.Generation_Progress (P.Generation_Started));
         L.Enter (Session, L.Generating);

         Decode_Loop :
         for Produced in 1 .. Item.Max_Tokens loop
            declare
               Token : Token_Id;
            begin
               if C.Is_Cancelled (Cancel) then
                  Conclude (Cancelled);
                  exit Decode_Loop;
               end if;

               --  Sample from the raw logits the last evaluation produced.
               S.Sample (Sampler, Logits.all, Token, Status);
               if E.Is_Error (Status) then
                  Conclude (Runtime_Error, Status);
                  exit Decode_Loop;
               end if;

               --  Token-level stop conditions, before any text is produced, so
               --  that no byte of a stop token reaches the output.
               if Token = Vocab.End_Token (Words.all) then
                  Conclude (End_Of_Sequence);
                  exit Decode_Loop;
               end if;

               if Model_Runner.Stops.Is_Stop_Token (Stop_Set, Token) then
                  Conclude (Stop_Token);
                  exit Decode_Loop;
               end if;

               --  Commit the token to the session.
               S.Record_Token (Sampler, Token);
               L.Evaluate (Session, Source, Token, Logits.all, Cancel, Status);

               if E.Is_Error (Status) then
                  if Status.Code = E.Generation_Cancelled then
                     Conclude (Cancelled);
                  elsif Status.Code = E.Generation_Context_Exhausted then
                     Conclude (Context_Full);
                  else
                     Conclude (Runtime_Error, Status);
                  end if;
                  exit Decode_Loop;
               end if;

               Outcome.Generated_Tokens := Produced;
               P.Publish
                 (Observer,
                  P.Generation_Progress
                    (P.Token_Produced, Interfaces.Unsigned_64 (Produced),
                     Interfaces.Unsigned_64 (Item.Max_Tokens)));

               --  Decode, holding back bytes that a stop string could still
               --  complete. The incremental decoder never returns a partial
               --  UTF-8 sequence.
               declare
                  Fragment : constant String :=
                    Vocab.Push (Decoder, Words.all, Token);
               begin
                  if Pending_Used + Fragment'Length
                    > Natural (Pending.all'Length)
                  then
                     Conclude
                       (Runtime_Error, E.Make (E.Internal_Invariant_Violated));
                     exit Decode_Loop;
                  end if;

                  if Fragment'Length > 0 then
                     Pending.all
                       (B.Byte_Count (Pending_Used) + 1
                        .. B.Byte_Count (Pending_Used + Fragment'Length)) :=
                       B.To_Bytes (Fragment);
                     Pending_Used := Pending_Used + Fragment'Length;
                  end if;
               end;

               --  Stop strings, matched across token boundaries.
               declare
                  First  : Natural;
                  Length : Natural;
               begin
                  Model_Runner.Stops.Scan
                    (Stop_Set, Pending_Text, First, Length);

                  if First /= 0 then
                     --  Release the text before the stop string and no byte of
                     --  the stop string itself.
                     Emit (Pending_Text (1 .. First - 1));
                     Pending_Used := 0;
                     Conclude ((if Closed then Output_Closed else Stop_String));
                     exit Decode_Loop;
                  end if;
               end;

               --  Release everything that can no longer begin a stop string.
               declare
                  Held : constant Natural :=
                    Natural'Min (Pending_Used, Natural'Max (Longest - 1, 0));
                  Free : constant Natural := Pending_Used - Held;
               begin
                  if Free > 0 then
                     Emit (Pending_Text (1 .. Free));
                     Consume (Free);
                  end if;
               end;

               if Closed then
                  Conclude (Output_Closed);
                  exit Decode_Loop;
               end if;

               if Produced = Item.Max_Tokens then
                  Conclude (Maximum_Tokens);
                  exit Decode_Loop;
               end if;
            end;
         end loop Decode_Loop;
      end if;

      --  Flush the safely decodable remainder, but only when the run ended for
      --  a reason that leaves buffered text meaningful. A cancelled or failed
      --  run does not emit a trailing fragment, and a stop string has already
      --  consumed the buffer.
      if Outcome.Reason in End_Of_Sequence | Stop_Token | Maximum_Tokens
                         | Context_Full
      then
         declare
            Tail : constant String := Pending_Text & Vocab.Flush (Decoder);
         begin
            Emit (Tail);
            Pending_Used := 0;
         end;
      end if;

      Model_Runner.Output.Flush_Sink (Sink, Closed);

      Outcome.Decode_Ns :=
        Model_Runner.Clocks.Elapsed (Started, Model_Runner.Clocks.Read (Time));
      Outcome.Decode_Rate :=
        Model_Runner.Clocks.Rate_Per_Second
          (Interfaces.Unsigned_64 (Outcome.Generated_Tokens),
           Outcome.Decode_Ns);
      Outcome.Final_Position := L.Position (Session);

      P.Publish
        (Observer,
         P.Generation_Progress
           (P.Generation_Completed,
            Interfaces.Unsigned_64 (Outcome.Generated_Tokens)));

      Cleanup;
   exception
      when Occurrence : others =>
         Cleanup;
         Outcome.Reason := Runtime_Error;
         Outcome.Error := E.Make (E.Internal_Unexpected_Exception);
         E.Add_Frame (Outcome.Error, "generation.generate");
         E.Add_Frame
           (Outcome.Error, Ada.Exceptions.Exception_Name (Occurrence));
   end Generate;

end Model_Runner.Generation;
