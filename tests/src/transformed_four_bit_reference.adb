with Interfaces;

with Model_Runner.Numerics;

package body Transformed_Four_Bit_Reference is

   package N renames Model_Runner.Numerics;

   use type C.Byte;
   use type C.Element_Count;
   use type C.Real;
   use type C.Wide_Real;
   use type Interfaces.Unsigned_32;

   type Direction is (Forward, Inverse);

   function Positive_Sign (Offset : C.Element_Count) return Boolean
   is ((Interfaces.Shift_Right
          (C.Sign_Mask, Natural (Offset mod C.Group_Size)) and 1) = 0);

   function Positive_Coefficient
     (Row, Column : C.Element_Count) return Boolean
   is
      Left  : C.Element_Count := Row;
      Right : C.Element_Count := Column;
      Odd  : Boolean := False;
   begin
      while Left > 0 or else Right > 0 loop
         if Left mod 2 = 1 and then Right mod 2 = 1 then
            Odd := not Odd;
         end if;
         Left := Left / 2;
         Right := Right / 2;
      end loop;
      return not Odd;
   end Positive_Coefficient;

   procedure Transform
     (Source : C.Real_Array;
      Target : out C.Real_Array;
      Way    : Direction;
      Valid  : out Boolean)
   is
      Base : C.Element_Count := 0;
   begin
      Target := [others => 0.0];
      Valid := Target'Length = Source'Length;
      if not Valid or else Source'Length = 0 then
         return;
      end if;

      while Base < C.Element_Count (Source'Length) loop
         declare
            Span : constant C.Element_Count :=
              C.Element_Count'Min
                (C.Group_Size, C.Element_Count (Source'Length) - Base);
            Used : C.Element_Count := 0;
         begin
            while Used < Span loop
               declare
                  Left  : constant C.Element_Count := Span - Used;
                  Width : C.Element_Count := 1;
               begin
                  while Width * 2 <= Left loop
                     Width := Width * 2;
                  end loop;

                  for Row in C.Element_Count range 0 .. Width - 1 loop
                     declare
                        Total : C.Wide_Real := 0.0;
                     begin
                        for Column in C.Element_Count range 0 .. Width - 1 loop
                           declare
                              Value : C.Wide_Real :=
                                C.Wide_Real
                                  (Source
                                     (Source'First + Base + Used + Column));
                           begin
                              if not N.Is_Finite (Value) then
                                 Valid := False;
                                 return;
                              end if;
                              if Way = Forward
                                and then not Positive_Sign (Used + Column)
                              then
                                 Value := -Value;
                              end if;
                              if not Positive_Coefficient (Row, Column) then
                                 Value := -Value;
                              end if;
                              Total := Total + Value;
                           end;
                        end loop;
                        Total := Total / N.Sqrt (C.Wide_Real (Width));
                        if Way = Inverse
                          and then not Positive_Sign (Used + Row)
                        then
                           Total := -Total;
                        end if;
                        if not N.Is_Finite (Total)
                          or else abs Total > C.Wide_Real (C.Real'Last)
                        then
                           Valid := False;
                           return;
                        end if;
                        Target (Target'First + Base + Used + Row) :=
                          C.Real (Total);
                     end;
                  end loop;
                  Used := Used + Width;
               end;
            end loop;
            Base := Base + Span;
         end;
      end loop;
   exception
      when Constraint_Error =>
         Target := [others => 0.0];
         Valid := False;
   end Transform;

   procedure Pack
     (Source : C.Real_Array;
      Codes  : out C.Byte_Array;
      Scales : out C.Real_Array;
      Valid  : out Boolean)
   is
      Base : C.Element_Count := 0;
   begin
      Codes := [others => 0];
      Scales := [others => 0.0];
      Valid := C.Element_Count (Codes'Length)
                 = C.Code_Bytes (C.Element_Count (Source'Length))
        and then C.Element_Count (Scales'Length)
                 = C.Scale_Count (C.Element_Count (Source'Length));
      if not Valid or else Source'Length = 0 then
         return;
      end if;

      while Base < C.Element_Count (Source'Length) loop
         declare
            Span : constant C.Element_Count :=
              C.Element_Count'Min
                (C.Group_Size, C.Element_Count (Source'Length) - Base);
            Largest : C.Real := 0.0;
            Signed  : C.Real := 0.0;
         begin
            for Offset in C.Element_Count range 0 .. Span - 1 loop
               declare
                  Value : constant C.Real :=
                    Source (Source'First + Base + Offset);
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
               Scale : constant C.Real := Signed / (-8.0);
               Inverse : constant C.Real :=
                 (if Scale = 0.0 then 0.0 else 1.0 / Scale);
            begin
               Scales (Scales'First + Base / C.Group_Size) := Scale;
               for Offset in C.Element_Count range 0 .. Span - 1 loop
                  declare
                     Level : constant C.Real :=
                       C.Real'Floor
                         (Source (Source'First + Base + Offset)
                          * Inverse + 8.5);
                     Nibble : constant C.Byte :=
                       C.Byte
                         (Integer
                            (C.Real'Max
                               (0.0, C.Real'Min (15.0, Level))));
                     Where : constant C.Element_Count :=
                       Codes'First + (Base + Offset) / 2;
                  begin
                     if (Base + Offset) mod 2 = 0 then
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
   end Pack;

   function Unpack
     (Codes   : C.Byte_Array;
      Scales  : C.Real_Array;
      Element : C.Element_Count) return C.Real
   is
      Octet : constant C.Byte := Codes (Codes'First + Element / 2);
      Level : constant Integer :=
        (if Element mod 2 = 0
         then Integer (Octet and 15)
         else Integer (Interfaces.Shift_Right (Octet, 4) and 15));
   begin
      return C.Real (Level - 8)
        * Scales (Scales'First + Element / C.Group_Size);
   end Unpack;

   procedure Encode_Key
     (Source : C.Real_Array;
      Codes  : out C.Byte_Array;
      Scales : out C.Real_Array;
      Valid  : out Boolean)
   is
      Rotated : C.Real_Array (Source'Range);
   begin
      Transform (Source, Rotated, Forward, Valid);
      if not Valid then
         Codes := [others => 0];
         Scales := [others => 0.0];
         return;
      end if;
      Pack (Rotated, Codes, Scales, Valid);
   end Encode_Key;

   procedure Decode_Key
     (Codes  : C.Byte_Array;
      Scales : C.Real_Array;
      Target : out C.Real_Array;
      Valid  : out Boolean)
   is
      Rotated : C.Real_Array (Target'Range);
   begin
      Target := [others => 0.0];
      Valid := C.Element_Count (Codes'Length)
                 = C.Code_Bytes (C.Element_Count (Target'Length))
        and then C.Element_Count (Scales'Length)
                 = C.Scale_Count (C.Element_Count (Target'Length));
      if not Valid or else Target'Length = 0 then
         return;
      end if;
      for Offset in C.Element_Count range
        0 .. C.Element_Count (Target'Length) - 1
      loop
         Rotated (Rotated'First + Offset) := Unpack (Codes, Scales, Offset);
      end loop;
      Transform (Rotated, Target, Inverse, Valid);
   end Decode_Key;

   function Score_Key
     (Query  : C.Real_Array;
      Codes  : C.Byte_Array;
      Scales : C.Real_Array;
      Valid  : out Boolean) return C.Wide_Real
   is
      Decoded : C.Real_Array (Query'Range);
      Total   : C.Wide_Real := 0.0;
   begin
      Decode_Key (Codes, Scales, Decoded, Valid);
      if not Valid then
         return 0.0;
      end if;
      for Index in Query'Range loop
         Total := Total
           + C.Wide_Real (Query (Index)) * C.Wide_Real (Decoded (Index));
      end loop;
      Valid := N.Is_Finite (Total);
      return (if Valid then Total else 0.0);
   end Score_Key;

   procedure Encode_Value
     (Source : C.Real_Array;
      Codes  : out C.Byte_Array;
      Scales : out C.Real_Array;
      Valid  : out Boolean) is
   begin
      Pack (Source, Codes, Scales, Valid);
   end Encode_Value;

   procedure Decode_Value
     (Codes  : C.Byte_Array;
      Scales : C.Real_Array;
      Target : out C.Real_Array;
      Valid  : out Boolean) is
   begin
      Target := [others => 0.0];
      Valid := C.Element_Count (Codes'Length)
                 = C.Code_Bytes (C.Element_Count (Target'Length))
        and then C.Element_Count (Scales'Length)
                 = C.Scale_Count (C.Element_Count (Target'Length));
      if not Valid or else Target'Length = 0 then
         return;
      end if;
      for Offset in C.Element_Count range
        0 .. C.Element_Count (Target'Length) - 1
      loop
         Target (Target'First + Offset) := Unpack (Codes, Scales, Offset);
      end loop;
   end Decode_Value;

end Transformed_Four_Bit_Reference;
