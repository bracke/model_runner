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
   Name_Fixtures       : aliased constant String := "fixtures";
   Name_Package        : aliased constant String := "package";

   Nothing : aliased constant String := "";

   Takes_Check     : aliased constant String := "[ROOT]";
   Takes_Fuzz      : aliased constant String := "[--seed N] [--cases N]";
   Takes_Speed     : aliased constant String :=
     "--model PATH [--prompt-file PATH] [--max-tokens N] [--threads N]"
     & " [--batch-size N] [--repeats N]";
   Takes_Benchmark : aliased constant String := "[--seconds N] [--rounds N]";
   Takes_External  : aliased constant String :=
     "--model PATH [--prompt TEXT] [--max-tokens N] [--threads N]"
     & " [--expect TEXT]";
   Takes_Tokenize  : aliased constant String := "--model PATH --text TEXT";
   Takes_Docs      : aliased constant String := "[ROOT]";
   Takes_Fixtures  : aliased constant String := "[DIR]";
   Takes_Package   : aliased constant String := "[ROOT] [INTO]";

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
     "measure the kernels, medians of three rounds";
   Says_External : aliased constant String :=
     "validate a model you already have, and say what it produced";
   Says_Tokenize : aliased constant String :=
     "tokenize text with a model's own vocabulary";
   Says_Docs : aliased constant String :=
     "regenerate the documentation derived from the Ada registries";
   Says_Fixtures : aliased constant String :=
     "write the committed test fixtures";
   Says_Package : aliased constant String :=
     "assemble the distributable archive from what is already built";

   Held : constant array (1 .. 11) of Command :=
     [(Name_Test'Access, Nothing'Access, Says_Test'Access),
      (Name_Check'Access, Takes_Check'Access, Says_Check'Access),
      (Name_Conformance'Access, Nothing'Access, Says_Conformance'Access),
      (Name_Fuzz'Access, Takes_Fuzz'Access, Says_Fuzz'Access),
      (Name_Speed'Access, Takes_Speed'Access, Says_Speed'Access),
      (Name_Benchmark'Access, Takes_Benchmark'Access, Says_Benchmark'Access),
      (Name_External'Access, Takes_External'Access, Says_External'Access),
      (Name_Tokenize'Access, Takes_Tokenize'Access, Says_Tokenize'Access),
      (Name_Docs'Access, Takes_Docs'Access, Says_Docs'Access),
      (Name_Fixtures'Access, Takes_Fixtures'Access, Says_Fixtures'Access),
      (Name_Package'Access, Takes_Package'Access, Says_Package'Access)];

   -----------
   -- Count --
   -----------

   function Count return Natural is (Held'Length);

   ----------
   -- Item --
   ----------

   function Item (Index : Positive) return Command is (Held (Index));

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
