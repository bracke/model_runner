separate (Model_Runner.Framework.Work)
procedure Close_Child
  (Host   : in out Child_Host;
   Answer : String;
   Tokens : Natural;
   Ran    : Model_Runner.Errors.Error_Info;
   Told   : out Ada.Strings.Unbounded.Unbounded_String;
   Retry  : out Boolean;
   Prompt_Tokens : Natural := 0)
is
   Change  : Stores.Transaction;
   Status  : E.Error_Info;
   Charged : E.Error_Info;
   Held    : E.Error_Info;
   Said    : Invocations.Claims;
   Child   : Agents.Agent;
   Good    : Boolean := False;
   Why     : Unbounded_String;
   Kept    : Results.Result;

   --  How many times the child it stands for has been run before it.
   function Runs_Before (Id : String) return Natural is
      Held_Agent : Agents.Agent;
      Read       : E.Error_Info;
   begin
      Agents.Read (Host.Item.all, Id, Held_Agent, Read);
      return (if E.Is_Error (Read) or else Held_Agent.Retry_Of = Null_Unbounded_String
              then 0 else 1 + Runs_Before (To_String (Held_Agent.Retry_Of)));
   end Runs_Before;

   Retries : constant Natural :=
     (declare
        Text : constant String := Scalar (Host.Item.all, "agents.child_retries");
      begin
        (if Text'Length in 1 .. 3 and then (for all C of Text => C in '0' .. '9')
         then Natural'Value (Text) else 1));
begin
   Told := Null_Unbounded_String;
   Retry := False;
   if Natural (Host.Open.Length) < 2 then
      Told := To_Unbounded_String ("error: no child is open");
      return;
   end if;

   declare
      Id : constant String := Host.Open.Last_Element;
   begin
      Agents.Read (Host.Item.all, Id, Child, Status);
      Agents.Charge (Host.Item.all, Change, Id, Tokens, Charged);

      if Interrupted (Ran) then
         Why := To_Unbounded_String
           ("it was stopped: the work was "
            & (if Execution.Cancel_Asked_From_Outside then "cancelled" else "interrupted"));
      elsif E.Is_Error (Ran) then
         Why := To_Unbounded_String ("it failed: " & Why_Of (Ran));
      else
         Invocations.Hold (Child_Claim, Answer, Said, Held);
         if E.Is_Error (Held) then
            Why := To_Unbounded_String
              ("its answer did not keep to the child result contract: "
               & E.Text_Of (Held, "name") & ": " & E.Text_Of (Held, "detail")
               & " -- a helper answers with status: done, and summary: one line on what it found");
         elsif E.Is_Error (Charged) then
            Why := To_Unbounded_String ("it went over its budget");
         else
            Good := Invocations.Claim (Said, "status") = "done";
            Why := To_Unbounded_String (Own_Words (Invocations.Claim (Said, "summary")));
            --  Said nothing of what it found: said so, not left blank.
            if Trim (To_String (Why)) = "" then
               Why := To_Unbounded_String ("(it gave no summary of what it found)");
            end if;

            --  Done, it says -- but a required child of its own that
            --  failed holds it as it holds the root.
            declare
               Held_Back : Unbounded_String;
            begin
               if Good and then not Agents.May_Complete (Host.Item.all, Id, Held_Back) then
                  Good := False;
                  Why := Held_Back;
               end if;
            end;
         end if;
      end if;

      --  Its result is kept, whichever way it went; the parent is told
      --  of it, not of how it was reached.
      Kept :=
        (Kind       => Results.Child_Result,
         Producer   => To_Unbounded_String (Id),
         Summary    => Why,
         Payload    => To_Unbounded_String
           (if E.Is_Ok (Held) and then E.Is_Ok (Ran)
            then Invocations.Claim (Said, "findings")
                 & (if Invocations.Claim (Said, "changed_files") = "" then ""
                    else ASCII.LF & "changed_files: "
                         & Invocations.Claim (Said, "changed_files"))
            else Answer),
         Provenance => Child.Parent,
         others     => <>);
      Results.Add (Host.Item.all, Change, Kept, Status);
      if E.Is_Ok (Status) and then Interrupted (Ran) then
         --  Stopped by whoever started the work: cancelled, with what it
         --  made, and not run again.
         declare
            Stopped : Name_Lists.Vector;
         begin
            Agents.Cancel (Host.Item.all, Change, Id, Stopped, Status,
                           Why => To_String (Why), Result_Id => To_String (Kept.Id));
         end;
      elsif E.Is_Ok (Status) then
         Agents.Finish
           (Host.Item.all, Change, Id, Good, To_String (Kept.Id), To_String (Why), Status);
      end if;
      --  Its invocation ended, with what it used.
      if E.Is_Ok (Status) and then Host.Calls.Last_Element /= "" then
         Invocations.Finish
           (Host.Item.all, Change, Host.Calls.Last_Element,
            (if Interrupted (Ran) then Invocations.Cancelled
             elsif E.Is_Ok (Ran) then Invocations.Completed
             else Invocations.Failed),
            (Prompt_Tokens => Prompt_Tokens,
             Output_Tokens => Tokens,
             Seconds       =>
               Natural (Duration'Max
                 (0.0, Ada.Calendar."-" (Ada.Calendar.Clock, Host.Opened.Last_Element)))),
            To_String (Kept.Id),
            (if E.Is_Ok (Ran) then "" else Why_Of (Ran)), Status);
      end if;
      if E.Is_Ok (Status) then
         Stores.Commit (Host.Item.all, Change, Status);
      end if;
      Host.Open.Delete_Last;
      Host.Calls.Delete_Last;
      Host.Opened.Delete_Last;

      --  Not run again where it went round: the same model on the same
      --  brief goes round the same way, and the parent's time goes with
      --  it -- a helper sent to fix an overflow repeated one edit until
      --  stopped, was run again, and did it again. The parent hears of it
      --  at once, and may do the part itself.
      Retry := not Good and then not Interrupted (Ran) and then not Out_Of_Time (Ran)
        and then not Went_Round (Ran)
        and then Agents."=" (Child.Need, Agents.Required)
        and then Runs_Before (Id) < Retries;
      Told := To_Unbounded_String
        (Id & " (" & Ada.Characters.Handling.To_Lower (Agents.Obligation'Image (Child.Need))
         & ") " & (if Good then "done" elsif Interrupted (Ran) then "cancelled" else "failed")
         & (if Kept.Id = Null_Unbounded_String then "" else ", " & To_String (Kept.Id))
         & ": " & To_String (Why)
         & (if Good and then Invocations.Claim (Said, "findings") /= ""
            then ASCII.LF & Invocations.Claim (Said, "findings") else "")
         & (if Retry then ASCII.LF & "It is run once more." else ""));
   end;
end Close_Child;
