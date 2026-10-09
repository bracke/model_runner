with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Interfaces;

package body Model_Runner.Tools.Editing is

   package E renames Model_Runner.Errors;
   package U renames Ada.Strings.Unbounded;

   use type Interfaces.Unsigned_64;
   use type Ada.Directories.File_Size;
   use type E.Error_Code;

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   -------------
   -- On_Disk --
   -------------

   function On_Disk (Base, Path : String) return String
   is (if Base = "" or else Path = "" or else Path (Path'First) = '/'
       then Path
       elsif Path = "." then Base
       else Base & "/" & Path);

   function Failing (Text : String) return Said is
     ((Text => U.To_Unbounded_String ("error: " & Text), Failed => True, others => <>));

   ---------------
   -- Read_Text --
   ---------------

   procedure Read_Text
     (Path   : String;
      Text   : out U.Unbounded_String;
      Status : out E.Error_Info;
      Base   : String := "")
   is
      Disk : constant String := On_Disk (Base, Path);
      use Ada.Streams;
      File : Stream_IO.File_Type;
   begin
      Text := U.Null_Unbounded_String;
      Status := E.Success;
      if not Ada.Directories.Exists (Disk) then
         Status := E.Make (E.IO_Open_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      elsif Ada.Directories."/=" (Ada.Directories.Kind (Disk), Ada.Directories.Ordinary_File) then
         Status := E.Make (E.IO_Not_A_Regular_File);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         return;
      elsif Ada.Directories.Size (Disk) > Ada.Directories.File_Size (Text_Most) then
         Status := E.Make (E.IO_File_Too_Large);
         E.Add_Text (Status, "path", Path, E.Param_Path);
         E.Add_Text (Status, "detail", Image (Natural (Ada.Directories.Size (Disk) / 1024)) & " KiB, past the "
                     & Image (Text_Most / 1024) & " KiB a file is read whole");
         return;
      end if;
      Stream_IO.Open (File, Stream_IO.In_File, Disk);
      declare
         Length : constant Natural := Natural (Stream_IO.Size (File));
         Block  : Stream_Element_Array (1 .. Stream_Element_Offset (Length));
         Last   : Stream_Element_Offset := 0;
         Whole  : String (1 .. Length);
      begin
         if Length > 0 then
            Stream_IO.Read (File, Block, Last);
         end if;
         Stream_IO.Close (File);
         for Index in 1 .. Natural (Last) loop
            Whole (Index) := Character'Val (Block (Stream_Element_Offset (Index)));
            --  A NUL is not text: a binary file named like a source.
            if Whole (Index) = ASCII.NUL then
               Status := E.Make (E.IO_Read_Failed);
               E.Add_Text (Status, "path", Path, E.Param_Path);
               E.Add_Text (Status, "detail", "it is not text");
               return;
            end if;
         end loop;
         Text := U.To_Unbounded_String (Whole (1 .. Natural (Last)));
      end;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         Text := U.Null_Unbounded_String;
         Status := E.Make (E.IO_Read_Failed);
         E.Add_Text (Status, "path", Path, E.Param_Path);
   end Read_Text;

   --------------
   -- Revision --
   --------------

   function Revision (Text : String) return String is
      Hash   : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
      Digits_Of : constant String := "0123456789abcdef";
      Result : String (1 .. 16);
   begin
      for C of Text loop
         Hash := (Hash xor Interfaces.Unsigned_64 (Character'Pos (C))) * 16#0000_0100_0000_01B3#;
      end loop;
      for Index in reverse Result'Range loop
         Result (Index) := Digits_Of (Natural (Hash and 15) + 1);
         Hash := Interfaces.Shift_Right (Hash, 4);
      end loop;
      return Result;
   end Revision;

   -----------------
   -- Revision_Of --
   -----------------

   function Revision_Of (Path : String; Base : String := "") return String is
      Text   : U.Unbounded_String;
      Status : E.Error_Info;
   begin
      Read_Text (Path, Text, Status, Base);
      return (if E.Is_Ok (Status) then Revision (U.To_String (Text)) else "");
   end Revision_Of;

   --  What a failed read is said as, to a model.
   function Why_Unread (Path : String; Status : E.Error_Info) return String is
   begin
      if Status.Code = E.IO_Open_Failed then
         return "no file at " & Path;
      elsif Status.Code = E.IO_Not_A_Regular_File then
         return Path & " is a directory: list_directory lists it";
      elsif Status.Code = E.IO_File_Too_Large then
         return Path & " is too large to read whole (" & E.Text_Of (Status, "detail")
           & "): read_range reads lines of it, search_file finds them";
      elsif E.Text_Of (Status, "detail") /= "" then
         return Path & " cannot be read as text: " & E.Text_Of (Status, "detail");
      end if;
      return Path & " could not be read";
   end Why_Unread;

   --  How many lines a text has up to and including an index.
   function Line_At (Text : String; Index : Natural) return Positive is
      Count : Positive := 1;
   begin
      for At_Char in Text'First .. Natural'Min (Index, Text'Last) - 1 loop
         if Text (At_Char) = ASCII.LF then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Line_At;

   function Lines_In (Text : String) return Natural is
     (if Text'Length = 0 then 0
      else Ada.Strings.Fixed.Count (Text, [1 => ASCII.LF])
           + (if Text (Text'Last) = ASCII.LF then 0 else 1));

   --  Write a text as bytes, exactly.
   procedure Write_Bytes (Path : String; Text : String) is
      use Ada.Streams;
      File  : Stream_IO.File_Type;
      Block : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length));
   begin
      for Index in Block'Range loop
         Block (Index) := Stream_Element (Character'Pos (Text (Text'First + Natural (Index) - 1)));
      end loop;
      Stream_IO.Create (File, Stream_IO.Out_File, Path);
      Stream_IO.Write (File, Block);
      Stream_IO.Close (File);
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         raise;
   end Write_Bytes;

   ---------------------
   -- Declarations_In --
   ---------------------

   function Declarations_In (Text : String; First, Last : Positive) return String is
      type Word_Ref is access constant String;
      Opening : constant array (1 .. 15) of Word_Ref :=
        [new String'("procedure "), new String'("function "), new String'("package body "),
         new String'("package "), new String'("type "), new String'("subtype "),
         new String'("task body "), new String'("task "), new String'("protected body "),
         new String'("protected "), new String'("entry "), new String'("def "),
         new String'("class "), new String'("fn "), new String'("func ")];
      Found  : U.Unbounded_String;
      Above  : U.Unbounded_String;
      Line   : Positive := 1;
      Start  : Positive := Text'First;

      --  The name a line declares, or "".
      function Declared (Said : String) return String is
         Bare : constant String :=
           Ada.Strings.Fixed.Trim (Said, Ada.Strings.Both);
         Low  : constant String := Ada.Characters.Handling.To_Lower (Bare);
         Rest : constant String :=
           (if Low'Length > 11 and then Low (Low'First .. Low'First + 10) = "overriding " then
               Bare (Bare'First + 11 .. Bare'Last)
            elsif Low'Length > 4 and then Low (Low'First .. Low'First + 3) = "pub " then
               Bare (Bare'First + 4 .. Bare'Last)
            else Bare);
         Lower : constant String := Ada.Characters.Handling.To_Lower (Rest);
      begin
         for Word of Opening loop
            if Lower'Length > Word'Length
              and then Lower (Lower'First .. Lower'First + Word'Length - 1) = Word.all
            then
               declare
                  From : constant Positive := Rest'First + Word'Length;
                  To   : Natural := From - 1;
               begin
                  while To < Rest'Last
                    and then (Ada.Characters.Handling.Is_Alphanumeric (Rest (To + 1))
                              or else Rest (To + 1) in '_' | '.')
                  loop
                     To := To + 1;
                  end loop;
                  return Rest (From .. To);
               end;
            end if;
         end loop;
         return "";
      end Declared;

      procedure Note (Name : String) is
      begin
         if Name /= "" and then U.Index (Found, Name) = 0 then
            U.Append (Found, (if U.Length (Found) = 0 then "" else ", ") & Name);
         end if;
      end Note;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            declare
               Name : constant String := Declared (Text (Start .. Index - 1));
            begin
               if Name /= "" then
                  if Line <= First then
                     Above := U.To_Unbounded_String (Name);
                  elsif Line <= Last then
                     Note (Name);
                  end if;
               end if;
            end;
            exit when Line > Last;
            Line := Line + 1;
            Start := Index + 1;
         end if;
      end loop;
      declare
         Within : constant String := U.To_String (Found);
      begin
         Found := U.Null_Unbounded_String;
         Note (U.To_String (Above));
         if Within /= "" then
            U.Append (Found, (if U.Length (Found) = 0 then "" else ", ") & Within);
         end if;
      end;
      return U.To_String (Found);
   end Declarations_In;

   ----------
   -- Edit --
   ----------

   function Edit (Path, Old_Text, New_Text, Expected : String; Base : String := "") return Said is
      Held   : U.Unbounded_String;
      Status : E.Error_Info;
   begin
      Read_Text (Path, Held, Status, Base);
      if E.Is_Error (Status) then
         return Failing (Why_Unread (Path, Status));
      end if;
      declare
         Text : constant String := U.To_String (Held);
         Now  : constant String := Revision (Text);
      begin
         if Expected /= "" and then Expected /= Now then
            return Failing (Path & " has changed since you read it (you read revision " & Expected
                            & ", it is now " & Now & "): read it again, then edit what is there");
         elsif Old_Text = "" then
            return Failing ("old_text is empty: give the exact text to replace (write_file makes a new file)");
         end if;
         declare
            At_Text : constant Natural := Ada.Strings.Fixed.Index (Text, Old_Text);
            Times   : constant Natural := Ada.Strings.Fixed.Count (Text, Old_Text);
         begin
            if At_Text = 0 then
               return Failing ("old_text is not in " & Path & " as it is now (revision " & Now
                               & "): read the part you mean to change again, and give it exactly");
            elsif Times > 1 then
               return Failing ("old_text is in " & Path & Natural'Image (Times)
                               & " times: give more of the text around the one you mean");
            elsif Old_Text = New_Text then
               return (Text => U.To_Unbounded_String ("unchanged: old_text and new_text are the same"),
                       others => <>);
            end if;
            declare
               After : constant String :=
                 Text (Text'First .. At_Text - 1) & New_Text
                 & Text (At_Text + Old_Text'Length .. Text'Last);
               From  : constant Positive := Line_At (Text, At_Text);
               Upto  : constant Positive := From + Natural'Max (1, Lines_In (New_Text)) - 1;
               Names : constant String := Declarations_In (After, From, Upto);
            begin
               Write_Bytes (On_Disk (Base, Path), After);
               return
                 (Text    => U.To_Unbounded_String
                    ("edited " & Path & " at line" & Natural'Image (From) & ":"
                     & Natural'Image (Lines_In (Old_Text)) & " line"
                     & (if Lines_In (Old_Text) = 1 then "" else "s") & " replaced by"
                     & Natural'Image (Lines_In (New_Text))
                     & (if Names = "" then "" else "; in " & Names)
                     & "; revision now " & Revision (After)),
                  Changed => True,
                  others  => <>);
            end;
         end;
      end;
   exception
      when others =>
         return Failing ("could not write " & Path);
   end Edit;

   ----------------
   -- Read_Range --
   ----------------

   function Read_Range (Path : String; First, Last : Natural; Base : String := "") return Said is
      Held   : U.Unbounded_String;
      Status : E.Error_Info;
      Result : Said;
   begin
      if First = 0 or else (Last /= 0 and then Last < First) then
         return Failing ("read_range takes first_line from 1, and last_line at or after it (0 for the end)");
      end if;
      Read_Text (Path, Held, Status, Base);
      if E.Is_Error (Status) and then Status.Code = E.IO_File_Too_Large then
         return Failing (Path & " is too large to read here (" & E.Text_Of (Status, "detail")
                         & "): search_file finds the lines you want");
      elsif E.Is_Error (Status) then
         return Failing (Why_Unread (Path, Status));
      end if;
      declare
         Text  : constant String := U.To_String (Held);
         Total : constant Natural := Lines_In (Text);
         Upto  : constant Natural :=
           Natural'Min (Natural'Min ((if Last = 0 then Total else Last), Total), First + Range_Most - 1);
         Line  : Positive := 1;
         Start : Positive := Text'First;
      begin
         if First > Total then
            return Failing (Path & " has" & Natural'Image (Total) & " lines");
         end if;
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last or else Text (Index) = ASCII.LF then
               if Line >= First and then Line <= Upto then
                  U.Append (Result.Text, Image (Line) & ": " & Text (Start .. Index - 1) & ASCII.LF);
               end if;
               exit when Line >= Upto;
               Line := Line + 1;
               Start := Index + 1;
            end if;
         end loop;
         if Upto < (if Last = 0 then Total else Natural'Min (Last, Total)) then
            Result.Truncated := True;
            U.Append (Result.Text, "(" & Natural'Image (Range_Most) & " lines at most; read on from line"
                      & Natural'Image (Upto + 1) & ")" & ASCII.LF);
         end if;
         U.Append (Result.Text, "(" & Path & ":" & Natural'Image (Total) & " lines, revision "
                   & Revision (Text) & ")");
         return Result;
      end;
   end Read_Range;

   --  The lines of a text holding a pattern, each with what is before it.
   procedure Search_Text
     (Text, Pattern, Before : String;
      Into   : in out Said;
      Hits   : in out Natural)
   is
      Line  : Positive := 1;
      Start : Positive := Text'First;
   begin
      for Index in Text'First .. Text'Last + 1 loop
         if Index > Text'Last or else Text (Index) = ASCII.LF then
            declare
               Said_Line : constant String := Text (Start .. Index - 1);
            begin
               if Ada.Strings.Fixed.Index (Said_Line, Pattern) > 0 then
                  if Hits = Search_Most then
                     Into.Truncated := True;
                     return;
                  end if;
                  Hits := Hits + 1;
                  U.Append (Into.Text, Before & Image (Line) & ": "
                            & (if Said_Line'Length > 200
                               then Said_Line (Said_Line'First .. Said_Line'First + 199) & " ..."
                               else Said_Line)
                            & ASCII.LF);
               end if;
            end;
            Line := Line + 1;
            Start := Index + 1;
         end if;
      end loop;
   end Search_Text;

   -----------------
   -- Search_File --
   -----------------

   function Search_File (Path, Pattern : String; Base : String := "") return Said is
      Held   : U.Unbounded_String;
      Status : E.Error_Info;
      Result : Said;
      Hits   : Natural := 0;
   begin
      if Pattern = "" then
         return Failing ("search_file needs a pattern: the text to find");
      end if;
      Read_Text (Path, Held, Status, Base);
      if E.Is_Error (Status) then
         return Failing (Why_Unread (Path, Status));
      end if;
      Search_Text (U.To_String (Held), Pattern, "", Result, Hits);
      if Hits = 0 then
         Result.Text := U.To_Unbounded_String ("no line of " & Path & " holds that");
      elsif Result.Truncated then
         U.Append (Result.Text, "(the first" & Natural'Image (Search_Most) & " only; a longer pattern narrows it)");
      end if;
      return Result;
   end Search_File;

   -----------------
   -- Search_Code --
   -----------------

   function Search_Code (Folder, Pattern : String; Base : String := "") return Said is
      Result : Said;
      Hits   : Natural := 0;

      function Passed_Over (Name : String) return Boolean is
        (Name'Length = 0 or else Name (Name'First) = '.'
         or else Name in "obj" | "bin" | "alire" | "node_modules" | "target" | "__pycache__");

      procedure Walk (Here : String) is
         Search : Ada.Directories.Search_Type;
         Found  : Ada.Directories.Directory_Entry_Type;
      begin
         Ada.Directories.Start_Search (Search, On_Disk (Base, Here), "");
         while Ada.Directories.More_Entries (Search) and then not Result.Truncated loop
            Ada.Directories.Get_Next_Entry (Search, Found);
            declare
               use type Ada.Directories.File_Kind;
               Name : constant String := Ada.Directories.Simple_Name (Found);
               Full : constant String := (if Here = "." then Name else Here & "/" & Name);
            begin
               if Passed_Over (Name) then
                  null;
               elsif Ada.Directories.Kind (Found) = Ada.Directories.Directory then
                  Walk (Full);
               elsif Ada.Directories.Kind (Found) = Ada.Directories.Ordinary_File then
                  declare
                     Held   : U.Unbounded_String;
                     Status : E.Error_Info;
                  begin
                     Read_Text (Full, Held, Status, Base);
                     if E.Is_Ok (Status) then
                        Search_Text (U.To_String (Held), Pattern, Full & ":", Result, Hits);
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
      if Pattern = "" then
         return Failing ("search_code needs a pattern: the text to find");
      elsif not Ada.Directories.Exists (On_Disk (Base, Folder))
        or else Ada.Directories."/=" (Ada.Directories.Kind (On_Disk (Base, Folder)), Ada.Directories.Directory)
      then
         return Failing ("no folder at " & Folder);
      end if;
      Walk (Folder);
      if Hits = 0 then
         Result.Text := U.To_Unbounded_String ("no file under " & Folder & " holds that");
      elsif Result.Truncated then
         U.Append (Result.Text, "(the first" & Natural'Image (Search_Most) & " only; a longer pattern narrows it)");
      end if;
      return Result;
   end Search_Code;

end Model_Runner.Tools.Editing;
