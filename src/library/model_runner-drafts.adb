with Ada.Directories;
with Ada.Strings.Fixed;

with Model_Runner.Errors;
with Model_Runner.GGUF.Shards;
with Model_Runner.Text;

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

end Model_Runner.Drafts;
