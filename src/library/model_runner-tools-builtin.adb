with Ada.Calendar.Formatting;
with Ada.Directories;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Model_Runner.UTF8;

package body Model_Runner.Tools.Builtin is

   package E renames Model_Runner.Errors;
   package U renames Ada.Strings.Unbounded;

   --  The most a tool answers with, leaving room under the call buffer for
   --  a truncation note.
   Cap : constant := Model_Runner.Tools.Max_Call_Bytes - 64;

   ---------------------------------------------------------------------------
   --  Definitions
   --
   --  Two objects share the four pure tools' text: the pure set the eval
   --  offers, and the full set the command line offers. Written once so a
   --  tool cannot be described in one place and not the other.
   ---------------------------------------------------------------------------

   Pure_Body : constant String :=
     "{""type"": ""function"", ""function"": {"
     & """name"": ""calculator"", "
     & """description"": ""Evaluate a binary arithmetic operation on two "
     & "integers."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """a"": {""type"": ""integer""}, "
     & """op"": {""type"": ""string"", ""enum"": [""+"", ""-"", ""*"", "
     & """/""]}, "
     & """b"": {""type"": ""integer""}}, "
     & """required"": [""a"", ""op"", ""b""]}}}, "
     & "{""type"": ""function"", ""function"": {"
     & """name"": ""string_length"", "
     & """description"": ""Return the number of characters in a string."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """text"": {""type"": ""string""}}, "
     & """required"": [""text""]}}}, "
     & "{""type"": ""function"", ""function"": {"
     & """name"": ""reverse_text"", "
     & """description"": ""Return a string with its characters reversed."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """text"": {""type"": ""string""}}, "
     & """required"": [""text""]}}}, "
     & "{""type"": ""function"", ""function"": {"
     & """name"": ""lookup"", "
     & """description"": ""Look up a fact by its key."", "
     & """parameters"": {""type"": ""object"", ""properties"": {"
     & """key"": {""type"": ""string"", ""enum"": ["
     & """capital_of_france"", ""speed_of_light"", ""ada_year""]}}, "
     & """required"": [""key""]}}}";

   --  Shorthands for the many one- and two-string parameter schemas below.
   function Str1 (Name : String) return String
   is ("{""type"": ""object"", ""properties"": {"
       & """" & Name & """: {""type"": ""string""}}, "
       & """required"": [""" & Name & """]}");

   function Str2 (A, B : String) return String
   is ("{""type"": ""object"", ""properties"": {"
       & """" & A & """: {""type"": ""string""}, "
       & """" & B & """: {""type"": ""string""}}, "
       & """required"": [""" & A & """, """ & B & """]}");

   function Tool (Name, Description, Parameters : String) return String
   is ("{""type"": ""function"", ""function"": {""name"": """ & Name
       & """, ""description"": """ & Description
       & """, ""parameters"": " & Parameters & "}}");

   More_Body : constant String :=
     Tool ("base64_encode", "Encode a string as base64.", Str1 ("text"))
     & ", "
     & Tool ("base64_decode", "Decode a base64 string.", Str1 ("text"))
     & ", "
     & Tool ("now", "Return the current local date and time.",
             "{""type"": ""object"", ""properties"": {}}")
     & ", "
     & Tool ("memory_put", "Remember a value under a key for later.",
             Str2 ("key", "value"))
     & ", "
     & Tool ("memory_get", "Recall the value remembered under a key.",
             Str1 ("key"))
     & ", "
     & Tool ("read_file", "Read a text file and return its contents.",
             Str1 ("path"))
     & ", "
     & Tool ("write_file", "Write text to a file, replacing it.",
             Str2 ("path", "content"))
     & ", "
     & Tool ("list_directory", "List the entries of a directory.",
             Str1 ("path"))
     & ", "
     & Tool ("shell", "Run a shell command and return its output.",
             Str1 ("command"))
     & ", "
     & Tool ("run_python", "Run Python 3 source and return its output.",
             Str1 ("code"))
     & ", "
     & Tool ("http_get", "Fetch a URL over HTTP and return the body.",
             Str1 ("url"))
     & ", "
     & Tool ("web_search", "Search the web and return the results page.",
             Str1 ("query"))
     & ", "
     & Tool ("sql", "Run a query against a SQLite database file.",
             Str2 ("database", "query"));

   Definitions     : constant String := "[" & Pure_Body & "]";
   All_Definitions : constant String := "[" & Pure_Body & ", " & More_Body
                                        & "]";

   function Definitions_Text return String is (Definitions);
   function All_Definitions_Text return String is (All_Definitions);

   ---------------------------------------------------------------------------
   --  Reading arguments (a walk over the top level of one JSON object)
   ---------------------------------------------------------------------------

   function After_String (Text : String; Index : Positive) return Positive is
      I : Natural := Index + 1;
   begin
      while I <= Text'Last loop
         if Text (I) = '\' then
            I := I + 2;
         elsif Text (I) = '"' then
            return I + 1;
         else
            I := I + 1;
         end if;
      end loop;
      return Text'Last + 1;
   end After_String;

   function String_Content (Text : String; Index : Positive) return String is
      Room : String (1 .. Text'Length);
      Used : Natural := 0;
      I    : Natural := Index + 1;

      procedure Put (C : Character) is
      begin
         Used := Used + 1;
         Room (Used) := C;
      end Put;
   begin
      while I <= Text'Last and then Text (I) /= '"' loop
         if Text (I) = '\' and then I < Text'Last then
            case Text (I + 1) is
               when 'n'    => Put (ASCII.LF);
               when 't'    => Put (ASCII.HT);
               when 'r'    => Put (ASCII.CR);
               when 'b'    => Put (ASCII.BS);
               when 'f'    => Put (ASCII.FF);
               when others => Put (Text (I + 1));
            end case;
            I := I + 2;
         else
            Put (Text (I));
            I := I + 1;
         end if;
      end loop;
      return Room (1 .. Used);
   end String_Content;

   procedure Locate
     (Args  : String;
      Key   : String;
      First : out Natural;
      Last  : out Natural;
      Found : out Boolean)
   is
      I     : Natural := Args'First;
      Depth : Natural := 0;
   begin
      First := 0;
      Last  := 0;
      Found := False;

      while I <= Args'Last and then Args (I) /= '{' loop
         I := I + 1;
      end loop;
      if I > Args'Last then
         return;
      end if;
      I := I + 1;

      loop
         while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
           | ASCII.LF | ASCII.CR
         loop
            I := I + 1;
         end loop;
         exit when I > Args'Last or else Args (I) = '}';

         if Args (I) /= '"' then
            return;
         end if;

         declare
            Key_First : constant Positive := I;
            Key_After : constant Positive := After_String (Args, I);
            This_Key  : constant String :=
              String_Content (Args, Key_First);
         begin
            I := Key_After;
            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last or else Args (I) /= ':';
            I := I + 1;
            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last;

            declare
               Value_First : constant Positive := I;
            begin
               case Args (I) is
                  when '"' =>
                     I := After_String (Args, I);
                  when '{' | '[' =>
                     Depth := 1;
                     I := I + 1;
                     while I <= Args'Last and then Depth > 0 loop
                        case Args (I) is
                           when '"'       => I := After_String (Args, I);
                           when '{' | '[' => Depth := Depth + 1; I := I + 1;
                           when '}' | ']' => Depth := Depth - 1; I := I + 1;
                           when others    => I := I + 1;
                        end case;
                     end loop;
                  when others =>
                     while I <= Args'Last
                       and then Args (I) not in ',' | '}' | ']'
                       | ' ' | ASCII.HT | ASCII.LF | ASCII.CR
                     loop
                        I := I + 1;
                     end loop;
               end case;

               if This_Key = Key then
                  First := Value_First;
                  Last  := I - 1;
                  Found := True;
                  return;
               end if;
            end;

            while I <= Args'Last and then Args (I) in ' ' | ASCII.HT
              | ASCII.LF | ASCII.CR
            loop
               I := I + 1;
            end loop;
            exit when I > Args'Last or else Args (I) /= ',';
            I := I + 1;
         end;
      end loop;
   end Locate;

   --  A string argument's decoded content, unbounded so a tool need not size
   --  a buffer for it.
   function Text_Argument (Args : String; Key : String; Found : out Boolean)
     return String
   is
      From, To : Natural;
      Present  : Boolean;
   begin
      Found := False;
      Locate (Args, Key, From, To, Present);
      if not Present or else To < From or else Args (From) /= '"' then
         return "";
      end if;
      Found := True;
      return String_Content (Args, From);
   end Text_Argument;

   procedure Integer_Argument
     (Args  : String;
      Key   : String;
      Value : out Long_Long_Integer;
      Found : out Boolean)
   is
      From, To : Natural;
      Present  : Boolean;
   begin
      Value := 0;
      Found := False;
      Locate (Args, Key, From, To, Present);
      if not Present or else To < From then
         return;
      end if;

      declare
         Raw  : String renames Args (From .. To);
         Sign : Long_Long_Integer := 1;
         Acc  : Long_Long_Integer := 0;
         I    : Natural := Raw'First;
         Seen : Boolean := False;
      begin
         if I <= Raw'Last and then Raw (I) = '-' then
            Sign := -1;
            I := I + 1;
         end if;
         while I <= Raw'Last and then Raw (I) in '0' .. '9' loop
            Acc := Acc * 10
              + Long_Long_Integer
                  (Character'Pos (Raw (I)) - Character'Pos ('0'));
            Seen := True;
            I := I + 1;
         end loop;
         if Seen and then I > Raw'Last then
            Value := Sign * Acc;
            Found := True;
         end if;
      end;
   end Integer_Argument;

   function Image (Value : Long_Long_Integer) return String is
      Raw : constant String := Long_Long_Integer'Image (Value);
   begin
      if Raw (Raw'First) = ' ' then
         return Raw (Raw'First + 1 .. Raw'Last);
      else
         return Raw;
      end if;
   end Image;

   --  Cut an answer to what the call buffer holds, noting where it was cut.
   function Capped (Text : String) return String is
   begin
      if Text'Length <= Cap then
         return Text;
      end if;
      return Text (Text'First .. Text'First + Cap - 1) & " ...(truncated)";
   end Capped;

   ---------------------------------------------------------------------------
   --  The pure tools
   ---------------------------------------------------------------------------

   function Calculator (Args : String) return String is
      A, B : Long_Long_Integer;
      Found_A, Found_B, Found_Op : Boolean;
      Op : constant String := Text_Argument (Args, "op", Found_Op);
   begin
      Integer_Argument (Args, "a", A, Found_A);
      Integer_Argument (Args, "b", B, Found_B);
      if not (Found_A and then Found_B and then Found_Op) then
         return "error: calculator needs integers a and b and an op";
      end if;
      if Op = "+" then
         return Image (A + B);
      elsif Op = "-" then
         return Image (A - B);
      elsif Op = "*" then
         return Image (A * B);
      elsif Op = "/" then
         if B = 0 then
            return "error: division by zero";
         else
            return Image (A / B);
         end if;
      else
         return "error: op must be one of + - * /";
      end if;
   end Calculator;

   function String_Length (Args : String) return String is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);
   begin
      if not Have then
         return "error: string_length needs a string text";
      end if;
      return Image
        (Long_Long_Integer (Model_Runner.UTF8.Code_Point_Count (Text)));
   end String_Length;

   function Reverse_Text (Args : String) return String is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);
   begin
      if not Have then
         return "error: reverse_text needs a string text";
      end if;
      declare
         Output : String (1 .. Text'Length);
         Fill   : Natural := Output'Last;
         I      : Natural := Text'First;
         Point  : Natural;
         Width  : Natural;
      begin
         while I <= Text'Last loop
            Model_Runner.UTF8.Decode_First
              (Text (I .. Text'Last), Point, Width);
            exit when Width = 0;
            Output (Fill - Width + 1 .. Fill) := Text (I .. I + Width - 1);
            Fill := Fill - Width;
            I := I + Width;
         end loop;
         return Output;
      end;
   end Reverse_Text;

   function Lookup (Args : String) return String is
      Have : Boolean;
      Key  : constant String := Text_Argument (Args, "key", Have);
   begin
      if not Have then
         return "error: lookup needs a string key";
      elsif Key = "capital_of_france" then
         return "Paris";
      elsif Key = "speed_of_light" then
         return "299792458 metres per second";
      elsif Key = "ada_year" then
         return "1983";
      else
         return "error: no fact by that key";
      end if;
   end Lookup;

   --  Base64, the standard alphabet with = padding.
   Alphabet : constant String :=
     "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

   function Base64_Encode (Args : String) return String is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);
   begin
      if not Have then
         return "error: base64_encode needs a string text";
      end if;
      declare
         Out_S : U.Unbounded_String;
         I     : Natural := Text'First;
         function Byte (K : Natural) return Natural
         is (Character'Pos (Text (K)));
      begin
         while I <= Text'Last loop
            declare
               B0 : constant Natural := Byte (I);
               Have1 : constant Boolean := I + 1 <= Text'Last;
               Have2 : constant Boolean := I + 2 <= Text'Last;
               B1 : constant Natural := (if Have1 then Byte (I + 1) else 0);
               B2 : constant Natural := (if Have2 then Byte (I + 2) else 0);
            begin
               U.Append (Out_S, Alphabet (Alphabet'First + B0 / 4));
               U.Append
                 (Out_S,
                  Alphabet (Alphabet'First + (B0 mod 4) * 16 + B1 / 16));
               U.Append
                 (Out_S,
                  (if Have1
                   then Alphabet
                          (Alphabet'First + (B1 mod 16) * 4 + B2 / 64)
                   else '='));
               U.Append
                 (Out_S,
                  (if Have2 then Alphabet (Alphabet'First + B2 mod 64)
                   else '='));
            end;
            I := I + 3;
         end loop;
         return Capped (U.To_String (Out_S));
      end;
   end Base64_Encode;

   function Base64_Decode (Args : String) return String is
      Have : Boolean;
      Text : constant String := Text_Argument (Args, "text", Have);

      function Value_Of (C : Character) return Integer is
      begin
         for K in Alphabet'Range loop
            if Alphabet (K) = C then
               return K - Alphabet'First;
            end if;
         end loop;
         return -1;
      end Value_Of;
   begin
      if not Have then
         return "error: base64_decode needs a string text";
      end if;
      declare
         Out_S : U.Unbounded_String;
         Bits  : Natural := 0;
         Acc   : Natural := 0;
      begin
         for C of Text loop
            exit when C = '=';
            if C not in ' ' | ASCII.LF | ASCII.CR | ASCII.HT then
               declare
                  V : constant Integer := Value_Of (C);
               begin
                  if V < 0 then
                     return "error: not valid base64";
                  end if;
                  Acc := Acc * 64 + V;
                  Bits := Bits + 6;
                  if Bits >= 8 then
                     Bits := Bits - 8;
                     U.Append
                       (Out_S, Character'Val ((Acc / (2 ** Bits)) mod 256));
                  end if;
               end;
            end if;
         end loop;
         return Capped (U.To_String (Out_S));
      end;
   end Base64_Decode;

   function Now_Text return String is
   begin
      return Ada.Calendar.Formatting.Image (Ada.Calendar.Clock);
   end Now_Text;

   function Memory_Put (Self : in out Instance; Args : String) return String is
      Have_K, Have_V : Boolean;
      Key   : constant String := Text_Argument (Args, "key", Have_K);
      Value : constant String := Text_Argument (Args, "value", Have_V);
   begin
      if not (Have_K and then Have_V) then
         return "error: memory_put needs a key and a value";
      end if;
      for I in 1 .. Self.Used loop
         if U.To_String (Self.Memory (I).Key) = Key then
            Self.Memory (I).Value := U.To_Unbounded_String (Value);
            return "ok";
         end if;
      end loop;
      if Self.Used >= Max_Notes then
         return "error: memory is full";
      end if;
      Self.Used := Self.Used + 1;
      Self.Memory (Self.Used) :=
        (Key => U.To_Unbounded_String (Key),
         Value => U.To_Unbounded_String (Value));
      return "ok";
   end Memory_Put;

   function Memory_Get (Self : in out Instance; Args : String) return String is
      Have : Boolean;
      Key  : constant String := Text_Argument (Args, "key", Have);
   begin
      if not Have then
         return "error: memory_get needs a key";
      end if;
      for I in 1 .. Self.Used loop
         if U.To_String (Self.Memory (I).Key) = Key then
            return U.To_String (Self.Memory (I).Value);
         end if;
      end loop;
      return "error: nothing remembered under that key";
   end Memory_Get;

   ---------------------------------------------------------------------------
   --  The tools that reach the world
   ---------------------------------------------------------------------------

   --  Read a file into a string, no more than the call buffer holds.
   function Read_Capped (Path : String) return String is
      File  : Ada.Text_IO.File_Type;
      Out_S : U.Unbounded_String;
      First : Boolean := True;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File)
        and then U.Length (Out_S) <= Cap
      loop
         if not First then
            U.Append (Out_S, ASCII.LF);
         end if;
         U.Append (Out_S, Ada.Text_IO.Get_Line (File));
         First := False;
      end loop;
      Ada.Text_IO.Close (File);
      return Capped (U.To_String (Out_S));
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "error: could not read the file";
   end Read_Capped;

   --  Run a program, capturing its output (and its errors), and free the
   --  argument list. A program that is not installed is said so plainly.
   function Capture
     (Program : String; Args : GNAT.OS_Lib.Argument_List) return String
   is
      use type GNAT.OS_Lib.String_Access;
      Prog : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path (Program);
      Path : GNAT.OS_Lib.String_Access;
      FD   : GNAT.OS_Lib.File_Descriptor;
      Ran  : Boolean := False;
      Code : Integer := -1;

      procedure Release is
      begin
         for A of Args loop
            declare
               Item : GNAT.OS_Lib.String_Access := A;
            begin
               GNAT.OS_Lib.Free (Item);
            end;
         end loop;
         GNAT.OS_Lib.Free (Prog);
      end Release;
   begin
      if Prog = null then
         Release;
         return "error: '" & Program & "' is not installed on this machine";
      end if;

      GNAT.OS_Lib.Create_Temp_File (FD, Path);
      GNAT.OS_Lib.Close (FD);
      GNAT.OS_Lib.Spawn (Prog.all, Args, Path.all, Ran, Code,
                         Err_To_Out => True);

      declare
         Output : constant String := Read_Capped (Path.all);
         Gone   : Boolean;
      begin
         GNAT.OS_Lib.Delete_File (Path.all, Gone);
         GNAT.OS_Lib.Free (Path);
         Release;
         if not Ran then
            return "error: could not run '" & Program & "'";
         elsif Output = "" then
            return "(the command produced no output; exit code"
              & Integer'Image (Code) & ")";
         else
            return Output;
         end if;
      end;
   end Capture;

   function Read_File (Args : String) return String is
      Have : Boolean;
      Path : constant String := Text_Argument (Args, "path", Have);
   begin
      if not Have then
         return "error: read_file needs a path";
      elsif not Ada.Directories.Exists (Path) then
         return "error: no file at that path";
      end if;
      return Read_Capped (Path);
   end Read_File;

   function Write_File (Args : String) return String is
      Have_P, Have_C : Boolean;
      Path    : constant String := Text_Argument (Args, "path", Have_P);
      Content : constant String := Text_Argument (Args, "content", Have_C);
      File    : Ada.Text_IO.File_Type;
   begin
      if not (Have_P and then Have_C) then
         return "error: write_file needs a path and content";
      end if;
      Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Path);
      Ada.Text_IO.Put (File, Content);
      Ada.Text_IO.Close (File);
      return "wrote" & Natural'Image (Content'Length) & " bytes to " & Path;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         return "error: could not write the file";
   end Write_File;

   function List_Directory (Args : String) return String is
      Have : Boolean;
      Path : constant String := Text_Argument (Args, "path", Have);
      Out_S : U.Unbounded_String;
      Search : Ada.Directories.Search_Type;
      Item   : Ada.Directories.Directory_Entry_Type;
   begin
      if not Have then
         return "error: list_directory needs a path";
      elsif not Ada.Directories.Exists (Path) then
         return "error: no directory at that path";
      end if;
      Ada.Directories.Start_Search (Search, Path, "");
      while Ada.Directories.More_Entries (Search)
        and then U.Length (Out_S) <= Cap
      loop
         Ada.Directories.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Ada.Directories.Simple_Name (Item);
         begin
            if Name /= "." and then Name /= ".." then
               if U.Length (Out_S) > 0 then
                  U.Append (Out_S, ASCII.LF);
               end if;
               U.Append (Out_S, Name);
            end if;
         end;
      end loop;
      Ada.Directories.End_Search (Search);
      return Capped (U.To_String (Out_S));
   exception
      when others =>
         return "error: could not list the directory";
   end List_Directory;

   function Shell (Args : String) return String is
      Have : Boolean;
      Cmd  : constant String := Text_Argument (Args, "command", Have);
   begin
      if not Have then
         return "error: shell needs a command";
      end if;
      return Capture ("sh", [new String'("-c"), new String'(Cmd)]);
   end Shell;

   function Run_Python (Args : String) return String is
      Have : Boolean;
      Code : constant String := Text_Argument (Args, "code", Have);
   begin
      if not Have then
         return "error: run_python needs code";
      end if;
      return Capture ("python3", [new String'("-c"), new String'(Code)]);
   end Run_Python;

   function Http_Get (Args : String) return String is
      Have : Boolean;
      Url  : constant String := Text_Argument (Args, "url", Have);
   begin
      if not Have then
         return "error: http_get needs a url";
      end if;
      return Capture
        ("curl", [new String'("-fsSL"), new String'(Url)]);
   end Http_Get;

   function Web_Search (Args : String) return String is
      Have  : Boolean;
      Query : constant String := Text_Argument (Args, "query", Have);
   begin
      if not Have then
         return "error: web_search needs a query";
      end if;
      --  curl encodes the query, so a space or a symbol in it is safe.
      return Capture
        ("curl",
         [new String'("-fsSL"),
          new String'("--data-urlencode"),
          new String'("q=" & Query),
          new String'("https://lite.duckduckgo.com/lite/")]);
   end Web_Search;

   function Sql (Args : String) return String is
      Have_D, Have_Q : Boolean;
      Database : constant String := Text_Argument (Args, "database", Have_D);
      Query    : constant String := Text_Argument (Args, "query", Have_Q);
   begin
      if not (Have_D and then Have_Q) then
         return "error: sql needs a database and a query";
      end if;
      return Capture
        ("sqlite3", [new String'(Database), new String'(Query)]);
   end Sql;

   ---------
   -- Run --
   ---------

   overriding procedure Run
     (Self      : in out Instance;
      Named     : String;
      Arguments : String;
      Result    : out String;
      Last      : out Natural;
      Status    : out Model_Runner.Errors.Error_Info)
   is
      function Answer return String is
      begin
         if Named = "calculator" then
            return Calculator (Arguments);
         elsif Named = "string_length" then
            return String_Length (Arguments);
         elsif Named = "reverse_text" then
            return Reverse_Text (Arguments);
         elsif Named = "lookup" then
            return Lookup (Arguments);
         elsif Named = "base64_encode" then
            return Base64_Encode (Arguments);
         elsif Named = "base64_decode" then
            return Base64_Decode (Arguments);
         elsif Named = "now" then
            return Now_Text;
         elsif Named = "memory_put" then
            return Memory_Put (Self, Arguments);
         elsif Named = "memory_get" then
            return Memory_Get (Self, Arguments);
         elsif Named = "read_file" then
            return Read_File (Arguments);
         elsif Named = "write_file" then
            return Write_File (Arguments);
         elsif Named = "list_directory" then
            return List_Directory (Arguments);
         elsif Named = "shell" then
            return Shell (Arguments);
         elsif Named = "run_python" then
            return Run_Python (Arguments);
         elsif Named = "http_get" then
            return Http_Get (Arguments);
         elsif Named = "web_search" then
            return Web_Search (Arguments);
         elsif Named = "sql" then
            return Sql (Arguments);
         else
            return "error: no tool by the name """ & Named & """";
         end if;
      end Answer;

      Text : constant String := Answer;
   begin
      Last   := 0;
      Status := E.Success;
      if Text'Length > Result'Length then
         Status := E.Make (E.Tools_Too_Large);
         return;
      end if;
      Result (Result'First .. Result'First + Text'Length - 1) := Text;
      Last := Result'First + Text'Length - 1;
   end Run;

end Model_Runner.Tools.Builtin;
