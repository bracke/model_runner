package body Model_Runner.Lookup is

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
