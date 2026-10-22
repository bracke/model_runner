with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;
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
   use type Model_Runner.Bytes.Byte_Count;

   procedure Free is new Ada.Unchecked_Deallocation (L.Row_Places, L.Row_Places_Access);

   procedure Encode
     (Encoder : in out L.Model'Class;
      Prompt  : String;
      Rows    : out T.Real_Array_Access;
      Count   : out Natural;
      Status  : out E.Error_Info;
      Workers : Model_Runner.Backend.CPU.Pool_Reference := null)
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

      Rows_Of (Encoder, Whole (1 .. Last), Dropped, Rows, Status, Workers);
      if E.Is_Ok (Status) then
         Count := Last - Dropped;
      end if;
   end Encode;

   -------------------
   -- Template_With --
   -------------------

   function Template_With (Prompt : String; Counts : Model_Runner.Qwen_Image.Slot_List) return String is
      Text : Ada.Strings.Unbounded.Unbounded_String;
      use Ada.Strings.Unbounded;
   begin
      Append (Text, System_Turn & "<|im_start|>user" & ASCII.LF);
      for Index in Counts'Range loop
         declare
            Number : constant String := Natural'Image (Index - Counts'First + 1);
         begin
            Append (Text, (if Index = Counts'First then "" else " ") & "<image"
                    & Number (Number'First + 1 .. Number'Last) & "><|vision_start|>");
            for Pad in 1 .. Counts (Index) loop
               Append (Text, "<|image_pad|>");
            end loop;
            Append (Text, "<|vision_end|>");
         end;
      end loop;
      Append (Text, (if Prompt = "" then " " else Prompt) & "<|im_end|>" & ASCII.LF
              & "<|im_start|>assistant" & ASCII.LF);
      return To_String (Text);
   end Template_With;

   --------------------------
   -- Encode_With_Pictures --
   --------------------------

   procedure Encode_With_Pictures
     (Encoder  : in out L.Model'Class;
      Eyes     : in out Model_Runner.Vision.Encoder;
      Prompt   : String;
      Pictures : Picture_List;
      Rows     : out T.Real_Array_Access;
      Count    : out Natural;
      Slots    : out Slots_Access;
      Status   : out E.Error_Info;
      Workers  : Model_Runner.Backend.CPU.Pool_Reference := null)
   is
      Words   : constant access constant Vocab.Vocabulary := L.Vocabulary (Encoder);
      Stacked : constant Natural := Model_Runner.Vision.Stacked_Rows (Eyes);
      Stride  : constant N.Element_Count :=
        N.Element_Count (Model_Runner.Vision.Row_Width (Eyes)) * N.Element_Count (1 + Stacked);
      Counts  : Model_Runner.Qwen_Image.Slot_List (Pictures'Range) := [others => 0];
      Grids   : array (Pictures'Range, 1 .. 2) of Natural := [others => [others => 0]];
      Seen    : T.Real_Array_Access;
      Total   : N.Element_Count := 0;
      Whole   : Vocab.Token_Array (1 .. Max_Tokens);
      Opening : Vocab.Token_Array (1 .. Max_Tokens);
      Last, Dropped : Natural;
      Places  : L.Row_Places_Access;
      Pad     : Vocab.Token_Id;
   begin
      Rows := null;
      Count := 0;
      Slots := null;
      Status := E.Success;

      --  Each picture through the tower at its own size, on white.
      for Index in Pictures'Range loop
         declare
            Shown   : Model_Runner.Images.Raster := Pictures (Index);
            Opaque  : Model_Runner.Images.Raster;
            Part    : T.Real_Array_Access;
            Grown   : T.Real_Array_Access;
            Down, Across : Natural;
         begin
            if Shown.Width mod 32 /= 0 or else Shown.Height mod 32 /= 0 or else Shown.Width = 0 then
               Status := E.Make (E.Tensor_Shape_Mismatch);
               exit;
            end if;
            if Model_Runner.Bytes."/=" (Shown.Alpha, null) then
               Opaque.Width := Shown.Width;
               Opaque.Height := Shown.Height;
               Opaque.Pixels := new Model_Runner.Bytes.Byte_Array'(Shown.Pixels.all);
               for P in 0 .. Shown.Width * Shown.Height - 1 loop
                  declare
                     A : constant Natural :=
                       Natural (Shown.Alpha (Shown.Alpha'First + Model_Runner.Bytes.Byte_Count (P)));
                  begin
                     for C in 0 .. 2 loop
                        declare
                           At_Byte : constant Model_Runner.Bytes.Byte_Count :=
                             Opaque.Pixels'First + Model_Runner.Bytes.Byte_Count (3 * P + C);
                        begin
                           Opaque.Pixels (At_Byte) :=
                             Model_Runner.Bytes.Byte ((Natural (Opaque.Pixels (At_Byte)) * A + 255 * (255 - A) + 127)
                                                      / 255);
                        end;
                     end loop;
                  end;
               end loop;
               Shown := Opaque;
            end if;
            Model_Runner.Vision.Encode_Frames
              (Eyes, Shown, Shown, Shown.Width, Shown.Height, Workers, Part, Down, Across, null, Status);
            Model_Runner.Images.Free (Opaque);
            exit when E.Is_Error (Status);
            if Down * Across * 32 * 32 /= Shown.Width * Shown.Height or else Part = null
              or else Part'Length /= N.Element_Count (Down * Across) * Stride
            then
               T.Free (Part);
               Status := E.Make (E.Tensor_Shape_Mismatch);
               exit;
            end if;
            Counts (Index) := Down * Across;
            Grids (Index, 1) := Down;
            Grids (Index, 2) := Across;
            T.Allocate (Total + Part'Length, Grown);
            if Seen /= null then
               Grown (0 .. Total - 1) := Seen (0 .. Total - 1);
            end if;
            Grown (Total .. Total + Part'Length - 1) := Part.all;
            Total := Total + Part'Length;
            T.Free (Seen);
            T.Free (Part);
            Seen := Grown;
         end;
      end loop;
      if E.Is_Error (Status) then
         T.Free (Seen);
         return;
      end if;

      Vocab.Encode (Words.all, Template_With (Prompt, Counts), False, False, Whole, Last, Status);
      if E.Is_Ok (Status) then
         Vocab.Encode (Words.all, System_Turn, False, False, Opening, Dropped, Status);
      elsif Status.Code = E.Tokenizer_Buffer_Too_Small then
         Status := E.Make (E.Tokenizer_Input_Too_Long);
      end if;
      if E.Is_Error (Status) then
         T.Free (Seen);
         return;
      end if;
      Dropped := Natural'Min (Dropped, Last);
      Pad := Vocab.Find (Words.all, "<|image_pad|>");

      --  Where each picture row stands: its picture's row and column, the
      --  text after a picture on by its longer side.
      declare
         Rows_In : constant N.Element_Count := Total / Stride;
         At_Row  : N.Element_Count := 0;
      begin
         Places := new L.Row_Places (0 .. Rows_In - 1);
         for Index in Pictures'Range loop
            for Where in 0 .. Counts (Index) - 1 loop
               Places (At_Row) :=
                 (Row     => Where / Grids (Index, 2),
                  Column  => Where mod Grids (Index, 2),
                  First   => Where = 0,
                  Last    => Where = Counts (Index) - 1,
                  Advance => Natural'Max (Grids (Index, 1), Grids (Index, 2)));
               At_Row := At_Row + 1;
            end loop;
         end loop;
      end;

      Rows_Of (Encoder, Whole (1 .. Last), Dropped, Rows, Status, Workers,
               Given => (Token => Pad, Rows => Seen, First => 0, Places => Places, Causal => True,
                         Stacked => Stacked, others => <>));
      T.Free (Seen);
      Free (Places);
      if E.Is_Error (Status) then
         return;
      end if;
      Count := Last - Dropped;
      Slots := new Model_Runner.Qwen_Image.Slot_List (0 .. Count - 1);
      declare
         Which : Natural := 0;
         Left  : Natural := 0;
      begin
         for Position in 1 .. Last loop
            if Vocab."=" (Whole (Position), Pad) then
               if Left = 0 then
                  Which := Which + 1;
                  Left := Counts (Pictures'First + Which - 1);
               end if;
               Left := Left - 1;
            end if;
            if Position > Dropped then
               Slots (Position - Dropped - 1) := (if Vocab."=" (Whole (Position), Pad) then Which else 0);
            end if;
         end loop;
      end;
   end Encode_With_Pictures;

   procedure Rows_Of
     (Encoder : in out L.Model'Class;
      Tokens  : Vocab.Token_Array;
      Dropped : Natural;
      Rows    : out T.Real_Array_Access;
      Status  : out E.Error_Info;
      Workers : Model_Runner.Backend.CPU.Pool_Reference := null;
      Given   : L.Given_Rows := L.No_Given_Rows)
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
      L.Open (Live, Encoder, Context => Tokens'Length, Workers => Workers, Status => Status);
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
            declare
               --  The given rows the batches before this one took.
               Taken : N.Element_Count := 0;
               Mine  : L.Given_Rows := Given;
            begin
               if Given.Rows /= null then
                  for Position in Tokens'First .. Tokens'First + From - 1 loop
                     if Vocab."=" (Tokens (Position), Given.Token) then
                        Taken := Taken + 1;
                     end if;
                  end loop;
                  Mine.First := Given.First + Taken;
               end if;
               L.Evaluate_Batch
                 (Live, Encoder, Tokens (Tokens'First + From .. Tokens'First + Upto), Logits,
                  States => States, Given => Mine, Normalized => False, Status => Status);
            end;
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
