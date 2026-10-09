with Ada.Finalization;
with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Hostkit.Descriptors;
with Hostkit.Terminal_Control;

with Model_Runner.CLI.Checkpoint;
with Model_Runner.CLI.Choosers;
with Model_Runner.CLI.Completion;
with Model_Runner.CLI.Project_Commands;
with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Limits;
with Model_Runner.Framework.Permissions;
with Model_Runner.Localization;
with Model_Runner.Platform.Signals;
with Model_Runner.Sampling;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.UTF8;
with Model_Runner.CLI.Pictures;
with Model_Runner.Vision;

package body Model_Runner.CLI.Interactive is

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
   begin
      if Item.Room = null then
         Effect := Too_Long;
         return;
      end if;

      --  A command only when nothing is pending. A slash on the second line
      --  of a prompt is the text it looks like: someone typing "and then
      --  run" and "/usr/bin/ls" means the path, and reading it as a command
      --  would drop the half they had already typed.
      if Item.Used = 0
        and then Parse (Trimmed).Kind /= Not_A_Command
      then
         Effect := Is_Command;
         return;
      end if;

      --  A project command, typed while a message is: run, and the message
      --  kept to go on with -- not taken into it as its text. The
      --  session's own commands, and a path, are still the text they are.
      if Item.Used > 0
        and then Model_Runner.CLI.Project_Commands.Is_Project_Command
                   (Trimmed (Trimmed'First
                             .. (if Ada.Strings.Fixed.Index (Trimmed, " ") = 0 then Trimmed'Last
                                 else Ada.Strings.Fixed.Index (Trimmed, " ") - 1)))
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
            Item.Used := 0;
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

   -----------
   -- Taken --
   -----------

   procedure Taken (Item : in out Turn) is
   begin
      Item.Used := 0;
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
      while Stop <= Line'Last and then Line (Stop) /= ' ' loop
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
         while First <= Last and then Line (First) = ' ' loop
            First := First + 1;
         end loop;
         while Last >= First and then Line (Last) = ' ' loop
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

      Messages : Conv.History;
      Stop_Set : aliased Model_Runner.Stops.Set;

      --  The session's own model, as the agent /work runs on a task.
      Asked_For : aliased constant Opt.Command := Item;
      Worker_Notes : aliased Model_Runner.CLI.Project_Commands.Run_Notes;
      Worker    : Model_Runner.CLI.Project_Commands.Session_Agent
        (Prepared'Unchecked_Access, Session'Unchecked_Access,
         Stop_Set'Unchecked_Access, Screen'Unchecked_Access,
         Asked_For'Unchecked_Access, Cancel, Worker_Notes'Unchecked_Access);
      Sink     : aliased Pres.Standard_Output_Sink;
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
      Seer         : Model_Runner.CLI.Pictures.Seer;
      Next_Picture : Text_Access := null;

      --  Whether what is named for the next turn is a video's frames
      --  rather than a picture.
      Next_Is_Video : Boolean := False;

      --  Encode what the conversation names and Pictures does not hold.
      procedure Gather_Pictures (Outcome : out E.Error_Info) is
         Named : Boolean := False;
      begin
         Outcome := E.Success;
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
         Model_Runner.CLI.Pictures.Gather
           (Seer, Messages, Pictures, L.Workers (Session), Item.Pan_And_Scan,
            Status => Outcome);
      end Gather_Pictures;

      procedure Release_Pictures is
      begin
         Model_Runner.CLI.Pictures.Release (Pictures);
         Model_Runner.CLI.Pictures.Close (Seer);
         Free_Text (Next_Picture);
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
            Video_Marker => Model_Runner.CLI.Pictures.Video_Marker (Seer));
         if E.Is_Ok (Outcome) then
            Rendered := new String'(Buffer.all (1 .. Last));
         end if;
         Free_Text (Buffer);
      end Render;

      --  Show the sampling settings in use. Option names are protocol and are
      --  printed as written.
      procedure Show_Settings is
         Default : constant Model_Runner.Sampling.Configuration := (others => <>);
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
            T.Image (Long_Float (Item.Sampling.Temperature), 3), Pres.Diagnostic,
            Tone_Of (Item.Sampling.Temperature /= Default.Temperature));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_k",
            T.Image (Long_Long_Integer (Item.Sampling.Top_K)), Pres.Diagnostic,
            Tone_Of (Item.Sampling.Top_K /= Default.Top_K));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_p",
            T.Image (Long_Float (Item.Sampling.Top_P), 3), Pres.Diagnostic,
            Tone_Of (Item.Sampling.Top_P /= Default.Top_P));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.min_p",
            T.Image (Long_Float (Item.Sampling.Min_P), 3), Pres.Diagnostic,
            Tone_Of (Item.Sampling.Min_P /= Default.Min_P));
         if Item.Has_Seed then
            Pres.Put_Field
              (Screen, "cli.interactive.setting.seed",
               T.Image (Item.Seed), Pres.Diagnostic, Pres.Pending);
         end if;
         Pres.Put_Heading (Screen, "cli.interactive.settings.repeating", Pres.Diagnostic, Gap => True);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_penalty",
            T.Image (Long_Float (Item.Sampling.Repeat_Penalty), 3), Pres.Diagnostic,
            Tone_Of (Item.Sampling.Repeat_Penalty /= Default.Repeat_Penalty));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_window",
            T.Image (Long_Long_Integer (Item.Sampling.Repeat_Window)), Pres.Diagnostic,
            Tone_Of (Item.Sampling.Repeat_Window /= Default.Repeat_Window));
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

      --  Handle one slash command. Returns True when the input was a command.
      function Handle_Command (Line : String) return Boolean is
         Asked : constant Parsed_Command := Parse (Line);
         Space : constant Natural := Ada.Strings.Fixed.Index (Line, " ");
         First : constant String :=
           (if Space = 0 then Line else Line (Line'First .. Space - 1));
      begin
         if Asked.Kind = Not_A_Command then
            return False;
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
            L.Reset (Session);
            Model_Runner.CLI.Pictures.Release (Pictures);
            Free_Text (Next_Picture);
            Have_Stats := False;
            Pres.Put_Note (Screen, "cli.interactive.reset_done");

         elsif Asked.Kind = Help
           and then Asked.First in Line'Range
           and then Line (Asked.First .. Asked.Last) = "project"
         then
            --  The project's commands, each with what it does.
            Model_Runner.CLI.Project_Commands.Help (Screen);

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
               --  The commands a line of help is kept for.
               Known : constant String :=
                 " projects exit reset help settings stats context system tools tool save load"
                 & " image video init bootstrap state config git sandbox instruct reconfigure task"
                 & " accept reject work cancel check req decision spec result tree sym refs deps"
                 & " users impact trace scan ";
            begin
               if Named /= "" and then Ada.Strings.Fixed.Index (Known, " " & Named & " ") > 0 then
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
               Used     : constant Natural := L.Position (Session);
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
               Conv.Set_System (Messages, Content, Outcome);
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
                     function String_Of (Key : String) return String is
                        At_Key : constant Natural := Ada.Strings.Fixed.Index (Definition, '"' & Key & '"');
                        Open   : Natural;
                        Stop   : Natural;
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
                          and then (Definition (Stop) /= '"' or else Definition (Stop - 1) = '\')
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
            elsif Conv.Length (Messages) = 0
              or else Conv.Sender_At (Messages, Conv.Length (Messages))
                      not in Conv.Assistant_Role | Conv.Tool_Role
            then
               --  Nothing asked for it. A tool answer before the model has
               --  said anything is an answer to a question nobody put.
               Pres.Put_Note (Screen, "cli.interactive.tool_unasked");
            else
               Take_Turn (Line (Asked.First .. Asked.Last), Conv.Tool_Role);
            end if;

         elsif Asked.Kind = Save_Conversation then
            if Asked.First = 0 then
               Pres.Put_Note (Screen, "cli.interactive.path_needed");
            else
               declare
                  Path : constant String := Line (Asked.First .. Asked.Last);
               begin
                  Model_Runner.CLI.Checkpoint.Save (Path, Messages);
                  Pres.Put_Note
                    (Screen, "cli.interactive.saved",
                     [Loc.Named ("detail", Path)]);
               end;
            end if;

         elsif Asked.Kind = Load_Conversation then
            if Asked.First = 0 then
               Pres.Put_Note (Screen, "cli.interactive.path_needed");
            else
               declare
                  Path    : constant String := Line (Asked.First .. Asked.Last);
                  Loaded  : Boolean;
                  Outcome : E.Error_Info;
               begin
                  --  Loading replaces the conversation, so the old one goes
                  --  and the cached positions with it.
                  Conv.Clear (Messages);
                  Model_Runner.CLI.Checkpoint.Load
                    (Path, Messages, Loaded, Outcome);
                  L.Reset (Session);
                  Model_Runner.CLI.Pictures.Release (Pictures);
                  Have_Stats := False;
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
            if Asked.First = 0 then
               Pres.Put_Note (Screen, "cli.interactive.path_needed");
            elsif T.Is_Empty (Item.Projector_Path) then
               Pres.Put_Note (Screen, "cli.interactive.no_projector");
            else
               Free_Text (Next_Picture);
               Next_Picture := new String'(Line (Asked.First .. Asked.Last));
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
                  Typed : constant String :=
                    (if Ada.Strings.Fixed.Index (Line & " ", " ") > Line'First
                     then Line (Line'First .. Ada.Strings.Fixed.Index (Line & " ", " ") - 1) else Line);
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
      begin
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
            Free_Text (Next_Picture);
         else
            Conv.Append (Messages, Sender, Prompt, Outcome);
         end if;
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            return;
         end if;

         Gather_Pictures (Outcome);
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Conv.Drop_Last (Messages, 1);
            return;
         end if;

         Render (Rendered, Outcome);
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Conv.Drop_Last (Messages, 1);
            return;
         end if;

         Request.Max_Tokens := Item.Max_Tokens;
         Request.Sampling := Item.Sampling;
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
              Video_Marker => Model_Runner.CLI.Pictures.Video_Marker (Seer));

         Gen.Release (Last_Result);
         Gen.Generate
           (Source   => Prepared,
            Session  => Session,
            Prompt   => Rendered.all,
            Item     => Request,
            Stop_Set => Stop_Set,
            Rules    => Rules,
            Sink     => Sink'Unchecked_Access,
            Observer => null,
            Time     => Clock'Unchecked_Access,
            Seeds    => Seeds'Unchecked_Access,
            Cancel   => Cancel,
            Pictures => Pictures,
            Outcome  => Last_Result);

         Free_Text (Rendered);
         Ada.Text_IO.New_Line (Ada.Text_IO.Standard_Output);

         if Last_Result.Reason = Gen.Runtime_Error then
            Pres.Report (Screen, Last_Result.Error);
            --  An unfinished assistant response is not committed, and the
            --  session is reset so that the next turn re-evaluates the prior
            --  committed conversation.
            Conv.Drop_Last (Messages, 1);
            L.Reset (Session);
            Have_Stats := False;
            return;
         end if;

         if Last_Result.Reason = Gen.Cancelled then
            Conv.Drop_Last (Messages, 1);
            L.Reset (Session);
            Have_Stats := False;
            return;
         end if;

         --  Commit the assistant turn only after a valid completion. Where
         --  tools were offered the reply is taken apart into what the model
         --  said and what it asked for, so that the calls reach the next
         --  turn as the model's own template writes them rather than as the
         --  model happened to spell them.
         if Tools /= null and then Model_Runner.Tools.Count (Tools.all) > 0
         then
            declare
               Reading : E.Error_Info;
            begin
               Conv.Append_Reply
                 (Messages, Gen.Generated_Text (Last_Result), Outcome,
                  Reading);
               if E.Is_Error (Reading) then
                  Pres.Report (Screen, Reading);
               end if;
            end;
         else
            Conv.Append
              (Messages, Conv.Assistant_Role,
               Gen.Generated_Text (Last_Result), Outcome);
         end if;

         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Conv.Drop_Last (Messages, 1);
            L.Reset (Session);
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
               Take_Turn (Prompt);
            else
               Pres.Report (Screen, E.Make (E.IO_Invalid_UTF8));
            end if;
         end;
      end Submit;

   begin
      Status := E.Exit_Success;

      --  Conversation mode needs a usable template; raw mode is not offered
      --  interactively because the turn structure would have nowhere to go.
      if not L.Template_Ready (Prepared) then
         Pres.Report (Screen, L.Template_Condition (Prepared));
         Status := E.Exit_Status (L.Template_Condition (Prepared));
         return;
      end if;

      Conv.Open (Messages, Bounds, Condition);
      if E.Is_Error (Condition) then
         Pres.Report (Screen, Condition);
         Status := E.Exit_Status (Condition);
         return;
      end if;

      --  A project in the session's directory is looked at before anything
      --  is asked of it.
      Model_Runner.CLI.Project_Commands.Recover_Here (Screen);

      Model_Runner.Stops.Open (Stop_Set, Bounds);
      for Index in 1 .. Item.Stop_Count loop
         Model_Runner.Stops.Add_String
           (Stop_Set, T.To_String (Item.Stop_Strings (Index)), Condition);
      end loop;
      for Index in 1 .. Item.Stop_Token_Count loop
         Model_Runner.Stops.Add_Token
           (Stop_Set, Vocab.Token_Id (Item.Stop_Tokens (Index)), Condition);
      end loop;

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
               Model_Runner.Platform.Signals.Set_Waiting_For_Input
                 (True, Note => Pres.Message_Value
                                  (Screen, (if Pending (Typing) = "" then "cli.interactive.dropped_line"
                                            else "cli.interactive.dropped")) & ASCII.LF
                                --  What was typed is dropped: the prompt is
                                --  the first line's again.
                                & Pres.Message_Value (Screen, "cli.interactive.prompt") & " ");
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
                          Describe => Model_Runner.CLI.Completion.Described'Access);
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
                              Ada.Text_IO.Skip_Line
                                (Ada.Text_IO.Current_Input);
                              exit;
                           end if;
                           exit when Room'Length >= Max_Turn_Bytes;
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
               Model_Runner.Platform.Signals.Set_Waiting_For_Input (False);
            exception
               when Ada.Text_IO.End_Error =>
                  Model_Runner.Platform.Signals.Set_Waiting_For_Input (False);
                  exit Read_Loop;
            end;

            --  A line longer than the buffer arrives in pieces. Joining them
            --  would be the same turn; treating each as a line would put line
            --  feeds inside what the user typed as one. Neither is worth the
            --  code, so a line this long ends the turn it is part of.
            if Stop = Room'Length and then Room'Length >= Max_Turn_Bytes
              and then not Ada.Text_IO.End_Of_Line (Ada.Text_IO.Current_Input)
            then
               Ada.Text_IO.Skip_Line (Ada.Text_IO.Current_Input);
               Taken (Typing);
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
                     Taken (Typing);
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
                     Taken (Typing);
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
                  Offer (Typing, Line, Effect);
                  case Effect is
                     when Is_Command =>
                        --  Offer says so only for a line Parse reads as one,
                        --  so the answer here is always True and is not
                        --  consulted.
                        Handled := Handle_Command (T.Trim (Line));
                        After_Command := True;

                     when Command_Mid_Message =>
                        Handled := Handle_Command (T.Trim (Line));
                        After_Command := True;
                        Pres.Put_Note (Screen, "cli.interactive.message_kept");

                     when Submits =>
                        --  A blank line submits; an empty submission is
                        --  ignored.
                        Submit;

                     when Too_Long =>
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

      --  At end of file a pending prompt is submitted, then the session ends.
      if not Leaving then
         Submit;
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
