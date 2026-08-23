with Ada.Strings.Fixed;

with Model_Runner.Byte_Sources.Files;
with Model_Runner.Byte_Sources.Memory;
with Model_Runner.Bytes;
with Model_Runner.Errors;
with Model_Runner.GGUF.Containers.Reader;

package body Fixture_Likeness is

   package B renames Model_Runner.Bytes;
   package Containers renames Model_Runner.GGUF.Containers;
   package E renames Model_Runner.Errors;
   package Files renames Model_Runner.Byte_Sources.Files;

   --  Room for every distinct folded name either side carries. A published
   --  file folds to a few dozen; the bound is generous and overflow is
   --  reported rather than silently dropped, because a dropped name is a
   --  difference this package would then claim does not exist.
   Room : constant := 256;

   type Slot is record
      Text       : String (1 .. Name_Limit) := [others => ' '];
      Last       : Natural := 0;
      In_File    : Boolean := False;
      In_Fixture : Boolean := False;
   end record;

   --  The names of the most recent comparison. A package variable rather
   --  than a field of the report so that the report stays a plain record
   --  the caller can copy; `Each_Name` is documented as walking the most
   --  recent comparison for the same reason.
   Names : array (1 .. Room) of Slot;
   Held  : Natural := 0;

   --  Fold a tensor name so that models of different depths compare.
   --
   --  `blk.17.attn_q.weight` and `blk.0.attn_q.weight` are the same tensor
   --  at different depths; without folding, a published file of thirty-two
   --  layers would report every one of them as a name the fixture does not
   --  write.
   --
   --  @param Name Tensor name as the file spells it.
   --  @return The name with any layer index replaced by a star.
   function Folded (Name : String) return String is
      Prefix : constant String := "blk.";
      Cut    : Natural;
   begin
      if Name'Length <= Prefix'Length
        or else Name (Name'First .. Name'First + Prefix'Length - 1) /= Prefix
      then
         return Name;
      end if;

      Cut := Name'First + Prefix'Length;
      while Cut <= Name'Last and then Name (Cut) in '0' .. '9' loop
         Cut := Cut + 1;
      end loop;

      --  A name beginning `blk.` with no digits after it is left alone: it
      --  is not a layer tensor, whatever else it is.
      if Cut = Name'First + Prefix'Length then
         return Name;
      end if;

      return Prefix & "*" & Name (Cut .. Name'Last);
   end Folded;

   --  Record one name against one side.
   --
   --  @param Name Folded tensor name.
   --  @param Side_Is_File Whether this sighting is from the published file.
   --  @param Overflowed Set when there was no room left.
   procedure Note
     (Name         : String;
      Side_Is_File : Boolean;
      Overflowed   : in out Boolean)
   is
      Kept : constant String :=
        Name (Name'First .. Natural'Min (Name'Last,
                                         Name'First + Name_Limit - 1));
   begin
      for Index in 1 .. Held loop
         if Names (Index).Text (1 .. Names (Index).Last) = Kept then
            if Side_Is_File then
               Names (Index).In_File := True;
            else
               Names (Index).In_Fixture := True;
            end if;
            return;
         end if;
      end loop;

      if Held = Room then
         Overflowed := True;
         return;
      end if;

      Held := Held + 1;
      Names (Held).Text (1 .. Kept'Length) := Kept;
      Names (Held).Last := Kept'Length;
      Names (Held).In_File := Side_Is_File;
      Names (Held).In_Fixture := not Side_Is_File;
   end Note;

   --  Which fixture architecture a declared name asks for.
   --
   --  @param Declared The file's `general.architecture`.
   --  @param Kind Fixture architecture to build.
   --  @param Known Whether there is a fixture for it at all.
   procedure Match_Architecture
     (Declared : String;
      Kind     : out Tiny_Model.Fixture_Architecture;
      Known    : out Boolean) is
   begin
      Known := True;
      if Declared = "llama" then
         Kind := Tiny_Model.Llama;
      elsif Declared = "qwen2" then
         Kind := Tiny_Model.Qwen2;
      elsif Declared = "qwen3" then
         Kind := Tiny_Model.Qwen3;
      elsif Declared = "qwen3moe" then
         Kind := Tiny_Model.Qwen3_MoE;
      elsif Declared = "gemma" then
         Kind := Tiny_Model.Gemma;
      elsif Declared = "gemma2" then
         Kind := Tiny_Model.Gemma2;
      elsif Declared = "gemma3" then
         Kind := Tiny_Model.Gemma3;
      elsif Declared = "phi3" then
         Kind := Tiny_Model.Phi3;
      elsif Declared = "phi2" then
         Kind := Tiny_Model.Phi2;
      elsif Declared = "falcon" then
         Kind := Tiny_Model.Falcon;
      elsif Declared = "gpt2" then
         Kind := Tiny_Model.GPT2;

      --  The three that produce states rather than a distribution. They were
      --  missing here for as long as they have existed, so the check written
      --  to catch a fixture describing a model nobody ships had never once
      --  been run against an embedding model -- which is the half of the
      --  architectures where a fixture written from a description and a
      --  reader written from the same description agreed about two faults.
      elsif Declared = "bert" then
         Kind := Tiny_Model.Bert;
      elsif Declared = "nomic-bert" then
         Kind := Tiny_Model.Nomic_Bert;
      elsif Declared = "jina-bert-v2" then
         Kind := Tiny_Model.Jina_Bert_V2;
      else
         Kind := Tiny_Model.Llama;
         Known := False;
      end if;
   end Match_Architecture;

   --  Say something about how the comparison ended.
   --
   --  @param Result Report to write into.
   --  @param Text What to say.
   procedure Say (Result : in out Report; Text : String) is
      Kept : constant String :=
        Text (Text'First .. Natural'Min (Text'Last,
                                         Text'First + Result.Detail'Length - 1));
   begin
      Result.Detail := [others => ' '];
      Result.Detail (1 .. Kept'Length) := Kept;
      Result.Detail_Last := Kept'Length;
   end Say;

   procedure Compare (Path : String; Result : out Report) is
      Source     : Files.File_Source;
      Published  : Containers.Container;
      Status     : E.Error_Info;
      Known      : Boolean;
      Overflowed : Boolean := False;
      Image      : B.Byte_Array_Access;
   begin
      Result := (others => <>);
      Held := 0;

      Files.Open (Source, Path, Files.Mapping_Automatic, 0, Status);
      if E.Is_Error (Status) then
         Result.Result := Skipped;
         Say (Result, "no file at " & Path);
         return;
      end if;

      Containers.Reader.Parse (Published, Source, Status => Status);
      if E.Is_Error (Status) then
         Result.Result := Rejected;
         Say (Result, E.Diagnostic_Code (Status.Code));
         Files.Close (Source);
         return;
      end if;

      Match_Architecture
        (Containers.String_Value (Published, "general.architecture"),
         Result.Kind, Known);
      if not Known then
         Result.Result := Skipped;
         Say (Result,
              "no fixture for architecture "
              & Containers.String_Value (Published, "general.architecture"));
         Containers.Close (Published);
         Files.Close (Source);
         return;
      end if;

      --  The shape follows the file. Comparing a dense model against the
      --  mixture fixture would report every expert matrix as invented,
      --  which is true and tells nobody anything.
      Result.Shape :=
        (if Containers.Has
           (Published,
            Containers.String_Value (Published, "general.architecture")
            & ".expert_count")
         then Tiny_Model.Mixed
         else Tiny_Model.Plain);

      if Tiny_Model.Cannot_Hold (Result.Kind, Result.Shape) then
         Result.Shape := Tiny_Model.Plain;
      end if;

      for Index in 1 .. Containers.Tensor_Count (Published) loop
         Note (Folded (Containers.Tensor_Name (Published, Index)),
               Side_Is_File => True, Overflowed => Overflowed);
      end loop;
      Containers.Close (Published);
      Files.Close (Source);

      --  The fixture, read the same way the engine reads it. Building it in
      --  memory keeps this from writing anything to the tree, which a check
      --  that runs against a caller's own model has no business doing.
      Tiny_Model.Build_Shaped
        (Image, Tiny_Model.F32, Result.Kind, Result.Shape);
      declare
         Held_Image : Model_Runner.Byte_Sources.Memory.Buffer_Source (Image);
         Fixture    : Containers.Container;
      begin
         Containers.Reader.Parse (Fixture, Held_Image, Status => Status);
         if E.Is_Error (Status) then
            Result.Result := Rejected;
            Say (Result, "the fixture did not parse: " & E.Diagnostic_Code (Status.Code));
            B.Free (Image);
            return;
         end if;

         for Index in 1 .. Containers.Tensor_Count (Fixture) loop
            Note (Folded (Containers.Tensor_Name (Fixture, Index)),
                  Side_Is_File => False, Overflowed => Overflowed);
         end loop;
         Containers.Close (Fixture);
      end;
      B.Free (Image);

      for Index in 1 .. Held loop
         if Names (Index).In_File then
            Result.Published := Result.Published + 1;
         end if;
         if Names (Index).In_Fixture then
            Result.Written := Result.Written + 1;
         end if;

         if Names (Index).In_File and then not Names (Index).In_Fixture then
            Result.Unwritten := Result.Unwritten + 1;
            if Result.First_Unwritten_Last = 0 then
               Result.First_Unwritten (1 .. Names (Index).Last) :=
                 Names (Index).Text (1 .. Names (Index).Last);
               Result.First_Unwritten_Last := Names (Index).Last;
            end if;
         elsif Names (Index).In_Fixture and then not Names (Index).In_File
         then
            Result.Invented := Result.Invented + 1;
            if Result.First_Invented_Last = 0 then
               Result.First_Invented (1 .. Names (Index).Last) :=
                 Names (Index).Text (1 .. Names (Index).Last);
               Result.First_Invented_Last := Names (Index).Last;
            end if;
         end if;
      end loop;

      Result.Result := Compared;
      if Overflowed then
         Say (Result,
              "more than" & Natural'Image (Room)
              & " distinct names; the comparison is incomplete");
      end if;
   end Compare;

   procedure Each_Name is
   begin
      for Index in 1 .. Held loop
         Visit (Names (Index).Text (1 .. Names (Index).Last),
                Names (Index).In_File, Names (Index).In_Fixture);
      end loop;
   end Each_Name;

   function Summary (Item : Report) return String is
      function Trimmed (Value : Natural) return String
      is (Ada.Strings.Fixed.Trim (Natural'Image (Value),
                                  Ada.Strings.Both));
   begin
      case Item.Result is
         when Skipped =>
            return "skipped, " & Detail_Text (Item);
         when Rejected =>
            return "rejected, " & Detail_Text (Item);
         when Compared =>
            return "architecture "
              & Tiny_Model.Fixture_Architecture'Image (Item.Kind)
              & ", shape " & Tiny_Model.Fixture_Shape'Image (Item.Shape)
              & ", published " & Trimmed (Item.Published)
              & ", fixture " & Trimmed (Item.Written)
              & ", unwritten " & Trimmed (Item.Unwritten)
              & (if Item.First_Unwritten_Last > 0
                 then " (" & Item.First_Unwritten
                        (1 .. Item.First_Unwritten_Last) & ")"
                 else "")
              & ", invented " & Trimmed (Item.Invented)
              & (if Item.First_Invented_Last > 0
                 then " (" & Item.First_Invented
                        (1 .. Item.First_Invented_Last) & ")"
                 else "");
      end case;
   end Summary;

end Fixture_Likeness;
