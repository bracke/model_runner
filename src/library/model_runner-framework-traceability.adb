with Ada.Characters.Handling;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Strings.Hash;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Identifiers;
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
               Record_Of => To_Unbounded_String (Record_Of),
               Created_At => Null_Unbounded_String));
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

      --  Whether the repository holds a file or declares a symbol by that
      --  name.
      function Held_By_Repository (Target : String) return Boolean is
      begin
         for Index in 1 .. Repository.File_Count (Files) loop
            if To_String (Repository.File_At (Files, Index).Path) = Target then
               return True;
            end if;
         end loop;
         return not Repository.Find_Symbols (Files, Target).Is_Empty;
      end Held_By_Repository;

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
                  --  The document it was read from says it: a change there
                  --  reaches it.
                  if To_String (Held.Source) not in "" | "user"
                    and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                  then
                     Link (Result, "file:" & To_String (Held.Source), Node, "sources",
                           Repository.Explicit, Repository.Certain, Id);
                  end if;
                  --  One the repository does not hold is linked all the same,
                  --  and said to be missing: not a certainty.
                  for Target of Intent.Links (Item, Intent.Requirement, Id,
                                              Intent.Implementation)
                  loop
                     if Held_By_Repository (Target) then
                        Link (Result, Node, Target_Node (Target), "implemented_by",
                              Repository.Explicit, Repository.Certain, Id);
                     else
                        Link (Result, Node, Target_Node (Target), "implemented_by, missing",
                              Repository.Explicit, Repository.Uncertain, Id);
                     end if;
                  end loop;

                  --  What it rests on, and the component it is linked to.
                  for Target of Intent.Links (Item, Intent.Requirement, Id, Intent.Dependency) loop
                     declare
                        Other : Intent.Entity;
                        Read  : E.Error_Info;
                     begin
                        Intent.Read (Item, Intent.Requirement, Target, Other, Read);
                        --  One the project does not hold is said missing.
                        if E.Is_Ok (Read) then
                           Link (Result, Node, Target & "@" & Image (Other.Revision),
                                 "depends_on", Repository.Explicit, Repository.Certain, Id);
                        else
                           Link (Result, Node, Target, "depends_on, missing",
                                 Repository.Explicit, Repository.Uncertain, Id);
                        end if;
                     end;
                  end loop;
                  --  A task linked to it by hand serves it as one naming it
                  --  does.
                  for Target of Intent.Links (Item, Intent.Requirement, Id, Intent.Task_Link) loop
                     Link (Result, Node, Target, "served_by",
                           Repository.Explicit, Repository.Certain, Id);
                  end loop;
                  for Target of Intent.Links (Item, Intent.Requirement, Id, Intent.Component) loop
                     Component (Target);
                     Link (Result, Node, "component:" & Target, "belongs_to",
                           Repository.Explicit, Repository.Certain, Id);
                  end loop;
                  --  A test the repository does not hold tests nothing:
                  --  linked, it is a mistake consistency names, not a test
                  --  a change is certainly covered by.
                  for Target of Intent.Links (Item, Intent.Requirement, Id, Intent.Test)
                  loop
                     if Held_By_Repository (Target) then
                        Link (Result, Node, Target_Node (Target), "tested_by",
                              Repository.Explicit, Repository.Certain, Id);
                     else
                        Link (Result, Node, Target_Node (Target), "tested_by, missing",
                              Repository.Explicit, Repository.Uncertain, Id);
                     end if;
                  end loop;
                  --  Evidence linked by hand, the missing said so.
                  for Target of Intent.Links (Item, Intent.Requirement, Id, Intent.Verification) loop
                     if Stores.Exists (Item, Verification_Area, Target) then
                        Link (Result, Node, Target, "verified_by",
                              Repository.Explicit, Repository.Certain, Id);
                     else
                        Link (Result, Node, Target, "verified_by, missing",
                              Repository.Explicit, Repository.Uncertain, Id);
                     end if;
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

            --  The document each came from, whatever it is: candidates are
            --  what a change to it reaches too.
            for Id of Intent.List (Item, Kind) loop
               declare
                  Held   : Intent.Entity;
                  Status : E.Error_Info;
               begin
                  Intent.Read (Item, Kind, Id, Held, Status);
                  if E.Is_Ok (Status) and then To_String (Held.Source) not in "" | "user"
                    and then To_String (Held.State) not in "rejected" | "obsolete" | "superseded"
                  then
                     Link (Result, "file:" & To_String (Held.Source),
                           Id & "@" & Image (Held.Revision),
                           "sources", Repository.Explicit, Repository.Certain, Id);
                  end if;
               end;
            end loop;
         end if;
      end loop;

      --  Every component the project has, linked or not: its files are its
      --  own whatever else names it.
      for Name of Tasks.Components (Item) loop
         Component (Name);
      end loop;

      --  Files named after a component belong to it, probably.
      for Index in 1 .. Repository.File_Count (Files) loop
         declare
            File : constant Repository.File_Entry := Repository.File_At (Files, Index);
            Path : constant String := Lower (To_String (File.Path));
         begin
            for Name of Result.Components loop
               --  A component that says where its files are is certain of
               --  them; one that does not, only probably by their names.
               if not Repository.Component_Roots (Item, Name).Is_Empty then
                  if Repository.In_Component (Item, Name, To_String (File.Path)) then
                     Link (Result, "component:" & Name, "file:" & To_String (File.Path),
                           "names", Repository.Explicit, Repository.Certain);
                  end if;
               elsif Ada.Strings.Fixed.Index (Path, Lower (Name)) > 0 then
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

      --  Every edge worked out now.
      declare
         Now : constant Unbounded_String := To_Unbounded_String (Timestamp);
      begin
         for One of Result.Edges loop
            One.Created_At := Now;
         end loop;
      end;
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

      --  A node as a person names it: the node itself, a requirement or
      --  another entity by its identifier at any revision (REQ-X for
      --  REQ-X@3), a file by its path (src/a.adb for file:src/a.adb), or a
      --  symbol by its name.
      function Names (Held : String) return Boolean
      is (Held = Node
          or else Held = "file:" & Node
          or else Held = "symbol:" & Node
          or else Held = "unit:" & Node
          or else (Held'Length > Node'Length
                   and then Held (Held'First .. Held'First + Node'Length) = Node & "@"));
   begin
      for Index in 1 .. Natural (From.Edges.Length) loop
         if Names (To_String (From.Edges (Index).From))
           or else Names (To_String (From.Edges (Index).To))
         then
            Result.Append (Image (Index));
         end if;
      end loop;
      return Result;
   end Touching;

   ---------------
   -- Impact_Of --
   ---------------

   --  The node a change starts from: a file by its path, or a symbol or a
   --  unit named as its node.
   --  A changed thing as a node: a symbol, unit or component as it is
   --  named, an entity of the project's state by its identifier, anything
   --  else a file.
   function Seed_Of (Changed : String) return String is
      function Starts (Prefix : String) return Boolean
      is (Changed'Length > Prefix'Length
          and then Changed (Changed'First .. Changed'First + Prefix'Length - 1) = Prefix);
   begin
      return (if Starts ("symbol:") or else Starts ("unit:") or else Starts ("component:")
                or else ((Starts ("REQ-") or else Starts ("TASK-") or else Starts ("SPEC-")
                          or else Starts ("DEC-"))
                         and then Identifiers.Is_Valid
                                    (if Ada.Strings.Fixed.Index (Changed, "@") > 0
                                     then Changed (Changed'First
                                                   .. Ada.Strings.Fixed.Index (Changed, "@") - 1)
                                     else Changed))
              then Changed else "file:" & Changed);
   end Seed_Of;

   function Impact_Of (From : Graph; Changed : Name_Lists.Vector) return Impact is
      Result : Impact;

      --  Each node reached, and how surely, as a node name to confidence.
      type Mark is record
         Node : Unbounded_String;
         Sure : Repository.Confidence;
      end record;
      package Mark_Vectors is new Ada.Containers.Vectors (Positive, Mark);
      Seen : Mark_Vectors.Vector;

      --  Where each node reached is in Seen, and the edges from and to each
      --  node, found once: a large project's graph holds a hundred thousand
      --  edges, and walking them all for every node reached took seconds.
      package Places is new Ada.Containers.Indefinite_Hashed_Maps
        (String, Positive, Ada.Strings.Hash, "=");
      package Edge_Lists is new Ada.Containers.Vectors (Positive, Positive);
      package Edge_Lists_Sorting is new Edge_Lists.Generic_Sorting;
      package Edge_Index is new Ada.Containers.Indefinite_Hashed_Maps
        (String, Edge_Lists.Vector, Ada.Strings.Hash, "=", Edge_Lists."=");
      Where : Places.Map;
      Out_Of : Edge_Index.Map;
      Into   : Edge_Index.Map;
      Tests  : Places.Map;

      function Place (Node : String) return Natural is
         Found : constant Places.Cursor := Where.Find (Node);
      begin
         return (if Places.Has_Element (Found) then Places.Element (Found) else 0);
      end Place;

      procedure Index_Edges is
         procedure Add (Into_Map : in out Edge_Index.Map; Key : String; At_Edge : Positive) is
            Found : constant Edge_Index.Cursor := Into_Map.Find (Key);
         begin
            if Edge_Index.Has_Element (Found) then
               Into_Map.Reference (Found).Append (At_Edge);
            else
               Into_Map.Insert (Key, Edge_Lists.To_Vector (At_Edge, 1));
            end if;
         end Add;
      begin
         for At_Edge in 1 .. Natural (From.Edges.Length) loop
            declare
               One : constant Edge := From.Edges (At_Edge);
            begin
               Add (Out_Of, To_String (One.From), At_Edge);
               Add (Into, To_String (One.To), At_Edge);
               --  A test by its place, or by a requirement naming it one.
               if To_String (One.Kind) = "is_test" then
                  Tests.Include (To_String (One.From), 1);
               elsif To_String (One.Kind) = "tested_by" then
                  Tests.Include (To_String (One.To), 1);
               end if;
            end;
         end loop;
      end Index_Edges;

      --  Reach a node; true when this is new or surer than before.
      function Reach (Node : String; Sure : Repository.Confidence) return Boolean is
         Held : constant Natural := Place (Node);
      begin
         if Held = 0 then
            Seen.Append (Mark'(To_Unbounded_String (Node), Sure));
            Where.Insert (Node, Natural (Seen.Length));
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
      --  reach it; and forward from a requirement to the tests it names,
      --  which are its explicitly and before any a dependency finds.
      function Forward (Kind : String) return Boolean
      is (Kind in "contains" | "implements" | "declares" | "tested_by" | "served_by" | "sources");

      --  A file and its units reach each other either way: a changed spec
      --  reaches its body, and a dependent unit reaches its files, tests
      --  among them.
      function Both_Ways (Kind : String) return Boolean
      is (Kind in "contains" | "implements" | "served_by");

      Queue  : Name_Lists.Vector;
      Seeds  : Name_Lists.Vector;
      Served : Name_Lists.Vector;
   begin
      Index_Edges;
      for Path of Changed loop
         Seeds.Append (Seed_Of (Path));
         if Reach (Seed_Of (Path), Repository.Certain) then
            Queue.Append (Seed_Of (Path));
         end if;
      end loop;

      while not Queue.Is_Empty loop
         declare
            Node : constant String := Queue.First_Element;
            Sure : constant Repository.Confidence := Seen (Place (Node)).Sure;
         begin
            Queue.Delete_First;
            --  Only the edges that touch it: those from it, then those into
            --  it -- each once, where it both starts and ends one.
            declare
               Touching : Edge_Lists.Vector;
               Found    : Edge_Index.Cursor := Out_Of.Find (Node);
            begin
               if Edge_Index.Has_Element (Found) then
                  Touching := Edge_Index.Element (Found);
               end if;
               Found := Into.Find (Node);
               if Edge_Index.Has_Element (Found) then
                  for At_Edge of Edge_Index.Element (Found) loop
                     if To_String (From.Edges (At_Edge).From) /= Node then
                        Touching.Append (At_Edge);
                     end if;
                  end loop;
               end if;
               Edge_Lists_Sorting.Sort (Touching);
               for At_Edge of Touching loop
                  declare
                     Next : constant Edge := From.Edges (At_Edge);
                     Kind : constant String := To_String (Next.Kind);

                     --  Reached only through sharing a component is not
                     --  reached surely: the component is wider than the change.
                     Along : constant Repository.Confidence :=
                       (if Kind in "scope" | "belongs_to" | "part_of"
                        then Weaker (Weaker (Sure, Next.Sure), Repository.Probable)
                        else Weaker (Sure, Next.Sure));
                  begin
                     --  A unit only probably reached -- one that uses what
                     --  changed -- is reached itself, not every symbol beside
                     --  the use: those are reached through what they use.
                     if Kind = "declares" and then To_String (Next.From) = Node
                       and then not Repository."=" (Sure, Repository.Certain)
                     then
                        null;
                     elsif Forward (Kind) and then To_String (Next.From) = Node then
                        if Reach (To_String (Next.To), Along) then
                           Queue.Append (To_String (Next.To));
                        end if;

                     --  A requirement changed reaches what it is carried out
                     --  in: its implementation, the tasks serving it, and its
                     --  component -- as surely as its links say -- and the
                     --  components those tasks are in.
                     elsif ((Seeds.Contains (Node)
                             and then Kind in "implemented_by" | "scope" | "belongs_to" | "served_by")
                            or else (Served.Contains (Node) and then Kind = "part_of"))
                       and then To_String (Next.From) = Node
                     then
                        if Kind = "served_by" then
                           Served.Append (To_String (Next.To));
                        end if;
                        if Reach (To_String (Next.To), Weaker (Sure, Next.Sure)) then
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
         end;
      end loop;

      --  What was reached, by kind; and what reached nothing.
      for Held of Seen loop
         declare
            Node : constant String := To_String (Held.Node);

            function Kind_Of return String is
            begin
               --  A test by its place, or by a requirement naming it one.
               if Tests.Contains (Node) then
                  return "test";
               end if;
               if Node'Length > 5 and then Node (Node'First .. Node'First + 4) = "file:" then
                  return "file";
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
                 or else ((To_String (Next.From) = Seed_Of (Path)
                           or else To_String (Next.To) = Seed_Of (Path))
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
            --  file:PATH or symbol:NAME, as the test is known.
            declare
               Id    : constant String := To_String (Next.Id);
               Colon : constant Natural := Ada.Strings.Fixed.Index (Id, ":");
            begin
               Result.Tests.Append (Id (Colon + 1 .. Id'Last));
            end;
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
      elsif Partial and then Records.Get (Config, "set.components") = "" then
         Result.Width := Full_Suite;
         Result.Reason := To_Unbounded_String
           ("some tests are only probably affected, and the project names no components, so the whole"
            & " suite runs");
      elsif Partial then
         Result.Width := Component_Tests;
         declare
            Named : Unbounded_String;
         begin
            for Next of From.Items loop
               if To_String (Next.Kind) = "component" then
                  Append (Named, (if Named = Null_Unbounded_String then "" else ", ")
                          & Slice (Next.Id, Ada.Strings.Fixed.Index (To_String (Next.Id), ":") + 1,
                                   Length (Next.Id)));
               end if;
            end loop;
            Result.Reason := To_Unbounded_String
              ("some tests are only probably affected, so the tests of "
               & (if Named = Null_Unbounded_String then "the components it reaches"
                  else "its component " & To_String (Named))
               & " run");
         end;
      else
         Result.Width := Certain_Tests;
         Result.Reason := To_Unbounded_String ("every affected test is certainly so");
      end if;
      return Result;
   end Select_Tests;

end Model_Runner.Framework.Traceability;
