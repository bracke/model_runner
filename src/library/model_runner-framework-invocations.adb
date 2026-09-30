with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Records;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Transitions;

package body Model_Runner.Framework.Invocations is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Trim (Natural'Image (Value)));

   --  A value as a model may have written it in JSON: without the quotes
   --  and the comma around it, or the brackets of an empty list.
   function Unquoted (Text : String) return String is
      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while Last >= First and then Text (Last) in ',' | ' ' loop
         Last := Last - 1;
      end loop;
      if Last > First and then Text (First) = '"' and then Text (Last) = '"' then
         First := First + 1;
         Last := Last - 1;
      end if;
      if Text (First .. Last) = "[]" then
         return "";
      end if;
      return Text (First .. Last);
   end Unquoted;

   --  The lifecycle of an invocation: started, then ended once.
   function Machine return Transitions.Machine is
      Result : Transitions.Machine;
   begin
      Transitions.Allow (Result, "started", "completed");
      Transitions.Allow (Result, "started", "failed");
      Transitions.Allow (Result, "started", "cancelled");
      return Result;
   end Machine;

   -----------------
   -- Contract_Of --
   -----------------

   function Contract_Of (Name : String; Text : String) return Contract is
      Result : Contract;
   begin
      Result.Name := To_Unbounded_String (Name);
      for Line of Lines_Of (Text) loop
         declare
            Equal : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
            Left  : constant String :=
              Trim (if Equal = 0 then Line else Line (Line'First .. Equal - 1));
            Right : constant String :=
              (if Equal = 0 then "" else Trim (Line (Equal + 1 .. Line'Last)));
         begin
            if Left /= "" then
               if Left (Left'Last) = '?' then
                  declare
                     Field : constant String := Left (Left'First .. Left'Last - 1);
                  begin
                     Result.Fields.Include (Field, Right);
                     Result.Optional.Append (Field);
                     Result.Order.Append (Field);
                  end;
               else
                  Result.Fields.Include (Left, Right);
                  Result.Order.Append (Left);
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Contract_Of;

   ----------------
   -- Work_Claim --
   ----------------

   function Work_Claim return Contract
   is (Contract_Of
         ("work_claim",
          "status = done|blocked|failed|issue" & ASCII.LF
          & "summary" & ASCII.LF
          & "changed_files?" & ASCII.LF
          & "issues?" & ASCII.LF
          & "proposed_tasks?" & ASCII.LF
          & "parts?" & ASCII.LF
          & "decisions?" & ASCII.LF
          & "specifications?" & ASCII.LF
          & "waits_for?" & ASCII.LF
          & "instead?" & ASCII.LF
          & "verify? = yes|no"));

   function Name_Of (Item : Contract) return String
   is (To_String (Item.Name));

   ----------
   -- Hold --
   ----------

   --  A line of an answer as an item: a list's mark taken off -- "- a",
   --  "* a", "1. a" -- and quotes, as a model writes a list.
   function Item_Of (Line : String) return String is
      Text : constant String := Trim (Line);
   begin
      if Text'Length >= 2 and then Text (Text'First) in '-' | '*' | '+'
        and then Text (Text'First + 1) = ' '
      then
         return Unquoted (Trim (Text (Text'First + 2 .. Text'Last)));
      end if;
      declare
         Dot : constant Natural := Ada.Strings.Fixed.Index (Text, ". ");
      begin
         if Dot > Text'First and then Dot - Text'First <= 3
           and then (for all C of Text (Text'First .. Dot - 1) => C in '0' .. '9')
         then
            return Unquoted (Trim (Text (Dot + 2 .. Text'Last)));
         end if;
      end;
      return Unquoted (Text);
   end Item_Of;

   procedure Hold
     (Rules  : Contract;
      Answer : String;
      Result : out Claims;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Current : Unbounded_String;

      procedure Refuse (Field, Detail : String) is
      begin
         Status := E.Make (E.Framework_Contract_Violation);
         E.Add_Text (Status, "name", To_String (Rules.Name) & "." & Field);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;
   begin
      Result := (others => <>);
      Status := E.Success;

      for Line of Lines_Of (Answer) loop
         declare
            Colon : constant Natural := Ada.Strings.Fixed.Index (Line, ":");
            Said  : constant String :=
              (if Colon = 0 then "" else Unquoted (Lower (Trim (Line (Line'First .. Colon - 1)))));

            --  A field named in the singular -- issue: for issues: -- is that
            --  field, not a line of the list before it.
            Name  : constant String :=
              (if Said /= "" and then not Rules.Fields.Contains (Said)
                 and then Rules.Fields.Contains (Said & "s")
               then Said & "s" else Said);
            --  What only frames an answer -- a brace, a bracket, a code
            --  fence -- ends the field before it and is no part of one.
            Bare  : constant String := Trim (Line);
            Frame : constant Boolean :=
              Bare in "{" | "}" | "[" | "]" | "}," | "],"
              or else (Bare'Length >= 3 and then Bare (Bare'First .. Bare'First + 2) = "```")
              or else (Bare'Length >= 2 and then Bare (Bare'First) = '{'
                       and then Bare (Bare'Last) = '}' and then Name = "");
         begin
            if Frame then
               Current := Null_Unbounded_String;
            elsif Name /= "" and then Rules.Fields.Contains (Name) then
               Current := To_Unbounded_String (Name);
               Result.Values.Include (Name, Item_Of (Line (Colon + 1 .. Line'Last)));
            elsif Current /= Null_Unbounded_String and then Item_Of (Line) /= "" then
               declare
                  Held : constant String := Result.Values (To_String (Current));
               begin
                  Result.Values.Include
                    (To_String (Current),
                     (if Held = "" then Item_Of (Line) else Held & ASCII.LF & Item_Of (Line)));
               end;
            end if;
         end;
      end loop;

      for Field of Rules.Order loop
         declare
            Allowed : constant String := Rules.Fields (Field);
            Given   : constant String :=
              (if Result.Values.Contains (Field) then Result.Values (Field) else "");
         begin
            if Given = "" and then not Rules.Optional.Contains (Field) then
               Refuse (Field, "the answer does not give it");
               return;
            elsif Given /= "" and then Allowed /= "" then
               declare
                  Words : constant String := "|" & Allowed & "|";
               begin
                  if Ada.Strings.Fixed.Index (Words, "|" & Lower (Given) & "|") = 0 then
                     Refuse (Field, Given & " is not one of " & Allowed);
                     return;
                  end if;
                  Result.Values.Include (Field, Lower (Given));
               end;
            end if;
         end;
      end loop;
   end Hold;

   function Claim (From : Claims; Name : String) return String
   is (if From.Values.Contains (Name) then From.Values (Name) else "");

   -----------
   -- Start --
   -----------

   procedure Start
     (Item        : Stores.Store;
      Change      : in out Stores.Transaction;
      Agent       : String;
      Task_Id     : String;
      Generation  : String;
      Profile     : String;
      Manifest    : String;
      Tool_Policy : String;
      Rules       : Contract;
      Id          : out Ada.Strings.Unbounded.Unbounded_String;
      Status      : out Model_Runner.Errors.Error_Info;
      Resource_Class : String := "")
   is
      Number : Natural;
   begin
      Id := Null_Unbounded_String;

      --  No more calls for one execution generation than the policy
      --  allows: a recursion of children cannot spend more than its root.
      declare
         Config : Records.Item;
         Read   : E.Error_Info;
      begin
         Stores.Read (Item, Config_Area, "resolved", Config, Read);
         declare
            Text  : constant String := Records.Get (Config, "scalar.agents.max_invocations");
            Limit : constant Natural :=
              (if Text'Length in 1 .. 6 and then (for all C of Text => C in '0' .. '9')
               then Natural'Value (Text) else 0);
            Made  : Natural := 0;
         begin
            if Limit > 0 and then Task_Id /= "" then
               for Name of Stores.Names (Item, Invocations_Area) loop
                  declare
                     Held : Records.Item;
                  begin
                     Stores.Read (Item, Invocations_Area, Name, Held, Read);
                     --  Calls only: the context manifests kept beside them
                     --  name the task and generation too, and are no call.
                     if Name'Length > 4 and then Name (Name'First .. Name'First + 3) = "INV-"
                       and then E.Is_Ok (Read) and then Records.Get (Held, "task") = Task_Id
                       and then Records.Get (Held, "generation") = Generation
                     then
                        Made := Made + 1;
                     end if;
                  end;
               end loop;
               if Made >= Limit then
                  Status := E.Make (E.Framework_Limit_Exceeded);
                  E.Add_Text (Status, "name", "model invocations");
                  E.Add_Text (Status, "detail", "all" & Natural'Image (Limit)
                              & " calls of this execution of " & Task_Id & " are made");
                  return;
               end if;
            end if;
         end;
      end;

      Stores.Allocate_Number (Item, Change, "INV", "", Number, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Id := To_Unbounded_String
        ("INV-" & [1 .. Integer'Max (0, 6 - Image (Number)'Length) => '0'] & Image (Number));

      declare
         Value : Records.Item :=
           Records.Create (Schemas.Invocation_Schema, 1, To_String (Id), 1);
      begin
         Records.Set (Value, "state", "started");
         Records.Set (Value, "agent", Agent);
         Records.Set (Value, "task", Task_Id);
         Records.Set (Value, "generation", Generation);
         Records.Set (Value, "model_profile", Profile);
         Records.Set (Value, "context_manifest", Manifest);
         Records.Set (Value, "tool_policy", Tool_Policy);
         Records.Set (Value, "result_contract", To_String (Rules.Name));
         Records.Set (Value, "started_at", Timestamp);
         if Resource_Class /= "" then
            Records.Set (Value, "resource_class", Resource_Class);
         end if;
         Stores.Put (Change, Invocations_Area, To_String (Id), Value);
      end;
   end Start;

   ------------
   -- Finish --
   ------------

   procedure Finish
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      How       : Ending;
      Used      : Usage;
      Result_Id : String;
      Failure   : String;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Value  : Records.Item;
      Staged : Boolean;
      Next   : constant String := Lower (Ending'Image (How));
   begin
      Status := E.Success;
      Stores.Pending (Change, Invocations_Area, Id, Value, Staged);
      if not Staged then
         Stores.Read (Item, Invocations_Area, Id, Value, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Value, Records.Revision (Value) + 1);
      end if;

      Transitions.Check
        (Machine, Id, Records.Get (Value, "state"), Next, Transitions.Ordinary_Only,
         Status);
      if E.Is_Error (Status) then
         return;
      end if;

      Records.Set (Value, "state", Next);
      Records.Set (Value, "ended_at", Timestamp);
      Records.Set (Value, "prompt_tokens", Image (Used.Prompt_Tokens));
      Records.Set (Value, "output_tokens", Image (Used.Output_Tokens));
      Records.Set (Value, "seconds", Image (Used.Seconds));
      if Result_Id /= "" then
         Records.Set (Value, "result", Result_Id);
      end if;
      --  Stopped by whoever ran it is not a failure to look into: said on
      --  the call, and kept as nothing more.
      if Failure /= "" and then Next = "cancelled" then
         Records.Set (Value, "failure", "cancelled: " & Failure);
      elsif Failure /= "" then
         Records.Set (Value, "failure", Failure);

         --  And kept as a record of its own, which the call refers to: a
         --  failure is looked up, not only read off a line.
         declare
            Kept : Results.Result :=
              (Kind       => Results.Diagnostic,
               Producer   => Ada.Strings.Unbounded.To_Unbounded_String (Records.Get (Value, "agent")),
               Summary    => Ada.Strings.Unbounded.To_Unbounded_String (Id & " failed: " & Failure),
               Payload    => Ada.Strings.Unbounded.To_Unbounded_String (Failure),
               Provenance => Ada.Strings.Unbounded.To_Unbounded_String (Id),
               others     => <>);
            Kept_Status : E.Error_Info;
         begin
            Results.Add (Item, Change, Kept, Kept_Status);
            if E.Is_Ok (Kept_Status) then
               Records.Set (Value, "failure_result", Ada.Strings.Unbounded.To_String (Kept.Id));
            end if;
         end;
      end if;
      Stores.Put (Change, Invocations_Area, Id, Value);
   end Finish;

   ---------------
   -- Note_Call --
   ---------------

   procedure Note_Call
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Named     : String;
      Arguments : String;
      Answer    : String;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Value  : Records.Item;
      Staged : Boolean;
      Calls  : Natural := 0;

      --  The start of a text, on one line.
      function Start_Of (Text : String) return String is
         Cut : String := Text (Text'First .. Text'First + Natural'Min (Text'Length, 200) - 1);
      begin
         for C of Cut loop
            if C in ASCII.LF | ASCII.CR | ASCII.HT then
               C := ' ';
            end if;
         end loop;
         return Cut & (if Text'Length > 200 then "..." else "");
      end Start_Of;
   begin
      Status := E.Success;
      Stores.Pending (Change, Invocations_Area, Id, Value, Staged);
      if not Staged then
         Stores.Read (Item, Invocations_Area, Id, Value, Status);
         if E.Is_Error (Status) then
            return;
         end if;
         Records.Set_Revision (Value, Records.Revision (Value) + 1);
      end if;
      for Index in 1 .. Records.Field_Count (Value) loop
         if Ada.Strings.Fixed.Index (Records.Field_Name (Value, Index), "call.") = 1 then
            Calls := Calls + 1;
         end if;
      end loop;
      Records.Set
        (Value, "call." & [1 .. Integer'Max (0, 4 - Image (Calls + 1)'Length) => '0']
                & Image (Calls + 1),
         Named & ASCII.HT & Start_Of (Arguments) & ASCII.HT & Start_Of (Answer));
      Stores.Put (Change, Invocations_Area, Id, Value);
   end Note_Call;

   --------------
   -- State_Of --
   --------------

   function State_Of (Item : Stores.Store; Id : String) return String is
      Value  : Records.Item;
      Status : E.Error_Info;
   begin
      Stores.Read (Item, Invocations_Area, Id, Value, Status);
      return (if E.Is_Ok (Status) then Records.Get (Value, "state") else "");
   end State_Of;

end Model_Runner.Framework.Invocations;
