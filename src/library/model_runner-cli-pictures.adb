with Ada.Calendar;
with Ada.Strings.Unbounded;

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

   use type Ada.Calendar.Time;
   use type N.Element_Count;
   use type T.Real_Array_Access;
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
      Cancel   : Model_Runner.Cancellation.Token_Reference := null;
      Reporter : access procedure
        (Index, Total : Positive; Milliseconds : Natural) := null;
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

      if Total <= Into.Count then
         return;
      end if;

      --  Room for every picture, the rows already held copied over.
      declare
         Grown : T.Real_Array_Access;
      begin
         T.Allocate (N.Element_Count (Total) * Row_Elements, Grown);
         if Grown = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            E.Add_Text (Status, "category", "pictures", E.Param_Identifier);
            return;
         end if;
         if Into.Rows /= null and then Into.Count > 0 then
            Grown (0 .. N.Element_Count (Into.Count) * Row_Elements - 1) :=
              Into.Rows (0 .. N.Element_Count (Into.Count) * Row_Elements - 1);
         end if;
         T.Free (Into.Rows);
         Into.Rows := Grown;
      end;

      for Index in Into.Count + 1 .. Total loop
         declare
            Picture : Model_Runner.Images.Raster;
            Rows    : T.Real_Array_Access;
            Started : constant Ada.Calendar.Time := Ada.Calendar.Clock;
            At_Row  : constant N.Element_Count :=
              N.Element_Count (Index - 1) * Row_Elements;
         begin
            Model_Runner.Images.Load
              (US.To_String (Paths (Index)), Picture, Status);
            if E.Is_Error (Status) then
               return;
            end if;
            Model_Runner.Vision.Encode
              (Item.Eyes, Picture, Team, Rows, Cancel, Status);
            Model_Runner.Images.Free (Picture);
            if E.Is_Error (Status) then
               return;
            end if;
            Into.Rows (At_Row .. At_Row + Rows.all'Length - 1) := Rows.all;
            T.Free (Rows);
            Into.Count := Index;
            if Reporter /= null then
               Reporter
                 (Index, Total,
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
      Item := Gen.No_Pictures;
   end Release;

end Model_Runner.CLI.Pictures;
