separate (Model_Runner.Framework.Work)
procedure Open_Child
  (Host     : in out Child_Host;
   Role     : String;
   Need     : String;
   Brief    : String;
   Retry_Of : String;
   Child_Id : out Ada.Strings.Unbounded.Unbounded_String;
   Context  : out Ada.Strings.Unbounded.Unbounded_String;
   Budget   : out Natural;
   Status   : out Model_Runner.Errors.Error_Info)
is
   Change  : Stores.Transaction;
   Parent  : constant String := Current (Host);
   Owner   : Agents.Agent;
   Read    : E.Error_Info := E.Success;
   Named   : constant String := (if Trim (Role) = "" then "helper" else Trim (Role));
   Obliged : constant Agents.Obligation :=
     (if Need = "optional" then Agents.Optional
      elsif Need = "advisory" then Agents.Advisory
      else Agents.Required);
begin
   Child_Id := Null_Unbounded_String;
   Context := Null_Unbounded_String;
   Budget := 0;

   --  Half of what its parent has left: a child that could spend all of
   --  it would leave its parent nothing to finish with.
   Agents.Read (Host.Item.all, Parent, Owner, Status);
   if E.Is_Error (Status) then
      return;
   end if;
   Budget := (if Owner.Used >= Owner.Budget then 0 else (Owner.Budget - Owner.Used) / 2);
   if Budget = 0 then
      Status := E.Make (E.Framework_Limit_Exceeded);
      E.Add_Text (Status, "name", Parent);
      E.Add_Text (Status, "detail", "it has no tokens left to give a child");
      return;
   end if;

   Agents.Spawn_Child
     (Host.Item.all, Change, Parent, Named, Obliged, Permissions.Unrestricted, Budget,
      Child_Id, Status, Retry_Of => Retry_Of);
   if E.Is_Ok (Status) then
      Stores.Commit (Host.Item.all, Change, Status);
   end if;
   if E.Is_Error (Status) then
      Child_Id := Null_Unbounded_String;
      Budget := 0;
      return;
   end if;
   Host.Open.Append (To_String (Child_Id));
   Host.Opened.Append (Ada.Calendar.Clock);

   --  A context of its own -- the task it helps with and what it is
   --  asked, nothing of the conversation it was asked from -- with its
   --  manifest kept and its invocation recorded before it is made.
   declare
      Made   : Framework.Context.Built;
      Called : Unbounded_String;

      --  What it may do, told it as the root agent is told: where it
      --  may write, whether it may make helpers or propose work.
      function Child_Allowed return String is
         Held : Agents.Agent;
         Got  : E.Error_Info;
         Said : Unbounded_String;
      begin
         Agents.Read (Host.Item.all, To_String (Child_Id), Held, Got);
         if E.Is_Error (Got) then
            return "";
         end if;
         --  Only what a tool of its own uses: a permission it has no
         --  tool for -- the network, proposing work -- is no use told.
         for Line of Lines_Of (Permissions.Image (Held.Allowed)) loop
            declare
               Word : constant String := Trim (Line);
            begin
               if Word /= ""
                 and then (Ada.Strings.Fixed.Index (Word, "read_") = Word'First
                           or else Ada.Strings.Fixed.Index (Word, "write_") = Word'First
                           or else Ada.Strings.Fixed.Index (Word, "run_") = Word'First
                           or else Ada.Strings.Fixed.Index (Word, "create_children") = Word'First)
               then
                  Append (Said, (if Said = Null_Unbounded_String then "" else ", ")
                          & Permissions.In_Words (Word));
               end if;
            end;
         end loop;
         declare
            Policy : constant String :=
              Tool_Policy (Host.Item.all, To_String (Child_Id), Host.Max_Calls, To_String (Host.Task_Id),
                           Host.Apart);
            Tools_End : constant Natural := Ada.Strings.Fixed.Index (Policy, ";");
         begin
            return ASCII.LF & "## What you may do" & ASCII.LF
              & "Your tools -- these and no others: "
              & (if Tools_End > 7 then Policy (Policy'First + 7 .. Tools_End - 1) else "read_file, list_directory")
              & "." & ASCII.LF
              & "You may " & (if Said = Null_Unbounded_String then "only read what you are given"
                              else To_String (Said))
              & "." & ASCII.LF
              & (if Permissions.Allows (Held.Allowed, Permissions.Write_Source)
                   or else Permissions.Allows (Held.Allowed, Permissions.Write_Specs)
                 then "Change only the files you may write."
                 else "Change no file: read, and report.")
              & (if Permissions.Allows (Held.Allowed, Permissions.Create_Children) then ""
                 else " You may not make helpers of your own.")
              & " Work you find beyond your part goes in your findings, for the agent that"
              & " asked to propose."
              & ASCII.LF;
         end;
      end Child_Allowed;
   begin
      Framework.Context.Build_Brief
        (Host.Item.all, To_String (Host.Task_Id), Host.Model,
         "You are helping an agent with one part of its task, as its " & Named
         & ". You cannot see its conversation, and it will see only your report.",
         Brief, Made, Read, Instructions => Child_Instructions & Child_Allowed);
      if E.Is_Ok (Read) then
         Framework.Context.Keep (Host.Item.all, Change, Made, Read);
      end if;
      if E.Is_Ok (Read) then
         Invocations.Start
           (Host.Item.all, Change, To_String (Child_Id), To_String (Host.Task_Id),
            Generation_Of (Host.Item.all, To_String (Host.Task_Id)),
            To_String (Host.Model.Id), Framework.Context.Manifest_Id (Made),
            Tool_Policy (Host.Item.all, To_String (Child_Id), Host.Max_Calls,
                         To_String (Host.Task_Id), Host.Apart),
            Child_Claim, Called, Read,
            Resource_Class => To_String (Host.Model.Resource_Class));
         if E.Is_Ok (Read) then
            Agents.Record_Holding
              (Host.Item.all, Change, To_String (Child_Id), "", To_String (Called), Read);
         end if;
      end if;
      if E.Is_Ok (Read) then
         Stores.Commit (Host.Item.all, Change, Read);
      end if;

      --  Not made after all: the child ends failed, and is no longer the
      --  one working -- its parent goes on as itself, charged and held
      --  as itself, with nothing left open in its name.
      if E.Is_Error (Read) then
         --  Cancelled, not failed: it never worked, and a helper the
         --  model was told was not made holds nothing up.
         declare
            Ended : E.Error_Info;
            Close : Stores.Transaction;
         begin
            Agent_State (Host.Item.all, Close, To_String (Child_Id), "cancelled",
                         "it could not be started: " & Why_Of (Read));
            Stores.Commit (Host.Item.all, Close, Ended);
         end;
         Host.Open.Delete_Last;
         Host.Opened.Delete_Last;
         Child_Id := Null_Unbounded_String;
         Budget := 0;
         Status := Read;
         return;
      end if;
      Host.Calls.Append (To_String (Called));
      Context := To_Unbounded_String (Framework.Context.Rendered (Made));
   end;
end Open_Child;
