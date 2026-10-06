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
      begin
         Status := E.Exit_Success;

         Load (Item, Screen, Source, Container, Prepared, True, null, null,
               Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

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

            Tokens : Vocab.Token_Array
              (1 .. Model_Runner.Limits.Default_Session_Limits.Max_Batch);
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
            Pooling : constant Opt.Pooling_Kind :=
              (if Item.Pooling_Named then Item.Pooling
               else (case Settings.Pooling is
                       when L.Pool_Cls | L.Pool_Rank => Opt.Pool_Cls,
                       when L.Pool_Last => Opt.Pool_Last,
                       when others      => Opt.Pool_Mean));

            --  Build the query/document pair a reranker scores, into Tokens
            --  and Count: <s> query </s></s> document </s> for the RoBERTa
            --  family, whose separator is its end marker; a [SEP] where a BERT
            --  has one. Sets Condition; leaves the pair for the caller to run.
            procedure Encode_Pair (Document : String) is
               use type Vocab.Token_Id;
               Q_Tokens : Vocab.Token_Array (1 .. Tokens'Length);
               D_Tokens : Vocab.Token_Array (1 .. Tokens'Length);
               Q_Count, D_Count : Natural;
               Beginning : constant Vocab.Token_Id :=
                 Vocab.Beginning_Token (Words.all);
               Ending    : constant Vocab.Token_Id :=
                 Vocab.End_Token (Words.all);
               Sep       : constant Vocab.Token_Id :=
                 (if Vocab.Find (Words.all, "[SEP]") /= Vocab.No_Token
                  then Vocab.Find (Words.all, "[SEP]") else Ending);
               K : Natural := 0;

               procedure Put (Tok : Vocab.Token_Id) is
               begin
                  if Tok /= Vocab.No_Token and then K < Tokens'Length then
                     K := K + 1;
                     Tokens (Tokens'First + K - 1) := Tok;
                  end if;
               end Put;
            begin
               Vocab.Encode (Words.all, Item.Query_Text.all, False, False,
                             Q_Tokens, Q_Count, Condition);
               if E.Is_Error (Condition) then
                  return;
               end if;
               Vocab.Encode (Words.all, Document, False, False,
                             D_Tokens, D_Count, Condition);
               if E.Is_Error (Condition) then
                  return;
               end if;

               if Vocab.Adds_Beginning (Words.all) then
                  Put (Beginning);
               end if;
               for I in 1 .. Q_Count loop
                  Put (Q_Tokens (Q_Tokens'First + I - 1));
               end loop;
               Put (Ending);
               Put (Sep);
               for I in 1 .. D_Count loop
                  Put (D_Tokens (D_Tokens'First + I - 1));
               end loop;
               Put (Ending);
               Count := K;
            end Encode_Pair;
         begin
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
                     begin
                        while Stop <= Prompt.all'Last
                          and then Prompt.all (Stop) /= ASCII.LF
                        loop
                           Stop := Stop + 1;
                        end loop;

                        if Stop > First then
                           Encode_Pair (Prompt.all (First .. Stop - 1));
                           if E.Is_Error (Condition) then
                              Fail (Condition);
                              return;
                           end if;

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
                                (Session, Prepared, Tokens (1 .. Count),
                                 Logits, States => Room, Status => Condition);
                              if E.Is_Error (Condition) then
                                 Free_Reals (Room);
                                 Fail (Condition);
                                 return;
                              end if;

                              --  The CLS position stands for the pair; its
                              --  state through the head is the score.
                              Pooled := Room.all (0 .. Width - 1);
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

                        First := Stop + 1;
                     end;
                  end loop;
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
               --  The end marker where the model is one that reads whole texts
               --  and its file asks for one. Bert is trained with a marker at
               --  each end and its states are what they are because of them;
               --  a decoder's embedded text is not a finished utterance and
               --  takes none, which is what this did for every model before.
               Vocab.Encode
                 (Words.all, Prompt.all, Vocab.Adds_Beginning (Words.all),
                  not Settings.Causal and then Vocab.Adds_End (Words.all),
                  Tokens, Count, Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;
            end if;

            if Count = 0 then
               Fail (E.Make (E.CLI_No_Prompt_Available));
               return;
            end if;

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
                             Model_Runner.Limits.Default_Session_Limits
                               .Max_Batch)));

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
                       (Session, Prepared, Tokens (From .. Upto), Logits,
                        States => Room, Status => Condition);
                     if E.Is_Error (Condition) then
                        Free_Reals (Room);
                        Fail (Condition);
                        return;
                     end if;

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
               if Item.Normalize then
                  declare
                     Total : N.Wide_Real := 0.0;
                  begin
                     for Element of Pooled loop
                        Total := Total + N.Wide_Real (Element)
                          * N.Wide_Real (Element);
                     end loop;

                     if Total > 0.0 then
                        declare
                           Scale : constant N.Real :=
                             N.Real (1.0 / N.Sqrt (Total));
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
               for Element of Pooled loop
                  Pres.Put_Line (Screen, T.Image (Long_Float (Element), 6));
               end loop;
            end if;
         end;

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
