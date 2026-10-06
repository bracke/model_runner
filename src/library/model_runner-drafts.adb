with Ada.Directories;
with Ada.Strings.Fixed;

with Model_Runner.Errors;
with Model_Runner.GGUF.Shards;
with Model_Runner.Text;

with Ada.Streams.Stream_IO;

package body Model_Runner.Drafts is

   package E renames Model_Runner.Errors;
   package Containers renames Model_Runner.GGUF.Containers;
   package Shards renames Model_Runner.GGUF.Shards;

   ----------
   -- Find --
   ----------

   function Find
     (Directory  : String;
      Model_Path : String;
      Model      : Model_Runner.GGUF.Containers.Container;
      Words      : Model_Runner.Tokenizer.Vocabulary;
      Share      : Positive := Default_Share;
      Least      : Long_Long_Integer := Default_Least) return String
   is
      use Ada.Directories;

      Dir : String renames Directory;

      Model_Bytes : Long_Long_Integer := 0;
      Best        : Model_Runner.Text.Bounded := Model_Runner.Text.Empty;
      Best_Bytes  : Long_Long_Integer := 0;

      Tokens_Key : constant String := "tokenizer.ggml.tokens";

      --  Whether a candidate's architecture and tokens are the model's.
      function Alike (Path : String) return Boolean is
         Source    : Shards.Shard_Set;
         Candidate : Containers.Container;
         Local     : E.Error_Info;
         Length    : Natural;
         Differ    : Natural := 0;
         Result    : Boolean := False;
      begin
         Shards.Open_Model (Source, Candidate, Path, Status => Local);
         if E.Is_Ok (Local)
           and then Containers.String_Value (Candidate, "general.architecture")
                    = Containers.String_Value (Model, "general.architecture")
         then
            Containers.Get_Array_Length
              (Candidate, Tokens_Key, Model_Runner.GGUF.Value_String, Length, Local);

            if E.Is_Ok (Local)
              and then Length > 0
              and then Length <= Model_Runner.Tokenizer.Size (Words)
            then
               for Index in 1 .. Length loop
                  declare
                     Value : String (1 .. 256);
                     Last  : Natural;
                  begin
                     Containers.Get_String_Element
                       (Candidate, Tokens_Key, Index, Value, Last, Local);
                     if E.Is_Error (Local)
                       or else Value (1 .. Last)
                               /= Model_Runner.Tokenizer.Token_Text
                                    (Words,
                                     Model_Runner.Tokenizer.Token_Id
                                       (Index - 1))
                     then
                        Differ := Differ + 1;
                     end if;
                  end;
                  exit when not Alike_Enough (Differ, Length);
               end loop;

               Result := Alike_Enough (Differ, Length);
            end if;
         end if;

         Containers.Close (Candidate);
         Shards.Close (Source);
         return Result;
      exception
         when others =>
            Shards.Close (Source);
            return False;
      end Alike;

      Search : Search_Type;
      Found  : Directory_Entry_Type;
   begin
      if Dir = "" or else not Exists (Dir) then
         return "";
      end if;

      begin
         Model_Bytes := Long_Long_Integer (Size (Model_Path));
      exception
         when others =>
            return "";
      end;

      Start_Search (Search, Dir, "*.gguf", [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Found);
         declare
            Path  : constant String := Full_Name (Found);
            Bytes : constant Long_Long_Integer :=
              Long_Long_Integer (Size (Found));
         begin
            if Bytes >= Least
              and then Bytes * Long_Long_Integer (Share) <= Model_Bytes
              and then Bytes > Best_Bytes
              and then Ada.Strings.Fixed.Index (Simple_Name (Path), "-of-") = 0
              and then Alike (Path)
            then
               Best := Model_Runner.Text.To_Bounded (Path);
               Best_Bytes := Bytes;
            end if;
         end;
      end loop;
      End_Search (Search);

      return Model_Runner.Text.To_String (Best);
   exception
      when others =>
         return "";
   end Find;

   ------------
   -- Paired --
   ------------

   function Paired (Model_Path : String; Store : String) return String is
      use Ada.Streams;

      Sidecar : constant String := Model_Path & ".draft";

      --  More than any path a sidecar needs; a larger file is not one.
      Most : constant := 4096;

      Handle : Stream_IO.File_Type;
      Bytes  : Stream_Element_Array (1 .. Most);
      Last   : Stream_Element_Offset := 0;
   begin
      if Model_Path = "" or else not Ada.Directories.Exists (Sidecar) then
         return "";
      end if;

      Stream_IO.Open (Handle, Stream_IO.In_File, Sidecar);
      Stream_IO.Read (Handle, Bytes, Last);
      Stream_IO.Close (Handle);

      declare
         Text : String (1 .. Natural (Last));
         Line_First : Positive := 1;

         Folder : constant String :=
           Ada.Directories.Containing_Directory
             (Ada.Directories.Full_Name (Model_Path));

         function Here (Path : String) return Boolean
         is (Path /= ""
             and then Ada.Directories.Exists (Path)
             and then Ada.Directories."="
                        (Ada.Directories.Kind (Path),
                         Ada.Directories.Ordinary_File));

         --  The draft a name names, or nothing.
         function Resolved (Named : String) return String
         is (if Named (Named'First) = '/'
             then (if Here (Named) then Named else "")
             elsif Here (Ada.Directories.Compose (Folder, Named))
             then Ada.Directories.Compose (Folder, Named)
             elsif Store /= ""
               and then Here (Ada.Directories.Compose (Store, Named))
             then Ada.Directories.Compose (Store, Named)
             else "");
      begin
         for Index in Text'Range loop
            Text (Index) :=
              Character'Val (Bytes (Stream_Element_Offset (Index)));
         end loop;

         --  The first line that is not empty, trimmed.
         for Index in Text'First .. Text'Last + 1 loop
            if Index > Text'Last
              or else Text (Index) = ASCII.LF
              or else Text (Index) = ASCII.CR
            then
               declare
                  Named : constant String :=
                    Ada.Strings.Fixed.Trim
                      (Text (Line_First .. Index - 1), Ada.Strings.Both);
               begin
                  if Named /= "" then
                     return Resolved (Named);
                  end if;
               end;
               Line_First := Index + 1;
            end if;
         end loop;
      end;

      return "";
   exception
      when others =>
         if Stream_IO.Is_Open (Handle) then
            Stream_IO.Close (Handle);
         end if;
         return "";
   end Paired;

end Model_Runner.Drafts;
