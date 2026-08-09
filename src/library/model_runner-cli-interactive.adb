with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with Model_Runner.Clocks;
with Model_Runner.Conversation;
with Model_Runner.Entropy;
with Model_Runner.Errors;
with Model_Runner.Generation;
with Model_Runner.Limits;
with Model_Runner.Localization;
with Model_Runner.Stops;
with Model_Runner.Templates;
with Model_Runner.Text;
with Model_Runner.Tokenizer;
with Model_Runner.UTF8;

package body Model_Runner.CLI.Interactive is

   use type Model_Runner.Generation.Completion_Reason;
   use type Model_Runner.CLI.Options.Text_Access;

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

   ----------
   -- Open --
   ----------

   procedure Open (Item : in out Turn; Ok : out Boolean) is
   begin
      Close (Item);
      Item.Room := new String (1 .. Max_Turn_Bytes);
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
      Trimmed : constant String := T.Trim (Line);
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

      if Trimmed = "" then
         Effect := Submits;
         return;
      end if;

      --  The separator is counted before the line, because the check has to
      --  be the one the copy below performs.
      if Item.Used + Line'Length + (if Item.Used > 0 then 1 else 0)
         > Item.Room.all'Length
      then
         Item.Used := 0;
         Effect := Too_Long;
         return;
      end if;

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

         if Word = "/exit" then
            return (Leave, 0, 0);
         elsif Word = "/reset" then
            return (Reset, 0, 0);
         elsif Word = "/help" then
            return (Help, 0, 0);
         elsif Word = "/settings" then
            return (Settings, 0, 0);
         elsif Word = "/stats" then
            return (Statistics, 0, 0);
         elsif Word = "/context" then
            return (Context, 0, 0);
         elsif Word = "/system" then
            return (Set_System, First, Last);
         else
            return (Unknown, 0, 0);
         end if;
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
      Status   : out Natural)
   is
      Bounds : constant Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Words  : constant access constant Vocab.Vocabulary :=
        L.Vocabulary (Prepared);

      Messages : Conv.History;
      Stop_Set : Model_Runner.Stops.Set;
      Sink     : aliased Pres.Standard_Output_Sink;
      Clock    : aliased Model_Runner.Clocks.System_Clock;
      Seeds    : aliased Model_Runner.Entropy.Host_Source;

      Typing       : Turn;
      Have_Stats   : Boolean := False;
      Last_Result  : Gen.Result;
      Condition    : E.Error_Info;
      Leaving      : Boolean := False;

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
            True, Buffer.all, Last, Outcome);
         if E.Is_Ok (Outcome) then
            Rendered := new String'(Buffer.all (1 .. Last));
         end if;
         Free_Text (Buffer);
      end Render;

      --  Show the sampling settings in use. Option names are protocol and are
      --  printed as written.
      procedure Show_Settings is
      begin
         Pres.Put_Field
           (Screen, "cli.interactive.setting.temperature",
            T.Image (Long_Float (Item.Sampling.Temperature), 3), Pres.Diagnostic);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_k",
            T.Image (Long_Long_Integer (Item.Sampling.Top_K)), Pres.Diagnostic);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_p",
            T.Image (Long_Float (Item.Sampling.Top_P), 3), Pres.Diagnostic);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.min_p",
            T.Image (Long_Float (Item.Sampling.Min_P), 3), Pres.Diagnostic);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_penalty",
            T.Image (Long_Float (Item.Sampling.Repeat_Penalty), 3), Pres.Diagnostic);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_window",
            T.Image (Long_Long_Integer (Item.Sampling.Repeat_Window)), Pres.Diagnostic);
         Pres.Put_Field
           (Screen, "cli.interactive.setting.max_tokens",
            T.Image (Long_Long_Integer (Item.Max_Tokens)), Pres.Diagnostic);
         if Item.Has_Seed then
            Pres.Put_Field
              (Screen, "cli.interactive.setting.seed",
               T.Image (Item.Seed), Pres.Diagnostic);
         end if;
      end Show_Settings;

      --  Handle one slash command. Returns True when the input was a command.
      function Handle_Command (Line : String) return Boolean is
         Asked : constant Parsed_Command := Parse (Line);
      begin
         if Asked.Kind = Not_A_Command then
            return False;
         end if;

         if Asked.Kind = Leave then
            Leaving := True;

         elsif Asked.Kind = Reset then
            Conv.Clear (Messages);
            L.Reset (Session);
            Have_Stats := False;
            Pres.Put_Note (Screen, "cli.interactive.reset_done");

         elsif Asked.Kind = Help then
            Pres.Put_Note (Screen, "cli.interactive.help.exit");
            Pres.Put_Note (Screen, "cli.interactive.help.reset");
            Pres.Put_Note (Screen, "cli.interactive.help.help");
            Pres.Put_Note (Screen, "cli.interactive.help.settings");
            Pres.Put_Note (Screen, "cli.interactive.help.stats");
            Pres.Put_Note (Screen, "cli.interactive.help.context");
            Pres.Put_Note (Screen, "cli.interactive.help.system");

         elsif Asked.Kind = Settings then
            Show_Settings;

         elsif Asked.Kind = Statistics then
            if Have_Stats then
               Pres.Put_Statistics (Screen, Last_Result);
            else
               Pres.Put_Note (Screen, "cli.interactive.no_stats");
            end if;

         elsif Asked.Kind = Context then
            Pres.Put_Note
              (Screen, "cli.interactive.context",
               [Loc.Named
                  ("used", T.Image (Long_Long_Integer (L.Position (Session)))),
                Loc.Named
                  ("capacity",
                   T.Image (Long_Long_Integer (L.Capacity (Session))))]);

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

         else
            Pres.Put_Note
              (Screen, "cli.interactive.unknown_command",
               [Loc.Named ("value", T.Escape_Controls (Line))]);
         end if;

         return True;
      end Handle_Command;

      --  Run one turn against the model.
      procedure Take_Turn (Prompt : String) is
         Rendered : Text_Access := null;
         Outcome  : E.Error_Info;
         Request  : Gen.Request;
      begin
         Conv.Append (Messages, Conv.User_Role, Prompt, Outcome);
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
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
         Request.Add_Beginning := False;
         Request.Retain_Text := True;
         --  The rendered conversation grows by an appended turn, so the cache
         --  usually holds an exact prefix of it and only the new suffix has to
         --  be evaluated.
         Request.Reuse_Committed_Prefix := True;

         Gen.Release (Last_Result);
         Gen.Generate
           (Source   => Prepared,
            Session  => Session,
            Prompt   => Rendered.all,
            Item     => Request,
            Stop_Set => Stop_Set,
            Sink     => Sink'Unchecked_Access,
            Observer => null,
            Time     => Clock'Unchecked_Access,
            Seeds    => Seeds'Unchecked_Access,
            Cancel   => null,
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

         --  Commit the assistant turn only after a valid completion.
         Conv.Append
           (Messages, Conv.Assistant_Role,
            Gen.Generated_Text (Last_Result), Outcome);
         if E.Is_Error (Outcome) then
            Pres.Report (Screen, Outcome);
            Conv.Drop_Last (Messages, 1);
            L.Reset (Session);
            return;
         end if;

         Have_Stats := True;
         if Item.Show_Stats then
            Pres.Put_Statistics (Screen, Last_Result);
         end if;
      end Take_Turn;

      --  Submit whatever has accumulated, if anything.
      procedure Submit is
      begin
         if Pending (Typing) = "" then
            return;
         end if;

         declare
            Prompt : constant String := Pending (Typing);
         begin
            Taken (Typing);
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

      Read_Loop :
      while not Leaving loop
         --  The prompt marker goes to standard error so that a redirected
         --  standard output still receives only generated text.
         Pres.Put_Prompt
           (Screen,
            (if Pending (Typing) = ""
             then "cli.interactive.prompt"
             else "cli.interactive.continuation"));

         exit Read_Loop when Ada.Text_IO.End_Of_File (Ada.Text_IO.Current_Input);

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
            Room : String (1 .. 8192);
            Stop : Natural;

            Effect  : Line_Effect;
            Handled : Boolean;
            pragma Unreferenced (Handled);
         begin
            Ada.Text_IO.Get_Line (Ada.Text_IO.Current_Input, Room, Stop);

            --  A line longer than the buffer arrives in pieces. Joining them
            --  would be the same turn; treating each as a line would put line
            --  feeds inside what the user typed as one. Neither is worth the
            --  code, so a line this long ends the turn it is part of.
            if Stop = Room'Length
              and then not Ada.Text_IO.End_Of_Line (Ada.Text_IO.Current_Input)
            then
               Ada.Text_IO.Skip_Line (Ada.Text_IO.Current_Input);
               Taken (Typing);
               Pres.Report (Screen, E.Make (E.Conversation_Too_Long));
            else
               declare
                  Line : constant String := Room (1 .. Stop);
               begin
                  Offer (Typing, Line, Effect);
                  case Effect is
                     when Is_Command =>
                        --  Offer says so only for a line Parse reads as one,
                        --  so the answer here is always True and is not
                        --  consulted.
                        Handled := Handle_Command (T.Trim (Line));

                     when Submits =>
                        --  A blank line submits; an empty submission is
                        --  ignored.
                        Submit;

                     when Too_Long =>
                        Pres.Report (Screen, E.Make (E.Conversation_Too_Long));

                     when Held =>
                        null;
                  end case;
               end;
            end if;
         end;
      end loop Read_Loop;

      --  At end of file a pending prompt is submitted, then the session ends.
      if not Leaving then
         Submit;
      end if;

      Gen.Release (Last_Result);
      Model_Runner.Stops.Close (Stop_Set);
      Conv.Close (Messages);
      Close (Typing);
   exception
      when others =>
         Gen.Release (Last_Result);
         Model_Runner.Stops.Close (Stop_Set);
         Conv.Close (Messages);
         Close (Typing);
         Pres.Report (Screen, E.Make (E.Internal_Unexpected_Exception));
         Status := E.Exit_Internal;
   end Run;

end Model_Runner.CLI.Interactive;
