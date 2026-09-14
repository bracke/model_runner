with AUnit.Assertions; use AUnit.Assertions;

with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;

with Zlib;

with Model_Runner.Errors;
with Model_Runner.Grammar;
with Model_Runner.Tools;
with Model_Runner.UTF8;
with Model_Runner.Tools.Builtin;
with Model_Runner.Tools.Constraint;

package body Tests.Tools_Cases is

   package E renames Model_Runner.Errors;
   package G renames Model_Runner.Grammar;
   package Tools renames Model_Runner.Tools;
   package Builtin renames Model_Runner.Tools.Builtin;
   package Constraint renames Model_Runner.Tools.Constraint;

   overriding function Name (T : Case_Type) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("built-in tools and the call grammar");
   end Name;

   --  Run one built-in call and return its answer.
   function Answer (Named, Arguments : String) return String is
      Runner : Builtin.Instance;
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      Runner.Run (Named, Arguments, Room, Last, Status);
      Assert (E.Is_Ok (Status),
              "a built-in tool would not answer: "
              & E.Error_Code'Image (Status.Code));
      return Room (1 .. Last);
   end Answer;

   --  Whether the call grammar, compiled from the built-in tools, accepts a
   --  text whole and calls it complete.
   function Grammar_Takes (Text : String) return Boolean is
      Defs   : Tools.Definitions;
      Rules  : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Held   : Boolean;
   begin
      Tools.Read (Defs, Builtin.Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the built-in definitions would not read");

      Constraint.Compile_Call_Grammar (Defs, Rules, Status);
      Assert (E.Is_Ok (Status),
              "the call grammar would not compile: "
              & E.Error_Code'Image (Status.Code));
      Assert (G.Is_Ready (Rules), "the call grammar is not ready");

      G.Start (Rules, State, Status);
      Assert (E.Is_Ok (Status), "the call grammar would not start");

      G.Advance (Rules, State, Text, Status);
      if E.Is_Error (Status) then
         G.Close (Rules);
         Tools.Close (Defs);
         return False;
      end if;

      Held := G.Is_Complete (Rules, State);
      G.Close (Rules);
      Tools.Close (Defs);
      return Held;
   end Grammar_Takes;

   --  Whether the call grammar, compiled with an answer schema, accepts a
   --  text whole and calls it complete.
   function Grammar_Takes_Answer (Text, Schema : String) return Boolean is
      Defs   : Tools.Definitions;
      Rules  : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Held   : Boolean;
   begin
      Tools.Read (Defs, Builtin.Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the built-in definitions would not read");

      Constraint.Compile_Call_Grammar
        (Defs, Rules, Status, Answer_Schema => Schema);
      Assert (E.Is_Ok (Status),
              "the call grammar would not compile with an answer schema: "
              & E.Error_Code'Image (Status.Code));
      Assert (G.Is_Ready (Rules), "the answer-schema grammar is not ready");

      G.Start (Rules, State, Status);
      Assert (E.Is_Ok (Status), "the answer-schema grammar would not start");

      G.Advance (Rules, State, Text, Status);
      if E.Is_Error (Status) then
         G.Close (Rules);
         Tools.Close (Defs);
         return False;
      end if;

      Held := G.Is_Complete (Rules, State);
      G.Close (Rules);
      Tools.Close (Defs);
      return Held;
   end Grammar_Takes_Answer;

   --  With an answer schema, a reply is a tool call or an answer in that
   --  shape -- never free prose and never an answer of the wrong shape.
   procedure Answer_Schema_Shapes_The_Answer
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Schema : constant String :=
        "{""type"":""object"",""properties"":"
        & "{""answer"":{""type"":""integer""}},""required"":[""answer""]}";
   begin
      --  A well-formed call is still taken: the loop must still be able to
      --  reach a tool on the way to the answer.
      Assert
        (Grammar_Takes_Answer
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47,""op"":""*"",""b"":89}}</tool_call>", Schema),
         "a call was refused once an answer schema was set");
      --  An answer object in the schema's shape is taken whole.
      Assert
        (Grammar_Takes_Answer ("{""answer"":4183}", Schema),
         "a schema-valid answer was refused");
      --  Prose is no longer an answer.
      Assert
        (not Grammar_Takes_Answer ("The answer is 4183.", Schema),
         "prose was taken where a shaped answer was required");
      --  An answer of the wrong type is refused.
      Assert
        (not Grammar_Takes_Answer ("{""answer"":""x""}", Schema),
         "an answer whose type did not match the schema was taken");
      --  An answer missing the required field is refused.
      Assert
        (not Grammar_Takes_Answer ("{}", Schema),
         "an answer missing a required field was taken");
   end Answer_Schema_Shapes_The_Answer;

   --  Whether the grammar compiled from the whole built-in set accepts a
   --  text whole. The full set must build the tight grammar -- one that
   --  pins each tool's arguments -- and not fall back to the loose one.
   function Full_Set_Takes (Text : String) return Boolean is
      Defs   : Tools.Definitions;
      Rules  : G.Compiled;
      State  : G.Matcher;
      Status : E.Error_Info;
      Held   : Boolean;
   begin
      Tools.Read (Defs, Builtin.All_Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the full definitions would not read");
      Constraint.Compile_Call_Grammar (Defs, Rules, Status);
      Assert (E.Is_Ok (Status) and then G.Is_Ready (Rules),
              "the full-set call grammar would not compile");
      G.Start (Rules, State, Status);
      G.Advance (Rules, State, Text, Status);
      if E.Is_Error (Status) then
         G.Close (Rules);
         Tools.Close (Defs);
         return False;
      end if;
      Held := G.Is_Complete (Rules, State);
      G.Close (Rules);
      Tools.Close (Defs);
      return Held;
   end Full_Set_Takes;

   --  The whole built-in set -- all eighteen tools -- builds the tight
   --  grammar: a call names a tool and its arguments match that tool's
   --  schema. It must not outgrow the grammar and fall back to the loose
   --  form, which would leave arguments (and an answer schema) unconstrained.
   procedure Full_Set_Is_Tight
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  A well-formed calculator call is taken.
      Assert
        (Full_Set_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47,""op"":""*"",""b"":89}}</tool_call>"),
         "the full set refused a well-formed calculator call");
      --  A call missing required arguments is refused -- which only the
      --  tight grammar does; the loose one would take it.
      Assert
        (not Full_Set_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47}}</tool_call>"),
         "the full set took a calculator call missing arguments "
         & "(it fell back to the loose grammar)");
   end Full_Set_Is_Tight;

   --  Every built-in tool answers the same way every time.
   procedure Answers_Are_Fixed
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Answer ("calculator", "{""a"": 47, ""op"": ""*"", ""b"": 89}")
         = "4183",
         "the calculator did not multiply");
      Assert
        (Answer ("calculator", "{""a"": 10, ""op"": ""-"", ""b"": 4}")
         = "6",
         "the calculator did not subtract");
      Assert
        (Answer ("calculator", "{""a"": 5, ""op"": ""/"", ""b"": 0}")
         = "error: division by zero",
         "the calculator divided by zero");
      Assert
        (Answer ("string_length", "{""text"": ""hello""}") = "5",
         "string_length miscounted");
      Assert
        (Answer ("reverse_text", "{""text"": ""abc""}") = "cba",
         "reverse_text did not reverse");
      Assert
        (Answer ("lookup", "{""key"": ""capital_of_france""}") = "Paris",
         "lookup did not find the fact");
      Assert
        (Answer ("nonesuch", "{}")
           (1 .. 5) = "error",
         "an unknown tool was not reported as one");
   end Answers_Are_Fixed;

   --  The definitions read as the four tools they describe.
   procedure Definitions_Read
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Defs   : Tools.Definitions;
      Status : E.Error_Info;
   begin
      Tools.Read (Defs, Builtin.Definitions_Text, Status);
      Assert (E.Is_Ok (Status), "the built-in definitions would not read");
      Assert (Tools.Count (Defs) = 4, "the definitions are not four tools");
      Assert (Tools.Offers (Defs, "calculator"), "calculator is not offered");
      Assert (Tools.Offers (Defs, "lookup"), "lookup is not offered");
      Assert (not Tools.Offers (Defs, "danger"),
              "a tool nobody defined is offered");
      Tools.Close (Defs);

      --  The full set reads too, and offers the tools that reach the world.
      declare
         All_Defs : Tools.Definitions;
         Rules    : G.Compiled;
         G_Status : E.Error_Info;
      begin
         Tools.Read (All_Defs, Builtin.All_Definitions_Text, Status);
         Assert (E.Is_Ok (Status), "the full definitions would not read");
         Assert (Tools.Count (All_Defs) = 20,
                 "the full set is not twenty tools");
         Assert (Tools.Offers (All_Defs, "shell"), "shell is not offered");
         Assert (Tools.Offers (All_Defs, "http_get"),
                 "http_get is not offered");
         Assert (Tools.Offers (All_Defs, "memory_put"),
                 "memory_put is not offered");
         Assert (Tools.Offers (All_Defs, "retrieve"),
                 "retrieve is not offered");
         Assert (Tools.Offers (All_Defs, "delegate"),
                 "delegate is not offered");
         Assert (Tools.Offers (All_Defs, "ask_user"),
                 "ask_user is not offered");

         --  The grammar compiles over the full set (the tight form, which
         --  the rule bound is now wide enough to hold -- see Full_Set_Is_Tight).
         Constraint.Compile_Call_Grammar (All_Defs, Rules, G_Status);
         Assert (E.Is_Ok (G_Status) and then G.Is_Ready (Rules),
                 "the call grammar would not compile over the full set");
         G.Close (Rules);
         Tools.Close (All_Defs);
      end;
   end Definitions_Read;

   --  The stateless new pure tools answer the same way every time.
   procedure Pure_Additions
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Answer ("base64_encode", "{""text"":""hi""}") = "aGk=",
              "base64_encode is wrong");
      Assert (Answer ("base64_decode", "{""text"":""aGk=""}") = "hi",
              "base64_decode did not round-trip");
   end Pure_Additions;

   --  Memory keeps what one call wrote for a later call to read.
   procedure Memory_Round_Trips
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Runner : Builtin.Instance;
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      Runner.Run ("memory_put", "{""key"":""x"",""value"":""42""}",
                  Room, Last, Status);
      Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "ok",
              "memory_put did not accept the note");
      Runner.Run ("memory_get", "{""key"":""x""}", Room, Last, Status);
      Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "42",
              "memory_get did not recall what was put");
      Runner.Run ("memory_get", "{""key"":""nope""}", Room, Last, Status);
      Assert (Room (1 .. Last) (1 .. 5) = "error",
              "memory_get invented a value for an unknown key");
   end Memory_Round_Trips;

   --  With no delegator wired -- the state of a runner given none, and of a
   --  sub-agent's own runner -- delegate declines in words the model reads,
   --  rather than crashing or recursing, so the loop goes on.
   procedure Delegate_Declines_Undelegated
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Reply : constant String := Answer ("delegate", "{""task"":""do it""}");
   begin
      Assert (Reply'Length >= 5 and then Reply (Reply'First .. Reply'First + 4)
              = "error",
              "delegate with no delegator did not decline as an error");
   end Delegate_Declines_Undelegated;

   --  With no inquirer wired -- the state of a runner given none, as an eval
   --  or a sub-agent is -- ask_user declines rather than blocking on input no
   --  one will give, so the loop goes on.
   procedure Ask_User_Declines_Unwired
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Reply : constant String :=
        Answer ("ask_user", "{""question"":""which one?""}");
   begin
      Assert (Reply'Length >= 5 and then Reply (Reply'First .. Reply'First + 4)
              = "error",
              "ask_user with no inquirer did not decline as an error");
   end Ask_User_Declines_Unwired;

   --  A note written with a memory file behind it is there for a later run:
   --  a fresh runner pointed at the same file reads it back, value and all,
   --  a space in the value included (the store is length-prefixed, so no byte
   --  of a value is a delimiter).
   procedure Memory_Persists_To_A_File
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Dir    : constant String := "obj/memory_case";
      Store  : constant String := Dir & "/notes.mem";
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);

      --  One runner writes a note; the file now holds it.
      declare
         Writer : Builtin.Instance;
      begin
         Writer.Use_Memory_File (Store);
         Writer.Run
           ("memory_put", "{""key"":""greeting"",""value"":""hello world""}",
            Room, Last, Status);
         Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "ok",
                 "memory_put did not accept the note");
      end;

      --  A fresh runner, as a later run would be, reads it back.
      declare
         Reader : Builtin.Instance;
      begin
         Reader.Use_Memory_File (Store);
         Reader.Run ("memory_get", "{""key"":""greeting""}",
                     Room, Last, Status);
         Assert (E.Is_Ok (Status) and then Room (1 .. Last) = "hello world",
                 "memory_get did not read the persisted note back whole");
      end;

      Ada.Directories.Delete_Tree (Dir);
   end Memory_Persists_To_A_File;

   --  A result too big for the call buffer keeps its head and its tail, with
   --  the middle dropped and its size noted, rather than losing everything
   --  past the head. read_file over an oversized file shows it: the file's
   --  first bytes and last bytes both come back, inside the buffer.
   procedure Large_Result_Keeps_Head_And_Tail
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Dir    : constant String := "obj/cap_case";
      Path   : constant String := Dir & "/big.txt";
      Filler : constant String (1 .. 50_000) := [others => 'x'];
      Big    : constant String := "HEAD-MARKER-START" & Filler & "TAIL-MARKER-END";
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      --  Write the bytes exactly, so no trailing newline creeps onto the
      --  tail and the test can check the file's true last bytes.
      declare
         use Ada.Streams;
         F     : Stream_IO.File_Type;
         Block : Stream_Element_Array (1 .. Stream_Element_Offset (Big'Length));
      begin
         for I in Big'Range loop
            Block (Stream_Element_Offset (I - Big'First + 1)) :=
              Stream_Element (Character'Pos (Big (I)));
         end loop;
         Stream_IO.Create (F, Stream_IO.Out_File, Path);
         Stream_IO.Write (F, Block);
         Stream_IO.Close (F);
      end;

      declare
         Runner : Builtin.Instance;
      begin
         Runner.Run ("read_file", "{""path"":""" & Path & """}",
                     Room, Last, Status);
      end;
      Assert (E.Is_Ok (Status), "read_file would not answer");

      declare
         Result : constant String := Room (1 .. Last);
      begin
         Assert (Result'Length <= Tools.Max_Call_Bytes,
                 "the kept result does not fit the call buffer");
         Assert (Result'Length < Big'Length,
                 "an oversized result was not cut down at all");
         Assert (Result'Length >= 17
                 and then Result (Result'First .. Result'First + 16)
                   = "HEAD-MARKER-START",
                 "the head of the oversized result was lost");
         Assert (Result'Length >= 15
                 and then Result (Result'Last - 14 .. Result'Last)
                   = "TAIL-MARKER-END",
                 "the tail of the oversized result was lost");
      end;

      Ada.Directories.Delete_Tree (Dir);
   end Large_Result_Keeps_Head_And_Tail;

   --  The runner marks the tools that may overlap and the tools that may not:
   --  reads and network fetches and lexical retrieve overlap; a shared
   --  scratchpad, a waited-on process, a single session or the console do not.
   procedure Parallel_Safety_Is_Marked
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Runner : Builtin.Instance;
   begin
      Assert (Runner.Parallel_Safe ("http_get"),
              "http_get should be parallel-safe");
      Assert (Runner.Parallel_Safe ("web_search"),
              "web_search should be parallel-safe");
      Assert (Runner.Parallel_Safe ("read_file"),
              "read_file should be parallel-safe");
      Assert (Runner.Parallel_Safe ("calculator"),
              "calculator should be parallel-safe");
      Assert (Runner.Parallel_Safe ("retrieve"),
              "lexical retrieve (no embedder) should be parallel-safe");
      Assert (not Runner.Parallel_Safe ("shell"),
              "shell must not be parallel-safe (it waits on a process)");
      Assert (not Runner.Parallel_Safe ("run_python"),
              "run_python must not be parallel-safe");
      Assert (not Runner.Parallel_Safe ("sql"),
              "sql must not be parallel-safe");
      Assert (not Runner.Parallel_Safe ("memory_put"),
              "memory_put must not be parallel-safe (shared scratchpad)");
      Assert (not Runner.Parallel_Safe ("write_file"),
              "write_file must not be parallel-safe");
      Assert (not Runner.Parallel_Safe ("delegate"),
              "delegate must not be parallel-safe (one sub-session)");
      Assert (not Runner.Parallel_Safe ("ask_user"),
              "ask_user must not be parallel-safe (one console)");
   end Parallel_Safety_Is_Marked;

   --  The grammar takes a well-formed call to an offered tool, takes prose,
   --  and refuses a call to a tool nobody offered.
   procedure Grammar_Constrains
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
   begin
      --  A well-formed call whose arguments match the calculator's schema.
      --  The arguments are compact, which is what the schema grammar allows;
      --  whitespace is still fine in the envelope around them.
      Assert
        (Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47,""op"":""*"",""b"":89}}</tool_call>"),
         "the grammar refused a well-formed call to an offered tool");
      Assert
        (Grammar_Takes
           ("<tool_call>{""name"": ""lookup"", ""arguments"": "
            & "{""key"":""capital_of_france""}}</tool_call>"),
         "the grammar refused a well-formed lookup call");
      --  The same call spaced the way a model naturally writes it -- a space
      --  after each colon and comma -- is taken too: the schema grammar
      --  tolerates whitespace rather than forcing compact JSON.
      Assert
        (Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"": 47, ""op"": ""*"", ""b"": 89}}</tool_call>"),
         "the grammar refused a schema-valid call with natural spacing");
      Assert
        (Grammar_Takes ("The answer is 4183."),
         "the grammar refused plain prose");
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""danger"", ""arguments"": {}}"
            & "</tool_call>"),
         "the grammar took a call to a tool nobody offered");
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47</tool_call>"),
         "the grammar took a call whose arguments never closed");

      --  Arguments that do not match the named tool's schema are refused:
      --  the calculator requires a, op and b, so a call missing op and b is
      --  not a call the grammar allows.
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":47}}</tool_call>"),
         "the grammar took a calculator call missing required arguments");
      --  A string where the schema asks for an integer is refused too.
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""calculator"", ""arguments"": "
            & "{""a"":""x"",""op"":""*"",""b"":89}}</tool_call>"),
         "the grammar took a calculator call with a non-integer argument");
      --  And the lookup's key is one of a fixed set: another string is not
      --  a call the grammar allows.
      Assert
        (not Grammar_Takes
           ("<tool_call>{""name"": ""lookup"", ""arguments"": "
            & "{""key"":""nonesuch""}}</tool_call>"),
         "the grammar took a lookup call with a key outside its enum");
   end Grammar_Constrains;

   --  retrieve ranks a folder's passages against a query: the file that
   --  carries the query's words comes back first, and a query whose words
   --  are nowhere finds nothing. Deterministic, so it is scored here rather
   --  than left to a model.
   procedure Retrieve_Ranks_The_Folder
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Dir    : constant String := "obj/retrieve_case";
      Runner : Builtin.Instance;
      Room   : String (1 .. Tools.Max_Call_Bytes);
      Last   : Natural;
      Status : E.Error_Info;
      LF     : constant Character := ASCII.LF;

      --  A minimal PDF: a header, one uncompressed content stream showing a
      --  line of text, and a trailer. Enough for the extractor to find the
      --  stream, see the text block, and read the shown string.
      PDF    : constant String :=
        "%PDF-1.4" & LF
        & "1 0 obj" & LF
        & "<< /Length 51 >>" & LF
        & "stream" & LF
        & "BT /F1 12 Tf (neptune tides fill the document) Tj ET" & LF
        & "endstream" & LF
        & "endobj" & LF
        & "%%EOF" & LF;

      procedure Write_File (Name, Text : String) is
         F : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (F, Ada.Text_IO.Out_File, Dir & "/" & Name);
         Ada.Text_IO.Put_Line (F, Text);
         Ada.Text_IO.Close (F);
      end Write_File;

      --  Write exact bytes, for a file that carries binary (a compressed
      --  PDF stream) a line writer would mangle.
      procedure Write_Bytes (Name, Content : String) is
         use Ada.Streams;
         F   : Stream_IO.File_Type;
         Buf : Stream_Element_Array (1 .. Content'Length);
      begin
         for I in Content'Range loop
            Buf (Stream_Element_Offset (I - Content'First + 1)) :=
              Stream_Element (Character'Pos (Content (I)));
         end loop;
         Stream_IO.Create (F, Stream_IO.Out_File, Dir & "/" & Name);
         Stream_IO.Write (F, Buf);
         Stream_IO.Close (F);
      end Write_Bytes;

      --  A PDF whose content stream is FlateDecode-compressed, built by
      --  deflating the stream here so the extractor's inflate path is tried.
      function Compressed_PDF return String is
         use Zlib;
         Content : constant String :=
           "BT /F1 12 Tf (kraken lurks in the compressed deep) Tj ET";
         Raw     : Byte_Array (0 .. Content'Length - 1);
         Status  : Status_Code;
      begin
         for I in Raw'Range loop
            Raw (I) := Byte (Character'Pos (Content (Content'First + I)));
         end loop;
         declare
            Comp : constant Byte_Array := Deflate_Stored (Raw, Status);
            Bytes : String (1 .. Comp'Length);
         begin
            for I in Comp'Range loop
               Bytes (Bytes'First + (I - Comp'First)) :=
                 Character'Val (Integer (Comp (I)));
            end loop;
            return "%PDF-1.4" & LF
              & "1 0 obj" & LF
              & "<< /Filter /FlateDecode >>" & LF
              & "stream" & LF
              & Bytes & LF
              & "endstream" & LF
              & "endobj" & LF
              & "%%EOF" & LF;
         end;
      end Compressed_PDF;

      --  Little-endian fields for a hand-built ZIP.
      function LE16 (V : Natural) return String
      is (Character'Val (V mod 256) & Character'Val (V / 256 mod 256));
      function LE32 (V : Natural) return String
      is (LE16 (V mod 65536) & LE16 (V / 65536));

      --  A one-entry ZIP holding Entry_Name with Xml, deflate-compressed --
      --  the shape a .docx or .pptx has. CRC is left zero; the extractor
      --  reads the sizes and the data, not the checksum.
      function Zip_One (Entry_Name, Xml : String) return String is
         use Zlib;
         In_B   : Byte_Array (0 .. Xml'Length - 1);
         Status : Status_Code;
      begin
         for I in In_B'Range loop
            In_B (I) := Byte (Character'Pos (Xml (Xml'First + I)));
         end loop;
         declare
            Comp_B : constant Byte_Array :=
              Deflate_Raw (In_B, Status => Status);
            Comp   : String (1 .. Comp_B'Length);
            Nm     : constant Natural := Entry_Name'Length;
         begin
            for I in Comp_B'Range loop
               Comp (Comp'First + (I - Comp_B'First)) :=
                 Character'Val (Integer (Comp_B (I)));
            end loop;
            declare
               Local : constant String :=
                 "PK" & Character'Val (3) & Character'Val (4)
                 & LE16 (20) & LE16 (0) & LE16 (8) & LE16 (0) & LE16 (0)
                 & LE32 (0) & LE32 (Comp'Length) & LE32 (Xml'Length)
                 & LE16 (Nm) & LE16 (0) & Entry_Name & Comp;
               Central : constant String :=
                 "PK" & Character'Val (1) & Character'Val (2)
                 & LE16 (20) & LE16 (20) & LE16 (0) & LE16 (8) & LE16 (0)
                 & LE16 (0) & LE32 (0) & LE32 (Comp'Length) & LE32 (Xml'Length)
                 & LE16 (Nm) & LE16 (0) & LE16 (0) & LE16 (0) & LE16 (0)
                 & LE32 (0) & LE32 (0) & Entry_Name;
            begin
               return Local & Central
                 & "PK" & Character'Val (5) & Character'Val (6)
                 & LE16 (0) & LE16 (0) & LE16 (1) & LE16 (1)
                 & LE32 (Central'Length) & LE32 (Local'Length) & LE16 (0);
            end;
         end;
      end Zip_One;

      function Begins (Hay, Head : String) return Boolean
      is (Hay'Length >= Head'Length
          and then Hay (Hay'First .. Hay'First + Head'Length - 1) = Head);

      --  Each character followed by a zero byte -- UTF-16LE, as a .doc keeps
      --  Unicode text.
      function Utf16 (S : String) return String is
         R : String (1 .. S'Length * 2);
      begin
         for I in S'Range loop
            R (2 * (I - S'First) + 1) := S (I);
            R (2 * (I - S'First) + 2) := ASCII.NUL;
         end loop;
         return R;
      end Utf16;

      --  A legacy .doc: the OLE2 magic, then a single-byte run and a
      --  UTF-16LE run, the way real ones carry their text.
      Ole    : constant String :=
        Character'Val (16#D0#) & Character'Val (16#CF#)
        & Character'Val (16#11#) & Character'Val (16#E0#)
        & Character'Val (16#A1#) & Character'Val (16#B1#)
        & Character'Val (16#1A#) & Character'Val (16#E1#);
      Doc    : constant String :=
        Ole & ASCII.NUL & ASCII.NUL
        & "walrus legacy manuscript"
        & ASCII.NUL & ASCII.NUL
        & Utf16 ("moonlight equinox verse")
        & ASCII.NUL & ASCII.NUL;

      --  A legacy .xls: OLE2, like the .doc, with a run of cell text.
      Xls    : constant String :=
        Ole & ASCII.NUL & ASCII.NUL
        & "xlsledger quarterly figures"
        & ASCII.NUL & ASCII.NUL;

      --  An RTF document: a font table to skip, then the body text.
      Rtf    : constant String :=
        "{\rtf1\ansi {\fonttbl{\f0\froman Times;}} "
        & "\b0 salmontrout lighthouse manuscript\par }";

      --  An HTML page: tags around the text.
      Html   : constant String :=
        "<html><head><title>t</title></head><body>"
        & "<h1>peregrine beacon heading</h1>"
        & "<p>and some more prose</p></body></html>";
   begin
      if Ada.Directories.Exists (Dir) then
         Ada.Directories.Delete_Tree (Dir);
      end if;
      Ada.Directories.Create_Path (Dir);
      Write_File ("cats.txt", "Cats are small carnivorous mammals that purr.");
      Write_File
        ("dogs.txt",
         "Dogs are loyal domestic animals that bark and guard the home.");
      Write_File ("space.txt", "A planet orbits a star within a galaxy.");
      --  A file in a subdirectory, to prove the walk descends into it.
      Ada.Directories.Create_Path (Dir & "/notes");
      Write_File
        ("notes/ocean.txt",
         "The ocean is a vast body of saltwater covering most of the earth.");
      --  A binary file: a NUL byte among words found nowhere else. It must
      --  be skipped, so a query for those words finds nothing.
      Write_File
        ("blob.bin", "xyzzy" & Character'Val (0) & "hidden treasure trove");
      --  A PDF, whose text lives in a content stream, not in the source.
      Write_File ("paper.pdf", PDF);
      --  A PDF whose stream is compressed, to exercise the inflate path.
      Write_Bytes ("deep.pdf", Compressed_PDF);
      --  A .docx: a ZIP whose word/document.xml holds the text.
      Write_Bytes
        ("report.docx",
         Zip_One
           ("word/document.xml",
            "<w:document><w:body><w:p><w:r><w:t>kingfisher docx "
            & "paragraph</w:t></w:r></w:p></w:body></w:document>"));
      --  A legacy .doc, OLE2 with single-byte and UTF-16LE text runs.
      Write_Bytes ("old.doc", Doc);
      --  A legacy .xls (OLE2), an .rtf, and an .html.
      Write_Bytes ("book.xls", Xls);
      Write_File ("note.rtf", Rtf);
      Write_File ("page.html", Html);
      --  A file with a byte that is not valid UTF-8 (Latin-1 e-acute) among
      --  ASCII words -- what a PDF or a cut window can produce.
      Write_Bytes
        ("latin.txt",
         "kestrel" & Character'Val (16#E9#) & " headland manuscript");

      --  A query whose words are in the dogs file: it ranks first.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""loyal domestic guard "
         & "dogs""}",
         Room, Last, Status);
      Assert (E.Is_Ok (Status), "retrieve did not answer");
      Assert (Begins (Room (1 .. Last), "[dogs.txt]"),
              "retrieve did not rank the dogs passage first: "
              & Room (1 .. Last));

      --  A query whose words are in the nested file: retrieve descended into
      --  the subdirectory and labelled the passage with its path.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""vast saltwater ocean""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[notes/ocean.txt]"),
              "retrieve did not find the passage in the subdirectory: "
              & Room (1 .. Last));

      --  A query for words that live only inside the PDF's content stream:
      --  the extractor pulled them out of the compressed-format file, so the
      --  passage comes back labelled with the .pdf.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""neptune tides document""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[paper.pdf]"),
              "retrieve did not extract text from the PDF: "
              & Room (1 .. Last));

      --  Words that live only inside the compressed PDF's stream: the
      --  extractor inflated it and read them out.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""kraken compressed deep""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[deep.pdf]"),
              "retrieve did not inflate and extract the compressed PDF: "
              & Room (1 .. Last));

      --  Words that live only inside the .docx's XML part: the ZIP was read,
      --  the part inflated, and the tags stripped to the text.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""kingfisher docx""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[report.docx]"),
              "retrieve did not extract text from the .docx: "
              & Room (1 .. Last));

      --  The legacy .doc's single-byte run.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""walrus legacy manuscript""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[old.doc]"),
              "retrieve did not read the legacy .doc's text: "
              & Room (1 .. Last));

      --  And its UTF-16LE run.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""moonlight equinox verse""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[old.doc]"),
              "retrieve did not read the .doc's UTF-16 text: "
              & Room (1 .. Last));

      --  The legacy .xls (OLE2), read the same way as the .doc.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""xlsledger quarterly""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[book.xls]"),
              "retrieve did not read the legacy .xls: " & Room (1 .. Last));

      --  The RTF's body text, its font table skipped.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""salmontrout lighthouse""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[note.rtf]"),
              "retrieve did not read the .rtf's text: " & Room (1 .. Last));

      --  The HTML page's text, its tags stripped.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""peregrine beacon""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[page.html]"),
              "retrieve did not strip the .html tags: " & Room (1 .. Last));

      --  A passage with an invalid byte is found by its ASCII words, and
      --  what comes back is valid UTF-8 -- the byte scrubbed to a space, so
      --  the embedder and the model it is handed to both accept it.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""kestrel headland""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "[latin.txt]"),
              "retrieve did not find the Latin-1 file: " & Room (1 .. Last));
      Assert (Model_Runner.UTF8.Is_Valid (Room (1 .. Last)),
              "retrieve returned bytes that are not valid UTF-8");

      --  The binary file's words are searched for: it was skipped, so
      --  nothing matches even though the bytes are there.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""xyzzy hidden treasure""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "no passage"),
              "retrieve searched a binary file it should have skipped: "
              & Room (1 .. Last));

      --  A query whose words are in no file: nothing matches.
      Runner.Run
        ("retrieve",
         "{""folder"":""" & Dir & """,""query"":""xylophone zebra""}",
         Room, Last, Status);
      Assert (Begins (Room (1 .. Last), "no passage"),
              "retrieve found a match for words in no file: "
              & Room (1 .. Last));

      Ada.Directories.Delete_Tree (Dir);
   end Retrieve_Ranks_The_Folder;

   --  MiniCPM writes a call as a <function> element with a <param> per
   --  argument, not a <tool_call> JSON object. Read in that syntax, a call
   --  comes out the same shape as any other: a name and its arguments as one
   --  JSON object, each param value a JSON string, a CDATA wrapper removed.
   procedure Function_XML_Calls_Parse
     (T : in out AUnit.Test_Cases.Test_Case'Class)
   is
      pragma Unreferenced (T);
      Asked  : Tools.Calls;
      Status : E.Error_Info;
   begin
      --  One call, three params; the values become JSON strings.
      Tools.Read_Calls
        (Asked,
         "<function name=""calculator"">"
         & "<param name=""a"">47</param>"
         & "<param name=""op"">*</param>"
         & "<param name=""b"">89</param></function>",
         Status, Syntax => Tools.Function_XML);
      Assert (E.Is_Ok (Status), "the function-form call would not read");
      Assert (Tools.Count (Asked) = 1, "not one call");
      Assert (Tools.Called (Asked, 1) = "calculator",
              "wrong name: " & Tools.Called (Asked, 1));
      --  A numeric param value becomes a JSON number, so a typed tool gets a
      --  number; a non-numeric one (the op) stays a string.
      Assert (Tools.Arguments (Asked, 1)
              = "{""a"": 47, ""op"": ""*"", ""b"": 89}",
              "wrong arguments: " & Tools.Arguments (Asked, 1));
      Tools.Close (Asked);

      --  Two calls, and a CDATA value with a newline becomes an escaped
      --  JSON string.
      Tools.Read_Calls
        (Asked,
         "<function name=""first""><param name=""x"">1</param></function>"
         & "<function name=""note""><param name=""body"">"
         & "<![CDATA[a" & ASCII.LF & "b]]></param></function>",
         Status, Syntax => Tools.Function_XML);
      Assert (E.Is_Ok (Status), "the two function-form calls would not read");
      Assert (Tools.Count (Asked) = 2, "not two calls");
      Assert (Tools.Called (Asked, 2) = "note", "wrong second name");
      Assert (Tools.Arguments (Asked, 2) = "{""body"": ""a\nb""}",
              "CDATA value not read as an escaped JSON string: "
              & Tools.Arguments (Asked, 2));
      Tools.Close (Asked);

      --  The function form read as the JSON form finds nothing, and that is
      --  not an error: the syntaxes do not collide.
      Tools.Read_Calls
        (Asked, "<function name=""x""></function>", Status,
         Syntax => Tools.Tool_Call_JSON);
      Assert (E.Is_Ok (Status) and then Tools.Count (Asked) = 0,
              "the function form was mistaken for a tool_call");
      Tools.Close (Asked);
   end Function_XML_Calls_Parse;

   -------------------
   -- Register_Tests --
   -------------------

   overriding procedure Register_Tests (T : in out Case_Type) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Answers_Are_Fixed'Access,
         "every built-in tool answers the same way every time");
      Register_Routine
        (T, Definitions_Read'Access,
         "the built-in definitions read as the tools they describe");
      Register_Routine
        (T, Pure_Additions'Access,
         "the added pure tools answer the same way every time");
      Register_Routine
        (T, Memory_Round_Trips'Access,
         "memory keeps what one call wrote for a later call to read");
      Register_Routine
        (T, Function_XML_Calls_Parse'Access,
         "a MiniCPM function/param reply reads as calls with JSON arguments");
      Register_Routine
        (T, Delegate_Declines_Undelegated'Access,
         "delegate with no delegator declines rather than crashing or "
         & "recursing");
      Register_Routine
        (T, Ask_User_Declines_Unwired'Access,
         "ask_user with no inquirer declines rather than blocking on input");
      Register_Routine
        (T, Parallel_Safety_Is_Marked'Access,
         "the runner marks which tools may overlap and which may not");
      Register_Routine
        (T, Memory_Persists_To_A_File'Access,
         "a note written with a memory file behind it is read back by a "
         & "later runner");
      Register_Routine
        (T, Large_Result_Keeps_Head_And_Tail'Access,
         "a result too big for the buffer keeps its head and its tail, "
         & "not only its head");
      Register_Routine
        (T, Grammar_Constrains'Access,
         "the call grammar takes a readable call and prose and refuses the "
         & "rest");
      Register_Routine
        (T, Answer_Schema_Shapes_The_Answer'Access,
         "an answer schema makes the reply a call or an answer in that "
         & "shape, not prose");
      Register_Routine
        (T, Full_Set_Is_Tight'Access,
         "the whole built-in set builds the tight grammar, not the loose "
         & "fallback");
      Register_Routine
        (T, Retrieve_Ranks_The_Folder'Access,
         "retrieve ranks a folder tree's passages against a query, descends "
         & "into subfolders, and finds nothing for words in no file");
   end Register_Tests;

end Tests.Tools_Cases;
