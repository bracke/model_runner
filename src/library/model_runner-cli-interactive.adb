with Ada.Finalization;
with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Hostkit.Descriptors;
with Hostkit.Terminal_Control;

with Model_Runner.Backend.Device;
with Model_Runner.CLI.Checkpoint;
with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Completion;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.CLI.Speech_Input;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Framework.Permissions;
with Model_Runner.Localization;
with Model_Runner.Platform.Signals;
with Model_Runner.Platform.Signals.Waiting;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Output.Harmony;
with Model_Runner.Output.Reasoning;
with Model_Runner.Agent;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.Tensors;
with Model_Runner.Numerics;
with Model_Runner.UTF8;
with Model_Runner.CLI.Pictures;
with Model_Runner.Vision;
with Model_Runner.Conversation.Rooms;
with Model_Runner.CLI.Pictures.Rooms;

package body Model_Runner.CLI.Interactive is

   --  The turn kept for a reply with no words to keep: an ellipsis, U+2026.
   Elided_Reply : constant String :=
     [Character'Val (16#E2#), Character'Val (16#80#), Character'Val (16#A6#)];

   ------------------
   -- Command_Word --
   ------------------

   function Command_Word (Kind : Command_Kind) return String
   is (case Kind is
         when Not_A_Command | Unknown => "",
         when Leave      => "/exit",
         when Reset      => "/reset",
         when Help       => "/help",
         when Settings   => "/settings",
         when Statistics => "/stats",
         when Context    => "/context",
         when Set_System => "/system",
         when Show_Tools => "/tools",
         when Tool_Result => "/tool",
         when Save_Conversation => "/save",
         when Load_Conversation => "/load",
         when Show_Picture => "/image",
         when Show_Video   => "/video");

   use type Model_Runner.Generation.Completion_Reason;
   use type Model_Runner.CLI.Options.Text_Access;
   use type Model_Runner.Conversation.Role;

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package Loc renames Model_Runner.Localization;
   package Opt renames Model_Runner.CLI.Options;
   package Pres renames Model_Runner.Presentation;
   package T renames Model_Runner.Text;
   package Vocab renames Model_Runner.Tokenizer;

   procedure Free_Text is new Ada.Unchecked_Deallocation (String, Text_Access);

   --  A line as it is read, on the heap and given back however the read
   --  ends; see the read loop.
   type Line_Holder is new Ada.Finalization.Limited_Controlled with record
      Text : Text_Access := null;
   end record;

   overriding procedure Finalize (Holder : in out Line_Holder);
   overriding procedure Finalize (Holder : in out Line_Holder) is
   begin
      Free_Text (Holder.Text);
   end Finalize;

   --  Room twice as long, the text kept: a line or a turn longer than the
   --  room it has, up to Max_Turn_Bytes.
   procedure Grow (Room : in out Text_Access; Least : Natural) is
      Size : Natural := Room.all'Length;
      More : Text_Access;
   begin
      while Size < Least loop
         Size := Natural'Min (2 * Size, Max_Turn_Bytes);
         exit when Size = Max_Turn_Bytes;
      end loop;
      More := new String (1 .. Natural'Max (Size, Least));
      More (1 .. Room.all'Length) := Room.all;
      Free_Text (Room);
      Room := More;
   end Grow;

   ----------
   -- Open --
   ----------

   procedure Open (Item : in out Turn; Ok : out Boolean) is
   begin
      Close (Item);
      Item.Room := new String (1 .. First_Turn_Bytes);
      Item.Used := 0;
      Ok := True;
   exception
      when others =>
         Ok := False;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Turn) is
   begin
      if Item.Room /= null then
         Free_Text (Item.Room);
      end if;
      Item.Used := 0;
   end Close;

   -----------
   -- Offer --
   -----------

   procedure Offer
     (Item   : in out Turn;
      Line   : String;
      Effect : out Line_Effect)
   is
      --  The line less its blanks at either end, as T.Trim makes it, but
      --  a slice rather than a copy: a pasted line may be megabytes, and a
      --  copy of it on the stack overflowed it.
      function Blank (C : Character) return Boolean
      is (C = ' ' or else C = ASCII.HT);

      function Lead return Positive is
         At_Char : Positive := Line'First;
      begin
         while At_Char <= Line'Last and then Blank (Line (At_Char)) loop
            At_Char := At_Char + 1;
         end loop;
         return At_Char;
      end Lead;

      function Tail return Natural is
         At_Char : Natural := Line'Last;
      begin
         while At_Char >= Line'First and then Blank (Line (At_Char)) loop
            At_Char := At_Char - 1;
         end loop;
         return At_Char;
      end Tail;

      Trimmed : String renames Line (Lead .. Tail);

      --  A command's word ends at a space or a tab, as Parse has it.
      Word_End : constant Ada.Strings.Maps.Character_Set := Ada.Strings.Maps.To_Set (" " & ASCII.HT);
   begin
      if Item.Room = null then
         Effect := Too_Long;
         return;
      end if;

      --  A command only when nothing is pending. A slash on the second line
      --  of a prompt is the text it looks like: someone typing "and then
      --  run" and "/usr/bin/ls" means the path, and reading it as a command
      --  would drop the half they had already typed.
      --  A pasted block of several lines is text whatever it begins with:
      --  a log beginning /home/x.log: is no command, and none was pasted.
      if Item.Used = 0
        and then Ada.Strings.Fixed.Index (Line, [1 => ASCII.LF]) = 0
        and then Parse (Trimmed).Kind /= Not_A_Command
      then
         Effect := Is_Command;
         return;
      end if;

      --  A project command its table lets run mid-message, typed while a
      --  message is: run, and the message kept to go on with -- not taken
      --  into it as its text. The session's own commands, a project command
      --  that waits for the message, and a path are the text they are.
      --  /image and /video too: a picture is named for the message
      --  pending, and one kept back with a picture that would not read
      --  has its picture named again.
      if Item.Used > 0
        and then Ada.Strings.Fixed.Index (Line, [1 => ASCII.LF]) = 0
        and then (Model_Runner.CLI.Project_Commands.Runs_Mid_Message
                    (Trimmed (Trimmed'First
                              .. (if Ada.Strings.Fixed.Index (Trimmed, Word_End) = 0 then Trimmed'Last
                                  else Ada.Strings.Fixed.Index (Trimmed, Word_End) - 1)))
                  or else Parse (Trimmed).Kind in Show_Picture | Show_Video
                  --  A message kept back -- the conversation full -- has
                  --  its remedies run beside it: typed as its text, /reset
                  --  was sent with it and refused again.
                  or else (Item.Kept
                           and then Parse (Trimmed).Kind
                                      in Reset | Save_Conversation | Load_Conversation | Context))
      then
         Effect := Command_Mid_Message;
         return;
      end if;

      if Trimmed = "" then
         Effect := Submits;
         return;
      end if;

      --  The separator is counted before the line, because the check has to
      --  be the one the copy below performs.
      declare
         Needed : constant Natural :=
           Item.Used + Line'Length + (if Item.Used > 0 then 1 else 0);
      begin
         if Needed > Max_Turn_Bytes then
            --  Dropped whole: no longer a kept message, whose /reset and
            --  /save would run beside the next one typed.
            Item.Used := 0;
            Item.Kept := False;
            Effect := Too_Long;
            return;
         elsif Needed > Item.Room.all'Length then
            Grow (Item.Room, Needed);
         end if;
      end;

      if Item.Used > 0 then
         Item.Used := Item.Used + 1;
         Item.Room.all (Item.Used) := ASCII.LF;
      end if;
      Item.Room.all (Item.Used + 1 .. Item.Used + Line'Length) := Line;
      Item.Used := Item.Used + Line'Length;
      Effect := Held;
   end Offer;

   -------------
   -- Pending --
   -------------

   function Pending (Item : Turn) return String is
   begin
      if Item.Room = null then
         return "";
      end if;
      return Item.Room.all (1 .. Item.Used);
   end Pending;

   -------------
   -- Restore --
   -------------

   procedure Restore (Item : in out Turn; Text : String) is
   begin
      Item.Used := 0;
      Item.Kept := False;
      if Item.Room = null or else Text'Length > Max_Turn_Bytes then
         return;
      end if;
      if Text'Length > Item.Room.all'Length then
         Grow (Item.Room, Text'Length);
      end if;
      Item.Room.all (1 .. Text'Length) := Text;
      Item.Used := Text'Length;
      Item.Kept := Text'Length > 0;
   end Restore;

   -----------
   -- Taken --
   -----------

   procedure Taken (Item : in out Turn) is
   begin
      Item.Used := 0;
      Item.Kept := False;
   end Taken;

   -----------
   -- Parse --
   -----------

   function Parse (Line : String) return Parsed_Command is
      Stop : Natural := Line'First;
   begin
      if Line'Length = 0 or else Line (Line'First) /= '/' then
         return (others => <>);
      end if;

      --  The command word runs to the first space. Splitting here rather
      --  than comparing whole lines is what lets a command with an argument
      --  and the same command without one be the same command: /system was
      --  matched as "/system " with the space, so a bare /system was an
      --  unknown command rather than one missing its text.
      --  A tab is a space here, as Offer takes it: /system and a tab was
      --  an unknown command, and the text after it lost.
      while Stop <= Line'Last and then Line (Stop) not in ' ' | ASCII.HT loop
         Stop := Stop + 1;
      end loop;

      declare
         Word  : constant String := Line (Line'First .. Stop - 1);
         First : Natural := Stop + 1;
         Last  : Natural := Line'Last;
      begin
         --  The argument, with the space that separates it and any padding
         --  around it removed. An argument of nothing but spaces is no
         --  argument, which is what makes "/system   " clear the message
         --  rather than set it to blanks.
         while First <= Last and then Line (First) in ' ' | ASCII.HT loop
            First := First + 1;
         end loop;
         while Last >= First and then Line (Last) in ' ' | ASCII.HT loop
            Last := Last - 1;
         end loop;
         if Last < First then
            First := 0;
            Last := 0;
         end if;

         --  Matched against the words the enumeration carries rather than
         --  a chain beside it. Those that take what follows them are named.
         for Kind in Command_Kind loop
            if Command_Word (Kind) /= "" and then Word = Command_Word (Kind)
            then
               if Kind in Set_System | Tool_Result
                            | Save_Conversation | Load_Conversation
                            | Show_Picture | Show_Video | Help
               then
                  return (Kind, First, Last);
               else
                  return (Kind, 0, 0);
               end if;
            end if;
         end loop;

         return (Unknown, 0, 0);
      end;
   end Parse;

   ---------
   -- Run --
   ---------

   --  The pages the processor will read of a split model, brought in
   --  behind the conversation (Llama.Warm_Host_Pages). Not a task of Run's:
   --  the first turn does not wait for it, as it does for the token below,
   --  and it may outlast a line typed quickly. Told to stop and waited for
   --  when Run is left, before the model it reads is closed.
   Touch_Stop : aliased Model_Runner.Cancellation.Token;

   type Model_Reference is access constant L.Model;

   task type Page_Toucher is
      entry Start (Source : Model_Reference);
   end Page_Toucher;

   task body Page_Toucher is
      Held : Model_Reference;
   begin
      accept Start (Source : Model_Reference) do
         Held := Source;
      end Start;
      L.Warm_Host_Pages (Held.all, Touch_Stop'Access);
   exception
      when others =>
         null;
   end Page_Toucher;

   type Toucher_Access is access Page_Toucher;
   procedure Free_Toucher is new Ada.Unchecked_Deallocation (Page_Toucher, Toucher_Access);

   --  Stops the toucher and waits for it as Run is left, however it is.
   --  The device's turn lent again however a session ends, as it is
   --  outside one: a session ended holding it left a later user of the
   --  device in the same process without it.
   type Turn_Guard is new Ada.Finalization.Limited_Controlled with null record;

   overriding procedure Finalize (Guard : in out Turn_Guard);

   overriding procedure Finalize (Guard : in out Turn_Guard) is
      pragma Unreferenced (Guard);
   begin
      Model_Runner.Backend.Device.Lend_Turn;
   end Finalize;

   type Toucher_Guard is new Ada.Finalization.Limited_Controlled with record
      Running : Toucher_Access := null;
   end record;

   overriding procedure Finalize (Guard : in out Toucher_Guard);

   overriding procedure Finalize (Guard : in out Toucher_Guard) is
   begin
      if Guard.Running /= null then
         Touch_Stop.Request;
         while not Guard.Running'Terminated loop
            delay 0.01;
         end loop;
         Touch_Stop.Reset;
         --  Ended, its object given back: each session left one behind.
         Free_Toucher (Guard.Running);
      end if;
   end Finalize;

   procedure Run
     (Item     : Opt.Command;
      Screen   : in out Pres.Console;
      Prepared : in out L.Model;
      Session  : in out L.Session;
      Rules    : Model_Runner.Generation.Grammar_Reference := null;
      Tools    : access constant Model_Runner.Tools.Definitions := null;
      Status   : out Natural;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null)
   is
      Bounds : constant Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Words  : constant access constant Vocab.Vocabulary :=
        L.Vocabulary (Prepared);

      Messages_Room : Model_Runner.Conversation.Rooms.Holder;
      Messages      : Conv.History renames Messages_Room.Data.all;

      --  The project's revision the conversation last saw: what it moved by
      --  since is said before the next turn.
      Project_Seen : Natural := Model_Runner.CLI.Project_Commands.Project_Revision;
      Stop_Set : aliased Model_Runner.Stops.Set;

      --  The session's own model, as the agent /work runs on a task.
      Asked_For : aliased constant Opt.Command := Item;
      Worker_Notes : aliased Model_Runner.CLI.Project_Commands.Run_Notes;
      Work_Session : aliased L.Session;
      Helper_Session : aliased L.Session;
      Worker    : Model_Runner.CLI.Project_Commands.Session_Agent
        (Prepared'Unchecked_Access, Session'Unchecked_Access,
         Stop_Set'Unchecked_Access, Screen'Unchecked_Access,
         Asked_For'Unchecked_Access, Cancel, Worker_Notes'Unchecked_Access);
      Sink     : aliased Pres.Standard_Output_Sink;
      --  Speech into the line being typed, where a speech model is named:
      --  its own model, read on first use, beside this one and apart from
      --  it; stopped however the session ends.
      Speech   : aliased Model_Runner.CLI.Speech_Input.Input;
      --  And gpt-oss's replies through a filter that shows its reasoning
      --  and answer without the harmony markup.
      Tidied   : aliased Model_Runner.Output.Harmony.Filter
        (Sink'Unchecked_Access);
      --  And any other model's think block, left out where --hide-reasoning
      --  asks for the answer alone.
      Unthought : aliased Model_Runner.Output.Reasoning.Filter
        (Sink'Unchecked_Access);
      function Harmony return Boolean
      is (Model_Runner.Tools."="
            (Model_Runner.Templates.Syntax_Of (L.Template_Format (Prepared)),
             Model_Runner.Tools.Harmony_Call));
      Clock    : aliased Model_Runner.Clocks.System_Clock;
      Seeds    : aliased Model_Runner.Entropy.Host_Source;

      Typing       : Turn;
      Have_Stats   : Boolean := False;
      Last_Result  : Gen.Result;
      Condition    : E.Error_Info;
      Leaving      : Boolean := False;

      --  Whether this session hid the echo of control keys, to show again.
      Keys_Hidden  : Boolean := False;

      --  Whether lines typed during a /work are still being taken up.
      Draining     : Boolean := False;

      --  The pictures the conversation shows, gathered before every turn
      --  from the turns as they stand; a picture named with /image goes
      --  into the next turn typed, as a part beside its words.
      Pictures     : Gen.Picture_Set;
      Seer_Room    : Model_Runner.CLI.Pictures.Rooms.Holder;
      Seer         : Model_Runner.CLI.Pictures.Seer renames Seer_Room.Data.all;

      --  A message's content as the template is to see it: a control
      --  marker someone wrote in it is text, not a turn, and a picture's
      --  token is no picture.
      function Content_Text (Text : String) return String
      is (Vocab.Defused (Words.all, Text, Model_Runner.CLI.Pictures.Picture_Tokens (Seer)));
      Next_Picture : Text_Access := null;

      --  Whether what is named for the next turn is a video's frames
      --  rather than a picture.
      Next_Is_Video : Boolean := False;

      --  The picture the latest turn took, held until the turn is in: a
      --  turn kept back gets it back with its words, rather than the
      --  words alone -- /image could not be typed while they waited.
      Turn_Picture  : Text_Access := null;
      Turn_Is_Video : Boolean := False;

      --  Whether the picture named was itself what failed -- it would not
      --  read, or the model takes none: not given back with its words, or
      --  every message after would carry it and be refused for it.
      Picture_Failed : Boolean := False;

      --  Whether Next_Picture came back with a kept-back message: dropped
      --  with it when Ctrl-C or Esc drops the message.
      Picture_Kept : Boolean := False;

      procedure Drop_Kept_Picture is
      begin
         if Picture_Kept then
            Free_Text (Next_Picture);
            Picture_Kept := False;
         end if;
      end Drop_Kept_Picture;

      --  The pending message dropped unsent -- Ctrl-C, Esc, too long -- and
      --  the picture that came back with it: every way it goes, one way.
      procedure Drop_Message is
      begin
         Drop_Kept_Picture;
         Taken (Typing);
      end Drop_Message;

      --  Encode what the conversation names and Pictures does not hold.
      procedure Gather_Pictures_Of
        (Source : Conv.History; Outcome : out E.Error_Info)
      is
         Named : Boolean := False;
      begin
         Outcome := E.Success;
         for Index in 1 .. Conv.Length (Source) loop
            if Model_Runner.CLI.Pictures.Names_A_Picture
                 (Conv.Parts_At (Source, Index))
            then
               Named := True;
               exit;
            end if;
         end loop;
         if not Named then
            return;
         end if;
         if T.Is_Empty (Item.Projector_Path) then
            Outcome := E.Make (E.CLI_Picture_Needs_Projector);
            E.Add_Text (Outcome, "option", "/image", E.Param_Identifier);
            E.Add_Text (Outcome, "other", "--mmproj", E.Param_Identifier);
            return;
         end if;
         Model_Runner.Vision.Prefer_Exact
           (Item.Arithmetic_Set
            and then Model_Runner.Llama."="
                       (Item.Arithmetic, Model_Runner.Llama.Float_Activations));
         if not Model_Runner.CLI.Pictures.Is_Open (Seer) then
            Model_Runner.CLI.Pictures.Open
              (Seer, T.To_String (Item.Projector_Path), Prepared, Outcome);
            if E.Is_Error (Outcome) then
               return;
            end if;
         end if;
         --  Ctrl-C stops the encoding too, not only the reply after it:
         --  a video's hundreds of slots ran to their end first.
         Model_Runner.CLI.Pictures.Gather
           (Seer, Source, Pictures, L.Workers (Session), Item.Pan_And_Scan,
            Cancel => Cancel, Status => Outcome);
      end Gather_Pictures_Of;

      procedure Gather_Pictures (Outcome : out E.Error_Info) is
      begin
         Gather_Pictures_Of (Messages, Outcome);
      end Gather_Pictures;

      --  What /load reads, asked before it takes the conversation's place:
      --  its system message first if it has one, a developer's beside it,
      --  and its pictures
      --  gathered, which every turn after does again: a picture missing,
      --  or no projector, and every turn after was refused, while the load
      --  had said it loaded.
      procedure Check_Loaded (Trial : Conv.History; Status : out E.Error_Info) is
         Count : constant Natural := Conv.Length (Trial);

         procedure Refuse (Detail : String) is
         begin
            Status := E.Make (E.Framework_Input_Invalid);
            E.Add_Text (Status, "name", "the conversation");
            E.Add_Text (Status, "value", "/load");
            E.Add_Text (Status, "detail", Detail);
         end Refuse;
      begin
         Status := E.Success;
         for Index in 1 .. Count loop
            declare
               Said : constant Conv.Role := Conv.Sender_At (Trial, Index);
            begin
               if Said = Conv.System_Role and then Index /= 1 then
                  Refuse ("a system message stands at turn" & Natural'Image (Index) & ", not first");
                  return;
               elsif Said = Conv.Developer_Role
                 and then not (Index = 1 or else (Index = 2 and then Conv.Sender_At (Trial, 1) = Conv.System_Role))
               then
                  Refuse ("a developer message stands at turn" & Natural'Image (Index) & ", not first");
                  return;
               end if;
            end;
         end loop;
         --  Two turns of a side in a row, or a last turn unanswered, are
         --  asked of the model's own template rather than refused outright:
         --  an agent's checkpoint holds both -- its nudges are the person's
         --  -- and a template that does not alternate takes it, while one
         --  that does (Gemma's, Mistral's) would refuse every turn after.
         declare
            Buffer : Text_Access := new String (1 .. Bounds.Max_Rendered_Bytes);
            Last   : Natural;
         begin
            Model_Runner.Templates.Render
              (L.Template (Prepared).all, Trial,
               Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
               Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
               True, Buffer.all, Last, Status,
               Thinking => Item.Thinking, Tools => Tools,
               Image_Marker => Model_Runner.CLI.Pictures.Picture_Marker (Seer),
               Video_Marker => Model_Runner.CLI.Pictures.Video_Marker (Seer),
               Literal => Content_Text'Access,
               Effort => Item.Effort);
            Free_Text (Buffer);
            if E.Is_Error (Status) then
               return;
            end if;
         end;
         --  The pictures the loaded one names, gathered in place of the
         --  ones held: refused, the set is empty, and the conversation
         --  kept gathers its own again at its next turn.
         Model_Runner.CLI.Pictures.Release (Pictures);
         Gather_Pictures_Of (Trial, Status);
         if E.Is_Error (Status) then
            Model_Runner.CLI.Pictures.Release (Pictures);
         end if;
      end Check_Loaded;

      procedure Release_Pictures is
      begin
         Model_Runner.CLI.Pictures.Release (Pictures);
         Model_Runner.CLI.Pictures.Close (Seer);
         Free_Text (Next_Picture);
         Free_Text (Turn_Picture);
      end Release_Pictures;

      --  Render the committed conversation plus the pending user turn.
      procedure Render
        (Rendered : out Text_Access;
         Outcome  : out E.Error_Info)
      is
         --  Allocated rather than declared: the rendered-prompt limit is far
         --  larger than a stack object may be.
         Buffer : Text_Access := new String (1 .. Bounds.Max_Rendered_Bytes);
         Last   : Natural;
      begin
         Rendered := null;
         Model_Runner.Templates.Render
           (L.Template (Prepared).all, Messages,
            Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
            Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
            True, Buffer.all, Last, Outcome,
            Thinking => Item.Thinking, Tools => Tools,
            Image_Marker => Model_Runner.CLI.Pictures.Picture_Marker (Seer),
            Video_Marker => Model_Runner.CLI.Pictures.Video_Marker (Seer),
            Literal => Content_Text'Access,
            Effort => Item.Effort);
         if E.Is_Ok (Outcome) then
            Rendered := new String'(Buffer.all (1 .. Last));
         end if;
         Free_Text (Buffer);
      end Render;

      --  Show the sampling settings in use. Option names are protocol and are
      --  printed as written.
      procedure Show_Settings is
         Default : constant Model_Runner.Sampling.Configuration := (others => <>);
         --  As a turn samples: the model file's own settings where none
         --  was named.
         Used    : constant Model_Runner.Sampling.Configuration := Opt.Sampling_For (Item, Prepared);
         use type Model_Runner.Sampling.Real;

         --  A value the session changed from the default stands out.
         function Tone_Of (Changed : Boolean) return Pres.Tone
         is (if Changed then Pres.Pending else Pres.Plain);
      begin
         --  In groups, as /task show is: how a token is chosen, what holds
         --  repetition back, and how much is said.
         Pres.Put_Heading (Screen, "cli.interactive.settings.choosing", Pres.Diagnostic);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.temperature",
            T.Image (Long_Float (Used.Temperature), 3), Pres.Diagnostic,
            Tone_Of (Used.Temperature /= Default.Temperature));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_k",
            T.Image (Long_Long_Integer (Used.Top_K)), Pres.Diagnostic,
            Tone_Of (Used.Top_K /= Default.Top_K));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_p",
            T.Image (Long_Float (Used.Top_P), 3), Pres.Diagnostic,
            Tone_Of (Used.Top_P /= Default.Top_P));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.min_p",
            T.Image (Long_Float (Used.Min_P), 3), Pres.Diagnostic,
            Tone_Of (Used.Min_P /= Default.Min_P));
         if Item.Has_Seed then
            Pres.Put_Field
              (Screen, "cli.interactive.setting.seed",
               T.Image (Item.Seed), Pres.Diagnostic, Pres.Pending);
         end if;
         Pres.Put_Heading (Screen, "cli.interactive.settings.repeating", Pres.Diagnostic, Gap => True);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_penalty",
            T.Image (Long_Float (Used.Repeat_Penalty), 3), Pres.Diagnostic,
            Tone_Of (Used.Repeat_Penalty /= Default.Repeat_Penalty));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_window",
            T.Image (Long_Long_Integer (Used.Repeat_Window)), Pres.Diagnostic,
            Tone_Of (Used.Repeat_Window /= Default.Repeat_Window));
         Pres.Put_Heading (Screen, "cli.interactive.settings.length", Pres.Diagnostic, Gap => True);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.max_tokens",
            T.Image (Long_Long_Integer (Item.Max_Tokens)), Pres.Diagnostic);
      end Show_Settings;

      --  Declared here because a command runs one: an answer handed back
      --  with /tool is a turn like any other, and the model is asked to go
      --  on the moment it arrives.
      procedure Take_Turn
        (Prompt : String; Sender : Conv.Role := Conv.User_Role);

      --  Whether the last Take_Turn put a reply into the conversation, and
      --  how many it was asked for: a command that talks to the model --
      --  /tool -- leaves the model, not the command, to be answered.
      Turn_Taken : Boolean := False;
      Turns_Asked : Natural := 0;

      --  Whether the last Take_Turn was refused before the model read any
      --  of it -- its picture unreadable, no projector, a template that
      --  would not render -- so that what was typed is kept to mend and
      --  send again rather than typed again.
      Kept_Back : Boolean := False;

      --  The weights read once while the first line is typed: a token run
      --  through a session that holds nothing, which uploads what the
      --  device keeps and brings into memory what the processor reads,
      --  and the session given back empty. ThinkingCap's first prompt
      --  carried eleven gigabytes of uploads otherwise. What uses the
      --  session waits for it -- a turn, a command other than the project's
      --  own, /work -- and finds it done after the first; the project's
      --  other commands do not: /init waited behind a cold model's reading,
      --  past half a minute where the drive was slow.
      --  And the device's turn, lent while a line is waited for once the
      --  model is warm -- at the line's start, or when warming ends while
      --  it is waited for.
      protected Warming is
         procedure Finish;
         entry Settled;
         procedure Enter_Line;
         procedure Leave_Line;
      private
         Done    : Boolean := False;
         At_Line : Boolean := False;
      end Warming;

      protected body Warming is
         procedure Finish is
         begin
            Done := True;
            if At_Line then
               Model_Runner.Backend.Device.Lend_Turn;
            end if;
         end Finish;

         entry Settled when Done is
         begin
            null;
         end Settled;

         procedure Enter_Line is
         begin
            At_Line := True;
            if Done then
               Model_Runner.Backend.Device.Lend_Turn;
            end if;
         end Enter_Line;

         procedure Leave_Line is
         begin
            At_Line := False;
         end Leave_Line;
      end Warming;

      --  What stops the warming where nothing else would: leaving waits for
      --  it, and a run of half a minute on a slow drive held /exit as long.
      Warm_Stop : aliased Model_Runner.Cancellation.Token;

      function Warm_Token return Model_Runner.Cancellation.Token_Reference
      is (if Model_Runner.Cancellation."/=" (Cancel, null) then Cancel else Warm_Stop'Unchecked_Access);

      --  Asked to stop warming, leaving: the session is not used after.
      procedure Stop_Warming is
      begin
         Warm_Token.Request;
      end Stop_Warming;

      --  The calls the model's last reply made that no tool's answer has
      --  answered yet: an answer to none -- after a plain reply, or a
      --  second to one call -- is to a question nobody put.
      function Calls_Unanswered return Natural is
         Answers : Natural := 0;
      begin
         for Index in reverse 1 .. Conv.Length (Messages) loop
            if Conv."=" (Conv.Sender_At (Messages, Index), Conv.Tool_Role) then
               Answers := Answers + 1;
            elsif Conv."=" (Conv.Sender_At (Messages, Index), Conv.Assistant_Role) then
               return Natural'Max (0, Conv.Call_Count (Messages, Index) - Answers);
            else
               return 0;
            end if;
         end loop;
         return 0;
      end Calls_Unanswered;

      --  Handle one slash command. Returns True when the input was a command.
      function Handle_Command (Line : String) return Boolean is
         Asked : constant Parsed_Command := Parse (Line);
         --  The command's word ends at a space or a tab, as Parse has it.
         Space : constant Natural :=
           Ada.Strings.Fixed.Index (Line, Ada.Strings.Maps.To_Set (" " & ASCII.HT));
         First : constant String :=
           (if Space = 0 then Line else Line (Line'First .. Space - 1));

         --  A path as Tab completes it, quoted when it holds a space: the
         --  quotes are not part of its name.
         --  The text after a quoted path's closing quote, which no path
         --  holds: /save "a b" x.
         --  Within the quotes \" is a quote of the name and \\ a
         --  backslash, as Tab writes them and the project's commands read
         --  them: the first quote no backslash escapes closes it.
         function Closing_Quote return Natural is
            Text : constant String := Line (Asked.First .. Asked.Last);
            At_Char : Natural;
         begin
            if Text'Length > 0 and then Text (Text'First) = '"' then
               At_Char := Text'First + 1;
               while At_Char <= Text'Last loop
                  if Text (At_Char) = '\' and then At_Char < Text'Last then
                     At_Char := At_Char + 2;
                  elsif Text (At_Char) = '"' then
                     return At_Char;
                  else
                     At_Char := At_Char + 1;
                  end if;
               end loop;
            end if;
            return 0;
         end Closing_Quote;

         function Path_Asked return String is
            Text  : constant String := Line (Asked.First .. Asked.Last);
            Last  : Natural := Text'Last;
         begin
            if Text'Length > 0 and then Text (Text'First) = '"' then
               if Closing_Quote > 0 then
                  Last := Closing_Quote - 1;
               end if;
               --  Its escapes undone: \" a quote, \\ a backslash.
               declare
                  Name    : String (1 .. Text'Length);
                  Used    : Natural := 0;
                  At_Char : Natural := Text'First + 1;
               begin
                  while At_Char <= Last loop
                     if Text (At_Char) = '\' and then At_Char < Last
                       and then Text (At_Char + 1) in '"' | '\'
                     then
                        At_Char := At_Char + 1;
                     end if;
                     Used := Used + 1;
                     Name (Used) := Text (At_Char);
                     At_Char := At_Char + 1;
                  end loop;
                  return Name (1 .. Used);
               end;
            end if;
            return Text (Text'First .. Last);
         end Path_Asked;

         --  What follows a quoted path, trimmed: "" when nothing does.
         function Path_After return String is
         begin
            if Asked.First = 0 or else Closing_Quote = 0 then
               return "";
            end if;
            return Ada.Strings.Fixed.Trim (Line (Closing_Quote + 1 .. Asked.Last), Ada.Strings.Both);
         end Path_After;

         --  No path to read or write: none typed, or only its quotes --
         --  /save "" named the session's directory.
         function Path_Missing return Boolean
         is (Asked.First = 0 or else Ada.Strings.Fixed.Trim (Path_Asked, Ada.Strings.Both) = "");
      begin
         if Asked.Kind = Not_A_Command then
            return False;
         end if;

         --  Leaving does not wait for the warming to finish: it is stopped.
         if Asked.Kind = Leave then
            Stop_Warming;
         end if;
         if not Model_Runner.CLI.Project_Commands.Is_Project_Command (First)
           or else Model_Runner.CLI.Project_Commands.Runs_Model (First)
         then
            Warming.Settled;
         end if;

         --  The project's own commands, between turns.
         if Model_Runner.CLI.Project_Commands.Is_Project_Command (First) then
            declare
               Errors_Before : constant Natural := Pres.Errors_Reported (Screen);
            begin
               Model_Runner.CLI.Project_Commands.Run (Line, Screen, Worker);
               --  Refused: not offered back by Up or as a suggestion.
               if Pres.Errors_Reported (Screen) > Errors_Before then
                  Model_Runner.CLI.Choosers.Forget_Last_Line;
               end if;
            end;
            return True;
         end if;

         if Asked.Kind = Leave then
            Leaving := True;

         elsif Asked.Kind = Reset then
            Conv.Clear (Messages);
            --  The conversation starts over as the session started it: with
            --  the --system message, which a reset had dropped with the rest.
            if Item.Has_System and then Item.System_Text /= null then
               declare
                  Restored : E.Error_Info;
               begin
                  Conv.Set_System (Messages, Item.System_Text.all, Restored);
                  if E.Is_Error (Restored) then
                     Pres.Report (Screen, Restored);
                  end if;
               end;
            end if;
            L.Reset (Session);
            Model_Runner.CLI.Pictures.Release (Pictures);
            --  A message kept to send again keeps its picture: it goes
            --  into the new conversation, as /reset beside it was for.
            if not Picture_Kept then
               Free_Text (Next_Picture);
            end if;
            Have_Stats := False;
            Pres.Put_Note (Screen, "cli.interactive.reset_done");

         elsif Asked.Kind = Help
           and then Asked.First in Line'Range
           and then Line (Asked.First .. Asked.Last) in "project" | "project all"
         then
            --  The project's commands that apply here, each with what it
            --  does; all of them where asked.
            Model_Runner.CLI.Project_Commands.Help
              (Screen, All_Of_Them => Line (Asked.First .. Asked.Last) = "project all");

         elsif Asked.Kind = Help and then Asked.First in Line'Range
           and then Asked.Last >= Asked.First
         then
            --  One command's line: /help result, /help /work.
            declare
               --  The command alone: /help task list is /help task.
               Whole : constant String :=
                 (if Line (Asked.First) = '/' then Line (Asked.First + 1 .. Asked.Last)
                  else Line (Asked.First .. Asked.Last));
               Named : constant String :=
                 (if Ada.Strings.Fixed.Index (Whole, " ") > 0
                  then Whole (Whole'First .. Ada.Strings.Fixed.Index (Whole, " ") - 1) else Whole);
               --  The session's own commands a line of help is kept for; the
               --  project's are the command table's.
               Known : constant String :=
                 " projects exit reset help settings stats context system tools tool save load"
                 & " image video ";
            begin
               --  A project command by the command table, which knows every one.
               if Named /= ""
                 and then (Ada.Strings.Fixed.Index (Known, " " & Named & " ") > 0
                           or else Model_Runner.CLI.Project_Commands.Is_Project_Command ("/" & Named))
               then
                  Pres.Put_Help_Line (Screen, "cli.interactive.help." & Named);
                  --  And how it is used, where that takes more than a line.
                  if Named = "init" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.init");
                  elsif Named = "task" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.task");
                  elsif Named = "work" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.work");
                  elsif Named = "req" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.req");
                  elsif Named = "decision" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.decision");
                  elsif Named = "spec" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.spec");
                  elsif Named = "accept" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.accept");
                  elsif Named = "reject" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.reject");
                  elsif Named = "git" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.git");
                  elsif Named = "result" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.result");
                  elsif Named = "reconfigure" then
                     Pres.Put_Usage (Screen, "cli.project.reconfigure.usage");
                  elsif Named = "config" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.config");
                  elsif Named = "state" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.state");
                  elsif Named = "check" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.check");
                  elsif Named = "bootstrap" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.bootstrap");
                  elsif Named = "instruct" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.instruct");
                  elsif Named = "obs" then
                     Pres.Put_Usage (Screen, "cli.interactive.usage.obs");
                  end if;
               else
                  --  The command most likely meant, as Tab would take it.
                  declare
                     Near : constant Model_Runner.Framework.Name_Lists.Vector :=
                       Model_Runner.CLI.Completion.Candidates ("/help " & Named);
                     --  None it begins: the nearest by its letters, as an
                     --  unknown command is answered.
                     Close : constant String :=
                       (if Near.Is_Empty
                        then Model_Runner.Framework.Nearest
                               (Named, Model_Runner.CLI.Completion.Candidates ("/help "))
                        else "");
                     --  A few it begins: each offered.
                     function Offered (From : Positive := 1) return String
                     is (if From > Natural'Min (3, Natural (Near.Length)) then ""
                         else (if From = 1 then "" else " or ") & "/help " & Near (From)
                              & String'(Offered (From => From + 1)));
                  begin
                     Pres.Put_Message (Screen, "cli.interactive.help_unknown",
                                       [Loc.Named ("value", T.Escape_Controls (Named)
                                                   & (if not Near.Is_Empty
                                                      then " -- did you mean " & Offered & "?"
                                                      elsif Close /= ""
                                                      then " -- did you mean /help " & Close & "?"
                                                      else ""))]);
                  end;
               end if;
            end;

         elsif Asked.Kind = Help then
            --  One line per command the enumeration carries, so a command
            --  added without a line fails the checklist rather than going
            --  unmentioned in the only place that lists them; the project's
            --  commands named on one more, so that it all fits a screen.
            for Kind in Command_Kind loop
               if Command_Word (Kind) /= "" then
                  declare
                     Word : constant String := Command_Word (Kind);
                  begin
                     Pres.Put_Help_Line
                       (Screen,
                        "cli.interactive.help."
                        & Word (Word'First + 1 .. Word'Last));
                  end;
               end if;
            end loop;
            Pres.Put_Aside (Screen, "cli.interactive.help.projects");

         elsif Asked.Kind = Settings then
            Show_Settings;

         elsif Asked.Kind = Statistics then
            if Have_Stats then
               Pres.Put_Statistics (Screen, Last_Result);
            else
               Pres.Put_Note (Screen, "cli.interactive.no_stats");
            end if;

         elsif Asked.Kind = Context then
            --  How full it is, in the colour of how near the end that is,
            --  and what fills it: the conversation's turns by who said them.
            declare
               --  What the conversation is, as the next turn will read it:
               --  rendered and counted. The cache's position said nought
               --  after /load or /system, which read the session back, and
               --  counted a cancelled turn's prompt the conversation lost.
               function Conversation_Tokens return Natural is
                  Rendered : Text_Access := null;
                  Outcome  : E.Error_Info;
               begin
                  if Conv.Length (Messages) = 0 then
                     return L.Position (Session);
                  end if;
                  Render (Rendered, Outcome);
                  if E.Is_Error (Outcome) or else Rendered = null then
                     return L.Position (Session);
                  end if;
                  declare
                     type Token_Access is access Vocab.Token_Array;
                     procedure Free is new Ada.Unchecked_Deallocation (Vocab.Token_Array, Token_Access);
                     Room : Token_Access := new Vocab.Token_Array (1 .. Rendered'Length + 8);
                     Last : Natural := 0;
                     Read : E.Error_Info;
                  begin
                     Vocab.Encode (Words.all, Rendered.all, True, False, Room.all, Last, Read);
                     Free (Room);
                     Free_Text (Rendered);
                     return (if E.Is_Error (Read) then L.Position (Session) else Last);
                  end;
               exception
                  when others =>
                     Free_Text (Rendered);
                     return L.Position (Session);
               end Conversation_Tokens;
               Used     : constant Natural := Conversation_Tokens;
               Capacity : constant Natural := L.Capacity (Session);
               Percent  : constant Natural := (if Capacity = 0 then 0 else Used * 100 / Capacity);
               Counts   : array (Conv.Role) of Natural := [others => 0];
               Pictures : Natural := 0;
            begin
               for Index in 1 .. Conv.Length (Messages) loop
                  Counts (Conv.Sender_At (Messages, Index)) := Counts (Conv.Sender_At (Messages, Index)) + 1;
                  if Model_Runner.CLI.Pictures.Names_A_Picture (Conv.Parts_At (Messages, Index)) then
                     Pictures := Pictures + 1;
                  end if;
               end loop;
               Pres.Put_Heading (Screen, "cli.interactive.context.heading", Pres.Diagnostic);
               Pres.Put_Field
                 (Screen, "cli.interactive.context.used",
                  T.Image (Long_Long_Integer (Used)) & " of " & T.Image (Long_Long_Integer (Capacity))
                  & " tokens (" & T.Image (Long_Long_Integer (Percent)) & "%)",
                  Pres.Diagnostic,
                  (if Percent >= 90 then Pres.Bad elsif Percent >= 70 then Pres.Pending else Pres.Good));
               Pres.Put_Field
                 (Screen, "cli.interactive.context.free",
                  T.Image (Long_Long_Integer (Capacity - Natural'Min (Used, Capacity))) & " tokens",
                  Pres.Diagnostic);
               Pres.Put_Heading (Screen, "cli.interactive.context.fills", Pres.Diagnostic, Gap => True);
               Pres.Put_Field
                 (Screen, "cli.interactive.context.system",
                  (if Conv.Has_System (Messages) then "set (/system shows how to change it)" else "none"),
                  Pres.Diagnostic);
               Pres.Put_Field (Screen, "cli.interactive.context.yours",
                               T.Image (Long_Long_Integer (Counts (Conv.User_Role))), Pres.Diagnostic);
               Pres.Put_Field (Screen, "cli.interactive.context.answers",
                               T.Image (Long_Long_Integer (Counts (Conv.Assistant_Role))), Pres.Diagnostic);
               if Counts (Conv.Tool_Role) > 0 then
                  Pres.Put_Field (Screen, "cli.interactive.context.tools",
                                  T.Image (Long_Long_Integer (Counts (Conv.Tool_Role))), Pres.Diagnostic);
               end if;
               if Pictures > 0 then
                  Pres.Put_Field (Screen, "cli.interactive.context.pictures",
                                  T.Image (Long_Long_Integer (Pictures)), Pres.Diagnostic);
               end if;
               if Percent >= 70 then
                  Pres.Put_Note (Screen, "cli.interactive.context.nearly_full");
               end if;
            end;

         elsif Asked.Kind = Set_System then
            declare
               Content : constant String :=
                 (if Asked.First = 0 then ""
                  else Line (Asked.First .. Asked.Last));
               Outcome : E.Error_Info;
            begin
               --  Words that are not UTF-8 are refused here, as a typed
               --  turn's are: taken in, every turn after failed to tokenize.
               if not Model_Runner.UTF8.Is_Valid (Content) then
                  Outcome := E.Make (E.IO_Invalid_UTF8);
               else
                  Conv.Set_System (Messages, Content, Outcome);
               end if;
               if E.Is_Error (Outcome) then
                  Pres.Report (Screen, Outcome);
               else
                  --  A changed system message invalidates every cached
                  --  position, so the context is cleared rather than reused.
                  L.Reset (Session);
                  Have_Stats := False;
                  Pres.Put_Note
                    (Screen,
                     (if Content = "" then "cli.interactive.system_cleared"
                      else "cli.interactive.system_done"));
               end if;
            end;

         elsif Asked.Kind = Show_Tools then
            if Tools = null or else Model_Runner.Tools.Count (Tools.all) = 0
            then
               Pres.Put_Note (Screen, "cli.interactive.no_tools");
            else
               --  Each by its name, set apart, with what it does and what it
               --  takes set in under it -- read from its definition.
               for Index in 1 .. Model_Runner.Tools.Count (Tools.all) loop
                  declare
                     Definition : constant String := Model_Runner.Tools.Definition (Tools.all, Index);

                     --  The first string a key holds: "description": "...".
                     --  The tool's own, ahead of its parameters: one with no
                     --  description showed its first parameter's.
                     At_Parameters : constant Natural := Ada.Strings.Fixed.Index (Definition, """parameters""");
                     Own : constant String :=
                       (if At_Parameters = 0 then Definition else Definition (Definition'First .. At_Parameters - 1));

                     function String_Of (Key : String) return String is
                        At_Key : constant Natural := Ada.Strings.Fixed.Index (Own, '"' & Key & '"');
                        Open   : Natural;
                        Stop   : Natural;

                        --  A quote is escaped by an odd run of backslashes
                        --  before it: "\\" ends its string.
                        function Escaped (At_Quote : Positive) return Boolean is
                           Run : Natural := 0;
                        begin
                           while At_Quote - Run - 1 >= Definition'First
                             and then Definition (At_Quote - Run - 1) = '\'
                           loop
                              Run := Run + 1;
                           end loop;
                           return Run mod 2 = 1;
                        end Escaped;
                     begin
                        if At_Key = 0 then
                           return "";
                        end if;
                        Open := Ada.Strings.Fixed.Index (Definition (At_Key + Key'Length + 2 .. Definition'Last), """");
                        if Open = 0 then
                           return "";
                        end if;
                        Stop := Open + 1;
                        while Stop <= Definition'Last
                          and then (Definition (Stop) /= '"' or else Escaped (Stop))
                        loop
                           Stop := Stop + 1;
                        end loop;
                        return (if Stop > Definition'Last then "" else Definition (Open + 1 .. Stop - 1));
                     end String_Of;

                     --  The names of its parameters: the keys of "properties".
                     function Parameters return String is
                        At_Props : constant Natural := Ada.Strings.Fixed.Index (Definition, """properties""");
                        Said     : Ada.Strings.Unbounded.Unbounded_String;
                        Depth    : Natural := 0;
                        Index_At : Natural;
                        In_Text  : Boolean := False;
                        Start    : Natural := 0;
                     begin
                        if At_Props = 0 then
                           return "";
                        end if;
                        Index_At := Ada.Strings.Fixed.Index (Definition (At_Props .. Definition'Last), "{");
                        if Index_At = 0 then
                           return "";
                        end if;
                        for Here in Index_At .. Definition'Last loop
                           declare
                              C : constant Character := Definition (Here);
                           begin
                              if In_Text then
                                 if C = '"' and then Definition (Here - 1) /= '\' then
                                    In_Text := False;
                                    --  A key at the first depth, a colon after it.
                                    if Depth = 1 and then Here < Definition'Last
                                      and then Ada.Strings.Fixed.Index
                                                 (Ada.Strings.Fixed.Trim (Definition (Here + 1 .. Definition'Last),
                                                                          Ada.Strings.Left), ":") = 1
                                    then
                                       Ada.Strings.Unbounded.Append
                                         (Said, (if Ada.Strings.Unbounded.Length (Said) = 0 then "" else ", ")
                                                & Definition (Start .. Here - 1));
                                    end if;
                                 end if;
                              elsif C = '"' then
                                 In_Text := True;
                                 Start := Here + 1;
                              elsif C = '{' then
                                 Depth := Depth + 1;
                              elsif C = '}' then
                                 Depth := Depth - 1;
                                 exit when Depth = 0;
                              end if;
                           end;
                        end loop;
                        return Ada.Strings.Unbounded.To_String (Said);
                     end Parameters;
                  begin
                     Pres.Put_Aside_Marked
                       (Screen, "cli.interactive.tool_name",
                        [Loc.Named ("name", Model_Runner.Tools.Tool_Name (Tools.all, Index))],
                        Model_Runner.Tools.Tool_Name (Tools.all, Index), Pres.Good);
                     if String_Of ("description") /= "" then
                        Pres.Put_Aside (Screen, "cli.interactive.tool_does",
                                        [Loc.Named ("detail", String_Of ("description"))], Indent => 2);
                     end if;
                     Pres.Put_Aside (Screen, "cli.interactive.tool_takes",
                                     [Loc.Named ("detail", (if Parameters = "" then "nothing" else Parameters))],
                                     Indent => 2);
                  end;
               end loop;
            end if;

         elsif Asked.Kind = Tool_Result then
            --  The other half of a call. It is a turn of its own: the
            --  template writes a tool's answer differently from a person's,
            --  and handing it back as the person would make it a different
            --  conversation.
            if Tools = null or else Model_Runner.Tools.Count (Tools.all) = 0
            then
               Pres.Put_Note (Screen, "cli.interactive.no_tools");
            elsif Asked.First = 0 then
               Pres.Put_Note (Screen, "cli.interactive.tool_needs_text");
            elsif not Model_Runner.UTF8.Is_Valid (Line (Asked.First .. Asked.Last))
            then
               --  Refused as a typed turn is: see Submit.
               Pres.Report (Screen, E.Make (E.IO_Invalid_UTF8));
            elsif Conv.Length (Messages) = 0
              or else Conv.Sender_At (Messages, Conv.Length (Messages))
                      not in Conv.Assistant_Role | Conv.Tool_Role
              or else Calls_Unanswered = 0
            then
               --  Nothing asked for it. A tool answer before the model has
               --  said anything is an answer to a question nobody put.
               Pres.Put_Note (Screen, "cli.interactive.tool_unasked");
            else
               Take_Turn (Line (Asked.First .. Asked.Last), Conv.Tool_Role);
            end if;

         elsif Asked.Kind = Save_Conversation then
            if Path_Missing then
               Pres.Put_Note (Screen, "cli.interactive.path_needed");
            elsif Path_After /= "" then
               declare
                  Stray : E.Error_Info := E.Make (E.CLI_Unexpected_Operand);
               begin
                  E.Add_Text (Stray, "value", Path_After);
                  Pres.Report (Screen, Stray);
               end;
            else
               declare
                  Path  : constant String :=
                    Model_Runner.CLI.Project_Commands.From_Session_Start (Path_Asked);
                  Wrote : E.Error_Info;
               begin
                  Model_Runner.CLI.Checkpoint.Save (Path, Messages, Wrote);
                  if E.Is_Error (Wrote) then
                     Pres.Report (Screen, Wrote);
                  else
                     Pres.Put_Note
                       (Screen, "cli.interactive.saved",
                        [Loc.Named ("detail", Path)]);
                  end if;
               end;
            end if;

         elsif Asked.Kind = Load_Conversation then
            if Path_Missing then
               Pres.Put_Note (Screen, "cli.interactive.path_needed");
            elsif Path_After /= "" then
               declare
                  Stray : E.Error_Info := E.Make (E.CLI_Unexpected_Operand);
               begin
                  E.Add_Text (Stray, "value", Path_After);
                  Pres.Report (Screen, Stray);
               end;
            else
               declare
                  Path    : constant String :=
                    Model_Runner.CLI.Project_Commands.From_Session_Start (Path_Asked);
                  Loaded  : Boolean;
                  Outcome : E.Error_Info;
               begin
                  --  Loading replaces the conversation -- read once, and put
                  --  in its place only when it read -- so the old one goes,
                  --  and the cached positions with it.
                  Model_Runner.CLI.Checkpoint.Load
                    (Path, Messages, Loaded, Outcome, Replace => True, Check => Check_Loaded'Access);
                  if E.Is_Ok (Outcome) and then Loaded then
                     --  The pictures were gathered for it by the check; a
                     --  picture named for the conversation before is not
                     --  this one's.
                     L.Reset (Session);
                     if not Picture_Kept then
                        Free_Text (Next_Picture);
                     end if;
                     Have_Stats := False;
                  end if;
                  if E.Is_Error (Outcome) then
                     Pres.Report (Screen, Outcome);
                  elsif not Loaded then
                     Pres.Put_Note
                       (Screen, "cli.interactive.load_empty",
                        [Loc.Named ("detail", Path)]);
                  else
                     Pres.Put_Note
                       (Screen, "cli.interactive.loaded",
                        [Loc.Named ("detail", Path)]);
                  end if;
               end;
            end if;

         elsif Asked.Kind in Show_Picture | Show_Video then
            --  A picture, or a video's frames, for the next turn: named
            --  now, shown when the words that go with it are typed.
            if Path_Missing then
               Pres.Put_Note (Screen, "cli.interactive.path_needed");
            elsif Path_After /= "" then
               declare
                  Stray : E.Error_Info := E.Make (E.CLI_Unexpected_Operand);
               begin
                  E.Add_Text (Stray, "value", Path_After);
                  Pres.Report (Screen, Stray);
               end;
            elsif T.Is_Empty (Item.Projector_Path) then
               Pres.Put_Note (Screen, "cli.interactive.no_projector");
            else
               Free_Text (Next_Picture);
               --  Named while a message waits: that message's, dropped
               --  with it; named alone, the next message's.
               Picture_Kept := Pending (Typing) /= "";
               Next_Picture := new String'
                 (Model_Runner.CLI.Project_Commands.From_Session_Start (Path_Asked));
               Next_Is_Video := Asked.Kind = Show_Video;
               Pres.Put_Note
                 (Screen, "cli.interactive.picture_pending",
                  [Loc.Named ("detail", Next_Picture.all)]);
            end if;

         else
            --  An answer, however quiet: said as the error it is, with
            --  where the commands are listed.
            declare
               Unknown : E.Error_Info := E.Make (E.CLI_Unknown_Command);
            begin
               --  The nearest command there is, where one is near.
               declare
                  --  Its word, ended at a space or a tab as Parse ends it.
                  Typed : String renames First;
                  Near  : constant Model_Runner.Framework.Name_Lists.Vector :=
                    --  Every command: a typo may be in its first letters too.
                    Model_Runner.CLI.Completion.Candidates (Typed (Typed'First .. Typed'First));
                  --  One it begins -- /reqs is /req -- before one a letter away.
                  function Begun return String is
                     Found : Natural := 0;
                  begin
                     for Index in 1 .. Natural (Near.Length) loop
                        declare
                           One : constant String := Near (Index);
                        begin
                           if One'Length < Typed'Length
                             and then Typed (Typed'First .. Typed'First + One'Length - 1) = One
                             and then (Found = 0 or else One'Length > String'(Near (Found))'Length)
                           then
                              Found := Index;
                           end if;
                        end;
                     end loop;
                     return (if Found = 0 then "" else Near (Found));
                  end Begun;
                  First_Near : constant String :=
                    (if Begun /= "" then Begun else Model_Runner.Framework.Nearest (Typed, Near));
                  --  Another as near, where there is one: both offered, never
                  --  only the one that would forget the conversation.
                  function Also_Near return String is
                     Rest_Of : Model_Runner.Framework.Name_Lists.Vector;
                  begin
                     if First_Near = "" or else Begun /= ""
                       or else Ada.Characters.Handling.To_Lower (Typed) = Ada.Characters.Handling.To_Lower (First_Near)
                     then
                        return "";
                     end if;
                     for One of Near loop
                        if One /= First_Near then
                           Rest_Of.Append (One);
                        end if;
                     end loop;
                     return Model_Runner.Framework.Nearest (Typed, Rest_Of);
                  end Also_Near;
                  Best  : constant String :=
                    (if Also_Near = "" then First_Near else First_Near & " or " & Also_Near);
               begin
                  declare
                     --  An action of a register's command typed as a command of
                     --  its own -- /reconsider DEC-3 -- with an ID: that command.
                     Rest  : constant String :=
                       Ada.Strings.Fixed.Trim (Line (Line'First + Typed'Length .. Line'Last), Ada.Strings.Both);
                     Upper : constant String := Ada.Strings.Fixed.Head (Rest, 5);
                     Owner : constant String :=
                       (if Upper = "TASK-" then "/task"
                        elsif Upper (Upper'First .. Upper'First + 3) = "REQ-" then "/req"
                        elsif Upper (Upper'First .. Upper'First + 3) = "DEC-" then "/decision"
                        elsif Upper = "SPEC-" then "/spec" else "");
                  begin
                     E.Add_Text (Unknown, "value", T.Escape_Controls (Typed)
                                 & (if Owner /= "" and then Typed'Length > 1
                                    then " -- " & Owner & " " & Typed (Typed'First + 1 .. Typed'Last) & " " & Rest
                                         & " is the command"
                                    elsif Best /= "" then " -- did you mean " & Best & "?" else "")
                                 & " (/help lists the commands)");
                  end;
               end;
               Pres.Report (Screen, Unknown);
            end;
         end if;

         return True;
      end Handle_Command;

      --  Run one turn against the model.
      procedure Take_Turn
        (Prompt : String; Sender : Conv.Role := Conv.User_Role)
      is
         Rendered : Text_Access := null;
         Outcome  : E.Error_Info;
         Request  : Gen.Request;
         --  How many times this turn has had the conversation compacted
         --  for room: once keeping the last few turns, and once more
         --  keeping only the one being asked, where the first did not make
         --  room -- turns shorter than their digest lines are not made any
         --  shorter by folding them.
         Compactions : Natural := 0;
      begin
         Turn_Taken := False;
         Kept_Back := False;
         Picture_Failed := False;
         Turns_Asked := Turns_Asked + 1;
         if Sender = Conv.User_Role and then Next_Picture /= null then
            --  The words and the picture named for them, as one turn of
            --  parts, the path quoted as JSON quotes it.
            Conv.Append_Parts
              (Messages, Sender,
               "[{""type"": """
               & (if Next_Is_Video then "video" else "image")
               & """, ""path"": "
               & Model_Runner.Text.JSON_Quoted (Next_Picture.all)
               & "}, {""type"": ""text"", ""text"": "
               & Model_Runner.Text.JSON_Quoted (Prompt) & "}]",
               Outcome);
            Free_Text (Turn_Picture);
            Turn_Picture := Next_Picture;
            Turn_Is_Video := Next_Is_Video;
            Next_Picture := null;
            Picture_Kept := False;
         else
            Conv.Append (Messages, Sender, Prompt, Outcome);
         end if;
         --  Not taken in -- the conversation full -- is kept back too: the
         --  message typed, and its picture, are not lost for it.
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Kept_Back := Sender = Conv.User_Role;
            return;
         end if;

         Gather_Pictures (Outcome);
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Conv.Drop_Last (Messages, 1);
            Kept_Back := Sender = Conv.User_Role;
            --  Not read for being stopped is the picture still; any other
            --  failure is the picture's own.
            Picture_Failed :=
              not (Model_Runner.Cancellation."/=" (Cancel, null)
                   and then Model_Runner.Cancellation.Is_Cancelled (Cancel));
            --  And the pictures it gave, so the next turn does not take them
            --  for its own: a picture set counts what it holds, not which.
            Model_Runner.CLI.Pictures.Release (Pictures);
            return;
         end if;

         <<Rendering>>
         Render (Rendered, Outcome);
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Conv.Drop_Last (Messages, 1);
            Kept_Back := Sender = Conv.User_Role;
            --  And the pictures it gave, so the next turn does not take them
            --  for its own: a picture set counts what it holds, not which.
            Model_Runner.CLI.Pictures.Release (Pictures);
            return;
         end if;

         --  The room a turn of a conversation is given; see Reply_Tokens.
         --  The plain run's 256 cut a reasoning model off mid-thought.
         Request.Max_Tokens := Opt.Reply_Tokens (Item, L.Capacity (Session));
         Request.Sampling := Opt.Sampling_For (Item, Prepared);
         Request.Seed := Item.Seed;
         Request.Has_Seed := Item.Has_Seed;
         --  What the backend can be asked for, not what was asked. The
         --  same clamp the single-shot path makes: a backend that does not
         --  batch is given one token at a time rather than refused, and a
         --  capability is for deciding what to ask.
         --
         --  The clamp was written once and this path was left without it,
         --  so --interactive --backend reference refused its first turn.
         Request.Batch_Size :=
           (if L.Capability (Prepared).Supports_Batched
            then Item.Batch_Size
            else 1);
         --  Never here: a conversation is always rendered through a
         --  template, and the template is handed the beginning token's text
         --  and writes it where the model expects it. See the same decision,
         --  argued, in CLI.Execute.
         Request.Add_Beginning := False;
         Request.Retain_Text := True;
         --  The rendered conversation grows by an appended turn, so the cache
         --  usually holds an exact prefix of it and only the new suffix has to
         --  be evaluated.
         Request.Reuse_Committed_Prefix := True;
         Request.Hold_Back :=
           Model_Runner.Templates.Opening
             (L.Template (Prepared).all, Messages,
              Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
              Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
              Rendered.all,
              Thinking => Item.Thinking, Tools => Tools,
              Image_Marker => Model_Runner.CLI.Pictures.Picture_Marker (Seer),
              Video_Marker => Model_Runner.CLI.Pictures.Video_Marker (Seer),
              Literal => Content_Text'Access,
              Effort => Item.Effort);

         Gen.Release (Last_Result);
         Tidied.Answer_Only (Item.Hide_Reasoning);
         Unthought.Start_Reply
           (Inside => Model_Runner.Agent.Thought_Open ("", Rendered.all));
         --  At a terminal the think block is shown without its markers,
         --  in italics where answers are styled; written elsewhere, the
         --  text is the model's as it wrote it.
         Unthought.Show_Reasoning (not Item.Hide_Reasoning);
         Sink.Use_Styles (Pres.Styles_Answers (Screen));
         Gen.Generate
           (Source   => Prepared,
            Session  => Session,
            Prompt   => Rendered.all,
            Item     => Request,
            Stop_Set => Stop_Set,
            Rules    => Rules,
            Sink     =>
              (if Harmony then Tidied'Unchecked_Access
               elsif Item.Hide_Reasoning or else Model_Runner.Platform.Is_Terminal (1)
               then Unthought'Unchecked_Access
               else Sink'Unchecked_Access),
            Observer => null,
            Time     => Clock'Unchecked_Access,
            Seeds    => Seeds'Unchecked_Access,
            Cancel   => Cancel,
            Pictures => Pictures,
            Outcome  => Last_Result);

         Free_Text (Rendered);

         --  Nobody reads the answers any more -- the terminal or the pipe
         --  is gone -- so the session ends, as it ends at end of input,
         --  rather than reading lines to answer into nowhere.
         if Last_Result.Reason = Gen.Output_Closed then
            Conv.Drop_Last (Messages, 1);
            Model_Runner.CLI.Pictures.Release (Pictures);
            Leaving := True;
            return;
         end if;

         begin
            Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Output);
         exception
            --  Closed between the answer and its line end: as above.
            when others =>
               Conv.Drop_Last (Messages, 1);
               Model_Runner.CLI.Pictures.Release (Pictures);
               Leaving := True;
               return;
         end;

         if Last_Result.Reason = Gen.Runtime_Error then
            declare
               --  A turn the context had no room for: refused before any
               --  of it was read, or out of room as it answered. Either way
               --  the session holds what it committed and no more.
               Out_Of_Room : constant Boolean :=
                 Last_Result.Error.Code in E.Generation_Prompt_Too_Long
                                         | E.Generation_Context_Exhausted;
               Gone : Natural := 0;
            begin
               --  The conversation compacted, as a /work agent's is, and the
               --  turn asked again; twice at most a turn.
               while Out_Of_Room and then Gone = 0 and then Compactions < 2 loop
                  Compactions := Compactions + 1;
                  --  A synopsis the context has room for: at most half
                  --  as many characters as it has positions, and an
                  --  eighth the second time -- the default's 2,560 filled
                  --  a context of a few hundred alone.
                  Conv.Compact
                    (Messages, Keep_Recent => (if Compactions = 1 then 6 else 1),
                     Dropped => Gone,
                     Synopsis_Room =>
                       Positive'Max
                         (Conv.Least_Synopsis,
                          Natural'Min
                            (Conv.Default_Synopsis,
                             L.Capacity (Session)
                             / (if Compactions = 1 then 2 else 8))));
                  if Gone > 0 then
                     Pres.Put_Note
                       (Screen, "cli.interactive.compacted",
                        [Loc.Named ("value", T.Image (Long_Long_Integer (Gone)))]);
                     --  The pictures gathered again: a picture set counts
                     --  what it holds, not which, and one of a turn the
                     --  compaction folded stayed in it while its marker
                     --  left the render -- the turn asked again was refused
                     --  for a count that did not match.
                     Model_Runner.CLI.Pictures.Release (Pictures);
                     Gather_Pictures (Outcome);
                     if E.Is_Error (Outcome) then
                        Pres.Report (Screen, Outcome);
                        Conv.Drop_Last (Messages, 1);
                        Model_Runner.CLI.Pictures.Release (Pictures);
                        Kept_Back := Sender = Conv.User_Role;
                        return;
                     end if;
                     goto Rendering;
                  end if;
               end loop;

               Pres.Report (Screen, Last_Result.Error);
               --  An unfinished assistant response is not committed.
               Conv.Drop_Last (Messages, 1);
               --  And the pictures it gave, so the next turn does not take them
               --  for its own: a picture set counts what it holds, not which.
               Model_Runner.CLI.Pictures.Release (Pictures);
               --  The session is read again from the start only where it
               --  may hold what was not committed: an error of its own, or
               --  recurrent states a stopped batch may have moved. A turn
               --  refused for room read nothing, and the next turn's prefix
               --  reuse keeps what the cache holds -- it cost a thirty
               --  thousand token conversation read again whole.
               if not Out_Of_Room
                 or else L.States_Kept (Session) /= Natural'Last
               then
                  L.Reset (Session);
               end if;
               Have_Stats := False;
               return;
            end;
         end if;

         if Last_Result.Reason = Gen.Cancelled then
            Conv.Drop_Last (Messages, 1);
            --  And the pictures it gave, so the next turn does not take them
            --  for its own: a picture set counts what it holds, not which.
            Model_Runner.CLI.Pictures.Release (Pictures);
            --  A cancelled evaluation commits no position, so a session
            --  that keeps every position still holds exactly what it
            --  committed, and the next turn rewinds to where it and the
            --  conversation agree: a stopped answer cost the whole
            --  conversation read again. A session with recurrent states
            --  may have had some layers' states moved by the stopped
            --  batch, and is read again.
            if L.States_Kept (Session) /= Natural'Last then
               L.Reset (Session);
            end if;
            Have_Stats := False;
            return;
         end if;

         --  Commit the assistant turn only after a valid completion. Where
         --  tools were offered the reply is taken apart into what the model
         --  said and what it asked for, so that the calls reach the next
         --  turn as the model's own template writes them rather than as the
         --  model happened to spell them.
         --  A reply the token limit stopped is said to have been: nothing
         --  else would say the answer was cut.
         --  With the reasoning left out, one stopped before its answer
         --  showed nothing, which is said as such.
         if Last_Result.Reason = Gen.Maximum_Tokens then
            Pres.Put_Note
              (Screen,
               (if Item.Hide_Reasoning
                  and then (if Harmony then Tidied.Showed_Nothing
                            else Unthought.Showed_Nothing)
                then "cli.run.reasoning_cut"
                else "cli.interactive.reply_cut"),
               [Loc.Named ("value", T.Image (Long_Long_Integer (Request.Max_Tokens)))]);
         end if;

         if Tools /= null and then Model_Runner.Tools.Count (Tools.all) > 0
         then
            declare
               Reading : E.Error_Info;
            begin
               --  Read in the shape the model's own format writes calls,
               --  against the tools it was offered, as the agent reads them.
               --  Reasoning the limit cut off is closed first.
               Conv.Append_Reply
                 (Messages,
                  Conv.Closed_Reasoning (Gen.Generated_Text (Last_Result)),
                  Outcome,
                  Reading,
                  Syntax  => Model_Runner.Templates.Syntax_Of (L.Template_Format (Prepared)),
                  Offered => Tools);
               if E.Is_Error (Reading) then
                  Pres.Report (Screen, Reading);
               end if;
            end;
         else
            Conv.Append
              (Messages, Conv.Assistant_Role,
               Conv.Reply_Turn
                 (Gen.Generated_Text (Last_Result),
                  Model_Runner.Templates.Syntax_Of
                    (L.Template_Format (Prepared))),
               Outcome);
         end if;

         --  A reply with nothing to keep as a turn -- gpt-oss cut while
         --  still in its analysis, or an end at once -- is not an error of
         --  the conversation: the question stays, answered by an elision,
         --  and the cache that holds it is kept. Dropped, the question was
         --  lost and the whole conversation read again.
         if E."=" (Outcome.Code, E.Conversation_Empty)
           and then Conv.Length (Messages) > 0
           and then not Conv."=" (Conv.Sender_At (Messages, Conv.Length (Messages)), Conv.Assistant_Role)
         then
            Conv.Append (Messages, Conv.Assistant_Role, Elided_Reply, Outcome);
         end if;

         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Conv.Drop_Last (Messages, 1);
            --  And the pictures it gave, so the next turn does not take them
            --  for its own: a picture set counts what it holds, not which.
            Model_Runner.CLI.Pictures.Release (Pictures);
            L.Reset (Session);
            --  Its figures are of a turn the conversation does not hold.
            Have_Stats := False;
            return;
         end if;

         --  What the reply asks for, shown. The reply itself has already
         --  been streamed; this is the part of it that needs an answer, and
         --  a caller who has to find it by eye in a page of text will find
         --  it wrong. Read back out of the turn rather than out of the
         --  reply a second time: what the model asked for is what the
         --  conversation now holds.
         if Tools /= null then
            for Index in 1 .. Conv.Call_Count (Messages, Conv.Length (Messages))
            loop
               declare
                  Named : constant String :=
                    Conv.Call_Name (Messages, Conv.Length (Messages), Index);
               begin
                  Pres.Put_Note
                    (Screen, "cli.interactive.tool_call",
                     [Loc.Named ("name", Named),
                      Loc.Named
                        ("arguments",
                         Conv.Call_Arguments
                           (Messages, Conv.Length (Messages), Index))]);

                  if not Model_Runner.Tools.Offers (Tools.all, Named) then
                     Pres.Put_Note
                       (Screen, "cli.interactive.tool_unknown",
                        [Loc.Named ("name", Named)]);
                  end if;
               end;
            end loop;
         end if;

         Turn_Taken := True;
         Have_Stats := True;
         if Item.Show_Stats then
            Pres.Put_Statistics (Screen, Last_Result);
         end if;
      end Take_Turn;

      --  Submit whatever has accumulated, if anything.
      --  Whether the last line was a command, not words for the model.
      After_Command : Boolean := False;

      procedure Submit is
      begin
         if Pending (Typing) = "" then
            return;
         end if;
         Warming.Settled;

         declare
            Prompt : constant String := Pending (Typing);
            Word   : constant String := Ada.Characters.Handling.To_Lower (T.Trim (Prompt));
         begin
            Taken (Typing);

            --  A lone yes or no just after a command answers nothing: the
            --  command asked no question, and the model was not being
            --  talked to. Said so, and sent only if it is sent again.
            if After_Command and then Word in "y" | "n" | "yes" | "no" | "j" | "ja" | "nej" then
               After_Command := False;
               Pres.Put_Note (Screen, "cli.interactive.no_question", [Loc.Named ("value", T.Trim (Prompt))]);
               return;
            end if;
            After_Command := False;
            if Model_Runner.UTF8.Is_Valid (Prompt) then
               --  What changed in the project since the model last spoke,
               --  said before the turn: its earlier talk of the project
               --  may no longer hold.
               --  Seen once the turn that was told is in the conversation: a
               --  turn stopped or refused told the model nothing, and the
               --  next one says it again.
               declare
                  Seen : Natural := Project_Seen;
                  Told : constant String := Model_Runner.CLI.Project_Commands.Changes_Since (Seen);
               begin
                  Take_Turn (Told & Prompt);
                  if Turn_Taken then
                     Project_Seen := Seen;
                  end if;
                  --  Refused before the model read it: the message kept,
                  --  pending, to add to or send again, with its picture --
                  --  /image names another while it waits.
                  if Kept_Back and then Turn_Picture /= null and then not Picture_Failed then
                     Free_Text (Next_Picture);
                     Next_Picture := Turn_Picture;
                     Next_Is_Video := Turn_Is_Video;
                     Turn_Picture := null;
                     Picture_Kept := True;
                  else
                     Free_Text (Turn_Picture);
                  end if;
                  if Kept_Back then
                     --  Whole, as it was: offered again line by line, a
                     --  first line that looked like a command was dropped,
                     --  and so were its blank lines.
                     Restore (Typing, Prompt);
                     Pres.Put_Note (Screen, "cli.interactive.message_kept");
                  end if;
               end;
            else
               Pres.Report (Screen, E.Make (E.IO_Invalid_UTF8));
            end if;
         end;
      end Submit;

      Toucher : Toucher_Guard;
      Turn    : Turn_Guard;
      pragma Unreferenced (Turn);

      task Warmer;

      task body Warmer is
      begin
         if L.Position (Session) = 0 then
            declare
               use type Model_Runner.Tensors.Real_Array_Access;
               Logits : Model_Runner.Tensors.Real_Array_Access := null;
               Local  : E.Error_Info;
            begin
               Model_Runner.Tensors.Allocate
                 (Model_Runner.Numerics.Element_Count
                    (L.Config (Prepared).Vocabulary),
                  Logits);
               if Logits /= null then
                  begin
                     L.Evaluate
                       (Session, Prepared, Words.Beginning_Token, Logits,
                        Cancel => Warm_Token, Status => Local);
                  exception
                     --  Raised rather than said: the session read back to
                     --  nothing all the same, and the logits freed.
                     when others =>
                        null;
                  end;
                  L.Reset (Session);
                  Model_Runner.Tensors.Free (Logits);
               end if;
            end;
         end if;
         Warming.Finish;

         --  And the processor's pages behind it, read on alone.
         Toucher.Running := new Page_Toucher;
         Toucher.Running.Start (Prepared'Unchecked_Access);
      exception
         when others =>
            Warming.Finish;
      end Warmer;

   begin
      Status := E.Exit_Success;
      Worker.Work_Session := Work_Session'Unchecked_Access;
      Worker.Helper_Session := Helper_Session'Unchecked_Access;

      --  Speech input, where a speech model is named; nothing is read or
      --  recorded until the shortcut is pressed.
      Model_Runner.CLI.Speech_Input.Open (Speech, Item);

      --  Conversation mode needs a usable template; raw mode is not offered
      --  interactively because the turn structure would have nowhere to go.
      if not L.Template_Ready (Prepared) then
         Pres.Report (Screen, L.Template_Condition (Prepared));
         Status := E.Exit_Status (L.Template_Condition (Prepared));
         Stop_Warming;
         return;
      end if;

      Conv.Open (Messages, Bounds, Condition);
      if E.Is_Error (Condition) then
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
         Stop_Warming;
         return;
      end if;

      --  A project in the session's directory is looked at before anything
      --  is asked of it.
      Model_Runner.CLI.Project_Commands.Recover_Here (Screen);
      --  Seen as of the project the session is on: read before the move
      --  up to its top, it was nought, and the first turn told the model
      --  the project's history as news.
      Project_Seen := Model_Runner.CLI.Project_Commands.Project_Revision;

      --  A stop the set refuses, or a token the vocabulary has not got,
      --  refused as run refuses it: taken in silence, the conversation ran
      --  with no stop where one was asked for.
      Model_Runner.Stops.Open (Stop_Set, Bounds);
      for Index in 1 .. Item.Stop_Count loop
         Model_Runner.Stops.Add_String
           (Stop_Set, T.To_String (Item.Stop_Strings (Index)), Condition);
         exit when E.Is_Error (Condition);
      end loop;
      if E.Is_Ok (Condition) then
         for Index in 1 .. Item.Stop_Token_Count loop
            if Item.Stop_Tokens (Index) >= Long_Long_Integer (Vocab.Size (Words.all)) then
               Condition := E.Make (E.CLI_Option_Out_Of_Range);
               E.Add_Text (Condition, "option", "--stop-token", E.Param_Identifier);
               E.Add_Text (Condition, "value", Long_Long_Integer'Image (Item.Stop_Tokens (Index)));
               E.Add_Integer (Condition, "minimum", 0);
               E.Add_Integer (Condition, "maximum", Long_Long_Integer (Vocab.Size (Words.all)) - 1);
               exit;
            end if;
            Model_Runner.Stops.Add_Token
              (Stop_Set, Vocab.Token_Id (Item.Stop_Tokens (Index)), Condition);
            exit when E.Is_Error (Condition);
         end loop;
      end if;
      if E.Is_Error (Condition) then
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
         Model_Runner.Stops.Close (Stop_Set);
         Conv.Close (Messages);
         Stop_Warming;
         return;
      end if;

      if Item.Has_System and then Item.System_Text /= null then
         Conv.Set_System (Messages, Item.System_Text.all, Condition);
         if E.Is_Error (Condition) then
            Pres.Report (Screen, Condition);
         end if;
      end if;

      declare
         Ready : Boolean;
      begin
         Open (Typing, Ready);
         if not Ready then
            Pres.Report (Screen, E.Make (E.Memory_Allocation_Failed));
            Model_Runner.Stops.Close (Stop_Set);
            Conv.Close (Messages);
            Status := E.Exit_Resource;
            Stop_Warming;
            return;
         end if;
      end;

      Pres.Put_Note (Screen, "cli.interactive.banner");
      --  A sandbox the shell sets that does not read confines every agent
      --  to nothing: said at once, not found out from a refusal.
      if Model_Runner.Framework.Permissions.Sandbox_Problem /= "" then
         Pres.Put_Note (Screen, "cli.task.sandbox_bad",
                        [Loc.Named ("detail", Model_Runner.Framework.Permissions.Sandbox_Problem)]);
      end if;

      --  Next steps are said as they are typed here.
      Pres.Use_Session (Screen, True);

      --  Esc is left for the terminal to show as ^[: hidden, it echoes
      --  as the key itself, which swallows the next one typed.

      Read_Loop :
      while not Leaving loop
         --  The prompt marker goes to standard error so that a redirected
         --  standard output still receives only generated text.
         --  At a terminal the line is edited, and its prompt drawn, as it is
         --  typed; elsewhere the prompt is said and a line read.
         if not Model_Runner.CLI.Choosers.Is_Available (Screen) then
            Pres.Put_Prompt
              (Screen,
               (if Pending (Typing) = ""
                then "cli.interactive.prompt"
                else "cli.interactive.continuation"));
         end if;

         --  No End_Of_File before the line: at a terminal it reads ahead
         --  past the line mark, and waits for the line after the one typed.
         --  The end of input is found by reading, and ends the loop.

         declare
            --  Read into a fixed buffer rather than as a String: the function
            --  form puts a whole line on the stack, and a line has no length
            --  this program chooses. The prompt file and standard input are
            --  read this way for the same reason.
            --
            --  Current_Input rather than Standard_Input, so that a caller can
            --  redirect it. The program never does -- the driver refuses
            --  interactive mode unless both descriptors are terminals, and
            --  Current_Input is Standard_Input until something says otherwise
            --  -- but a test can, and until it could, nothing exercised this
            --  loop at all.
            --  Grown to the line, which a paste may make tens of kilobytes:
            --  bounded at eight, a pasted paragraph ended the turn it was
            --  part of.
            Held_Line : Line_Holder :=
              (Ada.Finalization.Limited_Controlled with
               Text => new String (1 .. 8192));
            Room : Text_Access renames Held_Line.Text;
            Stop : Natural;

            --  Whether the line was edited as it was typed, coloured then.
            Edited : Boolean := False;
            --  Whether the line read was longer than a turn may be, and
            --  the rest of it is still to be skipped.
            Cut_Short : Boolean := False;

            --  The wait for the line, said to the handler and ended however
            --  this is left: an exception past it left the program said to
            --  wait, and a later ending skipped stopping and saving the run.
            Wait_Held : Model_Runner.Platform.Signals.Waiting.Guard;

            Effect  : Line_Effect;
            Handled : Boolean;
            pragma Unreferenced (Handled);
         begin
            begin
               --  An interrupt that stopped what ran before is spent: one
               --  seen once the line comes was pressed while it was typed.
               if Model_Runner.Cancellation."/=" (Cancel, null)
                 and then Model_Runner.Cancellation.Is_Cancelled (Cancel)
               then
                  Cancel.Reset;
               end if;
               Model_Runner.Platform.Signals.Waiting.Begin_Wait
                 (Wait_Held, Note => Pres.Message_Value
                                  (Screen, (if Pending (Typing) = "" then "cli.interactive.dropped_line"
                                            else "cli.interactive.dropped")) & ASCII.LF
                                --  What was typed is dropped: the prompt is
                                --  the first line's again.
                                & Pres.Message_Value (Screen, "cli.interactive.prompt") & " ");
               --  The device lent while the line is waited for, once the
               --  model is warm: nothing of the conversation's runs then,
               --  and speech heard meanwhile may borrow it. Held first, as
               --  it starts lent and the warming may still be running;
               --  taken back, once any borrower is done, before the line is
               --  answered.
               Model_Runner.Backend.Device.Take_Turn;
               Warming.Enter_Line;
               declare
                  Asked_At : constant Ada.Calendar.Time := Ada.Calendar.Clock;
                  use type Ada.Calendar.Time;
               begin
                  declare
                     use type Model_Runner.CLI.Choosers.Line_End;
                     Key    : constant String :=
                       (if Pending (Typing) = "" then "cli.interactive.prompt" else "cli.interactive.continuation");
                     Ending : Model_Runner.CLI.Choosers.Line_End;
                     Got    : constant String :=
                       Model_Runner.CLI.Choosers.Edited_Line
                         (Screen, Pres.Message_Value (Screen, Key) & " ", Ending,
                          Complete => Model_Runner.CLI.Completion.Candidates'Access,
                          Describe => Model_Runner.CLI.Completion.Described'Access,
                          Dictate  =>
                            (if Model_Runner.CLI.Speech_Input.Is_Enabled (Speech)
                             then Speech'Unchecked_Access else null),
                          Shortcut => Item.Speech_Shortcut);
                     --  Escape and Ctrl-C drop the line, as when a cooked
                     --  terminal passes them on: the key after what was typed.
                     Whole  : constant String :=
                       (case Ending is
                          when Model_Runner.CLI.Choosers.Escaped     => Got & ASCII.ESC,
                          when Model_Runner.CLI.Choosers.Interrupted => Got & ASCII.ETX,
                          when others                                => Got);
                  begin
                     if Ending = Model_Runner.CLI.Choosers.Unavailable then
                        Stop := 0;
                        loop
                           Ada.Text_IO.Get_Line
                             (Ada.Text_IO.Current_Input,
                              Room (Stop + 1 .. Room'Last), Stop);
                           exit when Stop < Room'Last;
                           --  Full: the line's end is the next thing, and
                           --  read here -- left, it was an empty line, which
                           --  submits -- or the room grows for the rest.
                           if Ada.Text_IO.End_Of_Line
                                (Ada.Text_IO.Current_Input)
                           then
                              --  At the end of input with no line feed
                              --  after it, there is no line end to skip:
                              --  the line is kept, and the next read ends.
                              begin
                                 Ada.Text_IO.Skip_Line
                                   (Ada.Text_IO.Current_Input);
                              exception
                                 when Ada.Text_IO.End_Error =>
                                    null;
                              end;
                              exit;
                           end if;
                           if Room'Length >= Max_Turn_Bytes then
                              Cut_Short := True;
                              exit;
                           end if;
                           Grow (Room, 2 * Room'Length);
                        end loop;
                     elsif Ending = Model_Runner.CLI.Choosers.Ended then
                        raise Ada.Text_IO.End_Error;
                     else
                        Edited := True;
                        if Whole'Length > Room'Length then
                           Grow (Room, Whole'Length);
                        end if;
                        Stop := Whole'Length;
                        Room (1 .. Stop) := Whole;
                     end if;
                  end;
                  --  Ctrl-L asks for a clear screen, as a shell's line does:
                  --  the screen cleared, and the key not part of the line.
                  if Ada.Strings.Fixed.Index (Room (Room'First .. Stop), [1 => ASCII.FF]) > 0 then
                     declare
                        Kept : Natural := Room'First - 1;
                     begin
                        for Index in Room'First .. Stop loop
                           if Room (Index) /= ASCII.FF then
                              Kept := Kept + 1;
                              Room (Kept) := Room (Index);
                           end if;
                        end loop;
                        Stop := Kept;
                     end;
                     Pres.Clear_Screen (Screen);
                  end if;
                  --  Typed while a /work ran, unshown then: there at once
                  --  now, and shown as what is run.
                  --  Every line typed then, not the first alone: each comes at
                  --  once, and is shown on a line of its own.
                  if Model_Runner.CLI.Project_Commands.Typed_During_Work then
                     Draining := True;
                  end if;
                  if Draining and then Ada.Calendar.Clock - Asked_At < 0.3 and then Stop >= Room'First then
                     Pres.Put_After_Prompt (Screen, "cli.interactive.typed_during_work",
                                    [Loc.Named ("value", T.Escape_Controls (Room (Room'First .. Stop)))]);
                  else
                     Draining := False;
                  end if;
               end;
               Model_Runner.Platform.Signals.Waiting.Stop_Wait (Wait_Held);
               Warming.Leave_Line;
               Model_Runner.Backend.Device.Take_Turn;
            exception
               when Ada.Text_IO.End_Error =>
                  Model_Runner.Platform.Signals.Waiting.Stop_Wait (Wait_Held);
                  Warming.Leave_Line;
                  Model_Runner.Backend.Device.Take_Turn;
                  exit Read_Loop;
            end;

            --  A line longer than the buffer arrives in pieces. Joining them
            --  would be the same turn; treating each as a line would put line
            --  feeds inside what the user typed as one. Neither is worth the
            --  code, so a line this long ends the turn it is part of.
            --  Asked of the read itself, not of the input after it: a line
            --  that filled the room exactly had its end read already, and
            --  End_Of_Line asked of the next line -- waiting for one at a
            --  terminal, and skipping it unread where it came.
            if Cut_Short then
               begin
                  Ada.Text_IO.Skip_Line (Ada.Text_IO.Current_Input);
               exception
                  when Ada.Text_IO.End_Error =>
                     null;
               end;
               Drop_Message;
               declare
                  Refused : E.Error_Info := E.Make (E.Conversation_Too_Long);
               begin
                  E.Add_Integer
                    (Refused, "limit", Long_Long_Integer (Max_Turn_Bytes),
                     E.Param_Bytes);
                  Pres.Report (Screen, Refused);
               end;
            else
               declare
                  --  Control characters a cooked terminal passes on as they
                  --  are -- Ctrl-L -- are no part of what was typed.
                  function Cleaned (Text : String) return String is
                  begin
                     for Index in Text'Range loop
                        if Text (Index) = ASCII.FF then
                           return Text (Text'First .. Index - 1)
                             & Cleaned (Text (Index + 1 .. Text'Last));
                        end if;
                     end loop;
                     return Text;
                  end Cleaned;
                  Typed : constant String := Cleaned (Room (1 .. Stop));

                  --  Esc on a line drops what was typed before it, as does
                  --  Ctrl-C where the terminal passes it on as a character;
                  --  what follows the last of them is the line.
                  Last_Key : constant Natural :=
                    Natural'Max
                      (Ada.Strings.Fixed.Index (Typed, [1 => ASCII.ESC], Ada.Strings.Backward),
                       Ada.Strings.Fixed.Index (Typed, [1 => ASCII.ETX], Ada.Strings.Backward));
                  Line     : constant String :=
                    (if Last_Key = 0 then Typed else Typed (Last_Key + 1 .. Typed'Last));
               begin
                  if Last_Key > 0 then
                     --  An Esc the terminal echoed as it is leaves a sequence
                     --  open the next output would end, losing its first
                     --  character: cancelled first.
                     if not Edited then
                        Ada.Text_IO.Put (Ada.Text_IO.Standard_Error, ASCII.CAN);
                     end if;
                     --  Something before the key was dropped: said. Nothing
                     --  was -- the key pressed on an empty line -- nothing
                     --  to say; and what follows it, shown, as the echo of
                     --  the key hid it.
                     if T.Trim (Typed (Typed'First .. Last_Key - 1)) /= "" or else Pending (Typing) /= "" then
                        Pres.Put_Note
                          (Screen, "cli.interactive.dropped_key",
                           [Loc.Named ("name", (if Typed (Last_Key) = ASCII.ESC then "Esc" else "Ctrl-C"))]);
                     --  Ctrl-C with nothing typed: how to leave, as a shell
                     --  would not say but a person looks for.
                     elsif Typed (Last_Key) = ASCII.ETX then
                        Pres.Put_Note (Screen, "cli.interactive.how_to_leave");
                     end if;
                     Drop_Message;
                     if Line = "" then
                        goto Next_Line;
                     end if;
                     Pres.Put_After_Prompt (Screen, "cli.interactive.line_after_key",
                                            [Loc.Named ("value", T.Escape_Controls (Line))]);
                  end if;
                  --  Ctrl-C while a prompt was being typed drops it: the
                  --  line after starts afresh.
                  if Model_Runner.Cancellation."/=" (Cancel, null)
                    and then Model_Runner.Cancellation.Is_Cancelled (Cancel)
                  then
                     Drop_Message;
                     --  Said when it was pressed, where it could be.
                     if not Model_Runner.Platform.Signals.Interrupt_Noted then
                        Pres.Put_Note (Screen, "cli.interactive.dropped");
                     end if;
                  end if;

                  --  An interrupt stops what the line starts, not one typed
                  --  before it.
                  if Model_Runner.Cancellation."/=" (Cancel, null) then
                     Cancel.Reset;
                  end if;
                  --  At a terminal Enter sends the message, as a chat's
                  --  line does; a line ending in a backslash goes on to the
                  --  next, and a paste brings its own line ends. Read from
                  --  elsewhere, lines gather until an empty one.
                  declare
                     Goes_On : constant Boolean :=
                       Edited and then Line'Length > 0 and then Line (Line'Last) = '\';
                  begin
                     Offer (Typing,
                            (if Goes_On then Line (Line'First .. Line'Last - 1) else Line),
                            Effect);
                     if Edited and then not Goes_On and then Effect = Held then
                        Effect := Submits;
                     end if;
                  end;
                  case Effect is
                     when Is_Command =>
                        --  Offer says so only for a line Parse reads as one,
                        --  so the answer here is always True and is not
                        --  consulted.
                        declare
                           Before : constant Natural := Turns_Asked;
                        begin
                           Handled := Handle_Command (T.Trim (Line));
                           After_Command := Turns_Asked = Before;
                        end;

                     when Command_Mid_Message =>
                        --  The message pending was typed before the
                        --  command, not after it: a yes in it answers what
                        --  the model asked, and is not refused as one said
                        --  just after a command.
                        Handled := Handle_Command (T.Trim (Line));
                        After_Command := False;
                        Pres.Put_Note (Screen, "cli.interactive.message_kept");

                     when Submits =>
                        --  A blank line submits; an empty submission is
                        --  ignored.
                        Submit;

                     when Too_Long =>
                        --  Offer let the message go: its picture goes with it.
                        Drop_Kept_Picture;
                        declare
                           Refused : E.Error_Info :=
                             E.Make (E.Conversation_Too_Long);
                        begin
                           E.Add_Integer
                             (Refused, "limit",
                              Long_Long_Integer (Max_Turn_Bytes),
                              E.Param_Bytes);
                           Pres.Report (Screen, Refused);
                        end;

                     when Held =>
                        null;
                  end case;
               end;
            end if;
         end;
         <<Next_Line>>
         --  Told to end while something ran: it ends once that stopped.
         if Model_Runner.Platform.Signals.Ending_Asked then
            Status := E.Exit_Cancelled;
            Leaving := True;
            exit Read_Loop;
         end if;
      end loop Read_Loop;
      if Keys_Hidden then
         Keys_Hidden := Hostkit.Terminal_Control.Show_Control_Keys (Hostkit.Descriptors.Standard_Input, True);
      end if;

      --  At end of file a pending prompt is submitted, then the session ends
      --  -- as a cancellation where it was told to end while it ran.
      if not Leaving then
         Submit;
         if Model_Runner.Platform.Signals.Ending_Asked then
            Status := E.Exit_Cancelled;
         end if;
      end if;

      Gen.Release (Last_Result);
      Model_Runner.Stops.Close (Stop_Set);
      Conv.Close (Messages);
      Close (Typing);
      Release_Pictures;
   exception
      when Failure : others =>
         Gen.Release (Last_Result);
         Model_Runner.Stops.Close (Stop_Set);
         Conv.Close (Messages);
         Close (Typing);
         Release_Pictures;
         Pres.Report (Screen, E.Unexpected (Failure, "chat"));
         Status := E.Exit_Internal;
   end Run;

end Model_Runner.CLI.Interactive;
