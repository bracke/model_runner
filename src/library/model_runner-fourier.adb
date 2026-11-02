with Ada.Numerics;
with Ada.Numerics.Generic_Elementary_Functions;

package body Model_Runner.Fourier is

   package Elementary is
     new Ada.Numerics.Generic_Elementary_Functions (Wide_Real);

   use type Wide_Real;
   use type Model_Runner.Numerics.Element_Count;

   -------------
   -- Prepare --
   -------------

   procedure Prepare (Item : in out Plan) is
      N    : constant Positive := Item.Length;
      Left : Positive := N;
      P    : Positive := 4;
   begin
      --  Fours while they divide, then twos, then the odd numbers; a
      --  remainder with no factor below its root is a factor of its own.
      Item.Factors := 0;
      while Left > 1 loop
         while Left mod P /= 0 loop
            P := (case P is when 4 => 2, when 2 => 3, when others => P + 2);
            if P * P > Left then
               P := Left;
            end if;
         end loop;
         Item.Factors := Item.Factors + 1;
         Item.Radix (Item.Factors) := P;
         Left := Left / P;
      end loop;

      for J in 0 .. N - 1 loop
         declare
            Angle : constant Wide_Real :=
              -2.0 * Ada.Numerics.Pi * Wide_Real (J) / Wide_Real (N);
         begin
            Item.Cos_Of (J + 1) := Elementary.Cos (Angle);
            Item.Sin_Of (J + 1) := Elementary.Sin (Angle);
         end;
      end loop;
      Item.Prepared := True;
   end Prepare;

   --  The transform of the In_ elements In_At, In_At + Stride, ... into
   --  Out_ from Out_At, for the factors from Stage on: each of the
   --  stage's P sub-transforms made first, then the butterflies of radix
   --  P that join them.
   procedure Work
     (Item   : in out Plan;
      Out_At : Natural;
      In_At  : Natural;
      Stride : Positive;
      Stage  : Positive)
   is
      N : constant Positive := Item.Length;
      P : constant Positive := Item.Radix (Stage);
      M : Positive := 1;
   begin
      for Later in Stage + 1 .. Item.Factors loop
         M := M * Item.Radix (Later);
      end loop;

      if M = 1 then
         for J in 0 .. P - 1 loop
            Item.Out_Re (Out_At + J + 1) := Item.In_Re (In_At + J * Stride + 1);
            Item.Out_Im (Out_At + J + 1) := Item.In_Im (In_At + J * Stride + 1);
         end loop;
      else
         for J in 0 .. P - 1 loop
            Work (Item, Out_At + J * M, In_At + J * Stride, Stride * P,
                  Stage + 1);
         end loop;
      end if;

      for U in 0 .. M - 1 loop
         for Q in 0 .. P - 1 loop
            Item.Scratch_Re (Q + 1) := Item.Out_Re (Out_At + U + Q * M + 1);
            Item.Scratch_Im (Q + 1) := Item.Out_Im (Out_At + U + Q * M + 1);
         end loop;
         for Q1 in 0 .. P - 1 loop
            declare
               K     : constant Natural := U + Q1 * M;
               Index : Natural := 0;
               Re    : Wide_Real := Item.Scratch_Re (0 + 1);
               Im    : Wide_Real := Item.Scratch_Im (0 + 1);
            begin
               for Q in 1 .. P - 1 loop
                  Index := Index + Stride * K;
                  Index := Index mod N;
                  Re := Re + Item.Scratch_Re (Q + 1) * Item.Cos_Of (Index + 1)
                    - Item.Scratch_Im (Q + 1) * Item.Sin_Of (Index + 1);
                  Im := Im + Item.Scratch_Re (Q + 1) * Item.Sin_Of (Index + 1)
                    + Item.Scratch_Im (Q + 1) * Item.Cos_Of (Index + 1);
               end loop;
               Item.Out_Re (Out_At + K + 1) := Re;
               Item.Out_Im (Out_At + K + 1) := Im;
            end;
         end loop;
      end loop;
   end Work;

   ------------------
   -- Forward_Real --
   ------------------

   procedure Forward_Real
     (Item           : in out Plan;
      Input          : Wide_Real_Array;
      Real_Part      : out Wide_Real_Array;
      Imaginary_Part : out Wide_Real_Array) is
   begin
      for J in 0 .. Item.Length - 1 loop
         Item.In_Re (J + 1) := Input (Input'First + Model_Runner.Numerics.Element_Count (J));
         Item.In_Im (J + 1) := 0.0;
      end loop;
      Work (Item, 0, 0, 1, 1);
      for K in 0 .. Item.Length / 2 loop
         Real_Part (Real_Part'First + Model_Runner.Numerics.Element_Count (K)) := Item.Out_Re (K + 1);
         Imaginary_Part (Imaginary_Part'First + Model_Runner.Numerics.Element_Count (K)) :=
           Item.Out_Im (K + 1);
      end loop;
   end Forward_Real;

   ---------------------------
   -- Forward_Real_Directly --
   ---------------------------

   procedure Forward_Real_Directly
     (Input          : Wide_Real_Array;
      Real_Part      : out Wide_Real_Array;
      Imaginary_Part : out Wide_Real_Array)
   is
      N : constant Model_Runner.Numerics.Element_Count := Input'Length;
   begin
      for K in 0 .. N / 2 loop
         declare
            Re, Im : Wide_Real := 0.0;
         begin
            for J in 0 .. N - 1 loop
               declare
                  Angle : constant Wide_Real :=
                    -2.0 * Ada.Numerics.Pi * Wide_Real ((K * J) mod N) / Wide_Real (N);
                  X     : constant Wide_Real := Input (Input'First + J);
               begin
                  Re := Re + X * Elementary.Cos (Angle);
                  Im := Im + X * Elementary.Sin (Angle);
               end;
            end loop;
            Real_Part (Real_Part'First + K) := Re;
            Imaginary_Part (Imaginary_Part'First + K) := Im;
         end;
      end loop;
   end Forward_Real_Directly;

end Model_Runner.Fourier;
