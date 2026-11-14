with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

package body Model_Runner.CLI.Mentions is

   use Ada.Strings.Unbounded;

   function Attached
     (Message : String;
      Named   : out Ada.Strings.Unbounded.Unbounded_String) return String
   is
      Result : Unbounded_String;
      Index  : Natural := Message'First;
   begin
      Named := Null_Unbounded_String;
      while Index <= Message'Last loop
         if Message (Index) = '@'
           and then (Index = Message'First or else Message (Index - 1) in ' ' | ASCII.LF | ASCII.HT | '(')
         then
            declare
               Stop : Natural := Index + 1;
            begin
               while Stop <= Message'Last and then Message (Stop) not in ' ' | ASCII.LF | ASCII.HT loop
                  Stop := Stop + 1;
               end loop;
               --  Punctuation that ends a sentence is not the path's.
               while Stop - 1 > Index and then Message (Stop - 1) in '.' | ',' | ';' | ':' | '!' | '?' | ')' loop
                  Stop := Stop - 1;
               end loop;
               declare
                  Path : constant String := Message (Index + 1 .. Stop - 1);
               begin
                  if Path /= ""
                    and then Ada.Strings.Fixed.Index (To_String (Named), Path) = 0
                    and then Ada.Directories.Exists (Path)
                    and then Ada.Directories."=" (Ada.Directories.Kind (Path), Ada.Directories.Ordinary_File)
                  then
                     declare
                        Size   : constant Natural :=
                          Natural'Min (Natural (Ada.Directories.Size (Path)), Most_Bytes);
                        Whole  : constant Natural := Natural (Ada.Directories.Size (Path));
                        File   : Ada.Streams.Stream_IO.File_Type;
                        Buffer : String (1 .. Size);
                        Text   : Boolean := True;
                     begin
                        Ada.Streams.Stream_IO.Open (File, Ada.Streams.Stream_IO.In_File, Path, Form => "shared=yes");
                        String'Read (Ada.Streams.Stream_IO.Stream (File), Buffer);
                        Ada.Streams.Stream_IO.Close (File);
                        --  A NUL is no text: the file is left out.
                        for C of Buffer loop
                           if C = ASCII.NUL then
                              Text := False;
                              exit;
                           end if;
                        end loop;
                        if Text then
                           Append (Result,
                                   ASCII.LF & "The file " & Path & ", attached by the user"
                                   & (if Whole > Size then " (its first" & Natural'Image (Size) & " bytes of"
                                                           & Natural'Image (Whole) & ")" else "")
                                   & ":" & ASCII.LF & "```" & ASCII.LF & Buffer
                                   & (if Size > 0 and then Buffer (Buffer'Last) /= ASCII.LF
                                      then [1 => ASCII.LF] else "")
                                   & "```" & ASCII.LF);
                           Append (Named, (if Length (Named) = 0 then "" else ", ") & Path);
                        end if;
                     exception
                        when others =>
                           if Ada.Streams.Stream_IO.Is_Open (File) then
                              Ada.Streams.Stream_IO.Close (File);
                           end if;
                     end;
                  end if;
               end;
               Index := Stop;
            end;
         else
            Index := Index + 1;
         end if;
      end loop;
      return To_String (Result);
   end Attached;

end Model_Runner.CLI.Mentions;
