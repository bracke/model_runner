with Ada.Calendar;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Model_Runner.Bytes;
with Model_Runner.Images;
with Model_Runner.Numerics;
with Model_Runner.Tensors;
with Model_Runner.Video;

package body Model_Runner.CLI.Pictures is

   package Conv renames Model_Runner.Conversation;
   package E renames Model_Runner.Errors;
   package Gen renames Model_Runner.Generation;
   package L renames Model_Runner.Llama;
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package US renames Ada.Strings.Unbounded;

   procedure Free is new Ada.Unchecked_Deallocation
     (Gen.Crop_Counts, Gen.Crop_Counts_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (L.Row_Places, L.Row_Places_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Gen.Entry_Kinds, Gen.Entry_Kinds_Access);
   procedure Free is new Ada.Unchecked_Deallocation
     (Gen.Slot_Times, Gen.Slot_Times_Access);

   use type Ada.Calendar.Time;
   use type N.Element_Count;
   use type T.Real_Array_Access;
   use type Gen.Crop_Counts_Access;
   use type Gen.Entry_Kinds_Access;
   use type Gen.Slot_Times_Access;
   use type L.Row_Places_Access;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Tokenizer.Token_Id;

   --  The files a list of parts names as pictures, and the directories
   --  it names as videos: each part whose type is image or image_url, and
   --  its path -- or its url, which is a path here, there being nothing to
   --  fetch with -- and each of type video with its path and the rate its
   --  frames were taken at. Found is called for each in order, Video
   --  saying which it is.
   procedure Named_Pictures
     (Parts : String;
      Found : access procedure (Path : String; Video : Boolean; Fps : Long_Float))
   is
      I : Natural := Parts'First;

      procedure Skip_Blanks is
      begin
         while I <= Parts'Last
           and then Parts (I) in ' ' | ASCII.LF | ASCII.CR | ASCII.HT
         loop
            I := I + 1;
         end loop;
      end Skip_Blanks;

      --  A JSON string at I, I left past its closing quote.
      function Read_String return String is
         From : constant Natural := I + 1;
      begin
         I := From;
         while I <= Parts'Last and then Parts (I) /= '"' loop
            if Parts (I) = '\' and then I < Parts'Last then
               I := I + 1;
            end if;
            I := I + 1;
         end loop;
         I := I + 1;
         return Conv.Unescaped (Parts (From .. Natural'Min (I - 2, Parts'Last)));
      end Read_String;

      --  A JSON number at I, I left past it; what cannot be read as one
      --  is nought, which the caller treats as not given.
      function Read_Number return Long_Float is
         From : constant Natural := I;
      begin
         while I <= Parts'Last
           and then Parts (I) in '0' .. '9' | '.' | '-' | '+' | 'e' | 'E'
         loop
            I := I + 1;
         end loop;
         begin
            return Long_Float'Value (Parts (From .. I - 1));
         exception
            when Constraint_Error =>
               return 0.0;
         end;
      end Read_Number;

      Depth : Natural := 0;
      Kind, Path : US.Unbounded_String;
      Fps   : Long_Float := 0.0;
   begin
      while I <= Parts'Last loop
         case Parts (I) is
            when '{' =>
               Depth := Depth + 1;
               if Depth = 1 then
                  Kind := US.Null_Unbounded_String;
                  Path := US.Null_Unbounded_String;
                  Fps := 0.0;
               end if;
               I := I + 1;
            when '}' =>
               if Depth = 1 and then US.Length (Path) > 0 then
                  if US.To_String (Kind) = "image"
                    or else US.To_String (Kind) = "image_url"
                  then
                     Found (US.To_String (Path), False, 0.0);
                  elsif US.To_String (Kind) = "video" then
                     Found (US.To_String (Path), True,
                            (if Fps > 0.0 then Fps else Default_Fps));
                  end if;
               end if;
               Depth := Natural'Max (0, Depth - 1);
               I := I + 1;
            when '"' =>
               declare
                  Key : constant String := Read_String;
               begin
                  Skip_Blanks;
                  if I <= Parts'Last and then Parts (I) = ':' then
                     I := I + 1;
                     Skip_Blanks;
                     if I <= Parts'Last and then Parts (I) = '"' then
                        declare
                           Value : constant String := Read_String;
                        begin
                           if Key = "type" and then Depth = 1 then
                              Kind := US.To_Unbounded_String (Value);
                           elsif Key = "path" or else Key = "url" then
                              Path := US.To_Unbounded_String (Value);
                           end if;
                        end;
                     elsif I <= Parts'Last
                       and then Parts (I) in '0' .. '9' | '-'
                     then
                        declare
                           Value : constant Long_Float := Read_Number;
                        begin
                           if Key = "fps" and then Depth = 1 then
                              Fps := Value;
                           end if;
                        end;
                     end if;
                  end if;
               end;
            when others =>
               I := I + 1;
         end case;
      end loop;
   end Named_Pictures;

   ----------
   -- Open --
   ----------

   procedure Open
     (Item      : in out Seer;
      Projector : String;
      Model     : Model_Runner.Llama.Model'Class;
      Status    : out E.Error_Info)
   is
      Words : constant access constant Model_Runner.Tokenizer.Vocabulary :=
        Model_Runner.Llama.Vocabulary (Model);
   begin
      Close (Item);
      Status := E.Success;

      --  A model with neither family's tokens has no place for a picture
      --  whatever the projector says, and is refused before the projector
      --  is opened.
      if Model_Runner.Tokenizer.Find (Words.all, "<start_of_image>")
           = Model_Runner.Tokenizer.No_Token
        and then Model_Runner.Tokenizer.Find (Words.all, "<|image_pad|>")
           = Model_Runner.Tokenizer.No_Token
        and then Model_Runner.Tokenizer.Find (Words.all, "<image>")
           = Model_Runner.Tokenizer.No_Token
      then
         Status := E.Make (E.Arch_Vision_Tokens_Missing);
         E.Add_Text (Status, "token", "<start_of_image>", E.Param_Identifier);
         return;
      end if;

      Model_Runner.Vision.Open (Item.Eyes, Projector, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  The tokens a picture stands behind, which are the projector's
      --  family's. Gemma 3 writes a marker, the soft tokens and a closer,
      --  and its processor sets the marker between two line breaks before
      --  it tokenizes and, for a picture with crops, among its words.
      --  Qwen3.5's template writes <|vision_start|><|image_pad|>
      --  <|vision_end|> and its processor replaces the one <|image_pad|>
      --  by as many as the picture has rows: the marker is the soft
      --  token, nothing frames it, and there are no crops.
      if Model_Runner.Vision.Placed_Rows (Item.Eyes) then
         Item.Marker := Model_Runner.Tokenizer.Find (Words.all, "<|image_pad|>");
         Item.Soft := Item.Marker;
         Item.Closer := Model_Runner.Tokenizer.No_Token;
         Item.Keeps_Marker := False;
         Item.Marker_Text := Model_Runner.Text.Empty;
         Item.Before := Model_Runner.Text.Empty;
         Item.After := Model_Runner.Text.Empty;
         Item.Lead := Model_Runner.Text.Empty;
         Item.Bridge := Model_Runner.Text.Empty;
         Item.Gap := Model_Runner.Text.Empty;
         if Item.Marker = Model_Runner.Tokenizer.No_Token then
            Status := E.Make (E.Arch_Vision_Tokens_Missing);
            E.Add_Text (Status, "token", "<|image_pad|>", E.Param_Identifier);
            Model_Runner.Vision.Close (Item.Eyes);
            return;
         end if;

         --  And a video's, where the model has one: its marker is its
         --  soft token as a picture's is, and the processor writes each
         --  slot between the same opener and closer the template writes
         --  round the video.
         Item.Video_Marker :=
           Model_Runner.Tokenizer.Find (Words.all, "<|video_pad|>");
         Item.Video_Text := Model_Runner.Text.To_Bounded ("<|video_pad|>");
         Item.Video_Open := Model_Runner.Text.To_Bounded ("<|vision_start|>");
         Item.Video_Close := Model_Runner.Text.To_Bounded ("<|vision_end|>");
      elsif Model_Runner.Vision.Projector (Item.Eyes) = "resampler" then
         --  MiniCPM-V's resampler. Its processor wraps a picture's rows in
         --  <image> and </image>, one unknown token a row between them; a
         --  picture larger than the encoder's side becomes an overview so
         --  wrapped and a grid of slices each wrapped in <slice> and
         --  </slice>. This build shows the overview alone, fit to the side.
         Item.Resampler := True;
         Item.Marker := Model_Runner.Tokenizer.Find (Words.all, "<image>");
         Item.Soft := Model_Runner.Tokenizer.Unknown_Token (Words.all);
         Item.Closer := Model_Runner.Tokenizer.Find (Words.all, "</image>");
         Item.Keeps_Marker := True;
         if Item.Marker = Model_Runner.Tokenizer.No_Token
           or else Item.Soft = Model_Runner.Tokenizer.No_Token
           or else Item.Closer = Model_Runner.Tokenizer.No_Token
         then
            Status := E.Make (E.Arch_Vision_Tokens_Missing);
            E.Add_Text
              (Status, "token",
               (if Item.Marker = Model_Runner.Tokenizer.No_Token then "<image>"
                elsif Item.Closer = Model_Runner.Tokenizer.No_Token
                then "</image>" else "<unk>"),
               E.Param_Identifier);
            Model_Runner.Vision.Close (Item.Eyes);
            return;
         end if;
         Item.Marker_Text := Model_Runner.Text.To_Bounded ("<image>");
         Item.Before := Model_Runner.Text.Empty;
         Item.After := Model_Runner.Text.Empty;
         Item.Lead := Model_Runner.Text.Empty;
         Item.Bridge := Model_Runner.Text.Empty;
         Item.Gap := Model_Runner.Text.Empty;
      else
         Item.Marker := Model_Runner.Tokenizer.Find (Words.all, "<start_of_image>");
         Item.Soft := Model_Runner.Tokenizer.Find (Words.all, "<image_soft_token>");
         Item.Closer := Model_Runner.Tokenizer.Find (Words.all, "<end_of_image>");
         Item.Keeps_Marker := True;
         if Item.Marker = Model_Runner.Tokenizer.No_Token
           or else Item.Soft = Model_Runner.Tokenizer.No_Token
         then
            Status := E.Make (E.Arch_Vision_Tokens_Missing);
            E.Add_Text
              (Status, "token",
               (if Item.Marker = Model_Runner.Tokenizer.No_Token
                then "<start_of_image>" else "<image_soft_token>"),
               E.Param_Identifier);
            Model_Runner.Vision.Close (Item.Eyes);
            return;
         end if;
         Item.Marker_Text := Model_Runner.Text.To_Bounded ("<start_of_image>");
         Item.Before := Model_Runner.Text.To_Bounded (ASCII.LF & ASCII.LF);
         Item.After := Item.Before;
         Item.Lead := Model_Runner.Text.To_Bounded ("Here is the original image ");
         Item.Bridge := Model_Runner.Text.To_Bounded
           (" and here are some crops to help you see better ");
         Item.Gap := Model_Runner.Text.To_Bounded (" ");
      end if;

      Item.Width := Model_Runner.Llama.Config (Model).Embedding;
      if Model_Runner.Vision.Row_Width (Item.Eyes) /= Item.Width then
         Status := E.Make (E.Arch_Invalid_Dimensions);
         E.Add_Integer
           (Status, "embedding",
            Long_Long_Integer (Model_Runner.Vision.Row_Width (Item.Eyes)));
         E.Add_Integer (Status, "heads", Long_Long_Integer (Item.Width));
         Model_Runner.Vision.Close (Item.Eyes);
         return;
      end if;

      Item.Ready := True;
   end Open;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Seer) is
   begin
      Model_Runner.Vision.Close (Item.Eyes);
      Item.Ready := False;
   end Close;

   function Is_Open (Item : Seer) return Boolean is (Item.Ready);

   function Picture_Marker (Item : Seer) return String
   is (Model_Runner.Text.To_String (Item.Marker_Text));

   function Video_Marker (Item : Seer) return String
   is (Model_Runner.Text.To_String (Item.Video_Text));

   ----------------------
   -- Names_A_Picture --
   ----------------------

   function Names_A_Picture (Parts : String) return Boolean is
      Any : Boolean := False;
      procedure Note (Path : String; Video : Boolean; Fps : Long_Float) is
         pragma Unreferenced (Path, Video, Fps);
      begin
         Any := True;
      end Note;
   begin
      Named_Pictures (Parts, Note'Access);
      return Any;
   end Names_A_Picture;

   ------------
   -- Gather --
   ------------

   procedure Gather
     (Item     : in out Seer;
      Messages : Conv.History;
      Into     : in out Gen.Picture_Set;
      Team     : Model_Runner.Backend.CPU.Pool_Reference;
      Crops    : Boolean := False;
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Reporter : access procedure
        (Index, Total : Positive; Rows, Milliseconds : Natural) := null;
      Status   : out E.Error_Info)
   is
      Paths  : array (1 .. Max_Pictures) of US.Unbounded_String;
      Videos : array (1 .. Max_Pictures) of Boolean := [others => False];
      Rates  : array (1 .. Max_Pictures) of Long_Float := [others => 0.0];
      Total  : Natural := 0;
      Over   : Boolean := False;

      procedure Take (Path : String; Video : Boolean; Fps : Long_Float) is
      begin
         if Total < Max_Pictures then
            Total := Total + 1;
            Paths (Total) := US.To_Unbounded_String (Path);
            Videos (Total) := Video;
            Rates (Total) := Fps;
         else
            Over := True;
         end if;
      end Take;

      --  How many of the parts are done already: the set counts entries
      --  -- a still, or a slot of a video -- and the parts are what the
      --  conversation names, so the parts done are the set's own count.
      Parts_Done : constant Natural := Into.Parts;

      Per   : constant Natural := Model_Runner.Vision.Rows_Per_Picture (Item.Eyes);
      Width : constant N.Element_Count := N.Element_Count (Item.Width);

      --  Whether the model reads the rows as a grid, each with a place
      --  of its own, which is also where a picture's rows are its own
      --  count and there are no crops.
      Placed : constant Boolean := Model_Runner.Vision.Placed_Rows (Item.Eyes);
   begin
      Status := E.Success;
      if not Item.Ready then
         Status := E.Make (E.Lifecycle_Model_Not_Ready);
         return;
      end if;

      --  Every picture the conversation names, in its order.
      for Index in 1 .. Conv.Length (Messages) loop
         declare
            Parts : constant String := Conv.Parts_At (Messages, Index);
         begin
            if Parts'Length > 0 then
               Named_Pictures (Parts, Take'Access);
            end if;
         end;
      end loop;

      if Over then
         Status := E.Make (E.CLI_Option_Out_Of_Range);
         E.Add_Text (Status, "option", "--prompt-parts", E.Param_Identifier);
         return;
      end if;

      Into.Marker := Item.Marker;
      Into.Soft := Item.Soft;
      Into.Closer := Item.Closer;
      Into.Per_Picture := Per;
      Into.Keep_Marker := Item.Keeps_Marker;
      Into.Causal_Rows := Placed;
      Into.Marker_Text := Item.Marker_Text;
      Into.Frame_Before := Item.Before;
      Into.Frame_After := Item.After;
      Into.Crop_Lead := Item.Lead;
      Into.Crop_Bridge := Item.Bridge;
      Into.Crop_Gap := Item.Gap;
      Into.Video_Marker := Item.Video_Marker;
      Into.Video_Marker_Text := Item.Video_Text;
      Into.Video_Open := Item.Video_Open;
      Into.Video_Close := Item.Video_Close;

      if Total <= Parts_Done then
         return;
      end if;

      for Index in Parts_Done + 1 .. Total loop
         declare
            Picture : Model_Runner.Images.Raster;
            Grid    : Model_Runner.Images.Tiling := Model_Runner.Images.Uncut;
            Tiles   : Positive := 1;
            Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Held    : constant N.Element_Count :=
              (if Into.Rows = null then 0 else Into.Rows.all'Length);
            Held_Rows : constant N.Element_Count := Held / Width;
            Added   : N.Element_Count := 0;
            Grid_Rows, Grid_Columns : Natural;

            --  One more entry -- a still, a crop or a slot -- with its
            --  crops, rows and kind, the ones held copied over.
            procedure Add_Entry
              (Crops : Natural; Rows : Natural; Kind : Gen.Entry_Kind)
            is
               Grown_Crops : constant Gen.Crop_Counts_Access :=
                 new Gen.Crop_Counts'(1 .. Into.Count + 1 => 0);
               Grown_Counts : constant Gen.Crop_Counts_Access :=
                 new Gen.Crop_Counts'(1 .. Into.Count + 1 => Per);
               Grown_Kinds : constant Gen.Entry_Kinds_Access :=
                 new Gen.Entry_Kinds'(1 .. Into.Count + 1 => Gen.Still);
            begin
               for Which in 1 .. Into.Count loop
                  if Into.Crops /= null and then Which in Into.Crops.all'Range
                  then
                     Grown_Crops.all (Which) := Into.Crops.all (Which);
                  end if;
                  if Into.Counts /= null and then Which in Into.Counts.all'Range
                  then
                     Grown_Counts.all (Which) := Into.Counts.all (Which);
                  end if;
                  if Into.Kinds /= null and then Which in Into.Kinds.all'Range
                  then
                     Grown_Kinds.all (Which) := Into.Kinds.all (Which);
                  end if;
               end loop;
               Grown_Crops.all (Into.Count + 1) := Crops;
               Grown_Counts.all (Into.Count + 1) := Rows;
               Grown_Kinds.all (Into.Count + 1) := Kind;
               Free (Into.Crops);
               Free (Into.Counts);
               Free (Into.Kinds);
               Into.Crops := Grown_Crops;
               Into.Counts := Grown_Counts;
               Into.Kinds := Grown_Kinds;
               Into.Count := Into.Count + 1;
            end Add_Entry;

            --  The rows one picture -- the whole, a crop or a slot --
            --  became, put after those held so far, with their places
            --  where the model reads them.
            procedure Keep_Rows (Rows : in out T.Real_Array_Access) is
               Grown : T.Real_Array_Access;
               Was   : constant N.Element_Count := Held + Added;
               Count : constant N.Element_Count := Rows.all'Length / Width;
               Length : constant N.Element_Count := Rows.all'Length;
            begin
               T.Allocate (Was + Rows.all'Length, Grown);
               if Grown = null then
                  T.Free (Rows);
                  Status := E.Make (E.Memory_Allocation_Failed);
                  E.Add_Text
                    (Status, "category", "pictures", E.Param_Identifier);
                  return;
               end if;
               if Into.Rows /= null and then Was > 0 then
                  Grown (0 .. Was - 1) := Into.Rows (0 .. Was - 1);
               end if;
               Grown (Was .. Was + Rows.all'Length - 1) := Rows.all;
               T.Free (Into.Rows);
               Into.Rows := Grown;
               T.Free (Rows);

               if Placed then
                  declare
                     First_Row : constant N.Element_Count :=
                       Held_Rows + Added / Width;
                     More : constant L.Row_Places_Access :=
                       new L.Row_Places (0 .. First_Row + Count - 1);
                     Longer : constant Natural :=
                       Natural'Max (Grid_Rows, Grid_Columns);
                  begin
                     if Into.Places /= null then
                        for Where in Into.Places.all'Range loop
                           exit when Where >= First_Row;
                           More.all (Where) := Into.Places.all (Where);
                        end loop;
                     end if;
                     for Where in 0 .. Count - 1 loop
                        More.all (First_Row + Where) :=
                          (Row     => Natural (Where) / Natural'Max (1, Grid_Columns),
                           Column  => Natural (Where) mod Natural'Max (1, Grid_Columns),
                           First   => Where = 0,
                           Last    => Where = Count - 1,
                           Advance => Longer);
                     end loop;
                     Free (Into.Places);
                     Into.Places := More;
                  end;
               end if;

               Added := Added + Length;
            end Keep_Rows;

            --  One picture -- the whole, or a crop -- encoded and kept.
            procedure Encode_One (Shown : Model_Runner.Images.Raster) is
               Rows : T.Real_Array_Access;
            begin
               Model_Runner.Vision.Encode
                 (Item.Eyes, Shown, Team, Rows, Grid_Rows, Grid_Columns,
                  Cancel, Status);
               if E.Is_Ok (Status) then
                  Keep_Rows (Rows);
               end if;
            end Encode_One;

            --  A video: its frames fetched and fitted -- from a directory
            --  of pictures, or decoded from a file and sampled as the
            --  reference samples -- and encoded in pairs, each pair an
            --  entry of its own with the seconds it stands at, the mean of
            --  its two frames', kept for the prompt.
            procedure Encode_Video (Path : String; Fps : Long_Float) is
               Kept  : Model_Runner.Video.Raster_List_Access;
               Times : Model_Runner.Video.Seconds_List_Access;
               Fit_Width, Fit_Height : Positive;
               Slots : Natural := 0;
               Rows  : T.Real_Array_Access;
               Slots_Before : constant Natural :=
                 (if Into.Times = null then 0 else Into.Times.all'Length);
               Videos_Before : constant Natural :=
                 (if Into.Video_Slots = null then 0
                  else Into.Video_Slots.all'Length);

               procedure Note_Slot (Seconds : Long_Float) is
                  Held  : constant Natural :=
                    (if Into.Times = null then 0 else Into.Times.all'Length);
                  Grown : constant Gen.Slot_Times_Access :=
                    new Gen.Slot_Times (1 .. Held + 1);
               begin
                  if Into.Times /= null then
                     Grown.all (1 .. Held) := Into.Times.all;
                  end if;
                  Grown.all (Held + 1) := Seconds;
                  Free (Into.Times);
                  Into.Times := Grown;
               end Note_Slot;
            begin
               Model_Runner.Video.Fetch
                 (Path, Fps, Item.Eyes, Kept, Times, Fit_Width, Fit_Height,
                  Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               if Slots_Before + (Kept.all'Length + 1) / 2 > Max_Slots then
                  Status := E.Make (E.CLI_Option_Out_Of_Range);
                  E.Add_Text
                    (Status, "option", "--prompt-parts", E.Param_Identifier);
                  Model_Runner.Video.Release (Kept, Times);
                  return;
               end if;

               --  The pairs, the last frame paired with itself where the
               --  count is odd.
               declare
                  Frames   : constant Natural := Kept.all'Length;
                  At_Frame : Positive := 1;
               begin
                  while E.Is_Ok (Status) and then At_Frame <= Frames loop
                     declare
                        Next : constant Positive :=
                          Positive'Min (At_Frame + 1, Frames);
                     begin
                        Model_Runner.Vision.Encode_Frames
                          (Item.Eyes, Kept.all (At_Frame), Kept.all (Next),
                           Fit_Width, Fit_Height, Team, Rows, Grid_Rows,
                           Grid_Columns, Cancel, Status);
                        exit when E.Is_Error (Status);

                        Slots := Slots + 1;
                        Note_Slot
                          ((Times.all (At_Frame) + Times.all (Next)) / 2.0);
                        declare
                           Count : constant Natural :=
                             Natural (Rows.all'Length / Width);
                        begin
                           Keep_Rows (Rows);
                           exit when E.Is_Error (Status);
                           Add_Entry (0, Count, Gen.Slot);
                        end;
                        At_Frame := At_Frame + 2;
                     end;
                  end loop;
               end;
               Model_Runner.Video.Release (Kept, Times);

               if E.Is_Ok (Status) then
                  declare
                     Grown : constant Gen.Crop_Counts_Access :=
                       new Gen.Crop_Counts (1 .. Videos_Before + 1);
                  begin
                     if Into.Video_Slots /= null then
                        Grown.all (1 .. Videos_Before) := Into.Video_Slots.all;
                     end if;
                     Grown.all (Videos_Before + 1) := Slots;
                     Free (Into.Video_Slots);
                     Into.Video_Slots := Grown;
                  end;
               end if;
            end Encode_Video;
         begin
            if Videos (Index) then
               Encode_Video (US.To_String (Paths (Index)), Rates (Index));
               if E.Is_Error (Status) then
                  return;
               end if;
            else
               Model_Runner.Images.Load
                 (US.To_String (Paths (Index)), Picture, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               if Item.Resampler then
                  --  MiniCPM-V: show the overview, the whole fit to the
                  --  encoder's side keeping its aspect, and nothing else.
                  --  Tiles stays one, so the entry below is the overview's
                  --  own rows behind its <image> marker.
                  declare
                     OW, OH : Positive;
                     RW, RH, GC, GR, Cnt : Natural;
                     Sl : Model_Runner.Vision.Slice_List;
                     Fitted : Model_Runner.Images.Raster;
                  begin
                     Model_Runner.Vision.Plan_Slices
                       (Item.Eyes, Picture.Width, Picture.Height,
                        OW, OH, RW, RH, GC, GR, Sl, Cnt);
                     Model_Runner.Images.Resample (Picture, OW, OH, Fitted);
                     if Fitted.Pixels = null then
                        Status := E.Make (E.Memory_Allocation_Failed);
                        E.Add_Text
                          (Status, "category", "pictures", E.Param_Identifier);
                     else
                        Encode_One (Fitted);
                        Model_Runner.Images.Free (Fitted);
                     end if;
                  end;
               else
                  if Crops and then not Placed
                    and then Picture.Width > 0 and then Picture.Height > 0
                  then
                     Grid := Model_Runner.Images.Pan_And_Scan
                       (Picture.Width, Picture.Height);
                     Tiles := 1 + Grid.Across * Grid.Down;
                  end if;

                  Encode_One (Picture);

                  if E.Is_Ok (Status) and then Tiles > 1 then
                     Rows_Loop :
                     for Row in 0 .. Grid.Down - 1 loop
                        for Column in 0 .. Grid.Across - 1 loop
                           declare
                              Left, Top : Natural;
                              Wide, Tall : Positive;
                              Piece : Model_Runner.Images.Raster;
                           begin
                              Model_Runner.Images.Crop_Bounds
                                (Picture.Width, Picture.Height, Grid,
                                 Column, Row, Left, Top, Wide, Tall);
                              Model_Runner.Images.Crop
                                (Picture, Left, Top, Wide, Tall, Piece);
                              if Piece.Pixels = null then
                                 Status := E.Make (E.Memory_Allocation_Failed);
                                 E.Add_Text
                                   (Status, "category", "pictures",
                                    E.Param_Identifier);
                              else
                                 Encode_One (Piece);
                                 Model_Runner.Images.Free (Piece);
                              end if;
                           end;
                           exit Rows_Loop when E.Is_Error (Status);
                        end loop;
                     end loop Rows_Loop;
                  end if;
               end if;

               Model_Runner.Images.Free (Picture);
               if E.Is_Error (Status) then
                  return;
               end if;

               Add_Entry
                 (Tiles - 1,
                  (if Tiles > 1 then Per else Natural (Added / Width)),
                  Gen.Still);
            end if;

            Into.Parts := Index;
            if Reporter /= null then
               Reporter
                 (Index, Total, Natural (Added / Width),
                  Natural (Float (Ada.Calendar.Clock - Started) * 1000.0));
            end if;
         end;
      end loop;
   end Gather;

   -------------
   -- Release --
   -------------

   procedure Release (Item : in out Gen.Picture_Set) is
   begin
      T.Free (Item.Rows);
      Free (Item.Crops);
      Free (Item.Counts);
      Free (Item.Places);
      Free (Item.Kinds);
      Free (Item.Video_Slots);
      Free (Item.Times);
      Item := Gen.No_Pictures;
   end Release;

end Model_Runner.CLI.Pictures;
