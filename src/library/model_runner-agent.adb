with Ada.Unchecked_Deallocation;

with Model_Runner.Grammar;
with Model_Runner.Tokenizer;
with Model_Runner.Tools.Constraint;

package body Model_Runner.Agent is

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package Vocab renames Model_Runner.Tokenizer;

   use type Gen.Completion_Reason;

   type Text_Access is access String;
   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   ---------
   -- Run --
   ---------

   procedure Run
     (Source     : Model_Runner.Llama.Model'Class;
      Session    : in out Model_Runner.Llama.Session;
      Messages   : in out Model_Runner.Conversation.History;
      Offered    : Model_Runner.Tools.Definitions;
      Executor   : in out Model_Runner.Tools.Runner.Instance'Class;
      Generation : Model_Runner.Generation.Request;
      Stop_Set   : Model_Runner.Stops.Set;
      Sink       : Model_Runner.Output.Sink_Reference;
      Time       : Model_Runner.Clocks.Clock_Reference;
      Seeds      : Model_Runner.Entropy.Source_Reference;
      Cancel     : Model_Runner.Cancellation.Token_Reference := null;
      Max_Steps  : Positive := 8;
      Thinking   : Model_Runner.Templates.Thinking_Choice :=
        Model_Runner.Templates.Thinking_Unstated;
      Watch      : Observer_Reference := null;
      Bounds     : Model_Runner.Limits.Session_Limits :=
        Model_Runner.Limits.Default_Session_Limits;
      Result     : out Outcome)
   is
      Words : constant access constant Vocab.Vocabulary :=
        L.Vocabulary (Source);

      Have_Tools : constant Boolean :=
        Model_Runner.Tools.Count (Offered) > 0;

      --  The grammar, compiled once: the tools do not change between steps,
      --  so neither does what a call may look like.
      Rules_Grammar : aliased Model_Runner.Grammar.Compiled;
      Rules         : Gen.Grammar_Reference := null;

      --  A generation request the loop owns the discipline of. The caller's
      --  sampling and budget are kept; the three fields the loop must decide
      --  are set here, over whatever the caller left in them.
      Request : Gen.Request := Generation;

      Last_Result : Gen.Result;

      --  Render the committed conversation, with the tools in it, ready for
      --  the model to continue.
      procedure Render
        (Rendered : out Text_Access;
         Status   : out E.Error_Info)
      is
         Buffer : Text_Access := new String (1 .. Bounds.Max_Rendered_Bytes);
         Last   : Natural;
      begin
         Rendered := null;
         Model_Runner.Templates.Render
           (L.Template (Source).all, Messages,
            Vocab.Token_Text (Words.all, Vocab.Beginning_Token (Words.all)),
            Vocab.Token_Text (Words.all, Vocab.End_Token (Words.all)),
            True, Buffer.all, Last, Status,
            Thinking => Thinking,
            Tools    => (if Have_Tools then Offered'Unrestricted_Access
                         else null));
         if E.Is_Ok (Status) then
            Rendered := new String'(Buffer.all (1 .. Last));
         end if;
         Free (Buffer);
      end Render;

   begin
      Result := (Reason => Answered, others => <>);

      Request.Add_Beginning := False;
      Request.Retain_Text := True;
      Request.Reuse_Committed_Prefix := True;
      if not L.Capability (Source).Supports_Batched then
         Request.Batch_Size := 1;
      end if;

      if Have_Tools then
         Model_Runner.Tools.Constraint.Compile_Call_Grammar
           (Offered, Rules_Grammar, Result.Error);
         if E.Is_Error (Result.Error) then
            Result.Reason := Grammar_Failed;
            return;
         end if;
         Rules := Rules_Grammar'Unchecked_Access;
      end if;

      Step_Loop :
      loop
         declare
            Rendered : Text_Access := null;
            Status   : E.Error_Info;
         begin
            Render (Rendered, Status);
            if E.Is_Error (Status) then
               Result.Reason := Render_Failed;
               Result.Error := Status;
               exit Step_Loop;
            end if;

            Gen.Release (Last_Result);
            Gen.Generate
              (Source   => Source,
               Session  => Session,
               Prompt   => Rendered.all,
               Item     => Request,
               Stop_Set => Stop_Set,
               Rules    => Rules,
               Sink     => Sink,
               Observer => null,
               Time     => Time,
               Seeds    => Seeds,
               Cancel   => Cancel,
               Bounds   => Bounds,
               Outcome  => Last_Result);
            Free (Rendered);
         end;

         if Last_Result.Reason = Gen.Runtime_Error then
            --  An unfinished turn is not committed, and the session is reset
            --  so the next caller re-evaluates the committed conversation.
            L.Reset (Session);
            Result.Reason := Generation_Failed;
            Result.Error := Last_Result.Error;
            exit Step_Loop;
         end if;

         if Last_Result.Reason = Gen.Cancelled then
            L.Reset (Session);
            Result.Reason := Cancelled;
            exit Step_Loop;
         end if;

         --  Commit the reply as the turn it is: the text becomes the
         --  content, and each call is attached so the next render writes it
         --  in the template's own spelling.
         declare
            Status  : E.Error_Info;
            Reading : E.Error_Info;
         begin
            if Have_Tools then
               Conv.Append_Reply
                 (Messages, Gen.Generated_Text (Last_Result), Status, Reading);
            else
               Conv.Append
                 (Messages, Conv.Assistant_Role,
                  Gen.Generated_Text (Last_Result), Status);
            end if;

            if E.Is_Error (Status) then
               L.Reset (Session);
               Result.Reason := History_Failed;
               Result.Error := Status;
               exit Step_Loop;
            end if;
         end;

         Result.Steps := Result.Steps + 1;

         declare
            Turn  : constant Positive := Conv.Length (Messages);
            Asked : constant Natural := Conv.Call_Count (Messages, Turn);
         begin
            --  Nothing left to run: the model has answered.
            exit Step_Loop when Asked = 0;

            --  Calls to run, but no room to run them and read the answer.
            if Result.Steps >= Max_Steps then
               Result.Reason := Step_Limit;
               exit Step_Loop;
            end if;

            --  Run each call and hand its answer back as a tool turn.
            for Call in 1 .. Asked loop
               declare
                  Named : constant String :=
                    Conv.Call_Name (Messages, Turn, Call);
                  Args  : constant String :=
                    Conv.Call_Arguments (Messages, Turn, Call);
                  Answer : String (1 .. Model_Runner.Tools.Max_Call_Bytes);
                  Filled : Natural;
                  Status : E.Error_Info;
                  Ran    : E.Error_Info;
               begin
                  if Watch /= null then
                     Watch.On_Call (Named, Args);
                  end if;

                  if Model_Runner.Tools.Offers (Offered, Named) then
                     Executor.Run (Named, Args, Answer, Filled, Ran);
                     if E.Is_Error (Ran) then
                        --  The tool answered with more than fits. The model
                        --  is told so, in place of an answer it cannot have.
                        declare
                           Note : constant String :=
                             "error: the tool's answer was too large "
                             & "to return";
                        begin
                           Conv.Append (Messages, Conv.Tool_Role, Note, Status);
                           if Watch /= null then
                              Watch.On_Result (Named, Note);
                           end if;
                        end;
                     else
                        Conv.Append
                          (Messages, Conv.Tool_Role,
                           Answer (1 .. Filled), Status);
                        if Watch /= null then
                           Watch.On_Result (Named, Answer (1 .. Filled));
                        end if;
                     end if;
                  else
                     --  The grammar should have made this impossible; if it
                     --  happens anyway, the model hears the truth and may
                     --  correct itself rather than the loop breaking.
                     declare
                        Note : constant String :=
                          "error: no tool named """ & Named & """";
                     begin
                        Conv.Append (Messages, Conv.Tool_Role, Note, Status);
                        if Watch /= null then
                           Watch.On_Result (Named, Note);
                        end if;
                     end;
                  end if;

                  Result.Calls := Result.Calls + 1;

                  if E.Is_Error (Status) then
                     L.Reset (Session);
                     Result.Reason := History_Failed;
                     Result.Error := Status;
                     exit Step_Loop;
                  end if;
               end;
            end loop;
         end;
      end loop Step_Loop;

      Gen.Release (Last_Result);
      Model_Runner.Grammar.Close (Rules_Grammar);
   exception
      when others =>
         Gen.Release (Last_Result);
         Model_Runner.Grammar.Close (Rules_Grammar);
         Result.Reason := Generation_Failed;
         Result.Error := E.Make (E.Internal_Unexpected_Exception);
   end Run;

end Model_Runner.Agent;
