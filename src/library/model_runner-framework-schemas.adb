with Model_Runner.Framework.Identifiers;

package body Model_Runner.Framework.Schemas is

   package E renames Model_Runner.Errors;

   --  What a field holds.
   type Field_Kind is (Text_Field, Number_Field, Identifier_Field, Choice_Field);

   --  What becomes of a field the schema does not name.
   type Unknown_Policy is (Preserve_Unknown, Reject_Unknown);

   type Text_Access is access constant String;

   --  One field a schema names. A name ending in * names every field that
   --  begins with what comes before it. Choices are the words a choice
   --  field may hold, each followed by a space.
   type Field_Rule is record
      Name     : Text_Access;
      Kind     : Field_Kind;
      Required : Boolean;
      Choices  : Text_Access;
   end record;

   type Rule_List is array (Positive range <>) of Field_Rule;
   type Rule_Access is access constant Rule_List;

   type Schema is record
      Id      : Text_Access;
      Version : Positive;
      Policy  : Unknown_Policy;
      Rules   : Rule_Access;
   end record;

   None : constant Text_Access := new String'("");

   function Rule
     (Name     : String;
      Kind     : Field_Kind;
      Required : Boolean;
      Choices  : String := "") return Field_Rule
   is (Name     => new String'(Name),
       Kind     => Kind,
       Required => Required,
       Choices  => (if Choices = "" then None else new String'(Choices)));

   Schemas_Known : constant array (Positive range <>) of Schema :=
     [(Id      => new String'(Root_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("format", Choice_Field, True, Format_Name & " "),
          Rule ("state_version", Number_Field, True),
          Rule ("created_by", Text_Field, False)]),

      (Id      => new String'(Identity_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("project_id", Identifier_Field, True),
          Rule ("name", Text_Field, True),
          Rule ("created_at", Text_Field, True)]),

      --  Every field of the counters is a count somebody relies on, so a
      --  field that is not one is refused rather than carried.
      (Id      => new String'(Identifiers.Counters_Schema),
       Version => 1,
       Policy  => Reject_Unknown,
       Rules   => new Rule_List'
         [1 => Rule ("next.*", Number_Field, False)]),

      (Id      => new String'(Fact_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("key", Text_Field, True),
          Rule ("value", Text_Field, True),
          Rule ("source", Choice_Field, True,
                "explicit template semantic_analysis build_metadata "
                & "naming_convention heuristic "),
          Rule ("confidence", Choice_Field, True,
                "authoritative certain probable uncertain ")]),

      (Id      => new String'(Result_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("result_type", Choice_Field, True,
                "analysis implementation verification diagnostic "
                & "decision_proposal task_proposal impact_report "
                & "integration_report child_result context_report "
                & "bootstrap_report "),
          Rule ("producer", Text_Field, True),
          Rule ("created_at", Text_Field, True),
          Rule ("summary", Text_Field, True),
          Rule ("payload", Text_Field, False),
          Rule ("payload_fingerprint", Text_Field, True),
          Rule ("provenance", Text_Field, False),
          Rule ("references", Text_Field, False)]),

      --  What a template resolved to. Its declarations are fields named
      --  by their kind and key, which no schema can list ahead of time, so
      --  only the provenance and the fingerprint are required.
      (Id      => new String'(Configuration_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("template_id", Text_Field, True),
          Rule ("template_version", Text_Field, True),
          Rule ("template_fingerprint", Text_Field, True),
          Rule ("template_origin", Text_Field, True),
          Rule ("template_order", Text_Field, True),
          Rule ("configuration_fingerprint", Text_Field, True)]),

      (Id      => new String'(Index_Schema),
       Version => 1,
       Policy  => Reject_Unknown,
       Rules   => new Rule_List'
         [Rule ("entries", Number_Field, True),
          Rule ("entity.*", Text_Field, False)]),

      (Id      => new String'(Manifest_Schema),
       Version => 1,
       Policy  => Reject_Unknown,
       Rules   => new Rule_List'
         [Rule ("operations", Number_Field, True),
          Rule ("transaction", Text_Field, False),
          Rule ("op.*", Text_Field, False)]),

      --  An event. What kind it is is checked where it is made, against
      --  the kinds this build knows; a later build's kind is kept and
      --  read back as the word it is.
      (Id      => new String'(Event_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("event_kind", Text_Field, True),
          Rule ("sequence", Number_Field, True),
          Rule ("subject", Identifier_Field, True),
          Rule ("transaction", Identifier_Field, True),
          Rule ("occurred_at", Text_Field, True),
          Rule ("detail", Text_Field, False)]),

      --  Specifications, requirements and decisions, and each kept
      --  revision of one. Links and what an entity governs are optional
      --  fields; a later build's are kept.
      (Id      => new String'(Intent_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("kind", Choice_Field, True,
                "specification requirement decision "),
          Rule ("state", Text_Field, True),
          Rule ("title", Text_Field, True),
          Rule ("text", Text_Field, True),
          Rule ("criteria", Text_Field, False),
          Rule ("source", Text_Field, True),
          Rule ("provenance", Text_Field, False),
          Rule ("scope", Text_Field, True),
          Rule ("meaning", Text_Field, True),
          Rule ("supersedes", Text_Field, False),
          Rule ("superseded_by", Text_Field, False),
          Rule ("governs", Text_Field, False),
          Rule ("ruling", Text_Field, False),
          Rule ("overrides", Text_Field, False),
          Rule ("revision_of", Identifier_Field, False),
          Rule ("links.*", Text_Field, False)]),

      --  A task's definition: its core fields, and its kind's own as
      --  field.NAME, which the kind's schema in the configuration checks.
      (Id      => new String'(Task_Definition_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("title", Text_Field, True),
          Rule ("kind", Text_Field, True),
          Rule ("created_by", Text_Field, True),
          Rule ("origin", Text_Field, False),
          Rule ("component", Text_Field, False),
          Rule ("requirements", Text_Field, False),
          Rule ("depends_on", Text_Field, False),
          Rule ("priority", Number_Field, False),
          Rule ("acceptance", Text_Field, False),
          Rule ("parent", Identifier_Field, False),
          Rule ("notes", Text_Field, False),
          Rule ("derivation_key", Text_Field, False),
          Rule ("field.*", Text_Field, False)]),

      (Id      => new String'(Task_Runtime_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("state", Text_Field, True),
          Rule ("generation", Number_Field, True),
          Rule ("blocking_reasons", Text_Field, False),
          Rule ("current_failure", Text_Field, False),
          Rule ("accepted_by", Text_Field, False)]),

      (Id      => new String'(Readiness_Schema),
       Version => 1,
       Policy  => Reject_Unknown,
       Rules   => new Rule_List'
         [1 => Rule ("task.*", Choice_Field, False, "ready waiting ")]),

      (Id      => new String'(Lease_Schema),
       Version => 1,
       Policy  => Preserve_Unknown,
       Rules   => new Rule_List'
         [Rule ("resource", Text_Field, True),
          Rule ("owner", Text_Field, True),
          Rule ("acquired_at", Text_Field, True),
          Rule ("expires_at", Text_Field, True)]),

      --  The events one consumer has acted on, each a field of its own so
      --  that a record grows by one field an event and is never parsed.
      (Id      => new String'(Consumption_Schema),
       Version => 1,
       Policy  => Reject_Unknown,
       Rules   => new Rule_List'
         [Rule ("consumer", Text_Field, True),
          Rule ("done.*", Text_Field, False)])];

   --  Whether a rule names a field.
   function Names (Item : Field_Rule; Field : String) return Boolean is
      Name : String renames Item.Name.all;
   begin
      if Name (Name'Last) = '*' then
         declare
            Stem : constant String := Name (Name'First .. Name'Last - 1);
         begin
            return Field'Length > Stem'Length
              and then Field (Field'First .. Field'First + Stem'Length - 1)
                         = Stem;
         end;
      end if;
      return Field = Name;
   end Names;

   --  Whether a field's bytes are what its rule says they hold.
   function Holds (Item : Field_Rule; Text : String) return Boolean is
   begin
      case Item.Kind is
         when Text_Field =>
            return True;

         when Number_Field =>
            return Text'Length in 1 .. 9
              and then (for all Char of Text => Char in '0' .. '9');

         when Identifier_Field =>
            return Identifiers.Is_Valid (Text);

         when Choice_Field =>
            declare
               Choices : String renames Item.Choices.all;
               Wanted  : constant String := Text & " ";
            begin
               if Text'Length = 0
                 or else (for some Char of Text => Char = ' ')
               then
                  return False;
               end if;
               for Start in Choices'Range loop
                  if (Start = Choices'First or else Choices (Start - 1) = ' ')
                    and then Start + Wanted'Length - 1 <= Choices'Last
                    and then Choices (Start .. Start + Wanted'Length - 1)
                               = Wanted
                  then
                     return True;
                  end if;
               end loop;
               return False;
            end;
      end case;
   end Holds;

   --  The schema a record names, or zero.
   function Find (Schema_Id : String) return Natural is
   begin
      for Index in Schemas_Known'Range loop
         if Schemas_Known (Index).Id.all = Schema_Id then
            return Index;
         end if;
      end loop;
      return 0;
   end Find;

   ---------------------
   -- Current_Version --
   ---------------------

   function Current_Version (Schema_Id : String) return Natural is
      Which : constant Natural := Find (Schema_Id);
   begin
      return (if Which = 0 then 0 else Schemas_Known (Which).Version);
   end Current_Version;

   --------------
   -- Validate --
   --------------

   procedure Validate
     (Value  : Records.Item;
      Origin : String;
      Status : out Model_Runner.Errors.Error_Info)
   is
      Which : constant Natural := Find (Records.Schema_Id (Value));

      procedure Refuse (Detail : String) is
      begin
         Status := E.Make (E.Framework_Schema_Violation);
         E.Add_Text (Status, "name", Origin, E.Param_Path);
         E.Add_Text (Status, "detail", Detail);
      end Refuse;
   begin
      Status := E.Success;

      if Which = 0 then
         Refuse ("no schema is called " & Records.Schema_Id (Value));
         return;
      end if;

      declare
         Known : Schema renames Schemas_Known (Which);
      begin
         if Records.Schema_Version (Value) > Known.Version then
            Status := E.Make (E.Framework_Format_Unsupported);
            E.Add_Text (Status, "path", Origin, E.Param_Path);
            E.Add_Integer
              (Status, "version",
               Long_Long_Integer (Records.Schema_Version (Value)));
            return;
         end if;

         --  Every schema is at its first version, so there is nothing yet
         --  to carry an earlier record forward from. The first schema
         --  that changes adds its step here, before the fields are read
         --  against the current rules.

         if not Identifiers.Is_Valid (Records.Entity_Id (Value)) then
            Refuse ("its entity " & Records.Entity_Id (Value)
                    & " is not an identifier");
            return;
         elsif Records.Revision (Value) = 0 then
            Refuse ("it has no revision");
            return;
         end if;

         for Item of Known.Rules.all loop
            if Item.Required and then not Records.Has (Value, Item.Name.all)
            then
               Refuse ("it has no " & Item.Name.all);
               return;
            end if;
         end loop;

         for Index in 1 .. Records.Field_Count (Value) loop
            declare
               Field : constant String := Records.Field_Name (Value, Index);
               Named : Boolean := False;
            begin
               for Item of Known.Rules.all loop
                  if Names (Item, Field) then
                     Named := True;
                     if not Holds (Item, Records.Get (Value, Field)) then
                        Refuse ("its " & Field & " is not what the field"
                                & " holds");
                        return;
                     end if;
                  end if;
               end loop;

               if not Named
                 and then Known.Policy = Reject_Unknown
                 and then (for all Char of Field => Char /= ':')
               then
                  Refuse ("it has a field " & Field & " its schema does not"
                          & " name");
                  return;
               end if;
            end;
         end loop;
      end;
   end Validate;

end Model_Runner.Framework.Schemas;
