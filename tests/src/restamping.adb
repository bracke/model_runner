with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Interfaces;

package body Restamping is

   use Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;

   Record_Path : constant String := "docs/measured-figures.txt";

   --  A file's bytes, or nothing with Found false.
   function Read
     (Path : String; Found : out Boolean) return String
   is
      use Ada.Streams;
   begin
      Found := False;
      if not Ada.Directories.Exists (Path) then
         return "";
      end if;

      declare
         File : Stream_IO.File_Type;
         Size : constant Natural := Natural (Ada.Directories.Size (Path));
         Room : Stream_Element_Array
           (1 .. Stream_Element_Offset (Natural'Max (Size, 1)));
         Last : Stream_Element_Offset := 0;
         Text : String (1 .. Size);
      begin
         Stream_IO.Open (File, Stream_IO.In_File, Path);
         if Size > 0 then
            Stream_IO.Read (File, Room, Last);
         end if;
         Stream_IO.Close (File);

         for Index in 1 .. Natural (Last) loop
            Text (Index) :=
              Character'Val (Room (Stream_Element_Offset (Index)));
         end loop;

         Found := Natural (Last) = Size;
         return Text (1 .. Natural (Last));
      end;
   end Read;

   --  Sixteen hex digits, upper case, as the record writes them.
   function Hex (Value : Interfaces.Unsigned_64) return String is
      Digits_Text : constant String := "0123456789ABCDEF";
      Result_Text : String (1 .. 16);
      Left        : Interfaces.Unsigned_64 := Value;
   begin
      for Index in reverse Result_Text'Range loop
         Result_Text (Index) :=
           Digits_Text (Digits_Text'First + Natural (Left and 16#F#));
         Left := Interfaces.Shift_Right (Left, 4);
      end loop;
      return Result_Text;
   end Hex;

   ---------
   -- Run --
   ---------

   procedure Run
     (Root  : String;
      Note  : String;
      Moved : out Natural;
      Good  : out Boolean)
   is
      Path   : constant String := Root & "/" & Record_Path;
      Found  : Boolean;
      Listing : constant String := Read (Path, Found);

      Written : Unbounded_String;
      From    : Positive := Listing'First;

      --  The note as comment lines, each ending its line.
      function Comment return String is
         Said  : Unbounded_String;
         Start : Positive := Note'First;
      begin
         for Index in Note'First .. Note'Last + 1 loop
            if Index > Note'Last or else Note (Index) = Character'Val (10)
            then
               Append (Said, "# " & Note (Start .. Index - 1)
                             & Character'Val (10));
               Start := Index + 1;
            end if;
         end loop;
         return To_String (Said);
      end Comment;

      --  The Nth space-separated word of a line, or nothing.
      function Word (Line : String; Wanted : Positive) return String is
         Seen  : Natural := 0;
         Start : Natural := 0;
      begin
         for Index in Line'Range loop
            if Line (Index) /= ' ' then
               if Start = 0 then
                  Start := Index;
                  Seen := Seen + 1;
               end if;
               if Seen = Wanted
                 and then (Index = Line'Last or else Line (Index + 1) = ' ')
               then
                  return Line (Start .. Index);
               end if;
            else
               Start := 0;
            end if;
         end loop;
         return "";
      end Word;
   begin
      Moved := 0;
      Good := Found;
      if not Good then
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, Record_Path & " could not be read");
         return;
      end if;

      while From <= Listing'Last loop
         declare
            Stop : Natural := From;
         begin
            while Stop <= Listing'Last
              and then Listing (Stop) /= Character'Val (10)
            loop
               Stop := Stop + 1;
            end loop;

            declare
               Line  : constant String := Listing (From .. Stop - 1);
               Name  : constant String := Word (Line, 1);
               Known : constant String := Word (Line, 2);
               Sum   : Interfaces.Unsigned_64 := 16#CBF29CE484222325#;
               Which : Positive := 3;
            begin
               --  A record line, as the check reads one: a word that is not
               --  a comment, its digest, and the sources the digest is of,
               --  their bytes in order but for carriage returns.
               if Name'Length > 0 and then Name (Name'First) /= '#'
                 and then Word (Line, 3)'Length > 0
               then
                  loop
                     declare
                        Source : constant String := Word (Line, Which);
                        Here   : Boolean;
                     begin
                        exit when Source'Length = 0;
                        declare
                           Text_Of : constant String :=
                             Read (Root & "/" & Source, Here);
                        begin
                           if not Here then
                              Ada.Text_IO.Put_Line
                                (Ada.Text_IO.Standard_Error,
                                 Record_Path & " names " & Source
                                 & ", which is not there");
                              Good := False;
                              return;
                           end if;
                           for Letter of Text_Of loop
                              if Letter /= Character'Val (13) then
                                 Sum :=
                                   (Sum xor Interfaces.Unsigned_64
                                      (Character'Pos (Letter)))
                                   * 16#100000001B3#;
                              end if;
                           end loop;
                        end;
                     end;
                     Which := Which + 1;
                  end loop;

                  if Hex (Sum) /= Known then
                     declare
                        At_Known : constant Natural :=
                          Ada.Strings.Fixed.Index
                            (Line (Line'First + Name'Length .. Line'Last),
                             Known);
                     begin
                        Append (Written, Comment);
                        Append (Written,
                                Line (Line'First .. At_Known - 1) & Hex (Sum)
                                & Line (At_Known + Known'Length .. Line'Last));
                        Moved := Moved + 1;
                        Ada.Text_IO.Put_Line ("  " & Name & " " & Hex (Sum));
                     end;
                  else
                     Append (Written, Line);
                  end if;
               else
                  Append (Written, Line);
               end if;

               if Stop <= Listing'Last then
                  Append (Written, Character'Val (10));
               end if;
            end;

            From := Stop + 1;
         end;
      end loop;

      if Moved > 0 then
         declare
            File : Ada.Streams.Stream_IO.File_Type;
            Text : constant String := To_String (Written);
         begin
            Ada.Streams.Stream_IO.Create
              (File, Ada.Streams.Stream_IO.Out_File, Path);
            String'Write (Ada.Streams.Stream_IO.Stream (File), Text);
            Ada.Streams.Stream_IO.Close (File);
         end;
      end if;
   end Run;

end Restamping;
