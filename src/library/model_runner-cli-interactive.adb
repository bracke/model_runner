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

   type Text_Access is access String;
   procedure Free_Text is new Ada.Unchecked_Deallocation (String, Text_Access);

   --  Largest prompt one turn may accumulate before it is submitted.
   Max_Turn_Bytes : constant := 65_536;

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

      Pending      : String (1 .. Max_Turn_Bytes);
      Pending_Used : Natural := 0;
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
            T.Image (Long_Float (Item.Sampling.Temperature), 3));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_k",
            T.Image (Long_Long_Integer (Item.Sampling.Top_K)));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.top_p",
            T.Image (Long_Float (Item.Sampling.Top_P), 3));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.min_p",
            T.Image (Long_Float (Item.Sampling.Min_P), 3));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_penalty",
            T.Image (Long_Float (Item.Sampling.Repeat_Penalty), 3));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.repeat_window",
            T.Image (Long_Long_Integer (Item.Sampling.Repeat_Window)));
         Pres.Put_Field
           (Screen, "cli.interactive.setting.max_tokens",
            T.Image (Long_Long_Integer (Item.Max_Tokens)));
         if Item.Has_Seed then
            Pres.Put_Field
              (Screen, "cli.interactive.setting.seed",
               T.Image (Item.Seed));
         end if;
      end Show_Settings;

      --  Handle one slash command. Returns True when the input was a command.
      function Handle_Command (Line : String) return Boolean is
      begin
         if Line'Length = 0 or else Line (Line'First) /= '/' then
            return False;
         end if;

         if Line = "/exit" then
            Leaving := True;

         elsif Line = "/reset" then
            Conv.Clear (Messages);
            L.Reset (Session);
            Have_Stats := False;
            Pres.Put_Note (Screen, "cli.interactive.reset_done");

         elsif Line = "/help" then
            Pres.Put_Note (Screen, "cli.interactive.help.exit");
            Pres.Put_Note (Screen, "cli.interactive.help.reset");
            Pres.Put_Note (Screen, "cli.interactive.help.help");
            Pres.Put_Note (Screen, "cli.interactive.help.settings");
            Pres.Put_Note (Screen, "cli.interactive.help.stats");
            Pres.Put_Note (Screen, "cli.interactive.help.context");
            Pres.Put_Note (Screen, "cli.interactive.help.system");

         elsif Line = "/settings" then
            Show_Settings;

         elsif Line = "/stats" then
            if Have_Stats then
               Pres.Put_Statistics (Screen, Last_Result);
            else
               Pres.Put_Note (Screen, "cli.interactive.no_stats");
            end if;

         elsif Line = "/context" then
            Pres.Put_Note
              (Screen, "cli.interactive.context",
               [Loc.Named
                  ("used", T.Image (Long_Long_Integer (L.Position (Session)))),
                Loc.Named
                  ("capacity",
                   T.Image (Long_Long_Integer (L.Capacity (Session))))]);

         elsif T.Starts_With (Line, "/system ") then
            declare
               Content : constant String :=
                 T.Trim (Line (Line'First + 8 .. Line'Last));
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
                  Pres.Put_Note (Screen, "cli.interactive.system_done");
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
         Request.Batch_Size := Item.Batch_Size;
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
         if Pending_Used = 0 then
            return;
         end if;

         declare
            Prompt : constant String := Pending (1 .. Pending_Used);
         begin
            Pending_Used := 0;
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

      Pres.Put_Note (Screen, "cli.interactive.banner");

      Read_Loop :
      while not Leaving loop
         --  The prompt marker goes to standard error so that a redirected
         --  standard output still receives only generated text.
         Pres.Put_Prompt
           (Screen,
            (if Pending_Used = 0
             then "cli.interactive.prompt"
             else "cli.interactive.continuation"));

         exit Read_Loop when Ada.Text_IO.End_Of_File (Ada.Text_IO.Standard_Input);

         declare
            --  The function form returns the line as a String, which for an
            --  unbounded line would put all of it on the stack; the prompt
            --  file and standard input are both read into a fixed buffer for
            --  that reason. Here the source is a terminal -- interactive mode
            --  requires one on standard input and refuses to start otherwise
            --  -- and a terminal in canonical mode delivers at most a line
            --  discipline's worth at a time, measured at about four kilobytes
            --  against this program. That is far below Max_Turn_Bytes, so the
            --  length check below is what bounds a turn. Should interactive
            --  mode ever accept input that is not a terminal, this has to be
            --  read into a buffer like the others.
            Line : constant String := Ada.Text_IO.Get_Line (Ada.Text_IO.Standard_Input);
         begin
            if Pending_Used = 0 and then Handle_Command (T.Trim (Line)) then
               null;

            elsif T.Trim (Line) = "" then
               --  A blank line submits; an empty submission is ignored.
               Submit;

            elsif Pending_Used + Line'Length + 1 > Pending'Length then
               Pres.Report (Screen, E.Make (E.Conversation_Too_Long));
               Pending_Used := 0;

            else
               if Pending_Used > 0 then
                  Pending_Used := Pending_Used + 1;
                  Pending (Pending_Used) := ASCII.LF;
               end if;
               Pending (Pending_Used + 1 .. Pending_Used + Line'Length) := Line;
               Pending_Used := Pending_Used + Line'Length;
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
   exception
      when others =>
         Gen.Release (Last_Result);
         Model_Runner.Stops.Close (Stop_Set);
         Conv.Close (Messages);
         Pres.Report (Screen, E.Make (E.Internal_Unexpected_Exception));
         Status := E.Exit_Internal;
   end Run;

end Model_Runner.CLI.Interactive;
