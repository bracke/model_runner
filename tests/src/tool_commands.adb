package body Tool_Commands is

   Name_Test           : aliased constant String := "test";
   Name_Check          : aliased constant String := "check";
   Name_Conformance    : aliased constant String := "conformance";
   Name_Fuzz           : aliased constant String := "fuzz";
   Name_Speed          : aliased constant String := "speed";
   Name_Benchmark      : aliased constant String := "benchmark";
   Name_External       : aliased constant String := "external-model";
   Name_Tokenize       : aliased constant String := "tokenize";
   Name_Docs           : aliased constant String := "docs";
   Name_Shader         : aliased constant String := "shader";
   Name_Fixtures       : aliased constant String := "fixtures";
   Name_Package        : aliased constant String := "package";
   Name_Pristine       : aliased constant String := "pristine";
   Name_Schema         : aliased constant String := "schema";

   Nothing : aliased constant String := "";

   Opts_None      : aliased constant String := " ";
   Opts_Check     : aliased constant String := " --repository --record-warnings ";
   Opts_Fuzz      : aliased constant String := " --seed --cases ";
   Opts_Speed     : aliased constant String :=
     " --model --prompt-file --max-tokens --threads --batch-size --repack"
     & " --backend --repeat-penalty --draft-model --draft-tokens --repeats"
     & " --anyway ";
   Opts_Benchmark : aliased constant String := " --seconds --rounds --anyway ";
   Opts_External  : aliased constant String :=
     " --model --prompt --max-tokens --threads --expect --repack --backend"
     & " --draft-model --draft-tokens ";
   Opts_Tokenize  : aliased constant String := " --model --prompt ";

   Takes_Check     : aliased constant String := "[ROOT] [--repository] [--record-warnings]";
   Takes_Fuzz      : aliased constant String := "[--seed N] [--cases N]";
   Takes_Speed     : aliased constant String :=
     "--model PATH [--prompt-file PATH] [--max-tokens N] [--threads N]"
     & " [--batch-size N] [--repack MODE] [--backend NAME]"
     & " [--repeat-penalty X] [--draft-model PATH] [--draft-tokens N]"
     & " [--repeats N] [--anyway]";
   Takes_Benchmark : aliased constant String := "[--seconds N] [--rounds N] [--anyway]";
   Takes_External  : aliased constant String :=
     "--model PATH [--prompt TEXT] [--max-tokens N] [--threads N]"
     & " [--expect TEXT] [--repack MODE] [--backend NAME]"
     & " [--draft-model PATH] [--draft-tokens N]";
   Takes_Tokenize  : aliased constant String := "--model PATH --prompt TEXT";
   Takes_Docs      : aliased constant String := "[ROOT]";
   Takes_Shader    : aliased constant String :=
     "SOURCE.comp COMPILED.spv [ROOT]";
   Takes_Fixtures  : aliased constant String := "[DIR]";
   Takes_Package   : aliased constant String := "[ROOT] [INTO]";
   Takes_Pristine  : aliased constant String := "[ROOT]";
   Takes_Schema    : aliased constant String := "SCHEMA";

   Says_Test : aliased constant String :=
     "run the mandatory suite";
   Says_Check : aliased constant String :=
     "the gate: suite, repository checks, conformance and a short fuzzing"
     & " campaign";
   Says_Conformance : aliased constant String :=
     "compare the engine against the independent reference transformer";
   Says_Fuzz : aliased constant String :=
     "throw malformed containers at the reader";
   Says_Speed : aliased constant String :=
     "take the published speed figures again, on a model you have";
   Says_Benchmark : aliased constant String :=
     "measure the kernels; medians of three rounds, best of three "
     & "for device ratios";
   Says_External : aliased constant String :=
     "validate a model you already have, and say what it produced";
   Says_Tokenize : aliased constant String :=
     "tokenize text with a model's own vocabulary";
   Says_Docs : aliased constant String :=
     "regenerate the documentation derived from the Ada registries";
   Says_Shader : aliased constant String :=
     "turn a compiled shader into the Ada constant the engine hands a device";
   Says_Fixtures : aliased constant String :=
     "write the committed test fixtures";
   Says_Package : aliased constant String :=
     "assemble the distributable archive from what is already built";
   Says_Schema : aliased constant String :=
     "write the grammar a JSON schema becomes";
   Says_Pristine : aliased constant String :=
     "clone what git carries, build it, and run the suite and checks there";

   Held : constant array (1 .. 14) of Command :=
     [(Name_Test'Access, Nothing'Access, Says_Test'Access,
       Opts_None'Access),
      (Name_Check'Access, Takes_Check'Access, Says_Check'Access,
       Opts_Check'Access),
      (Name_Conformance'Access, Nothing'Access, Says_Conformance'Access,
       Opts_None'Access),
      (Name_Fuzz'Access, Takes_Fuzz'Access, Says_Fuzz'Access,
       Opts_Fuzz'Access),
      (Name_Speed'Access, Takes_Speed'Access, Says_Speed'Access,
       Opts_Speed'Access),
      (Name_Benchmark'Access, Takes_Benchmark'Access, Says_Benchmark'Access,
       Opts_Benchmark'Access),
      (Name_External'Access, Takes_External'Access, Says_External'Access,
       Opts_External'Access),
      (Name_Tokenize'Access, Takes_Tokenize'Access, Says_Tokenize'Access,
       Opts_Tokenize'Access),
      (Name_Docs'Access, Takes_Docs'Access, Says_Docs'Access,
       Opts_None'Access),
      (Name_Shader'Access, Takes_Shader'Access, Says_Shader'Access,
       Opts_None'Access),
      (Name_Fixtures'Access, Takes_Fixtures'Access, Says_Fixtures'Access,
       Opts_None'Access),
      (Name_Package'Access, Takes_Package'Access, Says_Package'Access,
       Opts_None'Access),
      (Name_Pristine'Access, Takes_Pristine'Access, Says_Pristine'Access,
       Opts_None'Access),
      (Name_Schema'Access, Takes_Schema'Access, Says_Schema'Access,
       Opts_None'Access)];

   -----------
   -- Count --
   -----------

   function Count return Natural is (Held'Length);

   ----------
   -- Item --
   ----------

   function Item (Index : Positive) return Command is (Held (Index));

   ----------------
   -- Options_Of --
   ----------------

   function Options_Of (Name : String) return String is
   begin
      for Index in Held'Range loop
         if Held (Index).Name.all = Name then
            return Held (Index).Options.all;
         end if;
      end loop;
      return " ";
   end Options_Of;

   ----------------
   -- Usage_Line --
   ----------------

   function Usage_Line return String is
      Room : String (1 .. 1024) := [others => ' '];
      Used : Natural := 0;

      procedure Add (Value : String) is
      begin
         if Used + Value'Length <= Room'Length then
            Room (Used + 1 .. Used + Value'Length) := Value;
            Used := Used + Value'Length;
         end if;
      end Add;
   begin
      Add ("usage: tests <command>");
      for Index in Held'Range loop
         Add (Character'Val (10) & "  " & Held (Index).Name.all);

         --  The name is padded to a column so the summaries line up, which
         --  is what makes a list of eleven readable rather than a wall.
         for Filler in Held (Index).Name.all'Length .. 14 loop
            Add (" ");
         end loop;

         Add (Held (Index).Summary.all);

         if Held (Index).Takes.all /= "" then
            Add (Character'Val (10) & "                 "
                 & Held (Index).Takes.all);
         end if;
      end loop;
      return Room (1 .. Used);
   end Usage_Line;

end Tool_Commands;
