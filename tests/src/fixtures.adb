with Ada.Unchecked_Conversion;
with Model_Runner.Arithmetic;

package body Fixtures is

   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;
   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type N.Element_Count;
   use type N.Real;

   --  The IQ3_S grid: 512 entries, each four small odd magnitudes packed as
   --  the four bytes of a thirty-two bit word, low byte first. A nine-bit
   --  index -- a qs byte and a high bit -- selects one. The engine carries
   --  the same table; the encoder searches it to place each group of four.
   IQ3S_Grid : constant array (0 .. 511) of Interfaces.Unsigned_32 :=
     [
      16#01010101#, 16#01010103#, 16#01010105#, 16#0101010B#, 16#0101010F#, 16#01010301#,
      16#01010303#, 16#01010305#, 16#01010309#, 16#0101030D#, 16#01010501#, 16#01010503#,
      16#0101050B#, 16#01010707#, 16#01010901#, 16#01010905#, 16#0101090B#, 16#0101090F#,
      16#01010B03#, 16#01010B07#, 16#01010D01#, 16#01010D05#, 16#01010F03#, 16#01010F09#,
      16#01010F0F#, 16#01030101#, 16#01030103#, 16#01030105#, 16#01030109#, 16#01030301#,
      16#01030303#, 16#0103030B#, 16#01030501#, 16#01030507#, 16#0103050F#, 16#01030703#,
      16#0103070B#, 16#01030909#, 16#01030D03#, 16#01030D0B#, 16#01030F05#, 16#01050101#,
      16#01050103#, 16#0105010B#, 16#0105010F#, 16#01050301#, 16#01050307#, 16#0105030D#,
      16#01050503#, 16#0105050B#, 16#01050701#, 16#01050709#, 16#01050905#, 16#0105090B#,
      16#0105090F#, 16#01050B03#, 16#01050B07#, 16#01050F01#, 16#01050F07#, 16#01070107#,
      16#01070303#, 16#0107030B#, 16#01070501#, 16#01070505#, 16#01070703#, 16#01070707#,
      16#0107070D#, 16#01070909#, 16#01070B01#, 16#01070B05#, 16#01070D0F#, 16#01070F03#,
      16#01070F0B#, 16#01090101#, 16#01090307#, 16#0109030F#, 16#01090503#, 16#01090509#,
      16#01090705#, 16#01090901#, 16#01090907#, 16#01090B03#, 16#01090F01#, 16#010B0105#,
      16#010B0109#, 16#010B0501#, 16#010B0505#, 16#010B050D#, 16#010B0707#, 16#010B0903#,
      16#010B090B#, 16#010B090F#, 16#010B0D0D#, 16#010B0F07#, 16#010D010D#, 16#010D0303#,
      16#010D0307#, 16#010D0703#, 16#010D0B05#, 16#010D0F03#, 16#010F0101#, 16#010F0105#,
      16#010F0109#, 16#010F0501#, 16#010F0505#, 16#010F050D#, 16#010F0707#, 16#010F0B01#,
      16#010F0B09#, 16#03010101#, 16#03010103#, 16#03010105#, 16#03010109#, 16#03010301#,
      16#03010303#, 16#03010307#, 16#0301030B#, 16#0301030F#, 16#03010501#, 16#03010505#,
      16#03010703#, 16#03010709#, 16#0301070D#, 16#03010B09#, 16#03010B0D#, 16#03010D03#,
      16#03010F05#, 16#03030101#, 16#03030103#, 16#03030107#, 16#0303010D#, 16#03030301#,
      16#03030309#, 16#03030503#, 16#03030701#, 16#03030707#, 16#03030903#, 16#03030B01#,
      16#03030B05#, 16#03030F01#, 16#03030F0D#, 16#03050101#, 16#03050305#, 16#0305030B#,
      16#0305030F#, 16#03050501#, 16#03050509#, 16#03050705#, 16#03050901#, 16#03050907#,
      16#03050B0B#, 16#03050D01#, 16#03050F05#, 16#03070103#, 16#03070109#, 16#0307010F#,
      16#03070301#, 16#03070307#, 16#03070503#, 16#0307050F#, 16#03070701#, 16#03070709#,
      16#03070903#, 16#03070D05#, 16#03070F01#, 16#03090107#, 16#0309010B#, 16#03090305#,
      16#03090309#, 16#03090703#, 16#03090707#, 16#03090905#, 16#0309090D#, 16#03090B01#,
      16#03090B09#, 16#030B0103#, 16#030B0301#, 16#030B0307#, 16#030B0503#, 16#030B0701#,
      16#030B0705#, 16#030B0B03#, 16#030D0501#, 16#030D0509#, 16#030D050F#, 16#030D0909#,
      16#030D090D#, 16#030F0103#, 16#030F0107#, 16#030F0301#, 16#030F0305#, 16#030F0503#,
      16#030F070B#, 16#030F0903#, 16#030F0D05#, 16#030F0F01#, 16#05010101#, 16#05010103#,
      16#05010107#, 16#0501010B#, 16#0501010F#, 16#05010301#, 16#05010305#, 16#05010309#,
      16#0501030D#, 16#05010503#, 16#05010507#, 16#0501050F#, 16#05010701#, 16#05010705#,
      16#05010903#, 16#05010907#, 16#0501090B#, 16#05010B01#, 16#05010B05#, 16#05010D0F#,
      16#05010F01#, 16#05010F07#, 16#05010F0B#, 16#05030101#, 16#05030105#, 16#05030301#,
      16#05030307#, 16#0503030F#, 16#05030505#, 16#0503050B#, 16#05030703#, 16#05030709#,
      16#05030905#, 16#05030B03#, 16#05050103#, 16#05050109#, 16#0505010F#, 16#05050503#,
      16#05050507#, 16#05050701#, 16#0505070F#, 16#05050903#, 16#05050B07#, 16#05050B0F#,
      16#05050F03#, 16#05050F09#, 16#05070101#, 16#05070105#, 16#0507010B#, 16#05070303#,
      16#05070505#, 16#05070509#, 16#05070703#, 16#05070707#, 16#05070905#, 16#05070B01#,
      16#05070D0D#, 16#05090103#, 16#0509010F#, 16#05090501#, 16#05090507#, 16#05090705#,
      16#0509070B#, 16#05090903#, 16#05090F05#, 16#05090F0B#, 16#050B0109#, 16#050B0303#,
      16#050B0505#, 16#050B070F#, 16#050B0901#, 16#050B0B07#, 16#050B0F01#, 16#050D0101#,
      16#050D0105#, 16#050D010F#, 16#050D0503#, 16#050D0B0B#, 16#050D0D03#, 16#050F010B#,
      16#050F0303#, 16#050F050D#, 16#050F0701#, 16#050F0907#, 16#050F0B01#, 16#07010105#,
      16#07010303#, 16#07010307#, 16#0701030B#, 16#0701030F#, 16#07010505#, 16#07010703#,
      16#07010707#, 16#0701070B#, 16#07010905#, 16#07010909#, 16#0701090F#, 16#07010B03#,
      16#07010D07#, 16#07010F03#, 16#07030103#, 16#07030107#, 16#0703010B#, 16#07030309#,
      16#07030503#, 16#07030507#, 16#07030901#, 16#07030D01#, 16#07030F05#, 16#07030F0D#,
      16#07050101#, 16#07050305#, 16#07050501#, 16#07050705#, 16#07050709#, 16#07050B01#,
      16#07070103#, 16#07070301#, 16#07070309#, 16#07070503#, 16#07070507#, 16#0707050F#,
      16#07070701#, 16#07070903#, 16#07070907#, 16#0707090F#, 16#07070B0B#, 16#07070F07#,
      16#07090107#, 16#07090303#, 16#0709030D#, 16#07090505#, 16#07090703#, 16#07090B05#,
      16#07090D01#, 16#07090D09#, 16#070B0103#, 16#070B0301#, 16#070B0305#, 16#070B050B#,
      16#070B0705#, 16#070B0909#, 16#070B0B0D#, 16#070B0F07#, 16#070D030D#, 16#070D0903#,
      16#070F0103#, 16#070F0107#, 16#070F0501#, 16#070F0505#, 16#070F070B#, 16#09010101#,
      16#09010109#, 16#09010305#, 16#09010501#, 16#09010509#, 16#0901050F#, 16#09010705#,
      16#09010903#, 16#09010B01#, 16#09010F01#, 16#09030105#, 16#0903010F#, 16#09030303#,
      16#09030307#, 16#09030505#, 16#09030701#, 16#0903070B#, 16#09030907#, 16#09030B03#,
      16#09030B0B#, 16#09050103#, 16#09050107#, 16#09050301#, 16#0905030B#, 16#09050503#,
      16#09050707#, 16#09050901#, 16#09050B0F#, 16#09050D05#, 16#09050F01#, 16#09070109#,
      16#09070303#, 16#09070307#, 16#09070501#, 16#09070505#, 16#09070703#, 16#0907070B#,
      16#09090101#, 16#09090105#, 16#09090509#, 16#0909070F#, 16#09090901#, 16#09090F03#,
      16#090B010B#, 16#090B010F#, 16#090B0503#, 16#090B0D05#, 16#090D0307#, 16#090D0709#,
      16#090D0D01#, 16#090F0301#, 16#090F030B#, 16#090F0701#, 16#090F0907#, 16#090F0B03#,
      16#0B010105#, 16#0B010301#, 16#0B010309#, 16#0B010505#, 16#0B010901#, 16#0B010909#,
      16#0B01090F#, 16#0B010B05#, 16#0B010D0D#, 16#0B010F09#, 16#0B030103#, 16#0B030107#,
      16#0B03010B#, 16#0B030305#, 16#0B030503#, 16#0B030705#, 16#0B030F05#, 16#0B050101#,
      16#0B050303#, 16#0B050507#, 16#0B050701#, 16#0B05070D#, 16#0B050B07#, 16#0B070105#,
      16#0B07010F#, 16#0B070301#, 16#0B07050F#, 16#0B070909#, 16#0B070B03#, 16#0B070D0B#,
      16#0B070F07#, 16#0B090103#, 16#0B090109#, 16#0B090501#, 16#0B090705#, 16#0B09090D#,
      16#0B0B0305#, 16#0B0B050D#, 16#0B0B0B03#, 16#0B0B0B07#, 16#0B0D0905#, 16#0B0F0105#,
      16#0B0F0109#, 16#0B0F0505#, 16#0D010303#, 16#0D010307#, 16#0D01030B#, 16#0D010703#,
      16#0D010707#, 16#0D010D01#, 16#0D030101#, 16#0D030501#, 16#0D03050F#, 16#0D030D09#,
      16#0D050305#, 16#0D050709#, 16#0D050905#, 16#0D050B0B#, 16#0D050D05#, 16#0D050F01#,
      16#0D070101#, 16#0D070309#, 16#0D070503#, 16#0D070901#, 16#0D09050B#, 16#0D090907#,
      16#0D090D05#, 16#0D0B0101#, 16#0D0B0107#, 16#0D0B0709#, 16#0D0B0D01#, 16#0D0D010B#,
      16#0D0D0901#, 16#0D0F0303#, 16#0D0F0307#, 16#0F010101#, 16#0F010109#, 16#0F01010F#,
      16#0F010501#, 16#0F010505#, 16#0F01070D#, 16#0F010901#, 16#0F010B09#, 16#0F010D05#,
      16#0F030105#, 16#0F030303#, 16#0F030509#, 16#0F030907#, 16#0F03090B#, 16#0F050103#,
      16#0F050109#, 16#0F050301#, 16#0F05030D#, 16#0F050503#, 16#0F050701#, 16#0F050B03#,
      16#0F070105#, 16#0F070705#, 16#0F07070B#, 16#0F070B07#, 16#0F090103#, 16#0F09010B#,
      16#0F090307#, 16#0F090501#, 16#0F090B01#, 16#0F0B0505#, 16#0F0B0905#, 16#0F0D0105#,
      16#0F0D0703#, 16#0F0F0101#
];

   --  Append bytes to a growable buffer.
   procedure Put (Item : in out Byte_Buffer; Data : B.Byte_Array) is
      Needed : constant B.Byte_Count := Item.Used + Data'Length;
   begin
      if Item.Data = null or else Needed > Item.Data.all'Length then
         declare
            Capacity : B.Byte_Count :=
              (if Item.Data = null then 256 else B.Byte_Count (Item.Data.all'Length));
            Fresh    : B.Byte_Array_Access;
         begin
            while Capacity < Needed loop
               Capacity := Capacity * 2;
            end loop;
            B.Allocate (Capacity, Fresh);
            if Item.Data /= null and then Item.Used > 0 then
               Fresh.all (1 .. Item.Used) := Item.Data.all (1 .. Item.Used);
            end if;
            B.Free (Item.Data);
            Item.Data := Fresh;
         end;
      end if;

      if Data'Length > 0 then
         Item.Data.all (Item.Used + 1 .. Item.Used + Data'Length) := Data;
         Item.Used := Item.Used + Data'Length;
      end if;
   end Put;

   --  Append a GGUF string: 64-bit length then bytes.
   procedure Put_String (Item : in out Byte_Buffer; Value : String) is
   begin
      Put (Item, B.Put_U64 (Interfaces.Unsigned_64 (Value'Length)));
      Put (Item, B.To_Bytes (Value));
   end Put_String;

   --  Append a metadata key and its value-type tag.
   --  Record where a field was written, within its own section.
   procedure Note
     (Item  : in out Builder;
      Where : Section;
      Field : Field_Name;
      Owner : Natural;
      Axis  : Natural := 0)
   is
      Position : constant B.Byte_Count :=
        (if Where = In_Metadata
         then Item.Metadata.Used
         else Item.Descriptors.Used);
   begin
      if Item.Marks_Used < Max_Marks then
         Item.Marks_Used := Item.Marks_Used + 1;
         Item.Marks (Item.Marks_Used) :=
           (Where     => Where,
            Field     => Field,
            Owner     => Owner,
            Axis      => Axis,
            At_Offset => Position);
      end if;
   end Note;

   procedure Put_Header
     (Item : in out Builder;
      Key  : String;
      Kind : G.Value_Type) is
   begin
      Put_String (Item.Metadata, Key);
      Note (Item, In_Metadata, Metadata_Value_Type, Item.Metadata_Count + 1);
      Put (Item.Metadata, B.Put_U32 (G.Value_Code (Kind)));
      Item.Metadata_Count := Item.Metadata_Count + 1;
   end Put_Header;

   -----------
   -- Reset --
   -----------

   procedure Reset
     (Item      : in out Builder;
      Version   : G.U32 := 3;
      Alignment : G.U64 := 0) is
   begin
      B.Free (Item.Metadata.Data);
      B.Free (Item.Descriptors.Data);
      B.Free (Item.Tensor_Data.Data);
      Item.Metadata := (null, 0);
      Item.Descriptors := (null, 0);
      Item.Tensor_Data := (null, 0);
      Item.Metadata_Count := 0;
      Item.Tensor_Count := 0;
      Item.Array_Open := False;
      Item.Version := Version;
      Item.Alignment := Alignment;

      if Alignment /= 0 then
         Add_U32 (Item, "general.alignment", Interfaces.Unsigned_32 (Alignment));
      end if;
   end Reset;

   ----------------
   -- Add_String --
   ----------------

   procedure Add_String (Item : in out Builder; Key, Value : String) is
   begin
      Put_Header (Item, Key, G.Value_String);
      Note (Item, In_Metadata, String_Value_Length, Item.Metadata_Count);
      Put_String (Item.Metadata, Value);
   end Add_String;

   -------------
   -- Add_U32 --
   -------------

   procedure Add_U32
     (Item : in out Builder; Key : String; Value : Interfaces.Unsigned_32) is
   begin
      Put_Header (Item, Key, G.Value_UInt32);
      Put (Item.Metadata, B.Put_U32 (Value));
   end Add_U32;

   -------------
   -- Add_U64 --
   -------------

   procedure Add_U64
     (Item : in out Builder; Key : String; Value : Interfaces.Unsigned_64) is
   begin
      Put_Header (Item, Key, G.Value_UInt64);
      Put (Item.Metadata, B.Put_U64 (Value));
   end Add_U64;

   -------------
   -- Add_I32 --
   -------------

   procedure Add_I32
     (Item : in out Builder; Key : String; Value : Interfaces.Integer_32)
   is
      use type Interfaces.Integer_32;
      Raw : constant Interfaces.Unsigned_32 :=
        (if Value >= 0
         then Interfaces.Unsigned_32 (Value)
         else Interfaces.Unsigned_32 (Interfaces.Integer_64 (Value) + 16#1_0000_0000#));
   begin
      Put_Header (Item, Key, G.Value_Int32);
      Put (Item.Metadata, B.Put_U32 (Raw));
   end Add_I32;

   -------------
   -- Add_F32 --
   -------------

   procedure Add_F32 (Item : in out Builder; Key : String; Value : N.Real) is
   begin
      Put_Header (Item, Key, G.Value_Float32);
      Put (Item.Metadata, B.Put_F32 (Value));
   end Add_F32;

   --------------
   -- Add_Bool --
   --------------

   procedure Add_Bool (Item : in out Builder; Key : String; Value : Boolean) is
   begin
      Put_Header (Item, Key, G.Value_Bool);
      Put (Item.Metadata, [1 => (if Value then 1 else 0)]);
   end Add_Bool;

   ------------------
   -- Begin_Array --
   ------------------

   procedure Begin_Array
     (Item    : in out Builder;
      Key     : String;
      Element : G.Value_Type;
      Count   : Natural) is
   begin
      Put_Header (Item, Key, G.Value_Array);
      Note (Item, In_Metadata, Array_Element_Type, Item.Metadata_Count);
      Put (Item.Metadata, B.Put_U32 (G.Value_Code (Element)));
      Put (Item.Metadata, B.Put_U64 (Interfaces.Unsigned_64 (Count)));
      Item.Array_Open := True;
   end Begin_Array;

   --------------------
   -- String_Element --
   --------------------

   procedure String_Element (Item : in out Builder; Value : String) is
   begin
      Put_String (Item.Metadata, Value);
   end String_Element;

   -------------------
   -- Int32_Element --
   -------------------

   procedure Int32_Element
     (Item : in out Builder; Value : Interfaces.Integer_32)
   is
      use type Interfaces.Integer_32;
      Raw : constant Interfaces.Unsigned_32 :=
        (if Value >= 0
         then Interfaces.Unsigned_32 (Value)
         else Interfaces.Unsigned_32 (Interfaces.Integer_64 (Value) + 16#1_0000_0000#));
   begin
      Put (Item.Metadata, B.Put_U32 (Raw));
   end Int32_Element;

   -------------------
   -- Float_Element --
   -------------------

   procedure UInt64_Element
     (Item : in out Builder; Value : Interfaces.Unsigned_64) is
   begin
      Put (Item.Metadata, B.Put_U64 (Value));
   end UInt64_Element;

   procedure Float_Element (Item : in out Builder; Value : N.Real) is
   begin
      Put (Item.Metadata, B.Put_F32 (Value));
   end Float_Element;

   ------------------
   -- Bool_Element --
   ------------------

   procedure Bool_Element (Item : in out Builder; Value : Boolean) is
   begin
      Put (Item.Metadata, [1 => (if Value then 1 else 0)]);
   end Bool_Element;

   ----------------
   -- End_Array --
   ----------------

   procedure End_Array (Item : in out Builder) is
   begin
      Item.Array_Open := False;
   end End_Array;

   ----------------
   -- Add_Tensor --
   ----------------

   procedure Add_Tensor
     (Item       : in out Builder;
      Name       : String;
      Dimensions : Dimension_List;
      Format     : G.Tensor_Type;
      Data       : B.Byte_Array)
   is
      Align   : constant G.U64 :=
        (if Item.Alignment = 0 then G.Default_Alignment else Item.Alignment);
      Padding : B.Byte_Count;
   begin
      --  Pad the previous tensor so that this one starts at an aligned offset
      --  within the data section, which is what the parser requires.
      Padding := B.Byte_Count (Align) -
        (Item.Tensor_Data.Used mod B.Byte_Count (Align));
      if Padding /= B.Byte_Count (Align) then
         Put (Item.Tensor_Data, B.Byte_Array'(1 .. Padding => 0));
      end if;

      Put_String (Item.Descriptors, Name);
      Put (Item.Descriptors, B.Put_U32 (Interfaces.Unsigned_32 (Dimensions'Length)));
      for Axis in Dimensions'Range loop
         Note (Item, In_Descriptors, Tensor_Extent, Item.Tensor_Count + 1,
               Axis - Dimensions'First + 1);
         Put (Item.Descriptors, B.Put_U64 (Dimensions (Axis)));
      end loop;
      Note (Item, In_Descriptors, Tensor_Format, Item.Tensor_Count + 1);
      Put (Item.Descriptors, B.Put_U32 (G.Tensor_Code (Format)));
      Note (Item, In_Descriptors, Tensor_Offset, Item.Tensor_Count + 1);
      Put (Item.Descriptors, B.Put_U64 (Interfaces.Unsigned_64 (Item.Tensor_Data.Used)));

      Put (Item.Tensor_Data, Data);
      Item.Tensor_Count := Item.Tensor_Count + 1;
   end Add_Tensor;

   --------------------
   -- Field_Position --
   --------------------

   function Field_Position
     (Item  : Builder;
      Field : Field_Name;
      Owner : Positive;
      Axis  : Positive := 1) return B.Byte_Count
   is
      --  Magic, version, tensor count and metadata count.
      Header_Bytes : constant B.Byte_Count := 24;
   begin
      for Index in 1 .. Item.Marks_Used loop
         declare
            Found : Mark renames Item.Marks (Index);
         begin
            if Found.Field = Field
              and then Found.Owner = Owner
              and then (Field /= Tensor_Extent or else Found.Axis = Axis)
            then
               return Header_Bytes
                 + (if Found.Where = In_Metadata
                    then Found.At_Offset
                    else Item.Metadata.Used + Found.At_Offset);
            end if;
         end;
      end loop;

      return 0;
   end Field_Position;

   --------------
   -- Poke_U32 --
   --------------

   procedure Poke_U32
     (Image     : in out B.Byte_Array;
      At_Offset : B.Byte_Count;
      Value     : Interfaces.Unsigned_32)
   is
      Written : constant B.Byte_Array := B.Put_U32 (Value);
   begin
      Image (Image'First + At_Offset .. Image'First + At_Offset + 3) := Written;
   end Poke_U32;

   --------------
   -- Poke_U64 --
   --------------

   procedure Poke_U64
     (Image     : in out B.Byte_Array;
      At_Offset : B.Byte_Count;
      Value     : Interfaces.Unsigned_64)
   is
      Written : constant B.Byte_Array := B.Put_U64 (Value);
   begin
      Image (Image'First + At_Offset .. Image'First + At_Offset + 7) := Written;
   end Poke_U64;

   -----------
   -- Build --
   -----------

   procedure Build (Item : in out Builder; Result : out B.Byte_Array_Access) is
      package A renames Model_Runner.Arithmetic;
      Header : Byte_Buffer;
      Align  : constant G.U64 :=
        (if Item.Alignment = 0 then G.Default_Alignment else Item.Alignment);
   begin
      Put (Header, B.Put_U32 (G.Magic));
      Put (Header, B.Put_U32 (Item.Version));
      Put (Header, B.Put_U64 (Interfaces.Unsigned_64 (Item.Tensor_Count)));
      Put (Header, B.Put_U64 (Interfaces.Unsigned_64 (Item.Metadata_Count)));

      declare
         Prefix : constant B.Byte_Count :=
           Header.Used + Item.Metadata.Used + Item.Descriptors.Used;
         Start  : constant B.Byte_Count :=
           B.Byte_Count
             (A.Value
                (A.Align_Up (A.To_Checked (Interfaces.Unsigned_64 (Prefix)), Align)));
         Total  : constant B.Byte_Count := Start + Item.Tensor_Data.Used;
      begin
         B.Allocate (Total, Result);
         Result.all := [others => 0];
         Result.all (1 .. Header.Used) := Header.Data.all (1 .. Header.Used);

         if Item.Metadata.Used > 0 then
            Result.all (Header.Used + 1 .. Header.Used + Item.Metadata.Used) :=
              Item.Metadata.Data.all (1 .. Item.Metadata.Used);
         end if;

         if Item.Descriptors.Used > 0 then
            Result.all
              (Header.Used + Item.Metadata.Used + 1 .. Prefix) :=
              Item.Descriptors.Data.all (1 .. Item.Descriptors.Used);
         end if;

         if Item.Tensor_Data.Used > 0 then
            Result.all (Start + 1 .. Total) :=
              Item.Tensor_Data.Data.all (1 .. Item.Tensor_Data.Used);
         end if;
      end;

      B.Free (Header.Data);
   end Build;

   ------------------
   -- Put_Infinity --
   ------------------

   procedure Put_Infinity
     (Into : in out N.Real_Array; Where : N.Element_Count)
   is
      pragma Suppress (Range_Check);
      pragma Suppress (Validity_Check);

      function Bits is new Ada.Unchecked_Conversion
        (Interfaces.Unsigned_32, N.Real);
   begin
      Into (Where) := Bits (16#7F80_0000#);
   end Put_Infinity;

   -----------------
   -- Encode_F32 --
   -----------------

   function Encode_F32 (Values : N.Real_Array) return B.Byte_Array is
      Result : B.Byte_Array (1 .. B.Byte_Count (Values'Length) * 4);
      Target : B.Byte_Count := 0;
   begin
      for Value of Values loop
         Result (Target + 1 .. Target + 4) := B.Put_F32 (Value);
         Target := Target + 4;
      end loop;
      return Result;
   end Encode_F32;

   -----------------
   -- Encode_F16 --
   -----------------

   function Encode_F16 (Values : N.Real_Array) return B.Byte_Array is
      Result : B.Byte_Array (1 .. B.Byte_Count (Values'Length) * 2);
      Target : B.Byte_Count := 0;
   begin
      for Value of Values loop
         Result (Target + 1 .. Target + 2) :=
           B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (Value)));
         Target := Target + 2;
      end loop;
      return Result;
   end Encode_F16;

   --------------
   -- Sequence --
   --------------

   function Sequence
     (Count : N.Element_Count;
      Seed  : Interfaces.Unsigned_64;
      Scale : N.Real := 1.0) return N.Real_Array
   is
      Result : N.Real_Array (0 .. Count - 1);
      State  : Interfaces.Unsigned_64 := Seed or 1;
   begin
      for Index in Result'Range loop
         --  A 64-bit xorshift, used purely to produce a fixed, reproducible
         --  sequence. Values are mapped into -Scale .. Scale.
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         Result (Index) :=
           Scale * (N.Real (Interfaces.Shift_Right (State, 40)) / 8388608.0 - 1.0);
      end loop;
      return Result;
   end Sequence;

   ------------------
   -- Encode_Q8_0 --
   ------------------

   function Encode_BF16 (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_32;

      Result : B.Byte_Array (0 .. B.Byte_Count (Values'Length) * 2 - 1) :=
        [others => 0];
      At_Byte : B.Byte_Count := 0;
   begin
      for Value of Values loop
         declare
            Whole : constant Interfaces.Unsigned_32 := N.Bits (Value);
            Round : constant Interfaces.Unsigned_32 :=
              16#7FFF# + (Interfaces.Shift_Right (Whole, 16) and 1);
            Kept  : constant Interfaces.Unsigned_16 :=
              Interfaces.Unsigned_16
                (Interfaces.Shift_Right (Whole + Round, 16) and 16#FFFF#);
         begin
            Result (At_Byte .. At_Byte + 1) := B.Put_U16 (Kept);
            At_Byte := At_Byte + 2;
         end;
      end loop;

      return Result;
   end Encode_BF16;

   --  One block of thirty-two, four bits an element, with or without a
   --  minimum of its own. Q4_0 centres on eight and carries one
   --  half-precision number; Q4_1 lifts from a minimum and carries two.
   function Encode_Four_Bit
     (Values  : N.Real_Array;
      Centred : Boolean) return B.Byte_Array
   is
      use type Interfaces.Unsigned_8;

      Width  : constant B.Byte_Count := (if Centred then 18 else 20);
      Blocks : constant N.Element_Count := Values'Length / 32;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * Width - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 32;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * Width;

            Smallest : N.Real := Values (First);
            Largest  : N.Real := Values (First);
         begin
            for Index in 0 .. 31 loop
               Smallest := N.Real'Min
                 (Smallest, Values (First + N.Element_Count (Index)));
               Largest := N.Real'Max
                 (Largest, Values (First + N.Element_Count (Index)));
            end loop;

            declare
               --  Centred: the levels run -8 .. 7 and the scale is set by
               --  whichever end is further from zero. Lifted: they run
               --  0 .. 15 from the block's own minimum.
               Extent : constant N.Real :=
                 N.Real'Max (abs Smallest, abs Largest);
               D      : constant N.Real :=
                 (if Centred
                  then (if Extent = 0.0 then 1.0 else Extent / 7.0)
                  else (if Largest = Smallest then 1.0
                        else (Largest - Smallest) / 15.0));
               Quants : constant B.Byte_Count :=
                 At_Byte + (if Centred then 2 else 4);

               function Level (Index : Natural) return Interfaces.Unsigned_8
               is
                  Value : constant N.Real :=
                    Values (First + N.Element_Count (Index));
                  Step  : constant N.Real :=
                    (if Centred then Value / D else (Value - Smallest) / D);
               begin
                  return Interfaces.Unsigned_8
                    (N.Real'Max
                       (0.0,
                        N.Real'Min
                          (15.0,
                           N.Real'Rounding (Step)
                           + (if Centred then 8.0 else 0.0))));
               end Level;
            begin
               Result (At_Byte .. At_Byte + 1) := Encode_F16 ([1 => D]);
               if not Centred then
                  Result (At_Byte + 2 .. At_Byte + 3) :=
                    Encode_F16 ([1 => Smallest]);
               end if;

               --  Element j in the low nibble, element j + 16 in the high.
               for J in 0 .. 15 loop
                  Result (Quants + B.Byte_Count (J)) :=
                    Level (J)
                    or Interfaces.Shift_Left (Level (J + 16), 4);
               end loop;
            end;
         end;
      end loop;

      return Result;
   end Encode_Four_Bit;

   function Encode_Q4_0 (Values : N.Real_Array) return B.Byte_Array
   is (Encode_Four_Bit (Values, Centred => True));

   function Encode_Q4_1 (Values : N.Real_Array) return B.Byte_Array
   is (Encode_Four_Bit (Values, Centred => False));

   --  One block of thirty-two with a fifth bit. Q5_0 centres the level on
   --  sixteen and carries one half-precision number; Q5_1 lifts it from a
   --  minimum and carries two. The fifth bits live in four bytes read as one
   --  thirty-two bit word: bit j belongs to element j.
   function Encode_Five_Bit
     (Values  : N.Real_Array;
      Centred : Boolean) return B.Byte_Array
   is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_32;

      Width  : constant B.Byte_Count := (if Centred then 22 else 24);
      Blocks : constant N.Element_Count := Values'Length / 32;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * Width - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 32;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * Width;

            Smallest : N.Real := Values (First);
            Largest  : N.Real := Values (First);
         begin
            for Index in 0 .. 31 loop
               Smallest := N.Real'Min
                 (Smallest, Values (First + N.Element_Count (Index)));
               Largest := N.Real'Max
                 (Largest, Values (First + N.Element_Count (Index)));
            end loop;

            declare
               Extent : constant N.Real :=
                 N.Real'Max (abs Smallest, abs Largest);
               D      : constant N.Real :=
                 (if Centred
                  then (if Extent = 0.0 then 1.0 else Extent / 15.0)
                  else (if Largest = Smallest then 1.0
                        else (Largest - Smallest) / 31.0));

               Fifths_At : constant B.Byte_Count :=
                 At_Byte + (if Centred then 2 else 4);
               Quants_At : constant B.Byte_Count :=
                 At_Byte + (if Centred then 6 else 8);

               Fifths : Interfaces.Unsigned_32 := 0;

               function Level (Index : Natural) return Natural is
                  Value : constant N.Real :=
                    Values (First + N.Element_Count (Index));
                  Step  : constant N.Real :=
                    (if Centred then Value / D else (Value - Smallest) / D);
               begin
                  return Natural
                    (N.Real'Max
                       (0.0,
                        N.Real'Min
                          (31.0,
                           N.Real'Rounding (Step)
                           + (if Centred then 16.0 else 0.0))));
               end Level;
            begin
               Result (At_Byte .. At_Byte + 1) := Encode_F16 ([1 => D]);
               if not Centred then
                  Result (At_Byte + 2 .. At_Byte + 3) :=
                    Encode_F16 ([1 => Smallest]);
               end if;

               for J in 0 .. 15 loop
                  declare
                     Low  : constant Natural := Level (J);
                     High : constant Natural := Level (J + 16);
                  begin
                     Result (Quants_At + B.Byte_Count (J)) :=
                       Interfaces.Unsigned_8 (Low mod 16)
                       or Interfaces.Shift_Left
                            (Interfaces.Unsigned_8 (High mod 16), 4);

                     if Low >= 16 then
                        Fifths := Fifths
                          or Interfaces.Shift_Left (1, J);
                     end if;
                     if High >= 16 then
                        Fifths := Fifths
                          or Interfaces.Shift_Left (1, J + 16);
                     end if;
                  end;
               end loop;

               Result (Fifths_At .. Fifths_At + 3) := B.Put_U32 (Fifths);
            end;
         end;
      end loop;

      return Result;
   end Encode_Five_Bit;

   function Encode_Q5_0 (Values : N.Real_Array) return B.Byte_Array
   is (Encode_Five_Bit (Values, Centred => True));

   function Encode_Q5_1 (Values : N.Real_Array) return B.Byte_Array
   is (Encode_Five_Bit (Values, Centred => False));

   function Encode_Q3_K (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 110 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 110;

            --  Sixteen sub-blocks of sixteen, walked as halves, groups and
            --  the upper half of each group, as in the two-bit format.
            type Sub_Range is array (0 .. 15) of N.Real;
            Widest  : Sub_Range := [others => 0.0];
            Extent  : N.Real := 0.0;

            function Start_Of (Sub : Natural) return N.Element_Count is
               Half  : constant Natural := Sub / 8;
               Rest  : constant Natural := Sub mod 8;
               Group : constant Natural := Rest / 2;
               Upper : constant Natural := Rest mod 2;
            begin
               return N.Element_Count
                 (Half * 128 + Group * 32 + Upper * 16);
            end Start_Of;
         begin
            for Sub in 0 .. 15 loop
               declare
                  Base : constant N.Element_Count := First + Start_Of (Sub);
                  Most : N.Real := 0.0;
               begin
                  for L in 0 .. 15 loop
                     Most := N.Real'Max
                       (Most, abs Values (Base + N.Element_Count (L)));
                  end loop;
                  Widest (Sub) := Most;
                  Extent := N.Real'Max (Extent, Most);
               end;
            end loop;

            declare
               --  A level runs -4 .. 3 and a scale -32 .. 31, so the factor
               --  covers the widest sub-block at the widest scale.
               D : constant N.Real :=
                 (if Extent = 0.0 then 1.0 else Extent / (3.0 * 31.0));

               High   : constant B.Byte_Count := At_Byte;
               Quants : constant B.Byte_Count := At_Byte + 32;
               Scales : constant B.Byte_Count := At_Byte + 96;
            begin
               Result (At_Byte + 108 .. At_Byte + 109) :=
                 Encode_F16 ([1 => D]);

               for Sub in 0 .. 15 loop
                  declare
                     Half  : constant Natural := Sub / 8;
                     Rest  : constant Natural := Sub mod 8;
                     Group : constant Natural := Rest / 2;
                     Upper : constant Natural := Rest mod 2;

                     Factor : constant Integer :=
                       Integer'Max
                         (1,
                          Integer'Min
                            (31,
                             Integer
                               (N.Real'Ceiling (Widest (Sub) / (3.0 * D)))));
                     Step : constant N.Real := D * N.Real (Factor);

                     --  Six bits, stored biased by thirty-two: four low bits
                     --  in one of the first eight bytes and two high bits in
                     --  one of the last four, chosen by the group of four
                     --  the sub-block falls in.
                     Stored : constant Natural := Factor + 32;
                     Which  : constant Natural := Sub;
                     Place  : constant B.Byte_Count :=
                       B.Byte_Count (Which mod 4);
                     Nibble : constant B.Byte_Count :=
                       (if (Which / 4) mod 2 = 0 then Place else Place + 4);

                     Base : constant N.Element_Count := First + Start_Of (Sub);
                     From : constant B.Byte_Count :=
                       Quants + B.Byte_Count (Half * 32 + Upper * 16);
                     Mask_At : constant B.Byte_Count :=
                       High + B.Byte_Count (Upper * 16);
                     Bit : constant Interfaces.Unsigned_8 :=
                       Interfaces.Shift_Left (1, Half * 4 + Group);
                  begin
                     if Which / 4 < 2 then
                        Result (Scales + Nibble) :=
                          Result (Scales + Nibble)
                          or Interfaces.Unsigned_8 (Stored mod 16);
                     else
                        Result (Scales + Nibble) :=
                          Result (Scales + Nibble)
                          or Interfaces.Shift_Left
                               (Interfaces.Unsigned_8 (Stored mod 16), 4);
                     end if;

                     Result (Scales + Place + 8) :=
                       Result (Scales + Place + 8)
                       or Interfaces.Shift_Left
                            (Interfaces.Unsigned_8 (Stored / 16),
                             2 * (Which / 4));

                     for L in 0 .. 15 loop
                        declare
                           Level : constant Integer :=
                             Integer'Max
                               (-4,
                                Integer'Min
                                  (3,
                                   Integer
                                     (N.Real'Rounding
                                        (Values (Base + N.Element_Count (L))
                                         / Step))));

                           --  The mask bit's absence takes four away, so a
                           --  level of -4 .. -1 clears it and 0 .. 3 sets it.
                           Lifted : constant Boolean := Level >= 0;
                           Low    : constant Natural :=
                             (if Lifted then Level else Level + 4);
                        begin
                           Result (From + B.Byte_Count (L)) :=
                             Result (From + B.Byte_Count (L))
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_8 (Low), 2 * Group);

                           if Lifted then
                              Result (Mask_At + B.Byte_Count (L)) :=
                                Result (Mask_At + B.Byte_Count (L)) or Bit;
                           end if;
                        end;
                     end loop;
                  end;
               end loop;
            end;
         end;
      end loop;

      return Result;
   end Encode_Q3_K;

   function Encode_Q5_K (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 176 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 176;

            type Sub_Range is array (0 .. 7) of N.Real;
            Low, Step : Sub_Range := [others => 0.0];
            Widest, Deepest : N.Real := 0.0;
         begin
            for Sub in 0 .. 7 loop
               declare
                  Base     : constant N.Element_Count :=
                    First + N.Element_Count (Sub) * 32;
                  Smallest : N.Real := Values (Base);
                  Largest  : N.Real := Values (Base);
               begin
                  for Index in 0 .. 31 loop
                     Smallest := N.Real'Min
                       (Smallest, Values (Base + N.Element_Count (Index)));
                     Largest := N.Real'Max
                       (Largest, Values (Base + N.Element_Count (Index)));
                  end loop;

                  --  As in the other two: the stored minimum is subtracted
                  --  and cannot be negative.
                  Low (Sub) := N.Real'Min (Smallest, 0.0);
                  Step (Sub) := (Largest - Low (Sub)) / 31.0;
                  Widest := N.Real'Max (Widest, Step (Sub));
                  Deepest := N.Real'Max (Deepest, abs Low (Sub));
               end;
            end loop;

            declare
               D    : constant N.Real :=
                 (if Widest = 0.0 then 1.0 else Widest / 63.0);
               DMin : constant N.Real :=
                 (if Deepest = 0.0 then 1.0 else Deepest / 63.0);

               Scales : constant B.Byte_Count := At_Byte + 4;
               High   : constant B.Byte_Count := At_Byte + 16;
               Quants : constant B.Byte_Count := At_Byte + 48;
            begin
               Result (At_Byte .. At_Byte + 1) := Encode_F16 ([1 => D]);
               Result (At_Byte + 2 .. At_Byte + 3) := Encode_F16 ([1 => DMin]);

               for Sub in 0 .. 7 loop
                  declare
                     Factor : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8
                         (N.Real'Min (63.0,
                                      N.Real'Rounding (Step (Sub) / D)));
                     Minimum : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8
                         (N.Real'Min (63.0,
                                      N.Real'Rounding (-Low (Sub) / DMin)));
                  begin
                     --  The same twelve bytes Q4_K uses.
                     if Sub < 4 then
                        Result (Scales + B.Byte_Count (Sub)) :=
                          Result (Scales + B.Byte_Count (Sub)) or Factor;
                        Result (Scales + B.Byte_Count (Sub) + 4) :=
                          Result (Scales + B.Byte_Count (Sub) + 4) or Minimum;
                     else
                        Result (Scales + B.Byte_Count (Sub) + 4) :=
                          Result (Scales + B.Byte_Count (Sub) + 4)
                          or (Factor and 16#0F#)
                          or Interfaces.Shift_Left (Minimum and 16#0F#, 4);
                        Result (Scales + B.Byte_Count (Sub) - 4) :=
                          Result (Scales + B.Byte_Count (Sub) - 4)
                          or Interfaces.Shift_Left
                               (Interfaces.Shift_Right (Factor, 4), 6);
                        Result (Scales + B.Byte_Count (Sub)) :=
                          Result (Scales + B.Byte_Count (Sub))
                          or Interfaces.Shift_Left
                               (Interfaces.Shift_Right (Minimum, 4), 6);
                     end if;
                  end;
               end loop;

               --  Sub-blocks in pairs, as Q4_K, with the fifth bits of the
               --  pair in one byte of the thirty-two: bit 2g for the first
               --  and bit 2g + 1 for the second.
               for Group in 0 .. 3 loop
                  for L in 0 .. 31 loop
                     declare
                        function Level (Sub : Natural) return Natural is
                           Value : constant N.Real :=
                             Values (First + N.Element_Count (Sub) * 32
                                     + N.Element_Count (L));
                           Span  : constant N.Real :=
                             (if Step (Sub) = 0.0 then 1.0 else Step (Sub));
                        begin
                           return Natural
                             (N.Real'Max
                                (0.0,
                                 N.Real'Min
                                   (31.0,
                                    N.Real'Rounding
                                      ((Value - Low (Sub)) / Span))));
                        end Level;

                        First_Level  : constant Natural := Level (Group * 2);
                        Second_Level : constant Natural :=
                          Level (Group * 2 + 1);

                        At_Quant : constant B.Byte_Count :=
                          Quants + B.Byte_Count (Group) * 32
                          + B.Byte_Count (L);
                        At_High  : constant B.Byte_Count :=
                          High + B.Byte_Count (L);
                     begin
                        Result (At_Quant) :=
                          Interfaces.Unsigned_8 (First_Level mod 16)
                          or Interfaces.Shift_Left
                               (Interfaces.Unsigned_8 (Second_Level mod 16),
                                4);

                        if First_Level >= 16 then
                           Result (At_High) :=
                             Result (At_High)
                             or Interfaces.Shift_Left (1, 2 * Group);
                        end if;
                        if Second_Level >= 16 then
                           Result (At_High) :=
                             Result (At_High)
                             or Interfaces.Shift_Left (1, 2 * Group + 1);
                        end if;
                     end;
                  end loop;
               end loop;
            end;
         end;
      end loop;

      return Result;
   end Encode_Q5_K;

   function Encode_Q6_K (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 210 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 210;

            --  Sixteen groups of sixteen elements, each with a signed
            --  scale, and a superblock factor that turns the scale into a
            --  number. The elements of a group are not adjacent: the reader
            --  walks halves, then a pair of runs, then four offsets.
            type Group_Range is array (0 .. 15) of N.Real;
            Widest : Group_Range := [others => 0.0];
            Extent : N.Real := 0.0;

            --  Where a group's elements begin and which scale byte is its
            --  own, following the reader exactly.
            function Start_Of (Half, Sub, Run : Natural) return N.Element_Count
            is (N.Element_Count (Half * 128 + Sub * 16 + Run * 32));

            function Scale_Of (Half, Sub, Run : Natural) return B.Byte_Count
            is (B.Byte_Count (Half * 8 + Sub + Run * 2));
         begin
            --  The largest magnitude in each group, and the largest of those.
            for Half in 0 .. 1 loop
               for Sub in 0 .. 1 loop
                  for Run in 0 .. 3 loop
                     declare
                        Base : constant N.Element_Count :=
                          First + Start_Of (Half, Sub, Run);
                        Most : N.Real := 0.0;
                     begin
                        for L in 0 .. 15 loop
                           Most := N.Real'Max
                             (Most,
                              abs Values (Base + N.Element_Count (L)));
                        end loop;
                        Widest (Half * 8 + Sub + Run * 2) := Most;
                        Extent := N.Real'Max (Extent, Most);
                     end;
                  end loop;
               end loop;
            end loop;

            declare
               --  A level runs -32 .. 31, and a scale is a signed byte, so
               --  the factor covers the widest group at the widest scale.
               D : constant N.Real :=
                 (if Extent = 0.0 then 1.0 else Extent / (31.0 * 127.0));
            begin
               Result (At_Byte + 208 .. At_Byte + 209) :=
                 Encode_F16 ([1 => D]);

               for Half in 0 .. 1 loop
                  for Sub in 0 .. 1 loop
                     for Run in 0 .. 3 loop
                        declare
                           Which : constant Natural :=
                             Half * 8 + Sub + Run * 2;
                           Factor : constant Integer :=
                             Integer'Max
                               (1,
                                Integer'Min
                                  (127,
                                   Integer
                                     (N.Real'Ceiling
                                        (Widest (Which) / (31.0 * D)))));
                           Step : constant N.Real := D * N.Real (Factor);

                           Base : constant N.Element_Count :=
                             First + Start_Of (Half, Sub, Run);
                           Low_Run : constant B.Byte_Count :=
                             At_Byte + B.Byte_Count (Half) * 64
                             + B.Byte_Count (Sub) * 16
                             + B.Byte_Count (Run mod 2) * 32;
                           High_Run : constant B.Byte_Count :=
                             At_Byte + 128 + B.Byte_Count (Half) * 32
                             + B.Byte_Count (Sub) * 16;
                           Shift : constant Natural := (Run / 2) * 4;
                        begin
                           Result (At_Byte + 192
                                   + Scale_Of (Half, Sub, Run)) :=
                             Interfaces.Unsigned_8 (Factor);

                           for L in 0 .. 15 loop
                              declare
                                 Level : constant Integer :=
                                   Integer'Max
                                     (0,
                                      Integer'Min
                                        (63,
                                         Integer
                                           (N.Real'Rounding
                                              (Values
                                                 (Base + N.Element_Count (L))
                                               / Step))
                                         + 32));
                                 Low  : constant B.Byte_Count :=
                                   Low_Run + B.Byte_Count (L);
                                 High : constant B.Byte_Count :=
                                   High_Run + B.Byte_Count (L);
                              begin
                                 --  Runs 0 and 1 keep their low nibble in
                                 --  the low half of the byte, runs 2 and 3
                                 --  in the high half; the two high bits go
                                 --  into the pair the reader shifts to.
                                 Result (Low) :=
                                   Result (Low)
                                   or Interfaces.Shift_Left
                                        (Interfaces.Unsigned_8 (Level mod 16),
                                         Shift);
                                 Result (High) :=
                                   Result (High)
                                   or Interfaces.Shift_Left
                                        (Interfaces.Unsigned_8 (Level / 16),
                                         2 * Run);
                              end;
                           end loop;
                        end;
                     end loop;
                  end loop;
               end loop;
            end;
         end;
      end loop;

      return Result;
   end Encode_Q6_K;

   function Encode_Q2_K (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 84 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 84;

            --  Sixteen sub-blocks of sixteen, in the order the reader
            --  consumes them: half, group, upper.
            type Sub_Range is array (0 .. 15) of N.Real;
            Low, Step : Sub_Range := [others => 0.0];

            Widest, Deepest : N.Real := 0.0;

            --  Where a sub-block's elements begin, which is not its index
            --  times sixteen: the reader walks halves, then groups, then
            --  the upper half of each group.
            function Start_Of (Sub : Natural) return N.Element_Count is
               Half  : constant Natural := Sub / 8;
               Rest  : constant Natural := Sub mod 8;
               Group : constant Natural := Rest / 2;
               Upper : constant Natural := Rest mod 2;
            begin
               return N.Element_Count
                 (Half * 128 + Group * 32 + Upper * 16);
            end Start_Of;
         begin
            for Sub in 0 .. 15 loop
               declare
                  Base     : constant N.Element_Count :=
                    First + Start_Of (Sub);
                  Smallest : N.Real := Values (Base);
                  Largest  : N.Real := Values (Base);
               begin
                  for Index in 0 .. 15 loop
                     Smallest := N.Real'Min
                       (Smallest, Values (Base + N.Element_Count (Index)));
                     Largest := N.Real'Max
                       (Largest, Values (Base + N.Element_Count (Index)));
                  end loop;

                  --  The reader computes factor * level - minimum, and the
                  --  minimum it stores is a non-negative multiple. A
                  --  sub-block whose smallest value is above zero is
                  --  therefore anchored at zero rather than at its own
                  --  smallest, which costs a little of the range and is
                  --  what the format can say.
                  Low (Sub) := N.Real'Min (Smallest, 0.0);
                  Step (Sub) := (Largest - Low (Sub)) / 3.0;
                  Widest := N.Real'Max (Widest, Step (Sub));
                  Deepest := N.Real'Max (Deepest, abs Low (Sub));
               end;
            end loop;

            declare
               D    : constant N.Real :=
                 (if Widest = 0.0 then 1.0 else Widest / 15.0);
               DMin : constant N.Real :=
                 (if Deepest = 0.0 then 1.0 else Deepest / 15.0);
            begin
               Result (At_Byte + 80 .. At_Byte + 81) := Encode_F16 ([1 => D]);
               Result (At_Byte + 82 .. At_Byte + 83) :=
                 Encode_F16 ([1 => DMin]);

               for Sub in 0 .. 15 loop
                  declare
                     Factor : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8
                         (N.Real'Min (15.0,
                                      N.Real'Rounding (Step (Sub) / D)));
                     Minimum : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8
                         (N.Real'Min (15.0,
                                      N.Real'Rounding (-Low (Sub) / DMin)));
                  begin
                     Result (At_Byte + B.Byte_Count (Sub)) :=
                       Factor or Interfaces.Shift_Left (Minimum, 4);
                  end;
               end loop;

               --  Two bits an element. One byte carries the same element of
               --  four groups, which is why the shift is the group and the
               --  byte is the element within its sixteen.
               for Half in 0 .. 1 loop
                  for Group in 0 .. 3 loop
                     for Upper in 0 .. 1 loop
                        declare
                           Sub  : constant Natural :=
                             Half * 8 + Group * 2 + Upper;
                           From : constant B.Byte_Count :=
                             At_Byte + 16
                             + B.Byte_Count (Half * 32 + Upper * 16);
                           Base : constant N.Element_Count :=
                             First + Start_Of (Sub);
                           Span : constant N.Real :=
                             (if Step (Sub) = 0.0 then 1.0 else Step (Sub));
                        begin
                           for L in 0 .. 15 loop
                              declare
                                 Level : constant Interfaces.Unsigned_8 :=
                                   Interfaces.Unsigned_8
                                     (N.Real'Max
                                        (0.0,
                                         N.Real'Min
                                           (3.0,
                                            N.Real'Rounding
                                              ((Values
                                                  (Base
                                                   + N.Element_Count (L))
                                                - Low (Sub)) / Span))));
                              begin
                                 Result (From + B.Byte_Count (L)) :=
                                   Result (From + B.Byte_Count (L))
                                   or Interfaces.Shift_Left
                                        (Level, 2 * Group);
                              end;
                           end loop;
                        end;
                     end loop;
                  end loop;
               end loop;
            end;
         end;
      end loop;

      return Result;
   end Encode_Q2_K;

   function Encode_Q4_K (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 144 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 144;

            --  Per sub-block: the smallest value it holds, and the step
            --  between the sixteen levels four bits can name.
            type Sub_Range is array (0 .. 7) of N.Real;
            Low, Step : Sub_Range := [others => 0.0];

            Widest, Deepest : N.Real := 0.0;
         begin
            for Sub in 0 .. 7 loop
               declare
                  Base    : constant N.Element_Count :=
                    First + N.Element_Count (Sub) * 32;
                  Smallest : N.Real := Values (Base);
                  Largest  : N.Real := Values (Base);
               begin
                  for Index in 0 .. 31 loop
                     Smallest := N.Real'Min
                       (Smallest, Values (Base + N.Element_Count (Index)));
                     Largest := N.Real'Max
                       (Largest, Values (Base + N.Element_Count (Index)));
                  end loop;

                  --  As in the two-bit encoder: the stored minimum is
                  --  subtracted and cannot be negative, so a sub-block
                  --  entirely above zero is anchored there.
                  Low (Sub) := N.Real'Min (Smallest, 0.0);
                  Step (Sub) := (Largest - Low (Sub)) / 15.0;
                  Widest := N.Real'Max (Widest, Step (Sub));
                  Deepest := N.Real'Max (Deepest, abs Low (Sub));
               end;
            end loop;

            --  The superblock's own two scales, each dividing a six-bit
            --  factor: d scales the step, dmin the minimum, and the minimum
            --  is stored negated the way the decoder adds it back.
            declare
               D    : constant N.Real :=
                 (if Widest = 0.0 then 1.0 else Widest / 63.0);
               DMin : constant N.Real :=
                 (if Deepest = 0.0 then 1.0 else Deepest / 63.0);
            begin
               Result (At_Byte .. At_Byte + 1) := Encode_F16 ([1 => D]);
               Result (At_Byte + 2 .. At_Byte + 3) := Encode_F16 ([1 => DMin]);

               for Sub in 0 .. 7 loop
                  declare
                     Factor : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8
                         (N.Real'Min (63.0,
                                      N.Real'Rounding (Step (Sub) / D)));
                     Minimum : constant Interfaces.Unsigned_8 :=
                       Interfaces.Unsigned_8
                         (N.Real'Min (63.0,
                                      N.Real'Rounding (-Low (Sub) / DMin)));
                     Scales : constant B.Byte_Count := At_Byte + 4;
                  begin
                     --  The same twelve bytes the kernels' scale unpack
                     --  reads: the first four sub-blocks keep six bits in
                     --  place, and the last four are split across two
                     --  bytes.
                     if Sub < 4 then
                        Result (Scales + B.Byte_Count (Sub)) :=
                          Result (Scales + B.Byte_Count (Sub)) or Factor;
                        Result (Scales + B.Byte_Count (Sub) + 4) :=
                          Result (Scales + B.Byte_Count (Sub) + 4) or Minimum;
                     else
                        Result (Scales + B.Byte_Count (Sub) + 4) :=
                          Result (Scales + B.Byte_Count (Sub) + 4)
                          or (Factor and 16#0F#)
                          or Interfaces.Shift_Left (Minimum and 16#0F#, 4);
                        Result (Scales + B.Byte_Count (Sub) - 4) :=
                          Result (Scales + B.Byte_Count (Sub) - 4)
                          or Interfaces.Shift_Left
                               (Interfaces.Shift_Right (Factor, 4), 6);
                        Result (Scales + B.Byte_Count (Sub)) :=
                          Result (Scales + B.Byte_Count (Sub))
                          or Interfaces.Shift_Left
                               (Interfaces.Shift_Right (Minimum, 4), 6);
                     end if;
                  end;
               end loop;

               --  Four bits an element, two elements a byte, in the pairing
               --  the decoder reads: sub-blocks 2g and 2g+1 share a run of
               --  thirty-two bytes, low nibbles first.
               for Group in 0 .. 3 loop
                  for L in 0 .. 31 loop
                     declare
                        Base : constant B.Byte_Count :=
                          At_Byte + 16 + B.Byte_Count (Group) * 32
                          + B.Byte_Count (L);

                        function Level (Sub, Within : Natural)
                          return Interfaces.Unsigned_8
                        is
                           Value : constant N.Real :=
                             Values (First + N.Element_Count (Sub) * 32
                                     + N.Element_Count (Within));
                           Span  : constant N.Real :=
                             (if Step (Sub) = 0.0 then 1.0 else Step (Sub));
                        begin
                           return Interfaces.Unsigned_8
                             (N.Real'Max
                                (0.0,
                                 N.Real'Min
                                   (15.0,
                                    N.Real'Rounding
                                      ((Value - Low (Sub)) / Span))));
                        end Level;
                     begin
                        Result (Base) :=
                          Level (Group * 2, L)
                          or Interfaces.Shift_Left
                               (Level (Group * 2 + 1, L), 4);
                     end;
                  end loop;
               end loop;
            end;
         end;
      end loop;

      return Result;
   end Encode_Q4_K;

   --  The sixteen levels a non-linear four-bit quant takes. Written out here
   --  as well as in the decoder, because a fixture that asked the decoder
   --  what the levels were would agree with it by construction.
   Levels : constant array (0 .. 15) of Integer :=
     [-127, -104, -83, -65, -49, -35, -22, -10,
         1,   13,  25,  38,  53,  69,  89, 113];

   --  The level nearest a value, in units of the scale.
   function Nearest (Value : N.Real) return Interfaces.Unsigned_8 is
      Best : Integer := 0;
      Gap  : N.Real := abs (Value - N.Real (Levels (0)));
   begin
      for Index in 1 .. 15 loop
         declare
            Here : constant N.Real := abs (Value - N.Real (Levels (Index)));
         begin
            if Here < Gap then
               Gap := Here;
               Best := Index;
            end if;
         end;
      end loop;

      return Interfaces.Unsigned_8 (Best);
   end Nearest;

   --  The scale one block of thirty-two wants: the element furthest from
   --  zero lands on the level furthest out in its own direction.
   function Step_Of (Values : N.Real_Array) return N.Real is
      Extreme : N.Real := 0.0;
   begin
      for Value of Values loop
         if abs Value > abs Extreme then
            Extreme := Value;
         end if;
      end loop;

      if Extreme = 0.0 then
         return 0.0;
      elsif Extreme < 0.0 then
         return Extreme / N.Real (Levels (0));
      else
         return Extreme / N.Real (Levels (15));
      end if;
   end Step_Of;

   --  Pack one block of thirty-two into sixteen bytes of nibbles, at the
   --  given scale. Element j is the low nibble of byte j and element j + 16
   --  the high one, which is the layout Q4_0 uses for its own nibbles.
   procedure Pack_Levels
     (Values : N.Real_Array;
      Step   : N.Real;
      Into   : out B.Byte_Array)
   is
      use type Interfaces.Unsigned_8;
   begin
      Into := [others => 0];

      if Step = 0.0 then
         return;
      end if;

      for J in 0 .. 15 loop
         declare
            Lower : constant Interfaces.Unsigned_8 :=
              Nearest (Values (Values'First + N.Element_Count (J)) / Step);
            Upper : constant Interfaces.Unsigned_8 :=
              Nearest
                (Values (Values'First + N.Element_Count (J) + 16) / Step);
         begin
            Into (Into'First + B.Byte_Count (J)) :=
              Lower or Interfaces.Shift_Left (Upper, 4);
         end;
      end loop;
   end Pack_Levels;

   function Encode_IQ4_NL (Values : N.Real_Array) return B.Byte_Array is
      Blocks : constant N.Element_Count := Values'Length / 32;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 18 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 32;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 18;

            Span : constant N.Real_Array := Values (First .. First + 31);
            Step : constant N.Real := Step_Of (Span);
         begin
            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (Step)));
            Pack_Levels
              (Span, Step, Result (At_Byte + 2 .. At_Byte + 17));
         end;
      end loop;

      return Result;
   end Encode_IQ4_NL;

   --  MXFP4's own sixteen: the E2M1 values at twice their size, so that a
   --  level is a whole number and the scale carries the halving. Written out
   --  here as well as in the decoder, for the reason the levels above are.
   Fours : constant array (0 .. 15) of Integer :=
     [0, 1, 2, 3, 4, 6, 8, 12, 0, -1, -2, -3, -4, -6, -8, -12];

   --  The level nearest a value, in units of the scale. Two of the sixteen
   --  are zero and the comparison is strict, so a zero takes the first of
   --  them and the other is written by nothing here.
   function Nearest_Four (Value : N.Real) return Interfaces.Unsigned_8 is
      Best : Integer := 0;
      Gap  : N.Real := abs Value;
   begin
      for Index in 1 .. 15 loop
         declare
            Here : constant N.Real := abs (Value - N.Real (Fours (Index)));
         begin
            if Here < Gap then
               Gap := Here;
               Best := Index;
            end if;
         end;
      end loop;

      return Interfaces.Unsigned_8 (Best);
   end Nearest_Four;

   --  The exponent one block of thirty-two wants.
   --
   --  Unlike every other format here there is nothing to choose: the scale
   --  is two to a power, so the question is only which power, and the answer
   --  is the smallest whose top level -- twelve, the table's largest --
   --  reaches the block's largest magnitude. The engine reads the byte as
   --  two to itself less a hundred and twenty-eight, and so does this.
   function Exponent_Of (Values : N.Real_Array) return Interfaces.Unsigned_8 is
      Extreme : N.Real := 0.0;
      Wanted  : N.Real;
      Steps   : Integer;
   begin
      for Value of Values loop
         Extreme := N.Real'Max (Extreme, abs Value);
      end loop;

      if Extreme = 0.0 then
         return 0;
      end if;

      Wanted := Extreme / 12.0;

      --  The exponent attribute puts a value in [2**(E-1), 2**E), so E - 1
      --  is the largest power at or below it and E - 1 or E is the smallest
      --  at or above it, depending on whether it sat exactly on the lower.
      Steps := N.Real'Exponent (Wanted) - 1;
      if 2.0 ** Steps < Wanted then
         Steps := Steps + 1;
      end if;

      return Interfaces.Unsigned_8
        (Integer'Max (0, Integer'Min (255, Steps + 128)));
   end Exponent_Of;

   function Encode_MXFP4 (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 32;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 17 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 32;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 17;

            Span  : constant N.Real_Array := Values (First .. First + 31);
            Power : constant Interfaces.Unsigned_8 := Exponent_Of (Span);
            Step  : constant N.Real := 2.0 ** (Integer (Power) - 128);
         begin
            Result (At_Byte) := Power;

            --  Element j is the low nibble of byte j and element j + 16 the
            --  high one, which is the layout the legacy four-bit blocks use
            --  and the layout the decoder reads.
            for J in 0 .. 15 loop
               declare
                  Lower : constant Interfaces.Unsigned_8 :=
                    Nearest_Four
                      (Span (Span'First + N.Element_Count (J)) / Step);
                  Upper : constant Interfaces.Unsigned_8 :=
                    Nearest_Four
                      (Span (Span'First + N.Element_Count (J) + 16) / Step);
               begin
                  Result (At_Byte + 1 + B.Byte_Count (J)) :=
                    Lower or Interfaces.Shift_Left (Upper, 4);
               end;
            end loop;
         end;
      end loop;

      return Result;
   end Encode_MXFP4;

   function Encode_IQ4_XS (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_16;

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 136 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 136;

            --  What each sub-block would want on its own, and the largest of
            --  those, which is what the block's own scale has to reach.
            Wants   : array (0 .. 7) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;

            Outer : N.Real;
            High  : Interfaces.Unsigned_16 := 0;
         begin
            for Sub in 0 .. 7 loop
               declare
                  Where : constant N.Element_Count :=
                    First + N.Element_Count (Sub) * 32;
               begin
                  Wants (Sub) := Step_Of (Values (Where .. Where + 31));
                  Largest := N.Real'Max (Largest, abs Wants (Sub));
               end;
            end loop;

            --  A sub-block scale is a whole number of the block's scale,
            --  offset by thirty-two and held in six bits, so the block's
            --  scale has to be large enough that the largest sub-block fits
            --  in the thirty-one steps above the offset.
            Outer := (if Largest = 0.0 then 0.0 else Largest / 31.0);

            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (Outer)));

            for Sub in 0 .. 7 loop
               declare
                  Steps : constant Integer :=
                    (if Outer = 0.0
                     then 0
                     else Integer (N.Real'Rounding (Wants (Sub) / Outer)));
                  Level : constant Integer :=
                    Integer'Max (0, Integer'Min (63, Steps + 32));

                  Place : constant B.Byte_Count :=
                    At_Byte + 4 + B.Byte_Count (Sub / 2);

                  Where : constant N.Element_Count :=
                    First + N.Element_Count (Sub) * 32;

                  --  The scale that level actually names, which is what the
                  --  elements have to be quantized against rather than what
                  --  the sub-block asked for.
                  Step : constant N.Real := Outer * N.Real (Level - 32);
               begin
                  if Sub mod 2 = 0 then
                     Result (Place) := Result (Place)
                       or Interfaces.Unsigned_8 (Level mod 16);
                  else
                     Result (Place) := Result (Place)
                       or Interfaces.Shift_Left
                            (Interfaces.Unsigned_8 (Level mod 16), 4);
                  end if;

                  High := High
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_16 (Level / 16), 2 * Sub);

                  Pack_Levels
                    (Values (Where .. Where + 31), Step,
                     Result (At_Byte + 8 + B.Byte_Count (Sub) * 16
                             .. At_Byte + 23 + B.Byte_Count (Sub) * 16));
               end;
            end loop;

            Result (At_Byte + 2 .. At_Byte + 3) := B.Put_U16 (High);
         end;
      end loop;

      return Result;
   end Encode_IQ4_XS;

   function Encode_Q8_0 (Values : N.Real_Array) return B.Byte_Array is
      Blocks : constant N.Element_Count := Values'Length / 32;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 34 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 32;
            Largest : N.Real := 0.0;
            Scale   : N.Real;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 34;
         begin
            for Index in 0 .. 31 loop
               Largest :=
                 N.Real'Max (Largest, abs Values (First + N.Element_Count (Index)));
            end loop;

            Scale := (if Largest = 0.0 then 1.0 else Largest / 127.0);

            Result (At_Byte .. At_Byte + 1) := Encode_F16 ([1 => Scale]);

            for Index in 0 .. 31 loop
               declare
                  Quantized : constant Integer :=
                    Integer (N.Real'Rounding
                               (Values (First + N.Element_Count (Index))
                                / Scale));
                  Clamped : constant Integer :=
                    Integer'Max (-127, Integer'Min (127, Quantized));
               begin
                  Result (At_Byte + 2 + B.Byte_Count (Index)) :=
                    B.Byte (if Clamped < 0 then Clamped + 256 else Clamped);
               end;
            end loop;
         end;
      end loop;

      return Result;
   end Encode_Q8_0;

   --  IQ2_XXS's grid and the sign table the IQ2 formats share, from ggml.
   IQ2XXS_Grid : constant array (0 .. 255) of Interfaces.Unsigned_64 :=
     [
      16#0808080808080808#, 16#080808080808082B#, 16#0808080808081919#, 16#0808080808082B08#,
      16#0808080808082B2B#, 16#0808080808190819#, 16#0808080808191908#, 16#08080808082B0808#,
      16#08080808082B082B#, 16#08080808082B2B08#, 16#08080808082B2B2B#, 16#0808080819080819#,
      16#0808080819081908#, 16#0808080819190808#, 16#0808080819192B08#, 16#08080808192B0819#,
      16#08080808192B1908#, 16#080808082B080808#, 16#080808082B08082B#, 16#080808082B082B2B#,
      16#080808082B2B082B#, 16#0808081908080819#, 16#0808081908081908#, 16#0808081908190808#,
      16#0808081908191919#, 16#0808081919080808#, 16#080808192B081908#, 16#080808192B192B08#,
      16#0808082B08080808#, 16#0808082B0808082B#, 16#0808082B082B082B#, 16#0808082B2B08082B#,
      16#0808190808080819#, 16#0808190808081908#, 16#0808190808190808#, 16#08081908082B0819#,
      16#08081908082B1908#, 16#0808190819080808#, 16#080819081908082B#, 16#0808190819082B08#,
      16#08081908192B0808#, 16#080819082B080819#, 16#080819082B081908#, 16#080819082B190808#,
      16#080819082B2B1908#, 16#0808191908080808#, 16#080819190808082B#, 16#0808191908082B08#,
      16#08081919082B0808#, 16#080819191908192B#, 16#08081919192B2B19#, 16#080819192B080808#,
      16#080819192B190819#, 16#0808192B08082B19#, 16#0808192B08190808#, 16#0808192B19080808#,
      16#0808192B2B081908#, 16#0808192B2B2B1908#, 16#08082B0808080808#, 16#08082B0808081919#,
      16#08082B0808082B08#, 16#08082B0808191908#, 16#08082B08082B2B08#, 16#08082B0819080819#,
      16#08082B0819081908#, 16#08082B0819190808#, 16#08082B081919082B#, 16#08082B082B082B08#,
      16#08082B1908081908#, 16#08082B1919080808#, 16#08082B2B0808082B#, 16#08082B2B08191908#,
      16#0819080808080819#, 16#0819080808081908#, 16#0819080808190808#, 16#08190808082B0819#,
      16#0819080819080808#, 16#08190808192B0808#, 16#081908082B081908#, 16#081908082B190808#,
      16#081908082B191919#, 16#0819081908080808#, 16#0819081908082B08#, 16#08190819082B0808#,
      16#0819081919190808#, 16#0819081919192B2B#, 16#081908192B080808#, 16#0819082B082B1908#,
      16#0819082B19081919#, 16#0819190808080808#, 16#0819190808082B08#, 16#08191908082B0808#,
      16#08191908082B1919#, 16#0819190819082B19#, 16#081919082B080808#, 16#0819191908192B08#,
      16#08191919192B082B#, 16#0819192B08080808#, 16#0819192B0819192B#, 16#08192B0808080819#,
      16#08192B0808081908#, 16#08192B0808190808#, 16#08192B0819080808#, 16#08192B082B080819#,
      16#08192B1908080808#, 16#08192B1908081919#, 16#08192B192B2B0808#, 16#08192B2B19190819#,
      16#082B080808080808#, 16#082B08080808082B#, 16#082B080808082B2B#, 16#082B080819081908#,
      16#082B0808192B0819#, 16#082B08082B080808#, 16#082B08082B08082B#, 16#082B0819082B2B19#,
      16#082B081919082B08#, 16#082B082B08080808#, 16#082B082B0808082B#, 16#082B190808080819#,
      16#082B190808081908#, 16#082B190808190808#, 16#082B190819080808#, 16#082B19081919192B#,
      16#082B191908080808#, 16#082B191919080819#, 16#082B1919192B1908#, 16#082B192B2B190808#,
      16#082B2B0808082B08#, 16#082B2B08082B0808#, 16#082B2B082B191908#, 16#082B2B2B19081908#,
      16#1908080808080819#, 16#1908080808081908#, 16#1908080808190808#, 16#1908080808192B08#,
      16#19080808082B0819#, 16#19080808082B1908#, 16#1908080819080808#, 16#1908080819082B08#,
      16#190808081919192B#, 16#19080808192B0808#, 16#190808082B080819#, 16#190808082B081908#,
      16#190808082B190808#, 16#1908081908080808#, 16#19080819082B0808#, 16#19080819192B0819#,
      16#190808192B080808#, 16#190808192B081919#, 16#1908082B08080819#, 16#1908082B08190808#,
      16#1908082B19082B08#, 16#1908082B1919192B#, 16#1908082B192B2B08#, 16#1908190808080808#,
      16#1908190808082B08#, 16#19081908082B0808#, 16#190819082B080808#, 16#190819082B192B19#,
      16#190819190819082B#, 16#19081919082B1908#, 16#1908192B08080808#, 16#19082B0808080819#,
      16#19082B0808081908#, 16#19082B0808190808#, 16#19082B0819080808#, 16#19082B0819081919#,
      16#19082B1908080808#, 16#19082B1919192B08#, 16#19082B19192B0819#, 16#19082B192B08082B#,
      16#19082B2B19081919#, 16#19082B2B2B190808#, 16#1919080808080808#, 16#1919080808082B08#,
      16#1919080808190819#, 16#1919080808192B19#, 16#19190808082B0808#, 16#191908082B080808#,
      16#191908082B082B08#, 16#1919081908081908#, 16#191908191908082B#, 16#191908192B2B1908#,
      16#1919082B2B190819#, 16#191919082B190808#, 16#191919082B19082B#, 16#1919191908082B2B#,
      16#1919192B08080819#, 16#1919192B19191908#, 16#19192B0808080808#, 16#19192B0808190819#,
      16#19192B0808192B19#, 16#19192B08192B1908#, 16#19192B1919080808#, 16#19192B2B08082B08#,
      16#192B080808081908#, 16#192B080808190808#, 16#192B080819080808#, 16#192B0808192B2B08#,
      16#192B081908080808#, 16#192B081919191919#, 16#192B082B08192B08#, 16#192B082B192B0808#,
      16#192B190808080808#, 16#192B190808081919#, 16#192B191908190808#, 16#192B19190819082B#,
      16#192B19192B081908#, 16#192B2B081908082B#, 16#2B08080808080808#, 16#2B0808080808082B#,
      16#2B08080808082B2B#, 16#2B08080819080819#, 16#2B0808082B08082B#, 16#2B08081908081908#,
      16#2B08081908192B08#, 16#2B08081919080808#, 16#2B08082B08190819#, 16#2B08190808080819#,
      16#2B08190808081908#, 16#2B08190808190808#, 16#2B08190808191919#, 16#2B08190819080808#,
      16#2B081908192B0808#, 16#2B08191908080808#, 16#2B0819191908192B#, 16#2B0819192B191908#,
      16#2B08192B08082B19#, 16#2B08192B19080808#, 16#2B08192B192B0808#, 16#2B082B080808082B#,
      16#2B082B1908081908#, 16#2B082B2B08190819#, 16#2B19080808081908#, 16#2B19080808190808#,
      16#2B190808082B1908#, 16#2B19080819080808#, 16#2B1908082B2B0819#, 16#2B1908190819192B#,
      16#2B1908192B080808#, 16#2B19082B19081919#, 16#2B19190808080808#, 16#2B191908082B082B#,
      16#2B19190819081908#, 16#2B19191919190819#, 16#2B192B082B080819#, 16#2B192B19082B0808#,
      16#2B2B08080808082B#, 16#2B2B080819190808#, 16#2B2B08082B081919#, 16#2B2B081908082B19#,
      16#2B2B082B08080808#, 16#2B2B190808192B08#, 16#2B2B2B0819190808#, 16#2B2B2B1908081908#];

   KSigns_IQ2XS : constant array (0 .. 127) of Interfaces.Unsigned_8 :=
     [
      0, 129, 130, 3, 132, 5, 6, 135, 136, 9, 10, 139, 12, 141, 142, 15,
      144, 17, 18, 147, 20, 149, 150, 23, 24, 153, 154, 27, 156, 29, 30, 159,
      160, 33, 34, 163, 36, 165, 166, 39, 40, 169, 170, 43, 172, 45, 46, 175,
      48, 177, 178, 51, 180, 53, 54, 183, 184, 57, 58, 187, 60, 189, 190, 63,
      192, 65, 66, 195, 68, 197, 198, 71, 72, 201, 202, 75, 204, 77, 78, 207,
      80, 209, 210, 83, 212, 85, 86, 215, 216, 89, 90, 219, 92, 221, 222, 95,
      96, 225, 226, 99, 228, 101, 102, 231, 232, 105, 106, 235, 108, 237, 238, 111,
      240, 113, 114, 243, 116, 245, 246, 119, 120, 249, 250, 123, 252, 125, 126, 255];

   --  Transcribed verbatim from llama.cpp's iq2xs_grid (ggml-common.h).
   IQ2XS_Grid : constant array (0 .. 511) of Interfaces.Unsigned_64 :=
     [
      16#0808080808080808#, 16#080808080808082B#, 16#0808080808081919#, 16#0808080808082B08#,
      16#0808080808082B2B#, 16#0808080808190819#, 16#0808080808191908#, 16#080808080819192B#,
      16#0808080808192B19#, 16#08080808082B0808#, 16#08080808082B082B#, 16#08080808082B1919#,
      16#08080808082B2B08#, 16#0808080819080819#, 16#0808080819081908#, 16#080808081908192B#,
      16#0808080819082B19#, 16#0808080819190808#, 16#080808081919082B#, 16#0808080819191919#,
      16#0808080819192B08#, 16#08080808192B0819#, 16#08080808192B1908#, 16#080808082B080808#,
      16#080808082B08082B#, 16#080808082B081919#, 16#080808082B082B08#, 16#080808082B190819#,
      16#080808082B191908#, 16#080808082B192B19#, 16#080808082B2B0808#, 16#0808081908080819#,
      16#0808081908081908#, 16#080808190808192B#, 16#0808081908082B19#, 16#0808081908190808#,
      16#080808190819082B#, 16#0808081908191919#, 16#0808081908192B08#, 16#0808081908192B2B#,
      16#08080819082B0819#, 16#08080819082B1908#, 16#0808081919080808#, 16#080808191908082B#,
      16#0808081919081919#, 16#0808081919082B08#, 16#0808081919190819#, 16#0808081919191908#,
      16#08080819192B0808#, 16#08080819192B2B08#, 16#080808192B080819#, 16#080808192B081908#,
      16#080808192B190808#, 16#0808082B08080808#, 16#0808082B0808082B#, 16#0808082B08081919#,
      16#0808082B08082B08#, 16#0808082B08190819#, 16#0808082B08191908#, 16#0808082B082B0808#,
      16#0808082B19080819#, 16#0808082B19081908#, 16#0808082B19190808#, 16#0808082B19191919#,
      16#0808082B2B080808#, 16#0808082B2B082B2B#, 16#0808190808080819#, 16#0808190808081908#,
      16#080819080808192B#, 16#0808190808082B19#, 16#0808190808190808#, 16#080819080819082B#,
      16#0808190808191919#, 16#0808190808192B08#, 16#08081908082B0819#, 16#08081908082B1908#,
      16#0808190819080808#, 16#080819081908082B#, 16#0808190819081919#, 16#0808190819082B08#,
      16#0808190819190819#, 16#0808190819191908#, 16#080819081919192B#, 16#08081908192B0808#,
      16#080819082B080819#, 16#080819082B081908#, 16#080819082B190808#, 16#0808191908080808#,
      16#080819190808082B#, 16#0808191908081919#, 16#0808191908082B08#, 16#0808191908190819#,
      16#0808191908191908#, 16#08081919082B0808#, 16#0808191919080819#, 16#0808191919081908#,
      16#0808191919190808#, 16#08081919192B0819#, 16#080819192B080808#, 16#0808192B08080819#,
      16#0808192B08081908#, 16#0808192B08190808#, 16#0808192B082B192B#, 16#0808192B19080808#,
      16#0808192B1908082B#, 16#0808192B2B081908#, 16#08082B0808080808#, 16#08082B080808082B#,
      16#08082B0808081919#, 16#08082B0808082B08#, 16#08082B0808082B2B#, 16#08082B0808190819#,
      16#08082B0808191908#, 16#08082B08082B0808#, 16#08082B08082B1919#, 16#08082B0819080819#,
      16#08082B0819081908#, 16#08082B0819190808#, 16#08082B0819192B08#, 16#08082B082B080808#,
      16#08082B082B2B0808#, 16#08082B082B2B2B2B#, 16#08082B1908080819#, 16#08082B1908081908#,
      16#08082B1908190808#, 16#08082B1919080808#, 16#08082B192B080819#, 16#08082B192B082B19#,
      16#08082B2B08080808#, 16#08082B2B082B0808#, 16#08082B2B082B2B08#, 16#08082B2B2B19192B#,
      16#08082B2B2B2B0808#, 16#0819080808080819#, 16#0819080808081908#, 16#081908080808192B#,
      16#0819080808082B19#, 16#0819080808190808#, 16#081908080819082B#, 16#0819080808191919#,
      16#0819080808192B08#, 16#08190808082B0819#, 16#08190808082B1908#, 16#0819080819080808#,
      16#081908081908082B#, 16#0819080819081919#, 16#0819080819082B08#, 16#0819080819190819#,
      16#0819080819191908#, 16#08190808192B0808#, 16#08190808192B2B2B#, 16#081908082B080819#,
      16#081908082B081908#, 16#081908082B190808#, 16#0819081908080808#, 16#081908190808082B#,
      16#0819081908081919#, 16#0819081908082B08#, 16#0819081908190819#, 16#0819081908191908#,
      16#08190819082B0808#, 16#0819081919080819#, 16#0819081919081908#, 16#0819081919190808#,
      16#081908192B080808#, 16#081908192B191908#, 16#081908192B19192B#, 16#0819082B08080819#,
      16#0819082B08081908#, 16#0819082B0808192B#, 16#0819082B08190808#, 16#0819082B19080808#,
      16#0819082B192B0808#, 16#0819190808080808#, 16#081919080808082B#, 16#0819190808081919#,
      16#0819190808082B08#, 16#0819190808190819#, 16#0819190808191908#, 16#08191908082B0808#,
      16#0819190819080819#, 16#0819190819081908#, 16#0819190819082B19#, 16#0819190819190808#,
      16#08191908192B1908#, 16#081919082B080808#, 16#0819191908080819#, 16#0819191908081908#,
      16#0819191908190808#, 16#0819191919080808#, 16#0819192B08080808#, 16#0819192B08191908#,
      16#0819192B19082B19#, 16#08192B0808080819#, 16#08192B0808081908#, 16#08192B0808190808#,
      16#08192B080819082B#, 16#08192B0819080808#, 16#08192B0819191908#, 16#08192B082B08192B#,
      16#08192B1908080808#, 16#08192B1908081919#, 16#08192B19192B192B#, 16#08192B2B19190819#,
      16#08192B2B2B2B2B19#, 16#082B080808080808#, 16#082B08080808082B#, 16#082B080808081919#,
      16#082B080808082B08#, 16#082B080808082B2B#, 16#082B080808190819#, 16#082B080808191908#,
      16#082B0808082B0808#, 16#082B080819080819#, 16#082B080819081908#, 16#082B080819190808#,
      16#082B08082B080808#, 16#082B08082B2B0808#, 16#082B081908080819#, 16#082B081908081908#,
      16#082B081908190808#, 16#082B081919080808#, 16#082B081919082B08#, 16#082B0819192B1919#,
      16#082B082B08080808#, 16#082B082B082B082B#, 16#082B082B2B080808#, 16#082B082B2B2B2B08#,
      16#082B190808080819#, 16#082B190808081908#, 16#082B190808190808#, 16#082B1908082B2B19#,
      16#082B190819080808#, 16#082B191908080808#, 16#082B191919080819#, 16#082B19191919082B#,
      16#082B19192B192B19#, 16#082B192B08080819#, 16#082B192B08192B2B#, 16#082B192B2B2B192B#,
      16#082B2B0808080808#, 16#082B2B0808082B08#, 16#082B2B0808082B2B#, 16#082B2B08082B0808#,
      16#082B2B0819191919#, 16#082B2B082B082B08#, 16#082B2B082B2B082B#, 16#082B2B19192B2B08#,
      16#082B2B192B190808#, 16#082B2B2B08082B08#, 16#082B2B2B082B0808#, 16#082B2B2B2B08082B#,
      16#082B2B2B2B082B08#, 16#082B2B2B2B082B2B#, 16#1908080808080819#, 16#1908080808081908#,
      16#190808080808192B#, 16#1908080808082B19#, 16#1908080808190808#, 16#190808080819082B#,
      16#1908080808191919#, 16#1908080808192B08#, 16#19080808082B0819#, 16#19080808082B1908#,
      16#1908080819080808#, 16#190808081908082B#, 16#1908080819081919#, 16#1908080819082B08#,
      16#1908080819082B2B#, 16#1908080819190819#, 16#1908080819191908#, 16#19080808192B0808#,
      16#19080808192B1919#, 16#190808082B080819#, 16#190808082B081908#, 16#190808082B190808#,
      16#1908081908080808#, 16#190808190808082B#, 16#1908081908081919#, 16#1908081908082B08#,
      16#1908081908190819#, 16#1908081908191908#, 16#19080819082B0808#, 16#1908081919080819#,
      16#1908081919081908#, 16#1908081919190808#, 16#190808192B080808#, 16#190808192B081919#,
      16#190808192B2B082B#, 16#1908082B08080819#, 16#1908082B08081908#, 16#1908082B08190808#,
      16#1908082B0819082B#, 16#1908082B082B2B19#, 16#1908082B19080808#, 16#1908190808080808#,
      16#190819080808082B#, 16#1908190808081919#, 16#1908190808082B08#, 16#1908190808190819#,
      16#1908190808191908#, 16#1908190808192B19#, 16#19081908082B0808#, 16#1908190819080819#,
      16#1908190819081908#, 16#1908190819190808#, 16#190819082B080808#, 16#190819082B191908#,
      16#1908191908080819#, 16#1908191908081908#, 16#1908191908190808#, 16#19081919082B1908#,
      16#1908191919080808#, 16#190819192B192B2B#, 16#1908192B08080808#, 16#1908192B08082B2B#,
      16#1908192B19081908#, 16#1908192B19190808#, 16#19082B0808080819#, 16#19082B0808081908#,
      16#19082B0808190808#, 16#19082B0819080808#, 16#19082B0819081919#, 16#19082B0819191908#,
      16#19082B08192B082B#, 16#19082B1908080808#, 16#19082B1908190819#, 16#19082B1919081908#,
      16#19082B1919190808#, 16#19082B19192B2B19#, 16#19082B2B08081908#, 16#1919080808080808#,
      16#191908080808082B#, 16#1919080808081919#, 16#1919080808082B08#, 16#1919080808190819#,
      16#1919080808191908#, 16#19190808082B0808#, 16#19190808082B2B08#, 16#1919080819080819#,
      16#1919080819081908#, 16#1919080819190808#, 16#191908082B080808#, 16#1919081908080819#,
      16#1919081908081908#, 16#1919081908190808#, 16#1919081908191919#, 16#1919081919080808#,
      16#191908191908082B#, 16#1919082B08080808#, 16#1919082B19081908#, 16#1919082B2B2B2B2B#,
      16#1919190808080819#, 16#1919190808081908#, 16#1919190808190808#, 16#19191908082B0819#,
      16#1919190819080808#, 16#19191908192B0808#, 16#191919082B080819#, 16#191919082B2B0819#,
      16#1919191908080808#, 16#1919191908082B08#, 16#191919192B080808#, 16#191919192B082B08#,
      16#1919192B082B0819#, 16#1919192B192B2B08#, 16#1919192B2B2B0819#, 16#19192B0808080808#,
      16#19192B0808191908#, 16#19192B0819080819#, 16#19192B0819190808#, 16#19192B082B192B19#,
      16#19192B1908192B2B#, 16#19192B1919080808#, 16#19192B191908082B#, 16#19192B2B2B081919#,
      16#192B080808080819#, 16#192B080808081908#, 16#192B080808190808#, 16#192B080819080808#,
      16#192B080819191908#, 16#192B0808192B082B#, 16#192B08082B08192B#, 16#192B08082B2B2B19#,
      16#192B081908080808#, 16#192B082B082B1908#, 16#192B082B19082B2B#, 16#192B082B2B19082B#,
      16#192B190808080808#, 16#192B19080819192B#, 16#192B191908190808#, 16#192B191919080808#,
      16#192B191919081919#, 16#192B19192B2B1908#, 16#192B2B0808080819#, 16#192B2B08192B2B2B#,
      16#192B2B19082B1919#, 16#192B2B2B0808192B#, 16#192B2B2B19191908#, 16#192B2B2B192B082B#,
      16#2B08080808080808#, 16#2B0808080808082B#, 16#2B08080808081919#, 16#2B08080808082B08#,
      16#2B08080808190819#, 16#2B08080808191908#, 16#2B080808082B0808#, 16#2B080808082B2B2B#,
      16#2B08080819080819#, 16#2B08080819081908#, 16#2B08080819190808#, 16#2B0808082B080808#,
      16#2B0808082B08082B#, 16#2B0808082B2B2B08#, 16#2B0808082B2B2B2B#, 16#2B08081908080819#,
      16#2B08081908081908#, 16#2B0808190808192B#, 16#2B08081908190808#, 16#2B08081919080808#,
      16#2B08081919190819#, 16#2B08081919192B19#, 16#2B08082B08080808#, 16#2B08082B082B0808#,
      16#2B08082B2B080808#, 16#2B08082B2B08082B#, 16#2B08082B2B2B0808#, 16#2B08082B2B2B2B08#,
      16#2B08190808080819#, 16#2B08190808081908#, 16#2B08190808190808#, 16#2B0819080819082B#,
      16#2B08190808191919#, 16#2B08190819080808#, 16#2B081908192B0808#, 16#2B0819082B082B19#,
      16#2B08191908080808#, 16#2B08191919081908#, 16#2B0819192B2B1919#, 16#2B08192B08192B08#,
      16#2B08192B192B2B2B#, 16#2B082B0808080808#, 16#2B082B0808082B08#, 16#2B082B08082B1919#,
      16#2B082B0819192B2B#, 16#2B082B082B080808#, 16#2B082B082B08082B#, 16#2B082B082B2B2B08#,
      16#2B082B190808192B#, 16#2B082B2B082B082B#, 16#2B082B2B2B080808#, 16#2B082B2B2B082B08#,
      16#2B082B2B2B19192B#, 16#2B082B2B2B2B2B08#, 16#2B19080808080819#, 16#2B19080808081908#,
      16#2B19080808190808#, 16#2B19080819080808#, 16#2B1908081919192B#, 16#2B1908082B081908#,
      16#2B19081908080808#, 16#2B190819082B082B#, 16#2B190819192B1908#, 16#2B19082B1919192B#,
      16#2B19082B2B082B19#, 16#2B19190808080808#, 16#2B19190808081919#, 16#2B19190819081908#,
      16#2B19190819190808#, 16#2B19190819192B08#, 16#2B191919082B2B19#, 16#2B1919192B190808#,
      16#2B1919192B19082B#, 16#2B19192B19080819#, 16#2B192B0819190819#, 16#2B192B082B2B192B#,
      16#2B192B1919082B19#, 16#2B192B2B08191919#, 16#2B192B2B192B0808#, 16#2B2B080808080808#,
      16#2B2B08080808082B#, 16#2B2B080808082B08#, 16#2B2B080808082B2B#, 16#2B2B0808082B0808#,
      16#2B2B0808082B2B2B#, 16#2B2B08082B2B0808#, 16#2B2B081919190819#, 16#2B2B081919192B19#,
      16#2B2B08192B2B192B#, 16#2B2B082B08080808#, 16#2B2B082B0808082B#, 16#2B2B082B08082B08#,
      16#2B2B082B082B2B2B#, 16#2B2B082B2B080808#, 16#2B2B082B2B2B0808#, 16#2B2B190819080808#,
      16#2B2B19082B191919#, 16#2B2B192B192B1919#, 16#2B2B192B2B192B08#, 16#2B2B2B0808082B2B#,
      16#2B2B2B08082B0808#, 16#2B2B2B08082B082B#, 16#2B2B2B08082B2B08#, 16#2B2B2B082B2B0808#,
      16#2B2B2B082B2B2B08#, 16#2B2B2B1908081908#, 16#2B2B2B192B081908#, 16#2B2B2B192B08192B#,
      16#2B2B2B2B082B2B08#, 16#2B2B2B2B082B2B2B#, 16#2B2B2B2B2B190819#, 16#2B2B2B2B2B2B2B2B#
     ];

   --  Transcribed verbatim from llama.cpp's iq2s_grid (ggml-common.h).
   IQ2S_Grid : constant array (0 .. 1023) of Interfaces.Unsigned_64 :=
     [
      16#0808080808080808#, 16#080808080808082B#, 16#0808080808081919#, 16#0808080808082B08#,
      16#0808080808082B2B#, 16#0808080808190819#, 16#0808080808191908#, 16#080808080819192B#,
      16#0808080808192B19#, 16#08080808082B0808#, 16#08080808082B082B#, 16#08080808082B1919#,
      16#08080808082B2B08#, 16#0808080819080819#, 16#0808080819081908#, 16#080808081908192B#,
      16#0808080819082B19#, 16#0808080819190808#, 16#080808081919082B#, 16#0808080819191919#,
      16#0808080819192B08#, 16#08080808192B0819#, 16#08080808192B1908#, 16#08080808192B192B#,
      16#08080808192B2B19#, 16#080808082B080808#, 16#080808082B08082B#, 16#080808082B081919#,
      16#080808082B082B08#, 16#080808082B190819#, 16#080808082B191908#, 16#080808082B2B0808#,
      16#080808082B2B1919#, 16#080808082B2B2B2B#, 16#0808081908080819#, 16#0808081908081908#,
      16#080808190808192B#, 16#0808081908082B19#, 16#0808081908190808#, 16#080808190819082B#,
      16#0808081908191919#, 16#0808081908192B08#, 16#08080819082B0819#, 16#08080819082B1908#,
      16#0808081919080808#, 16#080808191908082B#, 16#0808081919081919#, 16#0808081919082B08#,
      16#0808081919190819#, 16#0808081919191908#, 16#080808191919192B#, 16#0808081919192B19#,
      16#08080819192B0808#, 16#08080819192B1919#, 16#08080819192B2B08#, 16#080808192B080819#,
      16#080808192B081908#, 16#080808192B190808#, 16#080808192B19082B#, 16#080808192B191919#,
      16#080808192B2B0819#, 16#080808192B2B1908#, 16#0808082B08080808#, 16#0808082B0808082B#,
      16#0808082B08081919#, 16#0808082B08082B08#, 16#0808082B08190819#, 16#0808082B08191908#,
      16#0808082B082B0808#, 16#0808082B082B2B2B#, 16#0808082B19080819#, 16#0808082B19081908#,
      16#0808082B1908192B#, 16#0808082B19082B19#, 16#0808082B19190808#, 16#0808082B19191919#,
      16#0808082B2B080808#, 16#0808082B2B081919#, 16#0808082B2B082B2B#, 16#0808082B2B191908#,
      16#0808082B2B2B082B#, 16#0808190808080819#, 16#0808190808081908#, 16#080819080808192B#,
      16#0808190808082B19#, 16#0808190808190808#, 16#080819080819082B#, 16#0808190808191919#,
      16#0808190808192B08#, 16#08081908082B0819#, 16#08081908082B1908#, 16#08081908082B192B#,
      16#08081908082B2B19#, 16#0808190819080808#, 16#080819081908082B#, 16#0808190819081919#,
      16#0808190819082B08#, 16#0808190819082B2B#, 16#0808190819190819#, 16#0808190819191908#,
      16#080819081919192B#, 16#0808190819192B19#, 16#08081908192B0808#, 16#08081908192B082B#,
      16#08081908192B1919#, 16#080819082B080819#, 16#080819082B081908#, 16#080819082B08192B#,
      16#080819082B082B19#, 16#080819082B190808#, 16#080819082B191919#, 16#080819082B192B08#,
      16#080819082B2B0819#, 16#080819082B2B1908#, 16#0808191908080808#, 16#080819190808082B#,
      16#0808191908081919#, 16#0808191908082B08#, 16#0808191908082B2B#, 16#0808191908190819#,
      16#0808191908191908#, 16#080819190819192B#, 16#0808191908192B19#, 16#08081919082B0808#,
      16#08081919082B1919#, 16#08081919082B2B08#, 16#0808191919080819#, 16#0808191919081908#,
      16#080819191908192B#, 16#0808191919082B19#, 16#0808191919190808#, 16#080819191919082B#,
      16#0808191919191919#, 16#0808191919192B08#, 16#08081919192B0819#, 16#08081919192B1908#,
      16#080819192B080808#, 16#080819192B08082B#, 16#080819192B081919#, 16#080819192B082B08#,
      16#080819192B190819#, 16#080819192B191908#, 16#080819192B2B0808#, 16#0808192B08080819#,
      16#0808192B08081908#, 16#0808192B0808192B#, 16#0808192B08082B19#, 16#0808192B08190808#,
      16#0808192B08191919#, 16#0808192B19080808#, 16#0808192B19081919#, 16#0808192B19082B08#,
      16#0808192B19190819#, 16#0808192B19191908#, 16#0808192B192B0808#, 16#0808192B2B080819#,
      16#0808192B2B081908#, 16#0808192B2B190808#, 16#08082B0808080808#, 16#08082B080808082B#,
      16#08082B0808081919#, 16#08082B0808082B08#, 16#08082B0808190819#, 16#08082B0808191908#,
      16#08082B080819192B#, 16#08082B0808192B19#, 16#08082B08082B0808#, 16#08082B08082B1919#,
      16#08082B08082B2B2B#, 16#08082B0819080819#, 16#08082B0819081908#, 16#08082B081908192B#,
      16#08082B0819082B19#, 16#08082B0819190808#, 16#08082B081919082B#, 16#08082B0819191919#,
      16#08082B0819192B08#, 16#08082B08192B0819#, 16#08082B08192B1908#, 16#08082B082B080808#,
      16#08082B082B081919#, 16#08082B082B191908#, 16#08082B082B2B2B2B#, 16#08082B1908080819#,
      16#08082B1908081908#, 16#08082B1908190808#, 16#08082B190819082B#, 16#08082B1908191919#,
      16#08082B1908192B08#, 16#08082B19082B0819#, 16#08082B1919080808#, 16#08082B1919081919#,
      16#08082B1919082B08#, 16#08082B1919190819#, 16#08082B1919191908#, 16#08082B19192B0808#,
      16#08082B192B080819#, 16#08082B192B190808#, 16#08082B2B08080808#, 16#08082B2B08190819#,
      16#08082B2B08191908#, 16#08082B2B082B082B#, 16#08082B2B082B2B08#, 16#08082B2B082B2B2B#,
      16#08082B2B19190808#, 16#08082B2B2B192B19#, 16#0819080808080819#, 16#0819080808081908#,
      16#081908080808192B#, 16#0819080808082B19#, 16#0819080808190808#, 16#081908080819082B#,
      16#0819080808191919#, 16#0819080808192B08#, 16#08190808082B0819#, 16#08190808082B1908#,
      16#08190808082B192B#, 16#0819080819080808#, 16#081908081908082B#, 16#0819080819081919#,
      16#0819080819082B08#, 16#0819080819190819#, 16#0819080819191908#, 16#081908081919192B#,
      16#0819080819192B19#, 16#08190808192B0808#, 16#08190808192B082B#, 16#08190808192B1919#,
      16#08190808192B2B08#, 16#081908082B080819#, 16#081908082B081908#, 16#081908082B08192B#,
      16#081908082B190808#, 16#081908082B191919#, 16#081908082B192B08#, 16#081908082B2B0819#,
      16#081908082B2B1908#, 16#0819081908080808#, 16#081908190808082B#, 16#0819081908081919#,
      16#0819081908082B08#, 16#0819081908082B2B#, 16#0819081908190819#, 16#0819081908191908#,
      16#081908190819192B#, 16#0819081908192B19#, 16#08190819082B0808#, 16#08190819082B082B#,
      16#08190819082B1919#, 16#08190819082B2B08#, 16#0819081919080819#, 16#0819081919081908#,
      16#081908191908192B#, 16#0819081919082B19#, 16#0819081919190808#, 16#081908191919082B#,
      16#0819081919191919#, 16#0819081919192B08#, 16#08190819192B0819#, 16#08190819192B1908#,
      16#081908192B080808#, 16#081908192B08082B#, 16#081908192B081919#, 16#081908192B082B08#,
      16#081908192B190819#, 16#081908192B191908#, 16#0819082B08080819#, 16#0819082B08081908#,
      16#0819082B08082B19#, 16#0819082B08190808#, 16#0819082B08191919#, 16#0819082B082B0819#,
      16#0819082B082B1908#, 16#0819082B19080808#, 16#0819082B19081919#, 16#0819082B19190819#,
      16#0819082B19191908#, 16#0819082B2B080819#, 16#0819082B2B081908#, 16#0819082B2B190808#,
      16#0819190808080808#, 16#081919080808082B#, 16#0819190808081919#, 16#0819190808082B08#,
      16#0819190808190819#, 16#0819190808191908#, 16#081919080819192B#, 16#0819190808192B19#,
      16#08191908082B0808#, 16#08191908082B1919#, 16#08191908082B2B08#, 16#0819190819080819#,
      16#0819190819081908#, 16#081919081908192B#, 16#0819190819082B19#, 16#0819190819190808#,
      16#081919081919082B#, 16#0819190819191919#, 16#0819190819192B08#, 16#08191908192B0819#,
      16#08191908192B1908#, 16#081919082B080808#, 16#081919082B08082B#, 16#081919082B081919#,
      16#081919082B082B08#, 16#081919082B190819#, 16#081919082B191908#, 16#081919082B2B0808#,
      16#0819191908080819#, 16#0819191908081908#, 16#081919190808192B#, 16#0819191908082B19#,
      16#0819191908190808#, 16#081919190819082B#, 16#0819191908191919#, 16#0819191908192B08#,
      16#08191919082B0819#, 16#08191919082B1908#, 16#0819191919080808#, 16#081919191908082B#,
      16#0819191919081919#, 16#0819191919082B08#, 16#0819191919190819#, 16#0819191919191908#,
      16#08191919192B0808#, 16#081919192B080819#, 16#081919192B081908#, 16#081919192B190808#,
      16#0819192B08080808#, 16#0819192B08081919#, 16#0819192B08082B08#, 16#0819192B08190819#,
      16#0819192B08191908#, 16#0819192B082B0808#, 16#0819192B19080819#, 16#0819192B19081908#,
      16#0819192B19190808#, 16#0819192B2B080808#, 16#0819192B2B2B2B2B#, 16#08192B0808080819#,
      16#08192B0808081908#, 16#08192B080808192B#, 16#08192B0808082B19#, 16#08192B0808190808#,
      16#08192B0808191919#, 16#08192B0808192B08#, 16#08192B08082B0819#, 16#08192B0819080808#,
      16#08192B081908082B#, 16#08192B0819081919#, 16#08192B0819082B08#, 16#08192B0819190819#,
      16#08192B0819191908#, 16#08192B08192B0808#, 16#08192B082B080819#, 16#08192B082B081908#,
      16#08192B1908080808#, 16#08192B190808082B#, 16#08192B1908081919#, 16#08192B1908082B08#,
      16#08192B1908190819#, 16#08192B1908191908#, 16#08192B19082B0808#, 16#08192B1919080819#,
      16#08192B1919081908#, 16#08192B1919190808#, 16#08192B19192B2B19#, 16#08192B192B2B082B#,
      16#08192B2B08081908#, 16#08192B2B08190808#, 16#08192B2B19080808#, 16#08192B2B1919192B#,
      16#082B080808080808#, 16#082B08080808082B#, 16#082B080808081919#, 16#082B080808082B08#,
      16#082B080808190819#, 16#082B080808191908#, 16#082B08080819192B#, 16#082B080808192B19#,
      16#082B0808082B0808#, 16#082B0808082B1919#, 16#082B0808082B2B2B#, 16#082B080819080819#,
      16#082B080819081908#, 16#082B080819190808#, 16#082B08081919082B#, 16#082B080819191919#,
      16#082B0808192B1908#, 16#082B08082B080808#, 16#082B08082B082B2B#, 16#082B08082B191908#,
      16#082B08082B2B2B2B#, 16#082B081908080819#, 16#082B081908081908#, 16#082B081908190808#,
      16#082B08190819082B#, 16#082B081908191919#, 16#082B0819082B0819#, 16#082B081919080808#,
      16#082B08191908082B#, 16#082B081919081919#, 16#082B081919190819#, 16#082B081919191908#,
      16#082B0819192B0808#, 16#082B08192B080819#, 16#082B08192B081908#, 16#082B08192B190808#,
      16#082B082B08080808#, 16#082B082B08082B2B#, 16#082B082B082B082B#, 16#082B082B082B2B08#,
      16#082B082B082B2B2B#, 16#082B082B19081908#, 16#082B082B19190808#, 16#082B082B2B082B08#,
      16#082B082B2B082B2B#, 16#082B082B2B2B2B08#, 16#082B190808080819#, 16#082B190808081908#,
      16#082B19080808192B#, 16#082B190808082B19#, 16#082B190808190808#, 16#082B190808191919#,
      16#082B190808192B08#, 16#082B1908082B0819#, 16#082B1908082B1908#, 16#082B190819080808#,
      16#082B19081908082B#, 16#082B190819081919#, 16#082B190819082B08#, 16#082B190819190819#,
      16#082B190819191908#, 16#082B1908192B0808#, 16#082B19082B080819#, 16#082B19082B081908#,
      16#082B19082B190808#, 16#082B191908080808#, 16#082B191908081919#, 16#082B191908082B08#,
      16#082B191908190819#, 16#082B191908191908#, 16#082B1919082B0808#, 16#082B191919080819#,
      16#082B191919081908#, 16#082B191919190808#, 16#082B1919192B192B#, 16#082B19192B080808#,
      16#082B192B08080819#, 16#082B192B08081908#, 16#082B192B08190808#, 16#082B192B19080808#,
      16#082B192B19192B19#, 16#082B2B0808080808#, 16#082B2B0808081919#, 16#082B2B0808190819#,
      16#082B2B0808191908#, 16#082B2B0819080819#, 16#082B2B0819081908#, 16#082B2B0819190808#,
      16#082B2B082B082B2B#, 16#082B2B082B2B2B2B#, 16#082B2B1908080819#, 16#082B2B1908081908#,
      16#082B2B1908190808#, 16#082B2B192B191919#, 16#082B2B2B08082B2B#, 16#082B2B2B082B082B#,
      16#082B2B2B192B1908#, 16#082B2B2B2B082B08#, 16#082B2B2B2B082B2B#, 16#1908080808080819#,
      16#1908080808081908#, 16#190808080808192B#, 16#1908080808082B19#, 16#1908080808190808#,
      16#190808080819082B#, 16#1908080808191919#, 16#1908080808192B08#, 16#1908080808192B2B#,
      16#19080808082B0819#, 16#19080808082B1908#, 16#19080808082B192B#, 16#1908080819080808#,
      16#190808081908082B#, 16#1908080819081919#, 16#1908080819082B08#, 16#1908080819082B2B#,
      16#1908080819190819#, 16#1908080819191908#, 16#190808081919192B#, 16#1908080819192B19#,
      16#19080808192B0808#, 16#19080808192B082B#, 16#19080808192B1919#, 16#190808082B080819#,
      16#190808082B081908#, 16#190808082B190808#, 16#190808082B191919#, 16#190808082B192B08#,
      16#190808082B2B0819#, 16#190808082B2B1908#, 16#1908081908080808#, 16#190808190808082B#,
      16#1908081908081919#, 16#1908081908082B08#, 16#1908081908190819#, 16#1908081908191908#,
      16#190808190819192B#, 16#1908081908192B19#, 16#19080819082B0808#, 16#19080819082B082B#,
      16#19080819082B1919#, 16#1908081919080819#, 16#1908081919081908#, 16#190808191908192B#,
      16#1908081919082B19#, 16#1908081919190808#, 16#190808191919082B#, 16#1908081919191919#,
      16#1908081919192B08#, 16#19080819192B0819#, 16#19080819192B1908#, 16#190808192B080808#,
      16#190808192B08082B#, 16#190808192B081919#, 16#190808192B082B08#, 16#190808192B190819#,
      16#190808192B191908#, 16#190808192B2B0808#, 16#1908082B08080819#, 16#1908082B08081908#,
      16#1908082B08190808#, 16#1908082B0819082B#, 16#1908082B08191919#, 16#1908082B08192B08#,
      16#1908082B082B1908#, 16#1908082B19080808#, 16#1908082B19081919#, 16#1908082B19082B08#,
      16#1908082B19190819#, 16#1908082B19191908#, 16#1908082B192B0808#, 16#1908082B2B080819#,
      16#1908082B2B081908#, 16#1908190808080808#, 16#190819080808082B#, 16#1908190808081919#,
      16#1908190808082B08#, 16#1908190808082B2B#, 16#1908190808190819#, 16#1908190808191908#,
      16#190819080819192B#, 16#1908190808192B19#, 16#19081908082B0808#, 16#19081908082B082B#,
      16#19081908082B1919#, 16#19081908082B2B08#, 16#1908190819080819#, 16#1908190819081908#,
      16#190819081908192B#, 16#1908190819082B19#, 16#1908190819190808#, 16#190819081919082B#,
      16#1908190819191919#, 16#1908190819192B08#, 16#19081908192B0819#, 16#19081908192B1908#,
      16#190819082B080808#, 16#190819082B08082B#, 16#190819082B081919#, 16#190819082B082B08#,
      16#190819082B190819#, 16#190819082B191908#, 16#190819082B2B0808#, 16#1908191908080819#,
      16#1908191908081908#, 16#190819190808192B#, 16#1908191908082B19#, 16#1908191908190808#,
      16#190819190819082B#, 16#1908191908191919#, 16#1908191908192B08#, 16#19081919082B0819#,
      16#19081919082B1908#, 16#1908191919080808#, 16#190819191908082B#, 16#1908191919081919#,
      16#1908191919082B08#, 16#1908191919190819#, 16#1908191919191908#, 16#19081919192B0808#,
      16#19081919192B2B2B#, 16#190819192B080819#, 16#190819192B081908#, 16#190819192B190808#,
      16#1908192B08080808#, 16#1908192B0808082B#, 16#1908192B08081919#, 16#1908192B08082B08#,
      16#1908192B08190819#, 16#1908192B08191908#, 16#1908192B082B0808#, 16#1908192B19080819#,
      16#1908192B19081908#, 16#1908192B19190808#, 16#1908192B2B080808#, 16#1908192B2B2B1919#,
      16#19082B0808080819#, 16#19082B0808081908#, 16#19082B0808082B19#, 16#19082B0808190808#,
      16#19082B080819082B#, 16#19082B0808191919#, 16#19082B0808192B08#, 16#19082B08082B0819#,
      16#19082B08082B1908#, 16#19082B0819080808#, 16#19082B081908082B#, 16#19082B0819081919#,
      16#19082B0819082B08#, 16#19082B0819190819#, 16#19082B0819191908#, 16#19082B08192B0808#,
      16#19082B082B081908#, 16#19082B082B190808#, 16#19082B1908080808#, 16#19082B190808082B#,
      16#19082B1908081919#, 16#19082B1908082B08#, 16#19082B1908190819#, 16#19082B1908191908#,
      16#19082B19082B0808#, 16#19082B1919080819#, 16#19082B1919081908#, 16#19082B1919190808#,
      16#19082B192B080808#, 16#19082B192B19192B#, 16#19082B2B08080819#, 16#19082B2B08081908#,
      16#19082B2B08190808#, 16#19082B2B19080808#, 16#1919080808080808#, 16#191908080808082B#,
      16#1919080808081919#, 16#1919080808082B08#, 16#1919080808190819#, 16#1919080808191908#,
      16#191908080819192B#, 16#1919080808192B19#, 16#19190808082B0808#, 16#19190808082B082B#,
      16#19190808082B1919#, 16#19190808082B2B08#, 16#1919080819080819#, 16#1919080819081908#,
      16#191908081908192B#, 16#1919080819082B19#, 16#1919080819190808#, 16#191908081919082B#,
      16#1919080819191919#, 16#1919080819192B08#, 16#19190808192B0819#, 16#19190808192B1908#,
      16#191908082B080808#, 16#191908082B08082B#, 16#191908082B081919#, 16#191908082B082B08#,
      16#191908082B190819#, 16#191908082B191908#, 16#1919081908080819#, 16#1919081908081908#,
      16#191908190808192B#, 16#1919081908082B19#, 16#1919081908190808#, 16#191908190819082B#,
      16#1919081908191919#, 16#1919081908192B08#, 16#19190819082B0819#, 16#19190819082B1908#,
      16#1919081919080808#, 16#191908191908082B#, 16#1919081919081919#, 16#1919081919082B08#,
      16#1919081919190819#, 16#1919081919191908#, 16#19190819192B0808#, 16#191908192B080819#,
      16#191908192B081908#, 16#191908192B190808#, 16#1919082B08080808#, 16#1919082B08081919#,
      16#1919082B08082B08#, 16#1919082B08190819#, 16#1919082B08191908#, 16#1919082B082B0808#,
      16#1919082B19080819#, 16#1919082B19081908#, 16#1919082B19190808#, 16#1919082B192B2B19#,
      16#1919082B2B080808#, 16#1919190808080819#, 16#1919190808081908#, 16#191919080808192B#,
      16#1919190808082B19#, 16#1919190808190808#, 16#191919080819082B#, 16#1919190808191919#,
      16#1919190808192B08#, 16#19191908082B0819#, 16#19191908082B1908#, 16#1919190819080808#,
      16#191919081908082B#, 16#1919190819081919#, 16#1919190819082B08#, 16#1919190819190819#,
      16#1919190819191908#, 16#19191908192B0808#, 16#191919082B080819#, 16#191919082B081908#,
      16#191919082B190808#, 16#1919191908080808#, 16#191919190808082B#, 16#1919191908081919#,
      16#1919191908082B08#, 16#1919191908190819#, 16#1919191908191908#, 16#19191919082B0808#,
      16#1919191919080819#, 16#1919191919081908#, 16#1919191919190808#, 16#191919192B080808#,
      16#1919192B08080819#, 16#1919192B08081908#, 16#1919192B08190808#, 16#1919192B082B192B#,
      16#1919192B19080808#, 16#19192B0808080808#, 16#19192B080808082B#, 16#19192B0808081919#,
      16#19192B0808082B08#, 16#19192B0808190819#, 16#19192B0808191908#, 16#19192B08082B0808#,
      16#19192B0819080819#, 16#19192B0819081908#, 16#19192B0819190808#, 16#19192B0819192B2B#,
      16#19192B082B080808#, 16#19192B1908080819#, 16#19192B1908081908#, 16#19192B1908190808#,
      16#19192B1919080808#, 16#19192B2B08080808#, 16#19192B2B08192B19#, 16#19192B2B2B081919#,
      16#19192B2B2B2B2B08#, 16#192B080808080819#, 16#192B080808081908#, 16#192B08080808192B#,
      16#192B080808190808#, 16#192B08080819082B#, 16#192B080808191919#, 16#192B080808192B08#,
      16#192B0808082B0819#, 16#192B0808082B1908#, 16#192B080819080808#, 16#192B080819081919#,
      16#192B080819082B08#, 16#192B080819190819#, 16#192B080819191908#, 16#192B0808192B0808#,
      16#192B08082B081908#, 16#192B08082B190808#, 16#192B081908080808#, 16#192B08190808082B#,
      16#192B081908081919#, 16#192B081908082B08#, 16#192B081908190819#, 16#192B081908191908#,
      16#192B0819082B0808#, 16#192B081919080819#, 16#192B081919081908#, 16#192B081919190808#,
      16#192B08192B080808#, 16#192B08192B192B19#, 16#192B082B08081908#, 16#192B082B08190808#,
      16#192B082B19080808#, 16#192B082B1919192B#, 16#192B082B2B2B0819#, 16#192B190808080808#,
      16#192B190808081919#, 16#192B190808082B08#, 16#192B190808190819#, 16#192B190808191908#,
      16#192B1908082B0808#, 16#192B190819080819#, 16#192B190819081908#, 16#192B190819190808#,
      16#192B19082B080808#, 16#192B191908080819#, 16#192B191908081908#, 16#192B191908190808#,
      16#192B191919080808#, 16#192B191919082B2B#, 16#192B1919192B2B08#, 16#192B19192B19082B#,
      16#192B192B08080808#, 16#192B192B2B191908#, 16#192B2B0808080819#, 16#192B2B0808081908#,
      16#192B2B0808190808#, 16#192B2B08192B1919#, 16#192B2B082B192B08#, 16#192B2B1908080808#,
      16#192B2B19082B2B2B#, 16#192B2B2B1908082B#, 16#192B2B2B2B2B0819#, 16#2B08080808080808#,
      16#2B0808080808082B#, 16#2B08080808081919#, 16#2B08080808082B08#, 16#2B08080808190819#,
      16#2B08080808191908#, 16#2B08080808192B19#, 16#2B080808082B0808#, 16#2B080808082B1919#,
      16#2B08080819080819#, 16#2B08080819081908#, 16#2B08080819190808#, 16#2B0808081919082B#,
      16#2B08080819191919#, 16#2B08080819192B08#, 16#2B080808192B0819#, 16#2B0808082B080808#,
      16#2B0808082B081919#, 16#2B0808082B190819#, 16#2B0808082B191908#, 16#2B08081908080819#,
      16#2B08081908081908#, 16#2B08081908082B19#, 16#2B08081908190808#, 16#2B0808190819082B#,
      16#2B08081908191919#, 16#2B08081908192B08#, 16#2B080819082B0819#, 16#2B080819082B1908#,
      16#2B08081919080808#, 16#2B0808191908082B#, 16#2B08081919081919#, 16#2B08081919082B08#,
      16#2B08081919190819#, 16#2B08081919191908#, 16#2B0808192B080819#, 16#2B0808192B081908#,
      16#2B0808192B190808#, 16#2B0808192B2B2B19#, 16#2B08082B08080808#, 16#2B08082B08081919#,
      16#2B08082B08082B2B#, 16#2B08082B08190819#, 16#2B08082B08191908#, 16#2B08082B19080819#,
      16#2B08082B19081908#, 16#2B08082B19190808#, 16#2B08190808080819#, 16#2B08190808081908#,
      16#2B0819080808192B#, 16#2B08190808082B19#, 16#2B08190808190808#, 16#2B0819080819082B#,
      16#2B08190808191919#, 16#2B08190808192B08#, 16#2B081908082B0819#, 16#2B08190819080808#,
      16#2B0819081908082B#, 16#2B08190819081919#, 16#2B08190819082B08#, 16#2B08190819190819#,
      16#2B08190819191908#, 16#2B081908192B0808#, 16#2B0819082B080819#, 16#2B0819082B081908#,
      16#2B0819082B190808#, 16#2B08191908080808#, 16#2B0819190808082B#, 16#2B08191908081919#,
      16#2B08191908082B08#, 16#2B08191908190819#, 16#2B08191908191908#, 16#2B081919082B0808#,
      16#2B08191919080819#, 16#2B08191919081908#, 16#2B08191919190808#, 16#2B0819192B080808#,
      16#2B0819192B082B2B#, 16#2B08192B08080819#, 16#2B08192B08081908#, 16#2B08192B08190808#,
      16#2B08192B082B2B19#, 16#2B08192B19080808#, 16#2B082B0808080808#, 16#2B082B0808081919#,
      16#2B082B0808190819#, 16#2B082B0808191908#, 16#2B082B0819080819#, 16#2B082B0819081908#,
      16#2B082B0819190808#, 16#2B082B082B2B082B#, 16#2B082B1908080819#, 16#2B082B1908081908#,
      16#2B082B1919080808#, 16#2B082B19192B1919#, 16#2B082B2B082B082B#, 16#2B082B2B19192B08#,
      16#2B082B2B19192B2B#, 16#2B082B2B2B08082B#, 16#2B082B2B2B2B082B#, 16#2B19080808080819#,
      16#2B19080808081908#, 16#2B19080808082B19#, 16#2B19080808190808#, 16#2B1908080819082B#,
      16#2B19080808191919#, 16#2B19080808192B08#, 16#2B190808082B1908#, 16#2B19080819080808#,
      16#2B1908081908082B#, 16#2B19080819081919#, 16#2B19080819082B08#, 16#2B19080819190819#,
      16#2B19080819191908#, 16#2B190808192B0808#, 16#2B1908082B080819#, 16#2B1908082B081908#,
      16#2B1908082B190808#, 16#2B19081908080808#, 16#2B19081908081919#, 16#2B19081908190819#,
      16#2B19081908191908#, 16#2B19081919080819#, 16#2B19081919081908#, 16#2B19081919190808#,
      16#2B19081919192B2B#, 16#2B19082B08080819#, 16#2B19082B08081908#, 16#2B19082B08190808#,
      16#2B19082B19080808#, 16#2B19082B2B2B192B#, 16#2B19190808080808#, 16#2B1919080808082B#,
      16#2B19190808081919#, 16#2B19190808082B08#, 16#2B19190808190819#, 16#2B19190808191908#,
      16#2B191908082B0808#, 16#2B19190819080819#, 16#2B19190819081908#, 16#2B19190819190808#,
      16#2B1919082B080808#, 16#2B1919082B19192B#, 16#2B19191908080819#, 16#2B19191908081908#,
      16#2B19191908190808#, 16#2B19191919080808#, 16#2B1919192B192B08#, 16#2B1919192B2B0819#,
      16#2B19192B08080808#, 16#2B19192B1908192B#, 16#2B19192B192B1908#, 16#2B192B0808080819#,
      16#2B192B0808081908#, 16#2B192B0808190808#, 16#2B192B08082B192B#, 16#2B192B0819080808#,
      16#2B192B082B2B2B19#, 16#2B192B1908080808#, 16#2B192B1919082B19#, 16#2B192B191919082B#,
      16#2B192B2B2B190808#, 16#2B2B080808080808#, 16#2B2B080808081919#, 16#2B2B080808082B2B#,
      16#2B2B080808191908#, 16#2B2B0808082B082B#, 16#2B2B0808082B2B2B#, 16#2B2B080819080819#,
      16#2B2B080819081908#, 16#2B2B080819190808#, 16#2B2B08082B2B082B#, 16#2B2B08082B2B2B2B#,
      16#2B2B081919080808#, 16#2B2B0819192B1919#, 16#2B2B082B0808082B#, 16#2B2B082B08082B2B#,
      16#2B2B082B082B082B#, 16#2B2B082B082B2B08#, 16#2B2B082B082B2B2B#, 16#2B2B082B2B08082B#,
      16#2B2B082B2B082B08#, 16#2B2B082B2B082B2B#, 16#2B2B082B2B2B2B08#, 16#2B2B190808080819#,
      16#2B2B190808081908#, 16#2B2B190808190808#, 16#2B2B190819080808#, 16#2B2B19082B082B19#,
      16#2B2B19082B2B1908#, 16#2B2B191908080808#, 16#2B2B191908192B19#, 16#2B2B192B19190819#,
      16#2B2B2B0808082B2B#, 16#2B2B2B08082B2B08#, 16#2B2B2B082B2B082B#, 16#2B2B2B1919191908#,
      16#2B2B2B192B08192B#, 16#2B2B2B2B08082B08#, 16#2B2B2B2B08082B2B#, 16#2B2B2B2B082B0808#,
      16#2B2B2B2B082B082B#, 16#2B2B2B2B082B2B08#, 16#2B2B2B2B2B082B08#, 16#2B2B2B2B2B2B2B2B#
     ];

   --  Transcribed verbatim from llama.cpp's iq3xxs_grid (ggml-common.h).
   IQ3XXS_Grid : constant array (0 .. 255) of Interfaces.Unsigned_32 :=
     [
      16#04040404#, 16#04040414#, 16#04040424#, 16#04040C0C#, 16#04040C1C#, 16#04040C3E#,
      16#04041404#, 16#04041414#, 16#04041C0C#, 16#04042414#, 16#04043E1C#, 16#04043E2C#,
      16#040C040C#, 16#040C041C#, 16#040C0C04#, 16#040C0C14#, 16#040C140C#, 16#040C142C#,
      16#040C1C04#, 16#040C1C14#, 16#040C240C#, 16#040C2C24#, 16#040C3E04#, 16#04140404#,
      16#04140414#, 16#04140424#, 16#04140C0C#, 16#04141404#, 16#04141414#, 16#04141C0C#,
      16#04141C1C#, 16#04141C3E#, 16#04142C0C#, 16#04142C3E#, 16#04143E2C#, 16#041C040C#,
      16#041C043E#, 16#041C0C04#, 16#041C0C14#, 16#041C142C#, 16#041C3E04#, 16#04240C1C#,
      16#04241C3E#, 16#04242424#, 16#04242C3E#, 16#04243E1C#, 16#04243E2C#, 16#042C040C#,
      16#042C043E#, 16#042C1C14#, 16#042C2C14#, 16#04341C2C#, 16#04343424#, 16#043E0C04#,
      16#043E0C24#, 16#043E0C34#, 16#043E241C#, 16#043E340C#, 16#0C04040C#, 16#0C04041C#,
      16#0C040C04#, 16#0C040C14#, 16#0C04140C#, 16#0C04141C#, 16#0C041C04#, 16#0C041C14#,
      16#0C041C24#, 16#0C04243E#, 16#0C042C04#, 16#0C0C0404#, 16#0C0C0414#, 16#0C0C0C0C#,
      16#0C0C1404#, 16#0C0C1414#, 16#0C14040C#, 16#0C14041C#, 16#0C140C04#, 16#0C140C14#,
      16#0C14140C#, 16#0C141C04#, 16#0C143E14#, 16#0C1C0404#, 16#0C1C0414#, 16#0C1C1404#,
      16#0C1C1C0C#, 16#0C1C2434#, 16#0C1C3434#, 16#0C24040C#, 16#0C24042C#, 16#0C242C04#,
      16#0C2C1404#, 16#0C2C1424#, 16#0C2C2434#, 16#0C2C3E0C#, 16#0C34042C#, 16#0C3E1414#,
      16#0C3E2404#, 16#14040404#, 16#14040414#, 16#14040C0C#, 16#14040C1C#, 16#14041404#,
      16#14041414#, 16#14041434#, 16#14041C0C#, 16#14042414#, 16#140C040C#, 16#140C041C#,
      16#140C042C#, 16#140C0C04#, 16#140C0C14#, 16#140C140C#, 16#140C1C04#, 16#140C341C#,
      16#140C343E#, 16#140C3E04#, 16#14140404#, 16#14140414#, 16#14140C0C#, 16#14140C3E#,
      16#14141404#, 16#14141414#, 16#14141C3E#, 16#14142404#, 16#14142C2C#, 16#141C040C#,
      16#141C0C04#, 16#141C0C24#, 16#141C3E04#, 16#141C3E24#, 16#14241C2C#, 16#14242C1C#,
      16#142C041C#, 16#142C143E#, 16#142C240C#, 16#142C3E24#, 16#143E040C#, 16#143E041C#,
      16#143E0C34#, 16#143E242C#, 16#1C04040C#, 16#1C040C04#, 16#1C040C14#, 16#1C04140C#,
      16#1C04141C#, 16#1C042C04#, 16#1C04342C#, 16#1C043E14#, 16#1C0C0404#, 16#1C0C0414#,
      16#1C0C1404#, 16#1C0C1C0C#, 16#1C0C2424#, 16#1C0C2434#, 16#1C14040C#, 16#1C14041C#,
      16#1C140C04#, 16#1C14142C#, 16#1C142C14#, 16#1C143E14#, 16#1C1C0C0C#, 16#1C1C1C1C#,
      16#1C241C04#, 16#1C24243E#, 16#1C243E14#, 16#1C2C0404#, 16#1C2C0434#, 16#1C2C1414#,
      16#1C2C2C2C#, 16#1C340C24#, 16#1C341C34#, 16#1C34341C#, 16#1C3E1C1C#, 16#1C3E3404#,
      16#24040424#, 16#24040C3E#, 16#24041C2C#, 16#24041C3E#, 16#24042C1C#, 16#24042C3E#,
      16#240C3E24#, 16#24141404#, 16#24141C3E#, 16#24142404#, 16#24143404#, 16#24143434#,
      16#241C043E#, 16#241C242C#, 16#24240424#, 16#24242C0C#, 16#24243424#, 16#242C142C#,
      16#242C241C#, 16#242C3E04#, 16#243E042C#, 16#243E0C04#, 16#243E0C14#, 16#243E1C04#,
      16#2C040C14#, 16#2C04240C#, 16#2C043E04#, 16#2C0C0404#, 16#2C0C0434#, 16#2C0C1434#,
      16#2C0C2C2C#, 16#2C140C24#, 16#2C141C14#, 16#2C143E14#, 16#2C1C0414#, 16#2C1C2C1C#,
      16#2C240C04#, 16#2C24141C#, 16#2C24143E#, 16#2C243E14#, 16#2C2C0414#, 16#2C2C1C0C#,
      16#2C342C04#, 16#2C3E1424#, 16#2C3E2414#, 16#34041424#, 16#34042424#, 16#34042434#,
      16#34043424#, 16#340C140C#, 16#340C340C#, 16#34140C3E#, 16#34143424#, 16#341C1C04#,
      16#341C1C34#, 16#34242424#, 16#342C042C#, 16#342C2C14#, 16#34341C1C#, 16#343E041C#,
      16#343E140C#, 16#3E04041C#, 16#3E04042C#, 16#3E04043E#, 16#3E040C04#, 16#3E041C14#,
      16#3E042C14#, 16#3E0C1434#, 16#3E0C2404#, 16#3E140C14#, 16#3E14242C#, 16#3E142C14#,
      16#3E1C0404#, 16#3E1C0C2C#, 16#3E1C1C1C#, 16#3E1C3404#, 16#3E24140C#, 16#3E24240C#,
      16#3E2C0404#, 16#3E2C0414#, 16#3E2C1424#, 16#3E341C04#
     ];

   --  Transcribed verbatim from llama.cpp's iq1s_grid (ggml-common.h).
   IQ1S_Grid : constant array (0 .. 2047) of Interfaces.Unsigned_64 :=
     [
      16#FFFFFFFFFFFFFFFF#, 16#FFFFFFFFFFFFFF01#, 16#FFFFFFFFFFFF0000#, 16#FFFFFFFFFFFF01FF#,
      16#FFFFFFFFFFFF0101#, 16#FFFFFFFFFF00FF00#, 16#FFFFFFFFFF000000#, 16#FFFFFFFFFF01FFFF#,
      16#FFFFFFFFFF01FF01#, 16#FFFFFFFFFF0101FF#, 16#FFFFFFFFFF010101#, 16#FFFFFFFF00FF0000#,
      16#FFFFFFFF0000FF00#, 16#FFFFFFFF000000FF#, 16#FFFFFFFF00000001#, 16#FFFFFFFF00010000#,
      16#FFFFFFFF01FFFFFF#, 16#FFFFFFFF01FFFF01#, 16#FFFFFFFF01FF01FF#, 16#FFFFFFFF01FF0101#,
      16#FFFFFFFF01000000#, 16#FFFFFFFF0101FFFF#, 16#FFFFFFFF0101FF01#, 16#FFFFFFFF010101FF#,
      16#FFFFFFFF01010101#, 16#FFFFFF00FFFF00FF#, 16#FFFFFF00FFFF0000#, 16#FFFFFF00FF00FF00#,
      16#FFFFFF00FF0000FF#, 16#FFFFFF00FF000001#, 16#FFFFFF00FF000100#, 16#FFFFFF00FF000101#,
      16#FFFFFF00FF010000#, 16#FFFFFF0000FFFF00#, 16#FFFFFF0000FF0001#, 16#FFFFFF0000FF0100#,
      16#FFFFFF000000FF01#, 16#FFFFFF0000000000#, 16#FFFFFF0000000101#, 16#FFFFFF000001FF00#,
      16#FFFFFF00000100FF#, 16#FFFFFF0000010001#, 16#FFFFFF00000101FF#, 16#FFFFFF0001FF0000#,
      16#FFFFFF000100FF00#, 16#FFFFFF00010000FF#, 16#FFFFFF0001000001#, 16#FFFFFF0001010000#,
      16#FFFFFF01FFFFFFFF#, 16#FFFFFF01FFFFFF01#, 16#FFFFFF01FFFF01FF#, 16#FFFFFF01FFFF0101#,
      16#FFFFFF01FF000000#, 16#FFFFFF01FF01FFFF#, 16#FFFFFF01FF01FF01#, 16#FFFFFF01FF0101FF#,
      16#FFFFFF01FF010101#, 16#FFFFFF0100FF0000#, 16#FFFFFF010000FF00#, 16#FFFFFF0100000100#,
      16#FFFFFF01000100FF#, 16#FFFFFF0100010100#, 16#FFFFFF0101FFFFFF#, 16#FFFFFF0101FFFF01#,
      16#FFFFFF0101FF01FF#, 16#FFFFFF0101FF0101#, 16#FFFFFF010100FF00#, 16#FFFFFF0101000000#,
      16#FFFFFF0101000100#, 16#FFFFFF010101FFFF#, 16#FFFFFF010101FF01#, 16#FFFFFF01010101FF#,
      16#FFFFFF0101010101#, 16#FFFF00FFFF00FF00#, 16#FFFF00FFFF0000FF#, 16#FFFF00FFFF000001#,
      16#FFFF00FFFF010000#, 16#FFFF00FF00FFFF00#, 16#FFFF00FF00FF0100#, 16#FFFF00FF00000000#,
      16#FFFF00FF00000101#, 16#FFFF00FF000100FF#, 16#FFFF00FF00010000#, 16#FFFF00FF0100FF00#,
      16#FFFF00FF01000100#, 16#FFFF00FF01010000#, 16#FFFF0000FFFFFF00#, 16#FFFF0000FFFF00FF#,
      16#FFFF0000FFFF0000#, 16#FFFF0000FFFF0001#, 16#FFFF0000FF000000#, 16#FFFF0000FF0001FF#,
      16#FFFF0000FF000101#, 16#FFFF0000FF010100#, 16#FFFF000000FFFFFF#, 16#FFFF000000FF0000#,
      16#FFFF000000FF0101#, 16#FFFF00000000FFFF#, 16#FFFF00000000FF00#, 16#FFFF0000000000FF#,
      16#FFFF000000000000#, 16#FFFF000000000001#, 16#FFFF000000000100#, 16#FFFF00000001FFFF#,
      16#FFFF00000001FF01#, 16#FFFF000000010000#, 16#FFFF0000000101FF#, 16#FFFF000000010101#,
      16#FFFF000001FFFF00#, 16#FFFF00000100FF00#, 16#FFFF000001000000#, 16#FFFF0000010001FF#,
      16#FFFF000001000101#, 16#FFFF00000101FF00#, 16#FFFF0000010100FF#, 16#FFFF000001010000#,
      16#FFFF000001010001#, 16#FFFF000001010100#, 16#FFFF0001FF0000FF#, 16#FFFF0001FF000100#,
      16#FFFF000100FFFF00#, 16#FFFF000100FF00FF#, 16#FFFF00010000FFFF#, 16#FFFF00010000FF01#,
      16#FFFF000100000000#, 16#FFFF0001000001FF#, 16#FFFF00010001FFFF#, 16#FFFF00010001FF00#,
      16#FFFF000100010001#, 16#FFFF000100010100#, 16#FFFF000101FF0000#, 16#FFFF00010100FF00#,
      16#FFFF0001010000FF#, 16#FFFF000101000100#, 16#FFFF01FFFFFFFFFF#, 16#FFFF01FFFFFFFF01#,
      16#FFFF01FFFFFF01FF#, 16#FFFF01FFFFFF0101#, 16#FFFF01FFFF000000#, 16#FFFF01FFFF01FFFF#,
      16#FFFF01FFFF01FF01#, 16#FFFF01FFFF0101FF#, 16#FFFF01FFFF010101#, 16#FFFF01FF00FF0000#,
      16#FFFF01FF0000FF00#, 16#FFFF01FF00000001#, 16#FFFF01FF00010000#, 16#FFFF01FF01FFFFFF#,
      16#FFFF01FF01FFFF01#, 16#FFFF01FF01FF01FF#, 16#FFFF01FF01FF0101#, 16#FFFF01FF01000000#,
      16#FFFF01FF0101FFFF#, 16#FFFF01FF0101FF01#, 16#FFFF01FF010101FF#, 16#FFFF01FF01010101#,
      16#FFFF0100FFFF0000#, 16#FFFF0100FF00FF00#, 16#FFFF0100FF0000FF#, 16#FFFF0100FF000100#,
      16#FFFF0100FF0100FF#, 16#FFFF0100FF010000#, 16#FFFF010000FFFF00#, 16#FFFF01000000FFFF#,
      16#FFFF01000000FF00#, 16#FFFF010000000000#, 16#FFFF01000001FF00#, 16#FFFF0100000100FF#,
      16#FFFF010000010100#, 16#FFFF01000100FF00#, 16#FFFF0100010000FF#, 16#FFFF010001000001#,
      16#FFFF010001000100#, 16#FFFF010001010000#, 16#FFFF0101FFFFFFFF#, 16#FFFF0101FFFFFF01#,
      16#FFFF0101FFFF01FF#, 16#FFFF0101FFFF0101#, 16#FFFF0101FF000000#, 16#FFFF0101FF01FFFF#,
      16#FFFF0101FF01FF01#, 16#FFFF0101FF0101FF#, 16#FFFF0101FF010101#, 16#FFFF010100FF0000#,
      16#FFFF01010000FF00#, 16#FFFF010100000100#, 16#FFFF01010001FF00#, 16#FFFF010100010000#,
      16#FFFF010101FFFFFF#, 16#FFFF010101FFFF01#, 16#FFFF010101FF0000#, 16#FFFF010101FF01FF#,
      16#FFFF010101FF0101#, 16#FFFF010101000000#, 16#FFFF01010101FFFF#, 16#FFFF01010101FF01#,
      16#FFFF0101010101FF#, 16#FFFF010101010101#, 16#FF00FFFFFF00FFFF#, 16#FF00FFFFFF00FF00#,
      16#FF00FFFFFF0000FF#, 16#FF00FFFFFF000100#, 16#FF00FFFFFF0100FF#, 16#FF00FFFFFF010000#,
      16#FF00FFFF00FFFF00#, 16#FF00FFFF00FF00FF#, 16#FF00FFFF0000FFFF#, 16#FF00FFFF00000000#,
      16#FF00FFFF000001FF#, 16#FF00FFFF0001FF00#, 16#FF00FFFF000100FF#, 16#FF00FFFF00010000#,
      16#FF00FFFF00010100#, 16#FF00FFFF0100FF00#, 16#FF00FFFF010000FF#, 16#FF00FFFF01000001#,
      16#FF00FFFF0101FF00#, 16#FF00FFFF01010000#, 16#FF00FF00FFFFFF00#, 16#FF00FF00FFFF00FF#,
      16#FF00FF00FFFF0001#, 16#FF00FF00FFFF0100#, 16#FF00FF00FF00FFFF#, 16#FF00FF00FF00FF01#,
      16#FF00FF00FF000000#, 16#FF00FF00FF0001FF#, 16#FF00FF00FF01FF00#, 16#FF00FF00FF0100FF#,
      16#FF00FF00FF010100#, 16#FF00FF0000FF0000#, 16#FF00FF0000FF0101#, 16#FF00FF000000FFFF#,
      16#FF00FF000000FF00#, 16#FF00FF000000FF01#, 16#FF00FF00000000FF#, 16#FF00FF0000000000#,
      16#FF00FF0000000001#, 16#FF00FF0000000100#, 16#FF00FF000001FFFF#, 16#FF00FF0000010000#,
      16#FF00FF0001FF00FF#, 16#FF00FF000100FF01#, 16#FF00FF0001000000#, 16#FF00FF000101FF00#,
      16#FF00FF00010100FF#, 16#FF00FF01FF00FF00#, 16#FF00FF01FF0000FF#, 16#FF00FF01FF000001#,
      16#FF00FF01FF010000#, 16#FF00FF0100FFFFFF#, 16#FF00FF0100FF0001#, 16#FF00FF0100FF0100#,
      16#FF00FF010000FF01#, 16#FF00FF0100000000#, 16#FF00FF01000001FF#, 16#FF00FF0100000101#,
      16#FF00FF01000100FF#, 16#FF00FF0100010001#, 16#FF00FF0101FF0000#, 16#FF00FF010100FF00#,
      16#FF00FF01010000FF#, 16#FF00FF0101000001#, 16#FF00FF0101010000#, 16#FF0000FFFFFFFF00#,
      16#FF0000FFFFFF0001#, 16#FF0000FFFFFF0100#, 16#FF0000FFFF0000FF#, 16#FF0000FFFF000000#,
      16#FF0000FFFF0001FF#, 16#FF0000FFFF000100#, 16#FF0000FFFF01FF00#, 16#FF0000FFFF010001#,
      16#FF0000FF00FFFF00#, 16#FF0000FF00FF0000#, 16#FF0000FF00FF0001#, 16#FF0000FF00FF01FF#,
      16#FF0000FF00FF0101#, 16#FF0000FF0000FF00#, 16#FF0000FF000000FF#, 16#FF0000FF00000000#,
      16#FF0000FF00000001#, 16#FF0000FF00000100#, 16#FF0000FF0001FF01#, 16#FF0000FF00010000#,
      16#FF0000FF000101FF#, 16#FF0000FF01FF00FF#, 16#FF0000FF01FF0100#, 16#FF0000FF0100FFFF#,
      16#FF0000FF010000FF#, 16#FF0000FF01000000#, 16#FF0000FF010001FF#, 16#FF0000FF01000100#,
      16#FF0000FF01000101#, 16#FF0000FF0101FF00#, 16#FF0000FF010100FF#, 16#FF0000FF01010000#,
      16#FF0000FF01010100#, 16#FF000000FFFFFF01#, 16#FF000000FFFF0000#, 16#FF000000FFFF0101#,
      16#FF000000FF00FF00#, 16#FF000000FF0000FF#, 16#FF000000FF000000#, 16#FF000000FF000001#,
      16#FF000000FF000100#, 16#FF000000FF01FFFF#, 16#FF000000FF01FF01#, 16#FF000000FF010000#,
      16#FF000000FF0101FF#, 16#FF000000FF010101#, 16#FF00000000FFFF00#, 16#FF00000000FF00FF#,
      16#FF00000000FF0000#, 16#FF00000000FF0001#, 16#FF0000000000FF00#, 16#FF0000000000FF01#,
      16#FF000000000000FF#, 16#FF00000000000000#, 16#FF00000000000001#, 16#FF00000000000100#,
      16#FF00000000000101#, 16#FF0000000001FF00#, 16#FF000000000100FF#, 16#FF00000000010000#,
      16#FF00000000010001#, 16#FF00000000010100#, 16#FF00000001FFFFFF#, 16#FF00000001FFFF01#,
      16#FF00000001FF00FF#, 16#FF00000001FF0000#, 16#FF00000001FF01FF#, 16#FF00000001FF0101#,
      16#FF0000000100FFFF#, 16#FF0000000100FF00#, 16#FF000000010000FF#, 16#FF00000001000000#,
      16#FF00000001000001#, 16#FF00000001000100#, 16#FF00000001000101#, 16#FF0000000101FFFF#,
      16#FF0000000101FF01#, 16#FF00000001010000#, 16#FF000001FFFFFF00#, 16#FF000001FFFF00FF#,
      16#FF000001FFFF0000#, 16#FF000001FFFF0001#, 16#FF000001FF000000#, 16#FF000001FF000001#,
      16#FF000001FF0001FF#, 16#FF000001FF000101#, 16#FF000001FF01FF00#, 16#FF000001FF010001#,
      16#FF00000100FFFFFF#, 16#FF00000100FFFF01#, 16#FF00000100FF00FF#, 16#FF00000100FF0000#,
      16#FF00000100FF01FF#, 16#FF00000100FF0101#, 16#FF0000010000FF00#, 16#FF00000100000000#,
      16#FF00000100000001#, 16#FF000001000001FF#, 16#FF00000100000100#, 16#FF0000010001FF00#,
      16#FF000001000100FF#, 16#FF00000100010000#, 16#FF000001000101FF#, 16#FF00000100010100#,
      16#FF00000100010101#, 16#FF00000101FF0001#, 16#FF00000101FF0101#, 16#FF0000010100FF01#,
      16#FF00000101000000#, 16#FF000001010100FF#, 16#FF00000101010100#, 16#FF0001FFFF00FF00#,
      16#FF0001FFFF000001#, 16#FF0001FFFF010000#, 16#FF0001FF00FFFF00#, 16#FF0001FF00FF00FF#,
      16#FF0001FF00FF0001#, 16#FF0001FF00FF0100#, 16#FF0001FF0000FFFF#, 16#FF0001FF00000000#,
      16#FF0001FF000001FF#, 16#FF0001FF00000101#, 16#FF0001FF0001FFFF#, 16#FF0001FF0001FF00#,
      16#FF0001FF000100FF#, 16#FF0001FF00010001#, 16#FF0001FF00010100#, 16#FF0001FF01FF0000#,
      16#FF0001FF0100FF00#, 16#FF0001FF010000FF#, 16#FF0001FF01010000#, 16#FF000100FF00FFFF#,
      16#FF000100FF00FF01#, 16#FF000100FF000000#, 16#FF000100FF000101#, 16#FF000100FF01FF00#,
      16#FF000100FF010000#, 16#FF00010000FFFF01#, 16#FF00010000FF00FF#, 16#FF00010000FF0000#,
      16#FF00010000FF01FF#, 16#FF0001000000FF00#, 16#FF000100000000FF#, 16#FF00010000000000#,
      16#FF00010000000001#, 16#FF00010000000100#, 16#FF00010000000101#, 16#FF0001000001FFFF#,
      16#FF00010000010000#, 16#FF00010000010101#, 16#FF00010001FF0100#, 16#FF0001000100FF00#,
      16#FF0001000100FF01#, 16#FF00010001000000#, 16#FF000100010001FF#, 16#FF0001000101FF00#,
      16#FF00010001010001#, 16#FF00010001010100#, 16#FF000101FFFF0100#, 16#FF000101FF000001#,
      16#FF000101FF0100FF#, 16#FF000101FF010001#, 16#FF00010100FF00FF#, 16#FF00010100FF0001#,
      16#FF00010100FF0100#, 16#FF0001010000FFFF#, 16#FF0001010000FF01#, 16#FF00010100000000#,
      16#FF000101000001FF#, 16#FF0001010001FF00#, 16#FF00010100010001#, 16#FF00010100010100#,
      16#FF00010101FF0000#, 16#FF0001010100FF00#, 16#FF00010101000001#, 16#FF00010101000101#,
      16#FF01FFFFFFFFFFFF#, 16#FF01FFFFFFFFFF01#, 16#FF01FFFFFFFF01FF#, 16#FF01FFFFFFFF0101#,
      16#FF01FFFFFF000000#, 16#FF01FFFFFF01FFFF#, 16#FF01FFFFFF01FF01#, 16#FF01FFFFFF010000#,
      16#FF01FFFFFF0101FF#, 16#FF01FFFFFF010101#, 16#FF01FFFF00FF0000#, 16#FF01FFFF0000FF00#,
      16#FF01FFFF00000100#, 16#FF01FFFF0001FF00#, 16#FF01FFFF00010000#, 16#FF01FFFF01FFFFFF#,
      16#FF01FFFF01FFFF01#, 16#FF01FFFF01FF01FF#, 16#FF01FFFF01FF0101#, 16#FF01FFFF01000000#,
      16#FF01FFFF0101FFFF#, 16#FF01FFFF0101FF01#, 16#FF01FFFF01010000#, 16#FF01FFFF010101FF#,
      16#FF01FFFF01010101#, 16#FF01FF00FFFF0000#, 16#FF01FF00FF00FF00#, 16#FF01FF00FF0000FF#,
      16#FF01FF00FF000100#, 16#FF01FF00FF010000#, 16#FF01FF0000FFFF01#, 16#FF01FF0000FF00FF#,
      16#FF01FF0000FF0100#, 16#FF01FF0000000000#, 16#FF01FF00000001FF#, 16#FF01FF0000000101#,
      16#FF01FF000001FF00#, 16#FF01FF00000100FF#, 16#FF01FF0000010000#, 16#FF01FF0000010001#,
      16#FF01FF0001FF0000#, 16#FF01FF000100FFFF#, 16#FF01FF0001000001#, 16#FF01FF0001000100#,
      16#FF01FF0001010000#, 16#FF01FF01FFFFFF00#, 16#FF01FF01FFFF01FF#, 16#FF01FF01FFFF0101#,
      16#FF01FF01FF00FF00#, 16#FF01FF01FF000000#, 16#FF01FF01FF01FFFF#, 16#FF01FF01FF01FF01#,
      16#FF01FF01FF0101FF#, 16#FF01FF01FF010101#, 16#FF01FF0100FF0000#, 16#FF01FF010000FF00#,
      16#FF01FF0100000001#, 16#FF01FF0100000100#, 16#FF01FF0100010000#, 16#FF01FF0101FFFF00#,
      16#FF01FF0101FF01FF#, 16#FF01FF0101FF0101#, 16#FF01FF010100FF00#, 16#FF01FF0101000000#,
      16#FF01FF010101FFFF#, 16#FF01FF010101FF01#, 16#FF01FF01010101FF#, 16#FF01FF0101010101#,
      16#FF0100FFFFFF0000#, 16#FF0100FFFF0000FF#, 16#FF0100FFFF000001#, 16#FF0100FFFF000100#,
      16#FF0100FFFF010000#, 16#FF0100FF00FF00FF#, 16#FF0100FF00FF0000#, 16#FF0100FF00FF0001#,
      16#FF0100FF00FF0100#, 16#FF0100FF0000FF01#, 16#FF0100FF00000000#, 16#FF0100FF000001FF#,
      16#FF0100FF00000101#, 16#FF0100FF00010001#, 16#FF0100FF01FF0000#, 16#FF0100FF0100FF00#,
      16#FF0100FF010000FF#, 16#FF0100FF01000100#, 16#FF0100FF0101FF00#, 16#FF0100FF01010000#,
      16#FF010000FFFF0100#, 16#FF010000FF000000#, 16#FF010000FF01FF00#, 16#FF010000FF010100#,
      16#FF01000000FFFFFF#, 16#FF01000000FF0000#, 16#FF01000000FF01FF#, 16#FF0100000000FF00#,
      16#FF010000000000FF#, 16#FF01000000000000#, 16#FF01000000000100#, 16#FF0100000001FF01#,
      16#FF01000000010000#, 16#FF010000000101FF#, 16#FF01000001FF0100#, 16#FF0100000100FFFF#,
      16#FF010000010000FF#, 16#FF01000001000000#, 16#FF010000010001FF#, 16#FF01000001000101#,
      16#FF0100000101FF00#, 16#FF010000010100FF#, 16#FF01000001010001#, 16#FF01000001010100#,
      16#FF010001FFFF0000#, 16#FF010001FF00FFFF#, 16#FF010001FF00FF01#, 16#FF010001FF000100#,
      16#FF010001FF010000#, 16#FF01000100FFFF00#, 16#FF01000100FF0100#, 16#FF01000100000000#,
      16#FF0100010001FFFF#, 16#FF0100010001FF00#, 16#FF01000100010100#, 16#FF01000101FF00FF#,
      16#FF01000101FF0001#, 16#FF0100010100FFFF#, 16#FF01000101000101#, 16#FF0101FFFFFFFFFF#,
      16#FF0101FFFFFFFF01#, 16#FF0101FFFFFF01FF#, 16#FF0101FFFFFF0101#, 16#FF0101FFFF000000#,
      16#FF0101FFFF01FFFF#, 16#FF0101FFFF01FF01#, 16#FF0101FFFF0101FF#, 16#FF0101FFFF010101#,
      16#FF0101FF00FF0000#, 16#FF0101FF0000FF00#, 16#FF0101FF000000FF#, 16#FF0101FF00010000#,
      16#FF0101FF01FFFFFF#, 16#FF0101FF01FFFF01#, 16#FF0101FF01FF01FF#, 16#FF0101FF01FF0101#,
      16#FF0101FF0101FFFF#, 16#FF0101FF0101FF01#, 16#FF0101FF010101FF#, 16#FF0101FF01010101#,
      16#FF010100FFFF0100#, 16#FF010100FF00FF00#, 16#FF010100FF0000FF#, 16#FF010100FF000100#,
      16#FF010100FF010000#, 16#FF01010000FF0001#, 16#FF01010000FF0100#, 16#FF0101000000FF01#,
      16#FF01010000000000#, 16#FF0101000001FF00#, 16#FF010100000100FF#, 16#FF01010000010001#,
      16#FF01010000010100#, 16#FF01010001FF0000#, 16#FF0101000100FFFF#, 16#FF01010001000001#,
      16#FF01010001000100#, 16#FF010100010100FF#, 16#FF01010001010000#, 16#FF010101FFFFFFFF#,
      16#FF010101FFFFFF01#, 16#FF010101FFFF01FF#, 16#FF010101FFFF0101#, 16#FF010101FF01FFFF#,
      16#FF010101FF01FF01#, 16#FF010101FF0101FF#, 16#FF010101FF010101#, 16#FF01010100FF0000#,
      16#FF0101010000FF00#, 16#FF01010100000001#, 16#FF01010100000100#, 16#FF01010100010000#,
      16#FF01010101FFFFFF#, 16#FF01010101FFFF01#, 16#FF01010101FF01FF#, 16#FF01010101FF0101#,
      16#FF01010101000000#, 16#FF0101010101FFFF#, 16#FF0101010101FF01#, 16#FF010101010101FF#,
      16#FF01010101010101#, 16#00FFFFFFFFFF0000#, 16#00FFFFFFFF00FF00#, 16#00FFFFFFFF000001#,
      16#00FFFFFFFF010000#, 16#00FFFFFF00FF0100#, 16#00FFFFFF0000FF01#, 16#00FFFFFF00000000#,
      16#00FFFFFF000001FF#, 16#00FFFFFF00000101#, 16#00FFFFFF0001FF00#, 16#00FFFFFF000100FF#,
      16#00FFFFFF00010001#, 16#00FFFFFF010000FF#, 16#00FFFFFF01000100#, 16#00FFFFFF0101FF00#,
      16#00FFFFFF01010001#, 16#00FFFF00FFFFFFFF#, 16#00FFFF00FFFFFF00#, 16#00FFFF00FFFF00FF#,
      16#00FFFF00FFFF0001#, 16#00FFFF00FFFF0100#, 16#00FFFF00FF00FF01#, 16#00FFFF00FF000000#,
      16#00FFFF00FF000001#, 16#00FFFF00FF0001FF#, 16#00FFFF00FF000101#, 16#00FFFF00FF01FF00#,
      16#00FFFF00FF010001#, 16#00FFFF00FF010100#, 16#00FFFF0000FF0000#, 16#00FFFF0000FF01FF#,
      16#00FFFF0000FF0101#, 16#00FFFF000000FF00#, 16#00FFFF00000000FF#, 16#00FFFF0000000000#,
      16#00FFFF0000000001#, 16#00FFFF0000000100#, 16#00FFFF0000000101#, 16#00FFFF0000010000#,
      16#00FFFF00000101FF#, 16#00FFFF0000010101#, 16#00FFFF0001FFFF00#, 16#00FFFF0001FF00FF#,
      16#00FFFF0001FF0001#, 16#00FFFF000100FFFF#, 16#00FFFF000100FF01#, 16#00FFFF0001000000#,
      16#00FFFF000101FFFF#, 16#00FFFF000101FF00#, 16#00FFFF000101FF01#, 16#00FFFF01FFFF0000#,
      16#00FFFF01FF00FF00#, 16#00FFFF01FF0000FF#, 16#00FFFF01FF000001#, 16#00FFFF01FF010000#,
      16#00FFFF0100FFFF00#, 16#00FFFF010000FF01#, 16#00FFFF0100000000#, 16#00FFFF0100000101#,
      16#00FFFF01000100FF#, 16#00FFFF0100010100#, 16#00FFFF0101FF0100#, 16#00FFFF01010000FF#,
      16#00FFFF0101010000#, 16#00FF00FFFFFFFF00#, 16#00FF00FFFF000000#, 16#00FF00FFFF000100#,
      16#00FF00FFFF010100#, 16#00FF00FF00FF0000#, 16#00FF00FF00FF01FF#, 16#00FF00FF00FF0101#,
      16#00FF00FF0000FF00#, 16#00FF00FF000000FF#, 16#00FF00FF00000000#, 16#00FF00FF00000001#,
      16#00FF00FF0001FF00#, 16#00FF00FF0001FF01#, 16#00FF00FF00010000#, 16#00FF00FF000101FF#,
      16#00FF00FF00010101#, 16#00FF00FF01FFFF00#, 16#00FF00FF01FF0001#, 16#00FF00FF01FF0100#,
      16#00FF00FF0100FFFF#, 16#00FF00FF0100FF01#, 16#00FF00FF01000000#, 16#00FF00FF0101FFFF#,
      16#00FF00FF0101FF00#, 16#00FF00FF01010100#, 16#00FF0000FFFFFF00#, 16#00FF0000FFFFFF01#,
      16#00FF0000FFFF0000#, 16#00FF0000FFFF0101#, 16#00FF0000FF00FF00#, 16#00FF0000FF0000FF#,
      16#00FF0000FF000000#, 16#00FF0000FF000001#, 16#00FF0000FF000100#, 16#00FF0000FF01FFFF#,
      16#00FF0000FF010000#, 16#00FF0000FF010101#, 16#00FF000000FFFF00#, 16#00FF000000FF00FF#,
      16#00FF000000FF0000#, 16#00FF000000FF0001#, 16#00FF000000FF0100#, 16#00FF00000000FFFF#,
      16#00FF00000000FF00#, 16#00FF0000000000FF#, 16#00FF000000000000#, 16#00FF000000000001#,
      16#00FF0000000001FF#, 16#00FF000000000100#, 16#00FF00000001FF00#, 16#00FF0000000100FF#,
      16#00FF000000010000#, 16#00FF000000010001#, 16#00FF000000010100#, 16#00FF000001FFFF01#,
      16#00FF000001FF00FF#, 16#00FF000001FF0000#, 16#00FF000001FF01FF#, 16#00FF00000100FF00#,
      16#00FF0000010000FF#, 16#00FF000001000000#, 16#00FF000001000001#, 16#00FF000001000100#,
      16#00FF000001000101#, 16#00FF000001010000#, 16#00FF0000010101FF#, 16#00FF000001010101#,
      16#00FF0001FFFFFF00#, 16#00FF0001FFFF0000#, 16#00FF0001FFFF0100#, 16#00FF0001FF0000FF#,
      16#00FF0001FF000000#, 16#00FF0001FF0001FF#, 16#00FF0001FF000101#, 16#00FF0001FF01FF00#,
      16#00FF0001FF0100FF#, 16#00FF0001FF010100#, 16#00FF000100FFFFFF#, 16#00FF000100FFFF01#,
      16#00FF000100FF0000#, 16#00FF000100FF01FF#, 16#00FF00010000FFFF#, 16#00FF00010000FF00#,
      16#00FF00010000FF01#, 16#00FF000100000000#, 16#00FF000100000001#, 16#00FF000100000100#,
      16#00FF00010001FF01#, 16#00FF000100010000#, 16#00FF0001000101FF#, 16#00FF000101FFFF00#,
      16#00FF000101FF0000#, 16#00FF000101FF0101#, 16#00FF0001010000FF#, 16#00FF000101000000#,
      16#00FF00010101FF00#, 16#00FF0001010100FF#, 16#00FF000101010001#, 16#00FF01FFFFFF0000#,
      16#00FF01FFFF00FF00#, 16#00FF01FFFF000000#, 16#00FF01FFFF000101#, 16#00FF01FFFF010000#,
      16#00FF01FF00FFFF01#, 16#00FF01FF00FF0100#, 16#00FF01FF0000FFFF#, 16#00FF01FF00000000#,
      16#00FF01FF000001FF#, 16#00FF01FF0001FF00#, 16#00FF01FF000100FF#, 16#00FF01FF00010001#,
      16#00FF01FF00010100#, 16#00FF01FF01FF0000#, 16#00FF01FF0100FF00#, 16#00FF01FF010000FF#,
      16#00FF01FF01000001#, 16#00FF01FF01000100#, 16#00FF01FF01010000#, 16#00FF0100FFFFFF00#,
      16#00FF0100FFFF0000#, 16#00FF0100FFFF0001#, 16#00FF0100FFFF0101#, 16#00FF0100FF00FFFF#,
      16#00FF0100FF0000FF#, 16#00FF0100FF000000#, 16#00FF0100FF0001FF#, 16#00FF0100FF01FF00#,
      16#00FF0100FF0100FF#, 16#00FF0100FF010001#, 16#00FF010000FFFFFF#, 16#00FF010000FF0000#,
      16#00FF010000FF0101#, 16#00FF01000000FF00#, 16#00FF01000000FF01#, 16#00FF0100000000FF#,
      16#00FF010000000000#, 16#00FF010000000001#, 16#00FF010000000100#, 16#00FF01000001FFFF#,
      16#00FF01000001FF01#, 16#00FF010000010000#, 16#00FF010000010001#, 16#00FF010000010101#,
      16#00FF010001FF0001#, 16#00FF010001FF0100#, 16#00FF01000100FF01#, 16#00FF010001000000#,
      16#00FF010001000001#, 16#00FF0100010001FF#, 16#00FF01000101FF00#, 16#00FF0100010100FF#,
      16#00FF010001010001#, 16#00FF010001010100#, 16#00FF0101FF000001#, 16#00FF010100FF00FF#,
      16#00FF010100FF0001#, 16#00FF010100FF0100#, 16#00FF010100000000#, 16#00FF0101000001FF#,
      16#00FF010100000101#, 16#00FF0101000100FF#, 16#00FF010100010100#, 16#00FF0101010000FF#,
      16#00FF010101010000#, 16#0000FFFFFFFFFF00#, 16#0000FFFFFFFF00FF#, 16#0000FFFFFFFF0000#,
      16#0000FFFFFFFF0001#, 16#0000FFFFFFFF0100#, 16#0000FFFFFF00FF01#, 16#0000FFFFFF000000#,
      16#0000FFFFFF000101#, 16#0000FFFFFF01FF00#, 16#0000FFFFFF0100FF#, 16#0000FFFFFF010100#,
      16#0000FFFF00FFFFFF#, 16#0000FFFF00FF0000#, 16#0000FFFF00FF01FF#, 16#0000FFFF0000FF00#,
      16#0000FFFF000000FF#, 16#0000FFFF00000000#, 16#0000FFFF00000001#, 16#0000FFFF00000100#,
      16#0000FFFF00010000#, 16#0000FFFF000101FF#, 16#0000FFFF01FF0001#, 16#0000FFFF01FF0100#,
      16#0000FFFF01000000#, 16#0000FFFF010001FF#, 16#0000FFFF0101FFFF#, 16#0000FFFF0101FF00#,
      16#0000FFFF01010001#, 16#0000FFFF01010100#, 16#0000FF00FFFF0000#, 16#0000FF00FFFF01FF#,
      16#0000FF00FFFF0100#, 16#0000FF00FFFF0101#, 16#0000FF00FF00FF00#, 16#0000FF00FF0000FF#,
      16#0000FF00FF000000#, 16#0000FF00FF000001#, 16#0000FF00FF0001FF#, 16#0000FF00FF000100#,
      16#0000FF00FF01FFFF#, 16#0000FF00FF010000#, 16#0000FF00FF010001#, 16#0000FF00FF0101FF#,
      16#0000FF00FF010101#, 16#0000FF0000FFFF00#, 16#0000FF0000FF00FF#, 16#0000FF0000FF0000#,
      16#0000FF0000FF0001#, 16#0000FF0000FF0100#, 16#0000FF000000FFFF#, 16#0000FF000000FF00#,
      16#0000FF000000FF01#, 16#0000FF00000000FF#, 16#0000FF0000000000#, 16#0000FF0000000001#,
      16#0000FF00000001FF#, 16#0000FF0000000100#, 16#0000FF0000000101#, 16#0000FF000001FF00#,
      16#0000FF00000100FF#, 16#0000FF0000010000#, 16#0000FF0000010001#, 16#0000FF0000010100#,
      16#0000FF0001FFFF01#, 16#0000FF0001FF0000#, 16#0000FF000100FF00#, 16#0000FF00010000FF#,
      16#0000FF0001000000#, 16#0000FF0001000001#, 16#0000FF0001000100#, 16#0000FF000101FFFF#,
      16#0000FF0001010000#, 16#0000FF0001010101#, 16#0000FF01FFFFFF00#, 16#0000FF01FFFF0001#,
      16#0000FF01FF00FF01#, 16#0000FF01FF000000#, 16#0000FF01FF000101#, 16#0000FF01FF01FF00#,
      16#0000FF01FF0100FF#, 16#0000FF0100FFFF01#, 16#0000FF0100FF0000#, 16#0000FF0100FF0101#,
      16#0000FF010000FF00#, 16#0000FF01000000FF#, 16#0000FF0100000000#, 16#0000FF0100000001#,
      16#0000FF0100000100#, 16#0000FF010001FF01#, 16#0000FF0100010000#, 16#0000FF0101FF0000#,
      16#0000FF010100FFFF#, 16#0000FF010100FF01#, 16#0000FF0101000000#, 16#0000FF0101000100#,
      16#0000FF0101000101#, 16#0000FF01010100FF#, 16#000000FFFFFF00FF#, 16#000000FFFFFF0000#,
      16#000000FFFF00FF00#, 16#000000FFFF0000FF#, 16#000000FFFF000000#, 16#000000FFFF000001#,
      16#000000FFFF0001FF#, 16#000000FFFF000100#, 16#000000FFFF01FF00#, 16#000000FFFF010000#,
      16#000000FFFF0101FF#, 16#000000FFFF010101#, 16#000000FF00FFFF00#, 16#000000FF00FF00FF#,
      16#000000FF00FF0000#, 16#000000FF00FF0001#, 16#000000FF00FF0100#, 16#000000FF00FF0101#,
      16#000000FF0000FFFF#, 16#000000FF0000FF00#, 16#000000FF000000FF#, 16#000000FF00000000#,
      16#000000FF00000001#, 16#000000FF000001FF#, 16#000000FF00000100#, 16#000000FF00000101#,
      16#000000FF0001FF00#, 16#000000FF0001FF01#, 16#000000FF000100FF#, 16#000000FF00010000#,
      16#000000FF00010001#, 16#000000FF00010100#, 16#000000FF01FFFFFF#, 16#000000FF01FF01FF#,
      16#000000FF01FF0101#, 16#000000FF0100FF00#, 16#000000FF010000FF#, 16#000000FF01000000#,
      16#000000FF01000001#, 16#000000FF01000100#, 16#000000FF0101FF00#, 16#000000FF010100FF#,
      16#000000FF01010000#, 16#000000FF01010101#, 16#00000000FFFFFF00#, 16#00000000FFFFFF01#,
      16#00000000FFFF00FF#, 16#00000000FFFF0000#, 16#00000000FFFF0001#, 16#00000000FFFF0100#,
      16#00000000FF00FFFF#, 16#00000000FF00FF00#, 16#00000000FF00FF01#, 16#00000000FF0000FF#,
      16#00000000FF000000#, 16#00000000FF000001#, 16#00000000FF000100#, 16#00000000FF000101#,
      16#00000000FF01FF00#, 16#00000000FF0100FF#, 16#00000000FF010000#, 16#00000000FF010001#,
      16#00000000FF010100#, 16#0000000000FFFFFF#, 16#0000000000FFFF00#, 16#0000000000FFFF01#,
      16#0000000000FF00FF#, 16#0000000000FF0000#, 16#0000000000FF0001#, 16#0000000000FF01FF#,
      16#0000000000FF0100#, 16#000000000000FFFF#, 16#000000000000FF00#, 16#000000000000FF01#,
      16#00000000000000FF#, 16#0000000000000000#, 16#0000000000000001#, 16#00000000000001FF#,
      16#0000000000000100#, 16#0000000000000101#, 16#000000000001FFFF#, 16#000000000001FF00#,
      16#00000000000100FF#, 16#0000000000010000#, 16#0000000000010001#, 16#00000000000101FF#,
      16#0000000000010100#, 16#0000000000010101#, 16#0000000001FFFF00#, 16#0000000001FF00FF#,
      16#0000000001FF0000#, 16#0000000001FF0100#, 16#0000000001FF0101#, 16#000000000100FFFF#,
      16#000000000100FF00#, 16#00000000010000FF#, 16#0000000001000000#, 16#0000000001000001#,
      16#00000000010001FF#, 16#0000000001000100#, 16#000000000101FF00#, 16#00000000010100FF#,
      16#0000000001010000#, 16#0000000001010001#, 16#0000000001010100#, 16#00000001FFFFFFFF#,
      16#00000001FFFFFF00#, 16#00000001FFFFFF01#, 16#00000001FFFF00FF#, 16#00000001FFFF0001#,
      16#00000001FFFF01FF#, 16#00000001FFFF0100#, 16#00000001FF00FF00#, 16#00000001FF0000FF#,
      16#00000001FF000000#, 16#00000001FF0001FF#, 16#00000001FF000100#, 16#00000001FF01FFFF#,
      16#00000001FF01FF00#, 16#00000001FF01FF01#, 16#00000001FF0100FF#, 16#00000001FF010000#,
      16#00000001FF010001#, 16#00000001FF0101FF#, 16#00000001FF010100#, 16#0000000100FFFF00#,
      16#0000000100FF0000#, 16#0000000100FF0001#, 16#0000000100FF01FF#, 16#0000000100FF0100#,
      16#0000000100FF0101#, 16#000000010000FFFF#, 16#000000010000FF00#, 16#000000010000FF01#,
      16#00000001000000FF#, 16#0000000100000000#, 16#0000000100000001#, 16#00000001000001FF#,
      16#0000000100000100#, 16#0000000100000101#, 16#000000010001FF00#, 16#00000001000100FF#,
      16#0000000100010000#, 16#0000000100010100#, 16#0000000101FFFF01#, 16#0000000101FF0000#,
      16#0000000101FF0001#, 16#0000000101FF01FF#, 16#0000000101FF0100#, 16#0000000101FF0101#,
      16#000000010100FF00#, 16#0000000101000000#, 16#0000000101000101#, 16#000000010101FF01#,
      16#0000000101010000#, 16#0000000101010001#, 16#00000001010101FF#, 16#0000000101010100#,
      16#000001FFFFFF00FF#, 16#000001FFFFFF0000#, 16#000001FFFFFF0001#, 16#000001FFFFFF0100#,
      16#000001FFFF00FFFF#, 16#000001FFFF000000#, 16#000001FFFF0001FF#, 16#000001FFFF01FF00#,
      16#000001FFFF010101#, 16#000001FF00FF0000#, 16#000001FF00FF01FF#, 16#000001FF00FF0101#,
      16#000001FF0000FF00#, 16#000001FF000000FF#, 16#000001FF00000000#, 16#000001FF00000001#,
      16#000001FF000001FF#, 16#000001FF00000100#, 16#000001FF0001FFFF#, 16#000001FF0001FF01#,
      16#000001FF000100FF#, 16#000001FF00010000#, 16#000001FF01FFFF01#, 16#000001FF01FF0100#,
      16#000001FF0100FFFF#, 16#000001FF0100FF01#, 16#000001FF01000000#, 16#000001FF010001FF#,
      16#000001FF0101FF00#, 16#000001FF01010100#, 16#00000100FFFFFF00#, 16#00000100FFFFFF01#,
      16#00000100FFFF0000#, 16#00000100FFFF0101#, 16#00000100FF00FF00#, 16#00000100FF0000FF#,
      16#00000100FF000000#, 16#00000100FF000001#, 16#00000100FF000100#, 16#00000100FF010000#,
      16#0000010000FFFF00#, 16#0000010000FF00FF#, 16#0000010000FF0000#, 16#0000010000FF0001#,
      16#0000010000FF0100#, 16#000001000000FFFF#, 16#000001000000FF00#, 16#000001000000FF01#,
      16#00000100000000FF#, 16#0000010000000000#, 16#0000010000000001#, 16#00000100000001FF#,
      16#0000010000000100#, 16#0000010000000101#, 16#000001000001FF00#, 16#00000100000100FF#,
      16#0000010000010000#, 16#0000010000010001#, 16#0000010000010100#, 16#0000010001FFFF00#,
      16#0000010001FF0000#, 16#0000010001FF0100#, 16#000001000100FF00#, 16#00000100010000FF#,
      16#0000010001000000#, 16#0000010001000001#, 16#00000100010001FF#, 16#0000010001000100#,
      16#0000010001010000#, 16#00000101FFFF00FF#, 16#00000101FFFF01FF#, 16#00000101FF000000#,
      16#00000101FF000101#, 16#00000101FF01FFFF#, 16#00000101FF010000#, 16#00000101FF010001#,
      16#00000101FF010100#, 16#0000010100FF0000#, 16#0000010100FF01FF#, 16#0000010100FF0100#,
      16#000001010000FF00#, 16#0000010100000000#, 16#0000010100000001#, 16#00000101000001FF#,
      16#0000010100000100#, 16#000001010001FF01#, 16#0000010100010000#, 16#00000101000101FF#,
      16#0000010100010101#, 16#0000010101FFFF00#, 16#0000010101FF0101#, 16#000001010100FF01#,
      16#0000010101000000#, 16#0000010101000001#, 16#00000101010001FF#, 16#0000010101000101#,
      16#000001010101FF00#, 16#0001FFFFFFFF0000#, 16#0001FFFFFF0000FF#, 16#0001FFFFFF000001#,
      16#0001FFFFFF000100#, 16#0001FFFFFF010000#, 16#0001FFFF00FF00FF#, 16#0001FFFF0000FFFF#,
      16#0001FFFF00000000#, 16#0001FFFF00000001#, 16#0001FFFF000001FF#, 16#0001FFFF00000101#,
      16#0001FFFF0001FF00#, 16#0001FFFF000100FF#, 16#0001FFFF00010001#, 16#0001FFFF00010100#,
      16#0001FFFF01FFFF00#, 16#0001FFFF01000001#, 16#0001FFFF01010000#, 16#0001FF00FFFFFF00#,
      16#0001FF00FFFF00FF#, 16#0001FF00FFFF0001#, 16#0001FF00FFFF0100#, 16#0001FF00FF00FF01#,
      16#0001FF00FF000000#, 16#0001FF00FF01FF00#, 16#0001FF00FF01FF01#, 16#0001FF00FF010001#,
      16#0001FF00FF010100#, 16#0001FF0000FF0000#, 16#0001FF0000FF0100#, 16#0001FF000000FF00#,
      16#0001FF0000000000#, 16#0001FF0000000001#, 16#0001FF0000000100#, 16#0001FF0000010000#,
      16#0001FF0000010001#, 16#0001FF0000010101#, 16#0001FF0001FF00FF#, 16#0001FF0001FF0101#,
      16#0001FF000100FF01#, 16#0001FF0001000000#, 16#0001FF000101FF00#, 16#0001FF0001010001#,
      16#0001FF0001010100#, 16#0001FF01FF00FF00#, 16#0001FF01FF000001#, 16#0001FF01FF000100#,
      16#0001FF0100FFFFFF#, 16#0001FF0100FFFF00#, 16#0001FF0100FF0001#, 16#0001FF0100000000#,
      16#0001FF0100000001#, 16#0001FF01000001FF#, 16#0001FF010001FFFF#, 16#0001FF0101FF0000#,
      16#0001FF010100FF00#, 16#0001FF0101000001#, 16#0001FF0101010000#, 16#000100FFFF00FF00#,
      16#000100FFFF00FF01#, 16#000100FFFF000000#, 16#000100FFFF000001#, 16#000100FFFF000101#,
      16#000100FFFF01FF00#, 16#000100FFFF010001#, 16#000100FFFF010100#, 16#000100FF00FFFFFF#,
      16#000100FF00FFFF01#, 16#000100FF00FF0000#, 16#000100FF00FF01FF#, 16#000100FF00FF0101#,
      16#000100FF0000FF00#, 16#000100FF000000FF#, 16#000100FF00000000#, 16#000100FF00000001#,
      16#000100FF00000100#, 16#000100FF00000101#, 16#000100FF0001FFFF#, 16#000100FF0001FF01#,
      16#000100FF00010000#, 16#000100FF01FF00FF#, 16#000100FF01FF0000#, 16#000100FF01FF0100#,
      16#000100FF0100FFFF#, 16#000100FF0100FF01#, 16#000100FF010000FF#, 16#000100FF01000000#,
      16#000100FF01000001#, 16#000100FF010001FF#, 16#000100FF01000101#, 16#000100FF0101FF00#,
      16#000100FF010100FF#, 16#000100FF01010100#, 16#00010000FFFF0000#, 16#00010000FFFF01FF#,
      16#00010000FFFF0101#, 16#00010000FF00FF00#, 16#00010000FF000000#, 16#00010000FF000001#,
      16#00010000FF000100#, 16#0001000000FF00FF#, 16#0001000000FF0000#, 16#0001000000FF0001#,
      16#0001000000FF0100#, 16#000100000000FFFF#, 16#000100000000FF00#, 16#00010000000000FF#,
      16#0001000000000000#, 16#0001000000000001#, 16#0001000000000100#, 16#000100000001FF00#,
      16#00010000000100FF#, 16#0001000000010000#, 16#0001000000010001#, 16#0001000000010100#,
      16#0001000001FF0001#, 16#0001000001FF0100#, 16#0001000001FF0101#, 16#000100000100FF00#,
      16#0001000001000000#, 16#0001000001000001#, 16#0001000001000100#, 16#0001000001000101#,
      16#000100000101FF01#, 16#0001000001010000#, 16#0001000001010001#, 16#00010000010101FF#,
      16#00010001FFFFFF01#, 16#00010001FFFF0100#, 16#00010001FF000000#, 16#00010001FF01FFFF#,
      16#00010001FF010001#, 16#00010001FF0101FF#, 16#00010001FF010100#, 16#0001000100FFFFFF#,
      16#0001000100FF0000#, 16#0001000100FF01FF#, 16#0001000100FF0101#, 16#000100010000FF00#,
      16#00010001000000FF#, 16#0001000100000000#, 16#0001000100000001#, 16#00010001000001FF#,
      16#0001000100000101#, 16#000100010001FFFF#, 16#0001000100010000#, 16#00010001000101FF#,
      16#0001000101FFFFFF#, 16#0001000101FFFF01#, 16#0001000101FF0000#, 16#0001000101FF0101#,
      16#00010001010000FF#, 16#0001000101000001#, 16#00010001010001FF#, 16#0001000101000100#,
      16#000100010101FFFF#, 16#00010001010100FF#, 16#0001000101010001#, 16#0001000101010101#,
      16#000101FFFF000001#, 16#000101FFFF000100#, 16#000101FFFF010000#, 16#000101FF00FFFF00#,
      16#000101FF0000FF01#, 16#000101FF00000000#, 16#000101FF00000101#, 16#000101FF0001FF00#,
      16#000101FF00010100#, 16#000101FF01FF0000#, 16#000101FF0100FF00#, 16#000101FF010001FF#,
      16#000101FF01010001#, 16#00010100FFFFFF00#, 16#00010100FFFF00FF#, 16#00010100FF00FFFF#,
      16#00010100FF000000#, 16#00010100FF01FF00#, 16#00010100FF0100FF#, 16#00010100FF010001#,
      16#00010100FF010100#, 16#0001010000FFFFFF#, 16#0001010000FFFF00#, 16#0001010000FF0000#,
      16#0001010000FF0001#, 16#0001010000FF01FF#, 16#000101000000FF00#, 16#00010100000000FF#,
      16#0001010000000000#, 16#0001010000000001#, 16#0001010000000100#, 16#000101000001FFFF#,
      16#0001010000010000#, 16#0001010000010101#, 16#0001010001FFFF01#, 16#0001010001FF00FF#,
      16#0001010001FF0101#, 16#0001010001000000#, 16#000101000101FF00#, 16#00010100010100FF#,
      16#0001010001010000#, 16#0001010001010100#, 16#00010101FF00FF00#, 16#00010101FF000001#,
      16#00010101FF0001FF#, 16#0001010100FFFF00#, 16#0001010100FF00FF#, 16#0001010100FF0100#,
      16#000101010000FFFF#, 16#0001010100000000#, 16#00010101000001FF#, 16#0001010100000101#,
      16#00010101000100FF#, 16#0001010100010000#, 16#0001010100010100#, 16#0001010101FF0001#,
      16#00010101010000FF#, 16#00010101010001FF#, 16#0001010101000101#, 16#0001010101010001#,
      16#01FFFFFFFFFFFFFF#, 16#01FFFFFFFFFFFF01#, 16#01FFFFFFFFFF01FF#, 16#01FFFFFFFFFF0101#,
      16#01FFFFFFFF01FFFF#, 16#01FFFFFFFF01FF01#, 16#01FFFFFFFF0101FF#, 16#01FFFFFFFF010101#,
      16#01FFFFFF00FF0000#, 16#01FFFFFF0000FFFF#, 16#01FFFFFF0000FF00#, 16#01FFFFFF000000FF#,
      16#01FFFFFF00000001#, 16#01FFFFFF00000100#, 16#01FFFFFF00010000#, 16#01FFFFFF01FFFFFF#,
      16#01FFFFFF01FFFF01#, 16#01FFFFFF01FF01FF#, 16#01FFFFFF01FF0101#, 16#01FFFFFF01000000#,
      16#01FFFFFF0101FFFF#, 16#01FFFFFF0101FF01#, 16#01FFFFFF010101FF#, 16#01FFFFFF01010101#,
      16#01FFFF00FFFF0000#, 16#01FFFF00FF00FF00#, 16#01FFFF00FF0000FF#, 16#01FFFF00FF000001#,
      16#01FFFF00FF000100#, 16#01FFFF00FF010000#, 16#01FFFF0000FFFF00#, 16#01FFFF0000FF00FF#,
      16#01FFFF0000FF0100#, 16#01FFFF000000FFFF#, 16#01FFFF000000FF01#, 16#01FFFF0000000000#,
      16#01FFFF0000000001#, 16#01FFFF00000001FF#, 16#01FFFF0000000100#, 16#01FFFF00000100FF#,
      16#01FFFF0000010001#, 16#01FFFF0000010100#, 16#01FFFF0001FF0000#, 16#01FFFF0001FF0100#,
      16#01FFFF00010000FF#, 16#01FFFF0001000001#, 16#01FFFF0001000100#, 16#01FFFF0001010000#,
      16#01FFFF01FFFFFFFF#, 16#01FFFF01FFFFFF01#, 16#01FFFF01FFFF01FF#, 16#01FFFF01FFFF0101#,
      16#01FFFF01FF000000#, 16#01FFFF01FF01FFFF#, 16#01FFFF01FF01FF01#, 16#01FFFF01FF0101FF#,
      16#01FFFF01FF010101#, 16#01FFFF010000FF00#, 16#01FFFF01000000FF#, 16#01FFFF0100000100#,
      16#01FFFF0100010000#, 16#01FFFF0101FFFFFF#, 16#01FFFF0101FFFF01#, 16#01FFFF0101FF01FF#,
      16#01FFFF0101FF0101#, 16#01FFFF0101000000#, 16#01FFFF010101FFFF#, 16#01FFFF010101FF01#,
      16#01FFFF01010101FF#, 16#01FFFF0101010101#, 16#01FF00FFFF0000FF#, 16#01FF00FFFF000100#,
      16#01FF00FF00FFFF00#, 16#01FF00FF00FF00FF#, 16#01FF00FF0000FF00#, 16#01FF00FF00000000#,
      16#01FF00FF00000101#, 16#01FF00FF0001FF00#, 16#01FF00FF000100FF#, 16#01FF00FF00010100#,
      16#01FF00FF010000FF#, 16#01FF00FF01000100#, 16#01FF0000FFFFFF00#, 16#01FF0000FFFF0100#,
      16#01FF0000FF00FF01#, 16#01FF0000FF000000#, 16#01FF0000FF000101#, 16#01FF0000FF010001#,
      16#01FF0000FF010100#, 16#01FF000000FFFFFF#, 16#01FF000000FFFF00#, 16#01FF000000FF0000#,
      16#01FF000000FF01FF#, 16#01FF00000000FF00#, 16#01FF0000000000FF#, 16#01FF000000000000#,
      16#01FF000000000001#, 16#01FF000000000100#, 16#01FF000000000101#, 16#01FF000000010000#,
      16#01FF000000010001#, 16#01FF0000000101FF#, 16#01FF000000010101#, 16#01FF000001FFFF00#,
      16#01FF000001FF00FF#, 16#01FF000001FF0001#, 16#01FF000001FF0100#, 16#01FF00000100FFFF#,
      16#01FF00000100FF01#, 16#01FF000001000000#, 16#01FF0000010001FF#, 16#01FF000001010001#,
      16#01FF0001FF00FF00#, 16#01FF0001FF000001#, 16#01FF0001FF000100#, 16#01FF0001FF010000#,
      16#01FF000100FFFF00#, 16#01FF000100FF00FF#, 16#01FF000100FF0100#, 16#01FF000100FF0101#,
      16#01FF00010000FFFF#, 16#01FF000100000000#, 16#01FF000100000100#, 16#01FF000100000101#,
      16#01FF00010001FF00#, 16#01FF000100010001#, 16#01FF000100010101#, 16#01FF000101FF0000#,
      16#01FF00010100FF00#, 16#01FF000101000101#, 16#01FF0001010100FF#, 16#01FF01FFFFFFFFFF#,
      16#01FF01FFFFFFFF01#, 16#01FF01FFFFFF01FF#, 16#01FF01FFFFFF0101#, 16#01FF01FFFF000000#,
      16#01FF01FFFF01FFFF#, 16#01FF01FFFF01FF01#, 16#01FF01FFFF0101FF#, 16#01FF01FFFF010101#,
      16#01FF01FF00FFFF00#, 16#01FF01FF00FF0000#, 16#01FF01FF0000FF00#, 16#01FF01FF000000FF#,
      16#01FF01FF00000100#, 16#01FF01FF00010000#, 16#01FF01FF00010100#, 16#01FF01FF01FFFFFF#,
      16#01FF01FF01FFFF01#, 16#01FF01FF01FF01FF#, 16#01FF01FF01FF0101#, 16#01FF01FF01000000#,
      16#01FF01FF0101FFFF#, 16#01FF01FF0101FF01#, 16#01FF01FF010101FF#, 16#01FF01FF01010101#,
      16#01FF0100FFFF0000#, 16#01FF0100FFFF0001#, 16#01FF0100FF00FF00#, 16#01FF0100FF0000FF#,
      16#01FF0100FF000001#, 16#01FF0100FF010000#, 16#01FF010000FFFF00#, 16#01FF010000FF00FF#,
      16#01FF010000FF0001#, 16#01FF010000FF0100#, 16#01FF01000000FFFF#, 16#01FF01000000FF01#,
      16#01FF010000000000#, 16#01FF010000000101#, 16#01FF01000001FF00#, 16#01FF0100000100FF#,
      16#01FF010001FF0000#, 16#01FF010001000001#, 16#01FF010001000100#, 16#01FF010001010000#,
      16#01FF0101FFFFFFFF#, 16#01FF0101FFFFFF01#, 16#01FF0101FFFF01FF#, 16#01FF0101FFFF0101#,
      16#01FF0101FF000000#, 16#01FF0101FF01FFFF#, 16#01FF0101FF01FF01#, 16#01FF0101FF0101FF#,
      16#01FF0101FF010101#, 16#01FF010100FF0000#, 16#01FF01010000FF00#, 16#01FF0101000000FF#,
      16#01FF010100000001#, 16#01FF010101FFFFFF#, 16#01FF010101FFFF01#, 16#01FF010101FF01FF#,
      16#01FF010101FF0101#, 16#01FF010101000000#, 16#01FF01010101FFFF#, 16#01FF01010101FF01#,
      16#01FF0101010101FF#, 16#01FF010101010101#, 16#0100FFFFFFFF0000#, 16#0100FFFFFF00FF00#,
      16#0100FFFFFF000001#, 16#0100FFFFFF0001FF#, 16#0100FFFFFF000100#, 16#0100FFFFFF010000#,
      16#0100FFFF00FFFF00#, 16#0100FFFF00FF0001#, 16#0100FFFF00FF0100#, 16#0100FFFF00000000#,
      16#0100FFFF000001FF#, 16#0100FFFF00000101#, 16#0100FFFF00010100#, 16#0100FFFF00010101#,
      16#0100FFFF01FF0000#, 16#0100FFFF0100FF00#, 16#0100FFFF010000FF#, 16#0100FFFF01000001#,
      16#0100FFFF01000100#, 16#0100FFFF01010000#, 16#0100FF00FFFFFF00#, 16#0100FF00FFFF00FF#,
      16#0100FF00FFFF0001#, 16#0100FF00FFFF0100#, 16#0100FF00FF00FFFF#, 16#0100FF00FF000000#,
      16#0100FF00FF0001FF#, 16#0100FF00FF000101#, 16#0100FF00FF01FF00#, 16#0100FF00FF0100FF#,
      16#0100FF00FF010001#, 16#0100FF00FF010100#, 16#0100FF0000FFFFFF#, 16#0100FF0000FF0000#,
      16#0100FF000000FFFF#, 16#0100FF000000FF00#, 16#0100FF00000000FF#, 16#0100FF0000000000#,
      16#0100FF0000000001#, 16#0100FF0000000100#, 16#0100FF000001FF01#, 16#0100FF0000010000#,
      16#0100FF0001FF00FF#, 16#0100FF0001FF0001#, 16#0100FF000100FF01#, 16#0100FF0001000000#,
      16#0100FF00010001FF#, 16#0100FF000101FF00#, 16#0100FF00010100FF#, 16#0100FF0001010001#,
      16#0100FF0001010100#, 16#0100FF01FFFF0000#, 16#0100FF01FF00FF00#, 16#0100FF01FF0000FF#,
      16#0100FF01FF000100#, 16#0100FF01FF010000#, 16#0100FF0100FF00FF#, 16#0100FF0100FF0001#,
      16#0100FF0100FF0100#, 16#0100FF010000FFFF#, 16#0100FF010000FF01#, 16#0100FF0100000000#,
      16#0100FF01000001FF#, 16#0100FF0100010001#, 16#0100FF0100010100#, 16#0100FF0101FF0000#,
      16#0100FF01010000FF#, 16#0100FF0101000001#, 16#0100FF0101010100#, 16#010000FFFFFFFF00#,
      16#010000FFFFFF00FF#, 16#010000FFFFFF0001#, 16#010000FFFF00FFFF#, 16#010000FFFF000000#,
      16#010000FFFF0001FF#, 16#010000FFFF010001#, 16#010000FF00FFFFFF#, 16#010000FF00FF0101#,
      16#010000FF0000FF00#, 16#010000FF000000FF#, 16#010000FF00000000#, 16#010000FF00000001#,
      16#010000FF000001FF#, 16#010000FF00000100#, 16#010000FF0001FFFF#, 16#010000FF0001FF00#,
      16#010000FF0001FF01#, 16#010000FF00010000#, 16#010000FF01FF00FF#, 16#010000FF01FF0001#,
      16#010000FF0100FF01#, 16#010000FF010000FF#, 16#010000FF01000000#, 16#010000FF010001FF#,
      16#010000FF0101FF00#, 16#010000FF01010100#, 16#01000000FFFFFFFF#, 16#01000000FFFF0000#,
      16#01000000FFFF01FF#, 16#01000000FFFF0101#, 16#01000000FF00FFFF#, 16#01000000FF00FF00#,
      16#01000000FF0000FF#, 16#01000000FF000000#, 16#01000000FF000001#, 16#01000000FF000100#,
      16#01000000FF01FF00#, 16#01000000FF010000#, 16#01000000FF010100#, 16#01000000FF010101#,
      16#0100000000FFFF00#, 16#0100000000FF00FF#, 16#0100000000FF0000#, 16#0100000000FF0001#,
      16#0100000000FF0100#, 16#010000000000FFFF#, 16#010000000000FF00#, 16#010000000000FF01#,
      16#01000000000000FF#, 16#0100000000000000#, 16#0100000000000001#, 16#01000000000001FF#,
      16#0100000000000100#, 16#0100000000000101#, 16#010000000001FF00#, 16#01000000000100FF#,
      16#0100000000010000#, 16#0100000000010001#, 16#0100000000010100#, 16#0100000001FFFF00#,
      16#0100000001FF0000#, 16#0100000001FF01FF#, 16#010000000100FF00#, 16#010000000100FF01#,
      16#01000000010000FF#, 16#0100000001000000#, 16#0100000001000001#, 16#0100000001000100#,
      16#0100000001000101#, 16#010000000101FFFF#, 16#010000000101FF01#, 16#0100000001010000#,
      16#01000000010101FF#, 16#0100000001010101#, 16#01000001FFFFFF00#, 16#01000001FFFF00FF#,
      16#01000001FF00FFFF#, 16#01000001FF000000#, 16#01000001FF000100#, 16#01000001FF01FFFF#,
      16#01000001FF010001#, 16#01000001FF010100#, 16#0100000100FF0000#, 16#0100000100FF01FF#,
      16#0100000100FF0100#, 16#010000010000FF00#, 16#010000010000FF01#, 16#0100000100000000#,
      16#0100000100000001#, 16#0100000100000100#, 16#0100000100010000#, 16#01000001000101FF#,
      16#0100000101FFFF01#, 16#0100000101FF00FF#, 16#0100000101FF0100#, 16#0100000101FF0101#,
      16#010000010100FF01#, 16#01000001010000FF#, 16#0100000101000000#, 16#01000001010100FF#,
      16#0100000101010001#, 16#0100000101010100#, 16#010001FFFFFF0000#, 16#010001FFFF000001#,
      16#010001FFFF000100#, 16#010001FFFF010000#, 16#010001FF00FFFF00#, 16#010001FF00FF0001#,
      16#010001FF0000FFFF#, 16#010001FF0000FF01#, 16#010001FF00000000#, 16#010001FF00000001#,
      16#010001FF00000101#, 16#010001FF000100FF#, 16#010001FF00010000#, 16#010001FF01FF0000#,
      16#010001FF0100FF00#, 16#010001FF01000001#, 16#010001FF01000100#, 16#010001FF01010000#,
      16#01000100FFFF00FF#, 16#01000100FFFF0001#, 16#01000100FFFF0100#, 16#01000100FF00FFFF#,
      16#01000100FF00FF01#, 16#01000100FF000000#, 16#01000100FF0001FF#, 16#01000100FF000101#,
      16#01000100FF01FFFF#, 16#01000100FF01FF00#, 16#01000100FF0100FF#, 16#01000100FF010001#,
      16#0100010000FFFFFF#, 16#0100010000FFFF01#, 16#0100010000FF0000#, 16#0100010000FF01FF#,
      16#0100010000FF0101#, 16#010001000000FF00#, 16#01000100000000FF#, 16#0100010000000000#,
      16#0100010000000001#, 16#0100010000000100#, 16#010001000001FF01#, 16#0100010000010000#,
      16#0100010000010001#, 16#0100010000010101#, 16#0100010001FFFF00#, 16#0100010001FF00FF#,
      16#010001000100FFFF#, 16#010001000100FF01#, 16#0100010001000000#, 16#0100010001000101#,
      16#010001000101FF00#, 16#0100010001010001#, 16#01000101FFFF0000#, 16#01000101FF000000#,
      16#01000101FF010000#, 16#0100010100FF00FF#, 16#0100010100FF0001#, 16#0100010100FF0100#,
      16#010001010000FFFF#, 16#0100010100000000#, 16#01000101000001FF#, 16#010001010001FF00#,
      16#0100010101FF0000#, 16#010001010100FF00#, 16#01000101010000FF#, 16#0100010101000000#,
      16#0100010101000001#, 16#0101FFFFFFFFFFFF#, 16#0101FFFFFFFFFF01#, 16#0101FFFFFFFF01FF#,
      16#0101FFFFFFFF0101#, 16#0101FFFFFF000000#, 16#0101FFFFFF01FFFF#, 16#0101FFFFFF01FF01#,
      16#0101FFFFFF0101FF#, 16#0101FFFFFF010101#, 16#0101FFFF00FF0000#, 16#0101FFFF0000FF00#,
      16#0101FFFF000000FF#, 16#0101FFFF00000001#, 16#0101FFFF00000100#, 16#0101FFFF01FFFFFF#,
      16#0101FFFF01FFFF01#, 16#0101FFFF01FF01FF#, 16#0101FFFF01FF0101#, 16#0101FFFF01000000#,
      16#0101FFFF0101FFFF#, 16#0101FFFF0101FF01#, 16#0101FFFF010101FF#, 16#0101FFFF01010101#,
      16#0101FF00FFFF0000#, 16#0101FF00FFFF0100#, 16#0101FF00FF00FF00#, 16#0101FF00FF0000FF#,
      16#0101FF00FF000001#, 16#0101FF00FF000100#, 16#0101FF00FF000101#, 16#0101FF0000FF0001#,
      16#0101FF0000FF0100#, 16#0101FF000000FF00#, 16#0101FF0000000000#, 16#0101FF00000001FF#,
      16#0101FF0000000101#, 16#0101FF000001FF00#, 16#0101FF00000100FF#, 16#0101FF0001FF0000#,
      16#0101FF000100FFFF#, 16#0101FF000100FF01#, 16#0101FF0001000001#, 16#0101FF0001000100#,
      16#0101FF01FFFFFF01#, 16#0101FF01FFFF01FF#, 16#0101FF01FFFF0101#, 16#0101FF01FF00FFFF#,
      16#0101FF01FF000100#, 16#0101FF01FF01FF01#, 16#0101FF01FF0101FF#, 16#0101FF01FF010101#,
      16#0101FF0100FF0000#, 16#0101FF010000FF00#, 16#0101FF0100000001#, 16#0101FF0100000100#,
      16#0101FF0100010000#, 16#0101FF0101FFFFFF#, 16#0101FF0101FFFF01#, 16#0101FF0101FF01FF#,
      16#0101FF0101FF0101#, 16#0101FF0101000000#, 16#0101FF010101FFFF#, 16#0101FF010101FF01#,
      16#0101FF01010101FF#, 16#0101FF0101010101#, 16#010100FFFF000100#, 16#010100FFFF010000#,
      16#010100FF00FFFF00#, 16#010100FF00FF00FF#, 16#010100FF0000FFFF#, 16#010100FF000000FF#,
      16#010100FF00000000#, 16#010100FF000001FF#, 16#010100FF00000101#, 16#010100FF0001FF00#,
      16#010100FF00010000#, 16#010100FF00010001#, 16#010100FF000101FF#, 16#010100FF00010100#,
      16#010100FF01FF0000#, 16#01010000FFFF0001#, 16#01010000FFFF0100#, 16#01010000FF00FFFF#,
      16#01010000FF00FF01#, 16#01010000FF000000#, 16#01010000FF0001FF#, 16#01010000FF010001#,
      16#01010000FF010100#, 16#0101000000FFFF01#, 16#0101000000FF0000#, 16#010100000000FF00#,
      16#01010000000000FF#, 16#0101000000000000#, 16#0101000000000001#, 16#0101000000000100#,
      16#0101000000010000#, 16#0101000000010101#, 16#0101000001FFFF00#, 16#0101000001FF00FF#,
      16#0101000001FF0000#, 16#0101000001FF0001#, 16#0101000001FF0100#, 16#010100000100FF01#,
      16#0101000001000000#, 16#01010000010001FF#, 16#01010001FFFF0000#, 16#01010001FF00FF00#,
      16#01010001FF000001#, 16#01010001FF000101#, 16#01010001FF01FF00#, 16#01010001FF010000#,
      16#0101000100FF00FF#, 16#0101000100FF0001#, 16#0101000100FF0101#, 16#010100010000FF01#,
      16#0101000100000000#, 16#0101000100000001#, 16#01010001000001FF#, 16#010100010001FFFF#,
      16#010100010001FF01#, 16#0101000101FF0001#, 16#010100010100FFFF#, 16#0101000101000000#,
      16#0101000101000001#, 16#0101000101000100#, 16#010100010101FF00#, 16#01010001010100FF#,
      16#0101000101010001#, 16#010101FFFFFFFFFF#, 16#010101FFFFFFFF01#, 16#010101FFFFFF01FF#,
      16#010101FFFFFF0101#, 16#010101FFFF01FFFF#, 16#010101FFFF01FF01#, 16#010101FFFF0101FF#,
      16#010101FFFF010101#, 16#010101FF0000FF00#, 16#010101FF000000FF#, 16#010101FF00000001#,
      16#010101FF00000100#, 16#010101FF01FFFFFF#, 16#010101FF01FFFF01#, 16#010101FF01FF01FF#,
      16#010101FF01FF0101#, 16#010101FF01000000#, 16#010101FF0101FFFF#, 16#010101FF0101FF01#,
      16#010101FF010101FF#, 16#010101FF01010101#, 16#01010100FFFF0000#, 16#01010100FF0000FF#,
      16#01010100FF000100#, 16#01010100FF01FF00#, 16#01010100FF010000#, 16#0101010000FFFF00#,
      16#010101000000FFFF#, 16#0101010000000000#, 16#0101010000000101#, 16#010101000001FF00#,
      16#0101010000010001#, 16#0101010000010100#, 16#010101000100FFFF#, 16#0101010001000001#,
      16#01010101FFFFFFFF#, 16#01010101FFFFFF01#, 16#01010101FFFF01FF#, 16#01010101FFFF0101#,
      16#01010101FF01FFFF#, 16#01010101FF01FF01#, 16#01010101FF0101FF#, 16#01010101FF010101#,
      16#010101010000FF00#, 16#01010101000000FF#, 16#0101010100000001#, 16#0101010101FFFFFF#,
      16#0101010101FFFF01#, 16#0101010101FF01FF#, 16#0101010101FF0101#, 16#0101010101000000#,
      16#010101010101FFFF#, 16#010101010101FF01#, 16#01010101010101FF#, 16#0101010101010101#
     ];

   function Encode_IQ3_S (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_32;

      --  Magnitude byte J of a grid entry, low byte first.
      function Grid_Byte (Index : Natural; J : Natural) return N.Real
      is (N.Real
            (Integer
               (Interfaces.Shift_Right (IQ3S_Grid (Index), 8 * J)
                and 16#FF#)));

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 110 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 110;

            --  What each sub-block would want on its own -- its largest
            --  magnitude spread over the fifteen steps a grid byte reaches --
            --  and the largest of those, which the block scale must cover at
            --  the coarsest of its sixteen sub-block steps.
            Wants   : array (0 .. 7) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;
            D       : N.Real;
         begin
            for Sub in 0 .. 7 loop
               declare
                  Top : N.Real := 0.0;
               begin
                  for K in 0 .. 31 loop
                     Top := N.Real'Max
                       (Top,
                        abs Values (First + N.Element_Count (Sub * 32 + K)));
                  end loop;
                  Wants (Sub) := Top / 15.0;
                  Largest := N.Real'Max (Largest, Wants (Sub));
               end;
            end loop;

            --  A sub-block scale is d times an odd number one to thirty-one.
            --  Setting d to a thirty-first of the largest want lets that
            --  sub-block reach it at nibble fifteen.
            D := (if Largest = 0.0 then 0.0 else Largest / 31.0);
            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (D)));

            for Sub in 0 .. 7 loop
               declare
                  Nibble : constant Integer :=
                    (if D = 0.0 then 0
                     else Integer'Max
                            (0, Integer'Min
                                  (15,
                                   Integer (N.Real'Rounding
                                     ((Wants (Sub) / D - 1.0) / 2.0)))));
                  DB       : constant N.Real := D * N.Real (1 + 2 * Nibble);
                  Scale_At : constant B.Byte_Count :=
                    At_Byte + 106 + B.Byte_Count (Sub / 2);
               begin
                  if Sub mod 2 = 0 then
                     Result (Scale_At) := Result (Scale_At)
                       or Interfaces.Unsigned_8 (Nibble);
                  else
                     Result (Scale_At) := Result (Scale_At)
                       or Interfaces.Shift_Left
                            (Interfaces.Unsigned_8 (Nibble), 4);
                  end if;

                  --  Eight groups of four. Group g takes qs byte g and high
                  --  bit g of the sub-block; the four values it stands for
                  --  sit at the L*8 offset, past four for the odd groups.
                  for G in 0 .. 7 loop
                     declare
                        L    : constant Natural := G / 2;
                        Base : constant N.Element_Count :=
                          First + N.Element_Count
                            (Sub * 32 + L * 8
                             + (if G mod 2 = 0 then 0 else 4));

                        Best_Index : Natural := 0;
                        Best_Cost  : N.Real := N.Real'Last;

                        Sign_At : constant B.Byte_Count :=
                          At_Byte + 74 + B.Byte_Count (Sub * 4 + L);
                     begin
                        --  The nearest grid entry to the four magnitudes,
                        --  each divided by the scale it will be multiplied by.
                        for Cand in IQ3S_Grid'Range loop
                           declare
                              Cost : N.Real := 0.0;
                           begin
                              for J in 0 .. 3 loop
                                 declare
                                    Target : constant N.Real :=
                                      (if DB = 0.0 then 0.0
                                       else abs Values
                                              (Base + N.Element_Count (J))
                                            / DB);
                                    Diff : constant N.Real :=
                                      Grid_Byte (Cand, J) - Target;
                                 begin
                                    Cost := Cost + Diff * Diff;
                                 end;
                              end loop;
                              if Cost < Best_Cost then
                                 Best_Cost := Cost;
                                 Best_Index := Cand;
                              end if;
                           end;
                        end loop;

                        Result (At_Byte + 2 + B.Byte_Count (Sub * 8 + G)) :=
                          Interfaces.Unsigned_8 (Best_Index mod 256);
                        if Best_Index >= 256 then
                           Result (At_Byte + 66 + B.Byte_Count (Sub)) :=
                             Result (At_Byte + 66 + B.Byte_Count (Sub))
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_8 (1), G);
                        end if;

                        --  The sign nibble: bits zero to three for an even
                        --  group, four to seven for an odd one.
                        for J in 0 .. 3 loop
                           if Values (Base + N.Element_Count (J)) < 0.0 then
                              Result (Sign_At) := Result (Sign_At)
                                or Interfaces.Shift_Left
                                     (Interfaces.Unsigned_8 (1),
                                      (if G mod 2 = 0 then J else J + 4));
                           end if;
                        end loop;
                     end;
                  end loop;
               end;
            end loop;
         end;
      end loop;

      return Result;
   end Encode_IQ3_S;

   function Encode_IQ2_XXS (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_32;

      function Grid_Byte (Index : Natural; J : Natural) return N.Real
      is (N.Real
            (Integer
               (Interfaces.Shift_Right (IQ2XXS_Grid (Index), 8 * J)
                and 16#FF#)));

      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 66 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count :=
              Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 66;

            --  The scale each sub-block wants -- its largest magnitude over
            --  the largest grid byte, forty-three -- and the largest of
            --  those, which the block scale reaches at sub-block step
            --  fifteen, where the multiplier (0.5 + 15) * 0.25 is 3.875.
            Wants   : array (0 .. 7) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;
            D       : N.Real;
         begin
            for Sub in 0 .. 7 loop
               declare
                  Top : N.Real := 0.0;
               begin
                  for K in 0 .. 31 loop
                     Top := N.Real'Max
                       (Top,
                        abs Values (First + N.Element_Count (Sub * 32 + K)));
                  end loop;
                  Wants (Sub) := Top / 43.0;
                  Largest := N.Real'Max (Largest, Wants (Sub));
               end;
            end loop;

            D := (if Largest = 0.0 then 0.0 else Largest / 3.875);
            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (D)));

            for Sub in 0 .. 7 loop
               declare
                  Scale4 : constant Integer :=
                    (if D = 0.0 then 0
                     else Integer'Max
                            (0, Integer'Min
                                  (15,
                                   Integer (N.Real'Rounding
                                     (4.0 * Wants (Sub) / D - 0.5)))));
                  DB   : constant N.Real := D * (0.5 + N.Real (Scale4)) * 0.25;
                  Word : Interfaces.Unsigned_32 :=
                    Interfaces.Shift_Left
                      (Interfaces.Unsigned_32 (Scale4), 28);
                  Sub_At : constant B.Byte_Count :=
                    At_Byte + 2 + B.Byte_Count (Sub) * 8;
               begin
                  for L in 0 .. 3 loop
                     declare
                        Base : constant N.Element_Count :=
                          First + N.Element_Count (Sub * 32 + L * 8);
                        Best_Grid  : Natural := 0;
                        Best_Cost  : N.Real := N.Real'Last;
                        Best_Sign  : Natural := 0;
                        Best_SCost : N.Real := N.Real'Last;
                     begin
                        for Cand in IQ2XXS_Grid'Range loop
                           declare
                              Cost : N.Real := 0.0;
                           begin
                              for J in 0 .. 7 loop
                                 declare
                                    Target : constant N.Real :=
                                      (if DB = 0.0 then 0.0
                                       else abs Values
                                              (Base + N.Element_Count (J))
                                            / DB);
                                    Diff : constant N.Real :=
                                      Grid_Byte (Cand, J) - Target;
                                 begin
                                    Cost := Cost + Diff * Diff;
                                 end;
                              end loop;
                              if Cost < Best_Cost then
                                 Best_Cost := Cost;
                                 Best_Grid := Cand;
                              end if;
                           end;
                        end loop;

                        for Cand in 0 .. 127 loop
                           declare
                              Pattern : constant Interfaces.Unsigned_8 :=
                                KSigns_IQ2XS (Cand);
                              Cost : N.Real := 0.0;
                           begin
                              for J in 0 .. 7 loop
                                 declare
                                    Negative : constant Boolean :=
                                      Values (Base + N.Element_Count (J))
                                        < 0.0;
                                    Set : constant Boolean :=
                                      (Pattern
                                       and Interfaces.Unsigned_8 (2 ** J))
                                        /= 0;
                                 begin
                                    if Negative /= Set then
                                       Cost := Cost
                                         + abs Values
                                             (Base + N.Element_Count (J));
                                    end if;
                                 end;
                              end loop;
                              if Cost < Best_SCost then
                                 Best_SCost := Cost;
                                 Best_Sign := Cand;
                              end if;
                           end;
                        end loop;

                        Result (Sub_At + B.Byte_Count (L)) :=
                          Interfaces.Unsigned_8 (Best_Grid);
                        Word := Word or Interfaces.Shift_Left
                          (Interfaces.Unsigned_32 (Best_Sign), 7 * L);
                     end;
                  end loop;

                  Result (Sub_At + 4) :=
                    Interfaces.Unsigned_8 (Word and 16#FF#);
                  Result (Sub_At + 5) :=
                    Interfaces.Unsigned_8
                      (Interfaces.Shift_Right (Word, 8) and 16#FF#);
                  Result (Sub_At + 6) :=
                    Interfaces.Unsigned_8
                      (Interfaces.Shift_Right (Word, 16) and 16#FF#);
                  Result (Sub_At + 7) :=
                    Interfaces.Unsigned_8
                      (Interfaces.Shift_Right (Word, 24) and 16#FF#);
               end;
            end loop;
         end;
      end loop;

      return Result;
   end Encode_IQ2_XXS;

   --  IQ2_XS: two four-bit sub-scales in a byte -- one for a sub-block's
   --  first two lanes, one for its last two -- and a lane's nine-bit grid
   --  index and seven-bit sign index share a sixteen-bit word.
   function Encode_IQ2_XS (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_16;
      function Grid_Byte (Index : Natural; J : Natural) return N.Real
      is (N.Real (Integer (Interfaces.Shift_Right (IQ2XS_Grid (Index), 8 * J)
                           and 16#FF#)));
      Max_Grid : N.Real := 1.0;
      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 74 - 1) :=
        [others => 0];
   begin
      for Cand in IQ2XS_Grid'Range loop
         for J in 0 .. 7 loop
            Max_Grid := N.Real'Max (Max_Grid, Grid_Byte (Cand, J));
         end loop;
      end loop;
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 74;
            Wants   : array (0 .. 15) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;
            D       : N.Real;
         begin
            for HS in 0 .. 15 loop
               declare
                  Top : N.Real := 0.0;
               begin
                  for K in 0 .. 15 loop
                     Top := N.Real'Max
                       (Top, abs Values (First + N.Element_Count (HS * 16 + K)));
                  end loop;
                  Wants (HS) := Top / Max_Grid;
                  Largest := N.Real'Max (Largest, Wants (HS));
               end;
            end loop;
            D := (if Largest = 0.0 then 0.0 else Largest / 3.875);
            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (D)));
            for Sub in 0 .. 7 loop
               declare
                  function Nib (Want : N.Real) return Integer
                  is (if D = 0.0 then 0
                      else Integer'Max (0, Integer'Min (15,
                             Integer (N.Real'Rounding (4.0 * Want / D - 0.5)))));
                  S0 : constant Integer := Nib (Wants (2 * Sub));
                  S1 : constant Integer := Nib (Wants (2 * Sub + 1));
                  DB0 : constant N.Real := D * (0.5 + N.Real (S0)) * 0.25;
                  DB1 : constant N.Real := D * (0.5 + N.Real (S1)) * 0.25;
                  Scale_At : constant B.Byte_Count :=
                    At_Byte + 66 + B.Byte_Count (Sub);
               begin
                  Result (Scale_At) :=
                    Interfaces.Unsigned_8 (S0)
                    or Interfaces.Shift_Left (Interfaces.Unsigned_8 (S1), 4);
                  for L in 0 .. 3 loop
                     declare
                        Base : constant N.Element_Count :=
                          First + N.Element_Count (Sub * 32 + L * 8);
                        DB : constant N.Real := (if L / 2 = 0 then DB0 else DB1);
                        Best_Grid : Natural := 0;
                        Best_Cost : N.Real := N.Real'Last;
                        Best_Sign : Natural := 0;
                        Best_SCost : N.Real := N.Real'Last;
                     begin
                        for Cand in IQ2XS_Grid'Range loop
                           declare
                              Cost : N.Real := 0.0;
                           begin
                              for J in 0 .. 7 loop
                                 declare
                                    Target : constant N.Real :=
                                      (if DB = 0.0 then 0.0
                                       else abs Values (Base + N.Element_Count (J))
                                            / DB);
                                    Diff : constant N.Real :=
                                      Grid_Byte (Cand, J) - Target;
                                 begin
                                    Cost := Cost + Diff * Diff;
                                 end;
                              end loop;
                              if Cost < Best_Cost then
                                 Best_Cost := Cost; Best_Grid := Cand;
                              end if;
                           end;
                        end loop;
                        for Cand in 0 .. 127 loop
                           declare
                              Pattern : constant Interfaces.Unsigned_8 :=
                                KSigns_IQ2XS (Cand);
                              Cost : N.Real := 0.0;
                           begin
                              for J in 0 .. 7 loop
                                 declare
                                    Negative : constant Boolean :=
                                      Values (Base + N.Element_Count (J)) < 0.0;
                                    Set : constant Boolean :=
                                      (Pattern and Interfaces.Unsigned_8 (2 ** J))
                                        /= 0;
                                 begin
                                    if Negative /= Set then
                                       Cost := Cost
                                         + abs Values (Base + N.Element_Count (J));
                                    end if;
                                 end;
                              end loop;
                              if Cost < Best_SCost then
                                 Best_SCost := Cost; Best_Sign := Cand;
                              end if;
                           end;
                        end loop;
                        declare
                           Word : constant Interfaces.Unsigned_16 :=
                             Interfaces.Unsigned_16 (Best_Grid)
                             or Interfaces.Shift_Left
                                  (Interfaces.Unsigned_16 (Best_Sign), 9);
                           WAt : constant B.Byte_Count :=
                             At_Byte + 2 + B.Byte_Count (2 * (4 * Sub + L));
                        begin
                           Result (WAt .. WAt + 1) := B.Put_U16 (Word);
                        end;
                     end;
                  end loop;
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Encode_IQ2_XS;

   --  IQ2_S: as IQ2_XS, but the grid is larger, its top two index bits come
   --  from a high-bit byte, and each lane carries a whole eight-bit sign.
   function Encode_IQ2_S (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_16;
      function Grid_Byte (Index : Natural; J : Natural) return N.Real
      is (N.Real (Integer (Interfaces.Shift_Right (IQ2S_Grid (Index), 8 * J)
                           and 16#FF#)));
      Max_Grid : N.Real := 1.0;
      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 82 - 1) :=
        [others => 0];
   begin
      for Cand in IQ2S_Grid'Range loop
         for J in 0 .. 7 loop
            Max_Grid := N.Real'Max (Max_Grid, Grid_Byte (Cand, J));
         end loop;
      end loop;
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 82;
            Wants   : array (0 .. 15) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;
            D       : N.Real;
         begin
            for HS in 0 .. 15 loop
               declare
                  Top : N.Real := 0.0;
               begin
                  for K in 0 .. 15 loop
                     Top := N.Real'Max
                       (Top, abs Values (First + N.Element_Count (HS * 16 + K)));
                  end loop;
                  Wants (HS) := Top / Max_Grid;
                  Largest := N.Real'Max (Largest, Wants (HS));
               end;
            end loop;
            D := (if Largest = 0.0 then 0.0 else Largest / 3.875);
            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (D)));
            for Sub in 0 .. 7 loop
               declare
                  function Nib (Want : N.Real) return Integer
                  is (if D = 0.0 then 0
                      else Integer'Max (0, Integer'Min (15,
                             Integer (N.Real'Rounding (4.0 * Want / D - 0.5)))));
                  S0 : constant Integer := Nib (Wants (2 * Sub));
                  S1 : constant Integer := Nib (Wants (2 * Sub + 1));
                  DB0 : constant N.Real := D * (0.5 + N.Real (S0)) * 0.25;
                  DB1 : constant N.Real := D * (0.5 + N.Real (S1)) * 0.25;
                  Scale_At : constant B.Byte_Count :=
                    At_Byte + 74 + B.Byte_Count (Sub);
                  QH : Interfaces.Unsigned_8 := 0;
               begin
                  Result (Scale_At) :=
                    Interfaces.Unsigned_8 (S0)
                    or Interfaces.Shift_Left (Interfaces.Unsigned_8 (S1), 4);
                  for L in 0 .. 3 loop
                     declare
                        Base : constant N.Element_Count :=
                          First + N.Element_Count (Sub * 32 + L * 8);
                        DB : constant N.Real := (if L / 2 = 0 then DB0 else DB1);
                        Best_Grid : Natural := 0;
                        Best_Cost : N.Real := N.Real'Last;
                        Sign : Interfaces.Unsigned_8 := 0;
                     begin
                        for Cand in IQ2S_Grid'Range loop
                           declare
                              Cost : N.Real := 0.0;
                           begin
                              for J in 0 .. 7 loop
                                 declare
                                    Target : constant N.Real :=
                                      (if DB = 0.0 then 0.0
                                       else abs Values (Base + N.Element_Count (J))
                                            / DB);
                                    Diff : constant N.Real :=
                                      Grid_Byte (Cand, J) - Target;
                                 begin
                                    Cost := Cost + Diff * Diff;
                                 end;
                              end loop;
                              if Cost < Best_Cost then
                                 Best_Cost := Cost; Best_Grid := Cand;
                              end if;
                           end;
                        end loop;
                        for J in 0 .. 7 loop
                           if Values (Base + N.Element_Count (J)) < 0.0 then
                              Sign := Sign or Interfaces.Unsigned_8 (2 ** J);
                           end if;
                        end loop;
                        Result (At_Byte + 2 + B.Byte_Count (4 * Sub + L)) :=
                          Interfaces.Unsigned_8 (Best_Grid mod 256);
                        Result (At_Byte + 34 + B.Byte_Count (4 * Sub + L)) := Sign;
                        QH := QH or Interfaces.Shift_Left
                          (Interfaces.Unsigned_8
                             (Interfaces.Shift_Right
                                (Interfaces.Unsigned_16 (Best_Grid), 8) and 3),
                           2 * L);
                     end;
                  end loop;
                  Result (At_Byte + 66 + B.Byte_Count (Sub)) := QH;
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Encode_IQ2_S;

   --  IQ3_XXS: eight three-byte-per-lane sub-blocks -- two grid indices a
   --  lane into a four-value grid -- with a four-bit scale and four seven-bit
   --  sign indices packed in a word past the indices.
   function Encode_IQ3_XXS (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_32;
      function Grid_Byte (Index : Natural; J : Natural) return N.Real
      is (N.Real (Integer (Interfaces.Shift_Right (IQ3XXS_Grid (Index), 8 * J)
                           and 16#FF#)));
      Max_Grid : N.Real := 1.0;
      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 98 - 1) :=
        [others => 0];
   begin
      for Cand in IQ3XXS_Grid'Range loop
         for J in 0 .. 3 loop
            Max_Grid := N.Real'Max (Max_Grid, Grid_Byte (Cand, J));
         end loop;
      end loop;
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 98;
            Wants   : array (0 .. 7) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;
            D       : N.Real;
         begin
            for Sub in 0 .. 7 loop
               declare
                  Top : N.Real := 0.0;
               begin
                  for K in 0 .. 31 loop
                     Top := N.Real'Max
                       (Top, abs Values (First + N.Element_Count (Sub * 32 + K)));
                  end loop;
                  Wants (Sub) := Top / Max_Grid;
                  Largest := N.Real'Max (Largest, Wants (Sub));
               end;
            end loop;
            D := (if Largest = 0.0 then 0.0 else Largest / 7.75);
            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (D)));
            for Sub in 0 .. 7 loop
               declare
                  Scale4 : constant Integer :=
                    (if D = 0.0 then 0
                     else Integer'Max (0, Integer'Min (15,
                            Integer (N.Real'Rounding
                              (2.0 * Wants (Sub) / D - 0.5)))));
                  DB : constant N.Real := D * (0.5 + N.Real (Scale4)) * 0.5;
                  Word : Interfaces.Unsigned_32 :=
                    Interfaces.Shift_Left
                      (Interfaces.Unsigned_32 (Scale4), 28);
                  QS_At : constant B.Byte_Count :=
                    At_Byte + 2 + B.Byte_Count (Sub) * 8;
                  SS_At : constant B.Byte_Count :=
                    At_Byte + 66 + B.Byte_Count (Sub) * 4;
               begin
                  for L in 0 .. 3 loop
                     declare
                        Base : constant N.Element_Count :=
                          First + N.Element_Count (Sub * 32 + L * 8);
                        Best_G1, Best_G2 : Natural := 0;
                        Cost_G1, Cost_G2 : N.Real := N.Real'Last;
                        Best_Sign : Natural := 0;
                        Best_SCost : N.Real := N.Real'Last;
                     begin
                        for Cand in IQ3XXS_Grid'Range loop
                           declare
                              C1, C2 : N.Real := 0.0;
                           begin
                              for J in 0 .. 3 loop
                                 declare
                                    T1 : constant N.Real :=
                                      (if DB = 0.0 then 0.0
                                       else abs Values (Base + N.Element_Count (J))
                                            / DB);
                                    T2 : constant N.Real :=
                                      (if DB = 0.0 then 0.0
                                       else abs Values (Base + N.Element_Count (J + 4))
                                            / DB);
                                    D1 : constant N.Real := Grid_Byte (Cand, J) - T1;
                                    D2 : constant N.Real := Grid_Byte (Cand, J) - T2;
                                 begin
                                    C1 := C1 + D1 * D1;
                                    C2 := C2 + D2 * D2;
                                 end;
                              end loop;
                              if C1 < Cost_G1 then
                                 Cost_G1 := C1; Best_G1 := Cand;
                              end if;
                              if C2 < Cost_G2 then
                                 Cost_G2 := C2; Best_G2 := Cand;
                              end if;
                           end;
                        end loop;
                        for Cand in 0 .. 127 loop
                           declare
                              Pattern : constant Interfaces.Unsigned_8 :=
                                KSigns_IQ2XS (Cand);
                              Cost : N.Real := 0.0;
                           begin
                              for J in 0 .. 7 loop
                                 declare
                                    Negative : constant Boolean :=
                                      Values (Base + N.Element_Count (J)) < 0.0;
                                    Set : constant Boolean :=
                                      (Pattern and Interfaces.Unsigned_8 (2 ** J))
                                        /= 0;
                                 begin
                                    if Negative /= Set then
                                       Cost := Cost
                                         + abs Values (Base + N.Element_Count (J));
                                    end if;
                                 end;
                              end loop;
                              if Cost < Best_SCost then
                                 Best_SCost := Cost; Best_Sign := Cand;
                              end if;
                           end;
                        end loop;
                        Result (QS_At + B.Byte_Count (2 * L)) :=
                          Interfaces.Unsigned_8 (Best_G1);
                        Result (QS_At + B.Byte_Count (2 * L + 1)) :=
                          Interfaces.Unsigned_8 (Best_G2);
                        Word := Word or Interfaces.Shift_Left
                          (Interfaces.Unsigned_32 (Best_Sign), 7 * L);
                     end;
                  end loop;
                  Result (SS_At) :=
                    Interfaces.Unsigned_8 (Word and 16#FF#);
                  Result (SS_At + 1) :=
                    Interfaces.Unsigned_8
                      (Interfaces.Shift_Right (Word, 8) and 16#FF#);
                  Result (SS_At + 2) :=
                    Interfaces.Unsigned_8
                      (Interfaces.Shift_Right (Word, 16) and 16#FF#);
                  Result (SS_At + 3) :=
                    Interfaces.Unsigned_8
                      (Interfaces.Shift_Right (Word, 24) and 16#FF#);
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Encode_IQ3_XXS;

   --  IQ1_S: a signed grid of values in minus-one to one, a three-bit scale
   --  and a delta sign per sub-block in a high-bit word, the low index bits a
   --  byte a lane and the high three from that word.
   function Encode_IQ1_S (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_16;
      function Grid_Value (Index : Natural; J : Natural) return N.Real is
         SB : constant Interfaces.Unsigned_64 :=
           Interfaces.Shift_Right (IQ1S_Grid (Index), 8 * J) and 16#FF#;
      begin
         return N.Real (if SB < 128 then Integer (SB) else Integer (SB) - 256);
      end Grid_Value;
      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 50 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 50;
            Wants   : array (0 .. 7) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;
            D       : N.Real;
         begin
            for Sub in 0 .. 7 loop
               declare
                  Top : N.Real := 0.0;
               begin
                  for K in 0 .. 31 loop
                     Top := N.Real'Max
                       (Top, abs Values (First + N.Element_Count (Sub * 32 + K)));
                  end loop;
                  Wants (Sub) := Top / 1.125;
                  Largest := N.Real'Max (Largest, Wants (Sub));
               end;
            end loop;
            D := (if Largest = 0.0 then 0.0 else Largest / 15.0);
            Result (At_Byte .. At_Byte + 1) :=
              B.Put_U16 (Interfaces.Unsigned_16 (N.To_Half (D)));
            for Sub in 0 .. 7 loop
               declare
                  S3 : constant Integer :=
                    (if D = 0.0 then 0
                     else Integer'Max (0, Integer'Min (7,
                            Integer (N.Real'Rounding
                              ((Wants (Sub) / D - 1.0) / 2.0)))));
                  DL : constant N.Real := D * N.Real (2 * S3 + 1);
                  Best_Neg : Boolean := False;
                  Best_DCost : N.Real := N.Real'Last;
                  QH : Interfaces.Unsigned_16 := 0;
               begin
                  --  Choose the delta sign for the sub-block: the one whose
                  --  eighth-step offset better matches where the values sit.
                  for Neg in Boolean loop
                     declare
                        Delta_V : constant N.Real := (if Neg then -0.125 else 0.125);
                        Cost : N.Real := 0.0;
                     begin
                        for K in 0 .. 31 loop
                           declare
                              V : constant N.Real :=
                                (if DL = 0.0 then 0.0
                                 else Values (First + N.Element_Count (Sub * 32 + K))
                                      / DL);
                              R : constant N.Real := N.Real'Rounding (V - Delta_V);
                              E : constant N.Real := V - (R + Delta_V);
                           begin
                              Cost := Cost + E * E;
                           end;
                        end loop;
                        if Cost < Best_DCost then
                           Best_DCost := Cost; Best_Neg := Neg;
                        end if;
                     end;
                  end loop;
                  QH := Interfaces.Shift_Left (Interfaces.Unsigned_16 (S3), 12);
                  if Best_Neg then
                     QH := QH or 16#8000#;
                  end if;
                  declare
                     Delta_V : constant N.Real := (if Best_Neg then -0.125 else 0.125);
                  begin
                     for L in 0 .. 3 loop
                        declare
                           Base : constant N.Element_Count :=
                             First + N.Element_Count (Sub * 32 + L * 8);
                           Best_Grid : Natural := 0;
                           Best_Cost : N.Real := N.Real'Last;
                        begin
                           for Cand in IQ1S_Grid'Range loop
                              declare
                                 Cost : N.Real := 0.0;
                              begin
                                 for J in 0 .. 7 loop
                                    declare
                                       Target : constant N.Real :=
                                         (if DL = 0.0 then 0.0
                                          else Values (Base + N.Element_Count (J)) / DL);
                                       Diff : constant N.Real :=
                                         (Grid_Value (Cand, J) + Delta_V) - Target;
                                    begin
                                       Cost := Cost + Diff * Diff;
                                    end;
                                 end loop;
                                 if Cost < Best_Cost then
                                    Best_Cost := Cost; Best_Grid := Cand;
                                 end if;
                              end;
                           end loop;
                           Result (At_Byte + 2 + B.Byte_Count (4 * Sub + L)) :=
                             Interfaces.Unsigned_8 (Best_Grid mod 256);
                           QH := QH or Interfaces.Shift_Left
                             (Interfaces.Shift_Right
                                (Interfaces.Unsigned_16 (Best_Grid), 8) and 7,
                              3 * L);
                        end;
                     end loop;
                  end;
                  declare
                     QH_At : constant B.Byte_Count :=
                       At_Byte + 34 + B.Byte_Count (2 * Sub);
                  begin
                     Result (QH_At .. QH_At + 1) := B.Put_U16 (QH);
                  end;
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Encode_IQ1_S;

   --  IQ1_M: like IQ1_S, but no scale field of its own -- the half is spread
   --  four bits at a time across four scale words -- and each sub-block has
   --  two three-bit scales and, in a byte of high bits, two index bits and a
   --  delta sign for each of its two halves.
   function Encode_IQ1_M (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;
      use type Interfaces.Unsigned_16;
      function Grid_Value (Index : Natural; J : Natural) return N.Real is
         SB : constant Interfaces.Unsigned_64 :=
           Interfaces.Shift_Right (IQ1S_Grid (Index), 8 * J) and 16#FF#;
      begin
         return N.Real (if SB < 128 then Integer (SB) else Integer (SB) - 256);
      end Grid_Value;
      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 56 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 56;
            Wants   : array (0 .. 15) of N.Real := [others => 0.0];
            Largest : N.Real := 0.0;
            D       : N.Real;
            Bits    : Interfaces.Unsigned_16;
            SC      : array (0 .. 3) of Interfaces.Unsigned_16 := [others => 0];
         begin
            for HS in 0 .. 15 loop
               declare
                  Top : N.Real := 0.0;
               begin
                  for K in 0 .. 15 loop
                     Top := N.Real'Max
                       (Top, abs Values (First + N.Element_Count (HS * 16 + K)));
                  end loop;
                  Wants (HS) := Top / 1.125;
                  Largest := N.Real'Max (Largest, Wants (HS));
               end;
            end loop;
            D := (if Largest = 0.0 then 0.0 else Largest / 15.0);
            Bits := Interfaces.Unsigned_16 (N.To_Half (D));
            --  The half's four nibbles become the top nibble of each scale
            --  word, low to high.
            for H in 0 .. 3 loop
               SC (H) := Interfaces.Shift_Left
                 (Interfaces.Shift_Right (Bits, 4 * H) and 16#000F#, 12);
            end loop;
            for Sub in 0 .. 7 loop
               declare
                  function Scale3 (Want : N.Real) return Integer
                  is (if D = 0.0 then 0
                      else Integer'Max (0, Integer'Min (7,
                             Integer (N.Real'Rounding
                               ((Want / D - 1.0) / 2.0)))));
                  S1 : constant Integer := Scale3 (Wants (2 * Sub));
                  S2 : constant Integer := Scale3 (Wants (2 * Sub + 1));
                  DL1 : constant N.Real := D * N.Real (2 * S1 + 1);
                  DL2 : constant N.Real := D * N.Real (2 * S2 + 1);
                  Which : constant Natural := Sub / 2;
                  Shift : constant Natural := 6 * (Sub mod 2);
                  QH0 : Interfaces.Unsigned_8 := 0;
                  QH1 : Interfaces.Unsigned_8 := 0;
               begin
                  SC (Which) := SC (Which)
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_16 (S1), Shift)
                    or Interfaces.Shift_Left
                         (Interfaces.Unsigned_16 (S2), Shift + 3);
                  for L in 0 .. 3 loop
                     declare
                        Base : constant N.Element_Count :=
                          First + N.Element_Count (Sub * 32 + L * 8);
                        DL : constant N.Real := (if L < 2 then DL1 else DL2);
                        Best_Neg : Boolean := False;
                        Best_DCost : N.Real := N.Real'Last;
                        Best_Grid : Natural := 0;
                     begin
                        for Neg in Boolean loop
                           declare
                              Delta_V : constant N.Real :=
                                (if Neg then -0.125 else 0.125);
                              Best_Cost : N.Real := N.Real'Last;
                           begin
                              for Cand in IQ1S_Grid'Range loop
                                 declare
                                    Cost : N.Real := 0.0;
                                 begin
                                    for J in 0 .. 7 loop
                                       declare
                                          Target : constant N.Real :=
                                            (if DL = 0.0 then 0.0
                                             else Values (Base + N.Element_Count (J))
                                                  / DL);
                                          Diff : constant N.Real :=
                                            (Grid_Value (Cand, J) + Delta_V) - Target;
                                       begin
                                          Cost := Cost + Diff * Diff;
                                       end;
                                    end loop;
                                    if Cost < Best_Cost then
                                       Best_Cost := Cost;
                                       if Cost < Best_DCost then
                                          Best_DCost := Cost;
                                          Best_Neg := Neg;
                                          Best_Grid := Cand;
                                       end if;
                                    end if;
                                 end;
                              end loop;
                           end;
                        end loop;
                        Result (At_Byte + B.Byte_Count (4 * Sub + L)) :=
                          Interfaces.Unsigned_8 (Best_Grid mod 256);
                        declare
                           High : constant Interfaces.Unsigned_8 :=
                             Interfaces.Unsigned_8
                               (Interfaces.Shift_Right
                                  (Interfaces.Unsigned_16 (Best_Grid), 8) and 7);
                        begin
                           case L is
                              when 0 =>
                                 QH0 := QH0 or High;
                                 if Best_Neg then
                                    QH0 := QH0 or 16#08#;
                                 end if;
                              when 1 =>
                                 QH0 := QH0 or Interfaces.Shift_Left (High, 4);
                                 if Best_Neg then
                                    QH0 := QH0 or 16#80#;
                                 end if;
                              when 2 =>
                                 QH1 := QH1 or High;
                                 if Best_Neg then
                                    QH1 := QH1 or 16#08#;
                                 end if;
                              when others =>
                                 QH1 := QH1 or Interfaces.Shift_Left (High, 4);
                                 if Best_Neg then
                                    QH1 := QH1 or 16#80#;
                                 end if;
                           end case;
                        end;
                     end;
                  end loop;
                  Result (At_Byte + 32 + B.Byte_Count (2 * Sub)) := QH0;
                  Result (At_Byte + 32 + B.Byte_Count (2 * Sub + 1)) := QH1;
               end;
            end loop;
            for H in 0 .. 3 loop
               declare
                  At_SC : constant B.Byte_Count :=
                    At_Byte + 48 + B.Byte_Count (2 * H);
               begin
                  Result (At_SC .. At_SC + 1) := B.Put_U16 (SC (H));
               end;
            end loop;
         end;
      end loop;
      return Result;
   end Encode_IQ1_M;

   --  The ternary digit a value takes against a scale: minus one, nought or
   --  one, lifted to nought, one or two as the formats store it.
   function Trit_Of (Value, Scale : N.Real) return Natural is
     (if Scale = 0.0 then 1
      else Natural (Integer'Max (-1, Integer'Min (1, Integer (N.Real'Rounding
                                                        (Value / Scale)))) + 1));

   --  The largest magnitude of a run, which both ternary formats take as
   --  their scale.
   function Extreme_Of (Values : N.Real_Array) return N.Real is
      Largest : N.Real := 0.0;
   begin
      for Value of Values loop
         Largest := N.Real'Max (Largest, abs Value);
      end loop;
      return Largest;
   end Extreme_Of;

   function Encode_TQ1_0 (Values : N.Real_Array) return B.Byte_Array is
      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 54 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 54;
            Scale   : constant N.Real :=
              Extreme_Of (Values (First .. First + 255));

            --  Digits first-most-significant, then scaled up to fill the
            --  byte by a ceiling division by three to the fifth, which is
            --  what lets the decoder read a digit off the top.
            function Packed (Trits : Natural) return B.Byte is
              (B.Byte ((Trits * 256 + 242) / 243));

            --  One run of bytes: byte m holds, most significant first, the
            --  elements m, m plus the run's width, and so on, one a digit.
            procedure Run
              (Element : N.Element_Count; Byte : B.Byte_Count;
               Width : Natural; Places : Natural)
            is
            begin
               for M in 0 .. Width - 1 loop
                  declare
                     Q : Natural := 0;
                  begin
                     for Place in 0 .. Places - 1 loop
                        Q := Q * 3
                          + Trit_Of
                              (Values (Element + N.Element_Count
                                                   (M + Place * Width)),
                               Scale);
                     end loop;
                     for Pad in Places .. 4 loop
                        Q := Q * 3;
                     end loop;
                     Result (At_Byte + Byte + B.Byte_Count (M)) := Packed (Q);
                  end;
               end loop;
            end Run;
         begin
            Run (First, 0, 32, 5);
            Run (First + 160, 32, 16, 5);
            Run (First + 240, 48, 4, 4);
            Result (At_Byte + 52 .. At_Byte + 53) := Encode_F16 ([1 => Scale]);
         end;
      end loop;

      return Result;
   end Encode_TQ1_0;

   function Encode_TQ2_0 (Values : N.Real_Array) return B.Byte_Array is
      Blocks : constant N.Element_Count := Values'Length / 256;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 66 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 256;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 66;
            Scale   : constant N.Real :=
              Extreme_Of (Values (First .. First + 255));
         begin
            --  Byte m of a run of thirty-two holds elements m, m plus
            --  thirty-two, sixty-four and ninety-six of the run's hundred
            --  and twenty-eight, the first in the lowest two bits.
            for Half in 0 .. 1 loop
               for M in 0 .. 31 loop
                  declare
                     Byte : Natural := 0;
                  begin
                     for Field in 0 .. 3 loop
                        Byte := Byte + Trit_Of
                          (Values (First + N.Element_Count
                                             (Half * 128 + Field * 32 + M)),
                           Scale) * 4 ** Field;
                     end loop;
                     Result (At_Byte + B.Byte_Count (Half * 32 + M)) :=
                       B.Byte (Byte);
                  end;
               end loop;
            end loop;
            Result (At_Byte + 64 .. At_Byte + 65) := Encode_F16 ([1 => Scale]);
         end;
      end loop;

      return Result;
   end Encode_TQ2_0;

   function Encode_Q1_0 (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 128;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 18 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 128;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 18;
            Sum     : N.Real := 0.0;
         begin
            --  Every element is the scale or its negation, so the scale
            --  that lands nearest on average is the mean magnitude.
            for J in 0 .. 127 loop
               Sum := Sum + abs Values (First + N.Element_Count (J));
            end loop;
            Result (At_Byte .. At_Byte + 1) := Encode_F16 ([1 => Sum / 128.0]);

            for J in 0 .. 127 loop
               if Values (First + N.Element_Count (J)) >= 0.0 then
                  Result (At_Byte + 2 + B.Byte_Count (J / 8)) :=
                    Result (At_Byte + 2 + B.Byte_Count (J / 8))
                    + B.Byte (2 ** (J mod 8));
               end if;
            end loop;
         end;
      end loop;

      return Result;
   end Encode_Q1_0;

   function Encode_Q2_0 (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 64;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 18 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         declare
            First   : constant N.Element_Count := Values'First + Block * 64;
            At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 18;
            Top     : N.Real := 0.0;
            Bottom  : N.Real := 0.0;
            Scale   : N.Real;
         begin
            --  The levels are minus one to two steps, so the step is what
            --  reaches both the most negative value at one and the most
            --  positive at two.
            for J in 0 .. 63 loop
               Top := N.Real'Max (Top, Values (First + N.Element_Count (J)));
               Bottom :=
                 N.Real'Min (Bottom, Values (First + N.Element_Count (J)));
            end loop;
            Scale := N.Real'Max (Top / 2.0, -Bottom);
            Result (At_Byte .. At_Byte + 1) := Encode_F16 ([1 => Scale]);

            for J in 0 .. 63 loop
               declare
                  Level : constant Integer :=
                    (if Scale = 0.0 then 0
                     else Integer'Max
                            (-1, Integer'Min
                                   (2, Integer (N.Real'Rounding
                                                  (Values (First
                                                           + N.Element_Count (J))
                                                   / Scale)))));
               begin
                  Result (At_Byte + 2 + B.Byte_Count (J / 4)) :=
                    Result (At_Byte + 2 + B.Byte_Count (J / 4))
                    + B.Byte ((Level + 1) * 4 ** (J mod 4));
               end;
            end loop;
         end;
      end loop;

      return Result;
   end Encode_Q2_0;

   --  An unsigned E4M3 scale read as the engine reads it: four bits of
   --  exponent biased by seven, three of mantissa, halved.
   function E4M3_Value (Byte : Natural) return N.Real is
      Exponent : constant Natural := (Byte / 8) mod 16;
      Mantissa : constant Natural := Byte mod 8;
   begin
      if Byte = 0 or else Byte = 16#7F# then
         return 0.0;
      elsif Exponent = 0 then
         return N.Real (Mantissa) * 2.0 ** (-10);
      else
         return (1.0 + N.Real (Mantissa) / 8.0) * 2.0 ** (Exponent - 8);
      end if;
   end E4M3_Value;

   function Encode_NVFP4 (Values : N.Real_Array) return B.Byte_Array is
      use type Interfaces.Unsigned_8;

      Blocks : constant N.Element_Count := Values'Length / 64;
      Result : B.Byte_Array (0 .. B.Byte_Count (Blocks) * 36 - 1) :=
        [others => 0];
   begin
      for Block in 0 .. Blocks - 1 loop
         for Run in 0 .. 3 loop
            declare
               First   : constant N.Element_Count :=
                 Values'First + Block * 64 + N.Element_Count (Run) * 16;
               At_Byte : constant B.Byte_Count := B.Byte_Count (Block) * 36;
               Wanted  : constant N.Real :=
                 Extreme_Of (Values (First .. First + 15)) / 12.0;
               Chosen  : Natural := 0;
            begin
               --  The smallest scale whose top level, twelve of the doubled
               --  table, reaches the run's largest magnitude.
               if Wanted > 0.0 then
                  Chosen := 16#7E#;
                  for Byte in 1 .. 16#7E# loop
                     if E4M3_Value (Byte) >= Wanted then
                        Chosen := Byte;
                        exit;
                     end if;
                  end loop;
               end if;
               Result (At_Byte + B.Byte_Count (Run)) := B.Byte (Chosen);

               for J in 0 .. 7 loop
                  declare
                     Step  : constant N.Real := E4M3_Value (Chosen);
                     Lower : constant Interfaces.Unsigned_8 :=
                       (if Step = 0.0 then 0
                        else Nearest_Four
                               (Values (First + N.Element_Count (J)) / Step));
                     Upper : constant Interfaces.Unsigned_8 :=
                       (if Step = 0.0 then 0
                        else Nearest_Four
                               (Values (First + N.Element_Count (J) + 8)
                                / Step));
                  begin
                     Result (At_Byte + 4 + B.Byte_Count (Run * 8 + J)) :=
                       B.Byte (Lower or Interfaces.Shift_Left (Upper, 4));
                  end;
               end loop;
            end;
         end loop;
      end loop;

      return Result;
   end Encode_NVFP4;

end Fixtures;
