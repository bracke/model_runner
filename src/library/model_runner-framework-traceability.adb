with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Tasks;

package body Model_Runner.Framework.Traceability is

   use Ada.Strings.Unbounded;
   use type Repository.Confidence;
   use type Repository.Relation_Kind;
   use type Repository.File_Role;
   use type Intent.Intent_Kind;

   package E renames Model_Runner.Errors;

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --  The less sure of two confidences.
   function Weaker (A, B : Repository.Confidence) return Repository.Confidence
   is (if A > B then A else B);

   procedure Link
     (Into      : in out Graph;
      From, To  : String;
      Kind      : String;
      Source    : Repository.Derivation;
      Sure      : Repository.Confidence;
      Record_Of : String := "") is
   begin
      Into.Edges.Append
        (Edge'(From      => To_Unbounded_String (From),
               To        => To_Unbounded_String (To),
               Kind      => To_Unbounded_String (Kind),
               Source    => Source,
               Sure      => Sure,
               Record_Of => To_Unbounded_String (Record_Of)));
   end Link;

   --  What an implementation or test link names, as a node.
   function Target_Node (Target : String) return String
   is (if Ada.Strings.Fixed.Index (Target, "/") > 0
          or else Ada.Strings.Fixed.Index (Target, ".ad") > 0
       then "file:" & Target
       else "symbol:" & Target);

   -----------
   -- Build --
   -----------

   function Build
     (Item  : Stores.Store;
      Files : Repository.Graph) return Graph
   is
      Result : Graph;

      procedure Component (Name : String) is
      begin
         if Name /= "" and then Name /= "project"
           and then not Result.Components.Contains (Name)
         then
            Result.Components.Append (Name);
         end if;
      end Component;
   begin
      --  The repository's own relations, as found.
      for Index in 1 .. Repository.Relation_Count (Files) loop
         declare
            Found : constant Repository.Relation := Repository.Relation_At (Files, Index);
            From  : constant String := To_String (Found.From);
            To    : constant String := To_String (Found.To);
         begin
            case Found.Kind is
               when Repository.Contains | Repository.Implements =>
                  Link (Result, "file:" & From, "unit:" & To,
                        Lower (Repository.Relation_Kind'Image (Found.Kind)),
                        Found.Source, Found.Sure);
               when Repository.Depends_On =>
                  Link (Result, "unit:" & From, "unit:" & To, "depends_on",
                        Found.Source, Found.Sure, To_String (Found.Where));
               when Repository.Declares =>
                  Link (Result, "unit:" & From, "symbol:" & To, "declares",
                        Found.Source, Found.Sure, To_String (Found.Where));
               when Repository.References =>
                  Link (Result, "file:" & From, "symbol:" & To, "references",
                        Found.Source, Found.Sure, To_String (Found.Where));
               when Repository.Calls =>
                  Link (Result, "unit:" & From, "symbol:" & To, "calls",
                        Found.Source, Found.Sure, To_String (Found.Where));
               when Repository.Instantiates | Repository.Extends
                  | Repository.Implements_Interface | Repository.Overrides =>
                  --  What is made from what: a change to the one reaches the
                  --  other, as a dependency does.
                  Link (Result, "symbol:" & From, "unit:" & To,
                        Lower (Repository.Relation_Kind'Image (Found.Kind)),
                        Found.Source, Found.Sure, To_String (Found.Where));
            end case;
         end;
      end loop;

      --  Requirements at their revisions.
      for Id of Intent.List (Item, Intent.Requirement) loop
         declare
            Held   : Intent.Entity;
            Status : E.Error_Info;
         begin
            Intent.Read (Item, Intent.Requirement, Id, Held, Status);
            if E.Is_Ok (Status) then
               declare
                  Node : constant String := Id & "@" & Image (Held.Revision);
                  Value : Records.Item;
               begin
                  Component (To_String (Held.Scope));
                  if To_String (Held.Scope) /= "project" then
                     Link (Result, Node, "component:" & To_String (Held.Scope), "scope",
                           Repository.Explicit, Repository.Certain, Id);
                  end if;
                  for Target of Intent.Links (Item, Intent.Requirement, Id,
                                              Intent.Implementation)
                  loop
                     Link (Result, Node, Target_Node (Target), "implemented_by",
                           Repository.Explicit, Repository.Certain, Id);
                  end loop;
                  for Target of Intent.Links (Item, Intent.Requirement, Id, Intent.Test)
                  loop
                     Link (Result, Node, Target_Node (Target), "tested_by",
                           Repository.Explicit, Repository.Certain, Id);
                  end loop;
                  Stores.Read (Item, Requirements_Area, Id, Value, Status);
                  for Evidence of Lines_Of
                    (Ada.Strings.Fixed.Translate
                       (Records.Get (Value, "verified_by"),
                        Ada.Strings.Maps.To_Mapping (",", [1 => ASCII.LF])))
                  loop
                     Link (Result, Node, Ada.Strings.Fixed.Trim (Evidence, Ada.Strings.Both),
                           "verified_by", Repository.Explicit, Repository.Certain, Id);
                  end loop;
               end;
            end if;
         end;
      end loop;

      --  Tasks: what they serve, where they belong, what their work
      --  changed, what verified them.
      for Id of Tasks.List (Item) loop
         declare
            Defined : Records.Item;
            State   : Records.Item;
            Status  : E.Error_Info;
         begin
            Tasks.Definition (Item, Id, Defined, Status);
            if E.Is_Ok (Status) then
               for Requirement of Lines_Of (Records.Get (Defined, "requirements")) loop
                  declare
                     Held : Intent.Entity;
                  begin
                     Intent.Read (Item, Intent.Requirement, Requirement, Held, Status);
                     Link (Result, Requirement & "@" & Image (Held.Revision), Id, "served_by",
                           Repository.Explicit, Repository.Certain, Id);
                  end;
               end loop;
               if Records.Get (Defined, "component") /= "" then
                  Component (Records.Get (Defined, "component"));
                  Link (Result, Id, "component:" & Records.Get (Defined, "component"),
                        "part_of", Repository.Explicit, Repository.Certain, Id);
               end if;
            end if;
            Stores.Read (Item, Tasks_Area, Id & ".state", State, Status);
            if E.Is_Ok (Status) then
               for Path of Lines_Of (Records.Get (State, "changed_files")) loop
                  Link (Result, Id, "file:" & Path, "changed",
                        Repository.Explicit, Repository.Certain, Id & ".state");
               end loop;
            end if;
         end;
      end loop;

      for Name of Stores.Names (Item, Verification_Area) loop
         declare
            Value  : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Verification_Area, Name, Value, Status);
            if E.Is_Ok (Status) and then Records.Get (Value, "task") /= "" then
               Link (Result, Records.Get (Value, "task"), Name, "verified_by",
                     Repository.Explicit, Repository.Certain, Name);
            end if;
         end;
      end loop;

      --  Decisions and specifications, to their components.
      for Kind in Intent.Specification .. Intent.Decision loop
         if Kind /= Intent.Requirement then
            for Id of Intent.List (Item, Kind, "accepted") loop
               declare
                  Held   : Intent.Entity;
                  Status : E.Error_Info;
               begin
                  Intent.Read (Item, Kind, Id, Held, Status);
                  Component (To_String (Held.Scope));
                  Link (Result, Id & "@" & Image (Held.Revision),
                        (if To_String (Held.Scope) = "project" then "project"
                         else "component:" & To_String (Held.Scope)),
                        "applies_to", Repository.Explicit, Repository.Certain, Id);
               end;
            end loop;
         end if;
      end loop;

      --  Files named after a component belong to it, probably.
      for Index in 1 .. Repository.File_Count (Files) loop
         declare
            File : constant Repository.File_Entry := Repository.File_At (Files, Index);
            Path : constant String := Lower (To_String (File.Path));
         begin
            for Name of Result.Components loop
               if Ada.Strings.Fixed.Index (Path, Lower (Name)) > 0 then
                  Link (Result, "component:" & Name, "file:" & To_String (File.Path),
                        "names", Repository.Naming_Convention, Repository.Probable);
               end if;
            end loop;
            if File.Role = Repository.Test then
               Link (Result, "file:" & To_String (File.Path), "tests", "is_test",
                     Repository.Naming_Convention, Repository.Probable);
            end if;
         end;
      end loop;
      return Result;
   end Build;

   function Edge_Count (From : Graph) return Natural
   is (Natural (From.Edges.Length));

   function Edge_At (From : Graph; Index : Positive) return Edge
   is (From.Edges (Index));

   --------------
   -- Touching --
   --------------

   function Touching (From : Graph; Node : String) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Index in 1 .. Natural (From.Edges.Length) loop
         if To_String (From.Edges (Index).From) = Node
           or else To_String (From.Edges (Index).To) = Node
         then
            Result.Append (Image (Index));
         end if;
      end loop;
      return Result;
   end Touching;

   ---------------
   -- Impact_Of --
   ---------------

   function Impact_Of (From : Graph; Changed : Name_Lists.Vector) return Impact is
      Result : Impact;

      --  Each node reached, and how surely, as a node name to confidence.
      type Mark is record
         Node : Unbounded_String;
         Sure : Repository.Confidence;
      end record;
      package Mark_Vectors is new Ada.Containers.Vectors (Positive, Mark);
      Seen : Mark_Vectors.Vector;

      function Place (Node : String) return Natural is
      begin
         for Index in 1 .. Natural (Seen.Length) loop
            if To_String (Seen (Index).Node) = Node then
               return Index;
            end if;
         end loop;
         return 0;
      end Place;

      --  Reach a node; true when this is new or surer than before.
      function Reach (Node : String; Sure : Repository.Confidence) return Boolean is
         Held : constant Natural := Place (Node);
      begin
         if Held = 0 then
            Seen.Append (Mark'(To_Unbounded_String (Node), Sure));
            return True;
         elsif Sure < Seen (Held).Sure then
            Seen (Held).Sure := Sure;
            return True;
         end if;
         return False;
      end Reach;

      --  Which way impact flows along an edge of a kind: forward from a
      --  file to its units and a unit to its symbols; backward from a unit
      --  to what depends on it, from a symbol to what refers to it, from a
      --  file to the tasks that changed it and the components it belongs
      --  to, and from anything to the requirements and specifications that
      --  reach it.
      function Forward (Kind : String) return Boolean
      is (Kind in "contains" | "implements" | "declares");

      --  A file and its units reach each other either way: a changed spec
      --  reaches its body, and a dependent unit reaches its files, tests
      --  among them.
      function Both_Ways (Kind : String) return Boolean
      is (Kind in "contains" | "implements");

      Queue : Name_Lists.Vector;
   begin
      for Path of Changed loop
         if Reach ("file:" & Path, Repository.Certain) then
            Queue.Append ("file:" & Path);
         end if;
      end loop;

      while not Queue.Is_Empty loop
         declare
            Node : constant String := Queue.First_Element;
            Sure : constant Repository.Confidence := Seen (Place (Node)).Sure;
         begin
            Queue.Delete_First;
            for Next of From.Edges loop
               declare
                  Kind : constant String := To_String (Next.Kind);
                  Along : constant Repository.Confidence := Weaker (Sure, Next.Sure);
               begin
                  if Forward (Kind) and then To_String (Next.From) = Node then
                     if Reach (To_String (Next.To), Along) then
                        Queue.Append (To_String (Next.To));
                     end if;
                  elsif (not Forward (Kind) or else Both_Ways (Kind))
                    and then Kind /= "is_test"
                    and then To_String (Next.To) = Node
                  then
                     if Reach (To_String (Next.From), Along) then
                        Queue.Append (To_String (Next.From));
                     end if;
                  end if;
               end;
            end loop;
         end;
      end loop;

      --  What was reached, by kind; and what reached nothing.
      for Held of Seen loop
         declare
            Node : constant String := To_String (Held.Node);

            function Kind_Of return String is
            begin
               if Node'Length > 5 and then Node (Node'First .. Node'First + 4) = "file:" then
                  declare
                     Is_Test : Boolean := False;
                  begin
                     for Next of From.Edges loop
                        Is_Test := Is_Test
                          or else (To_String (Next.From) = Node
                                   and then To_String (Next.Kind) = "is_test");
                     end loop;
                     return (if Is_Test then "test" else "file");
                  end;
               elsif Node'Length > 5 and then Node (Node'First .. Node'First + 4) = "unit:" then
                  return "unit";
               elsif Node'Length > 7 and then Node (Node'First .. Node'First + 6) = "symbol:" then
                  return "symbol";
               elsif Node'Length > 10
                 and then Node (Node'First .. Node'First + 9) = "component:"
               then
                  return "component";
               elsif Ada.Strings.Fixed.Index (Node, "REQ-") = Node'First then
                  return "requirement";
               elsif Ada.Strings.Fixed.Index (Node, "TASK-") = Node'First then
                  return "task";
               elsif Ada.Strings.Fixed.Index (Node, "SPEC-") = Node'First then
                  return "specification";
               elsif Ada.Strings.Fixed.Index (Node, "DEC-") = Node'First then
                  return "decision";
               end if;
               return "other";
            end Kind_Of;
         begin
            Result.Items.Append
              (Reached'(Kind => To_Unbounded_String (Kind_Of),
                        Id   => Held.Node,
                        Sure => Held.Sure));
         end;
      end loop;

      for Path of Changed loop
         declare
            Reaches_Anything : Boolean := False;
         begin
            for Next of From.Edges loop
               Reaches_Anything := Reaches_Anything
                 or else ((To_String (Next.From) = "file:" & Path
                           or else To_String (Next.To) = "file:" & Path)
                          and then To_String (Next.Kind) /= "is_test");
            end loop;
            if not Reaches_Anything then
               Result.Unknown.Append (Path);
            end if;
         end;
      end loop;
      return Result;
   end Impact_Of;

   function Length (From : Impact) return Natural
   is (Natural (From.Items.Length));

   function Element (From : Impact; Index : Positive) return Reached
   is (From.Items (Index));

   ------------------
   -- Select_Tests --
   ------------------

   function Select_Tests (Item : Stores.Store; From : Impact) return Selection is
      Config  : Records.Item;
      Status  : E.Error_Info;
      Result  : Selection;
      Narrow  : Boolean;
      Doubt   : Boolean := False;
      Partial : Boolean := False;
   begin
      Configurations.Read (Item, Config, Status);
      Narrow := Records.Get (Config, "scalar.verification.escalation") = "narrow";

      for Next of From.Items loop
         if To_String (Next.Kind) = "test" then
            Result.Tests.Append (Ada.Strings.Fixed.Tail
                                   (To_String (Next.Id), Length (Next.Id) - 5));
            if Next.Sure /= Repository.Certain then
               Partial := True;
            end if;
         end if;
         if Next.Sure = Repository.Uncertain then
            Doubt := True;
         end if;
      end loop;

      if Narrow then
         Result.Width := Certain_Tests;
         Result.Reason := To_Unbounded_String ("the policy tests only what is affected");
      elsif not From.Unknown.Is_Empty then
         Result.Width := Full_Suite;
         Result.Reason := To_Unbounded_String
           ("nothing is known of what " & From.Unknown.First_Element & " affects");
      elsif Doubt then
         Result.Width := Full_Suite;
         Result.Reason := To_Unbounded_String ("some of what the change reaches is uncertain");
      elsif Result.Tests.Is_Empty then
         Result.Width := Full_Suite;
         Result.Reason := To_Unbounded_String ("no test is known to cover the change");
      elsif Partial then
         Result.Width := Component_Tests;
         Result.Reason := To_Unbounded_String
           ("some tests are only probably affected, so the component's run");
      else
         Result.Width := Certain_Tests;
         Result.Reason := To_Unbounded_String ("every affected test is certainly so");
      end if;
      return Result;
   end Select_Tests;

end Model_Runner.Framework.Traceability;
