package body Model_Runner.Arithmetic is

   ---------
   -- "+" --
   ---------

   function "+" (Left, Right : Checked) return Checked is
   begin
      if not Left.Valid or else not Right.Valid then
         return Invalid;
      elsif Left.Value > U64'Last - Right.Value then
         return Invalid;
      else
         return (Value => Left.Value + Right.Value, Valid => True);
      end if;
   end "+";

   ---------
   -- "-" --
   ---------

   function "-" (Left, Right : Checked) return Checked is
   begin
      if not Left.Valid or else not Right.Valid then
         return Invalid;
      elsif Left.Value < Right.Value then
         return Invalid;
      else
         return (Value => Left.Value - Right.Value, Valid => True);
      end if;
   end "-";

   ---------
   -- "*" --
   ---------

   function "*" (Left, Right : Checked) return Checked is
   begin
      if not Left.Valid or else not Right.Valid then
         return Invalid;
      elsif Left.Value = 0 or else Right.Value = 0 then
         return (Value => 0, Valid => True);
      elsif Left.Value > U64'Last / Right.Value then
         return Invalid;
      else
         return (Value => Left.Value * Right.Value, Valid => True);
      end if;
   end "*";

   ---------
   -- "/" --
   ---------

   function "/" (Left, Right : Checked) return Checked is
   begin
      if not Left.Valid or else not Right.Valid or else Right.Value = 0 then
         return Invalid;
      else
         return (Value => Left.Value / Right.Value, Valid => True);
      end if;
   end "/";

   --------------
   -- Align_Up --
   --------------

   function Align_Up (Item : Checked; Alignment : U64) return Checked is
      Mask : U64;
   begin
      if not Item.Valid or else not Is_Power_Of_Two (Alignment) then
         return Invalid;
      end if;

      Mask := Alignment - 1;

      if (Item.Value and Mask) = 0 then
         return Item;
      elsif Item.Value > U64'Last - (Alignment - (Item.Value and Mask)) then
         return Invalid;
      else
         return (Value => (Item.Value + Mask) and not Mask, Valid => True);
      end if;
   end Align_Up;

   ----------------
   -- To_Natural --
   ----------------

   function To_Natural (Item : Checked; Result : out Natural) return Boolean is
   begin
      if Item.Valid and then Item.Value <= U64 (Natural'Last) then
         Result := Natural (Item.Value);
         return True;
      else
         Result := 0;
         return False;
      end if;
   end To_Natural;

end Model_Runner.Arithmetic;
