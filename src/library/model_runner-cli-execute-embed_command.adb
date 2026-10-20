with Model_Runner.Clocks;
with Ada.Strings.Fixed;
with Ada.Unchecked_Deallocation;
with Model_Runner.Backend.CPU;
with Model_Runner.Backend.Device;
with Model_Runner.Limits;
with Model_Runner.Tensors;
with Model_Runner.UTF8;
with Model_Runner.CLI.Execute.Acquisition;

package body Model_Runner.CLI.Execute.Embed_Command is

   use Model_Runner.CLI.Execute.Acquisition;
   use type Model_Runner.CLI.Options.Prompt_Source;
   use type Model_Runner.CLI.Options.Text_Access;
   use type L.Pooling_Choice;
   use type Opt.Pooling_Kind;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;

   ---------------
   -- Do_Embed --
   ---------------

   --  Reduce a text to one vector.
   --
   --  What a model has made of everything it has read lives in the hidden
   --  state, and the output projection throws most of it away: two texts
   --  that mean the same thing leave similar states and quite different
   --  logits, because the logits say only how much each token is favoured
   --  next. This prints the state, pooled over the text's positions.
   --
   --  The prompt is read as written. No chat template is applied and none
   --  would be right: a template turns a text into a turn of a conversation,
   --  and an embedding is of the text.
   --
   --  Evaluated a token at a time rather than as a batch, because the state
   --  of every position is wanted and only the single-token path leaves one
   --  behind for each. For a prompt this is the same arithmetic either way.
   procedure Do_Embed
     (Item   : Opt.Command;
      Screen : in out Pres.Console;
      Status : out Natural)
   is
      Source    : Shards.Shard_Set;
      Container : Containers.Container;
      Prepared  : L.Model;
      Session   : L.Session;
      Prompt    : Opt.Text_Access := null;
      Condition : E.Error_Info;
      Ignored   : E.Error_Info;

      procedure Cleanup is
      begin
         L.Close (Session);
         L.Close (Prepared, Ignored);
         Containers.Close (Container);
         Shards.Close (Source);
         Free_Text (Prompt);
      end Cleanup;

      procedure Fail (Reason : E.Error_Info) is
      begin
         Pres.Report (Screen, Reason);
         Status := E.Exit_Status (Reason);
         Cleanup;
      end Fail;

      procedure Embed_With (Team : Workers_CPU.Pool_Reference) is
         --  For --show-stats: the tokens read, and since when.
         Watch    : Model_Runner.Clocks.System_Clock;
         Started  : Model_Runner.Clocks.Nanoseconds := 0;
         Read     : Natural := 0;

         --  What reading cost, as a run says its statistics, where asked.
         procedure Say_Statistics is
         begin
            if Item.Show_Stats then
               Pres.Put_Embedding_Statistics
                 (Screen, Read,
                  Model_Runner.Clocks.Elapsed (Started, Watch.Now),
                  Item.Backend,
                  (if Workers_CPU."=" (Team, null) then 1
                   else Positive (Workers_CPU.Worker_Total (Team.all)) + 1));
            end if;
         end Say_Statistics;
      begin
         Status := E.Exit_Success;

         Load (Item, Screen, Source, Container, Prepared, True, null, null,
               Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;
         Started := Watch.Now;

         --  The arithmetic, told to the backend before the session opens
         --  and therefore before anything is dispatched. The backend states
         --  that it must be told once and not part way through a run, which
         --  is why this is here and not a parameter of every product.
         Model_Runner.Backend.CPU.Use_Integer_Activations
           (L.Quantized_Roles (Chosen_Arithmetic (Item, Prepared)));

         L.Open
           (Session, Prepared, Item.Context_Size,
            Session_Bounds => Session_Bounds (Item),
            Workers => Team, Cache => Item.Cache, Status => Condition,
            Values => Item.Values, Paged => Session_Paging (Item));
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         Say_Device_Room (Screen, Session);

         case Item.Prompt_Kind is
            when Opt.Prompt_Inline =>
               Prompt := new String'(Item.Prompt_Text.all);

            when Opt.Prompt_File =>
               Read_File
                 (T.To_String (Item.Prompt_Path),
                  Model_Runner.Limits.Default_Session_Limits.Max_Prompt_Bytes,
                  Prompt, Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

            when others =>
               Read_Standard_Input
                 (Pres.Message_Value (Screen, "cli.label.standard_input"),
                  Model_Runner.Limits.Default_Session_Limits.Max_Prompt_Bytes,
                  Prompt, Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;
         end case;

         if Prompt = null or else Prompt.all'Length = 0 then
            Fail (E.Make (E.CLI_No_Prompt_Available));
            return;
         end if;

         if not Model_Runner.UTF8.Is_Valid (Prompt.all) then
            Fail (E.Make (E.IO_Invalid_UTF8));
            return;
         end if;

         declare
            Settings : constant L.Configuration := L.Config (Prepared);
            Width    : constant N.Element_Count :=
              N.Element_Count (Settings.Embedding);
            Words    : constant access constant Vocab.Vocabulary :=
              L.Vocabulary (Prepared);

            --  As long as the text can make, so a text longer than the model
            --  reads is told so below rather than refused by the tokenizer
            --  for a buffer it did not choose; on the heap, since a text
            --  may be megabytes.
            type Token_Room is access Vocab.Token_Array;
            procedure Free is
              new Ada.Unchecked_Deallocation (Vocab.Token_Array, Token_Room);
            --  Room for the query beside the text where a reranker joins the
            --  two: sized by the text alone, a pair whose document was short
            --  had its document cut off, and its score was the query's. A
            --  pair is two texts' tokens and as many as six markers -- a
            --  beginning, two ends, a separator and the lead a SentencePiece
            --  model puts before each text -- with room to spare.
            Held   : Token_Room :=
              new Vocab.Token_Array
                (1 .. Prompt.all'Length + 8
                      + (if Item.Query_Text = null then 0 else Item.Query_Text.all'Length));
            Count  : Natural;

            --  Empty where the model has no projection to a distribution,
            --  which is how a caller says they are not asking for one. A
            --  model that has one still produces the last position's, as it
            --  did: nothing here reads it, and refusing to compute it would
            --  be a second path through the evaluator for no gain.
            Logits : N.Real_Array
              (0 .. (if Settings.Has_Head
                     then N.Element_Count (Settings.Vocabulary) - 1
                     else -1));
            Pooled : N.Real_Array (0 .. Width - 1) := [others => 0.0];

            --  Which pooling this run uses. The caller's where they named
            --  one; otherwise the model's own, for the architecture that
            --  states it; otherwise the mean, as before.
            --  A reranker pools as the other runtime pools it: Qwen3's
            --  last position, the rest their first.
            Pooling : constant Opt.Pooling_Kind :=
              (if Item.Pooling_Named then Item.Pooling
               else (case Settings.Pooling is
                       when L.Pool_Cls  => Opt.Pool_Cls,
                       when L.Pool_Rank =>
                         (if Settings.Kind in L.Qwen3 | L.Qwen3_VL then Opt.Pool_Last
                          else Opt.Pool_Cls),
                       when L.Pool_Last => Opt.Pool_Last,
                       when others      => Opt.Pool_Mean));

            --  A reranker's own prompt for a pair, where its file carries
            --  one (Qwen3-Reranker's): the query and the document written
            --  into it, read with no markers added; empty for the rest.
            Rerank_Template : constant String :=
              Containers.String_Value
                (Container, "tokenizer.chat_template.rerank");

            --  Text with every Mark in it put by Value, as the other runtime
            --  writes a pair into a reranker's prompt (string_replace_all).
            function Fill (Text, Mark, Value : String) return String is
               At_Mark : constant Natural :=
                 (if Mark'Length = 0 then 0
                  else Ada.Strings.Fixed.Index (Text, Mark));
            begin
               if At_Mark = 0 then
                  return Text;
               end if;
               return Text (Text'First .. At_Mark - 1) & Value
                 & Fill (Text (At_Mark + Mark'Length .. Text'Last), Mark, Value);
            end Fill;

            --  Build the query/document pair a reranker scores, into Held
            --  and Count: <s> query </s></s> document </s> for the RoBERTa
            --  family, whose separator is its end marker; a [SEP] where a BERT
            --  has one. Sets Condition; leaves the pair for the caller to run.
            procedure Encode_Pair (Document : String) is
               use type Vocab.Token_Id;
               use type E.Error_Code;
               --  Each as long as its own text can make, and on the heap: a
               --  document list of megabytes gave two stack arrays its size
               --  for every document.
               Q_Room   : Token_Room;
               D_Room   : Token_Room;
               Q_Count, D_Count : Natural;
               Rule : constant Vocab.Pair_Rule := Vocab.Pair_Markers (Words.all);
               K : Natural := 0;

               --  A token past the room is refused, not dropped: dropped, it
               --  was the pair's last end marker, and the score was of a
               --  pair the model was not shown.
               procedure Put (Tok : Vocab.Token_Id) is
               begin
                  if Tok = Vocab.No_Token or else E.Is_Error (Condition) then
                     return;
                  elsif K < Held'Length then
                     K := K + 1;
                     Held (Held'First + K - 1) := Tok;
                  else
                     Condition := E.Make (E.Tokenizer_Buffer_Too_Small);
                  end if;
               end Put;

               --  A text's tokens into room of its own, grown where the
               --  normalizer made more of it than it was -- a charsmap
               --  writes U+FDFA as eighteen characters.
               procedure Encode_Text
                 (Text : String; Room : in out Token_Room; Count : out Natural)
               is
                  Size : Positive := Text'Length + 2;
               begin
                  Count := 0;
                  for Attempt in 1 .. 6 loop
                     Free (Room);
                     Room := new Vocab.Token_Array (1 .. Size);
                     Vocab.Encode (Words.all, Text, False, False,
                                   Room.all, Count, Condition);
                     exit when not (E.Is_Error (Condition)
                                    and then Condition.Code = E.Tokenizer_Buffer_Too_Small);
                     Size := Size * 4;
                  end loop;
               end Encode_Text;
            begin
               --  The file's own prompt for a pair, where it has one: the
               --  two written into it, and the whole read as text, its
               --  markers by name and none added.
               if Rerank_Template /= "" then
                  declare
                     Filled : constant String :=
                       Fill (Fill (Rerank_Template, "{query}",
                                   Item.Query_Text.all),
                             "{document}", Document);
                  begin
                     Encode_Text (Filled, D_Room, D_Count);
                     if E.Is_Error (Condition) then
                        Free (D_Room);
                        return;
                     end if;
                     if D_Count > Held'Length then
                        Free (Held);
                        Held := new Vocab.Token_Array (1 .. D_Count);
                     end if;
                     Held (1 .. D_Count) := D_Room (1 .. D_Count);
                     Count := D_Count;
                     Free (D_Room);
                     return;
                  end;
               end if;

               Encode_Text (Item.Query_Text.all, Q_Room, Q_Count);
               if E.Is_Error (Condition) then
                  Free (Q_Room);
                  return;
               end if;
               Encode_Text (Document, D_Room, D_Count);
               if E.Is_Error (Condition) then
                  Free (Q_Room);
                  Free (D_Room);
                  return;
               end if;

               --  The pair's room from what the two texts came to, where a
               --  normalizer made more of them than their bytes: a document
               --  of U+FDFA grew past the room its length gave.
               if Q_Count + D_Count + 6 > Held'Length then
                  Free (Held);
                  Held := new Vocab.Token_Array (1 .. Q_Count + D_Count + 6);
               end if;

               --  As the other runtime joins a pair where the file has no
               --  template for it (format_prompt_rerank), by the file's own
               --  flags: [CLS] q [SEP] d [SEP] for a BERT, whose end marker
               --  is its separator -- a [SEP] put beside it as well gave
               --  every BERT cross-encoder two -- and <s> q </s></s> d </s>
               --  for XLM-R, which asks for a separator too.
               if Rule.Begins then
                  Put (Rule.Beginning);
               end if;
               for I in 1 .. Q_Count loop
                  Put (Q_Room (I));
               end loop;
               if Rule.Ends then
                  Put (Rule.Ending);
               end if;
               if Rule.Separates then
                  Put (Rule.Separator);
               end if;
               for I in 1 .. D_Count loop
                  Put (D_Room (I));
               end loop;
               if Rule.Ends then
                  Put (Rule.Ending);
               end if;
               Count := K;
               Free (Q_Room);
               Free (D_Room);
            end Encode_Pair;

            --  Held to what the session reads: the first positions where the
            --  caller asked for that, with the end marker kept last where the
            --  model reads whole texts and was given one; said too long, with
            --  how many and what would take it, where not -- Fits false.
            procedure Fit (Fits : out Boolean) is
               --  What the session holds -- or, for a model that reads the
               --  text whole, what it was trained to read where that is
               --  less: the evaluator refuses past it, and a --context-size
               --  above it let --truncate cut to a length it then refused.
               Most : constant Natural :=
                 (if Settings.Causal or else Settings.Context_Length = 0
                  then L.Capacity (Session)
                  else Natural'Min (L.Capacity (Session),
                                    Settings.Context_Length));
            begin
               Fits := True;
               if Count > Most and then Most > 0 then
                  if Item.Truncate then
                     declare
                        use type Vocab.Token_Id;
                        Ended : constant Boolean :=
                          Vocab.Adds_End (Words.all)
                          and then Held (Count) = Vocab.End_Token (Words.all);
                     begin
                        Pres.Put_Note
                          (Screen, "cli.note.embed_truncated",
                           [Loc.Named ("value",
                                       T.Image (Long_Long_Integer (Most))),
                            Loc.Named ("total",
                                       T.Image (Long_Long_Integer (Count)))]);
                        if Ended then
                           Held (Most) := Held (Count);
                        end if;
                        Count := Most;
                     end;
                  else
                     Pres.Put_Note
                       (Screen, "cli.note.embed_too_long",
                        [Loc.Named ("value",
                                    T.Image (Long_Long_Integer (Most))),
                         Loc.Named ("total",
                                    T.Image (Long_Long_Integer (Count)))]);
                     Condition := E.Make (E.Arch_Context_Too_Large);
                     E.Add_Integer
                       (Condition, "requested", Long_Long_Integer (Count));
                     E.Add_Integer
                       (Condition, "maximum", Long_Long_Integer (Most));
                     Fits := False;
                  end if;
               end if;
            end Fit;
         begin
            --  A query beside a model that does not rank changes nothing:
            --  said, rather than a vector handed back to a caller who asked
            --  for scores.
            if Item.Query_Text /= null and then Settings.Pooling /= L.Pool_Rank
            then
               Pres.Put_Note (Screen, "cli.note.embed_query_unused");
            end if;

            --  A file that asks for no pooling asks for a vector a position,
            --  which this does not write: said, and the mean written.
            if not Item.Pooling_Named and then Settings.Pooling = L.Pool_None
            then
               Pres.Put_Note (Screen, "cli.note.embed_pooling_none");
            end if;

            --  Reranking a query against several documents in one load: where
            --  the prompt is more than one line, each line is a document, each
            --  scored against --query and its score printed in turn. A single
            --  document -- no line break -- falls through to the path below.
            if Item.Query_Text /= null
              and then Settings.Pooling = L.Pool_Rank
              and then (for some C of Prompt.all => C = ASCII.LF)
            then
               declare
                  First : Positive := Prompt.all'First;
               begin
                  while First <= Prompt.all'Last loop
                     declare
                        Stop : Natural := First;
                        --  The line's end, before a carriage return a list
                        --  written with CRLF puts there: read as the
                        --  document's last character, it moved its score.
                        Upto : Natural;
                     begin
                        while Stop <= Prompt.all'Last
                          and then Prompt.all (Stop) /= ASCII.LF
                        loop
                           Stop := Stop + 1;
                        end loop;
                        Upto := Stop - 1;
                        if Upto >= First and then Prompt.all (Upto) = ASCII.CR
                        then
                           Upto := Upto - 1;
                        end if;

                        --  An empty line is a document with no text: its
                        --  score is none, on its own line, so the scores
                        --  stay one a line beside the lines they score --
                        --  dropped, every score after it stood a line off.
                        --  The last line's end is not a document.
                        if Upto < First then
                           if Stop <= Prompt.all'Last then
                              Pres.Put_Line (Screen, "nan");
                           end if;
                        else
                           Encode_Pair (Prompt.all (First .. Upto));
                           if E.Is_Error (Condition) then
                              Free (Held);
                              Fail (Condition);
                              return;
                           end if;

                           --  Each pair held to the session as one text is:
                           --  cut where asked, else said too long on its own
                           --  line -- a score of none -- and the rest scored.
                           declare
                              Fits : Boolean;
                           begin
                              Fit (Fits);
                              if not Fits then
                                 Pres.Put_Line (Screen, "nan");
                                 Condition := E.Success;
                                 goto Next_Document;
                              end if;
                           end;

                           L.Rewind (Session, 0, Condition);
                           if E.Is_Error (Condition) then
                              Fail (Condition);
                              return;
                           end if;

                           declare
                              Room : Model_Runner.Tensors.Real_Array_Access :=
                                new N.Real_Array
                                  (0 .. N.Element_Count (Count) * Width - 1);
                              Score : N.Real;
                           begin
                              L.Evaluate_Batch
                                (Session, Prepared, Held (1 .. Count),
                                 Logits, States => Room, Status => Condition);
                              if E.Is_Error (Condition) then
                                 Free_Reals (Room);
                                 Fail (Condition);
                                 return;
                              end if;
                              Read := Read + Count;

                              --  Pooled as the single pair is, by the one
                              --  Pooling: its first position for a BERT
                              --  cross-encoder, its last for Qwen3's.
                              case Pooling is
                                 when Opt.Pool_Cls =>
                                    Pooled := Room.all (0 .. Width - 1);
                                 when Opt.Pool_Last =>
                                    Pooled :=
                                      Room.all
                                        (N.Element_Count (Count - 1) * Width
                                         .. N.Element_Count (Count) * Width - 1);
                                 when Opt.Pool_Mean =>
                                    Pooled := [others => 0.0];
                                    for Which in 0 .. N.Element_Count (Count) - 1
                                    loop
                                       for Element in Pooled'Range loop
                                          Pooled (Element) := Pooled (Element)
                                            + Room.all (Which * Width + Element);
                                       end loop;
                                    end loop;
                                    for Element in Pooled'Range loop
                                       Pooled (Element) :=
                                         Pooled (Element) / N.Real (Count);
                                    end loop;
                              end case;
                              Free_Reals (Room);

                              L.Rank (Session, Prepared, Pooled, Score,
                                      Condition);
                              if E.Is_Error (Condition) then
                                 Fail (Condition);
                                 return;
                              end if;
                              Pres.Put_Line
                                (Screen, T.Image (Long_Float (Score), 6));
                           end;
                        end if;

                        <<Next_Document>>
                        First := Stop + 1;
                     end;
                  end loop;
                  Free (Held);
                  Say_Statistics;
                  --  Closed as the single text's path closes it: returning
                  --  without, the model's file stayed open in the process,
                  --  and the next write of it was refused as shared.
                  Cleanup;
                  return;
               end;
            end if;
            if Item.Query_Text /= null
              and then Settings.Pooling = L.Pool_Rank
            then
               --  A reranker scores a query against a document. Join the two
               --  as the model was trained on: a beginning marker, the query,
               --  an end marker, a separator, the document, an end marker --
               --  <s> query </s></s> document </s> for the RoBERTa family,
               --  whose separator is its end marker; a BERT with a [SEP] of
               --  its own uses that between them.
               Encode_Pair (Prompt.all);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;
            else
               --  The markers the file asks for, at both ends, on any model,
               --  as the other runtime adds them: a decoder embedder pooled by
               --  its last position -- Qwen3-Embedding -- was trained with
               --  its end marker there, and pooled without it the vector was
               --  another one. Grown where the normalizer made more of the
               --  text than its bytes -- a charsmap writes U+FDFA as
               --  eighteen characters -- as the pair's texts are.
               for Attempt in 1 .. 6 loop
                  Vocab.Encode
                    (Words.all, Prompt.all, Vocab.Adds_Beginning (Words.all),
                     Vocab.Adds_End (Words.all),
                     Held.all, Count, Condition);
                  exit when not (E.Is_Error (Condition)
                                 and then E."=" (Condition.Code, E.Tokenizer_Buffer_Too_Small));
                  declare
                     Larger : constant Natural := 4 * Held'Length;
                  begin
                     Free (Held);
                     Held := new Vocab.Token_Array (1 .. Larger);
                  end;
               end loop;
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;
            end if;

            if Count = 0 then
               Free (Held);
               Fail (E.Make (E.CLI_No_Prompt_Available));
               return;
            end if;

            --  Longer than the session reads: cut, or refused (Fit).
            declare
               Fits : Boolean;
            begin
               Fit (Fits);
               if not Fits then
                  Free (Held);
                  Fail (Condition);
                  return;
               end if;
            end;

            --  In batches, as a prompt is read, because that is what the
            --  batched path is for: measured on this machine a matrix
            --  product over thirty-two vectors moves 1.87 times the
            --  elements a second that one at a time does, and a text to be
            --  embedded is exactly the shape that likes.
            --
            --  Pooling over the positions needs every position's state, and
            --  only the batched path has them all in hand at once; asking
            --  for them is what the States buffer is.
            declare
               --  How many positions go through the weights at once. A
               --  causal model may take the text in any batches it likes
               --  and get the same answer; one that attends both ways has
               --  to see the whole of it at once, so the batch is the text
               --  and --batch-size has nothing to say about it.
               Step : constant N.Element_Count :=
                 (if not Settings.Causal
                  then N.Element_Count (Count)
                  else N.Element_Count
                         (Natural'Min
                            (Natural'Max (1, Item.Batch_Size),
                             --  What one batched call of this model takes,
                             --  which the evaluator refuses past.
                             Natural'Min (L.Batch_Limit (Prepared),
                                          Model_Runner.Limits.Default_Session_Limits
                                            .Max_Batch))));

               Room : Model_Runner.Tensors.Real_Array_Access := null;
               From : Positive := 1;
            begin
               Room := new N.Real_Array (0 .. Step * Width - 1);

               while From <= Count loop
                  declare
                     Upto : constant Positive :=
                       Positive'Min (From + Natural (Step) - 1, Count);
                     Taken : constant N.Element_Count :=
                       N.Element_Count (Upto - From + 1);
                  begin
                     L.Evaluate_Batch
                       (Session, Prepared, Held (From .. Upto), Logits,
                        States => Room, Status => Condition);
                     if E.Is_Error (Condition) then
                        Free_Reals (Room);
                        Fail (Condition);
                        return;
                     end if;
                     Read := Read + Natural (Taken);

                     case Pooling is
                        when Opt.Pool_Mean =>
                           for Which in 0 .. Taken - 1 loop
                              for Element in Pooled'Range loop
                                 Pooled (Element) := Pooled (Element)
                                   + Room.all (Which * Width + Element);
                              end loop;
                           end loop;

                        when Opt.Pool_Last =>
                           if Upto = Count then
                              for Element in Pooled'Range loop
                                 Pooled (Element) :=
                                   Room.all ((Taken - 1) * Width + Element);
                              end loop;
                           end if;

                        --  The first position of the text, which is the
                        --  first position of the first batch and of no
                        --  other. A model pooled this way was trained with
                        --  a marker there and with that marker's state
                        --  standing for the whole.
                        when Opt.Pool_Cls =>
                           if From = 1 then
                              for Element in Pooled'Range loop
                                 Pooled (Element) := Room.all (Element);
                              end loop;
                           end if;
                     end case;

                     From := Upto + 1;
                  end;
               end loop;

               Free_Reals (Room);
            end;

            if Pooling = Opt.Pool_Mean then
               for Element in Pooled'Range loop
                  Pooled (Element) := Pooled (Element) / N.Real (Count);
               end loop;
            end if;

            if Settings.Pooling = L.Pool_Rank then
               --  A reranker scores rather than embeds: the pooled state
               --  through the head the model carries, to one number, which
               --  is how relevant the text is to what it was joined to.
               declare
                  Score  : N.Real;
                  Ranked : E.Error_Info;
               begin
                  L.Rank (Session, Prepared, Pooled, Score, Ranked);
                  if E.Is_Error (Ranked) then
                     Fail (Ranked);
                     return;
                  end if;
                  Pres.Put_Line (Screen, T.Image (Long_Float (Score), 6));
               end;
            else
               --  To unit length, unless the caller asked for the vector as
               --  it is. A vector of length zero stays as it is: there is no
               --  direction to scale it to, and dividing would produce
               --  not-a-number where the honest answer is what was computed.
               --  Divided by its norm, as the other runtime's
               --  common_embd_normalize divides it: the Euclidean length
               --  unasked, the largest magnitude scaled to sixteen-bit
               --  integers for nought, the p-norm for any other p.
               if Item.Normalize then
                  declare
                     Power : constant Natural := Item.Norm_Power;
                     Total : N.Wide_Real := 0.0;
                  begin
                     if Power = 0 then
                        for Element of Pooled loop
                           Total := N.Wide_Real'Max
                             (Total, abs N.Wide_Real (Element));
                        end loop;
                        Total := Total / 32_760.0;
                     elsif Power = 2 then
                        for Element of Pooled loop
                           Total := Total + N.Wide_Real (Element)
                             * N.Wide_Real (Element);
                        end loop;
                        Total := N.Sqrt (Total);
                     else
                        for Element of Pooled loop
                           if Element /= 0.0 then
                              Total := Total
                                + N.Exp (N.Wide_Real (Power)
                                         * N.Log (abs N.Wide_Real (Element)));
                           end if;
                        end loop;
                        if Total > 0.0 then
                           Total := N.Exp (N.Log (Total) / N.Wide_Real (Power));
                        end if;
                     end if;

                     --  A vector of length nought stays as it is: there is
                     --  no direction to scale it to.
                     if Total > 0.0 then
                        declare
                           Scale : constant N.Real := N.Real (1.0 / Total);
                        begin
                           for Element of Pooled loop
                              Element := Element * Scale;
                           end loop;
                        end;
                     end if;
                  end;
               end if;

               --  One component a line, so that the usual tools can read it.
               --  Through the plain line writer rather than the generated-
               --  text path, and that is safe here for the reason that path
               --  exists: what it guards against is a model's own bytes
               --  reaching a terminal, and these are digits, a sign and a
               --  point this program produced from a number.
               --  At the other runtime's precision: seven decimals, and none
               --  for the sixteen-bit scaling, whose components are whole.
               for Element of Pooled loop
                  Pres.Put_Line
                    (Screen,
                     T.Image (Long_Float (Element),
                              (if Item.Normalize and then Item.Norm_Power = 0
                               then 0 else 7)));
               end loop;
            end if;
         end;

         Say_Statistics;
         Cleanup;
      end Embed_With;
   begin
      --  Which backend reduces this text, which is the same choice the run
      --  command makes and was not made here at all: a device was selected,
      --  prepared against, and then never opened, so every embedding on a
      --  device was refused by the first product with a state error. One
      --  copy of a choice is one place to make it; two copies is one place
      --  to forget it, which is what happened.
      if Item.Device_Memory_Set
        and then Model_Runner.Backend."/=" (Item.Backend,
                                            Model_Runner.Backend.Backend_Device)
      then
         Pres.Put_Note (Screen, "cli.note.device_memory_unused");
      end if;

      case Item.Backend is
      when Model_Runner.Backend.Backend_Device =>
         declare
            Ready : Boolean;
         begin
            Model_Runner.Backend.Device.Open
              (Ready, Item.Device_Memory, Item.Device_Share,
               Patience => Item.Device_Patience,
               Which => Item.Device_Index);

            if not Ready then
               Fail (E.Make (E.Backend_No_Device));
               return;
            end if;

            Embed_With (null);
            Model_Runner.Backend.Device.Close;
         end;

      when Model_Runner.Backend.Backend_Reference =>
         Embed_With (null);

      when Model_Runner.Backend.Backend_CPU =>
         declare
            Wanted : constant Positive := Selected_Workers (Item);
         begin
            if Wanted = 1 then
               Embed_With (null);
            else
               declare
                  --  Declared here so that leaving the block waits for the
                  --  workers, as the run command's pool is.
                  Team : aliased Workers_CPU.Pool
                    (Workers_CPU.Worker_Count (Wanted));
               begin
                  Embed_With (Team'Unchecked_Access);
                  Workers_CPU.Close (Team);
               exception
                  when others =>
                     Workers_CPU.Close (Team);
                     raise;
               end;
            end if;
         end;
      end case;
   end Do_Embed;

end Model_Runner.CLI.Execute.Embed_Command;
