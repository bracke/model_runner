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

end Fixtures;
