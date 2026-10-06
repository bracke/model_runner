separate (Model_Runner.Framework.Work)
function Instructions_With
  (Item    : Stores.Store;
   Task_Id : String;
   Allowed : Permissions.Permission_Set;
   Apart   : Boolean;
   Helpers : Boolean := True) return String
is
   May_Write   : constant Boolean :=
     Allowed (Permissions.Write_Source).Granted or else Allowed (Permissions.Write_Specs).Granted;
   --  Helpers only where the runner can make them: a model run apart
   --  has no delegate tool.
   May_Delegate : constant Boolean :=
     Helpers and then Allowed (Permissions.Create_Children).Granted
     and then Allowed (Permissions.Create_Children).Max_Children > 0
     and then Allowed (Permissions.Create_Children).Max_Depth >= 1
     --  None allowed by the agents' own bound: no helpers either.
     and then Agents.Limits_Of (Item).Max_Children > 0;
   May_Check   : constant Boolean := Helpers and then Offers_Checks (Item, Allowed, Task_Id, Apart);
   May_Propose : constant Boolean := Permissions.Allows (Allowed, Permissions.Propose_Tasks);

   function May_Split return Boolean is
      Depth : Natural := 0;
      Up    : Unbounded_String := To_Unbounded_String (Task_Id);
      Limit : constant Permissions.Grant :=
        (if Allowed (Permissions.Create_Children).Granted then Allowed (Permissions.Create_Children)
         else Permissions.Effective (Item, "", "", Within_Sandbox => False) (Permissions.Create_Children));
      Bounds : constant Agents.Limits := Agents.Limits_Of (Item);
   begin
      loop
         declare
            Defined_Up : Records.Item;
            Read_Up    : E.Error_Info;
         begin
            Tasks.Definition (Item, To_String (Up), Defined_Up, Read_Up);
            exit when E.Is_Error (Read_Up) or else Records.Get (Defined_Up, "parent") = ""
              or else Depth > 64;
            Up := To_Unbounded_String (Records.Get (Defined_Up, "parent"));
            Depth := Depth + 1;
         end;
      end loop;
      return Limit.Granted and then Depth + 1 <= Natural'Min (Limit.Max_Depth, Bounds.Max_Depth);
   end May_Split;

   --  The permissions it has a tool for, in plain words.
   function Said_Permissions return String is
      Said : Unbounded_String;
      procedure Add (Text : String) is
      begin
         Append (Said, (if Said = Null_Unbounded_String then "" else "; ") & Text);
      end Add;
   begin
      if Allowed (Permissions.Read_Source).Granted then
         Add ("read the source");
      end if;
      if Allowed (Permissions.Read_Specs).Granted then
         Add ("read the specifications");
      end if;
      if Allowed (Permissions.Write_Source).Granted then
         Add ("write " & (if Allowed (Permissions.Write_Source).Roots.Is_Empty then "files"
                          else "files under " & Comma_Separated (Allowed (Permissions.Write_Source).Roots))
              --  What it may not, inherited or its own, said with it.
              & (if Allowed (Permissions.Write_Source).Deny.Is_Empty then ""
                 else " except " & Comma_Separated (Allowed (Permissions.Write_Source).Deny)));
      end if;
      if Allowed (Permissions.Write_Specs).Granted then
         Add ("write specifications "
              & (if Allowed (Permissions.Write_Specs).Roots.Is_Empty
                 then "(in " & Permissions.Specification_Places & ")"
                 else "under " & Comma_Separated (Allowed (Permissions.Write_Specs).Roots)));
      end if;
      --  Its checks, by the profile that runs them.
      if May_Check then
         declare
            Kind    : constant String := Kind_Of_Task (Item, Task_Id);
            Profile : constant String :=
              (if Tasks.Kind_Policy (Item, Kind, "profile") /= "" then Tasks.Kind_Policy (Item, Kind, "profile")
               else Scalar (Item, "verification.default"));
         begin
            Add ("run the project's checks" & (if Profile = "" then "" else " (profile " & Profile & ")"));
         end;
      end if;
      if May_Delegate then
         --  The lower of the grant and the agents' own bound: what an
         --  agent meets.
         Add ("hand parts to helpers (at most"
              & Natural'Image (Natural'Min (Allowed (Permissions.Create_Children).Max_Children,
                                            Agents.Limits_Of (Item).Max_Children)) & ")");
      end if;
      if May_Propose then
         Add ("propose tasks");
      end if;
      return (if Said = Null_Unbounded_String then "read only what you are given" else To_String (Said));
   end Said_Permissions;

   Parts : Unbounded_String;
begin
   for Child of Tasks.Children (Item, Task_Id) loop
      declare
         Defined : Records.Item;
         Read    : E.Error_Info;
      begin
         Tasks.Definition (Item, Child, Defined, Read);
         Append (Parts, "- " & Child & " " & Records.Get (Defined, "title") & ": "
                 & Tasks.State_Of (Item, Child) & ASCII.LF);
      end;
   end loop;
   return Instructions_For (May_Propose, May_Split, May_Write,
                            May_Delegate => May_Delegate, May_Check => May_Check)
     & ASCII.LF & "## What you may do" & ASCII.LF
     & "You may " & Said_Permissions & "."
     & (if May_Write then " Change only the files you may write; a change to any other file fails the work."
        else "")
     & (if May_Propose then "" else " You may not propose tasks or parts.")
     & ASCII.LF
     & (if Parts = Null_Unbounded_String then ""
        else ASCII.LF & "## Your parts" & ASCII.LF & To_String (Parts)
             & "Those complete are done: do what is left of the task itself, and do not split"
             & " it into them again." & ASCII.LF);
end Instructions_With;
