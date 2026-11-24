with Ada.Directories;
with Jsonlib.Documents;
with Jsonlib.Parsers;
with Jsonlib.Serializers;
with Jsonlib.Errors;
with Hostkit;
with Ada.Strings.Unbounded;
with Learning_Lora_Files;
with Campaign_Statistics;
with Model_Runner.Text;
with Project_Tools.Files;

package body Learning_Report is
   package J renames Jsonlib.Documents;
   package E renames Model_Runner.Errors;
   use Ada.Strings.Unbounded;
   use type J.Value_Kind;
   use type Ada.Directories.File_Size;
   function Text (Doc : J.Document; Node : J.Node; Key : String) return String is
     (if J.Kind (Doc, Node) = J.Object_Value and then J.Has_Member (Doc, Node, Key)
       and then J.Kind (Doc, J.Member (Doc, Node, Key)) = J.String_Value
      then J.As_String (Doc, J.Member (Doc, Node, Key)) else "");
   procedure Run (Root, Output : String; Status : out E.Error_Info) is
      Manifest, Doc, Statistics : J.Document;
      Object : constant J.Node := J.New_Object (Doc);
      Attempts : constant J.Node := J.New_Array (Doc);
      Error : Jsonlib.Errors.Error_Info;
      Tasks : constant Hostkit.String_Vectors.Vector :=
        [To_Unbounded_String ("edit"), To_Unbounded_String ("times-negative"), To_Unbounded_String ("subtract")];
      function Read (Path : String; Into : in out J.Document) return Boolean is
      begin
         if not Ada.Directories.Exists (Path) or else Ada.Directories.Size (Path) > 1_048_576 then
            return False;
         end if;
         Jsonlib.Parsers.Parse (Project_Tools.Files.Read_Raw_File (Path), Into, Error);
         return not Jsonlib.Errors.Failed (Error) and then J.Kind (Into, J.Root (Into)) = J.Object_Value;
      end Read;
   begin
      Status := E.Success;
      if Ada.Directories.Exists (Output) or else not Read (Root & "/manifest.json", Manifest) then
         Status := E.Make (E.IO_Read_Failed);
         return;
      end if;
      for Role in 1 .. 2 loop
         declare
            Stem : constant String := (if Role = 1 then "base" else "adapted");
         begin
            if Learning_Lora_Files.Digest (Text (Manifest, J.Root (Manifest), Stem & "_path")) /=
              Text (Manifest, J.Root (Manifest), Stem & "_sha256")
            then
               Status := E.Make (E.IO_Read_Failed);
               return;
            end if;
         end;
      end loop;
      J.Set_Root (Doc, Object);
      J.Insert (Doc, Object, "schema", J.New_String (Doc, "model_runner.mellum_learning_results.v1"));
      J.Insert (Doc, Object, "manifest", J.Copy (Doc, Manifest, J.Root (Manifest)));
      for Task_Name of Tasks loop
         for Seed in 51 .. 53 loop
            for Role in 1 .. 2 loop
               declare
                  Arm : constant String := (if Role = 1 then "base" else "adapted");
                  Path : constant String := Root & "/" & To_String (Task_Name) & "-"
                    & Model_Runner.Text.Image (Long_Long_Integer (Seed)) & "-" & Arm & "/result.json";
                  Item : J.Document;
               begin
                  if not Read (Path, Item) or else Text (Item, J.Root (Item), "state") /= "finished"
                    or else Text (Item, J.Root (Item), "grade") not in "passed" | "failed"
                    or else Text (Item, J.Root (Item), "task") /= To_String (Task_Name)
                    or else Text (Item, J.Root (Item), "arm") /= Arm
                    or else J.As_Integer (Item, J.Member (Item, J.Root (Item), "seed")) /= Long_Long_Integer (Seed)
                    or else Text (Item, J.Root (Item), "isolation") /= "bubblewrap-v1"
                  then
                     Status := E.Make (E.IO_Read_Failed);
                     return;
                  end if;
                  if Jsonlib.Serializers.To_String
                    (Item, J.Member (Item, J.Root (Item), "configuration_before")) /=
                      Jsonlib.Serializers.To_String (Item, J.Member (Item, J.Root (Item), "configuration_after"))
                  then
                     Status := E.Make (E.IO_Read_Failed);
                     E.Add_Frame (Status, "learning.evaluation.configuration_changed");
                     return;
                  end if;
                  J.Append (Doc, Attempts, J.Copy (Doc, Item, J.Root (Item)));
               end;
            end loop;
         end loop;
      end loop;
      J.Insert (Doc, Object, "attempts", Attempts);
      for Pair in 0 .. 8 loop
         declare
            Base : constant J.Node := J.Element (Doc, Attempts, Pair * 2 + 1);
            Adapted : constant J.Node := J.Element (Doc, Attempts, Pair * 2 + 2);
            Keys : constant Hostkit.String_Vectors.Vector :=
              [To_Unbounded_String ("backend"), To_Unbounded_String ("context_size"),
               To_Unbounded_String ("threads"), To_Unbounded_String ("cache_keys"),
               To_Unbounded_String ("cache_values"), To_Unbounded_String ("arithmetic"),
               To_Unbounded_String ("repack"), To_Unbounded_String ("batch_size"),
               To_Unbounded_String ("max_tokens"), To_Unbounded_String ("seed_given"),
               To_Unbounded_String ("seed"), To_Unbounded_String ("thinking"),
               To_Unbounded_String ("reasoning_effort"), To_Unbounded_String ("template"),
               To_Unbounded_String ("draft_tokens"), To_Unbounded_String ("draft_from_context"),
               To_Unbounded_String ("draft_from_next"), To_Unbounded_String ("draft_lookup"),
               To_Unbounded_String ("runtime_adapters"), To_Unbounded_String ("sampling")];
            Base_Settings : constant J.Node := J.Member (Doc, Base, "resolved_settings");
            Adapted_Settings : constant J.Node := J.Member (Doc, Adapted, "resolved_settings");
         begin
            if J.Kind (Doc, Base_Settings) /= J.Array_Value or else J.Kind (Doc, Adapted_Settings) /= J.Array_Value
              or else J.Length (Doc, Base_Settings) < 2 or else J.Length (Doc, Adapted_Settings) < 2
            then
               Status := E.Make (E.IO_Read_Failed);
               return;
            end if;
            for Snapshot in 1 .. 2 loop
               for Key of Keys loop
                  declare
                     Left : constant J.Node := J.Member
                       (Doc, J.Element (Doc, Base_Settings, Snapshot), To_String (Key));
                     Right : constant J.Node := J.Member
                       (Doc, J.Element (Doc, Adapted_Settings, Snapshot), To_String (Key));
                  begin
                     if not J.Is_Present (Left) or else not J.Is_Present (Right)
                       or else Jsonlib.Serializers.To_String (Doc, Left) /= Jsonlib.Serializers.To_String (Doc, Right)
                     then
                        Status := E.Make (E.IO_Read_Failed);
                        E.Add_Frame (Status, "learning.evaluation.settings_mismatch");
                        E.Add_Text (Status, "setting", To_String (Key), E.Param_Identifier);
                        return;
                     end if;
                  end;
               end loop;
            end loop;
         end;
      end loop;
      J.Insert (Doc, Object, "paired_settings_matched", J.New_Boolean (Doc, True));
      Jsonlib.Parsers.Parse (Campaign_Statistics.Describe (Doc, Attempts, Default_Only => True), Statistics, Error);
      if Jsonlib.Errors.Failed (Error) then
         Status := E.Make (E.IO_Read_Failed);
         return;
      end if;
      J.Insert (Doc, Object, "statistics", J.Copy (Doc, Statistics, J.Root (Statistics)));
      J.Insert (Doc, Object, "scope", J.New_String
        (Doc, "Nine paired attempts on three task families; descriptive pilot, no reliable general accuracy margin."));
      Project_Tools.Files.Write_Raw_File (Output, Jsonlib.Serializers.To_String (Doc) & ASCII.LF);
   exception
      when others =>
         Status := E.Make (E.IO_Read_Failed);
   end Run;
end Learning_Report;
