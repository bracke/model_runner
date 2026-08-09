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
