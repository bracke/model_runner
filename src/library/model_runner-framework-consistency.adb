with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

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
                      "it depends on " & Target & ", which is not there");
            end if;
         end loop;
      end loop;

      --  Statements that disagree with what governs their subject, and do
      --  not say they override it.
      declare
         use type Authority.Relation;
         Resolved : constant Authority.Resolution :=
           Authority.Resolve (Authority.Gather (Item));
      begin
         for Index in 1 .. Authority.Length (Resolved) loop
            declare
               Standing : constant Authority.Standing_Of :=
                 Authority.Element (Resolved, Index);
            begin
               if Standing.Relation = Authority.Conflict then
                  Found (Conflicting_Authority,
                         To_String (Standing.Governing.Subject),
                         To_String (Standing.Governing.Source) & " says "
                         & To_String (Standing.Governing.Value) & " and "
                         & To_String (Standing.Other.Source) & " says "
                         & To_String (Standing.Other.Value));
               end if;
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

      --  Traceability to symbols the repository does not have, as far as
      --  a kept graph says.
      declare
         Graph : Repository.Graph;
         Read  : E.Error_Info;
      begin
         Repository.Load (Item, Graph, Read);
         if E.Is_Ok (Read) then
            for Id of Intent.List (Item, Intent.Requirement) loop
               for Target of Intent.Links (Item, Intent.Requirement, Id,
                                           Intent.Implementation)
               loop
                  if Ada.Strings.Fixed.Index (Target, "/") = 0
                    and then Repository.Find_Symbols (Graph, Target).Is_Empty
                  then
                     Found (Missing_Symbol, Id,
                            "it is implemented by " & Target
                            & ", which the repository does not declare");
                  end if;
               end loop;
            end loop;
         end if;
      end;

      --  Verification that no longer applies, still counted.
      for Id of Intent.List (Item, Intent.Requirement, "verified") loop
         declare
            Value : Records.Item;
            Read  : E.Error_Info;
         begin
            Stores.Read (Item, Requirements_Area, Id, Value, Read);
            for Evidence of Lines_Of
              (Ada.Strings.Fixed.Translate
                 (Records.Get (Value, "verified_by"),
                  Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
            loop
               declare
                  Reasons : Name_Lists.Vector;
                  Named   : constant String :=
                    Ada.Strings.Fixed.Trim (Evidence, Ada.Strings.Both);
               begin
                  if not Verification.Is_Current (Item, Named, Reasons) then
                     Found (Stale_Verification, Id,
                            Named & " no longer applies: " & Reasons.First_Element);
                  end if;
               end;
            end loop;
         end;
      end loop;

      --  A complete task whose verification failed.
      for Id of Tasks.List (Item, "complete") loop
         declare
            Profile  : constant String := Verification.Profile_Of (Item, Id);
            Evidence : constant String :=
              (if Profile = "" then "" else Verification.Latest (Item, Id, Profile));
            Value    : Records.Item;
            Read     : E.Error_Info;
         begin
            if Evidence /= "" then
               Stores.Read (Item, Verification_Area, Evidence, Value, Read);
               if Records.Get (Value, "passed") /= "true" then
                  Found (Completed_Without_Gate, Id,
                         "it is complete and " & Evidence & " did not pass");
               end if;
            end if;
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

      return Result;
   end Check;

   function Length (From : Finding_List) return Natural
   is (Natural (From.Findings.Length));

   function Element (From : Finding_List; Index : Positive) return Finding
   is (From.Findings (Index));

end Model_Runner.Framework.Consistency;
