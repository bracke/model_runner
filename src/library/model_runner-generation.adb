with Ada.Exceptions;
with Ada.Unchecked_Deallocation;

with Model_Runner.Lookup;
with Model_Runner.Shares;
with Model_Runner.Backend.CPU;
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
      Pictures : Picture_Set := No_Pictures;
      Outcome  : out Result)
   is
      Settings : constant L.Configuration := L.Config (Source);
      Words    : constant access constant Vocab.Vocabulary :=
        L.Vocabulary (Source);
      Longest  : constant Natural :=
        Model_Runner.Stops.Longest_String (Stop_Set);

      Sampler : S.Sampler;

      --  The session's workers, as the sampler can take them. Sampling
      --  walks the vocabulary twice a token and both walks used to run on
      --  the task that had just finished waiting for five.
      Sharing : constant Model_Runner.Shares.Team_Access :=
        L.Sharing (Session);

      --  Where the generated text has got to in the grammar, when there is
      --  one. Started below, once the prompt is behind us: a grammar
      --  constrains what the model produces, not what it was given.
      Shape   : Model_Runner.Grammar.Matcher;
      Decoder : Vocab.Decoder;

      --  What every token spells, decoded once for the grammar's filter
      --  rather than twice a candidate a step. Filled only when there is a
      --  grammar to filter for.
      Spelt   : Vocab.Decoded_Texts;

      --  Whether the grammar's first, unmasked draw was taken as this
      --  step's token, so that nothing draws again below.
      Chosen  : Boolean := False;

      --  Whether the grammar takes a token where it stands: the end token
      --  only where the grammar may end, a token spelling nothing never --
      --  it could not advance the grammar and would be produced forever --
      --  and any other by what it spells.
      function Grammar_Takes (Which : Token_Id) return Boolean
      is (if Vocab.Ends_Generation (Words.all, Which)
          then Model_Runner.Grammar.Is_Complete (Rules.all, Shape)
          elsif Vocab.Text_Of (Spelt, Which) = "" then False
          else Model_Runner.Grammar.Accepts
                 (Rules.all, Shape, Vocab.Text_Of (Spelt, Which)));
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
      --  A model to draft with, where the caller gave one.
      By_Model : constant Boolean :=
        Draft /= null and then Draft_Session /= null;

      --  The model's own block past its stack, where the file carries
      --  one and the caller asked for it and gave no model.
      By_Next : constant Boolean :=
        not By_Model and then Item.Draft_From_Next
        and then L.Drafts_Next (Session);

      Drafting : constant Boolean :=
        (By_Model or else By_Next or else Item.Draft_From_Context)
        and then Item.Draft_Tokens > 0
        and then S.Is_Greedy (Item.Sampling)
        and then Rules = null;

      --  Drafting with nothing to draft from but the text. Everything below
      --  that reaches for the draft session is skipped: there is no second
      --  context to keep alongside this one, nothing to prefill, nothing to
      --  shift and nothing to rewind. The next block is the same in that:
      --  its context is this session's own.
      By_Context : constant Boolean :=
        Drafting and then not By_Model and then not By_Next;

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

      --  What this run has committed, for a proposal to be searched out of.
      --  The target's own tokens rather than a list kept alongside them: a
      --  proposal checked against a context the target has not read would
      --  be a guess about a different text.
      Said       : Token_Buffer := null;
      Said_Count : Natural := 0;

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
      Next_In     : T.Real_Array_Access := null;

      --  What a position run through the next block only for its cache
      --  is handed for logits: nothing, which is how the head is skipped.
      No_Logits : N.Real_Array (1 .. 0);

      --  Whether Next_In holds the state a round left for the next, which
      --  a single-token round does not: that one's state is the session's
      --  own last.
      Next_Chained : Boolean := False;
      Next_Out    : T.Real_Array_Access := null;
      Next_States : T.Real_Array_Access := null;
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
         T.Free (Next_In);
         T.Free (Next_Out);
         T.Free (Next_States);
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
         Vocab.Free (Spelt);
         S.Close (Sampler);
      end Cleanup;

      --  Bring Said up to what the session holds.
      --
      --  Read out of the session rather than appended to as tokens are
      --  produced, because the session is the thing that knows: a prompt
      --  arrives in batches, a rolling context renumbers what it keeps, and
      --  a rejected proposal takes its positions back. Refilled whole when
      --  it has shrunk -- which is a shift or a rejection -- and topped up
      --  otherwise, so a round costs the tokens it added.
      procedure Recall_Said;

      procedure Recall_Said is
      begin
         if Said = null then
            return;
         end if;

         if Said_Count > L.Position (Session) then
            Said_Count := 0;
         end if;

         while Said_Count < L.Position (Session)
           and then Said_Count < Said.all'Length
         loop
            Said_Count := Said_Count + 1;
            Said.all (Said_Count) :=
              L.Committed_Token (Session, Said_Count - 1);
         end loop;
      end Recall_Said;

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
      Outcome.Weights_Mapped := L.Weights_Mapped (Source);

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
         Vocab.Decode_All (Words.all, Spelt);
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

         if By_Context then
            Said := new Vocab.Token_Array (1 .. L.Capacity (Session) + 1);
         end if;

         T.Allocate
           (N.Element_Count (Settings.Vocabulary)
            * N.Element_Count (Largest_Draft + 1), Every);

         T.Allocate (N.Element_Count (Settings.Vocabulary), Aside);

         --  The next block's chain: the state it is given and the one it
         --  hands back, and every position's state of a checked round,
         --  which is what its cache is refilled from.
         if By_Next then
            T.Allocate (N.Element_Count (Settings.Embedding), Next_In);
            T.Allocate (N.Element_Count (Settings.Embedding), Next_Out);
            T.Allocate
              (N.Element_Count (Settings.Embedding)
               * N.Element_Count (Largest_Draft + 1), Next_States);
         end if;

         if Item.Logprobs > 0 then
            T.Allocate (N.Element_Count (Settings.Vocabulary), Opened);
         end if;

         if Proposed = null or else Verified = null or else Every = null
           or else Aside = null
           or else (Item.Logprobs > 0 and then Opened = null)
           or else (By_Next
                    and then (Next_In = null or else Next_Out = null
                              or else Next_States = null))
         then
            Conclude (Runtime_Error, E.Make (E.Memory_Allocation_Failed));
            Cleanup;
            return;
         end if;

         --  A round checks a draft's proposals and rewinds to the last one
         --  agreed, which a session of a hybrid architecture can do only
         --  as far back as it kept its states: a draft's worth and one.
         declare
            Kept : E.Error_Info;
         begin
            L.Keep_States (Session, Largest_Draft + 1, Kept);

            if E.Is_Ok (Kept) and then By_Model then
               L.Keep_States (Draft_Session.all, Largest_Draft + 1, Kept);
            end if;

            if E.Is_Error (Kept) then
               Conclude (Runtime_Error, Kept);
               Cleanup;
               return;
            end if;
         end;
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

      --  The pictures, opened out: each marker the template wrote becomes
      --  the marker, the soft tokens the picture's rows stand behind, and
      --  the closer, so that the positions the rows take are ordinary
      --  positions of the prompt from here on. A prompt marking more or
      --  fewer pictures than were given is refused before anything is
      --  evaluated, since the model would read it wrongly either way.
      if Pictures.Marker /= Vocab.No_Token then
         declare
            Marked : Natural := 0;
         begin
            for Index in 1 .. Prompt_Count loop
               if Tokens.all (Index) = Pictures.Marker then
                  Marked := Marked + 1;
               end if;
            end loop;

            if Marked /= Pictures.Count
              or else (Marked > 0
                       and then (Pictures.Rows = null
                                 or else Pictures.Soft = Vocab.No_Token))
            then
               Status := E.Make (E.Generation_Picture_Count_Mismatch);
               E.Add_Integer (Status, "expected", Long_Long_Integer (Marked));
               E.Add_Integer (Status, "count", Long_Long_Integer (Pictures.Count));
               Conclude (Runtime_Error, Status);
               Cleanup;
               return;
            end if;

            if Marked > 0 then
               declare
                  Extra  : constant Natural :=
                    Marked * (Pictures.Per_Picture
                              + (if Pictures.Closer /= Vocab.No_Token
                                 then 1 else 0));
                  Opened : constant Token_Buffer :=
                    new Vocab.Token_Array
                      (1 .. Natural'Max (Tokens.all'Length,
                                         Prompt_Count + Extra));
                  Filled : Natural := 0;
               begin
                  for Index in 1 .. Prompt_Count loop
                     Filled := Filled + 1;
                     Opened.all (Filled) := Tokens.all (Index);
                     if Tokens.all (Index) = Pictures.Marker then
                        for Row in 1 .. Pictures.Per_Picture loop
                           Filled := Filled + 1;
                           Opened.all (Filled) := Pictures.Soft;
                        end loop;
                        if Pictures.Closer /= Vocab.No_Token then
                           Filled := Filled + 1;
                           Opened.all (Filled) := Pictures.Closer;
                        end if;
                     end if;
                  end loop;
                  Free_Tokens (Tokens);
                  Tokens := Opened;
                  Prompt_Count := Filled;
               end;
            end if;
         end;
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

         --  The picture rows a batch starting at From reads: the soft
         --  tokens before it have taken that many rows already.
         function Given_Before (From : Positive) return L.Given_Rows is
            Before : N.Element_Count := 0;
         begin
            if Pictures.Rows = null or else Pictures.Soft = Vocab.No_Token then
               return L.No_Given_Rows;
            end if;
            for Step in 1 .. From - 1 loop
               if Tokens.all (Step) = Pictures.Soft then
                  Before := Before + 1;
               end if;
            end loop;
            return (Token => Pictures.Soft, Rows => Pictures.Rows,
                    First => Before);
         end Given_Before;
      begin
         Prefill_Loop :
         while Index <= Prompt_Count loop
            if C.Is_Cancelled (Cancel) then
               Conclude (Cancelled);
               exit Prefill_Loop;
            end if;

            declare
               --  The batch's last position -- moved so that a picture's
               --  rows, which attend to each other, travel in one batch:
               --  a batch that would end inside a run of them ends before
               --  the run instead, or, where the run began the batch and
               --  fits within what the engine takes at once, after it.
               function Batch_End return Natural is
                  Last : constant Natural := Natural'Min (Index + Span - 1, Prompt_Count);
               begin
                  if Pictures.Soft = Vocab.No_Token or else Last >= Prompt_Count
                    or else Tokens.all (Last) /= Pictures.Soft
                    or else Tokens.all (Last + 1) /= Pictures.Soft
                  then
                     return Last;
                  end if;
                  declare
                     Run_Start : Natural := Last;
                     Run_End   : Natural := Last;
                  begin
                     while Run_Start > Index
                       and then Tokens.all (Run_Start - 1) = Pictures.Soft
                     loop
                        Run_Start := Run_Start - 1;
                     end loop;
                     while Run_End < Prompt_Count
                       and then Tokens.all (Run_End + 1) = Pictures.Soft
                     loop
                        Run_End := Run_End + 1;
                     end loop;
                     if Run_Start > Index then
                        return Run_Start - 1;
                     elsif Run_End - Index + 1 <= L.Max_Batch then
                        return Run_End;
                     else
                        return Last;
                     end if;
                  end;
               end Batch_End;

               Last : constant Natural := Batch_End;
            begin
               --  With every position's state where the next block will
               --  be run over the prompt behind it.
               if By_Next then
                  declare
                     Rows : T.Real_Array_Access := null;
                  begin
                     T.Allocate
                       (N.Element_Count (Last - Index + 1)
                        * N.Element_Count (Settings.Embedding), Rows);

                     if Rows = null then
                        Conclude
                          (Runtime_Error,
                           E.Make (E.Memory_Allocation_Failed));
                        exit Prefill_Loop;
                     end if;

                     L.Evaluate_Batch
                       (Session, Source, Tokens.all (Index .. Last),
                        Logits.all, States => Rows, Cancel => Cancel,
                        Given => Given_Before (Index), Status => Status);

                     --  The block sees every position of the prompt but
                     --  the last: at position p it takes the token at
                     --  p + 1 beside the state at p, and the last token's
                     --  successor is what a round will draft.
                     if E.Is_Ok (Status) then
                        for Step in Index .. Last - 1 loop
                           declare
                              At_Row : constant N.Element_Count :=
                                N.Element_Count (Step - Index)
                                * N.Element_Count (Settings.Embedding);
                           begin
                              L.Draft_Next
                                (Session, Source, Tokens.all (Step + 1),
                                 Rows.all (At_Row
                                           .. At_Row
                                              + N.Element_Count
                                                  (Settings.Embedding) - 1),
                                 Step - 1, No_Logits, Next_Out.all, Status);
                              exit when E.Is_Error (Status);
                           end;
                        end loop;
                     end if;

                     T.Free (Rows);
                  end;
               else
                  L.Evaluate_Batch
                    (Session, Source, Tokens.all (Index .. Last), Logits.all,
                     Cancel => Cancel, Given => Given_Before (Index),
                     Status => Status);
               end if;

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
               if Drafting and then By_Model then
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
            Before : Natural := L.Position (Session);
            Count  : Natural := 0;
            Local  : E.Error_Info;
            Guess  : Token_Id;

            --  Drop the oldest positions from both sessions at once, when
            --  the caller asked for that. Both, because the draft is only
            --  useful while it is looking at what the target is looking at:
            --  shifting one and not the other leaves it proposing from a
            --  context the target does not have.
            --
            --  The single-token path had this and the round did not, so
            --  --context-shift did nothing at all in company with
            --  --draft-model -- an option that works alone and stops
            --  working beside another, which is the third time that shape
            --  of fault has been made here.
            procedure Make_Room (Ok : out Boolean) is
               Moved : E.Error_Info;
            begin
               Ok := False;
               if Item.Context_Shift = 0 then
                  return;
               end if;

               L.Shift
                 (Session, Source, Item.Context_Keep, Item.Context_Shift,
                  Moved);
               if E.Is_Error (Moved) then
                  return;
               end if;

               if By_Model then
                  L.Shift
                    (Draft_Session.all, Draft.all, Item.Context_Keep,
                     Item.Context_Shift, Moved);
                  if E.Is_Error (Moved) then
                     return;
                  end if;
               end if;

               Outcome.Shifted := Outcome.Shifted + 1;
               Before := L.Position (Session);
               Ok := True;
            end Make_Room;
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

            S.Sample (Sampler, Logits.all, Guess, Local, Sharing);
            if E.Is_Error (Local) then
               Conclude (Runtime_Error, Local);
               Failed := True;
               return;
            end if;

            Count := 1;
            Proposed.all (1) := Guess;

            if By_Next then
               --  The block past the stack, once a proposal: given the
               --  token just guessed beside the stack's state at the
               --  position before it, it says what follows; given that
               --  beside its own answer's state, what follows that.
               if not Next_Chained then
                  Next_In.all := L.Last_State (Session);
               end if;

               for Step in 1 .. Largest_Draft loop
                  exit when Before + Step - 2 >= L.Capacity (Session);

                  L.Draft_Next
                    (Session, Source, Proposed.all (Count),
                     Next_In.all, Before + Step - 2,
                     Aside.all, Next_Out.all, Local);
                  if E.Is_Error (Local) then
                     Conclude (Runtime_Error, Local);
                     Failed := True;
                     return;
                  end if;

                  S.Sample (Sampler, Aside.all, Guess, Local, Sharing);
                  if E.Is_Error (Local) then
                     Conclude (Runtime_Error, Local);
                     Failed := True;
                     return;
                  end if;

                  Count := Count + 1;
                  Proposed.all (Count) := Guess;
                  Next_In.all := Next_Out.all;
               end loop;
            elsif By_Context then
               --  What followed this phrase the last time it was said. One
               --  search rather than a pass a proposal, over the tokens
               --  this run has committed -- the target's own, so a proposal
               --  is never checked against a context the target has not
               --  read.
               Recall_Said;

               --  The token this round is already certain of, which the
               --  session has not committed yet and which the proposal has
               --  to follow: what is being asked is what comes after this
               --  phrase ending in Guess, not what came after the phrase
               --  before it.
               if Said_Count < Said.all'Length then
                  Said_Count := Said_Count + 1;
                  Said.all (Said_Count) := Guess;
               end if;

               declare
                  Given : Natural;
               begin
                  Lookup.Propose
                    (Said.all (1 .. Said_Count),
                     Proposed.all (2 .. Largest_Draft + 1), Given);
                  Count := Count + Given;
               end;
            else
               --  And what the draft would say after it, and after that, and
               --  so on. Each proposal costs the draft a pass; a draft as
               --  large as the target would cost exactly what it saves.
               for Step in 1 .. Largest_Draft loop
                  L.Evaluate
                    (Draft_Session.all, Draft.all, Proposed.all (Count),
                     Aside.all, Cancel, Local);

                  --  A draft that has run out of room stops proposing rather
                  --  than stopping the run: what it has proposed so far is
                  --  still worth checking, and the target's own room is
                  --  dealt with below.
                  exit when E.Is_Error (Local)
                    and then Local.Code = E.Generation_Context_Exhausted;

                  if E.Is_Error (Local) then
                     Conclude (Runtime_Error, Local);
                     Failed := True;
                     return;
                  end if;

                  S.Sample (Sampler, Aside.all, Guess, Local, Sharing);
                  if E.Is_Error (Local) then
                     Conclude (Runtime_Error, Local);
                     Failed := True;
                     return;
                  end if;

                  Count := Count + 1;
                  Proposed.all (Count) := Guess;
               end loop;
            end if;

            --  The first is the target's own; the rest are the draft's, and
            --  those are what the count below is about.
            Outcome.Drafted := Outcome.Drafted + Count - 1;

            --  The target reads the lot in one pass, and says what it would
            --  have said at each position.
            --
            --  UNLESS THERE IS ONLY THE ONE, which a lookup produces
            --  whenever the phrase it is holding has not been said before.
            --  A batch of one is not a token evaluated: it goes down the
            --  batched path, writes a row of every position's logits and
            --  costs about fifteen per cent more wall and half again the
            --  processor time. A draft model always proposes something, so
            --  this case did not exist until proposals came out of a
            --  search, and paying it on prose with nothing to look up would
            --  have made this a loss where it should be a wash.
            if Count = 1 then
               L.Evaluate
                 (Session, Source, Proposed.all (1), Logits.all,
                  Cancel, Local);
            else
               L.Evaluate_Batch
                 (Session, Source, Proposed.all (1 .. Count), Logits.all,
                  States => (if By_Next then Next_States else null),
                  Every => Every, Cancel => Cancel, Status => Local);
            end if;

            --  Out of room: drop the oldest and read them again. Once, as
            --  on the single-token path -- a batch that still will not fit
            --  after a shift ends the run as it would have.
            if E.Is_Error (Local)
              and then Local.Code = E.Generation_Context_Exhausted
            then
               declare
                  Room : Boolean;
               begin
                  Make_Room (Room);
                  if Room and then Count = 1 then
                     L.Evaluate
                       (Session, Source, Proposed.all (1), Logits.all,
                        Cancel, Local);
                  elsif Room then
                     L.Evaluate_Batch
                       (Session, Source, Proposed.all (1 .. Count),
                        Logits.all, Every => Every, Cancel => Cancel,
                        Status => Local);
                  end if;
               end;
            end if;

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

            --  AND THE PENALTY'S HISTORY MOVES WITH THE VERIFICATION, which
            --  it did not. A repetition penalty is computed from the tokens
            --  said so far, and a round samples several positions before it
            --  emits any of them: every row was scored against the history
            --  as it stood when the round began, where a run of single
            --  tokens would have scored each against the tokens before it.
            --
            --  So a drafted run answered differently from an undrafted one
            --  whenever a penalty was on -- which the command turns on by
            --  default, at 1.1 -- and the guarantee this path exists to
            --  keep was kept only at --repeat-penalty 1.0. Caught by a
            --  lookup drafting for a model that repeats itself, and true of
            --  --draft-model since it was written.
            --
            --  Recorded here rather than where a token is emitted, which is
            --  why the emitting below records only when nothing is
            --  drafting: a token recorded in both places is a token the
            --  penalty counts twice.
            S.Record_Token (Sampler, Proposed.all (1));

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
                  S.Record_Token (Sampler, Proposed.all (Step));
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

            if By_Model then
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
            while By_Model
              and then L.Position (Draft_Session.all)
                       < Before + Verified_Count
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
            --  or the next single step to sample from. A round of one never
            --  filled Every: what it wants is already in Logits, which is
            --  where a token evaluated on its own leaves it.
            if Count > 1 then
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
            end if;

            --  The next block's cache, put right: what it holds for the
            --  round's positions came from its own guesses at the states,
            --  and the stack has now said what they were. Every accepted
            --  position but the last is given its successor beside the
            --  stack's state; the last is the next round's first step,
            --  from the state kept here for it.
            if By_Next and then Count > 1 then
               declare
                  Width : constant N.Element_Count :=
                    N.Element_Count (Settings.Embedding);
               begin
                  for Step in 1 .. Verified_Count - 1 loop
                     declare
                        At_Row : constant N.Element_Count :=
                          N.Element_Count (Step - 1) * Width;
                     begin
                        L.Draft_Next
                          (Session, Source, Verified.all (Step + 1),
                           Next_States.all (At_Row .. At_Row + Width - 1),
                           Before + Step - 1, No_Logits, Next_Out.all, Local);
                        if E.Is_Error (Local) then
                           Conclude (Runtime_Error, Local);
                           Failed := True;
                           return;
                        end if;
                     end;
                  end loop;

                  declare
                     At_Row : constant N.Element_Count :=
                       N.Element_Count (Verified_Count - 1) * Width;
                  begin
                     Next_In.all :=
                       Next_States.all (At_Row .. At_Row + Width - 1);
                     Next_Chained := True;
                  end;
               end;
            elsif By_Next then
               Next_Chained := False;
            end if;

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

                  --  What the grammar allows next, if there is one. A token
                  --  whose text cannot continue it is not there to be
                  --  chosen, which is what makes this a constraint rather
                  --  than a request; and the end token is not there until
                  --  the grammar may end, so a run cannot stop half way
                  --  through what it was asked for.
                  --
                  --  Asked of one token before it is asked of all of them.
                  --  The whole vocabulary filtered a step is a quarter of a
                  --  million matches on a Qwen3.5 vocabulary, and where the
                  --  grammar stands at a choice between prose and every call
                  --  on offer each of those tries every branch: four seconds
                  --  a token, a hundred times the model. So the sampler is
                  --  asked first, unmasked, and its choice checked; a choice
                  --  the grammar takes is the token, and only a refused one
                  --  brings the whole filter and a second draw. Greedy, that
                  --  is the same token the filter alone would have found.
                  --  Sampled, a choice taken from the whole distribution and
                  --  kept only where the grammar allows it, with a fresh
                  --  draw from the filtered distribution otherwise, is a
                  --  draw from the filtered distribution -- the two branches
                  --  add up to exactly that -- so nothing about what is
                  --  produced changes, only what it costs.
                  if Rules /= null and then not Drafting then
                     S.Release_Step_Mask (Sampler);
                     S.Sample (Sampler, Logits.all, Token, Status, Sharing);
                     if E.Is_Error (Status) then
                        Conclude (Runtime_Error, Status);
                        exit Decode_Loop;
                     end if;

                     if Grammar_Takes (Token) then
                        Chosen := True;
                     else
                        Chosen := False;
                        declare
                           Allowed : Natural := 0;
                        begin
                           for Candidate in 0 .. Settings.Vocabulary - 1 loop
                              declare
                                 Which : constant Token_Id :=
                                   Token_Id (Candidate);
                              begin
                                 if Grammar_Takes (Which) then
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
                  else
                     Chosen := False;
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
                  elsif not Chosen then
                     S.Sample (Sampler, Logits.all, Token, Status, Sharing);
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
                  --  that no byte of a stop token reaches the output. The end
                  --  of the sequence, or of the turn: a model whose chat format
                  --  closes a turn with a token other than its end-of-sequence
                  --  one is done at either.
                  if Vocab.Ends_Generation (Words.all, Token) then
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
                  --  there twice. The penalty's history is the same story --
                  --  a round records what it verifies, as it verifies it.
                  if not Drafting then
                     S.Record_Token (Sampler, Token);
                  end if;

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
