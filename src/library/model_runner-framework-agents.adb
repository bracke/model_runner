with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Events;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Agents is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   Prefix : constant String := "agent.";

   function Trim (Text : String) return String
   is (Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both));

   function Image (Value : Natural) return String
   is (Trim (Natural'Image (Value)));

   function Number (Text : String; Default : Natural) return Natural
   is (if Text'Length in 1 .. 9 and then (for all C of Text => C in '0' .. '9')
       then Natural'Value (Text) else Default);

   function Need_Word (Need : Obligation) return String
   is (Ada.Characters.Handling.To_Lower (Obligation'Image (Need)));

   ---------------
   -- Limits_Of --
   ---------------

   function Limits_Of (Item : Stores.Store) return Limits is
      Config : Records.Item;
      Status : E.Error_Info;
      Result : Limits;
   begin
      Configurations.Read (Item, Config, Status);
      if E.Is_Ok (Status) then
         Result.Max_Depth :=
           Number (Records.Get (Config, "scalar.agents.max_depth"), Result.Max_Depth);
         Result.Max_Children :=
           Number (Records.Get (Config, "scalar.agents.max_children"), Result.Max_Children);
         Result.Max_Active :=
           Number (Records.Get (Config, "scalar.agents.max_active"), Result.Max_Active);
         Result.Token_Budget :=
           Number (Records.Get (Config, "scalar.agents.token_budget"), Result.Token_Budget);
      end if;
      return Result;
   end Limits_Of;

   --  The agent record a transaction will leave, or the one there is.
   procedure Current
     (Item   : Stores.Store;
      Change : Stores.Transaction;
      Id     : String;
      Value  : out Records.Item;
      Status : out E.Error_Info)
   is
      Staged : Boolean;
   begin
      Status := E.Success;
      Stores.Pending (Change, Runtime_Area, Prefix & Id, Value, Staged);
      if not Staged then
         Stores.Read (Item, Runtime_Area, Prefix & Id, Value, Status);
         if E.Is_Ok (Status) then
            Records.Set_Revision (Value, Records.Revision (Value) + 1);
         end if;
      end if;
   end Current;

   function From_Record (Value : Records.Item) return Agent is
      Result : Agent;
   begin
      Result.Id := To_Unbounded_String (Records.Entity_Id (Value));
      Result.Role := To_Unbounded_String (Records.Get (Value, "role"));
      Result.Parent := To_Unbounded_String (Records.Get (Value, "parent"));
      Result.Task_Id := To_Unbounded_String (Records.Get (Value, "task"));
      Result.Depth := Number (Records.Get (Value, "depth"), 0);
      Result.Need :=
        (if Records.Get (Value, "need") = "optional" then Optional
         elsif Records.Get (Value, "need") = "advisory" then Advisory
         else Required);
      Result.Status := To_Unbounded_String (Records.Get (Value, "state"));
      Result.Budget := Number (Records.Get (Value, "budget"), 0);
      Result.Used := Number (Records.Get (Value, "used"), 0);
      Result.Allowed := Permissions.Value (Records.Get (Value, "permissions"));
      Result.Result := To_Unbounded_String (Records.Get (Value, "result"));
      Result.Summary := To_Unbounded_String (Records.Get (Value, "summary"));
      Result.Retry_Of := To_Unbounded_String (Records.Get (Value, "retry_of"));
      Result.Generation := To_Unbounded_String (Records.Get (Value, "generation"));
      Result.Workspace := To_Unbounded_String (Records.Get (Value, "workspace"));
      Result.Invocation :=
        (if Records.Get (Value, "state") = "running"
         then To_Unbounded_String (Records.Get (Value, "invocation"))
         else Null_Unbounded_String);
      Result.Children := To_Unbounded_String (Records.Get (Value, "children"));
      return Result;
   end From_Record;

   ----------
   -- Read --
   ----------

   procedure Read
     (Item   : Stores.Store;
      Id     : String;
      Result : out Agent;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
   begin
      Result := (others => <>);
      Stores.Read (Item, Runtime_Area, Prefix & Id, Value, Status);
      if E.Is_Ok (Status) then
         Result := From_Record (Value);
      end if;
   end Read;

   --  How many agents are going: made and not ended.
   function Active_Count (Item : Stores.Store) return Natural is
      Count : Natural := 0;
   begin
      for Name of Stores.Names (Item, Runtime_Area) loop
         if Name'Length > Prefix'Length
           and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
         then
            declare
               Held   : Agent;
               Status : E.Error_Info;
            begin
               Read (Item, Name (Name'First + Prefix'Length .. Name'Last), Held, Status);
               if E.Is_Ok (Status)
                 and then To_String (Held.Status) in "created" | "running" | "waiting"
               then
                  Count := Count + 1;
               end if;
            end;
         end if;
      end loop;
      return Count;
   end Active_Count;

   procedure Over (What, Detail : String; Status : out E.Error_Info) is
   begin
      Status := E.Make (E.Framework_Limit_Exceeded);
      E.Add_Text (Status, "name", What);
      E.Add_Text (Status, "detail", Detail);
   end Over;

   --  Make an agent's record.
   procedure Make
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Held    : Agent;
      Id      : out Unbounded_String;
      Status  : out E.Error_Info)
   is
      Count : Natural;
   begin
      Stores.Allocate_Number (Item, Change, "AG", "", Count, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Id := To_Unbounded_String
        ("AG-" & [1 .. Integer'Max (0, 6 - Image (Count)'Length) => '0'] & Image (Count));

      declare
         Value : Records.Item :=
           Records.Create (Schemas.Agent_Schema, 1, To_String (Id), 1);
         Event : Unbounded_String;
      begin
         Records.Set (Value, "state", "running");
         Records.Set (Value, "task", To_String (Held.Task_Id));
         Records.Set (Value, "started_at", Timestamp);
         Records.Set (Value, "role", To_String (Held.Role));
         Records.Set (Value, "parent", To_String (Held.Parent));
         Records.Set (Value, "depth", Image (Held.Depth));
         Records.Set (Value, "need", Need_Word (Held.Need));
         Records.Set (Value, "budget", Image (Held.Budget));
         Records.Set (Value, "used", "0");
         Records.Set (Value, "permissions", Permissions.Image (Held.Allowed));
         if Held.Retry_Of /= Null_Unbounded_String then
            Records.Set (Value, "retry_of", To_String (Held.Retry_Of));
         end if;

         --  The execution of the task it works in.
         declare
            Task_State : Records.Item;
            Read       : E.Error_Info;
         begin
            Stores.Read (Item, Tasks_Area, To_String (Held.Task_Id) & ".state", Task_State, Read);
            if E.Is_Ok (Read) and then Records.Get (Task_State, "generation") /= "" then
               Records.Set (Value, "generation", Records.Get (Task_State, "generation"));
            end if;
         end;
         Stores.Put (Change, Runtime_Area, Prefix & To_String (Id), Value);

         --  Its parent's list of its children.
         if Held.Parent /= Null_Unbounded_String then
            declare
               Owner  : Records.Item;
               Staged : Boolean;
               Read   : E.Error_Info;
            begin
               Stores.Pending (Change, Runtime_Area, Prefix & To_String (Held.Parent), Owner, Staged);
               if not Staged then
                  Stores.Read (Item, Runtime_Area, Prefix & To_String (Held.Parent), Owner, Read);
                  if E.Is_Ok (Read) then
                     Records.Set_Revision (Owner, Records.Revision (Owner) + 1);
                  end if;
               end if;
               if Staged or else E.Is_Ok (Read) then
                  Records.Set
                    (Owner, "children",
                     (if Records.Get (Owner, "children") = "" then To_String (Id)
                      else Records.Get (Owner, "children") & ASCII.LF & To_String (Id)));
                  Stores.Put (Change, Runtime_Area, Prefix & To_String (Held.Parent), Owner);
               end if;
            end;
         end if;
         Events.Emit (Item, Change, Events.Agent_Spawned, To_String (Id),
                      (if Held.Parent = Null_Unbounded_String then "root"
                       else "child of " & To_String (Held.Parent)),
                      Event, Status);
      end;
   end Make;

   ----------------
   -- Start_Root --
   ----------------

   procedure Start_Root
     (Item    : Stores.Store;
      Change  : in out Stores.Transaction;
      Task_Id : String;
      Role    : String;
      Kind    : String;
      Id      : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Model_Runner.Errors.Error_Info;
      Restriction : String := "";
      Budget  : Natural := 0)
   is
      Bounds : constant Limits := Limits_Of (Item);
   begin
      Id := Null_Unbounded_String;
      if Active_Count (Item) >= Bounds.Max_Active then
         Over ("agents", "the project's" & Natural'Image (Bounds.Max_Active)
               & " agents are all running", Status);
         return;
      end if;
      Make (Item, Change,
            (Role    => To_Unbounded_String (Role),
             Task_Id => To_Unbounded_String (Task_Id),
             Depth   => 0,
             Need    => Required,
             Budget  => (if Budget > 0 then Budget else Bounds.Token_Budget),
             Allowed => Permissions.Effective
                          (Item, Kind, Role, Task_Level => Restriction),
             others  => <>),
            Id, Status);
   end Start_Root;

   --------------
   -- Children --
   --------------

   function Children
     (Item   : Stores.Store;
      Parent : String) return Name_Lists.Vector
   is
      Result : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Runtime_Area) loop
         if Name'Length > Prefix'Length
           and then Name (Name'First .. Name'First + Prefix'Length - 1) = Prefix
         then
            declare
               Held   : Agent;
               Status : E.Error_Info;
            begin
               Read (Item, Name (Name'First + Prefix'Length .. Name'Last), Held, Status);
               if E.Is_Ok (Status) and then To_String (Held.Parent) = Parent then
                  Result.Append (To_String (Held.Id));
               end if;
            end;
         end if;
      end loop;
      return Result;
   end Children;

   -----------------
   -- Spawn_Child --
   -----------------

   procedure Spawn_Child
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Parent : String;
      Role   : String;
      Need   : Obligation;
      Asked  : Permissions.Permission_Set;
      Budget : Natural;
      Id     : out Ada.Strings.Unbounded.Unbounded_String;
      Status : out Model_Runner.Errors.Error_Info;
      Retry_Of : String := "")
   is
      Bounds : constant Limits := Limits_Of (Item);
      Value  : Records.Item;

      --  Its children, less those run again for one that failed.
      function First_Runs return Natural is
         Count : Natural := 0;
      begin
         for Child of Children (Item, Parent) loop
            declare
               Held : Agent;
               Read_Status : E.Error_Info;
            begin
               Read (Item, Child, Held, Read_Status);
               if Held.Retry_Of = Null_Unbounded_String then
                  Count := Count + 1;
               end if;
            end;
         end loop;
         return Count;
      end First_Runs;
   begin
      Id := Null_Unbounded_String;
      Current (Item, Change, Parent, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Owner : constant Agent := From_Record (Value);
         Grant : Permissions.Grant renames Owner.Allowed (Permissions.Create_Children);
         Depth : constant Natural := Owner.Depth + 1;
         Left  : constant Natural :=
           (if Owner.Used >= Owner.Budget then 0 else Owner.Budget - Owner.Used);
      begin
         if To_String (Owner.Status) /= "running" then
            Status := E.Make (E.Framework_Transition_Invalid);
            E.Add_Text (Status, "name", Parent);
            E.Add_Text (Status, "value", To_String (Owner.Status));
            E.Add_Text (Status, "expected", "running");
            E.Add_Text (Status, "detail", "only a running agent makes children");
            return;
         elsif not Grant.Granted then
            Status := E.Make (E.Framework_Permission_Denied);
            E.Add_Text (Status, "name", Parent);
            E.Add_Text (Status, "detail", "it may not create children");
            return;
         elsif Depth > Bounds.Max_Depth or else Depth > Grant.Max_Depth then
            Over (Parent, "a child would be" & Natural'Image (Depth)
                  & " deep, past the limit", Status);
            return;
         elsif Retry_Of = ""
           and then First_Runs >= Natural'Min (Bounds.Max_Children, Grant.Max_Children)
         then
            Over (Parent, "it has all the children it may have", Status);
            return;
         elsif Active_Count (Item) >= Bounds.Max_Active then
            Over ("agents", "the project's" & Natural'Image (Bounds.Max_Active)
                  & " agents are all running", Status);
            return;
         elsif Budget > Left then
            Over (Parent, "it has" & Natural'Image (Left) & " tokens left, not"
                  & Natural'Image (Budget), Status);
            return;
         end if;

         --  What the child is given comes out of the parent's: its budget
         --  is set aside, and its permissions are what both allow.
         Records.Set (Value, "used", Image (Owner.Used + Budget));
         Stores.Put (Change, Runtime_Area, Prefix & Parent, Value);

         declare
            Role_Level : Permissions.Permission_Set;
            Present    : Boolean;
            Allowed    : Permissions.Permission_Set :=
              Permissions.Intersect (Owner.Allowed, Asked);
         begin
            Role_Level := Permissions.Level_Of (Item, "role." & Role, Present);
            if Present then
               Allowed := Permissions.Intersect (Allowed, Role_Level);
            end if;
            Make (Item, Change,
                  (Role    => To_Unbounded_String (Role),
                   Parent  => To_Unbounded_String (Parent),
                   Task_Id => Owner.Task_Id,
                   Depth   => Depth,
                   Need    => Need,
                   Budget  => Budget,
                   Allowed => Allowed,
                   Retry_Of => To_Unbounded_String (Retry_Of),
                   others  => <>),
                  Id, Status);
         end;
      end;
   end Spawn_Child;

   ------------
   -- Charge --
   ------------

   procedure Charge
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      Tokens : Natural;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
   begin
      Current (Item, Change, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         Used   : constant Natural := Number (Records.Get (Value, "used"), 0) + Tokens;
         Budget : constant Natural := Number (Records.Get (Value, "budget"), 0);
      begin
         Records.Set (Value, "used", Image (Used));
         Stores.Put (Change, Runtime_Area, Prefix & Id, Value);
         if Used > Budget then
            Over (Id, "it has used" & Natural'Image (Used) & " of"
                  & Natural'Image (Budget) & " tokens", Status);
         end if;
      end;
   end Charge;

   ------------
   -- Finish --
   ------------

   procedure Finish
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Succeeded : Boolean;
      Result_Id : String;
      Summary   : String;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      Value : Records.Item;
      Event : Unbounded_String;
   begin
      Current (Item, Change, Id, Value, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      if Records.Get (Value, "state") not in "created" | "running" | "waiting" then
         Status := E.Make (E.Framework_Transition_Invalid);
         E.Add_Text (Status, "name", Id);
         E.Add_Text (Status, "value", Records.Get (Value, "state"));
         E.Add_Text (Status, "expected", (if Succeeded then "completed" else "failed"));
         E.Add_Text (Status, "detail", "it has ended already");
         return;
      end if;

      Records.Set (Value, "state", (if Succeeded then "completed" else "failed"));
      Records.Set (Value, "ended_at", Timestamp);
      Records.Set (Value, "result", Result_Id);
      Records.Set (Value, "summary", Summary);
      Stores.Put (Change, Runtime_Area, Prefix & Id, Value);
      Events.Emit (Item, Change,
                   (if Succeeded then Events.Agent_Completed else Events.Agent_Failed),
                   Id, Summary, Event, Status);

      --  A required child's failure is its parent's to know of.
      if not Succeeded and then Records.Get (Value, "need") = "required"
        and then Records.Get (Value, "parent") /= ""
      then
         declare
            Parent : constant String := Records.Get (Value, "parent");
            Owner  : Records.Item;
            Held   : E.Error_Info;
         begin
            Current (Item, Change, Parent, Owner, Held);
            if E.Is_Ok (Held) then
               Records.Set
                 (Owner, "failed_children",
                  (if Records.Get (Owner, "failed_children") = "" then Id
                   else Records.Get (Owner, "failed_children") & ASCII.LF & Id));
               Stores.Put (Change, Runtime_Area, Prefix & Parent, Owner);
            end if;
         end;
      end if;
   end Finish;

   --------------------
   -- Record_Holding --
   --------------------

   procedure Record_Holding
     (Item       : Stores.Store;
      Change     : in out Stores.Transaction;
      Id         : String;
      Workspace  : String;
      Invocation : String;
      Status     : out Model_Runner.Errors.Error_Info)
   is
      Value  : Records.Item;
      Staged : Boolean;
   begin
      Status := E.Success;
      Stores.Pending (Change, Runtime_Area, Prefix & Id, Value, Staged);
      if not Staged then
         Stores.Read (Item, Runtime_Area, Prefix & Id, Value, Status);
         if E.Is_Error (Status) then
            Status := E.Make (E.Framework_Not_Found);
            E.Add_Text (Status, "name", Id);
            return;
         end if;
         Records.Set_Revision (Value, Records.Revision (Value) + 1);
      end if;
      if Workspace /= "" then
         Records.Set (Value, "workspace", Workspace);
      end if;
      if Invocation /= "" then
         Records.Set (Value, "invocation", Invocation);
      end if;
      Stores.Put (Change, Runtime_Area, Prefix & Id, Value);
   end Record_Holding;

   ------------------
   -- May_Complete --
   ------------------

   function May_Complete
     (Item   : Stores.Store;
      Id     : String;
      Reason : out Ada.Strings.Unbounded.Unbounded_String;
      Past_Failures : Boolean := False) return Boolean
   is
      Mine : constant Name_Lists.Vector := Children (Item, Id);

      --  Whether a failed child was run again until one of its runs
      --  completed.
      function Made_Good (Failed : String) return Boolean is
      begin
         for Child of Mine loop
            declare
               Held   : Agent;
               Status : E.Error_Info;
            begin
               Read (Item, Child, Held, Status);
               if To_String (Held.Retry_Of) = Failed
                 and then (To_String (Held.Status) = "completed"
                           or else (To_String (Held.Status) = "failed"
                                    and then Made_Good (Child)))
               then
                  return True;
               end if;
            end;
         end loop;
         return False;
      end Made_Good;
   begin
      Reason := Null_Unbounded_String;
      for Child of Mine loop
         declare
            Held   : Agent;
            Status : E.Error_Info;
         begin
            Read (Item, Child, Held, Status);
            if Held.Need = Required then
               if To_String (Held.Status) in "created" | "running" | "waiting" then
                  Reason := To_Unbounded_String ("its required child " & Child
                                                 & " is still going");
                  return False;
               elsif To_String (Held.Status) = "failed" and then not Made_Good (Child)
                 and then not Past_Failures
               then
                  Reason := To_Unbounded_String
                    ("its required child " & Child & " failed"
                     & (if Held.Summary = Null_Unbounded_String then ""
                        else ": " & To_String (Held.Summary)));
                  return False;
               end if;
            end if;
         end;
      end loop;
      return True;
   end May_Complete;

   ------------
   -- Cancel --
   ------------

   procedure Cancel
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Id        : String;
      Cancelled : out Name_Lists.Vector;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      procedure Stop (Named : String) is
         Value : Records.Item;
         Event : Unbounded_String;
      begin
         Current (Item, Change, Named, Value, Status);
         if E.Is_Error (Status)
           or else Records.Get (Value, "state") not in "created" | "running" | "waiting"
         then
            Status := E.Success;
            return;
         end if;
         Records.Set (Value, "state", "cancelled");
         Records.Set (Value, "ended_at", Timestamp);
         Stores.Put (Change, Runtime_Area, Prefix & Named, Value);
         Events.Emit (Item, Change, Events.Agent_Cancelled, Named, "", Event, Status);
         Cancelled.Append (Named);
         for Child of Children (Item, Named) loop
            Stop (Child);
         end loop;
      end Stop;
   begin
      Cancelled.Clear;
      Status := E.Success;
      Stop (Id);
   end Cancel;

   -------------------
   -- Child_Results --
   -------------------

   function Child_Results (Item : Stores.Store; Parent : String) return String is
      Text : Unbounded_String;
   begin
      for Child of Children (Item, Parent) loop
         declare
            Held   : Agent;
            Status : E.Error_Info;
         begin
            Read (Item, Child, Held, Status);
            Append (Text, Child & " (" & Need_Word (Held.Need) & ", "
                    & To_String (Held.Status) & ")"
                    & (if Held.Result = Null_Unbounded_String then ""
                       else " " & To_String (Held.Result))
                    & (if Held.Summary = Null_Unbounded_String then ""
                       else ": " & To_String (Held.Summary))
                    & ASCII.LF);
         end;
      end loop;
      return To_String (Text);
   end Child_Results;

end Model_Runner.Framework.Agents;
