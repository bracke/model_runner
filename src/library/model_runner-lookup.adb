package body Model_Runner.Lookup is

   function Verification_Length
     (Expected, Cost : Cost_Array; Samples : Sample_Array;
      Limit, Fallback : Positive) return Positive
   is
      Best : Positive := Positive'Min (Limit, Fallback);
      function Rate (At_Length : Positive) return Long_Float is
      begin
         if At_Length not in Expected'Range or else At_Length not in Cost'Range
           or else At_Length not in Samples'Range or else Samples (At_Length) < 3
           or else Cost (At_Length) <= 0.0 or else Expected (At_Length) <= 0.0
           or else Cost (At_Length) > Long_Float'Last or else Expected (At_Length) > Long_Float'Last
           or else Cost (At_Length) /= Cost (At_Length) or else Expected (At_Length) /= Expected (At_Length)
         then return 0.0; end if;
         return Expected (At_Length) / Cost (At_Length);
      end Rate;
   begin
      if Rate (Best) = 0.0 then return Best; end if;
      for Length in 1 .. Limit loop
         if Rate (Length) > 1.02 * Rate (Best) then Best := Length; end if;
      end loop;
      return Best;
   end Verification_Length;

   -------------
   -- Propose --
   -------------

   procedure Propose
     (History : Token_Array;
      Into    : out Token_Array;
      Count   : out Natural;
      Key     : Positive := Default_Key)
   is
      use type Model_Runner.Tokenizer.Token_Id;

      Held : constant Natural := History'Length;
   begin
      Count := 0;

      if Into'Length = 0 then
         return;
      end if;

      --  A key at the end and at least one token before it to match
      --  against, or there is nothing to search.
      if Held < Key + 1 then
         return;
      end if;

      declare
         --  Where the key sits: the last Key tokens of the history.
         Key_At : constant Natural := History'Last - Key + 1;
      begin
         --  Backwards from the latest earlier occurrence, so that a phrase
         --  said many times proposes what followed it last.
         for Start in reverse History'First .. Key_At - 1 loop
            declare
               Same : Boolean := True;
            begin
               for Offset in 0 .. Key - 1 loop
                  if History (Start + Offset)
                     /= History (Key_At + Offset)
                  then
                     Same := False;
                     exit;
                  end if;
               end loop;

               if Same then
                  --  What came after it, as much of it as asked for and as
                  --  the history has. The match cannot run to the end --
                  --  Start is below Key_At -- so there is always at least
                  --  one token here.
                  declare
                     From : constant Natural := Start + Key;
                     Most : constant Natural :=
                       Natural'Min (Into'Length, History'Last - From + 1);
                  begin
                     for Step in 0 .. Most - 1 loop
                        Into (Into'First + Step) := History (From + Step);
                     end loop;

                     Count := Most;
                     return;
                  end;
               end if;
            end;
         end loop;
      end;
   end Propose;

end Model_Runner.Lookup;
