with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Strings.Fixed;

with Hostkit.Fs;

with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Facts;
with Model_Runner.Framework.Files;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Repository;
with Model_Runner.Framework.Results;
with Model_Runner.Framework.Schemas;
with Model_Runner.Framework.Tasks;
with Model_Runner.Framework.Verification;

package body Model_Runner.Framework.Context is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   --  What every context starts with: how the harness expects to be
   --  answered, whatever the project.
   Harness_Rules : constant String :=
     "You are doing one task in a project. Change the project's files as"
     & " the task needs, and nothing outside the task. The harness keeps"
     & " the project's records -- tasks, requirements, verification -- and"
     & " decides from your answer and its own checks what happens next, so"
     & " say plainly what you did. If you find more work than the task"
     & " holds, say so as the instructions below ask, rather than doing it.";

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   type Name_Text is access constant String;

   --  The task's fields that say what it is.
   Wanted_Fields : constant array (1 .. 6) of Name_Text :=
     [new String'("title"), new String'("kind"), new String'("component"),
      new String'("requirements"), new String'("depends_on"), new String'("notes")];

   function Image (Value : Natural) return String
   is (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   --------------
   -- Estimate --
   --------------

   function Estimate (Text : String) return Natural
   is ((Text'Length + 3) / 4);

   -------------
   -- Profile --
   -------------

   function Profile (Item : Stores.Store; Id : String) return Model_Profile is
      Config : Records.Item;
      Status : E.Error_Info;
      Result : Model_Profile :=
        (Id             => To_Unbounded_String (if Id = "" then "default" else Id),
         Provider       => To_Unbounded_String ("local"),
         Resource_Class => To_Unbounded_String ("local"),
         others         => <>);
   begin
      Configurations.Read (Item, Config, Status);
      if E.Is_Error (Status) then
         return Result;
      end if;

      declare
         Chosen : constant String :=
           (if Id /= "" then Id
            elsif Records.Get (Config, "scalar.model.default") /= ""
            then Records.Get (Config, "scalar.model.default")
            else "default");
         Spec   : constant String := Records.Get (Config, "map.model." & Chosen);
         Start  : Natural := Spec'First;
      begin
         Result.Id := To_Unbounded_String (Chosen);
         for Index in Spec'First .. Spec'Last + 1 loop
            if Index > Spec'Last or else Spec (Index) = ',' then
               declare
                  Pair  : constant String :=
                    Ada.Strings.Fixed.Trim (Spec (Start .. Index - 1), Ada.Strings.Both);
                  Equal : constant Natural := Ada.Strings.Fixed.Index (Pair, "=");
               begin
                  if Equal > Pair'First then
                     declare
                        Key   : constant String := Lower (Pair (Pair'First .. Equal - 1));
                        Value : constant String := Pair (Equal + 1 .. Pair'Last);
                        Yes   : constant Boolean := Lower (Value) in "yes" | "true";
                        Count : Natural := 0;
                     begin
                        if Value'Length in 1 .. 9
                          and then (for all Char of Value => Char in '0' .. '9')
                        then
                           Count := Natural'Value (Value);
                        end if;
                        if Key = "context" and then Count > 0 then
                           Result.Context_Limit := Count;
                        elsif Key = "reserve" then
                           Result.Output_Reserve := Count;
                        elsif Key = "overhead" then
                           Result.Tool_Overhead := Count;
                        elsif Key = "tools" then
                           Result.Tools := Yes;
                        elsif Key = "structured" then
                           Result.Structured := Yes;
                        elsif Key = "reasoning" then
                           Result.Reasoning := Yes;
                        elsif Key = "streaming" then
                           Result.Streaming := Yes;
                        elsif Key = "parallel" then
                           Result.Parallel_Calls := Yes;
                        elsif Key = "class" then
                           Result.Resource_Class := To_Unbounded_String (Value);
                        elsif Key = "provider" then
                           Result.Provider := To_Unbounded_String (Value);
                        end if;
                     end;
                  end if;
               end;
               Start := Index + 1;
            end if;
         end loop;
      end;
      return Result;
   end Profile;

   --  Fit what is offered to the model's room -- mandatory whatever it
   --  costs, the rest by priority while it fits, the same text once -- and
   --  take the fingerprint of everything the manifest says.
   procedure Settle
     (Candidates : Item_Vectors.Vector;
      Task_Id    : String;
      Result     : in out Built;
      Status     : in out Model_Runner.Errors.Error_Info) is
   begin
      --  Budget: mandatory whatever it costs, the rest by priority while
      --  it fits, the same text once.
      Result.Budget :=
        Natural'Max (0, Result.Model.Context_Limit - Result.Model.Output_Reserve
                        - Result.Model.Tool_Overhead);
      declare
         Seen      : Name_Lists.Vector;
         Seen_From : Name_Lists.Vector;
         Chosen    : array (1 .. Natural (Candidates.Length)) of Boolean :=
           [others => False];
      begin
         for Rank in Priority loop
            for Index in 1 .. Natural (Candidates.Length) loop
               declare
                  Next  : Context.Item renames Candidates (Index);
                  Print : constant String := Fingerprint (To_String (Next.Text));
                  Cost  : constant Natural := Estimate (To_String (Next.Text));
               begin
                  if Next.Rank = Rank then
                     if Seen.Contains (Print) then
                        Result.Excluded.Append (Next);
                        Result.Reasons.Append
                          ("the same as " & Seen_From.Element (Seen.Find_Index (Print)));
                     elsif Rank = Mandatory or else Result.Cost + Cost <= Result.Budget then
                        Chosen (Index) := True;
                        Result.Cost := Result.Cost + Cost;
                        Seen.Append (Print);
                        Seen_From.Append (To_String (Next.Id));
                     else
                        Result.Excluded.Append (Next);
                        Result.Reasons.Append
                          ("over budget by" & Natural'Image (Result.Cost + Cost - Result.Budget));
                     end if;
                  end if;
               end;
            end loop;

            if Rank = Mandatory and then Result.Cost > Result.Budget then
               Status := E.Make (E.Framework_Context_Overflow);
               E.Add_Text (Status, "name", Task_Id);
               E.Add_Text
                 (Status, "detail",
                  "what it must hold is" & Natural'Image (Result.Cost)
                  & " tokens and the model has room for" & Natural'Image (Result.Budget));
               return;
            end if;
         end loop;

         --  In the order offered, which is the order they are rendered.
         for Index in 1 .. Natural (Candidates.Length) loop
            if Chosen (Index) then
               Result.Included.Append (Candidates (Index));
            end if;
         end loop;
      end;

      --  The fingerprint of everything the manifest says.
      declare
         Text : Unbounded_String;
      begin
         Append (Text, Task_Id & "|" & To_String (Result.Generation) & "|"
                 & To_String (Result.Model.Id) & "|" & Image (Result.Model.Context_Limit) & "|"
                 & Image (Result.Model.Output_Reserve) & "|" & Image (Result.Config_Revision)
                 & "|" & To_String (Result.Config_Fingerprint) & "|"
                 & Boolean'Image (Result.Semantic) & ASCII.LF);
         for Next of Result.Included loop
            Append (Text, "+" & To_String (Next.Id) & " "
                    & Fingerprint (To_String (Next.Text)) & ASCII.LF);
         end loop;
         if Result.Instructions /= Null_Unbounded_String then
            Append (Text, "+instructions " & Fingerprint (To_String (Result.Instructions))
                    & ASCII.LF);
         end if;
         for Index in 1 .. Natural (Result.Excluded.Length) loop
            Append (Text, "-" & To_String (Result.Excluded (Index).Id) & " "
                    & Result.Reasons (Index) & ASCII.LF);
         end loop;
         Result.Print := To_Unbounded_String (Fingerprint (To_String (Text)));
      end;
   end Settle;

   -----------
   -- Build --
   -----------

   procedure Build
     (Item    : Stores.Store;
      Task_Id : String;
      Model   : Model_Profile;
      Result  : out Built;
      Status  : out Model_Runner.Errors.Error_Info;
      Instructions : String := "")
   is
      View       : Records.Item;
      Config     : Records.Item;
      Candidates : Item_Vectors.Vector;
      Component  : Unbounded_String;

      procedure Offer (Id, Kind : String; Rank : Priority; Text : String) is
      begin
         --  Each once, however many ways it is reached.
         for Held of Candidates loop
            if To_String (Held.Id) = Id then
               return;
            end if;
         end loop;
         if Text /= "" then
            Candidates.Append
              (Context.Item'(Id   => To_Unbounded_String (Id),
                Kind => To_Unbounded_String (Kind),
                Rank => Rank,
                Text => To_Unbounded_String (Text)));
         end if;
      end Offer;

      --  The fields of a record whose names start with a prefix, one a
      --  line.
      function Fields_Of (Value : Records.Item; Prefix : String) return String is
         Text : Unbounded_String;
      begin
         for Index in 1 .. Records.Field_Count (Value) loop
            declare
               Field : constant String := Records.Field_Name (Value, Index);
            begin
               if Field'Length > Prefix'Length
                 and then Field (Field'First .. Field'First + Prefix'Length - 1)
                            = Prefix
               then
                  Append (Text, Field (Field'First + Prefix'Length .. Field'Last)
                          & ": " & Records.Get (Value, Field) & ASCII.LF);
               end if;
            end;
         end loop;
         return To_String (Text);
      end Fields_Of;

      --  The facts the registry holds that the configuration does not say
      --  -- found by bootstrap, say -- with where they came from.
      function Registry_Facts (Config : Records.Item) return String is
         Text : Unbounded_String;
      begin
         for Key of Facts.Keys (Item) loop
            if Records.Get (Config, "fact." & Key) = "" then
               declare
                  Held : Facts.Fact;
                  Read : E.Error_Info;
               begin
                  Facts.Find (Item, Key, Held, Read);
                  if E.Is_Ok (Read) then
                     Append (Text, Key & ": " & To_String (Held.Value)
                             & (if Length (Held.Origin) = 0 then ""
                                else " (from " & To_String (Held.Origin) & ")")
                             & ASCII.LF);
                  end if;
               end;
            end if;
         end loop;
         return To_String (Text);
      end Registry_Facts;
   begin
      Result := (Model => Model, others => <>);
      Result.Instructions := To_Unbounded_String (Instructions);
      Result.Cost := (if Instructions = "" then 0 else Estimate (Instructions));
      Result.Task_Id := To_Unbounded_String (Task_Id);

      Tasks.Effective (Item, Task_Id, View, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      Result.Generation := To_Unbounded_String (Records.Get (View, "runtime.generation"));
      Component := To_Unbounded_String (Records.Get (View, "definition.component"));

      Configurations.Read (Item, Config, Status);
      if E.Is_Ok (Status) then
         Result.Config_Revision := Records.Revision (Config);
         Result.Config_Fingerprint :=
           To_Unbounded_String (Records.Get (Config, "configuration_fingerprint"));
      end if;
      Status := E.Success;

      --  Room for the answer the task's kind needs: scalar
      --  task.output_reserve.KIND, where it asks for more or less than the
      --  model's profile keeps.
      declare
         Asked : constant String :=
           Records.Get (Config, "scalar.task.output_reserve."
                                & Records.Get (View, "definition.kind"));
      begin
         if Asked'Length in 1 .. 7 and then (for all C of Asked => C in '0' .. '9') then
            Result.Model.Output_Reserve := Natural'Value (Asked);
         end if;
      end;

      --  The harness's rules, and the project's.
      Offer ("rules", "rules", Mandatory,
             Harness_Rules
             & (if Records.Get (Config, "scalar.context.rules") = "" then ""
                else ASCII.LF & Records.Get (Config, "scalar.context.rules")));

      --  The task as it is to be done: what it is, not its bookkeeping.
      declare
         Text : Unbounded_String;
      begin
         for Name of Wanted_Fields loop
            if Records.Get (View, "definition." & Name.all) /= "" then
               Append (Text, Name.all & ": " & Records.Get (View, "definition." & Name.all)
                       & ASCII.LF);
            end if;
         end loop;
         for Index in 1 .. Records.Field_Count (View) loop
            declare
               Field : constant String := Records.Field_Name (View, Index);
            begin
               if Field'Length > 17 and then Field (Field'First .. Field'First + 16)
                                              = "definition.field."
               then
                  Append (Text, Field (Field'First + 17 .. Field'Last) & ": "
                          & Records.Get (View, Field) & ASCII.LF);
               end if;
            end;
         end loop;
         Offer (Task_Id & "#effective", "task", Mandatory, To_String (Text));
      end;

      --  The requirements it serves, at their revisions.
      for Index in 1 .. Records.Field_Count (View) loop
         declare
            Field : constant String := Records.Field_Name (View, Index);
         begin
            if Field'Length > 12 and then Field (Field'First .. Field'First + 11) = "requirement."
            then
               declare
                  Id   : constant String := Field (Field'First + 12 .. Field'Last);
                  Held : Intent.Entity;
                  Read : E.Error_Info;
               begin
                  Intent.Read (Item, Intent.Requirement, Id, Held, Read);
                  if E.Is_Ok (Read) then
                     Result.Revisions.Append (Id & "@" & Image (Held.Revision));
                     Offer (Id & "@" & Image (Held.Revision), "requirement", Mandatory,
                            Id & ": " & To_String (Held.Text)
                            & (if Length (Held.Criteria) = 0 then ""
                               else ASCII.LF & "Acceptance: " & To_String (Held.Criteria)));
                  end if;
               end;
            elsif Field'Length > 9 and then Field (Field'First .. Field'First + 8) = "decision."
            then
               declare
                  Id   : constant String := Field (Field'First + 9 .. Field'Last);
                  Held : Intent.Entity;
                  Read : E.Error_Info;
               begin
                  Intent.Read (Item, Intent.Decision, Id, Held, Read);
                  if E.Is_Ok (Read) then
                     Result.Revisions.Append (Id & "@" & Image (Held.Revision));
                     --  Mandatory: a decision that applies is in the context,
                     --  or the context does not fit -- never quietly left out.
                     Offer (Id & "@" & Image (Held.Revision), "decision", Mandatory,
                            Id & " " & To_String (Held.Title) & ": "
                            & To_String (Held.Text));
                  end if;
               end;
            end if;
         end;
      end loop;

      --  What governs the work, above the configuration, and every override
      --  and conflict: the model is told what holds, not left to guess.
      Offer (Task_Id & "#authority", "authority", Mandatory,
             Fields_Of (View, "authority.") & Fields_Of (View, "override.")
             & Fields_Of (View, "conflict."));

      --  Where the task stands: which attempt this is.
      Offer (Task_Id & "#runtime", "runtime", High,
             "attempt: " & Records.Get (View, "runtime.generation"));

      --  How the project is configured, as far as work on it goes.
      declare
         Kind : constant String := Records.Get (View, "definition.kind");
         Profile_Name : constant String :=
           (if Records.Get (Config, "scalar.task.profile." & Kind) /= ""
            then Records.Get (Config, "scalar.task.profile." & Kind)
            else Records.Get (Config, "scalar.verification.default"));
      begin
         Offer ("CONFIG@" & Image (Result.Config_Revision), "configuration", High,
                Fields_Of (Config, "fact.") & Registry_Facts (Config)
                & Fields_Of (Config, "scalar.build.")
                & Fields_Of (Config, "adapter.")
                & (if Records.Get (Config, "profile." & Profile_Name) = "" then ""
                   else "verification: " & Records.Get (Config, "profile." & Profile_Name)
                        & ASCII.LF));
      end;

      --  The accepted specifications for the project and the component.
      for Id of Intent.List (Item, Intent.Specification, "accepted") loop
         declare
            Held : Intent.Entity;
            Read : E.Error_Info;
         begin
            Intent.Read (Item, Intent.Specification, Id, Held, Read);
            if E.Is_Ok (Read)
              and then To_String (Held.Scope) in "project" | To_String (Component)
            then
               Offer (Id & "@" & Image (Held.Revision), "specification", Normal,
                      To_String (Held.Title) & ASCII.LF & To_String (Held.Text));
            end if;
         end;
      end loop;

      --  Source: from the repository's graph when one is kept, from the
      --  files as they are when not -- and the manifest says which.
      declare
         Graph   : Repository.Graph;
         Read    : E.Error_Info;
         Project : constant String :=
           Ada.Directories.Containing_Directory (Stores.Root (Item));
         Wanted  : constant String := Lower (To_String (Component));
      begin
         --  The kept graph, brought up to date: a stale one would offer the
         --  files and symbols as they were.
         Repository.Load (Item, Graph, Read);
         Result.Semantic := E.Is_Ok (Read);
         Graph := Repository.Now (Item);

         if Wanted /= "" then
            for Index in 1 .. Repository.File_Count (Graph) loop
               declare
                  use type Repository.File_Role;
                  File : constant Repository.File_Entry :=
                    Repository.File_At (Graph, Index);
                  Path : constant String := To_String (File.Path);
                  Text : Unbounded_String;
               begin
                  if Ada.Strings.Fixed.Index (Lower (Path), Wanted) > 0
                    and then File.Role in Repository.Source | Repository.Test
                  then
                     Files.Read_Text (Hostkit.Fs.Join (Project, Path), Text, Read);
                     if E.Is_Ok (Read) then
                        Offer ("file:" & Path,
                               (if File.Role = Repository.Source then "source" else "test"),
                               (if File.Role = Repository.Source then Normal else Low),
                               To_String (Text));
                     end if;
                  end if;
               end;
            end loop;

            --  The symbols its files declare: what there is to use or to
            --  change, where the files themselves may not all fit.
            declare
               Listed : Unbounded_String;
            begin
               for Index in 1 .. Repository.Symbol_Count (Graph) loop
                  declare
                     One : constant Repository.Symbol := Repository.Symbol_At (Graph, Index);
                  begin
                     if Ada.Strings.Fixed.Index (Lower (To_String (One.Path)), Wanted) > 0 then
                        Append (Listed, To_String (One.Kind) & " " & To_String (One.Name)
                                & "  " & To_String (One.Path) & ":" & Image (One.Line) & ASCII.LF);
                     end if;
                  end;
               end loop;
               Offer (Task_Id & "#symbols", "symbols", Normal, To_String (Listed));
            end;
         end if;

         --  The tests that bear on it: the component's test files, and the
         --  tests its requirements name.
         declare
            Listed : Unbounded_String;
         begin
            if Wanted /= "" then
               for Index in 1 .. Repository.File_Count (Graph) loop
                  declare
                     use type Repository.File_Role;
                     File : constant Repository.File_Entry := Repository.File_At (Graph, Index);
                  begin
                     if File.Role = Repository.Test
                       and then Ada.Strings.Fixed.Index (Lower (To_String (File.Path)), Wanted) > 0
                     then
                        Append (Listed, To_String (File.Path) & ASCII.LF);
                     end if;
                  end;
               end loop;
            end if;
            for Requirement of Lines_Of (Records.Get (View, "definition.requirements")) loop
               for Test of Intent.Links (Item, Intent.Requirement, Requirement, Intent.Test) loop
                  Append (Listed, Test & " (tests " & Requirement & ")" & ASCII.LF);
               end loop;
            end loop;

            --  How the project's tests are laid out, and what runs them: a
            --  test that is not registered where the harness lists its
            --  tests does not run.
            declare
               Layout : Unbounded_String;
               Shown  : Natural := 0;
            begin
               for Index in 1 .. Repository.File_Count (Graph) loop
                  declare
                     use type Repository.File_Role;
                     File : constant Repository.File_Entry := Repository.File_At (Graph, Index);
                     Path : constant String := To_String (File.Path);
                     Base : constant String :=
                       Lower (Ada.Directories.Base_Name (Ada.Directories.Simple_Name (Path)));
                     Text : Unbounded_String;
                  begin
                     if File.Role = Repository.Test then
                        if Shown < 40 then
                           Append (Layout, Path & ASCII.LF);
                           Shown := Shown + 1;
                        end if;
                        if Base in "tests" | "test_main" | "all_tests" | "test_runner" | "suite"
                                 | "test_suite" | "harness" | "conftest"
                        then
                           Files.Read_Text (Hostkit.Fs.Join (Project, Path), Text, Read);
                           if E.Is_Ok (Read) then
                              Offer ("file:" & Path, "test", Normal, To_String (Text));
                           end if;
                        end if;
                     end if;
                  end;
               end loop;
               if Layout /= Null_Unbounded_String then
                  Append (Listed, "The project's test files -- a new test runs only once it is"
                          & " registered where the test harness lists its tests:" & ASCII.LF
                          & Layout);
               end if;
            end;
            Offer (Task_Id & "#tests", "tests", Normal, To_String (Listed));
         end;
      end;

      --  What earlier attempts left: the last answer, and what the last
      --  verification found wrong -- a retry is told why it is one.
      declare
         State    : Records.Item;
         Read     : E.Error_Info;
         Listed   : Unbounded_String;

         --  The results and evidence it came from, by their identifiers:
         --  the manifest names what went in, not only that something did.
         Sources  : Unbounded_String;
      begin
         Stores.Read (Item, Tasks_Area, Task_Id & ".state", State, Read);
         if Records.Get (State, "last_result") /= "" then
            declare
               Held : Results.Result;
            begin
               Results.Read (Item, Records.Get (State, "last_result"), Held, Read);
               if E.Is_Ok (Read) then
                  Append (Listed, "The last answer (" & Records.Get (State, "last_result") & "):"
                          & ASCII.LF & To_String (Held.Payload) & ASCII.LF);
                  Append (Sources, "," & Records.Get (State, "last_result"));
               end if;
            end;
         end if;
         if Records.Get (State, "current_verification") /= "" then
            declare
               Evidence : constant String := Records.Get (State, "current_verification");
               Said     : constant Verification.Diagnostic_List :=
                 Verification.Diagnostics_Of (Item, Evidence);
               Value    : Records.Item;
            begin
               Stores.Read (Item, Verification_Area, Evidence, Value, Read);
               if E.Is_Ok (Read) and then Records.Get (Value, "passed") /= "true" then
                  Append (Sources, "," & Evidence);
                  Append (Listed, Evidence & " did not pass:" & ASCII.LF);
                  for Index in 1 .. Verification.Length (Said) loop
                     declare
                        One : constant Verification.Diagnostic := Verification.Element (Said, Index);
                     begin
                        Append (Listed, To_String (One.File) & ":" & Image (One.Line) & ": "
                                & To_String (One.Severity) & ": " & To_String (One.Message)
                                & ASCII.LF);
                     end;
                  end loop;
               end if;
            end;
         end if;
         Offer (Task_Id & "#results"
                & (if Sources = Null_Unbounded_String then ""
                   else ":" & Slice (Sources, 2, Length (Sources))),
                "results", High, To_String (Listed));
      end;

      Settle (Candidates, Task_Id, Result, Status);
   end Build;

   -----------------
   -- Build_Brief --
   -----------------

   procedure Build_Brief
     (Item    : Stores.Store;
      Task_Id : String;
      Model   : Model_Profile;
      Rules   : String;
      Brief   : String;
      Result  : out Built;
      Status  : out Model_Runner.Errors.Error_Info;
      Instructions : String := "")
   is
      Defined    : Records.Item;
      Config     : Records.Item;
      Candidates : Item_Vectors.Vector;

      procedure Offer (Id, Kind : String; Text : String) is
      begin
         Candidates.Append
           (Context.Item'(Id   => To_Unbounded_String (Id),
                          Kind => To_Unbounded_String (Kind),
                          Rank => Mandatory,
                          Text => To_Unbounded_String (Text)));
      end Offer;
   begin
      Result := (Model => Model, others => <>);
      Result.Instructions := To_Unbounded_String (Instructions);
      Result.Cost := (if Instructions = "" then 0 else Estimate (Instructions));
      Result.Task_Id := To_Unbounded_String (Task_Id);
      Tasks.Definition (Item, Task_Id, Defined, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         View : Records.Item;
      begin
         Tasks.Effective (Item, Task_Id, View, Status);
         Result.Generation := To_Unbounded_String (Records.Get (View, "runtime.generation"));
      end;
      Configurations.Read (Item, Config, Status);
      if E.Is_Ok (Status) then
         Result.Config_Revision := Records.Revision (Config);
         Result.Config_Fingerprint :=
           To_Unbounded_String (Records.Get (Config, "configuration_fingerprint"));
      end if;
      Status := E.Success;

      --  The child's rules, the task it helps with and what it is asked:
      --  nothing of the conversation it was asked from.
      Offer ("rules", "rules", Rules);
      Offer (Task_Id & "#helped", "helped",
             "title: " & Records.Get (Defined, "title") & ASCII.LF
             & (if Records.Get (Defined, "component") = "" then ""
                else "component: " & Records.Get (Defined, "component") & ASCII.LF));
      Offer ("brief", "brief", Brief);
      Settle (Candidates, Task_Id, Result, Status);
   end Build_Brief;

   function Manifest_Id (From : Built) return String
   is ("CTX-" & Ada.Characters.Handling.To_Upper (To_String (From.Print)));

   --------------
   -- Rendered --
   --------------

   function Rendered (From : Built) return String is
      Text : Unbounded_String;

      --  A heading a reader, or a model, takes for what it is rather than
      --  for an identifier to call.
      function Heading (Next : Item) return String is
         Kind : constant String := To_String (Next.Kind);
         Id   : constant String := To_String (Next.Id);
      begin
         if Kind = "rules" then
            return "Rules";
         elsif Kind = "task" then
            return "The task, " & Id (Id'First .. Ada.Strings.Fixed.Index (Id, "#") - 1);
         elsif Kind = "runtime" then
            return "Where the task stands";
         elsif Kind = "configuration" then
            return "The project's configuration";
         elsif Kind = "authority" then
            return "What governs the work";
         elsif Kind = "symbols" then
            return "What its files declare";
         elsif Kind = "tests" then
            return "The tests that bear on it";
         elsif Kind = "test" then
            return "The test " & Id (Id'First + 5 .. Id'Last);
         elsif Kind = "results" then
            return "What the last attempt left";
         elsif Kind = "helped" then
            return "The task it works on, " & Id (Id'First .. Ada.Strings.Fixed.Index (Id, "#") - 1);
         elsif Kind = "brief" then
            return "What you are asked";
         elsif Kind = "source" then
            return "The file " & Id (Id'First + 5 .. Id'Last);
         else
            return "The " & Kind & " " & Id;
         end if;
      end Heading;
   begin
      for Next of From.Included loop
         Append (Text, "## " & Heading (Next) & ASCII.LF
                 & To_String (Next.Text) & ASCII.LF & ASCII.LF);
      end loop;
      return To_String (Text & From.Instructions);
   end Rendered;

   function Budget (From : Built) return Natural
   is (From.Budget);

   function Cost (From : Built) return Natural
   is (From.Cost);

   function Included_Count (From : Built) return Natural
   is (Natural (From.Included.Length));

   function Excluded_Count (From : Built) return Natural
   is (Natural (From.Excluded.Length));

   function Included_At (From : Built; Index : Positive) return Item
   is (From.Included (Index));

   function Semantic (From : Built) return Boolean
   is (From.Semantic);

   ----------
   -- Keep --
   ----------

   procedure Keep
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      From   : Built;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Id   : constant String := Manifest_Id (From);
      Name : constant String := "manifest." & Id;
      Text : Results.Result :=
        (Kind       => Results.Context_Report,
         Producer   => To_Unbounded_String ("context-engine"),
         Summary    => To_Unbounded_String (Id),
         Payload    => To_Unbounded_String (Rendered (From)),
         Provenance => To_Unbounded_String (Id),
         others     => <>);
   begin
      Status := E.Success;
      if Stores.Exists (Item, Invocations_Area, Name) then
         return;
      end if;

      Results.Add (Item, Change, Text, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      declare
         Value : Records.Item := Records.Create (Schemas.Manifest_Record_Schema, 1, Id, 1);
      begin
         Records.Set (Value, "task", To_String (From.Task_Id));
         Records.Set (Value, "generation", To_String (From.Generation));
         Records.Set (Value, "model_profile", To_String (From.Model.Id));
         Records.Set (Value, "configuration_revision", Image (From.Config_Revision));
         Records.Set (Value, "configuration_fingerprint", To_String (From.Config_Fingerprint));
         Records.Set (Value, "retrieval", (if From.Semantic then "semantic" else "textual"));
         Records.Set (Value, "budget", Image (From.Budget));
         Records.Set (Value, "estimated_tokens", Image (From.Cost));
         Records.Set (Value, "fingerprint", To_String (From.Print));
         Records.Set (Value, "rendered", To_String (Text.Id));
         for Index in 1 .. Natural (From.Included.Length) loop
            Records.Set
              (Value, "included." & Image (Index),
               To_String (From.Included (Index).Id) & " "
               & Lower (Priority'Image (From.Included (Index).Rank)) & " "
               & Image (Estimate (To_String (From.Included (Index).Text))));
         end loop;
         for Index in 1 .. Natural (From.Excluded.Length) loop
            Records.Set
              (Value, "excluded." & Image (Index),
               To_String (From.Excluded (Index).Id) & ": " & From.Reasons (Index));
         end loop;
         for Revision of From.Revisions loop
            declare
               At_Sign : constant Natural := Ada.Strings.Fixed.Index (Revision, "@");
            begin
               Records.Set
                 (Value, "applies." & Revision (Revision'First .. At_Sign - 1),
                  Revision (At_Sign + 1 .. Revision'Last));
            end;
         end loop;
         Stores.Put (Change, Invocations_Area, Name, Value);
      end;
   end Keep;

end Model_Runner.Framework.Context;
