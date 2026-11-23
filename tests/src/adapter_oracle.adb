with Ada.Unchecked_Conversion;

package body Adapter_Oracle is

   --  Raw IEEE NaN/Inf must reach the explicit bit checks rather than GNAT's validity exception.
   --  Shape, index, range and overflow checks remain enabled.
   pragma Suppress (Validity_Check);

   package E renames Model_Runner.Errors;
   use type Number;
   use type Interfaces.Unsigned_64;

   function Bits is new Ada.Unchecked_Conversion (Number, Interfaces.Unsigned_64);

   function Finite (Value : Number) return Boolean
   is ((Bits (Value) and 16#7FF0_0000_0000_0000#) /= 16#7FF0_0000_0000_0000#);

   function Valid (Value : Number; Limit : Number := 1.0E40) return Boolean
   is (Finite (Value) and then abs Value <= Limit);

   function Valid (Value : Matrix) return Boolean
   is (for all Row in Value'Range (1) =>
         (for all Column in Value'Range (2) => Valid (Value (Row, Column))));

   function Valid (Value : Vector; Limit : Number := 1.0E40) return Boolean
   is (for all Item of Value => Valid (Item, Limit));

   procedure Project
     (Weight : Matrix; Input : Vector; Into : in out Vector; Status : out E.Error_Info)
   is
   begin
      Status := E.Success;
      if Weight'Length (1) = 0 or else Weight'Length (2) = 0
        or else Weight'Length (1) /= Into'Length or else Weight'Length (2) /= Input'Length
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
      elsif Into'Length > Max_Width or else Input'Length > Max_Width
        or else Into'Length > Max_Elements / Input'Length
      then
         Status := E.Make (E.Tensor_Out_Of_Bounds);
      elsif not Valid (Weight) or else not Valid (Input) then
         Status := E.Make (E.Tensor_Non_Finite_Value);
      else
         declare
            Result : Vector (Into'Range) := [others => 0.0];
         begin
            for R in 0 .. Into'Length - 1 loop
               for C in 0 .. Input'Length - 1 loop
                  Result (Into'First + R) := Result (Into'First + R)
                    + Weight (Weight'First (1) + R, Weight'First (2) + C) * Input (Input'First + C);
               end loop;
            end loop;
            Into := Result;
         end;
      end if;
   end Project;

   procedure Accumulate
     (Down, Up : Matrix; Input : Vector; Scale, Alpha : Number; Alpha_Present : Boolean;
      Into : in out Vector; Status : out E.Error_Info)
   is
      Rank : constant Natural := Down'Length (1);
   begin
      Status := E.Success;
      if Rank = 0 or else Input'Length = 0 or else Into'Length = 0
        or else Down'Length (2) /= Input'Length or else Up'Length (1) /= Into'Length
        or else Up'Length (2) /= Rank
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
      elsif Rank > Max_Rank then
         Status := E.Make (E.Tensor_Rank_Too_High);
      elsif Into'Length > Max_Width or else Input'Length > Max_Width
        or else Into'Length > Max_Products / Input'Length / Rank
      then
         Status := E.Make (E.Tensor_Out_Of_Bounds);
      elsif Alpha_Present and then Finite (Alpha) and then (Alpha < 0.0 or else Alpha > 1.0E6) then
         Status := E.Make (E.GGUF_Metadata_Out_Of_Range);
      elsif not Valid (Down) or else not Valid (Up) or else not Valid (Input)
        or else not Valid (Into, 1.0E240) or else not Valid (Scale)
        or else (Alpha_Present and then not Valid (Alpha))
      then
         Status := E.Make (E.Tensor_Non_Finite_Value);
      elsif Scale /= 0.0 then
         declare
            Factor : constant Number := Scale * (if not Alpha_Present or else Alpha = 0.0 then 1.0
                                                else Alpha / Number (Rank));
            Result : Vector (Into'Range) := Into;
         begin
            for R in 0 .. Into'Length - 1 loop
               for C in 0 .. Input'Length - 1 loop
                  declare
                     Delta_Weight : Number := 0.0;
                  begin
                     for K in 0 .. Rank - 1 loop
                        Delta_Weight := Delta_Weight
                          + Up (Up'First (1) + R, Up'First (2) + K)
                          * Down (Down'First (1) + K, Down'First (2) + C);
                     end loop;
                     Result (Into'First + R) := Result (Into'First + R)
                       + Factor * Delta_Weight * Input (Input'First + C);
                  end;
               end loop;
            end loop;
            Into := Result;
         end;
      end if;
   end Accumulate;

end Adapter_Oracle;
