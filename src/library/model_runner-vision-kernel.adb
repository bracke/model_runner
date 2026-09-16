package body Model_Runner.Vision.Kernel is

   pragma Unreferenced (Wider);

   subtype Real is Model_Runner.Numerics.Real;
   subtype Element_Count is Model_Runner.Numerics.Element_Count;
   subtype Real_Array is Model_Runner.Numerics.Real_Array;

   use type Real;
   use type Element_Count;

   --  Lanes a partial sum has: one vector register of binary32.
   Lanes : constant := 8;

   --  Rows of A one block holds while the tiles of W walk past it: 64
   --  rows of the widest activation here are a megabyte, which is what
   --  a core's second-level cache keeps while the tile it multiplies
   --  them by sits in its first.
   Block : constant := 64;

   --------------
   -- Multiply --
   --------------

   procedure Multiply
     (A      : Real_Array;
      Rows   : Element_Count;
      W      : Real_Array;
      Wanted : Element_Count;
      Width  : Element_Count;
      C      : in out Real_Array;
      First  : Element_Count;
      Last   : Element_Count)
   is
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      --  The whole lanes of a row, and the columns past them.
      Whole : constant Element_Count := (Width / Lanes) * Lanes;

      type Lane_Sums is array (0 .. Lanes - 1) of Real;
      type Pair_Sums is array (0 .. 1, 0 .. Tile - 1) of Lane_Sums;

      --  Two rows of A at Row_A against Count rows of W at Row_W, into C.
      procedure Pair
        (Row_A : Element_Count; Two : Boolean;
         Row_W : Element_Count; Count : Element_Count)
      is
         Sums : Pair_Sums := [others => [others => [others => 0.0]]];
         A0 : constant Element_Count := A'First + Row_A * Width;
         A1 : constant Element_Count :=
           (if Two then A0 + Width else A0);
         W0 : constant Element_Count := W'First + Row_W * Width;
      begin
         if Count = Tile then
            declare
               K : Element_Count := 0;
            begin
               while K < Whole loop
                  for L in 0 .. Lanes - 1 loop
                     declare
                        X0 : constant Real := A (A0 + K + Element_Count (L));
                        X1 : constant Real := A (A1 + K + Element_Count (L));
                        Y0 : constant Real := W (W0 + K + Element_Count (L));
                        Y1 : constant Real :=
                          W (W0 + Width + K + Element_Count (L));
                        Y2 : constant Real :=
                          W (W0 + 2 * Width + K + Element_Count (L));
                        Y3 : constant Real :=
                          W (W0 + 3 * Width + K + Element_Count (L));
                     begin
                        Sums (0, 0) (L) := Sums (0, 0) (L) + X0 * Y0;
                        Sums (0, 1) (L) := Sums (0, 1) (L) + X0 * Y1;
                        Sums (0, 2) (L) := Sums (0, 2) (L) + X0 * Y2;
                        Sums (0, 3) (L) := Sums (0, 3) (L) + X0 * Y3;
                        Sums (1, 0) (L) := Sums (1, 0) (L) + X1 * Y0;
                        Sums (1, 1) (L) := Sums (1, 1) (L) + X1 * Y1;
                        Sums (1, 2) (L) := Sums (1, 2) (L) + X1 * Y2;
                        Sums (1, 3) (L) := Sums (1, 3) (L) + X1 * Y3;
                     end;
                  end loop;
                  K := K + Lanes;
               end loop;
            end;
         else
            --  The tail of W, fewer rows than a tile: one row at a time.
            for N in 0 .. Count - 1 loop
               declare
                  K : Element_Count := 0;
                  WN : constant Element_Count := W0 + N * Width;
               begin
                  while K < Whole loop
                     for L in 0 .. Lanes - 1 loop
                        declare
                           Y : constant Real := W (WN + K + Element_Count (L));
                        begin
                           Sums (0, Integer (N)) (L) :=
                             Sums (0, Integer (N)) (L)
                             + A (A0 + K + Element_Count (L)) * Y;
                           Sums (1, Integer (N)) (L) :=
                             Sums (1, Integer (N)) (L)
                             + A (A1 + K + Element_Count (L)) * Y;
                        end;
                     end loop;
                     K := K + Lanes;
                  end loop;
               end;
            end loop;
         end if;

         --  The lanes summed in order, then the columns past the lanes.
         for N in 0 .. Count - 1 loop
            for R in 0 .. (if Two then 1 else 0) loop
               declare
                  Total : Real := 0.0;
                  A_Row : constant Element_Count := (if R = 0 then A0 else A1);
                  W_Row : constant Element_Count := W0 + N * Width;
               begin
                  for L in 0 .. Lanes - 1 loop
                     Total := Total + Sums (R, Integer (N)) (L);
                  end loop;
                  for K in Whole .. Width - 1 loop
                     Total := Total + A (A_Row + K) * W (W_Row + K);
                  end loop;
                  C (C'First + (Row_A + Element_Count (R)) * Wanted + Row_W + N)
                    := Total;
               end;
            end loop;
         end loop;
      end Pair;

      Tiles : constant Element_Count := (Wanted + Tile - 1) / Tile;
      Row   : Element_Count := 0;
   begin
      if Rows = 0 or else Wanted = 0 or else First > Last
        or else First >= Tiles
      then
         return;
      end if;

      while Row < Rows loop
         declare
            Block_Last : constant Element_Count :=
              Element_Count'Min (Rows, Row + Block);
         begin
            for T in First .. Element_Count'Min (Last, Tiles - 1) loop
               declare
                  Row_W : constant Element_Count := T * Tile;
                  Count : constant Element_Count :=
                    Element_Count'Min (Tile, Wanted - Row_W);
                  R : Element_Count := Row;
               begin
                  while R < Block_Last loop
                     Pair (R, R + 1 < Block_Last, Row_W, Count);
                     R := R + 2;
                  end loop;
               end;
            end loop;
            Row := Block_Last;
         end;
      end loop;
   end Multiply;

end Model_Runner.Vision.Kernel;
