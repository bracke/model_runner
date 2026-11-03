with Ada.Numerics.Generic_Elementary_Functions;

with Zlib;

package body Model_Runner.Whisper.Decoding is

   package N renames Model_Runner.Numerics;

   subtype Wide_Real is N.Wide_Real;

   package Elementary is new Ada.Numerics.Generic_Elementary_Functions (Wide_Real);

   use type Wide_Real;
   use type Token_Id;
   use type Zlib.Status_Code;

   --  Minus infinity, as a logit no token is given.
   Never : constant N.Real := N.Real'First;

   function Allowed (Value : N.Real) return Boolean is (Value > Never);

   procedure Suppress (Logits : in out Real_Array; Token : Token_Id) is
   begin
      if Token >= 0 and then N.Element_Count (Token) < Logits'Length then
         Logits (Logits'First + N.Element_Count (Token)) := Never;
      end if;
   end Suppress;

   --  log (sum exp) over Logits (From .. To), the allowed ones; minus
   --  infinity, as Wide_Real'First, where none is.
   function Log_Sum (Logits : Real_Array; From, To : N.Element_Count) return Wide_Real is
      Top : N.Real := Never;
      Sum : Wide_Real := 0.0;
   begin
      for I in From .. To loop
         Top := N.Real'Max (Top, Logits (I));
      end loop;
      if not Allowed (Top) then
         return Wide_Real'First;
      end if;
      for I in From .. To loop
         if Allowed (Logits (I)) then
            Sum := Sum + Elementary.Exp (Wide_Real (Logits (I)) - Wide_Real (Top));
         end if;
      end loop;
      return Wide_Real (Top) + Elementary.Log (Sum);
   end Log_Sum;

   -----------
   -- Apply --
   -----------

   procedure Apply (Item : Rules; Sampled : Token_Array; Logits : in out Real_Array) is
      First : constant N.Element_Count := Logits'First;
      Last  : constant N.Element_Count := Logits'Last;
      Begin_At : constant N.Element_Count := First + N.Element_Count (Item.Timestamp_Begin);
   begin
      if Sampled'Length = 0 then
         for I in 1 .. Item.Begin_Suppressed_Count loop
            Suppress (Logits, Item.Begin_Suppressed (I));
         end loop;
      end if;
      for I in 1 .. Item.Suppressed_Count loop
         Suppress (Logits, Item.Suppressed (I));
      end loop;

      if not Item.Timestamps then
         return;
      end if;

      Suppress (Logits, Item.No_Timestamps);

      declare
         Last_Was_Time : constant Boolean :=
           Sampled'Length >= 1 and then Sampled (Sampled'Last) >= Item.Timestamp_Begin;
         Penultimate_Was_Time : constant Boolean :=
           Sampled'Length < 2 or else Sampled (Sampled'Last - 1) >= Item.Timestamp_Begin;
         Last_Time : Token_Id := -1;
      begin
         if Last_Was_Time then
            if Penultimate_Was_Time then
               for I in Begin_At .. Last loop
                  Logits (I) := Never;
               end loop;
            else
               for I in First .. First + N.Element_Count (Item.End_Of_Text) - 1 loop
                  Logits (I) := Never;
               end loop;
            end if;
         end if;

         for T of Sampled loop
            if T >= Item.Timestamp_Begin then
               Last_Time := T;
            end if;
         end loop;
         if Last_Time >= 0 then
            declare
               Until_Token : constant Token_Id :=
                 (if Last_Was_Time and then not Penultimate_Was_Time then Last_Time else Last_Time + 1);
            begin
               for I in Begin_At .. First + N.Element_Count (Until_Token) - 1 loop
                  Logits (I) := Never;
               end loop;
            end;
         end if;
      end;

      if Sampled'Length = 0 then
         for I in First .. Begin_At - 1 loop
            Logits (I) := Never;
         end loop;
         for I in Begin_At + N.Element_Count (Item.Max_Initial_Timestamp) + 1 .. Last loop
            Logits (I) := Never;
         end loop;
      end if;

      --  All the times together against the likeliest text token: the
      --  log-softmax's shared normalizer cancels, so the raw sums compare.
      declare
         Times : constant Wide_Real := Log_Sum (Logits, Begin_At, Last);
         Text  : N.Real := Never;
      begin
         for I in First .. Begin_At - 1 loop
            Text := N.Real'Max (Text, Logits (I));
         end loop;
         if Times > Wide_Real'First and then (not Allowed (Text) or else Times > Wide_Real (Text)) then
            for I in First .. Begin_At - 1 loop
               Logits (I) := Never;
            end loop;
         end if;
      end;
   end Apply;

   ----------
   -- Pick --
   ----------

   function Pick (Logits : Real_Array) return Token_Id is
      Best : N.Element_Count := Logits'First;
   begin
      for I in Logits'Range loop
         if Logits (I) > Logits (Best) then
            Best := I;
         end if;
      end loop;
      return Token_Id (Best - Logits'First);
   end Pick;

   ---------------------
   -- Log_Probability --
   ---------------------

   function Log_Probability (Logits : Real_Array; Token : Token_Id) return Wide_Real is
      Value : constant N.Real := Logits (Logits'First + N.Element_Count (Token));
   begin
      if not Allowed (Value) then
         return Wide_Real'First;
      end if;
      return Wide_Real (Value) - Log_Sum (Logits, Logits'First, Logits'Last);
   end Log_Probability;

   -----------------
   -- Probability --
   -----------------

   function Probability (Logits : Real_Array; Token : Token_Id) return Wide_Real is
      Log_P : constant Wide_Real := Log_Probability (Logits, Token);
   begin
      return (if Log_P = Wide_Real'First then 0.0 else Elementary.Exp (Log_P));
   end Probability;

   ------------
   -- Seeded --
   ------------

   function Seeded (Seed : Interfaces.Unsigned_64) return Stream is ((State => Seed));

   ----------
   -- Next --
   ----------

   procedure Next (Item : in out Stream; Draw : out Wide_Real) is
      use type Interfaces.Unsigned_64;
      Z : Interfaces.Unsigned_64;
   begin
      Item.State := Item.State + 16#9E37_79B9_7F4A_7C15#;
      Z := Item.State;
      Z := (Z xor Interfaces.Shift_Right (Z, 30)) * 16#BF58_476D_1CE4_E5B9#;
      Z := (Z xor Interfaces.Shift_Right (Z, 27)) * 16#94D0_49BB_1331_11EB#;
      Z := Z xor Interfaces.Shift_Right (Z, 31);
      --  The top fifty-three bits, a binary64's fraction.
      Draw := Wide_Real (Interfaces.Shift_Right (Z, 11)) / 9_007_199_254_740_992.0;
   end Next;

   ------------
   -- Sample --
   ------------

   function Sample (Logits : Real_Array; Temperature : N.Real; Draw : Wide_Real) return Token_Id is
      Top   : N.Real := Never;
      Total : Wide_Real := 0.0;
   begin
      for V of Logits loop
         Top := N.Real'Max (Top, V);
      end loop;
      for V of Logits loop
         if Allowed (V) then
            Total := Total + Elementary.Exp ((Wide_Real (V) - Wide_Real (Top)) / Wide_Real (Temperature));
         end if;
      end loop;
      declare
         Goal    : constant Wide_Real := Draw * Total;
         Running : Wide_Real := 0.0;
         Last    : N.Element_Count := Logits'First;
      begin
         for I in Logits'Range loop
            if Allowed (Logits (I)) then
               Running := Running
                 + Elementary.Exp ((Wide_Real (Logits (I)) - Wide_Real (Top)) / Wide_Real (Temperature));
               Last := I;
               if Running > Goal then
                  return Token_Id (I - Logits'First);
               end if;
            end if;
         end loop;
         return Token_Id (Last - Logits'First);
      end;
   end Sample;

   -----------------------
   -- Compression_Ratio --
   -----------------------

   function Compression_Ratio (Text : String) return Wide_Real is
      Input  : Zlib.Byte_Array (0 .. Text'Length - 1);
      Status : Zlib.Status_Code;
   begin
      if Text'Length = 0 then
         return 0.0;
      end if;
      for I in Text'Range loop
         Input (I - Text'First) := Zlib.Byte (Character'Pos (Text (I)));
      end loop;
      declare
         Packed : constant Zlib.Byte_Array := Zlib.Deflate (Input, 6, Status);
      begin
         if Status /= Zlib.Ok or else Packed'Length = 0 then
            return 0.0;
         end if;
         return Wide_Real (Text'Length) / Wide_Real (Packed'Length);
      end;
   end Compression_Ratio;

end Model_Runner.Whisper.Decoding;
