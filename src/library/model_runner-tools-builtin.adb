with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with GNAT.OS_Lib;

with Http_Client.Clients;
with Http_Client.Errors;

with Model_Runner.Tools.DOC;
with Model_Runner.Tools.OOXML;
with Model_Runner.Tools.PDF;
with Model_Runner.Tools.RTF;
with Model_Runner.Tools.Text_Util;
with Model_Runner.UTF8;

package body Model_Runner.Tools.Builtin is

   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;
   package U renames Ada.Strings.Unbounded;

   use type N.Real;
   use type N.Element_Count;

   --  The most a tool answers with, leaving room under the call buffer for
   --  a truncation note.
   Cap : constant := Model_Runner.Tools.Max_Call_Bytes - 64;

   --  How long a spawned command -- a shell, python, curl, sqlite -- may run
   --  before it is stopped. A tool that hangs would hang the whole loop,
   --  which the agent's own wall-clock budget cannot cut short because it is
   --  only checked between steps, never inside a call. This is the bound
   --  inside the call.
   Tool_Timeout : constant Duration := 30.0;

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
     & Tool ("retrieve",
             "Search a folder of text files for the passages most relevant "
             & "to a query, ranked.",
             Str2 ("folder", "query"))
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
             Str2 ("database", "query"))
     & ", "
     & Tool ("delegate",
             "Hand a self-contained subtask to a fresh sub-agent that has "
             & "the same tools and a budget of its own, and get back only its "
             & "final answer. Use it to keep the detail of a large job out of "
             & "your own context: describe the whole subtask in one task "
             & "string, as the sub-agent starts with no memory of this "
             & "conversation.",
             Str1 ("task"));

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
   --  Whether a file looks binary rather than text: its first bytes carry a
   --  NUL, which text does not and most binary formats do. Cheap and bounded
   --  -- a couple of kilobytes -- and a file that will not open is called
   --  binary so retrieve leaves it alone. It keeps a folder's images, PDFs
   --  and archives out of a text search rather than turning them to noise.
   function Is_Binary (Path : String) return Boolean is
      use Ada.Streams;
      File : Stream_IO.File_Type;
      Buf  : Stream_Element_Array (1 .. 2048);
      Last : Stream_Element_Offset;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Path);
      Stream_IO.Read (File, Buf, Last);
      Stream_IO.Close (File);
      for I in 1 .. Last loop
         if Buf (I) = 0 then
            return True;
         end if;
      end loop;
      return False;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         return True;
   end Is_Binary;

   --  The most of a PDF's bytes read to pull text from -- a whole document,
   --  bounded so a huge file cannot fill memory.
   Doc_Bytes : constant := 4 * 1024 * 1024;

   --  Up to Limit of a file's raw bytes, as a String, or the empty string
   --  when it will not open. Unlike Read_Capped, this reads bytes as they
   --  are -- for a binary format like PDF, where a line reader would stop or
   --  mangle at the first NUL.
   function Read_Raw (Path : String; Limit : Positive) return String is
      use Ada.Streams;
      type Buffer is access Stream_Element_Array;
      procedure Free is new Ada.Unchecked_Deallocation (Stream_Element_Array,
                                                         Buffer);
      File : Stream_IO.File_Type;
      Buf  : Buffer := new Stream_Element_Array (1 .. Stream_Element_Offset (Limit));
      Last : Stream_Element_Offset := 0;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Path);
      Stream_IO.Read (File, Buf.all, Last);
      Stream_IO.Close (File);
      return Result : String (1 .. Natural (Last)) do
         for I in 1 .. Last loop
            Result (Natural (I)) := Character'Val (Integer (Buf (I)));
         end loop;
         Free (Buf);
      end return;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         Free (Buf);
         return "";
   end Read_Raw;

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
      use type GNAT.OS_Lib.Process_Id;
      Prog : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path (Program);
      Path : GNAT.OS_Lib.String_Access;
      FD   : GNAT.OS_Lib.File_Descriptor;

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

      function Seconds return String is
         Whole : constant Integer := Integer (Tool_Timeout);
         Raw   : constant String := Integer'Image (Whole);
      begin
         return Raw (Raw'First + 1 .. Raw'Last);
      end Seconds;
   begin
      if Prog = null then
         Release;
         return "error: '" & Program & "' is not installed on this machine";
      end if;

      GNAT.OS_Lib.Create_Temp_File (FD, Path);
      GNAT.OS_Lib.Close (FD);

      declare
         Pid : constant GNAT.OS_Lib.Process_Id :=
           GNAT.OS_Lib.Non_Blocking_Spawn
             (Prog.all, Args, Path.all, Err_To_Out => True);
         Gone : Boolean;
      begin
         if Pid = GNAT.OS_Lib.Invalid_Pid then
            GNAT.OS_Lib.Delete_File (Path.all, Gone);
            GNAT.OS_Lib.Free (Path);
            Release;
            return "error: could not run '" & Program & "'";
         end if;

         --  A watchdog that kills the child if it outlives the budget. The
         --  main path waits for the child -- which returns whether it exited
         --  on its own or was killed -- and then stops the watchdog, telling
         --  it whether it was the one that ended the child.
         declare
            task Watchdog is
               entry Stop (Killed : out Boolean);
            end Watchdog;

            task body Watchdog is
            begin
               select
                  accept Stop (Killed : out Boolean) do
                     Killed := False;
                  end Stop;
               or
                  delay Tool_Timeout;
                  GNAT.OS_Lib.Kill (Pid, Hard_Kill => True);
                  accept Stop (Killed : out Boolean) do
                     Killed := True;
                  end Stop;
               end select;
            end Watchdog;

            Done_Pid  : GNAT.OS_Lib.Process_Id;
            Ok        : Boolean;
            Timed_Out : Boolean;
         begin
            GNAT.OS_Lib.Wait_Process (Done_Pid, Ok);
            Watchdog.Stop (Timed_Out);

            declare
               Output : constant String := Read_Capped (Path.all);
            begin
               GNAT.OS_Lib.Delete_File (Path.all, Gone);
               GNAT.OS_Lib.Free (Path);
               Release;
               if Timed_Out then
                  return "error: '" & Program & "' did not finish within "
                    & Seconds & " seconds and was stopped";
               elsif Output = "" then
                  return "(the command produced no output)";
               else
                  return Output;
               end if;
            end;
         end;
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

   --  Fetch a URL's body through the in-process HTTP/HTTPS client, streamed
   --  to a temporary file and never held whole in memory, then return it
   --  capped. No process is spawned; the client's own timeouts bound a slow
   --  or silent server, and Max_Download_Size keeps the temp file no larger
   --  than what the tool will hand back.
   function Download (Url : String) return String is
      package HC renames Http_Client.Clients;
      package HE renames Http_Client.Errors;

      Path : GNAT.OS_Lib.String_Access;
      FD   : GNAT.OS_Lib.File_Descriptor;
      Outcome : HC.Download_Result;
      Options : HC.Download_Options := HC.Default_Download_Options;
      Config  : HC.Client_Configuration := HC.Default_Client_Configuration;
      Status  : HE.Result_Status;
      Gone    : Boolean;
   begin
      Options.Max_Download_Size := Cap;

      --  The streaming download writes what the stream yields and does not
      --  decode a content coding, so a body the server compressed would come
      --  back as bytes no reader can use. Ask for none: no Accept-Encoding
      --  advertised, so the server sends the text as it is.
      Config.Enable_Decompression := False;
      Config.Execution.Advertise_Accept_Encoding := False;

      GNAT.OS_Lib.Create_Temp_File (FD, Path);
      GNAT.OS_Lib.Close (FD);

      Status := HC.Download_To_File
        (URL           => Url,
         Path          => Path.all,
         Result        => Outcome,
         Options       => Options,
         Configuration => Config);

      declare
         Body_Text : constant String :=
           (if HE.Is_Success (Status) then Read_Capped (Path.all) else "");
      begin
         GNAT.OS_Lib.Delete_File (Path.all, Gone);
         GNAT.OS_Lib.Free (Path);
         if not HE.Is_Success (Status) then
            return "error: the request failed ("
              & HE.Result_Status'Image (Status) & ")";
         elsif Body_Text = "" then
            return "(the request returned no body; HTTP status"
              & Natural'Image (Outcome.HTTP_Status_Code) & ")";
         else
            return Body_Text;
         end if;
      end;
   end Download;

   --  Rank the passages of a folder's text files against a query and return
   --  the best few. This is lexical retrieval: a passage scores by how often
   --  the query's words appear in it, each word weighted down by how many
   --  passages carry it, so a rare word counts for more than a common one.
   --  It finds the words the query used, not their meaning -- a semantic
   --  ranking would embed both and compare, which needs the model this tool
   --  does not hold.
   procedure Use_Embedder
     (Self : in out Instance; Source : Embedder_Reference) is
   begin
      Self.Embed := Source;
   end Use_Embedder;

   procedure Use_Delegator
     (Self : in out Instance; Source : Delegator_Reference) is
   begin
      Self.Sub := Source;
   end Use_Delegator;

   --  The delegate tool: run one subtask on a sub-agent and return its
   --  answer. With no delegator wired -- which is how a sub-agent's own
   --  runner is left -- the call is declined in words the model reads, so
   --  delegation cannot recurse and the loop goes on.
   function Delegate
     (Self : in out Instance; Args : String) return String
   is
      Have : Boolean;
      Job  : constant String := Text_Argument (Args, "task", Have);
   begin
      if not Have then
         return "error: delegate needs a task string";
      end if;
      if Self.Sub = null then
         return "error: delegation is not available here -- a sub-agent "
                & "cannot delegate further; do the work with the other tools";
      end if;

      declare
         Buffer : String (1 .. Model_Runner.Tools.Max_Call_Bytes);
         Last   : Natural;
         Status : E.Error_Info;
      begin
         Self.Sub.Run_Sub (Job, Buffer, Last, Status);
         if E.Is_Error (Status) then
            return "error: the sub-agent could not finish the task";
         elsif Last = 0 then
            return "the sub-agent returned no answer";
         else
            return Buffer (1 .. Last);
         end if;
      end;
   end Delegate;

   function Retrieve
     (Args : String; Embed : Embedder_Reference) return String
   is
      Max_Chunks : constant := 2048;  --  passages held across the folder
      Max_Terms  : constant := 24;    --  distinct query words scored
      Max_Files  : constant := 1024;  --  files read from the folder
      Snippet    : constant := 600;   --  characters in a passage window
      Front      : constant := 1200;  --  leading bytes dropped as front matter
      Top        : constant := 3;     --  passages returned
      Embed_Cap  : constant := 64;    --  most passages embedded in one call
      Max_Width  : constant := 8192;  --  widest embedding vector held

      Have_F, Have_Q : Boolean;
      Folder : constant String := Text_Argument (Args, "folder", Have_F);
      Query  : constant String := Text_Argument (Args, "query", Have_Q);

      function Low (S : String) return String
        renames Ada.Characters.Handling.To_Lower;

      function Word (C : Character) return Boolean
      is (C in 'a' .. 'z' | '0' .. '9');

      --  Whole-word occurrences of Term (lowercased) in Hay (lowercased).
      function Occurrences (Hay, Term : String) return Natural is
         N : Natural := 0;
         I : Integer := Hay'First;
      begin
         if Term'Length = 0 or else Hay'Length < Term'Length then
            return 0;
         end if;
         while I <= Hay'Last - Term'Length + 1 loop
            if Hay (I .. I + Term'Length - 1) = Term
              and then (I = Hay'First or else not Word (Hay (I - 1)))
              and then (I + Term'Length - 1 = Hay'Last
                        or else not Word (Hay (I + Term'Length)))
            then
               N := N + 1;
               I := I + Term'Length;
            else
               I := I + 1;
            end if;
         end loop;
         return N;
      end Occurrences;

      Terms  : array (1 .. Max_Terms) of U.Unbounded_String;
      DF     : array (1 .. Max_Terms) of Natural := [others => 0];
      N_Term : Natural := 0;

      type Chunk is record
         Source : U.Unbounded_String;   --  the file it came from
         Shown  : U.Unbounded_String;   --  the passage as written
         Lower  : U.Unbounded_String;   --  the passage lowercased, to match
         Score  : Float := 0.0;
         Taken  : Boolean := False;
      end record;
      Chunks   : array (1 .. Max_Chunks) of Chunk;
      N_Chunks : Natural := 0;
      Files    : Natural := 0;   --  files read, over the whole tree
      Semantic : Boolean := False;   --  whether meaning-ranking was applied

      use type Ada.Directories.File_Kind;

      --  Take a lowercased query into its distinct words, longest first come
      --  first served, ignoring one-character noise.
      procedure Read_Terms (Q : String) is
         I : Integer := Q'First;
      begin
         while I <= Q'Last and then N_Term < Max_Terms loop
            if Word (Q (I)) then
               declare
                  First : constant Integer := I;
               begin
                  while I <= Q'Last and then Word (Q (I)) loop
                     I := I + 1;
                  end loop;
                  if I - First >= 2 then
                     declare
                        W : constant String := Q (First .. I - 1);
                        Seen : Boolean := False;
                     begin
                        for T in 1 .. N_Term loop
                           if U.To_String (Terms (T)) = W then
                              Seen := True;
                           end if;
                        end loop;
                        if not Seen then
                           N_Term := N_Term + 1;
                           Terms (N_Term) := U.To_Unbounded_String (W);
                        end if;
                     end;
                  end if;
               end;
            else
               I := I + 1;
            end if;
         end loop;
      end Read_Terms;

      --  Add a passage, lowercased once for matching, kept short for return.
      procedure Add_Chunk (From : String; Text : String) is
      begin
         if N_Chunks >= Max_Chunks or else Text'Length = 0 then
            return;
         end if;
         N_Chunks := N_Chunks + 1;
         Chunks (N_Chunks).Source := U.To_Unbounded_String (From);
         declare
            --  Made valid UTF-8: a window may cut a multi-byte character, and
            --  a PDF or a legacy Word file is not UTF-8 at all -- either would
            --  be refused by the embedder's tokenizer and by the model the
            --  passage is handed back to.
            Kept : constant String :=
              Model_Runner.Tools.Text_Util.To_Valid_Utf8
                (if Text'Length <= Snippet then Text
                 else Text (Text'First .. Text'First + Snippet - 1));
         begin
            Chunks (N_Chunks).Shown := U.To_Unbounded_String (Kept);
            Chunks (N_Chunks).Lower := U.To_Unbounded_String (Low (Kept));
         end;
      end Add_Chunk;

      --  Add a passage, breaking one longer than a window into several so a
      --  long stretch of text is indexed whole rather than truncated to its
      --  first window.
      procedure Add_Windows (From : String; Para : String) is
         P : Integer := Para'First;
      begin
         while P <= Para'Last and then N_Chunks < Max_Chunks loop
            declare
               Stop : constant Integer :=
                 Integer'Min (P + Snippet - 1, Para'Last);
            begin
               Add_Chunk (From, Para (P .. Stop));
               P := Stop + 1;
            end;
         end loop;
      end Add_Windows;

      --  Split a file's text into passages at blank lines, each windowed.
      procedure Split (From : String; Text : String) is
         I     : Integer := Text'First;
         Start : Integer := Text'First;
      begin
         while I <= Text'Last loop
            if I < Text'Last and then Text (I) = ASCII.LF
              and then Text (I + 1) = ASCII.LF
            then
               Add_Windows (From, Text (Start .. I - 1));
               I := I + 2;
               Start := I;
            else
               I := I + 1;
            end if;
         end loop;
         if Start <= Text'Last then
            Add_Windows (From, Text (Start .. Text'Last));
         end if;
      end Split;

      --  Drop the leading bytes of a long document's extracted text -- the
      --  title, author, copyright and table of contents a book opens with,
      --  which are not what a search is usually after. A short document keeps
      --  all of its text; only a long one has front matter to spare.
      function Skip_Front (Text : String) return String
      is (if Text'Length > 3 * Front
          then Text (Text'First + Front .. Text'Last) else Text);

      --  Read a directory and its subdirectories into passages, each
      --  labelled with its path under the folder the tool was given. A name
      --  beginning with a dot is skipped -- "." and ".." and hidden trees
      --  like .git -- and the file and passage caps bound the whole walk.
      procedure Walk (Dir : String; Prefix : String) is
         Search : Ada.Directories.Search_Type;
         Item   : Ada.Directories.Directory_Entry_Type;
      begin
         Ada.Directories.Start_Search
           (Search, Dir, "",
            [Ada.Directories.Ordinary_File => True,
             Ada.Directories.Directory     => True,
             others                        => False]);
         while Ada.Directories.More_Entries (Search)
           and then Files < Max_Files
           and then N_Chunks < Max_Chunks
         loop
            Ada.Directories.Get_Next_Entry (Search, Item);
            declare
               Name : constant String := Ada.Directories.Simple_Name (Item);
               Full : constant String := Ada.Directories.Full_Name (Item);
               OO_Found : Boolean;
               OO_Kind  : constant Model_Runner.Tools.OOXML.Document_Kind :=
                 Model_Runner.Tools.OOXML.Kind_Of (Name, OO_Found);

               --  The last four and five characters, lowercased, for reading
               --  a file's kind off its name.
               Ext4 : constant String :=
                 (if Name'Length >= 4
                  then Low (Name (Name'Last - 3 .. Name'Last)) else "");
               Ext5 : constant String :=
                 (if Name'Length >= 5
                  then Low (Name (Name'Last - 4 .. Name'Last)) else "");
            begin
               if Name'Length = 0 or else Name (Name'First) = '.' then
                  null;
               elsif Ada.Directories.Kind (Item)
                       = Ada.Directories.Directory
               then
                  Walk (Full, Prefix & Name & "/");
               elsif Read_Raw (Full, 5) = "%PDF-" then
                  --  A PDF: binary, but its text is pulled out and indexed
                  --  from the file's own bytes. Checked before the binary
                  --  test so a PDF is read as a PDF, never as raw text.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.PDF.Extract_Text
                         (Read_Raw (Full, Doc_Bytes));
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif OO_Found and then Read_Raw (Full, 2) = "PK" then
                  --  A Word, Excel, PowerPoint, OpenDocument or EPUB file:
                  --  a ZIP of XML, whose text is pulled from the right parts.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.OOXML.Extract_Text
                         (Read_Raw (Full, Doc_Bytes), OO_Kind);
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif (Ext4 = ".doc" or else Ext4 = ".xls"
                      or else Ext4 = ".ppt")
                 and then Read_Raw (Full, 8)
                          = Character'Val (16#D0#) & Character'Val (16#CF#)
                            & Character'Val (16#11#) & Character'Val (16#E0#)
                            & Character'Val (16#A1#) & Character'Val (16#B1#)
                            & Character'Val (16#1A#) & Character'Val (16#E1#)
               then
                  --  A legacy Word, Excel or PowerPoint file: an OLE2
                  --  compound file. Its printable runs are read out and
                  --  indexed.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.DOC.Extract_Text
                         (Read_Raw (Full, Doc_Bytes));
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif Ext4 = ".rtf" and then Read_Raw (Full, 5) = "{\rtf" then
                  --  An RTF document: its control words and groups stripped
                  --  to the text.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.RTF.Extract_Text
                         (Read_Raw (Full, Doc_Bytes));
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif Ext4 = ".htm" or else Ext4 = ".xml"
                 or else Ext5 = ".html"
               then
                  --  An HTML or XML file: its tags stripped to the text.
                  Files := Files + 1;
                  declare
                     Text : constant String :=
                       Model_Runner.Tools.Text_Util.Strip_Tags
                         (Read_Capped (Full));
                  begin
                     if Text'Length > 0 then
                        Split (Prefix & Name, Skip_Front (Text));
                     end if;
                  end;
               elsif Is_Binary (Full) then
                  --  An image, an archive -- not text to search.
                  null;
               else
                  Files := Files + 1;
                  declare
                     Body_Text  : constant String := Read_Capped (Full);
                     Unreadable : constant Boolean :=
                       Body_Text'Length >= 6
                       and then Body_Text
                                  (Body_Text'First .. Body_Text'First + 5)
                                = "error:";
                  begin
                     if not Unreadable then
                        Split (Prefix & Name, Body_Text);
                     end if;
                  end;
               end if;
            end;
         end loop;
         Ada.Directories.End_Search (Search);
      exception
         when others =>
            null;
      end Walk;

   begin
      if not (Have_F and then Have_Q) then
         return "error: retrieve needs a folder and a query";
      elsif not Ada.Directories.Exists (Folder) then
         return "error: no folder at that path";
      end if;

      Read_Terms (Low (Query));
      if N_Term = 0 then
         return "error: the query has no words to search for";
      end if;

      --  Read the folder tree's files into passages.
      Walk (Folder, "");

      if N_Chunks = 0 then
         return "no readable text files in that folder";
      end if;

      --  Document frequency of each term across the passages.
      for T in 1 .. N_Term loop
         declare
            Term : constant String := U.To_String (Terms (T));
         begin
            for C in 1 .. N_Chunks loop
               if Occurrences (U.To_String (Chunks (C).Lower), Term) > 0 then
                  DF (T) := DF (T) + 1;
               end if;
            end loop;
         end;
      end loop;

      --  Score each passage: term frequency times a rarity weight, so a word
      --  in few passages counts for more than one in many.
      for C in 1 .. N_Chunks loop
         declare
            Hay   : constant String := U.To_String (Chunks (C).Lower);
            Total : Float := 0.0;
         begin
            for T in 1 .. N_Term loop
               declare
                  TF : constant Natural :=
                    Occurrences (Hay, U.To_String (Terms (T)));
               begin
                  if TF > 0 then
                     Total := Total
                       + Float (TF) * (1.0 / (1.0 + Float (DF (T))));
                  end if;
               end;
            end loop;
            Chunks (C).Score := Total;
         end;
      end loop;

      --  With an embedder at hand, re-score by meaning: embed the query and
      --  the candidate passages and rank by how close each is to the query,
      --  which finds a passage that shares the query's sense even where it
      --  shares few of its words. Only a bounded number are embedded -- the
      --  whole set when it is small, otherwise the ones the lexical score
      --  already liked -- because each embedding is a pass over the model.
      --  A candidate's cosine (in -1 .. 1) is shifted into 0 .. 2 so the
      --  selection below, which keeps a positive score, still reads it; a
      --  passage not embedded is left at zero and drops out. If the query
      --  will not embed, the lexical scores stand.
      if Embed /= null then
         declare
            Q      : N.Real_Array (0 .. Max_Width - 1);
            P      : N.Real_Array (0 .. Max_Width - 1);
            Q_Last : Natural;
            P_Last : Natural;
            St     : E.Error_Info;
         begin
            Embed.Embed (Query, Q, Q_Last, St);
            if E.Is_Ok (St) then
               Semantic := True;
               declare
                  Used  : array (1 .. N_Chunks) of Boolean :=
                    [others => False];
                  Count : constant Natural :=
                    Natural'Min (N_Chunks, Embed_Cap);
                  Cand  : array (1 .. Count) of Positive;
               begin
                  --  The Count passages the lexical score liked most.
                  for K in 1 .. Count loop
                     declare
                        Best   : Natural := 0;
                        Best_S : Float := Float'First;
                     begin
                        for C in 1 .. N_Chunks loop
                           if not Used (C)
                             and then Chunks (C).Score >= Best_S
                           then
                              Best := C;
                              Best_S := Chunks (C).Score;
                           end if;
                        end loop;
                        exit when Best = 0;
                        Used (Best) := True;
                        Cand (K) := Best;
                     end;
                  end loop;

                  --  Every passage out of the running until its meaning earns
                  --  it back. The sentinel is below any cosine, so a passage
                  --  that was not embedded never outranks one that was.
                  for C in 1 .. N_Chunks loop
                     Chunks (C).Score := -2.0;
                  end loop;

                  for K in Cand'Range loop
                     Embed.Embed
                       (U.To_String (Chunks (Cand (K)).Shown),
                        P, P_Last, St);
                     if E.Is_Ok (St) and then P_Last = Q_Last then
                        declare
                           Dot : N.Real := 0.0;
                        begin
                           for I in 0 .. N.Element_Index (Q_Last) loop
                              Dot := Dot + Q (I) * P (I);
                           end loop;
                           Chunks (Cand (K)).Score := Float (Dot) + 1.0;
                        end;
                     end if;
                  end loop;
               end;
            end if;
         end;
      end if;

      --  The best few, in order, each labelled with its file.
      declare
         Out_S : U.Unbounded_String;
         Found : Natural := 0;

         --  Lexical ranking requires a positive score -- a word the query
         --  and the passage share. Semantic ranking returns its best
         --  candidates whatever their cosine, since a shared meaning need
         --  not be a shared word; only the sentinel non-candidates are shut
         --  out.
         Floor : constant Float := (if Semantic then -1.5 else 0.0);
      begin
         for Rank in 1 .. Top loop
            declare
               Best  : Natural := 0;
               Top_S : Float := Floor;
            begin
               for C in 1 .. N_Chunks loop
                  if not Chunks (C).Taken
                    and then Chunks (C).Score > Top_S
                  then
                     Best := C;
                     Top_S := Chunks (C).Score;
                  end if;
               end loop;
               exit when Best = 0;
               Chunks (Best).Taken := True;
               Found := Found + 1;
               if U.Length (Out_S) > 0 then
                  U.Append (Out_S, ASCII.LF & ASCII.LF);
               end if;
               U.Append (Out_S, "[" & U.To_String (Chunks (Best).Source)
                         & "] " & U.To_String (Chunks (Best).Shown));
            end;
         end loop;

         if Found = 0 then
            return "no passage in that folder matched the query";
         end if;
         return Capped (U.To_String (Out_S));
      end;
   end Retrieve;

   function Http_Get (Args : String) return String is
      Have : Boolean;
      Url  : constant String := Text_Argument (Args, "url", Have);
   begin
      if not Have then
         return "error: http_get needs a url";
      end if;
      return Download (Url);
   end Http_Get;

   --  Percent-encode a query string for a URL: the unreserved characters
   --  pass through, everything else -- a space, a symbol, a non-ASCII byte --
   --  becomes %XX, so the query is safe to paste after "?q=".
   function Encode_Query (S : String) return String is
      Hex  : constant String := "0123456789ABCDEF";
      Room : String (1 .. S'Length * 3);
      Used : Natural := 0;

      procedure Put (C : Character) is
      begin
         Used := Used + 1;
         Room (Used) := C;
      end Put;
   begin
      for C of S loop
         if C in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '_' | '.' | '~'
         then
            Put (C);
         else
            Put ('%');
            Put (Hex (Character'Pos (C) / 16 + 1));
            Put (Hex (Character'Pos (C) mod 16 + 1));
         end if;
      end loop;
      return Room (1 .. Used);
   end Encode_Query;

   function Web_Search (Args : String) return String is
      Have  : Boolean;
      Query : constant String := Text_Argument (Args, "query", Have);
   begin
      if not Have then
         return "error: web_search needs a query";
      end if;
      --  Fetched the same way as http_get -- through the in-process client,
      --  streamed -- with the query percent-encoded into the URL.
      return Download
        ("https://lite.duckduckgo.com/lite/?q=" & Encode_Query (Query));
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
         elsif Named = "retrieve" then
            return Retrieve (Arguments, Self.Embed);
         elsif Named = "delegate" then
            return Delegate (Self, Arguments);
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
