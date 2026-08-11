with Model_Runner.Arithmetic;

package body Fixtures is

   use type Interfaces.Unsigned_64;
   use type Interfaces.Integer_64;
   use type B.Byte_Count;
   use type B.Byte_Array_Access;
   use type N.Element_Count;
   use type N.Real;

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
                     --  The same twelve bytes Sub_Block_Scale reads: the
                     --  first four sub-blocks keep six bits in place, and
                     --  the last four are split across two bytes.
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

end Fixtures;
