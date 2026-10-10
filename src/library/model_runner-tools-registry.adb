with Ada.Strings.Unbounded;

package body Model_Runner.Tools.Registry is

   package Sc renames Model_Runner.Tools.Schemas;
   package U renames Ada.Strings.Unbounded;

   --  A tool, described once: its name, what it needs, whether it is
   --  offered or only run when called by name, what its call does to the
   --  state later calls read and which state that is, whether it may run
   --  beside the other calls of a turn, and what it does with a path.
   type Word is access constant String;
   type Entry_Of is record
      Name     : Word;
      Needs    : Capability;
      Offered  : Boolean;
      Effect   : Runner.Call_Kind;
      Touches  : Runner.Resource;
      Parallel : Boolean;
      Path     : Path_Use;

      --  What a model is told of it, built once from Tools.Schemas; null
      --  for a tool whose offer the environment shapes (Shaped_Definition)
      --  or one run by name and not offered.
      Text     : Word;
   end record;

   function W (Text : String) return Word is (new String'(Text));

   use Runner;

   Table : constant array (Positive range <>) of Entry_Of :=
     [(W ("calculator"), Facts, True, Reads, Pure, True, No_Path,
       W (Sc.Definition
         ("calculator", "Evaluate a binary arithmetic operation on two integers.",
            [Sc.Whole_Number ("a"), Sc.Text ("op", Choices => ["+", "-", "*", "/"]), Sc.Whole_Number ("b")]))),
      (W ("string_length"), Facts, True, Reads, Pure, True, No_Path,
       W (Sc.Definition
         ("string_length", "Return the number of characters in a string.", [Sc.Text ("text")]))),
      (W ("reverse_text"), Facts, True, Reads, Pure, True, No_Path,
       W (Sc.Definition
         ("reverse_text", "Return a string with its characters reversed.", [Sc.Text ("text")]))),
      (W ("lookup"), Facts, True, Reads, Pure, True, No_Path,
       W (Sc.Definition
         ("lookup", "Look up a fact by its key.",
            [Sc.Text ("key", Choices => ["capital_of_france", "speed_of_light", "ada_year"])]))),
      (W ("base64_encode"), Text, True, Reads, Pure, True, No_Path,
       W (Sc.Definition
         ("base64_encode", "Encode a string as base64.", [Sc.Text ("text")]))),
      (W ("base64_decode"), Text, True, Reads, Pure, True, No_Path,
       W (Sc.Definition
         ("base64_decode", "Decode a base64 string.", [Sc.Text ("text")]))),
      --  The clock answers anew each time.
      (W ("now"), Clock, True, Varies, Pure, True, No_Path,
       W (Sc.Definition
         ("now", "Return the current local date and time.", Sc.No_Parameters))),
      (W ("memory_put"), Memory, True, Changes, Agent_Memory, False, No_Path,
       W (Sc.Definition
         ("memory_put", "Remember a value under a key for later.",
                               [Sc.Text ("key"), Sc.Text ("value")]))),
      (W ("memory_get"), Memory, True, Reads, Agent_Memory, False, No_Path,
       W (Sc.Definition
         ("memory_get", "Recall the value remembered under a key.", [Sc.Text ("key")]))),
      (W ("read_file"), Read_Files, True, Reads, Files, True, Reads_Path,
       W (Sc.Definition
         ("read_file", "Read a text file -- whole, or lines first_line to last_line of it, numbered --"
            & " and its revision after it.",
            [Sc.Text ("path"), Sc.Whole_Number ("first_line", Required => False),
             Sc.Whole_Number ("last_line", Required => False)]))),
      (W ("list_directory"), Read_Files, True, Reads, Files, True, Reads_Path,
       W (Sc.Definition
         ("list_directory", "List the entries of a directory.", [Sc.Text ("path")]))),
      (W ("find"), Read_Files, True, Reads, Files, True, Reads_Path, null),
      (W ("edit_file"), Write_Files, True, Changes, Files, False, Writes_Path,
       W (Sc.Definition
         ("edit_file",
            "Replace one exact passage of a file with new text -- the way to change part of a file"
            & " without writing it all out. old_text must be in the file exactly once, as it is now;"
            & " give revision, from read_file, to be refused if the file changed since you read it.",
            [Sc.Text ("path"), Sc.Text ("old_text"), Sc.Text ("new_text"), Sc.Text ("revision", Required => False)]))),
      (W ("write_file"), Write_Files, True, Changes, Files, False, Writes_Path,
       W (Sc.Definition
         ("write_file", "Write a new file, or one rewritten whole -- edit_file changes part of one.",
            [Sc.Text ("path"), Sc.Text ("content")]))),
      --  The checks read the tree as it stands; their processes do not
      --  overlap, since waiting reaps whichever child ended.
      (W ("run_checks"), Project_Checks, True, Reads, Files, False, No_Path,
       W (Sc.Definition
         ("run_checks",
            "Build and test the project as the task will be verified, and get back whether it passes and,"
            & " if not, what the failing checks reported. scope affected checks only what your changes"
            & " so far reach -- quicker while you work; full, the default, everything the task is held to.",
            [Sc.Text ("scope", Required => False, Choices => ["affected", "full"])]))),
      --  Overlaps only without an embedding model: the runner says.
      (W ("retrieve"), Retrieval, True, Reads, Files, True, No_Path,
       W (Sc.Definition
         ("retrieve", "Search a folder of text files for the passages most relevant to a query, ranked.",
            [Sc.Text ("folder"), Sc.Text ("query")]))),
      (W ("shell"), Run_Programs, True, Changes, Anything, False, No_Path,
       W (Sc.Definition
         ("shell", "Run a shell command and return its output.", [Sc.Text ("command")]))),
      (W ("run_python"), Run_Programs, True, Changes, Anything, False, No_Path,
       W (Sc.Definition
         ("run_python", "Run Python 3 source and return its output.", [Sc.Text ("code")]))),
      (W ("sql"), Run_Programs, True, Changes, Anything, False, No_Path,
       W (Sc.Definition
         ("sql", "Run a query against a SQLite database file.",
                               [Sc.Text ("database"), Sc.Text ("query")]))),
      --  The world outside changes without a call here changing it.
      (W ("http_get"), Network, True, Varies, Pure, True, No_Path,
       W (Sc.Definition
         ("http_get", "Fetch a URL over HTTP and return the body.", [Sc.Text ("url")]))),
      (W ("web_search"), Network, True, Varies, Pure, True, No_Path,
       W (Sc.Definition
         ("web_search", "Search the web and return the results page.", [Sc.Text ("query")]))),
      --  A helper may write anything; it overlaps where its delegator can
      --  run two at once, which the runner says.
      (W ("delegate"), Delegation, True, Changes, Anything, True, No_Path, null),
      --  Somebody may answer the same question differently.
      (W ("ask_user"), Ask_User, True, Varies, Pure, False, No_Path,
       W (Sc.Definition
         ("ask_user",
            "Ask the user a question and get back what they type. Use it when the task is ambiguous, a"
            & " choice is the user's to make, or you need something only the user knows -- not for what"
            & " a tool or your own reasoning can settle.",
            [Sc.Text ("question")]))),
      --  Run by name, not offered: what read_file and find took over.
      (W ("read_range"), Read_Files, False, Reads, Files, True, Reads_Path, null),
      (W ("search_file"), Read_Files, False, Reads, Files, True, Reads_Path, null),
      (W ("search_code"), Read_Files, False, Reads, Files, True, Reads_Path, null),
      (W ("find_symbol"), Project_Graph, False, Reads, Files, False, No_Path, null),
      (W ("find_references"), Project_Graph, False, Reads, Files, False, No_Path, null),
      (W ("dependencies"), Project_Graph, False, Reads, Files, False, No_Path, null),
      (W ("dependents"), Project_Graph, False, Reads, Files, False, No_Path, null),
      (W ("impact"), Project_Graph, False, Reads, Files, False, No_Path, null)];

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
   -- Count --
   -----------

   function Count return Positive is (Table'Length);

   -------------
   -- Name_At --
   -------------

   function Name_At (Index : Positive) return String is (Table (Table'First + Index - 1).Name.all);

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

   function Kind_Of (Named : String) return Runner.Call_Kind
   is (if Known (Named) then Table (Place (Named)).Effect else Runner.Changes);

   -------------
   -- Touches --
   -------------

   function Touches (Named : String) return Runner.Resource
   is (if Known (Named) then Table (Place (Named)).Touches else Runner.Anything);

   --------------
   -- Parallel --
   --------------

   function Parallel (Named : String) return Boolean
   is (Known (Named) and then Table (Place (Named)).Parallel);

   -------------
   -- Path_Of --
   -------------

   function Path_Of (Named : String) return Path_Use
   is (if Known (Named) then Table (Place (Named)).Path else No_Path);

   --  The definition of a tool whose offer the environment shapes: find,
   --  by whether the project's graph is there, and delegate, by the roles
   --  a helper may be given. Every other tool's is fixed, in its row.
   function Shaped_Definition
     (Named : String;
      Can   : Capabilities;
      Roles : Sc.Choice_Lists.Vector) return String
   is
   begin
      if Named = "find" then
         declare
            Kinds : Sc.Choice_Lists.Vector;
         begin
            Kinds.Append ("text");
            if Can (Project_Graph) then
               for One of Sc.Choice_Lists.Vector'(["symbol", "references", "depends_on", "used_by", "impact"]) loop
                  Kinds.Append (One);
               end loop;
            end if;
            return Sc.Definition
              ("find",
               "Find, by kind: text -- the lines holding query in path, a file or a folder (the whole"
               & " tree when not given)"
               & (if Can (Project_Graph)
                  then "; symbol -- where a name is declared; references -- where it is used; depends_on --"
                       & " the units a unit or a file's unit depends on; used_by -- the units that use"
                       & " it; impact -- what"
                       & " changing a file or a name reaches"
                  else "")
               & ".",
               [Sc.Text ("kind", Choices => Kinds), Sc.Text ("query"), Sc.Text ("path", Required => False)]);
         end;
      elsif Named = "delegate" then
         return Sc.Definition
           ("delegate",
            "Hand one part of the work -- a review, an investigation, a piece to write -- to a helper that"
            & " starts with no memory of this conversation and reports back only its result. Say"
            & " everything it needs in task. role names what it is for"
            & (if Roles.Is_Empty then "" else ", and gives it that role's permissions")
            & "; need is required (the default), optional or advisory. inputs lists the paths of the"
            & " files it starts from, outputs the paths of the files it must write -- checked after --"
            & " and acceptance says when the part is done.",
            [Sc.Text ("task"), Sc.Text ("role", Required => False, Choices => Roles),
             Sc.Text ("need", Required => False, Choices => ["required", "optional", "advisory"]),
             Sc.Text_List ("inputs", Required => False), Sc.Text_List ("outputs", Required => False),
             Sc.Text ("acceptance", Required => False)]);
      end if;
      return "";
   end Shaped_Definition;

   -------------------
   -- Offered_Names --
   -------------------

   function Offered_Names (Can : Capabilities) return String is
      Said : U.Unbounded_String;
   begin
      for One of Table loop
         if One.Offered and then Can (One.Needs) then
            U.Append (Said, (if U.Length (Said) = 0 then "" else ", ") & One.Name.all);
         end if;
      end loop;
      return U.To_String (Said);
   end Offered_Names;

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
            U.Append (Said, (if U.Length (Said) = 0 then "" else ", ")
                      & (if One.Text /= null then One.Text.all else Shaped_Definition (One.Name.all, Can, Roles)));
         end if;
      end loop;
      return "[" & U.To_String (Said) & "]";
   end Offered;

end Model_Runner.Tools.Registry;
