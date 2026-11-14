package body Cache_Regression is

   procedure Read_Bound
     (Text  : String;
      Value : out Long_Float;
      Valid : out Boolean)
   is
   begin
      Value := Long_Float'Value (Text);
      Valid := Value >= 0.0;
   exception
      when others =>
         Value := 0.0;
         Valid := False;
   end Read_Bound;

   procedure Read_Count
     (Text  : String;
      Value : out Natural;
      Valid : out Boolean)
   is
   begin
      Value := Natural'Value (Text);
      Valid := True;
   exception
      when others =>
         Value := 0;
         Valid := False;
   end Read_Count;

   function Hit_Rate (Item : Speed_Run.Report) return Long_Float is
   begin
      return
        (if Item.Prompt_Total = 0 then 0.0
         else 100.0 * Long_Float (Item.Prompt_Reused)
              / Long_Float (Item.Prompt_Total));
   end Hit_Rate;

   function Passed (Failures : Failure_Set) return Boolean is
   begin
      for Failed of Failures loop
         if Failed then
            return False;
         end if;
      end loop;
      return True;
   end Passed;

   procedure Check
     (Item               : Speed_Run.Report;
      Has_Turns          : Boolean;
      Hit_Minimum        : String;
      Evaluated_Maximum  : String;
      Prompt_Maximum     : String;
      Expected_Digest    : String;
      Failures           : out Failure_Set)
   is
      Asked : constant Boolean :=
        Hit_Minimum /= "" or else Evaluated_Maximum /= ""
        or else Prompt_Maximum /= "" or else Expected_Digest /= "";

      Bound       : Long_Float;
      Count_Bound : Natural;
      Valid       : Boolean;
   begin
      Failures := [others => False];

      if not Asked then
         return;
      elsif not Has_Turns then
         Failures (Turns_Required) := True;
         return;
      elsif not Item.Ran then
         Failures (Campaign_Incomplete) := True;
         return;
      end if;

      Failures (Rewind_Failed) := Item.Rewind_Failed;

      if Hit_Minimum /= "" then
         Read_Bound (Hit_Minimum, Bound, Valid);
         Failures (Invalid_Hit_Minimum) := not Valid;
         if Valid then
            Failures (Hit_Rate_Too_Low) := Hit_Rate (Item) < Bound;
         end if;
      end if;

      if Evaluated_Maximum /= "" then
         Read_Count (Evaluated_Maximum, Count_Bound, Valid);
         Failures (Invalid_Evaluated_Maximum) := not Valid;
         if Valid then
            Failures (Too_Many_Evaluated) := Item.Prompt > Count_Bound;
         end if;
      end if;

      if Prompt_Maximum /= "" then
         Read_Bound (Prompt_Maximum, Bound, Valid);
         Failures (Invalid_Prompt_Maximum) := not Valid;
         if Valid then
            Failures (Prompt_Too_Slow) :=
              Long_Float (Item.Evaluate) > Bound;
         end if;
      end if;

      if Expected_Digest /= "" then
         Failures (Digest_Differs) := Item.Digest /= Expected_Digest;
      end if;
   end Check;

end Cache_Regression;
