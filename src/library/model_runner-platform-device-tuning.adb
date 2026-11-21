with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;

with Interfaces;

with Hostkit.Durability;
with Hostkit.Fs;
with Hostkit.Host;

with Model_Runner.Shaders;
with Model_Runner.Shaders.Attend;

package body Model_Runner.Platform.Device.Tuning is

   use type Hostkit.Durability.Outcome;
   use type Interfaces.Unsigned_64;

   Signature : constant String := "model-runner-device-tuning 1";

   function Is_Supported (Value : Launch_Choices) return Boolean
   is (Value.Attention_Workgroups in 64 | 128 | 256 | 512
       and then Value.Attention_Slice_Least in 128 | 256 | 512
       and then Value.Attention_Slice_Limit in 4 | 8 | 16
       and then Value.Row_Product_Workgroup in 128 | 256
       and then Value.Packed_Bundle_Least in 128 | 256 | 512
       --  No dispatch currently distinguishes a packed round, so False
       --  has no measured path and is not yet a profile alternative.
       and then Value.Packed_Cuts_A_Round
       and then Value.Matrix_Row_Crossover in 2 .. 128);

   ------------------
   -- Shader_Stamp --
   ------------------

   function Shader_Stamp return String is
      package S renames Model_Runner.Shaders;
      package A renames Model_Runner.Shaders.Attend;
      Digest : Interfaces.Unsigned_64 := 16#CBF29CE484222325#;

      procedure Mix (Value : Interfaces.Unsigned_64) is
      begin
         Digest := (Digest xor Value) * 16#100000001B3#;
      end Mix;
   begin
      Mix (S.Row_Product_Digest);
      Mix (S.Matrix_Product_Digest);
      Mix (S.Matrix_Narrow_Digest);
      Mix (S.Matrix_Wider_Digest);
      Mix (A.Attention_Digest);
      Mix (A.Attention_Bundled_Digest);
      Mix (A.Attention_Matrix_Digest);
      Mix (A.Attention_Token_Digest);
      Mix (A.Attention_Token_Packed_Digest);
      Mix (A.Attention_Packed_Digest);
      Mix (A.Attention_Packed_Subgroups_Digest);
      Mix (S.Merge_Digest);
      return Interfaces.Unsigned_64'Image (Digest);
   end Shader_Stamp;

   protected Parts is
      procedure Next (Value : out Natural);
   private
      Value : Natural := 0;
   end Parts;

   protected body Parts is
      procedure Next (Value : out Natural) is
      begin
         Parts.Value := (if Parts.Value = Natural'Last then 1
                         else Parts.Value + 1);
         Value := Parts.Value;
      end Next;
   end Parts;

   function Plain (Value : Natural) return String is
      Text : constant String := Natural'Image (Value);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Plain;

   function Bit (Value : Boolean) return Character
   is (if Value then '1' else '0');

   function Word (Value : Boolean) return String
   is (if Value then "true" else "false");

   function Hex
     (Value : Interfaces.Unsigned_64; Width : Positive) return String
   is
      Alphabet : constant String := "0123456789abcdef";
      Result   : String (1 .. Width);
      Rest     : Interfaces.Unsigned_64 := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Alphabet (Natural (Rest mod 16) + 1);
         Rest := Rest / 16;
      end loop;
      return Result;
   end Hex;

   function Safe_Stamp (Value : String) return Boolean is
   begin
      if Value'Length = 0 or else Value'Length > 256 then
         return False;
      end if;
      for Char of Value loop
         if Character'Pos (Char) < 32 or else Character'Pos (Char) = 127 then
            return False;
         end if;
      end loop;
      return True;
   end Safe_Stamp;

   function UUID_Image (Value : Device_UUID) return String is
      Result : String (1 .. 2 * UUID_Bytes);
   begin
      for Index in Value'Range loop
         Result (2 * Index - 1 .. 2 * Index) :=
           Hex (Interfaces.Unsigned_64 (Value (Index)), 2);
      end loop;
      return Result;
   end UUID_Image;

   ----------------
   -- Create_Key --
   ----------------

   function Create_Key
     (Identity      : Device_Identity;
      Shader_Stamp  : String;
      Program_Stamp : String) return Tuning_Key
   is
   begin
      if not Identity.Present
        or else not Safe_Stamp (Shader_Stamp)
        or else not Safe_Stamp (Program_Stamp)
      then
         return (others => <>);
      end if;

      declare
         Text : constant String :=
           "schema=" & Plain (Schema_Version)
           & "|vendor=" & Hex (Interfaces.Unsigned_64 (Identity.Vendor_Id), 8)
           & "|device=" & Hex (Interfaces.Unsigned_64 (Identity.Device_Id), 8)
           & "|driver=" & Hex (Interfaces.Unsigned_64 (Identity.Driver_Version), 8)
           & "|uuid=" & UUID_Image (Identity.Pipeline_Cache_UUID)
           & "|matrix=" & Bit (Identity.Matrix_Instruction)
           & "|subgroup=" & Bit (Identity.Subgroup_Arithmetic)
           & "|sized=" & Bit (Identity.Sized_Subgroups)
           & "|dot=" & Bit (Identity.Integer_Dot)
           & "|shader=" & Plain (Shader_Stamp'Length) & ":" & Shader_Stamp
           & "|program=" & Plain (Program_Stamp'Length) & ":" & Program_Stamp;
      begin
         if Text'Length > Max_Key_Bytes then
            return (others => <>);
         end if;
         declare
            Result : Tuning_Key;
         begin
            Result.Last := Text'Length;
            Result.Text (1 .. Text'Length) := Text;
            return Result;
         end;
      end;
   end Create_Key;

   function Is_Valid (Key : Tuning_Key) return Boolean is (Key.Last > 0);

   function Image (Key : Tuning_Key) return String
   is (Key.Text (1 .. Key.Last));

   function Key_Digest (Key : Tuning_Key) return String is
      Value : Interfaces.Unsigned_64 := 16#CBF2_9CE4_8422_2325#;
   begin
      for Char of Image (Key) loop
         Value := (Value xor Interfaces.Unsigned_64 (Character'Pos (Char)))
           * 16#0000_0100_0000_01B3#;
      end loop;
      return Hex (Value, 16);
   end Key_Digest;

   ------------------
   -- Profile_Path --
   ------------------

   function Profile_Path (Key : Tuning_Key) return String is
      Prefill : constant String := Model_Runner.Platform.Cache_Directory;
   begin
      if not Is_Valid (Key) or else Prefill = "" then
         return "";
      end if;
      return Hostkit.Fs.Join
        (Hostkit.Fs.Join
           (Ada.Directories.Containing_Directory (Prefill), "tuning"),
         Key_Digest (Key) & ".tuning");
   exception
      when others =>
         return "";
   end Profile_Path;

   function Serialize
     (Key : Tuning_Key; Value : Launch_Choices) return String
   is
   begin
      return Signature & ASCII.LF
        & "key=" & Image (Key) & ASCII.LF
        & "attention_workgroups=" & Plain (Value.Attention_Workgroups) & ASCII.LF
        & "attention_slice_least=" & Plain (Value.Attention_Slice_Least) & ASCII.LF
        & "attention_slice_limit=" & Plain (Value.Attention_Slice_Limit) & ASCII.LF
        & "row_product_workgroup=" & Plain (Value.Row_Product_Workgroup) & ASCII.LF
        & "packed_bundle_least=" & Plain (Value.Packed_Bundle_Least) & ASCII.LF
        & "packed_cuts_a_round=" & Word (Value.Packed_Cuts_A_Round) & ASCII.LF
        & "matrix_row_crossover=" & Plain (Value.Matrix_Row_Crossover) & ASCII.LF;
   end Serialize;

   procedure Number
     (Text  : String;
      Limit : Natural;
      Value : out Natural;
      Ok    : in out Boolean)
   is
      Held : Natural := 0;
   begin
      if not Ok or else Text'Length = 0 then
         Ok := False;
         Value := 0;
         return;
      end if;
      for Char of Text loop
         if Char not in '0' .. '9'
           or else Held > (Limit - Natural'Min (Limit, Character'Pos (Char) - Character'Pos ('0'))) / 10
         then
            Ok := False;
            Value := 0;
            return;
         end if;
         Held := Held * 10 + Character'Pos (Char) - Character'Pos ('0');
      end loop;
      if Held = 0 or else Held > Limit then
         Ok := False;
      end if;
      Value := Held;
   end Number;

   procedure Parse
     (Text     : String;
      Expected : Tuning_Key;
      Value    : out Launch_Choices;
      Found    : out Boolean)
   is
      Seen_Key, Seen_Workgroups, Seen_Slice_Least, Seen_Slice_Limit,
      Seen_Row, Seen_Bundle, Seen_Round, Seen_Crossover : Boolean := False;
      Good  : Boolean := Is_Valid (Expected);
      First : Natural := Text'First;
      Line_Number : Natural := 0;

      procedure Take (Line : String) is
         Mark : constant Natural := Ada.Strings.Fixed.Index (Line, "=");
         Numbered : Natural;
      begin
         Line_Number := Line_Number + 1;
         if Line_Number = 1 then
            Good := Good and then Line = Signature;
            return;
         elsif Mark = 0 or else Mark = Line'First then
            Good := False;
            return;
         end if;

         declare
            Name : constant String := Line (Line'First .. Mark - 1);
            Data : constant String := Line (Mark + 1 .. Line'Last);
         begin
            if Name = "key" and then not Seen_Key then
               Seen_Key := True;
               Good := Good and then Data = Image (Expected);
            elsif Name = "attention_workgroups" and then not Seen_Workgroups then
               Seen_Workgroups := True;
               Number (Data, Workgroup_Count'Last, Numbered, Good);
               if Good then
                  Value.Attention_Workgroups := Numbered;
               end if;
            elsif Name = "attention_slice_least" and then not Seen_Slice_Least then
               Seen_Slice_Least := True;
               Number (Data, Position_Count'Last, Numbered, Good);
               if Good then
                  Value.Attention_Slice_Least := Numbered;
               end if;
            elsif Name = "attention_slice_limit" and then not Seen_Slice_Limit then
               Seen_Slice_Limit := True;
               Number (Data, Slice_Count'Last, Numbered, Good);
               if Good then
                  Value.Attention_Slice_Limit := Numbered;
               end if;
            elsif Name = "row_product_workgroup" and then not Seen_Row then
               Seen_Row := True;
               Number (Data, Workgroup_Count'Last, Numbered, Good);
               if Good then
                  Value.Row_Product_Workgroup := Numbered;
               end if;
            elsif Name = "packed_bundle_least" and then not Seen_Bundle then
               Seen_Bundle := True;
               Number (Data, Position_Count'Last, Numbered, Good);
               if Good then
                  Value.Packed_Bundle_Least := Numbered;
               end if;
            elsif Name = "packed_cuts_a_round" and then not Seen_Round then
               Seen_Round := True;
               if Data = "true" then
                  Value.Packed_Cuts_A_Round := True;
               elsif Data = "false" then
                  Value.Packed_Cuts_A_Round := False;
               else
                  Good := False;
               end if;
            elsif Name = "matrix_row_crossover" and then not Seen_Crossover then
               Seen_Crossover := True;
               Number (Data, Batch_Count'Last, Numbered, Good);
               if Good then
                  Value.Matrix_Row_Crossover := Numbered;
               end if;
            else
               --  Unknown and duplicate fields both invalidate the whole.
               Good := False;
            end if;
         end;
      end Take;
   begin
      Value := Default_Choices;
      Found := False;
      if Text'Length = 0 or else Text (Text'Last) /= ASCII.LF then
         return;
      end if;
      while Good and then First <= Text'Last loop
         declare
            Last : constant Natural := Ada.Strings.Fixed.Index
              (Text, String'(1 => ASCII.LF), From => First);
         begin
            if Last = 0 then
               Good := False;
            else
               Take (Text (First .. Last - 1));
               First := Last + 1;
            end if;
         end;
      end loop;
      Found := Good and then Line_Number = 9
        and then Seen_Key and then Seen_Workgroups and then Seen_Slice_Least
        and then Seen_Slice_Limit and then Seen_Row and then Seen_Bundle
        and then Seen_Round and then Seen_Crossover
        and then Is_Supported (Value);
      if not Found then
         Value := Default_Choices;
      end if;
   exception
      when others =>
         Value := Default_Choices;
         Found := False;
   end Parse;

   ----------
   -- Load --
   ----------

   procedure Load
     (Path     : String;
      Expected : Tuning_Key;
      Value    : out Launch_Choices;
      Found    : out Boolean)
   is
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      use type Ada.Directories.File_Size;
      File : File_Type;

      procedure Close_Quietly is
      begin
         if Is_Open (File) then
            Close (File);
         end if;
      exception
         when others =>
            null;
      end Close_Quietly;
   begin
      Value := Default_Choices;
      Found := False;
      if Path = "" or else not Is_Valid (Expected)
        or else not Ada.Directories.Exists (Path)
      then
         return;
      end if;
      declare
         Size : constant Ada.Directories.File_Size := Ada.Directories.Size (Path);
      begin
         if Size = 0 or else Size > Ada.Directories.File_Size (Max_Record_Bytes) then
            return;
         end if;
         declare
            Text : String (1 .. Natural (Size));
            Data : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length))
              with Import, Address => Text'Address;
            Last : Stream_Element_Offset := 0;
            Got  : Stream_Element_Offset;
         begin
            Open (File, In_File, Path, Form => "shared=no");
            while Last < Data'Last loop
               Read (File, Data (Last + 1 .. Data'Last), Got);
               exit when Got <= Last;
               Last := Got;
            end loop;
            Close (File);
            if Last = Data'Last then
               Parse (Text, Expected, Value, Found);
            end if;
         end;
      end;
   exception
      when others =>
         Close_Quietly;
         Value := Default_Choices;
         Found := False;
   end Load;

   -----------
   -- Store --
   -----------

   procedure Store
     (Path    : String;
      Key     : Tuning_Key;
      Value   : Launch_Choices;
      Written : out Boolean)
   is
      use Ada.Streams;
      use Ada.Streams.Stream_IO;
      Sequence : Natural;
      File     : File_Type;

      procedure Close_Quietly is
      begin
         if Is_Open (File) then
            Close (File);
         end if;
      exception
         when others =>
            null;
      end Close_Quietly;
   begin
      Written := False;
      if Path = "" or else not Is_Valid (Key)
        or else not Is_Supported (Value)
      then
         return;
      end if;
      Parts.Next (Sequence);
      declare
         Folder  : constant String := Ada.Directories.Containing_Directory (Path);
         Partial : constant String := Hostkit.Fs.Join
           (Folder, "." & Ada.Directories.Simple_Name (Path) & ".tuning-partial."
            & Ada.Strings.Fixed.Trim
                (Integer'Image (Hostkit.Host.Own_Process_Id), Ada.Strings.Both)
            & "." & Plain (Sequence));
         Text : constant String := Serialize (Key, Value);
         Data : Stream_Element_Array (1 .. Stream_Element_Offset (Text'Length))
           with Import, Address => Text'Address;
      begin
         Ada.Directories.Create_Path (Folder);
         Create (File, Out_File, Partial, Form => "shared=no");
         Write (File, Data);
         Close (File);
         if Hostkit.Durability.Sync_File (Partial) = Hostkit.Durability.Failed
           or else not Hostkit.Fs.Replace_File (Partial, Path)
           or else Hostkit.Durability.Sync_Directory (Folder)
                     = Hostkit.Durability.Failed
         then
            if Ada.Directories.Exists (Partial) then
               Ada.Directories.Delete_File (Partial);
            end if;
            return;
         end if;
         Written := True;
      exception
         when others =>
            Close_Quietly;
            begin
               if Ada.Directories.Exists (Partial) then
                  Ada.Directories.Delete_File (Partial);
               end if;
            exception
               when others =>
                  null;
            end;
      end;
   end Store;

end Model_Runner.Platform.Device.Tuning;
