with Ada.Strings.Unbounded;

package body Model_Runner.Tools.Registry is

   package Sc renames Model_Runner.Tools.Schemas;
   package U renames Ada.Strings.Unbounded;

   --  A tool: its name, what it needs, and whether it is offered or only
   --  run when called by name.
   type Word is access constant String;
   type Entry_Of is record
      Name    : Word;
      Needs   : Capability;
      Offered : Boolean;
   end record;

   function W (Text : String) return Word is (new String'(Text));

   Table : constant array (Positive range <>) of Entry_Of :=
     [(W ("calculator"), Facts, True), (W ("string_length"), Facts, True),
      (W ("reverse_text"), Facts, True), (W ("lookup"), Facts, True),
      (W ("base64_encode"), Text, True), (W ("base64_decode"), Text, True),
      (W ("now"), Clock, True),
      (W ("memory_put"), Memory, True), (W ("memory_get"), Memory, True),
      (W ("read_file"), Read_Files, True), (W ("list_directory"), Read_Files, True),
      (W ("find"), Read_Files, True),
      (W ("edit_file"), Write_Files, True), (W ("write_file"), Write_Files, True),
      (W ("run_checks"), Project_Checks, True),
      (W ("retrieve"), Retrieval, True),
      (W ("shell"), Run_Programs, True), (W ("run_python"), Run_Programs, True),
      (W ("sql"), Run_Programs, True),
      (W ("http_get"), Network, True), (W ("web_search"), Network, True),
      (W ("delegate"), Delegation, True), (W ("ask_user"), Ask_User, True),
      --  Run by name, not offered: what read_file and find took over.
      (W ("read_range"), Read_Files, False), (W ("search_file"), Read_Files, False),
      (W ("search_code"), Read_Files, False),
      (W ("find_symbol"), Project_Graph, False), (W ("find_references"), Project_Graph, False),
      (W ("dependencies"), Project_Graph, False), (W ("dependents"), Project_Graph, False),
      (W ("impact"), Project_Graph, False)];

   function Place (Named : String) return Natural is
   begin
      for Index in Table'Range loop
         if Table (Index).Name.all = Named then
            return Index;
         end if;
      end loop;
      return 0;
   end Place;

   -----------
   -- Known --
   -----------

   function Known (Named : String) return Boolean is (Place (Named) > 0);

   -----------
   -- Needs --
   -----------

   function Needs (Named : String) return Capability is (Table (Place (Named)).Needs);

   ------------
   -- Allows --
   ------------

   function Allows (Can : Capabilities; Named : String) return Boolean is
     (Known (Named) and then Can (Needs (Named)));

   -------------
   -- Kind_Of --
   -------------

   function Kind_Of (Named : String) return Runner.Call_Kind is
     (if Named = "now" then Runner.Varies
      elsif Named in "calculator" | "string_length" | "reverse_text" | "lookup" | "base64_encode"
                   | "base64_decode" | "memory_get" | "read_file" | "list_directory" | "find"
                   | "read_range" | "search_file" | "search_code" | "find_symbol" | "find_references"
                   | "dependencies" | "dependents" | "impact" | "http_get" | "web_search" | "retrieve"
                   | "ask_user" | "run_checks"
      then Runner.Reads
      else Runner.Changes);

   --  One tool's definition, as the capabilities shape it.
   function Definition
     (Named : String;
      Can   : Capabilities;
      Roles : Sc.Choice_Lists.Vector) return String
   is
   begin
      if Named = "calculator" then
         return Sc.Definition
           ("calculator", "Evaluate a binary arithmetic operation on two integers.",
            [Sc.Whole_Number ("a"), Sc.Text ("op", Choices => ["+", "-", "*", "/"]), Sc.Whole_Number ("b")]);
      elsif Named = "string_length" then
         return Sc.Definition ("string_length", "Return the number of characters in a string.", [Sc.Text ("text")]);
      elsif Named = "reverse_text" then
         return Sc.Definition ("reverse_text", "Return a string with its characters reversed.", [Sc.Text ("text")]);
      elsif Named = "lookup" then
         return Sc.Definition
           ("lookup", "Look up a fact by its key.",
            [Sc.Text ("key", Choices => ["capital_of_france", "speed_of_light", "ada_year"])]);
      elsif Named = "base64_encode" then
         return Sc.Definition ("base64_encode", "Encode a string as base64.", [Sc.Text ("text")]);
      elsif Named = "base64_decode" then
         return Sc.Definition ("base64_decode", "Decode a base64 string.", [Sc.Text ("text")]);
      elsif Named = "now" then
         return Sc.Definition ("now", "Return the current local date and time.", Sc.No_Parameters);
      elsif Named = "memory_put" then
         return Sc.Definition ("memory_put", "Remember a value under a key for later.",
                               [Sc.Text ("key"), Sc.Text ("value")]);
      elsif Named = "memory_get" then
         return Sc.Definition ("memory_get", "Recall the value remembered under a key.", [Sc.Text ("key")]);
      elsif Named = "read_file" then
         return Sc.Definition
           ("read_file", "Read a text file -- whole, or lines first_line to last_line of it, numbered --"
            & " and its revision after it.",
            [Sc.Text ("path"), Sc.Whole_Number ("first_line", Required => False),
             Sc.Whole_Number ("last_line", Required => False)]);
      elsif Named = "list_directory" then
         return Sc.Definition ("list_directory", "List the entries of a directory.", [Sc.Text ("path")]);
      elsif Named = "find" then
         declare
            Kinds : Sc.Choice_Lists.Vector;
         begin
            Kinds.Append ("text");
            if Can (Project_Graph) then
               for One of Sc.Choice_Lists.Vector'(["symbol", "references", "uses", "used_by", "impact"]) loop
                  Kinds.Append (One);
               end loop;
            end if;
            return Sc.Definition
              ("find",
               "Find, by kind: text -- the lines holding query in path, a file or a folder (the whole"
               & " tree when not given)"
               & (if Can (Project_Graph)
                  then "; symbol -- where a name is declared; references -- where it is used; uses --"
                       & " what a unit or a file's unit uses; used_by -- what uses it; impact -- what"
                       & " changing a file or a name reaches"
                  else "")
               & ".",
               [Sc.Text ("kind", Choices => Kinds), Sc.Text ("query"), Sc.Text ("path", Required => False)]);
         end;
      elsif Named = "edit_file" then
         return Sc.Definition
           ("edit_file",
            "Replace one exact passage of a file with new text -- the way to change part of a file"
            & " without writing it all out. old_text must be in the file exactly once, as it is now;"
            & " give revision, from read_file, to be refused if the file changed since you read it.",
            [Sc.Text ("path"), Sc.Text ("old_text"), Sc.Text ("new_text"), Sc.Text ("revision", Required => False)]);
      elsif Named = "write_file" then
         return Sc.Definition
           ("write_file", "Write a new file, or one rewritten whole -- edit_file changes part of one.",
            [Sc.Text ("path"), Sc.Text ("content")]);
      elsif Named = "run_checks" then
         return Sc.Definition
           ("run_checks",
            "Build and test the project as the task will be verified, and get back whether it passes and,"
            & " if not, what the failing checks reported. scope affected checks only what your changes"
            & " so far reach -- quicker while you work; full, the default, everything the task is held to.",
            [Sc.Text ("scope", Required => False, Choices => ["affected", "full"])]);
      elsif Named = "retrieve" then
         return Sc.Definition
           ("retrieve", "Search a folder of text files for the passages most relevant to a query, ranked.",
            [Sc.Text ("folder"), Sc.Text ("query")]);
      elsif Named = "shell" then
         return Sc.Definition ("shell", "Run a shell command and return its output.", [Sc.Text ("command")]);
      elsif Named = "run_python" then
         return Sc.Definition ("run_python", "Run Python 3 source and return its output.", [Sc.Text ("code")]);
      elsif Named = "sql" then
         return Sc.Definition ("sql", "Run a query against a SQLite database file.",
                               [Sc.Text ("database"), Sc.Text ("query")]);
      elsif Named = "http_get" then
         return Sc.Definition ("http_get", "Fetch a URL over HTTP and return the body.", [Sc.Text ("url")]);
      elsif Named = "web_search" then
         return Sc.Definition ("web_search", "Search the web and return the results page.", [Sc.Text ("query")]);
      elsif Named = "delegate" then
         return Sc.Definition
           ("delegate",
            "Hand one part of the work -- a review, an investigation, a piece to write -- to a helper that"
            & " starts with no memory of this conversation and reports back only its result. Say"
            & " everything it needs in task. role names what it is for"
            & (if Roles.Is_Empty then "" else ", and gives it that role's permissions")
            & "; need is required (the default), optional or advisory. inputs names the files it starts"
            & " from, outputs the files it must write -- checked after -- and acceptance when the part"
            & " is done.",
            [Sc.Text ("task"), Sc.Text ("role", Required => False, Choices => Roles),
             Sc.Text ("need", Required => False, Choices => ["required", "optional", "advisory"]),
             Sc.Text ("inputs", Required => False), Sc.Text ("outputs", Required => False),
             Sc.Text ("acceptance", Required => False)]);
      elsif Named = "ask_user" then
         return Sc.Definition
           ("ask_user",
            "Ask the user a question and get back what they type. Use it when the task is ambiguous, a"
            & " choice is the user's to make, or you need something only the user knows -- not for what"
            & " a tool or your own reasoning can settle.",
            [Sc.Text ("question")]);
      end if;
      return "";
   end Definition;

   -------------
   -- Offered --
   -------------

   function Offered
     (Can   : Capabilities;
      Roles : Sc.Choice_Lists.Vector := Sc.Choice_Lists.Empty_Vector) return String
   is
      Said : U.Unbounded_String;
   begin
      for One of Table loop
         if One.Offered and then Can (One.Needs) then
            U.Append (Said, (if U.Length (Said) = 0 then "" else ", ") & Definition (One.Name.all, Can, Roles));
         end if;
      end loop;
      return "[" & U.To_String (Said) & "]";
   end Offered;

end Model_Runner.Tools.Registry;
