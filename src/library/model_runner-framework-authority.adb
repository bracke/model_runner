with Model_Runner.Framework.Configurations;
with Model_Runner.Framework.Intent;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Schemas;

package body Model_Runner.Framework.Authority is

   use Ada.Strings.Unbounded;

   package E renames Model_Runner.Errors;

   --  Whether a text begins with another.
   function Starts (Text, Prefix : String) return Boolean
   is (Text'Length >= Prefix'Length
       and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   ------------
   -- Append --
   ------------

   procedure Append (Into : in out Statement_List; Item : Statement) is
   begin
      Into.Statements.Append (Item);
   end Append;

   function Count (From : Statement_List) return Natural
   is (Natural (From.Statements.Length));

   Instruction_Prefix : constant String := "instruction.";

   --  The instructions on record, standing or not.
   function Instruction_Names (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Name of Stores.Names (Item, Project_Area) loop
         if Starts (Name, Instruction_Prefix) then
            Result.Append (Name);
         end if;
      end loop;
      return Result;
   end Instruction_Names;

   --------------
   -- Instruct --
   --------------

   procedure Instruct
     (Item      : Stores.Store;
      Change    : in out Stores.Transaction;
      Subject   : String;
      Value     : String;
      Overrides : String;
      Given_By  : String;
      Id        : out Ada.Strings.Unbounded.Unbounded_String;
      Status    : out Model_Runner.Errors.Error_Info)
   is
   begin
      Id := Null_Unbounded_String;
      if Subject = "" or else Value = "" then
         Status := E.Make (E.Framework_Input_Missing);
         E.Add_Text (Status, "name", (if Subject = "" then "the subject" else "what it says"));
         return;
      end if;
      Stores.Allocate_Identifier (Item, Change, "INSTR", "", Id, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      declare
         Value_Record : Records.Item :=
           Records.Create (Schemas.Instruction_Schema, 1, To_String (Id), 1);
      begin
         Records.Set (Value_Record, "subject", Subject);
         Records.Set (Value_Record, "value", Value);
         if Overrides /= "" then
            Records.Set (Value_Record, "overrides", Overrides);
         end if;
         Records.Set (Value_Record, "state", "standing");
         Records.Set (Value_Record, "given_by", (if Given_By = "" then "user" else Given_By));
         Records.Set (Value_Record, "given_at", Timestamp);
         Stores.Put (Change, Project_Area, Instruction_Prefix & To_String (Id), Value_Record);
      end;
   end Instruct;

   --------------
   -- Withdraw --
   --------------

   procedure Withdraw
     (Item   : Stores.Store;
      Change : in out Stores.Transaction;
      Id     : String;
      By     : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Held : Records.Item;
   begin
      Stores.Read (Item, Project_Area, Instruction_Prefix & Id, Held, Status);
      if E.Is_Error (Status) or else Records.Get (Held, "state") /= "standing" then
         Status := E.Make (E.Framework_Not_Found);
         E.Add_Text (Status, "name", Id);
         return;
      end if;
      Records.Set_Revision (Held, Records.Revision (Held) + 1);
      Records.Set (Held, "state", "withdrawn");
      Records.Set (Held, "withdrawn_by", (if By = "" then "user" else By));
      Records.Set (Held, "withdrawn_at", Timestamp);
      Stores.Put (Change, Project_Area, Instruction_Prefix & Id, Held);
   end Withdraw;

   ---------------------------
   -- Standing_Instructions --
   ---------------------------

   function Standing_Instructions (Item : Stores.Store) return Name_Lists.Vector is
      Result : Name_Lists.Vector;
   begin
      for Name of Instruction_Names (Item) loop
         declare
            Held   : Records.Item;
            Status : E.Error_Info;
         begin
            Stores.Read (Item, Project_Area, Name, Held, Status);
            if E.Is_Ok (Status) and then Records.Get (Held, "state") = "standing" then
               Result.Append
                 (Name (Name'First + Instruction_Prefix'Length .. Name'Last) & ": "
                  & Records.Get (Held, "subject") & " = " & Records.Get (Held, "value")
                  & (if Records.Get (Held, "overrides") = "" then ""
                     else " (overriding " & Records.Get (Held, "overrides") & ")"));
            end if;
         end;
      end loop;
      return Result;
   end Standing_Instructions;

   ------------
   -- Gather --
   ------------

   function Gather (Item : Stores.Store; Component : String := "") return Statement_List is
      Result : Statement_List;

      procedure From_Register
        (Kind    : Intent.Intent_Kind;
         Where   : Area;
         Project : Level;
         Scoped  : Level) is
      begin
         for Name of Intent.List (Item, Kind, "accepted") loop
            declare
               Held   : Records.Item;
               Status : E.Error_Info;
            begin
               Stores.Read (Item, Where, Name, Held, Status);
               --  The project's, and the component's own; one scoped to
               --  another component governs nothing here.
               if E.Is_Ok (Status) and then Records.Get (Held, "governs") /= ""
                 and then (Records.Get (Held, "scope") in "" | "project"
                           or else (Component /= "" and then Records.Get (Held, "scope") = Component))
               then
                  Append
                    (Result,
                     (Standing  =>
                        (if Records.Get (Held, "scope") = "project"
                         then Project else Scoped),
                      Source    => To_Unbounded_String (Name),
                      Subject   => To_Unbounded_String
                                     (Records.Get (Held, "governs")),
                      Value     => To_Unbounded_String
                                     (Records.Get (Held, "ruling")),
                      Overrides => To_Unbounded_String
                                     (Records.Get (Held, "overrides"))));
               end if;
            end;
         end loop;
      end From_Register;

      Config : Records.Item;
      Status : E.Error_Info;

      --  The settings a statement can be about; inputs, files and facts
      --  are what the project is, not rules about how it is made.
      type Prefix_Text is access constant String;
      Governed : constant array (1 .. 6) of Prefix_Text :=
        [new String'("scalar."), new String'("map."), new String'("adapter."),
         new String'("profile."), new String'("task_kind."),
         new String'("schema.")];
   begin
      --  A person's standing word first: it outranks all that follows.
      for Name of Instruction_Names (Item) loop
         declare
            Held : Records.Item;
            Read : E.Error_Info;
         begin
            Stores.Read (Item, Project_Area, Name, Held, Read);
            if E.Is_Ok (Read) and then Records.Get (Held, "state") = "standing" then
               Append
                 (Result,
                  (Standing  => Human_Instruction,
                   Source    => To_Unbounded_String
                                  (Name (Name'First + Instruction_Prefix'Length .. Name'Last)),
                   Subject   => To_Unbounded_String (Records.Get (Held, "subject")),
                   Value     => To_Unbounded_String (Records.Get (Held, "value")),
                   Overrides => To_Unbounded_String (Records.Get (Held, "overrides"))));
            end if;
         end;
      end loop;

      From_Register
        (Intent.Decision, Decisions_Area, Project_Decision, Project_Decision);
      From_Register
        (Intent.Specification, Specs_Area, Project_Specification,
         Component_Specification);

      --  The configuration's settings, each its own subject by the field
      --  it is kept in, so a decision about one names that field.
      Configurations.Read (Item, Config, Status);
      if E.Is_Ok (Status) then
         for Index in 1 .. Records.Field_Count (Config) loop
            declare
               Field : constant String := Records.Field_Name (Config, Index);
            begin
               --  A baseline's subject is what follows its level.
               if Starts (Field, "baseline.project.") or else Starts (Field, "baseline.language.") then
                  declare
                     Project : constant Boolean := Starts (Field, "baseline.project.");
                     Rest    : constant String :=
                       Field (Field'First + (if Project then 17 else 18) .. Field'Last);
                  begin
                     Append
                       (Result,
                        (Standing  => (if Project then Project_Baseline else Language_Baseline),
                         Source    => To_Unbounded_String ("CONFIG"),
                         Subject   => To_Unbounded_String (Rest),
                         Value     => To_Unbounded_String (Records.Get (Config, Field)),
                         Overrides => Null_Unbounded_String));
                  end;
               end if;
               for Prefix of Governed loop
                  if Field'Length > Prefix'Length
                    and then Field (Field'First .. Field'First + Prefix'Length - 1)
                               = Prefix.all
                  then
                     Append
                       (Result,
                        (Standing  => Resolved_Configuration,
                         Source    => To_Unbounded_String ("CONFIG"),
                         Subject   => To_Unbounded_String (Field),
                         Value     => To_Unbounded_String
                                        (Records.Get (Config, Field)),
                         Overrides => Null_Unbounded_String));
                  end if;
               end loop;
            end;
         end loop;
      end if;
      return Result;
   end Gather;

   -------------
   -- Resolve --
   -------------

   function Resolve (From : Statement_List) return Resolution is
      Result : Resolution;

      function Place_Of (Subject : Unbounded_String) return Natural is
      begin
         for Index in 1 .. Natural (Result.Governing.Length) loop
            if Result.Governing (Index).Subject = Subject then
               return Index;
            end if;
         end loop;
         return 0;
      end Place_Of;

      --  Whether a statement overrides another, itself or through what it
      --  overrides: an instruction overriding a decision overrides what the
      --  decision overrode.
      function Overrides (Rule, Other : Statement; Depth : Natural := 0) return Boolean is
      begin
         if Rule.Overrides = Null_Unbounded_String or else Depth > 8 then
            return False;
         elsif Rule.Overrides = Other.Source then
            return True;
         end if;
         for Next of From.Statements loop
            if Next.Subject = Rule.Subject and then Next.Source = Rule.Overrides
              and then Overrides (Next, Other, Depth + 1)
            then
               return True;
            end if;
         end loop;
         return False;
      end Overrides;
   begin
      --  The governing statement of each subject: the highest standing,
      --  and of equals the first given, so that equals that disagree are
      --  still set against each other below.
      for Next of From.Statements loop
         declare
            Held : constant Natural := Place_Of (Next.Subject);
         begin
            if Held = 0 then
               Result.Governing.Append (Next);
            elsif Next.Standing < Result.Governing (Held).Standing then
               Result.Governing (Held) := Next;
            end if;
         end;
      end loop;

      --  Every other statement, against the one governing its subject.
      for Next of From.Statements loop
         declare
            Rule : constant Statement := Result.Governing (Place_Of (Next.Subject));
         begin
            if Rule /= Next then
               Result.Standings.Append
                 (Standing_Of'
                    (Governing => Rule,
                     Other     => Next,
                     Relation  =>
                       (if Rule.Value = Next.Value then Agreement
                        elsif Overrides (Rule, Next) then Explicit_Override
                        else Conflict)));
            end if;
         end;
      end loop;

      --  A narrower subject refines a broader one.
      for Narrow of Result.Governing loop
         for Broad of Result.Governing loop
            declare
               Inner : constant String := To_String (Narrow.Subject);
               Outer : constant String := To_String (Broad.Subject) & ".";
            begin
               if Inner'Length > Outer'Length
                 and then Inner (Inner'First .. Inner'First + Outer'Length - 1)
                            = Outer
               then
                  Result.Standings.Append
                    (Standing_Of'
                       (Governing => Narrow,
                        Other     => Broad,
                        Relation  => Refinement));
               end if;
            end;
         end loop;
      end loop;
      return Result;
   end Resolve;

   ---------------
   -- Governing --
   ---------------

   function Governing
     (From    : Resolution;
      Subject : String;
      Found   : out Boolean) return Statement is
   begin
      for Rule of From.Governing loop
         if To_String (Rule.Subject) = Subject then
            Found := True;
            return Rule;
         end if;
      end loop;
      Found := False;
      return (others => <>);
   end Governing;

   function Length (From : Resolution) return Natural
   is (Natural (From.Standings.Length));

   function Element (From : Resolution; Index : Positive) return Standing_Of
   is (From.Standings (Index));

   ---------------------
   -- Governing_Count --
   ---------------------

   function Governing_Count (From : Resolution) return Natural
   is (Natural (From.Governing.Length));

   ------------------
   -- Governing_At --
   ------------------

   function Governing_At (From : Resolution; Index : Positive) return Statement
   is (From.Governing (Index));

end Model_Runner.Framework.Authority;
