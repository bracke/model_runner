with Ada.Strings.Fixed;
with Ada.Directories;
with Hostkit.Fs;
with Jsonlib.Documents;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Jsonlib.Errors;
with Model_Runner.CLI.Run_Settings;
with Model_Runner.Errors;
with Model_Runner.Framework.Configurations;
with Model_Runner.Framework;
with Model_Runner.Framework.Records;
with Model_Runner.Framework.Stores;

package body Trial_Settings is

   package J renames Jsonlib.Documents;
   use type J.Value_Kind;
   use type Jsonlib.Errors.Error_Code;

   function Valid (JSON : String; Need_Work : Boolean := False) return Boolean is
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Sessions : Natural := 0;
      Roots : Natural := 0;
   begin
      if JSON'Length = 0 or else JSON'Length > 4_194_304 then
         return False;
      end if;
      Jsonlib.Parsers.Parse (JSON, Doc, Error,
        (Max_Depth => 16, Max_Length => 4_194_304, Duplicates => Jsonlib.Parsers.Refuse_Duplicates));
      if Error.Code /= Jsonlib.Errors.No_Error or else J.Kind (Doc, J.Root (Doc)) /= J.Array_Value
        or else J.Length (Doc, J.Root (Doc)) > 4_096
      then
         return False;
      end if;
      for Index in 1 .. J.Length (Doc, J.Root (Doc)) loop
         declare
            Item : constant J.Node := J.Element (Doc, J.Root (Doc), Index);
            function Field (Name : String) return J.Node is (J.Member (Doc, Item, Name));
            Role : constant String := J.As_String (Doc, Field ("role"));
         begin
            if J.Kind (Doc, Item) /= J.Object_Value or else J.As_Integer (Doc, Field ("schema_version")) /= 1
              or else Role not in "session" | "root" | "helper"
              or else J.Kind (Doc, Field ("sampling")) /= J.Object_Value
              or else J.As_Integer (Doc, Field ("context_size")) <= 0
              or else J.As_Integer (Doc, Field ("threads")) <= 0
              or else J.As_Integer (Doc, Field ("batch_size")) <= 0
              or else J.As_String (Doc, Field ("backend")) not in "cpu" | "reference" | "device"
              or else J.As_String (Doc, Field ("cache_keys")) = ""
              or else J.As_String (Doc, Field ("cache_values")) = ""
              or else J.As_String (Doc, Field ("arithmetic")) = ""
              or else J.As_String (Doc, Field ("thinking")) = ""
              or else J.Kind (Doc, Field ("seed_given")) /= J.Boolean_Value
            then
               return False;
            end if;
            for Key of Model_Runner.Framework.Name_Lists.Vector'
              (["temperature", "dynatemp_range", "dynatemp_exponent", "top_k", "top_p", "min_p", "top_a",
                "repeat_penalty", "repeat_window", "frequency_penalty", "presence_penalty", "typical_p",
                "tail_free", "xtc_probability", "xtc_threshold", "dry_multiplier", "dry_base",
                "dry_allowed_length", "mirostat", "mirostat_tau", "mirostat_eta"])
            loop
               if J.Kind (Doc, J.Member (Doc, Field ("sampling"), Key)) not in J.Integer_Value | J.Float_Value then
                  return False;
               end if;
            end loop;
            if Role = "session" then
               Sessions := Sessions + 1;
               if Index /= 1 then
                  return False;
               end if;
            elsif Sessions /= 1 or else J.As_Integer (Doc, Field ("round")) <= 0
              or else J.As_String (Doc, Field ("policy")) = ""
            then
               return False;
            elsif Role = "root" then
               Roots := Roots + 1;
            end if;
         end;
      end loop;
      return Sessions = 1 and then (not Need_Work or else Roots > 0);
   exception
      when others => return False;
   end Valid;

   function Matches
     (JSON : String; Seed, Context_Size : Natural; Thinking : Boolean; Adapters : Natural) return Boolean
   is
      Doc : J.Document;
      Error : Jsonlib.Errors.Error_Info;
      Seed_Text : constant String := Ada.Strings.Fixed.Trim (Natural'Image (Seed), Ada.Strings.Both);
   begin
      if not Valid (JSON) then
         return False;
      end if;
      Jsonlib.Parsers.Parse (JSON, Doc, Error);
      for Index in 1 .. J.Length (Doc, J.Root (Doc)) loop
         declare
            Item : constant J.Node := J.Element (Doc, J.Root (Doc), Index);
            function Field (Name : String) return J.Node is (J.Member (Doc, Item, Name));
         begin
            if not J.As_Boolean (Doc, Field ("seed_given")) or else J.As_String (Doc, Field ("seed")) /= Seed_Text
              or else J.As_String (Doc, Field ("thinking")) /= (if Thinking then "THINKING_ON" else "THINKING_OFF")
              or else J.As_Integer (Doc, Field ("runtime_adapters")) /= Long_Long_Integer (Adapters)
              or else (J.As_String (Doc, Field ("role")) /= "helper"
                       and then J.As_Integer (Doc, Field ("context_size")) /= Long_Long_Integer (Context_Size))
            then
               return False;
            end if;
         end;
      end loop;
      return True;
   exception
      when others => return False;
   end Matches;

   function Extract (Transcript : String; Clean : out Boolean) return String is
      Marker : constant String := Model_Runner.CLI.Run_Settings.Marker;
      Doc, Frame : J.Document;
      Frames : constant J.Node := J.New_Array (Doc);
      Error : Jsonlib.Errors.Error_Info;
      From : Positive := Transcript'First;
      Bytes : Natural := 0;
   begin
      Clean := False;
      J.Set_Root (Doc, Frames);
      for Index in Transcript'First .. Transcript'Last + 1 loop
         if Index > Transcript'Last or else Transcript (Index) = ASCII.LF then
            declare
               Line : constant String := Transcript (From .. Index - 1);
            begin
               if Line'Length >= Marker'Length
                 and then Line (Line'First .. Line'First + Marker'Length - 1) = Marker
               then
                  if Line'Length > 65_536 or else Bytes > 4_194_304 - Line'Length
                    or else J.Length (Doc, Frames) >= 4_096
                  then
                     return "";
                  end if;
                  Bytes := Bytes + Line'Length;
                  Jsonlib.Parsers.Parse (Line (Line'First + Marker'Length .. Line'Last), Frame, Error,
                    (Max_Depth => 16, Max_Length => 65_536, Duplicates => Jsonlib.Parsers.Refuse_Duplicates));
                  if Error.Code /= Jsonlib.Errors.No_Error then
                     return "";
                  end if;
                  J.Append (Doc, Frames, J.Copy (Doc, Frame, J.Root (Frame)));
               end if;
            end;
            From := Index + 1;
         end if;
      end loop;
      declare
         JSON : constant String := Jsonlib.Serializers.To_String (Doc);
      begin
         Clean := Valid (JSON);
         return (if Clean then JSON else "");
      end;
   exception
      when others => Clean := False; return "";
   end Extract;

   function Configuration (Project : String) return String is
      package S renames Model_Runner.Framework.Stores;
      package R renames Model_Runner.Framework.Records;
      Store : S.Store;
      Settings : R.Item;
      Status : Model_Runner.Errors.Error_Info;
      Doc : J.Document;
      Root : constant J.Node := J.New_Object (Doc);
      Fields : constant J.Node := J.New_Object (Doc);
      Entries : Natural := 0;
      function Safe_State (Path : String; Depth : Natural := 0) return Boolean is
         Search : Ada.Directories.Search_Type;
         Entry_Info : Ada.Directories.Directory_Entry_Type;
         Active : Boolean := False;
         use type Hostkit.Fs.Entry_Kind;
      begin
         Entries := Entries + 1;
         if Entries > 32_768 or else Depth > 32 or else Hostkit.Fs.Is_Link (Path) then
            return False;
         elsif Hostkit.Fs.Kind_Of (Path) = Hostkit.Fs.Ordinary_File_Entry then
            return True;
         elsif Hostkit.Fs.Kind_Of (Path) /= Hostkit.Fs.Directory_Entry then
            return False;
         end if;
         Ada.Directories.Start_Search (Search, Path, "");
         Active := True;
         while Ada.Directories.More_Entries (Search) loop
            Ada.Directories.Get_Next_Entry (Search, Entry_Info);
            if Ada.Directories.Simple_Name (Entry_Info) not in "." | ".."
              and then not Safe_State (Ada.Directories.Full_Name (Entry_Info), Depth + 1)
            then
               Ada.Directories.End_Search (Search);
               return False;
            end if;
         end loop;
         Ada.Directories.End_Search (Search);
         return True;
      exception
         when others =>
            if Active then
               Ada.Directories.End_Search (Search);
            end if;
            return False;
      end Safe_State;
   begin
      --  No model or tool process remains after work. Refuse filesystem
      --  aliases and special files before the parent opens a store or its lock.
      if not Safe_State (Project & "/.model_runner") then
         return "";
      end if;
      S.Open_To_Read (Store, Project, Status);
      if Model_Runner.Errors.Is_Ok (Status) then
         Model_Runner.Framework.Configurations.Read (Store, Settings, Status);
      end if;
      S.Close (Store);
      if Model_Runner.Errors.Is_Error (Status) then
         return "";
      end if;
      J.Set_Root (Doc, Root);
      J.Insert (Doc, Root, "revision", J.New_Integer (Doc, Long_Long_Integer (R.Revision (Settings))));
      for Index in 1 .. R.Field_Count (Settings) loop
         J.Insert (Doc, Fields, R.Field_Name (Settings, Index), J.New_String (Doc, R.Field_Value (Settings, Index)));
      end loop;
      J.Insert (Doc, Root, "fields", Fields);
      return Jsonlib.Serializers.To_String (Doc);
   exception
      when others => S.Close (Store); return "";
   end Configuration;

end Trial_Settings;
