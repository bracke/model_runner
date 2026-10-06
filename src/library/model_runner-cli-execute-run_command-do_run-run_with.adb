separate (Model_Runner.CLI.Execute.Run_Command.Do_Run)
procedure Run_With (Team : Workers_CPU.Pool_Reference) is

   --  Why the first layer that did not go over whole did not, as a
   --  message key, or the empty string where every layer did.
   function Handed_Key return String is
   begin
      case Model_Runner.Backend.Device.First_Handing is
         when Model_Runner.Backend.Device.Not_Handed =>
            return "";
         when Model_Runner.Backend.Device.Shape_Handed =>
            return "statistics.handed.shape";
         when Model_Runner.Backend.Device.Packed_Handed =>
            return "statistics.handed.packed";
         when Model_Runner.Backend.Device.Cache_Handed =>
            return "statistics.handed.cache";
         when Model_Runner.Backend.Device.Blocks_Handed =>
            return "statistics.handed.blocks";
         when Model_Runner.Backend.Device.Room_Handed =>
            return "statistics.handed.room";
         when Model_Runner.Backend.Device.Refused_Handed =>
            return "statistics.handed.refused";
      end case;
   end Handed_Key;
begin
   Status := E.Exit_Success;

   --  Route an interrupt to a clean cancellation for the duration of the
   --  run. Loading and generation both observe it at bounded intervals.
   Model_Runner.Platform.Signals.Install (Cancel'Unchecked_Access, Attached);

   --  A command the harness runs for the session -- a check, a build --
   --  is stopped by the same interrupt.
   Model_Runner.Framework.Execution.Watch (Cancel'Unchecked_Access);

   --  Brain floats and an adapter are refused together rather than
   --  merged and rounded: what a merge adds is a small difference to
   --  every weight it touches, and eight mantissa bits is where a
   --  small difference goes.
   if not T.Is_Empty (Item.Adapter_Path)
     and then Item.Repack = L.To_BF16
   then
      Fail (E.Make (E.CLI_Conflicting_Prompt_Sources));
      return;
   end if;

   Load
     (Item, Screen, Source, Container, Prepared, True,
      Reporter'Unchecked_Access, Cancel'Unchecked_Access, Condition);
   if E.Is_Error (Condition) then
      Fail (Condition);
      return;
   end if;

   --  The adapter, merged into the weights before anything is
   --  generated. A merge is not a second set of weights carried
   --  alongside: what it costs is the load, and evaluation costs what
   --  it cost before.
   --  Every adapter, in the order it was given. A merge is an
   --  addition, so they stack; a scale of minus one subtracts, which
   --  is how one comes off again.
   for Which in 1 .. Item.Adapter_Count loop
      declare
         From   : Files.File_Source;
         Second : Containers.Container;

         --  The Nth scale belongs to the Nth adapter, and an adapter
         --  named without one is the adapter as it was trained.
         Scale : constant Model_Runner.Numerics.Real :=
           (if Which <= Item.Scale_Count
            then Item.Adapter_Scales (Which)
            else 1.0);
      begin
         Files.Open
           (From, T.To_String (Item.Adapters (Which)),
            Status => Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         Containers.Reader.Parse (Second, From, Status => Condition);
         if E.Is_Error (Condition) then
            Files.Close (From);
            Fail (Condition);
            return;
         end if;

         L.Merge_Adapter
           (Prepared, Second, From, Scale, Condition);

         Containers.Close (Second);
         Files.Close (From);

         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;
      end;
   end loop;

   --  A model that cannot say what comes next cannot be run. Refused
   --  here rather than at the first evaluation, so that a caller who
   --  asked the wrong command of the right model is told before a
   --  session, a cache and a worker pool are built for a generation
   --  that is not going to happen. `embed` is what such a model is
   --  for, and saying so is more use than the code alone.
   if not L.Config (Prepared).Has_Head then
      declare
         Refusal : E.Error_Info := E.Make (E.Arch_No_Output_Head);
      begin
         E.Add_Text
           (Refusal, "architecture",
            L.Architecture_Name (L.Config (Prepared).Kind),
            E.Param_Identifier);
         Fail (Refusal);
         return;
      end;
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

   --  An option that cannot do anything here says so rather than
   --  being accepted and forgotten -- and whether it can is known only
   --  now, once the model has said whether it carries a next-token
   --  block that drafts on its own.
   if Item.Draft_Tokens_Set
     and then T.Is_Empty (Item.Draft_Path)
     and then not Item.Draft_Lookup
     and then not L.Drafts_Next (Session)
   then
      Pres.Put_Note (Screen, "cli.note.draft_tokens_unused");
   end if;

   --  A draft model, when one was named: a second, smaller model that
   --  proposes what it would say next so that this one can check
   --  several tokens in a single pass over its weights.
   --
   --  Loaded exactly as the model was, with the same limits and the
   --  same refusals. What is checked here is the one thing that makes
   --  two models comparable at all: a proposal is a token identifier,
   --  so two models that number their tokens differently would be
   --  agreeing about numbers rather than about text.
   --  And where none was named and nothing else would draft -- a
   --  dense model of Next_Draft_Bytes a token or more, with no block
   --  past its stack -- a draft out of the model store or the
   --  model's own folder, when one there numbers its tokens as this
   --  one does; see Drafts.Find. Found, it is said so
   --  and loaded as a named one is; one that will not load or open
   --  leaves the run to draft as it would have without it, since
   --  nobody asked for it.
   --  A draft the model names beside itself comes first, whatever
   --  the rest says: someone chose it. See Drafts.Paired.
   if T.Is_Empty (Item.Draft_Path)
     and then not Item.Draft_Lookup
     and then Item.Draft_Tokens > 0
     and then L.Vocabulary (Prepared) /= null
   then
      Auto_Draft :=
        T.To_Bounded
          (Model_Runner.Drafts.Paired
             (Model_Runner.Platform.Resolve_Model_Path
                (Resolve_Alias (T.To_String (Item.Model_Path))),
              Model_Runner.Platform.Models_Directory));
   end if;

   if T.Is_Empty (Item.Draft_Path)
     and then T.Is_Empty (Auto_Draft)
     and then not Item.Draft_Lookup
     and then not Item.Draft_Tokens_Set
     and then Item.Draft_Tokens > 0
     and then L.Config (Prepared).Experts = 0
     and then not L.Drafts_Next (Session)
     and then L.Token_Bytes (Prepared) >= Next_Draft_Bytes
     and then L.Vocabulary (Prepared) /= null
   then
      --  In the store, and beside the model: a folder of models kept
      --  by hand is where the small one of a family usually is.
      declare
         Model_File : constant String :=
           Model_Runner.Platform.Resolve_Model_Path
             (Resolve_Alias (T.To_String (Item.Model_Path)));
         Beside : constant String :=
           Ada.Directories.Containing_Directory
             (Ada.Directories.Full_Name (Model_File));
         In_Store : constant String :=
           Model_Runner.Drafts.Find
             (Model_Runner.Platform.Models_Directory, Model_File,
              Container, L.Vocabulary (Prepared).all);
         Near : constant String :=
           Model_Runner.Drafts.Find
             (Beside, Model_File, Container,
              L.Vocabulary (Prepared).all);

         function Bytes (Path : String) return Long_Long_Integer
         is (if Path = "" then 0
             else Long_Long_Integer (Ada.Directories.Size (Path)));
      begin
         Auto_Draft :=
           T.To_Bounded
             (if Bytes (Near) > Bytes (In_Store) then Near
              else In_Store);
      end;
   end if;

   if not T.Is_Empty (Item.Draft_Path)
     or else not T.Is_Empty (Auto_Draft)
   then
      declare
         Asked : constant Boolean := not T.Is_Empty (Item.Draft_Path);
      begin
         Load (Item, Screen, Draft_Source, Draft_Container, Draft_Model,
               True, null, Cancel'Unchecked_Access, Condition,
               Instead =>
                 (if Asked then T.To_String (Item.Draft_Path)
                  else T.To_String (Auto_Draft)));

         if Asked and then E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         --  A draft's head at four bits: what it proposes is
         --  checked token by token, so this changes how many are
         --  taken and never what the run writes. A head that will
         --  not go is left as the file has it.
         if E.Is_Ok (Condition) then
            declare
               Lighter : E.Error_Info;
            begin
               L.Lighten_Head
                 (Draft_Model,
                  Model_Runner.Platform.Core_Count, Lighter);
            end;
         end if;

         if Asked and then not Numbers_Alike (Draft_Model, Prepared)
         then
            Fail (Draft_Mismatch (L.Config (Draft_Model).Vocabulary,
                                  L.Config (Prepared).Vocabulary));
            return;
         end if;

         --  The same worker pool. A draft that runs serial while the
         --  model it drafts for runs across seven workers is a draft
         --  paying seven times what it should for every proposal, and
         --  the run measures as though drafting were hopeless when
         --  what was hopeless was the arrangement. The two never
         --  evaluate at once -- a round proposes, then checks -- so
         --  one pool serves both.
         if E.Is_Ok (Condition)
           and then (Asked or else Numbers_Alike (Draft_Model, Prepared))
         then
            L.Open
              (Draft_Session, Draft_Model, Item.Context_Size,
               Session_Bounds => Session_Bounds (Item),
               Workers => Team, Cache => Item.Cache, Status => Condition,
               Values => Item.Values, Paged => Session_Paging (Item));
            if E.Is_Error (Condition) and then Asked then
               Fail (Condition);
               return;
            end if;

            Draft_Ready := E.Is_Ok (Condition);
         end if;

         if not Asked then
            Condition := E.Success;
            Auto_Drafted := Draft_Ready;
            if Draft_Ready then
               Pres.Put_Note
                 (Screen, "cli.note.draft_from_store",
                  [Loc.Named
                     ("model",
                      Ada.Directories.Simple_Name
                        (T.To_String (Auto_Draft)))]);
            end if;
         end if;
      end;
   end if;

   --  A model to embed with for the agent's retrieve tool, loaded like
   --  any other and used on its own session. It need not number its
   --  tokens like the model being run -- it only reads text and reports
   --  a vector -- so, unlike the draft, no vocabulary check is due.
   if Item.Agent and then not T.Is_Empty (Item.Embed_Model_Path) then
      Load (Item, Screen, Embed_Source, Embed_Container, Embed_Model,
            True, null, Cancel'Unchecked_Access, Condition,
            Instead => T.To_String (Item.Embed_Model_Path));
      if E.Is_Error (Condition) then
         Fail (Condition);
         return;
      end if;
      Embed_Model_Ready := True;
   end if;

   --  A schema is a grammar written in another notation, so it
   --  becomes one here and everything below treats it as one. The
   --  parser has already refused a caller who named both.
   if Item.Schema_Text /= null
     or else not T.Is_Empty (Item.Schema_Path)
   then
      declare
         Text : Opt.Text_Access := null;

         Written : String (1 .. Model_Runner.Schema.Max_Grammar_Bytes);
         Last    : Natural;
      begin
         if Item.Schema_Text /= null then
            Text := new String'(Item.Schema_Text.all);
         else
            Read_File
              (T.To_String (Item.Schema_Path),
               Model_Runner.Schema.Max_Schema_Bytes, Text, Condition);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;
         end if;

         Model_Runner.Schema.To_Grammar
           (Text.all, Written, Last, Condition);
         Free_Text (Text);

         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         Model_Runner.Grammar.Compile
           (Rules, Written (1 .. Last), Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         Rules_Ready := True;
      end;
   end if;

   --  The grammar, before anything is generated. A grammar that will
   --  not compile is the caller's mistake and is worth finding before
   --  a model is asked to produce anything under it.
   if Item.Grammar_Text /= null
     or else not T.Is_Empty (Item.Grammar_Path)
   then
      declare
         Text : Opt.Text_Access := null;
      begin
         if Item.Grammar_Text /= null then
            Text := new String'(Item.Grammar_Text.all);
         else
            Read_File
              (T.To_String (Item.Grammar_Path),
               Model_Runner.Limits.Default_Session_Limits
                 .Max_Prompt_Bytes,
               Text, Condition);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;
         end if;

         Model_Runner.Grammar.Compile (Rules, Text.all, Condition);
         Free_Text (Text);

         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         Rules_Ready := True;
      end;
   end if;

   --  The tools, and the one question worth asking about them: does
   --  this model's template have anywhere to put them. A model told
   --  about no tools answers as though there were none, which looks
   --  from the outside like a model that chose not to call one.
   if Item.Tools_Text /= null
     or else not T.Is_Empty (Item.Tools_Path)
   then
      declare
         Text : Opt.Text_Access := null;
      begin
         if Item.Tools_Text /= null then
            Text := new String'(Item.Tools_Text.all);
         else
            Read_File
              (T.To_String (Item.Tools_Path),
               Model_Runner.Tools.Max_Definition_Bytes, Text,
               Condition);
            if E.Is_Error (Condition) then
               Fail (Condition);
               return;
            end if;
         end if;

         Model_Runner.Tools.Read (Offered, Text.all, Condition);
         Free_Text (Text);

         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         if not L.Template_Ready (Prepared) then
            Fail (L.Template_Condition (Prepared));
            return;
         end if;

         if not Model_Runner.Templates.Reads_Tools
                  (L.Template (Prepared).all)
         then
            Condition := E.Make (E.Tools_Not_In_Template);
            Fail (Condition);
            return;
         end if;

         Tools_Ready := True;
      end;
   end if;

   --  A saved session, before the prompt is looked at. What it fills
   --  is the cache and the history, which is exactly what the prompt
   --  would otherwise have to be read to produce; the generation then
   --  keeps whatever of it the prompt agrees with and re-reads only
   --  the rest.
   --
   --  A restore that fails ends the run. It was asked for, and going
   --  on without it would silently do the slow thing after being told
   --  to do the fast one.
   if Load_Path /= "" then
      declare
         --  The auto cache is tolerant: a stale or unreadable one is
         --  no failure, only a prompt read in full. An explicit
         --  session was asked for and its failure ends the run.
         Auto : constant Boolean :=
           Cache_Path /= "" and then Load_Path = Cache_Path;
         Kept : Files.File_Source;
      begin
         Files.Open (Kept, Load_Path, Status => Condition);
         if E.Is_Error (Condition) then
            if not Auto then
               Fail (Condition);
               return;
            end if;
         else
            declare
               Length : constant Model_Runner.Bytes.Byte_Count :=
                 Files.Size (Kept);
               Room   : Model_Runner.Bytes.Byte_Array_Access;
            begin
               Model_Runner.Bytes.Allocate (Length, Room);
               if Room = null then
                  Files.Close (Kept);
                  if not Auto then
                     Fail (E.Make (E.Memory_Allocation_Failed));
                     return;
                  end if;
               else
                  Files.Read (Kept, 0, Room.all, Condition);
                  Files.Close (Kept);

                  if E.Is_Ok (Condition) then
                     L.Adopt (Session, Prepared, Room.all, Condition);
                  end if;

                  Model_Runner.Bytes.Free (Room);

                  if E.Is_Error (Condition) then
                     if not Auto then
                        Fail (Condition);
                        return;
                     end if;
                  else
                     Prefix_Reused := True;
                  end if;
               end if;
            end;
         end if;
      exception
         when others =>
            --  A cache that raised while being adopted is no failure
            --  either: the prompt is read in full. An explicit
            --  --load-session still faults.
            if not Auto then
               raise;
            end if;
            Prefix_Reused := False;
      end;
   end if;

   --  Interactive mode owns its own loop; it needs the same prepared model
   --  and session, so it is entered here rather than earlier.
   if Item.Prompt_Kind = Opt.Prompt_Interactive then
      Model_Runner.CLI.Interactive.Run
        (Item, Screen, Prepared, Session,
         (if Rules_Ready then Rules'Unchecked_Access else null),
         (if Tools_Ready then Offered'Unchecked_Access else null),
         Status, Cancel'Unchecked_Access);
      Cleanup;
      return;
   end if;

   --  Agent mode owns its loop too. It closes the tool loop the
   --  single run leaves open: the model's calls are run and the
   --  answers fed back until it answers. Without --tool-command the
   --  tools are the built-in ones and any --tools is ignored; with
   --  --tool-command the tools are the caller's, offered through
   --  --tools or --tools-file and run by handing each call to that
   --  program.
   if Item.Agent then
      if Item.Raw then
         Fail (E.Make (E.CLI_Conflicting_Prompt_Sources));
         return;
      end if;
      if not L.Template_Ready (Prepared) then
         Fail (L.Template_Condition (Prepared));
         return;
      end if;

      declare
         Messages     : aliased Conv.History;
         Agent_Tools  : aliased Model_Runner.Tools.Definitions;
         Built_Runner : aliased Model_Runner.Tools.Builtin.Instance;
         Cmd_Runner   : aliased Command_Runner (Item.Tool_Command);
         Request      : aliased Gen.Request;
         Watcher      : aliased Agent_Watch
           (Screen'Unchecked_Access,
            Trace => not T.Is_Empty (Item.Trace_File_Path),
            Log   => Messages'Access);
         --  An aliased copy so the approver can point at the guardrail
         --  rules; only their values are read, never the shared prompts.
         Rules_Copy   : aliased constant Opt.Command := Item;
         Confirmer    : aliased Policy_Approver
                          (Screen'Unchecked_Access,
                           Rules_Copy'Unchecked_Access);
         --  Asks the user a question for the ask_user tool.
         Asker        : aliased Console_Inquirer
                          (Screen'Unchecked_Access);
         --  Embed with the dedicated model when one was loaded, else
         --  with the model being run.
         Embedder     : aliased Model_Embedder
           ((if Embed_Model_Ready then Embed_Model'Access
             else Prepared'Access),
            Embed_Session'Access);
         Embed_Open   : Boolean := False;

         --  Sessions apart from the run's own, on which delegated
         --  subtasks run their sub-agents, so the run's loop is
         --  undisturbed. Their context is the run's, or a bounded
         --  default when the run left the context to the model, so a
         --  second session does not double an unbounded one. One when
         --  the loop runs calls one at a time or the backend evaluates
         --  one session at a time (the device backend); otherwise a
         --  small pool, so several subtasks may run at once.
         Sub_Ready    : Natural := 0;
         Sub_Context  : constant Natural :=
           (if Item.Context_Size = 0 then 8192 else Item.Context_Size);
         Sub_Count    : constant Positive :=
           (if Item.Max_Parallel > 1
              and then Model_Runner.Backend."/="
                         (Item.Backend,
                          Model_Runner.Backend.Backend_Device)
            then Positive'Min (Item.Max_Parallel, 4)
            else 1);
         --  A shared pool is safe only when one session evaluates at a
         --  time; when several run at once each session computes on its
         --  own worker task instead (null), which the processor backends
         --  allow.
         Sub_Workers  : constant Model_Runner.Backend.CPU.Pool_Reference :=
           (if Sub_Count > 1 then null else Team);
         Delegate_Runner : aliased Model_Delegator
           (Src    => Prepared'Access,
            Req    => Request'Access,
            Stops  => Stop_Set'Access,
            Time   => Clock'Unchecked_Access,
            Seed   => Seeds'Unchecked_Access,
            Steps  => Positive'Max (1, Item.Max_Steps),
            Budget => Item.Max_Total_Tokens,
            Count  => Sub_Count);

         --  The schema the final answer must match, from --json-schema
         --  or --json-schema-file, or null for a free-text answer.
         Answer : Opt.Text_Access := null;

         Using_Command : constant Boolean :=
           Item.Tool_Command /= null
           and then Item.Tool_Command.all /= "";

         --  One place the loop runs from, whichever tools and runner
         --  it was given.
         procedure Drive
           (Off  : Model_Runner.Tools.Definitions;
            Exec : in out Model_Runner.Tools.Runner.Instance'Class)
         is
            Loop_Out : Model_Runner.Agent.Outcome;
         begin
            --  Checkpoint at the close of each step, when one was asked
            --  for, so an interrupted run is resumable too.
            Watcher.Checkpoint :=
              US.To_Unbounded_String
                (T.To_String (Item.Checkpoint_File_Path));

            --  In groups, as /work is: the run, then how it came out.
            Pres.Put_Heading (Screen, "cli.work.section.run", Pres.Diagnostic);
            Model_Runner.Agent.Run
              (Source     => Prepared,
               Session    => Session,
               Messages   => Messages,
               Offered    => Off,
               Executor   => Exec,
               Generation => Request,
               Pictures   => Pictures,
               Stop_Set   => Stop_Set,
               Sink       => Sink'Unchecked_Access,
               Time       => Clock'Unchecked_Access,
               Seeds      => Seeds'Unchecked_Access,
               Max_Steps  => Positive'Max (1, Item.Max_Steps),
               Thinking   => Item.Thinking,
               Watch      => Watcher'Unchecked_Access,
               Approve    =>
                 (if Item.Confirm_Tools
                    or else Item.Deny_Tool_Count > 0
                    or else Item.Deny_Arg_Count > 0
                  then Confirmer'Unchecked_Access
                  else null),
               Max_Retries => Item.Max_Retries,
               Max_Total_Tokens => Item.Max_Total_Tokens,
               Max_Parallel => Positive'Max (1, Item.Max_Parallel),
               --  The loop reads calls in the shape the format the
               --  model renders with writes them -- the one named on
               --  the command line, or the one that stood in for a
               --  template that would not compile.
               --  Where that is the JSON envelope, the bare or fenced
               --  object too, as a session's /work reads it: models
               --  asked for a call often write it without the envelope.
               Tool_Syntax =>
                 (if Model_Runner.Tools."="
                       (Model_Runner.Templates.Syntax_Of (L.Template_Format (Prepared)),
                        Model_Runner.Tools.Tool_Call_JSON)
                  then Model_Runner.Tools.Open_JSON
                  else Model_Runner.Templates.Syntax_Of (L.Template_Format (Prepared))),
               Compact     => Item.Compact,
               Answer_Schema =>
                 (if Answer /= null then Answer.all else ""),
               Result     => Loop_Out);

            Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Output);
            Pres.Put_Heading (Screen, "cli.work.section.outcome", Pres.Diagnostic, Gap => True);

            --  The calls and their results were shown as they happened
            --  by the watcher; here only the outcome is left to note --
            --  a clean answer, a stop short of one, or a failure.
            Pres.Put_Agent_Outcome
              (Screen,
               State => Model_Runner.Agent.Stop_Reason'Image
                          (Loop_Out.Reason),
               Steps => Loop_Out.Steps,
               Calls => Loop_Out.Calls,
               Result =>
                 (case Loop_Out.Reason is
                    when Model_Runner.Agent.Answered =>
                      Pres.Answered_Well,
                    when Model_Runner.Agent.Step_Limit
                       | Model_Runner.Agent.Timed_Out
                       | Model_Runner.Agent.Token_Limit
                       | Model_Runner.Agent.Repeating
                       | Model_Runner.Agent.Declined =>
                      Pres.Stopped_Short,
                    when others => Pres.Failed));

            Status := E.Exit_Success;
            if Loop_Out.Reason /= Model_Runner.Agent.Answered
              and then E.Is_Error (Loop_Out.Error)
            then
               Pres.Report (Screen, Loop_Out.Error);
               Status := E.Exit_Status (Loop_Out.Error);
            end if;

            --  Write the run's trace, if one was asked for: the calls
            --  and results the watcher recorded, wrapped in the run's
            --  tally. Best effort -- a trace that will not write does
            --  not fail the run.
            if Watcher.Trace then
               declare
                  File : Ada.Text_IO.File_Type;
                  function N (V : Natural) return String
                  is (T.Image (Long_Long_Integer (V)));
               begin
                  Ada.Text_IO.Create
                    (File, Ada.Text_IO.Out_File,
                     T.To_String (Item.Trace_File_Path));
                  Ada.Text_IO.Put (File,
                     "{""model"":""" & JSON_Escape
                       (T.To_String (Item.Model_Path))
                     & """,""reason"":"""
                     & Model_Runner.Agent.Stop_Reason'Image
                         (Loop_Out.Reason)
                     & """,""steps"":" & N (Loop_Out.Steps)
                     & ",""calls"":" & N (Loop_Out.Calls)
                     & ",""retries"":" & N (Loop_Out.Retries)
                     & ",""generated_tokens"":"
                     & N (Loop_Out.Generated_Tokens)
                     & ",""prompt_tokens"":" & N (Loop_Out.Prompt_Tokens)
                     & ",""compactions"":" & N (Loop_Out.Compactions)
                     & ",""elapsed_ms"":" & Elapsed_Ms (Watcher)
                     & ",""events"":[" & US.To_String (Watcher.Events)
                     & "]}");
                  Ada.Text_IO.Close (File);
               exception
                  when others =>
                     if Ada.Text_IO.Is_Open (File) then
                        Ada.Text_IO.Close (File);
                     end if;
               end;
            end if;
         end Drive;
      begin
         if not Model_Runner.Templates.Reads_Tools
                  (L.Template (Prepared).all)
         then
            Fail (E.Make (E.Tools_Not_In_Template));
            return;
         end if;

         --  A tool command with nothing to describe is a program the
         --  model was never told about; the definitions come from
         --  --tools or --tools-file.
         if Using_Command and then not Tools_Ready then
            declare
               Reason : E.Error_Info := E.Make (E.CLI_Option_Combination);
            begin
               E.Add_Text
                 (Reason, "option", "--tool-command",
                  E.Param_Identifier);
               E.Add_Text
                 (Reason, "other", "--tools or --tools-file",
                  E.Param_Identifier);
               Fail (Reason);
            end;
            return;
         end if;

         --  The prompt: the first one given, resolved as the run path
         --  resolves it.
         case Item.Prompt_Kind is
            when Opt.Prompt_Inline =>
               Prompt := new String'(Item.Prompts (1).all);

            when Opt.Prompt_Parts =>
               Prompt := new String'
                 (Conv.Text_Of_Parts (Item.Prompt_Parts_Text.all));

            when Opt.Prompt_File =>
               Read_File
                 (T.To_String (Item.Prompt_Path),
                  Model_Runner.Limits.Default_Session_Limits
                    .Max_Prompt_Bytes,
                  Prompt, Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

            when others =>
               Read_Standard_Input
                 (Pres.Message_Value (Screen, "cli.label.standard_input"),
                  Model_Runner.Limits.Default_Session_Limits
                    .Max_Prompt_Bytes,
                  Prompt, Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;
         end case;

         --  A prompt of parts may be all picture and no words; the
         --  parts are its content, and their list is checked where
         --  it is appended.
         if Prompt = null
           or else (Prompt.all'Length = 0
                    and then Item.Prompt_Kind /= Opt.Prompt_Parts)
         then
            Fail (E.Make (E.CLI_No_Prompt_Available));
            return;
         end if;
         if not Model_Runner.UTF8.Is_Valid (Prompt.all) then
            Fail (E.Make (E.IO_Invalid_UTF8));
            return;
         end if;

         Conv.Open (Messages, Status => Condition);
         if E.Is_Error (Condition) then
            Fail (Condition);
            return;
         end if;

         --  Resume from a checkpoint that holds a conversation, else
         --  start fresh with the system message; either way the prompt
         --  is the next user turn -- the task on a fresh run, a
         --  follow-up on a resumed one.
         declare
            Ckpt     : constant String :=
              T.To_String (Item.Checkpoint_File_Path);
            Resuming : constant Boolean :=
              Ckpt /= "" and then Ada.Directories.Exists (Ckpt);
            Loaded   : Boolean := False;
         begin
            if Resuming then
               Model_Runner.CLI.Checkpoint.Load
                 (Ckpt, Messages, Loaded, Condition);
               if E.Is_Error (Condition) then
                  Conv.Close (Messages);
                  Fail (Condition);
                  return;
               end if;
            end if;
            if not Loaded
              and then Item.Has_System
              and then Item.System_Text /= null
            then
               Conv.Set_System
                 (Messages, Item.System_Text.all, Condition);
            end if;
            if Item.Prompt_Kind = Opt.Prompt_Parts then
               Conv.Append_Parts
                 (Messages, Conv.User_Role,
                  Item.Prompt_Parts_Text.all, Condition);
            else
               Conv.Append
                 (Messages, Conv.User_Role, Prompt.all, Condition);
            end if;
            if E.Is_Ok (Condition) then
               Gather_Pictures (Messages, Team, Condition);
            end if;
            if E.Is_Error (Condition) then
               Conv.Close (Messages);
               Fail (Condition);
               return;
            end if;
         end;

         Request.Sampling := Item.Sampling;
         Request.Max_Tokens := Item.Max_Tokens;
         Request.Seed := Item.Seed;
         Request.Has_Seed := Item.Has_Seed;
         Request.Batch_Size := Item.Batch_Size;

         --  A JSON schema, if one was named, becomes the shape the
         --  final answer must take: --json-schema means the whole
         --  output on a plain run, and the answer of an agent run.
         if Item.Schema_Text /= null then
            Answer := new String'(Item.Schema_Text.all);
         elsif not T.Is_Empty (Item.Schema_Path) then
            Read_File
              (T.To_String (Item.Schema_Path),
               Model_Runner.Schema.Max_Schema_Bytes, Answer, Condition);
            if E.Is_Error (Condition) then
               Conv.Close (Messages);
               Fail (Condition);
               return;
            end if;
         end if;

         --  A system prompt for the sub-agents a delegate spawns, read
         --  from a file where one was named; the built-in one stands
         --  otherwise. Set on the runner before the loop, so every
         --  sub-agent it opens is opened with it.
         if not T.Is_Empty (Item.Delegate_System_Path) then
            Read_File
              (T.To_String (Item.Delegate_System_Path),
               Model_Runner.Limits.Default_Session_Limits
                 .Max_Prompt_Bytes,
               Delegate_Runner.System_Text, Condition);
            if E.Is_Error (Condition) then
               Conv.Close (Messages);
               Fail (Condition);
               return;
            end if;
         end if;

         --  The caller's tools run by the named program, or the
         --  built-in ones. Either way the loop is the same; only what
         --  it offers and what runs a call differ.
         if Using_Command then
            Drive (Offered, Cmd_Runner);
         else
            Model_Runner.Tools.Read
              (Agent_Tools,
               Model_Runner.Tools.Builtin.All_Definitions_Text,
               Condition);
            if E.Is_Error (Condition) then
               Conv.Close (Messages);
               Fail (Condition);
               return;
            end if;

            --  Offered only what can run: a denied tool is not
            --  advertised, and an agent the harness started is given
            --  its file tools and, where it may, the network -- not a
            --  program, a memory or a calculator it never needs.
            declare
               Harnessed : constant Boolean :=
                 Ada.Environment_Variables.Exists
                   (Model_Runner.Framework.Permissions.Agent_Root_Variable);
               Named_Grants : constant String :=
                 Model_Runner.Framework.Permissions.Agent_Permissions_Variable;
               Granted   : constant String :=
                 (if Ada.Environment_Variables.Exists (Named_Grants)
                  then Ada.Environment_Variables.Value (Named_Grants)
                  else "");
               Kept      : Ada.Strings.Unbounded.Unbounded_String;
               Dropped   : Boolean := False;

               function Offered_Here (Named : String) return Boolean is
               begin
                  for I in 1 .. Item.Deny_Tool_Count loop
                     if Named = T.To_String (Item.Deny_Tools (I)) then
                        return False;
                     end if;
                  end loop;
                  return not Harnessed
                    or else Named in "read_file" | "list_directory" | "write_file"
                    or else (Named in "http_get" | "web_search"
                             and then Ada.Strings.Fixed.Index (Granted, "use_network") > 0);
               end Offered_Here;
            begin
               for Index in 1 .. Model_Runner.Tools.Count (Agent_Tools) loop
                  if Offered_Here (Model_Runner.Tools.Tool_Name (Agent_Tools, Index)) then
                     Ada.Strings.Unbounded.Append
                       (Kept, (if Ada.Strings.Unbounded.Length (Kept) = 0 then "" else ", ")
                              & Model_Runner.Tools.Definition (Agent_Tools, Index));
                  else
                     Dropped := True;
                  end if;
               end loop;
               if Dropped then
                  Model_Runner.Tools.Close (Agent_Tools);
                  Model_Runner.Tools.Read
                    (Agent_Tools, "[" & Ada.Strings.Unbounded.To_String (Kept) & "]", Condition);
                  if E.Is_Error (Condition) then
                     Conv.Close (Messages);
                     Fail (Condition);
                     return;
                  end if;
               end if;
            end;

            --  Open the embedding session -- on the dedicated model
            --  when one was loaded, else on the model being run -- and
            --  give it to retrieve, so it ranks a folder's passages by
            --  meaning. If it will not open, retrieve stays lexical --
            --  the run goes on either way. A small context is enough:
            --  one short text at a time.
            if Embed_Model_Ready then
               L.Open
                 (Embed_Session, Embed_Model, 512,
                  Session_Bounds => Session_Bounds (Item),
                  Workers => Team, Cache => Item.Cache,
                  Values => Item.Values,
                  Status => Condition);
            else
               L.Open
                 (Embed_Session, Prepared, 512,
                  Session_Bounds => Session_Bounds (Item),
                  Workers => Team, Cache => Item.Cache,
                  Values => Item.Values,
                  Status => Condition);
            end if;
            if E.Is_Ok (Condition) then
               Embed_Open := True;
               Built_Runner.Use_Embedder (Embedder'Unchecked_Access);
            end if;

            --  Open the sub-agent sessions and give the delegate tool a
            --  delegator. Open as many as will -- a second session most
            --  often fails for want of memory -- and stop at the first
            --  that does not; the ones that opened are leasable. With
            --  none, delegate declines and the run goes on with the
            --  other tools; with one, delegation runs one subtask at a
            --  time; with more, subtasks overlap.
            for I in 1 .. Sub_Count loop
               L.Open
                 (Delegate_Runner.Sessions (I), Prepared, Sub_Context,
                  Session_Bounds => Session_Bounds (Item),
                  Workers => Sub_Workers, Cache => Item.Cache,
                  Values => Item.Values,
                  Status => Condition);
               exit when E.Is_Error (Condition);
               Sub_Ready := Sub_Ready + 1;
            end loop;
            Delegate_Runner.Leases.Open (Sub_Ready);
            Delegate_Runner.Ready := Sub_Ready;
            if Sub_Ready >= 1 then
               Built_Runner.Use_Delegator
                 (Delegate_Runner'Unchecked_Access);
            end if;

            --  The run has a console, so ask_user can put a question to
            --  the user; an end of input is answered as no answer.
            Built_Runner.Use_Inquirer (Asker'Unchecked_Access);

            --  Back memory with a file when one was named, so what the
            --  run writes with memory_put is there for a later run.
            if not T.Is_Empty (Item.Memory_File_Path) then
               Built_Runner.Use_Memory_File
                 (T.To_String (Item.Memory_File_Path));
            end if;

            Drive (Agent_Tools, Built_Runner);

            if Embed_Open then
               L.Close (Embed_Session);
            end if;
            for I in 1 .. Sub_Ready loop
               L.Close (Delegate_Runner.Sessions (I));
            end loop;
         end if;

         --  Checkpoint the conversation so a later run can take it up.
         if not T.Is_Empty (Item.Checkpoint_File_Path) then
            Model_Runner.CLI.Checkpoint.Save
              (T.To_String (Item.Checkpoint_File_Path), Messages);
         end if;

         Free_Text (Answer);
         Conv.Close (Messages);
      end;

      Cleanup;
      return;
   end if;

   --  One sequence per prompt, from the one loaded model. Between
   --  them the session goes back to nothing: each prompt is its own
   --  conversation, and a second prompt continuing the first would be
   --  a different program.
   for Which in 1 .. Natural'Max (1, Item.Prompt_Count) loop

      if Which > 1 then
         L.Reset (Session);

         --  Which prompt this is, on standard error, so that a reader of
         --  the generated text can tell where one answer ends. Nothing
         --  goes to standard output but what the model produced.
         Pres.Put_Note
           (Screen, "cli.note.next_prompt",
            [Loc.Named ("index", T.Image (Long_Long_Integer (Which))),
             Loc.Named
               ("total",
                T.Image (Long_Long_Integer (Item.Prompt_Count)))]);
      end if;

      --  Resolve the prompt.
      case Item.Prompt_Kind is
         when Opt.Prompt_Inline =>
            Prompt := new String'(Item.Prompts (Which).all);

         when Opt.Prompt_Parts =>
            Prompt := new String'
              (Conv.Text_Of_Parts (Item.Prompt_Parts_Text.all));

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

      --  A prompt of parts may be all picture and no words; the parts
      --  are its content, and their list is checked where it is
      --  appended.
      if Prompt = null
        or else (Prompt.all'Length = 0
                 and then Item.Prompt_Kind /= Opt.Prompt_Parts)
      then
         Fail (E.Make (E.CLI_No_Prompt_Available));
         return;
      end if;

      if not Model_Runner.UTF8.Is_Valid (Prompt.all) then
         Fail (E.Make (E.IO_Invalid_UTF8));
         return;
      end if;

      --  Build the text that will actually be tokenized. Raw mode sends the
      --  prompt unchanged; conversation mode renders it through the model's
      --  own template and fails rather than guessing when that is unusable.
      declare
         Rendered : Opt.Text_Access := null;

         procedure Release_Rendered is
         begin
            Free_Text (Rendered);
         end Release_Rendered;
      begin
         if Item.Raw then
            Rendered := new String'(Prompt.all);
         else
            if not L.Template_Ready (Prepared) then
               Fail (L.Template_Condition (Prepared));
               return;
            end if;

            declare
               Messages : Conv.History;
               --  The render buffer is bounded by the session limit and is
               --  allocated rather than declared: the limit is large enough
               --  that a stack object of that size would not fit.
               Buffer   : Opt.Text_Access :=
                 new String
                   (1 .. Model_Runner.Limits.Default_Session_Limits
                           .Max_Rendered_Bytes);
               Last     : Natural;
               Words    : constant access constant Vocab.Vocabulary :=
                 L.Vocabulary (Prepared);
            begin
               Conv.Open (Messages, Status => Condition);
               if E.Is_Error (Condition) then
                  Fail (Condition);
                  return;
               end if;

               if Item.Has_System then
                  declare
                     System_Text : Opt.Text_Access := null;
                  begin
                     null;
                     if Item.System_Text /= null then
                        System_Text := new String'(Item.System_Text.all);
                     else
                        Read_File
                          (T.To_String (Item.System_Path),
                           Model_Runner.Limits.Default_Session_Limits
                             .Max_Prompt_Bytes,
                           System_Text, Condition);
                        if E.Is_Error (Condition) then
                           Conv.Close (Messages);
                           Fail (Condition);
                           return;
                        end if;
                     end if;

                     Conv.Append
                       (Messages, Conv.System_Role, System_Text.all, Condition);
                     Free_Text (System_Text);
                     if E.Is_Error (Condition) then
                        Free_Text (Buffer);
                        Conv.Close (Messages);
                        Fail (Condition);
                        return;
                     end if;
                  end;
               end if;

               if Item.Developer_Text /= null then
                  Conv.Append
                    (Messages, Conv.Developer_Role,
                     Item.Developer_Text.all, Condition);
                  if E.Is_Error (Condition) then
                     Free_Text (Buffer);
                     Conv.Close (Messages);
                     Fail (Condition);
                     return;
                  end if;
               end if;

               if Item.Prompt_Kind = Opt.Prompt_Parts then
                  Conv.Append_Parts
                    (Messages, Conv.User_Role,
                     Item.Prompt_Parts_Text.all, Condition);
               else
                  Conv.Append
                    (Messages, Conv.User_Role, Prompt.all, Condition);
               end if;
               if E.Is_Error (Condition) then
                  Free_Text (Buffer);
                  Conv.Close (Messages);
                  Fail (Condition);
                  return;
               end if;

               --  And the turns that follow it, in the order they
               --  were given: this is how one run closes the loop
               --  another opened. A reply is taken apart into what
               --  the model said and what it asked for, so a caller
               --  hands back the reply it was printed and this reads
               --  the calls out of it -- rather than the caller
               --  taking the reply apart and this trusting the
               --  pieces.
               for Turn in 1 .. Item.Turn_Count loop
                  declare
                     Spoken  : Opt.Text_Access := null;
                     Reading : E.Error_Info;
                  begin
                     if Item.Turn_Texts (Turn) /= null then
                        Spoken :=
                          new String'(Item.Turn_Texts (Turn).all);
                     else
                        Read_File
                          (T.To_String (Item.Turn_Paths (Turn)),
                           Model_Runner.Limits.Default_Session_Limits
                             .Max_Prompt_Bytes,
                           Spoken, Condition);
                     end if;

                     if E.Is_Ok (Condition) then
                        if Opt."=" (Item.Turn_Kinds (Turn),
                                    Opt.Turn_Tool)
                        then
                           Conv.Append
                             (Messages, Conv.Tool_Role, Spoken.all,
                              Condition);
                        elsif Opt."=" (Item.Turn_Kinds (Turn),
                                       Opt.Turn_Tool_Parts)
                        then
                           Conv.Append_Parts
                             (Messages, Conv.Tool_Role, Spoken.all,
                              Condition);
                        elsif Opt."=" (Item.Turn_Kinds (Turn),
                                       Opt.Turn_Assistant_Parts)
                        then
                           Conv.Append_Parts
                             (Messages, Conv.Assistant_Role, Spoken.all,
                              Condition);
                        elsif Tools_Ready then
                           Conv.Append_Reply
                             (Messages, Spoken.all, Condition, Reading);
                           if E.Is_Error (Reading) then
                              Pres.Report (Screen, Reading);
                           end if;
                        else
                           Conv.Append
                             (Messages, Conv.Assistant_Role, Spoken.all,
                              Condition);
                        end if;
                     end if;

                     Free_Text (Spoken);

                     if E.Is_Error (Condition) then
                        Free_Text (Buffer);
                        Conv.Close (Messages);
                        Fail (Condition);
                        return;
                     end if;
                  end;
               end loop;

               Gather_Pictures (Messages, Team, Condition);
               if E.Is_Error (Condition) then
                  Free_Text (Buffer);
                  Conv.Close (Messages);
                  Fail (Condition);
                  return;
               end if;

               Model_Runner.Templates.Render
                 (L.Template (Prepared).all, Messages,
                  Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
                  Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
                  True, Buffer.all, Last, Condition,
                  Thinking => Item.Thinking,
                  Tools =>
                    (if Tools_Ready
                     then Offered'Unchecked_Access else null),
                  Image_Marker =>
                    Model_Runner.CLI.Pictures.Picture_Marker (Seer),
                  Video_Marker =>
                    Model_Runner.CLI.Pictures.Video_Marker (Seer));
               Conv.Close (Messages);

               if E.Is_Error (Condition) then
                  Free_Text (Buffer);
                  Fail (Condition);
                  return;
               end if;

               Rendered := new String'(Buffer.all (1 .. Last));
               Free_Text (Buffer);

               --  Said here because here is where it happens. Generation is
               --  handed a prompt that is already rendered and never sees
               --  the conversation it came from, so the stage it declares
               --  for this could only ever be published by its caller --
               --  and was published by nobody.
               Model_Runner.Progress.Publish
                 (Reporter'Unchecked_Access,
                  Model_Runner.Progress.Generation_Progress
                    (Model_Runner.Progress.Prompt_Rendered,
                     Interfaces.Unsigned_64 (Last)));
            end;
         end if;

         --  Stop conditions.
         Model_Runner.Stops.Open (Stop_Set);
         for Index in 1 .. Item.Stop_Count loop
            Model_Runner.Stops.Add_String
              (Stop_Set, T.To_String (Item.Stop_Strings (Index)), Condition);
            if E.Is_Error (Condition) then
               Release_Rendered;
               Fail (Condition);
               return;
            end if;
         end loop;

         for Index in 1 .. Item.Stop_Token_Count loop
            Model_Runner.Stops.Add_Token
              (Stop_Set, Vocab.Token_Id (Item.Stop_Tokens (Index)), Condition);
            if E.Is_Error (Condition) then
               Release_Rendered;
               Fail (Condition);
               return;
            end if;
         end loop;

         --  The file the reports go to, made once a run: every prompt's
         --  tokens one after another in it.
         if not T.Is_Empty (Item.Logprobs_Path)
           and then not Ada.Text_IO.Is_Open (Told_File.File)
         then
            declare
               Made : Boolean;
            begin
               Pres.Open (Told_File, T.To_String (Item.Logprobs_Path),
                          Made);
               if not Made then
                  Condition := E.Make (E.IO_Open_Failed);
                  E.Add_Text
                    (Condition, "path", T.To_String (Item.Logprobs_Path),
                     E.Param_Path);
                  Release_Rendered;
                  Fail (Condition);
                  return;
               end if;
            end;
         end if;

         --  A rendered conversation already carries the beginning token, so
         --  the tokenizer must not add a second one.
         declare
            Request : Gen.Request;
         begin
            Request.Max_Tokens := Item.Max_Tokens;
            for Index in 1 .. Item.Bias_Count loop
               Request.Bias_Tokens (Index) :=
                 Model_Runner.Tokenizer.Token_Id
                   (Item.Bias_Tokens (Index));
               Request.Bias_Amounts (Index) := Item.Bias_Amounts (Index);
            end loop;

            Request.Bias_Count := Item.Bias_Count;
            --  A file of reports asked for without a count gets twenty
            --  a token: what a draft is taught from wants more than a
            --  reader does.
            Request.Logprobs :=
              (if Item.Logprobs = 0
                 and then not T.Is_Empty (Item.Logprobs_Path)
               then 20 else Item.Logprobs);
            Request.Context_Shift := Item.Context_Shift;
            Request.Context_Keep := Item.Context_Keep;
            --  Without a draft model or a lookup, a model that carries
            --  a next-token block drafts from that, asked or not: the
            --  block exists for nothing else, the text is the same
            --  with it as without, and the round is a gain on every
            --  file it has been measured on. --draft-tokens 0 is how
            --  a caller turns it off; generation itself leaves it
            --  unused where it cannot apply, which is any sampling
            --  but greedy and any run under a grammar.
            --
            --  Unless a draft costs too much of a token to pay: the
            --  block and the head over the stack and the head, which
            --  is 0.19 on Qwen3.5-4B, where three proposals a round
            --  read 13.3 -> 17.4 tokens a second sampling, and 0.38
            --  on the 0.8B, whose head is a third of the file and
            --  where one proposal a round already reads 57 -> 52 --
            --  and a model whose token reads less than Next_Draft_
            --  Bytes, whose token is its fixed costs: with its draft
            --  reading a slice of the head the 0.8B's share is a
            --  ninth, and it still reads 49 -> 39 at one proposal. A
            --  --draft-tokens named is taken as asked. Three a round
            --  unless named: four read 15.5 on the 4B and six 14.0,
            --  the proposals past the third kept too rarely to pay
            --  for the block's pass.
            Request.Draft_From_Next :=
              Item.Draft_Tokens > 0
              and then not Draft_Ready
              and then not Item.Draft_Lookup
              and then L.Drafts_Next (Session)
              and then (Item.Draft_Tokens_Set
                        or else (L.Draft_Share (Prepared)
                                   <= Next_Draft_Share
                                 and then L.Token_Bytes (Prepared)
                                          >= Next_Draft_Bytes));
            --  The block's proposals read a slice of the head, at
            --  four bits for that alone.
            if Request.Draft_From_Next then
               declare
                  Lighter : E.Error_Info;
               begin
                  L.Lighten_Draft_Head
                    (Prepared, Model_Runner.Platform.Core_Count,
                     Lighter);
               end;
            end if;

            Request.Draft_Tokens :=
              (if Request.Draft_From_Next
                 and then not Item.Draft_Tokens_Set
               then Next_Draft_Tokens
               elsif Auto_Drafted then Store_Draft_Tokens
               --  A named draft model starts where a found one does
               --  unless a length was named: three, then adapting.
               --  Started at four it was slower on every pair
               --  measured.
               elsif Draft_Ready and then not Item.Draft_Tokens_Set
               then Store_Draft_Tokens
               elsif Draft_Ready or else Item.Draft_Lookup
                 or else Request.Draft_From_Next
               then Item.Draft_Tokens else 0);
            Request.Draft_From_Context :=
              Item.Draft_Lookup and then not Draft_Ready;

            --  A draft model's rounds follow what the rounds before
            --  kept, unless a length was named.
            Request.Draft_Adapts :=
              Draft_Ready and then not Item.Draft_Tokens_Set;

            --  And where nothing drafts, a dense model large enough
            --  that a round pays drafts out of its own context: what
            --  followed this phrase the last time it was said. A
            --  phrase not said before proposes nothing and costs
            --  nothing, and a reply that repeats its context -- an
            --  edit to code, a summary, a quotation -- is where it
            --  pays: gemma-3-4b editing a function 20.8 -> 31.8
            --  tokens a second, qwen3-8b 12.7 -> 13.9, and prose
            --  within a few per cent either way. Not a mixture: its
            --  check of several positions reads several tokens'
            --  experts, and Qwen3-Coder-30B lost 9 and 15 per cent.
            --  Nor on the processor, where checking several positions
            --  costs several positions' arithmetic and a phrase seen
            --  before is too seldom what follows to pay for it: phi3
            --  kept 4 to 8 per cent of what the text proposed and lost
            --  5 per cent writing code and 2 writing prose. A draft
            --  named, or a --draft-tokens, decides instead.
            if not Request.Draft_From_Context
              and then not Request.Draft_From_Next
              and then not Draft_Ready
              and then not Item.Draft_Tokens_Set
              and then Item.Draft_Tokens > 0
              and then L.Config (Prepared).Experts = 0
              and then L.Token_Bytes (Prepared) >= Next_Draft_Bytes
              and then not Model_Runner.Backend."="
                             (L.Capability (Prepared).Kind,
                              Model_Runner.Backend.Backend_CPU)
            then
               Request.Draft_From_Context := True;
               Request.Draft_Tokens := Item.Draft_Tokens;
            end if;

            Request.Sampling := Item.Sampling;
            Request.Seed := Item.Seed;
            Request.Has_Seed := Item.Has_Seed;
            --  A backend that does not batch is asked for one token at
            --  a time rather than refused. The capability decides the
            --  request instead of failing it, which is what a capability
            --  is for; --batch-size is a performance control and this is
            --  the performance the chosen backend has.
            Request.Batch_Size :=
              (if L.Capability (Prepared).Supports_Batched
               then Item.Batch_Size
               else 1);

            if not L.Capability (Prepared).Supports_Batched
              and then Item.Batch_Size /= 1
              and then Item.Level = Opt.Verbose
            then
               Pres.Warn
                 (Screen, "warning.backend_no_batching",
                  [Loc.Named
                     ("value",
                      Model_Runner.Backend.Backend_Name
                        (L.Capability (Prepared).Kind))]);
            end if;
            --  What was generated is kept only where something here
            --  reads it back: the calls a reply asks for are read out
            --  of the reply, and a run that offered no tools has
            --  nothing to read.
            Request.Retain_Text := Tools_Ready;

            --  Who puts the beginning token in front.
            --
            --  With --raw there is no template, so nothing else can: the
            --  request asks for one and the vocabulary decides whether it
            --  wants one, which Generation checks.
            --
            --  With a template the template does it. It is handed the
            --  beginning token's own text and writes it where the model
            --  expects it, which for some models is not the front -- and
            --  the tokenizer turns that spelling back into the one token
            --  it stands for. Asking here as well would put two in front
            --  of a model that wants one, and a marker that model did not
            --  ask for moves a logit by nearly two.
            --
            --  What follows from that: a model whose template writes no
            --  beginning token gets none, whatever its add_bos_token
            --  says. That is the template's answer and this defers to it,
            --  because the template is the part that knows where in the
            --  rendered text the token belongs.
            Request.Add_Beginning := Item.Raw;

            --  Keep what the restored cache and the prompt agree on. The
            --  session already holds a conversation; this is what makes
            --  restoring it worth anything, and where they diverge the
            --  engine resets and reads the prompt as it would have.
            Request.Reuse_Committed_Prefix := Prefix_Reused;

            --  What the last prompt retained goes before this one
            --  begins: Generate starts from an empty result and would
            --  otherwise leave the previous run's text behind, once
            --  per prompt, for as many prompts as were given.
            Gen.Release (Outcome);
            Gen.Generate
              (Source   => Prepared,
               Session  => Session,
               Prompt   => Rendered.all,
               Item     => Request,
               Stop_Set => Stop_Set,
               Rules    =>
                 (if Rules_Ready then Rules'Unchecked_Access else null),
               Sink     => Sink'Unchecked_Access,
               Observer => Reporter'Unchecked_Access,
               Time     => Clock'Unchecked_Access,
               Seeds    => Seeds'Unchecked_Access,
               Cancel   => Cancel'Unchecked_Access,
               Draft    =>
                 (if Draft_Ready then Draft_Model'Unchecked_Access
                  else null),
               Draft_Session =>
                 (if Draft_Ready then Draft_Session'Unchecked_Access
                  else null),
               Reporter =>
                 (if not T.Is_Empty (Item.Logprobs_Path)
                  then Told_File'Unchecked_Access
                  elsif Item.Logprobs > 0
                  then Told'Unchecked_Access
                  else null),
               Pictures => Pictures,
               Outcome  => Outcome);
         end;

         Release_Rendered;
      end;

      if Outcome.Reason = Gen.Runtime_Error then
         Fail (Outcome.Error);
         return;
      end if;

      --  A run the reader interrupted did not succeed, and said so with
      --  a zero. Cancelled is not Runtime_Error, so it fell through to
      --  Exit_Success and a script around this program was told the
      --  generation had finished normally -- while `help` promises "7
      --  cancelled" and the error table maps MR-GEN-0006 to seven.
      --
      --  Reported through the same path as any other refusal, so the
      --  status is the table's answer rather than a second one written
      --  here. Cancellation during loading already came out this way;
      --  only cancellation during generation did not.
      if Outcome.Reason = Gen.Cancelled then
         Fail (E.Make (E.Generation_Cancelled));
         return;
      end if;

      --  What the reply asked for, read out of it and shown. The
      --  reply itself has already gone to standard output; this goes
      --  to standard error with the rest of the diagnostics, so a
      --  redirected run still holds only what the model wrote -- and
      --  the caller who has to hand an answer back is told what was
      --  asked rather than left to find it in the text.
      if Tools_Ready then
         declare
            Asked   : Model_Runner.Tools.Calls;
            Reading : E.Error_Info;
         begin
            Model_Runner.Tools.Read_Calls
              (Asked, Gen.Generated_Text (Outcome), Reading);
            if E.Is_Error (Reading) then
               Pres.Report (Screen, Reading);
            end if;

            for Index in 1 .. Model_Runner.Tools.Count (Asked) loop
               declare
                  Named : constant String :=
                    Model_Runner.Tools.Called (Asked, Index);
               begin
                  Pres.Put_Note
                    (Screen, "cli.run.tool_call",
                     [Loc.Named ("name", Named),
                      Loc.Named
                        ("arguments",
                         Model_Runner.Tools.Arguments (Asked, Index))]);

                  if not Model_Runner.Tools.Offers (Offered, Named) then
                     Pres.Put_Note
                       (Screen, "cli.run.tool_unknown",
                        [Loc.Named ("name", Named)]);
                  end if;
               end;
            end loop;
            Model_Runner.Tools.Close (Asked);
         end;
      end if;

      --  And the context out, when it was asked for. After the run
      --  rather than before it, because what is worth saving is the
      --  prompt and the reply together: the next run continues from
      --  where this one stopped.
      if Save_Path /= "" then
         declare
            --  Writing the auto cache is tolerant: the run already
            --  produced its answer, so a snapshot or write that fails
            --  costs the next run a cache, not this run its output.
            Auto : constant Boolean :=
              Cache_Path /= "" and then Save_Path = Cache_Path;
            Room : Model_Runner.Bytes.Byte_Array_Access;
         begin
            L.Snapshot (Session, Prepared, Room, Condition);
            if E.Is_Error (Condition) then
               if not Auto then
                  Fail (Condition);
                  return;
               end if;
            else
               Model_Runner.Platform.Ensure_Parent_Directory (Save_Path);
               Write_File (Save_Path, Room.all, Condition);
               Model_Runner.Bytes.Free (Room);

               if E.Is_Error (Condition) and then not Auto then
                  Fail (Condition);
                  return;
               end if;
            end if;
         exception
            when others =>
               --  The auto cache breaks nothing: a snapshot or write
               --  that raised costs the next run a cache, not this one
               --  its answer. An explicit --save-session still faults.
               if not Auto then
                  raise;
               end if;
         end;
      end if;

      --  Statistics go to standard error, so a redirected standard output
      --  still contains only generated text.
      if Item.Show_Stats
        or else (not Item.Stats_Set and then Item.Level = Opt.Verbose)
      then
         --  With what the device did, when a device did it.
         if Model_Runner.Backend."=" (Item.Backend,
                                       Model_Runner.Backend.Backend_Device)
         then
            Pres.Put_Statistics
              (Screen, Outcome,
               Device         => Model_Runner.Backend.Device.Name,
               Resident       => Model_Runner.Backend.Device.Resident,
               Resident_Limit =>
                 Model_Runner.Backend.Device.Resident_Limit,
               Imported       => Model_Runner.Backend.Device.Imported,
               Resident_Bytes =>
                 Model_Runner.Backend.Device.Resident_Bytes,
               Given_Back     => Model_Runner.Backend.Device.Given_Back,
               Cached_Bytes   =>
                 Model_Runner.Backend.Device.Cached_Bytes,
               State_Bytes    =>
                 Model_Runner.Backend.Device.State_Room_Bytes,
               Layers_Whole   =>
                 Model_Runner.Backend.Device.Layers_Whole,
               Layers_Handed  =>
                 Model_Runner.Backend.Device.Layers_Handed,
               Layers_Split   =>
                 Model_Runner.Backend.Device.Layers_Split,
               Handed_Why     => Handed_Key,
               Blocks_Moved   =>
                 Model_Runner.Backend.Device.Blocks_Moved,
               Rings_Moved    =>
                 Model_Runner.Backend.Device.Rings_Moved);
         else
            Pres.Put_Statistics (Screen, Outcome);
         end if;
         --  Rows a product read out of their panels, a kernel missing:
         --  said where there were any, as a cost a token should not pay.
         if Model_Runner.Tensors.Fallback_Rows > 0 then
            Pres.Put_Note (Screen, "cli.run.fallback_rows",
                           [Loc.Named ("count", T.Image (Long_Long_Integer
                                                           (Model_Runner.Tensors.Fallback_Rows)))]);
         end if;

         --  And products that missed the fast kernel for their
         --  shape: a quantized share the integer kernels refused,
         --  or a batch the device's tile did not take. Each is a
         --  model running several times slower than it could in that
         --  product, which no rate above says by itself.
         declare
            Floated : constant Natural :=
              Model_Runner.Backend.CPU.Float_Shares;
            Integer_Taken : constant Natural :=
              Model_Runner.Backend.CPU.Integer_Shares;
            Rowed : constant Natural :=
              Model_Runner.Backend.Device.Untiled_Products;
            Tiled_Taken : constant Natural :=
              Model_Runner.Backend.Device.Tiled_Products;
         begin
            if Floated > 0 then
               Pres.Put_Note
                 (Screen, "cli.run.float_shares",
                  [Loc.Named ("count",
                              T.Image (Long_Long_Integer (Floated))),
                   Loc.Named ("total",
                              T.Image (Long_Long_Integer
                                         (Floated + Integer_Taken)))]);
            end if;

            if Rowed > 0 then
               Pres.Put_Note
                 (Screen, "cli.run.untiled_products",
                  [Loc.Named ("count",
                              T.Image (Long_Long_Integer (Rowed))),
                   Loc.Named ("total",
                              T.Image (Long_Long_Integer
                                         (Rowed + Tiled_Taken)))]);
            end if;
         end;
      end if;

      Free_Text (Prompt);
   end loop;

   Status := E.Exit_Success;
   Cleanup;
end Run_With;
