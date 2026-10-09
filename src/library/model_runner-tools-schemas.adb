package body Model_Runner.Tools.Schemas is

   use Ada.Strings.Unbounded;

   ----------
   -- Text --
   ----------

   function Text
     (Name     : String;
      Required : Boolean := True;
      Choices  : Choice_Lists.Vector := Any_Text) return Parameter
   is ((Name => To_Unbounded_String (Name), Required => Required, Choices => Choices,
        Whole => False));

   ------------------
   -- Whole_Number --
   ------------------

   function Whole_Number
     (Name     : String;
      Required : Boolean := True) return Parameter
   is ((Name => To_Unbounded_String (Name), Required => Required,
        Choices => Any_Text, Whole => True));

   ------------
   -- Quoted --
   ------------

   function Quoted (Item : String) return String is
      Hex  : constant String := "0123456789abcdef";
      Said : Unbounded_String := To_Unbounded_String ("""");
   begin
      for C of Item loop
         case C is
            when '"'      => Append (Said, "\""");
            when '\'      => Append (Said, "\\");
            when ASCII.LF => Append (Said, "\n");
            when ASCII.CR => Append (Said, "\r");
            when ASCII.HT => Append (Said, "\t");
            when ASCII.NUL .. ASCII.BS | ASCII.VT | ASCII.FF | ASCII.SO .. ASCII.US =>
               Append (Said, "\u00" & Hex (Hex'First + Character'Pos (C) / 16)
                             & Hex (Hex'First + Character'Pos (C) mod 16));
            when others   => Append (Said, C);
         end case;
      end loop;
      Append (Said, """");
      return To_String (Said);
   end Quoted;

   ----------------
   -- Definition --
   ----------------

   function Definition
     (Name        : String;
      Description : String;
      Parameters  : Parameter_List) return String
   is
      Properties : Unbounded_String;
      Required   : Unbounded_String;
   begin
      for One of Parameters loop
         declare
            Choices : Unbounded_String;
         begin
            for Choice of One.Choices loop
               Append (Choices, (if Length (Choices) = 0 then "" else ", ") & Quoted (Choice));
            end loop;
            Append (Properties,
                    (if Length (Properties) = 0 then "" else ", ")
                    & Quoted (To_String (One.Name))
                    & (if One.Whole then ": {""type"": ""integer""" else ": {""type"": ""string""")
                    & (if One.Choices.Is_Empty then ""
                       else ", ""enum"": [" & To_String (Choices) & "]")
                    & "}");
            if One.Required then
               Append (Required,
                       (if Length (Required) = 0 then "" else ", ") & Quoted (To_String (One.Name)));
            end if;
         end;
      end loop;
      return "{""type"": ""function"", ""function"": {""name"": " & Quoted (Name)
        & ", ""description"": " & Quoted (Description)
        & ", ""parameters"": {""type"": ""object"", ""properties"": {"
        & To_String (Properties) & "}"
        & (if Length (Required) = 0 then "" else ", ""required"": [" & To_String (Required) & "]")
        & "}}}";
   end Definition;

end Model_Runner.Tools.Schemas;
