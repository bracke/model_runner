with Model_Runner.Kernels;
with Model_Runner.Numerics;

package body Model_Runner.Delta_Rule.Kernel is

   package N renames Model_Runner.Numerics;

   use type Real;
   use type N.Wide_Real;

   pragma Unreferenced (Wider);

   --  How many positions read the state together, which is what the
   --  nearest cache holds beside a row of it.
   Block : constant := 8;

   procedure Chunk
     (State        : in out Real_Array;
      From         : Element_Count;
      Written      : Slot_Origins;
      Head         : Element_Count;
      Count        : Element_Count;
      Mixed        : Real_Array;
      Stride       : Element_Count;
      Key_At       : Element_Count;
      Query_At     : Element_Count;
      Value_At     : Element_Count;
      Decay        : Real_Array;
      Rate         : Real_Array;
      Z_Gate       : Real_Array;
      Z_At         : Element_Count;
      Z_Stride     : Element_Count;
      Blend        : in out Real_Array;
      Blend_At     : Element_Count;
      Blend_Stride : Element_Count;
      State_Norm   : Real_Array;
      Epsilon      : Real;
      Scale        : Real)
   is
      --  The chunk's numbers: the products of decays from one position to
      --  another, what the state says of each key and of each query, the
      --  keys and queries turned round, the two triangles, the
      --  corrections, and a row on the way.
      Between   : Real_Array (0 .. Count * Count - 1);
      Of_Key    : Real_Array (0 .. Count * Head - 1);
      Of_Query  : Real_Array (0 .. Count * Head - 1);
      Keys_T    : Real_Array (0 .. Count * Head - 1);
      Queries_T : Real_Array (0 .. Count * Head - 1);
      Gram      : Real_Array (0 .. Count * Count - 1);
      Cross     : Real_Array (0 .. Count * Count - 1);
      Fix       : Real_Array (0 .. Count * Head - 1);
      Read      : Real_Array (0 .. Head - 1);
      Row       : Real_Array (0 .. Head - 1);
      Gate      : Real_Array (0 .. Head - 1);

      --  The reach is the caller's to prove -- it proves it once for a
      --  share of heads -- and the checks are left out of the loops,
      --  which is what lets them run as rows rather than as an index
      --  check an element.
      pragma Suppress (Index_Check);
      pragma Suppress (Range_Check);
      pragma Suppress (Overflow_Check);

      function Row_At (Position : Element_Count) return Element_Count
      is (Mixed'First + Position * Stride);

      D0 : constant Element_Count := Decay'First;
      R0 : constant Element_Count := Rate'First;
      N0 : constant Element_Count := State_Norm'First;
   begin
      if Count = 0 or else Count > Chunk_Most then
         return;
      end if;

      --  Between (S, T) for S <= T: the decays from S + 1 to T, one for
      --  S = T. The products are products and not quotients of a running
      --  product: a decay can be very small, and a quotient of two small
      --  numbers is not the product that was meant.
      for S in 0 .. Count - 1 loop
         Between (S * Count + S) := 1.0;
         for T in S + 1 .. Count - 1 loop
            Between (S * Count + T) :=
              Between (S * Count + T - 1) * Decay (D0 + T);
         end loop;
      end loop;

      --  What the state says of every key and every query: a few
      --  positions at a time over the whole state, so that the running
      --  rows stay in the nearest cache while the state streams past.
      Of_Key := [others => 0.0];
      Of_Query := [others => 0.0];
      for Part in 0 .. (Count - 1) / Block loop
         declare
            First : constant Element_Count := Part * Block;
            Last  : constant Element_Count :=
              Element_Count'Min (First + Block, Count) - 1;
         begin
            for I in 0 .. Head - 1 loop
               declare
                  Base : constant Element_Count := From + I * Head;
               begin
                  for S in First .. Last loop
                     declare
                        Key   : constant Real := Mixed (Row_At (S) + Key_At + I);
                        Query : constant Real :=
                          Mixed (Row_At (S) + Query_At + I);
                        K_Row : constant Element_Count := S * Head;
                     begin
                        for J in 0 .. Head - 1 loop
                           Of_Key (K_Row + J) :=
                             Of_Key (K_Row + J) + State (Base + J) * Key;
                           Of_Query (K_Row + J) :=
                             Of_Query (K_Row + J) + State (Base + J) * Query;
                        end loop;
                     end;
                  end loop;
               end;
            end loop;
         end;
      end loop;

      --  The keys against each other, and against the queries: the
      --  chunk's keys and queries turned round first, a dimension's worth
      --  of every position together, so that each triangle is built a
      --  row at a time from a dimension's products rather than a dot
      --  product an entry -- a dot product is a chain of dependent
      --  additions, and a thousand of them a head were most of what a
      --  chunk cost.
      for T in 0 .. Count - 1 loop
         for I in 0 .. Head - 1 loop
            Keys_T (I * Count + T) := Mixed (Row_At (T) + Key_At + I);
            Queries_T (I * Count + T) := Mixed (Row_At (T) + Query_At + I);
         end loop;
      end loop;

      Gram := [others => 0.0];
      Cross := [others => 0.0];
      for S in 0 .. Count - 1 loop
         declare
            K_S   : constant Element_Count := Row_At (S) + Key_At;
            G_Row : constant Element_Count := S * Count;
         begin
            for I in 0 .. Head - 1 loop
               declare
                  Key  : constant Real := Mixed (K_S + I);
                  Base : constant Element_Count := I * Count;
               begin
                  for T in S .. Count - 1 loop
                     Gram (G_Row + T) := Gram (G_Row + T) + Key * Keys_T (Base + T);
                     Cross (G_Row + T) :=
                       Cross (G_Row + T) + Key * Queries_T (Base + T);
                  end loop;
               end;
            end loop;
         end;
      end loop;

      --  The corrections, each from the ones before it.
      for S in 0 .. Count - 1 loop
         declare
            F_Row : constant Element_Count := S * Head;
            V_S   : constant Element_Count := Row_At (S) + Value_At;
            G_S   : constant Real := Between (S) * Decay (D0);
         begin
            for J in 0 .. Head - 1 loop
               Fix (F_Row + J) := Mixed (V_S + J) - G_S * Of_Key (F_Row + J);
            end loop;

            for R in 0 .. S - 1 loop
               declare
                  Weight : constant Real :=
                    Between (R * Count + S) * Gram (R * Count + S);
                  R_Row  : constant Element_Count := R * Head;
               begin
                  for J in 0 .. Head - 1 loop
                     Fix (F_Row + J) := Fix (F_Row + J) - Weight * Fix (R_Row + J);
                  end loop;
               end;
            end loop;

            for J in 0 .. Head - 1 loop
               Fix (F_Row + J) := Fix (F_Row + J) * Rate (R0 + S);
            end loop;
         end;
      end loop;

      --  The answers, normalized and gated, into the blend.
      for T in 0 .. Count - 1 loop
         declare
            O_At : constant Element_Count := Blend_At + T * Blend_Stride;
            G_At : constant Element_Count := Z_At + T * Z_Stride;
            G_T  : constant Real := Between (T) * Decay (D0);
            Sum  : N.Wide_Real := 0.0;
         begin
            for J in 0 .. Head - 1 loop
               Read (J) := G_T * Of_Query (T * Head + J);
            end loop;

            for S in 0 .. T loop
               declare
                  Weight : constant Real :=
                    Between (S * Count + T) * Cross (S * Count + T);
                  F_Row  : constant Element_Count := S * Head;
               begin
                  for J in 0 .. Head - 1 loop
                     Read (J) := Read (J) + Weight * Fix (F_Row + J);
                  end loop;
               end;
            end loop;

            for J in 0 .. Head - 1 loop
               Read (J) := Read (J) * Scale;
               Sum := Sum + N.Wide_Real (Read (J)) * N.Wide_Real (Read (J));
            end loop;

            --  The gate's unit through the kernel that takes the
            --  exponential in binary32: a hundred and twenty-eight of the
            --  library's a head a position were most of what the rule
            --  cost past its rows.
            Gate := Z_Gate (G_At .. G_At + Head - 1);
            Model_Runner.Kernels.SiLU (Gate);

            declare
               Root : constant Real :=
                 Real (1.0 / N.Sqrt (Sum / N.Wide_Real (Head)
                                     + N.Wide_Real (Epsilon)));
            begin
               for J in 0 .. Head - 1 loop
                  Blend (O_At + J) :=
                    Read (J) * Root * State_Norm (N0 + J) * Gate (J);
               end loop;
            end;
         end;
      end loop;

      --  The states the chunk leaves, a row at a time from the row it
      --  began with: each position's is the one before decayed and
      --  corrected, and the ones nobody asks for are not written. The
      --  row is read before any position's is written, so a slot written
      --  may be the slot read.
      for I in 0 .. Head - 1 loop
         declare
            Base : constant Element_Count := From + I * Head;
         begin
            Row := State (Base .. Base + Head - 1);

            for T in 0 .. Count - 1 loop
               declare
                  Key   : constant Real := Mixed (Row_At (T) + Key_At + I);
                  A     : constant Real := Decay (D0 + T);
                  F_Row : constant Element_Count := T * Head;
                  Slot  : constant Element_Count := Written (T);
               begin
                  for J in 0 .. Head - 1 loop
                     Row (J) := Row (J) * A + Key * Fix (F_Row + J);
                  end loop;

                  if Slot /= Nowhere then
                     State (Slot + I * Head .. Slot + I * Head + Head - 1) := Row;
                  end if;
               end;
            end loop;
         end;
      end loop;
   end Chunk;

end Model_Runner.Delta_Rule.Kernel;
