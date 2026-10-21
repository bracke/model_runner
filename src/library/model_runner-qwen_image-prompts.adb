with Ada.Directories;
with Ada.Streams.Stream_IO;
with Interfaces;

with Hostkit.Fs;

with Model_Runner.Numerics;
with Model_Runner.Platform;

package body Model_Runner.Qwen_Image.Prompts is

   package E renames Model_Runner.Errors;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package Vocab renames Model_Runner.Tokenizer;

   use type E.Error_Code;
   use type N.Element_Count;
   use type T.Real_Array_Access;

   procedure Encode
     (Encoder : in out L.Model'Class;
      Prompt  : String;
      Rows    : out T.Real_Array_Access;
      Count   : out Natural;
      Status  : out E.Error_Info)
   is
      Words  : constant access constant Vocab.Vocabulary := L.Vocabulary (Encoder);
      Whole  : Vocab.Token_Array (1 .. Max_Tokens);
      Opening : Vocab.Token_Array (1 .. Max_Tokens);
      Last, Dropped : Natural;
   begin
      Rows := null;
      Count := 0;

      Vocab.Encode (Words.all, Template (Prompt), False, False, Whole, Last, Status);
      if E.Is_Error (Status) then
         if Status.Code = E.Tokenizer_Buffer_Too_Small then
            Status := E.Make (E.Tokenizer_Input_Too_Long);
         end if;
         return;
      end if;
      Vocab.Encode (Words.all, System_Turn, False, False, Opening, Dropped, Status);
      if E.Is_Error (Status) then
         return;
      end if;
      --  The system turn is the template's first tokens: it ends where a
      --  marker begins, and nothing reads across a marker.
      Dropped := Natural'Min (Dropped, Last);

      Rows_Of (Encoder, Whole (1 .. Last), Dropped, Rows, Status);
      if E.Is_Ok (Status) then
         Count := Last - Dropped;
      end if;
   end Encode;

   procedure Rows_Of
     (Encoder : in out L.Model'Class;
      Tokens  : Vocab.Token_Array;
      Dropped : Natural;
      Rows    : out T.Real_Array_Access;
      Status  : out E.Error_Info)
   is
      Width  : constant N.Element_Count := N.Element_Count (L.Config (Encoder).Embedding);
      Kept   : constant Natural := Tokens'Length - Natural'Min (Dropped, Tokens'Length);
      Live   : L.Session;
      Limit  : constant Positive := L.Batch_Limit (Encoder);
      States : T.Real_Array_Access;
      Logits : N.Real_Array (0 .. N.Element_Count (L.Config (Encoder).Vocabulary) - 1);
      From   : Natural := 0;
   begin
      Rows := null;
      L.Open (Live, Encoder, Context => Tokens'Length, Status => Status);
      if E.Is_Error (Status) then
         return;
      end if;
      T.Allocate (N.Element_Count (Natural'Max (Kept, 1)) * Width, Rows);
      T.Allocate (N.Element_Count (Natural'Min (Limit, Tokens'Length)) * Width, States);
      if Rows = null or else States = null then
         T.Free (Rows);
         T.Free (States);
         L.Close (Live);
         Status := E.Make (E.Memory_Allocation_Failed);
         return;
      end if;
      --  From and Upto count positions from nought.
      while From < Tokens'Length loop
         declare
            Upto : constant Natural := Natural'Min (Tokens'Length, From + Limit) - 1;
         begin
            L.Evaluate_Batch
              (Live, Encoder, Tokens (Tokens'First + From .. Tokens'First + Upto), Logits,
               States => States, Normalized => False, Status => Status);
            exit when E.Is_Error (Status);
            for Position in Natural'Max (From, Dropped) .. Upto loop
               declare
                  Into   : constant N.Element_Count := N.Element_Count (Position - Dropped) * Width;
                  Out_Of : constant N.Element_Count := N.Element_Count (Position - From) * Width;
               begin
                  Rows (Into .. Into + Width - 1) := States (Out_Of .. Out_Of + Width - 1);
               end;
            end loop;
            From := Upto + 1;
         end;
      end loop;
      T.Free (States);
      L.Close (Live);
      if E.Is_Error (Status) then
         T.Free (Rows);
      end if;
   end Rows_Of;

   Magic : constant String := "MRPROWS1";

   ---------------
   -- Find_Kept --
   ---------------

   procedure Find_Kept
     (Key   : String;
      Rows  : out Model_Runner.Tensors.Real_Array_Access;
      Count : out Natural)
   is
      use Ada.Streams.Stream_IO;
      use type Interfaces.Unsigned_32;
      Path   : constant String := Model_Runner.Platform.Prompt_File (Key);
      Handle : File_Type;
   begin
      Rows := null;
      Count := 0;
      if Path = "" or else not Ada.Directories.Exists (Path) then
         return;
      end if;
      Open (Handle, In_File, Path);
      declare
         Data  : constant Stream_Access := Stream (Handle);
         Said  : String (Magic'Range);
         Long  : Interfaces.Unsigned_32;
      begin
         String'Read (Data, Said);
         Interfaces.Unsigned_32'Read (Data, Long);
         if Said /= Magic or else Long /= Interfaces.Unsigned_32 (Key'Length) then
            Close (Handle);
            return;
         end if;
         declare
            Kept_Key : String (1 .. Key'Length);
            Many, Wide : Interfaces.Unsigned_32;
         begin
            String'Read (Data, Kept_Key);
            Interfaces.Unsigned_32'Read (Data, Many);
            Interfaces.Unsigned_32'Read (Data, Wide);
            if Kept_Key /= Key or else Many = 0 or else Wide = 0 or else Many > Max_Tokens
              or else Wide > 1_048_576
            then
               Close (Handle);
               return;
            end if;
            Model_Runner.Tensors.Allocate
              (Model_Runner.Numerics.Element_Count (Many) * Model_Runner.Numerics.Element_Count (Wide), Rows);
            Model_Runner.Numerics.Real_Array'Read (Data, Rows.all);
            Count := Natural (Many);
         end;
      end;
      Close (Handle);
      Model_Runner.Platform.Mark_Used (Path);
   exception
      when others =>
         if Is_Open (Handle) then
            Close (Handle);
         end if;
         Model_Runner.Tensors.Free (Rows);
         Count := 0;
   end Find_Kept;

   ----------
   -- Keep --
   ----------

   procedure Keep
     (Key   : String;
      Rows  : Model_Runner.Tensors.Real_Array;
      Count : Natural)
   is
      use Ada.Streams.Stream_IO;
      Path   : constant String := Model_Runner.Platform.Prompt_File (Key);
      Part   : constant String := Path & ".part";
      Handle : File_Type;
   begin
      if Path = "" or else Count = 0 or else Rows'Length mod Model_Runner.Numerics.Element_Count (Count) /= 0 then
         return;
      end if;
      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (Path));
      Create (Handle, Out_File, Part);
      declare
         Data : constant Stream_Access := Stream (Handle);
      begin
         String'Write (Data, Magic);
         Interfaces.Unsigned_32'Write (Data, Interfaces.Unsigned_32 (Key'Length));
         String'Write (Data, Key);
         Interfaces.Unsigned_32'Write (Data, Interfaces.Unsigned_32 (Count));
         Interfaces.Unsigned_32'Write
           (Data, Interfaces.Unsigned_32 (Rows'Length / Model_Runner.Numerics.Element_Count (Count)));
         Model_Runner.Numerics.Real_Array'Write (Data, Rows);
      end;
      Close (Handle);
      if Hostkit.Fs.Replace_File (Part, Path) then
         Model_Runner.Platform.Trim_Directory
           (Ada.Directories.Containing_Directory (Path), "*.rows", Model_Runner.Platform.Prompt_Cache_Most,
            Keep => Path);
      end if;
   exception
      when others =>
         if Is_Open (Handle) then
            Close (Handle);
         end if;
   end Keep;

end Model_Runner.Qwen_Image.Prompts;
