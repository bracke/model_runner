with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with GNAT.OS_Lib;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;
with Model_Runner.Limits;
with Model_Runner.Tokenizer;

with Project_Tools.Files;

package body Tokenizer_Cross is

   package E renames Model_Runner.Errors;
   package U renames Ada.Strings.Unbounded;
   package Vocab renames Model_Runner.Tokenizer;

   --  The line between two cases: U+241E, SYMBOL FOR RECORD SEPARATOR.
   Separator : constant String :=
     Character'Val (16#E2#) & Character'Val (16#90#) & Character'Val (16#9E#)
     & ASCII.LF;

   type Case_List is array (Positive range <>) of U.Unbounded_String;

   function Split (Text : String) return Case_List is
      Count : Natural := 1;
      At_Of : Natural := Text'First;
   begin
      loop
         declare
            Found : constant Natural :=
              Ada.Strings.Fixed.Index (Text (At_Of .. Text'Last), Separator);
         begin
            exit when Found = 0;
            Count := Count + 1;
            At_Of := Found + Separator'Length;
         end;
      end loop;

      declare
         Result : Case_List (1 .. Count);
         From   : Natural := Text'First;
      begin
         for Index in Result'Range loop
            declare
               Found : constant Natural :=
                 (if From > Text'Last then 0
                  else Ada.Strings.Fixed.Index
                         (Text (From .. Text'Last), Separator));
               Upto  : constant Natural :=
                 (if Found = 0 then Text'Last else Found - 1);
            begin
               Result (Index) := U.To_Unbounded_String (Text (From .. Upto));
               From := Upto + 1 + (if Found = 0 then 0 else Separator'Length);
            end;
         end loop;
         return Result;
      end;
   end Split;

   --  The numbers of "[1, 2, 3]", as llama-tokenize --ids prints them.
   function Numbers (Text : String) return String is
      Result : U.Unbounded_String;
   begin
      for C of Text loop
         if C in '0' .. '9' then
            U.Append (Result, C);
         elsif C = ',' then
            U.Append (Result, ' ');
         end if;
      end loop;
      return U.To_String (Result);
   end Numbers;

   procedure Write_Raw (Path : String; Text : String) is
      use Ada.Streams.Stream_IO;
      File : File_Type;
   begin
      Create (File, Out_File, Path);
      String'Write (Stream (File), Text);
      Close (File);
   end Write_Raw;

   procedure Run
     (Llama   : String;
      Models  : String;
      Corpus  : String;
      Scratch : String;
      Result  : out Report)
   is
      Cases : constant Case_List :=
        Split (Project_Tools.Files.Read_Raw_File (Corpus));
      List  : Ada.Text_IO.File_Type;
   begin
      Result := (others => <>);
      if not Ada.Directories.Exists (Scratch) then
         Ada.Directories.Create_Path (Scratch);
      end if;

      Ada.Text_IO.Open (List, Ada.Text_IO.In_File, Models);
      while not Ada.Text_IO.End_Of_File (List) loop
         declare
            Path   : constant String := Ada.Text_IO.Get_Line (List);
            Source : Model_Runner.Byte_Sources.Files.File_Source;
            Item   : Model_Runner.GGUF.Containers.Container;
            Words  : Vocab.Vocabulary;
            Status : E.Error_Info;
            Agreed, Differed : Natural := 0;
         begin
            if Path'Length = 0 then
               goto Next_Model;
            end if;

            Model_Runner.Byte_Sources.Files.Open
              (Source, Path, Status => Status);
            if E.Is_Ok (Status) then
               Model_Runner.GGUF.Containers.Reader.Parse
                 (Item, Source, Model_Runner.Limits.Default_Model_Limits,
                  null, null, Status);
            end if;
            if E.Is_Ok (Status) then
               Vocab.Load
                 (Words, Item, Model_Runner.Limits.Default_Model_Limits,
                  Status);
            end if;
            if E.Is_Error (Status) then
               Ada.Text_IO.Put_Line
                 (Ada.Directories.Simple_Name (Path) & ": not read: "
                  & E.Diagnostic_Code (Status.Code));
               Result.Failed := Result.Failed + 1;
               goto Next_Model;
            end if;
            Result.Models := Result.Models + 1;

            for Index in Cases'Range loop
               declare
                  Text : constant String := U.To_String (Cases (Index));
                  Held : Vocab.Token_Array (1 .. Text'Length + 2);
                  Used : Natural := 0;
                  Ours : U.Unbounded_String;
                  Case_File : constant String :=
                    Scratch & "/case.txt";
                  Out_File  : constant String :=
                    Scratch & "/ids.txt";
                  Ok        : Boolean;
                  Code      : Integer;
                  Args      : GNAT.OS_Lib.Argument_List :=
                    [new String'("-m"), new String'(Path),
                     new String'("-f"), new String'(Case_File),
                     new String'("--ids"), new String'("--no-escape"),
                     new String'("--log-disable")];
               begin
                  if Text'Length = 0 then
                     goto Next_Case;
                  end if;

                  Vocab.Encode
                    (Words, Text, Vocab.Adds_Beginning (Words),
                     Vocab.Adds_End (Words), Held, Used, Status);
                  if E.Is_Error (Status) then
                     Ada.Text_IO.Put_Line
                       (Ada.Directories.Simple_Name (Path) & " case"
                        & Positive'Image (Index) & ": ours refused: "
                        & E.Diagnostic_Code (Status.Code));
                     Differed := Differed + 1;
                     goto Next_Case;
                  end if;
                  for I in 1 .. Used loop
                     if I > 1 then
                        U.Append (Ours, ' ');
                     end if;
                     U.Append
                       (Ours,
                        Ada.Strings.Fixed.Trim
                          (Natural'Image (Natural (Held (I))),
                           Ada.Strings.Both));
                  end loop;

                  Write_Raw (Case_File, Text);
                  GNAT.OS_Lib.Spawn
                    (Llama, Args, Out_File, Ok, Code, Err_To_Out => False);
                  for A of Args loop
                     GNAT.OS_Lib.Free (A);
                  end loop;
                  if not Ok or else Code /= 0 then
                     Ada.Text_IO.Put_Line
                       (Ada.Directories.Simple_Name (Path) & " case"
                        & Positive'Image (Index)
                        & ": llama-tokenize failed");
                     Result.Failed := Result.Failed + 1;
                     goto Next_Case;
                  end if;

                  declare
                     Printed : constant String :=
                       Project_Tools.Files.Read_Raw_File (Out_File);
                     Bracket : constant Natural :=
                       Ada.Strings.Fixed.Index (Printed, "[", Going => Ada.Strings.Backward);
                     Theirs  : constant String :=
                       Ada.Strings.Fixed.Trim
                         (Numbers
                            (if Bracket = 0 then Printed
                             else Printed (Bracket .. Printed'Last)),
                          Ada.Strings.Both);
                     Squeezed : U.Unbounded_String;
                  begin
                     --  "1  2" as "1 2": the comma and the space after it.
                     for C of Theirs loop
                        if C /= ' '
                          or else U.Length (Squeezed) = 0
                          or else U.Element (Squeezed, U.Length (Squeezed))
                                  /= ' '
                        then
                           U.Append (Squeezed, C);
                        end if;
                     end loop;

                     if U.To_String (Squeezed) = U.To_String (Ours) then
                        Agreed := Agreed + 1;
                     else
                        Differed := Differed + 1;
                        Ada.Text_IO.Put_Line
                          (Ada.Directories.Simple_Name (Path) & " case"
                           & Positive'Image (Index) & " differs:");
                        Ada.Text_IO.Put_Line
                          ("  ours:  " & U.To_String (Ours));
                        Ada.Text_IO.Put_Line
                          ("  llama: " & U.To_String (Squeezed));
                     end if;
                  end;
                  <<Next_Case>>
               end;
            end loop;

            Ada.Text_IO.Put_Line
              (Ada.Directories.Simple_Name (Path) & ":"
               & Natural'Image (Agreed) & " agree,"
               & Natural'Image (Differed) & " differ");
            Result.Agreed := Result.Agreed + Agreed;
            Result.Differed := Result.Differed + Differed;
            Result.Cases := Result.Cases + Agreed + Differed;
            Model_Runner.GGUF.Containers.Close (Item);
            Model_Runner.Byte_Sources.Files.Close (Source);
         end;
         <<Next_Model>>
      end loop;
      Ada.Text_IO.Close (List);
   end Run;

end Tokenizer_Cross;
