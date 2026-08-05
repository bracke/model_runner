with Model_Runner.Text;

package body Model_Runner.GGUF.Containers is

   use type Interfaces.Unsigned_64;
   use type Model_Runner.Bytes.Byte_Count;
   use type Model_Runner.Bytes.Byte_Array_Access;
   use type Model_Runner.Numerics.Wide_Real;

   package B renames Model_Runner.Bytes;
   package E renames Model_Runner.Errors;
   package N renames Model_Runner.Numerics;

   -----------
   -- Close --
   -----------

   procedure Close (Item : in out Container) is
   begin
      B.Free (Item.Pool);
      Item.Pool_Used := 0;
      Item.Slices.Clear;
      Item.Entries.Clear;
      Item.Tensors.Clear;
      Item.Metadata_Map.Clear;
      Item.Tensor_Map.Clear;
      Item.Valid := False;
   exception
      when others =>
         Item.Valid := False;
   end Close;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Container) is
   begin
      Close (Item);
   end Finalize;

   --------------
   -- Is_Valid --
   --------------

   function Is_Valid (Item : Container) return Boolean is (Item.Valid);

   -------------
   -- Version --
   -------------

   function Version (Item : Container) return U32 is (Item.Format);

   ---------------
   -- Alignment --
   ---------------

   function Alignment (Item : Container) return U64 is (Item.Align);

   -----------------
   -- Data_Offset --
   -----------------

   function Data_Offset (Item : Container) return U64 is (Item.Data_Start);

   ---------------
   -- File_Size --
   ---------------

   function File_Size (Item : Container) return U64 is (Item.Total_Size);

   ------------------------
   -- Tensor_Data_Bytes --
   ------------------------

   function Tensor_Data_Bytes (Item : Container) return U64 is (Item.Data_Bytes);

   --  Return the text a slice refers to.
   function Text (Item : Container; Part : Slice) return String is
   begin
      if Item.Pool = null or else Part.Length = 0
        or else Part.Offset + Part.Length > Item.Pool_Used
      then
         return "";
      end if;

      return B.To_String
        (Item.Pool.all (Item.Pool.all'First + Part.Offset
                        .. Item.Pool.all'First + Part.Offset + Part.Length - 1));
   end Text;

   ---------------------
   -- Metadata_Count --
   ---------------------

   function Metadata_Count (Item : Container) return Natural
   is (Natural (Item.Entries.Length));

   -------------------
   -- Metadata_Key --
   -------------------

   function Metadata_Key (Item : Container; Index : Positive) return String is
   begin
      if Index > Metadata_Count (Item) then
         return "";
      else
         return Text (Item, Item.Entries (Index).Key);
      end if;
   end Metadata_Key;

   --------------------
   -- Metadata_Kind --
   --------------------

   function Metadata_Kind (Item : Container; Index : Positive) return Value_Type
   is (if Index > Metadata_Count (Item)
       then Value_UInt8
       else Item.Entries (Index).Kind);

   ----------------------------
   -- Metadata_Element_Kind --
   ----------------------------

   function Metadata_Element_Kind
     (Item : Container; Index : Positive) return Value_Type
   is (if Index > Metadata_Count (Item)
       then Value_UInt8
       else Item.Entries (Index).Element_Kind);

   ----------------------
   -- Metadata_Length --
   ----------------------

   function Metadata_Length (Item : Container; Index : Positive) return Natural
   is (if Index > Metadata_Count (Item) then 0 else Item.Entries (Index).Length);

   ----------
   -- Find --
   ----------

   function Find (Item : Container; Key : String) return Natural is
      Position : constant Name_Maps.Cursor := Item.Metadata_Map.Find (Key);
   begin
      if Name_Maps.Has_Element (Position) then
         return Name_Maps.Element (Position);
      else
         return 0;
      end if;
   end Find;

   --  Build a "key is absent" diagnostic.
   function Missing (Key : String) return E.Error_Info is
      Result : E.Error_Info := E.Make (E.GGUF_Missing_Metadata_Key);
   begin
      E.Add_Text (Result, "key", Key, E.Param_Identifier);
      return Result;
   end Missing;

   --  Build a "key has the wrong type" diagnostic.
   function Mismatch
     (Key      : String;
      Expected : String;
      Actual   : Value_Type) return E.Error_Info
   is
      Result : E.Error_Info := E.Make (E.GGUF_Metadata_Type_Mismatch);
   begin
      E.Add_Text (Result, "key", Key, E.Param_Identifier);
      E.Add_Text (Result, "expected", Expected, E.Param_Identifier);
      E.Add_Text
        (Result, "actual",
         Model_Runner.Text.To_Lower (Value_Type'Image (Actual)),
         E.Param_Identifier);
      return Result;
   end Mismatch;

   --  Build a "value outside the accepted range" diagnostic.
   function Out_Of_Range (Key : String) return E.Error_Info is
      Result : E.Error_Info := E.Make (E.GGUF_Metadata_Out_Of_Range);
   begin
      E.Add_Text (Result, "key", Key, E.Param_Identifier);
      return Result;
   end Out_Of_Range;

   -----------------
   -- Get_String --
   -----------------

   procedure Get_String
     (Item       : Container;
      Key        : String;
      Max_Length : Natural;
      Value      : out String;
      Last       : out Natural;
      Status     : out E.Error_Info)
   is
      Index : constant Natural := Find (Item, Key);
   begin
      Value := [others => ' '];
      Last := 0;

      if Index = 0 then
         Status := Missing (Key);
         return;
      end if;

      declare
         Found : Metadata_Entry renames Item.Entries (Index);
      begin
         if Found.Kind /= Value_String then
            Status := Mismatch (Key, "string", Found.Kind);
            return;
         end if;

         declare
            Content : constant String := Text (Item, Found.Payload);
         begin
            if Content'Length > Max_Length or else Content'Length > Value'Length
            then
               Status := Out_Of_Range (Key);
               E.Add_Integer
                 (Status, "length", Long_Long_Integer (Content'Length),
                  E.Param_Bytes);
               E.Add_Integer
                 (Status, "limit",
                  Long_Long_Integer (Natural'Min (Max_Length, Value'Length)),
                  E.Param_Bytes);
               return;
            end if;

            Last := Content'Length;
            if Last > 0 then
               Value (Value'First .. Value'First + Last - 1) := Content;
            end if;
            Status := E.Success;
         end;
      end;
   end Get_String;

   -------------------
   -- String_Value --
   -------------------

   function String_Value (Item : Container; Key : String) return String is
      Index : constant Natural := Find (Item, Key);
   begin
      if Index = 0 or else Item.Entries (Index).Kind /= Value_String then
         return "";
      else
         return Text (Item, Item.Entries (Index).Payload);
      end if;
   end String_Value;

   ------------------
   -- Get_Integer --
   ------------------

   procedure Get_Integer
     (Item    : Container;
      Key     : String;
      Minimum : Long_Long_Integer;
      Maximum : Long_Long_Integer;
      Value   : out Long_Long_Integer;
      Status  : out E.Error_Info)
   is
      Index : constant Natural := Find (Item, Key);
   begin
      Value := Minimum;

      if Index = 0 then
         Status := Missing (Key);
         return;
      end if;

      declare
         Found : Metadata_Entry renames Item.Entries (Index);
      begin
         if not Is_Integer (Found.Kind) then
            Status := Mismatch (Key, "integer", Found.Kind);
            return;
         end if;

         if Found.Signed < Minimum or else Found.Signed > Maximum then
            Status := Out_Of_Range (Key);
            E.Add_Integer (Status, "value", Found.Signed);
            E.Add_Integer (Status, "minimum", Minimum);
            E.Add_Integer (Status, "maximum", Maximum);
            return;
         end if;

         Value := Found.Signed;
         Status := E.Success;
      end;
   end Get_Integer;

   ----------------
   -- Get_Float --
   ----------------

   procedure Get_Float
     (Item    : Container;
      Key     : String;
      Minimum : N.Wide_Real;
      Maximum : N.Wide_Real;
      Value   : out N.Wide_Real;
      Status  : out E.Error_Info)
   is
      Index : constant Natural := Find (Item, Key);
   begin
      Value := Minimum;

      if Index = 0 then
         Status := Missing (Key);
         return;
      end if;

      declare
         Found : Metadata_Entry renames Item.Entries (Index);
      begin
         if not Is_Float (Found.Kind) then
            Status := Mismatch (Key, "float", Found.Kind);
            return;
         end if;

         if not N.Is_Finite (Found.Number)
           or else Found.Number < Minimum
           or else Found.Number > Maximum
         then
            Status := Out_Of_Range (Key);
            E.Add_Real (Status, "value", Long_Float (Found.Number));
            return;
         end if;

         Value := Found.Number;
         Status := E.Success;
      end;
   end Get_Float;

   ------------------
   -- Get_Boolean --
   ------------------

   procedure Get_Boolean
     (Item   : Container;
      Key    : String;
      Value  : out Boolean;
      Status : out E.Error_Info)
   is
      Index : constant Natural := Find (Item, Key);
   begin
      Value := False;

      if Index = 0 then
         Status := Missing (Key);
         return;
      end if;

      if Item.Entries (Index).Kind /= Value_Bool then
         Status := Mismatch (Key, "bool", Item.Entries (Index).Kind);
         return;
      end if;

      Value := Item.Entries (Index).Flag;
      Status := E.Success;
   end Get_Boolean;

   ------------------------
   -- Get_Array_Length --
   ------------------------

   procedure Get_Array_Length
     (Item    : Container;
      Key     : String;
      Element : Value_Type;
      Length  : out Natural;
      Status  : out E.Error_Info)
   is
      Index : constant Natural := Find (Item, Key);
   begin
      Length := 0;

      if Index = 0 then
         Status := Missing (Key);
         return;
      end if;

      declare
         Found : Metadata_Entry renames Item.Entries (Index);
      begin
         if Found.Kind /= Value_Array then
            Status := Mismatch (Key, "array", Found.Kind);
            return;
         end if;

         if Found.Element_Kind /= Element then
            Status := Mismatch
              (Key,
               Model_Runner.Text.To_Lower (Value_Type'Image (Element)),
               Found.Element_Kind);
            return;
         end if;

         Length := Found.Length;
         Status := E.Success;
      end;
   end Get_Array_Length;

   --  Locate an array entry and check its element type and index bound.
   procedure Locate_Element
     (Item    : Container;
      Key     : String;
      Index   : Positive;
      Element : Value_Type;
      Found   : out Natural;
      Status  : out E.Error_Info) is
   begin
      Found := Find (Item, Key);

      if Found = 0 then
         Status := Missing (Key);
         return;
      end if;

      declare
         Entry_Value : Metadata_Entry renames Item.Entries (Found);
      begin
         if Entry_Value.Kind /= Value_Array then
            Status := Mismatch (Key, "array", Entry_Value.Kind);
            Found := 0;
            return;
         end if;

         if Entry_Value.Element_Kind /= Element then
            Status := Mismatch
              (Key,
               Model_Runner.Text.To_Lower (Value_Type'Image (Element)),
               Entry_Value.Element_Kind);
            Found := 0;
            return;
         end if;

         if Index > Entry_Value.Length then
            Status := Out_Of_Range (Key);
            E.Add_Integer (Status, "index", Long_Long_Integer (Index));
            E.Add_Integer
              (Status, "length", Long_Long_Integer (Entry_Value.Length));
            Found := 0;
            return;
         end if;
      end;

      Status := E.Success;
   end Locate_Element;

   -------------------------------
   -- Get_String_Element_Length --
   -------------------------------

   procedure Get_String_Element_Length
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Length : out Natural;
      Status : out E.Error_Info)
   is
      Position : Natural;
   begin
      Length := 0;
      Locate_Element (Item, Key, Index, Value_String, Position, Status);

      if Position = 0 then
         return;
      end if;

      declare
         Slice_Index : constant Natural :=
           Item.Entries (Position).First_Slice + Index - 1;
      begin
         if Slice_Index < 1 or else Slice_Index > Natural (Item.Slices.Length)
         then
            Status := Out_Of_Range (Key);
            return;
         end if;
         Length := Natural (Item.Slices (Slice_Index).Length);
      end;
   end Get_String_Element_Length;

   -------------------------
   -- Get_String_Element --
   -------------------------

   procedure Get_String_Element
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Value  : out String;
      Last   : out Natural;
      Status : out E.Error_Info)
   is
      Position : Natural;
   begin
      Value := [others => ' '];
      Last := 0;
      Locate_Element (Item, Key, Index, Value_String, Position, Status);

      if Position = 0 then
         return;
      end if;

      declare
         Slice_Index : constant Natural :=
           Item.Entries (Position).First_Slice + Index - 1;
      begin
         if Slice_Index < 1 or else Slice_Index > Natural (Item.Slices.Length)
         then
            Status := Out_Of_Range (Key);
            return;
         end if;

         declare
            Content : constant String := Text (Item, Item.Slices (Slice_Index));
         begin
            if Content'Length > Value'Length then
               Status := Out_Of_Range (Key);
               E.Add_Integer
                 (Status, "length", Long_Long_Integer (Content'Length),
                  E.Param_Bytes);
               return;
            end if;

            Last := Content'Length;
            if Last > 0 then
               Value (Value'First .. Value'First + Last - 1) := Content;
            end if;
         end;
      end;
   end Get_String_Element;

   --------------------------
   -- Get_Integer_Element --
   --------------------------

   procedure Get_Integer_Element
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Value  : out Long_Long_Integer;
      Status : out E.Error_Info)
   is
      Position : constant Natural := Find (Item, Key);
   begin
      Value := 0;

      if Position = 0 then
         Status := Missing (Key);
         return;
      end if;

      declare
         Found   : Metadata_Entry renames Item.Entries (Position);
         Element : Value_Type;
      begin
         if Found.Kind /= Value_Array then
            Status := Mismatch (Key, "array", Found.Kind);
            return;
         end if;

         Element := Found.Element_Kind;

         if not Is_Integer (Element) then
            Status := Mismatch (Key, "integer", Element);
            return;
         end if;

         if Index > Found.Length then
            Status := Out_Of_Range (Key);
            E.Add_Integer (Status, "index", Long_Long_Integer (Index));
            return;
         end if;

         declare
            Width  : constant B.Byte_Count := Scalar_Size (Element);
            Offset : constant B.Byte_Count :=
              Found.Payload.Offset + B.Byte_Count (Index - 1) * Width;
            Ok     : Boolean;
         begin
            if Item.Pool = null
              or else Offset + Width > Item.Pool_Used
            then
               Status := Out_Of_Range (Key);
               return;
            end if;

            case Element is
               when Value_UInt8 =>
                  Value := Long_Long_Integer
                    (B.Get_U8 (Item.Pool.all, Offset, Ok));
               when Value_Int8 =>
                  Value := Long_Long_Integer
                    (B.Get_I8 (Item.Pool.all, Offset, Ok));
               when Value_UInt16 =>
                  Value := Long_Long_Integer
                    (B.Get_U16 (Item.Pool.all, Offset, Ok));
               when Value_Int16 =>
                  Value := Long_Long_Integer
                    (B.Get_I16 (Item.Pool.all, Offset, Ok));
               when Value_UInt32 =>
                  Value := Long_Long_Integer
                    (B.Get_U32 (Item.Pool.all, Offset, Ok));
               when Value_Int32 =>
                  Value := Long_Long_Integer
                    (B.Get_I32 (Item.Pool.all, Offset, Ok));
               when Value_UInt64 =>
                  declare
                     Raw : constant Interfaces.Unsigned_64 :=
                       B.Get_U64 (Item.Pool.all, Offset, Ok);
                  begin
                     if Raw > Interfaces.Unsigned_64 (Long_Long_Integer'Last) then
                        Status := Out_Of_Range (Key);
                        return;
                     end if;
                     Value := Long_Long_Integer (Raw);
                  end;
               when Value_Int64 =>
                  Value := Long_Long_Integer
                    (B.Get_I64 (Item.Pool.all, Offset, Ok));
               when others =>
                  Ok := False;
            end case;

            if not Ok then
               Status := Out_Of_Range (Key);
               Value := 0;
               return;
            end if;
         end;
      end;

      Status := E.Success;
   end Get_Integer_Element;

   ------------------------
   -- Get_Float_Element --
   ------------------------

   procedure Get_Float_Element
     (Item   : Container;
      Key    : String;
      Index  : Positive;
      Value  : out N.Wide_Real;
      Status : out E.Error_Info)
   is
      Position : constant Natural := Find (Item, Key);
   begin
      Value := 0.0;

      if Position = 0 then
         Status := Missing (Key);
         return;
      end if;

      declare
         Found   : Metadata_Entry renames Item.Entries (Position);
         Element : Value_Type;
      begin
         if Found.Kind /= Value_Array then
            Status := Mismatch (Key, "array", Found.Kind);
            return;
         end if;

         Element := Found.Element_Kind;

         if not Is_Float (Element) then
            Status := Mismatch (Key, "float", Element);
            return;
         end if;

         if Index > Found.Length then
            Status := Out_Of_Range (Key);
            E.Add_Integer (Status, "index", Long_Long_Integer (Index));
            return;
         end if;

         declare
            Width  : constant B.Byte_Count := Scalar_Size (Element);
            Offset : constant B.Byte_Count :=
              Found.Payload.Offset + B.Byte_Count (Index - 1) * Width;
            Ok     : Boolean;
         begin
            if Item.Pool = null or else Offset + Width > Item.Pool_Used then
               Status := Out_Of_Range (Key);
               return;
            end if;

            if Element = Value_Float32 then
               Value := N.Wide_Real (B.Get_F32 (Item.Pool.all, Offset, Ok));
            else
               Value := B.Get_F64 (Item.Pool.all, Offset, Ok);
            end if;

            if not Ok then
               Status := Out_Of_Range (Key);
               Value := 0.0;
               return;
            end if;
         end;
      end;

      Status := E.Success;
   end Get_Float_Element;

   -------------------
   -- Tensor_Count --
   -------------------

   function Tensor_Count (Item : Container) return Natural
   is (Natural (Item.Tensors.Length));

   ------------------
   -- Find_Tensor --
   ------------------

   function Find_Tensor (Item : Container; Name : String) return Natural is
      Position : constant Name_Maps.Cursor := Item.Tensor_Map.Find (Name);
   begin
      if Name_Maps.Has_Element (Position) then
         return Name_Maps.Element (Position);
      else
         return 0;
      end if;
   end Find_Tensor;

   ------------------
   -- Tensor_Name --
   ------------------

   function Tensor_Name (Item : Container; Index : Positive) return String
   is (if Index > Tensor_Count (Item)
       then ""
       else Text (Item, Item.Tensors (Index).Name));

   --------------------
   -- Tensor_Format --
   --------------------

   function Tensor_Format
     (Item : Container; Index : Positive) return Tensor_Type
   is (if Index > Tensor_Count (Item)
       then Type_Unknown
       else Item.Tensors (Index).Format);

   ------------------
   -- Tensor_Rank --
   ------------------

   function Tensor_Rank (Item : Container; Index : Positive) return Positive
   is (if Index > Tensor_Count (Item) then 1 else Item.Tensors (Index).Rank);

   -----------------------
   -- Tensor_Dimension --
   -----------------------

   function Tensor_Dimension
     (Item : Container; Index : Positive; Axis : Positive) return U64
   is (if Index > Tensor_Count (Item) or else Axis > Max_Rank
       then 0
       else Item.Tensors (Index).Dimensions (Axis));

   ----------------------
   -- Tensor_Elements --
   ----------------------

   function Tensor_Elements (Item : Container; Index : Positive) return U64
   is (if Index > Tensor_Count (Item) then 0 else Item.Tensors (Index).Elements);

   --------------------
   -- Tensor_Offset --
   --------------------

   function Tensor_Offset (Item : Container; Index : Positive) return U64
   is (if Index > Tensor_Count (Item) then 0 else Item.Tensors (Index).Absolute);

   -------------------
   -- Tensor_Bytes --
   -------------------

   function Tensor_Bytes (Item : Container; Index : Positive) return U64
   is (if Index > Tensor_Count (Item) then 0 else Item.Tensors (Index).Size);

   --------------------------
   -- Tensor_Is_Supported --
   --------------------------

   function Tensor_Is_Supported
     (Item : Container; Index : Positive) return Boolean
   is (Is_Supported (Tensor_Format (Item, Index)));

end Model_Runner.GGUF.Containers;
