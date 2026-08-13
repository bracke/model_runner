with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Backend.CPU;
with Model_Runner.Tensors;
with Model_Runner.Text;

package body Model_Runner.Generation is

   package Workers_CPU renames Model_Runner.Backend.CPU;

   use type Workers_CPU.Pool_Reference;

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

   use type N.Element_Count;
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
      Rules    : Grammar_Reference := null;
      Sink     : Model_Runner.Output.Sink_Reference;
      Observer : P.Observer_Reference;
      Time     : Model_Runner.Clocks.Clock_Reference;
      Seeds    : Model_Runner.Entropy.Source_Reference;
      Cancel   : C.Token_Reference;
      Draft    : access L.Model'Class := null;
      Draft_Session : access L.Session := null;
      Reporter : Explainer_Reference := null;
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

      --  Where the generated text has got to in the grammar, when there is
      --  one. Started below, once the prompt is behind us: a grammar
      --  constrains what the model produces, not what it was given.
      Shape   : Model_Runner.Grammar.Matcher;
      Decoder : Vocab.Decoder;
      Logits  : T.Real_Array_Access := null;
      Tokens  : Token_Buffer := null;

      --  Bytes decoded but not yet released, because a stop string might still
      --  complete inside them.
      Pending      : B.Byte_Array_Access := null;
      Pending_Used : Natural := 0;

      Prompt_Count : Natural := 0;
      First_Token  : Positive := 1;

      --  Drafting. On only when there is a draft model and a session on it,
      --  a count of tokens to propose, greedy sampling and no grammar --
      --  the last two because they are what makes "the same text as without
      --  a draft" a statement anybody can check.
      Drafting : constant Boolean :=
        Draft /= null
        and then Draft_Session /= null
        and then Item.Draft_Tokens > 0
        and then S.Is_Greedy (Item.Sampling)
        and then Rules = null;

      Largest_Draft : constant Natural :=
        (if Drafting
         then Natural'Min (Item.Draft_Tokens, L.Max_Batch - 1)
         else 0);

      --  What a round proposed and what came back for it. Proposals are the
      --  draft's; Verified holds the ones the target agrees with, which is
      --  a prefix of them and is what the run then emits one at a time.
      Proposed : Token_Buffer := null;
      Verified : Token_Buffer := null;
      Verified_Count : Natural := 0;
      Verified_At    : Natural := 0;

      --  One vocabulary-sized row per position of a verification batch, and
      --  a copy of the distribution the round started from.
      --
      --  The copy is for explaining. A verified token was chosen from a
      --  particular distribution -- the first from the one the round began
      --  with, the rest from the batch's rows -- and reporting the row the
      --  round ended at would answer about the wrong position for every
      --  token but the last.
      Every  : T.Real_Array_Access := null;
      Opened : T.Real_Array_Access := null;

      --  Somewhere for the draft's own distributions to go.
      --
      --  Its own, and not the target's buffer. Sharing that one was a fault
      --  it took a draft that disagrees to find: the draft reads the prompt
      --  too, and writing its logits over the target's meant the first token
      --  of the run was sampled from the draft's distribution rather than
      --  the model's. A draft that agrees with the model everywhere -- a
      --  model drafting for itself, which is what the first test used --
      --  cannot tell the two apart.
      Aside : T.Real_Array_Access := null;
      Status       : E.Error_Info := E.Success;
      Closed       : Boolean := False;
      Started      : Model_Runner.Clocks.Nanoseconds := 0;
      Finished     : Boolean := False;

      --  Release everything this call owns. Called exactly once, from the
      --  single exit path.
      procedure Cleanup is
      begin
         T.Free (Logits);
         T.Free (Every);
         T.Free (Opened);
         T.Free (Aside);
         B.Free (Pending);
         if Tokens /= null then
            Free_Tokens (Tokens);
         end if;
         if Proposed /= null then
            Free_Tokens (Proposed);
         end if;
         if Verified /= null then
            Free_Tokens (Verified);
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

      --  What actually ran this, recorded before the first product rather
      --  than assumed by whoever reads the figures afterwards.
      Outcome.Backend := L.Capability (Source).Kind;
      Outcome.Workers :=
        (if L.Workers (Session) = null then 1
         else Positive (Workers_CPU.Worker_Total (L.Workers (Session).all)));

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

      if Rules /= null then
         Model_Runner.Grammar.Start (Rules.all, Shape, Status);
         if E.Is_Error (Status) then
            Conclude (Runtime_Error, Status);
            Cleanup;
            return;
         end if;
      end if;

      --  What the caller wants nudged. Set once, before anything is
      --  generated, because a bias is a property of the run.
      for Index in 1 .. Item.Bias_Count loop
         S.Bias (Sampler, Item.Bias_Tokens (Index), Item.Bias_Amounts (Index),
                 Status);
         if E.Is_Error (Status) then
            Conclude (Runtime_Error, Status);
            Cleanup;
            return;
         end if;
      end loop;

      --  A beginning-of-sequence marker belongs to the prompt, never to the
      --  generated text.
      if Vocab.Beginning_Token (Words.all) /= Vocab.No_Token then
         S.Forbid (Sampler, Vocab.Beginning_Token (Words.all));
      end if;

      T.Allocate (N.Element_Count (Settings.Vocabulary), Logits);

      if Drafting then
         Proposed := new Vocab.Token_Array (1 .. Largest_Draft + 1);
         Verified := new Vocab.Token_Array (1 .. Largest_Draft + 1);
         T.Allocate
           (N.Element_Count (Settings.Vocabulary)
            * N.Element_Count (Largest_Draft + 1), Every);

         T.Allocate (N.Element_Count (Settings.Vocabulary), Aside);

         if Item.Logprobs > 0 then
            T.Allocate (N.Element_Count (Settings.Vocabulary), Opened);
         end if;

         if Proposed = null or else Verified = null or else Every = null
           or else Aside = null
           or else (Item.Logprobs > 0 and then Opened = null)
         then
            Conclude (Runtime_Error, E.Make (E.Memory_Allocation_Failed));
            Cleanup;
            return;
         end if;
      end if;
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

         --  A run that may drop its oldest positions is not bounded by what
         --  the context holds at once, so the sum below is not a limit on
         --  it. The prompt still has to fit -- there is nothing to drop
         --  before it has been read -- which is the check above.
         if Item.Context_Shift = 0
           and then Remaining + Item.Max_Tokens > Available
         then
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
                  Cancel => Cancel, Status => Status);

               if E.Is_Error (Status) then
                  if Status.Code = E.Generation_Cancelled then
                     Conclude (Cancelled);
                  else
                     Conclude (Runtime_Error, Status);
                  end if;
                  exit Prefill_Loop;
               end if;

               --  The same prompt on the draft, so that it is looking at
               --  what the target is looking at. Its logits are thrown away
               --  here; what matters is its context.
               if Drafting then
                  declare
                     Local : E.Error_Info;
                  begin
                     L.Evaluate_Batch
                       (Draft_Session.all, Draft.all,
                        Tokens.all (Index .. Last), Aside.all,
                        Cancel => Cancel, Status => Local);

                     if E.Is_Error (Local) then
                        Conclude (Runtime_Error, Local);
                        exit Prefill_Loop;
                     end if;
                  end;
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

      --  One round of drafting and checking.
      --
      --  The draft proposes what it would say next, one token at a time from
      --  where it is; the target then reads all of them in one pass and says
      --  what it would have said at each of those positions. The proposals
      --  the target agrees with are what the run produces -- and because
      --  this only runs at temperature zero, "agrees with" is the whole
      --  test: the target's own choice at that position either is the
      --  proposal or it is not.
      --
      --  What comes out is the same text the target would have produced
      --  alone. What is saved is passes over the target's weights: however
      --  many proposals are accepted, they cost one.
      --
      --  Both sessions are put back to the accepted length afterwards. The
      --  target read further than that and the draft proposed further than
      --  that, and neither of those positions describes the text.
      declare
         --  Declared here and called from the loop below, which is the only
         --  caller it will ever have.
         procedure Draft_Round
           (Produced_Here : out Natural;
            Failed        : out Boolean)
         is
            Before : constant Natural := L.Position (Session);
            Count  : Natural := 0;
            Local  : E.Error_Info;
            Guess  : Token_Id;
         begin
            Produced_Here := 0;
            Failed := False;

            --  What the target would say now, which is the one token this
            --  round is certain of before it starts. Kept, when anybody is
            --  being told about the probabilities, because this is the
            --  distribution that token came from.
            if Opened /= null then
               Opened.all := Logits.all;
            end if;

            S.Sample (Sampler, Logits.all, Guess, Local);
            if E.Is_Error (Local) then
               Conclude (Runtime_Error, Local);
               Failed := True;
               return;
            end if;

            Count := 1;
            Proposed.all (1) := Guess;

            --  And what the draft would say after it, and after that, and so
            --  on. Each proposal costs the draft a pass; a draft as large as
            --  the target would cost exactly what it saves.
            for Step in 1 .. Largest_Draft loop
               L.Evaluate
                 (Draft_Session.all, Draft.all, Proposed.all (Count),
                  Aside.all, Cancel, Local);
               if E.Is_Error (Local) then
                  Conclude (Runtime_Error, Local);
                  Failed := True;
                  return;
               end if;

               S.Sample (Sampler, Aside.all, Guess, Local);
               if E.Is_Error (Local) then
                  Conclude (Runtime_Error, Local);
                  Failed := True;
                  return;
               end if;

               Count := Count + 1;
               Proposed.all (Count) := Guess;
            end loop;

            --  The first is the target's own; the rest are the draft's, and
            --  those are what the count below is about.
            Outcome.Drafted := Outcome.Drafted + Count - 1;

            --  The target reads the lot in one pass, and says what it would
            --  have said at each position.
            L.Evaluate_Batch
              (Session, Source, Proposed.all (1 .. Count), Logits.all,
               Every => Every, Cancel => Cancel, Status => Local);
            if E.Is_Error (Local) then
               if Local.Code = E.Generation_Cancelled then
                  Conclude (Cancelled);
               elsif Local.Code = E.Generation_Context_Exhausted then
                  Conclude (Context_Full);
               else
                  Conclude (Runtime_Error, Local);
               end if;
               Failed := True;
               return;
            end if;

            --  The first proposal is the target's own and is always kept.
            --  Each one after it is kept while the target's choice at the
            --  position before it is the proposal.
            Verified.all (1) := Proposed.all (1);
            Verified_Count := 1;

            for Step in 2 .. Count loop
               declare
                  Row : constant N.Element_Count :=
                    N.Element_Count (Step - 2)
                    * N.Element_Count (Settings.Vocabulary);

                  Wanted : Token_Id;
               begin
                  S.Sample
                    (Sampler,
                     Every.all (Every.all'First + Row
                                .. Every.all'First + Row
                                   + N.Element_Count (Settings.Vocabulary)
                                   - 1),
                     Wanted, Local);
                  if E.Is_Error (Local) then
                     Conclude (Runtime_Error, Local);
                     Failed := True;
                     return;
                  end if;

                  exit when Wanted /= Proposed.all (Step);

                  Verified_Count := Verified_Count + 1;
                  Verified.all (Verified_Count) := Proposed.all (Step);
               end;
            end loop;

            --  Back to what was agreed, on both sides. The target committed
            --  every proposal and the draft committed every proposal but the
            --  last, so both have gone further than the text has.
            L.Rewind (Session, Before + Verified_Count, Local);
            if E.Is_Error (Local) then
               Conclude (Runtime_Error, Local);
               Failed := True;
               return;
            end if;

            L.Rewind
              (Draft_Session.all,
               Natural'Min (L.Position (Draft_Session.all),
                            Before + Verified_Count),
               Local);
            if E.Is_Error (Local) then
               Conclude (Runtime_Error, Local);
               Failed := True;
               return;
            end if;

            --  And forward, where the draft is behind. It proposed further
            --  than it read: the last proposal is one it never evaluated,
            --  so when every proposal is accepted the draft is a token short
            --  of the text and the next round would ask it what comes next
            --  without showing it what came last.
            --
            --  That is not a wrong answer anywhere -- the target checks
            --  everything -- it is a draft guessing from a context missing
            --  its last token, which guesses badly. Found by a model
            --  drafting for itself and agreeing with only four of six
            --  proposals, which is four more than a disagreement and two
            --  fewer than the truth.
            while L.Position (Draft_Session.all) < Before + Verified_Count
            loop
               declare
                  Step : constant Natural :=
                    L.Position (Draft_Session.all) - Before + 1;
               begin
                  L.Evaluate
                    (Draft_Session.all, Draft.all, Verified.all (Step),
                     Aside.all, Cancel, Local);
                  if E.Is_Error (Local) then
                     Conclude (Runtime_Error, Local);
                     Failed := True;
                     return;
                  end if;
               end;
            end loop;

            --  And what follows the last accepted token, for the next round
            --  or the next single step to sample from.
            declare
               Row : constant N.Element_Count :=
                 N.Element_Count (Verified_Count - 1)
                 * N.Element_Count (Settings.Vocabulary);
            begin
               Logits.all :=
                 Every.all (Every.all'First + Row
                            .. Every.all'First + Row
                               + N.Element_Count (Settings.Vocabulary) - 1);
            end;

            Outcome.Accepted := Outcome.Accepted + Verified_Count - 1;

            Verified_At := 0;
            Produced_Here := Verified_Count;
         end Draft_Round;
      begin

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

               --  What the grammar allows next, if there is one. Every token
               --  whose text cannot continue it leaves the distribution
               --  before anything is sampled, which is what makes this a
               --  constraint rather than a request: the tokens that would
               --  break the shape are not there to be chosen.
               --
               --  The end token goes with them until the grammar may end, so
               --  a run cannot stop half way through what it was asked for.
               if Rules /= null then
                  S.Release_Step_Mask (Sampler);

                  declare
                     Allowed : Natural := 0;
                  begin
                     for Candidate in 0 .. Settings.Vocabulary - 1 loop
                        declare
                           Which : constant Token_Id := Token_Id (Candidate);
                        begin
                           if Which = Vocab.End_Token (Words.all) then
                              if Model_Runner.Grammar.Is_Complete
                                   (Rules.all, Shape)
                              then
                                 Allowed := Allowed + 1;
                              else
                                 S.Forbid_For_Step (Sampler, Which);
                              end if;

                           elsif Vocab.Decode_Token (Words.all, Which) = ""
                           then
                              --  A token that contributes no text cannot
                              --  advance a grammar, and allowing it would
                              --  let a run produce it forever while the
                              --  grammar stayed where it was. The end token
                              --  is the one exception and it is above.
                              S.Forbid_For_Step (Sampler, Which);

                           elsif Model_Runner.Grammar.Accepts
                                   (Rules.all, Shape,
                                    Vocab.Decode_Token (Words.all, Which))
                           then
                              Allowed := Allowed + 1;
                           else
                              S.Forbid_For_Step (Sampler, Which);
                           end if;
                        end;
                     end loop;

                     if Allowed = 0 then
                        Conclude
                          (Runtime_Error,
                           E.Make (E.Grammar_Rejected_Every_Token));
                        exit Decode_Loop;
                     end if;
                  end;
               end if;

               --  Where the next token comes from. Without a draft it is
               --  sampled from the logits the last evaluation produced.
               --  With one it comes from a round of proposals the target has
               --  already checked, and the session is already past it -- so
               --  the commit at the bottom of this loop is skipped for it.
               if Drafting then
                  if Verified_At >= Verified_Count then
                     declare
                        Made : Natural;
                        Gave : Boolean;
                     begin
                        Draft_Round (Made, Gave);
                        exit Decode_Loop when Gave;
                     end;
                  end if;

                  Verified_At := Verified_At + 1;
                  Token := Verified.all (Verified_At);
               else
                  S.Sample (Sampler, Logits.all, Token, Status);
                  if E.Is_Error (Status) then
                     Conclude (Runtime_Error, Status);
                     exit Decode_Loop;
                  end if;
               end if;

               --  What the model made of this position, when somebody asked.
               --  After the choice rather than instead of it: the report says
               --  what was chosen as well as what was likely, and the two are
               --  not always the same token.
               if Reporter /= null and then Item.Logprobs > 0 then
                  declare
                     Report : S.Explanation;
                     Told   : E.Error_Info;

                     --  Which distribution this token was chosen from. Not
                     --  the current one when a round produced it: the first
                     --  of a round came from what the round began with and
                     --  the rest from the batch's own rows, and the current
                     --  one describes the position after all of them.
                     Row : constant N.Element_Count :=
                       (if Drafting and then Verified_At > 1
                        then N.Element_Count (Verified_At - 2)
                             * N.Element_Count (Settings.Vocabulary)
                        else 0);
                  begin
                     if not Drafting then
                        S.Explain
                          (Sampler, Logits.all, Token, Item.Logprobs, Report,
                           Told);
                     elsif Verified_At = 1 then
                        S.Explain
                          (Sampler, Opened.all, Token, Item.Logprobs, Report,
                           Told);
                     else
                        S.Explain
                          (Sampler,
                           Every.all (Every.all'First + Row
                                      .. Every.all'First + Row
                                         + N.Element_Count
                                             (Settings.Vocabulary) - 1),
                           Token, Item.Logprobs, Report, Told);
                     end if;

                     if E.Is_Ok (Told) then
                        Reporter.all.Explain (Report);
                     end if;
                  end;
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

               --  And through the grammar, which now expects what follows
               --  this token rather than what followed the one before it.
               if Rules /= null then
                  Model_Runner.Grammar.Advance
                    (Rules.all, Shape,
                     Vocab.Decode_Token (Words.all, Token), Status);
                  if E.Is_Error (Status) then
                     Conclude (Runtime_Error, Status);
                     exit Decode_Loop;
                  end if;
               end if;

               --  Commit the token to the session, unless a round already
               --  did: a verified token is in the target's context by the
               --  time it reaches here, and evaluating it again would put it
               --  there twice.
               S.Record_Token (Sampler, Token);

               if Drafting then
                  Status := E.Success;
               else
                  L.Evaluate
                    (Session, Source, Token, Logits.all, Cancel, Status);
               end if;

               --  A context that has filled, when the caller asked for the
               --  oldest to be dropped rather than the run to end. Tried
               --  once: if the token still will not go in after the shift,
               --  the run ends as it would have.
               if E.Is_Error (Status)
                 and then Status.Code = E.Generation_Context_Exhausted
                 and then Item.Context_Shift > 0
               then
                  declare
                     Moved : E.Error_Info;
                  begin
                     L.Shift
                       (Session, Source, Item.Context_Keep,
                        Item.Context_Shift, Moved);

                     if E.Is_Ok (Moved) then
                        Outcome.Shifted := Outcome.Shifted + 1;
                        L.Evaluate
                          (Session, Source, Token, Logits.all, Cancel,
                           Status);
                     end if;
                  end;
               end if;

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
      end;

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
