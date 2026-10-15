package body Model_Runner.Platform.Signals.Waiting is

   ----------------
   -- Begin_Wait --
   ----------------

   procedure Begin_Wait (Item : in out Guard; Note : String := "") is
   begin
      Set_Waiting_For_Input (True, Note);
      Item.Held := True;
   end Begin_Wait;

   ---------------
   -- Stop_Wait --
   ---------------

   procedure Stop_Wait (Item : in out Guard) is
   begin
      if Item.Held then
         Set_Waiting_For_Input (False);
         Item.Held := False;
      end if;
   end Stop_Wait;

   --------------
   -- Finalize --
   --------------

   overriding procedure Finalize (Item : in out Guard) is
   begin
      Stop_Wait (Item);
   exception
      --  Finalization must not propagate.
      when others =>
         Item.Held := False;
   end Finalize;

end Model_Runner.Platform.Signals.Waiting;
