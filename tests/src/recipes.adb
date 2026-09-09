with Model_Runner.Numerics;
with Model_Runner.Text;

package body Recipes is

   use type Model_Runner.Numerics.Element_Count;

   --  Whether a layer is one of the ones the policy spends more on.
   --
   --  The first eighth, the last eighth, and every third one of what is
   --  left. Transcribed rather than reasoned about: it is llama.cpp's
   --  `use_more_bits` and the point of it is to match, not to be defended.
   function More_Bits (Which, Layers : Natural) return Boolean
   is (Which < Layers / 8
       or else Which >= 7 * Layers / 8
       or else (Which - Layers / 8) mod 3 = 2);

   --  Which layer a tensor belongs to, from its own name.
   --
   --  NOT FROM A COUNTER, which is what the reference uses and what this
   --  used first. A counter is right only if the tensors arrive in layer
   --  order, and in a GGUF they arrive in the order the converter wrote
   --  them -- which for this model is lexicographic: blk.1, blk.10, blk.11,
   --  and blk.2 twelve places later. llama.cpp walks its own list, built by
   --  the loader and ordered by layer, so its counter and its layer agree;
   --  a reader walking the file's own order has to ask the name. Counting
   --  instead put a tenth of the layers' extra bits on the wrong ones.
   --
   --  Minus one where the name carries no layer.
   function Layer_Of (Name : String) return Integer;

   function Layer_Of (Name : String) return Integer is
      Head : constant String := "blk.";
      From : Natural;
      Upto : Natural;
      Value : Integer := 0;
   begin
      if Name'Length <= Head'Length
        or else Name (Name'First .. Name'First + Head'Length - 1) /= Head
      then
         return -1;
      end if;

      From := Name'First + Head'Length;
      Upto := From;

      while Upto <= Name'Last and then Name (Upto) in '0' .. '9' loop
         Upto := Upto + 1;
      end loop;

      if Upto = From then
         return -1;
      end if;

      for Index in From .. Upto - 1 loop
         Value := Value * 10 + (Character'Pos (Name (Index))
                                - Character'Pos ('0'));
      end loop;

      return Value;
   end Layer_Of;

   --  Whether a name ends in a suffix.
   function Ends_With (Name, Tail : String) return Boolean
   is (Name'Length >= Tail'Length
       and then Name (Name'Last - Tail'Length + 1 .. Name'Last) = Tail);

   -----------
   -- Named --
   -----------

   procedure Named (Text : String; Item : out Recipe; Known : out Boolean) is
      Said : constant String := Model_Runner.Text.To_Lower (Text);
   begin
      Known := True;
      for Which in Recipe loop
         if Name_Of (Which) = Said then
            Item := Which;
            return;
         end if;
      end loop;

      Item := Q4_K_M;
      Known := False;
   end Named;

   ----------
   -- Fits --
   ----------

   function Fits
     (Architecture : String;
      Experts      : Natural;
      Parameters   : Long_Long_Integer) return Boolean is
   begin
      --  A Falcon takes a different branch at nearly every rule, a mixture
      --  of experts takes another, and llama.cpp gives a model of about
      --  seventy billion parameters more bits on its attention values
      --  because eight heads share them. None of those is transcribed, and
      --  a file written as though they were would differ for a reason
      --  nothing here would record.
      return Architecture /= "falcon"
        and then Experts <= 1
        and then Parameters < 60_000_000_000;
   end Fits;

   --------------
   -- Type_For --
   --------------

   function Type_For
     (Item    : Recipe;
      Name    : String;
      Model   : Shape;
      Seen    : in out Progress;
      Columns : Long_Long_Integer) return Quantizer.Target
   is
      Chosen : Quantizer.Target := Base_Of (Item);

      Wide : constant Boolean := Model.Grouped >= 4;

      --  The layer this tensor is in, which is the number in its name and
      --  not how many of its kind have gone before.
      Layer : constant Integer := Layer_Of (Name);
   begin
      --  The output projection, and the embedding when it is the same
      --  tensor. Six bits, unless the row cannot be cut into super-blocks.
      if Name = "output.weight"
        or else (Model.Tied and then Name = "token_embd.weight")
      then
         return (if Columns mod 256 /= 0 then Quantizer.Q8_0
                 else Quantizer.Q6_K);
      end if;

      --  The embedding on its own. Every recipe here leaves it at the base
      --  format; the ones that do not are the very low-bit mixtures, which
      --  are not written here.
      if Name = "token_embd.weight" then
         return Chosen;
      end if;

      if Ends_With (Name, "attn_v.weight") then
         case Item is
            when Q2_K_Mix =>
               Chosen := (if Wide then Quantizer.Q4_K else Quantizer.Q3_K);
            when Q3_K_M =>
               Chosen :=
                 (if Layer < 2 then Quantizer.Q5_K else Quantizer.Q4_K);
            when Q3_K_L =>
               Chosen := Quantizer.Q5_K;
            when Q4_K_M | Q5_K_M =>
               if More_Bits (Layer, Model.Layers) then
                  Chosen := Quantizer.Q6_K;
               end if;
            when Q4_K_S =>
               if Layer < 4 then
                  Chosen := Quantizer.Q5_K;
               end if;
            when others =>
               null;
         end case;

         Seen.Values := Seen.Values + 1;

      elsif Ends_With (Name, "ffn_down.weight") then
         case Item is
            when Q2_K_Mix =>
               Chosen := Quantizer.Q3_K;
            when Q3_K_M =>
               Chosen :=
                 (if Layer < Model.Layers / 16 then Quantizer.Q5_K
                  else Quantizer.Q4_K);
            when Q3_K_L =>
               Chosen := Quantizer.Q5_K;
            when Q4_K_M | Q5_K_M =>
               if More_Bits (Layer, Model.Layers) then
                  Chosen := Quantizer.Q6_K;
               end if;
            when Q4_K_S =>
               if Layer < Model.Layers / 8 then
                  Chosen := Quantizer.Q5_K;
               end if;
            when others =>
               null;
         end case;

         Seen.Downs := Seen.Downs + 1;

      elsif Ends_With (Name, "attn_output.weight") then
         case Item is
            when Q2_K_Mix => Chosen := Quantizer.Q3_K;
            when Q3_K_M   => Chosen := Quantizer.Q4_K;
            when Q3_K_L   => Chosen := Quantizer.Q5_K;
            when others   => null;
         end case;

      elsif Ends_With (Name, "attn_qkv.weight") then
         case Item is
            when Q3_K_M | Q3_K_L => Chosen := Quantizer.Q4_K;
            when Q4_K_M => Chosen := Quantizer.Q5_K;
            when Q5_K_M => Chosen := Quantizer.Q6_K;
            when others => null;
         end case;

      elsif Ends_With (Name, "ffn_gate.weight") then
         Seen.Gates := Seen.Gates + 1;

      elsif Ends_With (Name, "ffn_up.weight") then
         Seen.Ups := Seen.Ups + 1;
      end if;

      --  And the shape. A super-block is two hundred and fifty-six wide, so
      --  a row that is not a multiple of it cannot hold one whatever the
      --  policy asked for.
      if Columns mod 256 /= 0
        and then Quantizer.Block_Of (Chosen) = 256
      then
         Chosen :=
           (case Chosen is
               when Quantizer.Q2_K | Quantizer.Q3_K => Quantizer.Q4_0,
               when Quantizer.Q4_K => Quantizer.Q5_0,
               when Quantizer.Q5_K => Quantizer.Q5_1,
               when others => Quantizer.Q8_0);
      end if;

      return Chosen;
   end Type_For;

end Recipes;
