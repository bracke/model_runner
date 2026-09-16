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
   package N renames Model_Runner.Numerics;
   package T renames Model_Runner.Tensors;
   package US renames Ada.Strings.Unbounded;

   procedure Free is new Ada.Unchecked_Deallocation
     (Gen.Crop_Counts, Gen.Crop_Counts_Access);

   use type Ada.Calendar.Time;
   use type N.Element_Count;
   use type T.Real_Array_Access;
   use type Gen.Crop_Counts_Access;
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

      Item.Marker := Model_Runner.Tokenizer.Find (Words.all, "<start_of_image>");
      Item.Soft := Model_Runner.Tokenizer.Find (Words.all, "<image_soft_token>");
      Item.Closer := Model_Runner.Tokenizer.Find (Words.all, "<end_of_image>");
      if Item.Marker = Model_Runner.Tokenizer.No_Token
        or else Item.Soft = Model_Runner.Tokenizer.No_Token
      then
         Status := E.Make (E.Arch_Vision_Tokens_Missing);
         E.Add_Text
           (Status, "token",
            (if Item.Marker = Model_Runner.Tokenizer.No_Token
             then "<start_of_image>" else "<image_soft_token>"),
            E.Param_Identifier);
         return;
      end if;

      Model_Runner.Vision.Open (Item.Eyes, Projector, Status);
      if E.Is_Error (Status) then
         return;
      end if;

      --  What the reference processor writes round a picture before it
      --  tokenizes -- two line breaks either side of the marker -- and the
      --  words it sets a picture with crops among, and its crops apart.
      --  Gemma 3's, which is the one projector read here.
      Item.Marker_Text := Model_Runner.Text.To_Bounded ("<start_of_image>");
      Item.Before := Model_Runner.Text.To_Bounded (ASCII.LF & ASCII.LF);
      Item.After := Item.Before;
      Item.Lead := Model_Runner.Text.To_Bounded ("Here is the original image ");
      Item.Bridge := Model_Runner.Text.To_Bounded
        (" and here are some crops to help you see better ");
      Item.Gap := Model_Runner.Text.To_Bounded (" ");

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
      Row_Elements : constant N.Element_Count :=
        N.Element_Count (Per) * Width;
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
      Into.Marker_Text := Item.Marker_Text;
      Into.Frame_Before := Item.Before;
      Into.Frame_After := Item.After;
      Into.Crop_Lead := Item.Lead;
      Into.Crop_Bridge := Item.Bridge;
      Into.Crop_Gap := Item.Gap;

      if Total <= Into.Count then
         return;
      end if;

      --  A crop count for every picture, the ones held copied over.
      declare
         Grown : constant Gen.Crop_Counts_Access :=
           new Gen.Crop_Counts'(1 .. Total => 0);
      begin
         if Into.Crops /= null then
            for Index in Into.Crops.all'Range loop
               if Index <= Total then
                  Grown.all (Index) := Into.Crops.all (Index);
               end if;
            end loop;
            Free (Into.Crops);
         end if;
         Into.Crops := Grown;
      end;

      for Index in Into.Count + 1 .. Total loop
         declare
            Picture : Model_Runner.Images.Raster;
            Grid    : Model_Runner.Images.Tiling := Model_Runner.Images.Uncut;
            Tiles   : Positive := 1;
            Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            Held    : constant N.Element_Count :=
              (if Into.Rows = null then 0 else Into.Rows.all'Length);
            At_Row  : N.Element_Count := Held;

            --  One picture -- the whole, or a crop -- encoded to the rows
            --  after those held so far.
            procedure Encode_One (Shown : Model_Runner.Images.Raster) is
               Rows : T.Real_Array_Access;
            begin
               Model_Runner.Vision.Encode
                 (Item.Eyes, Shown, Team, Rows, Cancel, Status);
               if E.Is_Error (Status) then
                  return;
               end if;
               Into.Rows (At_Row .. At_Row + Rows.all'Length - 1) := Rows.all;
               At_Row := At_Row + Rows.all'Length;
               T.Free (Rows);
            end Encode_One;
         begin
            Model_Runner.Images.Load
              (US.To_String (Paths (Index)), Picture, Status);
            if E.Is_Error (Status) then
               return;
            end if;

            if Crops and then Picture.Width > 0 and then Picture.Height > 0
            then
               Grid := Model_Runner.Images.Pan_And_Scan
                 (Picture.Width, Picture.Height);
               Tiles := 1 + Grid.Across * Grid.Down;
            end if;

            --  Room for this picture's rows, whole and crops, past the
            --  rows already held.
            declare
               Grown : T.Real_Array_Access;
            begin
               T.Allocate
                 (Held + N.Element_Count (Tiles) * Row_Elements, Grown);
               if Grown = null then
                  Model_Runner.Images.Free (Picture);
                  Status := E.Make (E.Memory_Allocation_Failed);
                  E.Add_Text (Status, "category", "pictures", E.Param_Identifier);
                  return;
               end if;
               if Into.Rows /= null and then Held > 0 then
                  Grown (0 .. Held - 1) := Into.Rows (0 .. Held - 1);
               end if;
               T.Free (Into.Rows);
               Into.Rows := Grown;
            end;

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
            Into.Count := Index;
            if Reporter /= null then
               Reporter
                 (Index, Total, Tiles * Per,
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
      Item := Gen.No_Pictures;
   end Release;

end Model_Runner.CLI.Pictures;
