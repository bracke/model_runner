with Ada.Unchecked_Deallocation;
with Ada.Numerics.Generic_Elementary_Functions;

package body Model_Runner.Whisper.Timing is

   package N renames Model_Runner.Numerics;

   package Elementary is new Ada.Numerics.Generic_Elementary_Functions (Wide_Real);

   --  On the heap: a window's tokens by its frames is a megabyte or more.
   type Cost_Access is access Cost_Matrix;
   procedure Free is new Ada.Unchecked_Deallocation (Cost_Matrix, Cost_Access);

   use type Wide_Real;

   -------------------
   -- Median_Filter --
   -------------------

   procedure Median_Filter (Item : in out Cost_Matrix; Width : Positive := 7) is
      Pad  : constant Natural := Width / 2;
      Cols : constant Natural := Item'Length (2);
      Row  : array (0 .. Cols - 1) of Wide_Real;
      Hold : array (1 .. Width) of Wide_Real;

      --  Column C of the row, reflected about its ends as torch's reflect
      --  padding is: the end not repeated.
      function At_Column (C : Integer) return Wide_Real is
        (Row (if C < 0 then -C elsif C >= Cols then 2 * (Cols - 1) - C else C));
   begin
      if Cols <= Pad then
         return;
      end if;
      for R in Item'Range (1) loop
         for C in 0 .. Cols - 1 loop
            Row (C) := Item (R, Item'First (2) + C);
         end loop;
         for C in 0 .. Cols - 1 loop
            for K in Hold'Range loop
               Hold (K) := At_Column (C - Pad + K - 1);
            end loop;
            --  Insertion sort: seven values.
            for I in 2 .. Width loop
               declare
                  V : constant Wide_Real := Hold (I);
                  J : Natural := I - 1;
               begin
                  while J >= 1 and then Hold (J) > V loop
                     Hold (J + 1) := Hold (J);
                     J := J - 1;
                  end loop;
                  Hold (J + 1) := V;
               end;
            end loop;
            Item (R, Item'First (2) + C) := Hold (Pad + 1);
         end loop;
      end loop;
   end Median_Filter;

   -------------
   -- Weights --
   -------------

   procedure Weights
     (Scores                : N.Real_Array;
      Heads, Tokens, Frames : Positive;
      Stride                : Positive;
      Into                  : out Cost_Matrix)
   is
      Held : Cost_Access := new Cost_Matrix (0 .. Tokens - 1, 0 .. Frames - 1);
      One  : Cost_Matrix renames Held.all;
   begin
      for R in Into'Range (1) loop
         for C in Into'Range (2) loop
            Into (R, C) := 0.0;
         end loop;
      end loop;
      for A in 0 .. Heads - 1 loop
         --  A softmax over the frames heard, each token's row.
         for T in 0 .. Tokens - 1 loop
            declare
               Base : constant N.Element_Count := N.Element_Count ((A * Tokens + T) * Stride);
               Top  : Wide_Real := Wide_Real'First;
               Sum  : Wide_Real := 0.0;
            begin
               for F in 0 .. Frames - 1 loop
                  Top := Wide_Real'Max (Top, Wide_Real (Scores (Scores'First + Base + N.Element_Count (F))));
               end loop;
               for F in 0 .. Frames - 1 loop
                  One (T, F) := Elementary.Exp (Wide_Real (Scores (Scores'First + Base + N.Element_Count (F))) - Top);
                  Sum := Sum + One (T, F);
               end loop;
               for F in 0 .. Frames - 1 loop
                  One (T, F) := One (T, F) / Sum;
               end loop;
            end;
         end loop;
         --  Each frame standardized over the tokens.
         for F in 0 .. Frames - 1 loop
            declare
               Mean, Spread : Wide_Real := 0.0;
            begin
               for T in 0 .. Tokens - 1 loop
                  Mean := Mean + One (T, F);
               end loop;
               Mean := Mean / Wide_Real (Tokens);
               for T in 0 .. Tokens - 1 loop
                  Spread := Spread + (One (T, F) - Mean) ** 2;
               end loop;
               Spread := Elementary.Sqrt (Spread / Wide_Real (Tokens));
               for T in 0 .. Tokens - 1 loop
                  One (T, F) := (One (T, F) - Mean) / (if Spread = 0.0 then 1.0 else Spread);
               end loop;
            end;
         end loop;
         Median_Filter (One);
         for T in 0 .. Tokens - 1 loop
            for F in 0 .. Frames - 1 loop
               Into (Into'First (1) + T, Into'First (2) + F) :=
                 Into (Into'First (1) + T, Into'First (2) + F) + One (T, F) / Wide_Real (Heads);
            end loop;
         end loop;
      end loop;
      Free (Held);
   end Weights;

   ----------
   -- Warp --
   ----------

   procedure Warp
     (Cost       : Cost_Matrix;
      Rows_Of    : out Index_List;
      Columns_Of : out Index_List;
      Steps      : out Natural)
   is
      Rows : constant Natural := Cost'Length (1);
      Cols : constant Natural := Cost'Length (2);
      type Move is (Diagonal, Down, Across, None);
      type Move_Matrix is array (Natural range <>, Natural range <>) of Move;
      type Move_Access is access Move_Matrix;
      procedure Free is new Ada.Unchecked_Deallocation (Move_Matrix, Move_Access);
      Held  : Cost_Access := new Cost_Matrix (0 .. Rows, 0 .. Cols);
      Moves : Move_Access := new Move_Matrix'(0 .. Rows => [0 .. Cols => None]);
      Total : Cost_Matrix renames Held.all;
      Trace : Move_Matrix renames Moves.all;
      Unreached : constant Wide_Real := Wide_Real'Last;
   begin
      for I in 0 .. Rows loop
         for J in 0 .. Cols loop
            Total (I, J) := Unreached;
         end loop;
      end loop;
      Total (0, 0) := 0.0;
      for J in 1 .. Cols loop
         for I in 1 .. Rows loop
            declare
               C0 : constant Wide_Real := Total (I - 1, J - 1);
               C1 : constant Wide_Real := Total (I - 1, J);
               C2 : constant Wide_Real := Total (I, J - 1);
               C  : Wide_Real;
            begin
               if C0 < C1 and then C0 < C2 then
                  C := C0;
                  Trace (I, J) := Diagonal;
               elsif C1 < C0 and then C1 < C2 then
                  C := C1;
                  Trace (I, J) := Down;
               else
                  C := C2;
                  Trace (I, J) := Across;
               end if;
               Total (I, J) :=
                 (if C = Unreached then Unreached
                  else Cost (Cost'First (1) + I - 1, Cost'First (2) + J - 1) + C);
            end;
         end loop;
      end loop;

      --  Back from the last cell; the first row goes across, the first
      --  column down, as the reference's backtrace sets them.
      declare
         I : Natural := Rows;
         J : Natural := Cols;
         Count : Natural := 0;
         Back_Rows, Back_Cols : Index_List (1 .. Rows + Cols);
      begin
         while I > 0 or else J > 0 loop
            Count := Count + 1;
            Back_Rows (Count) := Natural'Max (I, 1) - 1;
            Back_Cols (Count) := Natural'Max (J, 1) - 1;
            declare
               Step : constant Move :=
                 (if I = 0 then Across elsif J = 0 then Down else Trace (I, J));
            begin
               case Step is
                  when Diagonal =>
                     I := I - 1;
                     J := J - 1;
                  when Down =>
                     I := I - 1;
                  when Across | None =>
                     J := J - 1;
               end case;
            end;
         end loop;
         Steps := Count;
         for K in 1 .. Count loop
            Rows_Of (Rows_Of'First + K - 1) := Back_Rows (Count - K + 1);
            Columns_Of (Columns_Of'First + K - 1) := Back_Cols (Count - K + 1);
         end loop;
      end;
      Free (Held);
      Free (Moves);
   end Warp;

end Model_Runner.Whisper.Timing;
