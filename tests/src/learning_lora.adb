package body Learning_Lora is
   pragma Suppress (Validity_Check);
   package T renames Model_Runner.Tensors;
   use type N.Element_Count;
   use type N.Real;
   use type N.Wide_Real;
   use type T.Real_Array_Access;
   use type Interfaces.Unsigned_64;
   function Shape (Item : Adapter) return Dimensions is (Item.Geometry);
   procedure Clear (Item : in out Adapter) is
      procedure Release (F : in out Factor) is
      begin
         T.Free (F.Values);
         T.Free (F.Gradient);
         T.Free (F.Mean);
         T.Free (F.Square);
      end Release;
   begin
      Release (Item.Down);
      Release (Item.Up);
      T.Free (Item.Scores);
      Item.Geometry := (others => 0);
      Item.Samples := 0;
      Item.Steps := 0;
   end Clear;
   procedure Initialize
     (Item : in out Adapter; Shape : Dimensions; Seed : Interfaces.Unsigned_64; Status : out E.Error_Info)
   is
      State : Interfaces.Unsigned_64 := (if Seed = 0 then 1 else Seed);
      function Random return N.Real is
      begin
         State := State xor Interfaces.Shift_Left (State, 13);
         State := State xor Interfaces.Shift_Right (State, 7);
         State := State xor Interfaces.Shift_Left (State, 17);
         return N.Real (State mod 65_536) / 32_768.0 - 1.0;
      end Random;
      procedure Allocate (F : in out Factor; Count : N.Element_Count) is
      begin
         T.Allocate (Count, F.Values);
         T.Allocate (Count, F.Gradient);
         T.Allocate (Count, F.Mean);
         T.Allocate (Count, F.Square);
         if F.Values = null or else F.Gradient = null or else F.Mean = null or else F.Square = null then
            Status := E.Make (E.Memory_Allocation_Failed);
            return;
         end if;
         F.Values.all := [others => 0.0];
         F.Gradient.all := [others => 0.0];
         F.Mean.all := [others => 0.0];
         F.Square.all := [others => 0.0];
      end Allocate;
   begin
      Status := E.Success;
      if Shape.Width not in 1 .. 8_192 or else Shape.Vocabulary not in 2 .. 262_144
        or else Shape.Rank not in 1 .. 64
        or else Long_Long_Integer (Shape.Rank) * Long_Long_Integer (Shape.Width + Shape.Vocabulary) > 8_388_608
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      Clear (Item);
      Allocate (Item.Down, N.Element_Count (Shape.Width * Shape.Rank));
      if E.Is_Ok (Status) then
         Allocate (Item.Up, N.Element_Count (Shape.Vocabulary * Shape.Rank));
      end if;
      if E.Is_Ok (Status) then
         T.Allocate (N.Element_Count (Shape.Vocabulary), Item.Scores);
         if Item.Scores = null then
            Status := E.Make (E.Memory_Allocation_Failed);
         end if;
      end if;
      if E.Is_Error (Status) then
         Clear (Item);
         return;
      end if;
      Item.Geometry := Shape;
      for Value of Item.Down.Values.all loop
         Value := Random / N.Real (N.Sqrt (N.Wide_Real (Shape.Width)));
      end loop;
   end Initialize;
   procedure Get_Factors (Item : Adapter; Down, Up : out N.Real_Array; Status : out E.Error_Info) is
   begin
      Status := E.Success;
      if Item.Scores = null or else Down'Length /= Item.Down.Values'Length or else Up'Length /= Item.Up.Values'Length
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      Down := Item.Down.Values.all;
      Up := Item.Up.Values.all;
   end Get_Factors;
   procedure Begin_Batch (Item : in out Adapter) is
   begin
      if Item.Scores /= null then
         Item.Down.Gradient.all := [others => 0.0];
         Item.Up.Gradient.all := [others => 0.0];
         Item.Samples := 0;
      end if;
   end Begin_Batch;
   procedure Set_Factors (Item : in out Adapter; Down, Up : N.Real_Array; Status : out E.Error_Info) is
   begin
      Status := E.Success;
      if Item.Scores = null or else Down'Length /= Item.Down.Values'Length or else Up'Length /= Item.Up.Values'Length
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      for Value of Down loop
         if not N.Is_Finite (Value) then
            Status := E.Make (E.Tensor_Non_Finite_Value);
            return;
         elsif abs Value > 1_000.0 then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text (Status, "feature", "training_factor_magnitude", E.Param_Identifier);
            return;
         end if;
      end loop;
      for Value of Up loop
         if not N.Is_Finite (Value) then
            Status := E.Make (E.Tensor_Non_Finite_Value);
            return;
         elsif abs Value > 1_000.0 then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text (Status, "feature", "training_factor_magnitude", E.Param_Identifier);
            return;
         end if;
      end loop;
      Item.Down.Values.all := Down;
      Item.Up.Values.all := Up;
      Item.Down.Mean.all := [others => 0.0];
      Item.Down.Square.all := [others => 0.0];
      Item.Up.Mean.all := [others => 0.0];
      Item.Up.Square.all := [others => 0.0];
      Item.Steps := 0;
      Begin_Batch (Item);
   end Set_Factors;
   procedure Observe
     (Item : in out Adapter; Hidden, Base : N.Real_Array; Target : Natural;
      Differentiate : Boolean; Loss : out N.Wide_Real; Status : out E.Error_Info)
   is
      Width : constant N.Element_Count := N.Element_Count (Item.Geometry.Width);
      Rank : constant N.Element_Count := N.Element_Count (Item.Geometry.Rank);
      Vocabulary : constant N.Element_Count := N.Element_Count (Item.Geometry.Vocabulary);
      Latent, Back : N.Real_Array (0 .. Rank - 1) := [others => 0.0];
      Most : N.Real := N.Real'First;
      Sum : N.Wide_Real := 0.0;
   begin
      Status := E.Success;
      Loss := 0.0;
      if Item.Scores = null or else Hidden'Length /= Width or else Base'Length /= Vocabulary
        or else Target >= Item.Geometry.Vocabulary or else Item.Samples >= 65_536
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      for Value of Hidden loop
         if not N.Is_Finite (Value) then
            Status := E.Make (E.Tensor_Non_Finite_Value);
            return;
         elsif abs Value > 1.0E6 then
            Status := E.Make (E.Arch_Unsupported_Feature);
            E.Add_Text (Status, "feature", "training_feature_magnitude", E.Param_Identifier);
            return;
         end if;
      end loop;
      for R in Latent'Range loop
         declare
            Dot : N.Wide_Real := 0.0;
         begin
            for C in 0 .. Width - 1 loop
               Dot := Dot + N.Wide_Real (Item.Down.Values (R * Width + C)) * N.Wide_Real (Hidden (Hidden'First + C));
            end loop;
            if not N.Is_Finite (Dot) or else abs Dot > N.Wide_Real (N.Real'Last) then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               return;
            end if;
            Latent (R) := N.Real (Dot);
         end;
      end loop;
      for V in 0 .. Vocabulary - 1 loop
         declare
            Logit : N.Wide_Real := N.Wide_Real (Base (Base'First + V));
         begin
            for R in 0 .. Rank - 1 loop
               Logit := Logit + N.Wide_Real (Item.Up.Values (V * Rank + R)) * N.Wide_Real (Latent (R));
            end loop;
            if not N.Is_Finite (Logit) or else abs Logit > N.Wide_Real (N.Real'Last) then
               Status := E.Make (E.Tensor_Non_Finite_Value);
               return;
            end if;
            Item.Scores (V) := N.Real (Logit);
            Most := N.Real'Max (Most, Item.Scores (V));
         end;
      end loop;
      for Value of Item.Scores.all loop
         Sum := Sum + N.Exp (N.Wide_Real (Value) - N.Wide_Real (Most));
      end loop;
      Loss := N.Log (Sum) + N.Wide_Real (Most) - N.Wide_Real (Item.Scores (N.Element_Count (Target)));
      if not Differentiate then
         return;
      end if;
      for V in 0 .. Vocabulary - 1 loop
         declare
            D : constant N.Real := N.Real (N.Exp (N.Wide_Real (Item.Scores (V)) - N.Wide_Real (Most)) / Sum)
              - (if Natural (V) = Target then 1.0 else 0.0);
         begin
            for R in 0 .. Rank - 1 loop
               Item.Up.Gradient (V * Rank + R) := Item.Up.Gradient (V * Rank + R) + D * Latent (R);
               Back (R) := Back (R) + D * Item.Up.Values (V * Rank + R);
            end loop;
         end;
      end loop;
      for R in 0 .. Rank - 1 loop
         for C in 0 .. Width - 1 loop
            Item.Down.Gradient (R * Width + C) :=
              Item.Down.Gradient (R * Width + C) + Back (R) * Hidden (Hidden'First + C);
         end loop;
      end loop;
      Item.Samples := Item.Samples + 1;
   end Observe;
   procedure Gradients (Item : Adapter; Down, Up : out N.Real_Array; Status : out E.Error_Info) is
   begin
      Status := E.Success;
      if Item.Scores = null or else Item.Samples = 0 or else Down'Length /= Item.Down.Gradient'Length
        or else Up'Length /= Item.Up.Gradient'Length
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      Down := Item.Down.Gradient.all;
      Up := Item.Up.Gradient.all;
   end Gradients;
   procedure Step (Item : in out Adapter; Rate, Clip : N.Real; Status : out E.Error_Info) is
      Norm : N.Wide_Real := 0.0;
      Scale : N.Real;
      procedure Count (F : Factor) is
      begin
         for G of F.Gradient.all loop
            Norm := Norm + N.Wide_Real (G) ** 2;
         end loop;
      end Count;
      procedure Update (F : in out Factor) is
         Correct_M : constant N.Real := 1.0 - 0.9 ** Item.Steps;
         Correct_V : constant N.Real := 1.0 - 0.999 ** Item.Steps;
      begin
         for I in F.Values'Range loop
            declare
               G : constant N.Real := F.Gradient (I) * Scale;
            begin
               F.Mean (I) := 0.9 * F.Mean (I) + 0.1 * G;
               F.Square (I) := 0.999 * F.Square (I) + 0.001 * G * G;
               F.Values (I) := F.Values (I) - Rate * (F.Mean (I) / Correct_M)
                 / (N.Real (N.Sqrt (N.Wide_Real (F.Square (I) / Correct_V))) + 1.0E-8);
            end;
         end loop;
      end Update;
   begin
      Status := E.Success;
      if Item.Scores = null or else Item.Samples = 0 or else Item.Steps >= 1_000_000
        or else not N.Is_Finite (Rate) or else Rate <= 0.0 or else Rate > 0.01
        or else not N.Is_Finite (Clip) or else Clip <= 0.0 or else Clip > 100.0
      then
         Status := E.Make (E.Tensor_Shape_Mismatch);
         return;
      end if;
      Count (Item.Down);
      Count (Item.Up);
      if not N.Is_Finite (Norm) then
         Status := E.Make (E.Tensor_Non_Finite_Value);
         return;
      end if;
      Scale := N.Real (1.0 / N.Wide_Real (Item.Samples));
      Norm := N.Sqrt (Norm) * N.Wide_Real (Scale);
      if Norm > N.Wide_Real (Clip) then
         Scale := Scale * N.Real (N.Wide_Real (Clip) / Norm);
      end if;
      Item.Steps := Item.Steps + 1;
      Update (Item.Down);
      Update (Item.Up);
      Begin_Batch (Item);
   end Step;
   overriding procedure Finalize (Item : in out Adapter) is
   begin
      Clear (Item);
   end Finalize;
end Learning_Lora;
