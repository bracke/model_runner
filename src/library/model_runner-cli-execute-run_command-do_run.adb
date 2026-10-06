separate (Model_Runner.CLI.Execute.Run_Command)
procedure Do_Run
  (Item    : Opt.Command;
   Screen  : in out Pres.Console;
   Catalog : Loc.Catalog;
   Status  : out Natural)
is
   pragma Unreferenced (Catalog);

   Source    : Shards.Shard_Set;
   Container : Containers.Container;
   Prepared  : aliased L.Model;
   Session   : L.Session;

   --  The prefill cache: a run reuses and rewrites one file per model,
   --  so a repeated prompt prefix is not read again -- unless the caller
   --  opts out, manages a session by hand, or the run is interactive or
   --  an agent's, which own their sessions. The file is keyed by the
   --  model and the settings a reused cache must match.
   Auto_Cache : constant Boolean :=
     not Item.No_Cache
     and then T.Is_Empty (Item.Load_Session)
     and then T.Is_Empty (Item.Save_Session)
     and then Item.Prompt_Kind /= Opt.Prompt_Interactive
     and then not Item.Agent;
   Cache_Path : constant String :=
     (if Auto_Cache
      then Model_Runner.Platform.Cache_File
             (Model_Runner.Platform.Resolve_Model_Path
                (Resolve_Alias (T.To_String (Item.Model_Path)))
              & "|" & L.Cache_Name (Item.Cache)
              & "|" & L.Value_Precision'Image (Item.Values)
              & "|" & Item.Context_Size'Image
              & "|" & L.Arithmetic_Mode'Image (Item.Arithmetic))
      else "");
   Load_Path : constant String :=
     (if not T.Is_Empty (Item.Load_Session)
      then Model_Runner.Platform.Resolve_Session_Path
             (T.To_String (Item.Load_Session), For_Saving => False)
      elsif Cache_Path /= ""
            and then Ada.Directories.Exists (Cache_Path)
      then Cache_Path
      else "");
   Save_Path : constant String :=
     (if not T.Is_Empty (Item.Save_Session)
      then Model_Runner.Platform.Resolve_Session_Path
             (T.To_String (Item.Save_Session), For_Saving => True)
      elsif Cache_Path /= "" then Cache_Path
      else "");

   --  Whether the load below adopted a cache, so the prompt reuses the
   --  prefix it shares with it.
   Prefix_Reused : Boolean := False;

   --  A second session on the same model, opened only for the agent's
   --  retrieve tool to embed with, so embedding a passage never disturbs
   --  the generation session's committed conversation.
   Embed_Session : aliased L.Session;

   Stop_Set  : aliased Model_Runner.Stops.Set;
   Sink      : aliased Pres.Standard_Output_Sink;
   Reporter  : aliased Pres.Progress_Reporter (Screen'Unchecked_Access);
   Told      : aliased Pres.Logprob_Reporter (Screen'Unchecked_Access);
   Told_File : aliased Pres.Logprob_File_Reporter;

   --  A second, smaller model proposing tokens for the first to check,
   --  when one was named. Held here so it outlives the generation.
   Draft_Source    : Shards.Shard_Set;
   Draft_Container : Containers.Container;
   Draft_Model     : aliased L.Model;
   Draft_Session   : aliased L.Session;
   Draft_Ready     : Boolean := False;

   --  The draft Drafts.Find found, when none was named, and whether the
   --  run drafts with it.
   Auto_Draft   : T.Bounded := T.Empty;
   Auto_Drafted : Boolean := False;

   --  A model loaded only to embed with, for the agent's retrieve tool,
   --  when --embed-model named one. Held here so it outlives the loop.
   Embed_Source    : Shards.Shard_Set;
   Embed_Container : Containers.Container;
   Embed_Model     : aliased L.Model;
   Embed_Model_Ready : Boolean := False;

   --  Whether a draft numbers its tokens as the target does: its
   --  vocabulary no longer than the target's, and the same text under
   --  every number both have, but for a few at the end of the draft's
   --  where one model has special tokens and the other has padding --
   --  Qwen2's small models against Qwen2.5's large ones, which pad to
   --  152,064. A proposal is a number, so any draft of no more numbers
   --  keeps the target's distribution; the text is what says whether it
   --  will ever be accepted.
   function Numbers_Alike
     (Draft, Target : L.Model) return Boolean
   is

      Drafts  : constant access constant Model_Runner.Tokenizer.Vocabulary :=
        L.Vocabulary (Draft);
      Targets : constant access constant Model_Runner.Tokenizer.Vocabulary :=
        L.Vocabulary (Target);
      Size    : constant Natural := L.Config (Draft).Vocabulary;
      Differ  : Natural := 0;
   begin
      if Size = L.Config (Target).Vocabulary then
         return True;
      elsif Size > L.Config (Target).Vocabulary
        or else Drafts = null or else Targets = null
      then
         return False;
      end if;

      for Id in 0 .. Natural'Min (Size, Model_Runner.Tokenizer.Size (Drafts.all))
                     - 1
      loop
         if Id >= Model_Runner.Tokenizer.Size (Targets.all)
           or else Model_Runner.Tokenizer.Token_Text
                     (Drafts.all, Model_Runner.Tokenizer.Token_Id (Id))
                   /= Model_Runner.Tokenizer.Token_Text
                     (Targets.all, Model_Runner.Tokenizer.Token_Id (Id))
         then
            Differ := Differ + 1;
         end if;
      end loop;

      return Model_Runner.Drafts.Alike_Enough (Differ, Size);
   end Numbers_Alike;

   --  Two models that do not number their tokens alike.
   function Draft_Mismatch (Draft, Wanted : Natural) return E.Error_Info is
      Result : E.Error_Info := E.Make (E.Arch_Unsupported_Feature);
   begin
      E.Add_Text (Result, "feature", "draft_vocabulary",
                  E.Param_Identifier);
      E.Add_Integer (Result, "actual", Long_Long_Integer (Draft));
      E.Add_Integer (Result, "expected", Long_Long_Integer (Wanted));
      return Result;
   end Draft_Mismatch;
   Clock     : aliased Model_Runner.Clocks.System_Clock;
   Seeds     : aliased Model_Runner.Entropy.Host_Source;
   Prompt    : Opt.Text_Access := null;

   --  The grammar the run must obey, when one was named. Held here so it
   --  outlives the generation that reads it.
   Rules       : aliased Model_Runner.Grammar.Compiled;
   Rules_Ready : Boolean := False;

   --  The tools offered to the model. Read before anything is generated,
   --  for the same reason a grammar is: an offer that will not parse is
   --  the caller's mistake and is worth finding before a model is asked
   --  to answer under it.
   Offered     : aliased Model_Runner.Tools.Definitions;
   Tools_Ready : Boolean := False;

   Cancel    : aliased Model_Runner.Cancellation.Token;
   Attached  : Boolean := False;
   Condition : E.Error_Info;
   Ignored   : E.Error_Info;
   Outcome   : Gen.Result;

   --  The pictures the conversation shows, encoded once for every
   --  prompt and step of the run: their rows, and the tokens that frame
   --  them. The projector is opened once a picture is named and kept,
   --  since a later turn may add one.
   Pictures  : Gen.Picture_Set;
   Seer      : Model_Runner.CLI.Pictures.Seer;

   procedure Cleanup is
   begin
      if Attached then
         Model_Runner.Platform.Signals.Remove;
         Attached := False;
      end if;
      Pres.Close (Told_File);
      Model_Runner.Framework.Execution.Watch (null);
      Model_Runner.Stops.Close (Stop_Set);
      Model_Runner.Grammar.Close (Rules);
      Rules_Ready := False;
      L.Close (Session);
      L.Close (Prepared, Ignored);
      Containers.Close (Container);
      Shards.Close (Source);
      if Embed_Model_Ready then
         L.Close (Embed_Model, Ignored);
         Containers.Close (Embed_Container);
         Shards.Close (Embed_Source);
         Embed_Model_Ready := False;
      end if;
      Gen.Release (Outcome);
      Model_Runner.CLI.Pictures.Release (Pictures);
      Model_Runner.CLI.Pictures.Close (Seer);
      Free_Text (Prompt);
   end Cleanup;

   --  Encode the pictures the conversation names that are not yet in
   --  Pictures, in the conversation's order: the ones the prompt's parts
   --  name, and the ones a checkpoint read back names. Nothing to do
   --  for a conversation naming none.
   procedure Gather_Pictures
     (Messages  : Conv.History;
      Team      : Workers_CPU.Pool_Reference;
      Condition : out E.Error_Info)
   is
      Named : Boolean := False;

      procedure Note
        (Index, Total : Positive; Rows, Milliseconds : Natural) is
      begin
         if Item.Level = Opt.Verbose then
            Pres.Put_Note
              (Screen, "cli.note.picture_encoded",
               [Loc.Named ("index", T.Image (Long_Long_Integer (Index))),
                Loc.Named ("total", T.Image (Long_Long_Integer (Total))),
                Loc.Named ("value", T.Image (Long_Long_Integer (Rows))),
                Loc.Named
                  ("count", T.Image (Long_Long_Integer (Milliseconds)))]);
         end if;
      end Note;
   begin
      Condition := E.Success;
      for Index in 1 .. Conv.Length (Messages) loop
         if Model_Runner.CLI.Pictures.Names_A_Picture
              (Conv.Parts_At (Messages, Index))
         then
            Named := True;
            exit;
         end if;
      end loop;
      if not Named then
         return;
      end if;

      if T.Is_Empty (Item.Projector_Path) then
         Condition := E.Make (E.CLI_Picture_Needs_Projector);
         E.Add_Text (Condition, "option", "--prompt-parts", E.Param_Identifier);
         E.Add_Text (Condition, "other", "--mmproj", E.Param_Identifier);
         return;
      end if;

      Model_Runner.Vision.Prefer_Exact
        (L."=" (Chosen_Arithmetic (Item, Prepared), L.Float_Activations));

      if not Model_Runner.CLI.Pictures.Is_Open (Seer) then
         Model_Runner.CLI.Pictures.Open
           (Seer, T.To_String (Item.Projector_Path), Prepared, Condition);
         if E.Is_Error (Condition) then
            return;
         end if;
      end if;

      Model_Runner.CLI.Pictures.Gather
        (Seer, Messages, Pictures, Team, Item.Pan_And_Scan,
         Cancel'Unchecked_Access, Note'Access, Condition);
   end Gather_Pictures;

   procedure Fail (Reason : E.Error_Info) is
   begin
      Pres.Report (Screen, Reason);
      Status := E.Exit_Status (Reason);
      Cleanup;
   end Fail;

   --  Everything from model loading onwards, parameterized by the worker
   --  pool so that the pool can be declared in a frame whose exit waits
   --  for its workers.

   procedure Run_With (Team : Workers_CPU.Pool_Reference) is separate;

   Team_Size : constant Natural := Selected_Workers (Item);

begin
   --  Which backend runs this. There is one, and going through the choice
   --  rather than around it is what makes --backend an option and not a
   --  word the parser accepts and forgets. The case has no others, so a
   --  kind added to the enumeration stops this compiling until something
   --  here answers for it -- which is the only way a second backend can
   --  arrive without the flag that selects it quietly doing nothing.
   --  Options that cannot do anything here say so rather than being
   --  accepted and forgotten.
   if Item.Device_Memory_Set
     and then Model_Runner.Backend."/=" (Item.Backend,
                                         Model_Runner.Backend.Backend_Device)
   then
      Pres.Put_Note (Screen, "cli.note.device_memory_unused");
   end if;

   --  Said for the same reason and in the same place: an option that
   --  changes nothing where it was given should say so rather than look
   --  as though it worked.
   if Item.Device_Patience_Set
     and then Model_Runner.Backend."/=" (Item.Backend,
                                         Model_Runner.Backend.Backend_Device)
   then
      Pres.Put_Note (Screen, "cli.note.device_patience_unused");
   end if;

   if Item.Device_Index_Set
     and then Model_Runner.Backend."/=" (Item.Backend,
                                         Model_Runner.Backend.Backend_Device)
   then
      Pres.Put_Note (Screen, "cli.note.device_unused");
   end if;

   case Item.Backend is
   when Model_Runner.Backend.Backend_Reference =>
      --  No pool: this backend runs on the calling task and says so.
      Run_With (null);

   when Model_Runner.Backend.Backend_Device =>
      --  A device instead of a pool. Opened here rather than at the first
      --  product so that a machine without one is told before a model is
      --  loaded: being refused after a minute of loading is being refused
      --  a minute late.
      declare
         Ready : Boolean;
      begin
         Model_Runner.Backend.Device.Open
           (Ready, Item.Device_Memory, Item.Device_Share,
            Patience => Item.Device_Patience,
            Which => Item.Device_Index);

         --  What the host offered, said once where a device was
         --  actually opened. The engine uses one queue; whether the
         --  family has more is a fact worth printing rather than a
         --  number only a test ever reads.
         if Ready and then Item.Show_Stats then
            Screen.Put_Message
              ("cli.note.device_queues",
               [Loc.Named
                  ("value",
                   Model_Runner.Text.Image
                     (Long_Long_Integer
                        (Model_Runner.Backend.Device.Queues)))]);
         end if;

         if not Ready then
            --  A condition of its own rather than a borrowed one. This
            --  used to report a missing capability with no capability
            --  named, and a message whose text names a parameter that is
            --  not there does not render at all: what a machine with no
            --  device got was the message key in angle brackets, which is
            --  the diagnostic for a diagnostic that failed.
            Fail (E.Make (E.Backend_No_Device));
            return;
         end if;

         --  A pool for the host loops a device run still has, made and
         --  waited for exactly as the processor's is below.
         if Team_Size <= 1 then
            Run_With (null);
         else
            declare
               Team : aliased Workers_CPU.Pool
                 (Workers_CPU.Worker_Count (Team_Size));
            begin
               Run_With (Team'Unchecked_Access);
               Workers_CPU.Close (Team);
            exception
               when others =>
                  Workers_CPU.Close (Team);
                  raise;
            end;
         end if;

         Model_Runner.Backend.Device.Close;
      end;

   when Model_Runner.Backend.Backend_CPU =>
      if Team_Size <= 1 then
         Run_With (null);
      else
         declare
            --  Declared here so that leaving this block waits for the workers
            --  to terminate; nothing is deallocated and no task outlives the
            --  command.
            Team : aliased Workers_CPU.Pool
              (Workers_CPU.Worker_Count (Team_Size));
         begin
            Run_With (Team'Unchecked_Access);
            Workers_CPU.Close (Team);
         exception
            --  The workers are told to stop before the exception leaves this
            --  block. Without this they are still waiting for work when the
            --  block is left, and leaving waits for them to terminate: the
            --  program stops responding instead of reporting what went wrong.
            --  That is not hypothetical -- an unsigned seed converted to a
            --  signed type raised here, and a verbose run with more than one
            --  worker hung rather than saying anything.
            when others =>
               Workers_CPU.Close (Team);
               raise;
         end;
      end if;
   end case;
end Do_Run;
