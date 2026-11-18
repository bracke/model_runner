with Ada.Directories;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

with CryptoLib.Hashes;
with Hostkit.Fs;
with Jsonlib.Documents;
with Jsonlib.Errors;
with Jsonlib.Parsers;

with Model_Runner.Backend.Device;
with Model_Runner.Expert_Cache;
with Model_Runner.Heap_Buffers;
with Model_Runner.Llama;
with Model_Runner.Platform;
with Model_Runner.Platform.Device.Products;
with Model_Runner.Text;

package body Model_Runner.Expert_Cache_Recommendations is

   package Doc renames Jsonlib.Documents;
   package US renames Ada.Strings.Unbounded;
   use type Interfaces.Unsigned_64;
   use type Jsonlib.Documents.Value_Kind;

   Max_Entries : constant := 128;
   Max_Registry_Bytes : constant := 1_048_576;

   type Recommendation_Entry is record
      Digest   : US.Unbounded_String;
      Engine   : US.Unbounded_String;
      Device   : US.Unbounded_String;
      Protocol : US.Unbounded_String;
      Report   : US.Unbounded_String;
      Device_Memory : Interfaces.Unsigned_64 := 0;
      Bytes    : Interfaces.Unsigned_64 := 0;
   end record;

   type Entry_List is
     array (Positive range 1 .. Max_Entries) of Recommendation_Entry;

   function Selected_Path (Asked : String) return String is
     (if Asked /= "" then Asked
      else Model_Runner.Platform.Expert_Cache_Recommendations_File);

   function Engine_Identity return String is
     (Model_Runner.Version & ":"
      & Model_Runner.Llama'Body_Version & ":"
      & Model_Runner.Expert_Cache'Body_Version & ":"
      & Model_Runner.Backend.Device'Body_Version & ":"
      & Model_Runner.Platform.Device.Products'Body_Version & ":"
      & Model_Runner.Llama.Arithmetic_Name
          (Model_Runner.Llama.Integer_Activations) & ":"
      & Model_Runner.Expert_Cache.Observation_Outcome'Image
          (Model_Runner.Expert_Cache.Cache_Hit) & ":"
      & Natural'Image (Model_Runner.Backend.Device.Block_Limit) & ":"
      & Interfaces.Unsigned_64'Image
          (Model_Runner.Platform.Device.Products.Max_Elements));

   function Artifact_Digest (Path : String) return String is
      use Ada.Streams;
      package SIO renames Ada.Streams.Stream_IO;
      Context : CryptoLib.Hashes.SHA256_Context;
      File    : SIO.File_Type;
      Room    : Model_Runner.Heap_Buffers.Bytes (4 * 1_024 * 1_024);
      Buffer  : Stream_Element_Array renames Room.Data.all;
      Last    : Stream_Element_Offset;
      Digest  : CryptoLib.Hashes.SHA256_Digest;
      Hex     : constant String := "0123456789abcdef";
      Result  : String (1 .. 64);
   begin
      CryptoLib.Hashes.Initialize_SHA256 (Context);
      SIO.Open (File, SIO.In_File, Path, Form => "shared=yes");
      while not SIO.End_Of_File (File) loop
         SIO.Read (File, Buffer, Last);
         CryptoLib.Hashes.Update (Context, Buffer (1 .. Last));
      end loop;
      SIO.Close (File);
      Digest := CryptoLib.Hashes.Finalize (Context);
      for Index in Digest'Range loop
         Result (2 * Index - 1) := Hex (Natural (Digest (Index)) / 16 + 1);
         Result (2 * Index) := Hex (Natural (Digest (Index)) mod 16 + 1);
      end loop;
      return Result;
   exception
      when others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;
         return [1 .. 64 => '0'];
   end Artifact_Digest;

   procedure Read
     (Path    : String;
      Entries : in out Entry_List;
      Count   : out Natural;
      Valid   : out Boolean)
   is
      use Ada.Streams;
      package SIO renames Ada.Streams.Stream_IO;
      File   : SIO.File_Type;
      Error  : Jsonlib.Errors.Error_Info;
      Parsed : Doc.Document;
   begin
      Count := 0;
      Valid := False;
      if Path = "" or else not Ada.Directories.Exists (Path) then
         Valid := True;
         return;
      end if;
      SIO.Open (File, SIO.In_File, Path, Form => "shared=yes");
      declare
         Size : constant SIO.Count := SIO.Size (File);
         use type SIO.Count;
      begin
         if Size = 0 or else Size > SIO.Count (Max_Registry_Bytes) then
            SIO.Close (File);
            return;
         end if;
         declare
            Bytes : Model_Runner.Heap_Buffers.Bytes
              (Stream_Element_Offset (Size));
            Text  : Model_Runner.Heap_Buffers.Text (Natural (Size));
            Last  : Stream_Element_Offset;
         begin
            SIO.Read (File, Bytes.Data.all, Last);
            SIO.Close (File);
            for Index in 1 .. Last loop
               Text.Data (Natural (Index)) :=
                 Character'Val (Natural (Bytes.Data (Index)));
            end loop;
            Jsonlib.Parsers.Parse
              (Text.Data (1 .. Natural (Last)), Parsed, Error,
               (Jsonlib.Parsers.Default_Options with delta
                  Max_Depth => 8,
                  Max_Length => Max_Registry_Bytes));
         end;
      end;
      if Jsonlib.Errors.Failed (Error) then
         return;
      end if;
      declare
         Root : constant Doc.Node := Doc.Root (Parsed);
         Schema : constant Doc.Node := Doc.Member (Parsed, Root, "schema");
         Items  : constant Doc.Node := Doc.Member (Parsed, Root, "entries");
      begin
         if Doc.Kind (Parsed, Root) /= Doc.Object_Value
           or else not Doc.Is_Present (Schema)
           or else Doc.Kind (Parsed, Schema) /= Doc.String_Value
           or else Doc.As_String (Parsed, Schema)
                   /= "expert-cache-recommendations/1"
           or else not Doc.Is_Present (Items)
           or else Doc.Kind (Parsed, Items) /= Doc.Array_Value
           or else Doc.Length (Parsed, Items) > Max_Entries
         then
            return;
         end if;
         for Index in 1 .. Doc.Length (Parsed, Items) loop
            declare
               Item     : constant Doc.Node := Doc.Element (Parsed, Items, Index);
               Digest   : constant Doc.Node := Doc.Member (Parsed, Item, "model_sha256");
               Engine   : constant Doc.Node := Doc.Member (Parsed, Item, "engine_id");
               Device   : constant Doc.Node := Doc.Member (Parsed, Item, "device");
               Protocol : constant Doc.Node := Doc.Member (Parsed, Item, "protocol");
               Report   : constant Doc.Node := Doc.Member (Parsed, Item, "report");
               Memory   : constant Doc.Node :=
                 Doc.Member (Parsed, Item, "device_memory_bytes");
               Bytes    : constant Doc.Node := Doc.Member (Parsed, Item, "cache_bytes");
            begin
               if not Doc.Is_Present (Item)
                 or else Doc.Kind (Parsed, Item) /= Doc.Object_Value
                 or else not Doc.Is_Present (Digest)
                 or else not Doc.Is_Present (Engine)
                 or else not Doc.Is_Present (Device)
                 or else not Doc.Is_Present (Protocol)
                 or else not Doc.Is_Present (Report)
                 or else not Doc.Is_Present (Memory)
                 or else not Doc.Is_Present (Bytes)
                 or else Doc.Kind (Parsed, Digest) /= Doc.String_Value
                 or else Doc.As_String (Parsed, Digest)'Length /= 64
                 or else Doc.Kind (Parsed, Engine) /= Doc.String_Value
                 or else Doc.Kind (Parsed, Device) /= Doc.String_Value
                 or else Doc.Kind (Parsed, Protocol) /= Doc.String_Value
                 or else Doc.Kind (Parsed, Report) /= Doc.String_Value
                 or else Doc.Kind (Parsed, Memory) /= Doc.Integer_Value
                 or else Doc.As_Integer (Parsed, Memory) < 0
                 or else Doc.Kind (Parsed, Bytes) /= Doc.Integer_Value
                 or else Doc.As_Integer (Parsed, Bytes) <= 0
               then
                  return;
               end if;
               Count := Count + 1;
               Entries (Count) :=
                 (Digest => US.To_Unbounded_String (Doc.As_String (Parsed, Digest)),
                  Engine => US.To_Unbounded_String (Doc.As_String (Parsed, Engine)),
                  Device => US.To_Unbounded_String (Doc.As_String (Parsed, Device)),
                  Protocol => US.To_Unbounded_String (Doc.As_String (Parsed, Protocol)),
                  Report => US.To_Unbounded_String (Doc.As_String (Parsed, Report)),
                  Device_Memory =>
                    Interfaces.Unsigned_64 (Doc.As_Integer (Parsed, Memory)),
                  Bytes => Interfaces.Unsigned_64 (Doc.As_Integer (Parsed, Bytes)));
            end;
         end loop;
      end;
      Valid := True;
   exception
      when others =>
         if SIO.Is_Open (File) then
            SIO.Close (File);
         end if;
         Count := 0;
         Valid := False;
   end Read;

   function Find
     (Model_Path    : String;
      Device        : String;
      Device_Memory : Interfaces.Unsigned_64;
      Registry_Path : String := "") return Interfaces.Unsigned_64
   is
      Entries : Entry_List;
      Count   : Natural;
      Valid   : Boolean;
      Engine    : constant String := Engine_Identity;
      Candidate : Boolean := False;
   begin
      if Device = "" then
         return 0;
      end if;
      Read (Selected_Path (Registry_Path), Entries, Count, Valid);
      if not Valid or else Count = 0 then
         return 0;
      end if;

      --  Avoid reading a potentially very large model unless this registry
      --  contains an otherwise applicable entry.  The digest remains the
      --  final authority before a recommendation can be returned.
      for Index in 1 .. Count loop
         if US.To_String (Entries (Index).Engine) = Engine
           and then US.To_String (Entries (Index).Device) = Device
           and then Entries (Index).Device_Memory = Device_Memory
         then
            Candidate := True;
            exit;
         end if;
      end loop;
      if not Candidate then
         return 0;
      end if;

      declare
         Digest : constant String := Artifact_Digest (Model_Path);
      begin
         if Digest = [1 .. 64 => '0'] then
            return 0;
         end if;
         for Index in 1 .. Count loop
            if US.To_String (Entries (Index).Digest) = Digest
              and then US.To_String (Entries (Index).Engine) = Engine
              and then US.To_String (Entries (Index).Device) = Device
              and then Entries (Index).Device_Memory = Device_Memory
            then
               return Entries (Index).Bytes;
            end if;
         end loop;
      end;
      return 0;
   end Find;

   procedure Save
     (Model_SHA256 : String;
      Device       : String;
      Device_Memory : Interfaces.Unsigned_64;
      Bytes        : Interfaces.Unsigned_64;
      Protocol     : String;
      Report       : String;
      Registry_Path : String := "";
      Stored       : out Boolean)
   is
      Entries : Entry_List;
      Count   : Natural;
      Valid   : Boolean;
      Path    : constant String := Selected_Path (Registry_Path);
      Engine  : constant String := Engine_Identity;
      Part    : constant String := Path & ".part";
      File    : Ada.Streams.Stream_IO.File_Type;
      Match   : Natural := 0;

      procedure Put (Text : String; New_Line : Boolean := False) is
         use Ada.Streams;
         Buffer : Stream_Element_Array (1 .. 4_096);
         First  : Natural := Text'First;
      begin
         while First <= Text'Last loop
            declare
               Count : constant Natural :=
                 Natural'Min (Buffer'Length, Text'Last - First + 1);
            begin
               for Index in 0 .. Count - 1 loop
                  Buffer (Stream_Element_Offset (Index + 1)) :=
                    Stream_Element (Character'Pos (Text (First + Index)));
               end loop;
               Ada.Streams.Stream_IO.Write
                 (File, Buffer (1 .. Stream_Element_Offset (Count)));
               First := First + Count;
            end;
         end loop;
         if New_Line then
            Buffer (1) := 10;
            Ada.Streams.Stream_IO.Write (File, Buffer (1 .. 1));
         end if;
      end Put;
   begin
      Stored := False;
      if Path = "" or else Model_SHA256'Length /= 64 or else Device = ""
        or else Protocol = ""
      then
         return;
      end if;
      Read (Path, Entries, Count, Valid);
      if not Valid then
         return;
      end if;
      for Index in 1 .. Count loop
         if US.To_String (Entries (Index).Digest) = Model_SHA256
           and then US.To_String (Entries (Index).Engine) = Engine
           and then US.To_String (Entries (Index).Device) = Device
           and then Entries (Index).Device_Memory = Device_Memory
         then
            Match := Index;
            exit;
         end if;
      end loop;
      if Bytes = 0 then
         if Match > 0 then
            for Index in Match .. Count - 1 loop
               Entries (Index) := Entries (Index + 1);
            end loop;
            Count := Count - 1;
         end if;
      else
         if Match = 0 then
            if Count = Max_Entries then
               return;
            end if;
            Count := Count + 1;
            Match := Count;
         end if;
         Entries (Match) :=
           (Digest => US.To_Unbounded_String (Model_SHA256),
            Engine => US.To_Unbounded_String (Engine),
            Device => US.To_Unbounded_String (Device),
            Protocol => US.To_Unbounded_String (Protocol),
            Report => US.To_Unbounded_String (Report),
            Device_Memory => Device_Memory,
            Bytes => Bytes);
      end if;

      declare
         Parent : constant String := Ada.Directories.Containing_Directory (Path);
      begin
         if Parent /= "" and then not Ada.Directories.Exists (Parent) then
            Ada.Directories.Create_Path (Parent);
         end if;
      end;
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Part, Form => "shared=no");
      Put ("{""schema"":""expert-cache-recommendations/1"",""entries"":[",
           New_Line => True);
      for Index in 1 .. Count loop
         Put
           (
            "{""model_sha256"":"
            & Model_Runner.Text.JSON_Quoted (US.To_String (Entries (Index).Digest))
            & ",""engine_id"":"
            & Model_Runner.Text.JSON_Quoted (US.To_String (Entries (Index).Engine))
            & ",""device"":"
            & Model_Runner.Text.JSON_Quoted (US.To_String (Entries (Index).Device))
            & ",""protocol"":"
            & Model_Runner.Text.JSON_Quoted (US.To_String (Entries (Index).Protocol))
            & ",""report"":"
            & Model_Runner.Text.JSON_Quoted (US.To_String (Entries (Index).Report))
            & ",""device_memory_bytes"":"
            & Interfaces.Unsigned_64'Image (Entries (Index).Device_Memory)
            & ",""cache_bytes"":"
            & Interfaces.Unsigned_64'Image (Entries (Index).Bytes)
            & "}" & (if Index = Count then "" else ","),
            New_Line => True);
      end loop;
      Put ("]}", New_Line => True);
      Ada.Streams.Stream_IO.Close (File);
      Stored := Hostkit.Fs.Replace_File (Part, Path);
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Stored := False;
   end Save;

end Model_Runner.Expert_Cache_Recommendations;
