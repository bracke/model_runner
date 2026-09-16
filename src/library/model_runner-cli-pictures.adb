with Ada.Calendar;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Model_Runner.Bytes;
with Model_Runner.Images;
with Model_Runner.Numerics;
with Model_Runner.Tensors;

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

   use type Ada.Calendar.Time;
   use type N.Element_Count;
   use type T.Real_Array_Access;
   use type Gen.Crop_Counts_Access;
   use type L.Row_Places_Access;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Tokenizer.Token_Id;

   --  The files a list of parts names as pictures: each part whose type
   --  is image or image_url, and its path -- or its url, which is a path
   --  here, there being nothing to fetch with. Found is called for each
   --  in order.
   procedure Named_Pictures
     (Parts : String; Found : access procedure (Path : String))
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

      Depth : Natural := 0;
      Kind, Path : US.Unbounded_String;
   begin
      while I <= Parts'Last loop
         case Parts (I) is
            when '{' =>
               Depth := Depth + 1;
               if Depth = 1 then
                  Kind := US.Null_Unbounded_String;
                  Path := US.Null_Unbounded_String;
               end if;
               I := I + 1;
            when '}' =>
               if Depth = 1
                 and then (US.To_String (Kind) = "image"
                           or else US.To_String (Kind) = "image_url")
                 and then US.Length (Path) > 0
               then
                  Found (US.To_String (Path));
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

   ----------------------
   -- Names_A_Picture --
   ----------------------

   function Names_A_Picture (Parts : String) return Boolean is
      Any : Boolean := False;
      procedure Note (Path : String) is
         pragma Unreferenced (Path);
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
      Paths : array (1 .. Max_Pictures) of US.Unbounded_String;
      Total : Natural := 0;
      Over  : Boolean := False;

      procedure Take (Path : String) is
      begin
         if Total < Max_Pictures then
            Total := Total + 1;
            Paths (Total) := US.To_Unbounded_String (Path);
         else
            Over := True;
         end if;
      end Take;

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

      if Total <= Into.Count then
         return;
      end if;

      --  A crop count and a row count for every picture, the ones held
      --  copied over.
      declare
         Grown_Crops : constant Gen.Crop_Counts_Access :=
           new Gen.Crop_Counts'(1 .. Total => 0);
         Grown_Counts : constant Gen.Crop_Counts_Access :=
           new Gen.Crop_Counts'(1 .. Total => Per);
      begin
         for Index in 1 .. Into.Count loop
            if Into.Crops /= null and then Index in Into.Crops.all'Range then
               Grown_Crops.all (Index) := Into.Crops.all (Index);
            end if;
            if Into.Counts /= null and then Index in Into.Counts.all'Range then
               Grown_Counts.all (Index) := Into.Counts.all (Index);
            end if;
         end loop;
         Free (Into.Crops);
         Free (Into.Counts);
         Into.Crops := Grown_Crops;
         Into.Counts := Grown_Counts;
      end;

      for Index in Into.Count + 1 .. Total loop
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

            --  One picture -- the whole, or a crop -- encoded, and its
            --  rows put after those held so far, with their places
            --  where the model reads them.
            procedure Encode_One (Shown : Model_Runner.Images.Raster) is
               Rows : T.Real_Array_Access;
            begin
               Model_Runner.Vision.Encode
                 (Item.Eyes, Shown, Team, Rows, Grid_Rows, Grid_Columns,
                  Cancel, Status);
               if E.Is_Error (Status) then
                  return;
               end if;

               declare
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
               end;
            end Encode_One;
         begin
            Model_Runner.Images.Load
              (US.To_String (Paths (Index)), Picture, Status);
            if E.Is_Error (Status) then
               return;
            end if;

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
                          (Picture.Width, Picture.Height, Grid, Column, Row,
                           Left, Top, Wide, Tall);
                        Model_Runner.Images.Crop
                          (Picture, Left, Top, Wide, Tall, Piece);
                        if Piece.Pixels = null then
                           Status := E.Make (E.Memory_Allocation_Failed);
                           E.Add_Text
                             (Status, "category", "pictures", E.Param_Identifier);
                        else
                           Encode_One (Piece);
                           Model_Runner.Images.Free (Piece);
                        end if;
                     end;
                     exit Rows_Loop when E.Is_Error (Status);
                  end loop;
               end loop Rows_Loop;
            end if;

            Model_Runner.Images.Free (Picture);
            if E.Is_Error (Status) then
               return;
            end if;

            Into.Crops.all (Index) := Tiles - 1;
            Into.Counts.all (Index) :=
              (if Tiles > 1 then Per else Natural (Added / Width));
            Into.Count := Index;
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
      Item := Gen.No_Pictures;
   end Release;

end Model_Runner.CLI.Pictures;
