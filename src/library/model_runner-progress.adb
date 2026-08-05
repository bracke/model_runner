package body Model_Runner.Progress is

   -------------
   -- Publish --
   -------------

   procedure Publish (Item : Observer_Reference; Value : Event) is
   begin
      if Item /= null then
         Item.all.Notify (Value);
      end if;
   exception
      --  A progress observer belongs to the presentation layer and must not be
      --  able to fail the work it is observing.
      when others =>
         null;
   end Publish;

   -------------------
   -- Load_Progress --
   -------------------

   function Load_Progress
     (Stage     : Load_Stage;
      Completed : Interfaces.Unsigned_64 := 0;
      Total     : Interfaces.Unsigned_64 := 0;
      Detail    : String := "") return Event
   is
      Result : Event (Kind => Load_Event);
   begin
      Result.Load := Stage;
      Result.Completed := Completed;
      Result.Total := Total;
      Result.Detail := Model_Runner.Text.To_Bounded (Detail);
      return Result;
   end Load_Progress;

   -------------------------
   -- Generation_Progress --
   -------------------------

   function Generation_Progress
     (Stage     : Generation_Stage;
      Completed : Interfaces.Unsigned_64 := 0;
      Total     : Interfaces.Unsigned_64 := 0) return Event
   is
      Result : Event (Kind => Generation_Event);
   begin
      Result.Generation := Stage;
      Result.Completed := Completed;
      Result.Total := Total;
      return Result;
   end Generation_Progress;

end Model_Runner.Progress;
