package body Model_Runner.Cache_Codecs.Transformed_Four_Bit is

   use type Interfaces.Unsigned_32;
   use type Interfaces.Unsigned_8;
   use type N.Real;
   use type N.Wide_Real;

   type Direction is (Forward, Inverse);

   function Buffers_Match
     (Elements : Element_Count;
      Codes    : Byte_Array;
      Scales   : Real_Array) return Boolean
   is (Element_Count (Codes'Length) = Code_Bytes (Elements)
       and then Element_Count (Scales'Length) = Scale_Count (Elements));

   function Positive_Sign (Offset : Element_Count) return Boolean
   is ((Interfaces.Shift_Right
          (Sign_Mask, Natural (Offset mod Group_Size)) and 1) = 0);

   procedure Clear (Item : out Byte_Array) is
   begin
      Item := [others => 0];
   end Clear;

   procedure Clear (Item : out Real_Array) is
   begin
      Item := [others => 0.0];
   end Clear;

   --  Apply one side of R = H.D, independently in each group. H is the
   --  normalized Walsh-Hadamard matrix and D is Sign_Mask. R preserves dot
   --  products. Its inverse is D.H.
   procedure Transform
     (Source : Real_Array;
      Target : out Real_Array;
      Way    : Direction;
      Valid  : out Boolean)
   is
      Scratch : N.Wide_Real_Array (0 .. Group_Size - 1);
      Base    : Element_Count := 0;
   begin
      Clear (Target);
      Valid := Target'Length = Source'Length;
      if not Valid or else Source'Length = 0 then
         return;
      end if;

      while Base < Element_Count (Source'Length) loop
         declare
            Span : constant Element_Count :=
              Element_Count'Min
                (Group_Size, Element_Count (Source'Length) - Base);
            Used : Element_Count := 0;
         begin
            while Used < Span loop
               declare
                  Left  : constant Element_Count := Span - Used;
                  Width : Element_Count := 1;
               begin
                  while Width * 2 <= Left loop
                     Width := Width * 2;
                  end loop;

                  for Index in 0 .. Width - 1 loop
                     declare
                        Value : constant Real :=
                          Source
                            (Source'First + Base + Used + Index);
                     begin
                        if not N.Is_Finite (Value) then
                           Valid := False;
                           return;
                        end if;
                        Scratch (Index) := N.Wide_Real (Value);
                        if Way = Forward
                          and then not Positive_Sign (Used + Index)
                        then
                           Scratch (Index) := -Scratch (Index);
                        end if;
                     end;
                  end loop;

                  declare
                     Step : Element_Count := 1;
                  begin
                     while Step < Width loop
                        declare
                           Block : Element_Count := 0;
                        begin
                           while Block < Width loop
                              for Index in 0 .. Step - 1 loop
                                 declare
                                    A : constant Wide_Real :=
                                      Scratch (Block + Index);
                                    B : constant Wide_Real :=
                                      Scratch (Block + Step + Index);
                                 begin
                                    Scratch (Block + Index) := A + B;
                                    Scratch (Block + Step + Index) := A - B;
                                 end;
                              end loop;
                              Block := Block + Step * 2;
                           end loop;
                        end;
                        Step := Step * 2;
                     end loop;
                  end;

                  declare
                     Normalizer : constant Wide_Real :=
                       1.0 / N.Sqrt (Wide_Real (Width));
                  begin
                     for Index in 0 .. Width - 1 loop
                        declare
                           Value : Wide_Real := Scratch (Index) * Normalizer;
                        begin
                           if Way = Inverse
                             and then not Positive_Sign (Used + Index)
                           then
                              Value := -Value;
                           end if;
                           if not N.Is_Finite (Value)
                             or else abs Value > Wide_Real (Real'Last)
                           then
                              Valid := False;
                              return;
                           end if;
                           Target
                             (Target'First + Base + Used + Index) := Real (Value);
                        end;
                     end loop;
                  end;
                  Used := Used + Width;
               end;
            end loop;
            Base := Base + Span;
         end;
      end loop;
   exception
      when Constraint_Error =>
         Clear (Target);
         Valid := False;
   end Transform;

   procedure Rotate_Key
     (Source : Real_Array;
      Target : out Real_Array;
      Valid  : out Boolean) is
   begin
      Transform (Source, Target, Forward, Valid);
   end Rotate_Key;

   procedure Restore_Key
     (Source : Real_Array;
      Target : out Real_Array;
      Valid  : out Boolean) is
   begin
      Transform (Source, Target, Inverse, Valid);
   end Restore_Key;

   procedure Pack
     (Source : Real_Array;
      Codes  : out Byte_Array;
      Scales : out Real_Array;
      Valid  : out Boolean)
   is
      Base : Element_Count := 0;
   begin
      Clear (Codes);
      Clear (Scales);
      Valid := Buffers_Match
        (Element_Count (Source'Length), Codes, Scales);
      if not Valid or else Source'Length = 0 then
         return;
      end if;

      while Base < Element_Count (Source'Length) loop
         declare
            Span : constant Element_Count :=
              Element_Count'Min
                (Group_Size, Element_Count (Source'Length) - Base);
            Largest : Real := 0.0;
            Signed  : Real := 0.0;
         begin
            for Index in 0 .. Span - 1 loop
               declare
                  Value : constant Real := Source (Source'First + Base + Index);
               begin
                  if not N.Is_Finite (Value) then
                     Valid := False;
                     return;
                  end if;
                  if abs Value > Largest then
                     Largest := abs Value;
                     Signed := Value;
                  end if;
               end;
            end loop;

            declare
               Scale   : constant Real := Signed / (-8.0);
               Inverse : constant Real :=
                 (if Scale = 0.0 then 0.0 else 1.0 / Scale);
            begin
               Scales (Scales'First + Base / Group_Size) := Scale;
               for Index in 0 .. Span - 1 loop
                  declare
                     Level : constant Real :=
                       Real'Floor
                         (Source (Source'First + Base + Index) * Inverse + 8.5);
                     Nibble : constant Byte :=
                       Byte
                         (Integer
                            (Real'Max (0.0, Real'Min (15.0, Level))));
                     Where : constant Element_Count :=
                       Codes'First + (Base + Index) / 2;
                  begin
                     if (Base + Index) mod 2 = 0 then
                        Codes (Where) := Nibble;
                     else
                        Codes (Where) := Codes (Where) or Nibble * 16;
                     end if;
                  end;
               end loop;
            end;
            Base := Base + Span;
         end;
      end loop;
   exception
      when Constraint_Error =>
         Clear (Codes);
         Clear (Scales);
         Valid := False;
   end Pack;

   function Unpack
     (Codes   : Byte_Array;
      Scales  : Real_Array;
      Element : Element_Count) return Real
   is
      Octet : constant Byte := Codes (Codes'First + Element / 2);
      Level : constant Integer :=
        (if Element mod 2 = 0
         then Integer (Octet and 15)
         else Integer (Interfaces.Shift_Right (Octet, 4) and 15));
   begin
      return Real (Level - 8)
        * Scales (Scales'First + Element / Group_Size);
   end Unpack;

   procedure Encode_Key
     (Source : Real_Array;
      Codes  : out Byte_Array;
      Scales : out Real_Array;
      Valid  : out Boolean)
   is
      Rotated : Real_Array (Source'Range);
   begin
      Rotate_Key (Source, Rotated, Valid);
      if not Valid then
         Clear (Codes);
         Clear (Scales);
         return;
      end if;
      Pack (Rotated, Codes, Scales, Valid);
   end Encode_Key;

   procedure Decode_Key
     (Codes  : Byte_Array;
      Scales : Real_Array;
      Target : out Real_Array;
      Valid  : out Boolean)
   is
      Rotated : Real_Array (Target'Range);
   begin
      Clear (Target);
      Valid := Buffers_Match
        (Element_Count (Target'Length), Codes, Scales);
      if not Valid or else Target'Length = 0 then
         return;
      end if;
      for Offset in 0 .. Element_Count (Target'Length) - 1 loop
         Rotated (Rotated'First + Offset) := Unpack (Codes, Scales, Offset);
      end loop;
      Restore_Key (Rotated, Target, Valid);
   end Decode_Key;

   function Score_Key
     (Query  : Real_Array;
      Codes  : Byte_Array;
      Scales : Real_Array;
      Valid  : out Boolean) return Wide_Real
   is
      Rotated : Real_Array (Query'Range);
      Total   : Wide_Real := 0.0;
   begin
      Valid := Buffers_Match
        (Element_Count (Query'Length), Codes, Scales);
      if not Valid or else Query'Length = 0 then
         return 0.0;
      end if;
      Rotate_Key (Query, Rotated, Valid);
      if not Valid then
         return 0.0;
      end if;
      for Offset in 0 .. Element_Count (Query'Length) - 1 loop
         Total := Total
           + Wide_Real (Rotated (Rotated'First + Offset))
             * Wide_Real (Unpack (Codes, Scales, Offset));
      end loop;
      Valid := N.Is_Finite (Total);
      return (if Valid then Total else 0.0);
   exception
      when Constraint_Error =>
         Valid := False;
         return 0.0;
   end Score_Key;

   procedure Encode_Value
     (Source : Real_Array;
      Codes  : out Byte_Array;
      Scales : out Real_Array;
      Valid  : out Boolean) is
   begin
      Pack (Source, Codes, Scales, Valid);
   end Encode_Value;

   procedure Accumulate_Value
     (Weight : Real;
      Codes  : Byte_Array;
      Scales : Real_Array;
      Target : in out Real_Array;
      Valid  : out Boolean) is
   begin
      Valid := N.Is_Finite (Weight)
        and then Buffers_Match
          (Element_Count (Target'Length), Codes, Scales);
      if not Valid or else Target'Length = 0 then
         return;
      end if;
      for Offset in 0 .. Element_Count (Target'Length) - 1 loop
         declare
            Value : constant Wide_Real :=
              Wide_Real (Target (Target'First + Offset))
              + Wide_Real (Weight) * Wide_Real (Unpack (Codes, Scales, Offset));
         begin
            if not N.Is_Finite (Value)
              or else abs Value > Wide_Real (Real'Last)
            then
               Valid := False;
               return;
            end if;
            Target (Target'First + Offset) := Real (Value);
         end;
      end loop;
   exception
      when Constraint_Error =>
         Valid := False;
   end Accumulate_Value;

   procedure Finish_Value
     (Target : Real_Array;
      Valid  : out Boolean) is
   begin
      Valid := (for all Value of Target => N.Is_Finite (Value));
   end Finish_Value;

end Model_Runner.Cache_Codecs.Transformed_Four_Bit;
