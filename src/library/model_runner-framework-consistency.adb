with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Model_Runner.Errors;
with Model_Runner.Framework.Authority;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Leases;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Verification;
with Model_Runner.Framework.Workspaces;
with Model_Runner.Framework.Tasks;
with Model_Runner.Text;

package body Model_Runner.Framework.Consistency is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   ---------------
   -- Kind_Word --
   ---------------

   function Kind_Word (Kind : Finding_Kind) return String
   is (Ada.Characters.Handling.To_Lower (Finding_Kind'Image (Kind)));

   -----------
   -- Check --
   -----------

   function Check (Item : Stores.Store) return Finding_List is
      Result : Finding_List;

      --  Every indexed entity and where its record is, as the index keeps
      --  them, so the stored index can be compared with the records.
      Expected : Configurations.Value_Maps.Map;

      procedure Found (Kind : Finding_Kind; Subject, Detail : String) is
      begin
         Result.Findings.Append
           (Finding'(Kind    => Kind,
             Subject => To_Unbounded_String (Subject),
             Detail  => To_Unbounded_String (Detail)));
      end Found;

      function Detail_Of (Status : E.Error_Info) return String is
         Text : Unbounded_String :=
           To_Unbounded_String (E.Error_Code'Image (Status.Code));
      begin
         for Index in 1 .. Status.Parameter_Total loop
            Append (Text, " " & Model_Runner.Text.To_String
                                  (Status.Parameters (Index).Text_Value));
         end loop;
         return To_String (Text);
      end Detail_Of;
   begin
      if not Stores.Is_Open (Item) then
         return Result;
      end if;

      --  Every record keeps to its schema, and no two authoritative ones
      --  claim one entity.
      for Where in Area loop
         if Where /= Indexes_Area then
            for Name of Stores.Names (Item, Where) loop
               declare
                  Place  : constant String :=
                    Directory_Name (Where) & "/" & Name;
                  Value  : Records.Item;
                  Status : E.Error_Info;
               begin
                  Stores.Read (Item, Where, Name, Value, Status);
                  if E.Is_Error (Status) then
                     Found (Schema_Mismatch, Place, Detail_Of (Status));
                  elsif Class_Of (Where) in Authored_State | Historical_State
                  then
                     declare
                        Entity : constant String := Records.Entity_Id (Value);
                     begin
                        if Expected.Contains (Entity) then
                           Found (Duplicate_Identifier, Entity,
                                  Expected (Entity) & " and " & Place);
                        else
                           Expected.Include (Entity, Place);
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;
      end loop;

      if Stores.Journal_Pending (Item) then
         Found (Incomplete_Transaction, "runtime/journal",
                "a change was staged and not finished");
      end if;

      --  The index is derived, and says what the records say or is wrong.
      declare
         Index  : Records.Item;
         Status : E.Error_Info;
      begin
         Stores.Read (Item, Indexes_Area, "entities", Index, Status);
         if E.Is_Error (Status) then
            Found (Index_Mismatch, "indexes/entities", Detail_Of (Status));
         else
            for Position in Expected.Iterate loop
               declare
                  Entity : constant String :=
                    Configurations.Value_Maps.Key (Position);
                  Place  : constant String :=
                    Configurations.Value_Maps.Element (Position);
               begin
                  if Records.Get (Index, "entity." & Entity) /= Place then
                     Found (Index_Mismatch, Entity,
                            "the index does not say it is in " & Place);
                  end if;
               end;
            end loop;

            for Field_At in 1 .. Records.Field_Count (Index) loop
               declare
                  Field : constant String := Records.Field_Name (Index, Field_At);
                  Stem  : constant String := "entity.";
               begin
                  if Field'Length > Stem'Length
                    and then Field (Field'First .. Field'First + Stem'Length - 1)
                               = Stem
                    and then not Expected.Contains
                                   (Field (Field'First + Stem'Length .. Field'Last))
                  then
                     Found (Index_Mismatch,
                            Field (Field'First + Stem'Length .. Field'Last),
                            "the index knows an entity no record is");
                  end if;
               end;
            end loop;
         end if;
      end;

      for Resource of Leases.Stale (Item) loop
         Found (Stale_Lease, Resource, "its lease has run out");
      end loop;

      --  A requirement depended on is one there is.
      for Id of Intent.List (Item, Intent.Requirement) loop
         for Target of Intent.Links (Item, Intent.Requirement, Id,
                                     Intent.Dependency)
         loop
            if not Stores.Exists (Item, Requirements_Area, Target) then
               Found (Undefined_Requirement, Id,
                      "it depends on " & Target & ", which is not there; req unlink " & Id
                      & " dependency " & Target & " takes the link off");
            end if;
         end loop;
      end loop;

      --  Statements that disagree with what governs their subject, and do
      --  not say they override it.
      --  Within the project, and within each component: statements for
      --  two components do not meet.
      declare
         use type Authority.Relation;
         Scopes : Name_Lists.Vector := Tasks.Components (Item);
         Said   : Name_Lists.Vector;
      begin
         Scopes.Prepend ("");
         for Scope of Scopes loop
            declare
               Resolved : constant Authority.Resolution :=
                 Authority.Resolve (Authority.Gather (Item, Scope));
            begin
               for Index in 1 .. Authority.Length (Resolved) loop
                  declare
                     Standing : constant Authority.Standing_Of :=
                       Authority.Element (Resolved, Index);
                     Line : constant String :=
                       To_String (Standing.Governing.Source) & " says "
                       & To_String (Standing.Governing.Value) & " and "
                       & To_String (Standing.Other.Source) & " says "
                       & To_String (Standing.Other.Value);
                  begin
                     if Standing.Relation = Authority.Conflict and then not Said.Contains (Line)
                     then
                        Said.Append (Line);
                        declare
                           Subject : constant String := To_String (Standing.Governing.Subject);
                           Mine    : constant String := To_String (Standing.Governing.Source);
                           Theirs  : constant String := To_String (Standing.Other.Source);
                           Ruling  : constant String := To_String (Standing.Governing.Value);
                           --  What it overrides already, kept beside the new.
                           Before  : constant String := To_String (Standing.Governing.Overrides);
                           Over    : constant String :=
                             (if Before = "" then Theirs else Before & "," & Theirs);
                        begin
                           Found (Conflicting_Authority, Subject,
                                  Line & "; to settle it, "
                                  & (if Theirs = "CONFIG"
                                     then "reconfigure " & Subject & "=" & Ruling
                                          & " makes the configuration agree, or "
                                     else "")
                                  & (if Ada.Strings.Fixed.Index (Mine, "DEC-") = 1
                                     then "decision govern " & Mine & " " & Subject & " " & Ruling
                                          & " overrides=" & Over & " says " & Mine & " holds over "
                                          & Theirs
                                     else "decision supersede, or a ruling that says which holds"));
                        end;
                     end if;
                  end;
               end loop;
            end;
         end loop;
      end;

      --  Tasks: every task named is one there is, no dependency or parent
      --  comes back to itself, and every task is of a kind the project
      --  defines, with only the fields that kind allows.
      declare
         Known_Kinds : constant Name_Lists.Vector := Tasks.Kinds (Item);
         Linking     : Name_Lists.Vector := Name_Lists.To_Vector ("depends_on", 1);
      begin
         Linking.Append ("parent");
         for Id of Tasks.List (Item) loop
            declare
               Defined : Records.Item;
               Status  : E.Error_Info;
            begin
               Tasks.Definition (Item, Id, Defined, Status);
               if E.Is_Ok (Status) then
                  for Field of Linking loop
                     for Other of Lines_Of (Records.Get (Defined, Field)) loop
                        if not Stores.Exists (Item, Tasks_Area, Other) then
                           Found (Unknown_Task_Reference, Id,
                                  "its " & Field & " names " & Other
                                  & ", which is not there");
                        end if;
                     end loop;
                  end loop;

                  for Requirement of Lines_Of
                                       (Records.Get (Defined, "requirements"))
                  loop
                     if not Stores.Exists (Item, Requirements_Area, Requirement)
                     then
                        Found (Undefined_Requirement, Id,
                               "it serves " & Requirement
                               & ", which is not there");
                     end if;
                  end loop;

                  declare
                     Kind : constant String := Records.Get (Defined, "kind");
                  begin
                     if not Known_Kinds.Contains (Kind) then
                        Found (Invalid_Task_Kind, Id,
                               Kind & " is not a kind the project defines");
                     else
                        declare
                           Allowed : constant Name_Lists.Vector :=
                             Tasks.Allowed_Fields (Item, Kind);
                        begin
                           for Index in 1 .. Records.Field_Count (Defined) loop
                              declare
                                 Field : constant String :=
                                   Records.Field_Name (Defined, Index);
                              begin
                                 if Field'Length > 6
                                   and then Field (Field'First .. Field'First + 5)
                                              = "field."
                                   and then not Allowed.Contains
                                                  (Field (Field'First + 6
                                                          .. Field'Last))
                                 then
                                    Found (Invalid_Task_Field, Id,
                                           Field (Field'First + 6 .. Field'Last)
                                           & " is not a field of " & Kind);
                                 elsif Field'Length > 6
                                   and then Field (Field'First .. Field'First + 5) = "field."
                                   and then Tasks.Field_Problem
                                              (Item, Field (Field'First + 6 .. Field'Last),
                                               Records.Get (Defined, Field)) /= ""
                                 then
                                    --  Its value, held to its schema as it
                                    --  stands now.
                                    Found (Invalid_Task_Field, Id,
                                           Field (Field'First + 6 .. Field'Last) & ": "
                                           & Tasks.Field_Problem
                                               (Item, Field (Field'First + 6 .. Field'Last),
                                                Records.Get (Defined, Field)));
                                 end if;
                              end;
                           end loop;
                        end;
                     end if;
                  end;
               end if;
            end;
         end loop;

         for Id of Tasks.Cycles (Item) loop
            Found (Cyclic_Dependency, Id,
                   "its dependencies or its parents come back to it");
         end loop;
      end;

      --  A task's component is one the project has, as tasks are held to:
      --  one it lists or places, or the project itself where it lists none.
      --  A file whose path happens to hold the name is no component.
      declare
         Listed   : Name_Lists.Vector;

         function Known (Component : String) return Boolean
         is (Listed.Contains (Component));
      begin
         --  The components as tasks take them: listed, or the project
         --  itself by its name.
         Listed := Tasks.Components (Item);

         --  Each component that is none, once, with the open tasks in it.
         declare
            Missing : Name_Lists.Vector;
         begin
            for Id of Tasks.List (Item) loop
               declare
                  Defined   : Records.Item;
                  Status    : E.Error_Info;
               begin
                  Tasks.Definition (Item, Id, Defined, Status);
                  if E.Is_Ok (Status)
                    and then Records.Get (Defined, "component") /= ""
                    and then Tasks.State_Of (Item, Id) not in "complete" | "cancelled" | "rejected"
                    and then not Known (Records.Get (Defined, "component"))
                    and then not Missing.Contains (Records.Get (Defined, "component"))
                  then
                     Missing.Append (Records.Get (Defined, "component"));
                  end if;
               end;
            end loop;
            for Component of Missing loop
               declare
                  Held : Unbounded_String;
               begin
                  for Id of Tasks.List (Item) loop
                     declare
                        Defined : Records.Item;
                        Status  : E.Error_Info;
                     begin
                        Tasks.Definition (Item, Id, Defined, Status);
                        if E.Is_Ok (Status) and then Records.Get (Defined, "component") = Component
                          and then Tasks.State_Of (Item, Id) not in "complete" | "cancelled" | "rejected"
                        then
                           Append (Held, (if Held = Null_Unbounded_String then "" else ", ") & Id);
                        end if;
                     end;
                  end loop;
                  Found (Missing_Component, Component,
                         "the component of " & To_String (Held) & ", which is neither listed nor"
                         & " found in the repository: task rehome " & Component
                         & " NAME places them in one that is");
               end;
            end loop;
         end;

         --  A task in another component than the requirement it serves is
         --  linked to.
         for Id of Tasks.List (Item) loop
            declare
               Defined : Records.Item;
               Status  : E.Error_Info;
            begin
               Tasks.Definition (Item, Id, Defined, Status);
               if E.Is_Ok (Status) and then Records.Get (Defined, "component") /= ""
                 and then Tasks.State_Of (Item, Id) not in "complete" | "cancelled" | "rejected"
               then
                  for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
                     declare
                        Linked : constant Name_Lists.Vector :=
                          Intent.Links (Item, Intent.Requirement, Requirement, Intent.Component);
                     begin
                        if not Linked.Is_Empty
                          and then not Linked.Contains (Records.Get (Defined, "component"))
                        then
                           Found (Missing_Component, Id,
                                  "it is in " & Records.Get (Defined, "component") & ", and "
                                  & Requirement & " it serves belongs to " & Linked.First_Element
                                  & ": task edit " & Id & " --set component="
                                  & Linked.First_Element & " places it there");
                        end if;
                     end;
                  end loop;
               end if;
            end;
         end loop;
      end;

      --  What the readiness index says is ready, with a dependency that is
      --  not complete.
      declare
         Cache  : Records.Item;
         Status : E.Error_Info;
      begin
         if Stores.Exists (Item, Indexes_Area, "readiness") then
            Stores.Read (Item, Indexes_Area, "readiness", Cache, Status);
            if E.Is_Ok (Status) then
               for Id of Tasks.List (Item) loop
                  if Records.Get (Cache, "task." & Id) = "ready" then
                     declare
                        Defined : Records.Item;
                        Read    : E.Error_Info;
                     begin
                        Tasks.Definition (Item, Id, Defined, Read);
                        for Other of Lines_Of (Records.Get (Defined, "depends_on")) loop
                           if Stores.Exists (Item, Tasks_Area, Other)
                             and then Tasks.State_Of (Item, Other) /= "complete"
                           then
                              Found (Ready_With_Open_Dependency, Id,
                                     "it is held ready while " & Other & " is "
                                     & Tasks.State_Of (Item, Other));
                           end if;
                        end loop;
                     end;
                  end if;
               end loop;
            end if;
         end if;
      end;

      --  Traceability to symbols the repository does not have, as far as
      --  a kept graph says.
      --  What a requirement is linked to is there: a symbol the repository
      --  declares, a file it holds, a component the project has.
      declare
         Graph : constant Repository.Graph := Repository.Now (Item);

         function Holds_File (Path : String) return Boolean is
         begin
            for Index in 1 .. Repository.File_Count (Graph) loop
               if Ada.Strings.Unbounded.To_String (Repository.File_At (Graph, Index).Path) = Path then
                  return True;
               end if;
            end loop;
            return False;
         end Holds_File;
      begin
         for Id of Intent.List (Item, Intent.Requirement) loop
            for Relation in Intent.Implementation .. Intent.Test loop
               if Intent."/=" (Relation, Intent.Task_Link) then
                  for Target of Intent.Links (Item, Intent.Requirement, Id, Relation) loop
                     if (if Ada.Strings.Fixed.Index (Target, "/") > 0 then not Holds_File (Target)
                         else Repository.Find_Symbols (Graph, Target).Is_Empty
                              and then not Holds_File (Target))
                     then
                        Found (Missing_Symbol, Id,
                               (if Intent."=" (Relation, Intent.Test) then "it is tested by "
                                else "it is implemented by ")
                               & Target & ", which the repository does not hold");
                     end if;
                  end loop;
               end if;
            end loop;
            for Target of Intent.Links (Item, Intent.Requirement, Id, Intent.Component) loop
               if not Tasks.Components (Item).Contains (Target) then
                  Found (Missing_Component, Id,
                         "it belongs to the component " & Target
                         & ", which is not one of the project's: reconfigure map.component."
                         & Target & "=roots=DIR makes it one, placed where its files are, or req"
                         & " unlink " & Id & " component " & Target
                         & " takes the link away");
               end if;
            end loop;
         end loop;
      end;

      --  Work still open for what is no longer wanted.
      for Id of Tasks.List (Item) loop
         if Tasks.State_Of (Item, Id) not in "complete" | "cancelled" | "rejected" then
            declare
               Defined : Records.Item;
               Read    : E.Error_Info;
            begin
               Tasks.Definition (Item, Id, Defined, Read);
               for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
                  declare
                     Held : Intent.Entity;
                     Got  : E.Error_Info;
                  begin
                     Intent.Read (Item, Intent.Requirement, Requirement, Held, Got);
                     if E.Is_Ok (Got)
                       and then Ada.Strings.Unbounded.To_String (Held.State)
                                in "obsolete" | "superseded" | "rejected"
                     then
                        Found (Undefined_Requirement, Id,
                               "it serves " & Requirement & ", which is "
                               & Ada.Strings.Unbounded.To_String (Held.State)
                               & (if Tasks.State_Of (Item, Id) = "candidate"
                                  then "; task reject " else "; task cancel ")
                               & Id & " lets it go");
                     end if;
                  end;
               end loop;
            end;
         end if;
      end loop;

      --  Verification that no longer applies, still counted.
      for Id of Intent.List (Item, Intent.Requirement, "verified") loop
         declare
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            Stores.Read (Item, Requirements_Area, Id, Value, Read);
            --  Judged as state and req judge it: by what supports it now,
            --  a later whole run standing for evidence it made stale.
            declare
               Why : constant String := Verification.Why_Not_Verified (Item, Id);
            begin
               if Why /= "" then
                  Found (Stale_Verification, Id, "its evidence no longer holds: " & Why);
               end if;
            end;
         end;
      end loop;

      --  A complete task whose gates did not hold: verification that
      --  failed or was never run where its kind is verified, or a child
      --  that is not done.
      for Id of Tasks.List (Item, "complete") loop
         declare
            Profile  : constant String := Verification.Profile_Of (Item, Id);
            Evidence : constant String :=
              (if Profile = "" then "" else Verification.Latest (Item, Id, Profile));
            Value    : Records.Item;
            Read     : E.Error_Info;
            Defined  : Records.Item;
            Got      : E.Error_Info;
            Config   : Records.Item;
         begin
            Configurations.Read (Item, Config, Got);
            Tasks.Definition (Item, Id, Defined, Got);
            declare
               Gates : constant Name_Lists.Vector :=
                 Tasks.Gate_Names (Item, Records.Get (Defined, "kind"));
            begin
               if Evidence /= "" then
                  Stores.Read (Item, Verification_Area, Evidence, Value, Read);
                  --  Failed since, and nothing that passed after it: a later
                  --  passing whole run answers for it.
                  if Records.Get (Value, "passed") /= "true"
                    and then not Verification.Passed_After (Item, Evidence)
                  then
                     Found (Completed_Without_Gate, Id,
                            "it is complete and " & Evidence & " did not pass");
                  end if;
               elsif Profile /= "" and then Gates.Contains ("verification") then
                  Found (Completed_Without_Gate, Id,
                         "it is complete and no evidence of " & Profile & " was ever taken");
               end if;
               if Gates.Contains ("children") then
                  for Child of Tasks.Children (Item, Id) loop
                     if Tasks.Holds_Parent (Item, Child, Tasks.State_Of (Item, Child)) then
                        Found (Completed_Without_Gate, Id,
                               "it is complete and its child " & Child & " is "
                               & Tasks.State_Of (Item, Child));
                     end if;
                  end loop;
               end if;

               --  Its other gates, as far as what they judge does not age:
               --  what it changed and where that went, judged as at
               --  completion; a project's own gate by whether its evidence
               --  passed, not whether it is still current.
               declare
                  Judged    : constant Verification.Gate_List := Verification.Gates (Item, Id);

                  --  What a person set aside completing it by hand holds as
                  --  they said.
                  Set_Aside : Name_Lists.Vector;
                  Its_State : Records.Item;
                  Got_State : E.Error_Info;
               begin
                  Stores.Read (Item, Tasks_Area, Id & ".state", Its_State, Got_State);
                  if E.Is_Ok (Got_State) then
                     Set_Aside := Lines_Of (Records.Get (Its_State, "set_aside"));
                  end if;
                  for Index in 1 .. Verification.Length (Judged) loop
                     declare
                        One  : constant Verification.Gate := Verification.Element (Judged, Index);
                        Name : constant String := To_String (One.Name);
                     begin
                        if not One.Passed
                          and then Name in "implementation_present" | "traceability_sufficient"
                                         | "integration" | "documentation_current"
                          and then not Set_Aside.Contains (Name)
                        then
                           Found (Completed_Without_Gate, Id,
                                  "it is complete and its gate " & Name & " does not hold: "
                                  & To_String (One.Reason));
                        end if;
                     end;
                  end loop;
               end;
               for Gate of Gates loop
                  declare
                     Profile : constant String :=
                       Records.Get (Config, "scalar.gate." & Gate);
                     Proof   : constant String :=
                       (if Profile = "" then "" else Verification.Latest (Item, Id, Profile));
                     Kept    : Records.Item;
                     Got     : E.Error_Info;
                  begin
                     if Profile /= "" then
                        if Proof = "" then
                           Found (Completed_Without_Gate, Id,
                                  "it is complete and its gate " & Gate & " was never checked");
                        else
                           Stores.Read (Item, Verification_Area, Proof, Kept, Got);
                           if Records.Get (Kept, "passed") /= "true" then
                              Found (Completed_Without_Gate, Id,
                                     "it is complete and its gate " & Gate & " did not pass ("
                                     & Proof & ")");
                           end if;
                        end if;
                     end if;
                  end;
               end loop;
            end;
         end;
      end loop;

      --  One active workspace a task, and none for a task not being worked.
      declare
         Owners : Name_Lists.Vector;
      begin
         for Name of Stores.Names (Item, Workspaces_Area) loop
            declare
               Held : Workspaces.Workspace;
               Read : E.Error_Info;
            begin
               Workspaces.Read (Item, Name, Held, Read);
               if E.Is_Ok (Read) and then To_String (Held.Status) = "active" then
                  if Owners.Contains (To_String (Held.Task_Id)) then
                     Found (Workspace_Assignment, Name,
                            To_String (Held.Task_Id) & " has more than one workspace");
                  end if;
                  Owners.Append (To_String (Held.Task_Id));
                  if Tasks.State_Of (Item, To_String (Held.Task_Id))
                       not in "running" | "verification"
                  then
                     Found (Workspace_Assignment, Name,
                            To_String (Held.Task_Id) & " is "
                            & Tasks.State_Of (Item, To_String (Held.Task_Id))
                            & " and still has a workspace");
                  end if;
               end if;
            end;
         end loop;
      end;

      --  A kind or role that says it may do more than the project allows
      --  is given what the project allows: clamped, as reconfigure says, and
      --  nothing that does not hold together.

      return Result;
   end Check;

   function Length (From : Finding_List) return Natural
   is (Natural (From.Findings.Length));

   function Element (From : Finding_List; Index : Positive) return Finding
   is (From.Findings (Index));

end Model_Runner.Framework.Consistency;
