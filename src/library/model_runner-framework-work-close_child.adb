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

   --  How many times the child it stands for has been run before it, and
   --  whether that can be told: a lineage the state holds damaged is not
   --  one to run again from.
   Lineage_Runs   : Natural := 0;
   Lineage_Status : E.Error_Info := E.Success;

   --  As the run resolved it when it began, where it did.
   Retries : constant Natural :=
     (if Host.Limits_Frozen then Host.Child_Retries else Retries_Allowed (Host.Item.all));
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

            --  And a file it says it changed that is not there is a claim
            --  the files refute, as the root's is: refused now, so the
            --  parent hears it while it can still do the part, not when
            --  its own answer repeats the claim at the end. A helper said
            --  it had written docs/calc.md having called nothing at all.
            if Good then
               declare
                  Place : constant String :=
                    (if Host.Apart then To_String (Host.Tree)
                     else Ada.Directories.Containing_Directory
                            (Stores.Root (Host.Item.all)));
                  Missing : Unbounded_String;
               begin
                  for Line of Lines_Of (Invocations.Claim (Said, "changed_files")) loop
                     declare
                        Path : constant String := Path_Claimed (Line, Host.Edited, Place);
                     begin
                        if Path /= ""
                          and then not Host.Edited.Contains (Path)
                          and then ((for some C of Path => C < ' ')
                                    or else not Ada.Directories.Exists
                                                  (Hostkit.Fs.Join (Place, Path)))
                        then
                           Append (Missing, (if Missing = Null_Unbounded_String then "" else ", ")
                                            & Path);
                        end if;
                     end;
                  end loop;
                  if Missing /= Null_Unbounded_String then
                     Good := False;
                     Why := "it says it changed " & Missing & ", which is not there";
                  end if;
               end;
            end if;
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
      --  A helper not ended in the state is one completion waits on for
      --  good: kept to be said, and no change starts after it.
      Keep_Unkept (Host, Status);
      Host.Open.Delete_Last;
      Host.Calls.Delete_Last;
      Host.Opened.Delete_Last;

      --  Not run again where it went round: the same model on the same
      --  brief goes round the same way, and the parent's time goes with
      --  it -- a helper sent to fix an overflow repeated one edit until
      --  stopped, was run again, and did it again. The parent hears of it
      --  at once, and may do the part itself.
      if not Good then
         Agents.Retry_Lineage (Host.Item.all, Id, Lineage_Runs, Lineage_Status);
      end if;
      Retry := not Good and then not Interrupted (Ran) and then not Out_Of_Time (Ran)
        and then not Went_Round (Ran)
        and then Agents."=" (Child.Need, Agents.Required)
        and then E.Is_Ok (Lineage_Status)
        and then Lineage_Runs < Retries;
      Told := To_Unbounded_String
        (Id & " (" & Ada.Characters.Handling.To_Lower (Agents.Obligation'Image (Child.Need))
         & ") " & (if Good then "done" elsif Interrupted (Ran) then "cancelled" else "failed")
         & (if Kept.Id = Null_Unbounded_String then "" else ", " & To_String (Kept.Id))
         & ": " & To_String (Why)
         & (if Good and then Invocations.Claim (Said, "findings") /= ""
            then ASCII.LF & Invocations.Claim (Said, "findings") else "")
         & (if Retry then ASCII.LF & "It is run once more." else "")
         & (if E.Is_Error (Lineage_Status)
            --  In the error's own words: its detail alone was nothing at
            --  all for an error that has none -- a helper whose own record
            --  could not be read, "It is not run again: ." after a stop.
            then ASCII.LF & "It is not run again: " & Why_Of (Lineage_Status) & "."
            else ""));
   end;
end Close_Child;
