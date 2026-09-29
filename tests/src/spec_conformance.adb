with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with GNAT.SHA1;

package body Spec_Conformance is

   use Ada.Strings.Unbounded;

   Matrix_Path : constant String := "docs/spec-conformance.tsv";
   Spec_Path   : constant String := "docs/spec_driven_development_framework_v3_revised.md";
   Digest_Path : constant String := "docs/spec-conformance.sha1";

   --  A whole file, lines joined by LF.
   function Whole (Path : String) return String is
      File : Ada.Text_IO.File_Type;
      Text : Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Text, Ada.Text_IO.Get_Line (File) & ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return To_String (Text);
   end Whole;

   --  A whole file as its bytes are, which is what its digest is of.
   function Whole_Bytes (Path : String) return String is
      use Ada.Streams.Stream_IO;
      File : File_Type;
      Size : constant Natural := Natural (Ada.Directories.Size (Path));
      Text : String (1 .. Size);
   begin
      Open (File, In_File, Path);
      String'Read (Stream (File), Text);
      Close (File);
      return Text;
   end Whole_Bytes;

   --  Every test source, its string literals joined across & and lines, so
   --  a test's name reads as it is said: "a " & "b" is "a b".
   function Tests_Text (Root : String) return String is
      Search : Ada.Directories.Search_Type;
      Found  : Ada.Directories.Directory_Entry_Type;
      Raw    : Unbounded_String;
      Flat   : Unbounded_String;
      Index  : Positive := 1;
   begin
      Ada.Directories.Start_Search (Search, Root & "/tests/src", "*.adb");
      while Ada.Directories.More_Entries (Search) loop
         Ada.Directories.Get_Next_Entry (Search, Found);
         Append (Raw, Whole (Ada.Directories.Full_Name (Found)));
      end loop;
      Ada.Directories.End_Search (Search);

      declare
         Text : constant String := To_String (Raw);
      begin
         while Index <= Text'Last loop
            if Text (Index) = '"' then
               --  A literal's end, then & and the next literal's start: the
               --  two are one text.
               declare
                  Next : Natural := Index + 1;
               begin
                  while Next <= Text'Last and then Text (Next) in ' ' | ASCII.LF | ASCII.CR loop
                     Next := Next + 1;
                  end loop;
                  if Next <= Text'Last and then Text (Next) = '&' then
                     Next := Next + 1;
                     while Next <= Text'Last and then Text (Next) in ' ' | ASCII.LF | ASCII.CR loop
                        Next := Next + 1;
                     end loop;
                     if Next <= Text'Last and then Text (Next) = '"' then
                        Index := Next + 1;
                        goto Continue;
                     end if;
                  end if;
                  if Index < Text'Last and then Text (Index + 1) = '"' then
                     Append (Flat, '"');
                     Index := Index + 2;
                     goto Continue;
                  end if;
               end;
            end if;
            Append (Flat, Text (Index));
            Index := Index + 1;
            <<Continue>>
         end loop;
      end;
      return To_String (Flat);
   end Tests_Text;

   --  The fields of a tab-separated line.
   function Field (Line : String; Number : Positive) return String is
      Start : Natural := Line'First;
      Count : Positive := 1;
   begin
      for Index in Line'First .. Line'Last + 1 loop
         if Index > Line'Last or else Line (Index) = ASCII.HT then
            if Count = Number then
               return Line (Start .. Index - 1);
            end if;
            Count := Count + 1;
            Start := Index + 1;
         end if;
      end loop;
      return "";
   end Field;

   --  Whether one of a row's tests -- several may be named, by ; or | --
   --  is said in the test sources.
   function Named (Tests, Text : String) return Boolean is
      Start : Natural := Tests'First;
   begin
      for Index in Tests'First .. Tests'Last + 1 loop
         if Index > Tests'Last or else Tests (Index) in ';' | '|' then
            declare
               One : constant String :=
                 Ada.Strings.Fixed.Trim (Tests (Start .. Index - 1), Ada.Strings.Both);
               Bare : constant String :=
                 (if One'Length >= 2 and then One (One'First) = '"' and then One (One'Last) = '"'
                  then One (One'First + 1 .. One'Last - 1) else One);
            begin
               if Bare /= "" and then Ada.Strings.Fixed.Index (Text, Bare) > 0 then
                  return True;
               end if;
            end;
            Start := Index + 1;
         end if;
      end loop;
      return False;
   end Named;

   -------------
   -- Problem --
   -------------

   function Problem (Root : String) return String is
      Matrix : Ada.Text_IO.File_Type;
      Header : Boolean := True;
   begin
      --  The rows were made from this specification, and no other.
      declare
         Kept : constant String :=
           Ada.Strings.Fixed.Trim (Whole (Root & "/" & Digest_Path),
                                   Ada.Strings.Maps.To_Set (" " & ASCII.LF & ASCII.CR),
                                   Ada.Strings.Maps.To_Set (" " & ASCII.LF & ASCII.CR));
         Now  : constant String := GNAT.SHA1.Digest (Whole_Bytes (Root & "/" & Spec_Path));
      begin
         if Kept /= Now then
            return Spec_Path & " has changed since " & Matrix_Path & " was made from it: derive"
              & " the rows again and record its digest in " & Digest_Path;
         end if;
      end;

      declare
         Text : constant String := Tests_Text (Root);
      begin
         Ada.Text_IO.Open (Matrix, Ada.Text_IO.In_File, Root & "/" & Matrix_Path);
         while not Ada.Text_IO.End_Of_File (Matrix) loop
            declare
               Line   : constant String := Ada.Text_IO.Get_Line (Matrix);
               Id     : constant String := Field (Line, 1);
               Status : constant String := Field (Line, 4);
               Tests  : constant String := Field (Line, 6);
            begin
               if Header then
                  Header := False;
               elsif Line = "" then
                  null;
               elsif Status not in "met" | "n/a" then
                  Ada.Text_IO.Close (Matrix);
                  return Id & " is " & Status & ": " & Field (Line, 7);
               elsif Status = "met" and then not Named (Tests, Text) then
                  Ada.Text_IO.Close (Matrix);
                  return Id & " is met by no test there is: " & Tests;
               end if;
            end;
         end loop;
         Ada.Text_IO.Close (Matrix);
      end;
      return "";
   end Problem;

end Spec_Conformance;
